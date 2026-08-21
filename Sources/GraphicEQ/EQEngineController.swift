import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

enum EQEngineError: LocalizedError {
    case blackHoleNotFound
    case noOutputDeviceSelected
    case deviceBindingFailed(String)

    var errorDescription: String? {
        switch self {
        case .blackHoleNotFound:
            return "BlackHole virtual audio device not found. Run setup_blackhole.sh in Terminal, then try again."
        case .noOutputDeviceSelected:
            return "No output device selected."
        case .deviceBindingFailed(let detail):
            return "Failed to bind audio device: \(detail)"
        }
    }
}

/// Owns the two AVAudioEngines that bridge system audio (via BlackHole) through a graphic
/// EQ and out to the user's chosen physical output device. See RingBuffer for the bridge.
final class EQEngineController {
    private let appState: AppState

    private var engineA: AVAudioEngine?
    private var engineB: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?

    private var converter: AVAudioConverter?
    private let ringBuffer: RingBuffer
    private var drainTimer: DispatchSourceTimer?

    private var savedOriginalOutputDeviceID: AudioDeviceID?

    private var cancellables = Set<AnyCancellable>()

    private static let bridgeSampleRate: Double = 48000
    private static let bridgeChannelCount: AVAudioChannelCount = 2
    private static let ringCapacityFrames = Int(bridgeSampleRate * 0.4) // ~400ms
    private static let drainIntervalMs = 20
    private static let drainFrameCount = Int(bridgeSampleRate) * drainIntervalMs / 1000

