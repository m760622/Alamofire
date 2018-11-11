//
//  ParameterEncoder.swift
//
//  Copyright (c) 2014-2018 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

public protocol ParameterEncoder {
    func encode<Parameters: Encodable>(_ parameters: Parameters?, into request: URLRequestConvertible) throws -> URLRequest
}

open class JSONParameterEncoder: ParameterEncoder {
    public static var `default`: JSONParameterEncoder { return JSONParameterEncoder() }
    public static var prettyPrinted: JSONParameterEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        return JSONParameterEncoder(encoder: encoder)
    }
    @available(macOS 10.13, iOS 11.0, tvOS 11.0, watchOS 4.0, *)
    public static var sortedKeys: JSONParameterEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        return JSONParameterEncoder(encoder: encoder)
    }

    let encoder: JSONEncoder

    public init(encoder: JSONEncoder = JSONEncoder()) {
        self.encoder = encoder
    }

    open func encode<Parameters: Encodable>(_ parameters: Parameters?,
                                            into request: URLRequestConvertible) throws -> URLRequest {
        var urlRequest = try request.asURLRequest()

        guard let parameters = parameters else { return urlRequest }

        do {
            let data = try encoder.encode(parameters)
            urlRequest.httpBody = data
            if urlRequest.httpHeaders["Content-Type"] == nil {
                urlRequest.httpHeaders.update(.contentType("application/json"))
            }

            return urlRequest
        } catch {
            throw AFError.parameterEncodingFailed(reason: .jsonEncodingFailed(error: error))
        }
    }
}

open class URLEncodedFormParameterEncoder: ParameterEncoder {
    public enum Destination {
        case methodDependent, queryString, httpBody

        func encodesParamtersInURL(for method: HTTPMethod) -> Bool {
            switch self {
            case .methodDependent: return [.get, .head, .delete].contains(method)
            case .queryString: return true
            case .httpBody: return false
            }
        }
    }

    public static var `default`: URLEncodedFormParameterEncoder { return URLEncodedFormParameterEncoder() }

    let encoder: URLEncodedFormEncoder
    let destination: Destination

    public init(encoder: URLEncodedFormEncoder = URLEncodedFormEncoder(), destination: Destination = .methodDependent) {
        self.encoder = encoder
        self.destination = destination
    }

    open func encode<Parameters: Encodable>(_ parameters: Parameters?,
                                              into request: URLRequestConvertible) throws -> URLRequest {
        var urlRequest = try request.asURLRequest()

        guard let parameters = parameters else { return urlRequest }

        guard
            let url = urlRequest.url,
            let rawMethod = urlRequest.httpMethod,
            let method = HTTPMethod(rawValue: rawMethod) else {
            // TODO: Need new error.
            throw AFError.parameterEncodingFailed(reason: .missingURL)
        }

        if destination.encodesParamtersInURL(for: method), var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // TODO: Make this safer?
            let query: String = try encoder.encode(parameters)
            let newQueryString = [urlComponents.percentEncodedQuery, query].compactMap { $0 }.joinedWithAmpersands()
            urlComponents.percentEncodedQuery = newQueryString
            urlRequest.url = urlComponents.url
        } else {
            if urlRequest.httpHeaders["Content-Type"] == nil {
                urlRequest.httpHeaders.update(.contentType("application/x-www-form-urlencoded; charset=utf-8"))
            }

            urlRequest.httpBody = try encoder.encode(parameters)
        }

        return urlRequest
    }
}

public class URLEncodedFormEncoder {
    public enum BoolEncoding {
        case numeric
        case literal

        func encode(_ value: Bool) -> String {
            switch self {
            case .numeric: return value ? "1" : "0"
            case .literal: return value ? "true" : "false"
            }
        }
    }

    public enum ArrayEncoding {
        case brackets
        case noBrackets

        func encode(_ key: String) -> String {
            switch self {
            case .brackets: return "\(key)[]"
            case .noBrackets: return key
            }
        }
    }

    enum Error: Swift.Error {
        case invalidRootObject
    }

    private let arrayEncoding: ArrayEncoding
    private let boolEncoding: BoolEncoding

    public init(arrayEncoding: ArrayEncoding = .brackets, boolEncoding: BoolEncoding = .numeric) {
        self.arrayEncoding = arrayEncoding
        self.boolEncoding = boolEncoding
    }

    func encode(_ value: Encodable) throws -> URLEncodedFormComponent {
        let context = URLEncodedFormContext(.object([:]))
        let encoder = _URLEncodedFormEncoder(context: context, boolEncoding: boolEncoding)
        try value.encode(to: encoder)

        return context.component
    }

