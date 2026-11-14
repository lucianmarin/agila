//
// agila.swift — Pythonic Swift Bidirectional Transpiler (single-file Swift implementation)
//
// Agila is to Swift what Pura is to C/C++, Strata is to Rust, and LMON is to JSON:
//   - Strict, lossless 1-to-1 structural equivalence with Swift
//   - Pythonic indentation (`:` blocks instead of `{` `}`, no trailing `;` noise)
//   - Pythonic declarations (`def fn(a: i32) -> i32:`, `x: i32 = 10` (`let`), `var x: i32 = 10`)
//   - Pythonic keywords & operators (`elif`, `and`, `or`, `not`, `True`, `False`, `nil` / `None`, `pass`)
//   - Pythonic references & pointers (`ref[T]` ↔ `inout T`, `addr[T]` ↔ `UnsafePointer<T>`,
//     `addr[mut T]` ↔ `UnsafeMutablePointer<T>`, `var.ref` / `var.addr` ↔ `&var`, `val(p)` ↔ `p.pointee`)
//   - Pythonic type casts (`cast(Type, x)` ↔ `(x as! Type)`, `u8(x)` / `i32(x)` / `f64(x)` ↔ `UInt8(x)` / `Int32(x)` / `Double(x)`)
//   - Pythonic f-strings (`f"Hello {name}"` ↔ `"Hello \(name)"`)
//   - Pythonic list, set, and dict comprehensions (`[x * x for x in range(8)]`, `{x for x in items}`, `{k: v for x in items}`)
//   - Concise fixed-width & container type aliases (`i8`..`i64`, `u8`..`u64`, `f32`, `f64`, `usize`, `isize`,
//     `str`, `any`, `list[T]`, `set[T]`, `dict[K, V]`)
//   - Auto-detected indentation (any consistent spaces or tabs) & universal newlines (\n, \r\n, \r)
//
// Build & CLI usage:
//   swiftc -O agila.swift -o agila
//   ./agila examples/hello.agila
//   ./agila --agila [--indent <N|tab>] examples/hello.agila
//   ./agila --from-swift [--indent <N|tab>] examples/hello.swift
//   ./agila --compile examples/hello.agila -o hello
//   ./agila --run examples/hello.agila
//   ./agila --check examples/hello.agila
//   ./agila --test
//   ./agila --bench [file.agila]
//

import Foundation

public struct AgilaError: Error {
    public let message: String
    public let line: Int
    public let col: Int

    public init(_ message: String, line: Int, col: Int = 1) {
        self.message = message
        self.line = line
        self.col = col
    }
}

// -------------------------------------------------------------------------
// Character & Token Helpers
// -------------------------------------------------------------------------

@inline(__always)
private func isIdentStart(_ b: UInt8) -> Bool {
    return (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b == 0x5F
}

@inline(__always)
private func isIdentCont(_ b: UInt8) -> Bool {
    return isIdentStart(b) || (b >= 0x30 && b <= 0x39)
}

private let TYPE_MAP: [(agila: String, swift: String)] = [
    ("i8",    "Int8"),
    ("i16",   "Int16"),
    ("i32",   "Int32"),
    ("i64",   "Int64"),
    ("isize", "Int"),
    ("u8",    "UInt8"),
    ("u16",   "UInt16"),
    ("u32",   "UInt32"),
    ("u64",   "UInt64"),
    ("usize", "UInt"),
    ("byte",  "UInt8"),
    ("f32",   "Float"),
    ("f64",   "Double"),
    ("bool",  "Bool"),
    ("str",   "String"),
    ("cstr",  "StaticString"),
    ("any",   "Any")
]

private func mapAgilaWordToSwift(_ w: String) -> String? {
    for pair in TYPE_MAP {
        if pair.agila == w { return pair.swift }
    }
    switch w {
    case "and":   return "&&"
    case "or":    return "||"
    case "not":   return "!"
    case "None":  return "nil"
    case "True":  return "true"
    case "False": return "false"
    default:      return nil
    }
}

private func mapSwiftWordToAgila(_ w: String) -> String? {
    for pair in TYPE_MAP {
        if pair.agila == "byte" { continue } // prefer u8 for UInt8
        if pair.swift == w { return pair.agila }
    }
    return nil
}

private func isAgilaScalarTypeWord(_ w: String) -> Bool {
    for pair in TYPE_MAP {
        if pair.agila == w { return true }
    }
    return false
}

// Find matching closing delimiter at byte index `openIdx`
private func findMatchingDelim(_ bytes: [UInt8], openIdx: Int, openCh: UInt8, closeCh: UInt8) -> Int {
    var depth = 0
    var quote: UInt8 = 0
    var i = openIdx
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count {
                i += 2
                continue
            } else if c == quote {
                quote = 0
            }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 {
            quote = c
        } else if c == openCh {
            depth += 1
        } else if c == closeCh {
            depth -= 1
            if depth == 0 { return i }
        }
        i += 1
    }
    return bytes.count
}

private func findTopLevelComma(_ s: String) -> String.Index? {
    let bytes = Array(s.utf8)
    var depth = 0
    var quote: UInt8 = 0
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 {
            quote = c
        } else if c == 0x28 || c == 0x5B || c == 0x7B || c == 0x3C {
            depth += 1
        } else if c == 0x29 || c == 0x5D || c == 0x7D || c == 0x3E {
            depth -= 1
        } else if c == 0x2C && depth == 0 {
            return String(decoding: bytes[0..<i], as: UTF8.self).endIndex
        }
        i += 1
    }
    return nil
}

private func trimASCII(_ s: String) -> String {
    let bytes = Array(s.utf8)
    var start = 0
    var end = bytes.count
    while start < end && (bytes[start] == 0x20 || bytes[start] == 0x09) { start += 1 }
    while end > start && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09) { end -= 1 }
    if start == 0 && end == bytes.count { return s }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

// -------------------------------------------------------------------------
// Type Translation (Agila <-> Swift)
// -------------------------------------------------------------------------

private func translateTypeAgilaToSwift(_ raw: String) -> String {
    let s = trimASCII(raw)
    if s.isEmpty { return "" }

    // Optional / force-unwrapped suffix `T?` or `T!`
    if s.hasSuffix("?") || s.hasSuffix("!") {
        let suffix = String(s.last!)
        let base = String(s.dropLast())
        return translateTypeAgilaToSwift(base) + suffix
    }

    let bytes = Array(s.utf8)

    // `ref[mut T]` or `ref[T]` -> `inout T`
    if s.hasPrefix("ref[") && findMatchingDelim(bytes, openIdx: 3, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        var inner = trimASCII(String(s.dropFirst(4).dropLast()))
        if inner.hasPrefix("mut ") {
            inner = trimASCII(String(inner.dropFirst(4)))
        }
        return "inout " + translateTypeAgilaToSwift(inner)
    }
    if s.hasPrefix("mut_ref[") && findMatchingDelim(bytes, openIdx: 7, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(8).dropLast()))
        return "inout " + translateTypeAgilaToSwift(inner)
    }

    // `addr[mut T]` -> `UnsafeMutablePointer<T>` and `addr[T]` -> `UnsafePointer<T>`
    if s.hasPrefix("addr[") && findMatchingDelim(bytes, openIdx: 4, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        var inner = trimASCII(String(s.dropFirst(5).dropLast()))
        if inner.hasPrefix("mut ") {
            inner = trimASCII(String(inner.dropFirst(4)))
            return "UnsafeMutablePointer<" + translateTypeAgilaToSwift(inner) + ">"
        }
        if inner.hasPrefix("const ") {
            inner = trimASCII(String(inner.dropFirst(6)))
        }
        return "UnsafePointer<" + translateTypeAgilaToSwift(inner) + ">"
    }

    // `list[T]` -> `[T]`
    if s.hasPrefix("list[") && findMatchingDelim(bytes, openIdx: 4, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(5).dropLast()))
        return "[" + translateTypeAgilaToSwift(inner) + "]"
    }

    // `set[T]` or `unordered_set[T]` -> `Set<T>`
    if s.hasPrefix("set[") && findMatchingDelim(bytes, openIdx: 3, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(4).dropLast()))
        return "Set<" + translateTypeAgilaToSwift(inner) + ">"
    }
    if s.hasPrefix("unordered_set[") && findMatchingDelim(bytes, openIdx: 13, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(14).dropLast()))
        return "Set<" + translateTypeAgilaToSwift(inner) + ">"
    }

    // `dict[K, V]` or `unordered_map[K, V]` -> `[K: V]`
    if s.hasPrefix("dict[") && findMatchingDelim(bytes, openIdx: 4, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = String(s.dropFirst(5).dropLast())
        if let comma = findTopLevelComma(inner) {
            let k = trimASCII(String(inner[..<comma]))
            let v = trimASCII(String(inner[inner.index(after: comma)...]))
            return "[" + translateTypeAgilaToSwift(k) + ": " + translateTypeAgilaToSwift(v) + "]"
        }
    }
    if s.hasPrefix("unordered_map[") && findMatchingDelim(bytes, openIdx: 13, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = String(s.dropFirst(14).dropLast())
        if let comma = findTopLevelComma(inner) {
            let k = trimASCII(String(inner[..<comma]))
            let v = trimASCII(String(inner[inner.index(after: comma)...]))
            return "[" + translateTypeAgilaToSwift(k) + ": " + translateTypeAgilaToSwift(v) + "]"
        }
    }

    // Postfix array syntax `T[N]` or `T[]` -> `[T]`
    if let bIdx = bytes.firstIndex(of: 0x5B), bIdx > 0,
       findMatchingDelim(bytes, openIdx: bIdx, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let base = String(decoding: bytes[0..<bIdx], as: UTF8.self)
        return "[" + translateTypeAgilaToSwift(base) + "]"
    }

    if let mapped = mapAgilaWordToSwift(s) {
        return mapped
    }
    return translateTokensAgilaToSwift(s)
}

private func translateTypeSwiftToAgila(_ raw: String) -> String {
    let s = trimASCII(raw)
    if s.isEmpty { return "" }

    if s.hasSuffix("?") || s.hasSuffix("!") {
        let suffix = String(s.last!)
        let base = String(s.dropLast())
        return translateTypeSwiftToAgila(base) + suffix
    }

    if s.hasPrefix("inout ") {
        let inner = trimASCII(String(s.dropFirst(6)))
        return "ref[" + translateTypeSwiftToAgila(inner) + "]"
    }

    let bytes = Array(s.utf8)

    if s.hasPrefix("UnsafeMutablePointer<") && findMatchingDelim(bytes, openIdx: 20, openCh: 0x3C, closeCh: 0x3E) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(21).dropLast()))
        return "addr[mut " + translateTypeSwiftToAgila(inner) + "]"
    }
    if s.hasPrefix("UnsafePointer<") && findMatchingDelim(bytes, openIdx: 13, openCh: 0x3C, closeCh: 0x3E) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(14).dropLast()))
        return "addr[" + translateTypeSwiftToAgila(inner) + "]"
    }
    if s.hasPrefix("Set<") && findMatchingDelim(bytes, openIdx: 3, openCh: 0x3C, closeCh: 0x3E) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(4).dropLast()))
        return "set[" + translateTypeSwiftToAgila(inner) + "]"
    }
    if s.hasPrefix("Array<") && findMatchingDelim(bytes, openIdx: 5, openCh: 0x3C, closeCh: 0x3E) == bytes.count - 1 {
        let inner = trimASCII(String(s.dropFirst(6).dropLast()))
        return "list[" + translateTypeSwiftToAgila(inner) + "]"
    }

    // Swift `[K: V]` or `[T]`
    if bytes.first == 0x5B && findMatchingDelim(bytes, openIdx: 0, openCh: 0x5B, closeCh: 0x5D) == bytes.count - 1 {
        let inner = String(s.dropFirst().dropLast())
        // Look for top-level `:` inside `[...]`
        let ib = Array(inner.utf8)
        var depth = 0
        var colonPos: Int? = nil
        for idx in 0..<ib.count {
            let c = ib[idx]
            if c == 0x5B || c == 0x3C || c == 0x28 { depth += 1 }
            else if c == 0x5D || c == 0x3E || c == 0x29 { depth -= 1 }
            else if c == 0x3A && depth == 0 {
                colonPos = idx
                break
            }
        }
        if let cp = colonPos {
            let k = trimASCII(String(decoding: ib[0..<cp], as: UTF8.self))
            let v = trimASCII(String(decoding: ib[(cp + 1)..<ib.count], as: UTF8.self))
            return "dict[" + translateTypeSwiftToAgila(k) + ", " + translateTypeSwiftToAgila(v) + "]"
        } else {
            return "list[" + translateTypeSwiftToAgila(inner) + "]"
        }
    }

    if let mapped = mapSwiftWordToAgila(s) {
        return mapped
    }
    return translateTokensSwiftToAgila(s)
}

// Convert Pythonic `f"Hello {name}!"` to Swift `"Hello \(name)!"`
private func convertFStringToSwift(_ contentBytes: [UInt8], quoteChar: UInt8 = 0x22) -> String {
    var out = "\""
    var i = 0
    while i < contentBytes.count {
        let c = contentBytes[i]
        if c == 0x5C && i + 1 < contentBytes.count {
            out.append(Character(UnicodeScalar(c)))
            out.append(Character(UnicodeScalar(contentBytes[i + 1])))
            i += 2
            continue
        }
        if quoteChar == 0x27 && c == 0x22 {
            out += "\\\""
            i += 1
            continue
        }
        if c == 0x7B { // '{'
            if i + 1 < contentBytes.count && contentBytes[i + 1] == 0x7B {
                out.append("{")
                i += 2
                continue
            }
            let closeIdx = findMatchingDelim(contentBytes, openIdx: i, openCh: 0x7B, closeCh: 0x7D)
            if closeIdx < contentBytes.count {
                let exprStr = String(decoding: contentBytes[(i + 1)..<closeIdx], as: UTF8.self)
                // Check optional `:spec` format specifier at top level
                let eb = Array(exprStr.utf8)
                var depth = 0
                var q: UInt8 = 0
                var colPos: Int? = nil
                var k = 0
                while k < eb.count {
                    let ch = eb[k]
                    if q != 0 {
                        if ch == 0x5C && k + 1 < eb.count { k += 2; continue }
                        if ch == q { q = 0 }
                    } else if ch == 0x22 || ch == 0x27 {
                        q = ch
                    } else if ch == 0x28 || ch == 0x5B || ch == 0x7B {
                        depth += 1
                    } else if ch == 0x29 || ch == 0x5D || ch == 0x7D {
                        depth -= 1
                    } else if ch == 0x3A && depth == 0 {
                        colPos = k
                        break
                    }
                    k += 1
                }
                if let cp = colPos {
                    let epart = trimASCII(String(decoding: eb[0..<cp], as: UTF8.self))
                    let spec = trimASCII(String(decoding: eb[(cp + 1)..<eb.count], as: UTF8.self))
                    out += "\\(String(format: \"%\(spec)\", " + translateTokensAgilaToSwift(epart) + "))"
                } else {
                    out += "\\(" + translateTokensAgilaToSwift(exprStr) + ")"
                }
                i = closeIdx + 1
                continue
            }
        }
        if c == 0x7D && i + 1 < contentBytes.count && contentBytes[i + 1] == 0x7D {
            out.append("}")
            i += 2
            continue
        }
        let start = i
        i += 1
        while i < contentBytes.count && contentBytes[i] != 0x5C && contentBytes[i] != 0x7B && contentBytes[i] != 0x7D && !(quoteChar == 0x27 && contentBytes[i] == 0x22) {
            i += 1
        }
        out += String(decoding: contentBytes[start..<i], as: UTF8.self)
    }
    out.append("\"")
    return out
}

// Convert Swift `"Hello \(name)!"` to Agila `f"Hello {name}!"` if it contains `\(`
private func convertSwiftStringToAgila(_ contentBytes: [UInt8]) -> String {
    var hasInterp = false
    var k = 0
    while k + 1 < contentBytes.count {
        if contentBytes[k] == 0x5C && contentBytes[k + 1] == 0x28 {
            hasInterp = true
            break
        }
        if contentBytes[k] == 0x5C { k += 2 } else { k += 1 }
    }
    if !hasInterp {
        return "\"" + String(decoding: contentBytes, as: UTF8.self) + "\""
    }
    var out = "f\""
    var i = 0
    while i < contentBytes.count {
        let c = contentBytes[i]
        if c == 0x5C && i + 1 < contentBytes.count && contentBytes[i + 1] == 0x28 {
            let closeIdx = findMatchingDelim(contentBytes, openIdx: i + 1, openCh: 0x28, closeCh: 0x29)
            if closeIdx < contentBytes.count {
                let exprStr = String(decoding: contentBytes[(i + 2)..<closeIdx], as: UTF8.self)
                out += "{" + translateTokensSwiftToAgila(exprStr) + "}"
                i = closeIdx + 1
                continue
            }
        }
        if c == 0x5C && i + 1 < contentBytes.count {
            out.append(Character(UnicodeScalar(c)))
            out.append(Character(UnicodeScalar(contentBytes[i + 1])))
            i += 2
            continue
        }
        let start = i
        i += 1
        while i < contentBytes.count && contentBytes[i] != 0x5C {
            i += 1
        }
        out += String(decoding: contentBytes[start..<i], as: UTF8.self)
    }
    out.append("\"")
    return out
}

