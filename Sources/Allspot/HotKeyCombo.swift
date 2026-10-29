import AppKit
import Carbon.HIToolbox

/// 전역 단축키 한 벌(키 + 보조키). 설정에 저장하고 화면에 "⌃⌥Space" 처럼 보여 준다.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    /// Carbon 보조키 비트(cmdKey, optionKey, controlKey, shiftKey)
    var modifiers: UInt32
    var keyName: String

    static let standard = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space")

    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"
    private static let keyNameKey = "hotKeyName"

    static func load() -> HotKeyCombo {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil, let name = defaults.string(forKey: keyNameKey) else { return standard }
        return HotKeyCombo(keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                           modifiers: UInt32(defaults.integer(forKey: modifiersKey)), keyName: name)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersKey)
        defaults.set(keyName, forKey: Self.keyNameKey)
    }

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// 눌린 키로 단축키를 만든다. ⌘·⌥·⌃ 중 하나가 없으면(F키 제외) 글자 입력과 겹치므로 받지 않는다.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let name = Self.specialNames[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        let isFunctionKey = Self.functionKeys.contains(code)
        guard !name.isEmpty, isFunctionKey || carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(code), modifiers: carbon, keyName: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let specialNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
}
