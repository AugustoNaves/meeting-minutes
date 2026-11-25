import Foundation

/// Names and terms to spell exactly right, plus phrases the speech recognizer consistently gets
/// wrong. Kept as a plain Markdown file next to the minutes (Glossary.md), so it can be read and
/// edited by hand; the AI adds to it on its own (see GlossaryLearner).
///
/// It is used in three places:
/// - every dictation and meeting transcript: the corrections are applied right away, on the Mac;
/// - the AI clean-up of a dictation and the AI that writes the minutes: the terms go in their
///   instructions, so they spell them right even when the recognizer did not;
/// - the next learning round, so the AI only adds what is new.
struct Glossary: Equatable {
    struct Correction: Equatable {
        var heard: String
        var correct: String
    }

    var terms: [String] = []
    var corrections: [Correction] = []

    static let maxTerms = 400
    static let maxCorrections = 400

    static var fileURL: URL { Paths.minutesFolder.appendingPathComponent("Glossary.md") }

    var isEmpty: Bool { terms.isEmpty && corrections.isEmpty }

    // MARK: - Reading and writing the file

    static func load() -> Glossary {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Glossary() }
        return parse(text)
    }

    /// Reads the "Terms" and "Corrections" sections ("Termos" / "Correções" also work).
    /// Each item is a "- " line; a correction is "- heard → correct" (or "->").
    static func parse(_ text: String) -> Glossary {
        enum Section { case other, terms, corrections }
        var glossary = Glossary()
        var section = Section.other
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let heading = key(line)
                if heading.contains("correc") {
                    section = .corrections
                } else if heading.contains("term") {
                    section = .terms
                } else {
                    section = .other
                }
                continue
            }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let item = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            switch section {
            case .terms:
                glossary.addTerm(item)
            case .corrections:
                if let arrow = item.range(of: "→") ?? item.range(of: "->") {
                    glossary.addCorrection(heard: String(item[..<arrow.lowerBound]), correct: String(item[arrow.upperBound...]))
                }
            case .other:
                break
            }
        }
        return glossary
    }

    func render() -> String {
        var md = """
        # Glossary

        Names and terms that dictation and meeting minutes must spell exactly like this. Edit freely, one item per line: Meeting Minutes reads this file every time, and adds new items by itself while “Learn Glossary Automatically” is on.

        ## Terms

        """
        md += terms.isEmpty ? "_(none yet)_\n" : terms.map { "- \($0)\n" }.joined()
        md += """

        ## Corrections

        What the speech recognizer hears → what it must become. Applied to every dictation and transcript, on your Mac.

        """
        md += corrections.isEmpty ? "_(none yet)_\n" : corrections.map { "- \($0.heard) → \($0.correct)\n" }.joined()
        return md
    }

    func save() throws {
        try Paths.ensure(Paths.minutesFolder)
        try render().write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Editing

    /// Comparison key: ignores case, accents and surrounding spaces.
    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    mutating func addTerm(_ raw: String) -> Bool {
        let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2, term.count <= 60, terms.count < Self.maxTerms,
              !terms.contains(where: { Self.key($0) == Self.key(term) })
        else { return false }
        terms.append(term)
        return true
    }

    @discardableResult
    mutating func addCorrection(heard rawHeard: String, correct rawCorrect: String) -> Bool {
        let heard = rawHeard.trimmingCharacters(in: .whitespacesAndNewlines)
        let correct = rawCorrect.trimmingCharacters(in: .whitespacesAndNewlines)
        guard heard.count >= 3, heard.count <= 80, !correct.isEmpty, correct.count <= 80,
              Self.key(heard) != Self.key(correct), corrections.count < Self.maxCorrections,
              !corrections.contains(where: { Self.key($0.heard) == Self.key(heard) })
        else { return false }
        corrections.append(Correction(heard: heard, correct: correct))
        return true
    }

    // MARK: - Applying

    /// Applies the corrections (whole words only, ignoring case and accents), then restores the
    /// exact spelling of terms written in an unusual way ("github" → "GitHub", "nasa" → "NASA").
    /// Ordinary capitalized words ("Meta", "Joana") are left alone: they may be common words too.
    func apply(to text: String) -> String {
        var result = text
        for correction in corrections.sorted(by: { $0.heard.count > $1.heard.count }) {
            result = Self.replaceWholeWords(in: result, phrase: correction.heard, with: correction.correct)
        }
        for term in terms where Self.hasDistinctSpelling(term) {
            result = Self.replaceWholeWords(in: result, phrase: term, with: term)
        }
        return result
    }

    /// True for "GitHub", "NASA", "TypeScript", "K8s", "iPhone"; false for "Joana" or "Grants".
    static func hasDistinctSpelling(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        guard letters.count >= 2 else { return false }
        if term.contains(where: { !$0.isLetter && !$0.isWhitespace }) { return true }
        if letters.dropFirst().contains(where: \.isUppercase) { return true }
        return letters.first?.isLowercase == true && letters.contains(where: \.isUppercase)
    }

    static func replaceWholeWords(in text: String, phrase: String, with replacement: String) -> String {
        guard !phrase.isEmpty else { return text }
        var result = text
        var searchOffset = 0
        while searchOffset < result.count {
            let searchStart = result.index(result.startIndex, offsetBy: searchOffset)
            guard let range = result.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<result.endIndex) else { break }
            let startsWord = range.lowerBound == result.startIndex || !isWordCharacter(result[result.index(before: range.lowerBound)])
            let endsWord = range.upperBound == result.endIndex || !isWordCharacter(result[range.upperBound])
            let lowerOffset = result.distance(from: result.startIndex, to: range.lowerBound)
            if startsWord && endsWord {
                result.replaceSubrange(range, with: replacement)
                searchOffset = lowerOffset + replacement.count
            } else {
                searchOffset = lowerOffset + 1
            }
        }
        return result
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

// MARK: - Learning with the AI

/// Builds the glossary from what the person actually says: recent dictations (what the
/// recognizer heard next to the AI-corrected text) and recent minutes (where the AI spelled
/// names from context). Only additions are made; the person's own edits are never removed.
enum GlossaryLearner {
    struct Outcome {
        let addedTerms: [String]
        let addedCorrections: [Glossary.Correction]
        var summary: String {
            "\(addedTerms.count) term(s) and \(addedCorrections.count) correction(s) added"
        }
    }

    enum LearnError: LocalizedError {
        case nothingToLearn
        var errorDescription: String? { "there are no new dictations or minutes to learn from yet" }
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "terms": ["type": "array", "items": ["type": "string"]],
            "corrections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "heard": ["type": "string"],
                        "correct": ["type": "string"],
                    ],
                    "required": ["heard", "correct"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["terms", "corrections"],
        "additionalProperties": false,
    ]

    static func systemPrompt(language: String) -> String {
        """
        You maintain the glossary of a person who dictates text and records meetings, mostly in \(language), using an automatic speech recognizer.
        The recognizer misspells names of people, companies, products, projects, acronyms and jargon. The glossary fixes that.

        You receive the current glossary and recent material:
        - dictations: what the recognizer heard ("heard") next to the text after an AI corrected it ("final");
        - meeting files: AI-written minutes (names spelled from context) followed by the raw transcript.

        Return only what is NEW:
        - terms: names, organizations, products, acronyms and jargon this person really uses, spelled exactly as they must be written. Take the spelling from the corrected text or the minutes. Never common words of the language.
        - corrections: phrases the recognizer gets wrong, as heard → correct, only when the raw text clearly stands for that term (for example, heard "guit rabe" where the final text has "GitHub"). The heard side must be copied exactly from the raw text, at least two words or one unusual word, and must never be a phrase that could be correct in another sentence.

        When in doubt, leave it out: a wrong entry causes more errors than a missing one. Do not repeat anything already in the glossary. Return empty lists when nothing new is clear.
        """
    }

    /// Material since the last learning round: dictations, and minutes files changed since then.
    static func material(since: Date?) -> (dictations: [DictationRecord], meetings: [(name: String, text: String)]) {
        let history = DictationHistory.load()
        let dictations = since.map { date in history.filter { $0.date > date } } ?? Array(history.suffix(40))
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.minutesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let meetings: [(name: String, text: String, date: Date)] = files.compactMap { url in
            guard url.pathExtension == "md", url.lastPathComponent.contains("_Meeting"),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  since.map({ date > $0 }) ?? true,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return (url.lastPathComponent, String(text.prefix(15_000)), date)
        }
        let recent = meetings.sorted { $0.date > $1.date }.prefix(4).map { (name: $0.name, text: $0.text) }
        return (Array(dictations.suffix(80)), recent)
    }

    static func learn(engine: MinutesEngine, locale: Locale, since: Date?) async throws -> Outcome {
        let (dictations, meetings) = material(since: since)
        guard !dictations.isEmpty || !meetings.isEmpty else { throw LearnError.nothingToLearn }
        let current = Glossary.load()

        var text = "<glossary>\n"
        text += "terms: " + (current.terms.isEmpty ? "(none)" : current.terms.joined(separator: ", ")) + "\n"
        text += "corrections: " + (current.corrections.isEmpty ? "(none)" : current.corrections.map { "\($0.heard) → \($0.correct)" }.joined(separator: "; ")) + "\n"
        text += "</glossary>\n\n"
        if !dictations.isEmpty {
            text += "<dictations>\n"
            for record in dictations {
                text += "- heard: \(record.raw)\n  final: \(record.text)\n"
            }
            text += "</dictations>\n\n"
        }
        for meeting in meetings {
            text += "<meeting file=\"\(meeting.name)\">\n\(meeting.text)\n</meeting>\n\n"
        }

        let object = try await MinutesGenerator.requestJSON(
            MinutesGenerator.AIRequest(
                system: systemPrompt(language: MeetingLanguage.displayName(locale)),
                userText: text,
                task: "Update the glossary from the material sent on standard input.",
                schema: schema, fast: false, timeout: 300
            ),
            engine: engine
        )
        let answer = object as? [String: Any] ?? [:]
        let terms = answer["terms"] as? [String] ?? []
        let corrections = (answer["corrections"] as? [[String: Any]] ?? []).compactMap { item -> Glossary.Correction? in
            guard let heard = item["heard"] as? String, let correct = item["correct"] as? String else { return nil }
            return Glossary.Correction(heard: heard, correct: correct)
        }

        // Merge into the file as it is now (the person may have edited it meanwhile).
        var glossary = Glossary.load()
        var addedTerms: [String] = []
        var addedCorrections: [Glossary.Correction] = []
        for term in terms where glossary.addTerm(term) { addedTerms.append(term) }
        for correction in corrections where glossary.addCorrection(heard: correction.heard, correct: correction.correct) {
            addedCorrections.append(correction)
        }
        if !addedTerms.isEmpty || !addedCorrections.isEmpty || !FileManager.default.fileExists(atPath: Glossary.fileURL.path) {
            try glossary.save()
        }
        let outcome = Outcome(addedTerms: addedTerms, addedCorrections: addedCorrections)
        Log.info("Glossary updated by \(engine.label): \(outcome.summary).")
        return outcome
    }
}
