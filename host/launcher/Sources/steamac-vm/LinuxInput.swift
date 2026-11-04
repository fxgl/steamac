// Linux input-event-codes.h subset (uapi/linux/input-event-codes.h).
enum EV {
    static let SYN: UInt16 = 0x00
    static let KEY: UInt16 = 0x01
    static let REL: UInt16 = 0x02
    static let ABS: UInt16 = 0x03
    static let MSC: UInt16 = 0x04
    static let REP: UInt16 = 0x14
}

enum SYN { static let REPORT: UInt16 = 0 }

enum REL {
    static let X: UInt16 = 0x00
    static let Y: UInt16 = 0x01
    static let HWHEEL: UInt16 = 0x06
    static let WHEEL: UInt16 = 0x08
    static let WHEEL_HI_RES: UInt16 = 0x0b
    static let HWHEEL_HI_RES: UInt16 = 0x0c
}

enum ABS {
    static let X: UInt16 = 0x00
    static let Y: UInt16 = 0x01
    static let Z: UInt16 = 0x02
    static let RX: UInt16 = 0x03
    static let RY: UInt16 = 0x04
    static let RZ: UInt16 = 0x05
    static let HAT0X: UInt16 = 0x10
    static let HAT0Y: UInt16 = 0x11
}

enum BTN {
    static let LEFT: UInt16 = 0x110
    static let RIGHT: UInt16 = 0x111
    static let MIDDLE: UInt16 = 0x112
    static let SIDE: UInt16 = 0x113
    static let EXTRA: UInt16 = 0x114
    // Gamepad. xpad (Xbox) reports its X/Y buttons as BTN_X/BTN_Y = 0x133/0x134 ("NORTH"/"WEST"
    // below, numerically); hid-playstation reports the face buttons by position: triangle
    // BTN_NORTH (0x133), square BTN_WEST (0x134).
    static let SOUTH: UInt16 = 0x130   // BTN_A
    static let EAST: UInt16 = 0x131    // BTN_B
    static let NORTH: UInt16 = 0x133   // BTN_X
    static let WEST: UInt16 = 0x134    // BTN_Y
    static let TL: UInt16 = 0x136
    static let TR: UInt16 = 0x137
    static let TL2: UInt16 = 0x138
    static let TR2: UInt16 = 0x139
    static let SELECT: UInt16 = 0x13a
    static let START: UInt16 = 0x13b
    static let MODE: UInt16 = 0x13c
    static let THUMBL: UInt16 = 0x13d
    static let THUMBR: UInt16 = 0x13e
}

enum BUS {
    static let USB: UInt16 = 0x03
    static let VIRTUAL: UInt16 = 0x06
}

