import AppKit
import Foundation
import MK750Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared app types

enum AppSection: String, CaseIterable, Identifiable, Hashable {
  case lighting
  case keymap
  case macros
  case device

  var id: String { rawValue }

  var title: String {
    switch self {
    case .lighting: "Lighting"
    case .keymap: "Keymap"
    case .macros: "Macros"
    case .device: "Device"
    }
  }

  var systemImage: String {
    switch self {
    case .lighting: "lightbulb"
    case .keymap: "keyboard"
    case .macros: "list.number"
    case .device: "gearshape"
    }
  }
}

enum ConnectionPhase: Equatable {
  case disconnected
  case connecting
  case connected

  var title: String {
    switch self {
    case .disconnected: "Disconnected"
    case .connecting: "Connecting"
    case .connected: "Connected"
    }
  }

  var symbol: String {
    switch self {
    case .disconnected: "bolt.slash"
    case .connecting: "arrow.triangle.2.circlepath"
    case .connected: "checkmark.circle"
    }
  }
}

struct Notice: Identifiable, Equatable {
  enum Kind: Equatable {
    case success
    case warning
    case failure
  }

  enum Action: String, Equatable {
    case reconnect
    case restoreFocus
    case openBackups
  }

  let id = UUID()
  var kind: Kind
  var title: String
  var message: String
  var action: Action?

  static func success(_ title: String, _ message: String) -> Notice {
    Notice(kind: .success, title: title, message: message, action: nil)
  }

  static func warning(_ title: String, _ message: String, action: Action? = nil) -> Notice {
    Notice(kind: .warning, title: title, message: message, action: action)
  }

  static func failure(_ title: String, _ message: String, action: Action? = nil) -> Notice {
    Notice(kind: .failure, title: title, message: message, action: action)
  }

  var symbol: String {
    switch kind {
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .failure: "xmark.octagon"
    }
  }
}

// MARK: - Hex and colour helpers

enum Hex {
  static func string(_ bytes: [UInt8], separator: String = " ") -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: separator)
  }

  /// Accepts "0a010000", "0a 01 00 00", "0x0a,0x01,0x00,0x00", or mixed whitespace.
  static func parse(_ text: String) -> [UInt8]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ":" })
    if tokens.count > 1 {
      var result: [UInt8] = []
      result.reserveCapacity(tokens.count)
      for token in tokens {
        var value = String(token).lowercased()
        if value.hasPrefix("0x") { value.removeFirst(2) }
        guard (1...2).contains(value.count), let byte = UInt8(value, radix: 16) else {
          return nil
        }
        result.append(byte)
      }
      return result
    }

    var value = trimmed.lowercased()
    if value.hasPrefix("0x") { value.removeFirst(2) }
    value.removeAll { $0.isWhitespace }
    guard !value.isEmpty else { return nil }
    if !value.count.isMultiple(of: 2) {
      value = "0" + value
    }
    var result: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      result.append(byte)
      index = next
    }
    return result
  }
}

struct RGB: Equatable, Hashable {
  var red: UInt8
  var green: UInt8
  var blue: UInt8

  init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  init?(hex: String) {
    var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
    red = UInt8((number >> 16) & 0xFF)
    green = UInt8((number >> 8) & 0xFF)
    blue = UInt8(number & 0xFF)
  }

  init(color: Color) {
    let converted =
      NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    func component(_ value: CGFloat) -> UInt8 {
      UInt8(max(0, min(255, (value * 255).rounded())))
    }
    red = component(converted.redComponent)
    green = component(converted.greenComponent)
    blue = component(converted.blueComponent)
  }

  var hexString: String {
    String(format: "#%02X%02X%02X", red, green, blue)
  }

  var color: Color {
    Color(
      .sRGB,
      red: Double(red) / 255,
      green: Double(green) / 255,
      blue: Double(blue) / 255,
      opacity: 1
    )
  }
}

// MARK: - Lighting models

struct LightDraft: Equatable {
  var mode: UInt8 = 1
  var speed: UInt8 = 0
  var brightness: UInt8 = 2
  var flags: UInt8 = 0x07
  var rgb = RGB(red: 255, green: 176, blue: 96)

  init(state: LightState) {
    mode = state.mode
    speed = state.speed
    brightness = state.brightness
    flags = state.flags
    rgb = RGB(red: state.red, green: state.green, blue: state.blue)
  }

  var state: LightState {
    LightState(
      mode: mode,
      speed: speed,
      brightness: brightness,
      flags: flags,
      red: rgb.red,
      green: rgb.green,
      blue: rgb.blue
    )
  }

  var lowFlag: UInt8 { flags & 0x0F }
  var optionNibble: UInt8 { flags >> 4 }

  mutating func setLowFlag(_ value: UInt8) {
    flags = (flags & 0xF0) | (value & 0x0F)
  }

  mutating func setOptionNibble(_ value: UInt8) {
    flags = (flags & 0x0F) | ((value & 0x0F) << 4)
  }
}

struct LightingMode: Identifiable, Hashable {
  let id: UInt8
  let name: String
}

enum LightingModes {
  static let main: [LightingMode] = [
    LightingMode(id: 1, name: "Static"),
    LightingMode(id: 2, name: "Breathing"),
    LightingMode(id: 3, name: "Spectrum"),
    LightingMode(id: 4, name: "Wave"),
    LightingMode(id: 5, name: "Ripple"),
    LightingMode(id: 6, name: "Star dots"),
    LightingMode(id: 7, name: "Flow"),
    LightingMode(id: 8, name: "Key shadow"),
    LightingMode(id: 9, name: "Layers"),
    LightingMode(id: 10, name: "Sine"),
    LightingMode(id: 11, name: "Spring"),
    LightingMode(id: 12, name: "Neon"),
    LightingMode(id: 14, name: "Radiant"),
    LightingMode(id: 15, name: "Loop"),
    LightingMode(id: 16, name: "Colour grid"),
    LightingMode(id: 17, name: "Snowfall"),
    LightingMode(id: 18, name: "Meteor"),
    LightingMode(id: 19, name: "Silent snow"),
    LightingMode(id: 23, name: "Train"),
    LightingMode(id: 24, name: "Endless"),
  ]

  static let side: [LightingMode] = [
    LightingMode(id: 0, name: "Off"),
    LightingMode(id: 1, name: "Static"),
    LightingMode(id: 2, name: "Breathing"),
    LightingMode(id: 3, name: "Neon"),
    LightingMode(id: 4, name: "Wave"),
    LightingMode(id: 5, name: "Snake"),
  ]

  static func modes(for channel: LightChannel) -> [LightingMode] {
    channel.isMain ? main : side
  }

  static func name(for mode: UInt8, channel: LightChannel) -> String {
    modes(for: channel).first(where: { $0.id == mode })?.name ?? "Mode \(mode) (unlisted)"
  }
}

struct FlagOption: Identifiable, Hashable {
  let id: UInt8
  let name: String
}

enum FlagOptions {
  static let all: [FlagOption] = [
    FlagOption(id: 0, name: "Preset red"),
    FlagOption(id: 1, name: "Preset orange"),
    FlagOption(id: 2, name: "Preset yellow"),
    FlagOption(id: 3, name: "Preset green"),
    FlagOption(id: 4, name: "Preset cyan"),
    FlagOption(id: 5, name: "Preset blue"),
    FlagOption(id: 6, name: "Preset magenta"),
    FlagOption(id: 7, name: "Fixed custom colour"),
    FlagOption(id: 8, name: "Rainbow"),
  ]

