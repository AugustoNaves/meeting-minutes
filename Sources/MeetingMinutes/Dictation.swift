import Accelerate
import AppKit
import AVFoundation
import Carbon.HIToolbox

// MARK: - History (local only; feeds the glossary)

/// One dictation: what the recognizer heard and the text that was typed.
struct DictationRecord: Codable {
    let date: Date
    let raw: String
    let text: String
    let app: String?
}

/// The last dictations, in ~/Library/Application Support/MeetingMinutes/dictations.jsonl.
/// They never leave the Mac except as material for the glossary (when it learns).
enum DictationHistory {
    static let limit = 300
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("dictations.jsonl") }
    private static let queue = DispatchQueue(label: "meetingminutes.dictation.history")

    static func append(_ record: DictationRecord) {
        queue.sync {
            var records = loadUnlocked()
            records.append(record)
            if records.count > limit { records.removeFirst(records.count - limit) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let lines = records.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            do {
                try Paths.ensure(Paths.appSupport)
                try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                Log.error("Could not save the dictation history: \(error.localizedDescription)")
            }
        }
    }

    static func load() -> [DictationRecord] {
        queue.sync { loadUnlocked() }
    }

    private static func loadUnlocked() -> [DictationRecord] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.components(separatedBy: "\n").compactMap { line in
            line.isEmpty ? nil : try? decoder.decode(DictationRecord.self, from: Data(line.utf8))
        }
    }
}

// MARK: - From audio to text

/// Transcribes a dictation on the Mac, applies the glossary and, if turned on, has the AI
/// polish it. Used by the shortcut and by `--dictate` on the command line.
enum DictationPipeline {
    struct Outcome {
        /// What the speech recognizer heard.
        let raw: String
        /// The text to type.
        let text: String
        let polished: Bool
        /// Why the AI clean-up was skipped or failed (the glossary-corrected text is used then).
        let note: String?
    }

