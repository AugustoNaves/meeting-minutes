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

// MARK: - System audio (the other people on the call)

/// Captures everything the Mac is playing through a Core Audio process tap (macOS 14.2+).
/// No BlackHole or virtual driver needed: macOS hands over the audio before it reaches the
/// headphones or speakers, so it also works with headphones on.
final class SystemAudioCapture {
    private let sink: AudioSink
    private let control = DispatchQueue(label: "meetingminutes.system.control")
    private let ioQueue = DispatchQueue(label: "meetingminutes.system.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var running = false

    init(sink: @escaping AudioSink) {
        self.sink = sink
    }

    deinit {
        stop()
    }

    func start() throws {
        try control.sync {
            try startTap()
            running = true
        }
        installOutputListener()
    }

    func stop() {
        removeOutputListener()
        control.sync {
            running = false
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
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stopTap()
            throw RecorderError.coreAudio("read the system audio format", status)
        }
        tapFormat = format

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

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let format = self.tapFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
            let timestamp = inputTime.pointee
            let host = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : mach_absolute_time()
            self.sink(buffer, host)
        }
        guard status == noErr else {
            stopTap()
            throw RecorderError.coreAudio("register the system audio reader", status)
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stopTap()
            throw RecorderError.coreAudio("start capturing system audio", status)
        }
        Log.info("System audio: capture started (\(Int(format.sampleRate)) Hz, \(format.channelCount) channels, output \(outputUID)).")
    }

    private func stopTap() {
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

    /// If the sound output changes mid-meeting (e.g. AirPods connect), rebuild the capture.
    private func installOutputListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.control.asyncAfter(deadline: .now() + 0.4) {
                guard self.running else { return }
                Log.info("Sound output changed; restarting system audio capture.")
                self.stopTap()
                for attempt in 1...5 {
                    do {
                        try self.startTap()
                        return
                    } catch {
                        Log.error("Attempt \(attempt) to restart system audio failed: \(error.localizedDescription)")
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
    }

    private func removeOutputListener() {
        guard let listener = outputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        outputListener = nil
    }
}

// MARK: - Microphone (your voice)

final class MicrophoneCapture {
    private let sink: AudioSink
    /// nil = follow the system default microphone.
    private let deviceUID: String?
    private let control = DispatchQueue(label: "meetingminutes.mic.control")
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var usingChosenDevice = false
    private(set) var deviceName = ""

    init(deviceUID: String?, sink: @escaping AudioSink) {
        self.deviceUID = deviceUID
        self.sink = sink
    }

    deinit {
        stop()
    }

    func start() throws {
        try control.sync {
            try startEngine()
            running = true
        }
        installListeners()
    }

    func stop() {
        removeListeners()
        control.sync {
            running = false
            stopEngine()
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Microphone chosen in the menu; if it is not connected, use the system default.
        var chosen: AudioDevices.InputDevice?
        if let deviceUID, let device = AudioDevices.inputDevices().first(where: { $0.uid == deviceUID }), let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status == noErr {
                chosen = device
            } else {
                Log.error("Could not use microphone \(device.name) (code \(status)); using the default.")
            }
        } else if deviceUID != nil {
            Log.info("The chosen microphone is not connected; using the system default.")
        }
        deviceName = chosen?.name ?? AudioDevices.defaultInputName() ?? "default microphone"
        usingChosenDevice = chosen != nil

        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else { throw RecorderError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, when in
            let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            self?.sink(buffer, host)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "audio configuration changed")
        }
        Log.info("Microphone: capture started on “\(deviceName)” (\(Int(hardwareFormat.sampleRate)) Hz, \(hardwareFormat.channelCount) channels).")
    }

    private func stopEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }

    private func scheduleRestart(reason: String) {
        control.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.running else { return }
            Log.info("Microphone: restarting (\(reason)).")
            self.stopEngine()
            for attempt in 1...5 {
                do {
                    try self.startEngine()
                    return
                } catch {
                    Log.error("Attempt \(attempt) to restart the microphone failed: \(error.localizedDescription)")
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
    }

    /// Restart when the default microphone changes (if following the default), or when the
    /// chosen microphone is unplugged or plugged back in.
    private func installListeners() {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.deviceUID == nil else { return }
            self.scheduleRestart(reason: "default microphone changed")
        }
        defaultInputListener = defaultListener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, nil, defaultListener)

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let uid = self.deviceUID else { return }
            let present = AudioDevices.inputDevices().contains { $0.uid == uid }
            let usingChosen = self.control.sync { self.usingChosenDevice }
            if present != usingChosen { self.scheduleRestart(reason: "microphone list changed") }
        }
        devicesListener = listListener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, nil, listListener)
    }

    private func removeListeners() {
        if let listener = defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        }
        if let listener = devicesListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        }
        defaultInputListener = nil
        devicesListener = nil
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
            var sum: Float = 0
            vDSP_svesq(data, 1, &sum, vDSP_Length(buffer.frameLength))
            let rms = sqrt(Double(sum) / Double(buffer.frameLength))
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

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
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

    static func defaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return stringProperty(device, kAudioObjectPropertyName)
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
