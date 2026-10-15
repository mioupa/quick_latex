import Foundation
import AppKit

/// Headless renderer (used for automated testing and by the VS Code extension):
///
///   QuickLaTeX (--render <src> | --source-file <path>) [--mode display|inline|text] [--color RRGGBB]
///              [--size 20] [--padding 2] [--preamble-file <path>] [--out <path.pdf>] [--png <path.png>]
///              [--svg <path.svg>] [--copy] [--copy-svg] [--json]
///   QuickLaTeX --print-preamble-path      (creates the shared preamble file if missing, prints its path)
enum CLI {
    static let usage = """
    usage: QuickLaTeX (--render <src> | --source-file <path>) [--mode display|inline|text] [--color RRGGBB] \
    [--size 20] [--padding 2] [--preamble-file <path>] [--out <path.pdf>] [--png <path.png>] \
    [--svg <path.svg>] [--copy] [--copy-svg] [--json]
    """

    /// Flags that make the binary run as a CLI instead of the GUI.
    static let triggerFlags: Set<String> = ["--render", "--source-file", "--print-preamble-path", "--self-test"]

    // MARK: output helpers

    private static func write(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    private static func jsonNumber(_ d: Double) -> String {
        var s = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), d)
        while s.hasSuffix("0") && !s.hasSuffix(".0") { s.removeLast() }
        return s
    }

    private static func jsonOptional(_ s: String?) -> String { s.map(jsonString) ?? "null" }

    private static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    // MARK: entry

    static func run(_ args: [String]) -> Int32 {
        if args.contains("--self-test") { return SelfTest.run() }
        let json = args.contains("--json")

        func fail(_ f: RenderFailure, code: Int32 = 1) -> Int32 {
            if json {
                write("{\"ok\":false,\"message\":\(jsonString(f.message)),\"context\":\(jsonString(f.context)),"
                      + "\"line\":\(f.line.map(String.init) ?? "null"),\"region\":\(jsonOptional(f.region))}")
            } else {
                write("ERROR: \(f.formatted)")
            }
            return code
        }
        func usageError(_ message: String) -> Int32 {
            json ? fail(RenderFailure(message), code: 2) : { write("error: \(message)\n\(usage)"); return 2 }()
        }

        var src: String?
        var sourceFile: String?
        var preambleFile: String?
        var mode = RenderMode.display
        var colorHex = "000000"
        var size = AppSettings.defaultFontSize
        var padding = AppSettings.defaultPadding
        var outPDF: String?
        var outPNG: String?
        var outSVG: String?
        var copy = false
        var copySVG = false
        var printPreamblePath = false

        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--json": break
            case "--copy": copy = true
            case "--copy-svg": copySVG = true
            case "--print-preamble-path": printPreamblePath = true
            case "--render", "--source-file", "--preamble-file", "--mode", "--color", "--size", "--padding",
                 "--out", "--png", "--svg":
                guard let v = next() else { return usageError("\(flag) requires a value") }
                switch flag {
                case "--render": src = v
                case "--source-file": sourceFile = v
                case "--preamble-file": preambleFile = v
                case "--mode":
                    guard let m = RenderMode(rawValue: v) else { return usageError("invalid --mode \(v)") }
                    mode = m
                case "--color":
                    guard let h = HexColor.normalized(v) else { return usageError("invalid --color \(v)") }
                    colorHex = h
                case "--size":
                    guard let d = Double(v) else { return usageError("invalid --size \(v)") }
                    size = min(200, max(4, d))
                case "--padding":
                    guard let d = Double(v) else { return usageError("invalid --padding \(v)") }
                    padding = max(0, d)
                case "--out": outPDF = v
                case "--png": outPNG = v
                default: outSVG = v
                }
            default:
                return usageError("unknown argument \(flag)")
            }
            i += 1
        }

        if printPreamblePath {
            write(PreambleStore.ensureFile().path)
            return 0
        }

        let source: String
        switch (src, sourceFile) {
        case (.some, .some): return usageError("specify only one of --render and --source-file")
        case (.some(let s), nil): source = s
        case (nil, .some(let path)):
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) else {
                return fail(RenderFailure("ソースファイルを読み込めません: \(path)"), code: 2)
            }
            var text = String(decoding: d, as: UTF8.self)
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }   // keep leading lines: line numbers stay 1:1
            source = text
        case (nil, nil): return usageError("--render or --source-file is required")
        }
        if copy && copySVG { return usageError("--copy and --copy-svg cannot be combined (the pasteboard holds one of them)") }

        let preamble: String
        if let pf = preambleFile {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: (pf as NSString).expandingTildeInPath)) else {
                return fail(RenderFailure("プリアンブルファイルを読み込めません: \(pf)"), code: 2)
            }
            preamble = String(decoding: d, as: UTF8.self)
        } else {
            preamble = PreambleStore.load()
        }

        let input = RenderInput(source: source, mode: mode, colorHex: colorHex, preamble: preamble,
                                texBinPath: AppSettings.storedTeXBinPath)

        // Private job dir so a running GUI / other CLI runs are never disturbed; always removed on exit.
        let engine = TeXEngine.shared
        let fm = FileManager.default
        removeStaleJobDirs()
        let jobDir = TeXPaths.cacheDir.appendingPathComponent("job-cli-\(getpid())", isDirectory: true)
        try? fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        engine.jobDir = jobDir
        defer { try? fm.removeItem(at: jobDir) }

        // The VS Code extension kills superseded renders with SIGTERM: stop the TeX child and clean up.
        signal(SIGTERM, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler {
            engine.killCurrent()
            try? fm.removeItem(at: jobDir)
            exit(143)
        }
        termSource.resume()
        defer { termSource.cancel() }

        let t0 = Date()
        let gen = engine.supersede()
        let rendered: RenderResult
        switch engine.renderRaw(input, gen: gen) {
        case .success(let r): rendered = r
        case .failure(let f): return fail(f)
        case .cancelled: return fail(RenderFailure("cancelled"))
        }

        // Let a pending background format rebuild (after a format fallback) finish before the process exits.
        engine.queue.sync {}

        let t1 = Date()
        let finalData: Data
        let privatePDF = jobDir.appendingPathComponent("final.pdf")   // never touch the GUI's cache/equation.pdf
        do {
            finalData = try PDFProcessing.finalize(raw: rendered.raw, fontSize: size, padding: padding)
            try finalData.write(to: privatePDF, options: .atomic)
            if let p = outPDF { try finalData.write(to: URL(fileURLWithPath: absolute(p)), options: .atomic) }
        } catch {
            return fail(RenderFailure((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        }
        let fin = Date().timeIntervalSince(t1)

        var png: Data?
        if outPNG != nil || copy {
            do {
                let d = try PDFProcessing.pngData(fromPDF: finalData)
                png = d
                if let p = outPNG { try d.write(to: URL(fileURLWithPath: absolute(p)), options: .atomic) }
            } catch {
                return fail(RenderFailure((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }

        if copy, let png = png {
            PasteboardWriter.copyImage(pdf: finalData, png: png)
        }

        var svgSeconds: Double?
        if outSVG != nil || copySVG {
            guard let tools = TeXTools.discover(override: input.texBinPath) else {
                return fail(RenderFailure("SVG変換ツールが見つかりません"))
            }
            let ts = Date()
            switch SVGExporter.makeSVG(finalPDF: privatePDF, dvi: rendered.dviURL,
                                       fontSize: size, padding: padding, tools: tools) {
            case .success(let svg):
                if let p = outSVG {
                    do { try svg.write(to: URL(fileURLWithPath: absolute(p)), atomically: true, encoding: .utf8) }
                    catch { return fail(RenderFailure(error.localizedDescription)) }
                }
                if copySVG { PasteboardWriter.copySVG(svg) }
                svgSeconds = Date().timeIntervalSince(ts)
            case .failure(let e):
                return fail(RenderFailure(e.message))
            }
        }

        let outSize = PDFProcessing.outputSize(raw: rendered.raw, fontSize: size, padding: padding)
        let total = Date().timeIntervalSince(t0)

        if json {
            write("{\"ok\":true,\"seconds\":\(jsonNumber(total)),\"formatBuilt\":\(rendered.formatBuilt),"
                  + "\"width\":\(jsonNumber(Double(outSize.width))),\"height\":\(jsonNumber(Double(outSize.height))),"
                  + "\"pdf\":\(jsonOptional(outPDF.map(absolute))),\"png\":\(jsonOptional(outPNG.map(absolute))),"
                  + "\"svg\":\(jsonOptional(outSVG.map(absolute)))}")
        } else {
            let fmtInfo = rendered.usedFormat
                ? (rendered.formatBuilt ? String(format: "format=built(%.2fs)", rendered.formatSeconds) : "format=cached")
                : "format=none(full document)"
            let svgInfo = svgSeconds.map { String(format: " svg=%.2fs", $0) } ?? ""
            write(String(format: "OK tex=%.2fs crop=%.2fs total=%.2fs %@%@ size=%.1fx%.1fpt",
                         rendered.texSeconds, rendered.seconds - rendered.texSeconds + fin, total,
                         fmtInfo, svgInfo, outSize.width, outSize.height))
        }
        return 0
    }

    /// Leftovers of CLI runs that were killed (e.g. by a timeout in the caller).
    private static func removeStaleJobDirs() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: TeXPaths.cacheDir.path) else { return }
        for name in names where name.hasPrefix("job-cli-") {
            let url = TeXPaths.cacheDir.appendingPathComponent(name)
            let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let m = m, Date().timeIntervalSince(m) > 3600 { try? fm.removeItem(at: url) }
        }
    }
}
