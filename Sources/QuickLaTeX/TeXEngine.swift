import Foundation
import CryptoKit

// MARK: - Paths

enum TeXPaths {
    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        let dir = base.appendingPathComponent("QuickLaTeX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var fmtRoot: URL { cacheDir.appendingPathComponent("fmt", isDirectory: true) }
    static var defaultJobDir: URL { cacheDir.appendingPathComponent("job", isDirectory: true) }
    static var equationPDF: URL { cacheDir.appendingPathComponent("equation.pdf") }
    static var svgDir: URL { cacheDir.appendingPathComponent("svg", isDirectory: true) }
}

// MARK: - Tool discovery

struct TeXTools {
    var binDir: URL
    var uplatex: URL
    var dvipdfmx: URL
    var dvisvgm: URL?
    var pdftocairo: URL?

    private struct Cached { var tools: TeXTools? }
    private static let lock = NSLock()
    private static var cache: [String: Cached] = [:]

    static func discover(override: String) -> TeXTools? {
        let key = override.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if let c = cache[key] { lock.unlock(); return c.tools }
        lock.unlock()
        let found = findUncached(override: key)
        lock.lock()
        cache[key] = Cached(tools: found)
        lock.unlock()
        return found
    }

    private static func isExec(_ dir: String, _ name: String) -> URL? {
        let p = (dir as NSString).appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: p) ? URL(fileURLWithPath: p) : nil
    }

    private static func tools(in dir: String) -> TeXTools? {
        guard let up = isExec(dir, "uplatex"), let dv = isExec(dir, "dvipdfmx") else { return nil }
        var pc = isExec(dir, "pdftocairo")
        if pc == nil {
            for d in ["/opt/homebrew/bin", "/usr/local/bin"] {
                if let u = isExec(d, "pdftocairo") { pc = u; break }
            }
        }
        return TeXTools(binDir: URL(fileURLWithPath: dir, isDirectory: true), uplatex: up, dvipdfmx: dv,
                        dvisvgm: isExec(dir, "dvisvgm"), pdftocairo: pc)
    }

    private static func texliveDirs() -> [String] {
        let root = "/usr/local/texlive"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let years = names.compactMap { Int($0) }.sorted(by: >)
        var out: [String] = []
        for y in years {
            for arch in ["universal-darwin", "aarch64-darwin", "x86_64-darwin"] {
                let d = "\(root)/\(y)/bin/\(arch)"
                if FileManager.default.fileExists(atPath: d) { out.append(d) }
            }
        }
        return out
    }

    private static func findUncached(override: String) -> TeXTools? {
        if !override.isEmpty {
            var p = (override as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue {
                p = (p as NSString).deletingLastPathComponent
            }
            return tools(in: p)
        }
        let candidates = ["/Library/TeX/texbin"] + texliveDirs() + ["/usr/local/bin", "/opt/homebrew/bin"]
        for d in candidates {
            if let t = tools(in: d) { return t }
        }
        if let d = shellLookup() { return tools(in: d) }
        return nil
    }

    /// `$SHELL -l -c 'command -v uplatex'` (works in fish and zsh).
    private static func shellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "command -v uplatex"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: s) {
                return (s as NSString).deletingLastPathComponent
            }
        }
        return nil
    }
}

// MARK: - Document construction

struct DocumentParts {
    let headerLines: [String]        // \documentclass ... \usepackage{varwidth}
    let bodyLines: [String]          // \begin{document} ... \end{document}
    let userPreambleLineCount: Int
    let srcStartInBody: Int          // 1-based line of the first user source line within the body
    let srcLineCount: Int
    let sourceLines: [String]        // the user's lines as placed in the document (same count as the input)

    enum Location { case source(Int), preamble(Int), other }

    init(input: RenderInput) {
        let preamble = input.preamble
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var preLines = preamble.components(separatedBy: "\n")
        while let last = preLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { preLines.removeLast() }

        var header = ["\\documentclass[dvipdfmx,border={10pt 10pt 200pt 10pt}]{standalone}"]
        header += preLines
        header += ["\\usepackage{xcolor}", "\\usepackage{varwidth}"]

        let rgb = HexColor.parse(input.colorHex) ?? (0, 0, 0)
        let color = "\\definecolor{qlfg}{rgb}{\(HexColor.texComponent(rgb.r)),\(HexColor.texComponent(rgb.g)),\(HexColor.texComponent(rgb.b))}\\color{qlfg}%"

        let normalizedSource = input.source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let plan = BodyPlanner.plan(source: normalizedSource, mode: input.mode)

        var body = ["\\begin{document}", color]
        body += plan.prefix
        let srcStart = body.count + 1
        body += plan.sourceLines
        body += plan.suffix
        body.append("\\end{document}")

        self.headerLines = header
        self.bodyLines = body
        self.userPreambleLineCount = preLines.count
        self.srcStartInBody = srcStart
        self.srcLineCount = plan.sourceLines.count
        self.sourceLines = plan.sourceLines
    }

