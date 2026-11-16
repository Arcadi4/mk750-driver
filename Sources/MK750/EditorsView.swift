import MK750Kit
import SwiftUI

// MARK: - Keymap

struct KeymapView: View {
  @ObservedObject var store: KeyboardStore

  @State private var readProfile: UInt8 = 0
  @State private var search = ""
  @State private var showRaw = false
  @State private var selectedSlot: Int?
  @State private var editorTarget: SlotEditorTarget?
  @State private var importArchive: KeymapArchive?
  @State private var showImportConfirmation = false

  private var keymap: Keymap? { store.loadedKeymap }

  private var rows: [KeymapSlotRow] {
    guard let keymap else { return [] }
    return (0..<128).map { slot in
      let base = slice(keymap.base, slot: slot)
      let fn = slice(keymap.fn, slot: slot)
      return KeymapSlotRow(slot: slot, baseBytes: base, fnBytes: fn)
    }
  }

  private var filteredRows: [KeymapSlotRow] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return rows }
    return rows.filter { row in
      let haystack = [
        "\(row.slot)",
        "c\(row.slot / 6) r\(row.slot % 6)",
        row.baseValue.summary,
        row.fnValue.summary,
        row.baseHex,
        row.fnHex,
      ].joined(separator: " ").lowercased()
      return haystack.contains(query)
    }
  }

  private var writable: Bool {
    guard let keymap else { return false }
    return keymap.profile <= 1
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()

      if keymap != nil {
        if filteredRows.isEmpty {
          ContentUnavailableView {
            Label("No Matching Slots", systemImage: "magnifyingglass")
          } description: {
            Text("No slots match “\(search)”.")
          } actions: {
            Button("Clear Search") {
              search = ""
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          dataTable
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        ContentUnavailableView {
          Label("No Keymap Loaded", systemImage: "tablecells")
        } description: {
          Text("Read a profile to edit its keys.")
        } actions: {
          Button("Read Profile \(readProfile)") {
            Task { await store.loadKeymap(profile: readProfile) }
          }
          .disabled(store.snapshot == nil || store.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if keymap != nil {
        Divider()
        footer
      }
    }
    .onChange(of: store.loadedKeymap?.profile) { _, profile in
      if let profile {
        readProfile = profile
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
        Task {
          if let archive = importArchive {
            _ = await store.applyImportedKeymap(archive)
          }
          importArchive = nil
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

  @ViewBuilder
  private var dataTable: some View {
    if showRaw {
      Table(filteredRows, selection: $selectedSlot) {
        TableColumn("Slot") { row in
          Text("\(row.slot)")
            .monospacedDigit()
        }
        .width(52)

        TableColumn("Matrix") { row in
          Text("c\(row.slot / 6) r\(row.slot % 6)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .width(76)

        TableColumn("Base") { row in
          Text(row.baseValue.summary)
            .lineLimit(1)
        }

        TableColumn("Fn") { row in
          Text(row.fnValue.summary)
            .lineLimit(1)
        }

        TableColumn("Base bytes") { row in
          Text(row.baseHex)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .width(112)

        TableColumn("Fn bytes") { row in
          Text(row.fnHex)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .width(112)
      }
      .tableStyle(.inset(alternatesRowBackgrounds: true))
    } else {
      Table(filteredRows, selection: $selectedSlot) {
        TableColumn("Slot") { row in
          Text("\(row.slot)")
            .monospacedDigit()
        }
        .width(52)

        TableColumn("Base") { row in
          Text(row.baseValue.summary)
            .lineLimit(1)
        }

        TableColumn("Fn") { row in
          Text(row.fnValue.summary)
            .lineLimit(1)
        }
      }
      .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Picker("Read profile", selection: $readProfile) {
        Text("Profile 0").tag(UInt8(0))
        Text("Profile 1").tag(UInt8(1))
        Text("Profile 2 (read-only)").tag(UInt8(2))
        Text("Profile 3 (read-only)").tag(UInt8(3))
      }
      .labelsHidden()
      .accessibilityLabel("Profile to read")

      Button("Read") {
        Task { await store.loadKeymap(profile: readProfile) }
      }
      .disabled(store.snapshot == nil || store.isBusy)
      .help("Read profile \(readProfile) keymap")
      .accessibilityLabel("Read keymap for profile \(readProfile)")

      if let keymap {
        Text("Profile \(keymap.profile)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .help(loadedDescription(keymap))
          .accessibilityLabel(loadedDescription(keymap))
      }

      Spacer(minLength: 12)

      searchField

      Toggle("Show Raw", isOn: $showRaw)
        .help("Show the matrix position and raw four-byte values")

      Menu {
        Button("Export Keymap…") {
          store.exportKeymap()
        }
        .disabled(keymap == nil)

        Divider()

        Button("Import and Restore…") {
          if let archive = store.prepareKeymapImport() {
            importArchive = archive
            showImportConfirmation = true
          }
        }
        .disabled(store.snapshot == nil || store.isBusy)
      } label: {
        Label("Import / Export", systemImage: "arrow.up.arrow.down")
      }
      .accessibilityLabel("Keymap import and export")
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      TextField("Search slots or keys", text: $search)
        .accessibilityLabel("Search keymap")
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Clear keymap search")
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if let selectedSlot {
        Text("Profile \(keymap?.profile ?? 0) · Slot \(selectedSlot)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        Text("No slot selected")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if keymap != nil && !writable {
        Label("Read-only profile", systemImage: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      Button("Edit Base…") {
        guard let slot = selectedSlot else { return }
        openEditor(slot: slot, layer: .base)
      }
      .disabled(selectedSlot == nil || !writable || store.isBusy)
      .help(editHelp(base: true))

      Button("Edit Fn…") {
        guard let slot = selectedSlot else { return }
        openEditor(slot: slot, layer: .fn)
      }
      .disabled(selectedSlot == nil || !writable || store.isBusy)
      .help(editHelp(base: false))
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func editHelp(base: Bool) -> String {
    guard keymap != nil else { return "Read a profile first" }
    guard writable else { return "Profile \(keymap?.profile ?? 0) is read-only" }
    guard selectedSlot != nil else { return "Select a slot to edit" }
    return "Edit the \(base ? "Base" : "Fn") layer for the selected slot"
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
        "Loaded profile \(keymap.profile) at \(readAt.formatted(date: .omitted, time: .standard))"
    }
    return "Loaded profile \(keymap.profile)"
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
  @State private var rawError: String?
  @State private var showRawBytes: Bool
  @State private var showWriteConfirmation = false

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
    profile <= 1 && !store.isBusy && store.snapshot != nil && rawIsValid
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
          rawError = nil
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
        Text("c\(slot / 6) r\(slot % 6) · Current \(Hex.string(initialBytes))")
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

          bindingControls
        }
      }
      .formStyle(.grouped)
      .disabled(store.isBusy || store.snapshot == nil)

      Divider()

      HStack(spacing: 8) {
        if rawIsValid {
          Text(effectiveValue.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
          Text("Enter four hexadecimal bytes")
            .font(.callout)
            .foregroundStyle(.red)
        }

        Spacer(minLength: 12)

        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button("Write Key…") {
          showWriteConfirmation = true
        }
        .disabled(!canWrite)
        .help("Back up both layers, write this slot and verify the read-back")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(.bar)
    }
    .frame(width: 520, height: 430)
    .alert(
      "Write this key?",
      isPresented: $showWriteConfirmation
    ) {
      Button("Write and Verify", role: .destructive) {
        let bytes = effectiveValue.bytes
        Task {
          if await store.writeKey(
            profile: profile, layer: layer, slot: slot, value: bytes)
          {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Profile \(profile) · \(layer.displayName) · slot \(slot)\n\(Hex.string(effectiveValue.bytes)) — \(effectiveValue.summary)\nBacked up before writing; the layer is verified after the write."
      )
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
    case .consumer:
      Picker("Consumer usage", selection: $value.consumerUsage) {
        ForEach(consumerChoices) { choice in
          Text("\(choice.name) (0x\(String(format: "%04X", choice.id)))").tag(choice.id)
        }
      }
    case .macro:
      Picker("Macro mode", selection: $value.macroMode) {
        Text("Repeat").tag(UInt8(0))
        Text("Toggle").tag(UInt8(1))
        Text("Hold").tag(UInt8(2))
      }
      Stepper(
        value: Binding(
          get: { Int(value.macroSlot) },
          set: { value.macroSlot = UInt8(min(49, max(0, $0))) }
        ), in: 0...49
      ) {
        Text("Macro slot: \(value.macroSlot)")
      }
    case .special:
      Picker("Special action", selection: $value.specialCode) {
        ForEach(specialChoices) { choice in
          Text(choice.name).tag(choice.id)
        }
      }
    case .transparent:
      Text("Clears this slot.")
        .foregroundStyle(.secondary)
        .help("On the Fn layer the key falls through to Base; on Base it does nothing.")
    case .raw:
      DisclosureGroup(isExpanded: $showRawBytes) {
        HStack(spacing: 8) {
          TextField("e.g. 0a 01 00 00", text: $rawText)
            .accessibilityLabel("Raw four-byte slot value in hexadecimal")
          Button("Set Bytes") {
            applyRaw()
          }
        }
        if let rawError {
          Text(rawError)
            .font(.callout)
            .foregroundStyle(.red)
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

  private func applyRaw() {
    guard let bytes = Hex.parse(rawText), bytes.count == 4 else {
      rawError = "Enter exactly four hexadecimal bytes, for example 0a 01 00 00."
      return
    }
    value = KeySlotValue(bytes: bytes)
    rawError = nil
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

struct MacrosView: View {
  @ObservedObject var store: KeyboardStore

  @State private var slot = 0
  @State private var mode: MacroEditorMode = .decoded
  @State private var repeatCount: UInt16 = 0
  @State private var steps: [MacroStepDraft] = []
  /// Slot whose loaded bytes the current draft was derived from. The draft is
  /// never shown or written under a different slot label.
  @State private var draftSlot: Int?
  @State private var rawText = ""
  @State private var decodeError: String?
  @State private var rawError: String?
  @State private var showWriteConfirmation = false

  private var loadedBytes: [UInt8]? {
    guard store.macroSlot == slot, draftSlot == slot else { return nil }
    return store.loadedMacro
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()

      if loadedBytes == nil {
        ContentUnavailableView {
          Label("Slot \(slot) Not Read", systemImage: "list.number")
        } description: {
          Text("Read this slot to inspect or edit its macro.")
        } actions: {
          Button("Read Slot \(slot)") {
            Task { await store.loadMacro(slot: slot) }
          }
          .disabled(store.snapshot == nil || store.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if mode == .decoded {
        ScrollView {
          decodedEditor
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        rawEditor
          .padding(20)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if loadedBytes != nil {
        Divider()
        writeBar
      }
    }
    .onAppear {
      syncDraftWithLoadedSlot()
    }
    .onChange(of: slot) { _, _ in
      showWriteConfirmation = false
      syncDraftWithLoadedSlot()
    }
    .onChange(of: store.macroSlot) { _, _ in
      syncDraftWithLoadedSlot()
    }
    .onChange(of: store.loadedMacro) { _, _ in
      syncDraftWithLoadedSlot()
    }
    .alert("Save macro slot \(slot)?", isPresented: $showWriteConfirmation) {
      Button("Save and Verify", role: .destructive) {
        guard draftSlot == slot, store.macroSlot == slot, loadedBytes != nil,
          let bytes = writeBytes, !beyond224
        else {
          return
        }
        Task {
          _ = await store.writeMacro(slot: slot, bytes: bytes)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Writes \(writeBytes?.count ?? 0) bytes to slot \(slot) and verifies all 256 bytes on read-back. Bytes 224–255 keep their current values; a backup is made first."
      )
    }
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Picker("Macro slot", selection: $slot) {
        ForEach(0..<50, id: \.self) { index in
          Text("Slot \(index)").tag(index)
        }
      }
      .labelsHidden()
      .accessibilityLabel("Macro slot")

      Button("Read") {
        Task { await store.loadMacro(slot: slot) }
      }
      .disabled(store.snapshot == nil || store.isBusy)
      .help("Read macro slot \(slot)")
      .accessibilityLabel("Read macro slot \(slot)")

      if let bytes = loadedBytes {
        Text("\(bytes.count) bytes")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 12)

      if loadedBytes != nil {
        Picker("Editor", selection: modeBinding) {
          ForEach(MacroEditorMode.allCases) { editorMode in
            Text(editorMode.title).tag(editorMode)
          }
        }
        .labelsHidden()
        .accessibilityLabel("Macro editor mode")
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  private var decodedEditor: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Text("Repeat")
        TextField(
          "Repeat count",
          value: repeatValue,
          format: .number
        )
        .accessibilityLabel("Repeat count")
        Stepper("Repeat count", value: repeatValue, in: 0...65535)
          .labelsHidden()
          .accessibilityLabel("Adjust repeat count")
        Spacer()
      }

      if steps.isEmpty {
        Text("No steps yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 0) {
          ForEach(steps.indices, id: \.self) { index in
            MacroStepRow(
              step: $steps[index],
              onRemove: {
                steps.remove(at: index)
              }
            )
            if index < steps.count - 1 {
              Divider()
            }
          }
        }
      }

      if let decodedError {
        Text(decodedError)
          .font(.callout)
          .foregroundStyle(.red)
      }
    }
  }

  private var rawEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      if decodeError != nil {
        Label(
          "Open Raw to edit this macro. Its bytes are preserved.",
          systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      TextEditor(text: $rawText)
        .accessibilityLabel("Raw macro bytes in hexadecimal")
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: 10) {
        Button("Validate Bytes") {
          validateRaw()
        }
        .disabled(store.isBusy)

        if let rawError {
          Text(rawError)
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(1)
        } else if let bytes = Hex.parse(rawText) {
          Text("\(bytes.count) bytes parsed")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
    }
  }

  private var writeBar: some View {
    HStack(spacing: 10) {
      if let bytes = writeBytes {
        Text("\(bytes.count) / 224 bytes")
          .font(.callout)
          .monospacedDigit()
          .foregroundStyle(beyond224 ? Color.red : Color.secondary)
          .help("Macro writes cover bytes 0–223; bytes 224–255 are preserved.")
      } else {
        Text("— / 224 bytes")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if beyond224 {
        Label("Bytes 224–255 differ", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      Button("Revert") {
        if let bytes = loadedBytes {
          load(bytes: bytes)
        }
      }
      .disabled(store.isBusy)
      .help("Restore the bytes last read from this slot")

      Menu("Add Step") {
        Button("Key") {
          steps.append(MacroStepDraft(kind: .key, code: 0x04, pressed: true, delay: 10))
        }
        Button("Mouse Button") {
          steps.append(MacroStepDraft(kind: .mouseButton, code: 0xF0, pressed: true, delay: 10))
        }
        Button("Mouse Move") {
          steps.append(MacroStepDraft(kind: .mouseMove, code: 0xF9, pressed: false, delay: 10))
        }
      }
      .disabled(mode != .decoded || decodeError != nil)
      .help(
        mode == .decoded
          ? "Add a macro step" : "Switch to Steps to add a step"
      )

      Button("Save Macro…") {
        rawError = nil
        guard writeBytes != nil else {
          rawError = "The macro bytes are not valid yet."
          return
        }
        showWriteConfirmation = true
      }
      .disabled(store.snapshot == nil || store.isBusy || writeBytes == nil || beyond224)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(.bar)
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
    if mode == .decoded, decodeError == nil {
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
    let requestedTail = Array(bytes[224...])
    guard requestedTail.contains(where: { $0 != 0 }) else { return false }
    guard let current = loadedBytes, current.count == 256 else { return true }
    return requestedTail != Array(current[224...])
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
      decodeError = nil
      mode = .decoded
      rawError = nil
    } catch {
      rawError = "This macro can't be shown as steps: \(KeyboardStore.describe(error))"
    }
  }

  private func validateRaw() {
    guard let bytes = Hex.parse(rawText), !bytes.isEmpty, bytes.count <= 256 else {
      rawError = "Enter 1–256 hexadecimal bytes."
      return
    }
    rawError = nil
    if let sequence = try? MacroSequence.decode(bytes) {
      repeatCount = sequence.repeatCount
      steps = sequence.steps.map { MacroStepDraft(step: $0) }
      decodeError = nil
    }
  }

  /// Reloads the draft from the selected slot's actual loaded bytes. When the
  /// store holds another slot's bytes (for example after an asynchronous read
  /// started from a different selection), the draft identity is invalidated so
  /// a lingering draft can never be displayed or written under this slot.
  private func syncDraftWithLoadedSlot() {
    guard store.macroSlot == slot, let bytes = store.loadedMacro else {
      invalidateDraft()
      return
    }
    load(bytes: bytes)
  }

  private func invalidateDraft() {
    draftSlot = nil
    rawText = ""
    rawError = nil
    decodeError = nil
    repeatCount = 0
    steps = []
    mode = .decoded
  }

  private func load(bytes: [UInt8]) {
    draftSlot = slot
    rawText = Hex.string(bytes)
    rawError = nil
    do {
      let sequence = try MacroSequence.decode(bytes)
      repeatCount = sequence.repeatCount
      steps = sequence.steps.map { MacroStepDraft(step: $0) }
      decodeError = nil
      mode = .decoded
    } catch {
      decodeError = KeyboardStore.describe(error)
      repeatCount = 0
      steps = []
      mode = .raw
    }
  }
}

private struct MacroStepRow: View {
  @Binding var step: MacroStepDraft
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Picker("Step type", selection: kindBinding) {
        ForEach(MacroStepKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .labelsHidden()
      .accessibilityLabel("Step type")

      switch step.kind {
      case .key:
        Picker("Key", selection: $step.code) {
          ForEach(keyChoices) { choice in
            Text(choice.name).tag(choice.id)
          }
        }
        .labelsHidden()
        .accessibilityLabel("Key code")
      case .mouseButton:
        Picker("Mouse button", selection: $step.code) {
          ForEach(mouseChoices) { choice in
            Text(choice.name).tag(choice.id)
          }
        }
        .labelsHidden()
        .accessibilityLabel("Mouse button")
      case .mouseMove:
        Stepper(
          value: Binding(
            get: { Int(step.dx) },
            set: { step.dx = Int8(clamping: max(-128, min(127, $0))) }
          ), in: -128...127
        ) {
          Text("dx \(step.dx)")
            .monospacedDigit()
        }
        .accessibilityLabel("Horizontal movement")

        Stepper(
          value: Binding(
            get: { Int(step.dy) },
            set: { step.dy = Int8(clamping: max(-128, min(127, $0))) }
          ), in: -128...127
        ) {
          Text("dy \(step.dy)")
            .monospacedDigit()
        }
        .accessibilityLabel("Vertical movement")
      }

      if step.kind != .mouseMove {
        Toggle("Press", isOn: $step.pressed)
          .accessibilityLabel("Pressed")
      }

      TextField(
        "Delay",
        value: Binding(
          get: { Int(step.delay) },
          set: { value in
            let maximum = step.kind == .mouseMove ? 255 : 65535
            step.delay = UInt16(clamping: max(0, min(maximum, value)))
          }
        ), format: .number
      )
      .accessibilityLabel("Delay in milliseconds")

      Text("ms")
        .foregroundStyle(.secondary)

      Spacer(minLength: 4)

      Button(role: .destructive) {
        onRemove()
      } label: {
        Image(systemName: "trash")
      }
      .accessibilityLabel("Remove step")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }

  private var kindBinding: Binding<MacroStepKind> {
    Binding(
      get: { step.kind },
      set: { newKind in
        step.kind = newKind
        switch newKind {
        case .key:
          if step.code < 0x04 || step.code > 0xEF {
            step.code = 0x04
          }
        case .mouseButton:
          step.code = 0xF0
        case .mouseMove:
          step.code = 0xF9
          step.pressed = false
          step.delay = min(step.delay, 255)
        }
      }
    )
  }

  private var keyChoices: [KeyCodeOption] {
    var choices = KeyNames.keyboard
      .map { KeyCodeOption(id: $0.key, name: $0.value) }
      .sorted { $0.id < $1.id }
    if !choices.contains(where: { $0.id == step.code }) {
      choices.append(KeyCodeOption(id: step.code, name: KeyNames.keyboardName(step.code)))
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
}
