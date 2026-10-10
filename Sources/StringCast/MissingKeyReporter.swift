import Foundation

/// Draft mode (§6.6): collects keys used at runtime that the base bundle lacks and POSTs them
/// to `/missing`, debounced and in batches of at most 500.
final class MissingKeyReporter {
    struct Context {
        var language: String
        var isInBase: (String) -> Bool
    }

    static let maxBatch = 500

    private let api: APIClient
    private let debounce: TimeInterval
    private let context: () -> Context?
    private let excludedKeys: Set<String>
    private let queue = DispatchQueue(label: "app.stringcast.missing-keys")
    private let lock = NSLock()
    private var pending: [String: TranslationValue] = [:]
    private var seen = Set<String>()
    private var scheduled = false

    init(api: APIClient, debounce: TimeInterval, excludedKeys: Set<String> = [], context: @escaping () -> Context?) {
        self.api = api
        self.excludedKeys = excludedKeys
        self.debounce = debounce
        self.context = context
    }

    func alreadySeen(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.contains(key)
    }

    func record(_ key: String, value: TranslationValue) {
        guard !excludedKeys.contains(key) else { return }
        lock.lock()
        guard !seen.contains(key) else { lock.unlock(); return }
        seen.insert(key)
        pending[key] = value
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { schedule() }
    }

    private func schedule() {
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.flush() }
    }

    /// Pending keys (for tests).
    var pendingKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return pending.keys.sorted()
    }

    func flush() {
        guard let ctx = context() else {
            // Base bundle not known yet; try again later.
            lock.lock()
            let hasPending = !pending.isEmpty
            scheduled = hasPending
            lock.unlock()
            if hasPending { schedule() }
            return
        }
        lock.lock()
        let batch = pending.filter { !ctx.isInBase($0.key) }
        pending.removeAll()
        scheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }

        let keys = batch.keys.sorted()
        var chunks: [[String]] = []
        var i = 0
        while i < keys.count {
            chunks.append(Array(keys[i..<min(i + Self.maxBatch, keys.count)]))
            i += Self.maxBatch
        }
        let api = self.api
        Task {
            for chunk in chunks {
                let payload = MissingKeyPayload(language: ctx.language, keys: chunk.map { .init(key: $0, value: batch[$0]!) })
                do {
                    let r = try await api.reportMissing(payload)
                    Log.debug("reported \(chunk.count) missing keys (created \(r.created), filled \(r.filled), ignored \(r.ignored))")
                } catch {
                    Log.debug("missing-key report failed: \(error)")
                    // Allow these keys to be reported again on next use.
                    self.lock.locked { chunk.forEach { self.seen.remove($0) } }
                }
            }
        }
    }
}
