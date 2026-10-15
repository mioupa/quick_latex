import AppKit

if !CLI.triggerFlags.isDisjoint(with: CommandLine.arguments) {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
