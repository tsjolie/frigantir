import AudioToolbox
import CoreMedia
import Foundation

/// Incremental demuxer for fragmented MP4 (ISO BMFF), the container go2rtc sends
/// over its MSE WebSocket and its `stream.mp4` endpoint.
///
/// Feed it bytes as they arrive with `append(_:)`. It turns the init segment
/// (`ftyp` + `moov`) into Core Media format descriptions, and each media fragment
/// (`moof` + `mdat`) into `CMSampleBuffer`s ready for `AVSampleBufferDisplayLayer`
/// / `AVSampleBufferAudioRenderer`. No decoding happens here: the compressed
/// H.264/HEVC/AAC samples are handed to the system, which decodes them on the
/// hardware media engine.
///
/// Each `mdat` payload is copied once into a `CMBlockBuffer`; individual samples
/// reference ranges of that buffer instead of being copied again.
nonisolated final class FMP4Demuxer {
    enum Output {
        case initialized(video: CMVideoFormatDescription?, audio: CMAudioFormatDescription?)
        case video(CMSampleBuffer)
        case audio(CMSampleBuffer)
    }

    enum DemuxError: Error, Equatable {
        case malformed(String)
        case unsupportedCodec(String)
        case coreMedia(OSStatus)
    }

    enum TrackKind { case video, audio }

    struct Track {
        let id: UInt32
        let kind: TrackKind
        let timescale: UInt32
        let formatDescription: CMFormatDescription
        var defaultDuration: UInt32 = 0
        var defaultSize: UInt32 = 0
        var defaultFlags: UInt32 = 0
    }

    private(set) var tracks: [UInt32: Track] = [:]
    private var buffer = Data()
    private var pendingMoof: Data?

    /// Drop all state, e.g. before reconnecting to a (possibly different) stream.
    func reset() {
        tracks = [:]
        buffer = Data()
        pendingMoof = nil
    }

    /// Appends bytes from the network and returns everything that could be
    /// demuxed so far. Partial boxes are kept until the rest arrives.
    func append(_ data: Data) throws -> [Output] {
        buffer.append(data)
        var outputs: [Output] = []
        var consumed = 0

        while let box = Self.nextBox(in: buffer, at: consumed) {
            consumed += box.totalSize
            switch box.type {
            case "moov":
                try parseMoov(box.payload)
                let video = tracks.values.first { $0.kind == .video }?.formatDescription
                let audio = tracks.values.first { $0.kind == .audio }?.formatDescription
                outputs.append(.initialized(video: video, audio: audio))
            case "moof":
                pendingMoof = buffer.subdata(in: buffer.startIndex + consumed - box.totalSize ..< buffer.startIndex + consumed)
            case "mdat":
                guard let moof = pendingMoof else { continue }
                pendingMoof = nil
                outputs += try parseFragment(moof: moof, mdatPayload: box.payload, mdatHeaderSize: box.headerSize)
            default:
                continue // ftyp, styp, sidx, free, ...
            }
        }

        if consumed > 0 {
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + consumed)
        }
        return outputs
    }

    // MARK: - Box framing

    struct Box {
        let type: String
        let headerSize: Int
        let totalSize: Int
        let payload: Data
    }

    /// Returns the complete box starting at `offset`, or nil if more bytes are needed.
    static func nextBox(in data: Data, at offset: Int) -> Box? {
        var reader = ByteReader(data, offset: offset)
        guard reader.remaining >= 8,
              let size32 = reader.uint32(), let type = reader.fourCC() else { return nil }
        var headerSize = 8
        var totalSize = Int(size32)
        if size32 == 1 {
            guard let large = reader.uint64() else { return nil }
            headerSize = 16
            totalSize = Int(large)
        } else if size32 == 0 {
            totalSize = data.count - offset // box extends to end of data
        }
        guard totalSize >= headerSize, data.count - offset >= totalSize else { return nil }
        let start = data.startIndex + offset
        let payload = data.subdata(in: start + headerSize ..< start + totalSize)
        return Box(type: type, headerSize: headerSize, totalSize: totalSize, payload: payload)
    }

    static func children(of payload: Data, from offset: Int = 0) -> [Box] {
        var boxes: [Box] = []
        var position = offset
        while let box = nextBox(in: payload, at: position) {
            boxes.append(box)
            position += box.totalSize
        }
        return boxes
    }

    static func child(_ type: String, in payload: Data, from offset: Int = 0) -> Box? {
        children(of: payload, from: offset).first { $0.type == type }
    }

    // MARK: - Init segment

    private func parseMoov(_ moov: Data) throws {
        tracks = [:]
        for box in Self.children(of: moov) where box.type == "trak" {
            if let track = try parseTrak(box.payload) {
                tracks[track.id] = track
            }
        }
        // Per-track sample defaults used when a fragment omits them.
        if let mvex = Self.child("mvex", in: moov) {
            for trex in Self.children(of: mvex.payload) where trex.type == "trex" {
                var r = ByteReader(trex.payload)
                r.skip(4) // version + flags
                guard let id = r.uint32(), r.skip(4), // default_sample_description_index
                      let duration = r.uint32(), let size = r.uint32(), let flags = r.uint32(),
                      var track = tracks[id] else { continue }
                track.defaultDuration = duration
                track.defaultSize = size
                track.defaultFlags = flags
                tracks[id] = track
            }
        }
        if tracks.isEmpty { throw DemuxError.malformed("moov has no supported tracks") }
    }

    private func parseTrak(_ trak: Data) throws -> Track? {
        guard let tkhd = Self.child("tkhd", in: trak),
              let mdia = Self.child("mdia", in: trak),
              let mdhd = Self.child("mdhd", in: mdia.payload),
              let hdlr = Self.child("hdlr", in: mdia.payload),
              let minf = Self.child("minf", in: mdia.payload),
              let stbl = Self.child("stbl", in: minf.payload),
              let stsd = Self.child("stsd", in: stbl.payload)
        else { throw DemuxError.malformed("incomplete trak") }

        var r = ByteReader(tkhd.payload)
        let tkhdVersion = r.uint8() ?? 0
        r.skip(3 + (tkhdVersion == 1 ? 16 : 8))
        guard let trackID = r.uint32() else { throw DemuxError.malformed("tkhd") }

        r = ByteReader(mdhd.payload)
        let mdhdVersion = r.uint8() ?? 0
        r.skip(3 + (mdhdVersion == 1 ? 16 : 8))
        guard let timescale = r.uint32(), timescale > 0 else { throw DemuxError.malformed("mdhd") }

        r = ByteReader(hdlr.payload)
        r.skip(8)
        let handler = r.fourCC()

        // stsd: version/flags(4) + entry_count(4), then the sample entries.
        guard let entry = Self.nextBox(in: stsd.payload, at: 8) else { throw DemuxError.malformed("stsd") }

        switch handler {
        case "vide":
            let format = try Self.videoFormat(entry)
            return Track(id: trackID, kind: .video, timescale: timescale, formatDescription: format)
        case "soun":
            let format = try Self.audioFormat(entry)
            return Track(id: trackID, kind: .audio, timescale: timescale, formatDescription: format)
        default:
            return nil
        }
    }

    /// Builds a video format description by handing the codec config box
    /// (`avcC` / `hvcC`) straight to Core Media, which is what AVFoundation does
    /// when it reads an MP4 file.
    static func videoFormat(_ entry: Box) throws -> CMVideoFormatDescription {
        let codec: CMVideoCodecType
        let configType: String
        switch entry.type {
        case "avc1": codec = kCMVideoCodecType_H264; configType = "avcC"
        case "hvc1": codec = kCMVideoCodecType_HEVC; configType = "hvcC"
        default: throw DemuxError.unsupportedCodec(entry.type)
        }
        // VisualSampleEntry: 8 bytes SampleEntry + 70 bytes of fields; width/height at 24.
        var r = ByteReader(entry.payload, offset: 24)
        guard let width = r.uint16(), let height = r.uint16(),
              let config = child(configType, in: entry.payload, from: 78)
        else { throw DemuxError.malformed("\(entry.type) sample entry") }

        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [configType: config.payload],
        ]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codec,
            width: Int32(width), height: Int32(height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw DemuxError.coreMedia(status) }
        return format
    }

    static func audioFormat(_ entry: Box) throws -> CMAudioFormatDescription {
        guard entry.type == "mp4a" else { throw DemuxError.unsupportedCodec(entry.type) }
        // AudioSampleEntry (version 0): 8 bytes SampleEntry + 20 bytes of fields.
        guard let esds = child("esds", in: entry.payload, from: 28) else {
            throw DemuxError.malformed("mp4a without esds")
        }
        let esDescriptor = esds.payload.subdata(in: esds.payload.startIndex + 4 ..< esds.payload.endIndex)
        guard let asc = decoderSpecificInfo(inESDescriptor: esDescriptor),
              let config = AudioSpecificConfig(asc) else {
            throw DemuxError.malformed("esds without AudioSpecificConfig")
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: config.sampleRate,
            mFormatID: config.objectType == 5 ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: config.channels, mBitsPerChannel: 0, mReserved: 0)

        // The magic cookie for AAC-in-MP4 is the ES_Descriptor (esds minus its
        // version/flags); Audio Toolbox reads the AudioSpecificConfig out of it.
        var format: CMAudioFormatDescription?
        let status = esDescriptor.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: cookie.baseAddress,
                extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw DemuxError.coreMedia(status) }
        return format
    }

    /// Walks ES_Descriptor (tag 3) → DecoderConfigDescriptor (tag 4) →
    /// DecoderSpecificInfo (tag 5) and returns the latter's bytes.
    static func decoderSpecificInfo(inESDescriptor data: Data) -> Data? {
        var r = ByteReader(data)
        func header() -> (tag: UInt8, size: Int)? {
            guard let tag = r.uint8() else { return nil }
            var size = 0
            for _ in 0 ..< 4 {
                guard let byte = r.uint8() else { return nil }
                size = (size << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            return (tag, size)
        }
        guard let es = header(), es.tag == 0x03 else { return nil }
        r.skip(2) // ES_ID
        guard let flags = r.uint8() else { return nil }
        if flags & 0x80 != 0 { r.skip(2) } // dependsOn_ES_ID
        if flags & 0x40 != 0 { r.skip(Int(r.uint8() ?? 0)) } // URL
        if flags & 0x20 != 0 { r.skip(2) } // OCR_ES_ID
        guard let dc = header(), dc.tag == 0x04 else { return nil }
        r.skip(13) // objectType, streamType, bufferSize, max/avg bitrate
        guard let dsi = header(), dsi.tag == 0x05 else { return nil }
        return r.bytes(dsi.size)
    }

    struct AudioSpecificConfig {
        static let sampleRates: [Float64] = [96000, 88200, 64000, 48000, 44100, 32000,
                                             24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let objectType: UInt32
        let sampleRate: Float64
        let channels: UInt32

        init?(_ data: Data) {
            var bits = BitReader(data)
            guard var objectType = bits.read(5) else { return nil }
            if objectType == 31 { objectType = 32 + (bits.read(6) ?? 0) }
            guard let index = bits.read(4) else { return nil }
            if index == 15 {
                guard let explicitRate = bits.read(24) else { return nil }
                sampleRate = Float64(explicitRate)
            } else {
                guard Int(index) < Self.sampleRates.count else { return nil }
                sampleRate = Self.sampleRates[Int(index)]
            }
            guard let channelConfig = bits.read(4) else { return nil }
            self.objectType = objectType
            self.channels = channelConfig == 7 ? 8 : max(channelConfig, 1)
        }
    }

    // MARK: - Media fragments

    private struct Sample {
        var offset: Int // relative to the mdat payload
        var size: Int
        var decodeTime: Int64
        var duration: UInt32
        var compositionOffset: Int32
        var isSync: Bool
    }

    private func parseFragment(moof: Data, mdatPayload: Data, mdatHeaderSize: Int) throws -> [Output] {
        let moofPayload = moof.subdata(in: moof.startIndex + 8 ..< moof.endIndex)
        // trun data offsets are relative to the first byte of the moof box
        // (default-base-is-moof, which go2rtc and ffmpeg both use).
        let mdatPayloadStart = moof.count + mdatHeaderSize
        let block = try Self.makeBlockBuffer(copying: mdatPayload)
        var outputs: [Output] = []

        for traf in Self.children(of: moofPayload) where traf.type == "traf" {
            guard let tfhd = Self.child("tfhd", in: traf.payload) else { continue }
            var r = ByteReader(tfhd.payload)
            r.skip(1)
            let tfhdFlags = r.uint24() ?? 0
            guard let trackID = r.uint32(), let track = tracks[trackID] else { continue }
            if tfhdFlags & 0x01 != 0 { r.skip(8) } // base_data_offset (absolute; unused by go2rtc)
            if tfhdFlags & 0x02 != 0 { r.skip(4) } // sample_description_index
            let defaultDuration = tfhdFlags & 0x08 != 0 ? r.uint32() ?? 0 : track.defaultDuration
            let defaultSize = tfhdFlags & 0x10 != 0 ? r.uint32() ?? 0 : track.defaultSize
            let defaultFlags = tfhdFlags & 0x20 != 0 ? r.uint32() ?? 0 : track.defaultFlags

            var decodeTime: Int64 = 0
            if let tfdt = Self.child("tfdt", in: traf.payload) {
                var t = ByteReader(tfdt.payload)
                let version = t.uint8() ?? 0
                t.skip(3)
                decodeTime = Int64(version == 1 ? t.uint64() ?? 0 : UInt64(t.uint32() ?? 0))
            }

            var samples: [Sample] = []
            var nextDataOffset = mdatPayloadStart
            for trun in Self.children(of: traf.payload) where trun.type == "trun" {
                var t = ByteReader(trun.payload)
                t.skip(1)
                let flags = t.uint24() ?? 0
                guard let count = t.uint32() else { throw DemuxError.malformed("trun") }
                if flags & 0x001 != 0 { nextDataOffset = Int(Int32(bitPattern: t.uint32() ?? 0)) }
                let firstFlags = flags & 0x004 != 0 ? t.uint32() : nil

                for index in 0 ..< Int(count) {
                    let duration = flags & 0x100 != 0 ? t.uint32() ?? 0 : defaultDuration
                    let size = flags & 0x200 != 0 ? t.uint32() ?? 0 : defaultSize
                    var sampleFlags = flags & 0x400 != 0 ? t.uint32() ?? 0 : defaultFlags
                    if index == 0, let firstFlags { sampleFlags = firstFlags }
                    let cto = flags & 0x800 != 0 ? Int32(bitPattern: t.uint32() ?? 0) : 0

                    let offset = nextDataOffset - mdatPayloadStart
                    guard offset >= 0, offset + Int(size) <= mdatPayload.count else {
                        throw DemuxError.malformed("sample outside mdat")
                    }
                    samples.append(Sample(
                        offset: offset, size: Int(size), decodeTime: decodeTime,
                        duration: duration, compositionOffset: cto,
                        isSync: sampleFlags & 0x0001_0000 == 0)) // sample_is_non_sync_sample
                    nextDataOffset += Int(size)
                    decodeTime += Int64(duration)
                }
            }
            guard !samples.isEmpty else { continue }

            switch track.kind {
            case .video:
                for sample in samples {
                    outputs.append(.video(try Self.makeVideoSample(sample, track: track, block: block)))
                }
            case .audio:
                outputs.append(.audio(try Self.makeAudioSample(samples, track: track, block: block)))
            }
        }
        return outputs
    }

    private static func makeVideoSample(_ sample: Sample, track: Track, block: CMBlockBuffer) throws -> CMSampleBuffer {
        let data = try referenceBlock(block, offset: sample.offset, length: sample.size)
        let scale = CMTimeScale(track.timescale)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(sample.duration), timescale: scale),
            presentationTimeStamp: CMTime(value: sample.decodeTime + Int64(sample.compositionOffset), timescale: scale),
            decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: scale))
        var size = sample.size
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: track.formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw DemuxError.coreMedia(status) }

        if !sample.isSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_NotSync] = true
        }
        return buffer
    }

    /// Packs one run of AAC packets into a single sample buffer. Audio packets in
    /// a `trun` are contiguous in the `mdat`, so one block reference covers them.
    private static func makeAudioSample(_ samples: [Sample], track: Track, block: CMBlockBuffer) throws -> CMSampleBuffer {
        let start = samples[0].offset
        let length = samples.last!.offset + samples.last!.size - start
        let data = try referenceBlock(block, offset: start, length: length)
        var packets = samples.map {
            AudioStreamPacketDescription(mStartOffset: Int64($0.offset - start),
                                         mVariableFramesInPacket: 0,
                                         mDataByteSize: UInt32($0.size))
        }
        let pts = CMTime(value: samples[0].decodeTime, timescale: CMTimeScale(track.timescale))
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: data, formatDescription: track.formatDescription,
            sampleCount: packets.count, presentationTimeStamp: pts,
            packetDescriptions: &packets, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw DemuxError.coreMedia(status) }
        return buffer
    }

    private static func makeBlockBuffer(copying data: Data) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw DemuxError.coreMedia(status) }
        status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw DemuxError.coreMedia(status) }
        return block
    }

    private static func referenceBlock(_ block: CMBlockBuffer, offset: Int, length: Int) throws -> CMBlockBuffer {
        var reference: CMBlockBuffer?
        let status = CMBlockBufferCreateWithBufferReference(
            allocator: kCFAllocatorDefault, referenceBuffer: block, offsetToData: offset,
            dataLength: length, flags: 0, blockBufferOut: &reference)
        guard status == noErr, let reference else { throw DemuxError.coreMedia(status) }
        return reference
    }
}

