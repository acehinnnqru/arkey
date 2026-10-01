import SwiftUI
import RimeEngine

/// S3 §4's palette decision and §5's feedback switches, as a screen.
///
/// Nothing here is written to a Rime patch: these are our settings, they need no deploy, and the
/// keyboard reads them from the app group the next time it appears.
struct KeyboardSettingsView: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    List {
      appearanceSection
      feedbackSection
      resetSection
      // S2 §3's last row is our own settings rather than Rime's, so there is no patch and no deploy to
      // wait for: the footer says the one thing that is true here.
      Section {
        Label("无需部署：键盘下次出现时读取。", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = model.errorMessage { UserFacing.errorRow(error) }
    }
    .navigationTitle("键盘")
    .task { model.refreshPreferences() }
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
      Text("跟随宿主时背板由系统的 .keyboard 材质提供，实测色只作为回落；固定调色板可预测，但在浅色宿主上会显得不对。")
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
      Button("恢复默认") { model.resetPreferences() }
    } footer: {
      Text("设置存在 App Group 里，键盘下次出现时生效，不需要部署。")
    }
  }
}
