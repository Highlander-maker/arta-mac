import CoreAudio
import AVFoundation
import Foundation

enum AudioError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    case message(String)

    var description: String {
        switch self {
        case .coreAudio(let status, let what): return "Core Audio error \(status) while \(what)"
        case .message(let msg): return msg
        }
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double
    let isDefaultInput: Bool
    let isDefaultOutput: Bool

    var label: String { "\(name) (\(inputChannels) in / \(outputChannels) out)" }
}

enum AudioDevices {

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        let defIn = defaultDeviceID(input: true)
        let defOut = defaultDeviceID(input: false)
        return ids.map { id in
            AudioDevice(
                id: id,
                name: stringProperty(id, kAudioDevicePropertyDeviceNameCFString),
                inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                nominalSampleRate: nominalSampleRate(id),
                isDefaultInput: id == defIn,
                isDefaultOutput: id == defOut
            )
        }
    }

    static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var addr = address(input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (status == noErr && id != 0) ? id : nil
    }

    static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func stringProperty(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return "?" }
        return cf as String
    }

    static func setDevice(_ deviceID: AudioDeviceID, on node: AVAudioIONode, what: String) throws {
        guard let unit = node.audioUnit else {
            throw AudioError.message("No audio unit available on \(what) node.")
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw AudioError.coreAudio(status, "setting \(what) device to ID \(deviceID)")
        }
    }
}
