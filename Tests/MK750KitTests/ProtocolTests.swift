import Foundation
import Testing

@testable import MK750Kit

// MARK: - Fake device

/// Stateful yc500 device used by the tests. It models the two behaviours that
/// matter most: a GET's first reply can be the previous GET's stale reply, and
/// some yc500 images silently drop the single-slot keymap writes.
final class FakeKeyboardDevice: MK750Transport {
  // Connection state
  private(set) var opened = false
  private(set) var closeCount = 0
  private(set) var requests: [[UInt8]] = []
  private(set) var staleReplyCount = 0

  // Identity
  var boardID: UInt32 = 849
  var revision: (low: UInt8, high: UInt8) = (0x07, 0x01)
  var gen2ProbeAllFF = true
  var yc500ProbeErased = false

  // Settings
  var activeProfile: UInt8 = 0
  var main = LightState(
    mode: 5, speed: 2, brightness: 4, flags: 7, red: 0xFF, green: 0x45, blue: 0x6E)
  var side = LightState(
    mode: 1, speed: 3, brightness: 4, flags: 8, red: 0xFF, green: 0xFF, blue: 0xFF)
  var debounce: UInt8 = 1
  var sleep = SleepTimers(bluetooth: 120, wireless: 120, deepBluetooth: 600, deepWireless: 600)
  var optionByte2: UInt8 = 0x02
  var fnMatrix: UInt8 = 0x02
  var powerSave: UInt8 = 0
  var autoOS = true

  // Flash state
  var baseLayers = [UInt8: [UInt8]]()
  var fnLayers = [UInt8: [UInt8]]()
  var macroSlots = [Int: [UInt8]]()
  var singleSlotWritesSupported = true

  // Fault injection
  var failSendOpcodes = Set<UInt8>()
  var dropSetOpcodes = Set<UInt8>()

  // Reply model
  private var pendingAfterSet = true
  private var nextReply: [UInt8]?
  private var nextIsStale = false
  private var lastReply: [UInt8]?

