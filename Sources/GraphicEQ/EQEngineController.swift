import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine
import os.log

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
///
/// Both engines are created ONCE and kept alive for the app's lifetime; enable/disable only
/// stops/reconfigures/restarts them. Recreating a fresh AVAudioEngine on every enable was
/// tried first and is flaky: CoreAudio doesn't always release a HAL device binding from a
/// just-stopped engine instance before a second, brand-new engine tries to claim the same
/// device, so the second enable "succeeds" with no error but produces no audio.
final class EQEngineController {
    private static let log = OSLog(subsystem: "com.ankitgupta.graphiceq", category: "engine")

    private let appState: AppState

    private let engineA = AVAudioEngine()
    private let engineB = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode: AVAudioUnitEQ

    private var converter: AVAudioConverter?
    private let ringBuffer: RingBuffer
    private var drainTimer: DispatchSourceTimer?

    /// UID (not AudioDeviceID) of the device to restore on disable. AudioDeviceIDs are
    /// recycled when devices come and go, so a stale ID can silently resolve to the wrong
    /// device; UIDs are stable.
    private var savedOriginalOutputDeviceUID: String?

    /// True between a successful enable and the matching disable. Guards enableEQMode against
    /// running twice without an intervening disable — which is how BlackHole ends up saved as
    /// the "original" device and the restore path becomes a permanent no-op.
    private var isActive = false

    /// Tracked explicitly because engineA.isRunning is NOT a reliable proxy for tap presence:
    /// the engine stops itself on AVAudioEngineConfigurationChange, and a failed start leaves
    /// the tap installed while isRunning is false. Installing a second tap on the same bus
    /// raises an ObjC exception that Swift cannot catch, killing the process.
    private var tapInstalled = false

    private var cancellables = Set<AnyCancellable>()
    private var configChangeObservers: [NSObjectProtocol] = []
    private var configChangeWorkItem: DispatchWorkItem?

    private static let configChangeDebounce: TimeInterval = 0.3

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
        self.eqNode = AVAudioUnitEQ(numberOfBands: EQBands.count)
        self.ringBuffer = RingBuffer(capacityFrames: Self.ringCapacityFrames, channelCount: Int(Self.bridgeChannelCount))

        configureEQBands(gains: appState.bandGains)
        engineB.attach(playerNode)
        engineB.attach(eqNode)
        engineB.connect(playerNode, to: eqNode, format: bridgeFormat)
        engineB.connect(eqNode, to: engineB.mainMixerNode, format: bridgeFormat)

