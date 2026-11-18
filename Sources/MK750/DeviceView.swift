import Foundation
import MK750Kit
import SwiftUI

struct DeviceView: View {
  @ObservedObject var store: KeyboardStore

  @State private var backupProfile: UInt8 = 0
  @State private var showLockConfirmation = false
  @State private var showSleep = false
  @State private var showOptions = true
  @State private var showAdvanced = false
  @State private var showDiagnostics = false

  private var settingsDisabled: Bool {
    !store.acceptsLiveEdits
  }

  private var unknownOptionBits: UInt8 {
    (store.liveSettings?.options ?? 0) & ~OptionBits.knownMask
  }

  private var enabledOptionCount: Int {
    let options = store.liveSettings?.options ?? 0
    return OptionBits.all.filter { $0.mask != 128 && options & $0.mask != 0 }.count
  }

  private var sleepSummary: String {
    guard let sleep = store.liveSettings?.sleep else { return "—" }
    return "\(sleep.bluetooth)/\(sleep.wireless) · \(sleep.deepBluetooth)/\(sleep.deepWireless) s"
  }

  /// Explains the lock request without claiming a state the keyboard has not
  /// verified yet. `liveSettings` is the latest request; `snapshot` is the last
  /// read-back.
  private var lockStatus: (text: String, symbol: String)? {
    guard let live = store.liveSettings, let snapshot = store.snapshot else { return nil }
    let requested = live.options & 128 != 0
    let verified = snapshot.options & 128 != 0

    switch (requested, verified) {
    case (true, false):
      return ("Lock requested. Keys stop responding once the write is verified.", "lock.open")
    case (true, true):
      return ("Keyboard keys are locked.", "lock")
    case (false, true):
      return ("Unlock requested. Keys stay locked until the write is verified.", "lock")
    case (false, false):
      return nil
    }
  }

  var body: some View {
    Form {
      if store.snapshot == nil {
        KeyboardConnectionCard(store: store)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      } else {
        statusSection
      }

      if store.liveSettings != nil {
        everydaySection
        sleepSection
        optionsSection
        advancedSection
      }

      backupsSection

      if store.snapshot != nil {
        diagnosticsSection
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await store.refreshBackupListing() }
    .alert("Lock the keyboard's keys?", isPresented: $showLockConfirmation) {
      Button("Lock Keyboard", role: .destructive) {
        confirmKeyboardLock()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Keyboard lock disables the MK750's own keys until you clear it here or reconnect power. USB commands from this app keep working."
      )
    }
  }

  // MARK: Sections

  private var statusSection: some View {
    Section {
      if let snapshot = store.snapshot {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "keyboard")
            .font(.title3)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text("MK750")
                .font(.headline)
              Text("Connected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Text("Firmware \(snapshot.firmware) · Board \(snapshot.boardID)")
              .font(.callout)
              .foregroundStyle(.secondary)
              .monospacedDigit()
            Text("Wired USB · every write is read back")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "MK750 connected, firmware \(snapshot.firmware), board \(snapshot.boardID)"
        )
      }
    } header: {
      Text("Keyboard")
    }
  }

  private var everydaySection: some View {
    Section {
      Picker("Active profile", selection: profileBinding) {
        Text("Profile 0").tag(UInt8(0))
        Text("Profile 1").tag(UInt8(1))
        if let snapshot = store.snapshot, snapshot.profile > 1 {
          Text("Profile \(snapshot.profile) (read-only)").tag(snapshot.profile)
        }
      }
      .disabled(store.focus != nil)
      .help(
        store.focus != nil
          ? "Finish or restore the focus session before switching profiles; the profile may replace the lighting saved for focus."
          : "Choose the keyboard's active profile"
      )

      if store.focus != nil {
        Text(
          "Profile switching is unavailable during a focus session; finish or restore focus first. Other settings remain available."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      LabeledContent("Debounce") {
        HStack(spacing: 6) {
          Text("\(store.liveSettings?.debounce ?? 1) ms")
            .monospacedDigit()
          Stepper("Debounce", value: debounceValue, in: 1...10)
            .labelsHidden()
            .accessibilityLabel("Debounce in milliseconds")
        }
      }

      Toggle("Auto OS detection", isOn: autoOSBinding)
        .help("Detect the host operating system automatically")
        .accessibilityHint("Uses the host operating system to choose the modifier layout")
    } header: {
      Text("Everyday")
    } footer: {
      Text(
        "Changes are written as you make them and read back. The active profile selects the keyboard's keymap and lighting slot."
      )
    }
    .disabled(settingsDisabled)
  }

  private var sleepSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showSleep) {
        SleepTimerField(
          title: "Bluetooth sleep",
          value: store.liveSettings?.sleep.bluetooth ?? 0,
          onCommit: { commitSleep($0, keyPath: \.bluetooth) }
        )
        SleepTimerField(
          title: "2.4 GHz sleep",
          value: store.liveSettings?.sleep.wireless ?? 0,
          onCommit: { commitSleep($0, keyPath: \.wireless) }
        )
        SleepTimerField(
          title: "Bluetooth deep sleep",
          value: store.liveSettings?.sleep.deepBluetooth ?? 0,
          onCommit: { commitSleep($0, keyPath: \.deepBluetooth) }
        )
        SleepTimerField(
          title: "2.4 GHz deep sleep",
          value: store.liveSettings?.sleep.deepWireless ?? 0,
          onCommit: { commitSleep($0, keyPath: \.deepWireless) }
        )
      } label: {
        HStack(spacing: 12) {
          Label("Sleep Timers", systemImage: "moon.zzz")
          Spacer(minLength: 8)
          Text(sleepSummary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .help("Bluetooth / 2.4 GHz sleep, then deep sleep, in seconds")
        }
      }
    }
    .disabled(settingsDisabled)
  }