  init() {
    let defaultBase = FakeKeyboardDevice.makeLayer()
    var base = defaultBase
    base.replaceSubrange(0..<4, with: [0x00, 0x00, 0x29, 0x00])  // Esc
    base.replaceSubrange(4..<8, with: [0x00, 0x00, 0x35, 0x00])  // Backquote
    base.replaceSubrange(260..<264, with: [0x0A, 0x01, 0x00, 0x00])  // Fn
    base.replaceSubrange(504..<512, with: [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04])

    var fn = FakeKeyboardDevice.makeLayer()
    fn.replaceSubrange(504..<512, with: [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

    for profile in UInt8(0)...3 {
      baseLayers[profile] = base
      fnLayers[profile] = fn
    }

    var oldReply = [UInt8](repeating: 0, count: 64)
    oldReply[0] = 0x91
    oldReply[2] = 9
    lastReply = oldReply
  }

  static func makeLayer() -> [UInt8] {
    [UInt8](repeating: 0, count: 512)
  }

  // MARK: MK750Transport

  func open() throws {
    opened = true
    nextReply = nil
  }

  func close() {
    opened = false
    closeCount += 1
    nextReply = nil
  }

  func send(_ report: [UInt8]) throws {
    guard opened else { throw MK750Error.notConnected }
    guard report.count == 64 else {
      throw MK750Error.invalidArgument("fake got \(report.count) bytes")
    }
    requests.append(report)
    if failSendOpcodes.contains(report[0]) {
      throw MK750Error.transport("injected send failure for opcode \(report[0])")
    }

    if FakeKeyboardDevice.isSetOpcode(report[0]) {
      if !dropSetOpcodes.contains(report[0]) {
        applySet(report)
      }
      pendingAfterSet = true
      nextReply = nil
      nextIsStale = false
      return
    }

    nextReply = getReply(for: report)
    nextIsStale = pendingAfterSet
    pendingAfterSet = false
  }

  func receive() throws -> [UInt8] {
    guard opened else { throw MK750Error.notConnected }
    guard let pending = nextReply else {
      throw MK750Error.transport("fake has no pending GET reply")
    }
    if nextIsStale {
      nextIsStale = false
      staleReplyCount += 1
      let stale = lastReply ?? [UInt8](repeating: 0xAA, count: 64)
      lastReply = stale
      return stale
    }
    nextReply = nil
    lastReply = pending
    return pending
  }

  // MARK: Request classification

  static func isSetOpcode(_ opcode: UInt8) -> Bool {
    switch opcode {
    case 0x07, 0x08, 0x05, 0x06, 0x11, 0x12, 0x17,
      0x09, 0x10, 0x13, 0x15, 0x16:
      return true
    default:
      return false
    }
  }

  func sent(opcode: UInt8) -> [[UInt8]] {
    requests.filter { $0[0] == opcode }
  }

  // MARK: Reply construction

  private func getReply(for request: [UInt8]) -> [UInt8] {
    var reply = [UInt8](repeating: 0, count: 64)
    switch request[0] {
    case 0x8F:
      reply[0] = 0x8F
      reply[1] = UInt8(boardID & 0xFF)
      reply[2] = UInt8((boardID >> 8) & 0xFF)
      reply[3] = UInt8((boardID >> 16) & 0xFF)
      reply[4] = UInt8((boardID >> 24) & 0xFF)

    case 0x80:
      reply[0] = 0x80
      reply[1] = revision.low
      reply[2] = revision.high

    case 0x85:
      reply[0] = 0x85
      reply[1] = activeProfile

    case 0x87:
      reply = lightReply(opcode: 0x87, state: main)

    case 0x88:
      reply = lightReply(opcode: 0x88, state: side)

    case 0x91:
      reply[0] = 0x91
      reply[2] = debounce

    case 0x92:
      reply[0] = 0x92
      write(sleep.bluetooth, into: &reply, at: 1)
      write(sleep.wireless, into: &reply, at: 3)
      write(sleep.deepBluetooth, into: &reply, at: 5)
      write(sleep.deepWireless, into: &reply, at: 7)

    case 0x86:
      reply[0] = 0x86
      reply[2] = optionByte2
      reply[3] = fnMatrix
      reply[4] = powerSave

    case 0x97:
      reply[0] = 0x97
      reply[1] = autoOS ? 1 : 0

    case 0x89:
      reply = keymapPage(
        layers: baseLayers,
        profile: request[1],
        page: Int(request[2]),
        erased: yc500ProbeErased && request[1] == 0 && request[2] == 0
      )

    case 0x90:
      reply = keymapPage(
        layers: fnLayers,
        profile: request[1],
        page: Int(request[2]),
        erased: false
      )

    case 0x8A:
      reply = [UInt8](repeating: gen2ProbeAllFF ? 0xFF : 0x00, count: 64)

    case 0x8B:
      reply = macroPage(slot: Int(request[1]), page: Int(request[2]))

    default:
      break
    }
    return reply
  }

  private func lightReply(opcode: UInt8, state: LightState) -> [UInt8] {
    var reply = [UInt8](repeating: 0, count: 64)
    reply[0] = opcode
    reply[1] = state.mode
    reply[2] = state.speed
    reply[3] = state.brightness
    reply[4] = state.flags
    reply[5] = state.red
    reply[6] = state.green
    reply[7] = state.blue
    return reply
  }

  private func keymapPage(
    layers: [UInt8: [UInt8]],
    profile: UInt8,
    page: Int,
    erased: Bool
  ) -> [UInt8] {
    if erased {
      return [UInt8](repeating: 0xFF, count: 64)
    }
    guard (0..<8).contains(page), let layer = layers[profile] else {
      return [UInt8](repeating: 0, count: 64)
    }
    let start = page * 64
    return Array(layer[start..<(start + 64)])
  }

  private func macroPage(slot: Int, page: Int) -> [UInt8] {
    guard (0..<4).contains(page) else {
      return [UInt8](repeating: 0, count: 64)
    }
    let blob = macroSlots[slot] ?? [UInt8](repeating: 0, count: 256)
    // GET 0x8B returns full 64-byte pages (4 x 64 = 256), unlike the
    // 56-byte write pages.
    let start = page * 64
    return Array(blob[start..<(start + 64)])
  }

  // MARK: Set application

  private func applySet(_ report: [UInt8]) {
    switch report[0] {
    case 0x07:
      main = decodeLight(report)
    case 0x08:
      side = decodeLight(report)
    case 0x05:
      activeProfile = report[1]
    case 0x06:
      optionByte2 = report[2]
      fnMatrix = report[3]
      powerSave = report[4]
    case 0x11:
      debounce = report[2]
    case 0x12:
      sleep = SleepTimers(
        bluetooth: read16(report, at: 8),
        wireless: read16(report, at: 10),
        deepBluetooth: read16(report, at: 12),
        deepWireless: read16(report, at: 14)
      )
    case 0x17:
      autoOS = report[1] == 1
    case 0x13:
      guard singleSlotWritesSupported else { return }
      applySingleSlot(report, layers: &baseLayers)
    case 0x15:
      guard singleSlotWritesSupported else { return }
      applySingleSlot(report, layers: &fnLayers)
    case 0x09:
      applyBulk(report, layers: &baseLayers)
    case 0x10:
      applyBulk(report, layers: &fnLayers)
    case 0x16:
      applyMacroPage(report)
    default:
      break
    }
  }

  private func applySingleSlot(_ report: [UInt8], layers: inout [UInt8: [UInt8]]) {
    let profile = report[1]
    let slot = Int(report[2])
    guard var layer = layers[profile], slot < 128 else { return }
    let offset = slot * 4
    layer.replaceSubrange(offset..<(offset + 4), with: report[8..<12])
    layers[profile] = layer
  }

  private func applyBulk(_ report: [UInt8], layers: inout [UInt8: [UInt8]]) {
    let profile = report[1]
    let page = Int(report[4])
    guard var layer = layers[profile], (0..<9).contains(page) else { return }
    let start = page * 56
    layer.replaceSubrange(start..<(start + 56), with: report[8..<64])
    layers[profile] = layer
  }

  private func applyMacroPage(_ report: [UInt8]) {
    let slot = Int(report[1])
    let page = Int(report[2])
    guard (0..<4).contains(page) else { return }
    var blob = macroSlots[slot] ?? [UInt8](repeating: 0, count: 256)
    let start = page * 56
    blob.replaceSubrange(start..<(start + 56), with: report[8..<64])
    macroSlots[slot] = blob
  }

  private func decodeLight(_ report: [UInt8]) -> LightState {
    LightState(
      mode: report[1],
      speed: report[2],
      brightness: report[3],
      flags: report[4],
      red: report[5],
      green: report[6],
      blue: report[7]
    )
  }

  private func write(_ value: UInt16, into bytes: inout [UInt8], at index: Int) {
    bytes[index] = UInt8(value & 0xFF)
    bytes[index + 1] = UInt8(value >> 8)
  }

  private func read16(_ bytes: [UInt8], at index: Int) -> UInt16 {
    UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
  }
}

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("MK750Tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func captureError<T>(_ operation: () async throws -> T) async -> MK750Error? {
  do {
    _ = try await operation()
    return nil
  } catch let error as MK750Error {
    return error
  } catch {
    Issue.record("non-MK750 error: \(error)")
    return nil
  }
}

private func expectUnsupported(
  _ error: MK750Error?,
  _ sourceLocation: SourceLocation = #_sourceLocation
) {
  guard case .unsupported? = error else {
    Issue.record(
      "expected .unsupported, got \(String(describing: error))", sourceLocation: sourceLocation)
    return
  }
}

// MARK: - Connection and gating

@Test func connectUsesSecondReplyAndValidatesIdentity() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)

