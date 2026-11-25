import AppKit
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private var hotKey: HotKey?
    private var hotKeyOK = true
    private let dictation = DictationController()
    private var dictationHotKey: HotKey?
    private var dictationHotKeyOK = true
    private var learningGlossary = false
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
    /// How many recording problems the user has already been alerted about.
    private var alertedWarnings = 0

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
        setUpDictation()
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
                    body: "Open the Prosa menu and choose “Process Pending Recordings”.",
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
            Log.info("Permissions: microphone \(mic); notifications \(notifications); typing into other apps \(AXIsProcessTrusted() ? "allowed" : "not allowed").")
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
    /// (handy for macOS Shortcuts, Raycast, Stream Deck…). Any app or web page can open such a
    /// link, so a link that would START a recording asks first (unless you chose “Always Allow”).
    /// Stopping is always allowed.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "meetingminutes" {
            switch url.host {
            case "toggle":
                if recorder.isRecording { stopRecording() } else if linkMayStartRecording() { startRecording() }
            case "start":
                if !recorder.isRecording, linkMayStartRecording() { startRecording() }
            case "stop":
                stopRecording()
            default:
                break
            }
        }
    }

    private func linkMayStartRecording() -> Bool {
        if Settings.shared.linksMayStartRecording { return true }
        let choice = Dialog.show(
            "Start recording?",
            "A link (from a shortcut, an app or a web page) asked Prosa to start recording your microphone and the sound of your Mac.\n\nIf you did not ask for this, click Cancel.",
            buttons: ["Start Recording", "Cancel", "Always Allow Links"],
            style: .warning
        )
        if choice == 2 {
            Settings.shared.linksMayStartRecording = true
            Log.info("Links may now start recordings without asking.")
            return true
        }
        Log.info(choice == 0 ? "A link started a recording (confirmed)." : "A link tried to start a recording; it was cancelled.")
        return choice == 0
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
        logPermissions()
        do {
            _ = try recorder.start()
            alertedWarnings = 0
            if Settings.shared.playSounds { NSSound(named: "Tink")?.play() }
            startTimer()
            alertNewWarnings()
        } catch {
            NSSound(named: "Basso")?.play()
            Log.error("Could not start recording: \(error.localizedDescription)")
            Notifier.shared.post(title: "Could not record", body: error.localizedDescription)
        }
        updateStatusButton()
    }

    /// A track failed or stopped: the icon turns orange (see updateStatusButton), a sound plays
    /// and a notification is posted. The sound and the icon also work with notifications off.
    private func alertNewWarnings() {
        let warnings = recorder.liveWarnings
        guard warnings.count > alertedWarnings else { return }
        let new = warnings[alertedWarnings...]
        alertedWarnings = warnings.count
        NSSound(named: "Basso")?.play()
        Notifier.shared.post(title: "Recording, with a problem", body: new.joined(separator: " "))
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
            MainActor.assumeIsolated {
                self?.alertNewWarnings()
                self?.updateStatusButton()
            }
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
        MinutesViewer.shared.minutesChanged(selecting: outcome.fileURL)
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
            // New minutes = new names spelled from context: a good moment to grow the glossary.
            if Settings.shared.glossaryAutoLearn { learnGlossary(manual: false) }
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

    /// The app's own menu bar mark when idle: the two Calçadão waves (a template image, so it
    /// follows the menu bar's light or dark look).
    private static let wavesSymbol = "prosa.waves"
    private static let wavesGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { rect in
            NSColor.black.setStroke()
            for y in [10.5, 5.5] as [CGFloat] {
                let path = NSBezierPath()
                path.lineWidth = 1.9
                path.lineCapStyle = .round
                var x: CGFloat = 2.5
                path.move(to: NSPoint(x: x, y: y + sin(x / 2.6) * 1.8))
                while x < rect.width - 2.5 {
                    x = min(rect.width - 2.5, x + 0.5)
                    path.line(to: NSPoint(x: x, y: y + sin(x / 2.6) * 1.8))
                }
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Prosa"
        return image
    }()

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        var symbol = Self.wavesSymbol
        var color: NSColor?
        var title = ""
        var tooltip = "Prosa — \(HotKeyPresets.current.title) to record"

        if dictation.state == .listening {
            symbol = "mic.fill"
            color = .systemRed
            title = ""
            tooltip = dictation.handsFree
                ? "Dictating — press \(DictationHotKeyPresets.current?.title ?? "the shortcut") again to type the text"
                : "Dictating — release the keys to type the text"
        } else if dictation.state == .finishing {
            symbol = "text.bubble"
            title = ""
            tooltip = "Turning your dictation into text"
        } else if recorder.isRecording, let start = recorder.startDate {
            symbol = "record.circle.fill"
            color = .systemRed
            title = " " + Formatting.elapsed(Date().timeIntervalSince(start))
            tooltip = "Recording — \(HotKeyPresets.current.title) to stop"
            let warnings = recorder.liveWarnings
            if !warnings.isEmpty {
                symbol = "exclamationmark.triangle.fill"
                color = .systemOrange
                tooltip = "Recording with a problem — \(warnings.joined(separator: " "))"
            }
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

        if symbol == Self.wavesSymbol {
            button.image = Self.wavesGlyph
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        } else if var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Prosa") {
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
            let problem = recorder.liveWarnings.isEmpty ? "" : " (with a problem)"
            return "Recording\(problem) — \(Formatting.elapsed(Date().timeIntervalSince(start)))"
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
        if recorder.isRecording {
            for problem in recorder.liveWarnings {
                let warning = NSMenuItem(title: "⚠︎ \(problem)", action: nil, keyEquivalent: "")
                warning.isEnabled = false
                menu.addItem(warning)
            }
        }
        if !dictationHotKeyOK, let preset = DictationHotKeyPresets.current {
            let warning = NSMenuItem(title: "⚠︎ The dictation shortcut \(preset.title) is used by another app — pick another one under Dictation", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        if !hotKeyOK {
            let warning = NSMenuItem(title: "⚠︎ The shortcut \(HotKeyPresets.current.title) is used by another app — pick another one below", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        menu.addItem(item(recorder.isRecording ? "Stop Recording" : "Start Recording", #selector(toggleFromMenu)))
        menu.addItem(.separator())

        menu.addItem(item("Open Minutes…", #selector(openMinutesViewer)))
        if let last = Settings.shared.lastMinutesPath, FileManager.default.fileExists(atPath: last) {
            menu.addItem(item("Open Latest Minutes", #selector(openLastMinutes)))
        }
        menu.addItem(item("Open Minutes Folder", #selector(openMinutesFolder)))
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
        addDictationMenu(to: menu)

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
        menu.addItem(item("Quit Prosa", #selector(quit)))
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
        let chosenNone = Settings.shared.minutesProvider == MinutesProvider.none.rawValue
        let engines = NSMenu()
        engines.autoenablesItems = false
        for provider in MinutesProvider.allCases {
            if provider == .none { engines.addItem(.separator()) }
            let ready = provider == .none || MinutesGenerator.engine(for: provider) != nil
            var title = provider.title
            var enabled = true
            switch provider {
            case .claudeCode, .gemini:
                if !ready { title += " — not installed"; enabled = false }
            case .claudeAPI:
                if !ready { title += " — set key…" }
            case .none:
                break
            default:
                if !ready { title += " — set up…" }
            }
            let option = item(title, #selector(selectProvider(_:)))
            option.representedObject = provider.rawValue
            option.state = (provider == .none ? chosenNone : currentEngine.provider == provider) ? .on : .off
            option.isEnabled = enabled
            engines.addItem(option)
        }
        let writer = chosenNone || currentEngine.provider == nil ? "No AI (transcript only)" : (currentEngine.provider?.shortTitle ?? "")
        let engineItem = NSMenuItem(title: "Minutes Written By: \(writer)", action: nil, keyEquivalent: "")
        engineItem.submenu = engines
        menu.addItem(engineItem)

        switch currentEngine {
        case .gemini:
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
        case .claudeAPI, .claudeCode:
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
        case let .compatible(connection):
            let service = connection.service
            let models = NSMenu()
            for model in service.cachedModels {
                let option = item(model, #selector(selectCompatibleModel(_:)))
                option.representedObject = model
                option.state = model == connection.model ? .on : .off
                models.addItem(option)
            }
            if !service.cachedModels.isEmpty { models.addItem(.separator()) }
            models.addItem(item("Refresh Model List", #selector(refreshCompatibleModels)))
            if service != .ollama {
                models.addItem(item(service == .custom ? "Change Address or Key…" : "Change Key…", #selector(reconfigureCompatible)))
                models.addItem(item("Remove Key", #selector(removeCompatibleKey)))
            }
            let modelItem = NSMenuItem(title: "Minutes Model: \(connection.model)", action: nil, keyEquivalent: "")
            modelItem.submenu = models
            menu.addItem(modelItem)
        case .none:
            break
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

    private func addDictationMenu(to menu: NSMenu) {
        let current = DictationHotKeyPresets.current
        let submenu = NSMenu()
        let explanation = NSMenuItem(
            title: current.map { "Hold \($0.title) and talk; release to finish. A quick tap keeps listening until the next tap." } ?? "Dictation is off",
            action: nil, keyEquivalent: ""
        )
        explanation.isEnabled = false
        submenu.addItem(explanation)
        submenu.addItem(.separator())
        for (index, preset) in DictationHotKeyPresets.all.enumerated() {
            let option = item("Shortcut: \(preset.title)", #selector(selectDictationHotKey(_:)))
            option.tag = index
            option.state = index == Settings.shared.dictationHotKeyPreset ? .on : .off
            submenu.addItem(option)
        }
        let off = item("Off", #selector(selectDictationHotKey(_:)))
        off.tag = -1
        off.state = current == nil ? .on : .off
        submenu.addItem(off)
        submenu.addItem(.separator())

        let writer = MinutesGenerator.currentEngine().provider?.shortTitle
        submenu.addItem(toggle("Type as You Speak", Settings.shared.dictationTypeLive, #selector(toggleDictationTypeLive)))
        submenu.addItem(toggle("Clean Up Text with AI" + (writer.map { " (\($0))" } ?? ""), Settings.shared.dictationCleanUp, #selector(toggleDictationCleanUp)))
        if !TextInserter.canPaste {
            submenu.addItem(item("Allow Typing into Other Apps…", #selector(allowTyping)))
        }
        submenu.addItem(.separator())
        submenu.addItem(toggle("Learn Glossary Automatically", Settings.shared.glossaryAutoLearn, #selector(toggleGlossaryLearning)))
        let update = item(learningGlossary ? "Updating Glossary…" : "Update Glossary Now", #selector(updateGlossaryNow))
        update.isEnabled = !learningGlossary
        submenu.addItem(update)
        submenu.addItem(item("Open Glossary", #selector(openGlossary)))

        let dictationItem = NSMenuItem(title: "Dictation: \(current?.title ?? "off")", action: nil, keyEquivalent: "")
        dictationItem.submenu = submenu
        menu.addItem(dictationItem)
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
        MinutesViewer.shared.show(selecting: URL(fileURLWithPath: path))
    }

    @objc private func openMinutesViewer() { MinutesViewer.shared.show() }

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
        // A service already set up is chosen right away; otherwise it is set up first.
        if let service = provider.compatible, service.connection != nil {
            Settings.shared.minutesProvider = raw
            Log.info("Minutes written by: \(provider.shortTitle).")
            return
        }
        Task { @MainActor in
            if await Onboarding.apply(provider) {
                Log.info("Minutes written by: \(provider.shortTitle).")
            }
        }
    }

    private var currentCompatible: CompatibleService? {
        if case let .compatible(connection) = MinutesGenerator.currentEngine() { return connection.service }
        return nil
    }

    @objc private func selectCompatibleModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String, let service = currentCompatible else { return }
        service.model = model
        Log.info("Minutes model: \(service.shortTitle) · \(model).")
    }

    @objc private func refreshCompatibleModels() {
        guard let service = currentCompatible, let base = service.baseURL.flatMap(URL.init(string:)) else { return }
        Task { @MainActor in
            do {
                let models = try await CompatibleService.listModels(baseURL: base, key: service.key, service: service)
                service.cachedModels = models
                Notifier.shared.post(title: "\(service.shortTitle) models refreshed", body: "\(models.count) models available in the menu.", sound: false)
            } catch {
                Notifier.shared.post(title: "Could not list \(service.shortTitle) models", body: error.localizedDescription)
            }
        }
    }

    @objc private func reconfigureCompatible() {
        guard let service = currentCompatible else { return }
        Task { @MainActor in _ = await AISetup.configure(service) }
    }

    @objc private func removeCompatibleKey() {
        guard let service = currentCompatible else { return }
        service.saveKey(nil)
        Settings.shared.minutesProvider = nil
        Notifier.shared.post(title: "Key removed", body: "Minutes written by: \(MinutesGenerator.currentEngine().label).", sound: false)
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

    // MARK: - Dictation

    private func setUpDictation() {
        dictationHotKey = HotKey(
            onPress: { [weak self] in self?.dictation.keyDown() },
            onRelease: { [weak self] in self?.dictation.keyUp() }
        )
        registerDictationHotKey(announceFailure: true)
        // Load the speech model now, so the first dictation shows words right away.
        Task.detached(priority: .utility) {
            await MeetingLanguage.resolveDefaultIfNeeded()
            await LiveTranscriber.warmUp(locale: MeetingLanguage.locale)
        }
        dictation.onChange = { [weak self] in self?.updateStatusButton() }
        dictation.onProblem = { [weak self] message in
            Log.error(message)
            NSSound(named: "Basso")?.play()
            Notifier.shared.post(title: "Dictation", body: message)
            self?.showBadgeIfNotificationsOff(Badge(text: "Dictation problem", symbol: "exclamationmark.triangle.fill", color: .systemOrange))
        }
        dictation.onDictated = { [weak self] _, delivery in
            guard let self else { return }
            if delivery == .copied {
                Notifier.shared.post(
                    title: "Text copied — press ⌘V",
                    body: "To have dictation type by itself, allow Prosa in System Settings › Privacy & Security › Accessibility.",
                    sound: false
                )
                showBadgeIfNotificationsOff(Badge(text: "Copied — press ⌘V", symbol: "doc.on.clipboard", color: .systemBlue))
            }
            Settings.shared.dictationsSinceLearning += 1
            if Settings.shared.glossaryAutoLearn && Settings.shared.dictationsSinceLearning >= 15 {
                learnGlossary(manual: false)
            }
        }
    }

    private func registerDictationHotKey(announceFailure: Bool) {
        guard let preset = DictationHotKeyPresets.current else {
            dictationHotKey?.unregister()
            dictationHotKeyOK = true
            return
        }
        dictationHotKeyOK = dictationHotKey?.register(preset) ?? false
        if !dictationHotKeyOK && announceFailure {
            Notifier.shared.post(
                title: "Dictation shortcut \(preset.title) unavailable",
                body: "Another app already uses this combination. Pick another one in the Prosa menu, under Dictation."
            )
        }
    }

    /// Asks the AI to add new terms and corrections to the glossary, in the background.
    private func learnGlossary(manual: Bool) {
        guard !learningGlossary else { return }
        let engine = MinutesGenerator.currentEngine()
        if case .none = engine {
            if manual { Notifier.shared.post(title: "Could not update the glossary", body: MinutesError.noEngine.localizedDescription) }
            return
        }
        learningGlossary = true
        let since = Settings.shared.glossaryLearnedAt
        let startedAt = Date()
        // The AppDelegate lives as long as the app; it is safe to capture directly.
        let owner = self
        Task.detached(priority: .utility) {
            await MeetingLanguage.resolveDefaultIfNeeded()
            let result: Result<GlossaryLearner.Outcome, Error>
            do {
                result = .success(try await GlossaryLearner.learn(engine: engine, locale: MeetingLanguage.locale, since: since))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                owner.learningGlossary = false
                // Wait for 15 more dictations (or the next minutes) before trying again, even after a failure.
                Settings.shared.dictationsSinceLearning = 0
                switch result {
                case let .success(outcome):
                    Settings.shared.glossaryLearnedAt = startedAt
                    if manual {
                        Notifier.shared.post(title: "Glossary updated", body: "\(outcome.summary). Click to open it.", fileURL: Glossary.fileURL, sound: false)
                    }
                case let .failure(error):
                    if error is GlossaryLearner.LearnError { Settings.shared.glossaryLearnedAt = startedAt }
                    if manual {
                        Notifier.shared.post(title: "Could not update the glossary", body: error.localizedDescription)
                    } else if !(error is GlossaryLearner.LearnError) {
                        Log.error("Could not update the glossary: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func selectDictationHotKey(_ sender: NSMenuItem) {
        Settings.shared.dictationHotKeyPreset = sender.tag
        registerDictationHotKey(announceFailure: true)
    }

    @objc private func toggleDictationCleanUp() { Settings.shared.dictationCleanUp.toggle() }
    @objc private func toggleDictationTypeLive() { Settings.shared.dictationTypeLive.toggle() }
    @objc private func toggleGlossaryLearning() { Settings.shared.glossaryAutoLearn.toggle() }
    @objc private func updateGlossaryNow() { learnGlossary(manual: true) }

    @objc private func allowTyping() {
        TextInserter.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGlossary() {
        if !FileManager.default.fileExists(atPath: Glossary.fileURL.path) {
            do {
                try Glossary().save()
            } catch {
                Log.error("Could not create the glossary: \(error.localizedDescription)")
                return
            }
        }
        NSWorkspace.shared.open(Glossary.fileURL)
    }

    private func registerHotKey(announceFailure: Bool) {
        hotKeyOK = hotKey?.register(HotKeyPresets.current) ?? false
        if !hotKeyOK && announceFailure {
            Notifier.shared.post(
                title: "Shortcut \(HotKeyPresets.current.title) unavailable",
                body: "Another app already uses this combination. Pick another shortcut in the Prosa menu."
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
            logPermissions() // so --diagnose reports the permissions granted during setup
        }
    }
}
