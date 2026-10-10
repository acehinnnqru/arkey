import SwiftUI
import RimeEngine

/// S3 §4's palette decision and §5's feedback switches, as a screen.
///
/// The auxiliary prefix also updates the active Rime schema and deploys it. Other keyboard
/// preferences are shared through the app group and take effect when the keyboard next appears.
struct KeyboardSettingsView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var auxiliaryPrefixDraft = ","
  @State private var isLoading = true

  var body: some View {
    let _ = interfaceLocale
    List {
      if isLoading { ProgressView(RimeLocalization.text("Loading settings…")) }
      auxiliarySection
      compositionSection
      appearanceSection
      feedbackSection
      resetSection
      // The auxiliary prefix deploys; the other keyboard preferences need no deploy.
      Section {
        Label(RimeLocalization.text("Changing the auxiliary prefix deploys the Rime scheme; other keyboard settings apply next time it opens."), systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .disabled(isLoading)
    .navigationTitle(RimeLocalization.text("Keyboard"))
    .task {
      isLoading = true
      await model.refreshPreferences()
      auxiliaryPrefixDraft = model.keyboardPreferences.auxiliaryPrefix
      isLoading = false
    }
  }

  private var auxiliarySection: some View {
    Section {
      TextField(RimeLocalization.text("Auxiliary prefix"), text: Binding(
        get: { auxiliaryPrefixDraft },
        set: { value in
          // Typing beside the existing one-character value is a common way to replace it.
          // Treat that as a replacement instead of silently retaining an invalid two-character draft.
          let candidate: String
          if value.count == 2, value.hasPrefix(auxiliaryPrefixDraft) {
            candidate = String(value.suffix(1))
          } else if value.count == 2, value.hasSuffix(auxiliaryPrefixDraft) {
            candidate = String(value.prefix(1))
          } else {
            candidate = value
          }
          auxiliaryPrefixDraft = candidate
          if let prefix = RimeKeyboardPreferences.normalizedAuxiliaryPrefix(candidate) {
            model.setAuxiliaryPrefix(prefix)
            auxiliaryPrefixDraft = prefix
          }
        }))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
      if !auxiliaryPrefixDraft.isEmpty,
         RimeKeyboardPreferences.normalizedAuxiliaryPrefix(auxiliaryPrefixDraft) == nil {
        Text(RimeLocalization.text("Enter one special character"))
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Picker(RimeLocalization.text("Auxiliary spelling"), selection: Binding(
        get: { model.auxiliarySpelling },
        set: { value in model.setAuxiliarySpelling(value) })) {
        ForEach(RimeAuxiliarySpelling.allCases, id: \.self) { spelling in
          Text(spelling.label).tag(spelling)
        }
      }
      Picker(RimeLocalization.text("Position"), selection: Binding(
        get: { model.keyboardPreferences.auxiliaryKeySide },
        set: { value in model.updatePreferences { $0.auxiliaryKeySide = value } })) {
        Text(RimeLocalization.text("Left of Space")).tag(RimeKeyboardPreferences.AuxiliaryKeySide.left)
        Text(RimeLocalization.text("Right of Space")).tag(RimeKeyboardPreferences.AuxiliaryKeySide.right)
      }
    } header: {
      Text(RimeLocalization.text("Auxiliary key"))
    } footer: {
      Text(RimeLocalization.text("Enter one half-width special character. Full-width equivalents are converted automatically. The default is a comma to the right of Space. The prefix and spelling are saved to the current scheme and radical_pinyin, then deployed automatically. Choose the spelling you use; schemes share the same auxiliary rules."))
    }
  }

  private var compositionSection: some View {
    Section {
      Picker(RimeLocalization.text("Composition display"), selection: Binding(
        get: { model.keyboardPreferences.compositionDisplay },
        set: { value in model.updatePreferences { $0.compositionDisplay = value } })) {
        Text(RimeLocalization.text("Original keys")).tag(RimeKeyboardPreferences.CompositionDisplay.rawInput)
        Text(RimeLocalization.text("Schema output")).tag(RimeKeyboardPreferences.CompositionDisplay.preedit)
      }
    } header: {
      Text(RimeLocalization.text("Uncommitted text"))
    } footer: {
      Text(RimeLocalization.text("For Flypy input nihcaa, Original keys shows ni hc aa and Schema output shows ni hao a. Return commits nihcaa in either mode. Display spacing does not change candidate selection or deletion."))
    }
  }

  private var appearanceSection: some View {
    Section {
      Picker(RimeLocalization.text("Background"), selection: Binding(
        get: { model.keyboardPreferences.paletteMode },
        set: { mode in model.updatePreferences { $0.paletteMode = mode } })) {
        Text(RimeLocalization.text("Follow host (system material)")).tag(RimeKeyboardPreferences.PaletteMode.followHost)
        Text(RimeLocalization.text("Fixed palette")).tag(RimeKeyboardPreferences.PaletteMode.fixed)
      }
    } header: {
      Text(RimeLocalization.text("Appearance"))
    } footer: {
      Text(RimeLocalization.text("System mode uses the host keyboard background. The fixed palette uses solid colors and may differ from the system strip. Changes apply the next time Arkey appears."))
    }
  }

  private var feedbackSection: some View {
    Section {
      Toggle(RimeLocalization.text("Key popups"), isOn: Binding(
        get: { model.keyboardPreferences.calloutEnabled },
        set: { value in model.updatePreferences { $0.calloutEnabled = value } }))
      Toggle(RimeLocalization.text("Key sounds"), isOn: Binding(
        get: { model.keyboardPreferences.keyClickEnabled },
        set: { value in model.updatePreferences { $0.keyClickEnabled = value } }))
      Toggle(RimeLocalization.text("Haptic feedback"), isOn: Binding(
        get: { model.keyboardPreferences.hapticsEnabled },
        set: { value in model.updatePreferences { $0.hapticsEnabled = value } }))
      Toggle(RimeLocalization.text("Double-tap Caps Lock"), isOn: Binding(
        get: { model.keyboardPreferences.capsLockEnabled },
        set: { value in model.updatePreferences { $0.capsLockEnabled = value } }))
      Stepper(value: Binding(
        get: { model.keyboardPreferences.deleteRepeatDelay },
        set: { value in model.updatePreferences { $0.deleteRepeatDelay = value } }),
              in: 0.2...1.0, step: 0.05) {
        Text(String(format: RimeLocalization.text("Delete repeat delay: %.2f s"), locale: interfaceLocale, model.keyboardPreferences.deleteRepeatDelay))
          .font(.body)
      }
      Stepper(value: Binding(
        get: { model.keyboardPreferences.deleteRepeatInterval },
        set: { value in model.updatePreferences { $0.deleteRepeatInterval = value } }),
              in: 0.05...0.3, step: 0.01) {
        Text(String(format: RimeLocalization.text("Delete repeat interval: %.2f s"), locale: interfaceLocale, model.keyboardPreferences.deleteRepeatInterval))
          .font(.body)
      }
    } header: {
      Text(RimeLocalization.text("Feedback"))
    } footer: {
      Text(RimeLocalization.text("Key popups appear only on phones and stay within the keyboard. Delete repeat uses the default timings; adjust them here after testing on a device."))
    }
  }

  private var resetSection: some View {
    Section {
      Button(RimeLocalization.text("Restore defaults")) {
        Task {
          await model.resetPreferences()
          auxiliaryPrefixDraft = model.keyboardPreferences.auxiliaryPrefix
        }
      }
    } footer: {
      Text(RimeLocalization.text("Restore keyboard appearance and key settings. Keep the auxiliary prefix and spelling configured in the Rime scheme."))
    }
  }
}
