import Accelerate
import Foundation

/// Complex FFT wrapper around vDSP. Power-of-two lengths only — all measurement
/// FFT sizes in the app are powers of two, matching ARTA's 4k–512k range.
public final class FFT {
    public let length: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    public init?(length: Int) {
        guard length >= 8, length & (length - 1) == 0 else { return nil }
        self.length = length
        self.log2n = vDSP_Length(length.trailingZeroBitCount)
        guard let s = vDSP_create_fftsetup(vDSP_Length(length.trailingZeroBitCount), FFTRadix(kFFTRadix2)) else {
            return nil
        }
        self.setup = s
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// In-place forward complex FFT.
    public func forward(_ re: inout [Float], _ im: inout [Float]) {
        transform(&re, &im, direction: FFTDirection(FFT_FORWARD))
    }

    /// In-place inverse complex FFT, scaled by 1/N so forward→inverse round-trips.
    public func inverse(_ re: inout [Float], _ im: inout [Float]) {
        transform(&re, &im, direction: FFTDirection(FFT_INVERSE))
        var scale = 1.0 / Float(length)
        vDSP_vsmul(re, 1, &scale, &re, 1, vDSP_Length(length))
        vDSP_vsmul(im, 1, &scale, &im, 1, vDSP_Length(length))
    }

    private func transform(_ re: inout [Float], _ im: inout [Float], direction: FFTDirection) {
        precondition(re.count == length && im.count == length, "buffer length must match FFT length")
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, direction)
            }
        }
    }

    public static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 8
        while p < n { p <<= 1 }
        return p
    }
}

// MARK: - Complex helpers (split re/im arrays)

enum ComplexOps {
    /// out = conj(a) * b, element-wise.
    static func conjugateMultiply(aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float])
        -> (re: [Float], im: [Float]) {
        let n = aRe.count
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        for i in 0..<n {
            re[i] = aRe[i] * bRe[i] + aIm[i] * bIm[i]
            im[i] = aRe[i] * bIm[i] - aIm[i] * bRe[i]
        }
        return (re, im)
    }

    /// out = a / b with regularization: a * conj(b) / (|b|^2 + eps)
    static func regularizedDivide(aRe: [Float], aIm: [Float], bRe: [Float], bIm: [Float], eps: Float)
        -> (re: [Float], im: [Float]) {
        let n = aRe.count
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let denom = bRe[i] * bRe[i] + bIm[i] * bIm[i] + eps
            re[i] = (aRe[i] * bRe[i] + aIm[i] * bIm[i]) / denom
            im[i] = (aIm[i] * bRe[i] - aRe[i] * bIm[i]) / denom
        }
        return (re, im)
    }

    static func magnitudeSquared(re: [Float], im: [Float]) -> [Float] {
        let n = re.count
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = re[i] * re[i] + im[i] * im[i] }
        return out
    }
}
