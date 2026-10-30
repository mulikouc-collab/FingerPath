import AppKit
import Carbon
import NaturalLanguage
import SwiftUI

/// 刘海下方常驻的屏幕键盘：每个键标出手指编号，按下的键实时亮起；
/// 底部镜像当前输入框的内容、正在打的词和英文，眼睛不用离开键盘。
///
/// 隐私：按键只用来点亮屏幕上的键；只统计「按完马上删」的键名和次数（不记内容），全部只存在本机。
/// 输入框镜像只显示在屏幕上，不保存。输入密码时 macOS 会屏蔽按键监听，密码框也不读取。
@MainActor
final class KeyboardOverlayController: ObservableObject {
    /// 提示等级：完整 → 隐藏字母（只留颜色和编号）→ 只在停顿时显示。
    enum HintLevel: Int, CaseIterable {
        case full, noLetters, onPause

        var title: String {
            switch self {
            case .full: "完整显示"
            case .noLetters: "隐藏字母（只留颜色和编号）"
            case .onPause: "只在停顿时显示"
            }
        }
    }

    static let shared = KeyboardOverlayController()
    private static let enabledKey = "FingerPath.enabled"
    private static let levelKey = "FingerPath.level"
    private static let followKey = "FingerPath.followsInput"
    private static let translationKey = "FingerPath.showsTranslation"