    static func run(audioURL: URL, cleanUp: Bool, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> Outcome {
        let (raw, note) = await transcribe(audioURL: audioURL)
        guard !raw.isEmpty else { return Outcome(raw: "", text: "", polished: false, note: note) }
        let corrected = Glossary.load().apply(to: raw)
        guard cleanUp else { return Outcome(raw: raw, text: corrected, polished: false, note: nil) }
        progress("Polishing…")
        return await polish(raw: raw, corrected: corrected)
    }

    /// The accurate on-device transcription of the whole recording.
    static func transcribe(audioURL: URL) async -> (raw: String, note: String?) {
        await MeetingLanguage.resolveDefaultIfNeeded()
        let locale = MeetingLanguage.locale
        do {
            try await Transcription.ensureModel(locale: locale)
            let phrases = try await Transcription.transcribe(fileURL: audioURL, locale: locale)
            return (text(from: phrases), nil)
        } catch {
            Log.error("Dictation: transcription failed: \(error.localizedDescription)")
            return ("", error.localizedDescription)
        }
    }

    /// The AI clean-up; on failure, the glossary-corrected text is kept.
    static func polish(raw: String, corrected: String) async -> Outcome {
        let engine = MinutesGenerator.currentEngine()
        if case .none = engine {
            return Outcome(raw: raw, text: corrected, polished: false, note: MinutesError.noEngine.localizedDescription)
        }
        do {
            let cleaned = try await MinutesGenerator.cleanUpDictation(corrected, glossary: Glossary.load(), locale: MeetingLanguage.locale, engine: engine)
            return Outcome(raw: raw, text: cleaned, polished: true, note: nil)
        } catch {
            Log.error("Dictation: clean-up failed, keeping the text without it: \(error.localizedDescription)")
            return Outcome(raw: raw, text: corrected, polished: false, note: error.localizedDescription)
        }
    }

    /// Joins the recognized phrases into one line of text.
    static func text(from phrases: [Phrase]) -> String {
        phrases.map { $0.words.map(\.text).joined() }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Typing into the app in front

/// Marks the keyboard events this app sends, so they are not mistaken for the person typing.
let syntheticEventMarker: Int64 = 0x4D4D_444B // 'MMDK'

/// Sends keystrokes to the app in front. Needs the Accessibility permission.
enum KeyTyper {
    /// When this app last sent keystrokes (used to tell them apart from the person's).
    nonisolated(unsafe) static var lastSent = Date.distantPast

    /// Types text character by character (as Unicode, so accents and emoji work with any
    /// keyboard layout). Line breaks become spaces: a typed line break can send a message.
    static func type(_ text: String) {
        lastSent = Date()
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            var units = Array((character.isNewline ? " " : String(character)).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    static func backspace(_ count: Int) {
        guard count > 0 else { return }
        lastSent = Date()
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: keyDown) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Selects the `count` characters before the cursor (⇧← repeated).
    static func selectBackward(_ count: Int) {
        guard count > 0 else { return }
        lastSent = Date()
        let source = CGEventSource(stateID: .privateState)
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: keyDown) else { continue }
                event.flags = .maskShift
                event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// True while ⌘, ⌥, ⌃ or ⇧ is physically held (e.g. the dictation shortcut).
    static var modifiersHeld: Bool {
        !NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// Waits (up to `timeout`) until the shortcut's keys are let go, so a held ⌥ cannot turn a
    /// backspace into "delete word" or ⌘V into something else.
    @MainActor
    static func waitForModifiersReleased(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while modifiersHeld && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
}

/// Tells whether the keyboard focus is somewhere typing makes text. Many apps (Electron ones
/// like Claude, Slack or VS Code, and some web pages) do not say what is focused, so only a
/// focus that is clearly NOT text (a button, a list of files, a web page outside any text box,
/// where letters can be shortcuts) stops live typing.
enum FocusInspector {
    enum Focus: Equatable {
        case text
        case notText(String)
        case unknown
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXList", "AXTable",
        "AXOutline", "AXRow", "AXCell", "AXImage", "AXBrowser", "AXMenu", "AXMenuBar", "AXMenuItem",
        "AXSlider", "AXTabGroup", "AXToolbar", "AXDisclosureTriangle", "AXScrollArea", "AXWebArea",
    ]

    static func focus() -> Focus {
        if let focus = check() { return focus }
        // Electron apps only describe their windows once asked to.
        if let app = NSWorkspace.shared.frontmostApplication {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let focus = check() { return focus }
        }
        return .unknown
    }

    /// nil = the app did not say what is focused.
    private static func check() -> Focus? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String ?? ""
        if textRoles.contains(role) { return .text }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue {
            return .text
        }
        if nonTextRoles.contains(role) { return .notText(role) }
        return role.isEmpty ? nil : .unknown
    }
}

/// Types a dictation into the app while it is spoken, and corrects it in place when the final
/// text arrives: it only ever changes characters it typed itself, and stops touching the text as
/// soon as the person clicks, types or switches apps.
@MainActor
final class LiveTyper {
    private(set) var typed = ""
    private(set) var interrupted = false
    private var typedWords = 0
    private var monitor: Any?
    private var savedClipboard: [NSPasteboardItem]?
    private var ourClipboard: Int?
    /// The app the text is being typed into; if another app comes to the front, typing stops.
    private let appID = NSWorkspace.shared.frontmostApplication?.processIdentifier

    /// Small corrections are typed; bigger ones replace the changed part in one paste, so the
    /// text never flickers through a long run of deletions and retyping.
    nonisolated static let maxTypedCorrection = 6

    /// False (and stays false) once the person clicked, typed or switched apps.
    private var mayType: Bool {
        if !interrupted, NSWorkspace.shared.frontmostApplication?.processIdentifier != appID {
            stopTyping("another app came to the front")
        }
        return !interrupted
    }

    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker { return }
            // Keys this app itself sends (letters, ⌫, ⇧←, ⌘V) right after sending them.
            if event.type == .keyDown, [0, 9, 51, 123].contains(event.keyCode), Date().timeIntervalSince(KeyTyper.lastSent) < 0.35 { return }
            let reason = event.type == .keyDown ? "you pressed a key (code \(event.keyCode))" : "you clicked"
            MainActor.assumeIsolated { self?.stopTyping(reason) }
        }
    }

    private func stopTyping(_ reason: String) {
        guard !interrupted else { return }
        interrupted = true
        Log.info("Dictation: \(reason), so the text typed so far is left alone.")
    }

    /// Ends live typing and gives the clipboard back (if a correction used it).
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard let saved = savedClipboard, let ours = ourClipboard else { return }
        savedClipboard = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// The words already settled in a live text (the last one is still changing).
    nonisolated static func settledWords(_ text: String) -> [Substring] {
        let words = text.split(whereSeparator: \.isWhitespace)
        return Array(words.dropLast())
    }

    /// While the shortcut is held: types the new settled words. Never deletes (a held ⌥ would
    /// turn a backspace into "delete word"), and keeps going even when the recognizer revises a
    /// word already typed: those are fixed when the dictation ends.
    func append(stableFrom live: String, includingLastWord: Bool = false) {
        guard mayType else { return }
        let clean = live.replacingOccurrences(of: "\n", with: " ")
        let words = includingLastWord ? clean.split(whereSeparator: \.isWhitespace) : Self.settledWords(clean)
        guard words.count > typedWords else { return }
        let addition = (typed.isEmpty ? "" : " ") + words[typedWords...].joined(separator: " ")
        KeyTyper.type(addition)
        typed += addition
        typedWords = words.count
    }

    /// Brings the typed text to `target` (keys must be released): only the part that differs is
    /// changed. Returns false if it was not allowed to (the person clicked, typed or left).
    @discardableResult
    func replace(with rawTarget: String) -> Bool {
        guard mayType else { return false }
        let target = rawTarget.replacingOccurrences(of: "\n", with: " ")
        let edit = Self.edit(from: typed, to: target)
        if edit.deletions == 0 && edit.insertion.isEmpty { return true }
        if edit.deletions <= Self.maxTypedCorrection && edit.insertion.count <= 40 {
            KeyTyper.backspace(edit.deletions)
            KeyTyper.type(edit.insertion)
        } else {
            KeyTyper.selectBackward(edit.deletions)
            if edit.insertion.isEmpty {
                KeyTyper.backspace(1)
            } else {
                paste(edit.insertion)
            }
        }
        typed = target
        typedWords = Self.settledWords(target + " ").count
        return true
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        if savedClipboard == nil { savedClipboard = TextInserter.snapshot(pasteboard) }
        TextInserter.write(text, to: pasteboard, transient: true)
        ourClipboard = pasteboard.changeCount
        TextInserter.pressCommandV()
    }

    /// How to turn `old` into `new`: delete the end of `old` back to their common start, then
    /// type the rest of `new`.
    nonisolated static func edit(from old: String, to new: String) -> (deletions: Int, insertion: String) {
        let common = zip(old, new).prefix { $0 == $1 }.count
        return (old.count - common, String(new.dropFirst(common)))
    }
}

// MARK: - Typing the whole text at once

/// Puts the text in the app in front: copies it, presses ⌘V, then gives the clipboard back.
/// Pressing ⌘V for another app needs the Accessibility permission; without it, the text stays
/// on the clipboard for the person to paste.
@MainActor
enum TextInserter {
    private static var askedThisLaunch = false

    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Asks for the Accessibility permission once per launch (the macOS prompt + its settings page).
    static func askOnce() {
        guard !askedThisLaunch else { return }
        askedThisLaunch = true
        requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the macOS prompt that leads to Accessibility settings.
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Only copies (no paste), leaving the text for the person.
    static func copy(_ text: String) {
        write(text, to: NSPasteboard.general, transient: false)
    }

    /// Returns true when the text was typed, false when it was only copied.
    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        guard canPaste else {
            write(text, to: pasteboard, transient: false)
            askOnce()
            return false
        }
        let saved = snapshot(pasteboard)
        write(text, to: pasteboard, transient: true)
        let ours = pasteboard.changeCount
        pressCommandV()
        // Give the app time to read the clipboard, then put back what was there before
        // (unless something else was copied meanwhile).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.changeCount == ours else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return true
    }

    static func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            // Clipboard managers skip items marked like this.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        }
        pasteboard.writeObjects([item])
    }

    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    static func pressCommandV() {
        KeyTyper.lastSent = Date()
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(kVK_ANSI_V)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown) else { continue }
            // Only ⌘, even if the dictation shortcut's keys are still held down.
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - The indicator ("Calçadão")

/// How loud the microphone is right now (0…1), for the indicator. Written on the audio thread.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0

    func update(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        var sum: Float = 0
        vDSP_svesq(data, 1, &sum, vDSP_Length(samples))
        let db = 20 * log10(max(sqrt(sum / Float(samples)), 1e-7))
        // -55 dB (silence) → 0, -18 dB (normal speech up close) → 1.
        let level = min(1, max(0, (db + 55) / 37))
        lock.lock(); value = level; lock.unlock()
    }

    var current: Float {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// A small pill at the bottom of the screen with the waves of Copacabana's sidewalk: they swell
/// with your voice while listening and flow slowly while the text is being written. A dot on the
/// left means hands-free (tap the shortcut again to finish). It never takes the focus.
@MainActor
final class DictationHUD {
    enum Mode { case listening, handsFree, writing }

    var levelSource: (() -> Float)?
    private var panel: NSPanel?
    private let view = CalcadaoView(frame: NSRect(x: 0, y: 0, width: 104, height: 32))
    private var timer: Timer?
    private var lastTick = Date()

    func show(_ mode: Mode) {
        view.mode = mode
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            position(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        startTimer()
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if self.timer == nil { panel.orderOut(nil) }
            }
        })
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 40, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let dt = CGFloat(min(0.1, now.timeIntervalSince(lastTick)))
        lastTick = now
        let target = view.mode == .writing ? 0.35 : CGFloat(levelSource?() ?? 0)
        view.advance(target: target, dt: dt)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let size = view.frame.size
        panel.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 28, width: size.width, height: size.height), display: true)
    }
}

/// Draws the pill: two cream bands shaped like the sidewalk waves, on charcoal.
final class CalcadaoView: NSView {
    var mode = DictationHUD.Mode.listening
    private var level: CGFloat = 0
    private var phase: CGFloat = 0
    private var pulse: CGFloat = 0