  let snapshot = try await keyboard.connect()

  #expect(snapshot.boardID == 849)
  #expect(snapshot.firmware == "1.07")
  #expect(snapshot.profile == 0)
  #expect(snapshot.main == fake.main)
  #expect(snapshot.side == fake.side)
  #expect(snapshot.debounce == 1)
  #expect(snapshot.sleep == fake.sleep)
  #expect(snapshot.options == 0x02)
  #expect(snapshot.fnMatrix == 0x02)
  #expect(snapshot.powerSave == 0)
  #expect(snapshot.autoOS)

  // The first GET after open returned the old debounce reply; the paired
  // read discarded it and the connection still succeeded with real identity.
  #expect(fake.staleReplyCount >= 1)
  let identify = try #require(fake.sent(opcode: 0x8F).first)
  #expect(identify[7] == 0x70)
  #expect(fake.sent(opcode: 0x07).isEmpty)

  _ = try await keyboard.refresh()
  #expect(fake.requests.allSatisfy { !FakeKeyboardDevice.isSetOpcode($0[0]) })
}

@Test func unknownFamilyFailsClosedWithoutAnyWrite() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.gen2ProbeAllFF = false
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)

  let error = await captureError { try await keyboard.connect() }
  guard case .familyUnverified? = error else {
    Issue.record("expected .familyUnverified, got \(String(describing: error))")
    return
  }
  #expect(fake.requests.allSatisfy { !FakeKeyboardDevice.isSetOpcode($0[0]) })

  let writeError = await captureError {
    try await keyboard.setLight(fake.main, channel: .main)
  }
  guard case .notConnected? = writeError else {
    Issue.record(
      "expected .notConnected after failed connect, got \(String(describing: writeError))")
    return
  }
  #expect(fake.sent(opcode: 0x07).isEmpty)
}

