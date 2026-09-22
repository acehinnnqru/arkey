import UIKit
import RimeEngine

/// Rime keyboard: system-like key grid, candidate bar, and marked-text composition.
///
/// The whole input path is synchronous. The engine owns a serial queue, so a key press is one
/// call plus one UI update with no scheduling hops; an earlier build hopped through an actor
/// twice per key and updated every view on screen each time, which read as a laggy keyboard.
final class KeyboardViewController: UIInputViewController {
  private let candidateBar = CandidateBar()
  private let keyGrid = KeyboardKeyGrid()
  private var heightConstraint: NSLayoutConstraint?
  private var engine: RimeEngine?
  private var theme = KeyboardTheme.current(for: .default)
  private var keyLayer: KeyLayer = .letters
  private var asciiMode = false
  private var markedText: String?

  // Input latency evidence, flushed to the probe log every 25 keys.
  private var keyCount = 0
  private var keyTotalMilliseconds = 0.0
  private var keyMaxMilliseconds = 0.0

  /// Keysym the aux-code key sends. Semicolon is the usual lead-in for auxiliary codes; it
  /// lives in one place so a schema can change it.
  private var auxCodeKeysym: Int32 { RimeKey.ascii(";") ?? 0x3B }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.background

    candidateBar.translatesAutoresizingMaskIntoConstraints = false
    keyGrid.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(candidateBar)
    view.addSubview(keyGrid)

