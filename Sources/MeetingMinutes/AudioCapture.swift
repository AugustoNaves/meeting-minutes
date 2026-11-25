import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

typealias AudioSink = (AVAudioPCMBuffer, UInt64) -> Void

enum RecorderError: LocalizedError {
    case audioFormat
    case coreAudio(String, OSStatus)
    case noMicrophone
    case nothingToRecord([String])
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .audioFormat:
            return "Could not set up the audio format."
        case let .coreAudio(step, status):
            return "Core Audio failed to \(step) (code \(status))."
        case .noMicrophone:
            return "No microphone available."
        case let .nothingToRecord(reasons):
            return "Could not record the microphone or the system audio. " + reasons.joined(separator: " ")
        case .alreadyRecording:
            return "A recording is already in progress."
        }
    }
}

// MARK: - Shared Core Audio plumbing

/// Property listeners on Core Audio objects, removed all at once.
/// Notifications arrive on a queue of their own, so removing listeners never waits on itself.
final class PropertyListeners {
    private static let queue = DispatchQueue(label: "meetingminutes.listeners")
    private var entries: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping () -> Void) {
        guard object != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, Self.queue, block) == noErr {
            entries.append((object, address, block))
        }
    }

    func removeAll() {
        for entry in entries {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.object, &address, Self.queue, entry.block)
        }
        entries.removeAll()
    }
}

/// A serial queue that runs work synchronously, also when called from inside itself
/// (e.g. a capture released by its own restart block), where a plain `sync` would deadlock.
final class ControlQueue {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<UUID>()
    private let id = UUID()

    init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: id)
    }

    func run<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) == id { return try work() }
        return try queue.sync(execute: work)
    }
}

/// Restarts a capture after a device change. Notifications that arrive in a burst are merged
/// into one restart, and if restarts keep coming (more than 5 in 30 s) they slow down to one
/// every 3 s, so a capture can never get stuck in a tight restart loop.
final class CaptureRestarter {
    private let control: DispatchQueue
    private var scheduled = false
    private var recent: [Date] = []

    init(control: DispatchQueue) {
        self.control = control
    }

    /// More than 5 restarts in the last 30 s: the capture is not settling. Read on the control queue.
    var isStruggling: Bool {
        recent.filter { Date().timeIntervalSince($0) < 30 }.count > 5
    }

    /// Runs `work` on the control queue after a short delay.
    func schedule(_ work: @escaping () -> Void) {
        control.async {
            guard !self.scheduled else { return }
            self.scheduled = true
            let now = Date()
            self.recent = self.recent.filter { now.timeIntervalSince($0) < 30 } + [now]
            let delay = self.recent.count > 5 ? 3.0 : 0.4
            self.control.asyncAfter(deadline: .now() + delay) {
                self.scheduled = false
                work()
            }
        }
    }
}

/// Turns the raw buffers of a Core Audio reader into AVAudioPCMBuffers, and checks that the
/// audio really arrives at the sample rate the device reported. Bluetooth headsets switch to
/// "call mode" on the fly (48 kHz → 16 or 24 kHz); a wrong rate makes the audio unintelligible.
final class StreamReader: @unchecked Sendable {
    private(set) var format: AVAudioFormat
    private let label: String
    private var windowStart: Double?
    private var lastTime: Double = 0
    private var windowFrames: Double = 0
    private var rateChecked = false
    private var layoutLogged = false

    static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    init(format: AVAudioFormat, label: String) {
        self.format = format
        self.label = label
    }

    /// True if this Core Audio buffer has audio in it.
    static func hasAudio(_ source: AudioBuffer) -> Bool {
        source.mData != nil && source.mDataByteSize > 0
    }

    /// The system audio stream in a capture device's buffers: the last one with the tap's
    /// channel count. A headset's own microphone, if any, comes before it.
    static func tapIndex(in list: UnsafeMutableAudioBufferListPointer, channels: UInt32) -> Int? {
        list.indices.last { list[$0].mNumberChannels == channels && hasAudio(list[$0]) }
    }

