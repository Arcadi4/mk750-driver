import Foundation

/// Wire-level facts for the yc500 family on board 849.
///
/// Every packet here is the protocol payload only: exactly 64 bytes, opcode at
/// index 0, checksum at index 7 (Bit7) or index 8 (Bit8). The IOKit transport
/// passes these bytes to `IOHIDDeviceSetReport` with report ID 0; it never
/// prepends hidapi's extra report-ID byte.
enum Protocol {
  static let reportLength = 64
  static let vendorID = 0x3151
  static let productID = 0x4015
  static let boardID: UInt32 = 849
  static let vendorUsagePage = 0xFFFF
  static let vendorUsage = 2
  static let vendorInterface = 2
  static let featureReportSize = 64

  // MARK: Opcodes

  enum Op {
    static let identify: UInt8 = 0x8F
    static let revision: UInt8 = 0x80

    static let getProfile: UInt8 = 0x85
    static let setProfile: UInt8 = 0x05

    static let getMainLight: UInt8 = 0x87
    static let setMainLight: UInt8 = 0x07
    static let getSideLight: UInt8 = 0x88
    static let setSideLight: UInt8 = 0x08

    static let getOptions: UInt8 = 0x86
    static let setOptions: UInt8 = 0x06
    static let getDebounce: UInt8 = 0x91
    static let setDebounce: UInt8 = 0x11
    static let getSleep: UInt8 = 0x92
    static let setSleep: UInt8 = 0x12
    static let getAutoOS: UInt8 = 0x97
    static let setAutoOS: UInt8 = 0x17

    static let getBaseKeymap: UInt8 = 0x89
    static let getFnKeymap: UInt8 = 0x90
    static let setBaseKeymapBulk: UInt8 = 0x09
    static let setFnKeymapBulk: UInt8 = 0x10
    static let setBaseKeymapSlot: UInt8 = 0x13
    static let setFnKeymapSlot: UInt8 = 0x15

    static let getMacro: UInt8 = 0x8B
    static let setMacro: UInt8 = 0x16

    /// Read-only family probe: documented to answer all `FF` on yc500.
    static let gen2KeymapProbe: UInt8 = 0x8A
  }

  // MARK: Keymap geometry

  static let layerBytes = 512
  static let layerPageCount = 8
  static let pageBytes = 64
  static let slotCount = 128
  static let slotsPerPage = 16
  static let slotBytes = 4

  static let bulkPagePayload = 56
  static let bulkPageCount = 9
  static let bulkRepresentableBytes = bulkPagePayload * bulkPageCount  // 504
  /// Slots 126 and 127 live in the final eight bytes and are never sent by
  /// the documented nine-page bulk upload.
  static let lastBulkSlot = 125

  static let macroCount = 50
  static let macroBytes = 256
  static let macroPageCount = 4
  static let macroPagePayload = 56
  static let macroWritableBytes = macroPagePayload * macroPageCount  // 224

  // MARK: Checksums

  /// `0xFF - (sum(bytes[0..<7]) & 0xFF)` stored at byte 7.
  static func bit7Checksum(_ packet: [UInt8]) -> UInt8 {
    let sum = packet[0..<7].reduce(0) { ($0 &+ Int($1)) & 0xFF }
    return UInt8((0xFF - sum) & 0xFF)
  }

  /// `0xFF - (sum(bytes[0..<8]) & 0xFF)` stored at byte 8.
  static func bit8Checksum(_ packet: [UInt8]) -> UInt8 {
    let sum = packet[0..<8].reduce(0) { ($0 &+ Int($1)) & 0xFF }
    return UInt8((0xFF - sum) & 0xFF)
  }

  static func zeroedPacket() -> [UInt8] {
    [UInt8](repeating: 0, count: reportLength)
  }

  /// A GET request: opcode, at most six argument bytes, Bit7 checksum.
  static func getRequest(opcode: UInt8, arguments: [UInt8] = []) -> [UInt8] {
    precondition(arguments.count <= 6, "GET requests carry at most six arguments")
    var packet = zeroedPacket()
    packet[0] = opcode
    for (index, byte) in arguments.enumerated() {
      packet[index + 1] = byte
    }
    packet[7] = bit7Checksum(packet)
    return packet
  }

  /// A Bit7 SET packet with sparse byte assignments.
  static func bit7SetPacket(opcode: UInt8, assignments: [(Int, UInt8)]) -> [UInt8] {
    var packet = zeroedPacket()
    packet[0] = opcode
    for (offset, value) in assignments {
      precondition(offset >= 1 && offset < reportLength, "assignment offset out of range")
      packet[offset] = value
    }
    packet[7] = bit7Checksum(packet)
    return packet
  }

