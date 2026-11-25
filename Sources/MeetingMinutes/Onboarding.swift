import AppKit
import AVFoundation
import ServiceManagement

enum SystemSettingsPane {
    static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let screenAndSystemAudio = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let filesAndFolders = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.meetingminutes"

    static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

@MainActor
enum Dialog {
    /// Shows an alert and returns the index of the clicked button (0 = first).
    @discardableResult
    static func show(_ title: String, _ text: String, buttons: [String] = ["OK"], style: NSAlert.Style = .informational, accessory: NSView? = nil) -> Int {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        alert.accessoryView = accessory
        if let field = accessory as? NSTextField { alert.window.initialFirstResponder = field }
        let response = alert.runModal()
        return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// Asks for a Claude API key and stores it in the macOS Keychain.
    @discardableResult
    static func askForAPIKey() -> Bool {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        let choice = show(
            "Claude API Key",
            "Paste your Anthropic API key (console.anthropic.com). It is stored in the macOS Keychain. With a key, the minutes are written through the API instead of Claude Code.",
            buttons: ["Save", "Cancel"],
            accessory: field
        )
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard choice == 0, !key.isEmpty else { return false }
        guard Keychain.saveAPIKey(key) else {
            show("Could not save the key", "The macOS Keychain refused to store it. Please try again.", style: .warning)
            return false
        }
        return true
    }
}

/// Checks whether system audio is coming through (plays a short sound and checks it was captured).
enum SystemAudioTester {
    private final class PeakBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Float = 0
        func update(_ new: Float) { lock.lock(); value = max(value, new); lock.unlock() }
        var peak: Float { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Returns nil if the capture could not even start.
    static func measure(playSound: Bool, seconds: Double) async -> Float? {
        let box = PeakBox()
        let capture = SystemAudioCapture { buffer, _ in box.update(buffer.peakLevel()) }
        do {
            try capture.start()
        } catch {
            Log.error("System audio test: \(error.localizedDescription)")
            return nil
        }
        try? await Task.sleep(for: .milliseconds(400))
        if playSound { await MainActor.run { _ = NSSound(named: "Glass")?.play() } }
        try? await Task.sleep(for: .seconds(seconds))
        capture.stop()
        return box.peak
    }
}

/// First launch: asks for and checks every permission, explaining why.
@MainActor
enum Onboarding {
    static func run(status: @escaping (String?) -> Void) async {
        Dialog.show(
            "Welcome to Prosa",
            """
            The app lives in the menu bar and records your meetings with a keyboard shortcut: your voice (microphone) and everyone else's (the Mac's audio). When you stop, it transcribes everything on this Mac and saves the minutes as Markdown.

            Let's set up the macOS permissions. It takes less than a minute.
            """,
            buttons: ["Get Started"]
        )
        await microphoneStep()
        await microphoneTestStep()
        await systemAudioStep()
        documentsStep()
        await notificationsStep()
        await accessibilityStep()
        await meetingLanguageStep(status: status)
        await minutesEngineStep()
        loginItemStep()
        Settings.shared.onboardingDone = true
        Dialog.show(
            "All set!",
            """
            During a meeting, press \(HotKeyPresets.current.title) to start recording and press it again to stop. A short sound confirms each action.

            The menu bar icon shows the recording time and then “processing”. When the minutes are ready you get a notification; click it to open the file.
            """
        )
    }

    // MARK: Microphone

    private static func microphoneStep() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            Dialog.show(
                "1 of 3 · Microphone",
                "macOS will ask for microphone access, to record your voice. Click “Allow”.",
                buttons: ["Continue"]
            )
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            microphoneDenied()
        default:
            microphoneDenied()
        }
    }

