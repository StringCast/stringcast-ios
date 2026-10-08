#if canImport(SwiftUI) && canImport(Combine)
import Combine
import Foundation
import SwiftUI

/// Publishes whenever StringCast updates so SwiftUI views re-render.
///
/// ```swift
/// struct Root: View {
///     @ObservedObject private var stringcast = StringCastStore.shared
///     var body: some View { Text(stringcast: "welcome_title") }
/// }
/// ```
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public final class StringCastStore: ObservableObject {
    public static let shared = StringCastStore()

    /// Increments on every update; read it (or any property) to depend on the store.
    @Published public private(set) var revision: Int = 0
    @Published public private(set) var language: String = StringCast.currentLanguage
    @Published public private(set) var version: Int = StringCast.currentVersion

    private var observation: StringCastObservation?

    public init() {
        observation = StringCast.addObserver { [weak self] in
            guard let self = self else { return }
            self.language = StringCast.currentLanguage
            self.version = StringCast.currentVersion
            self.revision += 1
        }
    }

    deinit { observation?.cancel() }

    public func string(_ key: String, default defaultValue: String? = nil, _ args: CVarArg...) -> String {
        StringCast.string(key, default: defaultValue, arguments: args)
    }

    public func pluralString(_ key: String, count: Int, default defaultValue: String? = nil) -> String {
        StringCast.pluralString(key, count: count, default: defaultValue)
    }

    public func setLanguage(_ code: String?) { StringCast.setLanguage(code) }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension Text {
    /// A `Text` with the StringCast value for `key`. Re-evaluated when the enclosing view's body
    /// runs — observe `StringCastStore.shared` in that view (or use `StringCastText`) to refresh on updates.
    init(stringcast key: String, default defaultValue: String? = nil, _ args: CVarArg...) {
        self.init(verbatim: StringCast.string(key, default: defaultValue, arguments: args))
    }

    /// Plural variant.
    init(stringcast key: String, count: Int, default defaultValue: String? = nil) {
        self.init(verbatim: StringCast.pluralString(key, count: count, default: defaultValue))
    }
}

/// Self-refreshing text view: observes `StringCastStore.shared` itself.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public struct StringCastText: View {
    @ObservedObject private var store = StringCastStore.shared
    private let key: String
    private let defaultValue: String?
    private let count: Int?
    private let args: [CVarArg]

    public init(_ key: String, default defaultValue: String? = nil, _ args: CVarArg...) {
        self.key = key
        self.defaultValue = defaultValue
        self.count = nil
        self.args = args
    }

    public init(_ key: String, count: Int, default defaultValue: String? = nil) {
        self.key = key
        self.defaultValue = defaultValue
        self.count = count
        self.args = []
    }

    public var body: some View {
        let _ = store.revision
        if let count = count {
            Text(verbatim: StringCast.pluralString(key, count: count, default: defaultValue))
        } else {
            Text(verbatim: StringCast.string(key, default: defaultValue, arguments: args))
        }
    }
}
#endif
