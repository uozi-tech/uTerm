import XCTest
@testable import uTermMobile

/// 远程桌面的键盘：英文键盘发按键给 Mac 的输入法，其他语言在手机上组字、把结果按 Unicode 发过去。
@MainActor
final class RemoteKeyInputTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func press(_ code: UInt16, _ modifiers: RemoteKeyModifiers = []) -> [RemoteDesktopInput] {
        [.key(code: code, down: true, modifiers: modifiers), .key(code: code, down: false, modifiers: modifiers)]
    }

    private let a: UInt16 = 0x00, c: UInt16 = 0x08, one: UInt16 = 0x12

    /// 一个接好的输入视图和它发出的全部输入。
    private func input(language: String?, keys: RemoteDesktopKeyState = RemoteDesktopKeyState())
        -> (view: RemoteKeyInputView, sent: () -> [RemoteDesktopInput]) {
        let view = RemoteKeyInputView()
        view.languageOverride = language
        view.keys = keys
        var sent: [RemoteDesktopInput] = []
        view.send = { sent.append($0) }
        return (view, { sent })
    }

    private func mounted(_ view: UIView) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        view.frame = CGRect(x: 0, y: 650, width: 400, height: 48)
        window.addSubview(view)
        window.isHidden = false
        self.window = window
    }

    // MARK: - 路由

    func testOnlyEnglishKeyboardsSendKeyPresses() {
        XCTAssertTrue(RemoteKeyboardRouting.usesKeyPresses(language: "en-US"))
        XCTAssertTrue(RemoteKeyboardRouting.usesKeyPresses(language: "en-GB"))
        XCTAssertTrue(RemoteKeyboardRouting.usesKeyPresses(language: nil), "拿不到语言时保持原来的行为")
        for language in ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "de-DE", "emoji", "dictation"] {
            XCTAssertFalse(RemoteKeyboardRouting.usesKeyPresses(language: language), language)
        }
    }

    func testEnglishLettersBecomeKeyPressesSoTheMacInputMethodStillWorks() {
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "aA", armed: [], asKeys: true),
                       press(a) + press(a, .shift))
    }

    func testClientLanguageSendsCommittedTextAsUnicode() {
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "你好", armed: [], asKeys: false), [.text("你好")])
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "hello 1", armed: [], asKeys: false), [.text("hello 1")],
                       "发成按键会被 Mac 上开着的拼音截走")
    }

    func testAloneSpaceAndNewlineAreStillKeyPressesInEveryLanguage() {
        for asKeys in [true, false] {
            XCTAssertEqual(RemoteKeyboardRouting.inputs(for: " ", armed: [], asKeys: asKeys), press(RemoteKeyMap.Key.space))
            XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "\n", armed: [], asKeys: asKeys), press(RemoteKeyMap.Key.returnKey))
            XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "\r\n", armed: [], asKeys: asKeys), press(RemoteKeyMap.Key.returnKey))
            XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "\t", armed: [], asKeys: asKeys), press(RemoteKeyMap.Key.tab))
        }
    }

    func testTextIsSplitAroundNewlinesInOrder() {
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "你\n好", armed: [], asKeys: false),
                       [.text("你")] + press(RemoteKeyMap.Key.returnKey) + [.text("好")])
    }

    func testArmedModifierPressesOnlyTheFirstCharacterInAnyLanguage() {
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "c你", armed: .command, asKeys: false),
                       press(c, .command) + [.text("你")])
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "A", armed: .control, asKeys: false),
                       press(a, [.control, .shift]))
    }

    func testCharactersWithoutAKeyFallBackToUnicodeOnEnglishKeyboards() {
        XCTAssertEqual(RemoteKeyboardRouting.inputs(for: "a😀1", armed: [], asKeys: true),
                       press(a) + [.text("😀")] + press(one))
    }

    // MARK: - 组字

    func testPinyinCompositionSendsNothingUntilACandidateIsChosen() {
        let (view, sent) = input(language: "zh-Hans")
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(view.text(in: view.markedTextRange!), "ni", "输入法要能读回正在组的字")
        XCTAssertEqual(sent(), [], "没选词之前什么都不能发给 Mac")

        view.insertText("你")

        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(sent(), [.text("你")])
    }

    func testUnmarkCommitsWhatIsBeingComposedExactlyOnce() {
        let (view, sent) = input(language: "zh-Hans")
        view.setMarkedText("hello", selectedRange: NSRange(location: 5, length: 0))
        view.unmarkText()
        view.unmarkText()
        XCTAssertEqual(sent(), [.text("hello")])
    }

    func testBackspaceEditsTheCompositionBeforeItReachesTheMac() {
        let (view, sent) = input(language: "zh-Hans")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.deleteBackward()
        XCTAssertEqual(view.text(in: view.markedTextRange!), "n")
        view.deleteBackward()
        XCTAssertNil(view.markedTextRange, "删光了就不在组字了")
        XCTAssertEqual(sent(), [])

        view.deleteBackward()
        XCTAssertEqual(sent(), press(RemoteKeyMap.Key.delete), "没在组字时才是 Mac 上的退格")
    }

    func testClearingTheCompositionSendsNothing() {
        let (view, sent) = input(language: "zh-Hans")
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(view.markedTextRange)
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(sent(), [])
    }

    func testCompositionIsShownOnScreenAndHiddenAfterCommit() throws {
        let (view, _) = input(language: "zh-Hans")
        try mounted(view)
        let label = try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertTrue(label.isHidden)

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.layoutIfNeeded()
        XCTAssertEqual(label.text, "ni")
        XCTAssertFalse(label.isHidden)
        XCTAssertGreaterThan(label.frame.width, 0)
        XCTAssertTrue(view.bounds.contains(label.frame), "要画在视图里，画布裁掉就看不见了")

        view.insertText("你")
        XCTAssertTrue(label.isHidden)
    }

    func testArmedShortcutOnAChineseKeyboardDoesNotStartComposing() {
        let keys = RemoteDesktopKeyState()
        keys.toggle(.command)
        let (view, sent) = input(language: "zh-Hans", keys: keys)

        view.setMarkedText("c", selectedRange: NSRange(location: 1, length: 0))

        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(sent(), press(c, .command))
        XCTAssertEqual(keys.modifiers, [], "修饰键用完熄灭")
    }

    func testArmedModifierWaitsWhileAlreadyComposing() {
        let (view, sent) = input(language: "zh-Hans")
        view.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        view.keys?.toggle(.command)

        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        view.insertText("你")

        XCTAssertEqual(sent(), [.text("你")])
        XCTAssertEqual(view.keys?.modifiers, .command, "上屏不消耗修饰键")
    }

    func testEmptyDocumentAnswersTheTextSystemWithoutCrashing() throws {
        let (view, _) = input(language: "zh-Hans")
        XCTAssertTrue(view.hasText, "否则系统不发退格，Mac 上删不了字")
        XCTAssertEqual(view.compare(view.beginningOfDocument, to: view.endOfDocument), .orderedSame)
        XCTAssertNil(view.position(from: view.beginningOfDocument, offset: 1))
        let everything = try XCTUnwrap(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        XCTAssertEqual(view.text(in: everything), "")
    }

    func testSelectionIsClampedToTheComposition() throws {
        let (view, _) = input(language: "zh-Hans")
        view.setMarkedText("你好", selectedRange: NSRange(location: 99, length: 5))
        let selected = try XCTUnwrap(view.selectedTextRange)
        XCTAssertEqual(view.offset(from: view.beginningOfDocument, to: selected.start), 2)
        XCTAssertTrue(selected.isEmpty)
    }

    func testPositionsMoveWithinTheComposition() throws {
        let (view, _) = input(language: "zh-Hans")
        view.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
        let two = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: 2))
        let range = try XCTUnwrap(view.textRange(from: two, to: view.endOfDocument))
        XCTAssertEqual(view.text(in: range), "hao")
        XCTAssertEqual(view.compare(two, to: view.endOfDocument), .orderedAscending)
        XCTAssertNil(view.position(from: view.endOfDocument, offset: 1))
    }

    // MARK: - 键盘语言

    func testKeyboardCanSwitchLanguages() {
        XCTAssertEqual(RemoteKeyInputView().keyboardType, .default, "`.asciiCapable` 的地球键切不到中文")
    }

    func testRemembersTheLanguageWhileItIsStillInstalled() {
        let available = ["en-US", "zh-Hans", "emoji"]
        XCTAssertEqual(RemoteKeyboardRouting.preferredLanguage(saved: "zh-Hans", available: available), "zh-Hans")
        XCTAssertEqual(RemoteKeyboardRouting.preferredLanguage(saved: nil, available: available), "en-US", "没切过默认英文")
        XCTAssertEqual(RemoteKeyboardRouting.preferredLanguage(saved: "ja-JP", available: available), "en-US", "删掉的键盘回到英文")
        XCTAssertNil(RemoteKeyboardRouting.preferredLanguage(saved: nil, available: ["zh-Hans"]), "没有英文键盘时交给系统")
    }

    func testEmojiAndDictationAreNotRememberedAsTheLanguage() {
        XCTAssertTrue(RemoteKeyboardRouting.isRememberable(language: "zh-Hans"))
        XCTAssertFalse(RemoteKeyboardRouting.isRememberable(language: "emoji"))
        XCTAssertFalse(RemoteKeyboardRouting.isRememberable(language: "dictation"))
    }

    // MARK: - 外接键盘

    private let hidA = 0x04, hidReturn = 0x28, hidLeft = 0x50, hidSpace = 0x2C

    func testExternalKeyboardGoesToTheMacOnEnglish() {
        XCTAssertFalse(RemoteKeyboardRouting.leavesToSystem(hidUsage: hidA, flags: [], armed: false, composing: false, asKeys: true))
    }

    func testPrintableExternalKeysFeedTheClientInputMethod() {
        for usage in [hidA, hidSpace, 0x1E, 0x38] {
            XCTAssertTrue(RemoteKeyboardRouting.leavesToSystem(hidUsage: usage, flags: [], armed: false, composing: false, asKeys: false))
        }
        XCTAssertTrue(RemoteKeyboardRouting.leavesToSystem(hidUsage: hidA, flags: .shift, armed: false, composing: false, asKeys: false))
    }

    func testControlKeysAndShortcutsStillGoToTheMacWhenNotComposing() {
        XCTAssertFalse(RemoteKeyboardRouting.leavesToSystem(hidUsage: hidReturn, flags: [], armed: false, composing: false, asKeys: false))
        XCTAssertFalse(RemoteKeyboardRouting.leavesToSystem(hidUsage: hidLeft, flags: [], armed: false, composing: false, asKeys: false))
        for flag: UIKeyModifierFlags in [.command, .control, .alternate] {
            XCTAssertFalse(RemoteKeyboardRouting.leavesToSystem(hidUsage: hidA, flags: flag, armed: false, composing: false, asKeys: false))
        }
        XCTAssertFalse(RemoteKeyboardRouting.leavesToSystem(hidUsage: hidA, flags: [], armed: true, composing: false, asKeys: false))
    }

    func testEverythingGoesToTheInputMethodWhileComposing() {
        for usage in [hidA, hidReturn, hidLeft] {
            XCTAssertTrue(RemoteKeyboardRouting.leavesToSystem(hidUsage: usage, flags: [], armed: false, composing: true, asKeys: false),
                          "方向键选词、回车上屏")
        }
    }

    // MARK: - 收键盘

    /// 键盘按钮收键盘走在 SwiftUI 更新视图期间，这时回调写 Binding 就是
    /// 「Modifying state during view update」。
    func testDismissingFromOutsideDoesNotCallBack() throws {
        let (view, _) = input(language: nil)
        try mounted(view)
        var resigned = 0
        view.onResign = { resigned += 1 }
        XCTAssertTrue(view.becomeFirstResponder())

        view.dismissKeyboard()

        XCTAssertFalse(view.isFirstResponder)
        XCTAssertEqual(resigned, 0)
    }

    func testSystemTakingTheKeyboardAwayIsReported() throws {
        let (view, _) = input(language: nil)
        try mounted(view)
        var resigned = 0
        view.onResign = { resigned += 1 }
        XCTAssertTrue(view.becomeFirstResponder())

        XCTAssertTrue(view.resignFirstResponder())

        XCTAssertEqual(resigned, 1, "按钮图标要跟上真实状态")
    }

    func testDismissStaysQuietOnlyForThatOneDismiss() throws {
        let (view, _) = input(language: nil)
        try mounted(view)
        var resigned = 0
        view.onResign = { resigned += 1 }
        XCTAssertTrue(view.becomeFirstResponder())
        view.dismissKeyboard()
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(resigned, 1)
    }

    func testLosingTheKeyboardDropsAnUnfinishedComposition() throws {
        let (view, sent) = input(language: "zh-Hans")
        try mounted(view)
        XCTAssertTrue(view.becomeFirstResponder())
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))

        view.dismissKeyboard()

        XCTAssertNil(view.markedTextRange, "组字条不能留在屏幕上")
        XCTAssertEqual(sent(), [], "没选的拼音不发给 Mac")
    }

    func testTouchesPassThroughToTheCanvas() {
        let view = RemoteKeyInputView(frame: CGRect(x: 0, y: 0, width: 400, height: 48))
        XCTAssertNil(view.hitTest(CGPoint(x: 200, y: 24), with: nil), "视图铺在画布底边，不能挡手势")
    }
}

