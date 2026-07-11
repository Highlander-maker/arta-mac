import Foundation

/// ARTA .pir binary impulse response files (format documented in the ARTA user
/// manual §4.6.1) and .frd ASCII frequency response files. Byte layout is
/// little-endian, matching the Windows originals, so files round-trip with real ARTA.
public struct PIRFile {
    public var version: UInt32 = 0x0101
    public var sampleRate: Int32
    public var samples: [Float]
    public var inputDevice: Int32 = 0        // 0 voltage probe, 1 mic, 2 accelerometer
    public var deviceSensitivity: Float = 1  // V/V or V/Pa
    public var measurementType: Int32 = 2    // 0 recorded, 1 single-channel IR, 2 dual-channel IR
    public var averagingType: Int32 = 0      // 0 time, 1 frequency
    public var numAverages: Int32 = 1
    public var antialiasFiltered: Int32 = 0
    public var generatorType: Int32 = 14     // SIG_TYPE_SWEEP_LOG
    public var peakLeft: Float = 0
    public var peakRight: Float = 0
    public var generatorSubtype: Int32 = 5   // sweep start freq (v1.9.6+)
    public var cursorPosition: Int32 = 0
    public var markerPosition: Int32 = -1
    public var infoText: String = ""

    public init(sampleRate: Int32, samples: [Float]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    // MARK: Encode

    public func encode() -> Data {
        var d = Data()
        d.append(contentsOf: [0x50, 0x49, 0x52, 0x00]) // 'P','I','R','\0'
        let info = infoText.data(using: .utf8) ?? Data()
        d.appendLE(version)
        d.appendLE(Int32(info.count))
        d.appendLE(Int32(0)) // reserved1
        d.appendLE(Int32(0)) // reserved2
        d.appendLE(Float(Double(sampleRate) / 1000.0)) // fskHz
        d.appendLE(sampleRate)
        d.appendLE(Int32(samples.count))
        d.appendLE(inputDevice)
        d.appendLE(deviceSensitivity)
        d.appendLE(measurementType)
        d.appendLE(averagingType)
        d.appendLE(numAverages)
        d.appendLE(antialiasFiltered)
        d.appendLE(generatorType)
        d.appendLE(peakLeft)
        d.appendLE(peakRight)
        d.appendLE(generatorSubtype)
        if version >= 0x0101 {
            d.appendLE(cursorPosition)
            d.appendLE(markerPosition)
        } else {
            d.appendLE(Float(0))
            d.appendLE(Float(0))
        }
        for s in samples { d.appendLE(s) }
        d.append(info)
        return d
    }

    public func write(to url: URL) throws {
        try encode().write(to: url)
    }

    // MARK: Decode

    public enum DecodeError: Error {
        case badSignature, truncated
    }

    public static func decode(_ data: Data) throws -> PIRFile {
        var r = LEReader(data: data)
        guard let sig = r.bytes(4), sig == [0x50, 0x49, 0x52, 0x00] else {
            throw DecodeError.badSignature
        }
        guard let version: UInt32 = r.read(),
              let infoSize: Int32 = r.read(),
              let _: Int32 = r.read(), // reserved1
              let _: Int32 = r.read(), // reserved2
              let _: Float = r.read(), // fskHz (derived)
              let sampleRate: Int32 = r.read(),
              let length: Int32 = r.read(),
              let inputDevice: Int32 = r.read(),
              let sensitivity: Float = r.read(),
              let measurementType: Int32 = r.read(),
              let avgType: Int32 = r.read(),
              let numAvg: Int32 = r.read(),
              let bFiltered: Int32 = r.read(),
              let genType: Int32 = r.read(),
              let peakL: Float = r.read(),
              let peakR: Float = r.read(),
              let genSubtype: Int32 = r.read()
        else { throw DecodeError.truncated }

        var cursor: Int32 = 0
        var marker: Int32 = -1
        if version >= 0x0101 {
            guard let c: Int32 = r.read(), let m: Int32 = r.read() else { throw DecodeError.truncated }
            cursor = c; marker = m
        } else {
            guard let _: Float = r.read(), let _: Float = r.read() else { throw DecodeError.truncated }
        }

        var samples = [Float](repeating: 0, count: Int(length))
        for i in 0..<Int(length) {
            guard let s: Float = r.read() else { throw DecodeError.truncated }
            samples[i] = s
        }
        let info = r.bytes(Int(infoSize)).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""

        var pir = PIRFile(sampleRate: sampleRate, samples: samples)
        pir.version = version
        pir.inputDevice = inputDevice
        pir.deviceSensitivity = sensitivity
        pir.measurementType = measurementType
        pir.averagingType = avgType
        pir.numAverages = numAvg
        pir.antialiasFiltered = bFiltered
        pir.generatorType = genType
        pir.peakLeft = peakL
        pir.peakRight = peakR
        pir.generatorSubtype = genSubtype
        pir.cursorPosition = cursor
        pir.markerPosition = marker
        pir.infoText = info
        return pir
    }

    public static func read(from url: URL) throws -> PIRFile {
        try decode(try Data(contentsOf: url))
    }
}

/// .frd ASCII frequency response: `frequency magnitude(dB) [phase(deg)]` lines,
/// `*` or `;` or `#` comments — the interchange format ARTA and most loudspeaker
/// tools share.
public enum FRDFile {
    public static func export(frequencies: [Double], magnitudesDB: [Float], phasesDegrees: [Float]? = nil) -> String {
        var out = "* Exported by ArtaDSP\n* Freq(Hz)\tMagn(dB)\(phasesDegrees != nil ? "\tPhase(deg)" : "")\n"
        for i in 0..<min(frequencies.count, magnitudesDB.count) {
            if let ph = phasesDegrees, i < ph.count {
                out += String(format: "%.4f\t%.4f\t%.4f\n", frequencies[i], magnitudesDB[i], ph[i])
            } else {
                out += String(format: "%.4f\t%.4f\n", frequencies[i], magnitudesDB[i])
            }
        }
        return out
    }

    public static func parse(_ text: String) -> (frequencies: [Double], magnitudesDB: [Float], phasesDegrees: [Float]) {
        var freqs: [Double] = []
        var mags: [Float] = []
        var phases: [Float] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !"*;#".contains(trimmed.first!) else { continue }
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            guard parts.count >= 2,
                  let f = Double(parts[0]), let m = Float(parts[1]) else { continue }
            freqs.append(f)
            mags.append(m)
            phases.append(parts.count >= 3 ? Float(parts[2]) ?? 0 : 0)
        }
        return (freqs, mags, phases)
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendLE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: Int32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: Float) { Swift.withUnsafeBytes(of: v.bitPattern.littleEndian) { append(contentsOf: $0) } }
}

private struct LEReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard offset + n <= data.count else { return nil }
        defer { offset += n }
        return [UInt8](data[data.startIndex + offset ..< data.startIndex + offset + n])
    }

    mutating func read<T: FixedWidthInteger>() -> T? {
        guard let b = bytes(MemoryLayout<T>.size) else { return nil }
        var v: T = 0
        for (i, byte) in b.enumerated() { v |= T(truncatingIfNeeded: UInt64(byte) << (8 * UInt64(i))) }
        return v
    }

    mutating func read() -> Float? {
        guard let raw: UInt32 = read() else { return nil }
        return Float(bitPattern: raw)
    }
}
