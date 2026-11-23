import Foundation

/// Structured minutes (the AI returns exactly these fields, validated by a JSON Schema).
struct Minutes: Codable {
    struct ActionItem: Codable {
        var description: String
        var owner: String
    }

    var summary: String
    var topics: [String]
    var decisions: [String]
    var actionItems: [ActionItem]

    enum CodingKeys: String, CodingKey {
        case summary, topics, decisions
        case actionItems = "action_items"
    }
}

// MARK: - Who writes the minutes, and with which model

/// Who writes the minutes. Chosen in the app menu.
enum MinutesProvider: String, CaseIterable {
    /// Claude Code installed on this Mac (uses your Claude subscription).
    case claudeCode = "claude-code"
    /// Google's Antigravity CLI (`agy`) with Gemini models (uses your Google account).
    case gemini = "gemini"
    /// Anthropic API with your own key (billed per token).
    case claudeAPI = "claude-api"

    var title: String {
        switch self {
        case .claudeCode: return "Claude Code (your Claude account)"
        case .gemini: return "Gemini via Antigravity (your Google account)"
        case .claudeAPI: return "Claude API (your own key)"
        }
    }

    var shortTitle: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .gemini: return "Gemini (Antigravity)"
        case .claudeAPI: return "Claude API"
        }
    }

    /// Order used when the chosen provider is not available.
    static let fallbackOrder: [MinutesProvider] = [.claudeAPI, .claudeCode, .gemini]
}

/// Claude models (used by both Claude Code and the API).
enum MinutesModel: String, CaseIterable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var title: String {
        switch self {
        case .opus: return "Opus 5.5 — best quality"
        case .sonnet: return "Sonnet 5.5 — balanced"
        case .haiku: return "Haiku 5.5 — most economical"
        }
    }

    var shortName: String {
        switch self {
        case .opus: return "Opus 5.5"
        case .sonnet: return "Sonnet 5.5"
        case .haiku: return "Haiku 5.5"
        }
    }

    static var current: MinutesModel { MinutesModel(rawValue: Settings.shared.minutesModel) ?? .opus }
}

/// Gemini models offered by Antigravity. The list comes from `agy models` itself
/// (names change over time) and is cached to build the menu.
enum GeminiModels {
    struct Model {
        let id: String
        let label: String
    }

    static var cached: [Model] {
        Settings.shared.geminiModels.compactMap { pair in
            pair.count == 2 ? Model(id: pair[0], label: pair[1]) : nil
        }
    }

    /// nil = Antigravity's default model.
    static var selectedID: String? { Settings.shared.geminiModel }

    static var selectedLabel: String {
        guard let id = selectedID else { return "Antigravity default" }
        return cached.first { $0.id == id }?.label ?? id
    }

    /// Refreshes the list by running `agy models` (needs internet; takes a few seconds).
    static func refresh() async {
        guard let agy = MinutesGenerator.findAntigravityCLI() else { return }
        do {
            let result = try await MinutesGenerator.runProcess(
                executable: agy, arguments: ["models"], stdin: nil,
                workDirectory: try MinutesGenerator.workDirectory("agy-cwd"), timeout: 30, toolName: "Gemini (Antigravity)"
            )
            let text = String(data: result.stdout, encoding: .utf8) ?? ""
            let models: [[String]] = text.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, parts[0].hasPrefix("gemini") else { return nil }
                return [parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: .whitespaces)]
            }
            if !models.isEmpty {
                Settings.shared.geminiModels = models
                Log.info("Gemini model list refreshed (\(models.count) models).")
            }
        } catch {
            Log.error("Could not list Gemini models: \(error.localizedDescription)")
        }
    }
}

enum MinutesEngine {
    case claudeAPI(key: String)
    case claudeCode(executable: URL)
    case gemini(executable: URL)
    case none

    var provider: MinutesProvider? {
        switch self {
        case .claudeAPI: return .claudeAPI
        case .claudeCode: return .claudeCode
        case .gemini: return .gemini
        case .none: return nil
        }
    }

    var label: String {
        switch self {
        case .claudeAPI: return "Claude API (your key) · \(MinutesModel.current.shortName)"
        case .claudeCode: return "Claude Code (your account) · \(MinutesModel.current.shortName)"
        case .gemini: return "Gemini (your Google account) · \(GeminiModels.selectedLabel)"
        case .none: return "none — transcript only"
        }
    }
}

