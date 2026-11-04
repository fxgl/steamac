import Carbon.HIToolbox

/// macOS virtual key codes (kVK_*, positional, US-ANSI names) -> Linux evdev KEY_*.
/// Positional mapping: the guest applies its own keyboard layout.
enum Keymap {
    /// ISO keyboards report the key left of "1" as kVK_ISO_Section and the extra key next to
    /// left shift as kVK_ANSI_Grave; PC/evdev has them as KEY_GRAVE and KEY_102ND.
    static let isISO: Bool = KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO

    static func linuxKey(_ keyCode: UInt16) -> UInt16? {
        switch Int(keyCode) {
        case kVK_ISO_Section: return isISO ? KEY.GRAVE : KEY._102ND
        case kVK_ANSI_Grave: return isISO ? KEY._102ND : KEY.GRAVE
        default: return table[keyCode]
        }
    }

    /// Every code the keyboard device can emit (advertised in EV_KEY bits).
    static var allCodes: [UInt16] { Array(Set(table.values).union(windows.values).union([KEY.GRAVE, KEY._102ND, KEY.KPENTER])) }

    static let table: [UInt16: UInt16] = {
        let pairs: [(Int, UInt16)] = [
            (kVK_ANSI_A, KEY.A), (kVK_ANSI_B, KEY.B), (kVK_ANSI_C, KEY.C), (kVK_ANSI_D, KEY.D),
            (kVK_ANSI_E, KEY.E), (kVK_ANSI_F, KEY.F), (kVK_ANSI_G, KEY.G), (kVK_ANSI_H, KEY.H),
            (kVK_ANSI_I, KEY.I), (kVK_ANSI_J, KEY.J), (kVK_ANSI_K, KEY.K), (kVK_ANSI_L, KEY.L),
            (kVK_ANSI_M, KEY.M), (kVK_ANSI_N, KEY.N), (kVK_ANSI_O, KEY.O), (kVK_ANSI_P, KEY.P),
            (kVK_ANSI_Q, KEY.Q), (kVK_ANSI_R, KEY.R), (kVK_ANSI_S, KEY.S), (kVK_ANSI_T, KEY.T),
            (kVK_ANSI_U, KEY.U), (kVK_ANSI_V, KEY.V), (kVK_ANSI_W, KEY.W), (kVK_ANSI_X, KEY.X),
            (kVK_ANSI_Y, KEY.Y), (kVK_ANSI_Z, KEY.Z),
            (kVK_ANSI_1, KEY._1), (kVK_ANSI_2, KEY._2), (kVK_ANSI_3, KEY._3), (kVK_ANSI_4, KEY._4),
            (kVK_ANSI_5, KEY._5), (kVK_ANSI_6, KEY._6), (kVK_ANSI_7, KEY._7), (kVK_ANSI_8, KEY._8),
            (kVK_ANSI_9, KEY._9), (kVK_ANSI_0, KEY._0),
            (kVK_ANSI_Minus, KEY.MINUS), (kVK_ANSI_Equal, KEY.EQUAL),
            (kVK_ANSI_LeftBracket, KEY.LEFTBRACE), (kVK_ANSI_RightBracket, KEY.RIGHTBRACE),
            (kVK_ANSI_Backslash, KEY.BACKSLASH), (kVK_ANSI_Semicolon, KEY.SEMICOLON),
            (kVK_ANSI_Quote, KEY.APOSTROPHE), (kVK_ANSI_Comma, KEY.COMMA),
            (kVK_ANSI_Period, KEY.DOT), (kVK_ANSI_Slash, KEY.SLASH),
            (kVK_Return, KEY.ENTER), (kVK_Tab, KEY.TAB), (kVK_Space, KEY.SPACE),
            (kVK_Delete, KEY.BACKSPACE), (kVK_ForwardDelete, KEY.DELETE), (kVK_Escape, KEY.ESC),
            (kVK_Command, KEY.LEFTMETA), (kVK_RightCommand, KEY.RIGHTMETA),
            (kVK_Shift, KEY.LEFTSHIFT), (kVK_RightShift, KEY.RIGHTSHIFT),
            (kVK_Option, KEY.LEFTALT), (kVK_RightOption, KEY.RIGHTALT),
            (kVK_Control, KEY.LEFTCTRL), (kVK_RightControl, KEY.RIGHTCTRL),
            (kVK_CapsLock, KEY.CAPSLOCK),
            (kVK_LeftArrow, KEY.LEFT), (kVK_RightArrow, KEY.RIGHT),
            (kVK_UpArrow, KEY.UP), (kVK_DownArrow, KEY.DOWN),
            (kVK_Home, KEY.HOME), (kVK_End, KEY.END), (kVK_PageUp, KEY.PAGEUP), (kVK_PageDown, KEY.PAGEDOWN),
            (kVK_Help, KEY.INSERT),
            (kVK_F1, KEY.F1), (kVK_F2, KEY.F2), (kVK_F3, KEY.F3), (kVK_F4, KEY.F4),
            (kVK_F5, KEY.F5), (kVK_F6, KEY.F6), (kVK_F7, KEY.F7), (kVK_F8, KEY.F8),
            (kVK_F9, KEY.F9), (kVK_F10, KEY.F10), (kVK_F11, KEY.F11), (kVK_F12, KEY.F12),
            (kVK_F13, KEY.F13), (kVK_F14, KEY.F14), (kVK_F15, KEY.F15), (kVK_F16, KEY.F16),
            (kVK_F17, KEY.F17), (kVK_F18, KEY.F18), (kVK_F19, KEY.F19), (kVK_F20, KEY.F20),
            (kVK_ANSI_Keypad0, KEY.KP0), (kVK_ANSI_Keypad1, KEY.KP1), (kVK_ANSI_Keypad2, KEY.KP2),
            (kVK_ANSI_Keypad3, KEY.KP3), (kVK_ANSI_Keypad4, KEY.KP4), (kVK_ANSI_Keypad5, KEY.KP5),
            (kVK_ANSI_Keypad6, KEY.KP6), (kVK_ANSI_Keypad7, KEY.KP7), (kVK_ANSI_Keypad8, KEY.KP8),
            (kVK_ANSI_Keypad9, KEY.KP9), (kVK_ANSI_KeypadDecimal, KEY.KPDOT),
            (kVK_ANSI_KeypadMultiply, KEY.KPASTERISK), (kVK_ANSI_KeypadPlus, KEY.KPPLUS),
            (kVK_ANSI_KeypadMinus, KEY.KPMINUS), (kVK_ANSI_KeypadDivide, KEY.KPSLASH),
            (kVK_ANSI_KeypadEnter, KEY.KPENTER), (kVK_ANSI_KeypadEquals, KEY.KPEQUAL),
            (kVK_ANSI_KeypadClear, KEY.NUMLOCK),
            (kVK_VolumeUp, KEY.VOLUMEUP), (kVK_VolumeDown, KEY.VOLUMEDOWN), (kVK_Mute, KEY.MUTE),
            (kVK_JIS_Yen, KEY.YEN), (kVK_JIS_Underscore, KEY.RO), (kVK_JIS_KeypadComma, KEY.KPJPCOMMA),
            (kVK_JIS_Eisu, KEY.HANJA), (kVK_JIS_Kana, KEY.HANGEUL),
            (kVK_ContextualMenu, KEY.COMPOSE),
        ]
        var t: [UInt16: UInt16] = [:]
        for (mac, linux) in pairs { t[UInt16(mac)] = linux }
        return t
    }()