    private static let charcoal = NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2A / 255.0, alpha: 1)
    private static let cream = NSColor(srgbRed: 0xF1 / 255.0, green: 0xEF / 255.0, blue: 0xE8 / 255.0, alpha: 1)

    func advance(target: CGFloat, dt: CGFloat) {
        level += (target - level) * min(1, dt * 9)
        phase += dt * (mode == .writing ? 1.4 : 2.6 + level * 2)
        pulse += dt * 3
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2 - 0.5, yRadius: bounds.height / 2 - 0.5)
        Self.charcoal.setFill()
        pill.fill()
        NSColor(white: 1, alpha: 0.14).setStroke()
        pill.lineWidth = 0.5
        pill.stroke()

        var start: CGFloat = 16
        let end = bounds.width - 16
        if mode == .handsFree {
            let size: CGFloat = 5 + sin(pulse) * 0.8
            Self.cream.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16 - size / 2, y: bounds.midY - size / 2, width: size, height: size)).fill()
            start += 11
        }
        // Two parallel stripes of constant width, like the sidewalk's mosaic. The amplitude is
        // capped so the stripes never touch each other or the edge of the pill.
        let amplitude = mode == .writing ? 2.2 : 0.8 + level * 3.6
        stripe(from: start, to: end, offset: 4.5, amplitude: amplitude)
        stripe(from: start, to: end, offset: -4.5, amplitude: amplitude)
    }

    private func stripe(from start: CGFloat, to end: CGFloat, offset: CGFloat, amplitude: CGFloat) {
        let mid = bounds.midY + offset
        let path = NSBezierPath()
        path.lineWidth = 3.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var x = start
        path.move(to: NSPoint(x: x, y: mid + sin(x / 9 + phase) * amplitude))
        while x < end {
            x = min(end, x + 1.5)
            path.line(to: NSPoint(x: x, y: mid + sin(x / 9 + phase) * amplitude))
        }
        Self.cream.setStroke()
        path.stroke()
    }
}

