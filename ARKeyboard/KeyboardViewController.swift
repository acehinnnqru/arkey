import UIKit
import RimeEngine

/// The host may retain another keyboard's height while switching input modes.
/// Report our content height without fitting against that temporary host constraint.
private final class KeyboardInputView: UIInputView {
  var onGeometry: ((String, String) -> Void)?
  var keyboardHeight = KeyboardMetrics.totalHeight(needsGlobeRow: false) {
    didSet {
      guard keyboardHeight != oldValue else { return }
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  }

  override var intrinsicContentSize: CGSize {
    let result = CGSize(width: UIView.noIntrinsicMetric, height: keyboardHeight)
    onGeometry?("intrinsic", "result=\(result)")
    return result
  }

  override var frame: CGRect {
    didSet {
      if frame != oldValue { onGeometry?("frame", "old=\(oldValue) new=\(frame)") }
    }
  }

  override var bounds: CGRect {
    didSet {
      if bounds != oldValue { onGeometry?("bounds", "old=\(oldValue) new=\(bounds)") }
    }
  }

  override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
    let result = CGSize(width: targetSize.width, height: keyboardHeight)
    onGeometry?("fit", "target=\(targetSize) result=\(result)")
    return result
  }

  override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                       withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                       verticalFittingPriority: UILayoutPriority) -> CGSize {
    let result = CGSize(width: targetSize.width, height: keyboardHeight)
    onGeometry?("fitPriorities", "target=\(targetSize) result=\(result)"
      + " horizontal=\(horizontalFittingPriority.rawValue) vertical=\(verticalFittingPriority.rawValue)")
    return result
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    onGeometry?("window", "attached=\(window != nil)")
  }

  override func layoutSubviews() {
    onGeometry?("inputLayout.before", "")
    super.layoutSubviews()
    onGeometry?("inputLayout.after", "")
  }
}

private final class CandidateLoadCancellation {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

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
  private let preferencesStore = RimeKeyboardPreferencesStore.appGroup()
  private var preferences: RimeKeyboardPreferences = .standard
  /// Prepared on touch down so the impact lands with the key rather than after the first use.
  private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
  private var isPanelExpanded = false
  private var loadedCandidates: [RimeCandidateItem] = []
  private var candidateLoadGeneration = 0
  private var candidateLoadCancellation: CandidateLoadCancellation?
  private var nextCandidateIndex = 0
  private var hasMoreCandidates = false
  private static let candidateBatchSize = 96
  private let keyGrid = KeyboardKeyGrid()
  private var heightConstraint: NSLayoutConstraint?
  private var gridHeightConstraint: NSLayoutConstraint?
  private let geometryID = String(UUID().uuidString.prefix(8))
  private let geometryTimeOrigin = DispatchTime.now().uptimeNanoseconds
  private var geometryAppearance = 0
  private var geometrySequence = 0
  private var previousGeometry: [String: String] = [:]
  private var pendingGeometry: [RimeProbeRecord] = []
  private var geometryTrace = KeyboardGeometryTrace()
  private var geometryDisplayLink: CADisplayLink?
  private var geometrySamplingStart: CFTimeInterval?
  private var engine: RimeEngine?
  /// Kept so the appearance can adopt a profile the app activated (S1 §8).
  private var engineSetup: KeyboardEngine.Setup?
  private var theme = KeyboardTheme.current(for: .default)
  private var hasAppliedTheme = false
  private var keyLayer: KeyLayer = .letters
  /// One-shot, caps lock and consumption live in the model, so the states are testable off-device.
  private var shiftController = RimeShiftController()
  private var asciiMode = false
  private var languageKey: RimeLanguageKey?
  private var languageSchemaID: String?
  private var schemaAuxiliaryPrefix: String?
  private var hasResolvedLanguageSchema = false
  private var languageSwitchAvailable = false
  private var markedText: String?
  /// The engine's current page, whose labels decide which physical keys select.
  private var currentPage: RimePage?
  private var candidatePreedit: String?