    public func encode(_ value: Encodable) throws -> String {
        let component: URLEncodedFormComponent = try encode(value)
        guard case let .object(object) = component else {
            throw Error.invalidRootObject
        }
        let serializer = URLEncodedFormSerializer(arrayEncoding: arrayEncoding)

        return try serializer.serialize(object)
    }

    public func encode(_ value: Encodable) throws -> Data {
        let string: String = try encode(value)

        return Data(string.utf8)
    }
}

final class _URLEncodedFormEncoder {
    var codingPath: [CodingKey]
    // Return empty dictionary, as this encoder supports no userInfo.
    var userInfo: [CodingUserInfoKey : Any] { return [:] }

    let context: URLEncodedFormContext

    private let boolEncoding: URLEncodedFormEncoder.BoolEncoding

    public init(context: URLEncodedFormContext,
                codingPath: [CodingKey] = [],
                boolEncoding: URLEncodedFormEncoder.BoolEncoding) {
        self.context = context
        self.codingPath = codingPath
        self.boolEncoding = boolEncoding
    }
}

extension _URLEncodedFormEncoder: Encoder {
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
        let container = _URLEncodedFormEncoder.KeyedContainer<Key>(context: context,
                                                                   codingPath: codingPath,
                                                                   boolEncoding: boolEncoding)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _URLEncodedFormEncoder.UnkeyedContainer(context: context,
                                                       codingPath: codingPath,
                                                       boolEncoding: boolEncoding)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _URLEncodedFormEncoder.SingleValueContainer(context: context,
                                                           codingPath: codingPath,
                                                           boolEncoding: boolEncoding)
    }
}

final class URLEncodedFormContext {
    var component: URLEncodedFormComponent

    init(_ component: URLEncodedFormComponent) {
        self.component = component
    }
}

enum URLEncodedFormComponent {
    case string(String)
    case array([URLEncodedFormComponent])
    case object([String: URLEncodedFormComponent])

    /// Converts self to an `String` or returns `nil` if not convertible.
    var string: String? {
        switch self {
        case let .string(string): return string
        default: return nil
        }
    }

    /// Converts self to an `[URLEncodedFormData]` or returns `nil` if not convertible.
    var array: [URLEncodedFormComponent]? {
        switch self {
        case let .array(array): return array
        default: return nil
        }
    }

    /// Converts self to an `[String: URLEncodedFormData]` or returns `nil` if not convertible.
    var object: [String: URLEncodedFormComponent]? {
        switch self {
        case let .object(object): return object
        default: return nil
        }
    }

    /// Sets self to the supplied value at a given path.
    ///
    ///     data.set(to: "hello", at: ["path", "to", "value"])
    ///
    /// - parameters:
    ///     - value: Value of `Self` to set at the supplied path.
    ///     - path: `CodingKey` path to update with the supplied value.
    public mutating func set(to value: URLEncodedFormComponent, at path: [CodingKey]) {
        set(&self, to: value, at: path)
    }

    /// Sets self to the supplied value at a given path.
    ///
    ///     data.get(at: ["path", "to", "value"])
    ///
    /// - parameters:
    ///     - path: `CodingKey` path to fetch the supplied value at.
    /// - returns: An instance of `Self` if a value exists at the path, otherwise `nil`.
    public func get(at path: [CodingKey]) -> URLEncodedFormComponent? {
        var child = self

        for seg in path {
            if let object = child.object, let c = object[seg.stringValue] {
                child = c
            } else if let array = child.array, let index = seg.intValue {
                child = array[index]
            } else {
                return nil
            }
        }

        return child
    }

    /// Recursive backing method to `set(to:at:)`.
    private func set(_ context: inout URLEncodedFormComponent, to value: URLEncodedFormComponent, at path: [CodingKey]) {
        guard path.count >= 1 else {
            context = value
            return
        }

        let end = path[0]
        var child: URLEncodedFormComponent
        switch path.count {
        case 1:
            child = value
        case 2...:
            if let index = end.intValue {
                let array = context.array ?? []
                if array.count > index {
                    child = array[index]
                } else {
                    child = .array([])
                }
                set(&child, to: value, at: Array(path[1...]))
            } else {
                child = context.object?[end.stringValue] ?? .object([:])
                set(&child, to: value, at: Array(path[1...]))
            }
        default: fatalError("Unreachable")
        }

        if let index = end.intValue {
            if var array = context.array {
                if array.count > index {
                    array[index] = child
                } else {
                    array.append(child)
                }
                context = .array(array)
            } else {
                context = .array([child])
            }
        } else {
            if var object = context.object {
                object[end.stringValue] = child
                context = .object(object)
            } else {
                context = .object([end.stringValue: child])
            }
        }
    }
}

struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }

    init<Key>(_ base: Key) where Key : CodingKey {
        if let intValue = base.intValue {
            self.init(intValue: intValue)!
        } else {
            self.init(stringValue: base.stringValue)!
        }
    }
}

extension _URLEncodedFormEncoder {
    final class KeyedContainer<Key> where Key: CodingKey {
        var codingPath: [CodingKey]

        private let context: URLEncodedFormContext
        private let boolEncoding: URLEncodedFormEncoder.BoolEncoding

        init(context: URLEncodedFormContext,
             codingPath: [CodingKey],
             boolEncoding: URLEncodedFormEncoder.BoolEncoding) {
            self.context = context
            self.codingPath = codingPath
            self.boolEncoding = boolEncoding
        }

        private func nestedCodingPath(for key: CodingKey) -> [CodingKey] {
            return codingPath + [key]
        }
    }
}

extension _URLEncodedFormEncoder.KeyedContainer: KeyedEncodingContainerProtocol {
    func encodeNil(forKey key: Key) throws {
        let context = EncodingError.Context(codingPath: codingPath,
                                            debugDescription: "URLEncodedFormEncoder cannot encode nil values.")
        throw EncodingError.invalidValue("\(key): nil", context)
    }

    func encode<T>(_ value: T, forKey key: Key) throws where T : Encodable {
        var container = nestedSingleValueEncoder(for: key)
        try container.encode(value)
    }

    func nestedSingleValueEncoder(for key: Key) -> SingleValueEncodingContainer {
        let container = _URLEncodedFormEncoder.SingleValueContainer(context: context,
                                                                    codingPath: nestedCodingPath(for: key),
                                                                    boolEncoding: boolEncoding)

        return container
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let container = _URLEncodedFormEncoder.UnkeyedContainer(context: context,
                                                                codingPath: nestedCodingPath(for: key),
                                                                boolEncoding: boolEncoding)

        return container
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        let container = _URLEncodedFormEncoder.KeyedContainer<NestedKey>(context: context,
                                                                         codingPath: nestedCodingPath(for: key),
                                                                         boolEncoding: boolEncoding)

        return KeyedEncodingContainer(container)
    }

    func superEncoder() -> Encoder {
        return _URLEncodedFormEncoder(context: context, codingPath: codingPath, boolEncoding: boolEncoding)
    }

    func superEncoder(forKey key: Key) -> Encoder {
        return _URLEncodedFormEncoder(context: context, codingPath: nestedCodingPath(for: key), boolEncoding: boolEncoding)
    }
}

extension _URLEncodedFormEncoder {
    final class SingleValueContainer {
        var codingPath: [CodingKey]

        private var canEncodeNewValue = true

        private let context: URLEncodedFormContext
        private let boolEncoding: URLEncodedFormEncoder.BoolEncoding

        init(context: URLEncodedFormContext, codingPath: [CodingKey], boolEncoding: URLEncodedFormEncoder.BoolEncoding) {
            self.context = context
            self.codingPath = codingPath
            self.boolEncoding = boolEncoding
        }

        private func checkCanEncode(value: Any?) throws {
            guard canEncodeNewValue else {
                let context = EncodingError.Context(codingPath: codingPath,
                                                    debugDescription: "Attempt to encode value through single value container when previously value already encoded.")
                throw EncodingError.invalidValue(value as Any, context)
            }
        }
    }
}

extension _URLEncodedFormEncoder.SingleValueContainer: SingleValueEncodingContainer {
    func encodeNil() throws {
        try checkCanEncode(value: nil)
        defer { canEncodeNewValue = false }

        let context = EncodingError.Context(codingPath: codingPath,
                                            debugDescription: "URLEncodedFormEncoder cannot encode nil values.")
        throw EncodingError.invalidValue("nil", context)
    }

    func encode(_ value: Bool) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(boolEncoding.encode(value)), at: codingPath)
    }

    func encode(_ value: String) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(value), at: codingPath)
    }

    func encode(_ value: Double) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: Float) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: Int) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: Int8) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: Int16) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: Int32) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: Int64) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: UInt) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: UInt8) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: UInt16) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: UInt32) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode(_ value: UInt64) throws {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        context.component.set(to: .string(String(value)), at: codingPath)
    }

    func encode<T>(_ value: T) throws where T : Encodable {
        try checkCanEncode(value: value)
        defer { canEncodeNewValue = false }

        let encoder = _URLEncodedFormEncoder(context: context,
                                             codingPath: codingPath,
                                             boolEncoding: boolEncoding)
        try value.encode(to: encoder)
    }
}

extension _URLEncodedFormEncoder {
    final class UnkeyedContainer {
        var codingPath: [CodingKey]

        var count = 0
        var nestedCodingPath: [CodingKey] {
            return codingPath + [AnyCodingKey(intValue: count)!]
        }