// MARK: - The shortcut

/// Hold the shortcut to talk and release it to finish; a quick tap keeps listening (hands-free)
/// until the next tap.
///
/// With "Type as You Speak" on and the cursor in a text field, the words are typed while they are
/// spoken. When the dictation ends, the accurate text (already transcribed while you spoke) and
/// the glossary replace them in one paste, a fraction of a second later, and dictation is ready
/// again. The AI clean-up, if on, then adjusts the text in the background, only if it is still safe.
@MainActor
final class DictationController {
    enum State { case idle, listening, finishing }
    enum Delivery { case typed, copied, leftAlone }

    private(set) var state = State.idle
    private(set) var handsFree = false
    private(set) var step: String?

    /// Called whenever the state changes (to update the menu bar icon).
    var onChange: (() -> Void)?
    /// Called after the text was typed, copied, or left as the person edited it.
    var onDictated: ((DictationRecord, Delivery) -> Void)?
    /// Called when a dictation could not even start.
    var onProblem: ((String) -> Void)?

    static let tapThreshold: TimeInterval = 0.35
    static let maxDuration: TimeInterval = 10 * 60
    /// A pause this long counts as the end of a word: the last word is typed too.
    nonisolated static let pauseFlush: TimeInterval = 0.6

    private var capture: MicrophoneCapture?
    private var writer: TrackWriter?
    private var quickLive: LiveTranscriber?
    private var accurate: LiveTranscriber?
    private var typer: LiveTyper?
    private let hud = DictationHUD()
    private let meter = LevelMeter()
    private var pressDate: Date?
    private var limitTimer: Timer?
    private var pauseTimer: Timer?
    private var lastLive = ""
    /// Counts dictations, so a late AI clean-up never touches the text of a newer one.
    private var generation = 0
    /// The shortcut was pressed while the previous dictation was being finished.
    private var startWhenDone = false