// KEY_* codes used by the keymap.
enum KEY {
    static let ESC: UInt16 = 1
    static let _1: UInt16 = 2, _2: UInt16 = 3, _3: UInt16 = 4, _4: UInt16 = 5, _5: UInt16 = 6
    static let _6: UInt16 = 7, _7: UInt16 = 8, _8: UInt16 = 9, _9: UInt16 = 10, _0: UInt16 = 11
    static let MINUS: UInt16 = 12, EQUAL: UInt16 = 13, BACKSPACE: UInt16 = 14, TAB: UInt16 = 15
    static let Q: UInt16 = 16, W: UInt16 = 17, E: UInt16 = 18, R: UInt16 = 19, T: UInt16 = 20
    static let Y: UInt16 = 21, U: UInt16 = 22, I: UInt16 = 23, O: UInt16 = 24, P: UInt16 = 25
    static let LEFTBRACE: UInt16 = 26, RIGHTBRACE: UInt16 = 27, ENTER: UInt16 = 28, LEFTCTRL: UInt16 = 29
    static let A: UInt16 = 30, S: UInt16 = 31, D: UInt16 = 32, F: UInt16 = 33, G: UInt16 = 34
    static let H: UInt16 = 35, J: UInt16 = 36, K: UInt16 = 37, L: UInt16 = 38
    static let SEMICOLON: UInt16 = 39, APOSTROPHE: UInt16 = 40, GRAVE: UInt16 = 41, LEFTSHIFT: UInt16 = 42
    static let BACKSLASH: UInt16 = 43
    static let Z: UInt16 = 44, X: UInt16 = 45, C: UInt16 = 46, V: UInt16 = 47, B: UInt16 = 48
    static let N: UInt16 = 49, M: UInt16 = 50
    static let COMMA: UInt16 = 51, DOT: UInt16 = 52, SLASH: UInt16 = 53, RIGHTSHIFT: UInt16 = 54
    static let KPASTERISK: UInt16 = 55, LEFTALT: UInt16 = 56, SPACE: UInt16 = 57, CAPSLOCK: UInt16 = 58
    static let F1: UInt16 = 59, F2: UInt16 = 60, F3: UInt16 = 61, F4: UInt16 = 62, F5: UInt16 = 63
    static let F6: UInt16 = 64, F7: UInt16 = 65, F8: UInt16 = 66, F9: UInt16 = 67, F10: UInt16 = 68
    static let NUMLOCK: UInt16 = 69, SCROLLLOCK: UInt16 = 70
    static let KP7: UInt16 = 71, KP8: UInt16 = 72, KP9: UInt16 = 73, KPMINUS: UInt16 = 74
    static let KP4: UInt16 = 75, KP5: UInt16 = 76, KP6: UInt16 = 77, KPPLUS: UInt16 = 78
    static let KP1: UInt16 = 79, KP2: UInt16 = 80, KP3: UInt16 = 81, KP0: UInt16 = 82, KPDOT: UInt16 = 83
    static let _102ND: UInt16 = 86, F11: UInt16 = 87, F12: UInt16 = 88, RO: UInt16 = 89
    static let KPJPCOMMA: UInt16 = 95
    static let KPENTER: UInt16 = 96, RIGHTCTRL: UInt16 = 97, KPSLASH: UInt16 = 98, SYSRQ: UInt16 = 99
    static let RIGHTALT: UInt16 = 100
    static let HOME: UInt16 = 102, UP: UInt16 = 103, PAGEUP: UInt16 = 104, LEFT: UInt16 = 105
    static let RIGHT: UInt16 = 106, END: UInt16 = 107, DOWN: UInt16 = 108, PAGEDOWN: UInt16 = 109
    static let INSERT: UInt16 = 110, DELETE: UInt16 = 111
    static let MUTE: UInt16 = 113, VOLUMEDOWN: UInt16 = 114, VOLUMEUP: UInt16 = 115, POWER: UInt16 = 116
    static let KPEQUAL: UInt16 = 117
    static let PAUSE: UInt16 = 119
    static let HANGEUL: UInt16 = 122, HANJA: UInt16 = 123, YEN: UInt16 = 124
    static let LEFTMETA: UInt16 = 125, RIGHTMETA: UInt16 = 126, COMPOSE: UInt16 = 127
    static let STOP: UInt16 = 128, HELP: UInt16 = 138, SLEEP: UInt16 = 142
    static let MAIL: UInt16 = 155, BOOKMARKS: UInt16 = 156, COMPUTER: UInt16 = 157
    static let BACK: UInt16 = 158, FORWARD: UInt16 = 159, NEXTSONG: UInt16 = 163, PLAYPAUSE: UInt16 = 164
    static let PREVIOUSSONG: UInt16 = 165, STOPCD: UInt16 = 166, HOMEPAGE: UInt16 = 172, REFRESH: UInt16 = 173
    static let F13: UInt16 = 183, F14: UInt16 = 184, F15: UInt16 = 185, F16: UInt16 = 186
    static let F17: UInt16 = 187, F18: UInt16 = 188, F19: UInt16 = 189, F20: UInt16 = 190
    static let F21: UInt16 = 191, F22: UInt16 = 192, F23: UInt16 = 193, F24: UInt16 = 194
    static let SEARCH: UInt16 = 217, MEDIA: UInt16 = 226
}
