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
  @State private var selectedSceneID = KeyboardStore.builtInScenes.first?.id
  @State private var selectedChannel: LightChannel = .main
  @State private var mainText = ChannelTextState()
  @State private var sideText = ChannelTextState()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if store.snapshot == nil {
          KeyboardConnectionCard(store: store)
        }

        scenesSection

        if store.snapshot != nil {
          channelSection
        }

        if store.snapshot != nil {
          focusSection
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .frame(maxWidth: 900, alignment: .leading)
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
        if store.deleteScene(scene), selectedSceneID == scene.id {
          selectedSceneID = KeyboardStore.builtInScenes.first?.id
        }
        sceneToDelete = nil
      }
      Button("Cancel", role: .cancel) {
        sceneToDelete = nil
      }
    } message: { scene in
      Text("Remove “\(scene.name)” from Scenes.json. The keyboard lighting is unchanged.")
    }
  }

  // MARK: Scenes

  private var selectedScene: NamedScene? {
    guard let id = selectedSceneID else { return nil }
    return store.quickScenes.first { $0.id == id }
  }

  private var isConnected: Bool {
    store.snapshot != nil && store.connection == .connected
  }

  private var canApplyNonLiveAction: Bool {
    isConnected
      && store.focus == nil
      && !store.isBusy
      && store.acceptsLiveEdits
  }

  private var sceneSectionDescription: String {
    if store.focus != nil {
      return "Lighting is locked during focus. Finish the session to apply a scene."
    }
    if isConnected {
      return "Choose a scene to apply it."
    }
    return "Choose a scene to preview it. Scenes are stored on this Mac."
  }

  private var saveSceneHelp: String {
    if !isConnected {
      return "Connect the MK750 to save its current lighting as a scene."
    }
    if store.focus != nil {
      return "Finish or restore the focus session before saving a scene."
    }
    if store.isBusy {
      return "Wait for the current operation to finish."
    }
    guard store.acceptsLiveEdits else { return "Lighting control is not available right now." }
    return "Save the lighting currently on the keyboard as a scene."
  }

  private func sceneCardHelp(_ scene: NamedScene) -> String {
    guard isConnected else { return "Preview \(scene.name)." }
    if store.focus != nil {
      return "Finish or restore the focus session before applying a scene."
    }
    if store.isBusy {
      return "Wait for the current operation to finish."
    }
    guard store.acceptsLiveEdits else { return "Lighting control is not available right now." }
    return "Apply \(scene.name) to the keyboard."
  }

  private var sceneCardHint: String {
    isConnected
      ? "Applies the scene to the keyboard."
      : "Shows a preview. No lighting is changed."
  }

  private func activate(_ scene: NamedScene) {
    guard isConnected else {
      selectedSceneID = scene.id
      return
    }
    guard canApplyNonLiveAction else { return }
    Task { await store.applyScene(scene) }
  }

  private var scenesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Scenes")
          .font(.title3.weight(.semibold))

        Button {
          showReference = true
        } label: {
          Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("About scenes and lighting")
        .help("About scenes and lighting")
        .popover(isPresented: $showReference, arrowEdge: .bottom) {
          referencePopover
        }

        Spacer(minLength: 8)

        if isConnected {
          Button { beginSaveScene() } label: {
            Label("Save Scene", systemImage: "plus")
          }
          .disabled(!canApplyNonLiveAction)
          .help(saveSceneHelp)
        }
      }

      Text(sceneSectionDescription)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      LazyVGrid(
        columns: [
          GridItem(.adaptive(minimum: 172, maximum: 260), spacing: 12, alignment: .top)
        ],
        alignment: .leading,
        spacing: 12
      ) {
        ForEach(store.quickScenes) { scene in
          Button {
            activate(scene)
          } label: {
            SceneCard(
              scene: scene,
              isSelected: !isConnected && selectedSceneID == scene.id,
              matchesHardware: sceneMatchesHardware(scene)
            )
          }
          .buttonStyle(.plain)
          .disabled(isConnected && !canApplyNonLiveAction)
          .accessibilityLabel(sceneAccessibilityLabel(scene))
          .accessibilityValue(
            !isConnected && selectedSceneID == scene.id ? "Selected for preview" : ""
          )
          .accessibilityHint(sceneCardHint)
          .help(sceneCardHelp(scene))
          .contextMenu {
            if !isBuiltIn(scene) {
              Button("Delete Scene…", role: .destructive) {
                sceneToDelete = scene
                showDeleteConfirmation = true
              }
            }
          }
        }
      }
      .accessibilityLabel("Scenes")

      if !isConnected {
        offlineScenePreview
      }
    }
  }

  private var offlineScenePreview: some View {
    GroupBox {
      if let scene = selectedScene {
        VStack(alignment: .leading, spacing: 10) {
          Text(scene.name)
            .font(.headline)

          LazyVGrid(
            columns: [
              GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)
            ],
            alignment: .leading,
            spacing: 10
          ) {
            SceneChannelDetail(channel: .main, state: scene.main)
            SceneChannelDetail(channel: .side, state: scene.side)
          }

          if !isBuiltIn(scene) {
            Button(role: .destructive) {
              sceneToDelete = scene
              showDeleteConfirmation = true
            } label: {
              Label("Delete Scene…", systemImage: "trash")
            }
            .help("Remove this scene from Scenes.json")
          }
        }
        .padding(.top, 4)
      } else {
        Text("Select a scene to preview its colors and mode.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } label: {
      Label("Scene Preview", systemImage: "eye")
    }
  }

  private func sceneMatchesHardware(_ scene: NamedScene) -> Bool {
    guard isConnected else { return false }
    guard let main = currentLight(.main), let side = currentLight(.side) else { return false }
    return scene.main == main && scene.side == side
  }

  private func sceneAccessibilityLabel(_ scene: NamedScene) -> String {
    let action = isConnected ? "Apply scene" : "Preview scene"
    let main =
      "backlight \(LightingModes.name(for: scene.main.mode, channel: .main)), "
      + "\(RGB(red: scene.main.red, green: scene.main.green, blue: scene.main.blue).hexString), "
      + "brightness \(scene.main.brightness) of 4"
    let side =
      "side light \(LightingModes.name(for: scene.side.mode, channel: .side)), "
      + "\(RGB(red: scene.side.red, green: scene.side.green, blue: scene.side.blue).hexString), "
      + "brightness \(scene.side.brightness) of 4"
    let match = sceneMatchesHardware(scene) ? ", matches the keyboard" : ""
    return "\(action) \(scene.name), \(main), \(side)\(match)"
  }

  private func isBuiltIn(_ scene: NamedScene) -> Bool {
    KeyboardStore.builtInScenes.contains { $0.id == scene.id }
  }

  private var referencePopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Lighting reference")
        .font(.headline)
        .foregroundStyle(.primary)

      Text(
        "Scenes store both lights. With a keyboard connected, clicking a scene applies it and reads both lights back."
      )
      Text(
        "Backlight and side light edit independently and write live as you adjust them. Invalid color hex stays in the field and is not sent."
      )
      Text(
        "Mode names and most effects come from the protocol reference. Some effects depend on firmware."
      )
      Text(
        "Speed 0 to 5 and brightness 0 to 4 are reference ranges. Backlight speed is a wire index; many patterns invert the host scale."
      )
      Text(
        "Use Device options for a true backlight off."
      )
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 300, alignment: .leading)
    .padding(14)
  }

  // MARK: Channels

  private var channelSelection: Binding<String> {
    Binding(
      get: { selectedChannel.rawValue },
      set: { rawValue in
        if let channel = LightChannel(rawValue: rawValue) {
          selectedChannel = channel
        }
      }
    )
  }

  private var selectedTextState: Binding<ChannelTextState> {
    selectedChannel == .main ? $mainText : $sideText
  }

  private var channelSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Channels")
        .font(.title3.weight(.semibold))

      Text("Backlight and side light are independent. Changes write live.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Channel", selection: channelSelection) {
        ForEach(LightChannel.allCases, id: \.rawValue) { channel in
          Text(channel.displayName).tag(channel.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("Lighting channel to edit")

      if store.focus != nil, !store.hasPendingFocusRestore {
        focusLockBanner
      }

      LightingEditorView(
        store: store,
        channel: selectedChannel,
        textState: selectedTextState
      )
      .id(selectedChannel.rawValue)
    }
  }

  private func currentLight(_ channel: LightChannel) -> LightState? {
    if let live = store.liveLight(for: channel) {
      return live
    }
    guard let snapshot = store.snapshot else { return nil }
    return channel.isMain ? snapshot.main : snapshot.side
  }

  private var focusLockBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "lock.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text("Lighting is locked during focus")
          .font(.callout.weight(.medium))
        Text("Finish the session to edit the keyboard again.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      Button("Finish & Restore") {
        Task { await store.restoreFocus() }
      }
      .disabled(
        store.isBusy || store.snapshot == nil || store.connection != .connected
      )
      .help("Restore the lighting saved when focus started")
    }
    .padding(10)
    .background(
      Color.orange.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 8)
    )
  }

  // MARK: Focus

  @ViewBuilder
  private var focusSection: some View {
    if !store.hasPendingFocusRestore {
      GroupBox {
        if let focus = store.focus, focus.status == .active {
          HStack(alignment: .top, spacing: 12) {
            Text("Saved lighting returns when the timer ends, or when you choose Finish & Restore above.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Text(store.focusCountdownText)
              .font(.title3.monospacedDigit())
              .accessibilityLabel("Focus time remaining \(store.focusCountdownText)")
          }
        } else {
          VStack(alignment: .leading, spacing: 10) {
            Text(
              "Save the current lighting, apply calm lighting, and lock channel edits until the timer ends."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
              Stepper(value: $focusMinutes, in: 5...600, step: 5) {
                Text("\(focusMinutes) min")
                  .monospacedDigit()
              }
              .accessibilityLabel("Focus duration")
              .accessibilityValue("\(focusMinutes) minutes")

              Button("Start Focus") {
                Task { await store.startFocus(minutes: focusMinutes) }
              }
              .disabled(!canApplyNonLiveAction)
              .help("Saves the current lighting and applies calm lighting.")

              Spacer(minLength: 0)
            }
          }
        }
      } label: {
        Label("Focus", systemImage: "timer")
      }
    }
  }

  // MARK: Save scene sheet

  private var saveSceneSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Save Scene")
        .font(.title3.weight(.semibold))

      Text("Saves the lighting currently on the keyboard as a new scene.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

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
    .frame(width: 380)
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
      selectedSceneID = store.customScenes.last?.id
      showSaveScene = false
      sceneName = ""
      saveError = nil
    } else {
      saveError = store.notice?.message ?? "The scene could not be saved."
    }
  }
}