// -------------------------------------------------------------------------
// Expression Token Translation (Agila -> Swift)
// -------------------------------------------------------------------------

private var agilaUsedInHelper = false
private var agilaUsedFloorDiv = false
private var agilaUsedPow = false

private func findTopLevelKwAgila(_ s: String, _ kw: String) -> Int? {
    let bytes = Array(s.utf8)
    let kb = Array(kw.utf8)
    if bytes.count < kb.count { return nil }
    var depth = 0
    var quote: UInt8 = 0
    var i = 0
    while i + kb.count <= bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 {
            quote = c
            i += 1
            continue
        }
        if c == 0x28 || c == 0x5B || c == 0x7B {
            depth += 1
        } else if c == 0x29 || c == 0x5D || c == 0x7D {
            if depth > 0 { depth -= 1 }
        } else if depth == 0 && Array(bytes[i..<(i + kb.count)]) == kb {
            let leftOk = (i == 0 || !isIdentCont(bytes[i - 1]))
            let rightOk = (i + kb.count == bytes.count || !isIdentCont(bytes[i + kb.count]))
            if leftOk && rightOk { return i }
        }
        i += 1
    }
    return nil
}

private func findTopLevelTokAgila(_ s: String, _ tok: String) -> Int? {
    let bytes = Array(s.utf8)
    let tb = Array(tok.utf8)
    if bytes.count < tb.count { return nil }
    var depth = 0
    var quote: UInt8 = 0
    var i = 0
    while i + tb.count <= bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 {
            quote = c
            i += 1
            continue
        }
        if c == 0x28 || c == 0x5B || c == 0x7B {
            depth += 1
        } else if c == 0x29 || c == 0x5D || c == 0x7D {
            if depth > 0 { depth -= 1 }
        } else if depth == 0 && Array(bytes[i..<(i + tb.count)]) == tb {
            return i
        }
        i += 1
    }
    return nil
}

private func hasTopLevelAssignOrSepAgila(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    var depth = 0
    var quote: UInt8 = 0
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 { quote = c; i += 1; continue }
        if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x7D { if depth > 0 { depth -= 1 } }
        else if depth == 0 {
            if c == 0x2C || c == 0x3B { return true }
            if c == 0x3D {
                if (i + 1 < bytes.count && (bytes[i + 1] == 0x3D || bytes[i + 1] == 0x3E)) ||
                   (i > 0 && [0x3D, 0x21, 0x3C, 0x3E, 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x26, 0x7C, 0x5E].contains(bytes[i - 1])) {
                    i += 1
                    continue
                }
                return true
            }
        }
        i += 1
    }
    return false
}

private func trySplitTernaryAgila(_ s: String) -> (String, String, String)? {
    guard let ifIdx = findTopLevelKwAgila(s, "if"), ifIdx > 0 else { return nil }
    let bytes = Array(s.utf8)
    let rest = String(decoding: bytes[(ifIdx + 2)..<bytes.count], as: UTF8.self)
    guard let elseRel = findTopLevelKwAgila(rest, "else"), elseRel > 0 else { return nil }
    let rb = Array(rest.utf8)
    let t = trimASCII(String(decoding: bytes[0..<ifIdx], as: UTF8.self))
    let c = trimASCII(String(decoding: rb[0..<elseRel], as: UTF8.self))
    let f = trimASCII(String(decoding: rb[(elseRel + 4)..<rb.count], as: UTF8.self))
    if t.isEmpty || c.isEmpty || f.isEmpty { return nil }
    return (t, c, f)
}

private func trySplitChainedCmpAgila(_ s: String) -> ([String], [String])? {
    let bytes = Array(s.utf8)
    var operands: [String] = []
    var ops: [String] = []
    var depth = 0
    var quote: UInt8 = 0
    var last = 0
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 { quote = c; i += 1; continue }
        if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x7D { if depth > 0 { depth -= 1 } }
        else if depth == 0 {
            if (c == 0x3C || c == 0x3E) && (i + 1 >= bytes.count || bytes[i + 1] != c) && (i == 0 || bytes[i - 1] != c) {
                if c == 0x3E && i > 0 && (bytes[i - 1] == 0x2D || bytes[i - 1] == 0x3D) {
                    i += 1; continue
                }
                if c == 0x3C && (i + 2 < bytes.count && bytes[i + 1] == 0x3C) {
                    i += 1; continue
                }
                let opLen = (i + 1 < bytes.count && bytes[i + 1] == 0x3D) ? 2 : 1
                operands.append(trimASCII(String(decoding: bytes[last..<i], as: UTF8.self)))
                ops.append(String(decoding: bytes[i..<(i + opLen)], as: UTF8.self))
                i += opLen
                last = i
                continue
            } else if (c == 0x3D || c == 0x21) && i + 1 < bytes.count && bytes[i + 1] == 0x3D {
                operands.append(trimASCII(String(decoding: bytes[last..<i], as: UTF8.self)))
                ops.append(String(decoding: bytes[i..<(i + 2)], as: UTF8.self))
                i += 2
                last = i
                continue
            }
        }
        i += 1
    }
    if ops.count < 2 { return nil }
    operands.append(trimASCII(String(decoding: bytes[last..<bytes.count], as: UTF8.self)))
    if operands.contains(where: { $0.isEmpty }) { return nil }
    return (operands, ops)
}

private func hasComparisonOpAgila(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    var depth = 0
    var quote: UInt8 = 0
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 { quote = c; i += 1; continue }
        if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x7D { if depth > 0 { depth -= 1 } }
        else if depth == 0 {
            if c == 0x3C || c == 0x3E {
                if !(c == 0x3E && i > 0 && (bytes[i - 1] == 0x2D || bytes[i - 1] == 0x3D)) {
                    return true
                }
            } else if (c == 0x3D || c == 0x21) && i + 1 < bytes.count && bytes[i + 1] == 0x3D {
                return true
            }
        }
        i += 1
    }
    return findTopLevelKwAgila(s, "in") != nil || findTopLevelKwAgila(s, "is") != nil
}

private func translateLambdaAgila(_ rest: String) -> (swiftCode: String, consumed: Int)? {
    let bytes = Array(rest.utf8)
    var idx = 0
    while idx < bytes.count && bytes[idx] == 0x20 { idx += 1 }
    var paramsStr = ""
    var retStr = ""
    var bodyColon: Int? = nil

    if idx < bytes.count && bytes[idx] == 0x28 {
        let rp = findMatchingDelim(bytes, openIdx: idx, openCh: 0x28, closeCh: 0x29)
        if rp >= bytes.count { return nil }
        paramsStr = String(decoding: bytes[(idx + 1)..<rp], as: UTF8.self)
        var after = rp + 1
        while after < bytes.count && bytes[after] == 0x20 { after += 1 }
        let afterStr = String(decoding: bytes[after..<bytes.count], as: UTF8.self)
        if afterStr.hasPrefix("->") {
            let tail = String(afterStr.dropFirst(2))
            guard let colRel = findTopLevelTokAgila(tail, ":") else { return nil }
            let tb = Array(tail.utf8)
            retStr = trimASCII(String(decoding: tb[0..<colRel], as: UTF8.self))
            bodyColon = after + 2 + colRel
        } else if after < bytes.count && bytes[after] == 0x3A {
            bodyColon = after
        } else {
            return nil
        }
    } else {
        var depth = 0
        var quote: UInt8 = 0
        var arrowIdx: Int? = nil
        var colons: [Int] = []
        var k = idx
        while k < bytes.count {
            let c = bytes[k]
            if quote != 0 {
                if c == 0x5C && k + 1 < bytes.count { k += 2; continue }
                if c == quote { quote = 0 }
                k += 1
                continue
            }
            if c == 0x22 || c == 0x27 { quote = c }
            else if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
            else if c == 0x29 || c == 0x5D || c == 0x7D {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0 {
                if c == 0x2D && k + 1 < bytes.count && bytes[k + 1] == 0x3E {
                    arrowIdx = k
                    break
                }
                if c == 0x3A { colons.append(k) }
            }
            k += 1
        }
        if let ai = arrowIdx {
            paramsStr = trimASCII(String(decoding: bytes[idx..<ai], as: UTF8.self))
            let tail = String(decoding: bytes[(ai + 2)..<bytes.count], as: UTF8.self)
            guard let colRel = findTopLevelTokAgila(tail, ":") else { return nil }
            let tb = Array(tail.utf8)
            retStr = trimASCII(String(decoding: tb[0..<colRel], as: UTF8.self))
            bodyColon = ai + 2 + colRel
        } else if let lc = colons.last {
            paramsStr = trimASCII(String(decoding: bytes[idx..<lc], as: UTF8.self))
            bodyColon = lc
        } else {
            return nil
        }
    }

    guard let bc = bodyColon else { return nil }
    let bodyStart = bc + 1
    var bodyEnd = bytes.count
    var depth = 0
    var quote: UInt8 = 0
    var k = bodyStart
    while k < bytes.count {
        let c = bytes[k]
        if quote != 0 {
            if c == 0x5C && k + 1 < bytes.count { k += 2; continue }
            if c == quote { quote = 0 }
            k += 1
            continue
        }
        if c == 0x22 || c == 0x27 { quote = c }
        else if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x7D {
            if depth == 0 { bodyEnd = k; break }
            depth -= 1
        } else if c == 0x2C && depth == 0 {
            bodyEnd = k
            break
        }
        k += 1
    }
    let body = trimASCII(String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self))
    if body.isEmpty { return nil }

    var swiftParams = ""
    let trimmedP = trimASCII(paramsStr)
    if !trimmedP.isEmpty {
        // Parse `a: T, b: U` or `a, b`
        var parts: [String] = []
        var segStart = 0
        var d = 0
        let pb = Array(trimmedP.utf8)
        for pIdx in 0...pb.count {
            if pIdx < pb.count {
                if pb[pIdx] == 0x28 || pb[pIdx] == 0x5B { d += 1 }
                else if pb[pIdx] == 0x29 || pb[pIdx] == 0x5D { d -= 1 }
            }
            if pIdx == pb.count || (pb[pIdx] == 0x2C && d == 0) {
                let p = trimASCII(String(decoding: pb[segStart..<pIdx], as: UTF8.self))
                if !p.isEmpty {
                    if let col = findTopLevelTokAgila(p, ":") {
                        let pbb = Array(p.utf8)
                        let pn = trimASCII(String(decoding: pbb[0..<col], as: UTF8.self))
                        let pt = trimASCII(String(decoding: pbb[(col + 1)..<pbb.count], as: UTF8.self))
                        parts.append("\(pn): \(translateTypeAgilaToSwift(pt))")
                    } else {
                        parts.append(p)
                    }
                }
                segStart = pIdx + 1
            }
        }
        swiftParams = parts.joined(separator: ", ")
    }

    let swBody = translateTokensAgilaToSwift(body)
    let swRet = retStr.isEmpty ? "" : " -> " + translateTypeAgilaToSwift(retStr)
    if swiftParams.isEmpty && swRet.isEmpty {
        return ("{ \(swBody) }", bodyEnd)
    }
    return ("{ (\(swiftParams))\(swRet) in \(swBody) }", bodyEnd)
}

