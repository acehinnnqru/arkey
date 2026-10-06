import UIKit
import RimeEngine

/// Rime keyboard: system-like key grid, candidate bar, and marked-text composition.
///
/// The whole input path is synchronous. The engine owns a serial queue, so a key press is one
/// call plus one UI update with no scheduling hops; an earlier build hopped through an actor
/// twice per key and updated every view on screen each time, which read as a laggy keyboard.
final class KeyboardViewController: UIInputViewController, UIInputViewAudioFeedback {
  /// S3 §5's click sound: the documented path is this protocol plus @B@playInputClick()@B@, which only
  /// makes a sound while the keyboard is visible and only when the user enabled it in Settings.
  var enableInputClicksWhenVisible: Bool { true }

  private let candidateBar = CandidateBar()
  /// S4 §6's expanded panel: it replaces the keyboard area, so the keys are hidden while it is open.
  private lazy var candidatePanel = CandidatePanelView()
  /// S3 §5's magnified cap. It lives in the controller's view because it draws into the candidate
  /// slot above the first key row, which the grid does not own.
  private lazy var callout = KeyCalloutView()
  private var calloutKey: RimeKeyboardKey?
  private var feedbackPreferences: RimeKeyboardPreferences = .standard
  /// Prepared on touch down so the impact lands with the key rather than after the first use.
  private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
  private var isPanelExpanded = false
  private var panelCandidates: [RimeCandidateItem] = []
  private var panelPage = 0
  private let keyGrid = KeyboardKeyGrid()
  private var heightConstraint: NSLayoutConstraint?
  private var engine: RimeEngine?
  /// Kept so the appearance can adopt a profile the app activated (S1 §8).
  private var engineSetup: KeyboardEngine.Setup?
  private var theme = KeyboardTheme.current(for: .default)
  private var keyLayer: KeyLayer = .letters
  /// One-shot, caps lock and consumption live in the model, so the states are testable off-device.
  private var shiftController = RimeShiftController()
  private var asciiMode = false
  private var markedText: String?
  /// The page the bar is showing, whose labels decide which keys select (S4 §4.1).
  private var currentPage: RimePage?

  // Input latency evidence, flushed to the probe log every 25 keys.
  /// The per-key samples of the current batch. The input path cannot write a record per key (S3-AC5), so the
  /// samples are kept here and one record is written per window — carrying the window's p95, which is the
  /// number S4-AC6 is about.
  private var keyLatency = RimeKeyLatencyWindow()


  // MARK: - Lifecycle

