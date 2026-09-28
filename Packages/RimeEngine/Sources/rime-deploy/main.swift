import Foundation
import RimeEngine

// rime-deploy: compiles the YAML schema sources into the prebuilt tables that ship inside the
// app bundle, using the same librime build the keyboard extension links.
//
//   rime-deploy --shared <RimeData> --staging <output directory> [--user <scratch directory>]
//
// `--probe <keys>` deploys, then opens a session and feeds <keys>, printing what composed. It exists
// because some settings only show their effect at session time and librime runs its maintenance once per
// process: a probe has to happen in the same fresh process as the deploy to mean anything.
// `--schema <id>` chooses the schema for the probe (default: tracer).
// `--twice` runs the maintenance a second time in the same process, which is what an in-session redeploy does.
// `--session-first` opens the session before the maintenance instead of after it.

func value(for flag: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let sharedArgument = value(for: "--shared", in: arguments),
      let stagingArgument = value(for: "--staging", in: arguments) else {
  fail("usage: rime-deploy --shared <RimeData> --staging <output directory> [--user <directory>]")
}

let fileManager = FileManager.default
let sharedURL = URL(fileURLWithPath: sharedArgument).standardizedFileURL
let stagingURL = URL(fileURLWithPath: stagingArgument).standardizedFileURL
let userURL: URL
if let userArgument = value(for: "--user", in: arguments) {
  userURL = URL(fileURLWithPath: userArgument).standardizedFileURL
} else {
  // Deployment writes user state (installation.yaml, logs). Keep the default outside the
  // repository so that the only thing produced in-tree is the staging output.
  userURL = fileManager.temporaryDirectory
    .appendingPathComponent("arkey-rime-deploy", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

guard fileManager.fileExists(atPath: sharedURL.path) else {
  fail("shared data directory does not exist: " + sharedURL.path)
}
try? fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
try? fileManager.createDirectory(at: userURL, withIntermediateDirectories: true)

print("librime:  " + RimeEngine.librimeVersion)
print("shared:   " + sharedURL.path)
print("staging:  " + stagingURL.path)
print("user:     " + userURL.path)

let directories = RimeDirectories(sharedDataDir: sharedURL.path,
                                  prebuiltDataDir: stagingURL.path,
                                  userDataDir: userURL.path,
                                  stagingDir: stagingURL.path,
                                  logDir: userURL.appendingPathComponent("log", isDirectory: true).path,
                                  writableRoot: .custom)
let engine = RimeEngine(configuration: RimeConfiguration(directories: directories))

do {
  _ = try engine.start()
  // The app can have a session open while it deploys; the tests do exactly that. `--session-first`
  // reproduces it, because a live session is one of the candidates for why a redeploy changes nothing.
  if arguments.contains("--session-first") {
    try engine.openSession()
  }

  let record = try engine.runMaintenance(fullCheck: true)

  // An in-session redeploy: the app can deploy twice in one launch, and librime reports whether the
  // second maintenance actually started. This is the measurement that tells the two cases apart.
  if arguments.contains("--twice") {
    let second = try engine.runMaintenance(fullCheck: true)
    print("second maintenance: " + (second.message ?? "(no message)"))
  }

  if let probeKeys = value(for: "--probe", in: arguments) {
    let schemaID = value(for: "--schema", in: arguments) ?? "tracer"
    try engine.openSession()
    _ = try engine.selectSchema(schemaID)
    let output = try engine.processKeys(probeKeys)
    let candidates = output.candidates.map { $0.text }.joined(separator: ", ")
    print("probe:    schema " + schemaID + ", keys " + probeKeys)
    print("  preedit:    " + (output.preedit ?? "(none)"))
    print("  candidates: " + (candidates.isEmpty ? "(none)" : candidates))
    print("  committed:  " + (output.commit ?? "(none)"))
  }

  engine.shutdown()

  let produced = ((try? fileManager.contentsOfDirectory(atPath: stagingURL.path)) ?? []).sorted()
  print(String(format: "deployment: %.0f ms, %d files", record.milliseconds ?? 0, produced.count))
  for name in produced {
    let attributes = try? fileManager.attributesOfItem(atPath: stagingURL.appendingPathComponent(name).path)
    let size = (attributes?[.size] as? Int) ?? 0
    print("  " + name + "  " + String(size) + " bytes")
  }
  if produced.isEmpty {
    fail("deployment produced no files in " + stagingURL.path)
  }
} catch {
  fail("deployment failed: " + String(describing: error))
}
