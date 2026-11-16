import Darwin
import Foundation

/// Native controller for the FL Esports MK750 (board 849, yc500 family).
///
/// Reads are always allowed on a verified connection. Writes are gated on a
/// fresh enumeration plus identify/revision/family evidence, always persist a
/// JSON backup before their first SET, are paced, and are verified by read-back
/// or they fail with `MK750Error.verificationFailed`. The library never seizes
/// the keyboard and never sends an opcode outside its documented allow-list.
public actor Keyboard {
  // MARK: - Timing

  struct Timing {
    var afterSet: TimeInterval = 0.15
    var look: TimeInterval = 0.15
    var flashPage: TimeInterval = 0.10
    var commit: TimeInterval = 2.0
    var rawRetry: TimeInterval = 0.10

    static let immediate = Timing(
      afterSet: 0,
      look: 0,
      flashPage: 0,
      commit: 0,
      rawRetry: 0
    )
  }

  // MARK: - State

  private let makeTransport: () -> any MK750Transport
  private let backupDirectory: URL
  private let timing: Timing

  private var transport: (any MK750Transport)?
  private var identity: DeviceIdentity?
  private var trusted = false
  private var mostRecentBackup: URL?

  // MARK: - Initializers

  /// Real IOKit transport. Enumeration runs fresh in `connect()`.
  public init() {
    self.makeTransport = { IOKitHIDTransport() }
    self.backupDirectory = Keyboard.defaultBackupDirectory()
    self.timing = Timing()
  }

  /// Test seam with deterministic pacing. Internal so the public API stays
  /// exactly the contract's surface.
  init(transport: any MK750Transport, backupDirectory: URL?, timing: Timing) {
    self.makeTransport = { transport }
    self.backupDirectory = backupDirectory ?? Keyboard.defaultBackupDirectory()
    self.timing = timing
  }

  // MARK: - Connection

  /// Fresh enumeration, identity gate, revision gate, and family probe. No
  /// SET is sent. Returns the complete read-only state.
  public func connect() throws -> DeviceSnapshot {
    teardown()

    let transport = makeTransport()
    do {
      try transport.open()
    } catch let error as MK750Error {
      transport.close()
      throw error
    } catch {
      transport.close()
      throw MK750Error.transport(error.localizedDescription)
    }
    self.transport = transport

    do {
      let identity = try establishIdentity()
      self.identity = identity
      let raw = try captureSettingsRaw()
      let snapshot = try raw.snapshot(identity: identity)
      trusted = true
      return snapshot
    } catch {
      loseTrust()
      if let error = error as? MK750Error {
        throw error
      }
      throw MK750Error.transport(error.localizedDescription)
    }
  }

  public func disconnect() {
    teardown()
  }

  /// Re-reads the complete state without any write.
  public func refresh() throws -> DeviceSnapshot {
    try perform {
      try ensureConnected()
      guard let identity else { throw MK750Error.notConnected }
      let raw = try captureSettingsRaw()
      return try raw.snapshot(identity: identity)
    }
  }

  // MARK: - Lighting

  public func setLight(_ state: LightState, channel: LightChannel) throws -> DeviceSnapshot {
    try perform {
      try ensureWritable()
      guard state.mode <= 31 else {
        throw MK750Error.invalidArgument(
          "lighting mode \(state.mode) exceeds the documented maximum 31"
        )
      }

      let before = try captureSettingsRaw()
      let current = channel == .main ? before.main : before.side
      let otherBefore = channel == .main ? before.side : before.main
      if current == state {
        guard let identity else { throw MK750Error.notConnected }
        return try before.snapshot(identity: identity)
      }

      _ = try persistSettingsBackup(before)
      try sendPacket(Protocol.lightSetPacket(opcode: channel.setOpcode, state: state))
      pause(timing.afterSet)

      let after = try readSettings(
        describing: "\(channel.rawValue) lighting did not match the requested state"
      ) { raw in
        let readBack = channel == .main ? raw.main : raw.side
        let other = channel == .main ? raw.side : raw.main
        return readBack == state && other == otherBefore
      }
      guard let identity else { throw MK750Error.notConnected }
      return try after.snapshot(identity: identity)
    }
  }

  // MARK: - Settings

  public func setProfile(_ profile: UInt8) throws -> DeviceSnapshot {
    try perform {
      try ensureWritable()
      try Protocol.validateWritableProfile(profile)

      let before = try captureSettingsRaw()
      if before.profileReply[1] == profile {
        guard let identity else { throw MK750Error.notConnected }
        return try before.snapshot(identity: identity)
      }

      _ = try persistSettingsBackup(before)
      try sendPacket(Protocol.profileSetPacket(profile))
      pause(timing.afterSet)

      let after = try readSettings(
        describing: "active profile did not switch to \(profile)"
      ) { $0.profileReply[1] == profile }
      guard let identity else { throw MK750Error.notConnected }
      return try after.snapshot(identity: identity)
    }
  }

  /// Flips exactly one options bit and preserves every other bit, the Fn
  /// matrix flag, and power save.
  public func setOption(mask: UInt8, enabled: Bool) throws -> DeviceSnapshot {
    try perform {
      try ensureWritable()
      guard mask != 0, mask.nonzeroBitCount == 1 else {
        throw MK750Error.invalidArgument(
          String(format: "option mask 0x%02X must contain exactly one bit", mask)
        )
      }

      let before = try captureSettingsRaw()
      guard let register = Protocol.decodeOptions(before.optionsReply) else {
        throw MK750Error.verificationFailed("options reply was not 64 bytes")
      }
      let updated = enabled ? (register.options | mask) : (register.options & ~mask)
      if updated == register.options {
        guard let identity else { throw MK750Error.notConnected }
        return try before.snapshot(identity: identity)
      }

      let expected = Protocol.OptionsRegister(
        options: updated,
        fnMatrix: register.fnMatrix,
        powerSave: register.powerSave
      )
      _ = try persistSettingsBackup(before)
      try sendPacket(Protocol.optionsSetPacket(expected))
      pause(timing.afterSet)

      let after = try readSettings(
        describing: "options register did not preserve the other bits"
      ) { raw in
        Protocol.decodeOptions(raw.optionsReply) == expected
      }
      guard let identity else { throw MK750Error.notConnected }
      return try after.snapshot(identity: identity)
    }
  }

  public func setDebounce(_ value: UInt8) throws -> DeviceSnapshot {
    try perform {
      try ensureWritable()
      guard (1...10).contains(value) else {
        throw MK750Error.invalidArgument("debounce must be 1...10 ms, got \(value)")
      }

      let before = try captureSettingsRaw()
      if before.debounceReply[2] == value {
        guard let identity else { throw MK750Error.notConnected }
        return try before.snapshot(identity: identity)
      }

      _ = try persistSettingsBackup(before)
      try sendPacket(Protocol.debounceSetPacket(value))
      pause(timing.afterSet)

      let after = try readSettings(
        describing: "debounce did not read back as \(value)"
      ) { $0.debounceReply[2] == value }
      guard let identity else { throw MK750Error.notConnected }
      return try after.snapshot(identity: identity)
    }
  }

  public func setSleep(_ timers: SleepTimers) throws -> DeviceSnapshot {
    try perform {
      try ensureWritable()

      let before = try captureSettingsRaw()
      if Protocol.decodeSleep(before.sleepReply) == timers {
        guard let identity else { throw MK750Error.notConnected }
        return try before.snapshot(identity: identity)
      }

      _ = try persistSettingsBackup(before)
      try sendPacket(Protocol.sleepSetPacket(timers))
      pause(timing.afterSet)

      let after = try readSettings(
        describing: "sleep timers did not read back as requested"
      ) { Protocol.decodeSleep($0.sleepReply) == timers }
      guard let identity else { throw MK750Error.notConnected }
      return try after.snapshot(identity: identity)
    }
  }

  public func setAutoOS(_ enabled: Bool) throws -> DeviceSnapshot {
    try perform {
      try ensureWritable()

      let before = try captureSettingsRaw()
      let current = before.autoOSReply[1] == 1
      if current == enabled {
        guard let identity else { throw MK750Error.notConnected }
        return try before.snapshot(identity: identity)
      }

      _ = try persistSettingsBackup(before)
      try sendPacket(Protocol.autoOSSetPacket(enabled))
      pause(timing.afterSet)

      let after = try readSettings(
        describing: "auto-OS did not read back as \(enabled ? "enabled" : "disabled")"
      ) { ($0.autoOSReply[1] == 1) == enabled }
      guard let identity else { throw MK750Error.notConnected }
      return try after.snapshot(identity: identity)
    }
  }

  // MARK: - Keymap

  public func readKeymap(profile: UInt8) throws -> Keymap {
    try perform {
      try ensureConnected()
      try Protocol.validateReadableProfile(profile)
      let layers = try readBothLayers(profile: profile)
      return Keymap(profile: profile, base: layers.base, fn: layers.fn)
    }
  }

  /// Saves both layers and the identity to a timestamped JSON document.
  public func backupKeymap(profile: UInt8) throws -> URL {
    try perform {
      try ensureConnected()
      try Protocol.validateReadableProfile(profile)
      let layers = try readBothLayers(profile: profile)
      return try persistKeymapBackup(profile: profile, base: layers.base, fn: layers.fn)
    }
  }

  /// Writes one 4-byte slot. Tries the single-slot opcode first, verifies up
  /// to three times, and falls back to the nine-page bulk upload only for
  /// slots 0...125 (the last two slots are not representable in that path).
  /// The other layer is read back and proven unchanged.
  public func writeKey(
    profile: UInt8,
    layer: KeyLayer,
    slot: Int,
    value: [UInt8]
  ) throws -> Keymap {
    try perform {
      try ensureWritable()
      try Protocol.validateWritableProfile(profile)
      try Protocol.validateSlot(slot)
      guard value.count == Protocol.slotBytes else {
        throw MK750Error.invalidArgument(
          "a keymap slot value must be \(Protocol.slotBytes) bytes, got \(value.count)"
        )
      }

      let current = try readBothLayers(profile: profile)
      let currentTarget = layer == .base ? current.base : current.fn
      let preservedOther = layer == .base ? current.fn : current.base
      var expectedTarget = currentTarget
      let offset = slot * Protocol.slotBytes
      expectedTarget.replaceSubrange(offset..<(offset + Protocol.slotBytes), with: value)

      _ = try persistKeymapBackup(profile: profile, base: current.base, fn: current.fn)
      try ensureActiveProfile(profile)

      try sendPacket(
        Protocol.singleSlotPacket(
          opcode: layer.singleSlotOpcode,
          profile: profile,
          slot: slot,
          value: value
        )
      )
      pause(timing.afterSet)

      let singleSlotLanded = try singleSlotMatches(
        profile: profile,
        layer: layer,
        slot: slot,
        expected: value
      )

      if singleSlotLanded {
        let reread = try readLayer(profile: profile, layer: layer)
        if reread != expectedTarget {
          try bulkRepairIfPossible(
            profile: profile,
            layer: layer,
            slot: slot,
            expectedLayer: expectedTarget
          )
        }
      } else {
        try bulkRepairIfPossible(
          profile: profile,
          layer: layer,
          slot: slot,
          expectedLayer: expectedTarget
        )
      }

      let after = try readBothLayers(profile: profile)
      let afterTarget = layer == .base ? after.base : after.fn
      let afterOther = layer == .base ? after.fn : after.base
      guard afterTarget == expectedTarget else {
        throw MK750Error.verificationFailed(
          "\(layer.rawValue) layer did not read back exactly after the keymap write"
        )
      }
      guard afterOther == preservedOther else {
        throw MK750Error.verificationFailed(
          "the other keymap layer changed during a single-slot write"
        )
      }

      return Keymap(profile: profile, base: after.base, fn: after.fn)
    }
  }

  /// Validates a complete two-layer keymap before any mutation, then restores
  /// it with the bulk path. Inputs that change slots 126...127 are rejected:
  /// those eight bytes per layer are not representable in the documented
  /// nine-page upload.
  public func restoreKeymap(_ keymap: Keymap) throws -> Keymap {
    try perform {
      try ensureWritable()
      try Protocol.validateWritableProfile(keymap.profile)
      guard keymap.base.count == Protocol.layerBytes else {
        throw MK750Error.invalidArgument(
          "base layer must be \(Protocol.layerBytes) bytes, got \(keymap.base.count)"
        )
      }
      guard keymap.fn.count == Protocol.layerBytes else {
        throw MK750Error.invalidArgument(
          "Fn layer must be \(Protocol.layerBytes) bytes, got \(keymap.fn.count)"
        )
      }

      let current = try readBothLayers(profile: keymap.profile)
      guard
        keymap.base[Protocol.bulkRepresentableBytes...]
          == current.base[Protocol.bulkRepresentableBytes...],
        keymap.fn[Protocol.bulkRepresentableBytes...]
          == current.fn[Protocol.bulkRepresentableBytes...]
      else {
        throw MK750Error.unsupported(
          "slots 126 and 127 cannot be written by the nine-page bulk path; "
            + "keep their current eight bytes per layer unchanged"
        )
      }

      if keymap.base == current.base && keymap.fn == current.fn {
        return keymap
      }

      _ = try persistKeymapBackup(
        profile: keymap.profile,
        base: current.base,
        fn: current.fn
      )
      try ensureActiveProfile(keymap.profile)

      if keymap.base != current.base {
        try bulkWriteLayer(
          profile: keymap.profile,
          layer: .base,
          layerBytes: keymap.base
        )
      }
      if keymap.fn != current.fn {
        try bulkWriteLayer(
          profile: keymap.profile,
          layer: .fn,
          layerBytes: keymap.fn
        )
      }

      let after = try readBothLayers(profile: keymap.profile)
      guard after.base == keymap.base, after.fn == keymap.fn else {
        throw MK750Error.verificationFailed(
          "restored keymap layers did not read back exactly"
        )
      }
      return Keymap(profile: keymap.profile, base: after.base, fn: after.fn)
    }
  }

  // MARK: - Macros

  public func readMacro(slot: Int) throws -> [UInt8] {
    try perform {
      try ensureConnected()
      try Protocol.validateMacroSlot(slot)
      return try readMacroBlob(slot: slot)
    }
  }

  /// Writes a 256-byte macro blob through pages 0...3.
  ///
  /// The four 56-byte pages cover bytes 0...223 only. Bytes 224...255 are
  /// not writable: if the requested tail differs from the current tail and
  /// contains a non-zero byte, the write is refused before any SET. A
  /// requested all-zero tail leaves the existing tail untouched, and the
  /// returned read-back is the full 256-byte result.
  public func writeMacro(slot: Int, bytes: [UInt8]) throws -> [UInt8] {
    try perform {
      try ensureWritable()
      try Protocol.validateMacroSlot(slot)
      guard bytes.count == Protocol.macroBytes else {
        throw MK750Error.invalidArgument(
          "a macro blob must be \(Protocol.macroBytes) bytes, got \(bytes.count)"
        )
      }

      let current = try readMacroBlob(slot: slot)
      let requestedTail = Array(bytes[Protocol.macroWritableBytes...])
      let currentTail = Array(current[Protocol.macroWritableBytes...])
      if requestedTail != currentTail && requestedTail.contains(where: { $0 != 0 }) {
        throw MK750Error.unsupported(
          "macro pages 0...3 cover only the first 224 bytes; bytes 224...255 "
            + "cannot be written. This request needs non-zero data in that non-writable tail."
        )
      }

      _ = try persistMacroBackup(slot: slot, blob: current)

      for page in 0..<Protocol.macroPageCount {
        let start = page * Protocol.macroPagePayload
        let end = start + Protocol.macroPagePayload
        try sendPacket(
          Protocol.macroSetPacket(
            slot: slot,
            page: page,
            payload: bytes[start..<end]
          )
        )
        if page < Protocol.macroPageCount - 1 {
          pause(timing.flashPage)
        }
      }
      pause(timing.commit)

      let expectedPrefix = Array(bytes[0..<Protocol.macroWritableBytes])
      for attempt in 0..<2 {
        let readBack = try readMacroBlob(slot: slot)
        let prefixMatches = Array(readBack[0..<Protocol.macroWritableBytes]) == expectedPrefix
        let readTail = Array(readBack[Protocol.macroWritableBytes...])
        // The non-writable tail is either preserved or cleared by the
        // commit path; any other value is a failed write.
        let tailPreserved = readTail == currentTail
        let tailCleared = readTail.allSatisfy { $0 == 0 }
        if prefixMatches && (tailPreserved || tailCleared) {
          return readBack
        }
        if attempt == 0 {
          pause(timing.look)
        }
      }
      throw MK750Error.verificationFailed(
        "macro slot \(slot) did not read back with the requested 256 bytes"
      )
    }
  }

  // MARK: - Backups

  /// Newest backup JSON by modification time, or nil when none exists.
  public func latestBackupURL() -> URL? {
    let manager = FileManager.default
    guard
      let urls = try? manager.contentsOfDirectory(
        at: backupDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return mostRecentBackup
    }
    let candidates = urls.filter { $0.pathExtension.lowercased() == "json" }
    guard
      let newest = candidates.max(by: { lhs, rhs in
        let left =
          (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        let right =
          (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        return left < right
      })
    else {
      return mostRecentBackup
    }
    return newest
  }

  // MARK: - Identity and family gates

  private func establishIdentity() throws -> DeviceIdentity {
    let identify = try pairedGet(opcode: Protocol.Op.identify)
    guard let board = Protocol.boardID(fromIdentifyReply: identify) else {
      throw MK750Error.identityFailed(
        "identify reply \(identify.prefix(8).mk750Hex) did not echo 0x8F"
      )
    }
    guard board == Protocol.boardID else {
      throw MK750Error.identityFailed(
        "board ID \(board) is not the supported MK750 board 849"
      )
    }

    let revisionReply = try pairedGet(opcode: Protocol.Op.revision)
    guard let firmware = Protocol.firmwareVersion(fromRevisionReply: revisionReply) else {
      throw MK750Error.identityFailed(
        "revision reply \(revisionReply.prefix(8).mk750Hex) is not a non-zero BCD revision"
      )
    }

    let yc500Page = try rawPage(
      opcode: Protocol.Op.getBaseKeymap,
      arguments: [0, 0]
    )
    let gen2Page = try rawPage(
      opcode: Protocol.Op.gen2KeymapProbe,
      arguments: [0, 0xFF, 0, 0]
    )

    guard Protocol.isAll(0xFF, in: gen2Page[...]) else {
      throw MK750Error.familyUnverified(
        "the gen2 keymap probe did not answer all FF, so the family is ambiguous"
      )
    }
    guard !Protocol.isAll(0xFF, in: yc500Page[...]), yc500Page != gen2Page else {
      throw MK750Error.familyUnverified(
        "the yc500 keymap probe returned an erased page, so the family is ambiguous"
      )
    }

    return DeviceIdentity(
      boardID: board,
      firmware: firmware,
      vendorID: Protocol.vendorID,
      productID: Protocol.productID
    )
  }

  // MARK: - Read path

  private struct SettingsRaw {
    var profileReply: [UInt8]
    var mainReply: [UInt8]
    var sideReply: [UInt8]
    var debounceReply: [UInt8]
    var sleepReply: [UInt8]
    var optionsReply: [UInt8]
    var autoOSReply: [UInt8]

    var main: LightState {
      Protocol.decodeLight(mainReply)
        ?? LightState(
          mode: 0, speed: 0, brightness: 0, flags: 0, red: 0, green: 0, blue: 0
        )
    }

    var side: LightState {
      Protocol.decodeLight(sideReply)
        ?? LightState(
          mode: 0, speed: 0, brightness: 0, flags: 0, red: 0, green: 0, blue: 0
        )
    }

    func snapshot(identity: DeviceIdentity) throws -> DeviceSnapshot {
      guard let decodedMain = Protocol.decodeLight(mainReply) else {
        throw MK750Error.verificationFailed("main lighting reply was not 64 bytes")
      }
      guard let decodedSide = Protocol.decodeLight(sideReply) else {
        throw MK750Error.verificationFailed("side lighting reply was not 64 bytes")
      }
      guard let sleep = Protocol.decodeSleep(sleepReply) else {
        throw MK750Error.verificationFailed("sleep reply was not 64 bytes")
      }
      guard let options = Protocol.decodeOptions(optionsReply) else {
        throw MK750Error.verificationFailed("options reply was not 64 bytes")
      }
      return DeviceSnapshot(
        boardID: identity.boardID,
        firmware: identity.firmware,
        profile: profileReply[1],
        main: decodedMain,
        side: decodedSide,
        debounce: debounceReply[2],
        sleep: sleep,
        options: options.options,
        fnMatrix: options.fnMatrix,
        powerSave: options.powerSave,
        autoOS: autoOSReply[1] == 1
      )
    }
  }

  private func captureSettingsRaw() throws -> SettingsRaw {
    SettingsRaw(
      profileReply: try pairedGet(opcode: Protocol.Op.getProfile),
      mainReply: try pairedGet(opcode: Protocol.Op.getMainLight),
      sideReply: try pairedGet(opcode: Protocol.Op.getSideLight),
      debounceReply: try pairedGet(opcode: Protocol.Op.getDebounce),
      sleepReply: try pairedGet(opcode: Protocol.Op.getSleep),
      optionsReply: try pairedGet(opcode: Protocol.Op.getOptions),
      autoOSReply: try pairedGet(opcode: Protocol.Op.getAutoOS)
    )
  }

  private func readSettings(
    describing failure: String,
    _ matches: (SettingsRaw) -> Bool
  ) throws -> SettingsRaw {
    for attempt in 0..<3 {
      let raw = try captureSettingsRaw()
      if matches(raw) {
        return raw
      }
      if attempt < 2 {
        pause(timing.look)
      }
    }
    throw MK750Error.verificationFailed(failure)
  }

  private func readLayer(profile: UInt8, layer: KeyLayer) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: Protocol.layerBytes)
    for page in 0..<Protocol.layerPageCount {
      let pageBytes = try rawPage(
        opcode: layer.readOpcode,
        arguments: [profile, UInt8(page)]
      )
      let start = page * Protocol.pageBytes
      bytes.replaceSubrange(start..<(start + Protocol.pageBytes), with: pageBytes)
    }
    return bytes
  }

  private func readBothLayers(profile: UInt8) throws -> (base: [UInt8], fn: [UInt8]) {
    let base = try readLayer(profile: profile, layer: .base)
    let fn = try readLayer(profile: profile, layer: .fn)
    return (base, fn)
  }

  private func readMacroBlob(slot: Int) throws -> [UInt8] {
    var blob = [UInt8]()
    blob.reserveCapacity(Protocol.macroBytes)
    for page in 0..<Protocol.macroPageCount {
      blob.append(
        contentsOf: try rawPage(
          opcode: Protocol.Op.getMacro,
          arguments: [UInt8(slot), UInt8(page)]
        )
      )
    }
    return blob
  }

  // MARK: - Keymap write internals

  private func singleSlotMatches(
    profile: UInt8,
    layer: KeyLayer,
    slot: Int,
    expected: [UInt8]
  ) throws -> Bool {
    let (page, offset) = Protocol.slotPageAndOffset(slot)
    for attempt in 0..<3 {
      let pageBytes = try rawPage(
        opcode: layer.readOpcode,
        arguments: [profile, UInt8(page)]
      )
      if Array(pageBytes[offset..<(offset + Protocol.slotBytes)]) == expected {
        return true
      }
      if attempt < 2 {
        pause(timing.look)
      }
    }
    return false
  }

  /// Throws when the slot is not representable and the single-slot write did
  /// not land.
  private func bulkRepairIfPossible(
    profile: UInt8,
    layer: KeyLayer,
    slot: Int,
    expectedLayer: [UInt8]
  ) throws {
    guard slot <= Protocol.lastBulkSlot else {
      throw MK750Error.unsupported(
        "the board did not accept the single-slot write and slot \(slot) is in the "
          + "final eight bytes that the nine-page bulk upload cannot send"
      )
    }
    try bulkWriteLayer(profile: profile, layer: layer, layerBytes: expectedLayer)
  }

  private func bulkWriteLayer(profile: UInt8, layer: KeyLayer, layerBytes: [UInt8]) throws {
    precondition(layerBytes.count == Protocol.layerBytes)

    for page in 0..<Protocol.bulkPageCount {
      let start = page * Protocol.bulkPagePayload
      let end = start + Protocol.bulkPagePayload
      try sendPacket(
        Protocol.bulkKeymapPacket(
          opcode: layer.bulkOpcode,
          profile: profile,
          page: page,
          payload: layerBytes[start..<end]
        )
      )
      if page < Protocol.bulkPageCount - 1 {
        pause(timing.flashPage)
      }
    }
    pause(timing.commit)

    for attempt in 0..<2 {
      let readBack = try readLayer(profile: profile, layer: layer)
      if readBack == layerBytes {
        return
      }
      if attempt == 0 {
        pause(timing.look)
      }
    }
    throw MK750Error.verificationFailed(
      "\(layer.rawValue) layer did not read back exactly after the bulk upload"
    )
  }

  private func ensureActiveProfile(_ profile: UInt8) throws {
    let reply = try pairedGet(opcode: Protocol.Op.getProfile)
    if reply[1] == profile {
      return
    }

    // The switch is a settings write too: save the active settings before
    // the profile SET, then verify the new active profile.
    let before = try captureSettingsRaw()
    _ = try persistSettingsBackup(before)
    try sendPacket(Protocol.profileSetPacket(profile))
    pause(timing.afterSet)

    for attempt in 0..<3 {
      let check = try pairedGet(opcode: Protocol.Op.getProfile)
      if check[1] == profile {
        return
      }
      if attempt < 2 {
        pause(timing.look)
      }
    }
    throw MK750Error.verificationFailed(
      "active profile did not switch to \(profile) before the keymap write"
    )
  }

  // MARK: - Transport transactions

  private func pairedGet(opcode: UInt8, arguments: [UInt8] = []) throws -> [UInt8] {
    let request = Protocol.getRequest(opcode: opcode, arguments: arguments)

    try sendPacket(request)
    _ = try receiveReport()  // May be the stale reply to an earlier GET.

    try sendPacket(request)
    let reply = try receiveReport()
    guard reply[0] == opcode else {
      throw MK750Error.verificationFailed(
        String(
          format: "reply opcode 0x%02X did not echo 0x%02X",
          reply[0],
          opcode
        )
      )
    }
    return reply
  }

  /// Bulk page reads carry no opcode echo, so stability is checked instead:
  /// both replies in a paired read must agree, retried up to three times.
  private func rawPage(opcode: UInt8, arguments: [UInt8]) throws -> [UInt8] {
    let request = Protocol.getRequest(opcode: opcode, arguments: arguments)
    for attempt in 0..<3 {
      try sendPacket(request)
      let first = try receiveReport()
      try sendPacket(request)
      let second = try receiveReport()
      if first == second {
        return second
      }
      if attempt < 2 {
        pause(timing.rawRetry)
      }
    }
    throw MK750Error.verificationFailed(
      String(
        format: "raw page opcode 0x%02X did not stabilise after three paired reads",
        opcode
      )
    )
  }

  private func sendPacket(_ packet: [UInt8]) throws {
    guard let transport else { throw MK750Error.notConnected }
    do {
      try transport.send(packet)
    } catch let error as MK750Error {
      loseTrust()
      throw error
    } catch {
      loseTrust()
      throw MK750Error.transport(error.localizedDescription)
    }
  }

  private func receiveReport() throws -> [UInt8] {
    guard let transport else { throw MK750Error.notConnected }
    do {
      let reply = try transport.receive()
      guard reply.count == Protocol.reportLength else {
        loseTrust()
        throw MK750Error.transport(
          "received \(reply.count) bytes; the feature report must be \(Protocol.reportLength)"
        )
      }
      return reply
    } catch let error as MK750Error {
      loseTrust()
      throw error
    } catch {
      loseTrust()
      throw MK750Error.transport(error.localizedDescription)
    }
  }

  // MARK: - Gating

  private func ensureConnected() throws {
    guard trusted, identity != nil, transport != nil else {
      throw MK750Error.notConnected
    }
  }

  private func ensureWritable() throws {
    guard trusted, identity != nil, transport != nil else {
      throw MK750Error.notConnected
    }
  }

  private func perform<T>(_ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as MK750Error {
      if error.clearsTrust {
        loseTrust()
      }
      throw error
    } catch {
      loseTrust()
      throw MK750Error.transport(error.localizedDescription)
    }
  }

  private func loseTrust() {
    transport?.close()
    transport = nil
    identity = nil
    trusted = false
  }

  private func teardown() {
    loseTrust()
    mostRecentBackup = nil
  }

  private func pause(_ seconds: TimeInterval) {
    guard seconds > 0 else { return }
    Thread.sleep(forTimeInterval: seconds)
  }

  // MARK: - Backup persistence

  private struct DeviceIdentity: Codable, Equatable, Sendable {
    var boardID: UInt32
    var firmware: String
    var vendorID: Int
    var productID: Int
  }

  private struct BackupDocument: Codable {
    var schemaVersion: Int
    var kind: String
    var createdAt: String
    var identity: DeviceIdentity
    var profile: UInt8?
    var base: String?
    var fn: String?
    var macroSlot: Int?
    var macro: String?
    var settings: SettingsBackup?

    struct SettingsBackup: Codable {
      var profileReply: String
      var mainReply: String
      var sideReply: String
      var debounceReply: String
      var sleepReply: String
      var optionsReply: String
      var autoOSReply: String
    }
  }

  private func persistKeymapBackup(profile: UInt8, base: [UInt8], fn: [UInt8]) throws -> URL {
    guard let identity else { throw MK750Error.notConnected }
    let now = Date()
    let document = BackupDocument(
      schemaVersion: 1,
      kind: "keymap",
      createdAt: Keyboard.isoTimestamp(now),
      identity: identity,
      profile: profile,
      base: base.mk750Hex,
      fn: fn.mk750Hex,
      macroSlot: nil,
      macro: nil,
      settings: nil
    )
    return try persistBackup(
      document,
      baseName: "keymap-profile\(profile)-\(Keyboard.fileStamp(now))"
    )
  }

  private func persistSettingsBackup(_ raw: SettingsRaw) throws -> URL {
    guard let identity else { throw MK750Error.notConnected }
    let now = Date()
    let document = BackupDocument(
      schemaVersion: 1,
      kind: "settings",
      createdAt: Keyboard.isoTimestamp(now),
      identity: identity,
      profile: raw.profileReply[1],
      base: nil,
      fn: nil,
      macroSlot: nil,
      macro: nil,
      settings: BackupDocument.SettingsBackup(
        profileReply: raw.profileReply.mk750Hex,
        mainReply: raw.mainReply.mk750Hex,
        sideReply: raw.sideReply.mk750Hex,
        debounceReply: raw.debounceReply.mk750Hex,
        sleepReply: raw.sleepReply.mk750Hex,
        optionsReply: raw.optionsReply.mk750Hex,
        autoOSReply: raw.autoOSReply.mk750Hex
      )
    )
    return try persistBackup(document, baseName: "settings-\(Keyboard.fileStamp(now))")
  }

  private func persistMacroBackup(slot: Int, blob: [UInt8]) throws -> URL {
    guard let identity else { throw MK750Error.notConnected }
    let now = Date()
    let document = BackupDocument(
      schemaVersion: 1,
      kind: "macro",
      createdAt: Keyboard.isoTimestamp(now),
      identity: identity,
      profile: nil,
      base: nil,
      fn: nil,
      macroSlot: slot,
      macro: blob.mk750Hex,
      settings: nil
    )
    return try persistBackup(
      document,
      baseName: "macro-slot\(slot)-\(Keyboard.fileStamp(now))"
    )
  }

  private func persistBackup(_ document: BackupDocument, baseName: String) throws -> URL {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: backupDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      throw MK750Error.backupFailed(
        "could not create \(backupDirectory.path): \(error.localizedDescription)"
      )
    }

    var url = backupDirectory.appendingPathComponent("\(baseName).json")
    var collision = 1
    while manager.fileExists(atPath: url.path) {
      url = backupDirectory.appendingPathComponent("\(baseName)-\(collision).json")
      collision += 1
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try encoder.encode(document)
    } catch {
      throw MK750Error.backupFailed("could not encode backup JSON: \(error.localizedDescription)")
    }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw MK750Error.backupFailed(
        "could not write \(url.path): \(error.localizedDescription)"
      )
    }

    // Durability: the write above is atomic; fsync the resulting file so a
    // power loss cannot leave the only backup unwritten before a SET.
    let descriptor = url.path.withCString { Darwin.open($0, O_RDWR) }
    guard descriptor >= 0 else {
      try? manager.removeItem(at: url)
      throw MK750Error.backupFailed("could not reopen \(url.path) for fsync")
    }
    defer { _ = Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      try? manager.removeItem(at: url)
      throw MK750Error.backupFailed("could not fsync \(url.path)")
    }

    // Best-effort directory sync so the rename that published the backup
    // is durable too; some filesystems reject fsync on a directory.
    let directoryDescriptor = backupDirectory.path.withCString { Darwin.open($0, O_RDONLY) }
    if directoryDescriptor >= 0 {
      _ = Darwin.fsync(directoryDescriptor)
      _ = Darwin.close(directoryDescriptor)
    }

    mostRecentBackup = url
    return url
  }

  private static func defaultBackupDirectory() -> URL {
    let manager = FileManager.default
    let applicationSupport: URL
    if let resolved = try? manager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ) {
      applicationSupport = resolved
    } else {
      applicationSupport = manager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
    return
      applicationSupport
      .appendingPathComponent("MK750", isDirectory: true)
      .appendingPathComponent("Backups", isDirectory: true)
  }

  private static func fileStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
    return formatter.string(from: date)
  }

  private static func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }
}

// MARK: - Helpers

extension MK750Error {
  fileprivate var clearsTrust: Bool {
    switch self {
    case .transport, .verificationFailed, .identityFailed, .familyUnverified, .notConnected:
      return true
    case .deviceNotFound, .unsupported, .invalidArgument, .backupFailed, .macroEncoding:
      return false
    }
  }
}

extension Sequence where Element == UInt8 {
  var mk750Hex: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