  // Input latency evidence, flushed to the probe log every 25 keys.
  /// The per-key samples of the current batch. The input path cannot write a record per key (S3-AC5), so the
  /// samples are kept here and one record is written per window — carrying the window's p95, which is the
  /// number S4-AC6 is about.
  private var keyLatency = RimeKeyLatencyWindow()

  deinit {
    geometryDisplayLink?.invalidate()
    candidateLoadCancellation?.cancel()
    engine?.closeSession()
  }

  // MARK: - Lifecycle

  override func loadView() {
    // The host owns the bottom system strip. Our content must cover any
    // previous input mode that remains underneath during a transition.
    let contentView = KeyboardInputView(frame: .zero, inputViewStyle: .default)
    // Honour our fitting height on the first presentation as well as later ones.
    contentView.allowsSelfSizing = true
    contentView.accessibilityIdentifier = "Arkey.keyboardSurface"
    contentView.backgroundColor = theme.background
    contentView.isOpaque = true
    contentView.clipsToBounds = true
    inputView = contentView
    contentView.onGeometry = { [weak self] event, detail in
      self?.recordGeometry(event, detail: detail)
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferences = preferencesStore?.value ?? .standard
    applyBacking()
    // Supply the height before the host begins presenting the extension.
    updateHeight()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (controller: KeyboardViewController, _: UITraitCollection) in
      controller.updateThemeIfNeeded()
    }
    // The host can update the input view's appearance without changing the
    // extension controller's traits at the same time (for example while the
    // keyboard remains presented during a system appearance switch).
    view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self]
      (_: UIView, _: UITraitCollection) in
      self?.updateThemeIfNeeded()
    }

    candidateBar.translatesAutoresizingMaskIntoConstraints = false
    keyGrid.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(candidateBar)
    view.addSubview(keyGrid)

    let gridHeight = keyGrid.heightAnchor.constraint(equalToConstant:
      KeyboardMetrics.totalHeight(needsGlobeRow: needsInputModeSwitchKey)
        - KeyboardMetrics.candidateBarHeight - KeyboardMetrics.keyBottomPadding)
    gridHeight.identifier = "Arkey.gridHeight"
    gridHeightConstraint = gridHeight
    NSLayoutConstraint.activate([
      gridHeight,
      candidateBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      candidateBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      candidateBar.heightAnchor.constraint(equalToConstant: KeyboardMetrics.candidateBarHeight),
      // Keep the content at its measured height and against the bottom while
      // iOS temporarily gives the extension a full-screen launch frame.
      // Pinning both ends to the root stretches the rows during that transition.
      keyGrid.topAnchor.constraint(equalTo: candidateBar.bottomAnchor),
      keyGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      keyGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      // The host owns the system strip; this small gap aligns the last key row with the reference.
      keyGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -KeyboardMetrics.keyBottomPadding),
    ])

    candidatePanel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(candidatePanel)
    NSLayoutConstraint.activate([
      candidatePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      candidatePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      candidatePanel.topAnchor.constraint(equalTo: candidateBar.topAnchor),
      candidatePanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    callout.isHidden = true
    view.addSubview(callout)

    candidatePanel.isHidden = true
    candidatePanel.onSelect = { [weak self] index in self?.selectFromPanel(index) }
    candidatePanel.onCollapse = { [weak self] in self?.collapsePanel() }
    candidatePanel.onNeedsMoreCandidates = { [weak self] in self?.loadMoreCandidates() }

    candidateBar.onSelect = { [weak self] index in
      guard let self else { return }
      self.selectCandidate(index)
      if self.isPanelExpanded { self.collapsePanel() }
    }
    candidateBar.onNeedsMoreCandidates = { [weak self] in self?.loadMoreCandidates() }
    candidateBar.onExpand = { [weak self] in
      guard let self else { return }
      if self.isPanelExpanded { self.collapsePanel() } else { self.expandPanel() }
    }
    keyGrid.onKey = { [weak self] key in self?.handle(key) }
    keyGrid.onKeyTouchDown = { [weak self] key, point in
      self?.haptic.prepare()
      self?.showCallout(for: key, at: point)
    }
    keyGrid.onKeyTouchMove = { [weak self] key, point in self?.moveCallout(for: key, at: point) }
    keyGrid.onKeyTouchEnded = { [weak self] in self?.hideCallout() }
    recordGeometry("loaded", force: true)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    geometryAppearance += 1
    geometryTrace = KeyboardGeometryTrace()
    previousGeometry.removeAll(keepingCapacity: true)
    recordGeometry("willAppear.before", force: true)
    startGeometrySampling()
    preferences = preferencesStore?.value ?? .standard
    applyCurrentTheme()
    refreshLayout()
    updateHeight()
    prepareEngine()
    // A profile the app activated is adopted here, before the first keystroke of this appearance,
    // and only because the composition was just cleared: S1 §8 forbids switching mid-sentence.
    markedText = nil
    try? engine?.clearComposition()
    if engine != nil, let setup = engineSetup {
      KeyboardEngine.adoptProfileIfNeeded(setup, isComposing: false)
      candidateBar.setMessage(KeyboardEngine.statusLine(setup, hasFullAccess: hasFullAccess))
    }
    refreshLanguageKeyFromEngine()
    refreshLayout()
    recordGeometry("willAppear.after", force: true)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    recordGeometry("didAppear", force: true)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    recordGeometry("willDisappear", force: true)
    finishGeometryTrace(reason: "disappear")
    geometryDisplayLink?.invalidate()
    geometryDisplayLink = nil
    if isPanelExpanded { collapsePanel() }
    flushKeyStatistics()
    candidateLoadCancellation?.cancel()
    engine?.closeSession()
    engine = nil
    markedText = nil
    currentPage = nil
    candidateBar.setPage(nil)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    recordGeometry("didDisappear", force: true)
  }

  override func textDidChange(_ textInput: UITextInput?) {
    super.textDidChange(textInput)
    updateThemeIfNeeded()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    recordGeometry("didLayout.before")
    // The host can resolve its switch-key policy after viewWillAppear.
    // Keep the measured height and the rendered rows on the same policy.
    updateHeight()
    refreshLayout()
    updateThemeIfNeeded()
    recordGeometry("didLayout.after")
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    recordGeometry("willLayout")
  }

  private var currentTheme: KeyboardTheme {
    KeyboardTheme.current(for: textDocumentProxy.keyboardAppearance,
                          interfaceStyle: view.traitCollection.userInterfaceStyle,
                          previous: hasAppliedTheme ? theme : nil)
  }

  private func updateThemeIfNeeded() {
    guard currentTheme.appearance != theme.appearance else { return }
    // Do not inherit the host's navigation animation when changing key colours.
    UIView.performWithoutAnimation {
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
      engineSetup = setup
      for record in pendingGeometry {
        // These events already went to the system log before engine setup existed.
        KeyboardLog.geometry(record, probe: setup.probe, includeSystemLog: false)
      }
      pendingGeometry.removeAll(keepingCapacity: true)
      do {
        let start = try setup.engine.start()
        try setup.engine.openSession()
        engine = setup.engine
        refreshLanguageKeyFromEngine()
        refreshLayout()
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
        setup.engine.closeSession()
        engine = nil
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
    candidateLoadCancellation?.cancel()
    do {
      apply(try engine.selectCandidate(at: index))
    } catch {
      report("select.failed", error, userVisible: "选词出错：")
    }
  }

  /// A long press forgets the candidate by its global index, even beyond the engine's current page.
  private func forgetCandidate(_ index: Int) {
    guard let engine else { return }
    if isPanelExpanded { collapsePanel() }
    do {
      candidateLoadCancellation?.cancel()
      let forgotten = try engine.deleteCandidate(at: index)
      apply(try engine.refresh())
      candidateBar.setMessage(forgotten ? "已忘记这个词" : "这个词不在用户词典里")
    } catch {
      report("forget.failed", error, userVisible: "忘记失败：")
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

    let previousAsciiMode = asciiMode
    let previousLanguageKey = languageKey
    asciiMode = output.status?.isAsciiMode ?? asciiMode
    if let status = output.status {
      refreshLanguageKey(schemaID: status.schemaID, isASCII: status.isAsciiMode)
    }
    // The page the bar is showing, kept so a select key can be matched against its labels: a commit clears it,
    // and then no key is a select key any more.
    if currentPage != output.page || output.page == nil || candidatePreedit != output.preedit {
      currentPage = output.page
      candidatePreedit = output.preedit
      resetCandidateList()
    }
    if previousAsciiMode != asciiMode || previousLanguageKey != languageKey {
      refreshLayout()
    }
  }

  // MARK: - Input

  private func handle(_ key: KeyboardKey) {
    switch key {
    case .character(let value):
      typeLiteralKey(value)
      // A single Shift tap applies to one character only. Keep caps lock active.
      if shiftController.state == .on {
        shiftController.consumeAfterCharacter()
        refreshLayout()
      }
    case .auxiliary(let value):
      typeAuxiliaryKey(value)
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
      recordGeometry("advanceInputMode", force: true)
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
      recordGeometry("advanceInputMode.emoji", force: true)
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
  private func typeLiteralKey(_ value: String, allowsCandidateSelection: Bool = true) {
    // S4 §4.1's select-key row: while composing, a key whose label a candidate carries selects that candidate.
    // Measured in round 172: librime's own selector does not do this for us — with menu/select_keys and
    // menu/alternative_select_labels both set, the label press arrived unhandled — so the page's own labels are
    // matched here and the selection goes through the same call the bar's taps use.
    if allowsCandidateSelection, let index = currentPage?.selectIndex(matching: value) {
      let offset = (currentPage?.pageNumber ?? 0) * (currentPage?.pageSize ?? 0)
      selectCandidate(offset + index)
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

  /// This key must follow the same processor path as a physical Rime key. The active
  /// schema's key_binder/search and speller/alphabet decide whether it is an auxiliary code.
  private func typeAuxiliaryKey(_ value: String) {
    guard let engine else {
      textDocumentProxy.insertText(value)
      return
    }
    guard let keysym = value.first.flatMap(RimeKey.ascii) else { return }
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let output = try engine.processKey(keysym)
      if output.needsLiteralFallback { textDocumentProxy.insertText(value) }
      apply(output)
      recordKeyLatency(since: start)
    } catch {
      report("auxiliary.failed", error, userVisible: "辅码输入出错：")
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

  /// An opaque content backing prevents the outgoing emoji keyboard from
  /// showing through between our keys during input-mode transitions.
  private func applyBacking() {
    view.backgroundColor = theme.background
    view.isOpaque = true
  }

  private func applyCurrentTheme() {
    theme = currentTheme
    hasAppliedTheme = true
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
    guard engine != nil, let page = currentPage, !page.candidates.isEmpty else { return }
    candidateBar.layoutIfNeeded()
    // Both presentations share the same candidate list and in-flight request.
    isPanelExpanded = true
    candidateBar.setExpanded(true)
    candidateBar.isHidden = true
    candidatePanel.isHidden = false
    keyGrid.isHidden = true
    applyPanelModel(resetScroll: true)
    candidatePanel.setLoading(loadedCandidates.isEmpty)
    animatePanelAppearance(candidatePanel)
    candidatePanel.requestMoreCandidatesIfNeeded()
  }

  private func resetCandidateList() {
    candidateLoadCancellation?.cancel()
    candidateLoadCancellation = nil
    candidateLoadGeneration += 1
    loadedCandidates = currentPage?.pageNumber == 0 ? currentPage?.candidates ?? [] : []
    nextCandidateIndex = loadedCandidates.count
    // A later engine page can still be enumerated from global index zero.
    hasMoreCandidates = currentPage.map { !$0.candidates.isEmpty && ($0.pageNumber > 0 || !$0.isLastPage) } ?? false
    candidateBar.setPage(nil)
    candidateBar.applyContinuation(loadedCandidates, selectLabels: currentPage?.pageNumber == 0 ? currentPage?.selectLabels ?? [] : [])
    if isPanelExpanded { applyPanelModel(resetScroll: true) }
    loadMoreCandidates()
  }

  private func loadMoreCandidates() {
    guard hasMoreCandidates, candidateLoadCancellation == nil,
          let engine else { return }
    let cancellation = CandidateLoadCancellation()
    candidateLoadCancellation = cancellation
    let generation = candidateLoadGeneration
    let start = nextCandidateIndex
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let candidates = try? engine.candidateList(startingAt: start, limit: Self.candidateBatchSize) {
        !cancellation.isCancelled
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.candidateLoadGeneration == generation,
              !cancellation.isCancelled else { return }
        guard let candidates else {
          self.candidateLoadCancellation = nil
          self.hasMoreCandidates = false
          self.candidatePanel.setLoading(false)
          return
        }
        self.loadedCandidates = Array(self.loadedCandidates.prefix(start)) + candidates
        self.nextCandidateIndex = start + candidates.count
        self.hasMoreCandidates = candidates.count == Self.candidateBatchSize
        self.candidateBar.applyContinuation(self.loadedCandidates,
          selectLabels: self.currentPage?.pageNumber == 0 ? self.currentPage?.selectLabels ?? [] : [])
        self.candidateBar.layoutIfNeeded()
        if self.isPanelExpanded {
          self.applyPanelModel()
          self.candidatePanel.layoutIfNeeded()
        }
        self.candidateLoadCancellation = nil
        // Defer the next request until the collection update has completed.
        DispatchQueue.main.async { [weak self] in
          self?.candidateBar.requestMoreCandidatesIfNeeded()
          if self?.isPanelExpanded == true { self?.candidatePanel.requestMoreCandidatesIfNeeded() }
        }
      }
    }
  }

  private func collapsePanel() {
    guard isPanelExpanded else { return }
    isPanelExpanded = false
    candidateBar.setExpanded(false)
    candidateBar.isHidden = false
    candidatePanel.isHidden = true
    keyGrid.isHidden = false
    candidateBar.requestMoreCandidatesIfNeeded()
    animatePanelAppearance(keyGrid)
  }

  private func animatePanelAppearance(_ appearing: UIView) {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0.65
    fade.toValue = 1
    let slide = CABasicAnimation(keyPath: "transform.translation.y")
    slide.fromValue = 6
    slide.toValue = 0
    let animation = CAAnimationGroup()
    animation.animations = [fade, slide]
    animation.duration = 0.14
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    appearing.layer.add(animation, forKey: "candidateTransition")
  }

  private func applyPanelModel(resetScroll: Bool = false) {
    candidatePanel.apply(theme: theme)
    candidatePanel.applyContinuation(loadedCandidates, startingAt: 0, resetScroll: resetScroll)
  }

  /// A candidate tapped in the panel commits and collapses (S4 §6).
  ///
  /// Both candidate presentations use librime's global candidate index.
  private func selectFromPanel(_ index: Int) {
    defer { collapsePanel() }
    guard let engine else { return }
    candidateLoadCancellation?.cancel()
    guard loadedCandidates.indices.contains(index) else { return }
    do {
      apply(try engine.selectCandidate(at: index))
    } catch {
      report("select.failed", error, userVisible: "选词出错：")
    }
  }

  private func refreshLayout() {
    // The keyboard's own preferences live in the app group, so a calibration change reaches the
    // keyboard the next time it appears — no deploy, and nothing for the extension to write.
    feedbackPreferences = preferences

    keyGrid.configure(theme: theme,
                      layer: keyLayer,
                      asciiMode: asciiMode,
                      returnKeyLabel: returnKeyLabel,
                      spaceKeyLabel: KeyboardKeyLabels.space(language: KeyboardKeyLabels.systemLanguage),
                      showsGlobeRow: needsInputModeSwitchKey,
                      shift: shiftController.state,
                      language: languageKey,
                      feedback: preferences.feedback,
                      auxiliaryPrefix: schemaAuxiliaryPrefix ?? preferences.auxiliaryPrefix,
                      auxiliaryKeySide: preferences.auxiliaryKeySide)
  }

  /// The switch declaration belongs to the schema, not to each keystroke. Reading its
  /// configuration on every layout pass blocks the main thread while a finger is on a key.
  private func refreshLanguageKey(schemaID: String?, isASCII: Bool) {
    guard let engine else { return }
    if !hasResolvedLanguageSchema || schemaID != languageSchemaID {
      languageSchemaID = schemaID
      schemaAuxiliaryPrefix = schemaID.flatMap { id in
        (try? engine.schemaValue("key_binder/search", schemaID: id)?.stringValue)
          .flatMap(RimeKeyboardPreferences.normalizedAuxiliaryPrefix)
      }
      hasResolvedLanguageSchema = true
      languageSwitchAvailable = engine.schemaDeclaresSwitch("ascii_mode")
      languageKey = nil
    }
    guard languageSwitchAvailable else {
      languageKey = nil
      return
    }
    if languageKey?.isASCII == isASCII { return }
    let label = (try? engine.stateLabel(option: "ascii_mode", state: isASCII)) ?? (isASCII ? "英" : "中")
    languageKey = RimeLanguageKey(label: label, isASCII: isASCII)
  }

  private func refreshLanguageKeyFromEngine() {
    guard let engine else { return }
    let schemaID = (try? engine.currentSchema()) ?? nil
    let isASCII = (try? engine.getOption("ascii_mode")) ?? false
    // A profile may replace the same schema ID with new switch labels between appearances.
    hasResolvedLanguageSchema = false
    languageKey = nil
    refreshLanguageKey(schemaID: schemaID, isASCII: isASCII)
  }

  private func updateHeight() {
    // The panel replaces the keys inside this frame; opening it must not resize the host keyboard.
    let height = KeyboardMetrics.totalHeight(needsGlobeRow: needsInputModeSwitchKey)
    let previousHeight = heightConstraint?.constant
    if previousHeight != height {
      recordGeometry("height.before", detail: "old=\(String(describing: previousHeight)) new=\(height)")
    }
    (inputView as? KeyboardInputView)?.keyboardHeight = height
    let gridHeight = height - KeyboardMetrics.candidateBarHeight - KeyboardMetrics.keyBottomPadding
    if gridHeightConstraint?.constant != gridHeight {
      gridHeightConstraint?.constant = gridHeight
    }
    if let heightConstraint {
      if heightConstraint.constant != height {
        heightConstraint.constant = height
      }
    } else {
      let constraint = view.heightAnchor.constraint(equalToConstant: height)
      constraint.identifier = "Arkey.keyboardHeight"
      constraint.priority = UILayoutPriority(999)
      view.addConstraint(constraint)
      heightConstraint = constraint
    }
    if previousHeight != height {
      recordGeometry("height.after", detail: "old=\(String(describing: previousHeight)) new=\(height)")
    }
  }

  /// Geometry only: never include the text proxy, composition, or candidate contents.
  /// Deduplicate identical callbacks, but retain every changed frame during a transition.
  private func recordGeometry(_ event: String, detail: String = "", force: Bool = false) {
    guard isViewLoaded, !geometryTrace.isFinished else { return }
    let root = view!
    let number: (CGFloat) -> String = { String(format: "%.2f", $0) }
    let rect: (CGRect) -> String = {
      [number($0.minX), number($0.minY), number($0.width), number($0.height)].joined(separator: ",")
    }
    let insets: (UIEdgeInsets) -> String = {
      [number($0.top), number($0.left), number($0.bottom), number($0.right)].joined(separator: ",")
    }
    var parts = ["needsGlobe=\(needsInputModeSwitchKey)",
                 "fullAccess=\(hasFullAccess)",
                 "requested=\(heightConstraint.map { number($0.constant) } ?? "nil")",
                 "fittingHeight=\((inputView as? KeyboardInputView).map { number($0.keyboardHeight) } ?? "nil")",
                 "selfSizing=\(inputView?.allowsSelfSizing == true)",
                 "frame=\(rect(root.frame))", "bounds=\(rect(root.bounds))",
                 "presentation=\(root.layer.presentation().map { rect($0.frame) } ?? "nil")",
                 "safe=\(insets(root.safeAreaInsets))",
                 "candidate=\(rect(candidateBar.frame))", "grid=\(rect(keyGrid.frame))",
                 "panelExpanded=\(isPanelExpanded)"]
    if let window = root.window {
      parts += ["window=\(rect(window.bounds))", "windowSafe=\(insets(window.safeAreaInsets))",
                "rootInWindow=\(rect(root.convert(root.bounds, to: window)))",
                "screen=\(rect(window.screen.bounds))", "scale=\(number(window.screen.scale))",
                "orientation=\(window.windowScene?.interfaceOrientation.rawValue ?? 0)"]
    } else {
      parts.append("window=nil")
    }
    let itemName: (Any?) -> String = {
      guard let item = $0 else { return "none" }
      if let itemView = item as? UIView {
        return NSStringFromClass(type(of: itemView)) + (itemView === root ? "(root)" : "")
      }
      return "layoutGuide"
    }
    var ancestor: UIView? = root
    for depth in 0..<6 {
      guard let current = ancestor else { break }
      let constraints = current.constraints.filter {
        $0.isActive && ($0.firstAttribute == .height || $0.secondAttribute == .height)
      }.prefix(12).map {
        "\($0.identifier ?? "anonymous"):\($0.firstAttribute.rawValue)"
          + ":\($0.relation.rawValue):\($0.secondAttribute.rawValue)"
          + ":c\(number($0.constant)):m\(number($0.multiplier)):p\(number(CGFloat($0.priority.rawValue)))"
          + ":first[\(itemName($0.firstItem))]:second[\(itemName($0.secondItem))]"
      }.joined(separator: "|")
      parts.append("ancestor\(depth)=\(NSStringFromClass(type(of: current)))"
        + " frame[\(rect(current.frame))] bounds[\(rect(current.bounds))] safe[\(insets(current.safeAreaInsets))]"
        + " presentation[\(current.layer.presentation().map { rect($0.frame) } ?? "nil")]"
        + " heights[\(constraints)]")
      ancestor = current.superview
    }
    if !detail.isEmpty { parts.append(detail) }
    let snapshot = parts.joined(separator: " ")
    guard force || previousGeometry[event] != snapshot else { return }
    previousGeometry[event] = snapshot
    geometrySequence += 1
    let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - geometryTimeOrigin) / 1_000_000
    let message = "geometry event=\(event) id=\(geometryID) pid=\(ProcessInfo.processInfo.processIdentifier)"
      + " appearance=\(geometryAppearance) seq=\(geometrySequence) build=\(version) trace=height-3"
      + " tMs=\(String(format: "%.3f", elapsed)) " + snapshot
    geometryTrace.record(height: max(root.bounds.height, root.layer.presentation()?.bounds.height ?? 0),
                         requestedHeight: heightConstraint?.constant,
                         needsGlobe: needsInputModeSwitchKey, message: message)
  }

  private func finishGeometryTrace(reason: String) {
    guard let summary = geometryTrace.finish(reason: reason) else { return }
    let record = RimeProbeRecord(phase: "keyboard.geometry.summary", message: summary)
    KeyboardLog.geometry(record, probe: engineSetup?.probe)
    if engineSetup == nil {
      // Preserve first-load measurements until the existing probe location is resolved.
      if pendingGeometry.count < 64 { pendingGeometry.append(record) }
    }
  }

  /// Sample the actual animation frames briefly, including ancestor layers that
  /// can animate without changing this controller's model frames or constraints.
  private func startGeometrySampling() {
    geometryDisplayLink?.invalidate()
    geometrySamplingStart = nil
    let link = CADisplayLink(target: self, selector: #selector(sampleGeometryFrame(_:)))
    geometryDisplayLink = link
    link.add(to: .main, forMode: .common)
  }

  @objc private func sampleGeometryFrame(_ link: CADisplayLink) {
    if geometrySamplingStart == nil { geometrySamplingStart = link.timestamp }
    recordGeometry("displayFrame")
    if link.timestamp - (geometrySamplingStart ?? link.timestamp) >= 0.75 {
      finishGeometryTrace(reason: "settled")
      link.invalidate()
      geometryDisplayLink = nil
    }
  }

  /// Native keyboards label the return key from the client's return key type.
  private var returnKeyLabel: String {
    KeyboardKeyLabels.returnKey(textDocumentProxy.returnKeyType ?? .default,
                                language: KeyboardKeyLabels.systemLanguage)
  }
}
