import AppKit
import Foundation

/// AI services that speak the OpenAI chat API. One client covers all of them:
/// OpenAI itself, Gemini with a Google AI Studio key (Google offers an OpenAI-compatible
/// address), Ollama on this Mac, and any other compatible service the person points to
/// (OpenRouter, Groq, LM Studio…).
enum CompatibleService: String, CaseIterable {
    case openAI = "openai"
    case geminiKey = "gemini-key"
    case ollama = "ollama"
    case custom = "custom"

    /// Everything needed to send a request.
    struct Connection {
        let service: CompatibleService
        let baseURL: URL
        let key: String?
        let model: String
    }

    var title: String {
        switch self {
        case .openAI: return "OpenAI / ChatGPT (your own key)"
        case .geminiKey: return "Gemini (Google AI Studio key)"
        case .ollama: return "Ollama (on this Mac, free, offline)"
        case .custom: return "Other compatible service (OpenRouter, Groq, LM Studio…)"
        }
    }

    var shortTitle: String {
        switch self {
        case .openAI: return "OpenAI"
        case .geminiKey: return "Gemini (key)"
        case .ollama: return "Ollama"
        case .custom: return "Compatible service"
        }
    }

    /// One line for the setup screen: what it costs and where the text goes.
    var summary: String {
        switch self {
        case .openAI: return "your OpenAI API key, billed per use; the text goes to OpenAI"
        case .geminiKey: return "a Google AI Studio key, with a free tier; the text goes to Google"
        case .ollama: return "models that run on this Mac: free, offline, nothing leaves the Mac (slower)"
        case .custom: return "any service with an OpenAI-compatible API: you paste its address and key"
        }
    }

    /// Where to get a key (shown in the setup dialog).
    var keyHelp: String? {
        switch self {
        case .openAI: return "Create one at platform.openai.com › API keys."
        case .geminiKey: return "Create one at aistudio.google.com › Get API key (free tier available)."
        case .custom: return "Leave it empty if the service needs no key (LM Studio, for example)."
        case .ollama: return nil
        }
    }

    var needsKey: Bool { self == .openAI || self == .geminiKey }