  static func name(for value: UInt8) -> String {
    all.first(where: { $0.id == value })?.name ?? String(format: "Unrecognised flag 0x%X", value)
  }
}

extension LightChannel {
  var isMain: Bool {
    switch self {
    case .main: true
    case .side: false
    }
  }

  var displayName: String {
    isMain ? "Backlight" : "Side light"
  }

  var summary: String {
    isMain ? "Main backlight" : "Edge light"
  }
}

// MARK: - Keymap names and slot codec

enum KeyNames {
  static let keyboard: [UInt8: String] = [
    0x04: "A", 0x05: "B", 0x06: "C", 0x07: "D", 0x08: "E",
    0x09: "F", 0x0A: "G", 0x0B: "H", 0x0C: "I", 0x0D: "J",
    0x0E: "K", 0x0F: "L", 0x10: "M", 0x11: "N", 0x12: "O",
    0x13: "P", 0x14: "Q", 0x15: "R", 0x16: "S", 0x17: "T",
    0x18: "U", 0x19: "V", 0x1A: "W", 0x1B: "X", 0x1C: "Y",
    0x1D: "Z",
    0x1E: "1", 0x1F: "2", 0x20: "3", 0x21: "4", 0x22: "5",
    0x23: "6", 0x24: "7", 0x25: "8", 0x26: "9", 0x27: "0",
    0x28: "Return", 0x29: "Escape", 0x2A: "Delete", 0x2B: "Tab",
    0x2C: "Space", 0x2D: "Minus", 0x2E: "Equal", 0x2F: "Left bracket",
    0x30: "Right bracket", 0x31: "Backslash", 0x32: "Non-US hash",
    0x33: "Semicolon", 0x34: "Quote", 0x35: "Grave", 0x36: "Comma",
    0x37: "Period", 0x38: "Slash", 0x39: "Caps Lock",
    0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4", 0x3E: "F5",
    0x3F: "F6", 0x40: "F7", 0x41: "F8", 0x42: "F9", 0x43: "F10",
    0x44: "F11", 0x45: "F12", 0x46: "Print Screen", 0x47: "Scroll Lock",
    0x48: "Pause", 0x49: "Insert", 0x4A: "Home", 0x4B: "Page Up",
    0x4C: "Delete Forward", 0x4D: "End", 0x4E: "Page Down",
    0x4F: "Right Arrow", 0x50: "Left Arrow", 0x51: "Down Arrow",
    0x52: "Up Arrow", 0x53: "Num Lock", 0x54: "Keypad /",
    0x55: "Keypad *", 0x56: "Keypad -", 0x57: "Keypad +",
    0x58: "Keypad Enter", 0x59: "Keypad 1", 0x5A: "Keypad 2",
    0x5B: "Keypad 3", 0x5C: "Keypad 4", 0x5D: "Keypad 5",
    0x5E: "Keypad 6", 0x5F: "Keypad 7", 0x60: "Keypad 8",
    0x61: "Keypad 9", 0x62: "Keypad 0", 0x63: "Keypad .",
    0x64: "Non-US backslash", 0x65: "Application", 0x66: "Power",
    0x67: "Keypad =", 0x68: "F13", 0x69: "F14", 0x6A: "F15",
    0x6B: "F16", 0x6C: "F17", 0x6D: "F18", 0x6E: "F19",
    0x6F: "F20", 0x70: "F21", 0x71: "F22", 0x72: "F23",
    0x73: "F24", 0x74: "Execute", 0x75: "Help", 0x76: "Menu",
    0x77: "Select", 0x78: "Stop", 0x79: "Again", 0x7A: "Undo",
    0x7B: "Cut", 0x7C: "Copy", 0x7D: "Paste", 0x7E: "Find",
    0x7F: "Mute", 0x80: "Volume Up", 0x81: "Volume Down",
    0x82: "Locking Caps Lock", 0x83: "Locking Num Lock",
    0x84: "Locking Scroll Lock", 0x85: "Keypad Comma",
    0x86: "Keypad = (AS/400)", 0x87: "International 1",
    0x88: "International 2", 0x89: "International 3",
    0x8A: "International 4", 0x8B: "International 5",
    0x8C: "International 6", 0x8D: "International 7",
    0x8E: "International 8", 0x8F: "International 9",
    0x90: "Language 1", 0x91: "Language 2", 0x92: "Language 3",
    0x93: "Language 4", 0x94: "Language 5", 0x95: "Language 6",
    0x96: "Language 7", 0x97: "Language 8", 0x98: "Language 9",
    0x99: "Alternate Erase", 0x9A: "SysReq/Attention",
    0x9B: "Cancel", 0x9C: "Clear", 0x9D: "Prior", 0x9E: "Return",
    0x9F: "Separator", 0xA0: "Out", 0xA1: "Oper", 0xA2: "Clear/Again",
    0xA3: "CrSel/Props", 0xA4: "ExSel", 0xB0: "Keypad 00",
    0xB1: "Keypad 000", 0xB2: "Thousands separator",
    0xB3: "Decimal separator", 0xB4: "Currency unit",
    0xB5: "Currency sub-unit", 0xB6: "Keypad (", 0xB7: "Keypad )",
    0xB8: "Keypad {", 0xB9: "Keypad }", 0xBA: "Keypad Tab",
    0xBB: "Keypad Backspace", 0xBC: "Keypad A", 0xBD: "Keypad B",
    0xBE: "Keypad C", 0xBF: "Keypad D", 0xC0: "Keypad E",
    0xC1: "Keypad F", 0xC2: "Keypad XOR", 0xC3: "Keypad ^",
    0xC4: "Keypad %", 0xC5: "Keypad <", 0xC6: "Keypad >",
    0xC7: "Keypad &", 0xC8: "Keypad &&", 0xC9: "Keypad |",
    0xCA: "Keypad ||", 0xCB: "Keypad :", 0xCC: "Keypad #",
    0xCD: "Keypad Space", 0xCE: "Keypad @", 0xCF: "Keypad !",
    0xD0: "Keypad Memory Store", 0xD1: "Keypad Memory Recall",
    0xD2: "Keypad Memory Clear", 0xD3: "Keypad Memory Add",
    0xD4: "Keypad Memory Subtract", 0xD5: "Keypad Memory Multiply",
    0xD6: "Keypad Memory Divide", 0xD7: "Keypad +/-",
    0xD8: "Keypad Clear", 0xD9: "Keypad Clear Entry",
    0xDA: "Keypad Binary", 0xDB: "Keypad Octal",
    0xDC: "Keypad Decimal", 0xDD: "Keypad Hexadecimal",
    0xE0: "Left Control", 0xE1: "Left Shift", 0xE2: "Left Option",
    0xE3: "Left Command", 0xE4: "Right Control", 0xE5: "Right Shift",
    0xE6: "Right Option", 0xE7: "Right Command",
  ]