    func keyDown() {
        switch state {
        case .idle: start()
        case .listening where handsFree: stop()
        case .finishing: startWhenDone = true
        default: break
        }
    }

    func keyUp() {
        guard state == .listening, !handsFree, let pressDate else { return }
        if Date().timeIntervalSince(pressDate) < Self.tapThreshold {
            handsFree = true
            Log.info("Dictation: quick tap, so it keeps listening until the shortcut is pressed again.")
            hud.show(.handsFree)
            onChange?()
        } else {
            stop()
        }
    }

    private func start() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onProblem?("Dictation needs the microphone permission. Use “Check Permissions…” in the menu.")
            return
        }
        generation += 1
        // Typing into another app needs the Accessibility permission: ask right away, not at the end.
        let mayType = TextInserter.canPaste
        if !mayType { TextInserter.askOnce() }
        let focus = mayType ? FocusInspector.focus() : .unknown
        let typeLive: Bool
        let why: String
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front"
        if !mayType {
            typeLive = false
            why = "no Accessibility permission yet: the text will be copied"
        } else if !Settings.shared.dictationTypeLive {
            typeLive = false
            why = "Type as You Speak is off: the text will be pasted at the end"
        } else if case let .notText(role) = focus {
            typeLive = false
            why = "the focus in \(appName) is not a text field (\(role)): the text will be pasted at the end"
        } else {
            typeLive = true
            why = "typing live into \(appName)" + (focus == .unknown ? " (it does not say what is focused)" : "")
        }
        Log.info("Dictation started: \(why).")

        let quickLive = typeLive ? LiveTranscriber(quick: true) : nil
        let accurate = LiveTranscriber(quick: false)
        let meter = self.meter
        do {
            let folder = Paths.appSupport.appendingPathComponent("Dictation", isDirectory: true)
            try Paths.ensure(folder)
            let url = folder.appendingPathComponent("dictation-\(UUID().uuidString).caf")
            let writer = try TrackWriter(url: url, startHostTime: mach_absolute_time(), label: "dictation")
            let capture = MicrophoneCapture(deviceUID: Settings.shared.micDeviceUID) { buffer, host in
                writer.append(buffer, hostTime: host)
                accurate.append(buffer)
                quickLive?.append(buffer)
                meter.update(buffer)
            }
            try capture.start()
            self.writer = writer
            self.capture = capture
        } catch {
            NSSound(named: "Basso")?.play()
            onProblem?("Dictation could not use the microphone (\(error.localizedDescription)).")
            return
        }
        // The controller lives as long as the app, so it is safe to capture directly.
        let controller = self
        let locale = MeetingLanguage.locale
        quickLive?.onText = { text in
            Task { @MainActor in controller.liveUpdate(text) }
        }
        quickLive?.start(locale: locale)
        accurate.start(locale: locale)
        self.quickLive = quickLive
        self.accurate = accurate
        typer = typeLive ? LiveTyper() : nil
        lastLive = ""
        state = .listening
        handsFree = false
        pressDate = Date()
        if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
        if !mayType {
            Notifier.shared.post(
                title: "Dictation will be copied this time",
                body: "To type into other apps, turn on Prosa in System Settings › Privacy & Security › Accessibility.",
                sound: false
            )
        }
        hud.levelSource = { meter.current }
        hud.show(.listening)
        let timer = Timer(timeInterval: Self.maxDuration, repeats: false) { _ in
            MainActor.assumeIsolated { controller.stop() }
        }
        RunLoop.main.add(timer, forMode: .common)
        limitTimer = timer
        onChange?()
    }

    /// New words from the quick transcriber: type the settled ones (never deleting while
    /// speaking), and the last one too once you pause.
    private func liveUpdate(_ text: String) {
        guard state == .listening, let typer, !typer.interrupted else { return }
        let corrected = Glossary.load().apply(to: text)
        lastLive = corrected
        typer.append(stableFrom: corrected)
        pauseTimer?.invalidate()
        let controller = self
        let timer = Timer(timeInterval: Self.pauseFlush, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard controller.state == .listening, let typer = controller.typer else { return }
                typer.append(stableFrom: controller.lastLive, includingLastWord: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func stop() {
        guard state == .listening, let capture, let writer else { return }
        let stoppedAt = Date()
        limitTimer?.invalidate()
        limitTimer = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        capture.stop()
        _ = writer.finish()
        quickLive?.stop()
        quickLive = nil
        let accurate = self.accurate
        self.accurate = nil
        self.capture = nil
        self.writer = nil
        state = .finishing
        step = "Writing…"
        Log.info(String(format: "Dictation stopped after %.1f s (%@).", stoppedAt.timeIntervalSince(pressDate ?? stoppedAt), handsFree ? "hands-free" : "held"))
        hud.show(.writing)
        onChange?()

        let url = writer.url
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let controller = self
        Task { @MainActor in
            // The accurate text was transcribed while you spoke: it is ready almost at once.
            var raw = await accurate?.finish(timeout: 2.5) ?? ""
            let streamed = !raw.isEmpty
            var note: String?
            if raw.isEmpty {
                (raw, note) = await DictationPipeline.transcribe(audioURL: url)
            }
            try? FileManager.default.removeItem(at: url)
            Log.info(String(format: "Dictation: final text ready %.2f s after stopping%@.", Date().timeIntervalSince(stoppedAt), streamed ? "" : " (from the recording)"))
            await controller.finish(raw: raw, note: note, app: app, stoppedAt: stoppedAt)
        }
    }

    private func finish(raw: String, note: String?, app: String?, stoppedAt: Date) async {
        let typer = self.typer
        self.typer = nil
        let wasHandsFree = handsFree
        let cleanUp = Settings.shared.dictationCleanUp

        guard !raw.isEmpty else {
            if let note {
                onProblem?("Dictation failed: \(note)")
            } else {
                Log.info("Dictation: nothing was recognized.")
                NSSound(named: "Funk")?.play()
            }
            // Nothing recognized: take back anything typed live.
            if let typer, !typer.typed.isEmpty {
                if !wasHandsFree { await KeyTyper.waitForModifiersReleased(timeout: 0.5) }
                typer.replace(with: "")
            }
            typer?.stop()
            ready()
            return
        }

        let corrected = Glossary.load().apply(to: raw)
        let delivery: Delivery
        var finalText = corrected

        if let typer {
            if !wasHandsFree { await KeyTyper.waitForModifiersReleased(timeout: 0.5) }
            delivery = typer.replace(with: corrected) ? .typed : .leftAlone
            if delivery == .leftAlone {
                Log.info("Dictation: the text was left as you edited it.")
            }
            Log.info(String(format: "Dictation: %d words in place %.2f s after stopping.", corrected.split(separator: " ").count, Date().timeIntervalSince(stoppedAt)))
            ready()
            if delivery == .typed && cleanUp {
                polishInBackground(raw: raw, corrected: corrected, typer: typer, app: app)
            } else {
                typer.stop()
            }
        } else {
            if cleanUp {
                step = "Polishing…"
                onChange?()
                let outcome = await DictationPipeline.polish(raw: raw, corrected: corrected)
                finalText = outcome.text
            }
            if !wasHandsFree { await KeyTyper.waitForModifiersReleased(timeout: 0.5) }
            delivery = TextInserter.insert(finalText) ? .typed : .copied
            ready()
        }

        let record = DictationRecord(date: Date(), raw: raw, text: finalText, app: app)
        DictationHistory.append(record)
        onDictated?(record, delivery)
    }

    /// The AI clean-up arrives a few seconds later. It only replaces the text if nothing happened
    /// in between: no new dictation, no typing or clicking, same app in front.
    private func polishInBackground(raw: String, corrected: String, typer: LiveTyper, app: String?) {
        let generation = self.generation
        let controller = self
        Task { @MainActor in
            let outcome = await DictationPipeline.polish(raw: raw, corrected: corrected)
            defer { typer.stop() }
            guard outcome.polished, outcome.text != corrected else { return }
            guard controller.generation == generation, controller.state == .idle else {
                Log.info("Dictation: AI clean-up skipped (a new dictation started).")
                return
            }
            if typer.replace(with: outcome.text) {
                Log.info("Dictation: AI clean-up applied.")
                DictationHistory.append(DictationRecord(date: Date(), raw: raw, text: outcome.text, app: app))
            } else {
                Log.info("Dictation: AI clean-up skipped (you typed, clicked or switched apps).")
            }
        }
    }

    /// Back to idle, ready for the next dictation (started right away if the shortcut was
    /// pressed meanwhile).
    private func ready() {
        state = .idle
        step = nil
        handsFree = false
        hud.hide()
        onChange?()
        if startWhenDone {
            startWhenDone = false
            start()
        }
    }
}
