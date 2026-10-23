import Foundation

/// Announces the encoder's no-reordering contract to decoders. Without explicit
/// VUI restrictions, H.264 E.2.1 permits buffering up to the level's DPB limit.
/// This is only suitable for streams encoded with AllowFrameReordering=false.
enum H264SPS {
    struct Info {
        let profile: Int
        let referenceFrames: Int
        let pictureOrderCountType: Int
        let reorderFrames: Int?
        let decoderBuffers: Int?
    }

    private struct ParseFailure: LocalizedError {
        var errorDescription: String? { "Unsupported or malformed H.264 SPS." }
    }

    private struct Parsed {
        let header: UInt8
        let bits: [UInt8]
        let info: Info
        let vuiFlagPosition: Int
        let restrictionPosition: Int?
        let restrictionPrefix: [UInt8]?
    }

    private struct Reader {
        let bits: [UInt8]
        var offset = 0
        mutating func read(_ count: Int = 1) throws -> Int {
            guard count >= 0, count <= 32, offset + count <= bits.count else { throw ParseFailure() }
            var value = 0
            for bit in bits[offset..<(offset + count)] { value = (value << 1) | Int(bit) }
            offset += count
            return value
        }
        mutating func ue() throws -> Int {
            var zeroes = 0
            while try read() == 0 {
                zeroes += 1
                guard zeroes <= 30 else { throw ParseFailure() }
            }
            return (1 << zeroes) - 1 + (try read(zeroes))
        }
        mutating func se() throws -> Int {
            let code = try ue()
            return code % 2 == 0 ? -(code / 2) : (code + 1) / 2
        }
        mutating func scalingList(_ size: Int) throws {
            var last = 8
            var next = 8
            for _ in 0..<size {
                if next != 0 { next = (last + (try se()) + 256) % 256 }
                last = next == 0 ? last : next
            }
        }
        mutating func hrd() throws {
            let count = try ue()
            guard count <= 31 else { throw ParseFailure() }
            _ = try read(8)
            for _ in 0...count {
                _ = try ue(); _ = try ue(); _ = try read()
            }
            _ = try read(20)
        }
    }

    static func inspect(_ annexB: Data) throws -> Info { try parse(annexB).info }

    static func declaringNoReordering(_ annexB: Data) throws -> Data {
        let parsed = try parse(annexB)
        if parsed.info.reorderFrames == 0, parsed.info.decoderBuffers == max(1, parsed.info.referenceFrames) {
            return annexB
        }
        var bits: [UInt8]
        if let restriction = parsed.restrictionPosition {
            bits = Array(parsed.bits[..<restriction])
        } else {
            bits = Array(parsed.bits[..<parsed.vuiFlagPosition])
            bits.append(1) // vui_parameters_present_flag
            bits.append(contentsOf: Array(repeating: 0, count: 8))
        }
        bits.append(1) // bitstream_restriction_flag
        if let prefix = parsed.restrictionPrefix {
            bits.append(contentsOf: prefix)
        } else {
            bits.append(1) // motion_vectors_over_pic_boundaries_flag (inferred default)
            appendUE(2, to: &bits) // max_bytes_per_pic_denom (inferred default)
            appendUE(1, to: &bits) // max_bits_per_mb_denom (inferred default)
            appendUE(16, to: &bits) // default motion-vector bounds
            appendUE(16, to: &bits)
        }
        appendUE(0, to: &bits) // max_num_reorder_frames
        appendUE(max(1, parsed.info.referenceFrames), to: &bits)
        bits.append(1) // rbsp_stop_one_bit
        while bits.count % 8 != 0 { bits.append(0) }
        var rbsp: [UInt8] = []
        for offset in stride(from: 0, to: bits.count, by: 8) {
            var byte: UInt8 = 0
            for bit in bits[offset..<(offset + 8)] { byte = (byte << 1) | bit }
            rbsp.append(byte)
        }
        var result = Data([0, 0, 0, 1, parsed.header])
        var zeroes = 0
        for byte in rbsp {
            if zeroes >= 2 && byte <= 3 { result.append(3); zeroes = 0 }
            result.append(byte)
            zeroes = byte == 0 ? zeroes + 1 : 0
        }
        return result
    }