    var formatSource: String { (headerLines + ["\\dump"]).joined(separator: "\n") + "\n" }
    var jobDocument: String { bodyLines.joined(separator: "\n") + "\n" }
    var fullDocument: String { (headerLines + bodyLines).joined(separator: "\n") + "\n" }

    func locate(docLine: Int, usedFormat: Bool) -> Location {
        let offset = usedFormat ? 0 : headerLines.count
        let s = offset + srcStartInBody
        if docLine >= s && docLine < s + srcLineCount { return .source(docLine - s + 1) }
        if !usedFormat, docLine >= 2, docLine < 2 + userPreambleLineCount { return .preamble(docLine - 1) }
        return .other
    }
}

// MARK: - Log parsing

/// Structured failure. `formatted` is the GUI string ("行 N: message" + context lines).
struct RenderFailure {
    var message: String
    var contextLines: [String] = []
    var line: Int?            // 1-based, relative to `region`
    var region: String?       // "source" | "preamble"

    init(_ message: String, contextLines: [String] = [], line: Int? = nil, region: String? = nil) {
        self.message = message
        self.contextLines = contextLines
        self.line = line
        self.region = region
    }

    var prefix: String {
        guard let line = line, let region = region else { return "" }
        return region == "preamble" ? "プリアンブル 行 \(line): " : "行 \(line): "
    }

    var formatted: String { ([prefix + message] + contextLines).joined(separator: "\n") }

