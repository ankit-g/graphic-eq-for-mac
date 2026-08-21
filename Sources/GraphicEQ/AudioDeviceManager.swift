import Foundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

enum AudioDeviceManager {

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    // MARK: - Enumeration

    static func allDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { info(for: $0) }
    }

    static func info(for deviceID: AudioDeviceID) -> AudioDeviceInfo? {
        guard let name = deviceName(deviceID), let uid = deviceUID(deviceID) else { return nil }
        let hasOutput = channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput) > 0
        let hasInput = channelCount(deviceID, scope: kAudioObjectPropertyScopeInput) > 0
        return AudioDeviceInfo(id: deviceID, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput)
    }

    static func outputCapableDevices(excludingNameSubstring excluded: String = "BlackHole") -> [AudioDeviceInfo] {
        allDevices().filter { $0.hasOutput && !$0.name.localizedCaseInsensitiveContains(excluded) }
    }

    static func findBlackHoleDevice() -> AudioDeviceInfo? {
        allDevices().first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
    }

    static func device(forUID uid: String) -> AudioDeviceInfo? {
        allDevices().first { $0.uid == uid }
    }

    // MARK: - Per-device property helpers

    private static func deviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return name as String
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { ptr -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return uid as String
    }

    private static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferListPtr.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPtr)
        guard status == noErr else { return 0 }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Default output device

    static func getDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr else { return nil }
        return deviceID
    }

    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &mutableDeviceID)
        return status == noErr
    }
}
