import Foundation
import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    static let shared = HotkeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handlers: [(keyCode: Int, modifiers: Int, action: () -> Void)] = []

    private init() {}

    /// Register Cmd+Shift+Space for quick panel toggle
    func registerDefaults(togglePanel: @escaping () -> Void) {
        register(
            keyCode: kVK_Space,
            modifiers: [.maskCommand, .maskShift],
            action: togglePanel
        )

        startListening()
        Log.app.info("Global hotkeys registered")
    }

    func register(keyCode: Int, modifiers: [CGEventFlags], action: @escaping () -> Void) {
        let mask = modifiers.reduce(CGEventFlags()) { $0.union($1) }
        handlers.append((keyCode: keyCode, modifiers: Int(mask.rawValue), action: action))
    }

    private func startListening() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, _, event, refcon -> Unmanaged<CGEvent>? in
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = Int(event.flags.rawValue) & 0xFF0000 // Mask to modifier bits only

            for handler in manager.handlers {
                if keyCode == handler.keyCode && flags == handler.modifiers {
                    DispatchQueue.main.async { handler.action() }
                    return nil // Consume the event
                }
            }

            return Unmanaged.passRetained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            Log.app.error("Failed to create event tap. Grant Accessibility permission in System Settings > Privacy & Security > Accessibility.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}
