import Foundation

enum Speaker {
    case you
    case meeting

    func label(_ strings: MinutesStrings) -> String {
        self == .you ? strings.you : strings.meeting
    }
}

struct TranscriptLine {
    var start: Double
    var end: Double
    let speaker: Speaker
    var text: String
}

/// Builds the final transcript from the two tracks:
/// - [You]: what came from the microphone;
/// - [Meeting]: what came from the system audio.
///
/// It also removes "echo": on speakers instead of headphones, the microphone also picks up
/// the other people. Their speech is already (cleanly) in the system track, so stretches of the
/// microphone track that repeat, at the same moment, the words of the system track are dropped.
enum TranscriptBuilder {
    /// Time window (s) in which a microphone word counts as an echo of the system track.
    static let echoWindow: Double = 1.2
    /// Runs of at least this many repeated words in a row count as echo.
    static let echoMinRun = 3
    /// If this share of a microphone sentence is echo, the whole sentence is dropped.
    static let echoSentenceRatio = 0.6

    static func build(micPhrases: [Phrase], systemPhrases: [Phrase]) -> [TranscriptLine] {
        let systemWords = systemPhrases.flatMap(\.words).sorted { $0.start < $1.start }
        let micSentences = removeEcho(from: sentences(from: micPhrases), systemWords: systemWords)
        let systemSentences = sentences(from: systemPhrases)

        var lines = micSentences.compactMap { makeLine($0, speaker: .you) }
            + systemSentences.compactMap { makeLine($0, speaker: .meeting) }
        lines.sort { $0.start < $1.start }

        // Merge consecutive sentences from the same speaker so it reads naturally.
        var merged: [TranscriptLine] = []
        for line in lines {
            if var last = merged.last,
               last.speaker == line.speaker,
               line.start - last.end < 2.0,
               last.text.count + line.text.count < 700 {
                last.text += " " + line.text
                last.end = max(last.end, line.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    /// Number of words in the transcript.
    static func wordCount(_ lines: [TranscriptLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    static func markdown(_ lines: [TranscriptLine], strings: MinutesStrings) -> String {
        lines.map { "**[\(Formatting.clock($0.start))] [\($0.speaker.label(strings))]:** \($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Sentences

    /// Splits into sentences at punctuation or long pauses.
    static func sentences(from phrases: [Phrase], maxPause: Double = 1.5) -> [[TimedWord]] {
        var output: [[TimedWord]] = []
        for phrase in phrases {
            var current: [TimedWord] = []
            for word in phrase.words {
                if let last = current.last, word.start - last.end > maxPause {
                    output.append(current)
                    current = []
                }
                current.append(word)
                let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let lastChar = trimmed.last, ".?!…。？！".contains(lastChar) {
                    output.append(current)
                    current = []
                }
            }
            if !current.isEmpty { output.append(current) }
        }
        return output
    }

    private static func makeLine(_ words: [TimedWord], speaker: Speaker) -> TranscriptLine? {
        guard let first = words.first, let last = words.last else { return nil }
        let text = words.map(\.text).joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return TranscriptLine(start: first.start, end: last.end, speaker: speaker, text: text)
    }

    // MARK: - Echo

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    static func removeEcho(from micSentences: [[TimedWord]], systemWords: [TimedWord]) -> [[TimedWord]] {
        guard !systemWords.isEmpty else { return micSentences }
        let system = systemWords.map { (start: $0.start, end: $0.end, token: normalize($0.text)) }
        let starts = system.map(\.start)

        func firstIndex(atOrAfter time: Double) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < time { low = mid + 1 } else { high = mid }
            }
            return low
        }

        func isEcho(_ word: TimedWord, token: String) -> Bool {
            guard !token.isEmpty else { return false }
            var index = firstIndex(atOrAfter: word.start - echoWindow - 5)
            while index < system.count, system[index].start <= word.end + echoWindow {
                let candidate = system[index]
                if candidate.end >= word.start - echoWindow, candidate.token == token { return true }
                index += 1
            }
            return false
        }

        func overlapsSystemSpeech(start: Double, end: Double) -> Bool {
            var index = firstIndex(atOrAfter: start - 5)
            while index < system.count, system[index].start < end {
                if system[index].end > start, !system[index].token.isEmpty { return true }
                index += 1
            }
            return false
        }

        // No other speech of yours within 1.5 s before or after
        // (e.g. "Perfect." followed by the rest of your sentence is not isolated).
        let micWords = micSentences.flatMap { $0 }.sorted { $0.start < $1.start }
        func isIsolated(start: Double, end: Double) -> Bool {
            !micWords.contains { word in
                (word.end <= start && start - word.end < 1.5) || (word.start >= end && word.start - end < 1.5)
            }
        }

        var result: [[TimedWord]] = []
        for sentence in micSentences {
            let tokens = sentence.map { normalize($0.text) }
            let flags = zip(sentence, tokens).map { isEcho($0.0, token: $0.1) }
            let realIndices = tokens.indices.filter { !tokens[$0].isEmpty }
            let totalTokens = realIndices.count
            guard totalTokens > 0 else { continue }
            let echoed = realIndices.filter { flags[$0] }.count

            // Short sentences (1–2 words) go if they are echo, or if they are isolated and land on
            // top of someone else's speech. That is almost always sound leaking from the headphones
            // or speakers into the microphone, recognized as a stray word. A "yes" said after a
            // question, while nobody else is talking, stays.
            if totalTokens <= 2 {
                if echoed == totalTokens { continue }
                if let first = sentence.first, let last = sentence.last,
                   isIsolated(start: first.start, end: last.end),
                   overlapsSystemSpeech(start: first.start, end: last.end) { continue }
                result.append(sentence)
                continue
            }
            // A sentence mostly repeated from the system track is echo.
            if Double(echoed) / Double(totalTokens) >= echoSentenceRatio { continue }

            // Remove only repeated runs (you talking over an echo).
            var remove = [Bool](repeating: false, count: sentence.count)
            var position = 0
            while position < realIndices.count {
                guard flags[realIndices[position]] else { position += 1; continue }
                var end = position
                while end < realIndices.count, flags[realIndices[end]] { end += 1 }
                if end - position >= echoMinRun {
                    for k in realIndices[position]...realIndices[end - 1] { remove[k] = true }
                }
                position = end
            }
            let kept = sentence.indices.filter { !remove[$0] }.map { sentence[$0] }
            let keptTokens = kept.filter { !normalize($0.text).isEmpty }.count
            if keptTokens >= 2 { result.append(kept) }
        }
        return result
    }
}
