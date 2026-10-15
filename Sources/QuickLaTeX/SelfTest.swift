import Foundation

/// `QuickLaTeX --self-test`: checks the body classification (MathBody.swift) and line mapping. Exit 0 = all passed.
enum SelfTest {
    private struct Case {
        var name: String
        var source: String
        var mode: RenderMode = .display
        var kind: BodyKind
        var expectedSource: String? = nil          // nil: the source must come back unchanged
    }

    static func run() -> Int32 {
        let bs = "\\"            // one backslash, to keep the cases readable
        let cases: [Case] = [
            // --- the five reported failures ------------------------------------------------
            Case(name: "comment before \\begin{align*}",
                 source: "% comment\n\(bs)begin{align*}\na &= b \(bs)\(bs) c &= d\n\(bs)end{align*}", kind: .envText),
            Case(name: "& and \\\\ without environment -> align*",
                 source: "a &= b \(bs)\(bs) c &= d", kind: .align),
            Case(name: "\\\\ only -> gather*",
                 source: "x = 1 \(bs)\(bs) y = 2", kind: .gather),
            Case(name: "inline mode with align* -> display handling",
                 source: "\(bs)begin{align*} a &= b \(bs)\(bs) c &= d \(bs)end{align*}", mode: .inline, kind: .envText),
            Case(name: "numbered align -> starred",
                 source: "\(bs)begin{align}\na &= b \(bs)\(bs)\nc &= d\n\(bs)end{align}", kind: .envText,
                 expectedSource: "\(bs)begin{align*}\na &= b \(bs)\(bs)\nc &= d\n\(bs)end{align*}"),
            // --- must stay $\displaystyle ---------------------------------------------------
            Case(name: "pmatrix stays display",
                 source: "\(bs)begin{pmatrix} a & b \(bs)\(bs) c & d \(bs)end{pmatrix}", kind: .display),
            Case(name: "cases stays display",
                 source: "\(bs)begin{cases} x & (x>0) \(bs)\(bs) -x & (x<0)\(bs)end{cases}", kind: .display),
            Case(name: "aligned inside \\left\\{ stays display",
                 source: "f(x) = \(bs)left\(bs){ \(bs)begin{aligned} a &= b \(bs)\(bs) c &= d \(bs)end{aligned} \(bs)right.", kind: .display),
            Case(name: "\\& stays display", source: "a \(bs)& b", kind: .display),
            Case(name: "& inside braces stays display", source: "\(bs)text{a & b} + \(bs)substack{x \(bs)\(bs) y}", kind: .display),
            Case(name: "plain formula", source: "x^2", kind: .display),
            Case(name: "plain formula inline", source: "x^2", mode: .inline, kind: .inline),
            Case(name: "display env inside a comment is ignored",
                 source: "% \(bs)begin{align}\nx^2", kind: .display),
            Case(name: "escaped percent is not a comment",
                 source: "100\(bs)% \(bs)\(bs) x", kind: .gather),
            // --- \\[2pt], \[ ... \], $$ ------------------------------------------------------
            Case(name: "\\\\[2pt] spacing arg counts as a break",
                 source: "a &= b \(bs)\(bs)[2pt] c &= d", kind: .align),
            Case(name: "\\[ ... \\]", source: "\(bs)[ a = b \(bs)]", kind: .envText),
            Case(name: "$$ ... $$", source: "$$ a = b $$", kind: .envText),
            Case(name: "& inside \\[ ... \\] is not top level on its own", source: "\(bs)[ a &= b \(bs)]", kind: .envText),
            // --- numbered conversion ---------------------------------------------------------
            Case(name: "equation -> equation*",
                 source: "\(bs)begin{equation}\nx\n\(bs)end{equation}", kind: .envText,
                 expectedSource: "\(bs)begin{equation*}\nx\n\(bs)end{equation*}"),
            Case(name: "empheq inner {align} -> {align*}",
                 source: "\(bs)begin{empheq}[box=\(bs)fbox]{align} E &= mc^2 \(bs)end{empheq}", kind: .envText,
                 expectedSource: "\(bs)begin{empheq}[box=\(bs)fbox]{align*} E &= mc^2 \(bs)end{empheq}"),
            Case(name: "empheq with already starred inner is untouched",
                 source: "\(bs)begin{empheq}{align*} E &= mc^2 \(bs)end{empheq}", kind: .envText),
            Case(name: "two top-level envs are both converted",
                 source: "\(bs)begin{gather}a\(bs)end{gather}\n\(bs)begin{multline}b\(bs)end{multline}", kind: .envText,
                 expectedSource: "\(bs)begin{gather*}a\(bs)end{gather*}\n\(bs)begin{multline*}b\(bs)end{multline*}"),
            Case(name: "nested align inside subequations is literal",
                 source: "\(bs)begin{subequations}\n\(bs)begin{align}\na &= b\n\(bs)end{align}\n\(bs)end{subequations}", kind: .envText),
            Case(name: "starred env is untouched",
                 source: "\(bs)begin{align*} a &= b \(bs)end{align*}", kind: .envText),
            // --- テキスト mode stays literal --------------------------------------------------
            Case(name: "text mode keeps numbered align literal",
                 source: "\(bs)begin{align}\na &= b\n\(bs)end{align}", mode: .text, kind: .text),
            Case(name: "text mode with & and \\\\ is untouched",
                 source: "a & b \(bs)\(bs) c", mode: .text, kind: .text),
            // --- blank lines ------------------------------------------------------------------
            Case(name: "blank line inside align* becomes a comment (envText)",
                 source: "\(bs)begin{align*}\na &= b \(bs)\(bs)\n\nc &= d\n\(bs)end{align*}", kind: .envText,
                 expectedSource: "\(bs)begin{align*}\na &= b \(bs)\(bs)\n%\nc &= d\n\(bs)end{align*}"),
            Case(name: "blank line between top-level envs stays literal (paragraph break)",
                 source: "\(bs)begin{align*}a\(bs)end{align*}\n\n\(bs)begin{align*}b\(bs)end{align*}", kind: .envText),
            Case(name: "blank line in math becomes a comment",
                 source: "a +\n\nb", kind: .display, expectedSource: "a +\n%\nb"),
        ]

        var failures = 0
        func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail())") }
        }

        for c in cases {
            let plan = BodyPlanner.plan(source: c.source, mode: c.mode)
            let expected = c.expectedSource ?? c.source.replacingOccurrences(
                of: "\n\n", with: "\n\n")        // unchanged unless a case says otherwise
            check(plan.kind == c.kind, c.name, "kind \(plan.kind) != \(c.kind)")
            check(plan.sourceLines.joined(separator: "\n") == expected, c.name + " (source)",
                  "\n  got:      \(plan.sourceLines.joined(separator: "\\n"))\n  expected: \(expected.replacingOccurrences(of: "\n", with: "\\n"))")
            check(plan.sourceLines.count == c.source.components(separatedBy: "\n").count, c.name + " (line count preserved)")

            // Line mapping: the source must sit exactly where DocumentParts says it does.
            let parts = DocumentParts(input: RenderInput(source: c.source, mode: c.mode, colorHex: "000000",
                                                         preamble: "\(bs)usepackage{amsmath}", texBinPath: ""))
            let start = parts.srcStartInBody - 1
            let slice = Array(parts.bodyLines[start..<start + parts.srcLineCount])
            check(slice == plan.sourceLines, c.name + " (line mapping)")
            if case .source(let k) = parts.locate(docLine: parts.srcStartInBody, usedFormat: true) {
                check(k == 1, c.name + " (first source line = 1)")
            } else {
                check(false, c.name + " (locate)")
            }
        }

        // Wrapper structure, spelled out once.
        let align = DocumentParts(input: RenderInput(source: "a &= b", mode: .display, colorHex: "000000",
                                                     preamble: "", texBinPath: ""))
        check(Array(align.bodyLines[2...]) == ["\(bs)begin{varwidth}{16cm}", "\(bs)begin{align*}", "a &= b",
                                                "\(bs)end{align*}", "\(bs)end{varwidth}", "\(bs)end{document}"],
              "align* body layout", "\(align.bodyLines)")

        // Error inside an amsmath body: TeX reports the \end line with an <argument> context; we map it back.
        let errParts = DocumentParts(input: RenderInput(source: "a &= b \(bs)\(bs)\nc &= \(bs)fracc{1}{2}\nd &= e", mode: .display,
                                                        colorHex: "000000", preamble: "", texBinPath: ""))
        let log = "./job.tex:9: Undefined control sequence.\n<argument>  a &= b \(bs)\(bs) c &= \(bs)fracc \n                          {1}{2} d &= e \nl.9 \(bs)end{align*}\n"
        let failure = TeXLog.parse(log: log, parts: errParts, usedFormat: true)
        check(failure?.line == 2 && failure?.region == "source" && failure?.message == "Undefined control sequence.",
              "<argument> error mapped to the offending source line", "\(String(describing: failure))")
        let plainLog = "./job.tex:4: Undefined control sequence.\nl.4 \(bs)fracc\n          {1}{2}\n"
        let plain = TeXLog.parse(log: plainLog, parts: DocumentParts(input: RenderInput(source: "\(bs)fracc{1}{2}", mode: .display,
                                 colorHex: "000000", preamble: "", texBinPath: "")), usedFormat: true)
        check(plain?.line == 1 && plain?.context == "l.1 \(bs)fracc{1}{2}", "plain error keeps TeX's own line mapping", "\(String(describing: plain))")

        print(failures == 0 ? "\nself-test: all passed" : "\nself-test: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}
