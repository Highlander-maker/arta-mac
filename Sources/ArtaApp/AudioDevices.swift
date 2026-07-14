import CoreAudio
import AVFoundation
import Foundation

/// Shared mic-permission gate: any engine that taps an input node calls this first.
func ensureMicrophonePermission() throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        let sema = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            sema.signal()
        }
        sema.wait()
        guard granted else { throw AudioError.message("Microphone permission was denied.") }
    default:
        throw AudioError.message(
            "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")
    }
}

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

    /// The device the node's AUHAL is currently bound to (on macOS this is the
    /// engine's private aggregate until a device is set explicitly).
    static func currentDeviceID(on node: AVAudioIONode) -> AudioDeviceID? {
        guard let unit = node.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
    }

    /// Set only when actually different — re-setting the shared AUHAL's device
    /// fails with kAudioUnitErr_InvalidPropertyValue and corrupts its state.
    static func ensureDevice(_ deviceID: AudioDeviceID, on node: AVAudioIONode, what: String) throws {
        if currentDeviceID(on: node) == deviceID { return }
        try setDevice(deviceID, on: node, what: what)
    }

    /// Set the input device, then wait (bounded) for the node's HARDWARE input
    /// format to adopt that device's real channel count, and return that format
    /// for tap installation. Two macOS gotchas are handled here:
    ///
    ///  1. Switching to a non-default device on the shared AUHAL is asynchronous,
    ///     so reading the format immediately after the set can catch a stale value.
    ///  2. Crucially, `node.outputFormat(forBus:0)` (the graph side) stays pinned
    ///     to a MONO downmix — verified: with a 2-in Scarlett set, inputFormat is
    ///     2 ch but outputFormat reports 1 ch. Installing a tap at the output
    ///     format silently drops every channel past the first, so a loop reference
    ///     on input 2 is invisible. The fix is to tap at `inputFormat(forBus:0)`
    ///     (the hardware side), which delivers all channels — confirmed 2-ch tap
    ///     buffers on the Scarlett.
    @discardableResult
    static func ensureInputDeviceSettled(
        _ deviceID: AudioDeviceID, on node: AVAudioIONode, what: String,
        timeout: TimeInterval = 0.5
    ) throws -> AVAudioFormat {
        try ensureDevice(deviceID, on: node, what: what)
        let expected = channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)
        var format = node.inputFormat(forBus: 0)
        if expected > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while Int(format.channelCount) != expected && Date() < deadline {
                usleep(10_000) // 10 ms
                format = node.inputFormat(forBus: 0)
            }
        }
        return format
    }
}