        recoverFromUncleanShutdown()
        observeAppState()
        observeConfigurationChanges()
    }

    deinit {
        configChangeObservers.forEach(NotificationCenter.default.removeObserver)
        configChangeWorkItem?.cancel()
    }

    // MARK: - Device configuration changes

    /// AVAudioEngine stops itself when the hardware underneath it changes and posts this
    /// notification. Without an observer the audio silently dies while the UI still reads
    /// "enabled" — and because we hold the system default output hostage on BlackHole, the
    /// user can't even escape by picking another device in System Settings.
    ///
    /// Triggers are broader than hot-plugging: a sample-rate or channel-count change on a
    /// bound device does it too, which is routine for BlackHole since every app on the system
    /// feeds it and any of them can renegotiate the rate.
    private func observeConfigurationChanges() {
        for engine in [engineA, engineB] {
            // `queue` MUST be nil. Passing a queue makes NotificationCenter wrap the block in
            // an NSOperation and *block the poster* on -waitUntilFinished until it runs.
            // AVFoundation posts this from its internal engine queue, while any main-thread
            // call into the engine (e.g. inputFormat(forBus:)) dispatch_syncs onto that same
            // queue — so `queue: .main` deadlocks the two against each other. With nil the
            // block runs inline on the posting thread; hop to main ourselves instead.
            let token = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.scheduleConfigurationRecovery() }
            }
            configChangeObservers.append(token)
        }
    }

    /// One device change fires this repeatedly — once per engine, and again as the HAL settles
    /// — and the hardware isn't reliably ready to rebind on the first one. Coalesce the burst
    /// into a single rebuild.
    private func scheduleConfigurationRecovery() {
        guard isActive else { return }
        configChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildAfterConfigurationChange() }
        configChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.configChangeDebounce, execute: work)
    }

    private func rebuildAfterConfigurationChange() {
        guard isActive else { return }
        os_log("config change: rebuilding audio graph", log: Self.log, type: .info)

        guard let blackHole = AudioDeviceManager.findBlackHoleDevice() else {
            giveUpAfterConfigurationChange(EQEngineError.blackHoleNotFound.errorDescription)
            return
        }
        guard let uid = appState.selectedOutputDeviceUID,
              let device = AudioDeviceManager.device(forUID: uid) else {
            giveUpAfterConfigurationChange("Output device is no longer available — EQ stopped.")
            return
        }

        // The same event may have knocked the system default off BlackHole.
        if AudioDeviceManager.getDefaultOutputDevice() != blackHole.id {
            AudioDeviceManager.setDefaultOutputDevice(blackHole.id)
        }

        do {
            ringBuffer.reset()
            try startEngineA(blackHoleDeviceID: blackHole.id)
            try startEngineB(realOutputDeviceID: device.id)
            if drainTimer == nil { startDrainTimer() }
            appState.statusMessage = "Enabled — routing via BlackHole"
            os_log("config change: recovered on %{public}@", log: Self.log, type: .info, device.name)
        } catch {
            os_log("config change: recovery failed: %{public}@", log: Self.log, type: .error,
                   String(describing: error))
            giveUpAfterConfigurationChange("Audio device changed — EQ stopped. Toggle to retry.")
        }
    }

    /// Unwind and flip the UI off, so the toggle never lies about whether audio is flowing.
    /// The isEnabled write is deferred for the same reason as reportEnableFailure: this can run
    /// while other state is still settling, and a synchronous write would re-enter the sink.
    private func giveUpAfterConfigurationChange(_ message: String?) {
        disableEQMode()
        appState.statusMessage = message
        DispatchQueue.main.async { [weak self] in
            self?.appState.isEnabled = false
        }
    }

    /// If a previous run died without restoring (crash, force-quit, power loss), the system
    /// default output is still BlackHole and the user has no audio. Put it back at launch.
    private func recoverFromUncleanShutdown() {
        guard let uid = appState.originalOutputDeviceUID else { return }
        defer { appState.originalOutputDeviceUID = nil }

        guard let blackHole = AudioDeviceManager.findBlackHoleDevice(),
              AudioDeviceManager.getDefaultOutputDevice() == blackHole.id else {
            // Default output isn't BlackHole, so someone (the user, or a clean exit we didn't
            // record) already sorted it out. Don't yank them off their current device.
            return
        }
        guard let device = AudioDeviceManager.device(forUID: uid) else {
            os_log("recovery: saved device %{public}@ is gone, leaving default alone",
                   log: Self.log, type: .error, uid)
            return
        }
        let ok = AudioDeviceManager.setDefaultOutputDevice(device.id)
        os_log("recovery: previous run exited without restoring; default output -> %{public}@ (ok=%{public}@)",
               log: Self.log, type: .info, device.name, String(ok))
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
            reportEnableFailure(EQEngineError.noOutputDeviceSelected.errorDescription)
            return
        }
        do {
            try enableEQMode(realOutputDeviceID: device.id)
            appState.statusMessage = "Enabled — routing via BlackHole"
        } catch {
            os_log("enableEQMode failed: %{public}@", log: Self.log, type: .error, String(describing: error))
            reportEnableFailure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// @Published publishes from willSet, i.e. *before* the new value is stored. Assigning
    /// isEnabled from inside its own subscriber therefore gets overwritten by the outer
    /// assignment that is still unwinding, leaving the toggle stuck ON with the engine off —
    /// and every subsequent retry re-entering enable without a disable. Defer the write to the
    /// next runloop turn so it actually sticks.
    private func reportEnableFailure(_ message: String?) {
        appState.statusMessage = message
        DispatchQueue.main.async { [weak self] in
            self?.appState.isEnabled = false
        }
    }

    // MARK: - Enable / Disable

    func enableEQMode(realOutputDeviceID: AudioDeviceID) throws {
        guard !isActive else {
            os_log("enable: already active, ignoring", log: Self.log, type: .info)
            return
        }
        guard let blackHole = AudioDeviceManager.findBlackHoleDevice() else {
            throw EQEngineError.blackHoleNotFound
        }

        captureOriginalOutputDevice(blackHoleID: blackHole.id, fallbackID: realOutputDeviceID)

        guard AudioDeviceManager.setDefaultOutputDevice(blackHole.id) else {
            savedOriginalOutputDeviceUID = nil
            appState.originalOutputDeviceUID = nil
            throw EQEngineError.deviceBindingFailed("could not set default output to BlackHole")
        }

        isActive = true
        do {
            ringBuffer.reset()
            try startEngineA(blackHoleDeviceID: blackHole.id)
            try startEngineB(realOutputDeviceID: realOutputDeviceID)
            startDrainTimer()
        } catch {
            // The default output is already pointing at BlackHole at this point. Leaving it
            // there means total system silence with no UI affordance to escape, so unwind
            // fully before propagating the failure.
            disableEQMode()
            throw error
        }
        os_log("enable: engines running (A=%{public}@ B=%{public}@)", log: Self.log, type: .info,
               String(engineA.isRunning), String(engineB.isRunning))
    }

    /// Records the device to restore on disable — never BlackHole itself. If BlackHole is
    /// already the default (a previous run exited uncleanly, or an enable ran without an
    /// intervening disable) then saving it would make restore a permanent no-op, stranding
    /// the user on a silent virtual device. Fall back to the device they picked in the UI.
    private func captureOriginalOutputDevice(blackHoleID: AudioDeviceID, fallbackID: AudioDeviceID) {
        let current = AudioDeviceManager.getDefaultOutputDevice()
        let candidate = (current == nil || current == blackHoleID) ? fallbackID : current!

        guard candidate != blackHoleID, let info = AudioDeviceManager.info(for: candidate) else {
            os_log("enable: no sane device to restore to (current=%u fallback=%u)",
                   log: Self.log, type: .error, current ?? 0, fallbackID)
            savedOriginalOutputDeviceUID = nil
            appState.originalOutputDeviceUID = nil
            return
        }

        savedOriginalOutputDeviceUID = info.uid
        appState.originalOutputDeviceUID = info.uid
        os_log("enable: saved original output = %{public}@ (%{public}@)",
               log: Self.log, type: .info, info.name, info.uid)
    }

    func disableEQMode() {
        stopDrainTimer()

        // Unconditional: engineA.isRunning is false after a self-stop or a failed start, but
        // the tap can still be installed. Missing it here crashes the next enable.
        removeCaptureTap()
        if engineA.isRunning { engineA.stop() }
        if engineB.isRunning {
            playerNode.stop()
            engineB.stop()
        }
        converter = nil
        isActive = false

        restoreOriginalOutputDevice()
    }

    private func restoreOriginalOutputDevice() {
        guard let uid = savedOriginalOutputDeviceUID ?? appState.originalOutputDeviceUID else {
            os_log("disable: engines stopped, no saved device to restore", log: Self.log, type: .info)
            return
        }
        defer {
            savedOriginalOutputDeviceUID = nil
            appState.originalOutputDeviceUID = nil
        }
        guard let device = AudioDeviceManager.device(forUID: uid) else {
            os_log("disable: saved device %{public}@ no longer present, cannot restore",
                   log: Self.log, type: .error, uid)
            appState.statusMessage = "Original output device is gone — pick one in System Settings."
            return
        }
        if AudioDeviceManager.setDefaultOutputDevice(device.id) {
            os_log("disable: engines stopped, output restored to %{public}@",
                   log: Self.log, type: .info, device.name)
        } else {
            os_log("disable: FAILED to restore output to %{public}@", log: Self.log, type: .error, device.name)
            appState.statusMessage = "Could not restore \(device.name) — set it in System Settings."
        }
    }

    private func removeCaptureTap() {
        guard tapInstalled else { return }
        engineA.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    // MARK: - Engine A (capture from BlackHole)

    private func startEngineA(blackHoleDeviceID: AudioDeviceID) throws {
        removeCaptureTap()
        if engineA.isRunning { engineA.stop() }

        let input = engineA.inputNode
        try setCurrentDevice(blackHoleDeviceID, on: input.audioUnit)

        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw EQEngineError.deviceBindingFailed("BlackHole input format unavailable")
        }

        converter = AVAudioConverter(from: inputFormat, to: bridgeFormat)

        engineA.connect(input, to: engineA.mainMixerNode, format: inputFormat)
        engineA.mainMixerNode.outputVolume = 0

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }
        tapInstalled = true

        engineA.prepare()
        try engineA.start()
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
        if engineB.isRunning {
            playerNode.stop()
            engineB.stop()
        }

        try setCurrentDevice(realOutputDeviceID, on: engineB.outputNode.audioUnit)
        reconnectMainMixerToOutput()

        engineB.prepare()
        try engineB.start()
        playerNode.play()
        applyGains(appState.bandGains)
    }

    /// The mainMixerNode -> outputNode connection is created implicitly the first time
    /// mainMixerNode is touched (in init), and it caches the format of whichever device was
    /// default at that moment. Repointing the output AU at another device does NOT refresh it,
    /// so after a device switch the cached format can disagree with the hardware's sample rate
    /// or channel count — which makes start() fail or plays back at the wrong rate. Rebuild
    /// the connection against the device that is actually bound now.
    private func reconnectMainMixerToOutput() {
        let outputFormat = engineB.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            os_log("reconnect: output format unavailable, keeping existing connection",
                   log: Self.log, type: .error)
            return
        }
        engineB.disconnectNodeOutput(engineB.mainMixerNode)
        engineB.connect(engineB.mainMixerNode, to: engineB.outputNode, format: outputFormat)
    }

    private func switchRealOutputDevice(to deviceID: AudioDeviceID) {
        guard isActive else { return }
        do {
            // Goes through startEngineB so the mixer reconnect above is never skipped.
            try startEngineB(realOutputDeviceID: deviceID)
        } catch {
            os_log("switchRealOutputDevice failed: %{public}@", log: Self.log, type: .error, String(describing: error))
            appState.statusMessage = "Failed to switch output device: \(error.localizedDescription)"
        }
    }

    private func configureEQBands(gains: [Float]) {
        for (index, definition) in EQBands.definitions.enumerated() {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = Float(definition.frequency)
            band.bandwidth = EQBands.bandwidth
            band.gain = gains[index]
            band.bypass = false
        }
        eqNode.globalGain = 0
    }

    private func applyGains(_ gains: [Float]) {
        guard gains.count == eqNode.bands.count else { return }
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
        guard engineB.isRunning else { return }
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

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
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