private func translateTokensAgilaToSwift(_ s: String) -> String {
    let trimmed = trimASCII(s)
    if !hasTopLevelAssignOrSepAgila(trimmed) && findTopLevelKwAgila(trimmed, "lambda") == nil {
        if let (tE, cE, fE) = trySplitTernaryAgila(trimmed) {
            return "(" + translateTokensAgilaToSwift(cE) + " ? " + translateTokensAgilaToSwift(tE) + " : " + translateTokensAgilaToSwift(fE) + ")"
        }
        if let orIdx = findTopLevelKwAgila(trimmed, "or"), orIdx > 0 {
            let tb = Array(trimmed.utf8)
            let l = trimASCII(String(decoding: tb[0..<orIdx], as: UTF8.self))
            let r = trimASCII(String(decoding: tb[(orIdx + 2)..<tb.count], as: UTF8.self))
            return translateTokensAgilaToSwift(l) + " || " + translateTokensAgilaToSwift(r)
        }
        if let andIdx = findTopLevelKwAgila(trimmed, "and"), andIdx > 0 {
            let tb = Array(trimmed.utf8)
            let l = trimASCII(String(decoding: tb[0..<andIdx], as: UTF8.self))
            let r = trimASCII(String(decoding: tb[(andIdx + 3)..<tb.count], as: UTF8.self))
            return translateTokensAgilaToSwift(l) + " && " + translateTokensAgilaToSwift(r)
        }
        if let afterNot = startsWithKw(trimmed, "not"), !afterNot.isEmpty {
            if let inIdx = findTopLevelKwAgila(afterNot, "in"), inIdx > 0 {
                agilaUsedInHelper = true
                let ab = Array(afterNot.utf8)
                let k = trimASCII(String(decoding: ab[0..<inIdx], as: UTF8.self))
                let m = trimASCII(String(decoding: ab[(inIdx + 2)..<ab.count], as: UTF8.self))
                return "!_agilaIn(\(translateTokensAgilaToSwift(m)), \(translateTokensAgilaToSwift(k)))"
            }
            if hasComparisonOpAgila(afterNot) {
                return "!(\(translateTokensAgilaToSwift(afterNot)))"
            }
        }
        if let notIdx = findTopLevelKwAgila(trimmed, "not"), notIdx > 0 {
            let tb = Array(trimmed.utf8)
            let afterN = trimASCII(String(decoding: tb[(notIdx + 3)..<tb.count], as: UTF8.self))
            if let inAfter = startsWithKw(afterN, "in"), !inAfter.isEmpty {
                agilaUsedInHelper = true
                let k = trimASCII(String(decoding: tb[0..<notIdx], as: UTF8.self))
                return "!_agilaIn(\(translateTokensAgilaToSwift(inAfter)), \(translateTokensAgilaToSwift(k)))"
            }
        }
        if let inIdx = findTopLevelKwAgila(trimmed, "in"), inIdx > 0 {
            agilaUsedInHelper = true
            let tb = Array(trimmed.utf8)
            let k = trimASCII(String(decoding: tb[0..<inIdx], as: UTF8.self))
            let m = trimASCII(String(decoding: tb[(inIdx + 2)..<tb.count], as: UTF8.self))
            return "_agilaIn(\(translateTokensAgilaToSwift(m)), \(translateTokensAgilaToSwift(k)))"
        }
        if let isIdx = findTopLevelKwAgila(trimmed, "is"), isIdx > 0 {
            let tb = Array(trimmed.utf8)
            let l = trimASCII(String(decoding: tb[0..<isIdx], as: UTF8.self))
            let rhs = trimASCII(String(decoding: tb[(isIdx + 2)..<tb.count], as: UTF8.self))
            if let afterNot = startsWithKw(rhs, "not"), !afterNot.isEmpty {
                return translateTokensAgilaToSwift(l) + " != " + translateTokensAgilaToSwift(afterNot)
            }
            return translateTokensAgilaToSwift(l) + " == " + translateTokensAgilaToSwift(rhs)
        }
        if let (operands, ops) = trySplitChainedCmpAgila(trimmed) {
            var parts: [String] = []
            for k in 0..<ops.count {
                parts.append("(\(translateTokensAgilaToSwift(operands[k])) \(ops[k]) \(translateTokensAgilaToSwift(operands[k + 1])))")
            }
            return parts.joined(separator: " && ")
        }
        if let flIdx = findTopLevelTokAgila(trimmed, "//"), flIdx > 0 {
            agilaUsedFloorDiv = true
            let tb = Array(trimmed.utf8)
            let l = trimASCII(String(decoding: tb[0..<flIdx], as: UTF8.self))
            let r = trimASCII(String(decoding: tb[(flIdx + 2)..<tb.count], as: UTF8.self))
            return "_agilaFloorDiv(\(translateTokensAgilaToSwift(l)), \(translateTokensAgilaToSwift(r)))"
        }
        if let pwIdx = findTopLevelTokAgila(trimmed, "**"), pwIdx > 0 {
            agilaUsedPow = true
            let tb = Array(trimmed.utf8)
            let l = trimASCII(String(decoding: tb[0..<pwIdx], as: UTF8.self))
            let r = trimASCII(String(decoding: tb[(pwIdx + 2)..<tb.count], as: UTF8.self))
            return "_agilaPow(\(translateTokensAgilaToSwift(l)), \(translateTokensAgilaToSwift(r)))"
        }
    }

    let bytes = Array(s.utf8)
    let len = bytes.count
    var out = ""
    out.reserveCapacity(len + 16)

    var i = 0
    while i < len {
        let c = bytes[i]

        // Pythonic f-string `f"..."` or `f'...'`
        if c == 0x66 && i + 1 < len && (bytes[i + 1] == 0x22 || bytes[i + 1] == 0x27) && (i == 0 || !isIdentCont(bytes[i - 1])) {
            let q = bytes[i + 1]
            var endQ = i + 2
            while endQ < len {
                if bytes[endQ] == 0x5C && endQ + 1 < len {
                    endQ += 2
                    continue
                }
                if bytes[endQ] == q { break }
                endQ += 1
            }
            if endQ < len {
                out += convertFStringToSwift(Array(bytes[(i + 2)..<endQ]), quoteChar: q)
                i = endQ + 1
                continue
            }
        }

        // String or char literal
        if c == 0x22 || c == 0x27 {
            let quote = c
            let start = i
            i += 1
            while i < len {
                let sc = bytes[i]
                i += 1
                if sc == 0x5C && i < len {
                    i += 1
                } else if sc == quote {
                    break
                }
            }
            out += String(decoding: bytes[start..<i], as: UTF8.self)
            continue
        }

        if isIdentStart(c) {
            let start = i
            while i < len && isIdentCont(bytes[i]) { i += 1 }
            let word = String(decoding: bytes[start..<i], as: UTF8.self)
            let isMember = (start > 0 && bytes[start - 1] == 0x2E)

            if !isMember && word == "lambda" && i < len && (bytes[i] == 0x20 || bytes[i] == 0x28 || bytes[i] == 0x3A) {
                if let lam = translateLambdaAgila(String(decoding: bytes[i..<len], as: UTF8.self)) {
                    out += lam.swiftCode
                    i += lam.consumed
                    continue
                }
            }

            if !isMember && word == "isinstance" && i < len && bytes[i] == 0x28 {
                let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
                if closeP < len {
                    let argsStr = String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self)
                    if let comma = findTopLevelComma(argsStr) {
                        let valPart = trimASCII(String(argsStr[..<comma]))
                        let typePart = trimASCII(String(argsStr[argsStr.index(after: comma)...]))
                        out += "(" + translateTokensAgilaToSwift(valPart) + " is " + translateTypeAgilaToSwift(typePart) + ")"
                        i = closeP + 1
                        continue
                    }
                }
            }

            if !isMember && word == "reversed" && i < len && bytes[i] == 0x28 {
                let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
                if closeP < len {
                    let innerStr = trimASCII(String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self))
                    out += translateTokensAgilaToSwift(innerStr) + ".reversed()"
                    i = closeP + 1
                    continue
                }
            }

            if !isMember && word == "enumerate" && i < len && bytes[i] == 0x28 {
                let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
                if closeP < len {
                    let innerStr = trimASCII(String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self))
                    out += translateTokensAgilaToSwift(innerStr) + ".enumerated()"
                    i = closeP + 1
                    continue
                }
            }

            // Negative integer index `xs[-1]` -> `xs[xs.count - 1]` and slicing `xs[a:b]` -> `Array(xs[a..<b])`
            if !isMember && i < len && bytes[i] == 0x5B {
                let closeB = findMatchingDelim(bytes, openIdx: i, openCh: 0x5B, closeCh: 0x5D)
                if closeB < len {
                    let idxStr = trimASCII(String(decoding: bytes[(i + 1)..<closeB], as: UTF8.self))
                    if idxStr.hasPrefix("-") {
                        let restDigits = String(idxStr.dropFirst())
                        if !restDigits.isEmpty && restDigits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                            out += "\(word)[\(word).count - \(restDigits)]"
                            i = closeB + 1
                            continue
                        }
                    } else if let colPos = findTopLevelTokAgila(idxStr, ":") {
                        let ib = Array(idxStr.utf8)
                        let aPart = trimASCII(String(decoding: ib[0..<colPos], as: UTF8.self))
                        let bPart = trimASCII(String(decoding: ib[(colPos + 1)..<ib.count], as: UTF8.self))
                        if !aPart.isEmpty && !bPart.isEmpty && !bPart.contains(":") {
                            out += "Array(\(word)[\(translateTokensAgilaToSwift(aPart))..<\(translateTokensAgilaToSwift(bPart))])"
                            i = closeB + 1
                            continue
                        } else if !aPart.isEmpty && bPart.isEmpty {
                            out += "Array(\(word)[\(translateTokensAgilaToSwift(aPart))...])"
                            i = closeB + 1
                            continue
                        } else if aPart.isEmpty && !bPart.isEmpty && !bPart.contains(":") {
                            out += "Array(\(word)[..<\(translateTokensAgilaToSwift(bPart))])"
                            i = closeB + 1
                            continue
                        }
                    }
                }
            }

            // `addr[...]` or `list[...]` or `set[...]` or `dict[...]` inside expressions
            if !isMember && (word == "addr" || word == "list" || word == "set" || word == "unordered_set" || word == "dict" || word == "unordered_map") &&
                i < len && bytes[i] == 0x5B {
                let closeB = findMatchingDelim(bytes, openIdx: i, openCh: 0x5B, closeCh: 0x5D)
                if closeB < len {
                    let fullType = String(decoding: bytes[start...closeB], as: UTF8.self)
                    out += translateTypeAgilaToSwift(fullType)
                    i = closeB + 1
                    continue
                }
            }

            // `cast(Type, expr)` -> `(expr as! Type)`
            if !isMember && word == "cast" && i < len && bytes[i] == 0x28 {
                let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
                if closeP < len {
                    let argsStr = String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self)
                    if let comma = findTopLevelComma(argsStr) {
                        let typePart = trimASCII(String(argsStr[..<comma]))
                        let valPart = trimASCII(String(argsStr[argsStr.index(after: comma)...]))
                        out += "(" + translateTokensAgilaToSwift(valPart) + " as! " + translateTypeAgilaToSwift(typePart) + ")"
                        i = closeP + 1
                        continue
                    }
                }
            }

            // Scalar conversion `i32(x)`, `f64(x)`, `u8(x)`, `str(x)` -> `Int32(x)`, `Double(x)`, `UInt8(x)`, `String(x)`
            if !isMember && i < len && bytes[i] == 0x28 && isAgilaScalarTypeWord(word) {
                let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
                if closeP < len, let swiftType = mapAgilaWordToSwift(word) {
                    let innerStr = String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self)
                    out += swiftType + "(" + translateTokensAgilaToSwift(innerStr) + ")"
                    i = closeP + 1
                    continue
                }
            }

            // `val(ptr)` -> `ptr.pointee` and `val(2, ptr)` -> `ptr.pointee.pointee`
            if !isMember && word == "val" && i < len && bytes[i] == 0x28 {
                let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
                if closeP < len {
                    let innerStr = String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self)
                    var derefLevel = 1
                    var exprPart = trimASCII(innerStr)
                    if let comma = findTopLevelComma(innerStr) {
                        let lvlPart = trimASCII(String(innerStr[..<comma]))
                        let rhsPart = trimASCII(String(innerStr[innerStr.index(after: comma)...]))
                        if let parsed = Int(lvlPart), parsed >= 1 && parsed <= 16 {
                            derefLevel = parsed
                            exprPart = rhsPart
                        }
                    }
                    out += translateTokensAgilaToSwift(exprPart)
                    for _ in 0..<derefLevel {
                        out += ".pointee"
                    }
                    i = closeP + 1
                    continue
                }
            }

            // Check if primary/postfix chain starting at `start` ends with `.ref`, `.mut_ref`, or `.addr` -> `&expr`
            if !isMember {
                var scan = i
                var matchedSuffixLen = 0
                while scan < len {
                    if bytes[scan] == 0x5B { // '['
                        let cb = findMatchingDelim(bytes, openIdx: scan, openCh: 0x5B, closeCh: 0x5D)
                        if cb < len { scan = cb + 1 } else { break }
                    } else if scan + 4 <= len && String(decoding: bytes[scan..<(scan + 4)], as: UTF8.self) == ".ref" &&
                              (scan + 4 == len || !isIdentCont(bytes[scan + 4])) {
                        matchedSuffixLen = 4
                        break
                    } else if scan + 5 <= len && String(decoding: bytes[scan..<(scan + 5)], as: UTF8.self) == ".addr" &&
                              (scan + 5 == len || !isIdentCont(bytes[scan + 5])) {
                        matchedSuffixLen = 5
                        break
                    } else if scan + 8 <= len && String(decoding: bytes[scan..<(scan + 8)], as: UTF8.self) == ".mut_ref" &&
                              (scan + 8 == len || !isIdentCont(bytes[scan + 8])) {
                        matchedSuffixLen = 8
                        break
                    } else if bytes[scan] == 0x2E && scan + 1 < len && isIdentStart(bytes[scan + 1]) {
                        scan += 1
                        while scan < len && isIdentCont(bytes[scan]) { scan += 1 }
                    } else {
                        break
                    }
                }
                if matchedSuffixLen > 0 {
                    let baseExpr = String(decoding: bytes[start..<scan], as: UTF8.self)
                    out += "&" + translateTokensAgilaToSwift(baseExpr)
                    i = scan + matchedSuffixLen
                    continue
                }
            }

            if !isMember, let rep = mapAgilaWordToSwift(word) {
                if rep == "!" && i < len && bytes[i] == 0x20 {
                    out += "!"
                    i += 1 // consume space after `not ` so `not x` -> `!x`
                } else {
                    out += rep
                }
            } else {
                out += word
            }
            continue
        }

        // Copy chunk of non-identifier, non-quote characters
        out.append(Character(UnicodeScalar(c)))
        i += 1
    }

    return out
}

// -------------------------------------------------------------------------
// Expression Token Translation (Swift -> Agila)
// -------------------------------------------------------------------------

private func isSwiftUnaryPrefixPos(_ bytes: [UInt8], idx: Int) -> Bool {
    var k = idx
    while k > 0 && bytes[k - 1] == 0x20 { k -= 1 }
    if k == 0 { return true }
    let prev = bytes[k - 1]
    return prev == 0x28 || prev == 0x5B || prev == 0x2C || prev == 0x3D ||
           prev == 0x3A || prev == 0x3B || prev == 0x21 || prev == 0x3F ||
           prev == 0x2B || prev == 0x2D || prev == 0x2A || prev == 0x2F ||
           prev == 0x25 || prev == 0x26 || prev == 0x7C || prev == 0x5E ||
           prev == 0x3C || prev == 0x3E
}

private func scanSwiftPostfixOperand(_ bytes: [UInt8], start: Int) -> Int {
    var i = start
    let len = bytes.count
    if i < len && bytes[i] == 0x28 {
        let cp = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
        if cp < len { return cp + 1 }
    }
    while i < len {
        if isIdentCont(bytes[i]) || bytes[i] == 0x2E {
            i += 1
        } else if bytes[i] == 0x5B {
            let cb = findMatchingDelim(bytes, openIdx: i, openCh: 0x5B, closeCh: 0x5D)
            if cb < len { i = cb + 1 } else { break }
        } else {
            break
        }
    }
    return i
}

private func translateTokensSwiftToAgila(_ s: String) -> String {
    let bytes = Array(s.utf8)
    let len = bytes.count
    var out = ""
    out.reserveCapacity(len + 16)

    var i = 0
    while i < len {
        let c = bytes[i]

        // String literal (check for `\(...)` interpolation -> `f"...{...}..."`)
        if c == 0x22 {
            var endQ = i + 1
            while endQ < len {
                if bytes[endQ] == 0x5C && endQ + 1 < len {
                    endQ += 2
                    continue
                }
                if bytes[endQ] == 0x22 { break }
                endQ += 1
            }
            if endQ < len {
                out += convertSwiftStringToAgila(Array(bytes[(i + 1)..<endQ]))
                i = endQ + 1
                continue
            }
        }

        // Parenthesized `(expr as! Type)` or `(expr as Type)` -> `cast(Type, expr)`
        if c == 0x28 {
            let closeP = findMatchingDelim(bytes, openIdx: i, openCh: 0x28, closeCh: 0x29)
            if closeP < len {
                let inner = String(decoding: bytes[(i + 1)..<closeP], as: UTF8.self)
                // Look for top-level ` as! ` or ` as `
                let ib = Array(inner.utf8)
                var depth = 0
                var quote: UInt8 = 0
                var asPos: Int? = nil
                var asLen = 0
                var k = 0
                while k < ib.count {
                    let ch = ib[k]
                    if quote != 0 {
                        if ch == 0x5C && k + 1 < ib.count { k += 2; continue }
                        if ch == quote { quote = 0 }
                        k += 1
                        continue
                    }
                    if ch == 0x22 || ch == 0x27 { quote = ch }
                    else if ch == 0x28 || ch == 0x5B || ch == 0x7B { depth += 1 }
                    else if ch == 0x29 || ch == 0x5D || ch == 0x7D { depth -= 1 }
                    else if depth == 0 {
                        if k + 5 <= ib.count && String(decoding: ib[k..<(k + 5)], as: UTF8.self) == " as! " {
                            asPos = k
                            asLen = 5
                            break
                        } else if k + 4 <= ib.count && String(decoding: ib[k..<(k + 4)], as: UTF8.self) == " as " {
                            asPos = k
                            asLen = 4
                            break
                        }
                    }
                    k += 1
                }
                if let ap = asPos {
                    let exprPart = trimASCII(String(decoding: ib[0..<ap], as: UTF8.self))
                    let typePart = trimASCII(String(decoding: ib[(ap + asLen)..<ib.count], as: UTF8.self))
                    out += "cast(" + translateTypeSwiftToAgila(typePart) + ", " + translateTokensSwiftToAgila(exprPart) + ")"
                    i = closeP + 1
                    continue
                }
            }
        }

        // Logical `&&` -> `and`, `||` -> `or`, `!` -> `not `
        if c == 0x26 && i + 1 < len && bytes[i + 1] == 0x26 {
            if !out.isEmpty && !out.hasSuffix(" ") { out += " " }
            out += "and"
            i += 2
            if i < len && bytes[i] != 0x20 { out += " " }
            continue
        }
        if c == 0x7C && i + 1 < len && bytes[i + 1] == 0x7C {
            if !out.isEmpty && !out.hasSuffix(" ") { out += " " }
            out += "or"
            i += 2
            if i < len && bytes[i] != 0x20 { out += " " }
            continue
        }
        if c == 0x21 && (i + 1 >= len || bytes[i + 1] != 0x3D) && isSwiftUnaryPrefixPos(bytes, idx: i) {
            out += "not "
            i += 1
            continue
        }

        // Unary `&expr` -> `expr.ref`
        if c == 0x26 && i + 1 < len && bytes[i + 1] != 0x26 && bytes[i + 1] != 0x3D && bytes[i + 1] != 0x20 &&
           isSwiftUnaryPrefixPos(bytes, idx: i) {
            let opEnd = scanSwiftPostfixOperand(bytes, start: i + 1)
            if opEnd > i + 1 {
                let operand = String(decoding: bytes[(i + 1)..<opEnd], as: UTF8.self)
                out += translateTokensSwiftToAgila(operand) + ".ref"
                i = opEnd
                continue
            }
        }

        if isIdentStart(c) {
            let start = i
            while i < len && isIdentCont(bytes[i]) { i += 1 }
            let word = String(decoding: bytes[start..<i], as: UTF8.self)
            let isMember = (start > 0 && bytes[start - 1] == 0x2E)

            // Check if primary/postfix chain starting at `start` ends with `.pointee` (one or more times) -> `val(expr)` or `val(N, expr)`
            if !isMember {
                var scan = i
                var lastBeforePointee = i
                var pointeeCount = 0
                while scan < len {
                    if bytes[scan] == 0x5B {
                        let cb = findMatchingDelim(bytes, openIdx: scan, openCh: 0x5B, closeCh: 0x5D)
                        if cb < len && pointeeCount == 0 {
                            scan = cb + 1
                            lastBeforePointee = scan
                        } else {
                            break
                        }
                    } else if scan + 8 <= len && String(decoding: bytes[scan..<(scan + 8)], as: UTF8.self) == ".pointee" &&
                              (scan + 8 == len || !isIdentCont(bytes[scan + 8])) {
                        pointeeCount += 1
                        scan += 8
                    } else if pointeeCount == 0 && bytes[scan] == 0x2E && scan + 1 < len && isIdentStart(bytes[scan + 1]) {
                        scan += 1
                        while scan < len && isIdentCont(bytes[scan]) { scan += 1 }
                        lastBeforePointee = scan
                    } else {
                        break
                    }
                }
                if pointeeCount > 0 {
                    let baseExpr = String(decoding: bytes[start..<lastBeforePointee], as: UTF8.self)
                    if pointeeCount == 1 {
                        out += "val(" + translateTokensSwiftToAgila(baseExpr) + ")"
                    } else {
                        out += "val(\(pointeeCount), " + translateTokensSwiftToAgila(baseExpr) + ")"
                    }
                    i = scan
                    continue
                }
            }

            if !isMember, let rep = mapSwiftWordToAgila(word) {
                out += rep
            } else {
                out += word
            }
            continue
        }

        out.append(Character(UnicodeScalar(c)))
        i += 1
    }

    return out
}

// -------------------------------------------------------------------------
// Parameter Lists & Function Headers
// -------------------------------------------------------------------------

