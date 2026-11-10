import SwiftUI
import RimeEngine

/// Details of the latest attempt in this app session, including only its deployment report.
struct DeploymentLogView: View {
  @Environment(\.locale) private var interfaceLocale
  @ObservedObject var model: RimeAppModel

  var body: some View {
    let _ = interfaceLocale
    List {
      if let attempt = model.latestDeployment {
        Section(RimeLocalization.text("Deployment")) {
          Text(attempt.profileName)
          Text(attempt.profileID).font(.caption).foregroundStyle(.secondary)
          LabeledContent(RimeLocalization.text("Started"), value: attempt.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(interfaceLocale)))
          if let finishedAt = attempt.finishedAt {
            LabeledContent(RimeLocalization.text("Finished"), value: finishedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(interfaceLocale)))
          }
          Text(UserFacing.text(attempt.message))
            .foregroundStyle(attempt.failed ? Color.red : Color.secondary)
          if attempt.finishedAt == nil, !attempt.wasInterrupted { ProgressView(RimeLocalization.text("Deploying…")) }
        }
        Section {
          if attempt.logs.isEmpty {
            Text(attempt.finishedAt == nil && !attempt.wasInterrupted
                 ? RimeLocalization.text("Logs will appear when this deployment finishes.")
                 : RimeLocalization.text("No engine log was returned for this attempt."))
              .foregroundStyle(.secondary)
          }
          ForEach(Array(attempt.logs.enumerated()), id: \.offset) { _, record in
            Text(record.display)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(record.severity >= .error ? Color.red : Color.secondary)
              .textSelection(.enabled)
          }
        } header: {
          Text(RimeLocalization.text("Engine log (\(String(attempt.logs.count)))"))
        } footer: {
          Text(RimeLocalization.text("The latest deployment report from this app session. Older lines may be omitted by the engine's log buffer."))
        }
      } else {
        ContentUnavailableView(RimeLocalization.text("No deployment log"), systemImage: "doc.text",
                               description: Text(RimeLocalization.text("Deploy a profile to see its result and engine log here. Logs are kept for this app session only.")))
      }
    }
    .navigationTitle(RimeLocalization.text("Deployment log"))
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("deployment-log")
  }
}
