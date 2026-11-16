import MK750Kit
import SwiftUI

struct DeviceView: View {
  @ObservedObject var store: KeyboardStore

  @State private var draft = DeviceSettings(
    profile: 0,
    debounce: 1,
    sleep: SleepTimers(bluetooth: 120, wireless: 120, deepBluetooth: 600, deepWireless: 600),
    autoOS: true,
    options: 0
  )
  @State private var dirty = false
  @State private var backupProfile: UInt8 = 0
  @State private var showLockConfirmation = false
  @State private var showSleep = false
  @State private var showOptions = false
  @State private var showAdvanced = false
  @State private var showDiagnostics = false
  @State private var showBackupPath = false

  private var controlsDisabled: Bool {
    store.snapshot == nil || store.isBusy
  }

  private var unknownOptionBits: UInt8 {
    draft.options & ~OptionBits.knownMask
  }

  private var enabledOptionCount: Int {
    OptionBits.all.filter { $0.mask != 128 && draft.options & $0.mask != 0 }.count
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        identitySection
        generalSection
        sleepSection
        optionsSection
        advancedSection
        diagnosticsSection
        backupsSection
      }
      .formStyle(.grouped)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      actionBar
    }
    .onAppear {
      syncFromSnapshot(force: true)
    }
    .onChange(of: store.snapshotRevision) { _, _ in
      if !dirty {
        syncFromSnapshot(force: false)
      }
    }
    .alert("Lock the keyboard's keys?", isPresented: $showLockConfirmation) {
      Button("Lock and Apply", role: .destructive) {
        apply(allowKeyboardLock: true)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Keyboard lock disables the MK750's own keys until you clear it here or reconnect power. USB commands from this app keep working."
      )
    }
  }

  // MARK: Sections

  private var identitySection: some View {
    Section {
      if let snapshot = store.snapshot {
        HStack(spacing: 12) {
          Image(systemName: "keyboard")
            .font(.title3)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 2) {
            Text("MK750")
              .font(.headline)
            Text("Firmware \(snapshot.firmware) · USB · Board \(snapshot.boardID)")
              .font(.callout)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }

          Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "MK750, firmware \(snapshot.firmware), wired USB, board \(snapshot.boardID)"
        )
      } else {
        Label("No keyboard connected", systemImage: "bolt.slash")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var generalSection: some View {
    Section("General") {
      Picker("Active profile", selection: profileBinding) {
        Text("Profile 0").tag(UInt8(0))
        Text("Profile 1").tag(UInt8(1))
        if let snapshot = store.snapshot, snapshot.profile > 1 {
          Text("Profile \(snapshot.profile) (read-only)").tag(snapshot.profile)
        }
      }

      LabeledContent("Debounce") {
        HStack(spacing: 6) {
          Text("\(draft.debounce) ms")
            .monospacedDigit()
          Stepper("Debounce", value: debounceValue, in: 1...10)
            .labelsHidden()
            .accessibilityLabel("Debounce in milliseconds")
        }
      }

      Toggle("Auto OS detection", isOn: autoOSBinding)
        .help("Detect the host operating system automatically")
    }
    .disabled(controlsDisabled)
  }

  private var sleepSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showSleep) {
        sleepRow("Bluetooth sleep", keyPath: \.bluetooth)
        sleepRow("2.4 GHz sleep", keyPath: \.wireless)
        sleepRow("Bluetooth deep sleep", keyPath: \.deepBluetooth)
        sleepRow("2.4 GHz deep sleep", keyPath: \.deepWireless)
      } label: {
        HStack(spacing: 12) {
          Label("Sleep Timers", systemImage: "moon.zzz")
          Spacer()
          Text(
            "\(draft.sleep.bluetooth) / \(draft.sleep.wireless) / \(draft.sleep.deepBluetooth) / \(draft.sleep.deepWireless) s"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        }
      }
    }
    .disabled(controlsDisabled)
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
          Spacer()
          Text("\(enabledOptionCount) on")
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
    .disabled(controlsDisabled)
  }

  private var advancedSection: some View {
    Section {
      DisclosureGroup(isExpanded: $showAdvanced) {
        Toggle("Keyboard lock", isOn: optionBinding(128))
          .help(
            "Locks the keyboard's own keys until cleared. Applying a newly enabled lock asks for confirmation."
          )
          .accessibilityHint(
            "The keys stop responding until you unlock them here or reconnect power.")

        if draft.options & 128 != 0 {
          Label(
            "Keyboard keys are locked.",
            systemImage: "lock"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      } label: {
        Label("Advanced", systemImage: "gearshape.2")
      }
    }
    .disabled(controlsDisabled)
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
          LabeledContent("Debounce read-back") {
            Text("\(snapshot.debounce) ms")
              .monospacedDigit()
          }
        } else {
          Text("Connect to read diagnostics.")
            .foregroundStyle(.secondary)
        }
      } label: {
        Label("Diagnostics", systemImage: "stethoscope")
      }
    }
  }

  private var backupsSection: some View {
    Section("Backups") {
      HStack(spacing: 8) {
        Picker("Backup profile", selection: $backupProfile) {
          Text("Profile 0").tag(UInt8(0))
          Text("Profile 1").tag(UInt8(1))
        }
        .labelsHidden()
        .accessibilityLabel("Profile to back up")

        Button("Back Up Keymap") {
          Task { await store.backupKeymap(profile: backupProfile) }
        }
        .disabled(controlsDisabled)

        Spacer(minLength: 12)

        Button("Open Folder") {
          store.openBackupsFolder()
        }

        Button("Reveal Latest") {
          Task { await store.revealLatestBackup() }
        }
        .disabled(store.isBusy)
      }

      DisclosureGroup(isExpanded: $showBackupPath) {
        Text(store.backupsURL.path)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .accessibilityLabel("Backup folder path")

        if let latest = store.lastBackupURL {
          Text("Latest: \(latest.lastPathComponent)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(latest.path)
        } else {
          Text("No backup recorded yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } label: {
        Label("Backup Folder", systemImage: "folder")
      }
    }
  }

  private var actionBar: some View {
    HStack(spacing: 10) {
      if dirty {
        Text("Unsaved changes")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Button("Revert") {
        revert()
      }
      .disabled(!dirty || controlsDisabled)
      .help("Discard staged changes and reload the current settings from the keyboard")

      Button("Apply Changes") {
        requestApply()
      }
      .disabled(controlsDisabled || !dirty)
      .help("Write the staged settings and verify the read-back")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
  }

  // MARK: Bindings

  private var profileBinding: Binding<UInt8> {
    Binding(
      get: { draft.profile },
      set: { value in
        draft.profile = value
        dirty = true
      }
    )
  }

  private var debounceValue: Binding<Int> {
    Binding(
      get: { Int(draft.debounce) },
      set: { value in
        draft.debounce = UInt8(min(10, max(1, value)))
        dirty = true
      }
    )
  }

  private var autoOSBinding: Binding<Bool> {
    Binding(
      get: { draft.autoOS },
      set: { value in
        draft.autoOS = value
        dirty = true
      }
    )
  }

  private func sleepRow(_ title: String, keyPath: WritableKeyPath<SleepTimers, UInt16>) -> some View
  {
    LabeledContent(title) {
      HStack(spacing: 6) {
        TextField(
          "Seconds",
          value: Binding(
            get: { Int(draft.sleep[keyPath: keyPath]) },
            set: { value in
              draft.sleep[keyPath: keyPath] = UInt16(clamping: max(0, min(65535, value)))
              dirty = true
            }
          ), format: .number
        )
        .accessibilityLabel("\(title) in seconds")

        Text("s")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func optionBinding(_ mask: UInt8) -> Binding<Bool> {
    Binding(
      get: { draft.options & mask != 0 },
      set: { enabled in
        if enabled {
          draft.options |= mask
        } else {
          draft.options &= ~mask
        }
        dirty = true
      }
    )
  }

  // MARK: Actions

  private func syncFromSnapshot(force: Bool) {
    guard let snapshot = store.snapshot else { return }
    guard force || !dirty else { return }
    draft = DeviceSettings(snapshot: snapshot)
    dirty = false
  }

  private func requestApply() {
    guard let snapshot = store.snapshot else { return }
    let isEnablingLock = draft.options & 128 != 0 && snapshot.options & 128 == 0
    if isEnablingLock {
      showLockConfirmation = true
    } else {
      apply(allowKeyboardLock: false)
    }
  }

  private func apply(allowKeyboardLock: Bool) {
    let pendingDraft = draft
    Task {
      if await store.applyDeviceSettings(pendingDraft, allowKeyboardLock: allowKeyboardLock) {
        dirty = false
        syncFromSnapshot(force: true)
      }
    }
  }

  private func revert() {
    Task {
      await store.refresh()
      dirty = false
      syncFromSnapshot(force: true)
    }
  }
}