  static let consumer: [UInt16: String] = [
    0x006F: "Brightness Down",
    0x0070: "Brightness Up",
    0x00B5: "Next Track",
    0x00B6: "Previous Track",
    0x00B7: "Stop",
    0x00CD: "Play/Pause",
    0x00E2: "Mute",
    0x00E9: "Volume Up",
    0x00EA: "Volume Down",
    0x018A: "Browser",
    0x0223: "Home",
    0x0224: "Back",
    0x0225: "Forward",
  ]

  static let special: [UInt8: String] = [
    1: "Fn",
    8: "Fn + Backspace (observed)",
    12: "Power save",
    13: "Fn + Esc (observed)",
    17: "Caps LED swap",
  ]

  static func keyboardName(_ usage: UInt8) -> String {
    keyboard[usage] ?? String(format: "HID usage 0x%02X", usage)
  }

  static func consumerName(_ usage: UInt16) -> String {
    consumer[usage] ?? String(format: "Consumer 0x%04X", usage)
  }

  static func specialName(_ code: UInt8) -> String {
    special[code] ?? String(format: "Special code %d", code)
  }

  static func macroCodeName(_ code: UInt8) -> String {
    switch code {
    case 0xF0: "Mouse left button"
    case 0xF1: "Mouse right button"
    case 0xF2: "Mouse middle button"
    case 0xF3: "Mouse button 4"
    case 0xF4: "Mouse button 5"
    case 0xF9: "Mouse move"
    default: keyboardName(code)
    }
  }
}

enum KeySlotKind: String, CaseIterable, Identifiable, Hashable {
  case keyboard
  case consumer
  case macro
  case special
  case transparent
  case raw

  var id: String { rawValue }

  var title: String {
    switch self {
    case .keyboard: "Keyboard usage"
    case .consumer: "Consumer usage"
    case .macro: "Macro binding"
    case .special: "Special action"
    case .transparent: "Transparent / none"
    case .raw: "Raw 4 bytes (advanced)"
    }
  }
}

struct KeySlotValue: Equatable {
  var kind: KeySlotKind = .transparent
  var keyboardUsage: UInt8 = 0
  var consumerUsage: UInt16 = 0
  var macroMode: UInt8 = 0
  var macroSlot: UInt8 = 0
  var specialCode: UInt8 = 0
  var rawBytes: [UInt8] = [0, 0, 0, 0]

  init(bytes: [UInt8]) {
    let padded = Array(bytes.prefix(4)) + Array(repeating: 0, count: max(0, 4 - bytes.count))
    rawBytes = padded
    let type = padded[0]
    switch type {
    case 0x00:
      if padded == [0, 0, 0, 0] {
        kind = .transparent
      } else if padded[1] == 0, padded[3] == 0 {
        kind = .keyboard
        keyboardUsage = padded[2]
      } else {
        kind = .raw
      }
    case 0x03:
      kind = .consumer
      consumerUsage = UInt16(padded[2]) | (UInt16(padded[3]) << 8)
    case 0x09:
      kind = .macro
      macroMode = padded[1]
      macroSlot = padded[2]
    case 0x0A:
      kind = .special
      specialCode = padded[1]
    default:
      kind = .raw
    }
  }

  var bytes: [UInt8] {
    switch kind {
    case .keyboard:
      [0x00, 0x00, keyboardUsage, 0x00]
    case .consumer:
      [0x03, 0x00, UInt8(consumerUsage & 0xFF), UInt8(consumerUsage >> 8)]
    case .macro:
      [0x09, macroMode, macroSlot, 0x00]
    case .special:
      [0x0A, specialCode, 0x00, 0x00]
    case .transparent:
      [0x00, 0x00, 0x00, 0x00]
    case .raw:
      Array(rawBytes.prefix(4)) + Array(repeating: 0, count: max(0, 4 - rawBytes.count))
    }
  }

  var summary: String {
    switch kind {
    case .keyboard:
      KeyNames.keyboardName(keyboardUsage)
    case .consumer:
      KeyNames.consumerName(consumerUsage)
    case .macro:
      "Macro \(macroSlot) · \(Self.macroModeName(macroMode))"
    case .special:
      KeyNames.specialName(specialCode)
    case .transparent:
      "Transparent / none"
    case .raw:
      rawSummary
    }
  }

  var rawSummary: String {
    let hex = Hex.string(rawBytes)
    switch rawBytes.first ?? 0 {
    case 0x01: return "Mouse button (raw \(hex))"
    case 0x0D: return "Extended Fn action (raw \(hex))"
    case 0x0E: return "Wireless channel (raw \(hex))"
    case 0x0A: return "Special action (raw \(hex))"
    default: return "Unknown type (raw \(hex))"
    }
  }

  static func macroModeName(_ mode: UInt8) -> String {
    switch mode {
    case 0: "Repeat"
    case 1: "Toggle"
    case 2: "Hold"
    default: "Mode \(mode)"
    }
  }
}

extension KeyLayer {
  var isBase: Bool {
    switch self {
    case .base: true
    case .fn: false
    }
  }

  var displayName: String {
    isBase ? "Base layer" : "Fn layer"
  }
}

// MARK: - Persisted documents

struct NamedScene: Identifiable, Codable, Equatable {
  var id: UUID
  var name: String
  var main: LightState
  var side: LightState
}

struct ScenesFile: Codable {
  var schemaVersion: Int
  var customScenes: [NamedScene]

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case customScenes
  }

  init(schemaVersion: Int = 1, customScenes: [NamedScene]) {
    self.schemaVersion = schemaVersion
    self.customScenes = customScenes
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    customScenes = try container.decode([NamedScene].self, forKey: .customScenes)
  }
}

enum FocusStatus: String, Codable, Equatable {
  case active
  case restorationPending
}

struct FocusSession: Codable, Equatable {
  var schemaVersion: Int = 1
  var startedAt: Date
  var deadline: Date
  var savedMain: LightState
  var savedSide: LightState
  var status: FocusStatus
  var calmApplied: Bool
  var lastFailure: String?

  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case startedAt
    case deadline
    case savedMain
    case savedSide
    case status
    case calmApplied
    case lastFailure
  }

  init(
    startedAt: Date,
    deadline: Date,
    savedMain: LightState,
    savedSide: LightState,
    status: FocusStatus,
    calmApplied: Bool,
    lastFailure: String? = nil
  ) {
    self.startedAt = startedAt
    self.deadline = deadline
    self.savedMain = savedMain
    self.savedSide = savedSide
    self.status = status
    self.calmApplied = calmApplied
    self.lastFailure = lastFailure
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    deadline = try container.decode(Date.self, forKey: .deadline)
    savedMain = try container.decode(LightState.self, forKey: .savedMain)
    savedSide = try container.decode(LightState.self, forKey: .savedSide)
    status = try container.decodeIfPresent(FocusStatus.self, forKey: .status) ?? .restorationPending
    calmApplied = try container.decodeIfPresent(Bool.self, forKey: .calmApplied) ?? false
    lastFailure = try container.decodeIfPresent(String.self, forKey: .lastFailure)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(deadline, forKey: .deadline)
    try container.encode(savedMain, forKey: .savedMain)
    try container.encode(savedSide, forKey: .savedSide)
    try container.encode(status, forKey: .status)
    try container.encode(calmApplied, forKey: .calmApplied)
    if let lastFailure {
      try container.encode(lastFailure, forKey: .lastFailure)
    } else {
      try container.encodeNil(forKey: .lastFailure)
    }
  }
}

