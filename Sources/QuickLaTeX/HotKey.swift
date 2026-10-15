import Carbon
import Foundation

/// Global hotkey via Carbon RegisterEventHotKey (no accessibility permission required).
enum HotKey {
    static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false

    @discardableResult
    static func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        self.handler = handler
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            guard status == noErr else {
                NSLog("QuickLaTeX: InstallEventHandler failed (\(status))")
                return false
            }
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x514C_5458), id: 1) // 'QLTX'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr {
            NSLog("QuickLaTeX: RegisterEventHotKey failed (\(status))")
            return false
        }
        return true
    }
}
