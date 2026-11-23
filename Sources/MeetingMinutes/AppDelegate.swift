import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private var hotKey: HotKey?
    private var hotKeyOK = true
    private var timer: Timer?

    // Processing queue: one meeting at a time, to keep the Mac light.
    private var queue: [URL] = []
    private var processingDirectory: URL?
    private var processingStep: String?
    private var regenerating = false
    private var transientStatus: String?
    private var onboardingRunning = false

    /// Indicator shown on the icon when macOS notifications are turned off.
    private struct Badge {
        let text: String
        let symbol: String
        let color: NSColor
    }
    private var badge: Badge?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateStatusButton()

        Notifier.shared.setUp()
        hotKey = HotKey { [weak self] in self?.toggleRecording() }
        registerHotKey(announceFailure: true)
        try? Paths.ensure(Paths.sessions)
        Task.detached(priority: .utility) {
            await MeetingLanguage.resolveDefaultIfNeeded()
            _ = MinutesGenerator.findClaudeCLI()
            if MinutesGenerator.findAntigravityCLI() != nil, GeminiModels.cached.isEmpty {
                await GeminiModels.refresh()
            }
        }

        if !Settings.shared.onboardingDone {
            runOnboarding()
        } else {
            let pending = recorder.pendingSessions().count
            if pending > 0 {
                Notifier.shared.post(
                    title: "\(pending) recording(s) without minutes",
                    body: "Open the Meeting Minutes menu and choose “Process Pending Recordings”.",
                    sound: false
                )
            }
        }
        Log.info("App launched.")
        logPermissions()
    }

    private func logPermissions() {
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "allowed"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        default: mic = "not requested yet"
        }
        Task {
            let notifications = Notifier.describe(await Notifier.shared.authorizationStatus())
            Log.info("Permissions: microphone \(mic); notifications \(notifications).")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder.isRecording {
            let choice = Dialog.show(
                "A recording is in progress",
                "If you quit now, the recording stops and is kept. Next time, use “Process Pending Recordings” to write the minutes.",
                buttons: ["Stop and Quit", "Cancel"]
            )
            if choice != 0 { return .terminateCancel }
            _ = recorder.stop()
        } else if processingDirectory != nil || !queue.isEmpty {
            let choice = Dialog.show(
                "Minutes are still being written",
                "If you quit now, the recording is kept and can be processed later from the menu.",
                buttons: ["Quit Anyway", "Cancel"]
            )
            if choice != 0 { return .terminateCancel }
        }
        return .terminateNow
    }

    /// meetingminutes://toggle, meetingminutes://start and meetingminutes://stop
    /// (handy for macOS Shortcuts, Raycast, Stream Deck…).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "meetingminutes" {
            switch url.host {
            case "toggle": toggleRecording()
            case "start": startRecording()
            case "stop": stopRecording()
            default: break
            }
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if recorder.isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !recorder.isRecording else { return }
        badge = nil
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                self.startRecording()
            }
            return
        }
        do {
            let warnings = try recorder.start()
            if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
            startTimer()
            if !warnings.isEmpty {
                Notifier.shared.post(title: "Recording, with a warning", body: warnings.joined(separator: " "))
            }
        } catch {
            NSSound(named: "Basso")?.play()
            Log.error("Could not start recording: \(error.localizedDescription)")
            Notifier.shared.post(title: "Could not record", body: error.localizedDescription)
        }
        updateStatusButton()
    }

    func stopRecording() {
        guard let finished = recorder.stop() else { return }
        stopTimer()
        if Settings.shared.playSounds { NSSound(named: "Pop")?.play() }
        enqueue(finished.directory)
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusButton() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        updateStatusButton()
    }

    // MARK: - Processing

    private func enqueue(_ directory: URL) {
        guard directory != processingDirectory, !queue.contains(directory) else { return }
        queue.append(directory)
        processNext()
    }

    private func processNext() {
        guard processingDirectory == nil, !queue.isEmpty else {
            updateStatusButton()
            return
        }
        let directory = queue.removeFirst()
        processingDirectory = directory
        processingStep = "Processing…"
        updateStatusButton()

        // The AppDelegate lives as long as the app; it is safe to capture directly.
        let owner = self
        Task.detached(priority: .utility) {
            do {
                let outcome = try await MeetingProcessor.process(sessionDirectory: directory) { step in
                    Task { @MainActor in
                        owner.processingStep = step
                        owner.updateStatusButton()
                    }
                }
                await owner.processingFinished(outcome)
            } catch {
                await owner.processingFailed(directory: directory, error: error)
            }
        }
    }

    private func processingFinished(_ outcome: ProcessOutcome) {
        processingDirectory = nil
        processingStep = nil
        Settings.shared.lastMinutesPath = outcome.fileURL.path
        showBadgeIfNotificationsOff(
            outcome.minutesGenerated
                ? Badge(text: "Minutes ready", symbol: "checkmark.circle.fill", color: .systemGreen)
                : Badge(text: "Minutes without summary", symbol: "exclamationmark.circle.fill", color: .systemOrange)
        )
        if outcome.minutesGenerated {
            Notifier.shared.post(
                title: "Minutes ready ✓",
                body: "\(outcome.fileURL.lastPathComponent) — click to open.",
                fileURL: outcome.fileURL
            )
        } else {
            Notifier.shared.post(
                title: "Transcript saved, but no minutes",
                body: "\(outcome.failure ?? "The minutes were not written.") Click to open the file.",
                fileURL: outcome.fileURL
            )
        }
        processNext()
    }

    private func processingFailed(directory: URL, error: Error) {
        processingDirectory = nil
        processingStep = nil
        Log.error("Could not process \(directory.lastPathComponent): \(error.localizedDescription)")
        showBadgeIfNotificationsOff(Badge(text: "Error — see menu", symbol: "exclamationmark.triangle.fill", color: .systemOrange))
        Notifier.shared.post(
            title: "Could not process the meeting",
            body: "\(error.localizedDescription) The recording was kept: use “Process Pending Recordings” in the menu."
        )
        processNext()
    }

    private func showBadgeIfNotificationsOff(_ newBadge: Badge) {
        Task {
            guard await !Notifier.shared.isAuthorized() else { return }
            badge = newBadge
            NSSound(named: "Glass")?.play()
            updateStatusButton()
        }
    }

    // MARK: - Menu bar

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        var symbol = "waveform.circle"
        var color: NSColor?
        var title = ""
        var tooltip = "Meeting Minutes — \(HotKeyPresets.current.title) to record"

        if recorder.isRecording, let start = recorder.startDate {
            symbol = "record.circle.fill"
            color = .systemRed
            title = " " + Formatting.elapsed(Date().timeIntervalSince(start))
            tooltip = "Recording — \(HotKeyPresets.current.title) to stop"
        } else if processingDirectory != nil || regenerating {
            symbol = "hourglass"
            title = " " + (processingStep ?? "Processing…")
            if !queue.isEmpty { title += " (+\(queue.count))" }
            tooltip = "Writing the minutes in the background"
        } else if let transientStatus {
            symbol = "arrow.down.circle"
            title = " " + transientStatus
        } else if let badge {
            symbol = badge.symbol
            color = badge.color
            title = " " + badge.text
        }

        if var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Meeting Minutes") {
            if let color, let colored = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) {
                image = colored
                image.isTemplate = false
            } else {
                image.isTemplate = true
            }
            button.image = image
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        } else {
            button.image = nil
            title = (recorder.isRecording ? "● " : "◎ ") + title
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)]
        )
        button.toolTip = tooltip
    }

    private func statusText() -> String {
        if recorder.isRecording, let start = recorder.startDate {
            return "Recording — \(Formatting.elapsed(Date().timeIntervalSince(start)))"
        }
        if processingDirectory != nil || regenerating {
            return processingStep ?? "Processing…"
        }
        if let transientStatus { return transientStatus }
        if let badge { return badge.text }
        return "Ready — \(HotKeyPresets.current.title) to record"
    }

    func menuDidClose(_ menu: NSMenu) {
        if badge != nil {
            badge = nil
            updateStatusButton()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !hotKeyOK {
            let warning = NSMenuItem(title: "⚠︎ The shortcut \(HotKeyPresets.current.title) is used by another app — pick another one below", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        menu.addItem(item(recorder.isRecording ? "Stop Recording" : "Start Recording", #selector(toggleFromMenu)))
        menu.addItem(.separator())

        menu.addItem(item("Open Minutes Folder", #selector(openMinutesFolder)))
        if let last = Settings.shared.lastMinutesPath, FileManager.default.fileExists(atPath: last) {
            menu.addItem(item("Open Latest Minutes", #selector(openLastMinutes)))
        }
        let regenerate = item("Regenerate Minutes from .md…", #selector(regenerateFromFile))
        regenerate.isEnabled = !regenerating
        menu.addItem(regenerate)
        let pending = recorder.pendingSessions().filter { $0 != processingDirectory && !queue.contains($0) }
        if !pending.isEmpty {
            menu.addItem(item("Process Pending Recordings (\(pending.count))", #selector(processPending)))
        }
        menu.addItem(.separator())

        addLanguageMenu(to: menu)
        addMinutesWriterMenus(to: menu)
        addMicrophoneMenu(to: menu)

        let shortcuts = NSMenu()
        for (index, preset) in HotKeyPresets.all.enumerated() {
            let option = item(preset.title, #selector(selectHotKey(_:)))
            option.tag = index
            option.state = index == Settings.shared.hotKeyPreset ? .on : .off
            shortcuts.addItem(option)
        }
        let shortcutItem = NSMenuItem(title: "Shortcut: \(HotKeyPresets.current.title)", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(item("Change Minutes Folder…", #selector(changeMinutesFolder)))
        menu.addItem(toggle("Sound on Start and Stop", Settings.shared.playSounds, #selector(toggleSounds)))
        menu.addItem(toggle("Keep Meeting Audio", Settings.shared.keepAudio, #selector(toggleKeepAudio)))
        menu.addItem(toggle("Open at Login", LoginItem.isEnabled, #selector(toggleLoginItem)))
        let permissions = item("Check Permissions…", #selector(runOnboardingFromMenu))
        permissions.isEnabled = !onboardingRunning && !recorder.isRecording
        menu.addItem(permissions)
        menu.addItem(item("Show Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Meeting Minutes", #selector(quit)))
    }

    private func addLanguageMenu(to menu: NSMenu) {
        let languages = NSMenu()
        let current = MeetingLanguage.locale.identifier
        let supported = MeetingLanguage.supported
        if supported.isEmpty {
            let loading = NSMenuItem(title: MeetingLanguage.displayName, action: nil, keyEquivalent: "")
            loading.state = .on
            loading.isEnabled = false
            languages.addItem(loading)
        }
        for locale in supported {
            let option = item(MeetingLanguage.displayName(locale), #selector(selectLanguage(_:)))
            option.representedObject = locale.identifier
            option.state = locale.identifier == current ? .on : .off
            languages.addItem(option)
        }
        let languageItem = NSMenuItem(title: "Meeting Language: \(MeetingLanguage.displayName)", action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        menu.addItem(languageItem)
    }

    private func addMinutesWriterMenus(to menu: NSMenu) {
        let currentEngine = MinutesGenerator.currentEngine()
        let engines = NSMenu()
        for provider in MinutesProvider.allCases {
            let available = MinutesGenerator.engine(for: provider) != nil
            var title = provider.title
            if !available { title += provider == .claudeAPI ? " — set key…" : " — not installed" }
            let option = item(title, #selector(selectProvider(_:)))
            option.representedObject = provider.rawValue
            option.state = currentEngine.provider == provider ? .on : .off
            option.isEnabled = available || provider == .claudeAPI
            engines.addItem(option)
        }
        let engineItem = NSMenuItem(title: "Minutes Written By: \(currentEngine.provider?.shortTitle ?? "nobody (transcript only)")", action: nil, keyEquivalent: "")
        engineItem.submenu = engines
        menu.addItem(engineItem)

        if case .gemini = currentEngine {
            let models = NSMenu()
            let standard = item("Antigravity Default", #selector(selectGeminiModel(_:)))
            standard.representedObject = ""
            standard.state = GeminiModels.selectedID == nil ? .on : .off
            models.addItem(standard)
            let cached = GeminiModels.cached
            if !cached.isEmpty { models.addItem(.separator()) }
            for model in cached {
                let option = item(model.label, #selector(selectGeminiModel(_:)))
                option.representedObject = model.id
                option.state = GeminiModels.selectedID == model.id ? .on : .off
                models.addItem(option)
            }
            models.addItem(.separator())
            models.addItem(item("Refresh Model List", #selector(refreshGeminiModels)))
            let modelItem = NSMenuItem(title: "Minutes Model: \(GeminiModels.selectedLabel)", action: nil, keyEquivalent: "")
            modelItem.submenu = models
            menu.addItem(modelItem)
        } else if currentEngine.provider != nil {
            let models = NSMenu()
            for model in MinutesModel.allCases {
                let option = item(model.title, #selector(selectModel(_:)))
                option.representedObject = model.rawValue
                option.state = model == MinutesModel.current ? .on : .off
                models.addItem(option)
            }
            let modelItem = NSMenuItem(title: "Minutes Model: \(MinutesModel.current.shortName)", action: nil, keyEquivalent: "")
            modelItem.submenu = models
            menu.addItem(modelItem)
        }
        if Keychain.readAPIKey() == nil {
            menu.addItem(item("Set Claude API Key…", #selector(configureAPIKey)))
        } else {
            menu.addItem(item("Remove Claude API Key", #selector(removeAPIKey)))
        }
    }

    private func addMicrophoneMenu(to menu: NSMenu) {
        let microphones = NSMenu()
        let followDefault = item("System Default (\(AudioDevices.defaultInputName() ?? "none"))", #selector(selectMicrophone(_:)))
        followDefault.representedObject = ""
        followDefault.state = Settings.shared.micDeviceUID == nil ? .on : .off
        microphones.addItem(followDefault)
        microphones.addItem(.separator())
        let devices = AudioDevices.inputDevices()
        for device in devices {
            let option = item(device.name, #selector(selectMicrophone(_:)))
            option.representedObject = device.uid
            option.state = Settings.shared.micDeviceUID == device.uid ? .on : .off
            microphones.addItem(option)
        }
        microphones.addItem(.separator())
        let testMic = item("Test Microphone…", #selector(testMicrophone))
        testMic.isEnabled = !recorder.isRecording && !onboardingRunning
        microphones.addItem(testMic)
        let micName = Settings.shared.micDeviceUID.flatMap { uid in devices.first { $0.uid == uid }?.name } ?? "system default"
        let micItem = NSMenuItem(title: "Microphone: \(micName)", action: nil, keyEquivalent: "")
        micItem.submenu = microphones
        menu.addItem(micItem)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Menu actions

    @objc private func toggleFromMenu() { toggleRecording() }

    @objc private func openMinutesFolder() {
        try? Paths.ensure(Paths.minutesFolder)
        NSWorkspace.shared.open(Paths.minutesFolder)
    }

    @objc private func openLastMinutes() {
        guard let path = Settings.shared.lastMinutesPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func processPending() {
        for directory in recorder.pendingSessions() { enqueue(directory) }
    }

    @objc private func regenerateFromFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Choose the minutes (.md) to regenerate"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.directoryURL = Paths.minutesFolder
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        regenerating = true
        processingStep = "Writing minutes…"
        updateStatusButton()
        let owner = self
        Task.detached(priority: .utility) {
            do {
                let engine = try await MeetingProcessor.regenerateMinutes(in: url)
                Log.info("Minutes regenerated by \(engine.label): \(url.lastPathComponent)")
                await MainActor.run {
                    Notifier.shared.post(title: "Minutes regenerated ✓", body: "\(url.lastPathComponent) — click to open.", fileURL: url)
                }
            } catch {
                await MainActor.run {
                    Notifier.shared.post(title: "Could not write the minutes", body: error.localizedDescription)
                }
            }
            await MainActor.run {
                owner.regenerating = false
                if owner.processingDirectory == nil { owner.processingStep = nil }
                owner.updateStatusButton()
            }
        }
    }

    @objc private func changeMinutesFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the minutes"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Paths.minutesFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Settings.shared.minutesFolderPath = url.path
        Log.info("Minutes folder changed to \(url.path).")
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.meetingLanguage = id
        Log.info("Meeting language: \(MeetingLanguage.displayName).")
        // Download the speech model now, so the next meeting is ready.
        Task.detached(priority: .utility) {
            do {
                try await Transcription.ensureModel()
            } catch {
                await MainActor.run {
                    Notifier.shared.post(title: "Could not prepare \(MeetingLanguage.displayName)", body: error.localizedDescription)
                }
            }
        }
    }

    @objc private func configureAPIKey() {
        if Dialog.askForAPIKey() {
            Settings.shared.minutesProvider = MinutesProvider.claudeAPI.rawValue
            Notifier.shared.post(title: "Key saved", body: "Upcoming minutes will be written through the Claude API.", sound: false)
        }
    }

    @objc private func removeAPIKey() {
        Keychain.deleteAPIKey()
        if Settings.shared.minutesProvider == MinutesProvider.claudeAPI.rawValue { Settings.shared.minutesProvider = nil }
        Notifier.shared.post(title: "Key removed", body: "Minutes written by: \(MinutesGenerator.currentEngine().label).", sound: false)
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Settings.shared.micDeviceUID = uid.isEmpty ? nil : uid
        Log.info("Microphone chosen: \(uid.isEmpty ? "system default" : sender.title).")
        if recorder.isRecording {
            Notifier.shared.post(title: "Microphone changed", body: "The change applies from the next recording.", sound: false)
        }
    }

    @objc private func testMicrophone() {
        guard !onboardingRunning else { return }
        onboardingRunning = true
        Task { @MainActor in
            await Onboarding.microphoneTestStep()
            onboardingRunning = false
        }
    }

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = MinutesProvider(rawValue: raw) else { return }
        if provider == .claudeAPI, Keychain.readAPIKey() == nil {
            guard Dialog.askForAPIKey() else { return }
        }
        Settings.shared.minutesProvider = raw
        Log.info("Minutes written by: \(provider.shortTitle).")
        if provider == .gemini, GeminiModels.cached.isEmpty {
            Task.detached(priority: .utility) { await GeminiModels.refresh() }
        }
    }

    @objc private func selectGeminiModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.geminiModel = id.isEmpty ? nil : id
    }

    @objc private func refreshGeminiModels() {
        Task.detached(priority: .utility) {
            await GeminiModels.refresh()
            await MainActor.run {
                Notifier.shared.post(title: "Gemini models refreshed", body: "\(GeminiModels.cached.count) models available in the menu.", sound: false)
            }
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Settings.shared.minutesModel = raw
    }

    @objc private func selectHotKey(_ sender: NSMenuItem) {
        Settings.shared.hotKeyPreset = sender.tag
        registerHotKey(announceFailure: true)
        updateStatusButton()
    }

    private func registerHotKey(announceFailure: Bool) {
        hotKeyOK = hotKey?.register(HotKeyPresets.current) ?? false
        if !hotKeyOK && announceFailure {
            Notifier.shared.post(
                title: "Shortcut \(HotKeyPresets.current.title) unavailable",
                body: "Another app already uses this combination. Pick another shortcut in the Meeting Minutes menu."
            )
        }
    }

    @objc private func toggleSounds() { Settings.shared.playSounds.toggle() }
    @objc private func toggleKeepAudio() { Settings.shared.keepAudio.toggle() }
    @objc private func toggleLoginItem() { LoginItem.set(enabled: !LoginItem.isEnabled) }
    @objc private func runOnboardingFromMenu() { runOnboarding() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func runOnboarding() {
        guard !onboardingRunning else { return }
        onboardingRunning = true
        Task { @MainActor in
            await Onboarding.run { [weak self] status in
                self?.transientStatus = status
                self?.updateStatusButton()
            }
            onboardingRunning = false
            updateStatusButton()
        }
    }
}
