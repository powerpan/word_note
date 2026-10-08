import AppKit
import Carbon
import WordNoteCore

@MainActor
final class CarbonCaptureShortcutBackend: CaptureShortcutBackend {
    private static var nextNativeID: UInt32 = 1
    private let state = NativeState()

    func register(_ shortcut: CaptureShortcut, id: UInt32, onKey: @escaping @MainActor (Bool) -> Void) throws {
        guard shortcut.isValid else { throw CaptureShortcutError.invalidCombination }
        let keyCode = shortcut.key.carbonKeyCode
        let modifiers = shortcut.modifiers.carbonFlags
        try checkSystemShortcuts(keyCode: keyCode, modifiers: modifiers)
        guard Self.nextNativeID < UInt32.max else { throw CaptureShortcutError.identifierExhausted }
        let nativeID = Self.nextNativeID
        Self.nextNativeID += 1
        try state.register(id: id, nativeID: nativeID, keyCode: keyCode, modifiers: modifiers, onKey: onKey)
    }

    func unregister(_ id: UInt32) throws {
        try state.unregister(id)
    }

    deinit {
        let state = state
        if Thread.isMainThread { MainActor.assumeIsolated { state.close() } }
        else { Task { @MainActor in state.close() } }
    }

    private func checkSystemShortcuts(keyCode: UInt32, modifiers: UInt32) throws {
        var values: Unmanaged<CFArray>?
        let result = CopySymbolicHotKeys(&values)
        guard result == noErr else { throw CaptureShortcutError.registrationFailed(result) }
        guard let entries = values?.takeRetainedValue() as? [[String: Any]] else {
            throw CaptureShortcutError.registrationFailed(OSStatus(paramErr))
        }
        if entries.contains(where: {
            ($0[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true
                && ($0[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == keyCode
                && ($0[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value == modifiers
        }) { throw CaptureShortcutError.systemReserved }
    }

    @MainActor
    private final class NativeState {
        private static let signature: OSType = 0x574E4F54
        private struct Registration {
            let nativeID: UInt32
            let hotKey: EventHotKeyRef
            let onKey: @MainActor (Bool) -> Void
        }
        private var registrations: [UInt32: Registration] = [:]
        private var handler: EventHandlerRef?
        private var retainedContext: Unmanaged<NativeState>?

        func register(id: UInt32, nativeID: UInt32, keyCode: UInt32, modifiers: UInt32,
                      onKey: @escaping @MainActor (Bool) -> Void) throws {
            guard registrations[id] == nil else { throw CaptureShortcutError.invalidCombination }
            try installHandler()
            var hotKey: EventHotKeyRef?
            let result = RegisterEventHotKey(keyCode, modifiers, .init(signature: Self.signature, id: nativeID),
                                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
            guard result == noErr, let hotKey else {
                removeUnusedHandler()
                throw CaptureShortcutError.registrationFailed(result == noErr ? OSStatus(paramErr) : result)
            }
            registrations[id] = Registration(nativeID: nativeID, hotKey: hotKey, onKey: onKey)
        }

        func unregister(_ id: UInt32) throws {
            guard let registration = registrations[id] else { return }
            let result = UnregisterEventHotKey(registration.hotKey)
            guard result == noErr else { throw CaptureShortcutError.removalFailed(result) }
            registrations[id] = nil
            removeUnusedHandler()
        }

        func close() {
            let active = Array(registrations.values)
            registrations.removeAll()
            for registration in active { UnregisterEventHotKey(registration.hotKey) }
            removeUnusedHandler()
        }

        private func installHandler() throws {
            guard handler == nil else { return }
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let context = Unmanaged.passRetained(self)
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard Thread.isMainThread, let event, let context else { return OSStatus(eventNotHandledErr) }
                // Application-target Carbon events are delivered on the AppKit main event loop.
                return MainActor.assumeIsolated {
                    Unmanaged<NativeState>.fromOpaque(context).takeUnretainedValue().handle(event)
                }
            }, events.count, &events, context.toOpaque(), &handler)
            guard installed == noErr else {
                context.release()
                throw CaptureShortcutError.registrationFailed(installed)
            }
            retainedContext = context
        }

        private func removeUnusedHandler() {
            guard registrations.isEmpty, let handler else { return }
            // A failed handler cleanup must not undo a successful key release or leave a dangling C context.
            guard RemoveEventHandler(handler) == noErr else { return }
            self.handler = nil
            let context = retainedContext
            retainedContext = nil
            context?.release()
        }

        private func handle(_ event: EventRef) -> OSStatus {
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == Self.signature,
                  let registration = registrations.values.first(where: { $0.nativeID == key.id }) else {
                return OSStatus(eventNotHandledErr)
            }
            registration.onKey(GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }
    }
}

private extension CaptureShortcut.Modifiers {
    var carbonFlags: UInt32 {
        let values: [(Self, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        return values.reduce(0) { $0 | (contains($1.0) ? UInt32($1.1) : 0) }
    }
}

extension CaptureShortcut.Key {
    var carbonKeyCode: UInt32 {
        let codes: [Self: Int] = [
            .space: kVK_Space, .a: kVK_ANSI_A, .b: kVK_ANSI_B, .c: kVK_ANSI_C, .d: kVK_ANSI_D, .e: kVK_ANSI_E,
            .f: kVK_ANSI_F, .g: kVK_ANSI_G, .h: kVK_ANSI_H, .i: kVK_ANSI_I, .j: kVK_ANSI_J, .k: kVK_ANSI_K,
            .l: kVK_ANSI_L, .m: kVK_ANSI_M, .n: kVK_ANSI_N, .o: kVK_ANSI_O, .p: kVK_ANSI_P, .q: kVK_ANSI_Q,
            .r: kVK_ANSI_R, .s: kVK_ANSI_S, .t: kVK_ANSI_T, .u: kVK_ANSI_U, .v: kVK_ANSI_V, .w: kVK_ANSI_W,
            .x: kVK_ANSI_X, .y: kVK_ANSI_Y, .z: kVK_ANSI_Z,
            .f1: kVK_F1, .f2: kVK_F2, .f3: kVK_F3, .f4: kVK_F4, .f5: kVK_F5, .f6: kVK_F6,
            .f7: kVK_F7, .f8: kVK_F8, .f9: kVK_F9, .f10: kVK_F10, .f11: kVK_F11, .f12: kVK_F12
        ]
        return UInt32(codes[self]!)
    }
}
