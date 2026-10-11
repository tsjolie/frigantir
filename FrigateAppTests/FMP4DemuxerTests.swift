import CoreMedia
import Foundation
import Testing
@testable import FrigateApp

private final class BundleToken {}

@Suite struct FMP4DemuxerTests {
    /// 2 s test pattern + 440 Hz tone, muxed like go2rtc (see scripts/make-fixture.sh).
    static var fixture: Data {
        get throws {
            let url = try #require(Bundle(for: BundleToken.self).url(forResource: "test-pattern-h264-aac",
                                                                     withExtension: "mp4"))
            return try Data(contentsOf: url)
        }
    }

    struct Demuxed {
        var video: CMVideoFormatDescription?
        var audio: CMAudioFormatDescription?
        var videoSamples: [CMSampleBuffer] = []
        var audioSamples: [CMSampleBuffer] = []
    }

    static func demux(_ data: Data, chunkSize: Int? = nil) throws -> Demuxed {
        let demuxer = FMP4Demuxer()
        var result = Demuxed()
        var outputs: [FMP4Demuxer.Output] = []
        if let chunkSize {
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                outputs += try demuxer.append(data.subdata(in: offset ..< end))
                offset = end
            }
        } else {
            outputs = try demuxer.append(data)
        }
        for output in outputs {
            switch output {
            case .initialized(let video, let audio): result.video = video; result.audio = audio
            case .video(let sample): result.videoSamples.append(sample)
            case .audio(let sample): result.audioSamples.append(sample)
            }
        }
        return result
    }

    @Test func parsesInitSegment() throws {
        let result = try Self.demux(Self.fixture)
        let video = try #require(result.video)
        #expect(CMFormatDescriptionGetMediaSubType(video) == kCMVideoCodecType_H264)
        let size = CMVideoFormatDescriptionGetDimensions(video)
        #expect(size.width == 320 && size.height == 240)

        let audio = try #require(result.audio)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(audio)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mSampleRate == 16000)
        #expect(asbd.mChannelsPerFrame == 1)
    }

    @Test func producesTimedSamples() throws {
        let result = try Self.demux(Self.fixture)
        #expect(result.videoSamples.count == 30) // 2 s at 15 fps
        #expect(result.videoSamples.filter(\.isKeyframe).count == 2) // GOP of 15
        #expect(result.videoSamples.first?.isKeyframe == true)

        let pts = result.videoSamples.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
        #expect(pts == pts.sorted())
        #expect(abs(pts[1] - pts[0] - 1.0 / 15) < 0.001)

        let packets = result.audioSamples.map(CMSampleBufferGetNumSamples).reduce(0, +)
        #expect(packets >= 31) // ≈ 2 s of 1024-sample AAC frames at 16 kHz
    }

    /// WebSocket messages don't have to align with MP4 boxes.
    @Test(arguments: [1, 7, 1000, 4096])
    func handlesArbitraryChunking(chunkSize: Int) throws {
        let whole = try Self.demux(Self.fixture)
        let chunked = try Self.demux(Self.fixture, chunkSize: chunkSize)
        #expect(chunked.videoSamples.count == whole.videoSamples.count)
        #expect(chunked.audioSamples.count == whole.audioSamples.count)
    }

    @Test func waitsForCompleteBoxes() throws {
        let demuxer = FMP4Demuxer()
        #expect(try demuxer.append(Self.fixture.prefix(20)).isEmpty)
    }

    @Test func parsesAudioSpecificConfig() {
        // AAC-LC (2), 16 kHz (index 8), mono: 00010 1000 0001 000
        let config = FMP4Demuxer.AudioSpecificConfig(Data([0x14, 0x08]))
        #expect(config?.objectType == 2)
        #expect(config?.sampleRate == 16000)
        #expect(config?.channels == 1)
    }
}