@Test func erasedYc500ProbeAlsoFailsClosed() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.yc500ProbeErased = true
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)

  let error = await captureError { try await keyboard.connect() }
  guard case .familyUnverified? = error else {
    Issue.record("expected .familyUnverified, got \(String(describing: error))")
    return
  }
}

@Test func wrongBoardAndZeroRevisionFailIdentityGate() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let wrongBoard = FakeKeyboardDevice()
  wrongBoard.boardID = 1586
  let keyboard1 = Keyboard(transport: wrongBoard, backupDirectory: directory, timing: .immediate)
  let boardError = await captureError { try await keyboard1.connect() }
  guard case .identityFailed? = boardError else {
    Issue.record("expected .identityFailed for board 1586, got \(String(describing: boardError))")
    return
  }

  let zeroRevision = FakeKeyboardDevice()
  zeroRevision.revision = (0x00, 0x00)
  let keyboard2 = Keyboard(transport: zeroRevision, backupDirectory: directory, timing: .immediate)
  let revisionError = await captureError { try await keyboard2.connect() }
  guard case .identityFailed? = revisionError else {
    Issue.record(
      "expected .identityFailed for zero revision, got \(String(describing: revisionError))")
    return
  }
}

// MARK: - Settings

@Test func settingsWritesUseDocumentedChecksumAndOffsetPositions() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  // Lighting SET: Bit8 checksum, Bit7 left zero. Captured red write from the
  // recon is `07 01 00 04 07 ff 00 00 ed`.
  let red = LightState(mode: 1, speed: 0, brightness: 4, flags: 7, red: 0xFF, green: 0, blue: 0)
  _ = try await keyboard.setLight(red, channel: .main)
  let lightSet = try #require(fake.sent(opcode: 0x07).last)
  #expect(lightSet[1] == 1)
  #expect(lightSet[2] == 0)
  #expect(lightSet[3] == 4)
  #expect(lightSet[4] == 7)
  #expect(lightSet[5] == 0xFF)
  #expect(lightSet[6] == 0)
  #expect(lightSet[7] == 0)
  #expect(lightSet[8] == 0xED)
  #expect(lightSet[8] == Protocol.bit8Checksum(lightSet))

  // GET sleep is Bit7 at byte 7: the captured request is 92 ... 6d.
  let sleepGet = try #require(fake.sent(opcode: 0x92).first)
  #expect(sleepGet[7] == 0x6D)

  // Sleep SET uses bytes 8...15, not the GET reply's bytes 1...8.
  let timers = SleepTimers(bluetooth: 60, wireless: 90, deepBluetooth: 300, deepWireless: 450)
  _ = try await keyboard.setSleep(timers)
  let sleepSet = try #require(fake.sent(opcode: 0x12).last)
  #expect(sleepSet[7] == Protocol.bit7Checksum(sleepSet))
  #expect(sleepSet[8] == 60)
  #expect(sleepSet[9] == 0)
  #expect(sleepSet[10] == 90)
  #expect(sleepSet[11] == 0)
  #expect(sleepSet[12] == 0x2C)
  #expect(sleepSet[13] == 0x01)
  #expect(sleepSet[14] == 0xC2)
  #expect(sleepSet[15] == 0x01)
  #expect(fake.sleep == timers)

  // Debounce SET puts the value at byte 2 and pads byte 1 (yc500 shape).
  _ = try await keyboard.setDebounce(7)
  let debounceSet = try #require(fake.sent(opcode: 0x11).last)
  #expect(debounceSet[1] == 0)
  #expect(debounceSet[2] == 7)
  #expect(debounceSet[7] == Protocol.bit7Checksum(debounceSet))

  _ = try await keyboard.setAutoOS(false)
  let autoOSSet = try #require(fake.sent(opcode: 0x17).last)
  #expect(autoOSSet[1] == 0)
  #expect(autoOSSet[7] == Protocol.bit7Checksum(autoOSSet))
  #expect(fake.autoOS == false)
}

