import AppKit
import Darwin
import Dispatch
import MK750Kit
import SwiftUI

// MARK: - Entry point

@main
enum MK750Main {
  @MainActor
  static func main() {
    if CommandLine.arguments.dropFirst().contains("--diagnose") {
      runDiagnose()
    }
    MK750App.main()
  }

  /// Read-only command-line mode. No NSApplication is created, no UI is
  /// shown and only `Keyboard.connect()` (a GET-only path) is called.
  private static func runDiagnose() -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    let outcome = DiagnoseOutcome()

    Task.detached(priority: .userInitiated) {
      let keyboard = Keyboard()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

      do {
        let snapshot = try await keyboard.connect()
        let data = try encoder.encode(snapshot)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        outcome.set(0)
      } catch {
        let report = DiagnoseFailure(ok: false, error: KeyboardStore.describe(error))
        let data =
          (try? encoder.encode(report)) ?? Data(#"{"ok":false,"error":"unknown failure"}"#.utf8)
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        outcome.set(1)
      }

      await keyboard.disconnect()
      semaphore.signal()
    }

    if semaphore.wait(timeout: .now() + 30) == .timedOut {
      FileHandle.standardError.write(Data("diagnose: timed out after 30 seconds\n".utf8))
      exit(2)
    }
    exit(outcome.value)
  }
}

private final class DiagnoseOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int32 = 1

  var value: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ value: Int32) {
    lock.lock()
    stored = value
    lock.unlock()
  }
}

private struct DiagnoseFailure: Encodable {
  let ok: Bool
  let error: String
}

// MARK: - App

struct MK750App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Window("MK750", id: "control") {
      ControlWindowView(store: .shared)
    }
    .defaultSize(width: 980, height: 680)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.presented)
    .restorationBehavior(.disabled)
    .commands {
      ControlCommands(store: .shared)
    }

    MenuBarExtra {
      MenuBarPanel(store: .shared)
    } label: {
      Label("MK750", systemImage: "keyboard")
        .accessibilityLabel("MK750 keyboard controller")
    }
    .menuBarExtraStyle(.window)
  }
}

// MARK: - Commands

private struct ControlCommands: Commands {
  let store: KeyboardStore
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandMenu("MK750") {
      Button("Open Control Window") {
        show(nil)
      }
      .keyboardShortcut("0", modifiers: .command)

      Divider()

      Button("Lighting") { show(.lighting) }
        .keyboardShortcut("1", modifiers: .command)
      Button("Keymap") { show(.keymap) }
        .keyboardShortcut("2", modifiers: .command)
      Button("Macros") { show(.macros) }
        .keyboardShortcut("3", modifiers: .command)
      Button("Device") { show(.device) }
        .keyboardShortcut("4", modifiers: .command)

      Divider()

      Button("Refresh") {
        Task {
          if store.connection == .disconnected {
            await store.connect()
          } else {
            await store.refresh()
          }
        }
      }
      .keyboardShortcut("r", modifiers: .command)
    }

