import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Minimal transport abstraction so the engine can be tested without network.
protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `URLSession.data(for:)` is iOS 15+; wrap the callback API for iOS 13.
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let http = response as? HTTPURLResponse {
                    continuation.resume(returning: (data ?? Data(), http))
                } else {
                    continuation.resume(throwing: StringCastError.invalidResponse)
                }
            }
            task.resume()
        }
    }
}

public enum StringCastError: Error, CustomStringConvertible {
    case invalidResponse
    case http(status: Int, body: String)
    case integrity(String)
    case notStarted
    case draftModeDisabled

    public var description: String {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(300))"
        case .integrity(let msg): return "Integrity check failed: \(msg)"
        case .notStarted: return "StringCast.start(...) has not been called"
        case .draftModeDisabled: return "Only available in draft mode"
        }
    }
}

struct MissingKeyPayload: Encodable {
    struct Entry: Encodable {
        var key: String
        var value: TranslationValue
        var comment: String?
    }
    var platform = "ios"
    var language: String
    var keys: [Entry]
}

public struct UploadResult: Decodable, Equatable {
    public var created: Int
    public var ignored: Int

    public init(created: Int, ignored: Int) {
        self.created = created
        self.ignored = ignored
    }
}

enum ManifestFetchResult {
    case notModified
    case updated(Manifest, etag: String?)
}

struct APIClient {
    let baseURL: URL
    let projectId: String
    let sdkKey: String
    let transport: HTTPTransport
    static let timeout: TimeInterval = 20

    /// `<base>/v1/sdk/<projectId>/<path>`; tolerates a base URL that already ends in `/v1`.
    func sdkURL(_ path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/v1") { base += "/v1" }
        let pid = projectId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectId
        return URL(string: "\(base)/sdk/\(pid)/\(path)") ?? baseURL
    }

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        r.httpMethod = method
        r.setValue(sdkKey, forHTTPHeaderField: "X-Api-Key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    func fetchManifest(etag: String?) async throws -> ManifestFetchResult {
        var r = request(sdkURL("manifest"))
        if let etag = etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await transport.send(r)
        if response.statusCode == 304 { return .notModified }
        guard (200..<300).contains(response.statusCode) else {
            throw StringCastError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let newEtag = response.value(forHTTPHeaderField: "ETag") ?? "\"v\(manifest.version)\""
        return .updated(manifest, etag: newEtag)
    }

    /// Downloads and verifies one bundle. Returns decoded bundle + raw bytes for caching.
    func fetchBundle(_ entry: Manifest.Language, expectedVersion: Int) async throws -> (TranslationBundle, Data) {
        guard let url = URL(string: entry.url, relativeTo: baseURL)?.absoluteURL else {
            throw StringCastError.integrity("bad bundle url \(entry.url)")
        }
        // Bundle URLs need no key (CDN); sending it is harmless for the local backend
        // but avoid leaking it to third-party hosts.
        var r = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: Self.timeout)
        if url.host == baseURL.host { r.setValue(sdkKey, forHTTPHeaderField: "X-Api-Key") }
        let (data, response) = try await transport.send(r)
        guard (200..<300).contains(response.statusCode) else {
            throw StringCastError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        if let hash = entry.hash, !Self.verify(data: data, hash: hash) {
            throw StringCastError.integrity("hash mismatch for \(entry.code)")
        }
        let bundle = try JSONDecoder().decode(TranslationBundle.self, from: data)
        guard LanguageResolver.normalize(bundle.language) == LanguageResolver.normalize(entry.code) else {
            throw StringCastError.integrity("bundle language \(bundle.language) != \(entry.code)")
        }
        guard bundle.version == expectedVersion else {
            throw StringCastError.integrity("bundle version \(bundle.version) != \(expectedVersion)")
        }
        return (bundle, data)
    }

    func reportMissing(_ payload: MissingKeyPayload) async throws -> UploadResult {
        var r = request(sdkURL("missing"), method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await transport.send(r)
        guard (200..<300).contains(response.statusCode) else {
            throw StringCastError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return (try? JSONDecoder().decode(UploadResult.self, from: data)) ?? UploadResult(created: 0, ignored: 0)
    }

    /// Verifies `sha256-<digest>` where digest is hex or (SRI-style) base64 of the raw bytes.
    /// Unknown hash formats are accepted (cannot verify) rather than blocking updates.
    static func verify(data: Data, hash: String) -> Bool {
        guard hash.lowercased().hasPrefix("sha256-") else { return true }
        let expected = String(hash.dropFirst("sha256-".count))
        guard !expected.isEmpty else { return true }
        #if canImport(CryptoKit)
        if #available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *) {
            let digest = Data(SHA256.hash(data: data))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if expected.lowercased() == hex { return true }
            let b64 = digest.base64EncodedString()
            if expected == b64 { return true }
            let b64url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            if expected.replacingOccurrences(of: "=", with: "") == b64url { return true }
            return false
        }
        #endif
        return true
    }
}
