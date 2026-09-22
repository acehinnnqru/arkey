import Foundation
import RimeEngine

// rime-deploy: compiles the YAML schema sources into the prebuilt tables that ship inside the
// app bundle, using the same librime build the keyboard extension links.
//
//   rime-deploy --shared <RimeData> --staging <output directory> [--user <scratch directory>]

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
  _ = try await engine.start()
  let record = try await engine.runMaintenance(fullCheck: true)
  await engine.shutdown()

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