// MARK: - Scene cards

private struct SceneCard: View {
  let scene: NamedScene
  let isSelected: Bool
  let matchesHardware: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(scene.name)
          .font(.callout.weight(.semibold))
          .lineLimit(2)
          .multilineTextAlignment(.leading)

        Spacer(minLength: 0)

        if matchesHardware {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .accessibilityLabel("Matches the lighting on the keyboard")
            .help("Matches the lighting on the keyboard")
        }
      }

      HStack(spacing: 4) {
        SceneSwatch(channel: .main, state: scene.main)
        SceneSwatch(channel: .side, state: scene.side)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      isSelected
        ? Color.accentColor.opacity(0.10)
        : Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isSelected ? 2 : 1
        )
    )
    .contentShape(RoundedRectangle(cornerRadius: 10))
  }
}

private struct SceneSwatch: View {
  let channel: LightChannel
  let state: LightState

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      RoundedRectangle(cornerRadius: 4)
        .fill(RGB(red: state.red, green: state.green, blue: state.blue).color)
        .frame(height: 26)
        .overlay {
          RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary)
        }
      Text(channel.isMain ? "Backlight" : (state.mode == 0 ? "Side · Off" : "Side"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityHidden(true) // The scene button describes both channels.
  }
}

private struct SceneChannelDetail: View {
  let channel: LightChannel
  let state: LightState