    /// Copies one Core Audio buffer. nil = its channel count no longer matches the format.
    func makeBuffer(_ source: AudioBuffer) -> AVAudioPCMBuffer? {
        guard let data = source.mData, source.mNumberChannels == format.channelCount else { return nil }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = Int(source.mDataByteSize) / bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first?.mData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        memcpy(destination, data, frames * bytesPerFrame)
        return buffer
    }

    /// Logs, once, when a device hands over more than one stream (and which one is used).
    func noteLayout(_ channels: [UInt32], using index: Int) {
        guard !layoutLogged else { return }
        layoutLogged = true
        if channels.count > 1 {
            Log.info("\(label): the device delivers \(channels.count) streams (channels \(channels.map(String.init).joined(separator: ", "))); recording only stream \(index + 1).")
        }
    }

    /// Measures the real rate over the first ~3 s of audio; if it is far from the reported
    /// rate, switches to the nearest standard rate so the recording stays intelligible.
    func watch(frames: AVAudioFrameCount, hostTime: UInt64) {
        guard !rateChecked else { return }
        let now = AVAudioTime.seconds(forHostTime: hostTime)
        if let start = windowStart, now - lastTime < 0.5, now > start {
            if now - start >= 3 {
                rateChecked = true
                let measured = windowFrames / (now - start)
                let expected = format.sampleRate
                if abs(measured - expected) / expected > 0.15,
                   let snapped = Self.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }),
                   let fixed = AudioDevices.makeFormat(sampleRate: snapped, channels: format.channelCount) {
                    Log.error("\(label): audio arrives at about \(Int(measured)) Hz but the device reported \(Int(expected)) Hz; recording at \(Int(snapped)) Hz.")
                    format = fixed
                }
            }
        } else {
            windowStart = now
            windowFrames = 0
        }
        windowFrames += Double(frames)
        lastTime = now
    }
}

// MARK: - System audio (the other people on the call)

/// Captures everything the Mac is playing through a Core Audio process tap (macOS 14.2+).
/// No BlackHole or virtual driver needed: macOS hands over the audio before it reaches the
/// headphones or speakers, so it also works with headphones on.
final class SystemAudioCapture {
    private let sink: AudioSink
    /// Called when the capture stops and cannot come back (shown to the user as a warning).
    var onProblem: ((String) -> Void)?
    private let control: ControlQueue
    private let ioQueue = DispatchQueue(label: "meetingminutes.system.io", qos: .userInteractive)
    private let restarter: CaptureRestarter
    private let systemListeners = PropertyListeners()
    private let tapListeners = PropertyListeners()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false

    init(sink: @escaping AudioSink) {
        self.sink = sink
        let control = ControlQueue(label: "meetingminutes.system.control")
        self.control = control
        restarter = CaptureRestarter(control: control.queue)
    }

    deinit {
        stop()
    }

