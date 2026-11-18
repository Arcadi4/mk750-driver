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
    .defaultSize(width: 1020, height: 720)
    .windowResizability(.contentMinSize)
    .defaultLaunchBehavior(.presented)
    .restorationBehavior(.disabled)
    .commands {
      SidebarCommands()
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
  @ObservedObject var store: KeyboardStore
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

      KeyboardConnectionButton(store: store)
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
  @StateObject private var macroDraft = MacroDraftModel()

  @State private var showConnectionDetails = false

  private var sectionBinding: Binding<AppSection?> {
    Binding(get: { store.section }, set: { if let section = $0 { store.section = section } })
  }

  private var visibleNotice: Notice? {
    guard let notice = store.notice, notice.kind != .success else { return nil }
    if store.hasPendingFocusRestore, notice.action == .restoreFocus {
      return nil
    }
    return notice
  }

  private var sidebar: some View {
    List(selection: sectionBinding) {
      Section("Workspace") {
        ForEach(AppSection.allCases) { section in
          Label(section.title, systemImage: section.systemImage).tag(section)
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, alignment: .leading) {
      VStack(alignment: .leading, spacing: 5) {
        Label("FL ESPORTS MK750", systemImage: "keyboard")
          .font(.subheadline.weight(.semibold))
        HStack(spacing: 5) {
          Image(systemName: store.connection.symbol)
          Text(store.isUpdatingKeyboard ? "Updating keyboard…" :
            store.connection == .connected ? "Connected · USB" : store.connection.title)
          if store.connectionError != nil {
            Button { showConnectionDetails.toggle() } label: {
              Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connection details")
            .popover(isPresented: $showConnectionDetails) {
              if let error = store.connectionError {
                Text(error).textSelection(.enabled).padding().frame(width: 280)
              }
            }
          }
        }
        .foregroundStyle(.secondary)
        .font(.caption)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
    }
    .navigationTitle("MK750")
    .navigationSplitViewColumnWidth(min: 168, ideal: 188, max: 248)
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      VStack(spacing: 0) {
        if store.hasPendingFocusRestore { pendingRestoreRow }
        if let notice = visibleNotice { NoticeBanner(store: store, notice: notice) }
        if let busy = store.busy {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(busy).foregroundStyle(.secondary)
            Spacer()
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 6)
        }
        sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(minWidth: 620, minHeight: 500)
      .navigationTitle(store.section.title)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          if store.connection == .connected || store.section != .lighting {
            KeyboardConnectionButton(store: store)
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    // Use normal Mac menus and Dock switching while the workspace is open.
    // Closing it leaves quick controls in the menu bar.
    .onAppear { NSApp.setActivationPolicy(.regular) }
    .onDisappear { NSApp.setActivationPolicy(.accessory) }
  }

  @ViewBuilder
  private var sectionContent: some View {
    switch store.section {
    case .lighting:
      LightingView(store: store)
    case .keymap:
      KeymapView(store: store)
    case .macros:
      MacrosView(store: store, draft: macroDraft)
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

  private var brightness: Binding<Double> {
    Binding {
      Double(store.liveLight(for: .main)?.brightness ?? 0)
    } set: { value in
      guard var main = store.liveLight(for: .main) else { return }
      main.brightness = UInt8(value.rounded())
      store.updateLight(main, channel: .main)
    }
  }

  private var lightingLocked: Bool {
    store.snapshot == nil || store.isBusy || store.focus != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if store.snapshot != nil {
        brightnessControl
        Divider()
        Text("Scenes").font(.headline)
        sceneGrid
        focusControl
      } else {
        Text("Connect the MK750 in wired USB mode to use quick controls.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        KeyboardConnectionButton(store: store)
        if let error = store.connectionError {
          DisclosureGroup("Connection details") {
            Text(error).font(.caption).textSelection(.enabled)
          }
        }
        if store.focus != nil { focusControl }
      }
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

  @ViewBuilder private var sceneGrid: some View {
    let scenes = store.quickScenes
    let grid = LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
      ForEach(scenes) { scene in sceneButton(scene) }
    }
    if scenes.count <= 4 {
      grid
    } else {
      ScrollView { grid.padding(.vertical, 2) }.frame(height: 108)
    }
  }

  private func sceneButton(_ scene: NamedScene) -> some View {
    let current = store.snapshot?.main == scene.main && store.snapshot?.side == scene.side
    return Button {
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
        if current {
          Image(systemName: "checkmark").font(.caption.bold()).accessibilityHidden(true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .disabled(lightingLocked)
    .accessibilityLabel("Use \(scene.name)")
    .accessibilityValue(current ? "Current scene" : "")
    .help(store.focus != nil ? "Finish focus to change scenes." : "Use \(scene.name)")
  }

  private var brightnessControl: some View {
    HStack(spacing: 8) {
      Image(systemName: "sun.max")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Slider(value: brightness, in: 0...4, step: 1) {
        Text("Backlight brightness")
      }
      .labelsHidden()
      .accessibilityLabel("Backlight brightness")
      .accessibilityValue("\(Int(brightness.wrappedValue)) of 4")
      .disabled(!store.acceptsLiveEdits || store.focus != nil)

      Text("\(Int(brightness.wrappedValue))/4")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 28, alignment: .trailing)
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