/// 真实输入法：要模拟器开了中文键盘（`defaults write -g AppleKeyboards`），没开就跳过。
/// 走的是系统自己的输入模式切换和拼音引擎，不是直接调 `setMarkedText`。
@MainActor
final class RemoteKeyInputRealKeyboardTests: XCTestCase {
    private var window: UIWindow?
    private var savedLanguage: String?

    override func setUp() async throws {
        savedLanguage = UserDefaults.standard.string(forKey: RemoteKeyInputView.languageKey)
        UserDefaults.standard.removeObject(forKey: RemoteKeyInputView.languageKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedLanguage, forKey: RemoteKeyInputView.languageKey)
        window?.isHidden = true
        window = nil
    }

    private func pump(_ seconds: TimeInterval = 0.4) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    private func switchKeyboard(to mode: UITextInputMode) throws {
        let cls = try XCTUnwrap(NSClassFromString("UIKeyboardInputModeController") as AnyObject as? NSObject)
        let controller = try XCTUnwrap(cls.perform(NSSelectorFromString("sharedInputModeController"))?.takeUnretainedValue() as? NSObject)
        controller.setValue(mode, forKey: "currentInputMode")
    }

    func testSwitchingLanguageIsRememberedAndChangesHowTextIsSent() async throws {
        let modes = UITextInputMode.activeInputModes
        guard let chinese = modes.first(where: { $0.primaryLanguage?.hasPrefix("zh") == true }) else {
            throw XCTSkip("模拟器没开中文键盘")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.isHidden = false
        window.makeKey()
        self.window = window
        let view = RemoteKeyInputView(frame: CGRect(x: 0, y: 300, width: window.bounds.width, height: 48))
        var sent: [RemoteDesktopInput] = []
        view.send = { sent.append($0) }
        window.addSubview(view)

        XCTAssertEqual(view.textInputMode?.primaryLanguage?.hasPrefix("en"), true, "没切过默认英文")
        XCTAssertTrue(view.becomeFirstResponder())
        try await pump()

        view.insertText("a")
        XCTAssertEqual(sent, [.key(code: 0, down: true, modifiers: []), .key(code: 0, down: false, modifiers: [])])
        sent = []

        try switchKeyboard(to: chinese)
        try await pump()
        XCTAssertEqual(UserDefaults.standard.string(forKey: RemoteKeyInputView.languageKey), chinese.primaryLanguage)
        XCTAssertEqual(view.textInputMode?.primaryLanguage, chinese.primaryLanguage, "下次打开还是它")

        view.insertText("a")
        XCTAssertEqual(sent, [.text("a")], "切到中文后不能再发按键，否则被 Mac 的拼音截走")
        sent = []

        // 把字母交给系统的键盘实现：真实的拼音引擎处理后，回到 UITextInput。
        let implClass = try XCTUnwrap(NSClassFromString("UIKeyboardImpl") as AnyObject as? NSObject)
        let impl = try XCTUnwrap(implClass.perform(NSSelectorFromString("activeInstance"))?.takeUnretainedValue() as? NSObject)
        let add = NSSelectorFromString("addInputString:")
        try XCTSkipUnless(impl.responds(to: add), "这个系统版本没有 addInputString:")
        for letter in ["n", "i"] {
            impl.perform(add, with: letter)
            try await pump(0.6)
        }
        XCTAssertEqual(view.markedTextRange.flatMap { view.text(in: $0) }, "ni", "真实拼音引擎应当进入组字")
        XCTAssertEqual(sent, [], "组字期间什么都不发")
        let label = try XCTUnwrap(view.subviews.compactMap { $0 as? UILabel }.first)
        XCTAssertFalse(label.isHidden, "拼音要显示出来")

        // 空格选第一个候选。
        impl.perform(add, with: " ")
        try await pump(0.6)
        XCTAssertNil(view.markedTextRange)
        // 系统自己的文本视图走同一串输入，得到的字就是标准答案。
        let oracle = UITextView(frame: CGRect(x: 0, y: 100, width: 300, height: 100))
        window.addSubview(oracle)
        XCTAssertTrue(oracle.becomeFirstResponder())
        try await pump()
        for letter in ["n", "i", " "] {
            impl.perform(add, with: letter)
            try await pump(0.6)
        }
        let typed = sent.reduce(into: "") { result, input in
            switch input {
            case .text(let text): result += text
            case .key(RemoteKeyMap.Key.space, down: true, _): result += " "
            default: break
            }
        }
        XCTAssertEqual(typed, oracle.text, "和系统文本视图打出来的字一致")
        XCTAssertFalse(typed.allSatisfy(\.isASCII), "发出去的是汉字，不是拼音：\(typed)")
        oracle.removeFromSuperview()
        XCTAssertTrue(view.becomeFirstResponder())
        try await pump()
        sent = []

        // 什么都没在组时退格是 Mac 上的退格。
        impl.perform(NSSelectorFromString("deleteFromInput"))
        try await pump(0.4)
        XCTAssertEqual(sent, [.key(code: RemoteKeyMap.Key.delete, down: true, modifiers: []),
                              .key(code: RemoteKeyMap.Key.delete, down: false, modifiers: [])])
        view.dismissKeyboard()
    }
}
