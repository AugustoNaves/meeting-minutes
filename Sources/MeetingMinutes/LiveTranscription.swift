import AVFoundation
import Speech

/// On-device transcription of a dictation while it is spoken. Dictation runs two of these:
///
/// - **quick** (`quick: true`): partial results about a second behind the voice, typed while you
///   speak. Less accurate.
/// - **accurate** (`quick: false`): the regular transcriber, fed the same audio as it arrives, so
///   that when the dictation ends its final text is ready a fraction of a second later instead of
///   transcribing the whole recording again.
///
/// (Tested on macOS 26: the "fast results" option is what makes partial results arrive while
/// speaking; without it they all arrive at the end. Each transcriber needs an analyzer of its
/// own: two in the same analyzer both run at the pace of the slower one.)
final class LiveTranscriber: @unchecked Sendable {
    /// Quick mode: called on a background queue with the whole text so far, every time it changes.
    var onText: (@Sendable (String) -> Void)?

    private let quick: Bool
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0
    private var stopped = false
    private var inputClosed = false
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var setUpTask: Task<Void, Never>?
    private var committed = ""

    init(quick: Bool) {
        self.quick = quick
    }

    /// Loads the speech models ahead of time, so the first dictation starts right away.
    static func warmUp(locale: Locale) async {
        do {
            try await Transcription.ensureModel(locale: locale)
            for quick in [true, false] {
                let transcriber = makeTranscriber(locale: locale, quick: quick)
                if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
                    try await SpeechAnalyzer(modules: [transcriber]).prepareToAnalyze(in: format)
                }
            }
        } catch {
            Log.error("Live dictation could not warm up: \(error.localizedDescription)")
        }
    }

    private static func makeTranscriber(locale: Locale, quick: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: quick ? [.volatileResults, .fastResults] : [],
            attributeOptions: []
        )
    }

    /// Starts the transcriber in the background. Audio appended before it is ready is kept and
    /// sent as soon as it is.
    func start(locale: Locale) {
        let task = Task.detached(priority: .userInitiated) { [self] in
            await setUp(locale: locale)
        }
        lock.lock(); setUpTask = task; lock.unlock()
    }

    private func setUp(locale: Locale) async {
        do {
            try await Transcription.ensureModel(locale: locale)
            let transcriber = Self.makeTranscriber(locale: locale, quick: quick)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let results = Task { [self] in
                do {
                    for try await result in transcriber.results { handle(result) }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)
            if !install(analyzer: analyzer, results: results, format: format, continuation: continuation) {
                continuation.finish()
                results.cancel()
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            Log.error("Live dictation unavailable: \(error.localizedDescription)")
        }
    }

    /// Makes the ready transcriber current and sends it the audio kept so far.
    /// Returns false if the dictation already stopped.
    private func install(analyzer: SpeechAnalyzer, results: Task<Void, Never>, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.analyzer = analyzer
        self.resultsTask = results
        self.targetFormat = format
        self.continuation = continuation
        for buffer in pending {
            if let converted = convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        pending = []
        if inputClosed { continuation.finish() }
        return true
    }

    /// Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !inputClosed else { return }
        guard let continuation, let targetFormat else {
            // Not ready yet: keep up to 60 s of audio.
            if pendingFrames < AVAudioFramePosition(buffer.format.sampleRate * 60), let copy = buffer.deepCopy() {
                pending.append(copy)
                pendingFrames += AVAudioFramePosition(copy.frameLength)
            }
            return
        }
        if let converted = convert(buffer, to: targetFormat) {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Accurate mode: ends the audio and returns the full text, usually a fraction of a second
    /// later. nil if the transcriber could not give it within `timeout` (the caller then
    /// transcribes the recording instead).
    func finish(timeout: TimeInterval) async -> String? {
        closeInput()
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { [self] in await finalText() }
            group.addTask { [self] in
                try? await Task.sleep(for: .seconds(timeout))
                // Unblocks the other task so the group can return.
                if !Task.isCancelled { stop() }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { stop() }
            return first
        }
    }

    private func closeInput() {
        lock.lock()
        inputClosed = true
        continuation?.finish()
        lock.unlock()
    }

    private func finalText() async -> String? {
        await currentSetUp()?.value
        guard let (analyzer, results) = installed() else { return nil }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            return nil
        }
        await results.value
        return committedText()
    }

    private func currentSetUp() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return setUpTask
    }

    private func installed() -> (SpeechAnalyzer, Task<Void, Never>)? {
        lock.lock(); defer { lock.unlock() }
        guard let analyzer, let resultsTask else { return nil }
        return (analyzer, resultsTask)
    }

    private func committedText() -> String {
        lock.lock(); defer { lock.unlock() }
        return committed
    }

    /// Stops right away: no more updates after this returns.
    func stop() {
        lock.lock()
        stopped = true
        continuation?.finish()
        continuation = nil
        pending = []
        let analyzer = self.analyzer
        let results = resultsTask
        lock.unlock()
        results?.cancel()
        if let analyzer {
            Task.detached { await analyzer.cancelAndFinishNow() }
        }
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let full: String
        if result.isFinal {
            committed = Self.join(committed, text)
            full = committed
        } else {
            full = Self.join(committed, text)
        }
        let active = !stopped && quick
        lock.unlock()
        if active { onText?(full) }
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Called with the lock held.
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