    func start() throws {
        try control.run {
            try startTap()
            running = true
            // If the sound output changes mid-meeting (e.g. AirPods connect), rebuild the capture.
            systemListeners.add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.scheduleRestart("sound output changed")
            }
        }
    }

    func stop() {
        control.run {
            running = false
            systemListeners.removeAll()
            stopTap()
        }
    }

    private func startTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Meeting Minutes"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw RecorderError.coreAudio("create the system audio tap", status) }
        tapID = newTap

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mChannelsPerFrame > 0 else {
            stopTap()
            throw RecorderError.coreAudio("read the system audio format", status)
        }

        let outputUID: String
        do {
            outputUID = try AudioDevices.defaultOutputUID()
        } catch {
            stopTap()
            throw error
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Minutes (system audio)",
            kAudioAggregateDeviceUIDKey: "local.meetingminutes.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else {
            stopTap()
            throw RecorderError.coreAudio("create the capture device", status)
        }
        aggregateID = newAggregate

        // The tap is delivered at the capture device's rate (the sound output's clock), which
        // can differ from the tap's own format: a Bluetooth headset in call mode runs at 16–24 kHz.
        let aggregateRate = AudioDevices.nominalSampleRate(aggregateID)
        let sampleRate = aggregateRate > 0 ? aggregateRate : asbd.mSampleRate
        guard let format = AudioDevices.makeFormat(sampleRate: sampleRate, channels: asbd.mChannelsPerFrame) else {
            stopTap()
            throw RecorderError.audioFormat
        }
        let reader = StreamReader(format: format, label: "System audio")

        // If the sound output also has a microphone (a headset), the capture device lists that
        // microphone first and the system audio last. Only the system audio stream is recorded.
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.contains(where: StreamReader.hasAudio) else { return }
            guard let index = StreamReader.tapIndex(in: list, channels: reader.format.channelCount),
                  let buffer = reader.makeBuffer(list[index])
            else {
                self.scheduleRestart("audio layout changed")
                return
            }
            reader.noteLayout(list.map(\.mNumberChannels), using: index)
            let timestamp = inputTime.pointee
            let host = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time()
            reader.watch(frames: buffer.frameLength, hostTime: host)
            self.sink(buffer, host)
        }
        guard status == noErr, let procID else {
            stopTap()
            throw RecorderError.coreAudio("register the system audio reader", status)
        }
        ignoreOtherInputStreams(of: aggregateID, procID: procID, keepChannels: asbd.mChannelsPerFrame)

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stopTap()
            throw RecorderError.coreAudio("start capturing system audio", status)
        }

        // A headset entering or leaving call mode changes the rate or the streams of the capture
        // device without changing the sound output: rebuild the capture when that happens.
        tapListeners.add(aggregateID, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            self?.scheduleRestart("sample rate changed")
        }
        tapListeners.add(aggregateID, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput) { [weak self] in
            self?.scheduleRestart("audio streams changed")
        }
        tapListeners.add(tapID, kAudioTapPropertyFormat) { [weak self] in
            self?.scheduleRestart("system audio format changed")
        }
        Log.info("System audio: capture started (\(Int(format.sampleRate)) Hz, \(format.channelCount) channels, output \(outputUID)).")
    }

    /// Tells Core Audio this reader only uses the system audio stream, so a headset's own
    /// microphone in the capture device is not opened for nothing. Best effort: if macOS does
    /// not accept it, the reader still picks the right stream by itself.
    private func ignoreOtherInputStreams(of device: AudioObjectID, procID: AudioDeviceIOProcID, keepChannels: UInt32) {
        let channels = AudioDevices.bufferChannels(device, scope: kAudioObjectPropertyScopeInput)
        guard channels.count > 1, let keep = channels.lastIndex(of: keepChannels) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn),
              Int(size) >= flagsOffset
        else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let count = Int(raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self).pointee.mNumberStreams)
        guard count == channels.count, flagsOffset + count * MemoryLayout<UInt32>.size <= Int(size) else { return }
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<count { flags[index] = index == keep ? 1 : 0 }
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
        if status == noErr {
            Log.info("System audio: the sound output has its own microphone; it is left closed (only the system audio is read).")
        } else {
            Log.info("System audio: could not leave the sound output's microphone closed (code \(status)); reading only the system audio stream.")
        }
    }

    private func stopTap() {
        tapListeners.removeAll()
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func scheduleRestart(_ reason: String) {
        restarter.schedule { [weak self] in
            guard let self, self.running else { return }
            Log.info("System audio: restarting (\(reason)).")
            self.stopTap()
            for attempt in 1...5 {
                do {
                    try self.startTap()
                    if self.restarter.isStruggling {
                        self.onProblem?("System audio keeps restarting (\(reason)): parts of what the other people said may be missing.")
                    }
                    return
                } catch {
                    Log.error("Attempt \(attempt) to restart system audio failed: \(error.localizedDescription)")
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            self.onProblem?("System audio stopped recording (\(reason)) and could not be restarted: the other people may be missing from the transcript.")
        }
    }
}

// MARK: - Microphone (your voice)

/// Records the microphone by reading the input device directly (Core Audio).
///
/// It does not use AVAudioEngine: the engine also runs the sound output and fails to start
/// (error -10868) when the microphone and the output run at different rates, which is exactly
/// the case of the Mac's microphone + a Bluetooth headset in call mode.
final class MicrophoneCapture {
    private let sink: AudioSink
    /// nil = follow the system default microphone.
    private let deviceUID: String?
    /// Called when the capture stops and cannot come back (shown to the user as a warning).
    var onProblem: ((String) -> Void)?
    private let control: ControlQueue
    private let ioQueue = DispatchQueue(label: "meetingminutes.mic.io", qos: .userInteractive)
    private let restarter: CaptureRestarter
    private let systemListeners = PropertyListeners()
    private let deviceListeners = PropertyListeners()
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var usingChosenDevice = false
    private var _deviceName = ""

    var deviceName: String { control.run { _deviceName } }

    init(deviceUID: String?, sink: @escaping AudioSink) {
        self.deviceUID = deviceUID
        self.sink = sink
        let control = ControlQueue(label: "meetingminutes.mic.control")
        self.control = control
        restarter = CaptureRestarter(control: control.queue)
    }

    deinit {
        stop()
    }

    func start() throws {
        try control.run {
            try startDevice()
            running = true
            installSystemListeners()
        }
    }

    func stop() {
        control.run {
            running = false
            systemListeners.removeAll()
            stopDevice()
        }
    }

    private func startDevice() throws {
        // Microphone chosen in the menu; if it is not connected, use the system default.
        var chosen: AudioDevices.InputDevice?
        if let deviceUID {
            chosen = AudioDevices.inputDevices().first { $0.uid == deviceUID }
            if chosen == nil { Log.info("The chosen microphone is not connected; using the system default.") }
        }
        guard let device = chosen?.id ?? AudioDevices.defaultInputID() else { throw RecorderError.noMicrophone }
        usingChosenDevice = chosen != nil
        _deviceName = chosen?.name ?? AudioDevices.name(of: device) ?? "default microphone"

        guard let stream = AudioDevices.inputStreams(device).first,
              let asbd = AudioDevices.virtualFormat(stream),
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0
        else { throw RecorderError.noMicrophone }
        let channels = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : asbd.mChannelsPerFrame
        guard let format = AudioDevices.makeFormat(sampleRate: asbd.mSampleRate, channels: channels) else {
            throw RecorderError.audioFormat
        }
        let reader = StreamReader(format: format, label: "Microphone")

        var newProc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProc, device, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = list.first, StreamReader.hasAudio(first) else { return }
            guard let buffer = reader.makeBuffer(first) else {
                self.scheduleRestart("audio format changed")
                return
            }
            let timestamp = inputTime.pointee
            let host = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time()
            reader.watch(frames: buffer.frameLength, hostTime: host)
            self.sink(buffer, host)
        }
        guard status == noErr, let newProc else { throw RecorderError.coreAudio("open the microphone", status) }
        status = AudioDeviceStart(device, newProc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device, newProc)
            throw RecorderError.coreAudio("start the microphone", status)
        }
        deviceID = device
        procID = newProc

        // Same microphone, new format (e.g. a headset switching to call mode): read it again.
        deviceListeners.add(device, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            self?.scheduleRestart("sample rate changed")
        }
        deviceListeners.add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput) { [weak self] in
            self?.scheduleRestart("audio streams changed")
        }
        deviceListeners.add(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            self?.scheduleRestart("microphone disconnected")
        }
        deviceListeners.add(stream, kAudioStreamPropertyVirtualFormat) { [weak self] in
            self?.scheduleRestart("audio format changed")
        }
        Log.info("Microphone: capture started on “\(_deviceName)” (\(Int(format.sampleRate)) Hz, \(format.channelCount) channels).")
    }

    private func stopDevice() {
        deviceListeners.removeAll()
        if deviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func scheduleRestart(_ reason: String) {
        restarter.schedule { [weak self] in
            guard let self, self.running else { return }
            Log.info("Microphone: restarting (\(reason)).")
            self.stopDevice()
            for attempt in 1...5 {
                do {
                    try self.startDevice()
                    if self.restarter.isStruggling {
                        self.onProblem?("The microphone keeps restarting (\(reason)): parts of what you said may be missing.")
                    }
                    return
                } catch {
                    Log.error("Attempt \(attempt) to restart the microphone failed: \(error.localizedDescription)")
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            self.onProblem?("The microphone stopped recording (\(reason)) and could not be restarted: your voice may be missing from the transcript.")
        }
    }

    /// Restart when the default microphone changes (if following the default), or when the
    /// chosen microphone is unplugged or plugged back in.
    private func installSystemListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemListeners.add(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            guard let self else { return }
            self.control.queue.async {
                if self.deviceUID == nil || !self.usingChosenDevice {
                    self.scheduleRestart("default microphone changed")
                }
            }
        }
        systemListeners.add(system, kAudioHardwarePropertyDevices) { [weak self] in
            guard let self, let uid = self.deviceUID else { return }
            let present = AudioDevices.inputDevices().contains { $0.uid == uid }
            self.control.queue.async {
                if present != self.usingChosenDevice { self.scheduleRestart("microphone list changed") }
            }
        }
    }
}

/// Records a few seconds from a microphone and tells whether it heard a voice or only noise.
enum MicrophoneTester {
    struct Result {
        let heardVoice: Bool
        let deviceName: String
        let loudDB: Double
        let quietDB: Double
    }

    private final class Levels: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            // Interleaved buffers keep every channel in the first array.
            let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
            var sum: Float = 0
            vDSP_svesq(data, 1, &sum, vDSP_Length(samples))
            let rms = sqrt(Double(sum) / Double(samples))
            lock.lock(); values.append(20 * log10(max(rms, 1e-7))); lock.unlock()
        }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    static func test(deviceUID: String?, seconds: Double) async -> Result? {
        let levels = Levels()
        let capture = MicrophoneCapture(deviceUID: deviceUID) { buffer, _ in levels.add(buffer) }
        do {
            try capture.start()
        } catch {
            Log.error("Microphone test: \(error.localizedDescription)")
            return nil
        }
        try? await Task.sleep(for: .seconds(seconds))
        let name = capture.deviceName
        capture.stop()
        let sorted = levels.all.sorted()
        guard sorted.count > 4 else { return Result(heardVoice: false, deviceName: name, loudDB: -140, quietDB: -140) }
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let quiet = sorted[Int(Double(sorted.count - 1) * 0.10)]
        // Speech = moments well above the background noise and loud enough to be a voice.
        // Calibrated on real recordings: the "External Microphone" of headphones without a mic
        // sits around -42 to -44 dB of pure hiss; normal speech on a Mac's microphone is above -35 dB.
        let heard = loud > -38 && loud - quiet > 12
        Log.info(String(format: "Microphone test on “%@”: loud %.0f dB, background %.0f dB → %@.", name, loud, quiet, heard ? "voice" : "no voice"))
        return Result(heardVoice: heard, deviceName: name, loudDB: loud, quietDB: quiet)
    }
}