@Test func optionWritePreservesUnknownBitsAndDiagnostics() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  fake.optionByte2 = 0xA2
  fake.fnMatrix = 0x12
  fake.powerSave = 0x05

  let enabled = try await keyboard.setOption(mask: 0x10, enabled: true)
  let enableSet = try #require(fake.sent(opcode: 0x06).last)
  #expect(enableSet[2] == 0xB2)
  #expect(enableSet[3] == 0x12)
  #expect(enableSet[4] == 0x05)
  #expect(enableSet[8] == 0)  // Bit7 packet does not use byte 8 for a checksum
  #expect(enableSet[7] == Protocol.bit7Checksum(enableSet))
  #expect(enabled.options == 0xB2)
  #expect(enabled.fnMatrix == 0x12)
  #expect(enabled.powerSave == 0x05)

  let latest = await keyboard.latestBackupURL()
  let settingsURL = try #require(latest)
  let settingsJSON =
    try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
  #expect(settingsJSON?["kind"] as? String == "settings")
  let settingsRaw = settingsJSON?["settings"] as? [String: Any]
  #expect((settingsRaw?["optionsReply"] as? String)?.count == 128)
  #expect((settingsRaw?["mainReply"] as? String)?.count == 128)
  #expect(settingsJSON?["profile"] as? Int == 0)

  let beforeInvalid = fake.sent(opcode: 0x06).count
  let invalid = await captureError {
    try await keyboard.setOption(mask: 0x11, enabled: true)
  }
  guard case .invalidArgument? = invalid else {
    Issue.record(
      "expected .invalidArgument for a multi-bit mask, got \(String(describing: invalid))")
    return
  }
  #expect(fake.sent(opcode: 0x06).count == beforeInvalid)

  let disabled = try await keyboard.setOption(mask: 0x10, enabled: false)
  #expect(disabled.options == 0xA2)
  #expect(disabled.fnMatrix == 0x12)
  #expect(disabled.powerSave == 0x05)
}

@Test func backupFailurePreventsSettingsKeymapAndMacroWrites() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  // A regular file where the backup directory must be makes persistence fail.
  let blocker = directory.appendingPathComponent("not-a-directory")
  try Data("blocked".utf8).write(to: blocker)

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: blocker, timing: .immediate)
  _ = try await keyboard.connect()

  let lightError = await captureError {
    try await keyboard.setLight(
      LightState(mode: 1, speed: 0, brightness: 4, flags: 7, red: 0xFF, green: 0, blue: 0),
      channel: .main
    )
  }
  guard case .backupFailed? = lightError else {
    Issue.record("expected .backupFailed for lighting, got \(String(describing: lightError))")
    return
  }
  #expect(fake.sent(opcode: 0x07).isEmpty)
  #expect(fake.main.mode == 5)

  let keymapError = await captureError {
    try await keyboard.writeKey(profile: 0, layer: .base, slot: 0, value: [0, 0, 0x2A, 0])
  }
  guard case .backupFailed? = keymapError else {
    Issue.record("expected .backupFailed for keymap, got \(String(describing: keymapError))")
    return
  }
  #expect(fake.sent(opcode: 0x13).isEmpty)
  #expect(fake.sent(opcode: 0x09).isEmpty)

  let macroError = await captureError {
    try await keyboard.writeMacro(slot: 0, bytes: [UInt8](repeating: 0, count: 256))
  }
  guard case .backupFailed? = macroError else {
    Issue.record("expected .backupFailed for macro, got \(String(describing: macroError))")
    return
  }
  #expect(fake.sent(opcode: 0x16).isEmpty)
}

