import SwiftUI
import RimeEngine

/// Details of the latest attempt in this app session, including only its deployment report.
struct DeploymentLogView: View {
  @ObservedObject var model: RimeAppModel

  var body: some View {
    List {
      if let attempt = model.latestDeployment {
        Section("Deployment") {
          Text(attempt.profileName)
          Text(attempt.profileID).font(.caption).foregroundStyle(.secondary)
          LabeledContent("Started", value: attempt.startedAt.formatted(date: .abbreviated, time: .standard))
          if let finishedAt = attempt.finishedAt {
            LabeledContent("Finished", value: finishedAt.formatted(date: .abbreviated, time: .standard))
          }
          Text(UserFacing.text(attempt.message))
            .foregroundStyle(attempt.failed ? Color.red : Color.secondary)
          if attempt.finishedAt == nil { ProgressView("Deploying…") }
        }
        Section {
          if attempt.logs.isEmpty {
            Text(attempt.finishedAt == nil
                 ? "Logs will appear when this deployment finishes."
                 : "No engine log was returned for this attempt.")
              .foregroundStyle(.secondary)
          }
          ForEach(Array(attempt.logs.enumerated()), id: \.offset) { _, record in
            Text(record.display)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(record.severity >= .error ? Color.red : Color.secondary)
              .textSelection(.enabled)
          }
        } header: {
          Text("Engine log (" + String(attempt.logs.count) + ")")
        } footer: {
          Text("The latest deployment report from this app session. Older lines may be omitted by the engine's log buffer.")
        }
      } else {
        ContentUnavailableView("No deployment log", systemImage: "doc.text",
                               description: Text("Deploy a profile to see its result and engine log here. Logs are kept for this app session only."))
      }
    }
    .navigationTitle("Deployment log")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("deployment-log")
  }
}
