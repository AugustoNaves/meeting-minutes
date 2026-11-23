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
            "Welcome to Meeting Minutes",
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
        await meetingLanguageStep(status: status)
        minutesEngineStep()
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
            "Without this permission your voice will not be in the minutes. Open System Settings › Privacy & Security › Microphone and turn on “Meeting Minutes”.",
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
                Open System Settings › Privacy & Security › Screen & System Audio Recording and turn on “Meeting Minutes” under “System Audio Recording Only”. Then come back and click “Test Again”.

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
                "The minutes are saved in \(Paths.minutesFolder.path). Open System Settings › Privacy & Security › Files & Folders and allow “Meeting Minutes” to use the Documents folder.",
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
            "Without notifications, “Minutes ready” only shows on the menu bar icon (with a sound). To get the notification, open System Settings › Notifications › Meeting Minutes and turn on “Allow notifications”.",
            buttons: ["Open Settings", "Keep It Off"]
        )
        if choice == 0 { SystemSettingsPane.open(SystemSettingsPane.notifications) }
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

    private static func minutesEngineStep() {
        let hasClaude = MinutesGenerator.findClaudeCLI() != nil
        let hasGemini = MinutesGenerator.findAntigravityCLI() != nil
        let hasKey = Keychain.readAPIKey() != nil

        var lines: [String] = []
        var options: [(title: String, apply: () -> Void)] = []
        if hasClaude {
            lines.append("• Claude Code: uses your Claude subscription. Best quality in our tests, about 10 s.")
            options.append(("Claude Code", { Settings.shared.minutesProvider = MinutesProvider.claudeCode.rawValue }))
        }
        if hasGemini {
            lines.append("• Gemini (Antigravity): uses your Google account. About 20 s.")
            options.append(("Gemini", { Settings.shared.minutesProvider = MinutesProvider.gemini.rawValue }))
        }
        lines.append("• Claude API: your own key, billed per use on your API account.")
        options.append((hasKey ? "Claude API (saved key)" : "Claude API Key", {
            if hasKey || Dialog.askForAPIKey() { Settings.shared.minutesProvider = MinutesProvider.claudeAPI.rawValue }
        }))
        if !hasClaude && !hasGemini && !hasKey {
            lines.append("\nI couldn't find Claude Code or Antigravity on this Mac. Without one of them or an API key, the .md will contain only the transcript.")
            options.append(("Later", {}))
        }

        let choice = Dialog.show(
            "Who Writes the Minutes",
            "Who should write the summary, decisions and action items? Only the transcript text is sent; the audio never leaves your Mac. You can change this later in the menu.\n\n" + lines.joined(separator: "\n"),
            buttons: options.map(\.title)
        )
        options[min(max(choice, 0), options.count - 1)].apply()
        if Settings.shared.minutesProvider == MinutesProvider.gemini.rawValue, GeminiModels.cached.isEmpty {
            Task.detached(priority: .utility) { await GeminiModels.refresh() }
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