@Test func verificationFailureClearsTrustAndBlocksFurtherWrites() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.dropSetOpcodes = [0x06]
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  let error = await captureError {
    try await keyboard.setOption(mask: 0x01, enabled: true)
  }
  guard case .verificationFailed? = error else {
    Issue.record("expected .verificationFailed, got \(String(describing: error))")
    return
  }
  #expect(fake.closeCount > 0)

  let next = await captureError { try await keyboard.refresh() }
  guard case .notConnected? = next else {
    Issue.record("expected .notConnected after trust clear, got \(String(describing: next))")
    return
  }
}

@Test func transportFailureClearsTrust() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.failSendOpcodes = [0x07]
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  let error = await captureError {
    try await keyboard.setLight(
      LightState(mode: 1, speed: 0, brightness: 4, flags: 7, red: 0xFF, green: 0, blue: 0),
      channel: .main
    )
  }
  guard case .transport? = error else {
    Issue.record("expected .transport, got \(String(describing: error))")
    return
  }
  #expect(fake.closeCount > 0)
  let next = await captureError { try await keyboard.refresh() }
  guard case .notConnected? = next else {
    Issue.record("expected .notConnected after transport failure")
    return
  }
}

// MARK: - Keymap

@Test func keymapBulkFallbackPreservesLastEightBytesAndOtherLayer() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.singleSlotWritesSupported = false
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  let beforeBase = try #require(fake.baseLayers[0])
  let beforeFn = try #require(fake.fnLayers[0])
  let value: [UInt8] = [0x00, 0x00, 0x30, 0x00]

  let keymap = try await keyboard.writeKey(profile: 0, layer: .base, slot: 125, value: value)

  #expect(Array(keymap.base[500..<504]) == value)
  #expect(keymap.base[504..<512] == beforeBase[504..<512])
  #expect(keymap.fn == beforeFn)
  #expect(fake.sent(opcode: 0x13).count == 1)
  #expect(fake.sent(opcode: 0x10).isEmpty)

  let bulk = fake.sent(opcode: 0x09)
  #expect(bulk.count == 9)
  #expect(bulk.compactMap { $0[4] } == Array(UInt8(0)...UInt8(8)))
  for packet in bulk {
    #expect(packet[1] == 0)  // target profile
    #expect(packet[2] == 0xF8)
    #expect(packet[3] == 1)
    #expect(packet[7] == Protocol.bit7Checksum(packet))
  }
  // Page 8 carries bytes 448...503 and commits; slots 126/127 are untouched.
  #expect(Array(fake.baseLayers[0]![448..<504]) == Array(keymap.base[448..<504]))
  #expect(Array(fake.baseLayers[0]![504..<512]) == Array(beforeBase[504..<512]))

  let latestBackup = await keyboard.latestBackupURL()
  let backupURL = try #require(latestBackup)
  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
  #expect(json?["schemaVersion"] as? Int == 1)
  #expect(json?["kind"] as? String == "keymap")
  #expect(json?["profile"] as? Int == 0)
  #expect((json?["base"] as? String)?.count == 1024)
  #expect((json?["fn"] as? String)?.count == 1024)
  let identity = json?["identity"] as? [String: Any]
  #expect(identity?["boardID"] as? Int == 849)
  #expect(identity?["firmware"] as? String == "1.07")
}

