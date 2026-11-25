import Accelerate
import AVFoundation
import Foundation
import os
import Security

// MARK: - Log

/// Minimal logger: writes to the macOS unified log and to ~/Library/Logs/MeetingMinutes.log.
/// It only records events and errors, never what was said in a meeting.
enum Log {
    private static let logger = Logger(subsystem: "local.meetingminutes", category: "app")
    private static let queue = DispatchQueue(label: "meetingminutes.log")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MeetingMinutes.log")
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("INFO", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

// MARK: - Folders

enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var defaultMinutesFolder: URL {
        home.appendingPathComponent("Documents/Meeting Minutes", isDirectory: true)
    }

    /// Where the minutes (.md) are saved. Can be changed from the menu.
    static var minutesFolder: URL {
        if let custom = Settings.shared.minutesFolderPath, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultMinutesFolder
    }

    /// Where audio is archived when "Keep Meeting Audio" is on.
    static var audioArchiveFolder: URL {
        minutesFolder.appendingPathComponent("Audio", isDirectory: true)
    }

    static var appSupport: URL {
        // Undocumented override for tests (e.g. `-dataFolder /tmp/x` on the command line).
        if let custom = UserDefaults.standard.string(forKey: "dataFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Application Support/MeetingMinutes", isDirectory: true)
    }

    /// Recordings in progress or not processed yet.
    static var sessions: URL {
        appSupport.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Settings

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "playSounds": true,
            "keepAudio": false,
            "hotKeyPreset": 0,
            "onboardingDone": false,
            "minutesModel": "claude-opus-5-5",
            "dictationHotKeyPreset": 0,
            "dictationCleanUp": true,
            "dictationTypeLive": true,
            "glossaryAutoLearn": true,
        ])
    }

    var onboardingDone: Bool {
        get { defaults.bool(forKey: "onboardingDone") }
        set { defaults.set(newValue, forKey: "onboardingDone") }
    }

    var playSounds: Bool {
        get { defaults.bool(forKey: "playSounds") }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    var keepAudio: Bool {
        get { defaults.bool(forKey: "keepAudio") }
        set { defaults.set(newValue, forKey: "keepAudio") }
    }

    var hotKeyPreset: Int {
        get { defaults.integer(forKey: "hotKeyPreset") }
        set { defaults.set(newValue, forKey: "hotKeyPreset") }
    }

    /// Language spoken in the meetings (locale identifier, e.g. "en_US", "pt_BR"). nil = the Mac's language.
    var meetingLanguage: String? {
        get { defaults.string(forKey: "meetingLanguage") }
        set { defaults.set(newValue, forKey: "meetingLanguage") }
    }

    /// Custom folder for the minutes. nil = ~/Documents/Meeting Minutes.
    var minutesFolderPath: String? {
        get { defaults.string(forKey: "minutesFolderPath") }
        set { defaults.set(newValue, forKey: "minutesFolderPath") }
    }

    /// Who writes the minutes (MinutesProvider). nil = automatic.
    var minutesProvider: String? {
        get { defaults.string(forKey: "minutesProvider") }
        set { defaults.set(newValue, forKey: "minutesProvider") }
    }

    /// Claude model used by Claude Code and the API.
    var minutesModel: String {
        get { defaults.string(forKey: "minutesModel") ?? "claude-opus-5-5" }
        set { defaults.set(newValue, forKey: "minutesModel") }
    }

    /// Gemini model used through Antigravity. nil = Antigravity's default.
    var geminiModel: String? {
        get { defaults.string(forKey: "geminiModel") }
        set { defaults.set(newValue, forKey: "geminiModel") }
    }

    /// Gemini models seen in the last `agy models` ([id, name]).
    var geminiModels: [[String]] {
        get { defaults.array(forKey: "geminiModels") as? [[String]] ?? [] }
        set { defaults.set(newValue, forKey: "geminiModels") }
    }

    /// Chosen microphone (Core Audio UID). nil = follow the system default.
    var micDeviceUID: String? {
        get { defaults.string(forKey: "micDeviceUID") }
        set { defaults.set(newValue, forKey: "micDeviceUID") }
    }

    /// Dictation shortcut (index in DictationHotKeyPresets; -1 = dictation off).
    var dictationHotKeyPreset: Int {
        get { defaults.integer(forKey: "dictationHotKeyPreset") }
        set { defaults.set(newValue, forKey: "dictationHotKeyPreset") }
    }

    /// Polish each dictation with the AI (punctuation, filler words, glossary) before typing it.
    var dictationCleanUp: Bool {
        get { defaults.bool(forKey: "dictationCleanUp") }
        set { defaults.set(newValue, forKey: "dictationCleanUp") }
    }

    /// Type the words into the app while they are spoken (corrected in place at the end).
    var dictationTypeLive: Bool {
        get { defaults.bool(forKey: "dictationTypeLive") }
        set { defaults.set(newValue, forKey: "dictationTypeLive") }
    }

    /// Let the AI add terms and corrections to the glossary on its own.
    var glossaryAutoLearn: Bool {
        get { defaults.bool(forKey: "glossaryAutoLearn") }
        set { defaults.set(newValue, forKey: "glossaryAutoLearn") }
    }

    /// When the glossary last learned from dictations and minutes.
    var glossaryLearnedAt: Date? {
        get { defaults.object(forKey: "glossaryLearnedAt") as? Date }
        set { defaults.set(newValue, forKey: "glossaryLearnedAt") }
    }

    /// Dictations since the glossary last learned.
    var dictationsSinceLearning: Int {
        get { defaults.integer(forKey: "dictationsSinceLearning") }
        set { defaults.set(newValue, forKey: "dictationsSinceLearning") }
    }

    var lastMinutesPath: String? {
        get { defaults.string(forKey: "lastMinutesPath") }
        set { defaults.set(newValue, forKey: "lastMinutesPath") }
    }
}

// MARK: - Keychain (Claude API key)

enum Keychain {
    private static let service = "local.meetingminutes"
    private static let account = "anthropic-api-key"

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        deleteAPIKey()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Prosa – Claude API key",
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Audio helpers

extension AVAudioPCMBuffer {
    /// Independent copy of the buffer (Core Audio buffers are only valid during the callback).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)
        else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            if let src = source[index].mData, let dst = destination[index].mData {
                memcpy(dst, src, Int(bytes))
            }
            destination[index].mDataByteSize = bytes
        }
        return copy
    }

    /// Largest absolute sample value (0 = complete silence). Float formats only.
    func peakLevel() -> Float {
        guard let channels = floatChannelData, frameLength > 0 else { return 0 }
        let channelCount = Int(format.channelCount)
        var peak: Float = 0
        if format.isInterleaved {
            vDSP_maxmgv(channels[0], 1, &peak, vDSP_Length(Int(frameLength) * channelCount))
        } else {
            for channel in 0..<channelCount {
                var value: Float = 0
                vDSP_maxmgv(channels[channel], 1, &value, vDSP_Length(frameLength))
                peak = max(peak, value)
            }
        }
        return peak
    }
}

/// Converts a recording .caf into a small .m4a (AAC) for archiving.
enum AudioArchiver {
    static func archive(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000 * 10) else {
            throw NSError(domain: "MeetingMinutes", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough memory to convert the audio."])
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        output.close()
    }
}

// MARK: - Formatting

enum Formatting {
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Date and time in the meeting language, for the title of the minutes.
    static func titleDate(_ date: Date, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()

    static let sessionID: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