    private lazy var bridgeFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.bridgeSampleRate,
                      channels: Self.bridgeChannelCount,
                      interleaved: false)!
    }()

    init(appState: AppState) {
        self.appState = appState
        self.ringBuffer = RingBuffer(capacityFrames: Self.ringCapacityFrames, channelCount: Int(Self.bridgeChannelCount))
        observeAppState()
    }

    private func observeAppState() {
        appState.$isEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    self.attemptEnable()
                } else {
                    self.disableEQMode()
                }
            }
            .store(in: &cancellables)

        appState.$bandGains
            .sink { [weak self] gains in
                self?.applyGains(gains)
            }
            .store(in: &cancellables)

        appState.$selectedOutputDeviceUID
            .dropFirst()
            .sink { [weak self] uid in
                guard let self, self.appState.isEnabled, let uid,
                      let device = AudioDeviceManager.device(forUID: uid) else { return }
                self.switchRealOutputDevice(to: device.id)
            }
            .store(in: &cancellables)
    }

    private func attemptEnable() {
        guard let uid = appState.selectedOutputDeviceUID, let device = AudioDeviceManager.device(forUID: uid) else {
            appState.statusMessage = EQEngineError.noOutputDeviceSelected.errorDescription
            appState.isEnabled = false
            return
        }
        do {
            try enableEQMode(realOutputDeviceID: device.id)
            appState.statusMessage = "Enabled — routing via BlackHole"
        } catch {
            appState.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appState.isEnabled = false
        }
    }

    // MARK: - Enable / Disable

    func enableEQMode(realOutputDeviceID: AudioDeviceID) throws {
        guard let blackHole = AudioDeviceManager.findBlackHoleDevice() else {
            throw EQEngineError.blackHoleNotFound
        }

        savedOriginalOutputDeviceID = AudioDeviceManager.getDefaultOutputDevice()

        guard AudioDeviceManager.setDefaultOutputDevice(blackHole.id) else {
            throw EQEngineError.deviceBindingFailed("could not set default output to BlackHole")
        }

        try startEngineA(blackHoleDeviceID: blackHole.id)
        try startEngineB(realOutputDeviceID: realOutputDeviceID)
        startDrainTimer()
    }

    func disableEQMode() {
        stopDrainTimer()

        engineA?.inputNode.removeTap(onBus: 0)
        engineA?.stop()
        engineA = nil

        playerNode?.stop()
        engineB?.stop()
        engineB = nil
        playerNode = nil
        eqNode = nil
        converter = nil

        if let original = savedOriginalOutputDeviceID {
            AudioDeviceManager.setDefaultOutputDevice(original)
        }
        savedOriginalOutputDeviceID = nil
    }

    // MARK: - Engine A (capture from BlackHole)

    private func startEngineA(blackHoleDeviceID: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        try setCurrentDevice(blackHoleDeviceID, on: input.audioUnit)

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw EQEngineError.deviceBindingFailed("BlackHole input format unavailable")
        }

        converter = AVAudioConverter(from: inputFormat, to: bridgeFormat)

        engine.connect(input, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 0

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        engineA = engine
    }

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = bridgeFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: bridgeFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        let status = converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil, converted.frameLength > 0 else { return }
        writeInterleavedToRing(converted)
    }

    private func writeInterleavedToRing(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(bridgeFormat.channelCount)
        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        for ch in 0..<channels {
            let src = channelData[ch]
            for i in 0..<frameCount {
                interleaved[i * channels + ch] = src[i]
            }
        }
        interleaved.withUnsafeBufferPointer { ptr in
            ringBuffer.write(ptr.baseAddress!, frameCount: frameCount)
        }
    }

    // MARK: - Engine B (EQ + playback to real device)

    private func startEngineB(realOutputDeviceID: AudioDeviceID) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = makeEQNode()

        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: bridgeFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: bridgeFormat)

        try setCurrentDevice(realOutputDeviceID, on: engine.outputNode.audioUnit)

        engine.prepare()
        try engine.start()
        player.play()

        engineB = engine
        playerNode = player
        eqNode = eq
        applyGains(appState.bandGains)
    }

    private func switchRealOutputDevice(to deviceID: AudioDeviceID) {
        guard let engine = engineB, let player = playerNode else { return }
        player.stop()
        engine.stop()
        do {
            try setCurrentDevice(deviceID, on: engine.outputNode.audioUnit)
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            appState.statusMessage = "Failed to switch output device: \(error.localizedDescription)"
        }
    }

    private func makeEQNode() -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: EQBands.count)
        for (index, definition) in EQBands.definitions.enumerated() {
            let band = eq.bands[index]
            band.filterType = .parametric
            band.frequency = Float(definition.frequency)
            band.bandwidth = EQBands.bandwidth
            band.gain = appState.bandGains[index]
            band.bypass = false
        }
        eq.globalGain = 0
        return eq
    }

    private func applyGains(_ gains: [Float]) {
        guard let eqNode, gains.count == eqNode.bands.count else { return }
        for (index, gain) in gains.enumerated() {
            eqNode.bands[index].gain = gain
        }
    }

    // MARK: - Drain timer (ring buffer -> player node)

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.graphiceq.drain"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(Self.drainIntervalMs))
        timer.setEventHandler { [weak self] in
            self?.drainRingBufferToPlayer()
        }
        timer.resume()
        drainTimer = timer
    }

    private func stopDrainTimer() {
        drainTimer?.cancel()
        drainTimer = nil
    }

    private func drainRingBufferToPlayer() {
        guard let player = playerNode else { return }
        let channels = Int(bridgeFormat.channelCount)
        let frameCount = Self.drainFrameCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: bridgeFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        interleaved.withUnsafeMutableBufferPointer { ptr in
            _ = ringBuffer.read(into: ptr.baseAddress!, frameCount: frameCount)
        }

        guard let channelData = buffer.floatChannelData else { return }
        for ch in 0..<channels {
            let dst = channelData[ch]
            for i in 0..<frameCount {
                dst[i] = interleaved[i * channels + ch]
            }
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Device binding helper

    private func setCurrentDevice(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else {
            throw EQEngineError.deviceBindingFailed("no underlying AudioUnit")
        }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw EQEngineError.deviceBindingFailed("AudioUnitSetProperty failed with status \(status)")
        }
    }
}