  // MARK: Identity

  static func boardID(fromIdentifyReply reply: [UInt8]) -> UInt32? {
    guard reply.count == reportLength, reply[0] == Op.identify else { return nil }
    return UInt32(reply[1])
      | (UInt32(reply[2]) << 8)
      | (UInt32(reply[3]) << 16)
      | (UInt32(reply[4]) << 24)
  }

  /// The revision reply packs two BCD bytes: `(reply[2] << 8) | reply[1]`.
  /// Every nibble must be a decimal digit and the value must be non-zero.
  /// 0x0107 becomes "1.07".
  static func firmwareVersion(fromRevisionReply reply: [UInt8]) -> String? {
    guard reply.count == reportLength, reply[0] == Op.revision else { return nil }
    let majorByte = Int(reply[2])
    let minorByte = Int(reply[1])
    guard validBCDNibbles(majorByte), validBCDNibbles(minorByte) else { return nil }
    guard majorByte != 0 || minorByte != 0 else { return nil }
    let major = bcdValue(majorByte)
    let minor = bcdValue(minorByte)
    return String(format: "%d.%02d", major, minor)
  }

  private static func validBCDNibbles(_ byte: Int) -> Bool {
    (byte >> 4) <= 9 && (byte & 0x0F) <= 9
  }

  private static func bcdValue(_ byte: Int) -> Int {
    ((byte >> 4) * 10) + (byte & 0x0F)
  }

  // MARK: Lighting

  static func decodeLight(_ reply: [UInt8]) -> LightState? {
    guard reply.count == reportLength else { return nil }
    return LightState(
      mode: reply[1],
      speed: reply[2],
      brightness: reply[3],
      flags: reply[4],
      red: reply[5],
      green: reply[6],
      blue: reply[7]
    )
  }

  /// Lighting SETs are the only Bit8 commands: the checksum lives in byte 8,
  /// not byte 7.
  static func lightSetPacket(opcode: UInt8, state: LightState) -> [UInt8] {
    var packet = zeroedPacket()
    packet[0] = opcode
    packet[1] = state.mode
    packet[2] = state.speed
    packet[3] = state.brightness
    packet[4] = state.flags
    packet[5] = state.red
    packet[6] = state.green
    packet[7] = state.blue
    packet[8] = bit8Checksum(packet)
    return packet
  }

  // MARK: Settings

  static func decodeSleep(_ reply: [UInt8]) -> SleepTimers? {
    guard reply.count == reportLength else { return nil }
    return SleepTimers(
      bluetooth: littleEndianUInt16(reply, at: 1),
      wireless: littleEndianUInt16(reply, at: 3),
      deepBluetooth: littleEndianUInt16(reply, at: 5),
      deepWireless: littleEndianUInt16(reply, at: 7)
    )
  }

  /// Sleep SET offsets are bytes 8...15, unlike the GET reply's bytes 1...8.
  static func sleepSetPacket(_ timers: SleepTimers) -> [UInt8] {
    var packet = bit7SetPacket(opcode: Op.setSleep, assignments: [])
    writeLittleEndian(timers.bluetooth, into: &packet, at: 8)
    writeLittleEndian(timers.wireless, into: &packet, at: 10)
    writeLittleEndian(timers.deepBluetooth, into: &packet, at: 12)
    writeLittleEndian(timers.deepWireless, into: &packet, at: 14)
    packet[7] = bit7Checksum(packet)
    return packet
  }

  struct OptionsRegister: Equatable {
    var options: UInt8
    var fnMatrix: UInt8
    var powerSave: UInt8
  }

  static func decodeOptions(_ reply: [UInt8]) -> OptionsRegister? {
    guard reply.count == reportLength else { return nil }
    return OptionsRegister(options: reply[2], fnMatrix: reply[3], powerSave: reply[4])
  }

  static func optionsSetPacket(_ register: OptionsRegister) -> [UInt8] {
    bit7SetPacket(
      opcode: Op.setOptions,
      assignments: [
        (2, register.options),
        (3, register.fnMatrix),
        (4, register.powerSave),
      ]
    )
  }

  static func autoOSSetPacket(_ enabled: Bool) -> [UInt8] {
    bit7SetPacket(opcode: Op.setAutoOS, assignments: [(1, enabled ? 1 : 0)])
  }

  static func debounceSetPacket(_ value: UInt8) -> [UInt8] {
    bit7SetPacket(opcode: Op.setDebounce, assignments: [(1, 0), (2, value)])
  }

  static func profileSetPacket(_ profile: UInt8) -> [UInt8] {
    bit7SetPacket(opcode: Op.setProfile, assignments: [(1, profile)])
  }