// MARK: - Readers

/// Big-endian reader over `Data` that is safe with slices (non-zero startIndex).
nonisolated struct ByteReader {
    private let data: Data
    private(set) var position: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.position = offset
    }

    var remaining: Int { data.count - position }

    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { position = data.count; return false }
        position += count
        return true
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        let start = data.startIndex + position
        position += count
        return data.subdata(in: start ..< start + count)
    }

    private mutating func integer(_ byteCount: Int) -> UInt64? {
        guard remaining >= byteCount else { return nil }
        var value: UInt64 = 0
        for i in 0 ..< byteCount {
            value = (value << 8) | UInt64(data[data.startIndex + position + i])
        }
        position += byteCount
        return value
    }

    mutating func uint8() -> UInt8? { integer(1).map { UInt8($0) } }
    mutating func uint16() -> UInt16? { integer(2).map { UInt16($0) } }
    mutating func uint24() -> UInt32? { integer(3).map { UInt32($0) } }
    mutating func uint32() -> UInt32? { integer(4).map { UInt32($0) } }
    mutating func uint64() -> UInt64? { integer(8) }

    mutating func fourCC() -> String? {
        bytes(4).flatMap { String(data: $0, encoding: .isoLatin1) }
    }
}

nonisolated struct BitReader {
    private let bytes: [UInt8]
    private var bitPosition = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func read(_ count: Int) -> UInt32? {
        guard bitPosition + count <= bytes.count * 8 else { return nil }
        var value: UInt32 = 0
        for _ in 0 ..< count {
            let bit = (bytes[bitPosition / 8] >> (7 - UInt8(bitPosition % 8))) & 1
            value = (value << 1) | UInt32(bit)
            bitPosition += 1
        }
        return value
    }
}