struct KeymapArchive: Codable {
  var schemaVersion: Int
  var app: String
  var createdAt: Date
  var boardID: UInt32?
  var firmware: String?
  var profile: UInt8
  var baseHex: String
  var fnHex: String

  enum ArchiveError: LocalizedError {
    case unsupportedSchema(Int)
    case wrongApplication(String)
    case wrongLengths(base: Int, fn: Int)
    case invalidHex(String)
    case unwritableProfile(UInt8)
    case boardMismatch(expected: UInt32, found: UInt32)

    var errorDescription: String? {
      switch self {
      case .unsupportedSchema(let version):
        "Unsupported keymap archive schema version \(version)."
      case .wrongApplication(let app):
        "This file was produced by “\(app)”, not the MK750 keymap archive schema."
      case .wrongLengths(let base, let fn):
        "A keymap archive must contain 512 base bytes and 512 Fn bytes; this file has \(base) and \(fn)."
      case .invalidHex(let layer):
        "The \(layer) layer is not valid hexadecimal."
      case .unwritableProfile(let profile):
        "Profile \(profile) is read-only. Only profiles 0 and 1 can be restored."
      case .boardMismatch(let expected, let found):
        "This archive was exported from board \(found); the connected keyboard reports board \(expected)."
      }
    }
  }

  func validatedKeymap(connectedBoard: UInt32?) throws -> Keymap {
    guard schemaVersion == 1 else {
      throw ArchiveError.unsupportedSchema(schemaVersion)
    }
    guard app == "MK750" else {
      throw ArchiveError.wrongApplication(app)
    }
    guard profile <= 1 else {
      throw ArchiveError.unwritableProfile(profile)
    }
    guard let base = Hex.parse(baseHex), let fn = Hex.parse(fnHex) else {
      throw ArchiveError.invalidHex("base or Fn")
    }
    guard base.count == 512, fn.count == 512 else {
      throw ArchiveError.wrongLengths(base: base.count, fn: fn.count)
    }
    if let archiveBoard = boardID, let connectedBoard, archiveBoard != connectedBoard {
      throw ArchiveError.boardMismatch(expected: connectedBoard, found: archiveBoard)
    }
    return Keymap(profile: profile, base: base, fn: fn)
  }
}

struct DeviceSettings: Equatable {
  var profile: UInt8
  var debounce: UInt8
  var sleep: SleepTimers
  var autoOS: Bool
  var options: UInt8

  init(profile: UInt8, debounce: UInt8, sleep: SleepTimers, autoOS: Bool, options: UInt8) {
    self.profile = profile
    self.debounce = debounce
    self.sleep = sleep
    self.autoOS = autoOS
    self.options = options
  }

  init(snapshot: DeviceSnapshot) {
    profile = snapshot.profile
    debounce = snapshot.debounce
    sleep = snapshot.sleep
    autoOS = snapshot.autoOS
    options = snapshot.options
  }
}

struct OptionBit: Identifiable {
  let mask: UInt8
  let title: String
  let detail: String

  var id: UInt8 { mask }
}

enum OptionBits {
  static let all: [OptionBit] = [
    OptionBit(mask: 1, title: "Win lock", detail: "Locks the Windows key."),
    OptionBit(mask: 2, title: "Mac mode", detail: "Switches the modifier layout for macOS."),
    OptionBit(mask: 8, title: "WASD swap", detail: "Swaps WASD with the arrow keys."),
    OptionBit(
      mask: 16, title: "Backlight off",
      detail: "Firmware backlight-off bit; this is not a black colour write."),
    OptionBit(mask: 32, title: "Side light off", detail: "Turns the edge light off."),
    OptionBit(mask: 64, title: "Keyboard mode", detail: "Firmware keyboard/consumer mode bit."),
    OptionBit(
      mask: 128, title: "Keyboard lock", detail: "Locks the keyboard's own keys until unlocked."),
  ]

  static let knownMask: UInt8 = 1 | 2 | 8 | 16 | 32 | 64 | 128
}

// MARK: - Store

@MainActor
final class KeyboardStore: ObservableObject {
  static let shared = KeyboardStore()

  // Application Support/ MK750/
  let supportDirectory: URL
  let scenesURL: URL
  let focusRecoveryURL: URL
  let backupsURL: URL

  @Published private(set) var snapshot: DeviceSnapshot?
  @Published private(set) var snapshotRevision = 0
  @Published private(set) var connection: ConnectionPhase = .disconnected
  @Published var section: AppSection = .lighting
  @Published private(set) var busy: String?
  @Published private(set) var isShuttingDown = false
  @Published var notice: Notice?
  @Published private(set) var customScenes: [NamedScene] = []
  @Published private(set) var focus: FocusSession?
  @Published private(set) var focusRemaining: TimeInterval = 0
  @Published private(set) var loadedKeymap: Keymap?
  @Published private(set) var keymapReadAt: Date?
  @Published private(set) var loadedMacro: [UInt8]?
  @Published private(set) var macroSlot: Int?
  @Published private(set) var lastBackupURL: URL?

  private let keyboard: Keyboard
  private var focusTimer: Timer?
  private var deferredFocusRestore: Task<Void, Never>?
  /// True while `focus` came from FocusRecovery.json rather than from a timer
  /// started in this process. Such a session may only be written by an
  /// explicit Restore; quitting preserves it instead of restoring it.
  private var recoveredFocus = false

  static let calmMain = LightState(
    mode: 1, speed: 0, brightness: 1, flags: 0x07,
    red: 255, green: 168, blue: 104
  )
  static let calmSide = LightState(
    mode: 1, speed: 0, brightness: 1, flags: 0x07,
    red: 255, green: 122, blue: 62
  )

  static let builtInScenes: [NamedScene] = [
    NamedScene(
      id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!,
      name: "Warm desk",
      main: LightState(
        mode: 1, speed: 0, brightness: 3, flags: 0x07, red: 255, green: 176, blue: 96),
      side: LightState(
        mode: 1, speed: 0, brightness: 2, flags: 0x07, red: 255, green: 112, blue: 48)
    ),
    NamedScene(
      id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000002")!,
      name: "Cool studio",
      main: LightState(
        mode: 1, speed: 0, brightness: 3, flags: 0x07, red: 168, green: 216, blue: 255),
      side: LightState(
        mode: 1, speed: 0, brightness: 2, flags: 0x07, red: 64, green: 156, blue: 255)
    ),
    NamedScene(
      id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000003")!,
      name: "Midnight",
      main: LightState(
        mode: 1, speed: 0, brightness: 1, flags: 0x07, red: 72, green: 96, blue: 192),
      side: LightState(mode: 1, speed: 0, brightness: 1, flags: 0x07, red: 24, green: 96, blue: 112)
    ),
    NamedScene(
      id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000004")!,
      name: "Paper",
      main: LightState(
        mode: 1, speed: 0, brightness: 2, flags: 0x07, red: 255, green: 236, blue: 210),
      side: LightState(mode: 0, speed: 0, brightness: 0, flags: 0x07, red: 0, green: 0, blue: 0)
    ),
  ]