private func emitSwiftParamList(_ rawParams: String) -> String {
    let params = trimASCII(rawParams)
    if params.isEmpty || params == "void" { return "" }

    let bytes = Array(params.utf8)
    let len = bytes.count
    var outParts: [String] = []

    var i = 0
    while i < len {
        let pstart = i
        var depth = 0
        var quote: UInt8 = 0
        while i < len {
            let c = bytes[i]
            if quote != 0 {
                if c == 0x5C && i + 1 < len { i += 2; continue }
                if c == quote { quote = 0 }
            } else {
                if c == 0x22 || c == 0x27 { quote = c }
                else if c == 0x28 || c == 0x3C || c == 0x5B { depth += 1 }
                else if c == 0x29 || c == 0x3E || c == 0x5D { depth -= 1 }
                else if c == 0x2C && depth == 0 { break }
            }
            i += 1
        }
        let part = trimASCII(String(decoding: bytes[pstart..<i], as: UTF8.self))
        if i < len && bytes[i] == 0x2C { i += 1 }
        if part.isEmpty { continue }
        if part == "self" { continue } // Swift methods have implicit `self`

        // Find top-level `:` in parameter
        let pb = Array(part.utf8)
        var colonIdx: Int? = nil
        depth = 0
        quote = 0
        var k = 0
        while k < pb.count {
            let c = pb[k]
            if quote != 0 {
                if c == 0x5C && k + 1 < pb.count { k += 2; continue }
                if c == quote { quote = 0 }
            } else {
                if c == 0x22 || c == 0x27 { quote = c }
                else if c == 0x28 || c == 0x3C || c == 0x5B { depth += 1 }
                else if c == 0x29 || c == 0x3E || c == 0x5D { depth -= 1 }
                else if c == 0x3A && depth == 0 {
                    colonIdx = k
                    break
                }
            }
            k += 1
        }

        if let ci = colonIdx {
            let paramName = trimASCII(String(decoding: pb[0..<ci], as: UTF8.self))
            let rest = trimASCII(String(decoding: pb[(ci + 1)..<pb.count], as: UTF8.self))

            // Optional default `= val`
            let rb = Array(rest.utf8)
            var eqIdx: Int? = nil
            depth = 0
            quote = 0
            var m = 0
            while m < rb.count {
                let c = rb[m]
                if quote != 0 {
                    if c == 0x5C && m + 1 < rb.count { m += 2; continue }
                    if c == quote { quote = 0 }
                } else {
                    if c == 0x22 || c == 0x27 { quote = c }
                    else if c == 0x28 || c == 0x3C || c == 0x5B { depth += 1 }
                    else if c == 0x29 || c == 0x3E || c == 0x5D { depth -= 1 }
                    else if c == 0x3D && depth == 0 {
                        eqIdx = m
                        break
                    }
                }
                m += 1
            }

            let labelPrefix = paramName.contains(" ") ? paramName : ("_ " + paramName)
            if let ei = eqIdx {
                let typePart = trimASCII(String(decoding: rb[0..<ei], as: UTF8.self))
                let defPart = trimASCII(String(decoding: rb[(ei + 1)..<rb.count], as: UTF8.self))
                outParts.append("\(labelPrefix): \(translateTypeAgilaToSwift(typePart)) = \(translateTokensAgilaToSwift(defPart))")
            } else {
                outParts.append("\(labelPrefix): \(translateTypeAgilaToSwift(rest))")
            }
        } else {
            outParts.append(translateTokensAgilaToSwift(part))
        }
    }

    return outParts.joined(separator: ", ")
}

private func emitAgilaParamList(_ rawParams: String) -> String {
    let params = trimASCII(rawParams)
    if params.isEmpty { return "" }

    let bytes = Array(params.utf8)
    let len = bytes.count
    var outParts: [String] = []

    var i = 0
    while i < len {
        let pstart = i
        var depth = 0
        var quote: UInt8 = 0
        while i < len {
            let c = bytes[i]
            if quote != 0 {
                if c == 0x5C && i + 1 < len { i += 2; continue }
                if c == quote { quote = 0 }
            } else {
                if c == 0x22 || c == 0x27 { quote = c }
                else if c == 0x28 || c == 0x3C || c == 0x5B { depth += 1 }
                else if c == 0x29 || c == 0x3E || c == 0x5D { depth -= 1 }
                else if c == 0x2C && depth == 0 { break }
            }
            i += 1
        }
        let part = trimASCII(String(decoding: bytes[pstart..<i], as: UTF8.self))
        if i < len && bytes[i] == 0x2C { i += 1 }
        if part.isEmpty { continue }

        let pb = Array(part.utf8)
        var colonIdx: Int? = nil
        depth = 0
        quote = 0
        var k = 0
        while k < pb.count {
            let c = pb[k]
            if quote != 0 {
                if c == 0x5C && k + 1 < pb.count { k += 2; continue }
                if c == quote { quote = 0 }
            } else {
                if c == 0x22 || c == 0x27 { quote = c }
                else if c == 0x28 || c == 0x3C || c == 0x5B { depth += 1 }
                else if c == 0x29 || c == 0x3E || c == 0x5D { depth -= 1 }
                else if c == 0x3A && depth == 0 {
                    colonIdx = k
                    break
                }
            }
            k += 1
        }

        if let ci = colonIdx {
            var paramName = trimASCII(String(decoding: pb[0..<ci], as: UTF8.self))
            if paramName.hasPrefix("_ ") {
                paramName = trimASCII(String(paramName.dropFirst(2)))
            }
            let rest = trimASCII(String(decoding: pb[(ci + 1)..<pb.count], as: UTF8.self))

            let rb = Array(rest.utf8)
            var eqIdx: Int? = nil
            depth = 0
            quote = 0
            var m = 0
            while m < rb.count {
                let c = rb[m]
                if quote != 0 {
                    if c == 0x5C && m + 1 < rb.count { m += 2; continue }
                    if c == quote { quote = 0 }
                } else {
                    if c == 0x22 || c == 0x27 { quote = c }
                    else if c == 0x28 || c == 0x3C || c == 0x5B { depth += 1 }
                    else if c == 0x29 || c == 0x3E || c == 0x5D { depth -= 1 }
                    else if c == 0x3D && depth == 0 {
                        eqIdx = m
                        break
                    }
                }
                m += 1
            }

            if let ei = eqIdx {
                let typePart = trimASCII(String(decoding: rb[0..<ei], as: UTF8.self))
                let defPart = trimASCII(String(decoding: rb[(ei + 1)..<rb.count], as: UTF8.self))
                outParts.append("\(paramName): \(translateTypeSwiftToAgila(typePart)) = \(translateTokensSwiftToAgila(defPart))")
            } else {
                outParts.append("\(paramName): \(translateTypeSwiftToAgila(rest))")
            }
        } else {
            outParts.append(translateTokensSwiftToAgila(part))
        }
    }

    return outParts.joined(separator: ", ")
}

private func emitAgilaFunctionDef(prefixQual: String?, rest: String, isBlock: Bool) -> String? {
    let bytes = Array(rest.utf8)
    guard let lparenIdx = bytes.firstIndex(of: 0x28) else { return nil }
    let rparenIdx = findMatchingDelim(bytes, openIdx: lparenIdx, openCh: 0x28, closeCh: 0x29)
    if rparenIdx >= bytes.count { return nil }

    let fname = trimASCII(String(decoding: bytes[0..<lparenIdx], as: UTF8.self))
    let rawParams = String(decoding: bytes[(lparenIdx + 1)..<rparenIdx], as: UTF8.self)
    var after = trimASCII(String(decoding: bytes[(rparenIdx + 1)..<bytes.count], as: UTF8.self))

    var effects = ""
    if after.hasPrefix("async throws") {
        effects = " async throws"
        after = trimASCII(String(after.dropFirst(12)))
    } else if after.hasPrefix("async") {
        effects = " async"
        after = trimASCII(String(after.dropFirst(5)))
    } else if after.hasPrefix("throws") {
        effects = " throws"
        after = trimASCII(String(after.dropFirst(6)))
    }

    var retStr = ""
    if after.hasPrefix("->") {
        let retRaw = trimASCII(String(after.dropFirst(2)))
        if !retRaw.isEmpty && retRaw != "void" && retRaw != "Void" {
            retStr = " -> " + translateTypeAgilaToSwift(retRaw)
        }
    }

    var qualPrefix = ""
    if let pq = prefixQual, !pq.isEmpty {
        var mapped = pq
        if mapped == "mut" { mapped = "mutating" }
        else if mapped.hasSuffix(" mut") { mapped = String(mapped.dropLast(4)) + " mutating" }
        qualPrefix = mapped + " "
    }

    let swiftParams = emitSwiftParamList(rawParams)
    let isInit = (fname == "init" || fname == "__init__")
    let head = isInit ? "\(qualPrefix)init(\(swiftParams))" : "\(qualPrefix)func \(fname)(\(swiftParams))\(effects)\(retStr)"
    return isBlock ? (head + " {") : head
}

// -------------------------------------------------------------------------
// Range Loops & Comprehensions (Agila <-> Swift)
// -------------------------------------------------------------------------

private func tryEmitForIn(_ expr: String) -> String? {
    let bytes = Array(expr.utf8)
    var depth = 0
    var inPos: Int? = nil
    var i = 0
    while i + 4 <= bytes.count {
        let c = bytes[i]
        if c == 0x28 || c == 0x5B || c == 0x3C { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x3E { depth -= 1 }
        else if depth == 0 && String(decoding: bytes[i..<(i + 4)], as: UTF8.self) == " in " {
            inPos = i
            break
        }
        i += 1
    }
    guard let ip = inPos else { return nil }

    let varPart = trimASCII(String(decoding: bytes[0..<ip], as: UTF8.self))
    let rhs = trimASCII(String(decoding: bytes[(ip + 4)..<bytes.count], as: UTF8.self))

    // Strip optional `: type` on loop variable (Swift infers loop var type cleanly)
    var vname = varPart
    if let colonIdx = varPart.firstIndex(of: ":") {
        vname = trimASCII(String(varPart[..<colonIdx]))
    }
    if vname.contains(",") && !(vname.hasPrefix("(") && vname.hasSuffix(")")) {
        vname = "(\(vname))"
    }

    let rb = Array(rhs.utf8)
    if rhs.hasPrefix("enumerate(") && findMatchingDelim(rb, openIdx: 9, openCh: 0x28, closeCh: 0x29) == rb.count - 1 {
        let inner = trimASCII(String(rhs.dropFirst(10).dropLast()))
        return "for \(vname) in \(translateTokensAgilaToSwift(inner)).enumerated() {"
    }
    if rhs.hasPrefix("reversed(") && findMatchingDelim(rb, openIdx: 8, openCh: 0x28, closeCh: 0x29) == rb.count - 1 {
        let inner = trimASCII(String(rhs.dropFirst(9).dropLast()))
        if inner.hasPrefix("range(") {
            let ib = Array(inner.utf8)
            if findMatchingDelim(ib, openIdx: 5, openCh: 0x28, closeCh: 0x29) == ib.count - 1 {
                let rargs = String(inner.dropFirst(6).dropLast())
                if let comma = findTopLevelComma(rargs) {
                    let a = translateTokensAgilaToSwift(trimASCII(String(rargs[..<comma])))
                    let b = translateTokensAgilaToSwift(trimASCII(String(rargs[rargs.index(after: comma)...])))
                    return "for \(vname) in (\(a)..<\(b)).reversed() {"
                }
                return "for \(vname) in (0..<\(translateTokensAgilaToSwift(rargs))).reversed() {"
            }
        }
        return "for \(vname) in \(translateTokensAgilaToSwift(inner)).reversed() {"
    }
    if rhs.hasPrefix("range(") && findMatchingDelim(rb, openIdx: 5, openCh: 0x28, closeCh: 0x29) == rb.count - 1 {
        let rargs = String(rhs.dropFirst(6).dropLast())
        // Split top-level commas (up to 3 args)
        let ab = Array(rargs.utf8)
        var parts: [String] = []
        var segStart = 0
        var d = 0
        for idx in 0...ab.count {
            if idx < ab.count {
                if ab[idx] == 0x28 || ab[idx] == 0x5B { d += 1 }
                else if ab[idx] == 0x29 || ab[idx] == 0x5D { d -= 1 }
            }
            if idx == ab.count || (ab[idx] == 0x2C && d == 0) {
                parts.append(trimASCII(String(decoding: ab[segStart..<idx], as: UTF8.self)))
                segStart = idx + 1
            }
        }
        if parts.count == 1 && !parts[0].isEmpty {
            let stop = translateTokensAgilaToSwift(parts[0])
            return "for \(vname) in 0..<\(stop) {"
        } else if parts.count == 2 {
            let start = translateTokensAgilaToSwift(parts[0])
            let stop = translateTokensAgilaToSwift(parts[1])
            return "for \(vname) in \(start)..<\(stop) {"
        } else if parts.count == 3 {
            let start = translateTokensAgilaToSwift(parts[0])
            let stop = translateTokensAgilaToSwift(parts[1])
            let step = translateTokensAgilaToSwift(parts[2])
            return "for \(vname) in stride(from: \(start), to: \(stop), by: \(step)) {"
        }
    }

    return "for \(vname) in \(translateTokensAgilaToSwift(rhs)) {"
}

private enum CompKind {
    case list
    case set
    case dict
}

// Emit Swift container initialization + loop for Agila list/set/dict comprehension
private func tryEmitAgilaComprehension(
    qual: String,
    lhs: String,
    ts: String,
    val: String,
    swiftIndent: String,
    level: Int
) -> String? {
    let v = trimASCII(val)
    if v.count < 2 { return nil }
    let vb = Array(v.utf8)

    let isBracket: Bool
    if vb.first == 0x5B && findMatchingDelim(vb, openIdx: 0, openCh: 0x5B, closeCh: 0x5D) == vb.count - 1 {
        isBracket = true
    } else if vb.first == 0x7B && findMatchingDelim(vb, openIdx: 0, openCh: 0x7B, closeCh: 0x7D) == vb.count - 1 {
        isBracket = false
    } else {
        return nil
    }

    let inner = String(decoding: vb[1..<(vb.count - 1)], as: UTF8.self)
    guard let forIdx = findTopLevelKwAgila(inner, "for"), forIdx > 0 else { return nil }
    let ib = Array(inner.utf8)
    let head = trimASCII(String(decoding: ib[0..<forIdx], as: UTF8.self))
    if head.isEmpty { return nil }

    // Parse 1 or more `var in iter [if cond...]` clauses
    var clauses: [(forClause: String, conds: [String])] = []
    var rem = trimASCII(String(decoding: ib[(forIdx + 3)..<ib.count], as: UTF8.self))
    while !rem.isEmpty {
        guard let inIdx = findTopLevelKwAgila(rem, "in"), inIdx > 0 else { return nil }
        let rb = Array(rem.utf8)
        let lhsPart = trimASCII(String(decoding: rb[0..<inIdx], as: UTF8.self))
        let afterIn = trimASCII(String(decoding: rb[(inIdx + 2)..<rb.count], as: UTF8.self))
        let ab = Array(afterIn.utf8)
        let seg: String
        if let nf = findTopLevelKwAgila(afterIn, "for") {
            seg = trimASCII(String(decoding: ab[0..<nf], as: UTF8.self))
            rem = trimASCII(String(decoding: ab[(nf + 3)..<ab.count], as: UTF8.self))
        } else {
            seg = afterIn
            rem = ""
        }
        var conds: [String] = []
        let iterPart: String
        if let firstIf = findTopLevelKwAgila(seg, "if") {
            let sb = Array(seg.utf8)
            iterPart = trimASCII(String(decoding: sb[0..<firstIf], as: UTF8.self))
            var ctail = trimASCII(String(decoding: sb[(firstIf + 2)..<sb.count], as: UTF8.self))
            if ctail.isEmpty { return nil }
            while !ctail.isEmpty {
                if let ni = findTopLevelKwAgila(ctail, "if") {
                    let cb = Array(ctail.utf8)
                    let c = trimASCII(String(decoding: cb[0..<ni], as: UTF8.self))
                    if c.isEmpty { return nil }
                    conds.append(c)
                    ctail = trimASCII(String(decoding: cb[(ni + 2)..<cb.count], as: UTF8.self))
                } else {
                    conds.append(ctail)
                    break
                }
            }
        } else {
            iterPart = seg
        }
        if iterPart.isEmpty { return nil }
        clauses.append((forClause: "\(lhsPart) in \(iterPart)", conds: conds))
    }
    if clauses.isEmpty { return nil }

    var kind: CompKind = .list
    var keyStr = ""
    var elemStr = head

    if !isBracket {
        let hb = Array(head.utf8)
        var colonIdx: Int? = nil
        var depth = 0
        var quote: UInt8 = 0
        var qmarkDepth = 0
        var k = 0
        while k < hb.count {
            let c = hb[k]
            if quote != 0 {
                if c == 0x5C && k + 1 < hb.count { k += 2; continue }
                if c == quote { quote = 0 }
                k += 1
                continue
            }
            if c == 0x22 || c == 0x27 { quote = c }
            else if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
            else if c == 0x29 || c == 0x5D || c == 0x7D { depth -= 1 }
            else if depth == 0 {
                if c == 0x3F { qmarkDepth += 1 }
                else if c == 0x3A {
                    if qmarkDepth > 0 { qmarkDepth -= 1 }
                    else { colonIdx = k; break }
                }
            }
            k += 1
        }
        if let ci = colonIdx {
            kind = .dict
            keyStr = trimASCII(String(decoding: hb[0..<ci], as: UTF8.self))
            elemStr = trimASCII(String(decoding: hb[(ci + 1)..<hb.count], as: UTF8.self))
            if keyStr.isEmpty || elemStr.isEmpty { return nil }
        } else {
            kind = .set
        }
    }

    let swiftType = translateTypeAgilaToSwift(ts)
    let initExpr: String
    switch kind {
    case .list: initExpr = "[]"
    case .set:  initExpr = "Set()"
    case .dict: initExpr = "[:]"
    }

    var out = "var \(lhs): \(swiftType) = \(initExpr)\n"
    var curLevel = level
    var closers: [Int] = []
    for cl in clauses {
        let ind = String(repeating: swiftIndent, count: curLevel)
        if let forLine = tryEmitForIn(cl.forClause) {
            out += "\(ind)\(forLine)\n"
        } else {
            out += "\(ind)for \(translateTokensAgilaToSwift(cl.forClause)) {\n"
        }
        closers.append(curLevel)
        curLevel += 1
        for cond in cl.conds {
            let cInd = String(repeating: swiftIndent, count: curLevel)
            out += "\(cInd)if \(translateTokensAgilaToSwift(cond)) {\n"
            closers.append(curLevel)
            curLevel += 1
        }
    }

    let bodyInd = String(repeating: swiftIndent, count: curLevel)
    switch kind {
    case .list:
        out += "\(bodyInd)\(lhs).append(\(translateTokensAgilaToSwift(elemStr)))\n"
    case .set:
        out += "\(bodyInd)\(lhs).insert(\(translateTokensAgilaToSwift(elemStr)))\n"
    case .dict:
        out += "\(bodyInd)\(lhs)[\(translateTokensAgilaToSwift(keyStr))] = \(translateTokensAgilaToSwift(elemStr))\n"
    }

    for (ci, cLvl) in closers.reversed().enumerated() {
        let cInd = String(repeating: swiftIndent, count: cLvl)
        out += "\(cInd)}" + (ci + 1 < closers.count ? "\n" : "")
    }
    return out
}

// -------------------------------------------------------------------------
// Agila -> Swift Transpiler
// -------------------------------------------------------------------------

private enum BlockKind {
    case normal
    case structOrClass
    case enumBlock
    case switchBlock
    case caseBlock
    case doWhile
}

private struct BlockFrame {
    let level: Int
    let kind: BlockKind
}

private func startsWithKw(_ s: String, _ kw: String) -> String? {
    if !s.hasPrefix(kw) { return nil }
    if s.count == kw.count { return "" }
    let after = s[s.index(s.startIndex, offsetBy: kw.count)...]
    guard let first = after.first else { return "" }
    if first == " " || first == "(" || first == ":" {
        return trimASCII(String(after))
    }
    return nil
}

private func splitInlineHashComment(_ s: String) -> (code: String, comment: String?) {
    let bytes = Array(s.utf8)
    var quote: UInt8 = 0
    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 {
            quote = c
            i += 1
            continue
        }
        if c == 0x23 && (i == 0 || bytes[i - 1] == 0x20) {
            var codeEnd = i
            while codeEnd > 0 && bytes[codeEnd - 1] == 0x20 { codeEnd -= 1 }
            let codeStr = String(decoding: bytes[0..<codeEnd], as: UTF8.self)
            let commentStr = String(decoding: bytes[(i + 1)..<bytes.count], as: UTF8.self)
            return (codeStr, commentStr)
        }
        i += 1
    }
    return (s, nil)
}