    /// Checks that the chosen microphone picks up a voice (not just noise). If not, offers another one.
    static func microphoneTestStep() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        var intro = true
        while true {
            let current = Settings.shared.micDeviceUID.flatMap { uid in AudioDevices.inputDevices().first { $0.uid == uid }?.name }
                ?? AudioDevices.defaultInputName() ?? "default microphone"
            if intro {
                let choice = Dialog.show(
                    "Microphone Test",
                    "Microphone in use: \(current).\n\nClick “Test” and say any sentence in a normal voice for 4 seconds (for example: “testing meeting minutes, one, two, three”).",
                    buttons: ["Test", "Skip"]
                )
                if choice != 0 { return }
            }
            intro = true
            guard let result = await MicrophoneTester.test(deviceUID: Settings.shared.micDeviceUID, seconds: 4) else {
                Dialog.show("Could not open the microphone", "Check the permission in System Settings › Privacy & Security › Microphone.", style: .warning)
                return
            }
            if result.heardVoice {
                Dialog.show("I heard your voice ✓", "“\(result.deviceName)” is picking you up well. You can switch microphones at any time from the app menu.")
                return
            }
            let alternative = AudioDevices.inputDevices()
                .filter { $0.name != result.deviceName }
                .sorted { ($0.name.contains("MacBook") ? 0 : 1) < ($1.name.contains("MacBook") ? 0 : 1) }
                .first
            var buttons = ["Test Again", "Skip"]
            if let alternative { buttons.insert("Use “\(alternative.name)”", at: 0) }
            let choice = Dialog.show(
                "I didn't hear your voice",
                "“\(result.deviceName)” only picked up noise (or your voice was too quiet). This happens, for example, with headphones that have no microphone: the Mac shows an “External Microphone” that does not pick up your voice.\(alternative.map { "\n\nUse “\($0.name)” to record your voice?" } ?? "")",
                buttons: buttons,
                style: .warning
            )
            let label = buttons[min(max(choice, 0), buttons.count - 1)]
            if label.hasPrefix("Use"), let alternative {
                Settings.shared.micDeviceUID = alternative.uid
                Log.info("Microphone chosen: \(alternative.name).")
                intro = true
            } else if label == "Test Again" {
                intro = false
            } else {
                return
            }
        }
    }

    private static func microphoneDenied() {
        let choice = Dialog.show(
            "No microphone access",
            "Without this permission your voice will not be in the minutes. Open System Settings › Privacy & Security › Microphone and turn on “Prosa”.",
            buttons: ["Open Settings", "Not Now"],
            style: .warning
        )
        if choice == 0 { SystemSettingsPane.open(SystemSettingsPane.microphone) }
    }

    // MARK: System audio

    private static func systemAudioStep() async {
        Dialog.show(
            "2 of 3 · System Audio",
            """
            To record the other people, the app captures the sound your Mac is playing (it works with headphones and needs no BlackHole or drivers).

            macOS will ask for permission to record system audio: click “Allow”. Then I'll play a short sound to test it.
            """,
            buttons: ["Continue"]
        )
        // First capture: makes macOS show the permission prompt.
        _ = await SystemAudioTester.measure(playSound: false, seconds: 1.0)
        Dialog.show(
            "Test System Audio",
            "If the macOS prompt appeared, answer “Allow”. Then click “Test” and make sure your Mac's volume is not muted.",
            buttons: ["Test"]
        )
        var shouldTest = true
        while true {
            if shouldTest, let peak = await SystemAudioTester.measure(playSound: true, seconds: 1.6), peak > 0.0005 {
                Log.info("System audio test: OK (peak \(peak)).")
                return
            }
            let choice = Dialog.show(
                "I couldn't capture system audio",
                """
                Open System Settings › Privacy & Security › Screen & System Audio Recording and turn on “Prosa” under “System Audio Recording Only”. Then come back and click “Test Again”.

                Also make sure the Mac's volume is not at zero or muted.
                """,
                buttons: ["Test Again", "Open Settings", "Skip"],
                style: .warning
            )
            switch choice {
            case 0: shouldTest = true
            case 1:
                SystemSettingsPane.open(SystemSettingsPane.screenAndSystemAudio)
                shouldTest = false
            default:
                return
            }
        }
    }

