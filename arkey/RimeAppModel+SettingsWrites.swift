import Combine
import Foundation
import RimeEngine
import SwiftUI

/// One settings change the user has asked for, as data rather than as work already in progress.
///
/// The 方案 screen's controls hand one of these to `enqueueSettingsWrite` and return. Nothing in it is
/// resolved against the engine yet: the schema list may want a profile scan to validate against, the switch
/// has to read the list it joins, and 模糊音 has to read the algebra it composes into — all of which are
/// engine calls, and an engine call made while a deploy is running waits for that deploy.
enum RimeSettingsIntent: Sendable {
  /// S2 §3's first row: which schemas the keyboard offers, in which order, and which one it starts on. One
  /// key, written as the whole list.
  case schemaList([String])
  /// One switch's default state. The whole `switches` list goes into the patch, because Rime replaces a list
  /// wholesale (`RimeSettingsModel.setSwitchReset`).
  case switchReset(schemaID: String, name: String, reset: Int)
  /// One translator setting, in its own scope's patch.
  case setting(configID: String, key: String, value: RimeSettingDescriptor.Value)
  /// A reset: the leaf is deleted from the patch, so the schema's own value comes back (S2 §4).
  case resetSetting(configID: String, key: String)
  /// 模糊音, composed into `speller/algebra` from the schema's own algebra, never appended (S2 §2.1).
  case fuzzyPresets(schemaID: String, enabled: [String])

  /// What the write addresses.
  ///
  /// Two intents with one slot are one control, and only the last of them has to run — without that, five taps
  /// down a list would be five deploys, and every one of them tens of seconds. A switch is per name rather than
  /// per schema even though the patch holds the schema's whole list: the list is what carries the change, so
  /// two switches are two changes and neither may replace the other.
  var slot: String {
    switch self {
    case .schemaList:
      return "default/schema_list"
    case .switchReset(let schemaID, let name, _):
      return schemaID + "/switches/" + name
    case .setting(let configID, let key, _), .resetSetting(let configID, let key):
      return configID + "/" + key
    case .fuzzyPresets(let schemaID, _):
      return schemaID + "/speller/algebra"
    }
  }
}

/// The screen's half of S2: a tap publishes what the user chose and queues the write, and the write happens
/// when the engine's queue is free.
///
/// Reported from the app as 方案的开关特别卡，点击一个关掉要很久才响应. Two things made it so. The switch read its
/// value from the *deployed* configuration, which is only re-read after the deploy ends; and the write that
/// followed the tap ran on the main actor, where librime's deploy is holding the engine's own queue. Both are
/// the same mistake — a tap treated as if the engine were free — and both are fixed the same way: the tap
/// publishes, the queue writes. See `RimeAppModel.pendingSettingsWrites` for the state that holds it.
@MainActor
extension RimeAppModel {
  // MARK: - The queue

  /// Takes one settings change and returns at once, with the screen already showing the choice.
  func enqueueSettingsWrite(_ intent: RimeSettingsIntent) {
    // The newest intent for a control replaces the one still waiting behind it: every write here is the whole
    // value, so an earlier one that has not started is already out of date.
    if let waiting = pendingSettingsWrites.firstIndex(where: { $0.slot == intent.slot }) {
      pendingSettingsWrites[waiting] = intent
    } else {
      pendingSettingsWrites.append(intent)
    }
    settingsFooter = .pending
    startSettingsWriterIfNeeded()
  }

  /// Waits until everything queued has been written and the deploy carrying it has finished. For tests, and
  /// for anything that must not race the deploy.
  func waitForSettingsWrites() async {
    while let writer = settingsWriter { await writer.value }
  }

  private func startSettingsWriterIfNeeded() {
    guard settingsWriter == nil else { return }
    settingsWriter = Task { @MainActor in
      await drainSettingsWrites()
      settingsWriter = nil
    }
  }

  /// Applies what is queued, deploys once for the batch, and goes round again if the user chose something new
  /// while that deploy ran.
  private func drainSettingsWrites() async {
    while !pendingSettingsWrites.isEmpty {
      let batch = pendingSettingsWrites
      pendingSettingsWrites.removeAll()

      // The engine's queue is what a deploy is holding. Wait for it to be free before writing: this runs on the
      // main actor, so a write attempted underneath a deploy is the main thread waiting for that deploy.
      await waitForDeployInFlight()
      // Nothing may suspend between here and the writes below. That is what makes them safe to run here at all
      // rather than on a queue of their own: no deploy can start while they hold the main actor. Every intent
      // is attempted — one bad key does not excuse the rest of the batch — and the first failure is the one
      // reported.
      var changes: [RimeConfigChange] = []
      var failure: Error?
      for intent in batch {
        do {
          changes.append(try apply(intent))
        } catch {
          if failure == nil { failure = error }
        }
      }

      for change in changes { recordConfigChange(change) }
      if !changes.isEmpty {
        await deploy(profileID: activeProfileID ?? "")
      }
      if let failure {
        errorMessage = "写入设置失败：" + String(describing: failure)
        settingsFooter = .failed(String(describing: failure))
      }
      // The engine's own answer, with whatever is still queued laid back over it.
      refreshSettings()
    }
  }

  private func waitForDeployInFlight() async {
    while let running = deployInFlight { await running.value }
  }

  /// The write itself, through the engine's own editors, which is where S2's writing rules live.
  private func apply(_ intent: RimeSettingsIntent) throws -> RimeConfigChange {
    switch intent {
    case .schemaList(let ids):
      return try schemaListEditor().write(ids)
    case .switchReset(let schemaID, let name, let reset):
      return try RimeSettingsModel.setSwitchReset(reset, forSwitch: name, schemaID: schemaID, engine: engine)
    case .setting(let configID, let key, let value):
      let patch = RimePatch(engine: engine, configID: configID)
      switch value {
      case .boolean(let raw): return try patch.set(.bool(raw), at: key)
      case .integer(let raw): return try patch.set(.int(raw), at: key)
      case .text(let raw): return try patch.set(.string(raw), at: key)
      case .list(let raw): return try patch.set(.list(raw.map { .string($0) }), at: key)
      }
    case .resetSetting(let configID, let key):
      return try RimePatch(engine: engine, configID: configID).remove(key: key)
    case .fuzzyPresets(let schemaID, let enabled):
      // The base is the schema's algebra as deployed, and `compose` drops anything it generated before it adds
      // what is enabled now, so switching a preset on twice cannot accumulate anything (S2 §2.1).
      let base = (try engine.schemaValue("speller/algebra", schemaID: schemaID)?.listValue ?? [])
        .compactMap(\.stringValue)
      let composed = RimeFuzzyPinyin.compose(baseAlgebra: base, enabled: enabled)
      return try RimePatch(engine: engine, configID: schemaID)
        .set(.list(composed.map { .string($0) }), at: "speller/algebra")
    }
  }
}
