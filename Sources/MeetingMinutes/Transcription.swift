import AVFoundation
import Foundation
import Speech

struct TimedWord {
    let start: Double
    let end: Double
    /// Text as returned by the recognizer (may include a leading space and trailing punctuation).
    let text: String
}

struct Phrase {
    let words: [TimedWord]
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case languageNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "macOS speech recognition is not available on this Mac."
        case let .languageNotSupported(language):
            return "macOS speech recognition does not support \(language) on this Mac."
        }
    }
}

/// Fully on-device transcription with macOS 26's SpeechAnalyzer.
/// The model runs outside the app, on the Neural Engine: fast and almost no memory used by the app.
enum Transcription {
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Is the speech model for this language already installed?
    static func isModelInstalled(locale: Locale = MeetingLanguage.locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Makes sure the speech model for this language is downloaded (only downloads once).
    static func ensureModel(locale: Locale = MeetingLanguage.locale) async throws {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            throw TranscriptionError.languageNotSupported(MeetingLanguage.displayName(locale))
        }
        if await isModelInstalled(locale: locale) { return }
        Log.info("Downloading the \(MeetingLanguage.displayName(locale)) speech model…")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale: locale)]) {
            try await request.downloadAndInstall()
        }
        Log.info("Speech model ready.")
    }

    /// Transcribes a whole audio file. Returns phrases with the timing of every word.
    static func transcribe(fileURL: URL, locale: Locale) async throws -> [Phrase] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let file = try AVAudioFile(forReading: fileURL)
        guard file.length > Int64(file.processingFormat.sampleRate * 0.3) else { return [] }

        let transcriber = makeTranscriber(locale: locale)
        let collector = Task { () throws -> [Phrase] in
            var phrases: [Phrase] = []
            for try await result in transcriber.results where result.isFinal {
                let phrase = makePhrase(from: result)
                if !phrase.words.isEmpty { phrases.append(phrase) }
            }
            return phrases
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    private static func makePhrase(from result: SpeechTranscriber.Result) -> Phrase {
        let text = result.text
        var words: [TimedWord] = []
        var lastEnd = result.range.start.seconds
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if piece.isEmpty { continue }
            if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                words.append(TimedWord(start: range.start.seconds, end: range.end.seconds, text: piece))
                lastEnd = range.end.seconds
            } else if let previous = words.popLast() {
                words.append(TimedWord(start: previous.start, end: previous.end, text: previous.text + piece))
            } else {
                words.append(TimedWord(start: lastEnd, end: lastEnd, text: piece))
            }
        }
        if words.isEmpty {
            let whole = String(text.characters)
            if !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                words = [TimedWord(start: result.range.start.seconds, end: result.range.end.seconds, text: whole)]
            }
        }
        return Phrase(words: trimLeadingSilence(words))
    }

    /// The recognizer stretches the first word after a silence back over that silence ("Ótimo"
    /// from 11.8 s to 13.3 s when it was said at 12.7 s). Left as is, a sentence is dated up to
    /// ~2 s early, which can put it before what the other person said just before it. A word much
    /// longer than the others has its start moved to its end minus a normal word length.
    static func trimLeadingSilence(_ words: [TimedWord]) -> [TimedWord] {
        let durations = words.map { $0.end - $0.start }.filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return words }
        let typical = min(0.6, max(0.2, durations[durations.count / 2]))
        let longest = max(0.7, typical * 2.5)
        return words.map { word in
            guard word.end - word.start > longest else { return word }
            return TimedWord(start: word.end - typical * 1.5, end: word.end, text: word.text)
        }
    }
}
