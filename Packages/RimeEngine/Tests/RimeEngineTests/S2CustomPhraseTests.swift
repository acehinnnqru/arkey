import XCTest
@testable import RimeEngine

/// S2 §3's 自定义短语 row: the file the user owns, read and written without losing what they wrote.
final class S2CustomPhraseTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("arkey-s2-phrase", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  func testTheFileParsesTheWayTheDesktopWritesIt() {
    let text = """
    # 自定义短语
    你好\tni hao\t1
    输入法\tshurufa
    的\td\t5.5

    """
    let result = RimeCustomPhraseFile.parse(text)
    XCTAssertEqual(result.phrases.count, 3)
    XCTAssertEqual(result.phrases[0], .init(text: "你好", code: "ni hao", weight: 1))
    XCTAssertEqual(result.phrases[1], .init(text: "输入法", code: "shurufa", weight: nil),
                   "a missing weight stays missing rather than becoming a zero")
    XCTAssertEqual(result.phrases[2].weight ?? 0, 5.5, accuracy: 0.001)
    XCTAssertTrue(result.rejected.isEmpty)
  }

  func testLinesItCannotReadAreReportedWithTheirNumber() {
    let text = """
    你好\tni hao
    only-one-field
    \tmissing-text
    输入法\tshurufa

    """
    let result = RimeCustomPhraseFile.parse(text)
    XCTAssertEqual(result.phrases.count, 2)
    XCTAssertEqual(result.rejected.map(\.line), [2, 3], "the line numbers point at the file")
    XCTAssertEqual(result.rejected[0].text, "only-one-field")
  }

  func testRoundTripKeepsTheValuesAndTheTrailingNewline() {
    let phrases = [RimeCustomPhrase(text: "你好", code: "ni hao", weight: 1),
                   RimeCustomPhrase(text: "输入法", code: "shurufa")]
    let text = RimeCustomPhraseFile.serialize(phrases)
    XCTAssertTrue(text.hasSuffix("\n"), "one line per phrase, with a final newline")
    XCTAssertEqual(RimeCustomPhraseFile.parse(text).phrases, phrases)
    XCTAssertEqual(RimeCustomPhraseFile.serialize([]), "")
  }

  func testSaveAndLoadGoThroughTheUserDirectory() throws {
    let url = scratch.appendingPathComponent("user/custom_phrase.txt")
    XCTAssertEqual(try RimeCustomPhraseFile.load(from: url).phrases, [],
                   "a missing file is an empty list, not an error")
    try RimeCustomPhraseFile.save([RimeCustomPhrase(text: "你好", code: "ni hao")], to: url)
    XCTAssertEqual(try RimeCustomPhraseFile.load(from: url).phrases.count, 1)
  }

  func testTheThreeMergeStrategies() {
    let existing = [RimeCustomPhrase(text: "你好", code: "ni hao")]
    let incoming = [RimeCustomPhrase(text: "你好", code: "ni hao"),
                    RimeCustomPhrase(text: "输入法", code: "shurufa")]

    XCTAssertEqual(RimeCustomPhraseFile.merge(incoming, into: existing, strategy: .replaceAll),
                   incoming)
    XCTAssertEqual(RimeCustomPhraseFile.merge(incoming, into: existing, strategy: .keepExisting),
                   existing)
    let appended = RimeCustomPhraseFile.merge(incoming, into: existing, strategy: .appendNew)
    XCTAssertEqual(appended.count, 2, "the duplicate is not added twice")
    XCTAssertEqual(appended[0].text, "你好", "and the user's own order is kept")
    XCTAssertEqual(appended[1].text, "输入法")
  }

  /// An import through the profile library carries the phrases it found; this is the shape the screen
  /// offers to merge.
  func testAnImportedBundleCarriesPhrasesInTheFileFormat() throws {
    let url = scratch.appendingPathComponent("bundle/custom_phrase.txt")
    try RimeCustomPhraseFile.save([RimeCustomPhrase(text: "哈哈", code: "haha", weight: 2)], to: url)
    let loaded = try RimeCustomPhraseFile.load(from: url)
    XCTAssertEqual(loaded.phrases.first?.line, "哈哈\thaha\t2")
  }
}