@Test func keymapLastTwoSlotsCannotUseBulkFallbackAndProfilesAreGuarded() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.singleSlotWritesSupported = false
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  let before = try #require(fake.baseLayers[0])
  let error = await captureError {
    try await keyboard.writeKey(profile: 0, layer: .base, slot: 126, value: [0, 0, 0x31, 0])
  }
  expectUnsupported(error)
  #expect(fake.sent(opcode: 0x13).count == 1)
  #expect(fake.sent(opcode: 0x09).isEmpty)
  #expect(fake.baseLayers[0] == before)

  // Profile 2 remains readable but is never writable.
  let profile2 = try await keyboard.readKeymap(profile: 2)
  #expect(profile2.profile == 2)
  let writeProfile2 = await captureError {
    try await keyboard.writeKey(profile: 2, layer: .base, slot: 0, value: [0, 0, 0x32, 0])
  }
  expectUnsupported(writeProfile2)
  #expect(fake.sent(opcode: 0x13).count == 1)

  let outOfRange = await captureError {
    try await keyboard.writeKey(profile: 0, layer: .base, slot: 128, value: [0, 0, 0, 0])
  }
  guard case .invalidArgument? = outOfRange else {
    Issue.record("expected .invalidArgument for slot 128")
    return
  }
}

@Test func keymapWriteSwitchesActiveProfileOnlyWhenNeeded() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.activeProfile = 1
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  let snapshot = try await keyboard.connect()
  #expect(snapshot.profile == 1)
  #expect(fake.sent(opcode: 0x05).isEmpty)

  _ = try await keyboard.writeKey(profile: 0, layer: .base, slot: 0, value: [0, 0, 0x2A, 0])
  #expect(fake.sent(opcode: 0x05).count == 1)
  #expect(fake.activeProfile == 0)
  #expect(Array(fake.baseLayers[0]![0..<4]) == [0, 0, 0x2A, 0])

  // Already active: a second write must not switch again.
  _ = try await keyboard.writeKey(profile: 0, layer: .base, slot: 1, value: [0, 0, 0x2B, 0])
  #expect(fake.sent(opcode: 0x05).count == 1)
}

@Test func keymapRestoreRejectsTailChangesBeforeAnyWrite() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  let current = try await keyboard.readKeymap(profile: 0)
  var changed = current
  changed.base[510] ^= 0xFF

  let error = await captureError { try await keyboard.restoreKeymap(changed) }
  expectUnsupported(error)
  #expect(fake.sent(opcode: 0x09).isEmpty)
  #expect(fake.sent(opcode: 0x05).isEmpty)
}

@Test func keymapRestoreBulkWritesBothLayersAndVerifies() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  var changed = try await keyboard.readKeymap(profile: 0)
  changed.base.replaceSubrange(0..<4, with: [0x03, 0x00, 0xB6, 0x00])
  changed.fn.replaceSubrange(260..<264, with: [0x00, 0x00, 0x40, 0x00])

  let restored = try await keyboard.restoreKeymap(changed)
  #expect(restored.base == changed.base)
  #expect(restored.fn == changed.fn)
  #expect(fake.sent(opcode: 0x09).count == 9)
  #expect(fake.sent(opcode: 0x10).count == 9)
  #expect(fake.baseLayers[0] == changed.base)
  #expect(fake.fnLayers[0] == changed.fn)

  let latestBackup = await keyboard.latestBackupURL()
  let backupURL = try #require(latestBackup)
  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
  #expect(json?["kind"] as? String == "keymap")
}

@Test func keymapRestoreValidatesBothLayerLengths() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  let error = await captureError {
    try await keyboard.restoreKeymap(
      Keymap(
        profile: 0, base: [UInt8](repeating: 0, count: 511), fn: [UInt8](repeating: 0, count: 512))
    )
  }
  guard case .invalidArgument? = error else {
    Issue.record("expected .invalidArgument for a short layer")
    return
  }
  #expect(fake.sent(opcode: 0x09).isEmpty)
}

// MARK: - Macros

