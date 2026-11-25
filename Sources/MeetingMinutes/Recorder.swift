import AVFoundation
import Foundation

/// Information about a recording, saved next to the audio (meta.json).
/// If the app quits mid-recording, the recording stays in its folder and can be processed later.
struct SessionMeta: Codable {
    var startDate: Date
    var endDate: Date?
    var micPeak: Float?
    var systemPeak: Float?
    /// Locale identifier of the meeting language at recording time.
    var language: String?
    var warnings: [String] = []

    static let fileName = "meta.json"
    static let micFile = "you.caf"
    static let systemFile = "meeting.caf"

    static func load(from dir: URL) -> SessionMeta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionMeta.self, from: data)
    }

    func save(to dir: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(self) {
            try? data.write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        }
    }
}

struct FinishedRecording {
    let directory: URL
    let meta: SessionMeta
    let duration: Double
}

/// Ties the two captures (microphone + system) to their tracks.
final class Recorder {
    private(set) var isRecording = false
    private(set) var startDate: Date?
    private var directory: URL?
    private var meta: SessionMeta?
    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var micWriter: TrackWriter?
    private var systemWriter: TrackWriter?

    // Problems found while recording (a track that failed or stopped). Captures report them
    // from their own queues, so access goes through a lock.
    private let warningsLock = NSLock()
    private var currentWarnings: [String] = []

    /// Problems of the recording in progress, to show on the menu bar icon.
    var liveWarnings: [String] {
        warningsLock.lock(); defer { warningsLock.unlock() }
        return currentWarnings
    }

    private func addWarning(_ warning: String) {
        warningsLock.lock()
        let isNew = !currentWarnings.contains(warning)
        if isNew { currentWarnings.append(warning) }
        warningsLock.unlock()
        if isNew { Log.error("Recording problem: \(warning)") }
    }

    /// Starts recording. Returns warnings (e.g. no microphone permission) if only one track works.
    func start() throws -> [String] {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        let start = Date()
        let dir = Paths.sessions.appendingPathComponent(Formatting.sessionID.string(from: start), isDirectory: true)
        try Paths.ensure(dir)
        var meta = SessionMeta(startDate: start, language: MeetingLanguage.locale.identifier)
        meta.save(to: dir)

        let startHost = mach_absolute_time()
        let micWriter = try TrackWriter(url: dir.appendingPathComponent(SessionMeta.micFile), startHostTime: startHost, label: "mic")
        let systemWriter = try TrackWriter(url: dir.appendingPathComponent(SessionMeta.systemFile), startHostTime: startHost, label: "system")

        var warnings: [String] = []
        warningsLock.lock(); currentWarnings = []; warningsLock.unlock()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            let capture = MicrophoneCapture(deviceUID: Settings.shared.micDeviceUID) { buffer, host in micWriter.append(buffer, hostTime: host) }
            capture.onProblem = { [weak self] in self?.addWarning($0) }
            do {
                try capture.start()
                mic = capture
            } catch {
                warnings.append("The microphone could not be recorded (\(error.localizedDescription)).")
            }
        default:
            warnings.append("No microphone permission: your voice will not be recorded.")
        }

        let capture = SystemAudioCapture { buffer, host in systemWriter.append(buffer, hostTime: host) }
        capture.onProblem = { [weak self] in self?.addWarning($0) }
        do {
            try capture.start()
            system = capture
        } catch {
            warnings.append("System audio could not be recorded (\(error.localizedDescription)).")
        }

        if mic == nil && system == nil {
            _ = micWriter.finish()
            _ = systemWriter.finish()
            try? FileManager.default.removeItem(at: dir)
            throw RecorderError.nothingToRecord(warnings)
        }

        for warning in warnings { addWarning(warning) }
        meta.warnings = warnings
        meta.save(to: dir)
        self.meta = meta
        self.directory = dir
        self.micWriter = micWriter
        self.systemWriter = systemWriter
        self.startDate = start
        isRecording = true
        Log.info("Recording started in \(dir.lastPathComponent).")
        return warnings
    }

    func stop() -> FinishedRecording? {
        guard isRecording, let directory, var meta else { return nil }
        mic?.stop()
        system?.stop()
        let micResult = micWriter?.finish()
        let systemResult = systemWriter?.finish()

        meta.endDate = Date()
        meta.warnings = liveWarnings
        meta.micPeak = mic == nil ? nil : micResult?.peak
        meta.systemPeak = system == nil ? nil : systemResult?.peak
        if let peak = meta.systemPeak, peak == 0 {
            meta.warnings.append("System audio was completely silent. If other people were talking, check the “System Audio Recording” permission in System Settings › Privacy & Security.")
        }
        if let peak = meta.micPeak, peak == 0 {
            meta.warnings.append("The microphone was completely silent. Check the microphone permission and that it is not muted.")
        }
        meta.save(to: directory)

        let duration = max(micResult?.duration ?? 0, systemResult?.duration ?? 0)
        let finished = FinishedRecording(directory: directory, meta: meta, duration: duration)

        mic = nil
        system = nil
        micWriter = nil
        systemWriter = nil
        self.directory = nil
        self.meta = nil
        startDate = nil
        isRecording = false
        Log.info("Recording stopped (\(Formatting.clock(duration))).")
        return finished
    }

    /// Recordings that have not become minutes yet (processing failed or the app quit mid-way).
    func pendingSessions() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: Paths.sessions, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.hasDirectoryPath && $0 != directory }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(SessionMeta.fileName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