private func findDeclColon(_ s: String) -> (lhs: String, typePart: String, valPart: String?)? {
    let bytes = Array(s.utf8)
    var depth = 0
    var quote: UInt8 = 0
    var colonIdx: Int? = nil
    var eqIdx: Int? = nil

    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 { quote = c; i += 1; continue }
        if c == 0x28 || c == 0x5B || c == 0x7B { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x7D { depth -= 1 }
        else if depth == 0 {
            if colonIdx == nil && c == 0x3A {
                if i + 1 < bytes.count && bytes[i + 1] == 0x3A {
                    i += 2
                    continue
                }
                colonIdx = i
            } else if colonIdx != nil && eqIdx == nil && c == 0x3D {
                if i + 1 < bytes.count && bytes[i + 1] == 0x3D {
                    i += 2
                    continue
                }
                eqIdx = i
                break
            } else if colonIdx == nil && (c == 0x3D || c == 0x3B || c == 0x2B || c == 0x2D || c == 0x2A || c == 0x2F) {
                return nil
            }
        }
        i += 1
    }

    guard let ci = colonIdx else { return nil }
    let lhs = trimASCII(String(decoding: bytes[0..<ci], as: UTF8.self))
    if lhs.isEmpty { return nil }
    for b in lhs.utf8 {
        if !isIdentCont(b) && b != 0x20 { return nil }
    }

    if let ei = eqIdx {
        let tp = trimASCII(String(decoding: bytes[(ci + 1)..<ei], as: UTF8.self))
        let vp = trimASCII(String(decoding: bytes[(ei + 1)..<bytes.count], as: UTF8.self))
        return (lhs, tp, vp)
    } else {
        let tp = trimASCII(String(decoding: bytes[(ci + 1)..<bytes.count], as: UTF8.self))
        return (lhs, tp, nil)
    }
}

private struct LogicalLineAgila {
    let lineNo: Int
    let raw: String
}

private func preprocessLogicalLinesAgila(_ src: String) throws -> [LogicalLineAgila] {
    let bytes = Array(src.utf8)
    var rawLines: [String] = []
    var p = 0
    while p < bytes.count {
        let ls = p
        while p < bytes.count && bytes[p] != 0x0A && bytes[p] != 0x0D { p += 1 }
        rawLines.append(String(decoding: bytes[ls..<p], as: UTF8.self))
        if p < bytes.count {
            if bytes[p] == 0x0D && p + 1 < bytes.count && bytes[p + 1] == 0x0A { p += 2 }
            else { p += 1 }
        }
    }

    func updateDepth(_ code: String, _ parenDepth: inout Int) {
        let b = Array(code.utf8)
        var q: UInt8 = 0
        var i = 0
        while i < b.count {
            let c = b[i]
            if q != 0 {
                if c == 0x5C && i + 1 < b.count { i += 2; continue }
                if c == q { q = 0 }
                i += 1
                continue
            }
            if c == 0x22 || c == 0x27 { q = c; i += 1; continue }
            if c == 0x28 || c == 0x5B || c == 0x7B { parenDepth += 1 }
            else if (c == 0x29 || c == 0x5D || c == 0x7D) && parenDepth > 0 { parenDepth -= 1 }
            i += 1
        }
    }

    func escapeSingleLineAgila(_ body: String, isF: Bool) -> String {
        var out = isF ? "f\"" : "\""
        for c in body {
            if c == "\n" { out += "\\n" }
            else if c == "\"" { out += "\\\"" }
            else { out.append(c) }
        }
        return out + "\""
    }

    func findTripleStartAgila(_ s: String) -> (idx: Int, delim: String, isF: Bool)? {
        let b = Array(s.utf8)
        var q: UInt8 = 0
        var i = 0
        while i < b.count {
            let c = b[i]
            if q != 0 {
                if c == 0x5C && i + 1 < b.count { i += 2; continue }
                if c == q { q = 0 }
                i += 1
                continue
            }
            if c == 0x23 && (i == 0 || b[i - 1] == 0x20 || b[i - 1] == 0x09) { break }
            let sub = String(decoding: b[i..<b.count], as: UTF8.self)
            if sub.hasPrefix("f\"\"\"") && (i == 0 || !isIdentCont(b[i - 1])) { return (i, "\"\"\"", true) }
            if sub.hasPrefix("f'''") && (i == 0 || !isIdentCont(b[i - 1])) { return (i, "'''", true) }
            if sub.hasPrefix("\"\"\"") { return (i, "\"\"\"", false) }
            if sub.hasPrefix("'''") { return (i, "'''", false) }
            if c == 0x22 || c == 0x27 { q = c }
            i += 1
        }
        return nil
    }

    func collapseSameLineAgila(_ s: String) -> String {
        var cur = s
        while let ts = findTripleStartAgila(cur) {
            let cb = Array(cur.utf8)
            let startOff = ts.idx + (ts.isF ? 4 : 3)
            let tail = String(decoding: cb[startOff..<cb.count], as: UTF8.self)
            guard let closeR = tail.range(of: ts.delim) else { break }
            let body = String(tail[..<closeR.lowerBound])
            let rest = String(tail[closeR.upperBound...])
            let prefix = String(decoding: cb[0..<ts.idx], as: UTF8.self)
            cur = prefix + escapeSingleLineAgila(body, isF: ts.isF) + rest
        }
        return cur
    }

    var result: [LogicalLineAgila] = []
    var curLineNo = 0
    var acc = ""
    var parenDepth = 0
    var continued = false
    var tripleQuote: String? = nil
    var tripleF = false
    var tripleBody = ""

    for (idx, raw) in rawLines.enumerated() {
        let lineNo = idx + 1
        if let delim = tripleQuote {
            if let closeR = raw.range(of: delim) {
                tripleBody += "\n" + String(raw[..<closeR.lowerBound])
                let rest = String(raw[closeR.upperBound...])
                acc += escapeSingleLineAgila(tripleBody, isF: tripleF) + collapseSameLineAgila(rest)
                tripleQuote = nil
                tripleBody = ""
                let trimmedAcc = String(acc.drop(while: { $0 == " " || $0 == "\t" }))
                let (code, _) = splitInlineHashComment(trimmedAcc)
                parenDepth = 0
                updateDepth(code, &parenDepth)
                continued = acc.hasSuffix("\\")
                if continued {
                    acc = String(acc.dropLast()).replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) + " "
                } else if parenDepth == 0 {
                    result.append(LogicalLineAgila(lineNo: curLineNo, raw: acc))
                    acc = ""
                }
            } else {
                tripleBody += "\n" + raw
            }
            continue
        }

        if parenDepth == 0 && !continued {
            if raw.utf8.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                result.append(LogicalLineAgila(lineNo: lineNo, raw: raw))
                continue
            }
            if raw.hasSuffix(" ") || raw.hasSuffix("\t") {
                throw AgilaError("trailing whitespace is not allowed", line: lineNo, col: raw.utf8.count)
            }
            curLineNo = lineNo
        }

        let line = collapseSameLineAgila(raw)
        if let ts = findTripleStartAgila(line) {
            let lb = Array(line.utf8)
            let startOff = ts.idx + (ts.isF ? 4 : 3)
            let prefix = String(decoding: lb[0..<ts.idx], as: UTF8.self)
            if !acc.isEmpty {
                acc += " " + String(prefix.drop(while: { $0 == " " || $0 == "\t" }))
            } else {
                acc = prefix
            }
            tripleQuote = ts.delim
            tripleF = ts.isF
            tripleBody = String(decoding: lb[startOff..<lb.count], as: UTF8.self)
            continue
        }

        if parenDepth > 0 || continued {
            let chunk = trimASCII(line)
            let (code, _) = splitInlineHashComment(chunk)
            if code.hasSuffix("\\") {
                acc += " " + trimASCII(String(code.dropLast()))
                continued = true
                continue
            }
            continued = false
            if acc.hasSuffix("(") || acc.hasSuffix("[") || acc.hasSuffix("{") {
                acc += code
            } else if !code.isEmpty {
                acc += " " + code
            }
            parenDepth = 0
            let trimmedAcc = String(acc.drop(while: { $0 == " " || $0 == "\t" }))
            let (cCode, _) = splitInlineHashComment(trimmedAcc)
            updateDepth(cCode, &parenDepth)
            if parenDepth == 0 {
                result.append(LogicalLineAgila(lineNo: curLineNo, raw: acc))
                acc = ""
            }
            continue
        }

        let trimmedStart = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        let (code, inlineC) = splitInlineHashComment(trimmedStart)
        if inlineC == nil && line.hasSuffix("\\") {
            acc = String(line.dropLast().reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            continued = true
            continue
        }
        updateDepth(code, &parenDepth)
        if parenDepth > 0 {
            let wsLen = line.utf8.count - trimmedStart.utf8.count
            let lb = Array(line.utf8)
            acc = String(decoding: lb[0..<wsLen], as: UTF8.self) + code
        } else {
            result.append(LogicalLineAgila(lineNo: lineNo, raw: line))
        }
    }

    if tripleQuote != nil {
        throw AgilaError("unterminated triple-quoted string", line: curLineNo, col: 1)
    }
    if !acc.isEmpty {
        result.append(LogicalLineAgila(lineNo: curLineNo, raw: acc))
    }
    return result
}

