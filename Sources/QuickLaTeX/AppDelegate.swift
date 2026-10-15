import AppKit
import SwiftUI
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow!
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        createWindow()
        if !HotKey.register(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, handler: { [weak self] in
            self?.showAndFocus()
        }) {
            NSLog("QuickLaTeX: global hotkey (ctrl+opt+L) is unavailable")
        }
        model.start()
        showAndFocus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showAndFocus()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !NSApp.isHidden, let w = window, !w.isVisible, !w.isMiniaturized {
            w.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: window

    private func createWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Quick LaTeX"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 480, height: 400)
        let host = NSHostingView(rootView: ContentView(model: model))
        host.sizingOptions = []
        w.contentView = host
        if !w.setFrameUsingName("QuickLaTeXMainWindow") { w.center() }
        w.setFrameAutosaveName("QuickLaTeXMainWindow")
        window = w
    }

    func showAndFocus() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let tv = LaTeXEditor.mainTextView else { return }
            self.window.makeFirstResponder(tv)
        }
    }

    // MARK: menu

    private func buildMenu() {
        let main = NSMenu()

        // App
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quick LaTeX について",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隠す", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Edit
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // LaTeX
        let texItem = NSMenuItem()
        main.addItem(texItem)
        let texMenu = NSMenu(title: "LaTeX")
        let copyImg = texMenu.addItem(withTitle: "画像をコピー", action: #selector(copyImage(_:)), keyEquivalent: "\r")
        copyImg.keyEquivalentModifierMask = [.command]
        copyImg.target = self
        let copySvg = texMenu.addItem(withTitle: "SVGをコピー", action: #selector(copySVG(_:)), keyEquivalent: "c")
        copySvg.keyEquivalentModifierMask = [.command, .shift]
        copySvg.target = self
        texMenu.addItem(.separator())
        let pre = texMenu.addItem(withTitle: "プリアンブル編集…", action: #selector(editPreamble(_:)), keyEquivalent: ",")
        pre.keyEquivalentModifierMask = [.command]
        pre.target = self
        texItem.submenu = texMenu

        // Window
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "ウィンドウ")
        winMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }

    @objc private func copyImage(_ sender: Any?) { model.copyImage() }
    @objc private func copySVG(_ sender: Any?) { model.copySVG() }
    @objc private func editPreamble(_ sender: Any?) {
        showAndFocus()
        model.showPreamble = true
    }
}