enum MinutesError: LocalizedError {
    case api(String)
    case tool(String, String)
    case noEngine
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .api(message): return "Claude API: \(message)"
        case let .tool(name, message): return "\(name): \(message)"
        case .noEngine: return "no minutes writer available: install Claude Code or Antigravity, or set a Claude API key in the menu"
        case let .invalidResponse(message): return "Unexpected AI response: \(message)"
        }
    }
}

enum MinutesGenerator {
    /// Instructions for the AI. The minutes are written in the meeting language.
    static func systemPrompt(language: String, strings: MinutesStrings) -> String {
        """
        You write concise, objective meeting minutes from an automatic transcript.

        About the transcript:
        - Each line has a timestamp and a speaker label. [\(strings.you)] is the person who recorded the meeting. [\(strings.meeting)] groups everyone else on the call (it may be several people; use their names when they come up in the conversation).
        - The transcript is automatic and may contain misrecognized words. Interpret them from context, without inventing facts.

        What to produce:
        - summary: 2 to 5 sentences with the purpose of the meeting and the conclusion it reached.
        - topics: the main subjects discussed, one per item, as short sentences.
        - decisions: only what was actually decided or agreed. Empty list if nothing was decided.
        - action_items: the actions agreed for after the meeting. In description, include the deadline when one was mentioned. In owner, use the person's name when it appears in the conversation, "\(strings.you)" when the person who recorded took the task, or "\(strings.toBeDefined)" when nobody was assigned. Empty list if there were no action items.

        Use only what is in the transcript. Write every text field in \(language), without Markdown formatting.
        """
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "topics": ["type": "array", "items": ["type": "string"]],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "description": ["type": "string"],
                        "owner": ["type": "string"],
                    ],
                    "required": ["description", "owner"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["summary", "topics", "decisions", "action_items"],
        "additionalProperties": false,
    ]

    // MARK: - Which engine to use

    static func engine(for provider: MinutesProvider) -> MinutesEngine? {
        switch provider {
        case .claudeAPI: return Keychain.readAPIKey().map { .claudeAPI(key: $0) }
        case .claudeCode: return findClaudeCLI().map { .claudeCode(executable: $0) }
        case .gemini: return findAntigravityCLI().map { .gemini(executable: $0) }
        }
    }

    /// The one chosen in the menu; if it is not available: API key → Claude Code → Gemini.
    static func currentEngine() -> MinutesEngine {
        if let raw = Settings.shared.minutesProvider,
           let preferred = MinutesProvider(rawValue: raw),
           let engine = engine(for: preferred) {
            return engine
        }
        for provider in MinutesProvider.fallbackOrder {
            if let engine = engine(for: provider) { return engine }
        }
        return .none
    }

    // MARK: - Finding the command-line tools

    private static let lookupLock = NSLock()
    nonisolated(unsafe) private static var lookupCache: [String: URL] = [:]

    static func findClaudeCLI() -> URL? {
        let home = Paths.home.path
        return findExecutable("claude", candidates: [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ])
    }