public func agilaToSwift(_ src: String) throws -> String {
    let rawBytes = Array(src.utf8)
    // Reject UTF-8 BOM
    if rawBytes.count >= 3 && rawBytes[0] == 0xEF && rawBytes[1] == 0xBB && rawBytes[2] == 0xBF {
        throw AgilaError("UTF-8 BOM is not allowed", line: 1, col: 1)
    }

    agilaUsedInHelper = false
    agilaUsedFloorDiv = false
    agilaUsedPow = false

    let logicalLines = try preprocessLogicalLinesAgila(src)

    var out = ""
    out.reserveCapacity(rawBytes.count * 2 + 128)

    var indentChar: UInt8 = 0
    var indentWidth = 0
    var stack: [BlockFrame] = []
    var currentLevel = 0
    var prevLineOpenedBlock = false
    var prevBlockLine = 0
    var hasFoundationImport = false

    let swiftIndent = "    "

    for ll in logicalLines {
        let lineNo = ll.lineNo
        let bytes = Array(ll.raw.utf8)
        let len = bytes.count

        // Measure leading whitespace
        var ws = 0
        var hasSpace = false
        var hasTab = false
        while ws < len {
            let c = bytes[ws]
            if c == 0x20 { hasSpace = true; ws += 1 }
            else if c == 0x09 { hasTab = true; ws += 1 }
            else { break }
        }

        // Blank line?
        if ws == len {
            out += "\n"
            continue
        }

        if hasSpace && hasTab {
            throw AgilaError("mixed spaces and tabs in indentation", line: lineNo, col: ws)
        }

        // Check for trailing whitespace
        if bytes[len - 1] == 0x20 || bytes[len - 1] == 0x09 {
            throw AgilaError("trailing whitespace is not allowed", line: lineNo, col: len)
        }

        var level = 0
        if ws > 0 {
            let ch: UInt8 = hasTab ? 0x09 : 0x20
            if indentWidth == 0 {
                if currentLevel == 0 && !prevLineOpenedBlock {
                    throw AgilaError("unexpected indentation at root level", line: lineNo, col: 1)
                }
                indentChar = ch
                indentWidth = ws
                level = 1
            } else {
                if ch != indentChar {
                    throw AgilaError("inconsistent indentation character (spaces vs tabs)", line: lineNo, col: 1)
                }
                if ws % indentWidth != 0 {
                    throw AgilaError("indentation is not a multiple of the file's indent unit", line: lineNo, col: ws + 1)
                }
                level = ws / indentWidth
            }
        }

        let content = String(decoding: bytes[ws..<len], as: UTF8.self)

        if prevLineOpenedBlock && !content.hasPrefix("#") {
            if level != currentLevel {
                throw AgilaError("expected indented block after ':'", line: prevBlockLine, col: 1)
            }
            prevLineOpenedBlock = false
        } else if !prevLineOpenedBlock && level > currentLevel && !content.hasPrefix("#") {
            throw AgilaError("unexpected indentation increase without a block header", line: lineNo, col: ws + 1)
        }

        let ind = String(repeating: swiftIndent, count: level)

        // Full-line comment `# ...`
        if content.hasPrefix("#") {
            out += ind + "//" + String(content.dropFirst()) + "\n"
            continue
        }

        let (code, inlineComment) = splitInlineHashComment(content)

        let isElif = startsWithKw(code, "elif") != nil
        let isElse = (code == "else:")
        let isCatch = startsWithKw(code, "catch") != nil || startsWithKw(code, "except") != nil
        let isCase = startsWithKw(code, "case") != nil || code == "default:"

        // Close blocks down to `level`
        while let top = stack.last, top.level >= level {
            if top.level == level && top.kind == .normal && (isElif || isElse || isCatch) {
                break
            }
            if top.level == level && top.kind == .caseBlock && isCase {
                stack.removeLast()
                break
            }
            if top.level == level && top.kind == .doWhile && startsWithKw(code, "while") != nil && !code.hasSuffix(":") {
                break
            }
            let frame = stack.removeLast()
            if frame.kind != .caseBlock {
                out += String(repeating: swiftIndent, count: frame.level) + "}\n"
            }
        }
        currentLevel = level

        // Handle `do:` (or `repeat:`) followed by `while cond` at same level
        if let top = stack.last, top.level == level && top.kind == .doWhile,
           let whileCond = startsWithKw(code, "while"), !code.hasSuffix(":") {
            stack.removeLast()
            out += ind + "} while " + translateTokensAgilaToSwift(whileCond)
            if let ic = inlineComment { out += " //" + ic }
            out += "\n"
            continue
        }

        // Handle `pass`
        if code == "pass" {
            if let ic = inlineComment {
                out += ind + "//" + ic + "\n"
            }
            continue
        }

        // Module imports: `import Foundation` or `from Foundation import Date`
        if let imp = startsWithKw(code, "import") {
            let impClean = trimASCII(imp)
            if impClean == "Foundation" { hasFoundationImport = true }
            out += ind + "import " + impClean
            if let ic = inlineComment { out += " //" + ic }
            out += "\n"
            continue
        }
        if let f = startsWithKw(code, "from") {
            let modName = f.split(separator: " ").first.map(String.init) ?? f
            if modName == "Foundation" { hasFoundationImport = true }
            out += ind + "import " + modName + "\n"
            continue
        }

        // Check if line is a block header ending with `:`
        if code.hasSuffix(":") {
            let header = trimASCII(String(code.dropLast()))

            if isElif, let top = stack.last, top.level == level, let cond = startsWithKw(header, "elif") {
                out += ind + "} else if " + translateTokensAgilaToSwift(cond) + " {"
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if isElse, let top = stack.last, top.level == level {
                out += ind + "} else {"
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if isCatch, let top = stack.last, top.level == level {
                let cexpr = startsWithKw(header, "catch") ?? startsWithKw(header, "except") ?? ""
                if cexpr.isEmpty {
                    out += ind + "} catch {"
                } else {
                    out += ind + "} catch " + translateTokensAgilaToSwift(cexpr) + " {"
                }
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let cond = startsWithKw(header, "if") {
                out += ind + "if " + translateTokensAgilaToSwift(cond) + " {"
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let cond = startsWithKw(header, "guard") {
                out += ind + "guard " + translateTokensAgilaToSwift(cond) + " else {"
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let cond = startsWithKw(header, "while") {
                out += ind + "while " + translateTokensAgilaToSwift(cond) + " {"
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if header == "do" || header == "repeat" {
                out += ind + "repeat {"
                stack.append(BlockFrame(level: level, kind: .doWhile))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if header == "try" {
                out += ind + "do {"
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if header == "defer" {
                out += ind + "defer {"
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let fexpr = startsWithKw(header, "for") {
                if let forLine = tryEmitForIn(fexpr) {
                    out += ind + forLine
                } else {
                    out += ind + "for " + translateTokensAgilaToSwift(fexpr) + " {"
                }
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let wexpr = startsWithKw(header, "with") {
                out += ind + "do {\n"
                if let asIdx = findTopLevelKwAgila(wexpr, "as"), asIdx > 0 {
                    let wb = Array(wexpr.utf8)
                    let exprS = trimASCII(String(decoding: wb[0..<asIdx], as: UTF8.self))
                    let vname = trimASCII(String(decoding: wb[(asIdx + 2)..<wb.count], as: UTF8.self))
                    out += ind + swiftIndent + "let \(vname) = \(translateTokensAgilaToSwift(exprS))"
                } else {
                    out += ind + swiftIndent + translateTokensAgilaToSwift(wexpr)
                }
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let swExpr = startsWithKw(header, "switch") ?? startsWithKw(header, "match") {
                out += ind + "switch " + translateTokensAgilaToSwift(swExpr) + " {"
                stack.append(BlockFrame(level: level, kind: .switchBlock))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let caseExpr = startsWithKw(header, "case") {
                out += ind + "case " + translateTokensAgilaToSwift(caseExpr) + ":"
                stack.append(BlockFrame(level: level, kind: .caseBlock))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if header == "default" {
                out += ind + "default:"
                stack.append(BlockFrame(level: level, kind: .caseBlock))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if startsWithKw(header, "struct") != nil ||
                      startsWithKw(header, "class") != nil ||
                      startsWithKw(header, "actor") != nil ||
                      startsWithKw(header, "protocol") != nil ||
                      startsWithKw(header, "extension") != nil {
                if let lp = header.firstIndex(of: "("), let rp = header.lastIndex(of: ")"), lp < rp {
                    let pre = trimASCII(String(header[..<lp]))
                    let base = trimASCII(String(header[header.index(after: lp)..<rp]))
                    out += ind + translateTokensAgilaToSwift(pre) + ": " + translateTypeAgilaToSwift(base) + " {"
                } else {
                    out += ind + translateTokensAgilaToSwift(header) + " {"
                }
                stack.append(BlockFrame(level: level, kind: .structOrClass))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let enumRest = startsWithKw(header, "enum") {
                if let lp = enumRest.firstIndex(of: "("), let rp = enumRest.lastIndex(of: ")"), lp < rp {
                    let ename = trimASCII(String(enumRest[..<lp]))
                    let rawT = trimASCII(String(enumRest[enumRest.index(after: lp)..<rp]))
                    out += ind + "enum \(ename): \(translateTypeAgilaToSwift(rawT)) {"
                } else {
                    out += ind + "enum " + translateTokensAgilaToSwift(enumRest) + " {"
                }
                stack.append(BlockFrame(level: level, kind: .enumBlock))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let fnRest = startsWithKw(header, "def") ?? startsWithKw(header, "fn") {
                guard let fnLine = emitAgilaFunctionDef(prefixQual: nil, rest: fnRest, isBlock: true) else {
                    throw AgilaError("invalid function definition", line: lineNo, col: 1)
                }
                out += ind + fnLine
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else if let defRange = header.range(of: " def ") {
                let qual = trimASCII(String(header[..<defRange.lowerBound]))
                let fnRest = trimASCII(String(header[defRange.upperBound...]))
                guard let fnLine = emitAgilaFunctionDef(prefixQual: qual, rest: fnRest, isBlock: true) else {
                    throw AgilaError("invalid qualified function definition", line: lineNo, col: 1)
                }
                out += ind + fnLine
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            } else {
                out += ind + translateTokensAgilaToSwift(header) + " {"
                stack.append(BlockFrame(level: level, kind: .normal))
                currentLevel = level + 1
                prevLineOpenedBlock = true
                prevBlockLine = lineNo
            }

            if let ic = inlineComment { out += " //" + ic }
            out += "\n"
            continue
        }

        // Inside an `enum` block, entries become `case ...`
        if let top = stack.last, top.kind == .enumBlock && top.level + 1 == level {
            if startsWithKw(code, "case") != nil {
                out += ind + translateTokensAgilaToSwift(code)
            } else {
                out += ind + "case " + translateTokensAgilaToSwift(code)
            }
            if let ic = inlineComment { out += " //" + ic }
            out += "\n"
            continue
        }

        // Function prototype (e.g. inside protocol): `def foo(a: i32) -> i32`
        if let fnRest = startsWithKw(code, "def") ?? startsWithKw(code, "fn") {
            guard let fnLine = emitAgilaFunctionDef(prefixQual: nil, rest: fnRest, isBlock: false) else {
                throw AgilaError("invalid function prototype", line: lineNo, col: 1)
            }
            out += ind + fnLine
            if let ic = inlineComment { out += " //" + ic }
            out += "\n"
            continue
        }

        // Type alias: `type Name = TargetType` -> `typealias Name = TargetType`
        if let typeRest = startsWithKw(code, "type"), let eqIdx = typeRest.firstIndex(of: "=") {
            let aliasName = trimASCII(String(typeRest[..<eqIdx]))
            let targetType = trimASCII(String(typeRest[typeRest.index(after: eqIdx)...]))
            out += ind + "typealias \(aliasName) = \(translateTypeAgilaToSwift(targetType))"
            if let ic = inlineComment { out += " //" + ic }
            out += "\n"
            continue
        }

        // Variable or field declaration: `[var|const|let|static] name: type [= value]`
        if let decl = findDeclColon(code) {
            var lhs = decl.lhs
            var kw = "let"
            let inStructOrClass = (stack.last?.kind == .structOrClass && (stack.last?.level ?? -1) + 1 == level)
            if inStructOrClass && decl.valPart == nil {
                kw = "var"
            }

            if let spaceIdx = lhs.lastIndex(of: " ") {
                let prefix = trimASCII(String(lhs[..<spaceIdx]))
                lhs = trimASCII(String(lhs[lhs.index(after: spaceIdx)...]))
                if prefix == "var" || prefix == "mut" {
                    kw = "var"
                } else if prefix == "const" || prefix == "let" {
                    kw = "let"
                } else if prefix == "static var" {
                    kw = "static var"
                } else if prefix == "static" || prefix == "static const" || prefix == "static let" {
                    kw = "static let"
                } else {
                    kw = prefix + " var"
                }
            }

            if let val = decl.valPart {
                if let compCode = tryEmitAgilaComprehension(qual: kw, lhs: lhs, ts: decl.typePart, val: val, swiftIndent: swiftIndent, level: level) {
                    out += ind + compCode
                } else {
                    out += ind + "\(kw) \(lhs): \(translateTypeAgilaToSwift(decl.typePart)) = \(translateTokensAgilaToSwift(val))"
                }
            } else {
                out += ind + "\(kw) \(lhs): \(translateTypeAgilaToSwift(decl.typePart))"
            }
        } else if let raiseExpr = startsWithKw(code, "raise") {
            out += ind + "throw " + translateTokensAgilaToSwift(raiseExpr)
        } else if let delExpr = startsWithKw(code, "del"), !delExpr.isEmpty {
            let db = Array(delExpr.utf8)
            var obOpt: Int? = nil
            var bdep = 0
            var bq: UInt8 = 0
            var k = 0
            while k < db.count {
                let c = db[k]
                if bq != 0 {
                    if c == 0x5C && k + 1 < db.count { k += 2; continue }
                    if c == bq { bq = 0 }
                    k += 1; continue
                }
                if c == 0x22 || c == 0x27 { bq = c; k += 1; continue }
                if c == 0x28 || c == 0x5B || c == 0x7B {
                    if c == 0x5B && bdep == 0 { obOpt = k }
                    bdep += 1
                } else if (c == 0x29 || c == 0x5D || c == 0x7D) && bdep > 0 {
                    bdep -= 1
                }
                k += 1
            }
            if let ob = obOpt, db.last == 0x5D {
                let mExpr = trimASCII(String(decoding: db[0..<ob], as: UTF8.self))
                let kExpr = trimASCII(String(decoding: db[(ob + 1)..<(db.count - 1)], as: UTF8.self))
                out += ind + "\(translateTokensAgilaToSwift(mExpr)).removeValue(forKey: \(translateTokensAgilaToSwift(kExpr)))"
            } else {
                out += ind + translateTokensAgilaToSwift(code)
            }
        } else if let retExpr = startsWithKw(code, "return") {
            if retExpr.isEmpty {
                out += ind + "return"
            } else {
                out += ind + "return " + translateTokensAgilaToSwift(retExpr)
            }
        } else if let varRest = startsWithKw(code, "var"), let eqIdx = varRest.firstIndex(of: "="),
                  !varRest.contains("=="), !varRest.contains("!="), !varRest.contains("<="), !varRest.contains(">=") {
            var vname = trimASCII(String(varRest[..<eqIdx]))
            let rhs = trimASCII(String(varRest[varRest.index(after: eqIdx)...]))
            if vname.contains(",") && !(vname.hasPrefix("(") && vname.hasSuffix(")")) {
                vname = "(\(vname))"
            }
            out += ind + "var \(vname) = \(translateTokensAgilaToSwift(rhs))"
        } else if level == 0, let eqIdx = code.firstIndex(of: "="),
                  !code.contains("=="), !code.contains("!="), !code.contains("<="), !code.contains(">=") {
            let lhs = trimASCII(String(code[..<eqIdx]))
            let rhs = trimASCII(String(code[code.index(after: eqIdx)...]))
            let isSimpleIdent = !lhs.isEmpty && lhs.utf8.allSatisfy({ isIdentCont($0) }) && isIdentStart(lhs.utf8.first!)
            if isSimpleIdent {
                out += ind + "let \(lhs) = \(translateTokensAgilaToSwift(rhs))"
            } else {
                out += ind + translateTokensAgilaToSwift(code)
            }
        } else {
            out += ind + translateTokensAgilaToSwift(code)
        }

        if let ic = inlineComment { out += " //" + ic }
        out += "\n"
    }

    if prevLineOpenedBlock {
        throw AgilaError("dangling block header at end of file (expected indented block)", line: prevBlockLine, col: 1)
    }

    while let frame = stack.popLast() {
        if frame.kind != .caseBlock {
            out += String(repeating: swiftIndent, count: frame.level) + "}\n"
        }
    }

    if agilaUsedPow && !hasFoundationImport {
        out = "import Foundation\n\n" + out
    }
    if agilaUsedInHelper {
        out += "\nprivate func _agilaIn<T: Equatable>(_ c: [T], _ k: T) -> Bool { return c.contains(k) }\n"
        out += "private func _agilaIn<T: Hashable>(_ c: Set<T>, _ k: T) -> Bool { return c.contains(k) }\n"
        out += "private func _agilaIn<K: Hashable, V>(_ c: [K: V], _ k: K) -> Bool { return c[k] != nil }\n"
        out += "private func _agilaIn(_ c: String, _ k: String) -> Bool { return c.contains(k) }\n"
    }
    if agilaUsedFloorDiv {
        out += "\nprivate func _agilaFloorDiv(_ a: Int, _ b: Int) -> Int { return Int(floor(Double(a) / Double(b))) }\n"
        out += "private func _agilaFloorDiv(_ a: Int32, _ b: Int32) -> Int32 { return Int32(floor(Double(a) / Double(b))) }\n"
        out += "private func _agilaFloorDiv(_ a: Int64, _ b: Int64) -> Int64 { return Int64(floor(Double(a) / Double(b))) }\n"
        out += "private func _agilaFloorDiv(_ a: Double, _ b: Double) -> Double { return floor(a / b) }\n"
        if !agilaUsedPow && !hasFoundationImport {
            out = "import Foundation\n\n" + out
        }
    }
    if agilaUsedPow {
        out += "\nprivate func _agilaPow(_ a: Int, _ b: Int) -> Int { return Int(pow(Double(a), Double(b))) }\n"
        out += "private func _agilaPow(_ a: Int32, _ b: Int32) -> Int32 { return Int32(pow(Double(a), Double(b))) }\n"
        out += "private func _agilaPow(_ a: Int64, _ b: Int64) -> Int64 { return Int64(pow(Double(a), Double(b))) }\n"
        out += "private func _agilaPow(_ a: Double, _ b: Double) -> Double { return pow(a, b) }\n"
    }

    return out
}

// -------------------------------------------------------------------------
// Swift -> Agila Transpiler & Canonical Formatter
// -------------------------------------------------------------------------

private func validIndentUnit(_ unit: String) -> Bool {
    if unit.isEmpty { return false }
    let bytes = Array(unit.utf8)
    let first = bytes[0]
    if first != 0x20 && first != 0x09 { return false }
    return bytes.allSatisfy { $0 == first }
}

private func tryConvertSwiftForHeader(_ rawCond: String) -> (agilaFor: String, loopVar: String)? {
    let cond = trimASCII(rawCond)
    let bytes = Array(cond.utf8)
    var depth = 0
    var inPos: Int? = nil
    var i = 0
    while i + 4 <= bytes.count {
        let c = bytes[i]
        if c == 0x28 || c == 0x5B || c == 0x3C { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x3E { depth -= 1 }
        else if depth == 0 && String(decoding: bytes[i..<(i + 4)], as: UTF8.self) == " in " {
            inPos = i
            break
        }
        i += 1
    }
    guard let ip = inPos else { return nil }

    let vname = trimASCII(String(decoding: bytes[0..<ip], as: UTF8.self))
    let rhs = trimASCII(String(decoding: bytes[(ip + 4)..<bytes.count], as: UTF8.self))

    // `0..<stop` or `start..<stop`
    if let rangePos = rhs.range(of: "..<") {
        let startStr = trimASCII(String(rhs[..<rangePos.lowerBound]))
        let stopStr = trimASCII(String(rhs[rangePos.upperBound...]))
        if startStr == "0" {
            return ("\(vname) in range(\(translateTokensSwiftToAgila(stopStr)))", vname)
        } else {
            return ("\(vname) in range(\(translateTokensSwiftToAgila(startStr)), \(translateTokensSwiftToAgila(stopStr)))", vname)
        }
    }

    // `stride(from: a, to: b, by: s)`
    if rhs.hasPrefix("stride(from:") && rhs.hasSuffix(")") {
        let inner = String(rhs.dropFirst(7).dropLast())
        if let fromR = inner.range(of: "from:"),
           let toR = inner.range(of: ", to:"),
           let byR = inner.range(of: ", by:") {
            let startStr = trimASCII(String(inner[fromR.upperBound..<toR.lowerBound]))
            let stopStr = trimASCII(String(inner[toR.upperBound..<byR.lowerBound]))
            let stepStr = trimASCII(String(inner[byR.upperBound...]))
            return ("\(vname) in range(\(translateTokensSwiftToAgila(startStr)), \(translateTokensSwiftToAgila(stopStr)), \(translateTokensSwiftToAgila(stepStr)))", vname)
        }
    }

    return ("\(vname) in \(translateTokensSwiftToAgila(rhs))", vname)
}

private func tryEmitSwiftFuncToAgila(_ s: String, isBlock: Bool) -> String? {
    var rest = trimASCII(s)
    var prefixQuals: [String] = []

    let quals = ["public", "private", "internal", "fileprivate", "open", "static", "class", "override", "mutating", "nonmutating", "final"]
    var changed = true
    while changed {
        changed = false
        for q in quals {
            if let after = startsWithKw(rest, q) {
                prefixQuals.append(q == "mutating" ? "mut" : q)
                rest = after
                changed = true
                break
            }
        }
    }

    var isInit = false
    var fnBody = ""
    if let fAfter = startsWithKw(rest, "func") {
        fnBody = fAfter
    } else if rest.hasPrefix("init(") {
        isInit = true
        fnBody = rest
    } else {
        return nil
    }

    let bytes = Array(fnBody.utf8)
    guard let lparenIdx = bytes.firstIndex(of: 0x28) else { return nil }
    let rparenIdx = findMatchingDelim(bytes, openIdx: lparenIdx, openCh: 0x28, closeCh: 0x29)
    if rparenIdx >= bytes.count { return nil }

    let fname = isInit ? "init" : trimASCII(String(decoding: bytes[0..<lparenIdx], as: UTF8.self))
    let rawParams = String(decoding: bytes[(lparenIdx + 1)..<rparenIdx], as: UTF8.self)
    var after = trimASCII(String(decoding: bytes[(rparenIdx + 1)..<bytes.count], as: UTF8.self))

    var effects = ""
    if after.hasPrefix("async throws") {
        effects = " async throws"
        after = trimASCII(String(after.dropFirst(12)))
    } else if after.hasPrefix("async") {
        effects = " async"
        after = trimASCII(String(after.dropFirst(5)))
    } else if after.hasPrefix("throws") {
        effects = " throws"
        after = trimASCII(String(after.dropFirst(6)))
    }

    var retPart = ""
    if after.hasPrefix("->") {
        let r = trimASCII(String(after.dropFirst(2)))
        if !r.isEmpty && r != "Void" && r != "()" {
            retPart = " -> " + translateTypeSwiftToAgila(r)
        }
    }

    let qualStr = prefixQuals.isEmpty ? "" : (prefixQuals.joined(separator: " ") + " ")
    let agParams = emitAgilaParamList(rawParams)
    return "\(qualStr)def \(fname)(\(agParams))\(effects)\(retPart)" + (isBlock ? ":" : "")
}

private func tryEmitSwiftVarDeclToAgila(_ s: String, atRootLevel: Bool) -> String? {
    var rest = trimASCII(s)
    var quals: [String] = []
    for q in ["public", "private", "internal", "static"] {
        if let after = startsWithKw(rest, q) {
            quals.append(q)
            rest = after
        }
    }

    var isVar = false
    var declBody = ""
    if let vAfter = startsWithKw(rest, "var") {
        isVar = true
        declBody = vAfter
    } else if let lAfter = startsWithKw(rest, "let") {
        isVar = false
        declBody = lAfter
    } else {
        return nil
    }

    let bytes = Array(declBody.utf8)
    var depth = 0
    var quote: UInt8 = 0
    var colonIdx: Int? = nil
    var eqIdx: Int? = nil

    var i = 0
    while i < bytes.count {
        let c = bytes[i]
        if quote != 0 {
            if c == 0x5C && i + 1 < bytes.count { i += 2; continue }
            if c == quote { quote = 0 }
            i += 1
            continue
        }
        if c == 0x22 || c == 0x27 { quote = c; i += 1; continue }
        if c == 0x28 || c == 0x5B || c == 0x7B || c == 0x3C { depth += 1 }
        else if c == 0x29 || c == 0x5D || c == 0x7D || c == 0x3E { depth -= 1 }
        else if depth == 0 {
            if colonIdx == nil && eqIdx == nil && c == 0x3A {
                colonIdx = i
            } else if eqIdx == nil && c == 0x3D {
                if i + 1 < bytes.count && bytes[i + 1] == 0x3D { i += 2; continue }
                eqIdx = i
                break
            }
        }
        i += 1
    }

    let qualPrefix = quals.isEmpty ? "" : (quals.joined(separator: " ") + " ")

    if let ci = colonIdx {
        let vname = trimASCII(String(decoding: bytes[0..<ci], as: UTF8.self))
        let varKw = isVar ? "var " : ""
        if let ei = eqIdx {
            let typeStr = trimASCII(String(decoding: bytes[(ci + 1)..<ei], as: UTF8.self))
            let valStr = trimASCII(String(decoding: bytes[(ei + 1)..<bytes.count], as: UTF8.self))
            return "\(qualPrefix)\(varKw)\(vname): \(translateTypeSwiftToAgila(typeStr)) = \(translateTokensSwiftToAgila(valStr))"
        } else {
            let typeStr = trimASCII(String(decoding: bytes[(ci + 1)..<bytes.count], as: UTF8.self))
            return "\(qualPrefix)\(vname): \(translateTypeSwiftToAgila(typeStr))"
        }
    } else if let ei = eqIdx {
        let vname = trimASCII(String(decoding: bytes[0..<ei], as: UTF8.self))
        let valStr = trimASCII(String(decoding: bytes[(ei + 1)..<bytes.count], as: UTF8.self))
        if !isVar && atRootLevel && quals.isEmpty {
            return "\(vname) = \(translateTokensSwiftToAgila(valStr))"
        }
        let varKw = isVar ? "var " : "const "
        return "\(qualPrefix)\(varKw)\(vname) = \(translateTokensSwiftToAgila(valStr))"
    }

    return nil
}

private func nextTrimmedSwiftLine(_ bytes: [UInt8], cursor: inout Int) -> String? {
    var p = cursor
    let len = bytes.count
    if p >= len { return nil }
    let ls = p
    while p < len && bytes[p] != 0x0A && bytes[p] != 0x0D { p += 1 }
    let le = p
    if p < len {
        if bytes[p] == 0x0D && p + 1 < len && bytes[p + 1] == 0x0A { p += 2 }
        else { p += 1 }
    }
    cursor = p
    return trimASCII(String(decoding: bytes[ls..<le], as: UTF8.self))
}

// Fold Swift container init + loop back into an Agila list/set/dict comprehension
private func tryEmitSwiftComprehensionToAgila(
    declLine: String,
    srcBytes: [UInt8],
    cursor: inout Int
) -> String? {
    let trimmed = trimASCII(declLine)
    guard let vAfter = startsWithKw(trimmed, "var") else { return nil }
    guard let colonIdx = vAfter.firstIndex(of: ":"),
          let eqIdx = vAfter.lastIndex(of: "="), colonIdx < eqIdx else { return nil }

    let varName = trimASCII(String(vAfter[..<colonIdx]))
    let typePart = trimASCII(String(vAfter[vAfter.index(after: colonIdx)..<eqIdx]))
    let initPart = trimASCII(String(vAfter[vAfter.index(after: eqIdx)...]))

    let kind: CompKind
    if initPart == "[]" {
        kind = .list
    } else if initPart == "Set()" {
        kind = .set
    } else if initPart == "[:]" {
        kind = .dict
    } else {
        return nil
    }

    var scanP = cursor
    guard let forLine = nextTrimmedSwiftLine(srcBytes, cursor: &scanP),
          forLine.hasSuffix("{"),
          let forAfter = startsWithKw(String(forLine.dropLast()), "for"),
          let (agilaFor, _) = tryConvertSwiftForHeader(forAfter) else {
        return nil
    }

    guard let line2 = nextTrimmedSwiftLine(srcBytes, cursor: &scanP), !line2.isEmpty else {
        return nil
    }

    var ifCond: String? = nil
    var stmtLine = line2

    if line2.hasSuffix("{"), let ifAfter = startsWithKw(String(line2.dropLast()), "if") {
        ifCond = trimASCII(ifAfter)
        guard let sLine = nextTrimmedSwiftLine(srcBytes, cursor: &scanP), !sLine.isEmpty else {
            return nil
        }
        stmtLine = sLine
    }

    if ifCond != nil {
        guard let closeIf = nextTrimmedSwiftLine(srcBytes, cursor: &scanP), closeIf == "}" else {
            return nil
        }
    }
    guard let closeFor = nextTrimmedSwiftLine(srcBytes, cursor: &scanP), closeFor == "}" else {
        return nil
    }

    if !stmtLine.hasPrefix(varName) { return nil }
    let afterVar = trimASCII(String(stmtLine.dropFirst(varName.count)))

    var keyStr = ""
    var elemStr = ""
    switch kind {
    case .list:
        guard afterVar.hasPrefix(".append(") && afterVar.hasSuffix(")") else { return nil }
        elemStr = trimASCII(String(afterVar.dropFirst(8).dropLast()))
    case .set:
        guard afterVar.hasPrefix(".insert(") && afterVar.hasSuffix(")") else { return nil }
        elemStr = trimASCII(String(afterVar.dropFirst(8).dropLast()))
    case .dict:
        let ab = Array(afterVar.utf8)
        guard ab.first == 0x5B else { return nil }
        let closeB = findMatchingDelim(ab, openIdx: 0, openCh: 0x5B, closeCh: 0x5D)
        guard closeB > 1 && closeB + 1 < ab.count else { return nil }
        keyStr = trimASCII(String(decoding: ab[1..<closeB], as: UTF8.self))
        let rest = trimASCII(String(decoding: ab[(closeB + 1)..<ab.count], as: UTF8.self))
        guard rest.hasPrefix("=") && !rest.hasPrefix("==") else { return nil }
        elemStr = trimASCII(String(rest.dropFirst()))
    }

    if elemStr.isEmpty { return nil }

    let openBr = (kind == .list) ? "[" : "{"
    let closeBr = (kind == .list) ? "]" : "}"
    var comp = "\(varName): \(translateTypeSwiftToAgila(typePart)) = \(openBr)"
    if kind == .dict {
        comp += "\(translateTokensSwiftToAgila(keyStr)): "
    }
    comp += "\(translateTokensSwiftToAgila(elemStr)) for \(agilaFor)"
    if let cond = ifCond {
        comp += " if \(translateTokensSwiftToAgila(cond))"
    }
    comp += closeBr

    cursor = scanP
    return comp
}

public func agilaFromSwift(_ src: String, indentUnit: String = "    ") throws -> String {
    if !validIndentUnit(indentUnit) {
        throw AgilaError("invalid indent unit", line: 1, col: 1)
    }

    let bytes = Array(src.utf8)
    let len = bytes.count
    var out = ""
    out.reserveCapacity(len + 128)

    var depth = 0
    var inCaseBody = false
    var caseSwitchDepth = 0
    var enumDepths: [Int] = []

    var p = 0
    while p < len {
        let ls = p
        while p < len && bytes[p] != 0x0A && bytes[p] != 0x0D { p += 1 }
        let le = p
        if p < len {
            if bytes[p] == 0x0D && p + 1 < len && bytes[p + 1] == 0x0A { p += 2 }
            else { p += 1 }
        }

        let rawLine = trimASCII(String(decoding: bytes[ls..<le], as: UTF8.self))
        if rawLine.isEmpty {
            out += "\n"
            continue
        }

        // Full-line comment `// ...` -> `# ...`
        if rawLine.hasPrefix("//") {
            let effDepth = depth + (inCaseBody ? 1 : 0)
            out += String(repeating: indentUnit, count: effDepth) + "#" + String(rawLine.dropFirst(2)) + "\n"
            continue
        }

        // Split trailing `//` comment outside string literals
        let lb = Array(rawLine.utf8)
        var codeStr = rawLine
        var inlineComment: String? = nil
        var quote: UInt8 = 0
        var i = 0
        while i + 1 < lb.count {
            let c = lb[i]
            if quote != 0 {
                if c == 0x5C { i += 2; continue }
                if c == quote { quote = 0 }
                i += 1
                continue
            }
            if c == 0x22 || c == 0x27 { quote = c; i += 1; continue }
            if c == 0x2F && lb[i + 1] == 0x2F {
                codeStr = trimASCII(String(decoding: lb[0..<i], as: UTF8.self))
                inlineComment = String(decoding: lb[(i + 2)..<lb.count], as: UTF8.self)
                break
            }
            i += 1
        }

        // Handle leading `}`
        if codeStr.hasPrefix("}") {
            if inCaseBody && depth == caseSwitchDepth {
                inCaseBody = false
            }
            if depth > 0 { depth -= 1 }
            if let lastEnum = enumDepths.last, lastEnum == depth {
                enumDepths.removeLast()
            }
            let rest = trimASCII(String(codeStr.dropFirst()))
            if rest.isEmpty || rest == ";" {
                continue
            }
            codeStr = rest
        }

        let inEnum = (enumDepths.last == depth - 1 && depth > 0)

        // Inside `switch`, handle `case ...:` or `default:`
        if !inEnum && ((startsWithKw(codeStr, "case") != nil && codeStr.hasSuffix(":")) || codeStr == "default:") {
            inCaseBody = false
            out += String(repeating: indentUnit, count: depth) + translateTokensSwiftToAgila(codeStr)
            if let ic = inlineComment { out += " #" + ic }
            out += "\n"
            inCaseBody = true
            caseSwitchDepth = depth
            continue
        }

        let effDepth = depth + (inCaseBody ? 1 : 0)
        let ind = String(repeating: indentUnit, count: effDepth)

        // Block opening `{`
        if codeStr.hasSuffix("{") {
            let header = trimASCII(String(codeStr.dropLast()))

            if let elifCond = startsWithKw(header, "else if") {
                out += ind + "elif " + translateTokensSwiftToAgila(elifCond) + ":"
            } else if header == "else" {
                out += ind + "else:"
            } else if let ifCond = startsWithKw(header, "if") {
                out += ind + "if " + translateTokensSwiftToAgila(ifCond) + ":"
            } else if var guardCond = startsWithKw(header, "guard") {
                if guardCond.hasSuffix(" else") {
                    guardCond = trimASCII(String(guardCond.dropLast(5)))
                }
                out += ind + "guard " + translateTokensSwiftToAgila(guardCond) + ":"
            } else if let whileCond = startsWithKw(header, "while") {
                out += ind + "while " + translateTokensSwiftToAgila(whileCond) + ":"
            } else if header == "repeat" {
                out += ind + "do:"
            } else if header == "do" {
                out += ind + "try:"
            } else if header == "defer" {
                out += ind + "defer:"
            } else if let catchRest = startsWithKw(header, "catch") {
                if catchRest.isEmpty {
                    out += ind + "catch:"
                } else {
                    out += ind + "catch " + translateTokensSwiftToAgila(catchRest) + ":"
                }
            } else if let forCond = startsWithKw(header, "for") {
                if let (agilaFor, _) = tryConvertSwiftForHeader(forCond) {
                    out += ind + "for " + agilaFor + ":"
                } else {
                    out += ind + "for " + translateTokensSwiftToAgila(forCond) + ":"
                }
            } else if let swCond = startsWithKw(header, "switch") {
                out += ind + "switch " + translateTokensSwiftToAgila(swCond) + ":"
            } else if let enumRest = startsWithKw(header, "enum") {
                enumDepths.append(depth)
                if let colonIdx = enumRest.firstIndex(of: ":") {
                    let ename = trimASCII(String(enumRest[..<colonIdx]))
                    let rawT = trimASCII(String(enumRest[enumRest.index(after: colonIdx)...]))
                    out += ind + "enum \(ename)(\(translateTypeSwiftToAgila(rawT))):"
                } else {
                    out += ind + "enum " + translateTokensSwiftToAgila(enumRest) + ":"
                }
            } else if startsWithKw(header, "struct") != nil ||
                      startsWithKw(header, "class") != nil ||
                      startsWithKw(header, "actor") != nil ||
                      startsWithKw(header, "protocol") != nil ||
                      startsWithKw(header, "extension") != nil {
                if let colonIdx = header.firstIndex(of: ":") {
                    let pre = trimASCII(String(header[..<colonIdx]))
                    let base = trimASCII(String(header[header.index(after: colonIdx)...]))
                    out += ind + "\(translateTokensSwiftToAgila(pre))(\(translateTypeSwiftToAgila(base))):"
                } else {
                    out += ind + translateTokensSwiftToAgila(header) + ":"
                }
            } else if let fnLine = tryEmitSwiftFuncToAgila(header, isBlock: true) {
                out += ind + fnLine
            } else {
                out += ind + translateTokensSwiftToAgila(header) + ":"
            }

            if let ic = inlineComment { out += " #" + ic }
            out += "\n"
            depth += 1
            continue
        }

        // Strip optional trailing `;`
        if codeStr.hasSuffix(";") {
            codeStr = trimASCII(String(codeStr.dropLast()))
        }

        if inEnum, let caseAfter = startsWithKw(codeStr, "case") {
            out += ind + translateTokensSwiftToAgila(caseAfter)
        } else if let typeRest = startsWithKw(codeStr, "typealias"), let eqIdx = typeRest.firstIndex(of: "=") {
            let aliasName = trimASCII(String(typeRest[..<eqIdx]))
            let targetType = trimASCII(String(typeRest[typeRest.index(after: eqIdx)...]))
            out += ind + "type \(aliasName) = \(translateTypeSwiftToAgila(targetType))"
        } else if let fnProto = tryEmitSwiftFuncToAgila(codeStr, isBlock: false) {
            out += ind + fnProto
        } else if inlineComment == nil, let compLine = tryEmitSwiftComprehensionToAgila(declLine: codeStr, srcBytes: bytes, cursor: &p) {
            out += ind + compLine
        } else if let varDecl = tryEmitSwiftVarDeclToAgila(codeStr, atRootLevel: effDepth == 0) {
            out += ind + varDecl
        } else {
            out += ind + translateTokensSwiftToAgila(codeStr)
        }

        if let ic = inlineComment { out += " #" + ic }
        out += "\n"
    }

    return out
}

public func agilaFormat(_ src: String, indentUnit: String = "    ") throws -> String {
    let swiftCode = try agilaToSwift(src)
    return try agilaFromSwift(swiftCode, indentUnit: indentUnit)
}

// -------------------------------------------------------------------------
// Standalone CLI, Conformance Tests, and Benchmark
// -------------------------------------------------------------------------

private func monotonicSec() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) * 1e-9
}

private func runTests() -> Int32 {
    let agilaCases: [String] = [
        """
        import Foundation
        MAX_ITEMS = 64

        struct Point:
            x: f64
            y: f64

        def move_x(p: ref[Point], dx: f64):
            p.x += dx

        def clamp(val: i32, lo: i32, hi: i32) -> i32:
            if val < lo:
                return lo
            elif val > hi:
                return hi
            else:
                return val

        def main():
            var pt: Point = Point(x: f64(1), y: 0.0)
            move_x(pt.ref, 2.5)
            raw: any = pt
            moved: Point = cast(Point, raw)
            var total: i32 = 0
            for i in range(10):
                if i == 5 and not (total < 0):
                    total += clamp(i, 0, i32(MAX_ITEMS))
            print(f"total={total} x={moved.x}")
        """ + "\n",

        // Tab-indented with switch/case, pointers, multi-level deref val(level, ptr), and enum
        "import Foundation\n" +
        "enum Status(i32):\n" +
        "\tOK = 0\n" +
        "\tERR = 1\n" +
        "def check(argv: addr[addr[i32]], out_code: addr[mut i32], code: i32) -> bool:\n" +
        "\tif val(2, argv) == 0 or code != 0:\n" +
        "\t\tval(out_code) = 1\n" +
        "\t\treturn false\n" +
        "\tswitch code:\n" +
        "\t\tcase 0:\n" +
        "\t\t\tval(out_code) = 0\n" +
        "\t\t\treturn true\n" +
        "\t\tdefault:\n" +
        "\t\t\treturn false\n",

        // List, set, and dict comprehensions
        """
        import Foundation

        def test_comprehensions() -> i32:
            squares: list[i32] = [i * i for i in range(8)]
            evens: set[i32] = {i for i in range(16) if i % 2 == 0}
            table: dict[i32, i32] = {i: i * 10 for i in range(8) if i > 0}
            vec: list[i32] = [x * 2 for x in squares if x > 0]
            uniq: set[i32] = {x for x in vec}
            mapping: dict[i32, i32] = {x: x + 1 for x in uniq if x < 100}
            return squares[3] + vec[0]
        """ + "\n"
    ]

    let indents = ["  ", "    ", "\t"]
    var passed = 0

    for (i, tc) in agilaCases.enumerated() {
        for u in indents {
            do {
                let sw1 = try agilaToSwift(tc)
                let ag = try agilaFromSwift(sw1, indentUnit: u)
                let sw2 = try agilaToSwift(ag)
                if sw1 != sw2 {
                    fputs("FAIL [case \(i) roundtrip mismatch]\n--- Expected Swift ---\n\(sw1)--- Got Swift ---\n\(sw2)", stderr)
                    return 1
                }
                passed += 1
            } catch let err as AgilaError {
                fputs("FAIL [case \(i)]: \(err.message) (line \(err.line))\n", stderr)
                return 1
            } catch {
                fputs("FAIL [case \(i)]: \(error)\n", stderr)
                return 1
            }
        }
    }

    // Universal newlines test (\r\n and \r)
    do {
        let crlfSrc = "def add(a: i32, b: i32) -> i32:\r\n    return a + b\r"
        let swOut = try agilaToSwift(crlfSrc)
        let expected = "func add(_ a: Int32, _ b: Int32) -> Int32 {\n    return a + b\n}\n"
        if swOut != expected {
            fputs("FAIL [universal_newlines output]:\nGot:\n\(swOut)Expected:\n\(expected)", stderr)
            return 1
        }
        passed += 1
    } catch {
        fputs("FAIL [universal_newlines]: \(error)\n", stderr)
        return 1
    }

    // Extended Pythonic syntax test
    do {
        let pyAgila = """
        import Foundation

        def test_py():
            doc: str = \"""hello
        world\"""
            nums: list[isize] = [
                x + y
                for x in range(3)
                for y in range(2)
                if x + y > 0
            ]
            var inc = lambda x: isize -> isize: x + 1
            tag: str = "big" if 2 in nums and 9 not in nums else "small"
            var opt: isize? = nil
            ok: bool = 0 < nums[0] < 10 and not 1 == 2 and opt is nil
            fv: isize = -7 // 2
            pv: isize = 2 ** 3
            last_v: isize = nums[-1]
            sl: list[isize] = nums[1:3]
            msg: str = f'tag={tag} {3.14159:.2f}'
            print(doc.count + inc(1) + fv + pv + last_v + sl.count + (ok ? 1 : 0) + msg.count)
        """
        let swOut = try agilaToSwift(pyAgila)
        if !swOut.contains("_agilaFloorDiv") || !swOut.contains("_agilaPow") || !swOut.contains("_agilaIn") {
            fputs("FAIL [extended_pythonic]:\n\(swOut)", stderr)
            return 1
        }
        passed += 1
    } catch {
        fputs("FAIL [extended_pythonic]: \(error)\n", stderr)
        return 1
    }

    // Exact comprehension Swift codegen & bidirectional round-trip test
    do {
        let compAgila =
            "def demo():\n" +
            "    squares: list[i32] = [i * i for i in range(8)]\n" +
            "    evens: set[i32] = {i for i in range(16) if i % 2 == 0}\n" +
            "    table: dict[i32, i32] = {i: i * 10 for i in range(8) if i > 0}\n" +
            "    vec: list[i32] = [x * 2 for x in squares if x > 0]\n" +
            "    uniq: set[i32] = {x for x in vec}\n" +
            "    mapping: dict[i32, i32] = {x: x + 1 for x in uniq if x < 100}\n"
        let expectedSwift =
            "func demo() {\n" +
            "    var squares: [Int32] = []\n" +
            "    for i in 0..<8 {\n" +
            "        squares.append(i * i)\n" +
            "    }\n" +
            "    var evens: Set<Int32> = Set()\n" +
            "    for i in 0..<16 {\n" +
            "        if i % 2 == 0 {\n" +
            "            evens.insert(i)\n" +
            "        }\n" +
            "    }\n" +
            "    var table: [Int32: Int32] = [:]\n" +
            "    for i in 0..<8 {\n" +
            "        if i > 0 {\n" +
            "            table[i] = i * 10\n" +
            "        }\n" +
            "    }\n" +
            "    var vec: [Int32] = []\n" +
            "    for x in squares {\n" +
            "        if x > 0 {\n" +
            "            vec.append(x * 2)\n" +
            "        }\n" +
            "    }\n" +
            "    var uniq: Set<Int32> = Set()\n" +
            "    for x in vec {\n" +
            "        uniq.insert(x)\n" +
            "    }\n" +
            "    var mapping: [Int32: Int32] = [:]\n" +
            "    for x in uniq {\n" +
            "        if x < 100 {\n" +
            "            mapping[x] = x + 1\n" +
            "        }\n" +
            "    }\n" +
            "}\n"

        let swOut = try agilaToSwift(compAgila)
        if swOut != expectedSwift {
            fputs("FAIL [comprehensions Swift output]\n--- Expected ---\n\(expectedSwift)--- Got ---\n\(swOut)", stderr)
            return 1
        }
        let agOut = try agilaFromSwift(swOut, indentUnit: "    ")
        if agOut != compAgila {
            fputs("FAIL [comprehensions Agila roundtrip]\n--- Expected ---\n\(compAgila)--- Got ---\n\(agOut)", stderr)
            return 1
        }
        passed += 1
    } catch {
        fputs("FAIL [comprehensions]: \(error)\n", stderr)
        return 1
    }

    // Invalid syntax tests
    let invalidCases = [
        "    x: i32 = 1\n",                        // Unexpected root indent
        "def foo():\n    x: i32 = 1\n  y: i32 = 2\n", // Inconsistent indent multiple
        "def foo():\n\tx: i32 = 1\n    y: i32 = 2\n", // Mixed tab and space lines
        "def foo():\n \tx: i32 = 1\n",             // Mixed space+tab on same line
        "def dangling():\n",                       // Dangling block header at EOF
        "def dangling():\nx: i32 = 1\n",           // Missing indent after ':'
        "x: i32 = 1   \n"                          // Trailing whitespace
    ]
    for (i, inv) in invalidCases.enumerated() {
        if (try? agilaToSwift(inv)) != nil {
            fputs("FAIL [invalid \(i) accepted]: \(inv)\n", stderr)
            return 1
        }
        passed += 1
    }

    print("Swift Agila: all \(passed) conformance tests passed.")
    return 0
}

private func runBench(_ path: String?) -> Int32 {
    let ag4Sample: String
    if let p = path {
        guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
            fputs("agila error: cannot read '\(p)'\n", stderr)
            return 1
        }
        ag4Sample = s
    } else {
        var b = "import Foundation\n\n" +
                "struct Node:\n" +
                "    id: i32\n" +
                "    weight: f64\n" +
                "    active: bool\n" +
                "    label: str\n\n"
        for i in 0..<250 {
            b += "def compute_layer_\(i)(n: list[Node], count: i32, threshold: f64) -> f64:\n" +
                 "    var acc: f64 = 0.0\n" +
                 "    for i in range(count):\n" +
                 "        if n[Int(i)].active and n[Int(i)].weight > threshold:\n" +
                 "            acc += n[Int(i)].weight * 1.25\n" +
                 "        elif not n[Int(i)].active or n[Int(i)].id == \(i):\n" +
                 "            acc -= 0.5\n" +
                 "        else:\n" +
                 "            acc += 0.1\n" +
                 "    return acc\n\n"
        }
        ag4Sample = b
    }

    guard let swSample = try? agilaToSwift(ag4Sample),
          let agTabSample = try? agilaFromSwift(swSample, indentUnit: "\t") else {
        fputs("agila bench error: failed to transpile sample\n", stderr)
        return 1
    }

    let ag4Len = ag4Sample.utf8.count
    let swLen = swSample.utf8.count
    let agTabLen = agTabSample.utf8.count

    let iters = 200
    var t0 = monotonicSec()
    for _ in 0..<iters {
        _ = try? agilaToSwift(ag4Sample)
    }
    let dtAg4 = monotonicSec() - t0

    t0 = monotonicSec()
    for _ in 0..<iters {
        _ = try? agilaToSwift(agTabSample)
    }
    let dtTab = monotonicSec() - t0

    t0 = monotonicSec()
    for _ in 0..<iters {
        _ = try? agilaFromSwift(swSample, indentUnit: "    ")
    }
    let dtFromSw = monotonicSec() - t0

    let mibAg4 = (Double(ag4Len * iters) / (1024.0 * 1024.0)) / dtAg4
    let mibTab = (Double(agTabLen * iters) / (1024.0 * 1024.0)) / dtTab
    let mibFromSw = (Double(swLen * iters) / (1024.0 * 1024.0)) / dtFromSw

    let pct4 = 100.0 * Double(ag4Len - swLen) / Double(swLen)
    let pctTab = 100.0 * Double(agTabLen - swLen) / Double(swLen)

    print("Agila Benchmark (250 functions, \(iters) iterations):")
    print(String(format: "  Swift source size      : %d bytes (%.1f KiB)", swLen, Double(swLen) / 1024.0))
    print(String(format: "  Agila 4-space size     : %d bytes (%.1f KiB, %+.1f%% vs Swift)", ag4Len, Double(ag4Len) / 1024.0, pct4))
    print(String(format: "  Agila tab (\\t) size    : %d bytes (%.1f KiB, %+.1f%% vs Swift)", agTabLen, Double(agTabLen) / 1024.0, pctTab))
    print(String(format: "  Agila (4-sp) -> Swift  : %.0f files/s (%.1f MiB/s)", Double(iters) / dtAg4, mibAg4))
    print(String(format: "  Agila (tab)  -> Swift  : %.0f files/s (%.1f MiB/s)", Double(iters) / dtTab, mibTab))
    print(String(format: "  Swift -> Agila (4-sp)  : %.0f files/s (%.1f MiB/s)", Double(iters) / dtFromSw, mibFromSw))
    return 0
}

private func printUsage(_ prog: String) {
    let msg = """
    Usage:
      \(prog) <file.agila>                        Transpile Agila to Swift on stdout
      \(prog) --agila [--indent <N|tab>] <f>      Format/canonicalize Agila
      \(prog) --from-swift [--indent <N|tab>] <f> Convert Swift source to Agila
      \(prog) --compile <file.agila> [-o <bin>]   Transpile and compile via swiftc
      \(prog) --run <file.agila>                  Transpile, compile, and execute immediately
      \(prog) --check <file.agila>                Validate Agila syntax only
      \(prog) --test                              Run built-in conformance test suite
      \(prog) --bench [file.agila]                Run transpilation throughput benchmark
    """
    fputs(msg + "\n", stderr)
}

private func runProcess(_ executable: String, _ args: [String]) -> Int32 {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = args
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    } catch {
        fputs("agila error: failed to launch \(executable): \(error)\n", stderr)
        return 1
    }
}

private func mainCLI() -> Int32 {
    let args = CommandLine.arguments
    if args.count < 2 {
        printUsage(args[0])
        return 1
    }

    var modeAgila = false
    var modeFromSwift = false
    var modeCheck = false
    var modeCompile = false
    var modeRun = false
    var indentOpt = "    "
    var inputPath: String? = nil
    var outputBin: String? = nil

    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--test" {
            return runTests()
        } else if arg == "--bench" {
            let bpath = (i + 1 < args.count && !args[i + 1].hasPrefix("-")) ? args[i + 1] : nil
            return runBench(bpath)
        } else if arg == "--agila" {
            modeAgila = true
        } else if arg == "--from-swift" {
            modeFromSwift = true
        } else if arg == "--check" {
            modeCheck = true
        } else if arg == "--compile" {
            modeCompile = true
        } else if arg == "--run" {
            modeRun = true
        } else if arg == "-o" && i + 1 < args.count {
            i += 1
            outputBin = args[i]
        } else if arg == "--indent" && i + 1 < args.count {
            i += 1
            let val = args[i]
            if val == "tab" || val == "\\t" {
                indentOpt = "\t"
            } else if let n = Int(val), n >= 1 && n <= 63 {
                indentOpt = String(repeating: " ", count: n)
            } else {
                fputs("agila error: --indent must be 1..63 or 'tab'\n", stderr)
                return 1
            }
        } else if arg == "--help" || arg == "-h" {
            printUsage(args[0])
            return 0
        } else if arg == "-" || !arg.hasPrefix("-") {
            inputPath = arg
        } else {
            fputs("agila error: unknown option '\(arg)'\n", stderr)
            return 1
        }
        i += 1
    }

    guard let path = inputPath else {
        fputs("agila error: missing input file\n", stderr)
        return 1
    }

    let src: String
    if path == "-" {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        src = String(decoding: data, as: UTF8.self)
    } else {
        guard let loaded = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("agila error: cannot read '\(path)'\n", stderr)
            return 1
        }
        src = loaded
    }

    do {
        if modeFromSwift {
            let ag = try agilaFromSwift(src, indentUnit: indentOpt)
            FileHandle.standardOutput.write(Data(ag.utf8))
            return 0
        }

        if modeAgila {
            let ag = try agilaFormat(src, indentUnit: indentOpt)
            FileHandle.standardOutput.write(Data(ag.utf8))
            return 0
        }

        var swiftCode = try agilaToSwift(src)
        if modeCheck {
            return 0
        }

        if modeCompile || modeRun {
            // If file defines `func main(` at top-level, append `main()` call for Swift script/executable compilation
            if swiftCode.contains("\nfunc main(") || swiftCode.hasPrefix("func main(") {
                if !swiftCode.hasSuffix("\nmain()\n") {
                    swiftCode += "\nmain()\n"
                }
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let tmpSwift = "/tmp/agila_\(pid).swift"
            try swiftCode.write(toFile: tmpSwift, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: tmpSwift) }

            let binPath = outputBin ?? (modeRun ? "/tmp/agila_bin_\(pid)" : "a.out")
            let rc = runProcess("/usr/bin/env", ["swiftc", "-O", tmpSwift, "-o", binPath])
            if rc != 0 { return 1 }

            if modeRun {
                let runRc = runProcess(binPath, [])
                if outputBin == nil {
                    try? FileManager.default.removeItem(atPath: binPath)
                }
                return runRc == 0 ? 0 : 1
            }
            return 0
        }

        FileHandle.standardOutput.write(Data(swiftCode.utf8))
        return 0
    } catch let err as AgilaError {
        fputs("agila error:\(err.line):\(err.col): \(err.message)\n", stderr)
        return 1
    } catch {
        fputs("agila error: \(error)\n", stderr)
        return 1
    }
}

exit(mainCLI())
