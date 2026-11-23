import Carbon.HIToolbox
import Foundation

struct HotKeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
}

enum HotKeyPresets {
    static let all: [HotKeyPreset] = [
        HotKeyPreset(title: "⌘⇧R", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey)),
        HotKeyPreset(title: "⌃⌥⌘R", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotKeyPreset(title: "⌥⇧R", keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | shiftKey)),
        HotKeyPreset(title: "⌃⇧M", keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | shiftKey)),
    ]

    static var current: HotKeyPreset {
        let index = Settings.shared.hotKeyPreset
        return all.indices.contains(index) ? all[index] : all[0]
    }
}

/// Global shortcut through Carbon (RegisterEventHotKey): works with any app in front,
/// including full-screen apps, and needs no Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var reference: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.installHandlerIfNeeded()
    }

    deinit {
        unregister()
        Self.handlers[id] = nil
    }

    /// Returns false if another app already uses this combination.
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4D_494E), id: id) // 'MMIN'
        let status = RegisterEventHotKey(preset.keyCode, preset.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr {
            Log.error("Could not register the shortcut \(preset.title) (code \(status)).")
            reference = nil
            return false
        }
        Log.info("Global shortcut registered: \(preset.title).")
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, let action = HotKey.handlers[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