    // MARK: Minutes folder

    private static func documentsStep() {
        do {
            try Paths.ensure(Paths.minutesFolder)
        } catch {
            let choice = Dialog.show(
                "No access to the minutes folder",
                "The minutes are saved in \(Paths.minutesFolder.path). Open System Settings › Privacy & Security › Files & Folders and allow “Prosa” to use the Documents folder.",
                buttons: ["Open Settings", "Not Now"],
                style: .warning
            )
            if choice == 0 { SystemSettingsPane.open(SystemSettingsPane.filesAndFolders) }
        }
    }

    // MARK: Notifications

    private static func notificationsStep() async {
        var status = await Notifier.shared.authorizationStatus()
        if status == .authorized || status == .provisional { return }
        if status == .notDetermined {
            Dialog.show(
                "Notifications",
                "To tell you when the minutes are ready, macOS will show a small prompt in the top-right corner of the screen. Hover over it and click “Allow”.",
                buttons: ["Continue"]
            )
            if await Notifier.shared.requestAuthorization() { return }
            status = await Notifier.shared.authorizationStatus()
        }
        Log.info("Notifications \(Notifier.describe(status)) during setup.")
        let choice = Dialog.show(
            "Notifications are off",
            "Without notifications, “Minutes ready” only shows on the menu bar icon (with a sound). To get the notification, open System Settings › Notifications › Prosa and turn on “Allow notifications”.",
            buttons: ["Open Settings", "Keep It Off"]
        )
        if choice == 0 { SystemSettingsPane.open(SystemSettingsPane.notifications) }
    }

    // MARK: Accessibility (dictation types into other apps)

    private static func accessibilityStep() async {
        guard !AXIsProcessTrusted() else { return }
        let choice = Dialog.show(
            "Typing by voice",
            "For dictation to type into the app you are using (\(DictationHotKeyPresets.current?.title ?? "the dictation shortcut")), macOS needs to allow Prosa under Privacy & Security › Accessibility. Click “Allow…”, then turn on Prosa in the list that opens.",
            buttons: ["Allow…", "Later"]
        )
        guard choice == 0 else { return }
        TextInserter.askOnce()
        // Wait (up to 2 minutes) for the switch to be turned on.
        let deadline = Date().addingTimeInterval(120)
        while !AXIsProcessTrusted() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        Log.info("Accessibility \(AXIsProcessTrusted() ? "allowed" : "not allowed") during setup.")
        if AXIsProcessTrusted() {
            Dialog.show("Typing by voice is ready ✓", "Put the cursor in any text field, hold \(DictationHotKeyPresets.current?.title ?? "the dictation shortcut") and talk.")
        }
    }

    // MARK: Meeting language and speech model

    private static func meetingLanguageStep(status: @escaping (String?) -> Void) async {
        await MeetingLanguage.resolveDefaultIfNeeded()
        let installed = await Transcription.isModelInstalled()
        Dialog.show(
            "3 of 3 · Meeting Language",
            """
            Meetings will be transcribed in \(MeetingLanguage.displayName), and the minutes will be written in that language. You can change it at any time in the menu under “Meeting Language”.

            Transcription runs on this Mac: meeting audio never leaves your computer.\(installed ? "" : " macOS will now download the speech model for this language (only once).")
            """,
            buttons: [installed ? "Continue" : "Download"]
        )
        if installed { return }
        status("Downloading model…")
        do {
            try await Transcription.ensureModel()
            status(nil)
        } catch {
            status(nil)
            Dialog.show(
                "Could not download the speech model",
                "\(error.localizedDescription)\n\nCheck your internet connection. The app tries again automatically on the first recording.",
                style: .warning
            )
        }
    }

    // MARK: Who writes the minutes