    /// 显示英文翻译（用 macOS 自带的离线翻译，需要 macOS 26 及以上）。
    @Published var showsTranslation: Bool {
        didSet {
            UserDefaults.standard.set(showsTranslation, forKey: Self.translationKey)
            translatedSource = ""
            if !showsTranslation {
                wordEnglish = ""
                sentenceEnglish = ""
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    /// 位置：false = 刘海下方；true = 跟随输入框（紧贴系统候选条，眼睛不用来回跑）。
    @Published var followsInput: Bool {
        didSet {
            UserDefaults.standard.set(followsInput, forKey: Self.followKey)
            hasFollowPosition = false
            DispatchQueue.main.async { [weak self] in self?.resizePanel() }
        }
    }
    @Published var level: HintLevel {
        didSet { UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey) }
    }
    /// 当前按住的键（键码）。
    @Published private(set) var pressed = Set<UInt16>()
    /// 最近按下的键：显示「J · 7 号」。
    @Published private(set) var lastKey: OverlayKey?

    // 输入框镜像
    @Published private(set) var mirrorAvailable = false
    @Published private(set) var committedText = ""
    @Published private(set) var composingText = ""
    @Published private(set) var currentWord = ""
    /// 刚打完（已上屏）的最后一个词，原来空格那一行显示它的英文。
    @Published private(set) var lastCommittedWord = ""
    /// 跟随模式：键盘在候选条下方时，词和整句放在键盘上面（挨着候选条）；否则放在下面。
    @Published private(set) var textRowsOnTop = false
    @Published private(set) var wordEnglish = ""
    /// wordEnglish 是哪个词的翻译：和当前的词对得上才显示，避免「来 → We」这种错位。
    @Published private(set) var wordEnglishFor = ""
    @Published private(set) var sentenceEnglish = ""

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    /// 有时收不到松开事件（比如按键时切换了窗口），按下 0.35 秒后自动熄灭。
    private var releaseTasks: [UInt16: Task<Void, Never>] = [:]
    private var lastKeyAt = Date.distantPast
    /// 上一个字符键和时间：紧接着按删除键，就算这个键打错了一次。
    private var lastCharKey: Character?
    private var lastCharAt = Date.distantPast
    private var translateTask: Task<Void, Never>?
    private var translatedSource = ""

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        level = HintLevel(rawValue: UserDefaults.standard.integer(forKey: Self.levelKey)) ?? .full
        followsInput = UserDefaults.standard.object(forKey: Self.followKey) as? Bool ?? true
        showsTranslation = UserDefaults.standard.object(forKey: Self.translationKey) as? Bool ?? true
    }

    func startIfEnabled() {
        if isEnabled { show() }
    }

    func toggle() {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        isEnabled ? show() : hide()
    }

    // MARK: - 窗口

    private func show() {
        let panel = panel ?? makePanel()
        hasFollowPosition = false
        position(panel)
        panel.alphaValue = 1
        lastKeyAt = Date()  // 刚打开时先完整显示 3 秒
        panel.orderFrontRegardless()
        startMonitoring()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func hide() {
        stopMonitoring()
        timer?.invalidate()
        timer = nil
        translateTask?.cancel()
        pressed.removeAll()
        lastKey = nil
        clearMirror()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 330),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // 鼠标直接穿过去，不挡后面的操作。
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let hosting = NSHostingView(rootView: KeyboardOverlayView(controller: self))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        self.panel = panel
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, self.isEnabled, !self.followsInput else { return }
                self.position(panel)
            }
        }
        return panel
    }

    /// 跟随模式不显示底部镜像，面板变小；切回刘海下方时恢复。
    private func resizePanel() {
        guard let panel, let content = panel.contentView else { return }
        panel.setContentSize(content.fittingSize)
        if !followsInput { position(panel) }
    }

    /// 放在刘海（菜单栏）正下方、屏幕居中。
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - max(menuBarHeight, 32) - size.height - 6
        ))
    }

    private var hasFollowPosition = false

    /// 跟随输入框：紧贴系统候选条，放在候选条远离文字的那一侧（候选条在文字上方 → 键盘贴在它正上方）。
    /// 没在打拼音（没有候选条）时停在原地，避免乱跑；第一次先按输入框位置放好。
    private func moveNear(_ snapshot: FocusedTextSnapshot, pid: pid_t) {
        guard let panel else { return }
        let element = snapshot.elementFrame
        let line = snapshot.caretLineFrame
        let anchor = (element.width > 1 && element.height > 1 && element.height <= 220) ? element
            : (line.width > 1 ? line : .zero)
        guard anchor.width > 1,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let gap: CGFloat = 4
        var target: NSPoint
        if let bar = Self.candidateBarRect(ownerPID: pid) {
            let textMid = (line.width > 1 ? line : anchor).midY
            let keyboardAboveBar = bar.midY > textMid
            let y = keyboardAboveBar ? bar.maxY + gap : bar.minY - gap - size.height
            target = NSPoint(x: bar.minX - 12, y: y)
            if textRowsOnTop == keyboardAboveBar { textRowsOnTop = !keyboardAboveBar }
        } else if !hasFollowPosition {
            // 还没出现过候选条：按输入框放，中间留出候选条的高度。
            let imeRoom: CGFloat = 50
            var y = anchor.minY - imeRoom - size.height
            let keyboardAbove = y < visible.minY + 4
            if keyboardAbove { y = anchor.maxY + imeRoom }
            target = NSPoint(x: anchor.midX - size.width / 2, y: y)
            textRowsOnTop = !keyboardAbove
        } else {
            return
        }
        target.x = min(max(target.x, visible.minX + 4), visible.maxX - size.width - 4)
        target.y = min(max(target.y, visible.minY + 4), visible.maxY - size.height - 4)
        hasFollowPosition = true
        // 移动不到 24 点就不动，避免打字时键盘抖来抖去。
        guard abs(panel.frame.origin.x - target.x) > 24 || abs(panel.frame.origin.y - target.y) > 24 else { return }
        panel.setFrame(NSRect(origin: target, size: size), display: true, animate: true)
    }

    /// 系统候选条：当前软件名下、浮在普通窗口之上的细长小窗口（AppKit 坐标）。
    private static func candidateBarRect(ownerPID: pid_t) -> CGRect? {
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for info in infos {
            guard info[kCGWindowOwnerPID as String] as? pid_t == ownerPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let w = b["Width"] ?? 0, h = b["Height"] ?? 0
            let horizontal = w >= 120 && h >= 18 && h <= 70
            let vertical = w >= 80 && w <= 320 && h > 70 && h <= 420
            guard horizontal || vertical else { continue }
            return CGRect(x: b["X"] ?? 0, y: primaryTop - (b["Y"] ?? 0) - h, width: w, height: h)
        }
        return nil
    }

    // MARK: - 定时：淡入淡出 + 输入框镜像

    private func tick() {
        updateVisibility()
        updateMirror()
    }

    /// 完整 / 隐藏字母：停止打字 3 秒后慢慢淡出直到消失，一按键马上亮起。
    /// 只在停顿时显示：打字时隐藏，停顿 1.5 秒出现，10 秒后再淡出。
    private func updateVisibility() {
        guard let panel else { return }
        let idle = Date().timeIntervalSince(lastKeyAt)
        let target: CGFloat
        switch level {
        case .full, .noLetters:
            target = idle > 3 ? 0 : 1
        case .onPause:
            target = (idle > 1.5 && idle < 10) ? 1 : 0
        }
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = target > panel.alphaValue ? 0.12 : 1.5
            panel.animator().alphaValue = target
        }
    }

    private func updateMirror() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard let snapshot = FocusedTextReader.read(), snapshot.isEditable else {
            if mirrorAvailable || !committedText.isEmpty { clearMirror() }
            return
        }
        mirrorAvailable = true
        if followsInput, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            moveNear(snapshot, pid: pid)
        }
        let paragraph = snapshot.text.trimmingCharacters(in: .newlines)
        let (committed, composing) = Self.splitComposing(paragraph)
        committedText = String(committed.suffix(60))
        composingText = composing
        currentWord = composing.isEmpty ? Self.lastWord(of: committed) : composing
        lastCommittedWord = Self.lastWord(of: committed)
        translateIfNeeded(committed)
    }

    private func clearMirror() {
        mirrorAvailable = false
        committedText = ""
        composingText = ""
        currentWord = ""
        lastCommittedWord = ""
        wordEnglish = ""
        sentenceEnglish = ""
        translatedSource = ""
    }

    /// 输入框末尾的小写拼音就是还没选字的部分（例如「我想学习zhong wen」）。
    static func splitComposing(_ text: String) -> (committed: String, composing: String) {
        guard let range = text.range(of: "[a-z' ]+$", options: .regularExpression) else { return (text, "") }
        let before = text[..<range.lowerBound]
        guard let last = before.last, TextLanguage.detect(String(last)) == .chinese else { return (text, "") }
        return (String(before), String(text[range]).trimmingCharacters(in: .whitespaces))
    }

    /// 最后一个词：中文用系统分词，英文取最后一个单词。
    static func lastWord(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else { return "" }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        var last = ""
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            last = String(trimmed[range])
            return true
        }
        return last
    }

    /// 打中文时：停顿 0.5 秒翻译当前词和整句。打英文就不翻（已经是英文了）。
    private func translateIfNeeded(_ committed: String) {
        let source = String(committed.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard showsTranslation, source != translatedSource else { return }
        translatedSource = source
        translateTask?.cancel()
        guard !source.isEmpty, TextLanguage.detect(source) == .chinese else {
            wordEnglish = ""
            sentenceEnglish = ""
            return
        }
        let word = Self.lastWord(of: source)
        translateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // 先翻译词（快），再翻译整句。
            if !word.isEmpty, word != source, let wordResult = try? await TranslationService.shared.translate(word) {
                guard !Task.isCancelled, let self else { return }
                self.wordEnglish = wordResult.translated
                self.wordEnglishFor = word
            }
            let sentence = try? await TranslationService.shared.translate(source)
            guard !Task.isCancelled, let self else { return }
            self.sentenceEnglish = sentence?.translated ?? ""
            if word == source {
                self.wordEnglish = self.sentenceEnglish
                self.wordEnglishFor = word
            }
        }
    }

    // MARK: - 按键

    private func startMonitoring() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type, code = event.keyCode, flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handle(type: type, code: code, flags: flags) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type, code = event.keyCode, flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handle(type: type, code: code, flags: flags) }
            return event
        }
    }

    private func stopMonitoring() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags) {
        switch type {
        case .keyDown:
            press(code)
        case .keyUp:
            release(code)
        case .flagsChanged:
            // Shift：按下时 flags 里有 shift，松开时没有。
            guard code == UInt16(kVK_Shift) || code == UInt16(kVK_RightShift) else { return }
            flags.contains(.shift) ? press(code) : release(code)
        default:
            break
        }
    }

    private func press(_ code: UInt16) {
        guard let key = OverlayKey.byCode[code] else { return }
        lastKeyAt = Date()
        countMistakeIfNeeded(key)
        pressed.insert(code)
        lastKey = key
        releaseTasks[code]?.cancel()
        releaseTasks[code] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.pressed.remove(code)
        }
        updateVisibility()
    }

    /// 字符键之后 1.5 秒内按了删除键：算那个字符键打错一次。只记键名，不记内容。
    private func countMistakeIfNeeded(_ key: OverlayKey) {
        if key.code == UInt16(kVK_Delete) {
            if let lastCharKey, Date().timeIntervalSince(lastCharAt) < 1.5 {
                KeyStats.record(lastCharKey)
            }
            lastCharKey = nil   // 按住删除键连删只算一次
        } else if let character = key.character {
            lastCharKey = character
            lastCharAt = Date()
        }
    }

    private func release(_ code: UInt16) {
        // 松开后再亮一小会儿，看得清按了哪个。
        releaseTasks[code]?.cancel()
        releaseTasks[code] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.pressed.remove(code)
        }
    }
}

