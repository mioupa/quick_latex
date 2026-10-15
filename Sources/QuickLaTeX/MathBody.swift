import Foundation

// Decides how the user's source is wrapped into the TeX body (shared by the GUI and the CLI).
//
// 数式 (display):
//   * a display environment / \[ / $$ at top level (any position)  -> テキスト body (varwidth), source kept literal,
//     numbered environments are converted to their starred form (no equation numbers);
//   * else `&` or `\\` at top level                                -> varwidth + align* (if `&`) / gather*;
//   * else                                                         -> $\displaystyle ... $
// インライン: same as 数式 when one of the above is detected, otherwise $ ... $.
// テキスト: always literal in varwidth.
//
// "Top level" = not inside any \begin..\end, not inside {...}, not inside \[ ... \]. Comments (`%` not preceded
// by an odd number of backslashes) are ignored. Source lines are never added or removed: replacements are in-line.

enum BodyKind: String {
    case inline          // $ ... $
    case display         // $\displaystyle ... $
    case text            // varwidth, literal (explicit テキスト mode)
    case envText         // varwidth, auto-detected display env / \[ / $$ (numbered envs starred)
    case align           // varwidth + align*
    case gather          // varwidth + gather*
}

struct BodyPlan {
    var kind: BodyKind
    var prefix: [String]
    var suffix: [String]
    var sourceLines: [String]
}

struct MathScan {
    var hasTopDisplayEnv = false
    var hasTopBracket = false       // \[ at top level
    var hasTopDollars = false       // $$ at top level
    var hasTopAmp = false
    var hasTopBreak = false
    /// In-line replacements: scalar index range of an environment name -> starred name.
    var starReplacements: [(range: Range<Int>, name: String)] = []
    /// For each source line: does it start inside an environment / braces / \[ ... \]?
    var nestedAtLineStart: [Bool] = [false]

    var wantsDisplayHandling: Bool {
        hasTopDisplayEnv || hasTopBracket || hasTopDollars || hasTopAmp || hasTopBreak
    }
}

enum MathScanner {
    static let numberedEnvs: Set<String> = ["equation", "align", "gather", "multline", "flalign", "alignat", "eqnarray"]
    static let displayEnvs: Set<String> = {
        var s = Set<String>()
        for e in numberedEnvs { s.insert(e); s.insert(e + "*") }
        s.insert("empheq")
        s.insert("subequations")
        return s
    }()

    private static func isLetter(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "A" && u <= "Z") || u == "@"
    }

    private static func string(_ s: [Unicode.Scalar], _ r: Range<Int>) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s[r])
        return String(v)
    }

    /// `{name}` starting at `i` (after optional blanks). Returns the name range and the index after `}`.
    private static func braced(_ s: [Unicode.Scalar], from i: Int, skipNewlines: Bool = false) -> (name: Range<Int>, end: Int)? {
        var k = i
        while k < s.count, s[k] == " " || s[k] == "\t" || (skipNewlines && s[k] == "\n") { k += 1 }
        guard k < s.count, s[k] == "{" else { return nil }
        var j = k + 1
        while j < s.count, s[j] != "}", s[j] != "\n", s[j] != "{" { j += 1 }
        guard j < s.count, s[j] == "}" else { return nil }
        return (k + 1..<j, j + 1)
    }

    /// For `\begin{empheq}[opts]{X}`: the `{X}` argument following the begin token.
    private static func empheqInner(_ s: [Unicode.Scalar], from i: Int) -> (name: Range<Int>, end: Int)? {
        var k = i
        while k < s.count, s[k] == " " || s[k] == "\t" || s[k] == "\n" { k += 1 }
        if k < s.count, s[k] == "[" {
            var depth = 0
            k += 1
            while k < s.count {
                if s[k] == "{" { depth += 1 }
                else if s[k] == "}" { depth = max(0, depth - 1) }
                else if s[k] == "]", depth == 0 { break }
                k += 1
            }
            guard k < s.count else { return nil }
            k += 1
        }
        return braced(s, from: k, skipNewlines: true)
    }

    static func scan(_ s: [Unicode.Scalar]) -> MathScan {
        var r = MathScan()
        let n = s.count
        var i = 0
        var envStack: [String] = []
        var braceDepth = 0
        var bracketDepth = 0
        func isTop() -> Bool { envStack.isEmpty && braceDepth == 0 && bracketDepth == 0 }

        while i < n {
            let c = s[i]
            switch c {
            case "\n":
                r.nestedAtLineStart.append(!isTop())
                i += 1
            case "%":
                while i < n, s[i] != "\n" { i += 1 }
            case "{":
                braceDepth += 1
                i += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
                i += 1
            case "&":
                if isTop() { r.hasTopAmp = true }
                i += 1
            case "$":
                if i + 1 < n, s[i + 1] == "$" {
                    if isTop() { r.hasTopDollars = true }
                    i += 2
                } else {
                    i += 1
                }
            case "\\":
                guard i + 1 < n else { i += 1; break }
                let d = s[i + 1]
                if isLetter(d) {
                    var j = i + 1
                    while j < n, isLetter(s[j]) { j += 1 }
                    let name = string(s, i + 1..<j)
                    if name == "begin" || name == "end", let arg = braced(s, from: j) {
                        let env = string(s, arg.name)
                        if name == "begin" {
                            if isTop() {
                                if displayEnvs.contains(env) { r.hasTopDisplayEnv = true }
                                if numberedEnvs.contains(env) {
                                    r.starReplacements.append((arg.name, env + "*"))
                                } else if env == "empheq", let inner = empheqInner(s, from: arg.end) {
                                    let innerName = string(s, inner.name)
                                    if numberedEnvs.contains(innerName) {
                                        r.starReplacements.append((inner.name, innerName + "*"))
                                    }
                                }
                            }
                            envStack.append(env)
                        } else if let last = envStack.last {
                            if envStack.count == 1, braceDepth == 0, bracketDepth == 0,
                               last == env, numberedEnvs.contains(env) {
                                r.starReplacements.append((arg.name, env + "*"))
                            }
                            envStack.removeLast()
                        }
                        i = arg.end
                    } else {
                        i = j
                    }
                } else if d == "\\" {
                    if isTop() { r.hasTopBreak = true }
                    i += 2
                } else if d == "[" {
                    if isTop() { r.hasTopBracket = true }
                    bracketDepth += 1
                    i += 2
                } else if d == "]" {
                    bracketDepth = max(0, bracketDepth - 1)
                    i += 2
                } else {
                    i += 2      // \& \{ \} \$ \% \, \; ...
                }
            default:
                i += 1
            }
        }
        return r
    }
}