    /// "l.1 \fracc" + "          {1}{2}"  ->  "l.1 \fracc{1}{2}" (the second line is the rest of the source line).
    var context: String {
        guard let first = contextLines.first else { return "" }
        var out = first
        if contextLines.count > 1 {
            let rest = contextLines[1].drop(while: { $0 == " " || $0 == "\t" })
            out += rest
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

enum TeXLog {
    private static let fileLineRegex = try! NSRegularExpression(pattern: #"^(.+?):(\d+): (.*)$"#)
    private static let contextRegex = try! NSRegularExpression(pattern: #"^l\.(\d+)(.*)$"#)

    private static func contextLines(_ lines: [String], after i: Int) -> [String] {
        var ctx: [String] = []
        var j = i + 1
        while j < lines.count, ctx.count < 2 {
            let l = lines[j]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { break }
            ctx.append(l)
            j += 1
        }
        return ctx
    }

    private static func remap(context: [String], parts: DocumentParts, usedFormat: Bool) -> [String] {
        context.map { line in
            let ns = line as NSString
            guard let m = contextRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let n = Int(ns.substring(with: m.range(at: 1))) else { return line }
            switch parts.locate(docLine: n, usedFormat: usedFormat) {
            case .source(let k), .preamble(let k): return "l.\(k)" + ns.substring(with: m.range(at: 2))
            case .other: return line
            }
        }
    }

    private static func location(_ docLine: Int, parts: DocumentParts, usedFormat: Bool) -> (region: String, line: Int)? {
        switch parts.locate(docLine: docLine, usedFormat: usedFormat) {
        case .source(let k): return ("source", k)
        case .preamble(let k): return ("preamble", k)
        case .other: return nil
        }
    }

    /// For "File `foo.sty' not found" find where the user's preamble mentions it (the log only shows the next line).
    private static func missingFileLocation(message: String, parts: DocumentParts, usedFormat: Bool) -> (region: String, line: Int)? {
        guard !usedFormat,
              let r = message.range(of: #"File `([^']+)' not found"#, options: .regularExpression) else { return nil }
        let inner = message[r].dropFirst("File `".count).dropLast("' not found".count)
        let base = (String(inner) as NSString).deletingPathExtension
        guard !base.isEmpty else { return nil }
        let pre = parts.headerLines.dropFirst().prefix(parts.userPreambleLineCount)
        for (idx, l) in pre.enumerated() where l.contains(base) && !l.trimmingCharacters(in: .whitespaces).hasPrefix("%") {
            return ("preamble", idx + 1)
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var backslashes = 0
        for (i, ch) in line.enumerated() {
            if ch == "\\" { backslashes += 1; continue }
            if ch == "%", backslashes % 2 == 0 { return String(line.prefix(i)) }
            backslashes = 0
        }
        return line
    }

    /// Inside amsmath environments (align*, gather*, ...) TeX reads the whole body as an argument, so the error is
    /// reported at the \end line with an "<argument> ..." context. Locate the offending text in the user's source
    /// instead (the first context line ends exactly where the error happened).
    private static func refineArgumentError(_ f: RenderFailure, parts: DocumentParts) -> RenderFailure {
        guard let first = f.contextLines.first, first.hasPrefix("<argument>") else { return f }
        func collapse(_ s: String) -> String {
            var out = ""
            for ch in s { if ch.isWhitespace { if out.last != " " { out.append(" ") } } else { out.append(ch) } }
            return out
        }
        var needle = collapse(String(first.dropFirst("<argument>".count))).trimmingCharacters(in: .whitespaces)
        if needle.hasPrefix("...") { needle = String(needle.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        guard needle.count >= 2 else { return f }

        var hay: [Character] = []
        var lineOf: [Int] = []
        for (idx, raw) in parts.sourceLines.enumerated() {
            for ch in stripComment(raw) {
                if ch.isWhitespace {
                    if hay.last != " " { hay.append(" "); lineOf.append(idx + 1) }
                } else {
                    hay.append(ch); lineOf.append(idx + 1)
                }
            }
            if hay.last != " " { hay.append(" "); lineOf.append(idx + 1) }
        }
        let text = String(hay)
        guard let r = text.range(of: needle, options: .literal) else { return f }
        let endIndex = text.distance(from: text.startIndex, to: r.upperBound) - 1
        guard endIndex >= 0, endIndex < lineOf.count else { return f }
        let k = lineOf[endIndex]
        var g = f
        g.line = k
        g.region = "source"
        g.contextLines = ["l.\(k) " + parts.sourceLines[k - 1]]
        return g
    }

    /// Returns the structured error, or nil if the log has no recognisable error.
    static func parse(log: String, parts: DocumentParts, usedFormat: Bool) -> RenderFailure? {
        guard let f = parseRaw(log: log, parts: parts, usedFormat: usedFormat) else { return nil }
        return refineArgumentError(f, parts: parts)
    }

    private static func parseRaw(log: String, parts: DocumentParts, usedFormat: Bool) -> RenderFailure? {
        let lines = log.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")

        func fileLineMatch(_ line: String) -> (file: String, docLine: Int, message: String)? {
            let ns = line as NSString
            guard let m = fileLineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let docLine = Int(ns.substring(with: m.range(at: 2))) else { return nil }
            return (ns.substring(with: m.range(at: 1)), docLine, ns.substring(with: m.range(at: 3)))
        }
        let flIndex = lines.firstIndex { fileLineMatch($0) != nil }
        let bangIndex = lines.firstIndex { $0.hasPrefix("! ") }

        // 1. -file-line-error style: "./job.tex:5: Undefined control sequence."
        //    (unless a "! " error precedes it, e.g. a missing .sty followed by "Emergency stop")
        if let i = flIndex, bangIndex == nil || i < bangIndex! {
            let hit = fileLineMatch(lines[i])!
            let ctx = remap(context: contextLines(lines, after: i), parts: parts, usedFormat: usedFormat)
            let loc = hit.file.hasSuffix("job.tex") ? location(hit.docLine, parts: parts, usedFormat: usedFormat) : nil
            return RenderFailure(hit.message, contextLines: ctx, line: loc?.line, region: loc?.region)
        }

        // 2. classic "! Message" style.
        if let i = bangIndex {
            let message = String(lines[i].dropFirst(2))
            let rawCtx = contextLines(lines, after: i)
            var loc = missingFileLocation(message: message, parts: parts, usedFormat: usedFormat)
            if loc == nil {
                for c in rawCtx {
                    let ns = c as NSString
                    if let m = contextRegex.firstMatch(in: c, range: NSRange(location: 0, length: ns.length)),
                       let n = Int(ns.substring(with: m.range(at: 1))) {
                        loc = location(n, parts: parts, usedFormat: usedFormat)
                        break
                    }
                }
            }
            let ctx = remap(context: rawCtx, parts: parts, usedFormat: usedFormat)
            return RenderFailure(message, contextLines: ctx, line: loc?.line, region: loc?.region)
        }
        return nil
    }
}

// MARK: - Engine

struct RenderResult {
    var raw: RawRender
    var dviURL: URL
    var seconds: Double          // total (TeX + analysis)
    var texSeconds: Double
    var usedFormat: Bool
    var formatBuilt: Bool
    var formatSeconds: Double
}

enum RenderOutcome {
    case success(RenderResult)
    case failure(RenderFailure)
    case cancelled
}

enum ProcOutcome {
    case exited(Int32)
    case timedOut
    case cancelled
    case launchFailed(String)
}

private final class Flag {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class TeXEngine {
    static let shared = TeXEngine()

    /// Single serial queue for format builds and compiles.
    let queue = DispatchQueue(label: "local.quicklatex.tex", qos: .userInitiated)
    var jobDir: URL = TeXPaths.defaultJobDir

    private let lock = NSLock()
    private var generation = 0
    private var current: Process?
    private var currentCancellable = false
    private var failedFormats = Set<String>()

    // MARK: cancellation

    /// Supersede everything queued/running: bumps the generation and terminates a running cancellable process.
    @discardableResult
    func supersede() -> Int {
        lock.lock()
        generation += 1
        let g = generation
        let p = currentCancellable ? current : nil
        lock.unlock()
        if let p = p, p.isRunning { p.terminate() }
        return g
    }

    /// Terminate whatever child is running right now (used when the CLI itself is told to stop).
    func killCurrent() {
        lock.lock()
        let p = current
        lock.unlock()
        if let p = p, p.isRunning { p.terminate() }
    }

    func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    // MARK: process running

    func environment(for tools: TeXTools) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(tools.binDir.path):/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// stdin = /dev/null, stdout/stderr discarded (we read the .log instead). 15 s timeout.
    func runProcess(_ exe: URL, _ args: [String], cwd: URL, tools: TeXTools,
                    gen: Int?, timeout: TimeInterval = 15) -> ProcOutcome {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = environment(for: tools)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }

        lock.lock()
        if let g = gen, g != generation { lock.unlock(); return .cancelled }
        do { try p.run() } catch {
            lock.unlock()
            return .launchFailed("\(exe.lastPathComponent) を起動できません: \(error.localizedDescription)")
        }
        current = p
        currentCancellable = (gen != nil)
        lock.unlock()

        let timedOut = Flag()
        let timer = DispatchWorkItem { if p.isRunning { timedOut.set(); p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        sem.wait()
        timer.cancel()

        lock.lock()
        current = nil
        currentCancellable = false
        let stale = (gen != nil && gen != generation)
        lock.unlock()

        if timedOut.isSet { return .timedOut }
        if stale { return .cancelled }
        return .exited(p.terminationStatus)
    }

    // MARK: format

    private func formatHash(_ parts: DocumentParts, tools: TeXTools) -> String {
        let digest = SHA256.hash(data: Data((parts.formatSource + tools.uplatex.path).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isFormatFailed(_ hash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failedFormats.contains(hash)
    }
    private func markFormat(_ hash: String, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if failed { failedFormats.insert(hash) } else { failedFormats.remove(hash) }
    }

    /// Remove formats for other preambles and stale temp dirs; temp dirs younger than 60 s belong to a
    /// build that may still be running in another process and are left alone.
    private func cleanupFormats(keeping hash: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: TeXPaths.fmtRoot.path) else { return }
        for name in names where name != hash {
            let url = TeXPaths.fmtRoot.appendingPathComponent(name)
            if name.contains(".tmp-") {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let date = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date)
                if let d = date, Date().timeIntervalSince(d) < 60 { continue }
            }
            try? fm.removeItem(at: url)
        }
    }

    /// Build the precompiled format for the given preamble; returns the .fmt URL or nil on failure.
    /// The format is dumped into `fmt/<hash>.tmp-<pid>-<rand>/` and renamed to `fmt/<hash>/` so that several
    /// processes (GUI + CLI runs) can build concurrently. If the final dir already exists the temp build is
    /// discarded, unless `replacing` is set (the existing format is known to be bad).
    @discardableResult
    func buildFormat(parts: DocumentParts, tools: TeXTools, replacing: Bool = false) -> URL? {
        let fm = FileManager.default
        let hash = formatHash(parts, tools: tools)
        let finalDir = TeXPaths.fmtRoot.appendingPathComponent(hash, isDirectory: true)
        let finalFmt = finalDir.appendingPathComponent("ql.fmt")
        try? fm.createDirectory(at: TeXPaths.fmtRoot, withIntermediateDirectories: true)
        cleanupFormats(keeping: hash)
        if !replacing, fm.fileExists(atPath: finalFmt.path) { return finalFmt }

        let tmpName = "\(hash).tmp-\(getpid())-\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
        let tmpDir = TeXPaths.fmtRoot.appendingPathComponent(tmpName, isDirectory: true)
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try parts.formatSource.write(to: tmpDir.appendingPathComponent("ql_pre.tex"), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: tmpDir)
            markFormat(hash, failed: true)
            return nil
        }
        let outcome = runProcess(tools.uplatex,
                                 ["-ini", "-interaction=nonstopmode", "-halt-on-error", "-jobname=ql", "&uplatex", "ql_pre.tex"],
                                 cwd: tmpDir, tools: tools, gen: nil)
        guard case .exited(0) = outcome, fm.fileExists(atPath: tmpDir.appendingPathComponent("ql.fmt").path) else {
            try? fm.removeItem(at: tmpDir)
            markFormat(hash, failed: true)
            return nil
        }

        if fm.fileExists(atPath: finalDir.path) {
            if replacing {
                try? fm.removeItem(at: finalDir)
            } else {
                try? fm.removeItem(at: tmpDir)           // another process finished first
                if fm.fileExists(atPath: finalFmt.path) { markFormat(hash, failed: false); return finalFmt }
            }
        }
        do {
            try fm.moveItem(at: tmpDir, to: finalDir)
        } catch {
            try? fm.removeItem(at: tmpDir)               // lost the rename race: use the winner's format
            if fm.fileExists(atPath: finalFmt.path) { markFormat(hash, failed: false); return finalFmt }
            markFormat(hash, failed: true)
            return nil
        }
        markFormat(hash, failed: false)
        return finalFmt
    }

    private func existingFormat(parts: DocumentParts, tools: TeXTools) -> URL? {
        let hash = formatHash(parts, tools: tools)
        let fmt = TeXPaths.fmtRoot.appendingPathComponent(hash).appendingPathComponent("ql.fmt")
        return FileManager.default.fileExists(atPath: fmt.path) ? fmt : nil
    }

    /// Warm-up entry point (startup / preamble change). Runs on the serial queue.
    func prepareFormat(preamble: String, texBinPath: String) {
        queue.async { [self] in
            guard let tools = TeXTools.discover(override: texBinPath) else { return }
            let input = RenderInput(source: "", mode: .display, colorHex: "000000", preamble: preamble, texBinPath: texBinPath)
            let parts = DocumentParts(input: input)
            if existingFormat(parts: parts, tools: tools) != nil { return }
            if isFormatFailed(formatHash(parts, tools: tools)) { return }
            buildFormat(parts: parts, tools: tools)
        }
    }

    // MARK: compile

    private enum JobResult {
        case ok
        case cancelled
        case failed(log: String?, message: String, timedOut: Bool)
    }

    private func runJob(parts: DocumentParts, tools: TeXTools, fmt: URL?, gen: Int) -> JobResult {
        let fm = FileManager.default
        try? fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        for ext in ["log", "dvi", "pdf", "aux"] {
            try? fm.removeItem(at: jobDir.appendingPathComponent("job.\(ext)"))
        }
        let doc = (fmt != nil) ? parts.jobDocument : parts.fullDocument
        do {
            try doc.write(to: jobDir.appendingPathComponent("job.tex"), atomically: true, encoding: .utf8)
        } catch {
            return .failed(log: nil, message: "作業ファイルを書き込めません: \(error.localizedDescription)", timedOut: false)
        }
        var args = ["-interaction=nonstopmode", "-halt-on-error", "-file-line-error"]
        if let fmt = fmt { args.append("-fmt=\(fmt.path)") }
        args.append("job.tex")

        let logURL = jobDir.appendingPathComponent("job.log")
        let dviURL = jobDir.appendingPathComponent("job.dvi")
        let pdfURL = jobDir.appendingPathComponent("job.pdf")

        switch runProcess(tools.uplatex, args, cwd: jobDir, tools: tools, gen: gen) {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .failed(log: nil, message: "TeXの実行がタイムアウトしました（15秒）", timedOut: true)
        case .launchFailed(let m):
            return .failed(log: nil, message: m, timedOut: false)
        case .exited(let status):
            let log: String? = (try? Data(contentsOf: logURL)).map { String(decoding: $0, as: UTF8.self) }
            if status != 0 {
                return .failed(log: log, message: "uplatex が異常終了しました（終了コード \(status)）", timedOut: false)
            }
            guard fm.fileExists(atPath: dviURL.path) else {
                return .failed(log: log, message: "出力が空です", timedOut: false)
            }
        }

        switch runProcess(tools.dvipdfmx, ["-q", "-o", "job.pdf", "job.dvi"], cwd: jobDir, tools: tools, gen: gen) {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .failed(log: nil, message: "dvipdfmx がタイムアウトしました（15秒）", timedOut: true)
        case .launchFailed(let m):
            return .failed(log: nil, message: m, timedOut: false)
        case .exited(let status):
            if status != 0 || !fm.fileExists(atPath: pdfURL.path) {
                return .failed(log: nil, message: "dvipdfmx の実行に失敗しました（終了コード \(status)）", timedOut: false)
            }
        }
        return .ok
    }

    private func failureInfo(_ log: String?, fallback: String, parts: DocumentParts, usedFormat: Bool) -> RenderFailure {
        if let log = log, let parsed = TeXLog.parse(log: log, parts: parts, usedFormat: usedFormat) { return parsed }
        return RenderFailure(fallback)
    }

    /// Compile to job.pdf and analyse (crop box). Must be called on `queue` (or synchronously from the CLI).
    func renderRaw(_ input: RenderInput, gen: Int) -> RenderOutcome {
        guard let tools = TeXTools.discover(override: input.texBinPath) else {
            return .failure(RenderFailure("uplatex が見つかりません。設定（歯車）で TeX bin のパスを指定してください。"))
        }
        let t0 = Date()
        let parts = DocumentParts(input: input)

        // Format: reuse, build, or skip (when a previous build failed).
        var fmt = existingFormat(parts: parts, tools: tools)
        var formatBuilt = false
        var formatSeconds = 0.0
        if fmt == nil, !isFormatFailed(formatHash(parts, tools: tools)) {
            let tf = Date()
            fmt = buildFormat(parts: parts, tools: tools)
            formatBuilt = (fmt != nil)
            formatSeconds = Date().timeIntervalSince(tf)
        }
        if !isCurrent(gen) { return .cancelled }

        var usedFormat = fmt != nil
        var result = runJob(parts: parts, tools: tools, fmt: fmt, gen: gen)
        var rebuildFormat = false

        if usedFormat, case .failed(let log, _, let timedOut) = result, !timedOut {
            let needsRetry = (log == nil)
                || log!.contains("Fatal format file error")
                || TeXLog.parse(log: log!, parts: parts, usedFormat: true) == nil
            if needsRetry {
                usedFormat = false
                let retry = runJob(parts: parts, tools: tools, fmt: nil, gen: gen)
                if case .ok = retry { rebuildFormat = true }
                result = retry
            }
        }

        switch result {
        case .cancelled:
            return .cancelled
        case .failed(let log, let message, _):
            return .failure(failureInfo(log, fallback: message, parts: parts, usedFormat: usedFormat))
        case .ok:
            break
        }

        if rebuildFormat {
            // The format misbehaved while the full document compiled fine: rebuild it in the background.
            let hash = formatHash(parts, tools: tools)
            markFormat(hash, failed: false)
            queue.async { [self] in
                buildFormat(parts: parts, tools: tools, replacing: true)
            }
        }
        let texSeconds = Date().timeIntervalSince(t0)

        let fm = FileManager.default
        let pdfURL = jobDir.appendingPathComponent("job.pdf")
        let keepDVI = jobDir.appendingPathComponent("last.dvi")
        try? fm.removeItem(at: keepDVI)
        try? fm.copyItem(at: jobDir.appendingPathComponent("job.dvi"), to: keepDVI)

        guard let data = try? Data(contentsOf: pdfURL) else { return .failure(RenderFailure("PDFを読み込めません")) }
        do {
            let raw = try PDFProcessing.analyze(pdfData: data)
            return .success(RenderResult(raw: raw, dviURL: keepDVI,
                                         seconds: Date().timeIntervalSince(t0), texSeconds: texSeconds,
                                         usedFormat: usedFormat, formatBuilt: formatBuilt, formatSeconds: formatSeconds))
        } catch {
            return .failure(RenderFailure((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
    }
}