        private let context: URLEncodedFormContext
        private let boolEncoding: URLEncodedFormEncoder.BoolEncoding

        init(context: URLEncodedFormContext,
             codingPath: [CodingKey],
             boolEncoding: URLEncodedFormEncoder.BoolEncoding) {
            self.context = context
            self.codingPath = codingPath
            self.boolEncoding = boolEncoding
        }
    }
}

extension _URLEncodedFormEncoder.UnkeyedContainer: UnkeyedEncodingContainer {
    func encodeNil() throws {
        let context = EncodingError.Context(codingPath: codingPath,
                                            debugDescription: "URLEncodedFormEncoder cannot encode nil values.")
        throw EncodingError.invalidValue("nil", context)
    }

    func encode<T>(_ value: T) throws where T : Encodable {
        var container = nestedSingleValueContainer()
        try container.encode(value)
    }

    func nestedSingleValueContainer() -> SingleValueEncodingContainer {
        defer { count += 1 }

        return _URLEncodedFormEncoder.SingleValueContainer(context: context,
                                                           codingPath: nestedCodingPath,
                                                           boolEncoding: boolEncoding)
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        defer { count += 1 }
        let container = _URLEncodedFormEncoder.KeyedContainer<NestedKey>(context: context,
                                                                         codingPath: nestedCodingPath,
                                                                         boolEncoding: boolEncoding)

        return KeyedEncodingContainer(container)
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        defer { count += 1 }

        return _URLEncodedFormEncoder.UnkeyedContainer(context: context,
                                                       codingPath: nestedCodingPath,
                                                       boolEncoding: boolEncoding)
    }

    func superEncoder() -> Encoder {
        defer { count += 1 }

        return _URLEncodedFormEncoder(context: context, codingPath: codingPath, boolEncoding: boolEncoding)
    }
}

final class URLEncodedFormSerializer {
    let arrayEncoding: URLEncodedFormEncoder.ArrayEncoding

    init(arrayEncoding: URLEncodedFormEncoder.ArrayEncoding) {
        self.arrayEncoding = arrayEncoding
    }

    func serialize(_ object: [String: URLEncodedFormComponent]) throws -> String {
        var output: [String] = []
        for (key, component) in object {
            let value = try serialize(component, forKey: key)
            output.append(value)
        }

        return output.joinedWithAmpersands()
    }

    func serialize(_ component: URLEncodedFormComponent, forKey key: String) throws -> String {
        switch component {
        case let .string(string): return "\(key.customURLQueryEscaped)=\(string.customURLQueryEscaped)"
        case let .array(array): return try serialize(array, forKey: key)
        case let .object(dictionary): return try serialize(dictionary, forKey: key)
        }
    }

    func serialize(_ object: [String: URLEncodedFormComponent], forKey key: String) throws -> String {
        let segments: [String] = try object.map { (subKey, value) in
            let keyPath = "[\(subKey)]"
            return try serialize(value, forKey: key + keyPath)
        }

        return segments.joinedWithAmpersands()
    }

    func serialize(_ array: [URLEncodedFormComponent], forKey key: String) throws -> String {
        let segments: [String] = try array.map { (component) in
            let keyPath = arrayEncoding.encode(key)
            return try serialize(component, forKey: keyPath)
        }

        return segments.joinedWithAmpersands()
    }
}

extension Array where Element == String {
    func joinedWithAmpersands() -> String {
        return joined(separator: "&")
    }
}

extension String {
    var customURLQueryEscaped: String {
        return addingPercentEncoding(withAllowedCharacters: .customURLQueryAllowed) ?? self
    }
}

extension CharacterSet {
    /// Creates a CharacterSet from RFC 3986 allowed characters.
    ///
    /// RFC 3986 states that the following characters are "reserved" characters.
    ///
    /// - General Delimiters: ":", "#", "[", "]", "@", "?", "/"
    /// - Sub-Delimiters: "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "="
    ///
    /// In RFC 3986 - Section 3.4, it states that the "?" and "/" characters should not be escaped to allow
    /// query strings to include a URL. Therefore, all "reserved" characters with the exception of "?" and "/"
    /// should be percent-escaped in the query string.
    static let customURLQueryAllowed: CharacterSet = {
        let generalDelimitersToEncode = ":#[]@" // does not include "?" or "/" due to RFC 3986 - Section 3.4
        let subDelimitersToEncode = "!$&'()*+,;="
        let encodableDelimiters = CharacterSet(charactersIn: "\(generalDelimitersToEncode)\(subDelimitersToEncode)")
        
        return CharacterSet.urlQueryAllowed.subtracting(encodableDelimiters)
    }()
}