    /// Moonlight sends Windows VK codes, independent of the Mac's keyboard layout.
    static func windowsKey(_ vk: UInt16, extended: Bool) -> UInt16? {
        let vk = vk & 0xff
        if extended {
            switch vk {
            case 0x0d: return KEY.KPENTER
            case 0x10: return KEY.RIGHTSHIFT
            case 0x11: return KEY.RIGHTCTRL
            case 0x12: return KEY.RIGHTALT
            default: break
            }
        }
        return windows[vk]
    }

    static let windows: [UInt16: UInt16] = {
        var t: [UInt16: UInt16] = [
            0x08: KEY.BACKSPACE, 0x09: KEY.TAB, 0x0c: KEY.KP5, 0x0d: KEY.ENTER,
            0x10: KEY.LEFTSHIFT, 0x11: KEY.LEFTCTRL, 0x12: KEY.LEFTALT, 0x13: KEY.PAUSE,
            0x14: KEY.CAPSLOCK, 0x15: KEY.HANGEUL, 0x19: KEY.HANJA, 0x1b: KEY.ESC,
            0x20: KEY.SPACE, 0x21: KEY.PAGEUP, 0x22: KEY.PAGEDOWN, 0x23: KEY.END, 0x24: KEY.HOME,
            0x25: KEY.LEFT, 0x26: KEY.UP, 0x27: KEY.RIGHT, 0x28: KEY.DOWN,
            0x2a: KEY.SYSRQ, 0x2c: KEY.SYSRQ, 0x2d: KEY.INSERT, 0x2e: KEY.DELETE, 0x2f: KEY.HELP,
            0x5b: KEY.LEFTMETA, 0x5c: KEY.RIGHTMETA, 0x5d: KEY.COMPOSE, 0x5f: KEY.SLEEP,
            0x6a: KEY.KPASTERISK, 0x6b: KEY.KPPLUS, 0x6c: KEY.KPJPCOMMA,
            0x6d: KEY.KPMINUS, 0x6e: KEY.KPDOT, 0x6f: KEY.KPSLASH, 0x90: KEY.NUMLOCK, 0x91: KEY.SCROLLLOCK,
            0xa0: KEY.LEFTSHIFT, 0xa1: KEY.RIGHTSHIFT, 0xa2: KEY.LEFTCTRL, 0xa3: KEY.RIGHTCTRL,
            0xa4: KEY.LEFTALT, 0xa5: KEY.RIGHTALT,
            0xa6: KEY.BACK, 0xa7: KEY.FORWARD, 0xa8: KEY.REFRESH, 0xa9: KEY.STOP,
            0xaa: KEY.SEARCH, 0xab: KEY.BOOKMARKS, 0xac: KEY.HOMEPAGE,
            0xad: KEY.MUTE, 0xae: KEY.VOLUMEDOWN, 0xaf: KEY.VOLUMEUP,
            0xb0: KEY.NEXTSONG, 0xb1: KEY.PREVIOUSSONG, 0xb2: KEY.STOPCD, 0xb3: KEY.PLAYPAUSE,
            0xb4: KEY.MAIL, 0xb5: KEY.MEDIA, 0xb6: KEY.COMPUTER, 0xb7: KEY.COMPUTER,
            0xba: KEY.SEMICOLON, 0xbb: KEY.EQUAL, 0xbc: KEY.COMMA, 0xbd: KEY.MINUS,
            0xbe: KEY.DOT, 0xbf: KEY.SLASH, 0xc0: KEY.GRAVE, 0xdb: KEY.LEFTBRACE,
            0xdc: KEY.BACKSLASH, 0xdd: KEY.RIGHTBRACE, 0xde: KEY.APOSTROPHE, 0xe2: KEY._102ND,
        ]
        let letters = [KEY.A, KEY.B, KEY.C, KEY.D, KEY.E, KEY.F, KEY.G, KEY.H, KEY.I, KEY.J,
                       KEY.K, KEY.L, KEY.M, KEY.N, KEY.O, KEY.P, KEY.Q, KEY.R, KEY.S, KEY.T,
                       KEY.U, KEY.V, KEY.W, KEY.X, KEY.Y, KEY.Z]
        let digits = [KEY._0, KEY._1, KEY._2, KEY._3, KEY._4, KEY._5, KEY._6, KEY._7, KEY._8, KEY._9]
        let keypad = [KEY.KP0, KEY.KP1, KEY.KP2, KEY.KP3, KEY.KP4, KEY.KP5, KEY.KP6, KEY.KP7, KEY.KP8, KEY.KP9]
        let functions = [KEY.F1, KEY.F2, KEY.F3, KEY.F4, KEY.F5, KEY.F6, KEY.F7, KEY.F8,
                         KEY.F9, KEY.F10, KEY.F11, KEY.F12, KEY.F13, KEY.F14, KEY.F15, KEY.F16,
                         KEY.F17, KEY.F18, KEY.F19, KEY.F20, KEY.F21, KEY.F22, KEY.F23, KEY.F24]
        for (i, code) in letters.enumerated() { t[0x41 + UInt16(i)] = code }
        for (i, code) in digits.enumerated() { t[0x30 + UInt16(i)] = code }
        for (i, code) in keypad.enumerated() { t[0x60 + UInt16(i)] = code }
        for (i, code) in functions.enumerated() { t[0x70 + UInt16(i)] = code }
        return t
    }()

    /// Device-dependent modifier bits (IOLLEvent.h NX_DEVICE*KEYMASK) per modifier keycode.
    static func modifierMask(_ keyCode: UInt16) -> UInt? {
        switch Int(keyCode) {
        case kVK_Control: return 0x0001
        case kVK_Shift: return 0x0002
        case kVK_RightShift: return 0x0004
        case kVK_Command: return 0x0008
        case kVK_RightCommand: return 0x0010
        case kVK_Option: return 0x0020
        case kVK_RightOption: return 0x0040
        case kVK_RightControl: return 0x2000
        default: return nil
        }
    }
}
