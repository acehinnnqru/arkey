import SwiftUI
import RimeEngine

/// S2's 方案 / 输入 screens: only the knobs the schema's translator actually reads, generated from the
/// schema rather than hard-coded per screen.
struct SchemaSettingsView: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    List {
      schemaSection
      if let descriptor = model.schemaDescriptor {
        switchSection(descriptor)
        inputSection(descriptor)
        fuzzySection
        footerSection(descriptor)
      } else {
        Section {
          Text("还没有可设置的方案。先到配置库导入并部署一个配置。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if let error = model.errorMessage { errorSection(error) }
    }
    .navigationTitle("方案")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("刷新") { model.refreshSettings() }
      }
    }
    .task { model.refreshSettings() }
  }

  // MARK: Sections

  /// S2 §3's first row: which schemas the keyboard offers, in which order, and which one it starts
  /// on. The first entry *is* the default, so there is no separate setting to get out of step.
  private var schemaSection: some View {
    let order = model.schemaOrderIDs
    let rows = model.schemaRows
    return Section {
      ForEach(rows, id: \.self) { id in
        HStack(spacing: 12) {
          Toggle(isOn: Binding(
            get: { order.contains(id) },
            set: { isOn in Task { await model.setSchema(id, enabled: isOn) } })) {
              VStack(alignment: .leading, spacing: 2) {
                Text(id)
                if order.first == id {
                  Text("默认").font(.caption2).foregroundStyle(.secondary)
                }
              }
            }
          if order.contains(id) {
            Button { Task { await model.moveSchema(id, by: -1) } } label: {
              Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(order.first == id)
            Button { Task { await model.moveSchema(id, by: 1) } } label: {
              Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(order.last == id)
            if order.first != id {
              Button("设为默认") { Task { await model.setSchemaDefault(id) } }
                .font(.caption)
                .buttonStyle(.borderless)
            }
          }
        }
      }
    } header: {
      Text("方案")
    } footer: {
      Text("第一个是默认方案。开关决定它是否出现在键盘上；改动写入 default.custom.yaml 并自动部署。")
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
                   set: { value in Task { await model.setSwitch(entry.name, reset: value) } })) {
            Text(entry.displayLabels[0]).tag(0)
            Text(entry.displayLabels[1]).tag(1)
          }
          .pickerStyle(.segmented)
        }
      }
    } header: {
      Text("开关")
    } footer: {
      // Measured: setting one switch writes the whole list, so the file cannot say which switch the
      // user changed. The section is marked, not each row.
      Text(descriptor.switches.contains { $0.isUserSet }
           ? "已修改（开关是整表写入，所以这里标记的是整节）"
           : "来自方案的默认值")
    }
  }

  /// The translator's own knobs. Which ones exist is the schema's business: a pinyin schema reads
  /// 逐码提示 and ignores 整句输入, and the model decides that, not this view.
  private func inputSection(_ descriptor: RimeSchemaDescriptor) -> some View {
    Section {
      ForEach(descriptor.settings.filter { $0.id != "pageSize" }, id: \.id) { setting in
        settingRow(setting)
      }
    } header: {
      Text("输入（" + translatorName(descriptor.translatorKind) + "）")
    }
  }

  @ViewBuilder
  private func settingRow(_ setting: RimeSettingDescriptor) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      switch setting.effective {
      case .boolean(let value):
        Toggle(setting.title, isOn: Binding(
          get: { value },
          set: { newValue in Task { await model.setSetting(setting, value: .boolean(newValue)) } }))
      case .integer(let value):
        Stepper(value: Binding(
          get: { value },
          set: { newValue in Task { await model.setSetting(setting, value: .integer(newValue)) } }),
                in: 0...20) {
          Text(setting.title + "：" + String(value))
            .font(.body)
        }
      default:
        Text(setting.title + "：" + (setting.effective?.displayText ?? "未设置"))
          .font(.body)
      }
      HStack(spacing: 8) {
        if let note = setting.note {
          Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        if setting.isUserSet {
          Button("重置") { Task { await model.resetSetting(setting) } }
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
            Task { await model.setFuzzyPinyin(next) }
          }))
      }
    } header: {
      Text("模糊音")
    } footer: {
      Text("按组合写入 speller/algebra：重复开关不会累积规则，关掉只移除自己的规则。")
    }
  }

  /// S2 §6's footer, plus the one sentence this screen owes: which file the change lands in.
  @ViewBuilder
  private func footerSection(_ descriptor: RimeSchemaDescriptor) -> some View {
    Text("改动写入 " + (descriptor.schemaID) + ".custom.yaml，随后自动部署；键盘在下次出现时采用。")
      .font(.caption2)
      .foregroundStyle(.secondary)
    SettingsDeployFooter(model: model)
  }

  private func errorSection(_ message: String) -> some View {
    Section("错误") {
      Text(message).font(.caption).foregroundStyle(.red)
      Button("清除") { model.errorMessage = nil }.font(.caption)
    }
  }

  private func translatorName(_ kind: RimeTranslatorKind) -> String {
    switch kind {
    case .script: return "拼音"
    case .table: return "码表"
    case .other: return "其他"
    }
  }
}
