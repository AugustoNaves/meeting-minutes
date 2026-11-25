import AppKit
import AVFoundation

// Command-line mode (diagnostics and reprocessing), e.g.:
//   "/Applications/Prosa.app/Contents/MacOS/MeetingMinutes" --diagnose
if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("--") {
    exit(CommandLineMode.run(Array(CommandLine.arguments.dropFirst())))
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon
    app.run()
}

enum CommandLineMode {
    static func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "--diagnose":
            return blocking { await diagnostics() }
        case "--transcribe" where args.count >= 2:
            return blocking { try await transcribe(URL(fileURLWithPath: args[1])) }
        case "--process" where args.count >= 2:
            return blocking { try await process(URL(fileURLWithPath: args[1])) }
        case "--regenerate" where args.count >= 2:
            return blocking { try await regenerate(URL(fileURLWithPath: args[1])) }
        case "--dictate" where args.count >= 2:
            return blocking { await dictate(URL(fileURLWithPath: args[1])) }
        case "--dictate-live" where args.count >= 2:
            return blocking { try await dictateLive(URL(fileURLWithPath: args[1])) }
        case "--learn-glossary":
            return blocking { try await learnGlossary() }
        default:
            print("""
            Usage:
              --diagnose               show permissions, speech model and minutes writer
              --transcribe <audio>     transcribe an audio file and print the result
              --process <folder>       write the minutes for a kept recording (folder with meta.json)
              --regenerate <file.md>   rewrite the minutes of an .md from its transcript
              --dictate <audio>        run dictation on an audio file and print the text (nothing is typed)
              --dictate-live <audio>   play an audio file into live dictation at real speed and show
                                       what would be typed while speaking (nothing is typed)
              --learn-glossary         update the glossary from recent dictations and minutes now
            """)
            return 64
        }
    }

    private static func blocking(_ work: @escaping @Sendable () async throws -> Void) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 0
        Task.detached {
            do {
                try await work()
            } catch {
                FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
                code = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return code
    }

    private static func diagnostics() async {
        await MeetingLanguage.resolveDefaultIfNeeded()
        // From Terminal, macOS reports Terminal's permissions, not the app's.
        // So the app's permissions come from the last line it wrote to the log.
        let log = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
        let permissions = log.components(separatedBy: "\n").last(where: { $0.contains("Permissions:") })
        print("App permissions (last launch): \(permissions?.components(separatedBy: "Permissions: ").last ?? "open the app once")")
        print("Meeting language: \(MeetingLanguage.displayName)")
        print("Speech model installed: \(await Transcription.isModelInstalled() ? "yes" : "no")")
        print("Minutes writer: \(MinutesGenerator.currentEngine().label)")
        if let cli = MinutesGenerator.findClaudeCLI() { print("Claude Code: \(cli.path)") }
        if let agy = MinutesGenerator.findAntigravityCLI() {
            print("Antigravity (Gemini): \(agy.path)")
            if GeminiModels.cached.isEmpty { await GeminiModels.refresh() }
            print("Gemini models: \(GeminiModels.cached.map(\.id).joined(separator: ", "))")
        }
        print("Minutes folder: \(Paths.minutesFolder.path)")
        print("Pending recordings: \(Recorder().pendingSessions().count)")
        print("Log: \(Log.fileURL.path)")
    }

    private static func transcribe(_ url: URL) async throws {
        await MeetingLanguage.resolveDefaultIfNeeded()
        try await Transcription.ensureModel()
        let start = Date()
        let phrases = try await Transcription.transcribe(fileURL: url, locale: MeetingLanguage.locale)
        let lines = TranscriptBuilder.build(micPhrases: phrases, systemPhrases: [])
        print(TranscriptBuilder.markdown(lines, strings: MeetingLanguage.strings))
        print(String(format: "\n(%.1f s)", Date().timeIntervalSince(start)))
    }

    private static func process(_ directory: URL) async throws {
        await MeetingLanguage.resolveDefaultIfNeeded()
        let outcome = try await MeetingProcessor.process(sessionDirectory: directory) { step in print(step) }
        print("Minutes: \(outcome.fileURL.path)")
        if let failure = outcome.failure { print("Warning: \(failure)") }
    }

    private static func dictate(_ audio: URL) async {
        let start = Date()
        let outcome = await DictationPipeline.run(audioURL: audio, cleanUp: Settings.shared.dictationCleanUp)
        print("Heard:     \(outcome.raw)")
        print("Glossary:  \(Glossary.load().apply(to: outcome.raw))")
        print("Final:     \(outcome.text)")
        if let note = outcome.note { print("Note:      \(note)") }
        print(String(format: "(%.1f s%@)", Date().timeIntervalSince(start), outcome.polished ? ", polished by AI" : ""))
        if !outcome.text.isEmpty {
            DictationHistory.append(DictationRecord(date: Date(), raw: outcome.raw, text: outcome.text, app: "command line"))
        }
    }

    /// Feeds a file to dictation in 100 ms pieces, like a microphone, and prints what
    /// "Type as You Speak" would type while speaking, how fast the final text is ready, and how
    /// it would be corrected (nothing is typed).
    private static func dictateLive(_ audio: URL) async throws {
        await MeetingLanguage.resolveDefaultIfNeeded()
        let locale = MeetingLanguage.locale
        await LiveTranscriber.warmUp(locale: locale)
        let file = try AVAudioFile(forReading: audio)
        let quick = LiveTranscriber(quick: true)
        let accurate = LiveTranscriber(quick: false)
        let start = Date()
        final class Typed: @unchecked Sendable {
            var text = ""
            var words = 0
            var live = ""
            var lastUpdate = Date()
            let lock = NSLock()
            func current() -> String { lock.lock(); defer { lock.unlock() }; return text }
            /// Same rule as LiveTyper.append.
            func append(_ live: String, includingLastWord: Bool, at start: Date) {
                lock.lock(); defer { lock.unlock() }
                let words = includingLastWord ? live.split(whereSeparator: \.isWhitespace) : LiveTyper.settledWords(live)
                guard words.count > self.words else { return }
                let addition = (text.isEmpty ? "" : " ") + words[self.words...].joined(separator: " ")
                print(String(format: "%5.1fs  types: “%@”%@", Date().timeIntervalSince(start), addition, includingLastWord ? "  (pause)" : ""))
                text += addition
                self.words = words.count
            }
            func update(_ live: String) { lock.lock(); self.live = live; lastUpdate = Date(); lock.unlock() }
            func pauseCheck() -> String? {
                lock.lock(); defer { lock.unlock() }
                return Date().timeIntervalSince(lastUpdate) >= DictationController.pauseFlush ? live : nil
            }
        }
        let typed = Typed()
        quick.onText = { (text: String) in
            let corrected = Glossary.load().apply(to: text)
            typed.update(corrected)
            typed.append(corrected, includingLastWord: false, at: start)
        }
        quick.start(locale: locale)
        accurate.start(locale: locale)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 0.1)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            quick.append(buffer)
            accurate.append(buffer)
            if let live = typed.pauseCheck() { typed.append(live, includingLastWord: true, at: start) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let stoppedAt = Date()
        print(String(format: "%5.1fs  — stopped —", stoppedAt.timeIntervalSince(start)))
        quick.stop()
        let raw = await accurate.finish(timeout: 2.5) ?? ""
        print(String(format: "        final text ready %.2f s after stopping%@", Date().timeIntervalSince(stoppedAt), raw.isEmpty ? " (empty: the app would transcribe the recording)" : ""))
        let corrected = Glossary.load().apply(to: raw)
        let edit = LiveTyper.edit(from: typed.current(), to: corrected)
        print("        corrects: \(describe(edit))")
        print("Heard:  \(raw)")
        print("Final:  \(corrected)")
        if Settings.shared.dictationCleanUp {
            let outcome = await DictationPipeline.polish(raw: raw, corrected: corrected)
            let second = LiveTyper.edit(from: corrected, to: outcome.text)
            print(String(format: "%5.1fs  AI clean-up (in the background): %@", Date().timeIntervalSince(start), describe(second)))
            print("Polished: \(outcome.text)")
        }
    }

    /// What LiveTyper.replace does for an edit.
    private static func describe(_ edit: (deletions: Int, insertion: String)) -> String {
        if edit.deletions == 0 && edit.insertion.isEmpty { return "nothing to change" }
        if edit.deletions <= LiveTyper.maxTypedCorrection && edit.insertion.count <= 40 {
            return "\(edit.deletions) backspace(s), then types “\(edit.insertion)”"
        }
        return "selects the last \(edit.deletions) character(s) and pastes “\(edit.insertion)” in one go"
    }

    private static func learnGlossary() async throws {
        await MeetingLanguage.resolveDefaultIfNeeded()
        let engine = MinutesGenerator.currentEngine()
        if case .none = engine { throw MinutesError.noEngine }
        let outcome = try await GlossaryLearner.learn(engine: engine, locale: MeetingLanguage.locale, since: Settings.shared.glossaryLearnedAt)
        Settings.shared.glossaryLearnedAt = Date()
        Settings.shared.dictationsSinceLearning = 0
        print("Glossary: \(outcome.summary) — \(Glossary.fileURL.path)")
        for term in outcome.addedTerms { print("  + term: \(term)") }
        for correction in outcome.addedCorrections { print("  + correction: \(correction.heard) → \(correction.correct)") }
    }

    private static func regenerate(_ file: URL) async throws {
        await MeetingLanguage.resolveDefaultIfNeeded()
        let engine = try await MeetingProcessor.regenerateMinutes(in: file)
        print("Minutes regenerated by \(engine.label): \(file.path)")
    }
}