    private var defaultBaseURL: String? {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .geminiKey: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return nil
        }
    }

    // MARK: Saved settings (key in the Keychain, the rest in the app settings)

    private var keychainAccount: String { "key-\(rawValue)" }
    private var defaultsPrefix: String { "ai.\(rawValue)." }

    var baseURL: String? {
        get {
            if self == .custom { return UserDefaults.standard.string(forKey: defaultsPrefix + "baseURL") }
            return defaultBaseURL
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsPrefix + "baseURL") }
    }

    var key: String? { Keychain.read(account: keychainAccount) }

    @discardableResult
    func saveKey(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else {
            Keychain.delete(account: keychainAccount)
            return true
        }
        return Keychain.save(key, account: keychainAccount, label: "Prosa – \(shortTitle) key")
    }

    var model: String? {
        get { UserDefaults.standard.string(forKey: defaultsPrefix + "model") }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsPrefix + "model") }
    }

    /// Models seen the last time the list was fetched (for the menu).
    var cachedModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: defaultsPrefix + "models") ?? [] }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsPrefix + "models") }
    }

    /// Ready to use: address, key (if needed) and a model.
    var connection: Connection? {
        guard let base = baseURL.flatMap(URL.init(string:)), let model, !model.isEmpty else { return nil }
        let key = self.key
        if needsKey && key == nil { return nil }
        return Connection(service: self, baseURL: base, key: key, model: model)
    }

    /// The model to suggest first: a quick, inexpensive one, which is plenty for minutes.
    func suggestedModel(from models: [String]) -> String? {
        let preferences: [String]
        switch self {
        case .openAI: preferences = ["gpt-5-mini", "mini", "gpt-5", "gpt-4.1"]
        case .geminiKey: preferences = ["flash", "pro"]
        case .ollama, .custom: preferences = []
        }
        for preference in preferences {
            if let match = models.first(where: { $0.contains(preference) && !$0.contains("embed") && !$0.contains("audio") && !$0.contains("image") }) {
                return match
            }
        }
        return models.first { !$0.contains("embed") }
    }

    // MARK: - Talking to the service

    enum ServiceError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(text) = self { return text }
            return nil
        }
    }

    /// Lists the models the service offers (GET /models).
    static func listModels(baseURL: URL, key: String?, service: CompatibleService) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 20
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await send(request, service: service)
        try check(response, data: data, service: service)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ids = (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
        return Array(Set(ids)).sorted()
    }

    /// Sends one request and returns the text of the answer. With a schema it first asks for
    /// strict JSON; services that do not support that get a plain JSON request instead.
    static func complete(_ request: MinutesGenerator.AIRequest, connection: Connection) async throws -> String {
        var modes: [String?] = request.schema == nil ? [nil] : ["json_schema", "json_object", nil]
        var lastError: Error = ServiceError.message("\(connection.service.shortTitle): no answer")
        while !modes.isEmpty {
            let mode = modes.removeFirst()
            var system = request.system
            if let schema = request.schema, mode != "json_schema" {
                let schemaText = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                system += "\n\nReply only with one JSON object that follows this JSON Schema, with no other text:\n\(schemaText)"
            }
            var body: [String: Any] = [
                "model": connection.model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": request.task + "\n\n" + request.userText],
                ],
            ]
            if mode == "json_schema", let schema = request.schema {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "answer", "strict": true, "schema": schema]]
            } else if mode == "json_object" {
                body["response_format"] = ["type": "json_object"]
            }
            var urlRequest = URLRequest(url: connection.baseURL.appendingPathComponent("chat/completions"))
            urlRequest.httpMethod = "POST"
            // Models on the Mac (Ollama) are slower: give them more time.
            urlRequest.timeoutInterval = connection.service == .ollama ? max(request.timeout, 900) : request.timeout
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key = connection.key { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await send(urlRequest, service: connection.service)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 400 || status == 422, mode != nil, !modes.isEmpty {
                // The service did not accept this response format: try the next, simpler one.
                lastError = ServiceError.message(errorMessage(data) ?? "HTTP \(status)")
                continue
            }
            try check(response, data: data, service: connection.service, model: connection.model)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty {
                throw ServiceError.message("\(connection.service.shortTitle): the model declined (\(refusal))")
            }
            guard let content = message?["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.message("\(connection.service.shortTitle): the answer was empty")
            }
            return content
        }
        throw lastError
    }

    private static func send(_ request: URLRequest, service: CompatibleService) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where service == .ollama && [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(error.code) {
            throw ServiceError.message("Ollama is not running. Open the Ollama app on this Mac and try again.")
        } catch {
            throw ServiceError.message("\(service.shortTitle): could not connect (\(error.localizedDescription))")
        }
    }

    private static func check(_ response: URLResponse, data: Data, service: CompatibleService, model: String? = nil) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        let detail = errorMessage(data) ?? "HTTP \(status)"
        switch status {
        case 401, 403:
            throw ServiceError.message("\(service.shortTitle) rejected the key (\(detail)). Set it again in the menu, under “Minutes Written By”.")
        case 404:
            throw ServiceError.message("\(service.shortTitle) does not know the model \(model ?? "") (\(detail)). Pick another one in the menu, under “Minutes Model”.")
        case 429:
            throw ServiceError.message("\(service.shortTitle) says the usage limit was reached (\(detail)). Try again later or pick another AI.")
        default:
            throw ServiceError.message("\(service.shortTitle): \(detail)")
        }
    }

    private static func errorMessage(_ data: Data) -> String? {
        let json = (try? JSONSerialization.jsonObject(with: data))
        if let object = json as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let message = object["error"] as? String { return message }
        }
        if let array = json as? [[String: Any]], let error = array.first?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}

// MARK: - Setting a service up (dialogs)

