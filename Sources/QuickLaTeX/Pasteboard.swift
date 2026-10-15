import AppKit
import UniformTypeIdentifiers

enum PasteboardWriter {
    /// PDF + PNG on a single pasteboard item.
    static func copyImage(pdf: Data, png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(pdf, forType: .pdf)
        item.setData(png, forType: .png)
        pb.writeObjects([item])
    }

    /// SVG as public.svg-image data and as plain text.
    static func copySVG(_ svg: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data(svg.utf8), forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
        item.setString(svg, forType: .string)
        pb.writeObjects([item])
    }
}

enum SVGExporter {
    /// pdftocairo when available (fast, Japanese stays as paths); otherwise dvisvgm (slow, no Japanese fonts).
    static func makeSVG(finalPDF: URL, dvi: URL, fontSize: Double, padding: Double,
                        tools: TeXTools) -> Result<String, QLError> {
        let fm = FileManager.default
        try? fm.createDirectory(at: TeXPaths.svgDir, withIntermediateDirectories: true)
        // Unique per call: the GUI and several CLI runs may export SVG at the same time.
        let out = TeXPaths.svgDir.appendingPathComponent("out-\(getpid())-\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).svg")
        defer { try? fm.removeItem(at: out) }
        let engine = TeXEngine.shared
        let scale = fontSize / 10
        let forceDvisvgm = ProcessInfo.processInfo.environment["QL_FORCE_DVISVGM"] == "1"

        let outcome: ProcOutcome
        let toolName: String
        if let pc = tools.pdftocairo, !forceDvisvgm {
            toolName = "pdftocairo"
            outcome = engine.runProcess(pc, ["-svg", finalPDF.path, out.path],
                                        cwd: TeXPaths.svgDir, tools: tools, gen: nil, timeout: 20)
        } else if let ds = tools.dvisvgm {
            toolName = "dvisvgm"
            // dvisvgm applies the --bbox margin after --scale (verified: width grows by 2*margin regardless of scale),
            // so the margin is the padding in output points as-is.
            let bbox = String(format: "%.4fpt", locale: Locale(identifier: "en_US_POSIX"), padding)
            let sc = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), scale)
            outcome = engine.runProcess(ds, ["--no-fonts", "--exact-bbox", "--bbox=\(bbox)", "--scale=\(sc)",
                                             "-o", out.path, dvi.path],
                                        cwd: TeXPaths.svgDir, tools: tools, gen: nil, timeout: 30)
        } else {
            return .failure(QLError("SVG変換ツール（pdftocairo / dvisvgm）が見つかりません"))
        }
        switch outcome {
        case .exited(0): break
        case .timedOut: return .failure(QLError("\(toolName) がタイムアウトしました"))
        case .cancelled: return .failure(QLError("キャンセルされました"))
        case .launchFailed(let m): return .failure(QLError(m))
        case .exited(let s): return .failure(QLError("\(toolName) の実行に失敗しました（終了コード \(s)）"))
        }
        guard let data = try? Data(contentsOf: out), let svg = String(data: data, encoding: .utf8), !svg.isEmpty else {
            return .failure(QLError("SVGを読み込めません"))
        }
        return .success(svg)
    }
}
