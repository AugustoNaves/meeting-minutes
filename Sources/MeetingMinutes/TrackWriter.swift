import AVFoundation
import Foundation

/// Writes one track (microphone or system audio) to a mono 16 kHz .caf file.
///
/// Both tracks share the same "time zero" (the moment recording started). Every block of
/// audio arrives with the host time it was captured at; if the track fell behind (headphones
/// switched, microphone restarted, the system stopped delivering audio while silent), the
/// missing stretch is filled with silence. That way 00:10:00 in one track is the same instant
/// as 00:10:00 in the other, and the order of who spoke when stays correct.
final class TrackWriter {
    static let sampleRate: Double = 16_000

    let url: URL
    private let startSeconds: Double
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var maxPeak: Float = 0
    private var writeErrorLogged = false

    init(url: URL, startHostTime: UInt64, label: String) throws {
        self.url = url
        self.startSeconds = AVAudioTime.seconds(forHostTime: startHostTime)
        self.queue = DispatchQueue(label: "meetingminutes.writer.\(label)", qos: .userInitiated)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false) else {
            throw RecorderError.audioFormat
        }
        targetFormat = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Safe to call from any thread. The buffer is copied right away.
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let copy = buffer.deepCopy() else { return }
        queue.async { [weak self] in self?.process(copy, hostTime: hostTime) }
    }

    /// Closes the file. Returns the duration and the loudest peak (0 = the track was completely silent).
    func finish() -> (duration: Double, peak: Float) {
        queue.sync {
            file?.close()
            file = nil
            return (Double(framesWritten) / Self.sampleRate, maxPeak)
        }
    }

    // MARK: - Internal (always on the writer queue)

    private func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let file else { return }

        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converter?.downmix = true
            converterInputFormat = buffer.format
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, converted.frameLength > 0 else { return }

        // Keep the track aligned with the recording clock.
        let elapsed = AVAudioTime.seconds(forHostTime: hostTime) - startSeconds
        let expectedFrame = AVAudioFramePosition(max(0, elapsed) * Self.sampleRate)
        let drift = expectedFrame - framesWritten
        var startOffset: AVAudioFrameCount = 0

        if drift > AVAudioFramePosition(Self.sampleRate * 0.1) {
            // More than 100 ms behind: fill the gap with silence.
            writeSilence(frames: drift, to: file)
        } else if drift < -AVAudioFramePosition(Self.sampleRate * 0.25) {
            // More than 250 ms ahead (device clock running fast): drop the excess.
            let excess = AVAudioFrameCount(-drift - AVAudioFramePosition(Self.sampleRate * 0.05))
            if excess >= converted.frameLength { return }
            startOffset = excess
        }

        let toWrite = startOffset > 0 ? slice(converted, from: startOffset) : converted
        guard let toWrite else { return }
        maxPeak = max(maxPeak, toWrite.peakLevel())
        do {
            try file.write(from: toWrite)
            framesWritten += AVAudioFramePosition(toWrite.frameLength)
        } catch {
            if !writeErrorLogged {
                Log.error("Could not write \(url.lastPathComponent): \(error.localizedDescription)")
                writeErrorLogged = true
            }
        }
    }

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) {
        var remaining = frames
        let chunk = AVAudioFrameCount(Self.sampleRate) // one second at a time
        guard let silence = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunk) else { return }
        if let data = silence.floatChannelData?[0] {
            data.initialize(repeating: 0, count: Int(chunk))
        }
        while remaining > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            silence.frameLength = count
            do {
                try file.write(from: silence)
            } catch {
                return
            }
            framesWritten += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from offset: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        let count = buffer.frameLength - offset
        guard count > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let src = buffer.floatChannelData?[0],
              let dst = out.floatChannelData?[0]
        else { return nil }
        dst.update(from: src.advanced(by: Int(offset)), count: Int(count))
        out.frameLength = count
        return out
    }
}