/// 屏幕键盘上的一个键：键码（与输入法无关）、显示文字、宽度、负责的手指。
struct OverlayKey: Hashable {
    let code: UInt16
    let label: String
    let width: CGFloat
    let finger: Finger

    var isHome: Bool { ["A", "S", "D", "F", "J", "K", "L", ";"].contains(label) }
    /// F 和 J：有小凸点的定位键，手指回家的地方。
    var isAnchor: Bool { label == "F" || label == "J" }
    /// 单个字符的键（字母、数字、符号），用于统计打错的键。
    var character: Character? { label.count == 1 ? label.lowercased().first : nil }

    private static func key(_ code: Int, _ label: String, _ width: CGFloat = 1, finger: Finger? = nil) -> OverlayKey {
        OverlayKey(
            code: UInt16(code),
            label: label,
            width: width,
            finger: finger ?? Finger.of(Character(label.lowercased().prefix(1).description))
        )
    }

    /// 标准 ANSI 键盘布局（按键码定位，开着中文输入法也准确）。
    static let rows: [[OverlayKey]] = [
        [key(kVK_ANSI_Grave, "`"), key(kVK_ANSI_1, "1"), key(kVK_ANSI_2, "2"), key(kVK_ANSI_3, "3"),
         key(kVK_ANSI_4, "4"), key(kVK_ANSI_5, "5"), key(kVK_ANSI_6, "6"), key(kVK_ANSI_7, "7"),
         key(kVK_ANSI_8, "8"), key(kVK_ANSI_9, "9"), key(kVK_ANSI_0, "0"), key(kVK_ANSI_Minus, "-"),
         key(kVK_ANSI_Equal, "="), key(kVK_Delete, "⌫", 1.6, finger: .rightPinky)],
        [key(kVK_Tab, "⇥", 1.6, finger: .leftPinky), key(kVK_ANSI_Q, "Q"), key(kVK_ANSI_W, "W"),
         key(kVK_ANSI_E, "E"), key(kVK_ANSI_R, "R"), key(kVK_ANSI_T, "T"), key(kVK_ANSI_Y, "Y"),
         key(kVK_ANSI_U, "U"), key(kVK_ANSI_I, "I"), key(kVK_ANSI_O, "O"), key(kVK_ANSI_P, "P"),
         key(kVK_ANSI_LeftBracket, "["), key(kVK_ANSI_RightBracket, "]"), key(kVK_ANSI_Backslash, "\\")],
        [key(kVK_CapsLock, "⇪", 1.9, finger: .leftPinky), key(kVK_ANSI_A, "A"), key(kVK_ANSI_S, "S"),
         key(kVK_ANSI_D, "D"), key(kVK_ANSI_F, "F"), key(kVK_ANSI_G, "G"), key(kVK_ANSI_H, "H"),
         key(kVK_ANSI_J, "J"), key(kVK_ANSI_K, "K"), key(kVK_ANSI_L, "L"), key(kVK_ANSI_Semicolon, ";"),
         key(kVK_ANSI_Quote, "'"), key(kVK_Return, "⏎", 1.7, finger: .rightPinky)],
        [key(kVK_Shift, "⇧", 2.4, finger: .leftPinky), key(kVK_ANSI_Z, "Z"), key(kVK_ANSI_X, "X"),
         key(kVK_ANSI_C, "C"), key(kVK_ANSI_V, "V"), key(kVK_ANSI_B, "B"), key(kVK_ANSI_N, "N"),
         key(kVK_ANSI_M, "M"), key(kVK_ANSI_Comma, ","), key(kVK_ANSI_Period, "."),
         key(kVK_ANSI_Slash, "/"), key(kVK_RightShift, "⇧", 2.2, finger: .rightPinky)],
    ]

