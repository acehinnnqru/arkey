import SwiftUI
import RimeEngine

/// S3 §4's palette decision and §5's feedback switches, as a screen.
///
/// The auxiliary prefix also updates the active Rime schema and deploys it. Other keyboard
/// preferences are shared through the app group and take effect when the keyboard next appears.
struct KeyboardSettingsView: View {
  @ObservedObject var model: RimeAppModel
  @State private var auxiliaryPrefixDraft = ","
  @State private var isLoading = true

  var body: some View {
    List {
      if isLoading { ProgressView("Loading settings…") }
      auxiliarySection
      SettingsDeployFooter(model: model)
      compositionSection
      appearanceSection
      feedbackSection
      resetSection
      // The auxiliary prefix deploys; the other keyboard preferences need no deploy.
      Section {
        Label("辅码前导键修改后会部署 Rime 方案；其他键盘设置下次出现时读取。", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .disabled(isLoading)
    .navigationTitle("键盘")
    .task {
      isLoading = true
      await model.refreshPreferences()
      auxiliaryPrefixDraft = model.keyboardPreferences.auxiliaryPrefix
      isLoading = false
    }
  }

  private var auxiliarySection: some View {
    Section {
      TextField("辅码前导键", text: Binding(
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
        Text("请输入一个特殊符号")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Picker("辅码拼写", selection: Binding(
        get: { model.auxiliarySpelling },
        set: { value in model.setAuxiliarySpelling(value) })) {
        ForEach(RimeAuxiliarySpelling.allCases, id: \.self) { spelling in
          Text(spelling.label).tag(spelling)
        }
      }
      Picker("位置", selection: Binding(
        get: { model.keyboardPreferences.auxiliaryKeySide },
        set: { value in model.updatePreferences { $0.auxiliaryKeySide = value } })) {
        Text("空格左侧").tag(RimeKeyboardPreferences.AuxiliaryKeySide.left)
        Text("空格右侧").tag(RimeKeyboardPreferences.AuxiliaryKeySide.right)
      }
    } header: {
      Text("辅码键")
    } footer: {
      Text("只能输入一个半角特殊符号；输入对应全角符号会自动转为半角。默认逗号，位于空格右侧。前导符和辅码拼写分别写入当前方案与 radical_pinyin，修改后自动部署。多个方案共用同一套拆字码型，请选择你实际使用的拼写。")
    }
  }

  private var compositionSection: some View {
    Section {
      Picker("输入中显示", selection: Binding(
        get: { model.keyboardPreferences.compositionDisplay },
        set: { value in model.updatePreferences { $0.compositionDisplay = value } })) {
        Text("原始按键").tag(RimeKeyboardPreferences.CompositionDisplay.rawInput)
        Text("方案转换结果").tag(RimeKeyboardPreferences.CompositionDisplay.preedit)
      }
    } header: {
      Text("未确认文字")
    } footer: {
      Text("例如小鹤双拼输入 nihc：原始按键显示 nihc，方案转换结果显示 ni hao。只影响输入框中未确认的文字，不影响候选词。")
    }
  }

  private var appearanceSection: some View {
    Section {
      Picker("背板", selection: Binding(
        get: { model.keyboardPreferences.paletteMode },
        set: { mode in model.updatePreferences { $0.paletteMode = mode } })) {
        Text("跟随宿主（系统材质）").tag(RimeKeyboardPreferences.PaletteMode.followHost)
        Text("固定调色板").tag(RimeKeyboardPreferences.PaletteMode.fixed)
      }
    } header: {
      Text("外观")
    } footer: {
      Text("System mode uses the host keyboard background. The fixed palette uses solid colors and may differ from the system strip. Changes apply the next time Arkey appears.")
    }
  }

  private var feedbackSection: some View {
    Section {
      Toggle("按键气泡", isOn: Binding(
        get: { model.keyboardPreferences.calloutEnabled },
        set: { value in model.updatePreferences { $0.calloutEnabled = value } }))
      Toggle("按键声音", isOn: Binding(
        get: { model.keyboardPreferences.keyClickEnabled },
        set: { value in model.updatePreferences { $0.keyClickEnabled = value } }))
      Toggle("触感反馈", isOn: Binding(
        get: { model.keyboardPreferences.hapticsEnabled },
        set: { value in model.updatePreferences { $0.hapticsEnabled = value } }))
      Toggle("双击大写锁定", isOn: Binding(
        get: { model.keyboardPreferences.capsLockEnabled },
        set: { value in model.updatePreferences { $0.capsLockEnabled = value } }))
      Stepper(value: Binding(
        get: { model.keyboardPreferences.deleteRepeatDelay },
        set: { value in model.updatePreferences { $0.deleteRepeatDelay = value } }),
              in: 0.2...1.0, step: 0.05) {
        Text(String(format: "连删起始：%.2f s", model.keyboardPreferences.deleteRepeatDelay))
          .font(.body)
      }
      Stepper(value: Binding(
        get: { model.keyboardPreferences.deleteRepeatInterval },
        set: { value in model.updatePreferences { $0.deleteRepeatInterval = value } }),
              in: 0.05...0.3, step: 0.01) {
        Text(String(format: "连删间隔：%.2f s", model.keyboardPreferences.deleteRepeatInterval))
          .font(.body)
      }
    } header: {
      Text("反馈")
    } footer: {
      Text("气泡只在手机类设备上出现，且被限制在键盘自身范围内；连删的默认值是出厂共识，真机校准后改这里一处即可。")
    }
  }

  private var resetSection: some View {
    Section {
      Button("恢复默认") {
        Task {
          await model.resetPreferences()
          auxiliaryPrefixDraft = model.keyboardPreferences.auxiliaryPrefix
        }
      }
    } footer: {
      Text("恢复键盘外观与按键设置；Rime 方案中的辅码前导符和辅码拼写保持当前配置。")
    }
  }
}
