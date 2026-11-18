import AppKit
import MK750Kit
import SwiftUI

// MARK: - Keymap

private enum KeymapKindFilter: String, CaseIterable, Identifiable, Hashable {
  case all
  case keyboard
  case consumer
  case macro
  case special
  case blank
  case other

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All bindings"
    case .keyboard: "Keyboard"
    case .consumer: "Consumer"
    case .macro: "Macro"
    case .special: "Special"
    case .blank: "Unassigned"
    case .other: "Other"
    }
  }

  func matches(_ value: KeySlotValue) -> Bool {
    switch self {
    case .all: true
    case .keyboard: value.kind == .keyboard
    case .consumer: value.kind == .consumer
    case .macro: value.kind == .macro
    case .special: value.kind == .special
    case .blank: value.kind == .transparent
    case .other: value.kind == .raw
    }
  }
}

struct KeymapView: View {
  @ObservedObject var store: KeyboardStore

  @State private var readProfile: UInt8 = 0
  @State private var search = ""
  @State private var filter: KeymapKindFilter = .all
  @State private var showRaw = false
  @State private var selectedSlot: Int?
  @State private var editorTarget: SlotEditorTarget?
  @State private var importArchive: KeymapArchive?
  @State private var showImportConfirmation = false

  private var keymap: Keymap? { store.loadedKeymap }

  private var rows: [KeymapSlotRow] {
    guard let keymap else { return [] }
    return (0..<128).map { slot in
      KeymapSlotRow(
        slot: slot,
        baseBytes: slice(keymap.base, slot: slot),
        fnBytes: slice(keymap.fn, slot: slot)
      )
    }
  }