  private var optionsSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showOptions) {
        ForEach(OptionBits.all.filter { $0.mask != 128 }) { bit in
          Toggle(bit.title, isOn: optionBinding(bit.mask))
            .help(bit.detail)
            .accessibilityHint(bit.detail)
        }

        if unknownOptionBits != 0 {
          Label(
            "Unmodelled bits 0x\(String(format: "%02X", unknownOptionBits)) are preserved.",
            systemImage: "info.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Text("Writes are read back; every other option bit is preserved.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } label: {
        HStack(spacing: 12) {
          Label("Options", systemImage: "slider.horizontal.3")
          Spacer(minLength: 8)
          Text("\(enabledOptionCount) on")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
    .disabled(settingsDisabled)
  }

  private var advancedSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showAdvanced) {
        Toggle("Keyboard lock", isOn: optionBinding(128))
          .help(
            "Locks the keyboard's own keys until cleared. Enabling the lock asks for confirmation before anything is written."
          )
          .accessibilityHint(
            "The keys stop responding until you unlock them here or reconnect power.")

        if let lockStatus {
          Label(lockStatus.text, systemImage: lockStatus.symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } label: {
        Label("Advanced", systemImage: "gearshape.2")
      }
    }
    .disabled(settingsDisabled)
  }

  private var diagnosticsSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showDiagnostics) {
        if let snapshot = store.snapshot {
          LabeledContent("Fn matrix flag") {
            Text(String(format: "0x%02X", snapshot.fnMatrix))
              .font(.body.monospaced())
          }
          LabeledContent("Power save") {
            Text("\(snapshot.powerSave)")
              .monospacedDigit()
          }
          LabeledContent("Options byte") {
            Text(String(format: "0x%02X", snapshot.options))
              .font(.body.monospaced())
          }
          if snapshot.options & ~OptionBits.knownMask != 0 {
            LabeledContent("Unmodelled bits") {
              Text(String(format: "0x%02X", snapshot.options & ~OptionBits.knownMask))
                .font(.body.monospaced())
            }
          }
          LabeledContent("Debounce read-back") {
            Text("\(snapshot.debounce) ms")
              .monospacedDigit()
          }
        } else {
          Text("Connect to read diagnostics.")
            .foregroundStyle(.secondary)
        }
      } label: {
        HStack(spacing: 12) {
          Label("Diagnostics", systemImage: "stethoscope")
          Spacer(minLength: 8)
          Text("Read-only")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var backupsSection: some View {
    Section {
      Picker("Profile", selection: $backupProfile) {
        Text("Profile 0").tag(UInt8(0))
        Text("Profile 1").tag(UInt8(1))
      }

      HStack(spacing: 10) {
        Button {
          Task { await store.backupKeymap(profile: backupProfile) }
        } label: {
          Label("Back Up Keymap", systemImage: "square.and.arrow.down")
        }
        .disabled(store.snapshot == nil || store.isBusy)
        .help(
          store.snapshot == nil
            ? "Connect the MK750 over wired USB to back up a profile."
            : "Read profile \(backupProfile) and save a copy in the backups folder"
        )

        Spacer(minLength: 8)
      }

      HStack(spacing: 10) {
        Button("Open Folder") {
          store.openBackupsFolder()
        }
        .help("Show the backups folder in Finder")

        Button("Reveal Latest") {
          Task { await store.revealLatestBackup() }
        }
        .disabled(store.lastBackupURL == nil)
        .help("Select the newest backup in Finder")
      }

      if let latest = store.lastBackupURL {
        LabeledContent("Latest backup") {
          Text(latest.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(latest.path)
        }
      } else {
        LabeledContent("Latest backup") {
          Text("None yet")
            .foregroundStyle(.secondary)
        }
      }

      LabeledContent("Folder") {
        Text(store.backupsURL.path)
          .font(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help(store.backupsURL.path)
      }
    } header: {
      Text("Backups")
    } footer: {
      Text("Backups are stored on this Mac and remain available without the keyboard.")
    }
  }

  // MARK: Bindings

  private var profileBinding: Binding<UInt8> {
    Binding(
      get: { store.liveSettings?.profile ?? 0 },
      set: { value in
        guard store.focus == nil else { return }
        guard var settings = store.liveSettings, settings.profile != value else { return }
        settings.profile = value
        store.updateSettings(settings)
      }
    )
  }

  private var debounceValue: Binding<Int> {
    Binding(
      get: { Int(store.liveSettings?.debounce ?? 1) },
      set: { value in
        let debounce = UInt8(min(10, max(1, value)))
        guard var settings = store.liveSettings, settings.debounce != debounce else { return }
        settings.debounce = debounce
        store.updateSettings(settings)
      }
    )
  }

  private var autoOSBinding: Binding<Bool> {
    Binding(
      get: { store.liveSettings?.autoOS ?? false },
      set: { value in
        guard var settings = store.liveSettings, settings.autoOS != value else { return }
        settings.autoOS = value
        store.updateSettings(settings)
      }
    )
  }

  private func optionBinding(_ mask: UInt8) -> Binding<Bool> {
    Binding(
      get: { (store.liveSettings?.options ?? 0) & mask != 0 },
      set: { enabled in
        setOption(mask, enabled: enabled)
      }
    )
  }

  // MARK: Actions

  private func setOption(_ mask: UInt8, enabled: Bool) {
    guard var settings = store.liveSettings else { return }
    let current = settings.options & mask != 0
    guard current != enabled else { return }

    if mask == 128 {
      if enabled {
        // Do not mutate the live settings here: the toggle must stay off until
        // the explicit confirmation succeeds. Cancel leaves everything as is.
        showLockConfirmation = true
      } else {
        settings.options &= ~mask
        store.updateSettings(settings)
      }
      return
    }

    if enabled {
      settings.options |= mask
    } else {
      settings.options &= ~mask
    }
    store.updateSettings(settings)
  }

  private func confirmKeyboardLock() {
    guard var settings = store.liveSettings, settings.options & 128 == 0 else { return }
    settings.options |= 128
    store.updateSettings(settings, allowKeyboardLock: true)
  }

  private func commitSleep(_ seconds: UInt16, keyPath: WritableKeyPath<SleepTimers, UInt16>) {
    guard var settings = store.liveSettings, settings.sleep[keyPath: keyPath] != seconds else {
      return
    }
    settings.sleep[keyPath: keyPath] = seconds
    store.updateSettings(settings)
  }
}

// MARK: - Sleep timer text entry

/// Keeps the in-progress text local so a partial or invalid number is never
/// written. A valid value is committed on Return or when focus leaves; an
/// invalid value is replaced by the last live value instead.
private struct SleepTimerField: View {
  let title: String
  let value: UInt16
  let onCommit: (UInt16) -> Void

  @State private var entry: String?
  @FocusState private var isFocused: Bool

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 6) {
        TextField("Seconds", text: Binding(get: { entry ?? String(value) }, set: { entry = $0 }))
          .frame(width: 84)
          .multilineTextAlignment(.trailing)
          .focused($isFocused)
          .onSubmit(commitOrRestore)
          .accessibilityLabel("\(title) in seconds")

        Text("s")
          .foregroundStyle(.secondary)
      }
    }
    .onChange(of: isFocused) { _, focused in
      if !focused {
        commitOrRestore()
      }
    }
  }

  private func commitOrRestore() {
    guard let entry else { return }
    self.entry = nil
    if let seconds = UInt16(entry.trimmingCharacters(in: .whitespacesAndNewlines)), seconds != value {
      onCommit(seconds)
    }
  }
}