// MARK: - Devices

enum AudioDevices {
    struct InputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    static func name(of device: AudioObjectID) -> String? {
        stringProperty(device, kAudioObjectPropertyName)
    }

    /// Channels of each buffer the device delivers in that direction (one entry per stream).
    static func bufferChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        bufferChannels(device, scope: kAudioDevicePropertyScopeInput).reduce(0) { $0 + Int($1) }
    }

    /// Input streams of a device, in the order their buffers are delivered.
    static func inputStreams(_ device: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// The format a stream hands to readers (normally 32-bit float).
    static func virtualFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// Interleaved 32-bit float, the format Core Audio readers receive.
    static func makeFormat(sampleRate: Double, channels: UInt32) -> AVAudioFormat? {
        guard sampleRate > 0, channels > 0 else { return nil }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: true)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: true, channelLayout: layout)
    }

    /// Available microphones (devices with audio input).
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("local.meetingminutes"),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultInputID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    static func defaultInputName() -> String? {
        defaultInputID().flatMap { name(of: $0) }
    }

    static func defaultOutputID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            throw RecorderError.coreAudio("find the default sound output", status)
        }
        return device
    }

    static func defaultOutputUID() throws -> String {
        let device = try defaultOutputID()
        guard let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else {
            throw RecorderError.coreAudio("read the sound output identifier", -1)
        }
        return uid
    }
}
