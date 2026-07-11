import CoreAudio
import Foundation

// MARK: - Errors

enum SpikeError: Error, CustomStringConvertible {
    case coreAudio(OSStatus, String)
    case message(String)

    var description: String {
        switch self {
        case .coreAudio(let status, let what):
            return "Core Audio error \(status) while \(what)"
        case .message(let msg):
            return msg
        }
    }
}

// MARK: - Device info model

struct AudioDeviceInfo {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int
    /// Supported nominal sample-rate ranges (min, max). Discrete rates have min == max.
    let sampleRateRanges: [(Double, Double)]
    let nominalSampleRate: Double
    let isDefaultInput: Bool
    let isDefaultOutput: Bool

    var sampleRatesDescription: String {
        sampleRateRanges.map { lo, hi in
            lo == hi ? formatRate(lo) : "\(formatRate(lo))-\(formatRate(hi))"
        }.joined(separator: ", ")
    }

    private func formatRate(_ r: Double) -> String {
        r == r.rounded() ? String(Int(r)) : String(r)
    }
}

// MARK: - Core Audio property helpers

private func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func getProperty<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    defaultValue: T,
    what: String
) throws -> T {
    var addr = address(selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = defaultValue
    let status = withUnsafeMutableBytes(of: &value) { raw in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw.baseAddress!)
    }
    guard status == noErr else { throw SpikeError.coreAudio(status, what) }
    return value
}

private func getPropertyArray<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    what: String
) throws -> [T] {
    var addr = address(selector, scope: scope)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
    guard status == noErr else { throw SpikeError.coreAudio(status, "sizing \(what)") }
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { raw.deallocate() }
    status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw)
    guard status == noErr else { throw SpikeError.coreAudio(status, what) }
    let typed = raw.assumingMemoryBound(to: T.self)
    return Array(UnsafeBufferPointer(start: typed, count: count))
}

private func getStringProperty(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    what: String
) -> String {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value)
    guard status == noErr, let cf = value?.takeRetainedValue() else { return "?" }
    return cf as String
}

// MARK: - Device enumeration

enum DeviceCatalog {

    static func allDeviceIDs() throws -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { throw SpikeError.coreAudio(status, "sizing device list") }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw SpikeError.coreAudio(status, "reading device list") }
        return ids
    }

    static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        let selector = input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        let id: AudioDeviceID? = try? getProperty(
            AudioObjectID(kAudioObjectSystemObject), selector,
            defaultValue: AudioDeviceID(0), what: "reading default device")
        return (id == 0) ? nil : id
    }

    static func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw)
        guard status == noErr else { return 0 }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRateRanges(_ deviceID: AudioDeviceID) -> [(Double, Double)] {
        let ranges: [AudioValueRange] = (try? getPropertyArray(
            deviceID, kAudioDevicePropertyAvailableNominalSampleRates,
            what: "reading sample rates")) ?? []
        return ranges.map { ($0.mMinimum, $0.mMaximum) }
    }

    static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        (try? getProperty(deviceID, kAudioDevicePropertyNominalSampleRate,
                          defaultValue: 0.0, what: "reading nominal sample rate")) ?? 0
    }

    /// Device-reported latency components (frames) for one direction.
    struct ReportedLatency {
        let deviceLatency: UInt32
        let safetyOffset: UInt32
        let bufferFrameSize: UInt32
        var totalFrames: UInt32 { deviceLatency + safetyOffset + bufferFrameSize }
    }

    static func reportedLatency(_ deviceID: AudioDeviceID, input: Bool) -> ReportedLatency {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let latency: UInt32 = (try? getProperty(
            deviceID, kAudioDevicePropertyLatency, scope: scope,
            defaultValue: 0, what: "reading device latency")) ?? 0
        let safety: UInt32 = (try? getProperty(
            deviceID, kAudioDevicePropertySafetyOffset, scope: scope,
            defaultValue: 0, what: "reading safety offset")) ?? 0
        let bufferSize: UInt32 = (try? getProperty(
            deviceID, kAudioDevicePropertyBufferFrameSize,
            defaultValue: 0, what: "reading buffer frame size")) ?? 0
        return ReportedLatency(
            deviceLatency: latency, safetyOffset: safety, bufferFrameSize: bufferSize)
    }

    static func info(for deviceID: AudioDeviceID) -> AudioDeviceInfo {
        AudioDeviceInfo(
            id: deviceID,
            name: getStringProperty(deviceID, kAudioDevicePropertyDeviceNameCFString,
                                    what: "reading device name"),
            uid: getStringProperty(deviceID, kAudioDevicePropertyDeviceUID,
                                   what: "reading device UID"),
            inputChannels: channelCount(deviceID, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput),
            sampleRateRanges: sampleRateRanges(deviceID),
            nominalSampleRate: nominalSampleRate(deviceID),
            isDefaultInput: defaultDeviceID(input: true) == deviceID,
            isDefaultOutput: defaultDeviceID(input: false) == deviceID
        )
    }

    static func allDevices() throws -> [AudioDeviceInfo] {
        try allDeviceIDs().map { info(for: $0) }
    }

    static func printDeviceTable() throws {
        let devices = try allDevices()
        guard !devices.isEmpty else {
            print("No audio devices found.")
            return
        }
        print("Available Core Audio devices:")
        print("")
        for dev in devices {
            var tags: [String] = []
            if dev.isDefaultInput { tags.append("default input") }
            if dev.isDefaultOutput { tags.append("default output") }
            let tagStr = tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"
            print("  ID \(dev.id): \(dev.name)\(tagStr)")
            print("      in: \(dev.inputChannels) ch, out: \(dev.outputChannels) ch")
            print("      current rate: \(Int(dev.nominalSampleRate)) Hz, supported: \(dev.sampleRatesDescription)")
        }
        print("")
        print("Use these IDs with: arta-mac-spike measure --input-device <ID> --output-device <ID>")
    }
}