  // MARK: Keymap packets

  static func slotPageAndOffset(_ slot: Int) -> (page: Int, offset: Int) {
    precondition((0..<slotCount).contains(slot))
    return (slot / slotsPerPage, (slot % slotsPerPage) * slotBytes)
  }

  static func singleSlotPacket(
    opcode: UInt8,
    profile: UInt8,
    slot: Int,
    value: [UInt8]
  ) -> [UInt8] {
    precondition(value.count == slotBytes)
    var packet = bit7SetPacket(
      opcode: opcode,
      assignments: [
        (1, profile),
        (2, UInt8(slot)),
      ]
    )
    for (index, byte) in value.enumerated() {
      packet[8 + index] = byte
    }
    packet[7] = bit7Checksum(packet)
    return packet
  }

  static func bulkKeymapPacket(
    opcode: UInt8,
    profile: UInt8,
    page: Int,
    payload: ArraySlice<UInt8>
  ) -> [UInt8] {
    precondition((0..<bulkPageCount).contains(page))
    precondition(payload.count == bulkPagePayload)
    var packet = bit7SetPacket(
      opcode: opcode,
      assignments: [
        (1, profile),
        (2, 0xF8),
        (3, 1),
        (4, UInt8(page)),
      ]
    )
    for (index, byte) in payload.enumerated() {
      packet[8 + index] = byte
    }
    packet[7] = bit7Checksum(packet)
    return packet
  }

  // MARK: Macro packets

  static func macroSetPacket(slot: Int, page: Int, payload: ArraySlice<UInt8>) -> [UInt8] {
    precondition((0..<macroCount).contains(slot))
    precondition((0..<macroPageCount).contains(page))
    precondition(payload.count == macroPagePayload)
    var packet = bit7SetPacket(
      opcode: Op.setMacro,
      assignments: [
        (1, UInt8(slot)),
        (2, UInt8(page)),
        (3, UInt8(macroPagePayload)),
        (4, page == macroPageCount - 1 ? 1 : 0),
      ]
    )
    for (index, byte) in payload.enumerated() {
      packet[8 + index] = byte
    }
    packet[7] = bit7Checksum(packet)
    return packet
  }

  // MARK: Validation

  static func validateReadableProfile(_ profile: UInt8) throws {
    guard profile <= 3 else {
      throw MK750Error.invalidArgument("profile \(profile) is not readable; profiles 0...3 exist")
    }
  }

  static func validateWritableProfile(_ profile: UInt8) throws {
    guard profile <= 1 else {
      throw MK750Error.unsupported(
        "profile \(profile) is read-only; only profiles 0 and 1 have valid Fn storage"
      )
    }
  }

  static func validateSlot(_ slot: Int) throws {
    guard (0..<slotCount).contains(slot) else {
      throw MK750Error.invalidArgument("slot \(slot) is outside 0...127")
    }
  }

  static func validateMacroSlot(_ slot: Int) throws {
    guard (0..<macroCount).contains(slot) else {
      throw MK750Error.invalidArgument("macro slot \(slot) is outside 0...49")
    }
  }

  static func isAll(_ byte: UInt8, in bytes: ArraySlice<UInt8>) -> Bool {
    !bytes.isEmpty && bytes.allSatisfy { $0 == byte }
  }

  // MARK: Helpers

  static func littleEndianUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
    UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
  }

  static func writeLittleEndian(_ value: UInt16, into bytes: inout [UInt8], at index: Int) {
    bytes[index] = UInt8(value & 0x00FF)
    bytes[index + 1] = UInt8(value >> 8)
  }
}

extension LightChannel {
  var getOpcode: UInt8 {
    switch self {
    case .main: return Protocol.Op.getMainLight
    case .side: return Protocol.Op.getSideLight
    }
  }

  var setOpcode: UInt8 {
    switch self {
    case .main: return Protocol.Op.setMainLight
    case .side: return Protocol.Op.setSideLight
    }
  }
}

extension KeyLayer {
  var readOpcode: UInt8 {
    switch self {
    case .base: return Protocol.Op.getBaseKeymap
    case .fn: return Protocol.Op.getFnKeymap
    }
  }

  var singleSlotOpcode: UInt8 {
    switch self {
    case .base: return Protocol.Op.setBaseKeymapSlot
    case .fn: return Protocol.Op.setFnKeymapSlot
    }
  }

  var bulkOpcode: UInt8 {
    switch self {
    case .base: return Protocol.Op.setBaseKeymapBulk
    case .fn: return Protocol.Op.setFnKeymapBulk
    }
  }
}
