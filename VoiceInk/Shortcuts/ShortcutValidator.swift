import AppKit
import Carbon.HIToolbox

enum ShortcutValidationError: Equatable {
    case plainKeyRequiresModifier
    case shiftTypingKeyRequiresAdditionalModifier
    case reservedBySystem
    case alreadyUsedBy(String)

    func notificationTitle(for shortcut: Shortcut) -> String {
        switch self {
        case .plainKeyRequiresModifier, .shiftTypingKeyRequiresAdditionalModifier:
            return String(format: String(localized: "Shortcut not allowed: %@"), shortcut.displayString)
        case .reservedBySystem:
            return String(format: String(localized: "Shortcut reserved by macOS: %@"), shortcut.displayString)
        case .alreadyUsedBy(let actionName):
            return String(format: String(localized: "Shortcut already used by %@"), actionName)
        }
    }
}

enum ShortcutValidator {
    static func validationError(for shortcut: Shortcut, action: ShortcutAction) -> ShortcutValidationError? {
        if let error = userRecordingShortcutError(for: shortcut) {
            return error
        }

        if systemReservedShortcuts.contains(where: { $0.conflicts(with: shortcut) }) {
            return .reservedBySystem
        }

        if let existingAction = storedActionConflicting(with: shortcut, excluding: action) {
            return .alreadyUsedBy(existingAction.displayName)
        }

        return nil
    }

    private static func userRecordingShortcutError(for shortcut: Shortcut) -> ShortcutValidationError? {
        switch shortcut.kind {
        case .modifierOnly:
            return shortcut.modifierFlags.isEmpty ? .plainKeyRequiresModifier : nil
        case .key:
            if Shortcut.isFunctionKeyCode(shortcut.keyCode) {
                return nil
            }

            guard !shortcut.modifierFlags.isEmpty else {
                return .plainKeyRequiresModifier
            }

            if shortcut.modifierFlags == [.shift],
               shiftOnlyTypingKeyCodes.contains(shortcut.keyCode) {
                return .shiftTypingKeyRequiresAdditionalModifier
            }

            return nil
        }
    }

    private static func storedActionConflicting(with candidate: Shortcut, excluding actionToIgnore: ShortcutAction) -> ShortcutAction? {
        for action in ShortcutAction.storedActions where action != actionToIgnore {
            guard let existingShortcut = ShortcutStore.shortcut(for: action) else {
                continue
            }

            if existingShortcut.conflicts(with: candidate) {
                return action
            }
        }

        return nil
    }

    private static var systemReservedShortcuts: [Shortcut] {
        commonEditCommandShortcuts + sessionShortcuts + essentialTextEditingShortcuts
    }

    private static var commonEditCommandShortcuts: [Shortcut] {
        [
            shortcut(kVK_ANSI_A, [.command]),
            shortcut(kVK_ANSI_C, [.command]),
            shortcut(kVK_ANSI_F, [.command]),
            shortcut(kVK_ANSI_H, [.command]),
            shortcut(kVK_ANSI_M, [.command]),
            shortcut(kVK_ANSI_N, [.command]),
            shortcut(kVK_ANSI_O, [.command]),
            shortcut(kVK_ANSI_P, [.command]),
            shortcut(kVK_ANSI_Q, [.command]),
            shortcut(kVK_ANSI_S, [.command]),
            shortcut(kVK_ANSI_T, [.command]),
            shortcut(kVK_ANSI_V, [.command]),
            shortcut(kVK_ANSI_W, [.command]),
            shortcut(kVK_ANSI_X, [.command]),
            shortcut(kVK_ANSI_Z, [.command]),
            shortcut(kVK_ANSI_Z, [.shift, .command]),
            shortcut(kVK_ANSI_Comma, [.command])
        ]
    }

    private static var sessionShortcuts: [Shortcut] {
        [
            shortcut(kVK_Escape, [.option, .command]),
            shortcut(kVK_ANSI_Q, [.control, .command]),
            shortcut(kVK_ANSI_Q, [.shift, .command]),
            shortcut(kVK_ANSI_Q, [.option, .shift, .command])
        ]
    }

    private static var essentialTextEditingShortcuts: [Shortcut] {
        [
            shortcut(kVK_ANSI_B, [.command]),
            shortcut(kVK_ANSI_I, [.command]),
            shortcut(kVK_ANSI_U, [.command]),
            shortcut(kVK_ANSI_D, [.control, .command]),
            shortcut(kVK_Delete, [.option])
        ]
    }

    private static func shortcut(_ keyCode: Int, _ modifierFlags: NSEvent.ModifierFlags) -> Shortcut {
        .key(keyCode: UInt16(keyCode), modifierFlags: modifierFlags)
    }

    private static let shiftOnlyTypingKeyCodes: Set<UInt16> = [
        UInt16(kVK_ANSI_A), UInt16(kVK_ANSI_B), UInt16(kVK_ANSI_C),
        UInt16(kVK_ANSI_D), UInt16(kVK_ANSI_E), UInt16(kVK_ANSI_F),
        UInt16(kVK_ANSI_G), UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_I),
        UInt16(kVK_ANSI_J), UInt16(kVK_ANSI_K), UInt16(kVK_ANSI_L),
        UInt16(kVK_ANSI_M), UInt16(kVK_ANSI_N), UInt16(kVK_ANSI_O),
        UInt16(kVK_ANSI_P), UInt16(kVK_ANSI_Q), UInt16(kVK_ANSI_R),
        UInt16(kVK_ANSI_S), UInt16(kVK_ANSI_T), UInt16(kVK_ANSI_U),
        UInt16(kVK_ANSI_V), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_X),
        UInt16(kVK_ANSI_Y), UInt16(kVK_ANSI_Z), UInt16(kVK_Space)
    ]
}
