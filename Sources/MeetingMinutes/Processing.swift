import Foundation

// MARK: - The .md file

enum MarkdownWriter {
    static func title(for date: Date, locale: Locale, strings: MinutesStrings) -> String {
        "# \(strings.title) - \(Formatting.titleDate(date, locale: locale))"
    }

    static func render(title: String, strings: MinutesStrings, minutes: Minutes?, failure: String?, transcript: String, warnings: [String]) -> String {
        var md = "\(title)\n\n"
        for warning in warnings {
            md += "> **\(strings.warning):** \(oneLine(warning))\n\n"
        }

        md += "## \(strings.summary)\n"
        if let minutes {
            md += "\(minutes.summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        } else {
            let reason = failure.map { oneLine($0) } ?? "unknown reason"
            md += "_\(String(format: strings.failure, reason))_\n\n"
        }

        md += "## \(strings.topics)\n"
        md += list(minutes?.topics, empty: strings.noTopics, missing: minutes == nil, strings: strings)

        md += "## \(strings.decisions)\n"
        md += list(minutes?.decisions, empty: strings.noDecisions, missing: minutes == nil, strings: strings)

        md += "## \(strings.nextSteps)\n"
        if let minutes {
            let items = minutes.actionItems.filter { !$0.description.trimmingCharacters(in: .whitespaces).isEmpty }
            if items.isEmpty {
                md += "- \(strings.noActionItems)\n\n"
            } else {
                for item in items {
                    let owner = oneLine(item.owner).isEmpty ? strings.toBeDefined : oneLine(item.owner)
                    md += "- [ ] \(oneLine(item.description)) — **\(strings.owner):** \(owner)\n"
                }
                md += "\n"
            }
        } else {
            md += "- _\(strings.notGenerated)_\n\n"
        }

        md += "---\n\n## \(strings.transcript)\n"
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        md += body.isEmpty ? "_\(strings.emptyTranscript)_\n" : "\(body)\n"
        return md
    }

    private static func list(_ items: [String]?, empty: String, missing: Bool, strings: MinutesStrings) -> String {
        if missing { return "- _\(strings.notGenerated)_\n\n" }
        let clean = (items ?? []).map { oneLine($0) }.filter { !$0.isEmpty }
        if clean.isEmpty { return "- \(empty)\n\n" }
        return clean.map { "- \($0)\n" }.joined() + "\n"
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueURL(for date: Date) -> URL {
        let base = "\(Formatting.fileDate.string(from: date))_Meeting"
        var url = Paths.minutesFolder.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Paths.minutesFolder.appendingPathComponent("\(base)_\(counter).md")
            counter += 1
        }
        return url
    }
}

// MARK: - From audio to .md

struct ProcessOutcome {
    let fileURL: URL
    let minutesGenerated: Bool
    let failure: String?
    let warnings: [String]
}

enum MeetingProcessor {
    /// Transcribes both tracks, builds the transcript, writes the minutes and saves the .md.
    /// If transcription fails, the recording is kept so it can be processed again.
    static func process(sessionDirectory dir: URL, progress: @escaping @Sendable (String) -> Void) async throws -> ProcessOutcome {
        let meta = SessionMeta.load(from: dir) ?? SessionMeta(startDate: Date())
        let locale = meta.language.map { Locale(identifier: $0) } ?? MeetingLanguage.locale
        let strings = MeetingLanguage.strings(for: locale)
        let micURL = dir.appendingPathComponent(SessionMeta.micFile)
        let systemURL = dir.appendingPathComponent(SessionMeta.systemFile)
        let startedAt = Date()

        progress("Transcribing…")
        try await Transcription.ensureModel(locale: locale)
        async let micPhrases = Transcription.transcribe(fileURL: micURL, locale: locale)
        async let systemPhrases = Transcription.transcribe(fileURL: systemURL, locale: locale)
        let (mic, system) = try await (micPhrases, systemPhrases)
        let lines = TranscriptBuilder.build(micPhrases: mic, systemPhrases: system)
        let transcript = TranscriptBuilder.markdown(lines, strings: strings)
        Log.info("Transcript ready: \(lines.count) lines in \(Int(Date().timeIntervalSince(startedAt))) s (\(MeetingLanguage.displayName(locale))).")

        let duration: Double = {
            if let end = meta.endDate { return end.timeIntervalSince(meta.startDate) }
            return lines.last?.end ?? 0
        }()
        let context = "Meeting date: \(Formatting.titleDate(meta.startDate, locale: Locale(identifier: "en_US"))). Approximate duration: \(Formatting.elapsed(duration))."

        var minutes: Minutes?
        var failure: String?
        let engine = MinutesGenerator.currentEngine()
        if lines.isEmpty {
            failure = "no speech was recognized in the recording"
        } else if case .none = engine {
            failure = MinutesError.noEngine.localizedDescription
        } else {
            progress("Writing minutes…")
            do {
                let generationStart = Date()
                minutes = try await MinutesGenerator.generate(transcript: transcript, context: context, locale: locale, engine: engine)
                Log.info("Minutes written by \(engine.label) in \(Int(Date().timeIntervalSince(generationStart))) s.")
            } catch {
                failure = error.localizedDescription
                Log.error("Could not write the minutes: \(error.localizedDescription)")
            }
        }

        let markdown = MarkdownWriter.render(
            title: MarkdownWriter.title(for: meta.startDate, locale: locale, strings: strings),
            strings: strings,
            minutes: minutes,
            failure: failure,
            transcript: transcript,
            warnings: meta.warnings
        )
        try Paths.ensure(Paths.minutesFolder)
        let fileURL = MarkdownWriter.uniqueURL(for: meta.startDate)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        Log.info("Minutes saved to \(fileURL.path).")

        if Settings.shared.keepAudio {
            let base = fileURL.deletingPathExtension().lastPathComponent
            do {
                try Paths.ensure(Paths.audioArchiveFolder)
                for (source, suffix) in [(micURL, "you"), (systemURL, "meeting")] where FileManager.default.fileExists(atPath: source.path) {
                    try AudioArchiver.archive(source, to: Paths.audioArchiveFolder.appendingPathComponent("\(base)_\(suffix).m4a"))
                }
            } catch {
                Log.error("Could not keep the audio: \(error.localizedDescription)")
            }
        }
        try? FileManager.default.removeItem(at: dir)

        return ProcessOutcome(fileURL: fileURL, minutesGenerated: minutes != nil, failure: failure, warnings: meta.warnings)
    }

    /// Reads an existing .md, sends its transcript to the AI again and rewrites the minutes part.
    static func regenerateMinutes(in fileURL: URL) async throws -> MinutesEngine {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        guard let detected = MeetingLanguage.detect(in: text) else {
            throw MinutesError.invalidResponse("the file has no “Full Transcript” section")
        }
        let strings = detected.strings
        let transcript = String(text[detected.heading.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, transcript != "_\(strings.emptyTranscript)_" else {
            throw MinutesError.invalidResponse("the transcript in this file is empty")
        }
        let title = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") })
            ?? "# \(strings.title) - \(fileURL.deletingPathExtension().lastPathComponent)"
        let dateText = title.replacingOccurrences(of: "# \(strings.title) - ", with: "")
        let engine = MinutesGenerator.currentEngine()
        if case .none = engine { throw MinutesError.noEngine }
        let minutes = try await MinutesGenerator.generate(
            transcript: transcript, context: "Meeting date: \(dateText).", locale: detected.locale, engine: engine
        )
        let markdown = MarkdownWriter.render(title: title, strings: strings, minutes: minutes, failure: nil, transcript: transcript, warnings: [])
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return engine
    }
}
