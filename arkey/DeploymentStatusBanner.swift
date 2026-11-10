import RimeEngine
import SwiftUI

/// Stays visible across navigation and the Settings sheet while compilation is in flight.
struct DeploymentStatusBanner: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel

  var body: some View {
    let _ = interfaceLocale
    if model.isDeploying {
      HStack(alignment: .top, spacing: 10) {
        ProgressView()
        Text(RimeLocalization.text("Compiling… Keep the app open in the foreground until it finishes. Do not lock the screen or switch apps."))
          .font(.callout)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("compilation-in-progress")
    } else if let record = model.interruptedDeployment {
      VStack(alignment: .leading, spacing: 10) {
        Label(RimeLocalization.text("The last compilation of \(record.profileName) was not confirmed complete. Retry compilation to finish applying this profile."),
              systemImage: "exclamationmark.triangle")
          .font(.callout)
        HStack {
          if model.profiles.contains(where: { $0.id == record.profileID }) {
            Button(RimeLocalization.text("Retry")) {
              Task { await model.deploy(profileID: record.profileID) }
            }
            .buttonStyle(.bordered)
            .disabled(model.isDownloading || model.isImporting)
            .accessibilityIdentifier("compilation-retry")
          }
          Button(RimeLocalization.text("Dismiss")) { model.dismissInterruptedDeployment() }
            .accessibilityIdentifier("compilation-dismiss")
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial)
      .accessibilityIdentifier("compilation-interrupted")
    }
  }
}
