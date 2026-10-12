import SwiftUI
import RimeEngine

/// S2's 方案 / 输入 screens: only the knobs the schema's translator actually reads, generated from the
/// schema rather than hard-coded per screen.
struct SchemaSettingsView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var isLoading = true

  var body: some View {
    let _ = interfaceLocale
    List {
      schemaSection
      if let descriptor = model.schemaDescriptor {
        switchSection(descriptor)
        inputSection(descriptor)
        fuzzySection
        footerSection(descriptor)
      } else if !isLoading {
        Section {
          Text(RimeLocalization.text("No scheme is available. Import and deploy a profile in the profile library first."))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if let error = model.errorMessage { errorSection(error) }
    }
    .modifier(SettingsLoadingPresentation(isLoading: isLoading))
    .navigationTitle(RimeLocalization.text("Scheme"))
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(RimeLocalization.text("Refresh")) { Task { await model.refreshSettings() } }
      }
    }
    .task {
      isLoading = true
      await model.refreshSettings()
      isLoading = false
    }
  }

  // MARK: Sections

  /// A selection publishes immediately; its single-schema list is written and deployed in the background.
  private var schemaSection: some View {
    let selected = model.schemaOrderIDs.first
    let rows = model.schemaRows
    return Section {
      Picker(RimeLocalization.text("Input scheme"), selection: Binding(
        get: { selected ?? "" },
        set: { model.selectInputSchema($0) })) {
          if selected == nil {
            Text(RimeLocalization.text("Choose a scheme")).tag("")
          }
          ForEach(rows, id: \.self) { id in
            Text(id).tag(id)
          }
      }
      .pickerStyle(.menu)
      .disabled(rows.isEmpty)
    } header: {
      Text(RimeLocalization.text("Scheme"))
    } footer: {
      Text(RimeLocalization.text("Choose one input scheme. Changes are deployed automatically and take effect the next time the keyboard opens."))
    }
  }

  /// The switches the schema declares, with the words it (or `get_state_label`) gives them.
  private func switchSection(_ descriptor: RimeSchemaDescriptor) -> some View {
    Section {
      ForEach(descriptor.switches, id: \.name) { entry in
        if entry.displayLabels.count >= 2 {
          Picker(entry.displayLabels[0] + " / " + entry.displayLabels[1],
                 selection: Binding(
                   get: { entry.reset },
                   set: { value in model.setSwitch(entry.name, reset: value) })) {
            Text(entry.displayLabels[0]).tag(0)
            Text(entry.displayLabels[1]).tag(1)
          }
          .pickerStyle(.segmented)
        }
      }
    } header: {
      Text(RimeLocalization.text("Switches"))
    } footer: {
      Text(RimeLocalization.text("These are the scheme’s startup defaults and take effect after deployment when the keyboard next opens. Half-width can still use Chinese punctuation; use the scheme’s Chinese/English punctuation switch to choose punctuation style."))
      // Measured: setting one switch writes the whole list, so the file cannot say which switch the
      // user changed. The section is marked, not each row.
      Text(descriptor.switches.contains { $0.isUserSet }
           ? RimeLocalization.text("Modified (switches are saved together, so the entire section is marked)")
           : RimeLocalization.text("Scheme defaults"))
    }
  }

  /// The translator's own knobs. Which ones exist is the schema's business: a pinyin schema reads
  /// 逐码提示 and ignores 整句输入, and the model decides that, not this view.
  private func inputSection(_ descriptor: RimeSchemaDescriptor) -> some View {
    Section {
      ForEach(descriptor.settings, id: \.id) { setting in
        settingRow(setting)
      }
    } header: {
      Text(RimeLocalization.text("Input (\(translatorName(descriptor.translatorKind)))"))
    }
  }

  @ViewBuilder
  private func settingRow(_ setting: RimeSettingDescriptor) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      switch setting.effective {
      case nil:
        // Missing YAML values use the engine's defaults, but still have editable types.
        switch setting.valueType {
        case .boolean:
          Picker(setting.title, selection: Binding<Bool?>(
            get: { nil },
            set: { value in
              if let value { model.setSetting(setting, value: .boolean(value)) }
            })) {
              Text(RimeLocalization.text("Use engine default")).tag(nil as Bool?)
              Text(RimeLocalization.text("On")).tag(Optional(true))
              Text(RimeLocalization.text("Off")).tag(Optional(false))
            }
            .pickerStyle(.menu)
        case .integer:
          Picker(setting.title, selection: Binding<Int?>(
            get: { nil },
            set: { value in
              if let value { model.setSetting(setting, value: .integer(value)) }
            })) {
              Text(RimeLocalization.text("Use engine default")).tag(nil as Int?)
              ForEach(0...20, id: \.self) { value in
                Text(String(value)).tag(Optional(value))
              }
            }
            .pickerStyle(.menu)
        }
      case .boolean(let value):
        Toggle(setting.title, isOn: Binding(
          get: { value },
          set: { newValue in model.setSetting(setting, value: .boolean(newValue)) }))
      case .integer(let value):
        Stepper(value: Binding(
          get: { value },
          set: { newValue in model.setSetting(setting, value: .integer(newValue)) }),
                in: 0...20) {
          Text(setting.title + "：" + String(value))
            .font(.body)
        }
      default:
        Text(setting.title + "：" + (setting.effective?.displayText ?? RimeLocalization.text("Not set")))
          .font(.body)
      }
      HStack(spacing: 8) {
        if let note = setting.note {
          Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        if setting.isUserSet {
          Button(RimeLocalization.text("Reset")) { model.resetSetting(setting) }
            .font(.caption2)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var fuzzySection: some View {
    let enabled = model.enabledFuzzyPresets
    return Section {
      ForEach(RimeFuzzyPinyin.presets) { preset in
        Toggle(preset.displayName, isOn: Binding(
          get: { enabled.contains(preset.id) },
          set: { isOn in
            var next = enabled
            if isOn {
              if !next.contains(preset.id) { next.append(preset.id) }
            } else {
              next.removeAll { $0 == preset.id }
            }
            model.setFuzzyPinyin(next)
          }))
      }
    } header: {
      Text(RimeLocalization.text("Fuzzy pinyin"))
    } footer: {
      Text(RimeLocalization.text("Saved together in speller/algebra. Repeated toggles do not duplicate rules; disabling removes only that preset’s rules."))
    }
  }

  /// Explains where schema changes are saved and when the keyboard adopts them.
  private func footerSection(_ descriptor: RimeSchemaDescriptor) -> some View {
    Text(RimeLocalization.text("Changes are saved to \((descriptor.schemaID)).custom.yaml and deployed automatically. The keyboard adopts them next time it opens."))
      .font(.caption2)
      .foregroundStyle(.secondary)
  }

  private func errorSection(_ message: RimeLocalizedMessage) -> some View {
    Section(RimeLocalization.text("Error")) {
      Text(UserFacing.text(message)).font(.caption).foregroundStyle(.red)
      Button(RimeLocalization.text("Clear")) { model.errorMessage = nil }.font(.caption)
    }
  }

  private func translatorName(_ kind: RimeTranslatorKind) -> String {
    switch kind {
    case .script: return RimeLocalization.text("Pinyin")
    case .table: return RimeLocalization.text("Table")
    case .other: return RimeLocalization.text("Other")
    }
  }
}