    /// Explains what an AI adds, lists every option (with what it costs and where the text
    /// goes) and lets the person pick one or none.
    private static func minutesEngineStep() async {
        struct Option {
            let provider: MinutesProvider
            let note: String
            let enabled: Bool
        }
        let hasClaude = MinutesGenerator.findClaudeCLI() != nil
        let hasGemini = MinutesGenerator.findAntigravityCLI() != nil
        let ollama = await AISetup.ollamaRunning()
        let options: [Option] = [
            Option(provider: .claudeCode, note: hasClaude ? "your Claude subscription" : "not installed on this Mac", enabled: hasClaude),
            Option(provider: .gemini, note: hasGemini ? "your Google account" : "not installed on this Mac", enabled: hasGemini),
            Option(provider: .claudeAPI, note: "your Anthropic key, billed per use", enabled: true),
            Option(provider: .openAI, note: CompatibleService.openAI.summary, enabled: true),
            Option(provider: .geminiKey, note: CompatibleService.geminiKey.summary, enabled: true),
            Option(provider: .ollama, note: ollama ? "running on this Mac: free, offline" : CompatibleService.ollama.summary, enabled: true),
            Option(provider: .custom, note: CompatibleService.custom.summary, enabled: true),
        ]
        let explanation = """
        Prosa records and transcribes on this Mac by itself, without any AI.

        An AI adds three things:
        • minutes: a summary, the decisions and the tasks with who does them;
        • dictation clean-up: punctuation, no “é…” or “tipo”, names spelled right;
        • a glossary that learns the names and terms you use.

        Only text is sent to the AI you pick, never audio. Without an AI, the minutes contain the full transcript and dictation types exactly what was recognized. You can change this anytime in the menu, under “Minutes Written By”.
        """
        while true {
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
            popup.autoenablesItems = false
            for option in options {
                popup.addItem(withTitle: "\(option.provider.shortTitle) — \(option.note)")
                popup.lastItem?.isEnabled = option.enabled
                popup.lastItem?.representedObject = option.provider.rawValue
            }
            if let first = options.firstIndex(where: \.enabled) { popup.selectItem(at: first) }
            let choice = Dialog.show("Do you want an AI to write your minutes?", explanation, buttons: ["Use This AI", "No AI"], accessory: popup)
            guard choice == 0, let raw = popup.selectedItem?.representedObject as? String, let provider = MinutesProvider(rawValue: raw) else {
                Settings.shared.minutesProvider = MinutesProvider.none.rawValue
                Log.info("Minutes written by: no AI (chosen during setup).")
                return
            }
            if await apply(provider) { return }
        }
    }

    /// Sets up the chosen AI. Returns false if it could not be set up (the list shows again).
    static func apply(_ provider: MinutesProvider) async -> Bool {
        switch provider {
        case .claudeCode, .gemini:
            Settings.shared.minutesProvider = provider.rawValue
            if provider == .gemini, GeminiModels.cached.isEmpty {
                Task.detached(priority: .utility) { await GeminiModels.refresh() }
            }
            return true
        case .claudeAPI:
            guard Keychain.readAPIKey() != nil || Dialog.askForAPIKey() else { return false }
            Settings.shared.minutesProvider = provider.rawValue
            return true
        case .none:
            Settings.shared.minutesProvider = provider.rawValue
            return true
        default:
            guard let service = provider.compatible else { return false }
            return await AISetup.configure(service)
        }
    }

    // MARK: Open at login

    private static func loginItemStep() {
        guard SMAppService.mainApp.status != .enabled else { return }
        let choice = Dialog.show(
            "Open with your Mac?",
            "That way the shortcut is always ready, without having to remember to open the app before a meeting.",
            buttons: ["Yes, Open at Login", "No"]
        )
        if choice == 0 { LoginItem.set(enabled: true) }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor
    static func set(enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.error("Open at login: \(error.localizedDescription)")
            Dialog.show(
                "Could not change this setting",
                "\(error.localizedDescription)\n\nThe app must be in the Applications folder to open at login.",
                style: .warning
            )
        }
    }
}
