import UIKit
import RimeEngine

/// Rime keyboard: system-like key grid, candidate bar, and marked-text composition.
final class KeyboardViewController: UIInputViewController {
  private let candidateBar = CandidateBar()
  private let keyGrid = KeyboardKeyGrid()
  private var heightConstraint: NSLayoutConstraint?
  private var engine: RimeEngine?
  private var theme = KeyboardTheme.current(for: .default)
  private var keyLayer: KeyLayer = .letters
  private var asciiMode = false
  private var isComposing = false

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

    startEngine()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyCurrentTheme()
    refreshLayout()
    updateHeight()
    Task { try? await engine?.clearComposition() }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    updateHeight()
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    applyCurrentTheme()
    refreshLayout()
  }

  // MARK: - Engine

  private func startEngine() {
    Task { await prepareEngine() }
  }

  private func prepareEngine() async {
    switch KeyboardEngine.setup {
    case .failure(let error):
      let reason = String(describing: error)
      KeyboardLog.error("setup failed: " + reason)
      candidateBar.setMessage("Arkey 启动失败：" + reason)
    case .success(let setup):
      engine = setup.engine
      do {
        let start = try await setup.engine.start()
        try await setup.engine.openSession()
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

  private func send(_ keysym: Int32) {
    Task { await process(keysym) }
  }

  private func process(_ keysym: Int32) async {
    guard let engine else { return }
    do {
      apply(try await engine.processKey(keysym))
    } catch {
      report("key.failed", error, userVisible: "按键出错：")
    }
  }

  private func selectCandidate(_ index: Int) {
    Task {
      guard let engine else { return }
      do {
        apply(try await engine.selectCandidate(at: index))
      } catch {
        report("select.failed", error, userVisible: "选词出错：")
      }
    }
  }

  private func toggleAsciiMode() {
    asciiMode.toggle()
    refreshLayout()
    Task {
      guard let engine else { return }
      do {
        try await engine.setOption("ascii_mode", asciiMode)
        apply(try await engine.refresh())
      } catch {
        report("option.failed", error, userVisible: "切换出错：")
      }
    }
  }

  /// Pushes one engine result into the text field and the candidate bar.
  private func apply(_ output: RimeOutput) {
    if let commit = output.commit, !commit.isEmpty {
      textDocumentProxy.insertText(commit)
    }

    let preedit = output.preedit ?? ""
    if preedit.isEmpty {
      if isComposing {
        textDocumentProxy.unmarkText()
      }
    } else {
      textDocumentProxy.setMarkedText(preedit,
                                      selectedRange: NSRange(location: (preedit as NSString).length, length: 0))
    }
    isComposing = !preedit.isEmpty

    asciiMode = output.status?.isAsciiMode ?? asciiMode
    if output.candidates.isEmpty {
      candidateBar.setCandidates([], highlighted: 0)
    } else {
      candidateBar.setCandidates(output.candidates, highlighted: output.page?.highlightedIndex ?? 0)
    }
    refreshLayout()
  }

  // MARK: - Input

  private func handle(_ key: KeyboardKey) {
    switch key {
    case .character(let value):
      guard let keysym = RimeKey.ascii(Character(value)) else { return }
      send(keysym)
    case .space:
      send(RimeKey.space)
    case .auxCode:
      send(auxCodeKeysym)
    case .backspace:
      if isComposing {
        send(RimeKey.backSpace)
      } else {
        textDocumentProxy.deleteBackward()
      }
    case .returnKey:
      if isComposing {
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