  private var hex: String {
    RGB(red: state.red, green: state.green, blue: state.blue).hexString
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Circle()
          .fill(RGB(red: state.red, green: state.green, blue: state.blue).color)
          .frame(width: 12, height: 12)
          .overlay(
            Circle()
              .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
          )
          .accessibilityHidden(true)

        Text(channel.displayName)
          .font(.callout.weight(.medium))
      }

      Text("\(LightingModes.name(for: state.mode, channel: channel)) · \(hex)")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text("Brightness \(state.brightness)/4 · Speed \(state.speed)/5")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(channel.displayName): \(LightingModes.name(for: state.mode, channel: channel)), color \(hex), brightness \(state.brightness) of 4, speed \(state.speed) of 5"
    )
  }
}

// MARK: - Independent channel editor

private struct ChannelTextState {
  var hexText = ""
  var rawFlagsText = ""
  var hexError: String?
  var flagsError: String?
  var showAdvanced = false
  var seeded = false
}

private struct LightingEditorView: View {
  @ObservedObject var store: KeyboardStore
  let channel: LightChannel
  @Binding var textState: ChannelTextState

  private var projected: LightState? {
    if let live = store.liveLight(for: channel) {
      return live
    }
    guard let snapshot = store.snapshot else { return nil }
    return channel.isMain ? snapshot.main : snapshot.side
  }