    static func findAntigravityCLI() -> URL? {
        let home = Paths.home.path
        return findExecutable("agy", candidates: [
            "\(home)/.local/bin/agy",
            "\(home)/.gemini/antigravity-cli/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ])
    }

    private static func findExecutable(_ name: String, candidates: [String]) -> URL? {
        lookupLock.lock()
        defer { lookupLock.unlock() }
        let fm = FileManager.default
        if let cached = lookupCache[name], fm.isExecutableFile(atPath: cached.path) { return cached }
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            lookupCache[name] = URL(fileURLWithPath: found)
            return lookupCache[name]
        }
        // Last resort: ask the user's login shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if output.hasPrefix("/"), fm.isExecutableFile(atPath: output) {
                lookupCache[name] = URL(fileURLWithPath: output)
                return lookupCache[name]
            }
        } catch {}
        return nil
    }

    // MARK: - Generate

    /// - Parameters:
    ///   - context: one line with the date (and duration, when known) of the meeting.
    ///   - locale: the meeting language; the minutes are written in it.
    static func generate(transcript: String, context: String, locale: Locale, engine: MinutesEngine) async throws -> Minutes {
        let strings = MeetingLanguage.strings(for: locale)
        let prompt = systemPrompt(language: MeetingLanguage.displayName(locale), strings: strings)
        let userText = """
        \(context)

        <transcript>
        \(transcript)
        </transcript>
        """
        switch engine {
        case let .claudeAPI(key):
            return try await generateWithAPI(system: prompt, userText: userText, apiKey: key)
        case let .claudeCode(executable):
            return try await generateWithClaudeCode(system: prompt, userText: userText, executable: executable)
        case let .gemini(executable):
            return try await generateWithGemini(system: prompt, userText: userText, executable: executable)
        case .none:
            throw MinutesError.noEngine
        }
    }

    // MARK: Anthropic API (plain HTTP: there is no official Swift SDK)

    private static func generateWithAPI(system: String, userText: String, apiKey: String) async throws -> Minutes {
        let model = MinutesModel.current
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16_000,
            "system": system,
            "messages": [["role": "user", "content": userText]],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": schema],
            ],
        ]
        // If the model refuses by mistake, the API itself retries on another model (not available for Haiku).
        let useFallbacks = model != .haiku
        if useFallbacks { body["fallbacks"] = "default" }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        if useFallbacks { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = MinutesError.api("no response")
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt * attempt) * 3)) }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                lastError = MinutesError.api("connection failed (\(error.localizedDescription))")
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            guard (200..<300).contains(status) else {
                let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
                lastError = MinutesError.api(message)
                // 429 (rate limit), 5xx and 529 (overloaded) are worth retrying; anything else is not.
                if status == 429 || status >= 500 { continue }
                throw lastError
            }
            guard let json else { throw MinutesError.invalidResponse("unreadable JSON") }
            let stopReason = json["stop_reason"] as? String
            if stopReason == "refusal" {
                throw MinutesError.api("the model declined to write these minutes")
            }
            if stopReason == "max_tokens" {
                throw MinutesError.api("the response was cut off for length")
            }
            let content = json["content"] as? [[String: Any]] ?? []
            guard let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
                throw MinutesError.invalidResponse("no text block")
            }
            return try decodeMinutes(from: text)
        }
        throw lastError
    }

    // MARK: Claude Code (claude -p)

    private static func generateWithClaudeCode(system: String, userText: String, executable: URL) async throws -> Minutes {
        let tool = "Claude Code"
        var environment = baseEnvironment()
        // Single call: caching would only add cost (writing to the cache costs twice the input price).
        environment["DISABLE_PROMPT_CACHING"] = "1"
        let result = try await runProcess(
            executable: executable,
            arguments: [
                "-p", "Write the meeting minutes from the transcript sent on standard input.",
                "--output-format", "json",
                "--json-schema", try schemaString(),
                "--system-prompt", system,
                "--model", MinutesModel.current.rawValue,
                "--effort", "medium",
                "--tools", "",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--disable-slash-commands",
            ],
            stdin: Data(userText.utf8),
            workDirectory: try workDirectory("claude-cwd"),
            environment: environment,
            timeout: 600,
            toolName: tool
        )
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            throw MinutesError.tool(tool, "invalid output (exit code \(result.exitCode)). \(result.stderrSummary)")
        }
        if (json["is_error"] as? Bool) == true {
            let message = (json["result"] as? String) ?? "unknown error"
            if message.localizedCaseInsensitiveContains("login") || message.localizedCaseInsensitiveContains("logged in") {
                throw MinutesError.tool(tool, "not logged in. Open Terminal, run “claude” and log in once.")
            }
            throw MinutesError.tool(tool, message)
        }
        if let structured = json["structured_output"], !(structured is NSNull) {
            return try decodeMinutes(fromJSONObject: structured)
        }
        if let text = json["result"] as? String {
            return try decodeMinutes(from: text)
        }
        throw MinutesError.invalidResponse("Claude Code did not return the minutes")
    }

    // MARK: Gemini via Antigravity (agy -p)

    private static func generateWithGemini(system: String, userText: String, executable: URL) async throws -> Minutes {
        let tool = "Gemini (Antigravity)"
        // agy does not read standard input in -p mode, so the transcript goes inside the prompt.
        let prompt = """
        \(system)

        Do not use tools or open files: reply only with the minutes, based on the transcript below.

        \(userText)
        """
        guard prompt.utf8.count < 800_000 else {
            throw MinutesError.tool(tool, "the transcript is too long for Antigravity; switch to Claude in the menu and regenerate")
        }
        var arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", try schemaString(),
            "--print-timeout", "600s",
            "--disable-slash-commands",
        ]
        if let model = GeminiModels.selectedID { arguments += ["--model", model] }

        let result = try await runProcess(
            executable: executable,
            arguments: arguments,
            stdin: nil,
            workDirectory: try workDirectory("agy-cwd"),
            environment: baseEnvironment(),
            timeout: 660,
            toolName: tool
        )
        guard let json = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] else {
            let output = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = output.isEmpty ? result.stderrSummary : String(output.prefix(300))
            if detail.localizedCaseInsensitiveContains("login") || detail.localizedCaseInsensitiveContains("sign in") || detail.localizedCaseInsensitiveContains("auth") {
                throw MinutesError.tool(tool, "not logged in. Open Terminal, run “agy” and sign in with your Google account once.")
            }
            throw MinutesError.tool(tool, "invalid output (exit code \(result.exitCode)). \(detail)")
        }
        let status = (json["status"] as? String) ?? ""
        guard status.uppercased() == "SUCCESS" else {
            let candidates = [json["error"] as? String, json["response"] as? String, result.stderrSummary]
            let full = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
                ?? "status \(status.isEmpty ? "unknown" : status)"
            if full.contains("invalid model selection") || full.contains("not recognized as a known model") {
                throw MinutesError.tool(tool, "the chosen model no longer exists in Antigravity. In the menu, under “Minutes Model”, use “Refresh Model List” and pick another one.")
            }
            if full.localizedCaseInsensitiveContains("login") || full.localizedCaseInsensitiveContains("sign in") || full.localizedCaseInsensitiveContains("unauthenticated") {
                throw MinutesError.tool(tool, "not logged in. Open Terminal, run “agy” and sign in with your Google account once.")
            }
            let firstLine = full.components(separatedBy: "\n").first ?? full
            throw MinutesError.tool(tool, String(firstLine.prefix(300)))
        }
        if let structured = json["structured_output"], !(structured is NSNull) {
            return try decodeMinutes(fromJSONObject: structured)
        }
        if let text = json["response"] as? String {
            return try decodeMinutes(from: text)
        }
        throw MinutesError.invalidResponse("Antigravity did not return the minutes")
    }

    // MARK: - Processes

    struct ProcessResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32

        var stderrSummary: String {
            let text = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return String(text.suffix(300))
        }
    }

    static func workDirectory(_ name: String) throws -> URL {
        let dir = Paths.appSupport.appendingPathComponent(name, isDirectory: true)
        try Paths.ensure(dir)
        return dir
    }

    private static func schemaString() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: schema)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func baseEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if environment["CLAUDECODE"] != nil {
            // Running from inside another Claude Code session (testing): behave like the normal app.
            for key in environment.keys where key.hasPrefix("CLAUDE") || key == "ANTHROPIC_BASE_URL" {
                environment.removeValue(forKey: key)
            }
        }
        let home = Paths.home.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    /// Runs a program, reading its output without blocking, with a time limit.
    static func runProcess(
        executable: URL, arguments: [String], stdin: Data?, workDirectory: URL,
        environment: [String: String]? = nil, timeout: TimeInterval, toolName: String
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        process.environment = environment ?? baseEnvironment()
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MinutesError.tool(toolName, "could not start (\(error.localizedDescription))"))
                    return
                }
                let group = DispatchGroup()
                var out = Data(), err = Data()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    out = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    err = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                if let stdin {
                    DispatchQueue.global(qos: .utility).async {
                        inputPipe.fileHandleForWriting.write(stdin)
                        try? inputPipe.fileHandleForWriting.close()
                    }
                }
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                group.wait()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: ProcessResult(stdout: out, stderr: err, exitCode: process.terminationStatus))
            }
        }
    }

    // MARK: - Reading the minutes

    static func decodeMinutes(fromJSONObject object: Any) throws -> Minutes {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(Minutes.self, from: data)
        } catch {
            throw MinutesError.invalidResponse("the minutes JSON was not in the expected format")
        }
    }

    static func decodeMinutes(from text: String) throws -> Minutes {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = cleaned.range(of: "```", options: .backwards) { cleaned = String(cleaned[..<fence.lowerBound]) }
        }
        if let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[first...last])
        }
        do {
            return try JSONDecoder().decode(Minutes.self, from: Data(cleaned.utf8))
        } catch {
            throw MinutesError.invalidResponse("the minutes JSON was not in the expected format")
        }
    }
}
