#if canImport(SwiftUI) && canImport(Combine)
import Combine
import Foundation
import SwiftUI

/// Publishes whenever Polyglot updates so SwiftUI views re-render.
///
/// ```swift
/// struct Root: View {
///     @ObservedObject private var polyglot = PolyglotStore.shared
///     var body: some View { Text(polyglot: "welcome_title") }
/// }
/// ```
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public final class PolyglotStore: ObservableObject {
    public static let shared = PolyglotStore()

    /// Increments on every update; read it (or any property) to depend on the store.
    @Published public private(set) var revision: Int = 0
    @Published public private(set) var language: String = Polyglot.currentLanguage
    @Published public private(set) var version: Int = Polyglot.currentVersion

    private var observation: PolyglotObservation?

    public init() {
        observation = Polyglot.addObserver { [weak self] in
            guard let self = self else { return }
            self.language = Polyglot.currentLanguage
            self.version = Polyglot.currentVersion
            self.revision += 1
        }
    }

    deinit { observation?.cancel() }

    public func string(_ key: String, default defaultValue: String? = nil, _ args: CVarArg...) -> String {
        Polyglot.string(key, default: defaultValue, arguments: args)
    }

    public func pluralString(_ key: String, count: Int, default defaultValue: String? = nil) -> String {
        Polyglot.pluralString(key, count: count, default: defaultValue)
    }

    public func setLanguage(_ code: String?) { Polyglot.setLanguage(code) }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public extension Text {
    /// A `Text` with the Polyglot value for `key`. Re-evaluated when the enclosing view's body
    /// runs — observe `PolyglotStore.shared` in that view (or use `PolyglotText`) to refresh on updates.
    init(polyglot key: String, default defaultValue: String? = nil, _ args: CVarArg...) {
        self.init(verbatim: Polyglot.string(key, default: defaultValue, arguments: args))
    }

    /// Plural variant.
    init(polyglot key: String, count: Int, default defaultValue: String? = nil) {
        self.init(verbatim: Polyglot.pluralString(key, count: count, default: defaultValue))
    }
}

/// Self-refreshing text view: observes `PolyglotStore.shared` itself.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public struct PolyglotText: View {
    @ObservedObject private var store = PolyglotStore.shared
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
            Text(verbatim: Polyglot.pluralString(key, count: count, default: defaultValue))
        } else {
            Text(verbatim: Polyglot.string(key, default: defaultValue, arguments: args))
        }
    }
}
#endif
