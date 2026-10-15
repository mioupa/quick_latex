import SwiftUI
import AppKit

private let presetColors: [(name: String, hex: String)] = [
    ("黒", "000000"), ("白", "FFFFFF"), ("赤", "D0021B"), ("青", "1F4FD8"),
]

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, showSettings: $showSettings)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            VSplitView {
                LaTeXEditor(text: $model.source, isMain: true, onEscape: { NSApp.hide(nil) })
                    .frame(minHeight: 90)
                PreviewPane(model: model)
                    .frame(minHeight: 90)
            }
            Divider()
            StatusBar(model: model)
        }
        .frame(minWidth: 480, minHeight: 400)
        .sheet(isPresented: $model.showPreamble) {
            PreambleSheet(model: model)
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $model.mode) {
                    ForEach(RenderMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)

                Spacer(minLength: 8)

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopover(model: model, showSettings: $showSettings)
                }

                Button("SVG") { model.copySVG() }
                    .help("SVGをコピー（⇧⌘C）")
                Button("コピー ⌘↩") { model.copyImage() }
                    .buttonStyle(.borderedProminent)
                    .help("PDF+PNGをコピー（⌘↩）")
            }
            HStack(spacing: 10) {
                Text("色").foregroundStyle(.secondary)
                ColorSwatches(model: model)
                Spacer(minLength: 8)
                Text("文字サイズ").foregroundStyle(.secondary)
                TextField("", value: $model.fontSize, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $model.fontSize, in: AppSettings.fontSizeRange, step: 1)
                    .labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ColorSwatches: View {
    @ObservedObject var model: AppModel

    private var customBinding: Binding<Color> {
        Binding(
            get: {
                let c = HexColor.parse(model.colorHex) ?? (0, 0, 0)
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
            },
            set: { newColor in
                guard let ns = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                let hex = String(format: "%02X%02X%02X",
                                 Int((ns.redComponent * 255).rounded()),
                                 Int((ns.greenComponent * 255).rounded()),
                                 Int((ns.blueComponent * 255).rounded()))
                if hex != model.colorHex { model.colorHex = hex }
            })
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(presetColors, id: \.hex) { preset in
                let c = HexColor.parse(preset.hex) ?? (0, 0, 0)
                let selected = model.colorHex.uppercased() == preset.hex
                Button {
                    model.colorHex = preset.hex
                } label: {
                    Circle()
                        .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
            ColorPicker("", selection: customBinding, supportsOpacity: false)
                .labelsHidden()
                .help("カスタム色")
        }
    }
}

// MARK: - Settings popover

private struct SettingsPopover: View {
    @ObservedObject var model: AppModel
    @Binding var showSettings: Bool
    @State private var autoPath = "検出中…"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("余白")
                TextField("", value: $model.padding, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $model.padding, in: 0...100, step: 0.5)
                    .labelsHidden()
                Text("pt").foregroundStyle(.secondary)
            }
            Toggle("コピー後にウィンドウを隠す", isOn: $model.hideAfterCopy)
            VStack(alignment: .leading, spacing: 4) {
                Text("TeX bin のパス（空欄で自動検出）")
                TextField(autoPath, text: $model.texBinPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
            }
            Button("プリアンブル編集…") {
                showSettings = false
                model.showPreamble = true
            }
        }
        .padding(14)
        .onAppear {
            let override = ""
            DispatchQueue.global(qos: .utility).async {
                let p = TeXTools.discover(override: override)?.binDir.path ?? "見つかりません"
                DispatchQueue.main.async { autoPath = p }
            }
        }
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                model.previewBackground
                if let img = model.previewImage {
                    let natural = img.size
                    let margin: CGFloat = 20
                    let s = min(1,
                                max(1, geo.size.width - margin) / max(1, natural.width),
                                max(1, geo.size.height - margin) / max(1, natural.height))
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: natural.width * s, height: natural.height * s)
                        .onDrag { model.dragProvider() }
                        .help("ドラッグしてPDFを他のアプリへ")
                } else {
                    Text("プレビュー")
                        .foregroundStyle(Color.gray)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

// MARK: - Status

private struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let toast = model.toast {
                Text(toast)
                    .foregroundStyle(Color.green)
            } else {
                switch model.status {
                case .idle:
                    Text(" ").foregroundStyle(.secondary)
                case .compiling:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("コンパイル中…").foregroundStyle(.secondary)
                    }
                case .success(let t):
                    Text(String(format: "✓ %.2fs", t))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                case .error(let msg):
                    ScrollView {
                        Text(msg)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Color.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 84)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
    }
}

// MARK: - Preamble sheet

private struct PreambleSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("プリアンブル").font(.headline)
            Text("\\documentclass の後に挿入されます。変更するとフォーマットを再構築して再コンパイルします。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LaTeXEditor(text: $model.preamble, onEscape: { model.showPreamble = false })
                .frame(minWidth: 520, minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.4)))
            HStack {
                Button("デフォルトに戻す") { model.resetPreamble() }
                Spacer()
                Button("閉じる") { model.showPreamble = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 580, height: 420)
    }
}
