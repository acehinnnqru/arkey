import Foundation
import RimeEngine

// S6's release check, as a tool rather than a paragraph: it walks a built bundle and fails when
// anything other than this repository's own tracer data is inside it.
//
//   swift run --package-path Packages/RimeEngine rime-release-check \
//     --bundle .build/DerivedData-release/Build/Products/Release-iphoneos/arkey.app \
//     --tracer RimeData

struct Options {
  var bundle: String?
  var tracer: String = "RimeData"

  static func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--bundle":
        index += 1
        if index < arguments.count { options.bundle = arguments[index] }
      case "--tracer":
        index += 1
        if index < arguments.count { options.tracer = arguments[index] }
      default:
        break
      }
      index += 1
    }
    return options
  }
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
guard let bundle = options.bundle else {
  FileHandle.standardError.write(Data("usage: rime-release-check --bundle <path> [--tracer <path>]\n".utf8))
  exit(2)
}

let fileManager = FileManager.default
let tracerURL = URL(fileURLWithPath: options.tracer)
guard fileManager.fileExists(atPath: tracerURL.path) else {
  FileHandle.standardError.write(Data(("the tracer data is missing at " + tracerURL.path + "\n").utf8))
  exit(2)
}

var bundles = [URL(fileURLWithPath: bundle)]
// The extension is a plugin inside the app; walking the app covers it, but an explicit .appex is
// also accepted so the check can be pointed at one on its own.
if bundle.hasSuffix(".appex") || fileManager.fileExists(atPath: bundle) {
  // nothing extra: the enumerator is recursive
}

var failed = false
for url in bundles {
  let result = RimeReleaseCheck.check(bundle: url, tracerData: tracerURL, fileManager: fileManager)
  print(result.report)
  if !result.isClean { failed = true }
}
exit(failed ? 1 : 0)