    static let byCode: [UInt16: OverlayKey] = Dictionary(
        rows.flatMap { $0 }.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first }
    )
}

private struct KeyboardOverlayView: View {
    @ObservedObject var controller: KeyboardOverlayController

    private let unit: CGFloat = 34
    private let gap: CGFloat = 4

    var body: some View {
        VStack(spacing: gap) {
            if controller.followsInput && controller.textRowsOnTop {
                sentenceRow
                wordRow
            }
            keyRows
            if controller.followsInput && !controller.textRowsOnTop {
                wordRow
                sentenceRow
            }
            // 刘海下方模式：底部是完整镜像（输入框、词、整句）。用 overlay，宽度跟着键盘走。
            if !controller.followsInput {
                Color.clear
                    .frame(height: 84)
                    .overlay(alignment: .topLeading) { footer }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .padding(8)
        .fixedSize()
    }

    private var keyRows: some View {
        VStack(spacing: gap) {
            ForEach(OverlayKey.rows.indices, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(Array(OverlayKey.rows[row].enumerated()), id: \.element) { index, key in
                        // 左手最后一个键和右手第一个键之间多留一道空隙，一眼分出左右手。
                        if index > 0, OverlayKey.rows[row][index - 1].finger.isLeft, !key.finger.isLeft,
                           key.finger != .rightThumb {
                            Rectangle()
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 2, height: unit - 10)
                                .padding(.horizontal, 3)
                        }
                        keyCap(key)
                    }
                }
            }
        }
    }