  init(keyboard: Keyboard = Keyboard()) {
    self.keyboard = keyboard
    let fileManager = FileManager.default
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    supportDirectory = base.appendingPathComponent("MK750", isDirectory: true)
    scenesURL = supportDirectory.appendingPathComponent("Scenes.json")
    focusRecoveryURL = supportDirectory.appendingPathComponent("FocusRecovery.json")
    backupsURL = supportDirectory.appendingPathComponent("Backups", isDirectory: true)

    try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)

    loadScenes()
    loadFocusRecovery()

    Task { await self.connect() }
  }

  // MARK: Derived state

  var isBusy: Bool { busy != nil || connection == .connecting || isShuttingDown }

  var allScenes: [NamedScene] { Self.builtInScenes + customScenes }

  var hasPendingFocusRestore: Bool {
    focus?.status == .restorationPending
  }

  var focusCountdownText: String {
    guard let focus else { return "" }
    if focus.status == .restorationPending { return "Restore pending" }
    let total = max(0, Int(focusRemaining.rounded(.up)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  var quickScenes: [NamedScene] { allScenes }

  // MARK: Connection

  func connect() async {
    guard !isShuttingDown, connection != .connecting else { return }
    connection = .connecting

    do {
      let fresh = try await keyboard.connect()
      setSnapshot(fresh)
      connection = .connected
      lastBackupURL = await keyboard.latestBackupURL()
      if notice == nil || notice?.kind != .failure || notice?.action == .reconnect {
        notice = .success(
          "Keyboard connected",
          "Board \(fresh.boardID), firmware \(fresh.firmware). Launch and refresh only read state; nothing was written."
        )
      }
    } catch {
      snapshot = nil
      connection = .disconnected
      notice = .failure(
        "Could not connect to the MK750",
        Self.describe(error) + " " + Self.connectionGuidance,
        action: .reconnect
      )
    }
  }

  func refresh() async {
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return
    }
    guard snapshot != nil || connection == .connected else {
      notice = .warning(
        "No keyboard connected",
        "Connect the MK750 over wired USB, then reconnect.",
        action: .reconnect
      )
      return
    }

    busy = "Reading keyboard state"
    defer { busy = nil }

    do {
      let fresh = try await keyboard.refresh()
      setSnapshot(fresh)
      connection = .connected
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Keyboard state refreshed", "Profile \(fresh.profile); debounce \(fresh.debounce) ms.")
    } catch {
      await handleFailure(error, context: "Could not read keyboard state")
    }
  }

  func disconnect() async {
    await keyboard.disconnect()
    snapshot = nil
    connection = .disconnected
    notice = .warning(
      "Keyboard disconnected",
      "Settings and keymap data already loaded stay available for review and export.")
  }

  // MARK: Lighting

  func applyLight(_ state: LightState, channel: LightChannel) async -> Bool {
    guard focus == nil else {
      notice = .warning(
        "Focus lighting is protected",
        "Finish or restore the focus session before changing lighting, so the saved states are not silently overwritten."
      )
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }

    busy = "Applying \(channel.displayName.lowercased())"
    defer { busy = nil }

    do {
      let fresh = try await keyboard.setLight(state, channel: channel)
      setSnapshot(fresh)
      connection = .connected
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "\(channel.displayName) applied",
        "The keyboard was read back after the write. Mode and flag names are reference-only; this unit verified fixed colour with flag 7."
      )
      return true
    } catch {
      await handleFailure(error, context: "Could not apply \(channel.displayName.lowercased())")
      return false
    }
  }

  func applyScene(_ scene: NamedScene) async -> Bool {
    guard focus == nil else {
      notice = .warning(
        "Focus lighting is protected",
        "Finish or restore the focus session before applying a scene, so the saved states are not silently overwritten."
      )
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }

    busy = "Applying “\(scene.name)”"
    defer { busy = nil }

    do {
      _ = try await keyboard.setLight(scene.main, channel: .main)
      let fresh = try await keyboard.setLight(scene.side, channel: .side)
      setSnapshot(fresh)
      connection = .connected
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Scene “\(scene.name)” applied",
        "Backlight and side light were set independently and read back from the keyboard."
      )
      return true
    } catch {
      await handleFailure(error, context: "Could not apply scene “\(scene.name)”")
      return false
    }
  }

  func saveScene(named rawName: String) -> Bool {
    guard let snapshot else {
      notice = .warning("No keyboard state loaded", "Connect and refresh before saving a scene.")
      return false
    }
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      notice = .warning("Scene name required", "Enter a name for the custom scene.")
      return false
    }
    guard !allScenes.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    else {
      notice = .warning(
        "Scene name already used", "Choose a different name; built-in scene names cannot be reused."
      )
      return false
    }

    let scene = NamedScene(id: UUID(), name: name, main: snapshot.main, side: snapshot.side)
    customScenes.append(scene)
    guard persistScenes() else {
      customScenes.removeAll { $0.id == scene.id }
      return false
    }
    notice = .success(
      "Scene “\(name)” saved",
      "It is stored in Scenes.json in the MK750 Application Support folder.")
    return true
  }

  func deleteScene(_ scene: NamedScene) -> Bool {
    guard let index = customScenes.firstIndex(where: { $0.id == scene.id }) else { return false }
    let removed = customScenes.remove(at: index)
    guard persistScenes() else {
      customScenes.insert(removed, at: min(index, customScenes.count))
      notice = .failure(
        "Could not delete scene", "The scene file could not be written; the deletion was not kept.")
      return false
    }
    notice = .success("Scene “\(scene.name)” deleted", "Built-in scenes cannot be deleted.")
    return true
  }

  // MARK: Focus timer

  func startFocus(minutes: Int) async -> Bool {
    guard (1...600).contains(minutes) else {
      notice = .warning("Choose a focus duration", "The timer must run between 1 and 600 minutes.")
      return false
    }
    guard focus == nil else {
      notice = .warning(
        "Focus timer already running", "Finish or restore the current session first.")
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }

    busy = "Reading lighting before focus"
    defer { busy = nil }

    // The cached snapshot can be older than the keyboard: the hardware's own
    // Fn lighting keys change these registers without going through the app.
    // Read fresh immediately before saving the restore point.
    let current: DeviceSnapshot
    do {
      current = try await keyboard.refresh()
      setSnapshot(current)
      connection = .connected
    } catch {
      await handleFailure(
        error, context: "Could not read the current lighting before starting focus")
      return false
    }

    // Quit started while the read was in flight. Nothing has been written
    // yet, so leave the lighting alone instead of starting a timer.
    guard !isShuttingDown else { return false }

    let started = Date()
    var session = FocusSession(
      startedAt: started,
      deadline: started.addingTimeInterval(TimeInterval(minutes * 60)),
      savedMain: current.main,
      savedSide: current.side,
      status: .active,
      calmApplied: false,
      lastFailure: nil
    )

    focus = session
    recoveredFocus = false
    focusRemaining = session.deadline.timeIntervalSinceNow
    guard persistFocus() else {
      focus = nil
      focusRemaining = 0
      notice = .failure(
        "Focus timer not started",
        "The recovery file could not be saved, so the exact lighting states would not be durable. Nothing was written to the keyboard."
      )
      return false
    }

    do {
      _ = try await keyboard.setLight(Self.calmMain, channel: .main)
      session.calmApplied = true
      focus = session
      let fresh = try await keyboard.setLight(Self.calmSide, channel: .side)
      setSnapshot(fresh)
      connection = .connected
      session.calmApplied = true
      focus = session
      guard persistFocus() else {
        session.status = .restorationPending
        session.lastFailure =
          "The calm lighting was applied but the recovery update could not be saved."
        focus = session
        notice = .failure(
          "Focus recovery needs attention",
          "Calm lighting was applied, but the recovery file could not be updated. Use Restore Saved Lighting now.",
          action: .restoreFocus
        )
        return false
      }
      if isShuttingDown {
        // Quit began while the calm lighting was being written. The quit
        // path owns restoration now; a countdown started here would outlive
        // the process and could race that restore.
        stopFocusTimer()
        return false
      }
      startFocusTimer()
      notice = .success(
        "Focus timer started",
        "Calm lighting was applied once. Saved lighting is restored when the timer finishes, or when you finish the session."
      )
      return true
    } catch {
      var failed = session
      failed.status = .restorationPending
      failed.lastFailure = Self.describe(error)
      focus = failed
      _ = persistFocus()
      await handleFailure(error, context: "Focus lighting could not be applied")
      if var current = notice {
        if current.kind == .failure {
          current.action = snapshot == nil ? .reconnect : .restoreFocus
          notice = current
        }
      }
      return false
    }
  }

  func restoreFocus() async -> Bool {
    guard let session = focus else { return true }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running",
        "Wait for “\(busy ?? "the current task")” to finish, then restore lighting.")
      return false
    }
    guard snapshot != nil else {
      var pending = session
      pending.status = .restorationPending
      pending.lastFailure = "The keyboard is disconnected; the saved lighting is still pending."
      focus = pending
      _ = persistFocus()
      notice = .warning(
        "Saved lighting is still pending",
        "Reconnect the MK750 over wired USB, then choose Restore Saved Lighting. Nothing is written automatically on reconnect.",
        action: .reconnect
      )
      return false
    }

    busy = "Restoring saved lighting"
    defer { busy = nil }

    do {
      _ = try await keyboard.setLight(session.savedMain, channel: .main)
      let fresh = try await keyboard.setLight(session.savedSide, channel: .side)
      setSnapshot(fresh)
      connection = .connected
      focus = nil
      recoveredFocus = false
      focusRemaining = 0
      stopFocusTimer()
      deleteFocusRecoveryFile()
      notice = .success(
        "Lighting restored",
        "Backlight and side light returned to the exact states saved when focus started."
      )
      return true
    } catch {
      var pending = session
      pending.status = .restorationPending
      pending.lastFailure = Self.describe(error)
      focus = pending
      _ = persistFocus()
      stopFocusTimer()
      await handleFailure(error, context: "Saved lighting was not restored")
      if var current = notice {
        if current.kind == .failure {
          current.action = snapshot == nil ? .reconnect : .restoreFocus
          notice = current
        }
      }
      return false
    }
  }

  func prepareForTermination() async {
    isShuttingDown = true
    stopFocusTimer()
    deferredFocusRestore?.cancel()
    deferredFocusRestore = nil

    // A multi-step lighting or scene write suspends on the actor while the
    // MainActor stays reentrant. New operations are refused from here on
    // (`isShuttingDown` is part of `isBusy`), but one may already be mid
    // write. Wait for it to actually finish before restoring: a fixed timeout
    // would let quit race the remaining SET and silently corrupt the saved
    // focus lighting.
    await waitForMutationsToSettle()

    guard let session = focus else { return }
    if recoveredFocus {
      // A session read from disk may only be written by an explicit Restore.
      // Quitting preserves it as pending instead of restoring automatically.
      var pending = session
      pending.status = .restorationPending
      focus = pending
      focusRemaining = 0
      _ = persistFocus()
      return
    }
    guard snapshot != nil else {
      var pending = session
      pending.status = .restorationPending
      pending.lastFailure = "The app quit while the keyboard was disconnected."
      focus = pending
      focusRemaining = 0
      _ = persistFocus()
      return
    }

    busy = "Restoring lighting before quit"
    defer { busy = nil }

    do {
      _ = try await keyboard.setLight(session.savedMain, channel: .main)
      _ = try await keyboard.setLight(session.savedSide, channel: .side)
      focus = nil
      focusRemaining = 0
      deleteFocusRecoveryFile()
    } catch {
      var pending = session
      pending.status = .restorationPending
      pending.lastFailure =
        "The app quit before lighting could be restored: \(Self.describe(error))"
      focus = pending
      focusRemaining = 0
      _ = persistFocus()
    }
  }

  private func waitForMutationsToSettle() async {
    // `busy` is the admission gate every write path holds for its entire
    // duration; `connection == .connecting` is a read-only connect still in
    // flight. Wait for both to clear without a timeout so termination never
    // starts restoring while a flash is still streaming.
    while busy != nil || connection == .connecting {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }

  private func startFocusTimer() {
    stopFocusTimer()
    guard let focus, focus.status == .active else { return }
    focusRemaining = max(0, focus.deadline.timeIntervalSinceNow)
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.focusTick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    focusTimer = timer
  }

  private func stopFocusTimer() {
    focusTimer?.invalidate()
    focusTimer = nil
  }

  private func focusTick() {
    if isShuttingDown {
      // A tick queued by the timer just before termination must not start a
      // second restore or rewrite the recovery file: the quit path owns the
      // session from here on.
      stopFocusTimer()
      return
    }
    guard let focus else {
      stopFocusTimer()
      return
    }
    let remaining = focus.deadline.timeIntervalSinceNow
    focusRemaining = max(0, remaining)
    guard remaining <= 0, focus.status == .active else { return }

    // The deadline is authoritative. Flip the session to pending and stop the
    // countdown even when another mutation currently owns `busy`, then restore
    // once that operation has actually finished instead of dropping the
    // automatic restore at restoreFocus's admission guard.
    var pending = focus
    pending.status = .restorationPending
    pending.lastFailure = "The focus timer finished."
    self.focus = pending
    _ = persistFocus()
    stopFocusTimer()
    deferredFocusRestore?.cancel()
    deferredFocusRestore = Task { @MainActor [weak self] in
      await self?.restoreFocusWhenIdle()
    }
  }

  /// Waits out an operation that overlapped the focus deadline. A quit leaves
  /// restoration to `prepareForTermination`, while a reconnect simply delays
  /// this attempt until the connection phase settles; the restore itself still
  /// runs through the normal admission checks.
  private func restoreFocusWhenIdle() async {
    while isBusy {
      if Task.isCancelled || isShuttingDown { return }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    guard !isShuttingDown else { return }
    _ = await restoreFocus()
  }

  // MARK: Keymap

  func loadKeymap(profile: UInt8) async {
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return
    }
    guard profile <= 3 else {
      notice = .warning(
        "Unknown profile", "Profiles 0–3 exist on this family; 0 and 1 are writable.")
      return
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return
    }

    busy = "Reading profile \(profile) keymap"
    defer { busy = nil }

    do {
      let keymap = try await keyboard.readKeymap(profile: profile)
      loadedKeymap = keymap
      keymapReadAt = Date()
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Profile \(keymap.profile) keymap read",
        keymap.profile <= 1
          ? "Both 512-byte layers were read. Reading does not write to the keyboard."
          : "This profile is read-only here; its Fn storage is not a valid keymap on this family."
      )
    } catch {
      await handleFailure(error, context: "Could not read the keymap")
    }
  }

  func writeKey(profile: UInt8, layer: KeyLayer, slot: Int, value: [UInt8]) async -> Bool {
    guard let loadedKeymap else {
      notice = .warning("No keymap loaded", "Read a profile before editing a slot.")
      return false
    }
    guard loadedKeymap.profile == profile else {
      notice = .warning(
        "Loaded keymap does not match",
        "The loaded keymap is profile \(loadedKeymap.profile). Read profile \(profile) first, then edit its slots."
      )
      return false
    }
    guard profile <= 1 else {
      notice = .warning("Read-only profile", "Only profiles 0 and 1 can be written.")
      return false
    }
    guard (0..<128).contains(slot), value.count == 4 else {
      notice = .warning(
        "Invalid slot", "Slots run from 0 to 127 and each value is exactly four bytes.")
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }

    busy = "Writing profile \(profile) \(layer.displayName.lowercased()) slot \(slot)"
    defer { busy = nil }

    do {
      let updated = try await keyboard.writeKey(
        profile: profile, layer: layer, slot: slot, value: value)
      self.loadedKeymap = updated
      keymapReadAt = Date()
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Profile \(profile), \(layer.displayName.lowercased()), slot \(slot) written",
        "The slot and its layer were read back and verified. Both layers were backed up before the write."
      )
      return true
    } catch {
      await handleFailure(error, context: "Keymap write failed")
      return false
    }
  }

  func exportKeymap() {
    guard let keymap = loadedKeymap else {
      notice = .warning("No keymap to export", "Read a profile first.")
      return
    }

    let panel = NSSavePanel()
    panel.title = "Export Keymap"
    panel.prompt = "Export"
    panel.nameFieldStringValue = "MK750-profile\(keymap.profile)-keymap.json"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let archive = KeymapArchive(
      schemaVersion: 1,
      app: "MK750",
      createdAt: Date(),
      boardID: snapshot?.boardID,
      firmware: snapshot?.firmware,
      profile: keymap.profile,
      baseHex: Hex.string(keymap.base),
      fnHex: Hex.string(keymap.fn)
    )

    do {
      let data = try Self.archiveEncoder.encode(archive)
      try data.write(to: url, options: .atomic)
      notice = .success("Keymap exported", "Saved to \(url.path).")
    } catch {
      notice = .failure("Keymap export failed", Self.describe(error))
    }
  }

  func prepareKeymapImport() -> KeymapArchive? {
    let panel = NSOpenPanel()
    panel.title = "Import and Restore Keymap"
    panel.prompt = "Choose"
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }

    do {
      let data = try Data(contentsOf: url)
      let archive = try Self.archiveDecoder.decode(KeymapArchive.self, from: data)
      _ = try archive.validatedKeymap(connectedBoard: snapshot?.boardID)
      return archive
    } catch {
      notice = .failure(
        "That keymap file cannot be restored",
        Self.describe(error) + " Nothing was written to the keyboard."
      )
      return nil
    }
  }

  func applyImportedKeymap(_ archive: KeymapArchive) async -> Bool {
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }
    guard archive.profile <= 1 else {
      notice = .warning("Read-only profile", "Only profiles 0 and 1 can be restored.")
      return false
    }

    let keymap: Keymap
    do {
      keymap = try archive.validatedKeymap(connectedBoard: snapshot?.boardID)
    } catch {
      notice = .failure("That keymap file is not valid", Self.describe(error))
      return false
    }

    busy = "Restoring profile \(keymap.profile) keymap"
    defer { busy = nil }

    do {
      let restored = try await keyboard.restoreKeymap(keymap)
      loadedKeymap = restored
      keymapReadAt = Date()
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Profile \(keymap.profile) keymap restored",
        "Both layers were validated and the restored keymap was read back from the keyboard. The affected profile was backed up first."
      )
      return true
    } catch {
      await handleFailure(error, context: "Keymap restore failed")
      return false
    }
  }

  // MARK: Macros

  func loadMacro(slot: Int) async {
    guard (0...49).contains(slot) else {
      notice = .warning("Invalid macro slot", "Macro slots run from 0 to 49.")
      return
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return
    }

    busy = "Reading macro slot \(slot)"
    defer { busy = nil }

    do {
      let bytes = try await keyboard.readMacro(slot: slot)
      loadedMacro = bytes
      macroSlot = slot
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Macro slot \(slot) read",
        "\(bytes.count) bytes read. Reading does not write to the keyboard."
      )
    } catch {
      await handleFailure(error, context: "Could not read macro slot \(slot)")
    }
  }

  func writeMacro(slot: Int, bytes: [UInt8]) async -> Bool {
    guard (0...49).contains(slot) else {
      notice = .warning("Invalid macro slot", "Macro slots run from 0 to 49.")
      return false
    }
    guard !bytes.isEmpty, bytes.count <= 256 else {
      notice = .warning(
        "Invalid macro data", "A macro is 256 bytes; the editor produced \(bytes.count) bytes.")
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }

    var padded = bytes
    if padded.count < 256 {
      padded += Array(repeating: 0, count: 256 - padded.count)
    }
    let requestedTail = Array(padded[224...])
    let currentTail = loadedMacro.flatMap { current -> [UInt8]? in
      guard macroSlot == slot, current.count == 256 else { return nil }
      return Array(current[224...])
    }
    let tailChanged = currentTail.map { $0 != requestedTail } ?? true
    if requestedTail.contains(where: { $0 != 0 }), tailChanged {
      notice = .failure(
        "Macro exceeds the writable range",
        "The documented write path covers only bytes 0–223. Bytes 224–255 cannot be changed; nothing was written."
      )
      return false
    }

    busy = "Writing macro slot \(slot)"
    defer { busy = nil }

    do {
      let readBack = try await keyboard.writeMacro(slot: slot, bytes: padded)
      loadedMacro = readBack
      macroSlot = slot
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Macro slot \(slot) written",
        "The full 256-byte slot was read back. Bytes 224–255 could not be changed and keep their previous values. Macro writes are reference-only on this unit."
      )
      return true
    } catch {
      await handleFailure(error, context: "Macro write failed")
      return false
    }
  }

  // MARK: Device settings

  func applyDeviceSettings(_ draft: DeviceSettings, allowKeyboardLock: Bool) async -> Bool {
    guard let original = snapshot else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }
    guard (1...10).contains(draft.debounce) else {
      notice = .warning(
        "Debounce out of range", "Debounce is measured in milliseconds and must be 1–10.")
      return false
    }
    if draft.profile != original.profile, draft.profile > 1 {
      notice = .warning("Read-only profile", "Only profiles 0 and 1 can be selected.")
      return false
    }
    if draft.options & 128 != 0, original.options & 128 == 0, !allowKeyboardLock {
      notice = .warning(
        "Keyboard lock needs confirmation",
        "Enabling keyboard lock disables the keyboard's own keys until it is unlocked. Nothing was written."
      )
      return false
    }

    busy = "Applying device settings"
    defer { busy = nil }

    do {
      var current = original

      if draft.profile != current.profile {
        current = try await keyboard.setProfile(draft.profile)
        setSnapshot(current)
      }

      let changedOptions = draft.options ^ current.options
      for bit in [UInt8(1), 2, 8, 16, 32, 64, 128] where changedOptions & bit != 0 {
        current = try await keyboard.setOption(mask: bit, enabled: draft.options & bit != 0)
        setSnapshot(current)
      }

      if draft.debounce != current.debounce {
        current = try await keyboard.setDebounce(draft.debounce)
        setSnapshot(current)
      }

      if draft.sleep != current.sleep {
        current = try await keyboard.setSleep(draft.sleep)
        setSnapshot(current)
      }

      if draft.autoOS != current.autoOS {
        current = try await keyboard.setAutoOS(draft.autoOS)
        setSnapshot(current)
      }

      connection = .connected
      lastBackupURL = await keyboard.latestBackupURL()
      notice = .success(
        "Device settings applied",
        "Each changed register was written with read-modify-write and read back. Unmodelled option bits, the Fn matrix and power save were preserved."
      )
      return true
    } catch {
      await handleFailure(error, context: "Device settings could not be fully applied")
      if var current = notice {
        if current.kind == .failure {
          current.message +=
            " Some settings may have been applied; reload to see the current values."
          notice = current
        }
      }
      return false
    }
  }

  // MARK: Backups

  func backupKeymap(profile: UInt8) async -> Bool {
    guard profile <= 1 else {
      notice = .warning("Read-only profile", "Only profiles 0 and 1 can be backed up.")
      return false
    }
    guard !isBusy else {
      notice = .warning(
        "Another operation is running", "Wait for “\(busy ?? "the current task")” to finish.")
      return false
    }
    guard snapshot != nil else {
      notice = .warning("No keyboard connected", Self.connectionGuidance, action: .reconnect)
      return false
    }

    busy = "Backing up profile \(profile) keymap"
    defer { busy = nil }

    do {
      let url = try await keyboard.backupKeymap(profile: profile)
      lastBackupURL = await keyboard.latestBackupURL() ?? url
      notice = .success(
        "Profile \(profile) keymap backed up",
        "Saved in \(url.lastPathComponent) inside the MK750 Backups folder."
      )
      return true
    } catch {
      await handleFailure(error, context: "Keymap backup failed")
      return false
    }
  }

  func openBackupsFolder() {
    try? FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
    NSWorkspace.shared.open(backupsURL)
  }

  func revealLatestBackup() async {
    let latest = await keyboard.latestBackupURL()
    lastBackupURL = latest
    guard let latest else {
      openBackupsFolder()
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([latest])
  }

  // MARK: Local persistence

  private func loadScenes() {
    guard FileManager.default.fileExists(atPath: scenesURL.path) else { return }
    do {
      let data = try Data(contentsOf: scenesURL)
      let file = try Self.archiveDecoder.decode(ScenesFile.self, from: data)
      guard file.schemaVersion == 1 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      customScenes = file.customScenes.filter {
        !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
      }
    } catch {
      customScenes = []
      notice = .failure(
        "Saved scenes could not be read",
        "The file was left untouched at \(scenesURL.path). \(Self.describe(error))"
      )
    }
  }

  @discardableResult
  private func persistScenes() -> Bool {
    let file = ScenesFile(customScenes: customScenes)
    do {
      let data = try Self.archiveEncoder.encode(file)
      try data.write(to: scenesURL, options: .atomic)
      return true
    } catch {
      notice = .failure(
        "Could not save scenes",
        "\(Self.describe(error)) The file is \(scenesURL.path); existing scenes were not overwritten."
      )
      return false
    }
  }

  private func loadFocusRecovery() {
    guard FileManager.default.fileExists(atPath: focusRecoveryURL.path) else { return }
    do {
      let data = try Data(contentsOf: focusRecoveryURL)
      let decoder = Self.archiveDecoder
      var session = try decoder.decode(FocusSession.self, from: data)
      guard session.schemaVersion == 1 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      // Anything loaded from disk belongs to an earlier process and may only
      // be restored explicitly, never by a timer or a quit.
      recoveredFocus = true
      if session.status == .active {
        // A session read from disk belongs to a previous process: the timer
        // that created it is gone, so it can never resume as a live
        // countdown. Treat it as pending recovery and never restart the timer
        // or write at the inherited deadline; only an explicit Restore may
        // write. A same-process session still restores automatically at its
        // own deadline via startFocusTimer().
        session.status = .restorationPending
        session.lastFailure =
          session.deadline <= Date()
          ? "The focus timer ended while the app was not running."
          : "The app was relaunched while a focus session was active; saved lighting is waiting for an explicit restore."
        focus = session
        focusRemaining = 0
        _ = persistFocus()
      } else {
        focus = session
        focusRemaining = 0
      }
    } catch {
      notice = .failure(
        "Focus recovery could not be read",
        "The file was kept at \(focusRecoveryURL.path). \(Self.describe(error)) No lighting was written."
      )
    }
  }

  @discardableResult
  private func persistFocus() -> Bool {
    guard let focus else { return true }
    do {
      let data = try Self.archiveEncoder.encode(focus)
      try data.write(to: focusRecoveryURL, options: .atomic)
      return true
    } catch {
      notice = .failure(
        "Could not save focus recovery",
        "\(Self.describe(error)) The existing recovery file at \(focusRecoveryURL.path) was left in place."
      )
      return false
    }
  }

  private func deleteFocusRecoveryFile() {
    try? FileManager.default.removeItem(at: focusRecoveryURL)
  }

  // MARK: Failure handling

  private func setSnapshot(_ fresh: DeviceSnapshot) {
    snapshot = fresh
    snapshotRevision &+= 1
  }

  private func handleFailure(_ error: Error, context: String) async {
    let message = Self.describe(error)
    await probeConnection()
    let action: Notice.Action?
    if connection == .disconnected {
      action = .reconnect
    } else {
      action = nil
    }
    let suffix = connection == .disconnected ? " " + Self.connectionGuidance : ""
    notice = .failure(context, message + suffix, action: action)
  }

  /// Reads the device again after a failed operation so the UI knows whether
  /// trust was lost. This is read-only and never replays the failed write.
  private func probeConnection() async {
    do {
      let fresh = try await keyboard.refresh()
      setSnapshot(fresh)
      connection = .connected
    } catch {
      snapshot = nil
      connection = .disconnected
    }
  }

  nonisolated static func describe(_ error: Error) -> String {
    if let localized = error as? LocalizedError {
      var parts: [String] = []
      if let description = localized.errorDescription, !description.isEmpty {
        parts.append(description)
      }
      if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
        parts.append(suggestion)
      }
      if !parts.isEmpty {
        return parts.joined(separator: " ")
      }
    }
    let nsError = error as NSError
    if nsError.localizedDescription
      != "The operation couldn’t be completed. \(nsError.domain) error \(nsError.code)."
    {
      return nsError.localizedDescription
    }
    return "\(nsError.domain) error \(nsError.code)."
  }

  static let connectionGuidance =
    "Connect the MK750 with its wired USB cable — Bluetooth does not expose the vendor interface — then choose Reconnect."

  // MARK: Encoders

  private static let archiveEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private static let archiveDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
