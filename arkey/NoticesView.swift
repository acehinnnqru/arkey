import SwiftUI
import RimeEngine
import UIKit

/// S6's 许可证 screen: what this install contains, who wrote it, and under what terms.
///
/// The data is `RimeNotices`, which renders what each profile says about itself. The last line is the
/// one a script enforces: `bundleContainsThirdPartyData` comes from the release check, so the sentence
/// the user reads is the sentence the release pipeline fails on.
struct NoticesView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel
  @State private var copied = false

  var body: some View {
    let _ = interfaceLocale
    ScrollView {
      Text(text)
        .font(.footnote)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    .navigationTitle(RimeLocalization.text("Licenses"))
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(copied ? RimeLocalization.text("Copied") : RimeLocalization.text("Copy")) {
          UIPasteboard.general.string = text
          copied = true
        }
      }
    }
    .task { await model.refreshNotices() }
  }

  private var text: String {
    model.notices?.text ?? RimeLocalization.text("Loading…")
  }
}
