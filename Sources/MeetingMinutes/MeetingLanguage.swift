import Foundation
import Speech

/// Fixed text that appears in the minutes file, in the language of the meeting.
struct MinutesStrings {
    let title: String
    let summary: String
    let topics: String
    let decisions: String
    let nextSteps: String
    let owner: String
    let transcript: String
    let you: String
    let meeting: String
    let noTopics: String
    let noDecisions: String
    let noActionItems: String
    let notGenerated: String
    let toBeDefined: String
    /// `%@` is replaced by the reason.
    let failure: String
    let emptyTranscript: String
    let warning: String
}

/// The language spoken in the meetings. It drives three things:
/// the speech recognizer, the language the AI writes the minutes in,
/// and the headings of the minutes file.
enum MeetingLanguage {
    /// Locales the on-device speech recognizer supports (filled at launch).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var supportedCache: [Locale] = []

    static var locale: Locale {
        if let id = Settings.shared.meetingLanguage { return Locale(identifier: id) }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en_US")
    }

    /// English name of the language, e.g. "Portuguese (Brazil)".
    static func displayName(_ locale: Locale) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    static var displayName: String { displayName(locale) }

    /// Picks the Mac's language the first time, if the recognizer supports it (otherwise English).
    static func resolveDefaultIfNeeded() async {
        let supported = await SpeechTranscriber.supportedLocales
        lock.withLock { supportedCache = supported.sorted { displayName($0) < displayName($1) } }
        guard Settings.shared.meetingLanguage == nil else { return }
        let preferred = Locale(identifier: Locale.preferredLanguages.first ?? "en_US")
        let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred)
        Settings.shared.meetingLanguage = (match ?? Locale(identifier: "en_US")).identifier
        Log.info("Meeting language set to \(displayName).")
    }

    static var supported: [Locale] {
        lock.lock()
        defer { lock.unlock() }
        return supportedCache
    }

    static var strings: MinutesStrings { strings(for: locale) }

    static func strings(for locale: Locale) -> MinutesStrings {
        let code = locale.language.languageCode?.identifier ?? "en"
        return tables[code] ?? english
    }

    /// Finds which language a minutes file was written in, from its "Full Transcript" heading.
    /// Returns the heading's range in the text, the strings and the locale to use.
    static func detect(in text: String) -> (heading: Range<String.Index>, strings: MinutesStrings, locale: Locale)? {
        let currentCode = locale.language.languageCode?.identifier ?? "en"
        // Try the current meeting language first, then the others.
        let ordered = tables.sorted { a, b in a.key == currentCode ? true : (b.key == currentCode ? false : a.key < b.key) }
        for (code, strings) in ordered {
            if let range = text.range(of: "## \(strings.transcript)") {
                return (range, strings, code == currentCode ? locale : Locale(identifier: code))
            }
        }
        return nil
    }

    // MARK: - Tables (languages without a table use English headings)

    /// The "[You]" label in every built-in language (to tell your lines apart when reading).
    static var youLabels: Set<String> { Set([english.you] + tables.values.map(\.you)) }

    static let english = MinutesStrings(
        title: "Meeting Minutes", summary: "Executive Summary", topics: "Key Topics Discussed",
        decisions: "Decisions Made", nextSteps: "Next Steps / Action Items", owner: "Owner",
        transcript: "Full Transcript", you: "You", meeting: "Meeting",
        noTopics: "No topics identified.", noDecisions: "No decisions recorded.", noActionItems: "No action items agreed.",
        notGenerated: "(not generated)", toBeDefined: "TBD",
        failure: "The minutes were not generated (%@). The full transcript is below.",
        emptyTranscript: "No speech was recognized in the recording.", warning: "Warning"
    )

    private static let tables: [String: MinutesStrings] = [
        "en": english,
        "pt": MinutesStrings(
            title: "Ata da Reunião", summary: "Resumo Executivo", topics: "Principais Tópicos Discutidos",
            decisions: "Decisões Tomadas", nextSteps: "Próximos Passos / Tarefas", owner: "Responsável",
            transcript: "Transcrição Completa", you: "Você", meeting: "Reunião",
            noTopics: "Nenhum tópico identificado.", noDecisions: "Nenhuma decisão registrada.", noActionItems: "Nenhuma tarefa combinada.",
            notGenerated: "(não gerado)", toBeDefined: "A definir",
            failure: "A ata não foi gerada (%@). A transcrição completa está abaixo.",
            emptyTranscript: "Nenhuma fala foi reconhecida na gravação.", warning: "Aviso"
        ),
        "es": MinutesStrings(
            title: "Acta de la Reunión", summary: "Resumen Ejecutivo", topics: "Principales Temas Tratados",
            decisions: "Decisiones Tomadas", nextSteps: "Próximos Pasos / Tareas", owner: "Responsable",
            transcript: "Transcripción Completa", you: "Tú", meeting: "Reunión",
            noTopics: "No se identificaron temas.", noDecisions: "No se registraron decisiones.", noActionItems: "No se acordaron tareas.",
            notGenerated: "(no generado)", toBeDefined: "Por definir",
            failure: "El acta no se generó (%@). La transcripción completa está abajo.",
            emptyTranscript: "No se reconoció ninguna voz en la grabación.", warning: "Aviso"
        ),
        "fr": MinutesStrings(
            title: "Compte rendu de réunion", summary: "Résumé", topics: "Principaux sujets abordés",
            decisions: "Décisions prises", nextSteps: "Prochaines étapes / Actions", owner: "Responsable",
            transcript: "Transcription complète", you: "Vous", meeting: "Réunion",
            noTopics: "Aucun sujet identifié.", noDecisions: "Aucune décision enregistrée.", noActionItems: "Aucune action convenue.",
            notGenerated: "(non généré)", toBeDefined: "À définir",
            failure: "Le compte rendu n'a pas été généré (%@). La transcription complète figure ci-dessous.",
            emptyTranscript: "Aucune parole n'a été reconnue dans l'enregistrement.", warning: "Avertissement"
        ),
        "de": MinutesStrings(
            title: "Besprechungsprotokoll", summary: "Zusammenfassung", topics: "Wichtigste Themen",
            decisions: "Getroffene Entscheidungen", nextSteps: "Nächste Schritte / Aufgaben", owner: "Verantwortlich",
            transcript: "Vollständiges Transkript", you: "Sie", meeting: "Besprechung",
            noTopics: "Keine Themen erkannt.", noDecisions: "Keine Entscheidungen festgehalten.", noActionItems: "Keine Aufgaben vereinbart.",
            notGenerated: "(nicht erstellt)", toBeDefined: "Offen",
            failure: "Das Protokoll wurde nicht erstellt (%@). Das vollständige Transkript steht unten.",
            emptyTranscript: "In der Aufnahme wurde keine Sprache erkannt.", warning: "Hinweis"
        ),
        "it": MinutesStrings(
            title: "Verbale della riunione", summary: "Sintesi", topics: "Principali argomenti discussi",
            decisions: "Decisioni prese", nextSteps: "Prossimi passi / Attività", owner: "Responsabile",
            transcript: "Trascrizione completa", you: "Tu", meeting: "Riunione",
            noTopics: "Nessun argomento individuato.", noDecisions: "Nessuna decisione registrata.", noActionItems: "Nessuna attività concordata.",
            notGenerated: "(non generato)", toBeDefined: "Da definire",
            failure: "Il verbale non è stato generato (%@). La trascrizione completa è qui sotto.",
            emptyTranscript: "Nessun parlato riconosciuto nella registrazione.", warning: "Avviso"
        ),
    ]
}