@Test func macroWriteUsesFourPagesAndPreservesNonWritableTail() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  var oldMacro = [UInt8](repeating: 0, count: 256)
  oldMacro[250] = 0xAB
  oldMacro[255] = 0xCD
  fake.macroSlots[0] = oldMacro

  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  var desired = [UInt8](repeating: 0, count: 256)
  desired[0] = 2  // repeat count low byte
  desired[10] = 0x11
  desired[223] = 0x22

  let readBack = try await keyboard.writeMacro(slot: 0, bytes: desired)
  #expect(readBack.count == 256)
  #expect(Array(readBack[0..<224]) == Array(desired[0..<224]))
  #expect(Array(readBack[224..<256]) == Array(oldMacro[224..<256]))
  #expect(Array(fake.macroSlots[0]![0..<224]) == Array(desired[0..<224]))
  #expect(Array(fake.macroSlots[0]![224..<256]) == Array(oldMacro[224..<256]))

  let packets = fake.sent(opcode: 0x16)
  #expect(packets.count == 4)
  #expect(packets.compactMap { $0[2] } == [0, 1, 2, 3])
  for (index, packet) in packets.enumerated() {
    #expect(packet[1] == 0)
    #expect(packet[3] == 56)
    #expect(packet[4] == (index == 3 ? 1 : 0))
    #expect(packet[7] == Protocol.bit7Checksum(packet))
  }
  #expect(Array(packets[3][8..<64]) == Array(desired[168..<224]))

  let latestBackup = await keyboard.latestBackupURL()
  let backupURL = try #require(latestBackup)
  let json = try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
  #expect(json?["kind"] as? String == "macro")
  #expect(json?["macroSlot"] as? Int == 0)
  #expect((json?["macro"] as? String)?.count == 512)
}

@Test func macroWriteRefusesNonZeroDataBeyond224AndBadLengths() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }

  let fake = FakeKeyboardDevice()
  fake.macroSlots[0] = [UInt8](repeating: 0, count: 256)
  let keyboard = Keyboard(transport: fake, backupDirectory: directory, timing: .immediate)
  _ = try await keyboard.connect()

  var overflowing = [UInt8](repeating: 0, count: 256)
  overflowing[230] = 0x01
  let overflowError = await captureError {
    try await keyboard.writeMacro(slot: 0, bytes: overflowing)
  }
  expectUnsupported(overflowError)
  #expect(fake.sent(opcode: 0x16).isEmpty)

  let shortError = await captureError {
    try await keyboard.writeMacro(slot: 0, bytes: [UInt8](repeating: 0, count: 255))
  }
  guard case .invalidArgument? = shortError else {
    Issue.record("expected .invalidArgument for a 255-byte macro")
    return
  }
  #expect(fake.sent(opcode: 0x16).isEmpty)
}

// MARK: - Macro codec

@Test func macroCodecUsesCompactAndExtendedForms() throws {
  let sequence = MacroSequence(
    repeatCount: 3,
    steps: [
      MacroStep(code: 0x04, pressed: true, delay: 10),
      MacroStep(code: 0x04, pressed: false, delay: 0),
      MacroStep(code: 0xF0, pressed: true, delay: 200),
      MacroStep(code: 0xF9, pressed: false, delay: 5, dx: -3, dy: 7),
    ]
  )

  let blob = try sequence.encoded()
  #expect(blob.count == 256)
  #expect(blob[0] == 3)
  #expect(blob[1] == 0)
  #expect(
    Array(blob[2..<16]) == [
      0x04, 0x8A,  // 'A' press, compact 10 ms
      0x04, 0x00, 0x00, 0x00,  // release, extended delay 0
      0xF0, 0x80, 0xC8, 0x00,  // mouse button, extended 200 ms
      0xF9, 0x05, 0xFD, 0x07,  // move 5 ms, dx -3, dy 7
    ])
  #expect(Array(blob[16..<20]) == [0, 0, 0, 0])

  let decoded = try MacroSequence.decode(blob)
  #expect(decoded == sequence)
}

@Test func macroCodecRejectsUnknownTruncatedTrailingAndOversizeData() throws {
  var unknown = [UInt8](repeating: 0, count: 256)
  unknown[2] = 0xF8
  #expect(throws: MK750Error.self) {
    _ = try MacroSequence.decode(unknown)
  }

  #expect(throws: MK750Error.self) {
    _ = try MacroSequence.decode([UInt8](repeating: 0, count: 255))
  }

  var trailing = [UInt8](repeating: 0, count: 256)
  trailing[10] = 0x7F
  #expect(throws: MK750Error.self) {
    _ = try MacroSequence.decode(trailing)
  }

  // 63 extended-delay events need 252 bytes, over the 250-byte stream budget.
  let tooMany = MacroSequence(
    repeatCount: 1,
    steps: Array(repeating: MacroStep(code: 0x04, pressed: true, delay: 0), count: 63)
  )
  #expect(throws: MK750Error.self) {
    _ = try tooMany.encoded()
  }
}
