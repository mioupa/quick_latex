import SwiftUI
import AppKit

enum StatusState: Equatable {
    case idle
    case compiling
    case success(Double)
    case error(String)
}

struct FinalResult {
    var pdfData: Data
    var pdfURL: URL
    var size: CGSize
    var fontSize: Double
    var padding: Double
}

/// Shared model (singleton) used by the SwiftUI views, the menu and the hotkey.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    private let defaults = AppSettings.defaults
    private let engine = TeXEngine.shared

    // MARK: persisted settings

    @Published var source: String {
        didSet { defaults.set(source, forKey: AppSettings.Key.source); scheduleCompile() }
    }
    @Published var mode: RenderMode {
        didSet { defaults.set(mode.rawValue, forKey: AppSettings.Key.mode); scheduleCompile() }
    }
    @Published var colorHex: String {
        didSet { defaults.set(colorHex, forKey: AppSettings.Key.color); scheduleCompile() }
    }
    @Published var fontSize: Double {
        didSet {
            let c = min(AppSettings.fontSizeRange.upperBound, max(AppSettings.fontSizeRange.lowerBound, fontSize))
            if c != fontSize { fontSize = c }
            defaults.set(c, forKey: AppSettings.Key.fontSize)
            refinalize(updateStatus: false)
        }
    }
    @Published var padding: Double {
        didSet {
            let c = min(100, max(0, padding))
            if c != padding { padding = c }
            defaults.set(c, forKey: AppSettings.Key.padding)
            refinalize(updateStatus: false)
        }
    }
    /// Mirrors ~/Library/Application Support/QuickLaTeX/preamble.tex (shared with the CLI / VS Code extension).
    @Published var preamble: String {
        didSet {
            if preamble != lastFilePreamble {
                PreambleStore.write(preamble)
                lastFilePreamble = preamble
            }
            scheduleCompile(delay: 0.8)   // format rebuild is debounced longer
        }
    }
    @Published var hideAfterCopy: Bool {
        didSet { defaults.set(hideAfterCopy, forKey: AppSettings.Key.hideAfterCopy) }
    }
    @Published var texBinPath: String {
        didSet { defaults.set(texBinPath, forKey: AppSettings.Key.texBinPath); scheduleCompile(delay: 0.6) }
    }

    // MARK: transient UI state

    @Published var status: StatusState = .idle
    @Published var toast: String?
    @Published var previewImage: NSImage?
    @Published var showPreamble = false

    private(set) var latest: (input: RenderInput, result: RenderResult)?
    private(set) var finalResult: FinalResult?
    private var previewURL: URL?

    private var lastFilePreamble = ""
    private var activationObserver: NSObjectProtocol?
    private var debounce: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var seq = 0
    private var inFlight: RenderInput?
    private var continuations: [(Bool) -> Void] = []

    private init() {
        let d = AppSettings.defaults
        source = d.string(forKey: AppSettings.Key.source) ?? #"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#
        mode = RenderMode(rawValue: d.string(forKey: AppSettings.Key.mode) ?? "") ?? .display
        colorHex = HexColor.normalized(d.string(forKey: AppSettings.Key.color) ?? "") ?? AppSettings.defaultColorHex
        let fs = d.object(forKey: AppSettings.Key.fontSize) as? Double ?? AppSettings.defaultFontSize
        fontSize = min(AppSettings.fontSizeRange.upperBound, max(AppSettings.fontSizeRange.lowerBound, fs))
        padding = d.object(forKey: AppSettings.Key.padding) as? Double ?? AppSettings.defaultPadding
        let filePreamble = PreambleStore.load()
        preamble = filePreamble
        lastFilePreamble = filePreamble
        hideAfterCopy = d.object(forKey: AppSettings.Key.hideAfterCopy) as? Bool ?? true
        texBinPath = AppSettings.storedTeXBinPath
    }

    var currentInput: RenderInput {
        RenderInput(source: source, mode: mode, colorHex: colorHex, preamble: preamble, texBinPath: texBinPath)
    }

    var previewBackground: Color {
        HexColor.luminance(colorHex) > 0.6 ? Color(.sRGB, red: 0x2B / 255, green: 0x2B / 255, blue: 0x2B / 255)
                                           : Color.white
    }

    func start() {
        engine.prepareFormat(preamble: preamble, texBinPath: texBinPath)
        compileNow()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadPreambleIfChangedExternally()
        }
    }

    /// The preamble file may have been edited elsewhere (VS Code, a text editor): pick it up and recompile.
    func reloadPreambleIfChangedExternally() {
        let onDisk = PreambleStore.load()
        guard onDisk != lastFilePreamble else { return }
        lastFilePreamble = onDisk
        preamble = onDisk       // didSet sees no difference to write; schedules the debounced rebuild + recompile
    }

    func resetPreamble() { preamble = AppSettings.defaultPreamble }

    // MARK: compile scheduling

    func scheduleCompile(delay: TimeInterval = 0.25) {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.compileNow() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Compile the current input immediately; `then` runs (on main) once the result for the latest request is known.
    func compileNow(then: ((Bool) -> Void)? = nil) {
        debounce?.cancel()
        debounce = nil
        if let then = then { continuations.append(then) }

        let input = currentInput
        if input.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            seq += 1
            inFlight = nil
            engine.supersede()
            latest = nil
            finalResult = nil
            previewImage = nil
            previewURL = nil
            status = .idle
            flush(ok: false, message: "入力が空です")
            return
        }
        if inFlight == input { return }

        seq += 1
        let mySeq = seq
        inFlight = input
        status = .compiling
        let gen = engine.supersede()
        engine.queue.async { [weak self, engine] in
            guard engine.isCurrent(gen) else {
                DispatchQueue.main.async { self?.finish(seq: mySeq, input: input, outcome: .cancelled) }
                return
            }
            let outcome = engine.renderRaw(input, gen: gen)
            DispatchQueue.main.async { self?.finish(seq: mySeq, input: input, outcome: outcome) }
        }
    }

    private func finish(seq mySeq: Int, input: RenderInput, outcome: RenderOutcome) {
        guard mySeq == seq else { return }   // superseded
        inFlight = nil
        var ok = false
        switch outcome {
        case .cancelled:
            status = .idle
        case .failure(let failure):
            status = .error(failure.formatted)
        case .success(let result):
            latest = (input, result)
            ok = refinalize(updateStatus: true)
        }
        flush(ok: ok, message: nil)
    }

    private func flush(ok: Bool, message: String?) {
        let conts = continuations
        continuations = []
        if !ok, !conts.isEmpty, let m = message { status = .error(m) }
        conts.forEach { $0(ok) }
    }

    /// Crop/scale the cached raw PDF (no TeX involved) and update the preview.
    @discardableResult
    func refinalize(updateStatus: Bool) -> Bool {
        guard let latest = latest else { return false }
        let t0 = Date()
        do {
            let data = try PDFProcessing.finalize(raw: latest.result.raw, fontSize: fontSize, padding: padding)
            try data.write(to: TeXPaths.equationPDF, options: .atomic)
            let size = PDFProcessing.outputSize(raw: latest.result.raw, fontSize: fontSize, padding: padding)
            finalResult = FinalResult(pdfData: data, pdfURL: TeXPaths.equationPDF, size: size,
                                      fontSize: fontSize, padding: padding)
            previewImage = NSImage(data: data)
            previewURL = TeXPaths.equationPDF
            if updateStatus {
                status = .success(latest.result.seconds + Date().timeIntervalSince(t0))
            }
            return true
        } catch {
            status = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return false
        }
    }

    func dragProvider() -> NSItemProvider {
        if let url = previewURL, let p = NSItemProvider(contentsOf: url) { return p }
        return NSItemProvider()
    }

    // MARK: toast

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
    }

    // MARK: copy actions

    /// Runs `body` with a final result that matches the current inputs (compiling first if necessary).
    private func withCurrentResult(_ body: @escaping (FinalResult, RenderResult) -> Void) {
        let input = currentInput
        if let l = latest, l.input == input, inFlight == nil {
            if finalResult?.fontSize != fontSize || finalResult?.padding != padding { refinalize(updateStatus: false) }
            if let f = finalResult { body(f, l.result); return }
        }
        compileNow { [weak self] ok in
            guard let self = self, ok, let l = self.latest, let f = self.finalResult else {
                NSSound.beep()
                return
            }
            body(f, l.result)
        }
    }

    func copyImage() {
        withCurrentResult { [weak self] final, _ in
            guard let self = self else { return }
            do {
                let png = try PDFProcessing.pngData(fromPDF: final.pdfData)
                PasteboardWriter.copyImage(pdf: final.pdfData, png: png)
                self.showToast("コピーしました（PDF+PNG）")
                self.hideIfNeeded()
            } catch {
                NSSound.beep()
                self.status = .error((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    func copySVG() {
        withCurrentResult { [weak self] final, result in
            guard let self = self else { return }
            guard let tools = TeXTools.discover(override: self.texBinPath) else {
                NSSound.beep()
                self.status = .error("SVG変換ツールが見つかりません")
                return
            }
            let fontSize = final.fontSize, padding = final.padding
            DispatchQueue.global(qos: .userInitiated).async {
                let r = SVGExporter.makeSVG(finalPDF: final.pdfURL, dvi: result.dviURL,
                                            fontSize: fontSize, padding: padding, tools: tools)
                DispatchQueue.main.async {
                    switch r {
                    case .success(let svg):
                        PasteboardWriter.copySVG(svg)
                        self.showToast("SVGをコピーしました")
                        self.hideIfNeeded()
                    case .failure(let e):
                        NSSound.beep()
                        self.status = .error(e.message)
                    }
                }
            }
        }
    }

    private func hideIfNeeded() {
        if hideAfterCopy { NSApp.hide(nil) }
    }
}