    private static func appendUE(_ value: Int, to bits: inout [UInt8]) {
        let code = value + 1
        let count = Int.bitWidth - code.leadingZeroBitCount
        bits.append(contentsOf: Array(repeating: 0, count: count - 1))
        for shift in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((code >> shift) & 1)) }
    }

    private static func parse(_ annexB: Data) throws -> Parsed {
        let bytes = Array(annexB)
        guard bytes.count >= 9, bytes.count <= 65536,
              Array(bytes.prefix(4)) == [0, 0, 0, 1], bytes[4] & 0x1f == 7,
              bytes[4] & 0x80 == 0 else { throw ParseFailure() }
        var rbsp: [UInt8] = []
        var zeroes = 0
        var index = 5
        while index < bytes.count {
            let byte = bytes[index]
            if zeroes >= 2 && byte == 3 {
                guard index + 1 < bytes.count, bytes[index + 1] <= 3 else { throw ParseFailure() }
                zeroes = 0
            } else {
                rbsp.append(byte)
                zeroes = byte == 0 ? zeroes + 1 : 0
            }
            index += 1
        }
        let bits = rbsp.flatMap { byte in (0..<8).reversed().map { UInt8((byte >> $0) & 1) } }
        var reader = Reader(bits: bits)
        let profile = try reader.read(8)
        guard [66, 77, 100].contains(profile) else { throw ParseFailure() }
        _ = try reader.read(8); _ = try reader.read(8); _ = try reader.ue()
        if profile == 100 {
            let chroma = try reader.ue()
            guard chroma <= 3 else { throw ParseFailure() }
            if chroma == 3 { _ = try reader.read() }
            _ = try reader.ue(); _ = try reader.ue(); _ = try reader.read()
            if try reader.read() == 1 {
                for entry in 0..<(chroma == 3 ? 12 : 8) {
                    if try reader.read() == 1 { try reader.scalingList(entry < 6 ? 16 : 64) }
                }
            }
        }
        _ = try reader.ue()
        let poc = try reader.ue()
        if poc == 0 { _ = try reader.ue() }
        else if poc == 1 {
            _ = try reader.read(); _ = try reader.se(); _ = try reader.se()
            let cycles = try reader.ue()
            guard cycles <= 255 else { throw ParseFailure() }
            for _ in 0..<cycles { _ = try reader.se() }
        } else if poc != 2 { throw ParseFailure() }
        let references = try reader.ue()
        guard references <= 16 else { throw ParseFailure() }
        _ = try reader.read(); _ = try reader.ue(); _ = try reader.ue()
        // Only the progressive frames produced by our encoder are supported.
        guard try reader.read() == 1 else { throw ParseFailure() }
        _ = try reader.read()
        if try reader.read() == 1 { for _ in 0..<4 { _ = try reader.ue() } }
        let vuiPosition = reader.offset
        var restrictionPosition: Int?
        var restrictionPrefix: [UInt8]?
        var reorder: Int?
        var buffers: Int?
        if try reader.read() == 1 {
            if try reader.read() == 1 {
                if try reader.read(8) == 255 { _ = try reader.read(32) }
            }
            if try reader.read() == 1 { _ = try reader.read() }
            if try reader.read() == 1 {
                _ = try reader.read(4)
                if try reader.read() == 1 { _ = try reader.read(24) }
            }
            if try reader.read() == 1 { _ = try reader.ue(); _ = try reader.ue() }
            if try reader.read() == 1 { _ = try reader.read(32); _ = try reader.read(32); _ = try reader.read() }
            let nalHRD = try reader.read()
            if nalHRD == 1 { try reader.hrd() }
            let vclHRD = try reader.read()
            if vclHRD == 1 { try reader.hrd() }
            if nalHRD == 1 || vclHRD == 1 { _ = try reader.read() }
            _ = try reader.read()
            restrictionPosition = reader.offset
            if try reader.read() == 1 {
                let prefixStart = reader.offset
                _ = try reader.read()
                for _ in 0..<4 { _ = try reader.ue() }
                restrictionPrefix = Array(bits[prefixStart..<reader.offset])
                reorder = try reader.ue()
                buffers = try reader.ue()
                guard let reorder, let buffers, reorder <= buffers, buffers <= 16, buffers >= references else { throw ParseFailure() }
            }
        }
        // No extensions follow VUI for the supported SPS profiles. Validate the
        // trailing stop bit and zero padding before replacing any bytes.
        guard try reader.read() == 1 else { throw ParseFailure() }
        while reader.offset < bits.count { guard try reader.read() == 0 else { throw ParseFailure() } }
        return Parsed(header: bytes[4], bits: bits,
            info: Info(profile: profile, referenceFrames: references, pictureOrderCountType: poc,
                reorderFrames: reorder, decoderBuffers: buffers),
            vuiFlagPosition: vuiPosition, restrictionPosition: restrictionPosition,
            restrictionPrefix: restrictionPrefix)
    }
}
