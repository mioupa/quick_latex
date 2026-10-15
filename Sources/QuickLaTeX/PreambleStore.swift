import Foundation

/// The user preamble lives in a plain file shared by the GUI, the CLI and the VS Code extension:
/// ~/Library/Application Support/QuickLaTeX/preamble.tex
enum PreambleStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("QuickLaTeX", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("preamble.tex") }

    /// Creates the file if missing: migrates a preamble previously stored in UserDefaults, else writes the default.
    @discardableResult
    static func ensureFile() -> URL {
        let url = fileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = AppSettings.defaults
        let legacy = defaults.string(forKey: AppSettings.Key.preamble)
        let text = legacy ?? (AppSettings.defaultPreamble + "\n")
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            if legacy != nil { defaults.removeObject(forKey: AppSettings.Key.preamble) }
        } catch {
            NSLog("QuickLaTeX: cannot write \(url.path): \(error.localizedDescription)")
        }
        return url
    }

    /// Current file contents (creating the file first if needed).
    static func load() -> String {
        let url = ensureFile()
        if let d = try? Data(contentsOf: url) { return String(decoding: d, as: UTF8.self) }
        return AppSettings.defaultPreamble
    }

    static func write(_ text: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("QuickLaTeX: cannot write \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