    /// 整句英文：小一号的灰字，太长时只显示最后一段（刚打的部分）。
    private var sentenceRow: some View {
        Color.clear
            .frame(height: 18)
            .overlay(alignment: .leading) {
                Text(controller.sentenceEnglish.isEmpty ? " " : controller.sentenceEnglish)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 4)
            }
    }

    private func keyCap(_ key: OverlayKey) -> some View {
        let isPressed = controller.pressed.contains(key.code)
        let width = unit * key.width + gap * (key.width - 1).rounded(.down)
        // 「隐藏字母」等级：字母和数字不显示，只留颜色和手指编号（功能键照常显示）。
        let showLabel = controller.level != .noLetters || key.character == nil
        return ZStack(alignment: .topTrailing) {
            Text(showLabel ? key.label : "")
                .font(.system(size: key.label.count > 1 ? 11 : 14,
                              weight: isPressed || key.isAnchor ? .heavy : .medium, design: .rounded))
                .frame(width: width, height: unit - 4)
            Text(key.finger == .rightThumb ? "5/6" : "\(key.finger.number)")
                .font(.system(size: 10, weight: .heavy).monospacedDigit())
                .padding(.trailing, 3)
                .padding(.top, 1)
            if key.isAnchor {
                Text("⌂")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.leading, 3)
                    .padding(.top, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 按下：黑底白字，不靠颜色也一眼能看出来。
        .foregroundStyle(isPressed ? Color.white : FingerPalette.text(key.finger))
        .background(
            isPressed ? Color.black : FingerPalette.color(key.finger),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            // 定位键 F / J：最粗的黑框；其他起始键：细黑框。
            RoundedRectangle(cornerRadius: 6)
                .stroke(isPressed ? Color.white
                        : (key.isAnchor ? Color.black : (key.isHome ? Color.black.opacity(0.6) : .clear)),
                        lineWidth: key.isAnchor ? 3.5 : 1.5)
        }
        .overlay(alignment: .bottom) {
            // F 和 J 上的小凸点，画得又粗又黑。
            if key.isAnchor {
                Capsule()
                    .fill(isPressed ? Color.white : Color.black)
                    .frame(width: 14, height: 4)
                    .padding(.bottom, 3)
            }
        }
        .scaleEffect(isPressed ? 1.12 : 1)
        .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    /// 底部：镜像当前输入框 → 正在打的词和英文 → 整句英文。
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if controller.mirrorAvailable {
                // 1. 输入框镜像：已经上屏的字 + 没选完的拼音（橙色下划线）
                (Text(controller.committedText)
                    + Text(controller.composingText.isEmpty ? "" : controller.composingText)
                        .foregroundColor(.orange).underline()
                    + Text("▏").foregroundColor(.orange))
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                // 2. 正在打的词 → 英文
                HStack(spacing: 8) {
                    Text(controller.currentWord.isEmpty ? "—" : controller.currentWord)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                    if !controller.wordEnglish.isEmpty {
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        Text(controller.wordEnglish)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(red: 0.0, green: 0.45, blue: 0.70))
                    }
                    Spacer(minLength: 4)
                    lastKeyHint
                }
                .lineLimit(1)
                // 3. 整句英文
                Text(controller.sentenceEnglish.isEmpty ? " " : controller.sentenceEnglish)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                HStack {
                    Text("点进一个输入框打字，这里会同步显示你打的内容和英文。微信等软件读不到输入框。")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    lastKeyHint
                }
                .font(.system(size: 12))
            }
        }
    }

    /// 刚打的词 → 英文（一行，高度和一排键一样）。
    private var wordRow: some View {
        Color.clear
            .frame(height: unit - 4)
            .overlay(alignment: .leading) {
                HStack(spacing: 8) {
                    if controller.lastCommittedWord.isEmpty {
                        Text("打一个词，这里显示它的英文")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(controller.lastCommittedWord)
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        // 译文还没回来（或者属于上一个词）时显示「…」。
                        if controller.wordEnglishFor == controller.lastCommittedWord, !controller.wordEnglish.isEmpty {
                            Text(controller.wordEnglish)
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color(red: 0.0, green: 0.45, blue: 0.70))
                        } else {
                            Text("…").foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    lastKeyHint
                }
                .lineLimit(1)
                .padding(.horizontal, 4)
            }
    }

    private var lastKeyHint: some View {
        Group {
            if let key = controller.lastKey {
                HStack(spacing: 4) {
                    Text(key.label).font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(key.finger == .rightThumb ? "5/6 号" : "\(key.finger.number) 号")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
