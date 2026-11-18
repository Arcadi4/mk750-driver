import Combine
import Foundation
import Testing

@testable import MK750
@testable import MK750Kit

@MainActor
private func withConnectedStore(_ exercise: (KeyboardStore, FakeKeyboardDevice) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let device = FakeKeyboardDevice()
  let keyboard = Keyboard(transport: device, backupDirectory: directory, timing: .immediate)
  let store = KeyboardStore(keyboard: keyboard, storageDirectory: directory)
  try await waitUntil { store.connection == .connected }
  try await exercise(store, device)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  let end = ContinuousClock.now.advanced(by: .seconds(5))
  while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
  try #require(condition())
}

@Test @MainActor func liveControlsCombineEditsAndFinishOnQuit() async throws {
  try await withConnectedStore { store, device in
    var light = try #require(store.liveLight(for: .main))
    light.brightness = 2
    store.updateLight(light, channel: .main)
    var second = try #require(store.liveLight(for: .main))
    second.red = 32
    store.updateLight(second, channel: .main)
    var settings = try #require(store.liveSettings)
    settings.autoOS.toggle()
    store.updateSettings(settings)
    store.section = .device
    await store.prepareForTermination()
    #expect(device.sent(opcode: 0x07).count == 1)
    #expect(device.main.brightness == 2 && device.main.red == 32)
    #expect(device.autoOS == settings.autoOS)
    #expect(store.snapshot?.main == second)
  }
}

@Test @MainActor func failedLiveChangeDropsRemainingWritesAcrossReconnect() async throws {
  try await withConnectedStore { store, device in
    device.failSendOpcodes = [0x07]
    var light = try #require(store.liveLight(for: .main))
    light.brightness = 0
    store.updateLight(light, channel: .main)
    var settings = try #require(store.liveSettings)
    settings.debounce = 5
    store.updateSettings(settings)
    try await waitUntil { !store.isBusy }
    #expect(store.notice?.kind == .failure)
    await store.connect()
    #expect(store.liveSettings?.debounce == 1)
    #expect(device.sent(opcode: 0x11).isEmpty)
    #expect(device.sent(opcode: 0x07).count == 1)
  }
}

@Test @MainActor func liveSettingsRequireConfirmationToLockKeyboard() async throws {
  try await withConnectedStore { store, device in
    var settings = try #require(store.liveSettings)
    settings.options |= 128
    store.updateSettings(settings)
    #expect(store.liveSettings?.options == device.optionByte2)
    #expect(!store.isUpdatingKeyboard)
    store.updateSettings(settings, allowKeyboardLock: true)
    try await waitUntil { !store.isBusy }
    #expect(device.optionByte2 == settings.options)
    #expect(device.sent(opcode: 0x06).count == 1)
  }
}

@Test @MainActor func newerInputSurvivesAnEarlierReadback() async throws {
  try await withConnectedStore { store, device in
    var first = try #require(store.liveLight(for: .main))
    first.brightness = 1
    // Deliver another edit exactly when the first verified result arrives,
    // before the writer has relinquished the control.
    let subscription = store.$snapshot.dropFirst().prefix(1).sink { _ in
      guard var latest = store.liveLight(for: .main) else { return }
      latest.brightness = 3
      store.updateLight(latest, channel: .main)
    }
    defer { subscription.cancel() }
    store.updateLight(first, channel: .main)
    try await waitUntil { !store.isBusy }
    #expect(device.sent(opcode: 0x07).map { $0[3] } == [1, 3])
    #expect(store.snapshot?.main.brightness == 3)
  }
}
