import Foundation

/// Finds the "app-owned" bundles: the app bundle itself plus every bundle stored inside it
/// (Swift-package resource bundles `<Package>_<Target>.bundle`, embedded `Frameworks/*.framework`,
/// and `X.framework/Y.bundle`). System bundles (UIKit, Foundation, …) are never included.
enum AppBundles {
    /// Bundle names that belong to StringCast itself (never scanned).
    static let ownBundleNames: Set<String> = ["StringCast_StringCast.bundle", "StringCast.framework"]

    /// Comparable form of a path: symlinks resolved (`/private/var` ≡ `/var`), standardized, no trailing `/`.
    static func canonicalPath(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// True when `path` is `root` or lies inside it. Both must be canonical.
    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// `root` first, then every bundle inside it sorted by folder name (case-insensitive), deduplicated
    /// by canonical path.
    ///
    /// - Parameters:
    ///   - root: the app bundle (`Bundle.main` in apps; a fixture directory in tests).
    ///   - loaded: bundles already loaded by the process (`Bundle.allFrameworks + Bundle.allBundles`);
    ///     only those located inside `root` are kept.
    static func discover(root: Bundle, loaded: [Bundle] = Bundle.allFrameworks + Bundle.allBundles) -> [Bundle] {
        let rootPath = canonicalPath(root.bundlePath)
        var seen: Set<String> = [rootPath]
        var others: [(name: String, bundle: Bundle)] = []

        func add(_ bundle: Bundle) {
            let path = canonicalPath(bundle.bundlePath)
            let name = (path as NSString).lastPathComponent
            guard isInside(path, root: rootPath), !ownBundleNames.contains(name), seen.insert(path).inserted else { return }
            others.append((name, bundle))
        }
        func add(url: URL) {
            if let b = Bundle(url: url) { add(b) }
        }

        for b in loaded { add(b) }
        for url in candidateURLs(in: root) { add(url: url) }

        others.sort {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
        return [root] + others.map(\.bundle)
    }

    /// `*.bundle` / `*.framework` directories at the top level of `root` (bundle and resource folder),
    /// in its `Frameworks/` folder, and one level inside each framework (`X.framework/Y.bundle`).
    static func candidateURLs(in root: Bundle) -> [URL] {
        let fm = FileManager.default
        var containers: [URL] = [root.bundleURL]
        if let r = root.resourceURL { containers.append(r) }
        if let f = root.privateFrameworksURL { containers.append(f) }
        containers.append(root.bundleURL.appendingPathComponent("Frameworks", isDirectory: true))

        var found: [URL] = []
        var seen = Set<String>()
        func list(_ dir: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return items.filter {
                let ext = $0.pathExtension.lowercased()
                guard ext == "bundle" || ext == "framework" else { return false }
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            }
        }
        for container in containers where seen.insert(canonicalPath(container.path)).inserted {
            for url in list(container) {
                found.append(url)
                guard url.pathExtension.lowercased() == "framework" else { continue }
                // One level of nesting: X.framework/Y.bundle (and macOS-style X.framework/Resources/Y.bundle).
                var inner: [URL] = [url]
                if let fb = Bundle(url: url), let r = fb.resourceURL { inner.append(r) }
                var innerSeen = Set<String>()
                for dir in inner where innerSeen.insert(canonicalPath(dir.path)).inserted {
                    found.append(contentsOf: list(dir).filter { $0.pathExtension.lowercased() == "bundle" })
                }
            }
        }
        return found
    }
}