  override func loadView() {
    // The host supplies the keyboard backing and the bottom system strip. A
    // .keyboard-style input view would add another material inside that backing.
    let contentView = UIInputView(frame: .zero, inputViewStyle: .default)
    contentView.backgroundColor = .clear
    contentView.isOpaque = false
    inputView = contentView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    applyBacking()

    candidateBar.translatesAutoresizingMaskIntoConstraints = false
    keyGrid.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(candidateBar)
    view.addSubview(keyGrid)

    NSLayoutConstraint.activate([
      candidateBar.topAnchor.constraint(equalTo: view.topAnchor),
      candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      candidateBar.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),
      // The measured slot is *everything* above the first key row — the bar and the room under it — so the grid
      // starts where the bar ends. One more row gap here (round 191) made the stack 11 pt taller than the frame
      // `updateHeight()` asks for, and iOS clipped exactly that off the bottom row: 123 / 中 / 空格 / 换行 came
      // back 34 pt tall instead of 45.
      keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
      keyGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // The system's own strip is below this frame, so the grid ends where the frame does (round 189: adding
      // the measured system inset here put a band of empty backing under the last row).
      keyGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    candidatePanel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(candidatePanel)
    NSLayoutConstraint.activate([
      candidatePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      candidatePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      candidatePanel.topAnchor.constraint(equalTo: view.topAnchor),
      candidatePanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    callout.isHidden = true
    view.addSubview(callout)

    candidatePanel.isHidden = true
    candidatePanel.onSelect = { [weak self] index in self?.selectFromPanel(index) }
    candidatePanel.onCollapse = { [weak self] in self?.collapsePanel() }
    candidatePanel.onPage = { [weak self] backward in self?.pagePanel(backward: backward) }

    candidateBar.onSelect = { [weak self] index in self?.selectCandidate(index) }
    candidateBar.onPage = { [weak self] backward in self?.changePage(backward: backward) }
    candidateBar.onExpand = { [weak self] in self?.expandPanel() }
    keyGrid.onKey = { [weak self] key in self?.handle(key) }
    keyGrid.onKeyTouchDown = { [weak self] key, point in
      self?.haptic.prepare()
      self?.showCallout(for: key, at: point)
    }
    keyGrid.onKeyTouchMove = { [weak self] key, point in self?.moveCallout(for: key, at: point) }
    keyGrid.onKeyTouchEnded = { [weak self] in self?.hideCallout() }

    prepareEngine()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    applyCurrentTheme()
    refreshLayout()
    updateHeight()
    // A profile the app activated is adopted here, before the first keystroke of this appearance,
    // and only because the composition was just cleared: S1 §8 forbids switching mid-sentence.
    markedText = nil
    try? engine?.clearComposition()
    if let setup = engineSetup {
      KeyboardEngine.adoptProfileIfNeeded(setup, isComposing: false)
      candidateBar.setMessage(KeyboardEngine.statusLine(setup, hasFullAccess: hasFullAccess))
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    updateHeight()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    flushKeyStatistics()
    // S5 §3.2: the dictionary lease is released when the keyboard goes away. The engine-side safety net
    // is the staleness rule, but a released lease is what makes the app usable again immediately.
    if case .success(let setup) = KeyboardEngine.setup {
      KeyboardEngine.releaseDictionaryLease(setup)
    }
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
      engineSetup = setup
      // The app stays away from the user dictionaries while this lease is fresh (S5 §3.2).
      KeyboardEngine.holdDictionaryLease(setup)
      do {
        let start = try setup.engine.start()
        try setup.engine.openSession()
        var detail = KeyboardEngine.detail(setup, hasFullAccess: hasFullAccess)
        if let age = RimeProbe.processAgeSeconds() {
          detail += " ageMs=" + String(format: "%.0f", age * 1000)
        }
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

  /// S4 §8 / S5-AC5: a long press on a candidate forgets the word. The bar's index is the one on the page it
  /// is showing, which is librime's numbering; librime answers false when the candidate did not come from the
  /// user dictionary, and the bar says so rather than pretending it forgot something.
  private func forgetCandidate(_ index: Int) {
    guard let engine else { return }
    do {
      let forgotten = try engine.deleteCandidate(at: index)
      apply(try engine.refresh())
      candidateBar.setMessage(forgotten ? "已忘记这个词" : "这个词不在用户词典里")
    } catch {
      report("forget.failed", error, userVisible: "忘记失败：")
    }
  }

  /// S3 §5: a page chevron pages the candidate list and never commits, so this only re-renders.
  private func changePage(backward: Bool) {
    guard let engine else { return }
    do {
      apply(try engine.changePage(backward: backward))
    } catch {
      report("page.failed", error, userVisible: "翻页出错：")
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

    let preferences = preferencesStore?.value ?? .standard
    let preedit = preferences.markedText(for: output) ?? ""
    if preedit != (markedText ?? "") {
      if preedit.isEmpty {
        if markedText != nil {
          // Unmarking preserves the text. When composition is deleted/cancelled,
          // replace the old marked range before releasing it. A commit above
          // already replaced that range and must be left intact.
          if output.commit?.isEmpty != false {
            textDocumentProxy.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
          }
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
    // The page the bar is showing, kept so a select key can be matched against its labels: a commit clears it,
    // and then no key is a select key any more.
    currentPage = output.page
    candidateBar.setPage(output.page)
    refreshLayout()
  }

  // MARK: - Input

  private func handle(_ key: KeyboardKey) {
    switch key {
    case .character(let value):
      typeLiteralKey(value)
    case .space:
      send(RimeKey.space, fallback: " ")
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
      // S3 §5: one-shot after a tap, caps lock after a double tap. The case control is ours; the
      // 中/英 state is the engine's ascii_mode and is not this key.
      shiftController.tap()
      refreshLayout()
    case .numbers:
      keyLayer = .numbers
      refreshLayout()
    case .symbols:
      keyLayer = .symbols
      refreshLayout()
    case .letters:
      keyLayer = .letters
      refreshLayout()
    case .globe:
      advanceToNextInputMode()
    case .language:
      // S3 §5's 中/英: the state is the engine's ascii_mode, and the key's own label comes from
      // get_state_label on the next layout pass.
      toggleAsciiMode()
    case .emoji:
      // D5, decided here and pending one device check: the key advances to the next input mode, which
      // is where the system emoji keyboard lives. It used to do nothing, which is the worst of the
      // three options — a key that is drawn and then lies. If a device shows the next mode is not the
      // emoji keyboard, D5's fallback applies and the key is removed instead.
      advanceToNextInputMode()
    }
    playFeedback()
  }

  /// S3 §5's key-up feedback: the action has already fired, and both signals are optional. Nothing
  /// here can block the input path — a click and an impact are fire-and-forget.
  private func playFeedback() {
    if feedbackPreferences.keyClickEnabled {
      UIDevice.current.playInputClick()
    }
    if feedbackPreferences.hapticsEnabled {
      haptic.impactOccurred()
    }
  }

  /// A character key: librime first, and the literal character when librime declines it.
  ///
  /// The fallback is not optional. The tracer schema has no punctuator, so librime refuses
  /// "." and "," outright, and without this the key did nothing at all — which users read as
  /// the keyboard dropping input.
  private func typeLiteralKey(_ value: String) {
    // S4 §4.1's select-key row: while composing, a key whose label a candidate carries selects that candidate.
    // Measured in round 172: librime's own selector does not do this for us — with menu/select_keys and
    // menu/alternative_select_labels both set, the label press arrived unhandled — so the page's own labels are
    // matched here and the selection goes through the same call the bar's taps use.
    if let index = currentPage?.selectIndex(matching: value) {
      selectCandidate(index)
      return
    }
    guard let engine, let keysym = RimeKey.ascii(Character(value)) else {
      textDocumentProxy.insertText(value)
      return
    }
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let output = try engine.processKey(keysym)
      if output.needsLiteralFallback {
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
      if output.needsLiteralFallback, let fallback {
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
    keyLatency.record(milliseconds: milliseconds)
    if milliseconds > 50 {
      KeyboardLog.error("slow key: " + String(format: "%.1f ms", milliseconds))
    }
    if keyLatency.isFull {
      flushKeyStatistics()
    }
  }

  private func flushKeyStatistics() {
    guard !keyLatency.isEmpty, case .success(let setup) = KeyboardEngine.setup else { return }
    // The record carries the window's p99, which is the statistic S4 §9's budget names, and its message
    // carries p50/p95/p99/avg: what the summary aggregates is a per-key percentile, not the average of
    // twenty-five keys, which would hide every spike the criterion is about.
    setup.probe?.append(RimeProbeRecord(phase: "keyboard.stats",
                                        milliseconds: keyLatency.p99,
                                        message: keyLatency.message))
    KeyboardLog.info("key stats: " + keyLatency.message)
    keyLatency.reset()
  }

  // MARK: - Presentation

  /// The extension owns content only; its host owns the keyboard background.
  /// Keep this transparent on every appearance, including theme changes.
  private func applyBacking() {
    view.backgroundColor = .clear
    view.isOpaque = false
  }

  private func applyCurrentTheme() {
    theme = KeyboardTheme.current(for: textDocumentProxy.keyboardAppearance ?? .default)
    applyBacking()
    candidateBar.onForget = { [weak self] index in self?.forgetCandidate(index) }
    candidateBar.apply(theme: theme)
    candidatePanel.apply(theme: theme)
    callout.apply(theme: theme)
  }

  // MARK: - Callout

  /// Raises the magnified cap for a key the policy allows one on, positioned by the model's geometry
  /// so it cannot escape the keyboard (S3 §5, R10).
  private func showCallout(for key: RimeKeyboardKey, at point: CGPoint) {
    guard feedbackPreferences.allowsCallout(isPhoneClass: isPhoneClassKeyboard),
          RimeKeyFeedbackPolicy.raisesCallout(key, isPhoneClass: isPhoneClassKeyboard,
                                              isRepeatingDelete: false,
                                              feedback: feedbackPreferences.feedback)
    else {
      calloutKey = nil
      return
    }
    calloutKey = key
    callout.apply(theme: theme)
    let frame = calloutFrame(for: key, at: point)
    callout.show(label: label(for: key), frame: frame)
  }

  private func moveCallout(for key: RimeKeyboardKey, at point: CGPoint) {
    guard calloutKey != nil else { return }
    callout.move(to: calloutFrame(for: key, at: point))
  }

  private func hideCallout() {
    calloutKey = nil
    callout.hide()
  }

  /// The key's frame and the finger, both in the controller's coordinates.
  private func calloutFrame(for key: RimeKeyboardKey, at point: CGPoint) -> CGRect {
    let keyFrame = keyGrid.convert(key.frame, to: view)
    let finger = keyGrid.convert(point, to: view)
    let placed = RimeKeyboardKey(kind: key.kind, frame: keyFrame, label: key.label,
                                 accessibilityLabel: key.accessibilityLabel)
    return RimeCalloutGeometry.frame(for: placed, in: view.bounds, fingerX: finger.x,
                                     feedback: feedbackPreferences.feedback)
  }

  private func label(for key: RimeKeyboardKey) -> String {
    key.label.isEmpty ? key.accessibilityLabel : key.label
  }

  /// iPad-class devices have no callout on the system keyboard either.
  private var isPhoneClassKeyboard: Bool {
    UIDevice.current.userInterfaceIdiom == .phone
  }

  // MARK: - Candidate panel

  private func expandPanel() {
    guard let engine, let candidates = try? engine.candidateList(), !candidates.isEmpty else { return }
    panelCandidates = candidates
    panelPage = 0
    isPanelExpanded = true
    candidatePanel.isHidden = false
    candidateBar.isHidden = true
    keyGrid.isHidden = true
    applyPanelModel()
    updateHeight()
  }

  private func collapsePanel() {
    isPanelExpanded = false
    candidatePanel.isHidden = true
    candidateBar.isHidden = false
    keyGrid.isHidden = false
    updateHeight()
  }

  private func applyPanelModel() {
    let output = try? engine?.refresh()
    let model = RimeCandidatePanelModel.page(panelCandidates, page: panelPage,
                                             highlightedIndex: output?.page?.highlightedIndex,
                                             selectLabels: [],
                                             syllableRow: output?.syllables)
    candidatePanel.apply(theme: theme)
    candidatePanel.apply(model: model)
  }

  private func pagePanel(backward: Bool) {
    panelPage += backward ? -1 : 1
    panelPage = max(0, panelPage)
    applyPanelModel()
  }

  /// A candidate tapped in the panel commits and collapses (S4 §6).
  ///
  /// The index is the panel's, which numbers the whole candidate list; librime's selection call numbers the
  /// candidates on the page it is showing. So the engine is paged to the right page first, and the selection
  /// is made with the page-relative index — the arithmetic lives in `RimeCandidatePanelModel.engineSelection`,
  /// because getting it wrong commits a different candidate than the one that was tapped.
  private func selectFromPanel(_ index: Int) {
    defer { collapsePanel() }
    guard let engine else { return }
    do {
      guard let page = try engine.refresh().page else { return }
      guard let target = RimeCandidatePanelModel.engineSelection(forGlobalIndex: index,
                                                                 pageNumber: page.pageNumber,
                                                                 pageSize: page.pageSize) else { return }
      var current = page.pageNumber
      while current != target.page {
        let moved = try engine.changePage(backward: target.page < current)
        guard let next = moved.page?.pageNumber, next != current else { break }
        current = next
      }
      selectCandidate(target.indexOnPage)
    } catch {
      report("select.failed", error, userVisible: "选词出错：")
    }
  }

  private func refreshLayout() {
    // The keyboard's own preferences live in the app group, so a calibration change reaches the
    // keyboard the next time it appears — no deploy, and nothing for the extension to write.
    let preferences = preferencesStore?.value ?? .standard
    feedbackPreferences = preferences

    // The 中/英 key's label is the schema's word for the state the keyboard is in, never ours.
    let languageKey: RimeLanguageKey?
    if let engine, engine.schemaDeclaresSwitch("ascii_mode") {
      let isASCII = (try? engine.getOption("ascii_mode")) ?? false
      // The schema's own word for the state, and the two words the measured keyboard shows when the
      // schema (or a session-less read) has none. The fallback belongs on this line only: the extra
      // `??` that used to be here was dead code, and the compiler said so once warnings were visible.
      let label = (try? engine.stateLabel(option: "ascii_mode", state: isASCII)) ?? (isASCII ? "英" : "中")
      languageKey = RimeLanguageKey(label: label, isASCII: isASCII)
    } else {
      languageKey = nil
    }

    keyGrid.configure(theme: theme,
                      layer: keyLayer,
                      asciiMode: asciiMode,
                      returnKeyLabel: returnKeyLabel,
                      showsGlobeRow: needsInputModeSwitchKey,
                      shift: shiftController.state,
                      language: languageKey,
                      feedback: preferences.feedback)
  }

  private var preferencesStore: RimeKeyboardPreferencesStore? {
    RimeKeyboardPreferencesStore.appGroup()
  }

  private func updateHeight() {
    // The expanded panel requests only its header and candidate area.
    let height = isPanelExpanded
      ? candidatePanel.height(bottomInset: 0)
      : KeyboardMetrics.totalHeight(needsGlobeRow: needsInputModeSwitchKey)
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