enum BodyPlanner {
    private static let beginVarwidth = "\\begin{varwidth}{16cm}"
    private static let endVarwidth = "\\end{varwidth}"

    /// `source` must already have normalised "\n" line endings.
    static func plan(source: String, mode: RenderMode) -> BodyPlan {
        let lines = source.components(separatedBy: "\n")
        if mode == .text {
            return BodyPlan(kind: .text, prefix: [beginVarwidth], suffix: [endVarwidth], sourceLines: lines)
        }

        let scalars = Array(source.unicodeScalars)
        let scan = MathScanner.scan(scalars)
        func blankToComment(_ ls: [String], onlyNested: Bool) -> [String] {
            ls.enumerated().map { idx, l in
                guard l.trimmingCharacters(in: .whitespaces).isEmpty else { return l }
                if onlyNested && !(idx < scan.nestedAtLineStart.count && scan.nestedAtLineStart[idx]) { return l }
                return "%"      // a blank line (\par) is an error inside math / environments
            }
        }

        guard scan.wantsDisplayHandling else {
            let cleaned = blankToComment(lines, onlyNested: false)
            return mode == .inline
                ? BodyPlan(kind: .inline, prefix: ["$"], suffix: ["$"], sourceLines: cleaned)
                : BodyPlan(kind: .display, prefix: ["$\\displaystyle"], suffix: ["$"], sourceLines: cleaned)
        }

        if scan.hasTopDisplayEnv || scan.hasTopBracket || scan.hasTopDollars {
            var converted = scalars
            for rep in scan.starReplacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                converted.replaceSubrange(rep.range, with: Array(rep.name.unicodeScalars))
            }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: converted)
            let convertedLines = String(v).components(separatedBy: "\n")
            return BodyPlan(kind: .envText, prefix: [beginVarwidth], suffix: [endVarwidth],
                            sourceLines: blankToComment(convertedLines, onlyNested: true))
        }

        let cleaned = blankToComment(lines, onlyNested: false)
        if scan.hasTopAmp {
            return BodyPlan(kind: .align, prefix: [beginVarwidth, "\\begin{align*}"],
                            suffix: ["\\end{align*}", endVarwidth], sourceLines: cleaned)
        }
        return BodyPlan(kind: .gather, prefix: [beginVarwidth, "\\begin{gather*}"],
                        suffix: ["\\end{gather*}", endVarwidth], sourceLines: cleaned)
    }
}