@MainActor
enum AISetup {
    /// Asks for whatever the service needs (address, key), fetches its models and lets the
    /// person pick one. Returns true when the service is ready and chosen.
    static func configure(_ service: CompatibleService) async -> Bool {
        if service == .custom {
            guard let address = Dialog.askText(
                "Compatible service",
                "Paste the service's API address. Examples: https://openrouter.ai/api/v1 (OpenRouter), https://api.groq.com/openai/v1 (Groq), http://localhost:1234/v1 (LM Studio).",
                placeholder: "https://…/v1", initial: service.baseURL ?? ""
            ), let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return false }
            service.baseURL = address.hasSuffix("/") ? String(address.dropLast()) : address
        }
        if service.needsKey || service == .custom {
            guard let key = Dialog.askText(
                "\(service.shortTitle) key",
                "Paste the API key. It is stored in the macOS Keychain and only sent to \(service.shortTitle). \(service.keyHelp ?? "")",
                placeholder: service == .openAI ? "sk-…" : "", secure: true, allowEmpty: !service.needsKey
            ) else { return false }
            guard service.saveKey(key) else {
                Dialog.show("Could not save the key", "The macOS Keychain refused to store it. Try again.", style: .warning)
                return false
            }
        }
        if service == .ollama, !(await ollamaRunning()) {
            let choice = Dialog.show(
                "Ollama is not running",
                "Ollama runs AI models on this Mac, for free and without internet. Install it from ollama.com, open it, and download a model in Terminal, for example:\n\nollama pull llama3.2\n\nThen choose Ollama again in the menu.",
                buttons: ["Open ollama.com", "Cancel"]
            )
            if choice == 0, let url = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(url) }
            return false
        }
        return await pickModel(service)
    }

    /// Fetches the models and shows a list to pick from. Returns true when one was chosen.
    static func pickModel(_ service: CompatibleService) async -> Bool {
        guard let base = service.baseURL.flatMap(URL.init(string:)) else { return false }
        let models: [String]
        do {
            models = try await CompatibleService.listModels(baseURL: base, key: service.key, service: service)
        } catch {
            Dialog.show("Could not reach \(service.shortTitle)", error.localizedDescription, style: .warning)
            return false
        }
        guard !models.isEmpty else {
            let hint = service == .ollama ? " Download one in Terminal, for example: ollama pull llama3.2" : ""
            Dialog.show("No models found", "\(service.shortTitle) did not list any model.\(hint)", style: .warning)
            return false
        }
        service.cachedModels = models
        guard let chosen = Dialog.choose(
            "Which \(service.shortTitle) model?",
            "This model writes the minutes, cleans up dictations and grows the glossary. A quick, inexpensive one is plenty; you can change it later in the menu.",
            options: models, selected: service.model.flatMap { models.contains($0) ? $0 : nil } ?? service.suggestedModel(from: models)
        ) else { return false }
        service.model = chosen
        Settings.shared.minutesProvider = service.rawValue
        Log.info("Minutes written by: \(service.shortTitle) · \(chosen).")
        return true
    }

    static func ollamaRunning() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }
}

extension Dialog {
    /// A text (or secure) field in an alert. nil = cancelled.
    static func askText(_ title: String, _ text: String, placeholder: String, initial: String = "", secure: Bool = false, allowEmpty: Bool = false) -> String? {
        let field: NSTextField = secure ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        let choice = show(title, text, buttons: ["Continue", "Cancel"], accessory: field)
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard choice == 0, allowEmpty || !value.isEmpty else { return nil }
        return value
    }

    /// A pop-up list in an alert. nil = cancelled.
    static func choose(_ title: String, _ text: String, options: [String], selected: String?) -> String? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        popup.addItems(withTitles: options)
        if let selected { popup.selectItem(withTitle: selected) }
        let choice = show(title, text, buttons: ["Use This Model", "Cancel"], accessory: popup)
        guard choice == 0 else { return nil }
        return popup.titleOfSelectedItem
    }
}