    NSLayoutConstraint.activate([
      candidateBar.topAnchor.constraint(equalTo: view.topAnchor),
      candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      candidateBar.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),
      keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor, constant: KeyboardMetrics.rowGap),
      keyGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      keyGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -KeyboardMetrics.bottomInset),
    ])

    candidateBar.onSelect = { [weak self] index in self?.selectCandidate(index) }
    keyGrid.onKey = { [weak self] key in self?.handle(key) }

    prepareEngine()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyCurrentTheme()
    refreshLayout()
    updateHeight()
    markedText = nil
    try? engine?.clearComposition()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    updateHeight()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    flushKeyStatistics()
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    // This fires on every marked-text update, so it only does work when the appearance really
    // changed.
    let appearance = textDocumentProxy.keyboardAppearance ?? .default
    if appearance != theme.appearance {
      theme = KeyboardTheme.current(for: appearance)
      applyCurrentTheme()
      refreshLayout()
    }
  }

  // MARK: - Engine

  private func prepareEngine() {
    switch KeyboardEngine.setup {
    case .failure(let error):
      let reason = String(describing: error)
      KeyboardLog.error("setup failed: " + reason)
      candidateBar.setMessage("Arkey 启动失败：" + reason)
    case .success(let setup):
      engine = setup.engine
      do {
        let start = try setup.engine.start()
        try setup.engine.openSession()
        let detail = KeyboardEngine.detail(setup, hasFullAccess: hasFullAccess)
        KeyboardLog.info("boot ok: " + detail)
        setup.probe?.append(RimeProbeRecord(phase: "keyboard.boot",
                                            milliseconds: start.milliseconds,
                                            message: detail))
        candidateBar.setMessage(KeyboardEngine.statusLine(setup, hasFullAccess: hasFullAccess))
      } catch {
        let reason = String(describing: error)
        KeyboardLog.error("boot failed: " + reason)
        setup.probe?.append(RimeProbeRecord(phase: "keyboard.boot.failed", message: reason))
        candidateBar.setMessage("Arkey 启动失败：" + reason)
      }
    }
  }

  /// One place for the "log everything, show something short" rule.
  private func report(_ phase: String, _ error: Error, userVisible: String) {
    let reason = String(describing: error)
    KeyboardLog.error(phase + ": " + reason)
    if case .success(let setup) = KeyboardEngine.setup {
      setup.probe?.append(RimeProbeRecord(phase: phase, message: reason))
    }
    candidateBar.setMessage(userVisible + reason)
  }

  private func selectCandidate(_ index: Int) {
    guard let engine else { return }
    do {
      apply(try engine.selectCandidate(at: index))
    } catch {
      report("select.failed", error, userVisible: "选词出错：")
    }
  }

  private func toggleAsciiMode() {
    asciiMode.toggle()
    refreshLayout()
    guard let engine else { return }
    do {
      try engine.setOption("ascii_mode", asciiMode)
      apply(try engine.refresh())
    } catch {
      report("option.failed", error, userVisible: "切换出错：")
    }
  }

  /// Pushes one engine result into the text field and the candidate bar.
  private func apply(_ output: RimeOutput) {
    if let commit = output.commit, !commit.isEmpty {
      textDocumentProxy.insertText(commit)
    }

    let preedit = output.preedit ?? ""
    if preedit != (markedText ?? "") {
      if preedit.isEmpty {
        if markedText != nil {
          textDocumentProxy.unmarkText()
        }
        markedText = nil
      } else {
        textDocumentProxy.setMarkedText(preedit,
                                        selectedRange: NSRange(location: (preedit as NSString).length,
                                                               length: 0))
        markedText = preedit
      }
    }

    asciiMode = output.status?.isAsciiMode ?? asciiMode
    candidateBar.setCandidates(output.candidates, highlighted: output.page?.highlightedIndex ?? 0)
    refreshLayout()
  }

  // MARK: - Input

  private func handle(_ key: KeyboardKey) {
    switch key {
    case .character(let value):
      typeLiteralKey(value)
    case .space:
      send(RimeKey.space, fallback: " ")
    case .auxCode:
      send(auxCodeKeysym, fallback: ";")
    case .backspace:
      if (markedText ?? "").isEmpty {
        textDocumentProxy.deleteBackward()
      } else {
        send(RimeKey.backSpace)
      }
    case .returnKey:
      if !(markedText ?? "").isEmpty {
        send(RimeKey.returnKey)
      }
      textDocumentProxy.insertText("\n")
    case .shift:
      toggleAsciiMode()
    case .numbers:
      keyLayer = .numbers
      refreshLayout()
    case .letters:
      keyLayer = .letters
      refreshLayout()
    case .globe:
      advanceToNextInputMode()
    case .emoji:
      // The tracer ships no emoji layer; the key is here so the row matches the system one.
      break
    }
  }

  /// A character key: librime first, and the literal character when librime declines it.
  ///
  /// The fallback is not optional. The tracer schema has no punctuator, so librime refuses
  /// "." and "," outright, and without this the key did nothing at all — which users read as
  /// the keyboard dropping input.
  private func typeLiteralKey(_ value: String) {
    guard let engine, let keysym = RimeKey.ascii(Character(value)) else {
      textDocumentProxy.insertText(value)
      return
    }
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let output = try engine.processKey(keysym)
      if !output.handled, (output.commit ?? "").isEmpty, !output.isComposing {
        textDocumentProxy.insertText(value)
        markedText = nil
      }
      apply(output)
      recordKeyLatency(since: start)
    } catch {
      report("key.failed", error, userVisible: "按键出错：")
      textDocumentProxy.insertText(value)
    }
  }

  private func send(_ keysym: Int32, fallback: String? = nil) {
    guard let engine else {
      if let fallback { textDocumentProxy.insertText(fallback) }
      return
    }
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let output = try engine.processKey(keysym)
      if !output.handled, (output.commit ?? "").isEmpty, !output.isComposing, let fallback {
        textDocumentProxy.insertText(fallback)
      }
      apply(output)
      recordKeyLatency(since: start)
    } catch {
      report("key.failed", error, userVisible: "按键出错：")
      if let fallback { textDocumentProxy.insertText(fallback) }
    }
  }

  // MARK: - Latency evidence

  private func recordKeyLatency(since start: UInt64) {
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    keyCount += 1
    keyTotalMilliseconds += milliseconds
    keyMaxMilliseconds = max(keyMaxMilliseconds, milliseconds)
    if milliseconds > 50 {
      KeyboardLog.error("slow key: " + String(format: "%.1f ms", milliseconds))
    }
    if keyCount % 25 == 0 {
      flushKeyStatistics()
    }
  }

  private func flushKeyStatistics() {
    guard keyCount > 0, case .success(let setup) = KeyboardEngine.setup else { return }
    let average = keyTotalMilliseconds / Double(keyCount)
    let message = "keys=" + String(keyCount)
      + " avgMs=" + String(format: "%.2f", average)
      + " maxMs=" + String(format: "%.2f", keyMaxMilliseconds)
    setup.probe?.append(RimeProbeRecord(phase: "keyboard.stats",
                                        milliseconds: average,
                                        message: message))
    KeyboardLog.info("key stats: " + message)
    keyCount = 0
    keyTotalMilliseconds = 0
    keyMaxMilliseconds = 0
  }

  // MARK: - Presentation

  private func applyCurrentTheme() {
    theme = KeyboardTheme.current(for: textDocumentProxy.keyboardAppearance ?? .default)
    view.backgroundColor = theme.background
    candidateBar.apply(theme: theme)
  }

  private func refreshLayout() {
    keyGrid.configure(theme: theme,
                      layer: keyLayer,
                      asciiMode: asciiMode,
                      returnKeyLabel: returnKeyLabel,
                      showsGlobeRow: needsInputModeSwitchKey)
  }

  private func updateHeight() {
    let height = KeyboardMetrics.totalHeight(needsGlobeRow: needsInputModeSwitchKey)
    if let heightConstraint {
      if heightConstraint.constant != height {
        heightConstraint.constant = height
      }
    } else {
      let constraint = view.heightAnchor.constraint(equalToConstant: height)
      constraint.priority = UILayoutPriority(999)
      view.addConstraint(constraint)
      heightConstraint = constraint
    }
  }

  /// Native keyboards label the return key from the client's return key type.
  private var returnKeyLabel: String {
    switch textDocumentProxy.returnKeyType {
    case .send: return "发送"
    case .search, .google, .yahoo: return "搜索"
    case .go: return "前往"
    case .done: return "完成"
    case .next: return "下一项"
    case .continue: return "继续"
    case .join: return "加入"
    case .route: return "路线"
    case .emergencyCall: return "紧急呼叫"
    default: return "换行"
    }
  }
}
