import MK750Kit
import SwiftUI

struct LightingView: View {
  @ObservedObject var store: KeyboardStore

  @State private var focusMinutes = 25
  @State private var sceneName = ""
  @State private var saveError: String?
  @State private var showSaveScene = false
  @State private var sceneToDelete: NamedScene?
  @State private var showDeleteConfirmation = false
  @State private var showReference = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        scenesSection
        channelSection
        focusSection
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .frame(maxWidth: 1040, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showSaveScene) {
      saveSceneSheet
    }
    .alert(
      "Delete Scene?",
      isPresented: $showDeleteConfirmation,
      presenting: sceneToDelete
    ) { scene in
      Button("Delete", role: .destructive) {
        _ = store.deleteScene(scene)
        sceneToDelete = nil
      }
      Button("Cancel", role: .cancel) {
        sceneToDelete = nil
      }
    } message: { scene in
      Text("Remove \"\(scene.name)\" from Scenes.json. Lighting on the keyboard is unchanged.")
    }
  }

  // MARK: Scenes

  private var scenesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Scenes")
          .font(.headline)

        Button {
          showReference = true
        } label: {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("About lighting modes")
        .popover(isPresented: $showReference, arrowEdge: .bottom) {
          referencePopover
        }

        Spacer(minLength: 8)

        Button {
          beginSaveScene()
        } label: {
          Label("Save Scene", systemImage: "plus")
        }
        .disabled(store.snapshot == nil || store.isBusy || store.focus != nil)
        .help("Save the current lighting as a scene")
      }

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
        alignment: .leading,
        spacing: 10
      ) {
        ForEach(store.quickScenes) { scene in
          sceneTile(scene)
        }
      }
      .accessibilityLabel("Scenes")
    }
  }

  private func sceneTile(_ scene: NamedScene) -> some View {
    let builtIn = isBuiltIn(scene)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 4) {
        Text(scene.name)
          .font(.callout.weight(.medium))
          .lineLimit(1)

        Spacer(minLength: 2)

        if !builtIn {
          Button {
            sceneToDelete = scene
            showDeleteConfirmation = true
          } label: {
            Image(systemName: "trash")
              .foregroundStyle(.secondary)
          }
          .disabled(store.isBusy)
          .accessibilityLabel("Delete scene \(scene.name)")
          .help("Delete scene")
        }
      }

      HStack(spacing: 8) {
        SceneDot(title: "Backlight", state: scene.main, channel: .main)
        SceneDot(title: "Side", state: scene.side, channel: .side)
      }

      Button("Apply") {
        Task { await store.applyScene(scene) }
      }
      .disabled(store.snapshot == nil || store.isBusy || store.focus != nil)
      .accessibilityLabel("Apply scene \(scene.name)")
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .contextMenu {
      if !builtIn {
        Button("Delete Scene…", role: .destructive) {
          sceneToDelete = scene
          showDeleteConfirmation = true
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func isBuiltIn(_ scene: NamedScene) -> Bool {
    KeyboardStore.builtInScenes.contains { $0.id == scene.id }
  }

  private var referencePopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Lighting reference")
        .font(.headline)
        .foregroundStyle(.primary)
      Text(
        "Mode names and most effects come from the protocol reference. Some effects depend on firmware."
      )
      Text(
        "Speed 0 to 5 and brightness 0 to 4 are reference ranges. Backlight speed is a wire index; many patterns invert the host scale."
      )
      Text(
        "Apply writes the state and reads it back. Use Device options for a true backlight off."
      )
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 280, alignment: .leading)
    .padding(14)
  }

  // MARK: Channels

  private var channelSection: some View {
    HStack(alignment: .top, spacing: 16) {
      LightingEditorView(store: store, channel: .main)
      LightingEditorView(store: store, channel: .side)
    }
  }

  // MARK: Focus

  @ViewBuilder
  private var focusSection: some View {
    if !store.hasPendingFocusRestore {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Image(systemName: "timer")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("Focus")
            .font(.callout.weight(.medium))

          if let focus = store.focus, focus.status == .active {
            Text(store.focusCountdownText)
              .font(.callout.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityLabel("Focus time remaining \(store.focusCountdownText)")

            Button("Finish") {
              Task { await store.restoreFocus() }
            }
            .disabled(store.isBusy)
            .help("Restore the lighting saved when focus started")
          } else {
            Stepper(value: $focusMinutes, in: 5...600, step: 5) {
              Text("\(focusMinutes) min")
                .monospacedDigit()
            }
            .accessibilityLabel("Focus duration")
            .accessibilityValue("\(focusMinutes) minutes")

            Button("Start") {
              Task { await store.startFocus(minutes: focusMinutes) }
            }
            .disabled(store.snapshot == nil || store.isBusy)
          }

          Spacer(minLength: 0)
        }

        Text("Restores your lighting when finished.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 10)
      )
    }
  }

  // MARK: Save scene sheet

  private var saveSceneSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Save Scene")
        .font(.title3.weight(.semibold))

      TextField("Name", text: $sceneName)
        .textFieldStyle(.roundedBorder)

      if let saveError {
        Text(saveError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack(spacing: 8) {
        Spacer(minLength: 8)
        Button("Cancel", role: .cancel) {
          showSaveScene = false
        }
        .keyboardShortcut(.cancelAction)
        Button("Save", role: .confirm) {
          saveScene()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
  }

  private func beginSaveScene() {
    sceneName = ""
    saveError = nil
    showSaveScene = true
  }

  private func saveScene() {
    let name = sceneName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    if store.saveScene(named: name) {
      showSaveScene = false
      sceneName = ""
      saveError = nil
    } else {
      saveError = store.notice?.message ?? "The scene could not be saved."
    }
  }
}

private struct SceneDot: View {
  let title: String
  let state: LightState
  let channel: LightChannel

  var body: some View {
    HStack(spacing: 3) {
      Circle()
        .fill(RGB(red: state.red, green: state.green, blue: state.blue).color)
        .frame(width: 9, height: 9)
        .overlay(
          Circle()
            .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(title) \(RGB(red: state.red, green: state.green, blue: state.blue).hexString), \(LightingModes.name(for: state.mode, channel: channel))"
    )
  }
}

// MARK: - Independent channel editor

struct LightingEditorView: View {
  @ObservedObject var store: KeyboardStore
  let channel: LightChannel

  @State private var draft = LightDraft(
    state: LightState(mode: 1, speed: 0, brightness: 2, flags: 0x07, red: 255, green: 176, blue: 96)
  )
  @State private var hexText = "#FFB060"
  @State private var hexError: String?
  @State private var rawFlagsText = "07"
  @State private var flagsError: String?
  @State private var edited = false
  @State private var showAdvanced = false

  private var controlsDisabled: Bool {
    store.snapshot == nil || store.isBusy || store.focus != nil
  }

  private var hasPendingChanges: Bool {
    guard let snapshot = store.snapshot else { return false }
    let current = channel.isMain ? snapshot.main : snapshot.side
    guard let typedRGB = RGB(hex: hexText) else { return true }
    guard let flagBytes = Hex.parse(rawFlagsText), flagBytes.count == 1 else { return true }
    let typedFlags = flagBytes[0]
    return draft.mode != current.mode
      || draft.speed != current.speed
      || draft.brightness != current.brightness
      || typedFlags != current.flags
      || typedRGB.red != current.red
      || typedRGB.green != current.green
      || typedRGB.blue != current.blue
  }

  private var modeChoices: [LightingMode] {
    var modes = LightingModes.modes(for: channel)
    if !modes.contains(where: { $0.id == draft.mode }) {
      modes.append(LightingMode(id: draft.mode, name: "Mode \(draft.mode) (unlisted)"))
    }
    return modes
  }

  private var flagChoices: [FlagOption] {
    var choices = FlagOptions.all
    if !choices.contains(where: { $0.id == draft.lowFlag }) {
      choices.append(FlagOption(id: draft.lowFlag, name: FlagOptions.name(for: draft.lowFlag)))
    }
    return choices
  }

  private var modeBinding: Binding<UInt8> {
    Binding(
      get: { draft.mode },
      set: { value in
        draft.mode = value
        edited = true
      }
    )
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { draft.rgb.color },
      set: { value in
        draft.rgb = RGB(color: value)
        hexText = draft.rgb.hexString
        hexError = nil
        edited = true
      }
    )
  }

  private var brightnessBinding: Binding<Double> {
    Binding(
      get: { Double(draft.brightness) },
      set: { value in
        draft.brightness = UInt8(value.rounded())
        edited = true
      }
    )
  }

  private var speedBinding: Binding<Double> {
    Binding(
      get: { Double(draft.speed) },
      set: { value in
        draft.speed = UInt8(value.rounded())
        edited = true
      }
    )
  }

  private var lowFlagBinding: Binding<Int> {
    Binding(
      get: { Int(draft.lowFlag) },
      set: { value in
        draft.setLowFlag(UInt8(value))
        edited = true
      }
    )
  }

  private var optionBinding: Binding<Int> {
    Binding(
      get: { Int(draft.optionNibble) },
      set: { value in
        draft.setOptionNibble(UInt8(value))
        edited = true
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      form
      advanced

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Revert") {
          load()
        }
        .disabled(controlsDisabled || !hasPendingChanges)
        .help("Discard changes and reload the keyboard state")

        Button("Apply") {
          apply()
        }
        .disabled(controlsDisabled || !hasPendingChanges)
        .help("Write \(channel.displayName.lowercased()) lighting")
        .accessibilityLabel("Apply \(channel.displayName.lowercased()) lighting")
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .onAppear(perform: load)
    .onChange(of: store.snapshotRevision) { _, _ in
      if !edited {
        load()
      }
    }
    .onChange(of: store.focus?.status) { _, _ in
      load()
    }
  }

  private var header: some View {
    HStack(spacing: 7) {
      Image(systemName: channel.isMain ? "keyboard" : "light.max")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(channel.displayName)
        .font(.headline)
      if store.focus != nil {
        Image(systemName: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("Lighting is locked while a focus session is active.")
          .accessibilityLabel("Lighting locked during focus")
      }
      if store.snapshot == nil {
        Text("Not loaded")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Mode")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 82, alignment: .leading)

        Picker("Mode", selection: modeBinding) {
          ForEach(modeChoices) { mode in
            Text(mode.name).tag(mode.id)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel("\(channel.displayName) mode")

        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Text("Color")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 82, alignment: .leading)

        ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
          .labelsHidden()
          .accessibilityLabel("\(channel.displayName) color")

        TextField("#RRGGBB", text: $hexText)
          .textFieldStyle(.roundedBorder)
          .font(.callout.monospaced())
          .onSubmit(applyHex)
          .onChange(of: hexText) { _, text in
            if let rgb = RGB(hex: text) {
              hexError = nil
              if rgb != draft.rgb {
                edited = true
              }
            } else {
              edited = true
            }
          }
          .accessibilityLabel("\(channel.displayName) color hex value")

        Spacer(minLength: 0)
      }

      if let hexError {
        Text(hexError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      HStack(spacing: 8) {
        Text("Brightness")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 82, alignment: .leading)

        Slider(value: brightnessBinding, in: 0...4, step: 1) {
          Text("\(channel.displayName) brightness")
        }
        .labelsHidden()
        .accessibilityLabel("\(channel.displayName) brightness")
        .accessibilityValue("\(draft.brightness) of 4")
        .help("Brightness 0 to 4")

        Text("\(draft.brightness)/4")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 32, alignment: .trailing)
      }

      HStack(spacing: 8) {
        Text("Speed")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 82, alignment: .leading)

        Slider(value: speedBinding, in: 0...5, step: 1) {
          Text("\(channel.displayName) speed")
        }
        .labelsHidden()
        .accessibilityLabel("\(channel.displayName) speed")
        .accessibilityValue("\(draft.speed) of 5")
        .help("Wire speed index 0 to 5")

        Text("\(draft.speed)/5")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 32, alignment: .trailing)
      }
    }
    .disabled(controlsDisabled)
  }

  private var advanced: some View {
    DisclosureGroup(isExpanded: $showAdvanced) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Text("Color mode")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 82, alignment: .leading)

          Picker("Color mode", selection: lowFlagBinding) {
            ForEach(flagChoices) { flag in
              Text(flag.name).tag(Int(flag.id))
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .accessibilityLabel("\(channel.displayName) color mode flag")

          Spacer(minLength: 0)
        }

        HStack(spacing: 8) {
          Stepper(value: optionBinding, in: 0...15) {
            Text("Option \(draft.optionNibble)")
              .monospacedDigit()
          }
          .accessibilityLabel("\(channel.displayName) mode option nibble")

          Spacer(minLength: 8)

          TextField("Flags", text: $rawFlagsText)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .onChange(of: rawFlagsText) { _, text in
              if let bytes = Hex.parse(text), bytes.count == 1 {
                if bytes[0] != draft.flags {
                  edited = true
                }
              } else {
                edited = true
              }
            }
            .accessibilityLabel("\(channel.displayName) raw flags byte in hexadecimal")
            .help("Full flags byte; Apply writes it")

          Text(String(format: "0x%02X", draft.flags))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }

        if let flagsError {
          Text(flagsError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        Text("Unused option bits are preserved until changed.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 2)
      .disabled(controlsDisabled)
    } label: {
      Text("Advanced")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .onChange(of: draft.flags) { _, flags in
      rawFlagsText = String(format: "%02X", flags)
      flagsError = nil
    }
  }

  private func load() {
    guard let snapshot = store.snapshot else { return }
    let state = channel.isMain ? snapshot.main : snapshot.side
    draft = LightDraft(state: state)
    hexText = draft.rgb.hexString
    rawFlagsText = String(format: "%02X", draft.flags)
    hexError = nil
    flagsError = nil
    edited = false
  }

  private func applyHex() {
    if let rgb = RGB(hex: hexText) {
      draft.rgb = rgb
      hexText = rgb.hexString
      hexError = nil
      edited = true
    } else {
      hexError = "Enter six hexadecimal digits, for example #FFA860."
    }
  }

  private func apply() {
    guard commitTextFields() else { return }
    Task {
      if await store.applyLight(draft.state, channel: channel) {
        edited = false
        load()
      }
    }
  }

  private func commitTextFields() -> Bool {
    guard let rgb = RGB(hex: hexText) else {
      hexError = "Enter six hexadecimal digits, for example #FFA860."
      return false
    }
    guard let bytes = Hex.parse(rawFlagsText), bytes.count == 1 else {
      flagsError = "Enter one hexadecimal byte, for example 07."
      return false
    }
    draft.rgb = rgb
    draft.flags = bytes[0]
    hexError = nil
    flagsError = nil
    return true
  }
}
