import Foundation

/// Thread-safe fixed-capacity circular buffer of interleaved Float samples, used to bridge
/// two independently-clocked AVAudioEngines (BlackHole capture vs. real hardware playback).
///
/// Bounds drift between the two clocks with simple watermark logic rather than a true
/// adaptive resampler: if the writer runs ahead, oldest frames are dropped once the high
/// watermark is crossed; if the reader runs ahead of available data, reads are padded with
/// silence instead of underrunning.
final class RingBuffer {
    private let channelCount: Int
    private let capacityFrames: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var availableFramesCount = 0
    private let lock = NSLock()

    private let highWatermarkFrames: Int

    init(capacityFrames: Int, channelCount: Int) {
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        self.storage = [Float](repeating: 0, count: capacityFrames * channelCount)
        self.highWatermarkFrames = Int(Double(capacityFrames) * 0.8)
    }

    var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return availableFramesCount
    }

    /// Clears all buffered audio and resets indices. Call when starting a fresh session
    /// (e.g. re-enabling after a disable) so stale samples from a prior session aren't played.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        writeIndex = 0
        availableFramesCount = 0
    }

    private var readIndexFrame: Int {
        let idx = writeIndex - availableFramesCount
        return ((idx % capacityFrames) + capacityFrames) % capacityFrames
    }

    /// Writes interleaved frames (frameCount * channelCount samples). Drops the oldest
    /// frames first if this write would push occupancy above the high watermark.
    func write(_ frames: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        lock.lock(); defer { lock.unlock() }

        var srcOffset = 0
        var framesToWrite = frameCount
        if framesToWrite > capacityFrames {
            srcOffset = (framesToWrite - capacityFrames) * channelCount
            framesToWrite = capacityFrames
        }

        if availableFramesCount + framesToWrite > highWatermarkFrames {
            let overflow = (availableFramesCount + framesToWrite) - highWatermarkFrames
            availableFramesCount = max(0, availableFramesCount - overflow)
        }

        for i in 0..<framesToWrite {
            let destFrame = (writeIndex + i) % capacityFrames
            for ch in 0..<channelCount {
                storage[destFrame * channelCount + ch] = frames[srcOffset + i * channelCount + ch]
            }
        }
        writeIndex = (writeIndex + framesToWrite) % capacityFrames
        availableFramesCount = min(capacityFrames, availableFramesCount + framesToWrite)
    }

    /// Reads up to frameCount interleaved frames into outBuffer. Any shortfall (buffer
    /// underrun) is padded with silence so the consumer always gets a full block.
    @discardableResult
    func read(into outBuffer: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        lock.lock(); defer { lock.unlock() }

        let framesToRead = min(frameCount, availableFramesCount)
        let startFrame = readIndexFrame
        for i in 0..<framesToRead {
            let srcFrame = (startFrame + i) % capacityFrames
            for ch in 0..<channelCount {
                outBuffer[i * channelCount + ch] = storage[srcFrame * channelCount + ch]
            }
        }
        if framesToRead < frameCount {
            let padCount = (frameCount - framesToRead) * channelCount
            (outBuffer + framesToRead * channelCount).update(repeating: 0, count: padCount)
        }
        availableFramesCount -= framesToRead
        return framesToRead
    }
}