    CommandGroup(replacing: .appTermination) {
      Button("Quit MK750") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q", modifiers: .command)
    }
  }

  private func show(_ section: AppSection?) {
    if let section {
      store.section = section
    }
    openWindow(id: "control")
    NSApp.activate()
  }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var isTerminating = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    _ = NSApp.setActivationPolicy(.accessory)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let store = KeyboardStore.shared
    // A deferred termination is already in progress. Every repeat Quit must
    // keep answering “later”: replying now would let AppKit terminate while
    // the in-flight lighting write or focus restore is still running. The
    // single outstanding reply comes from the same task once that work ends.
    guard !isTerminating else { return .terminateLater }
    guard store.focus != nil || store.isBusy else { return .terminateNow }
    isTerminating = true

    Task { @MainActor in
      await store.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

// MARK: - Control window

struct ControlWindowView: View {
  @ObservedObject var store: KeyboardStore

  private var sectionBinding: Binding<AppSection> {
    Binding(
      get: { store.section },
      set: { store.section = $0 }
    )
  }

  private var connectionSummary: String {
    switch store.connection {
    case .connected: "Connected · USB"
    case .connecting: "Connecting"
    case .disconnected: "Disconnected"
    }
  }

  private var connectionColor: Color {
    switch store.connection {
    case .connected: .green
    case .connecting: .orange
    case .disconnected: .secondary
    }
  }

  private var visibleNotice: Notice? {
    guard let notice = store.notice, notice.kind != .success else { return nil }
    if store.hasPendingFocusRestore, notice.action == .restoreFocus {
      return nil
    }
    return notice
  }

  private var refreshTitle: String {
    store.connection == .disconnected ? "Reconnect keyboard" : "Refresh keyboard state"
  }

  var body: some View {
    VStack(spacing: 0) {
      if store.hasPendingFocusRestore {
        pendingRestoreRow
      }

      if let notice = visibleNotice {
        NoticeBanner(store: store, notice: notice)
      }

      if let busy = store.busy {
        HStack(spacing: 8) {
          ProgressView()
            .progressViewStyle(.linear)
          Text(busy)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
      }

      sectionContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 760, minHeight: 520)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Section", selection: sectionBinding) {
          ForEach(AppSection.allCases) { section in
            Text(section.title)
              .tag(section)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Section")
      }

      ToolbarItem(placement: .primaryAction) {
        HStack(spacing: 5) {
          Image(systemName: store.connection.symbol)
            .foregroundStyle(connectionColor)
          Text(connectionSummary)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard \(connectionSummary)")
      }

      ToolbarItem(placement: .primaryAction) {
        if store.connection == .connecting {
          ProgressView()
        } else {
          Button {
            Task {
              if store.connection == .disconnected {
                await store.connect()
              } else {
                await store.refresh()
              }
            }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(store.isBusy)
          .help("\(refreshTitle) (⌘R)")
          .accessibilityLabel(refreshTitle)
        }
      }
    }
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch store.section {
    case .lighting:
      LightingView(store: store)
    case .keymap:
      KeymapView(store: store)
    case .macros:
      MacrosView(store: store)
    case .device:
      DeviceView(store: store)
    }
  }

  private var pendingRestoreRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text("Saved lighting restore pending")
          .font(.callout.weight(.medium))
        if let failure = store.focus?.lastFailure {
          Text(failure)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(failure)
        }
      }

      Spacer(minLength: 8)

      Button("Restore") {
        Task { await store.restoreFocus() }
      }
      .disabled(store.isBusy || store.snapshot == nil)
      .help(
        store.snapshot == nil
          ? "Reconnect the MK750 over wired USB to restore."
          : "Restore the lighting saved when focus started"
      )
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .background(Color.orange.opacity(0.10))
  }
}

struct NoticeBanner: View {
  @ObservedObject var store: KeyboardStore
  let notice: Notice

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: notice.symbol)
        .foregroundStyle(tint)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(notice.title)
          .font(.callout.weight(.medium))
        Text(notice.message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .help(notice.message)
      }

      Spacer(minLength: 8)

      if let action = notice.action {
        Button(action.title) {
          perform(action)
        }
        .disabled(store.isBusy)
      }

      Button {
        store.notice = nil
      } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Dismiss message")
      .help("Dismiss")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .background(background)
  }

  private var tint: Color {
    switch notice.kind {
    case .success: .green
    case .warning: .orange
    case .failure: .red
    }
  }

  private var background: Color {
    switch notice.kind {
    case .success: Color.green.opacity(0.08)
    case .warning: Color.orange.opacity(0.10)
    case .failure: Color.red.opacity(0.09)
    }
  }

  private func perform(_ action: Notice.Action) {
    switch action {
    case .reconnect:
      Task { await store.connect() }
    case .restoreFocus:
      Task { await store.restoreFocus() }
    case .openBackups:
      store.openBackupsFolder()
    }
  }
}

extension Notice.Action {
  fileprivate var title: String {
    switch self {
    case .reconnect: "Reconnect"
    case .restoreFocus: "Restore Lighting"
    case .openBackups: "Open Backups"
    }
  }
}

// MARK: - Menu bar panel

struct MenuBarPanel: View {
  @ObservedObject var store: KeyboardStore
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss

  @State private var brightness: Double = 0

  private var brightnessValue: UInt8 {
    UInt8(brightness.rounded())
  }

  private var brightnessChanged: Bool {
    guard let main = store.snapshot?.main else { return false }
    return brightnessValue != main.brightness
  }