  private var filteredRows: [KeymapSlotRow] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return rows.filter { row in
      guard filter.matches(row.baseValue) || filter.matches(row.fnValue) else { return false }
      guard !query.isEmpty else { return true }
      let haystack = [
        "\(row.slot)",
        row.matrix,
        row.baseValue.summary,
        row.fnValue.summary,
        row.baseHex,
        row.fnHex,
      ].joined(separator: " ").lowercased()
      return haystack.contains(query)
    }
  }

  private var selectedRow: KeymapSlotRow? {
    guard let selectedSlot else { return nil }
    return rows.first { $0.slot == selectedSlot }
  }

  private var writable: Bool {
    guard let keymap else { return false }
    return keymap.profile <= 1
  }

  private var canRead: Bool { store.snapshot != nil && !store.isBusy }

  private var canEdit: Bool { writable && store.snapshot != nil && !store.isBusy }

  private var isOffline: Bool { store.snapshot == nil }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      if keymap == nil {
        emptyState
      } else {
        loadedContent
      }
    }
    .onAppear {
      if let profile = keymap?.profile {
        readProfile = profile
      }
    }
    .onChange(of: store.loadedKeymap?.profile) { _, profile in
      guard let profile else { return }
      readProfile = profile
      selectedSlot = nil
    }
    .onChange(of: filteredRows.map(\.slot)) { _, slots in
      if let current = selectedSlot, !slots.contains(current) {
        selectedSlot = nil
      }
    }
    .sheet(item: $editorTarget) { target in
      SlotEditorView(
        store: store,
        profile: target.profile,
        slot: target.slot,
        layer: target.layer,
        initialBytes: target.bytes
      )
    }
    .alert("Restore this keymap?", isPresented: $showImportConfirmation) {
      Button("Restore and Verify", role: .destructive) {
        let archive = importArchive
        importArchive = nil
        Task {
          if let archive {
            _ = await store.applyImportedKeymap(archive)
          }
        }
      }
      Button("Cancel", role: .cancel) {
        importArchive = nil
      }
    } message: {
      if let archive = importArchive {
        Text(importConfirmationMessage(archive))
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Picker("Profile to read", selection: $readProfile) {
          Text("Profile 0").tag(UInt8(0))
          Text("Profile 1").tag(UInt8(1))
          Text("Profile 2 (read-only)").tag(UInt8(2))
          Text("Profile 3 (read-only)").tag(UInt8(3))
        }
        .labelsHidden()
        .frame(maxWidth: 200)
        .accessibilityLabel("Profile to read")

        Button {
          let profile = readProfile
          Task { await store.loadKeymap(profile: profile) }
        } label: {
          Label("Read", systemImage: "arrow.down.circle")
        }
        .disabled(!canRead)
        .help("Read profile \(readProfile) keymap. Reading never writes.")
        .accessibilityLabel("Read keymap for profile \(readProfile)")

        status

        Spacer(minLength: 8)

        importExportMenu
      }

      if keymap != nil {
        HStack(spacing: 8) {
          searchField

          Picker("Show \(filter.title)", selection: $filter) {
            ForEach(KeymapKindFilter.allCases) { kind in
              Text(kind.title).tag(kind)
            }
          }
          .pickerStyle(.menu)
          .fixedSize()
          .help("Show only slots with the selected binding type")
          .accessibilityLabel("Filter slots by binding type")

          Toggle("Bytes", isOn: $showRaw)
            .toggleStyle(.checkbox)
            .help("Show matrix position and four-byte hexadecimal values")

          Spacer(minLength: 0)

          Text("\(filteredRows.count) of 128")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(filteredRows.count) of 128 slots shown")
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var status: some View {
    if let keymap {
      HStack(spacing: 5) {
        Text("Profile \(keymap.profile)")
          .font(.callout)
          .foregroundStyle(.secondary)
        if keymap.profile <= 1 {
          Text("writable")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Label("read-only", systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Read-only profile")
        }
      }
      .lineLimit(1)
      .help(loadedDescription(keymap))
    }
  }

  private var importExportMenu: some View {
    Menu {
      Button("Export Keymap…") {
        store.exportKeymap()
      }
      .disabled(keymap == nil)

      Divider()

      Button("Import and Restore…") {
        beginImport()
      }
      .disabled(!canRead)
    } label: {
      Label("Import / Export", systemImage: "arrow.up.arrow.down")
        .labelStyle(.iconOnly)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Export this keymap or restore it from a JSON archive")
    .accessibilityLabel("Keymap import and export")
  }

  private var searchField: some View {
    HStack(spacing: 5) {
      Image(systemName: "magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("Search slots or keys", text: $search)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search keymap")

      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
        .accessibilityLabel("Clear keymap search")
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    .frame(minWidth: 150, maxWidth: 280)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(
        isOffline
          ? (store.connection == .connecting ? "Connecting…" : "Keyboard Not Connected")
          : "No Keymap Loaded",
        systemImage: isOffline ? "bolt.slash" : "keyboard"
      )
    } description: {
      if isOffline {
        Text(
          store.connection == .connecting
            ? "Looking for the MK750 over wired USB."
            : KeyboardStore.connectionGuidance
        )
      } else {
        Text(
          "Read profile \(readProfile) to browse its 128 slots. Reading never writes to the keyboard."
        )
      }
    } actions: {
      if isOffline {
        if store.connection == .connecting {
          ProgressView()
            .controlSize(.small)
        } else {
          Button("Reconnect") {
            Task { await store.connect() }
          }
          .disabled(store.isBusy)
          .help("Connect the MK750 over wired USB")
        }
      } else {
        Button("Read Profile \(readProfile)") {
          let profile = readProfile
          Task { await store.loadKeymap(profile: profile) }
        }
        .disabled(!canRead)
      }

      Button("Import Keymap…") {
        beginImport()
      }
      .disabled(!canRead)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var loadedContent: some View {
    VStack(spacing: 0) {
      if filteredRows.isEmpty {
        noMatchesState
      } else {
        keymapTable
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        Divider()
        inspector
      }
    }
  }

  private var noMatchesState: some View {
    ContentUnavailableView {
      Label("No Matching Slots", systemImage: "magnifyingglass")
    } description: {
      if search.isEmpty {
        Text("No slots use the selected binding type.")
      } else {
        Text("No slots match “\(search)”.")
      }
    } actions: {
      Button("Clear Search and Filter") {
        search = ""
        filter = .all
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var keymapTable: some View {
    Table(filteredRows, selection: $selectedSlot) {
      TableColumn("Slot") { row in
        Text("\(row.slot)")
          .monospacedDigit()
      }
      .width(min: 44, ideal: 52, max: 64)

      if showRaw {
        TableColumn("Matrix") { row in
          Text(row.matrix)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .width(min: 64, ideal: 76, max: 92)
      }

      TableColumn("Base") { row in
        Text(row.baseValue.summary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(row.baseValue.summary)
      }

      TableColumn("Fn") { row in
        Text(row.fnValue.summary)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(row.fnValue.summary)
      }

      if showRaw {
        TableColumn("Base bytes") { row in
          Text(row.baseHex)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .width(min: 92, ideal: 108, max: 124)

        TableColumn("Fn bytes") { row in
          Text(row.fnHex)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .width(min: 92, ideal: 108, max: 124)
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .contextMenu(forSelectionType: Int.self) { slots in
      if let slot = slots.first {
        Button("Edit Base…") {
          openEditor(slot: slot, layer: .base)
        }
        .disabled(!canEdit)

        Button("Edit Fn…") {
          openEditor(slot: slot, layer: .fn)
        }
        .disabled(!canEdit)
      }
    } primaryAction: { slots in
      guard canEdit, let slot = slots.first else { return }
      openEditor(slot: slot, layer: .base)
    }
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        if let row = selectedRow {
          Text("Slot \(row.slot)")
            .font(.headline)
            .monospacedDigit()
          Text(row.matrix)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        } else {
          Text("No slot selected")
            .font(.headline)
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        if let keymap, keymap.profile > 1 {
          Label("Profile \(keymap.profile) is read-only", systemImage: "lock")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if keymap != nil && isOffline {
          Label("Offline — reconnect to edit", systemImage: "bolt.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let row = selectedRow {
        HStack(alignment: .top, spacing: 10) {
          layerCard(.base, row: row)
          layerCard(.fn, row: row)
        }
      } else {
        Text("Select a row to inspect its Base and Fn bindings and assign a key.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
  }

  private func layerCard(_ layer: KeyLayer, row: KeymapSlotRow) -> some View {
    let value = layer.isBase ? row.baseValue : row.fnValue
    let hex = layer.isBase ? row.baseHex : row.fnHex

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(layer.isBase ? "Base" : "Fn")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 4)

        Button("Edit…") {
          openEditor(slot: row.slot, layer: layer)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!canEdit)
        .help(editHelp(base: layer.isBase))
        .accessibilityLabel(
          "Edit \(layer.isBase ? "Base" : "Fn") binding for slot \(row.slot)")
      }

      Text(value.summary)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(value.summary)

      Text(hex)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
  }

  private func editHelp(base: Bool) -> String {
    guard keymap != nil else { return "Read a profile first" }
    guard writable else { return "Profile \(keymap?.profile ?? 0) is read-only" }
    guard store.snapshot != nil else { return "Reconnect over wired USB to edit" }
    guard !store.isBusy else { return "Wait for the current operation to finish" }
    return "Edit the \(base ? "Base" : "Fn") layer for the selected slot"
  }

  private func beginImport() {
    guard canRead else { return }
    guard let archive = store.prepareKeymapImport() else { return }
    importArchive = archive
    showImportConfirmation = true
  }

  private func slice(_ layer: [UInt8], slot: Int) -> [UInt8] {
    let start = slot * 4
    let end = start + 4
    guard start >= 0, end <= layer.count else { return [0, 0, 0, 0] }
    return Array(layer[start..<end])
  }

  private func loadedDescription(_ keymap: Keymap) -> String {
    if let readAt = store.keymapReadAt {
      return
        "Loaded profile \(keymap.profile) at \(readAt.formatted(date: .omitted, time: .standard)). Reading never writes."
    }
    return "Loaded profile \(keymap.profile). Reading never writes."
  }

  private func importConfirmationMessage(_ archive: KeymapArchive) -> String {
    var message =
      "Profile \(archive.profile) · exported \(archive.createdAt.formatted(date: .abbreviated, time: .shortened))"
    if let board = archive.boardID {
      message += " · board \(board)"
    }
    message +=
      ".\n\nBoth layers of profile \(archive.profile) are backed up first, then replaced and verified."
    return message
  }

  private func openEditor(slot: Int, layer: KeyLayer) {
    guard let keymap else { return }
    let bytes = slice(layer.isBase ? keymap.base : keymap.fn, slot: slot)
    editorTarget = SlotEditorTarget(
      slot: slot,
      layer: layer,
      profile: keymap.profile,
      bytes: bytes
    )
  }
}

private struct KeymapSlotRow: Identifiable {
  let slot: Int
  let baseBytes: [UInt8]
  let fnBytes: [UInt8]

  var id: Int { slot }
  var matrix: String { "c\(slot / 6) r\(slot % 6)" }
  var baseValue: KeySlotValue { KeySlotValue(bytes: baseBytes) }
  var fnValue: KeySlotValue { KeySlotValue(bytes: fnBytes) }
  var baseHex: String { Hex.string(baseBytes) }
  var fnHex: String { Hex.string(fnBytes) }
}

private struct SlotEditorTarget: Identifiable {
  let slot: Int
  let layer: KeyLayer
  let profile: UInt8
  let bytes: [UInt8]

  var id: String { "\(slot)-\(layer.isBase ? "base" : "fn")" }
}

// MARK: - Slot editor

struct SlotEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var store: KeyboardStore

  let profile: UInt8
  let slot: Int
  let layer: KeyLayer
  let initialBytes: [UInt8]

  @State private var value: KeySlotValue
  @State private var rawText: String
  @State private var showRawBytes: Bool

  init(store: KeyboardStore, profile: UInt8, slot: Int, layer: KeyLayer, initialBytes: [UInt8]) {
    self.store = store
    self.profile = profile
    self.slot = slot
    self.layer = layer
    self.initialBytes = initialBytes
    let decoded = KeySlotValue(bytes: initialBytes)
    _value = State(initialValue: decoded)
    _rawText = State(initialValue: Hex.string(decoded.rawBytes))
    _showRawBytes = State(initialValue: decoded.kind == .raw)
  }

  private var canWrite: Bool {
    profile <= 1 && store.snapshot != nil && !store.isBusy && rawIsValid
  }

  private var effectiveValue: KeySlotValue {
    if value.kind == .raw,
      let bytes = Hex.parse(rawText),
      bytes.count == 4
    {
      return KeySlotValue(bytes: bytes)
    }
    return value
  }

  private var rawIsValid: Bool {
    guard value.kind == .raw else { return true }
    return Hex.parse(rawText)?.count == 4
  }

  private var writeBlockedReason: String? {
    if store.snapshot == nil { return "Disconnected — reconnect over wired USB to assign." }
    if store.isBusy { return "Wait for the current operation to finish." }
    if profile > 1 { return "Profile \(profile) is read-only." }
    return nil
  }

  private var kindBinding: Binding<KeySlotKind> {
    Binding(
      get: { value.kind },
      set: { newKind in
        let currentBytes: [UInt8]
        if value.kind == .raw,
          let parsed = Hex.parse(rawText),
          parsed.count == 4
        {
          currentBytes = parsed
        } else if value.kind == .raw {
          currentBytes = value.rawBytes
        } else {
          currentBytes = value.bytes
        }
        value = KeySlotValue(bytes: currentBytes)
        value.kind = newKind
        if newKind == .raw {
          rawText = Hex.string(currentBytes)
          showRawBytes = true
        }
      }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text("\(layer.displayName) · Slot \(slot)")
            .font(.title3.weight(.semibold))
          Spacer()
          Text("Profile \(profile)")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Text("c\(slot / 6) r\(slot % 6) · Replaces current bytes \(Hex.string(initialBytes))")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)

      Divider()

      Form {
        Section("Binding") {
          Picker("Type", selection: kindBinding) {
            ForEach(KeySlotKind.allCases) { kind in
              Text(kind.title).tag(kind)
            }
          }
          .accessibilityLabel("Binding type")

          bindingControls
        }
      }
      .formStyle(.grouped)
      .disabled(store.isBusy || store.snapshot == nil)

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        if let writeBlockedReason {
          Label(writeBlockedReason, systemImage: "bolt.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel(writeBlockedReason)
        }

        HStack(spacing: 8) {
          if rawIsValid {
            VStack(alignment: .leading, spacing: 2) {
              Text(effectiveValue.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Text(Hex.string(effectiveValue.bytes))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
            }
          } else {
            Text("Enter exactly four hexadecimal bytes, for example 0a 01 00 00.")
              .font(.callout)
              .foregroundStyle(.red)
          }

          Spacer(minLength: 12)

          Button("Cancel", role: .cancel) {
            dismiss()
          }
          .disabled(store.isBusy)
          .keyboardShortcut(.cancelAction)

          Button("Assign Key to Slot \(slot)") {
            assign()
          }
          .disabled(!canWrite)
          .help(
            "Replace the \(layer.displayName) binding for profile \(profile), slot \(slot). Backs up both layers and verifies the read-back."
          )
        }

        Text("Backs up both layers, writes this slot and verifies the read-back.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(.bar)
    }
    .frame(width: 500, height: 460)
  }

  private func assign() {
    guard canWrite else { return }
    let bytes = effectiveValue.bytes
    Task {
      if await store.writeKey(profile: profile, layer: layer, slot: slot, value: bytes) {
        dismiss()
      }
    }
  }

  @ViewBuilder
  private var bindingControls: some View {
    switch value.kind {
    case .keyboard:
      Picker("Keyboard usage", selection: $value.keyboardUsage) {
        ForEach(keyboardChoices) { choice in
          Text(choice.name).tag(choice.id)
        }
      }
      .accessibilityLabel("Keyboard usage")
    case .consumer:
      Picker("Consumer usage", selection: $value.consumerUsage) {
        ForEach(consumerChoices) { choice in
          Text("\(choice.name) (0x\(String(format: "%04X", choice.id)))").tag(choice.id)
        }
      }
      .accessibilityLabel("Consumer usage")
    case .macro:
      Picker("Macro mode", selection: $value.macroMode) {
        Text("Repeat").tag(UInt8(0))
        Text("Toggle").tag(UInt8(1))
        Text("Hold").tag(UInt8(2))
      }
      .accessibilityLabel("Macro mode")

      Stepper(
        value: Binding(
          get: { Int(value.macroSlot) },
          set: { value.macroSlot = UInt8(min(49, max(0, $0))) }
        ), in: 0...49
      ) {
        Text("Macro slot: \(value.macroSlot)")
          .monospacedDigit()
      }
      .accessibilityLabel("Macro slot")
    case .special:
      Picker("Special action", selection: $value.specialCode) {
        ForEach(specialChoices) { choice in
          Text(choice.name).tag(choice.id)
        }
      }
      .accessibilityLabel("Special action")
    case .transparent:
      Text("Clears this slot.")
        .foregroundStyle(.secondary)
        .help("On the Fn layer the key falls through to Base; on Base it does nothing.")
    case .raw:
      DisclosureGroup(isExpanded: $showRawBytes) {
        VStack(alignment: .leading, spacing: 6) {
          TextField("e.g. 0a 01 00 00", text: $rawText)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Raw four-byte slot value in hexadecimal")
          if !rawIsValid {
            Text("Use exactly four hexadecimal bytes, for example 0a 01 00 00.")
              .font(.caption)
              .foregroundStyle(.red)
          } else {
            Text("Four bytes, written exactly as entered.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } label: {
        Label("Raw Bytes", systemImage: "number")
      }
    }
  }

  private var keyboardChoices: [KeyCodeOption] {
    var choices = KeyNames.keyboard
      .map { KeyCodeOption(id: $0.key, name: $0.value) }
      .sorted { $0.id < $1.id }
    if !choices.contains(where: { $0.id == value.keyboardUsage }) {
      choices.append(
        KeyCodeOption(id: value.keyboardUsage, name: KeyNames.keyboardName(value.keyboardUsage)))
    }
    return choices
  }

  private var consumerChoices: [ConsumerCodeOption] {
    var choices = KeyNames.consumer
      .map { ConsumerCodeOption(id: $0.key, name: $0.value) }
      .sorted { $0.id < $1.id }
    if !choices.contains(where: { $0.id == value.consumerUsage }) {
      choices.append(
        ConsumerCodeOption(
          id: value.consumerUsage, name: KeyNames.consumerName(value.consumerUsage)))
    }
    return choices
  }

  private var specialChoices: [KeyCodeOption] {
    var choices = KeyNames.special
      .map { KeyCodeOption(id: $0.key, name: $0.value) }
      .sorted { $0.id < $1.id }
    if !choices.contains(where: { $0.id == value.specialCode }) {
      choices.append(
        KeyCodeOption(id: value.specialCode, name: KeyNames.specialName(value.specialCode)))
    }
    return choices
  }
}

private struct KeyCodeOption: Identifiable {
  let id: UInt8
  let name: String
}

private struct ConsumerCodeOption: Identifiable {
  let id: UInt16
  let name: String
}

// MARK: - Macros

enum MacroEditorMode: String, CaseIterable, Identifiable, Hashable {
  case decoded
  case raw

  var id: String { rawValue }
  var title: String { self == .decoded ? "Steps" : "Raw" }
}

enum MacroStepKind: String, CaseIterable, Identifiable, Hashable {
  case key
  case mouseButton
  case mouseMove

  var id: String { rawValue }

  var title: String {
    switch self {
    case .key: "Key"
    case .mouseButton: "Mouse button"
    case .mouseMove: "Mouse move"
    }
  }
}

struct MacroStepDraft: Identifiable {
  let id = UUID()
  var kind: MacroStepKind
  var code: UInt8
  var pressed: Bool
  var delay: UInt16
  var dx: Int8
  var dy: Int8

  init(step: MacroStep) {
    delay = step.delay
    dx = step.dx
    dy = step.dy
    switch step.code {
    case 0xF9:
      kind = .mouseMove
      code = 0xF9
      pressed = false
    case 0xF0...0xF4:
      kind = .mouseButton
      code = step.code
      pressed = step.pressed
    default:
      kind = .key
      code = step.code
      pressed = step.pressed
    }
  }

  init(kind: MacroStepKind, code: UInt8, pressed: Bool, delay: UInt16, dx: Int8 = 0, dy: Int8 = 0) {
    self.kind = kind
    self.code = code
    self.pressed = pressed
    self.delay = delay
    self.dx = dx
    self.dy = dy
  }

  var macroStep: MacroStep {
    MacroStep(
      code: kind == .mouseMove ? 0xF9 : code,
      pressed: kind == .mouseMove ? false : pressed,
      delay: delay,
      dx: kind == .mouseMove ? dx : 0,
      dy: kind == .mouseMove ? dy : 0
    )
  }
}

private enum PendingMacroAction: Equatable {
  case read
  case selectSlot(Int)
}

/// Macro drafts live outside `MacrosView` so switching sections cannot throw
/// away unsaved steps. The window owns one instance; `sourceBytes` is the
/// device blob the draft was derived from, which lets a returning view keep an
/// edited draft while still reloading after a read or save.
@MainActor
final class MacroDraftModel: ObservableObject {
  @Published var slot = 0
  @Published var mode: MacroEditorMode = .decoded
  @Published var repeatCount: UInt16 = 0
  @Published var steps: [MacroStepDraft] = []
  /// Slot whose loaded bytes the current draft was derived from. The draft is
  /// never shown or written under a different slot label.
  @Published var draftSlot: Int?
  @Published var rawText = ""
  @Published var decodeError: String?
  @Published var rawError: String?
  var sourceBytes: [UInt8]?

  func invalidate() {
    draftSlot = nil
    sourceBytes = nil
    rawText = ""
    rawError = nil
    decodeError = nil
    repeatCount = 0
    steps = []
    mode = .decoded
  }
}

struct MacrosView: View {
  @ObservedObject var store: KeyboardStore
  @ObservedObject var draft: MacroDraftModel

  @State private var pendingAction: PendingMacroAction?
  @State private var showDiscardConfirmation = false

  private static let writableBytes = 224

  private var slot: Int {
    get { draft.slot }
    nonmutating set { draft.slot = newValue }
  }

  private var mode: MacroEditorMode {
    get { draft.mode }
    nonmutating set { draft.mode = newValue }
  }

  private var repeatCount: UInt16 {
    get { draft.repeatCount }
    nonmutating set { draft.repeatCount = newValue }
  }

  private var steps: [MacroStepDraft] {
    get { draft.steps }
    nonmutating set { draft.steps = newValue }
  }

  private var draftSlot: Int? {
    get { draft.draftSlot }
    nonmutating set { draft.draftSlot = newValue }
  }

  private var rawText: String {
    get { draft.rawText }
    nonmutating set { draft.rawText = newValue }
  }

  private var rawError: String? {
    get { draft.rawError }
    nonmutating set { draft.rawError = newValue }
  }

  private var loadedBytes: [UInt8]? {
    guard store.macroSlot == slot, draftSlot == slot else { return nil }
    return store.loadedMacro
  }

  private var canRead: Bool { store.snapshot != nil && !store.isBusy }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      Group {
        if loadedBytes == nil {
          emptyState
        } else if mode == .decoded {
          decodedEditor
        } else {
          rawEditor
        }
      }
      .disabled(store.isBusy)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if loadedBytes != nil {
        Divider()
        saveBar
      }
    }
    .onAppear {
      syncDraftWithLoadedSlot()
    }
    .onChange(of: slot) { _, _ in
      syncDraftWithLoadedSlot()
    }
    .onChange(of: store.macroSlot) { _, _ in
      syncDraftWithLoadedSlot()
    }
    .onChange(of: store.loadedMacro) { _, _ in
      syncDraftWithLoadedSlot()
    }
    .onChange(of: rawText) { _, _ in
      rawError = nil
    }
    .alert("Discard unsaved changes?", isPresented: $showDiscardConfirmation) {
      Button("Discard and Continue", role: .destructive) {
        performPendingAction()
      }
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
    } message: {
      Text(
        "Slot \(slot) has macro changes that were not saved. Continuing discards them; nothing is written to the keyboard."
      )
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Picker("Macro slot", selection: slotBinding) {
        ForEach(0..<50, id: \.self) { index in
          Text("Slot \(index)").tag(index)
        }
      }
      .labelsHidden()
      .frame(maxWidth: 150)
      .help("Macro slots run from 0 to 49")
      .accessibilityLabel("Macro slot")

      Button {
        requestRead()
      } label: {
        Label("Read", systemImage: "arrow.down.circle")
      }
      .disabled(!canRead)
      .help("Read macro slot \(slot). Reading never writes.")
      .accessibilityLabel("Read macro slot \(slot)")

      Group {
        if let bytes = loadedBytes {
          HStack(spacing: 6) {
            Text("\(bytes.count) bytes")
              .font(.callout)
              .foregroundStyle(.secondary)
              .monospacedDigit()
            if isDirty {
              Label("Edited", systemImage: "pencil")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("This draft has changes that are not saved to the keyboard")
            }
          }
        } else {
          Text("Slot \(slot) not read")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)

      if loadedBytes != nil {
        Picker("Editor", selection: modeBinding) {
          ForEach(MacroEditorMode.allCases) { editorMode in
            Text(editorMode.title).tag(editorMode)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 130)
        .accessibilityLabel("Macro editor mode")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(
        store.snapshot == nil
          ? (store.connection == .connecting ? "Connecting…" : "Keyboard Not Connected")
          : "Slot \(slot) Not Read",
        systemImage: store.snapshot == nil ? "bolt.slash" : "list.number"
      )
    } description: {
      if store.snapshot == nil {
        Text(
          store.connection == .connecting
            ? "Looking for the MK750 over wired USB."
            : KeyboardStore.connectionGuidance
        )
      } else {
        Text("Read this slot to inspect its macro. Reading never writes to the keyboard.")
      }
    } actions: {
      if store.snapshot == nil {
        if store.connection == .connecting {
          ProgressView()
            .controlSize(.small)
        } else {
          Button("Reconnect") {
            Task { await store.connect() }
          }
          .disabled(store.isBusy)
        }
      } else {
        Button("Read Slot \(slot)") {
          requestRead()
        }
        .disabled(!canRead)
      }

      if let loadedSlot = store.macroSlot, loadedSlot != slot {
        Button("Show Slot \(loadedSlot)") {
          requestSelect(loadedSlot)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var decodedEditor: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text("Repeat")
          .font(.callout)

        TextField("Repeat count", value: repeatValue, format: .number)
          .textFieldStyle(.roundedBorder)
          .frame(width: 64)
          .accessibilityLabel("Repeat count")

        Stepper("Repeat count", value: repeatValue, in: 0...65535)
          .labelsHidden()
          .accessibilityLabel("Adjust repeat count")

        Text("×")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)

        Spacer(minLength: 8)

        Text(steps.count == 1 ? "1 step" : "\(steps.count) steps")
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()

        addStepMenu
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)

      Divider()

      if steps.isEmpty {
        emptyStepsState
      } else {
        stepsTable
      }
    }
  }

  private var emptyStepsState: some View {
    ContentUnavailableView {
      Label("No Steps", systemImage: "list.number")
    } description: {
      Text("Add a key press, mouse button, or mouse move. Each step stores its own delay.")
    } actions: {
      addStepMenu
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var addStepMenu: some View {
    Menu {
      Button("Key") {
        addStep(kind: .key, code: 0x04)
      }
      Button("Mouse Button") {
        addStep(kind: .mouseButton, code: 0xF0)
      }
      Button("Mouse Move") {
        addStep(kind: .mouseMove, code: 0xF9)
      }
    } label: {
      Label("Add Step", systemImage: "plus")
    }
    .help("Add a macro step")
    .accessibilityLabel("Add macro step")
  }

  private var stepsTable: some View {
    Table(steps) {
      TableColumn("Type") { row in
        Picker("Step type", selection: kindBinding(for: row)) {
          ForEach(MacroStepKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Step type")
      }
      .width(min: 100, ideal: 116, max: 132)

      TableColumn("Event") { row in
        eventControls(for: row)
      }
      .width(min: 150, ideal: 220)

      TableColumn("Press") { row in
        if row.kind == .mouseMove {
          Text("—")
            .foregroundStyle(.tertiary)
            .accessibilityLabel("No press state for mouse move")
        } else {
          Toggle("Press", isOn: binding(for: row).pressed)
            .labelsHidden()
            .controlSize(.small)
            .help("Press or release the event")
            .accessibilityLabel("Pressed")
        }
      }
      .width(min: 48, ideal: 58, max: 70)

      TableColumn("Delay") { row in
        HStack(spacing: 4) {
          TextField("Delay", value: delayBinding(for: row), format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 54)
            .accessibilityLabel("Delay in milliseconds")
          Text("ms")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 80, ideal: 98, max: 116)

      TableColumn("") { row in
        Button(role: .destructive) {
          removeStep(row.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Remove this step")
        .accessibilityLabel("Remove step")
      }
      .width(30)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func eventControls(for row: MacroStepDraft) -> some View {
    let step = binding(for: row)
    switch row.kind {
    case .key:
      Picker("Key", selection: step.code) {
        ForEach(keyChoices(for: row.code)) { choice in
          Text(choice.name).tag(choice.id)
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .accessibilityLabel("Key event")
    case .mouseButton:
      Picker("Mouse button", selection: step.code) {
        ForEach(mouseChoices) { choice in
          Text(choice.name).tag(choice.id)
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .accessibilityLabel("Mouse button")
    case .mouseMove:
      HStack(spacing: 4) {
        Stepper(value: dxBinding(for: row), in: -128...127) {
          Text("dx \(row.dx)")
            .font(.caption)
            .monospacedDigit()
        }
        .controlSize(.small)
        .accessibilityLabel("Horizontal movement")

        Stepper(value: dyBinding(for: row), in: -128...127) {
          Text("dy \(row.dy)")
            .font(.caption)
            .monospacedDigit()
        }
        .controlSize(.small)
        .accessibilityLabel("Vertical movement")
      }
    }
  }

  private var rawEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      if draft.decodeError != nil {
        Label(
          "These bytes don’t decode into steps. Editing raw preserves every byte.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      TextEditor(text: rawTextBinding)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(
          Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Raw macro bytes in hexadecimal")

      HStack(spacing: 8) {
        if let bytes = Hex.parse(rawText) {
          Label("\(bytes.count) bytes", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Label("Enter hexadecimal bytes", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }

        if let rawError {
          Text(rawError)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
        }

        Spacer(minLength: 0)
      }
    }
    .padding(20)
  }

  private var saveBar: some View {
    HStack(spacing: 10) {
      if let bytes = writeBytes {
        Text("\(min(bytes.count, Self.writableBytes)) / \(Self.writableBytes) bytes")
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(beyond224 ? Color.red : Color.secondary)
          .help("Writes cover bytes 0–223; bytes 224–255 are preserved.")
      } else {
        Text("No valid macro bytes")
          .font(.callout)
          .foregroundStyle(.red)
      }

      if beyond224 {
        Label("Bytes 224–255 differ", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
      } else if store.snapshot == nil {
        Label("Offline — reconnect to save", systemImage: "bolt.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if isDirty {
        Text("Backs up and verifies")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(
            "Saving replaces bytes 0–223 of slot \(slot). Bytes 224–255 are preserved, and all 256 bytes are verified on read-back."
          )
      } else {
        Text("No unsaved changes")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Button("Save Macro to Slot \(slot)") {
        saveMacro()
      }
      .disabled(!canSave)
      .help(saveHelp)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func saveMacro() {
    guard canSave, draftSlot == slot, store.macroSlot == slot,
      let bytes = writeBytes
    else {
      return
    }
    let targetSlot = slot
    Task {
      _ = await store.writeMacro(slot: targetSlot, bytes: bytes)
    }
  }

  private var canSave: Bool {
    loadedBytes != nil && draftSlot == slot && isDirty && !beyond224
      && writeBytes != nil && store.snapshot != nil && !store.isBusy
  }

  private var saveHelp: String {
    if store.snapshot == nil { return "Reconnect the MK750 over wired USB to save" }
    if store.isBusy { return "Wait for the current operation to finish" }
    if writeBytes == nil { return "Fix the macro bytes before saving" }
    if beyond224 { return "Bytes 224–255 cannot be written; remove that data first" }
    if !isDirty { return "No changes to save" }
    return "Back up this slot, write bytes 0–223 and verify the read-back"
  }

  private var isDirty: Bool {
    guard let current = loadedBytes, current.count == 256,
      let bytes = normalizedWriteBytes
    else {
      return false
    }
    return Array(bytes[0..<Self.writableBytes]) != Array(current[0..<Self.writableBytes])
  }

  private var rawTextBinding: Binding<String> {
    Binding(
      get: { rawText },
      set: { rawText = $0 }
    )
  }

  private var repeatValue: Binding<Int> {
    Binding(
      get: { Int(repeatCount) },
      set: { repeatCount = UInt16(clamping: max(0, min(65535, $0))) }
    )
  }

  private var modeBinding: Binding<MacroEditorMode> {
    Binding(
      get: { mode },
      set: { newMode in
        changeMode(to: newMode)
      }
    )
  }

  private var slotBinding: Binding<Int> {
    Binding(
      get: { slot },
      set: { newSlot in
        requestSelect(newSlot)
      }
    )
  }

  private var decodedBytes: [UInt8]? {
    try? MacroSequence(
      repeatCount: repeatCount,
      steps: steps.map(\.macroStep)
    ).encoded()
  }

  private var decodedError: String? {
    do {
      _ = try MacroSequence(repeatCount: repeatCount, steps: steps.map(\.macroStep)).encoded()
      return nil
    } catch {
      return KeyboardStore.describe(error)
    }
  }

  private var writeBytes: [UInt8]? {
    if mode == .decoded, decodedError == nil {
      return decodedBytes
    }
    guard let bytes = Hex.parse(rawText), !bytes.isEmpty, bytes.count <= 256 else {
      return nil
    }
    return bytes
  }

  private var normalizedWriteBytes: [UInt8]? {
    guard var bytes = writeBytes else { return nil }
    if bytes.count < 256 {
      bytes += Array(repeating: 0, count: 256 - bytes.count)
    }
    return bytes
  }

  private var beyond224: Bool {
    guard let bytes = normalizedWriteBytes else { return false }
    let requestedTail = Array(bytes[Self.writableBytes...])
    guard requestedTail.contains(where: { $0 != 0 }) else { return false }
    guard let current = loadedBytes, current.count == 256 else { return true }
    return requestedTail != Array(current[Self.writableBytes...])
  }

  private func binding(for row: MacroStepDraft) -> Binding<MacroStepDraft> {
    Binding(
      get: { steps.first { $0.id == row.id } ?? row },
      set: { updated in
        guard let index = draft.steps.firstIndex(where: { $0.id == row.id }) else { return }
        draft.steps[index] = updated
      }
    )
  }

  private func kindBinding(for row: MacroStepDraft) -> Binding<MacroStepKind> {
    let step = binding(for: row)
    return Binding(
      get: { step.wrappedValue.kind },
      set: { newKind in
        var updated = step.wrappedValue
        updated.kind = newKind
        switch newKind {
        case .key:
          if updated.code < 0x04 || updated.code > 0xEF {
            updated.code = 0x04
          }
        case .mouseButton:
          updated.code = 0xF0
          updated.pressed = true
        case .mouseMove:
          updated.code = 0xF9
          updated.pressed = false
          updated.delay = min(updated.delay, 255)
        }
        step.wrappedValue = updated
      }
    )
  }

  private func delayBinding(for row: MacroStepDraft) -> Binding<Int> {
    let step = binding(for: row)
    return Binding(
      get: { Int(step.wrappedValue.delay) },
      set: { newValue in
        let maximum = step.wrappedValue.kind == .mouseMove ? 255 : 65535
        step.wrappedValue.delay = UInt16(clamping: max(0, min(maximum, newValue)))
      }
    )
  }

  private func dxBinding(for row: MacroStepDraft) -> Binding<Int> {
    let step = binding(for: row)
    return Binding(
      get: { Int(step.wrappedValue.dx) },
      set: { step.wrappedValue.dx = Int8(clamping: max(-128, min(127, $0))) }
    )
  }

  private func dyBinding(for row: MacroStepDraft) -> Binding<Int> {
    let step = binding(for: row)
    return Binding(
      get: { Int(step.wrappedValue.dy) },
      set: { step.wrappedValue.dy = Int8(clamping: max(-128, min(127, $0))) }
    )
  }

  private func keyChoices(for code: UInt8) -> [KeyCodeOption] {
    var choices = KeyNames.keyboard
      .map { KeyCodeOption(id: $0.key, name: $0.value) }
      .sorted { $0.id < $1.id }
    if !choices.contains(where: { $0.id == code }) {
      choices.append(KeyCodeOption(id: code, name: KeyNames.keyboardName(code)))
    }
    return choices
  }

  private var mouseChoices: [KeyCodeOption] {
    [
      KeyCodeOption(id: 0xF0, name: "Left button"),
      KeyCodeOption(id: 0xF1, name: "Right button"),
      KeyCodeOption(id: 0xF2, name: "Middle button"),
      KeyCodeOption(id: 0xF3, name: "Button 4"),
      KeyCodeOption(id: 0xF4, name: "Button 5"),
    ]
  }

  private func addStep(kind: MacroStepKind, code: UInt8) {
    draft.steps.append(
      MacroStepDraft(
        kind: kind,
        code: code,
        pressed: kind != .mouseMove,
        delay: 10
      )
    )
  }

  private func removeStep(_ id: UUID) {
    draft.steps.removeAll { $0.id == id }
  }

  private func requestRead() {
    guard canRead else { return }
    let targetSlot = slot
    if isDirty {
      pendingAction = .read
      showDiscardConfirmation = true
    } else {
      Task { await store.loadMacro(slot: targetSlot) }
    }
  }

  private func requestSelect(_ newSlot: Int) {
    guard newSlot != slot else { return }
    if isDirty {
      pendingAction = .selectSlot(newSlot)
      showDiscardConfirmation = true
    } else {
      select(newSlot)
    }
  }

  private func select(_ newSlot: Int) {
    guard newSlot != slot else { return }
    draft.invalidate()
    slot = newSlot
  }

  private func performPendingAction() {
    let action = pendingAction
    pendingAction = nil
    switch action {
    case .read:
      // The user chose to discard unsaved edits before re-reading.
      let targetSlot = slot
      draft.invalidate()
      Task { await store.loadMacro(slot: targetSlot) }
    case .selectSlot(let newSlot):
      select(newSlot)
    case nil:
      break
    }
  }

  private func changeMode(to newMode: MacroEditorMode) {
    if newMode == .raw {
      if mode == .decoded, let bytes = decodedBytes {
        rawText = Hex.string(bytes)
      }
      mode = .raw
      rawError = nil
      return
    }

    guard let bytes = Hex.parse(rawText) else {
      rawError = "Enter valid hexadecimal bytes before switching to steps."
      return
    }
    do {
      let sequence = try MacroSequence.decode(bytes)
      repeatCount = sequence.repeatCount
      steps = sequence.steps.map { MacroStepDraft(step: $0) }
      draft.decodeError = nil
      mode = .decoded
      rawError = nil
    } catch {
      rawError = "This macro can’t be shown as steps: \(KeyboardStore.describe(error))"
    }
  }

  /// Loads the selected slot's bytes into the draft when the draft has no
  /// source yet or the device bytes changed. Returning to this section keeps
  /// an unsaved draft because the store still holds the same source blob.
  private func syncDraftWithLoadedSlot() {
    guard store.macroSlot == slot, let bytes = store.loadedMacro else { return }
    guard draftSlot != slot || draft.sourceBytes != bytes else { return }
    load(bytes: bytes)
  }

  private func load(bytes: [UInt8]) {
    draft.sourceBytes = bytes
    draftSlot = slot
    rawText = Hex.string(bytes)
    rawError = nil
    do {
      let sequence = try MacroSequence.decode(bytes)
      repeatCount = sequence.repeatCount
      steps = sequence.steps.map { MacroStepDraft(step: $0) }
      draft.decodeError = nil
      mode = .decoded
    } catch {
      draft.decodeError = KeyboardStore.describe(error)
      repeatCount = 0
      steps = []
      mode = .raw
    }
  }
}
