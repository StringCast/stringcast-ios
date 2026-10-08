import Foundation

/// Placeholder normalisation (contract §2) and crash-safe `String(format:)`.
public enum PlaceholderFormatter {
    /// Converts `%s` → `%@` and `%1$s` → `%1$@` (also with flags/width, e.g. `%-10s`).
    /// `%%s` (an escaped percent followed by `s`) is left untouched.
    public static func normalize(_ input: String) -> String {
        guard input.contains("%") else { return input }
        var out = ""
        out.reserveCapacity(input.utf16.count)
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "%" else { out.append(c); i += 1; continue }
            if i + 1 < chars.count, chars[i + 1] == "%" {
                out.append("%%"); i += 2; continue
            }
            // Parse the specifier body without conversion char.
            var j = i + 1
            while j < chars.count, isSpecBody(chars[j]) { j += 1 }
            if j < chars.count, chars[j] == "s" {
                out.append(contentsOf: String(chars[i..<j]))
                out.append("@")
            } else if j < chars.count {
                out.append(contentsOf: String(chars[i...j]))
            } else {
                out.append(contentsOf: String(chars[i..<j]))
            }
            i = j + 1
        }
        return out
    }

    private static func isSpecBody(_ c: Character) -> Bool {
        if c.isASCII, c.isNumber { return true }
        return "$-+ #'.".contains(c)
    }

    // MARK: - Specifier parsing

    enum ArgKind: Equatable { case object, integer, float, number, cString, pointer, unknown }

    struct Specifier: Equatable {
        var position: Int? // explicit 1-based position
        var kind: ArgKind
        var starArgs: Int  // `*` width/precision args consumed (sequential only)
    }

    /// Parses printf-style specifiers (skips `%%`). Returns nil if a specifier is malformed.
    static func specifiers(in format: String) -> [Specifier]? {
        let chars = Array(format)
        var result: [Specifier] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "%" else { i += 1; continue }
            i += 1
            guard i < chars.count else { return nil }
            if chars[i] == "%" { i += 1; continue }
            var position: Int?
            // positional `n$`
            var k = i
            var digits = ""
            while k < chars.count, chars[k].isASCII, chars[k].isNumber { digits.append(chars[k]); k += 1 }
            if !digits.isEmpty, k < chars.count, chars[k] == "$" {
                position = Int(digits)
                i = k + 1
            }
            var stars = 0
            // flags
            var hasHash = false
            while i < chars.count, "-+ #0'".contains(chars[i]) { if chars[i] == "#" { hasHash = true }; i += 1 }
            // width
            if i < chars.count, chars[i] == "*" { stars += 1; i += 1 }
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            // precision
            if i < chars.count, chars[i] == "." {
                i += 1
                if i < chars.count, chars[i] == "*" { stars += 1; i += 1 }
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1 }
            }
            // length
            while i < chars.count, "hlqLzjt".contains(chars[i]) { i += 1 }
            guard i < chars.count else { return nil }
            let conv = chars[i]
            i += 1
            // stringsdict variable reference `%#@name@` consumes one numeric argument.
            if conv == "@", hasHash, let close = chars[i...].firstIndex(of: "@") {
                i = close + 1
                result.append(Specifier(position: position, kind: .number, starArgs: stars))
                continue
            }
            let kind: ArgKind
            switch conv {
            case "@": kind = .object
            case "d", "i", "o", "u", "x", "X", "c", "C", "D", "O", "U": kind = .integer
            case "f", "F", "e", "E", "g", "G", "a", "A": kind = .float
            case "s", "S": kind = .cString
            case "p": kind = .pointer
            default: kind = .unknown
            }
            result.append(Specifier(position: position, kind: kind, starArgs: stars))
        }
        return result
    }

    /// Checks that `args` satisfy every specifier in `format` (count and type), so that
    /// `String(format:)` cannot read garbage or dereference a non-object.
    static func validate(_ format: String, args: [CVarArg]) -> Bool {
        guard let specs = specifiers(in: format) else { return false }
        if specs.isEmpty { return true }
        var sequential = 0
        var required: [Int: ArgKind] = [:]
        for s in specs {
            if let p = s.position {
                guard p >= 1 else { return false }
                if let existing = required[p - 1], existing != s.kind { return false }
                required[p - 1] = s.kind
            } else {
                for _ in 0..<s.starArgs { required[sequential] = .integer; sequential += 1 }
                if let existing = required[sequential], existing != s.kind { return false }
                required[sequential] = s.kind
                sequential += 1
            }
        }
        for (index, kind) in required {
            guard index < args.count else { return false }
            guard isCompatible(args[index], with: kind) else { return false }
        }
        return true
    }

    static func isCompatible(_ arg: CVarArg, with kind: ArgKind) -> Bool {
        switch kind {
        case .object:
            return arg is String || type(of: arg) is AnyClass
        case .integer:
            return arg is any BinaryInteger
        case .float:
            return arg is any BinaryFloatingPoint
        case .number:
            return arg is any BinaryInteger || arg is any BinaryFloatingPoint
        case .pointer:
            return true
        case .cString, .unknown:
            // `%s` is normalised away; C strings from Swift are too risky to pass blindly.
            return false
        }
    }

    /// Normalises and formats. Returns nil when the template does not match the arguments
    /// (the caller then tries the next fallback source). With no args the normalised template
    /// is returned unformatted (like `NSLocalizedString`).
    public static func format(_ template: String, args: [CVarArg], locale: Locale? = nil) -> String? {
        let normalized = normalize(template)
        if args.isEmpty { return normalized }
        guard validate(normalized, args: args) else { return nil }
        return String(format: normalized, locale: locale, arguments: args)
    }
}