  private var locked: Bool {
    !store.acceptsLiveEdits || store.focus != nil
  }

  private var optionNibble: Int {
    Int((projected?.flags ?? 0) >> 4)
  }

  private var modeChoices: [LightingMode] {
    var modes = LightingModes.modes(for: channel)
    if let mode = projected?.mode, !modes.contains(where: { $0.id == mode }) {
      modes.append(LightingMode(id: mode, name: "Mode \(mode) (unlisted)"))
    }
    return modes
  }

  private var flagChoices: [FlagOption] {
    var choices = FlagOptions.all
    if let flags = projected?.flags {
      let low = flags & 0x0F
      if !choices.contains(where: { $0.id == low }) {
        choices.append(FlagOption(id: low, name: FlagOptions.name(for: low)))
      }
    }
    return choices
  }

  private var modeBinding: Binding<UInt8> {
    Binding(
      get: { projected?.mode ?? 1 },
      set: { value in
        guard var state = projected, state.mode != value else { return }
        state.mode = value
        write(state)
      }
    )
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: {
        guard let state = projected else { return Color.clear }
        return RGB(red: state.red, green: state.green, blue: state.blue).color
      },
      set: { value in
        guard var state = projected else { return }
        let rgb = RGB(color: value)
        guard
          rgb.red != state.red || rgb.green != state.green || rgb.blue != state.blue
        else { return }
        state.red = rgb.red
        state.green = rgb.green
        state.blue = rgb.blue
        write(state)
        textState.hexText = rgb.hexString
        textState.hexError = nil
      }
    )
  }

  private var brightnessBinding: Binding<Double> {
    Binding(
      get: { Double(projected?.brightness ?? 0) },
      set: { value in
        let brightness = UInt8(value.rounded())
        guard var state = projected, state.brightness != brightness else { return }
        state.brightness = brightness
        write(state)
      }
    )
  }

  private var speedBinding: Binding<Double> {
    Binding(
      get: { Double(projected?.speed ?? 0) },
      set: { value in
        let speed = UInt8(value.rounded())
        guard var state = projected, state.speed != speed else { return }
        state.speed = speed
        write(state)
      }
    )
  }

  private var lowFlagBinding: Binding<Int> {
    Binding(
      get: { Int((projected?.flags ?? 0) & 0x0F) },
      set: { value in
        guard var state = projected else { return }
        let flags = (state.flags & 0xF0) | (UInt8(value) & 0x0F)
        guard state.flags != flags else { return }
        state.flags = flags
        write(state)
      }
    )
  }

  private var optionBinding: Binding<Int> {
    Binding(
      get: { optionNibble },
      set: { value in
        guard var state = projected else { return }
        let flags = (state.flags & 0x0F) | ((UInt8(value) & 0x0F) << 4)
        guard state.flags != flags else { return }
        state.flags = flags
        write(state)
      }
    )
  }

  private var hexTextBinding: Binding<String> {
    Binding(
      get: { textState.hexText },
      set: { value in
        guard value != textState.hexText else { return }
        textState.hexText = value
        textState.hexError = nil
        guard !locked, let rgb = RGB(hex: value) else { return }
        commitHexValue(rgb)
      }
    )
  }

  private var rawFlagsTextBinding: Binding<String> {
    Binding(
      get: { textState.rawFlagsText },
      set: { value in
        guard value != textState.rawFlagsText else { return }
        textState.rawFlagsText = value
        textState.flagsError = nil
        guard !locked, let byte = completeHexByte(value) else { return }
        guard var state = projected, state.flags != byte else { return }
        state.flags = byte
        write(state)
      }
    )
  }

  private var hexHint: String? {
    let trimmed = textState.hexText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, RGB(hex: trimmed) == nil else { return nil }
    return "Not applied. Enter six hexadecimal digits."
  }

  private var flagsHint: String? {
    let trimmed = textState.rawFlagsText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, completeHexByte(trimmed) == nil else { return nil }
    return "Not applied. Enter two hexadecimal digits."
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      form
      advanced
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .onAppear {
      guard let state = projected else { return }
      syncText(with: state, force: !textState.seeded)
    }
    .onChange(of: projected) { _, state in
      guard let state = state else { return }
      syncText(with: state, force: !textState.seeded)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: channel.isMain ? "keyboard" : "light.max")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      Text(channel.displayName)
        .font(.headline)

      if locked {
        Label(store.focus != nil ? "Locked" : "Unavailable", systemImage: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(
            store.focus != nil
              ? "Lighting is locked while a focus session is active."
              : "Editing is unavailable until the keyboard is ready."
          )
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

        TextField("#RRGGBB", text: hexTextBinding)
          .textFieldStyle(.roundedBorder)
          .font(.callout.monospaced())
          .frame(width: 110)
          .onSubmit(applyHex)
          .accessibilityLabel("\(channel.displayName) color hex value")

        Spacer(minLength: 0)
      }

      hexFeedback

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
        .accessibilityValue("\(projected?.brightness ?? 0) of 4")
        .help("Brightness 0 to 4")

        Text("\(projected?.brightness ?? 0)/4")
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
        .accessibilityValue("\(projected?.speed ?? 0) of 5")
        .help("Wire speed index 0 to 5")

        Text("\(projected?.speed ?? 0)/5")
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 32, alignment: .trailing)
      }
    }
    .disabled(locked)
  }

  @ViewBuilder
  private var hexFeedback: some View {
    if let error = textState.hexError {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    } else if let hint = hexHint {
      Text(hint)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var flagsFeedback: some View {
    if let error = textState.flagsError {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    } else if let hint = flagsHint {
      Text(hint)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var advanced: some View {
    DisclosureGroup(isExpanded: $textState.showAdvanced) {
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
            Text("Option \(optionNibble)")
              .monospacedDigit()
          }
          .accessibilityLabel("\(channel.displayName) mode option nibble")

          Spacer(minLength: 8)

          TextField("Flags", text: rawFlagsTextBinding)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(width: 72)
            .onSubmit(commitFlags)
            .accessibilityLabel("\(channel.displayName) raw flags byte in hexadecimal")
            .help(
              "Two hexadecimal digits. A complete value writes immediately; a partial value stays local."
            )
        }

        flagsFeedback

        Text(
          "Current flag byte \(String(format: "0x%02X", projected?.flags ?? 0)). Unknown option bits are preserved."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 2)
      .disabled(locked)
    } label: {
      Text("Advanced")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func write(_ state: LightState) {
    guard !locked else { return }
    store.updateLight(state, channel: channel)
  }

  private func syncText(with state: LightState, force: Bool) {
    let hex = RGB(red: state.red, green: state.green, blue: state.blue).hexString
    if force || textState.hexText.isEmpty || RGB(hex: textState.hexText) != nil {
      if textState.hexText != hex {
        textState.hexText = hex
      }
      textState.hexError = nil
    }

    let flags = String(format: "%02X", state.flags)
    if force || textState.rawFlagsText.isEmpty
      || completeHexByte(textState.rawFlagsText) != nil
    {
      if textState.rawFlagsText != flags {
        textState.rawFlagsText = flags
      }
      textState.flagsError = nil
    }

    textState.seeded = true
  }

  private func applyHex() {
    guard let rgb = RGB(hex: textState.hexText) else {
      textState.hexError = "Enter six hexadecimal digits, for example #FFA860."
      return
    }
    textState.hexError = nil
    textState.hexText = rgb.hexString
    commitHexValue(rgb)
  }

  private func commitHexValue(_ rgb: RGB) {
    guard var state = projected else { return }
    guard
      rgb.red != state.red || rgb.green != state.green || rgb.blue != state.blue
    else { return }
    state.red = rgb.red
    state.green = rgb.green
    state.blue = rgb.blue
    write(state)
  }

  private func commitFlags() {
    guard !locked else { return }
    var value = textState.rawFlagsText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if value.hasPrefix("0x") {
      value.removeFirst(2)
    }
    guard !value.isEmpty, value.count <= 2, let byte = UInt8(value, radix: 16) else {
      textState.flagsError = "Enter one or two hexadecimal digits, for example 07."
      return
    }
    textState.flagsError = nil
    let normalized = String(format: "%02X", byte)
    if textState.rawFlagsText != normalized {
      textState.rawFlagsText = normalized
    }
    guard var state = projected, state.flags != byte else { return }
    state.flags = byte
    write(state)
  }

  private func completeHexByte(_ text: String) -> UInt8? {
    var value = text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if value.hasPrefix("0x") {
      value.removeFirst(2)
    }
    guard value.count == 2, let byte = UInt8(value, radix: 16) else { return nil }
    return byte
  }
}