  private var lightingLocked: Bool {
    store.snapshot == nil || store.isBusy || store.focus != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      sceneGrid
      Divider()
      brightnessControl
      focusControl
      failureRow
      if let busy = store.busy {
        HStack(spacing: 6) {
          ProgressView()
          Text(busy)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 0)
        }
      }
      Divider()
      footer
    }
    .padding(14)
    .frame(width: 320)
    .onAppear(perform: syncBrightness)
    .onChange(of: store.snapshotRevision) { _, _ in
      syncBrightness()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "keyboard")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("MK750")
          .font(.headline)
      }

      Spacer(minLength: 8)

      HStack(spacing: 5) {
        Image(systemName: store.connection.symbol)
          .foregroundStyle(connectionColor)
        Text(store.connection.title)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Keyboard \(store.connection.title)")
    }
  }

  private var connectionColor: Color {
    switch store.connection {
    case .connected: .green
    case .connecting: .orange
    case .disconnected: .secondary
    }
  }

  private var sceneGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: [
          GridItem(.flexible(), spacing: 8),
          GridItem(.flexible(), spacing: 8),
        ],
        spacing: 8
      ) {
        ForEach(store.quickScenes) { scene in
          sceneButton(scene)
        }
      }
      .padding(.vertical, 1)
    }
    .frame(height: 96)
  }

  private func sceneButton(_ scene: NamedScene) -> some View {
    Button {
      Task { await store.applyScene(scene) }
    } label: {
      HStack(spacing: 6) {
        HStack(spacing: 2) {
          Circle()
            .fill(RGB(red: scene.main.red, green: scene.main.green, blue: scene.main.blue).color)
            .frame(width: 7, height: 7)
          Circle()
            .fill(RGB(red: scene.side.red, green: scene.side.green, blue: scene.side.blue).color)
            .frame(width: 7, height: 7)
        }
        .accessibilityHidden(true)

        Text(scene.name)
          .font(.callout)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .disabled(lightingLocked)
    .accessibilityLabel("Apply scene \(scene.name)")
    .help(
      lightingLocked
        ? "Connect the keyboard and finish any focus session first."
        : "Apply \(scene.name)"
    )
  }

  private var brightnessControl: some View {
    HStack(spacing: 8) {
      Image(systemName: "sun.max")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Slider(value: $brightness, in: 0...4, step: 1) {
        Text("Backlight brightness")
      }
      .labelsHidden()
      .accessibilityLabel("Backlight brightness")
      .accessibilityValue("\(Int(brightness)) of 4")
      .disabled(lightingLocked)

      Text("\(Int(brightness))/4")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .trailing)

      if brightnessChanged {
        Button("Apply") {
          applyBrightness()
        }
        .disabled(lightingLocked)
        .help("Write backlight brightness")
        .accessibilityLabel("Apply backlight brightness")
      }
    }
  }

  @ViewBuilder
  private var focusControl: some View {
    if let focus = store.focus {
      HStack(spacing: 8) {
        Image(
          systemName: focus.status == .restorationPending ? "exclamationmark.triangle" : "timer"
        )
        .foregroundStyle(focus.status == .restorationPending ? Color.orange : Color.secondary)
        .accessibilityHidden(true)

        if focus.status == .active {
          Text(store.focusCountdownText)
            .font(.callout.monospacedDigit())
          Spacer(minLength: 8)
          Button("Finish") {
            Task { await store.restoreFocus() }
          }
          .disabled(store.isBusy)
          .help("Restore the lighting saved when focus started")
        } else {
          Text("Restore pending")
            .font(.callout)
          Spacer(minLength: 8)
          Button("Restore") {
            Task { await store.restoreFocus() }
          }
          .disabled(store.isBusy || store.snapshot == nil)
        }
      }
    } else {
      HStack(spacing: 8) {
        Image(systemName: "timer")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Button("Focus 25 min") {
          Task { await store.startFocus(minutes: 25) }
        }
        .disabled(lightingLocked)
        .help("Restores your lighting when finished")
        Spacer(minLength: 0)
      }
    }
  }

  @ViewBuilder
  private var failureRow: some View {
    if let notice = store.notice,
      notice.kind == .failure,
      !(store.hasPendingFocusRestore && notice.action == .restoreFocus)
    {
      HStack(alignment: .top, spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .accessibilityHidden(true)
        Text(notice.title)
          .font(.caption)
          .lineLimit(2)
          .help(notice.message)
        Spacer(minLength: 0)
        if let action = notice.action {
          Button(action.title) {
            perform(action)
          }
          .disabled(store.isBusy)
        }
        Button {
          store.notice = nil
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Dismiss error")
      }
      .padding(8)
      .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button {
        dismiss()
        openWindow(id: "control")
        NSApp.activate()
      } label: {
        Label("Open Controls", systemImage: "macwindow")
      }
      .keyboardShortcut("0", modifiers: .command)

      Spacer(minLength: 8)

      Button {
        NSApp.terminate(nil)
      } label: {
        Label("Quit", systemImage: "power")
      }
      .keyboardShortcut("q", modifiers: .command)
    }
  }

  private func syncBrightness() {
    guard let main = store.snapshot?.main else { return }
    brightness = Double(main.brightness)
  }

  private func applyBrightness() {
    guard var state = store.snapshot?.main else { return }
    state.brightness = brightnessValue
    Task { await store.applyLight(state, channel: .main) }
  }

  private func perform(_ action: Notice.Action) {
    switch action {
    case .reconnect:
      Task { await store.connect() }
    case .restoreFocus:
      Task { await store.restoreFocus() }
    case .openBackups:
      store.openBackupsFolder()
    }
  }
}
