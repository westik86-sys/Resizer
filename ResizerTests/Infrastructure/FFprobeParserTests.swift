import Foundation
import Testing
@testable import Resizer

@Suite("FFprobe JSON parser")
struct FFprobeParserTests {
    private let parser = FFprobeParser()

    @Test("Full multistream output maps container, streams, HDR, and dispositions")
    func fullMultistream() throws {
        let info = try parseFixture("full-multistream")

        #expect(
            info.formatNames == ["mov", "mp4", "m4a", "3gp", "3g2", "mj2"]
        )
        #expect(info.durationMicroseconds == 12_345_678)
        #expect(info.byteCount == 24_681_357)
        #expect(info.bitRate == 8_000_000)
        #expect(info.streams.count == 6)
        #expect(info.streams.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(info.videoStreams.count == 2)
        #expect(info.audioStreams.count == 2)

        let primaryVideo = try requireVideo(info.streams[0])
        #expect(primaryVideo.codecName == "hevc")
        #expect(primaryVideo.encodedWidth == 3_840)
        #expect(primaryVideo.encodedHeight == 2_160)
        #expect(primaryVideo.frameRate?.numerator == 30_000)
        #expect(primaryVideo.frameRate?.denominator == 1_001)
        #expect(primaryVideo.rotationDegrees == -90)
        #expect(primaryVideo.pixelFormat == "yuv420p10le")
        #expect(primaryVideo.bitDepth == 10)
        #expect(primaryVideo.colorMetadata.primaries == "bt2020")
        #expect(primaryVideo.colorMetadata.transfer == "smpte2084")
        #expect(primaryVideo.colorMetadata.space == "bt2020nc")
        #expect(primaryVideo.colorMetadata.range == "tv")
        #expect(primaryVideo.dynamicRange == .hdr)
        #expect(primaryVideo.disposition.isDefault)
        #expect(!primaryVideo.disposition.isForced)
        #expect(!primaryVideo.disposition.isAttachedPicture)

        let englishAudio = try requireAudio(info.streams[1])
        #expect(englishAudio.codecName == "aac")
        #expect(englishAudio.sampleRate == 48_000)
        #expect(englishAudio.channelCount == 2)
        #expect(englishAudio.channelLayout == "stereo")
        #expect(englishAudio.bitRate == 192_000)
        #expect(englishAudio.languageCode == "eng")
        #expect(englishAudio.disposition.isDefault)

        let spanishAudio = try requireAudio(info.streams[2])
        #expect(spanishAudio.codecName == "ac3")
        #expect(spanishAudio.sampleRate == 48_000)
        #expect(spanishAudio.channelCount == 6)
        #expect(spanishAudio.channelLayout == "5.1(side)")
        #expect(spanishAudio.bitRate == 384_000)
        #expect(spanishAudio.languageCode == "spa")
        #expect(!spanishAudio.disposition.isDefault)

        let subtitle = try requireSubtitle(info.streams[3])
        #expect(subtitle.codecName == "mov_text")
        #expect(subtitle.languageCode == "fra")
        #expect(!subtitle.disposition.isDefault)
        #expect(subtitle.disposition.isForced)

        let dataStream = try requireOther(info.streams[4])
        #expect(dataStream.codecType == "data")
        #expect(dataStream.codecName == "tmcd")
        #expect(dataStream.disposition == .none)

        let coverArt = try requireVideo(info.streams[5])
        #expect(coverArt.codecName == "mjpeg")
        #expect(coverArt.encodedWidth == 600)
        #expect(coverArt.encodedHeight == 600)
        #expect(coverArt.frameRate == nil)
        #expect(coverArt.dynamicRange == .unknown)
        #expect(coverArt.disposition.isAttachedPicture)
    }

    @Test("Missing and unknown fields use conservative defaults")
    func missingAndUnknownFields() throws {
        let info = try parseFixture("minimal-unknown")

        #expect(info.formatNames.isEmpty)
        #expect(info.durationMicroseconds == nil)
        #expect(info.byteCount == 0)
        #expect(info.bitRate == nil)
        #expect(info.videoStreams.isEmpty)
        #expect(info.audioStreams.isEmpty)
        #expect(info.streams.count == 2)

        let telemetry = try requireOther(info.streams[0])
        #expect(telemetry.index == 0)
        #expect(telemetry.codecType == "telemetry")
        #expect(telemetry.codecName == nil)
        #expect(telemetry.disposition == .none)

        let unknown = try requireOther(info.streams[1])
        #expect(unknown.index == 1)
        #expect(unknown.codecType == nil)
        #expect(unknown.codecName == nil)
        #expect(unknown.disposition == .none)
    }

    @Test("Frame rate prefers valid average and falls back to real rational")
    func rationalFrameRateFallback() throws {
        let info = try parseFixture("rational-edge")
        let videos = info.videoStreams

        #expect(info.formatNames == ["matroska", "webm"])
        #expect(info.durationMicroseconds == nil)
        #expect(info.byteCount == 0)
        #expect(info.bitRate == nil)
        #expect(videos.count == 4)
        #expect(videos[0].frameRate?.numerator == 30_000)
        #expect(videos[0].frameRate?.denominator == 1_001)
        #expect(videos[1].frameRate?.numerator == 25)
        #expect(videos[1].frameRate?.denominator == 1)
        #expect(videos[2].frameRate?.numerator == 24_000)
        #expect(videos[2].frameRate?.denominator == 1_001)
        #expect(videos[3].frameRate == nil)
        #expect(videos.allSatisfy { $0.dynamicRange == .unknown })
        #expect(videos.allSatisfy { $0.disposition == .none })
    }

    @Test("Native JSON numbers, legacy rotation, and SDR metadata map correctly")
    func nativeNumbersLegacyRotationAndSDR() throws {
        let info = try parseFixture("legacy-rotation-sdr")

        #expect(info.durationMicroseconds == 5_250_000)
        #expect(info.byteCount == 4_096)
        #expect(info.bitRate == 6_241)
        #expect(info.audioStreams.isEmpty)

        let video = try requireVideo(try #require(info.streams.first))
        #expect(video.codecName == "h264")
        #expect(video.encodedWidth == 1_920)
        #expect(video.encodedHeight == 1_080)
        #expect(video.frameRate?.numerator == 30_000)
        #expect(video.frameRate?.denominator == 1_001)
        #expect(video.rotationDegrees == 90)
        #expect(video.pixelFormat == "yuv420p")
        #expect(video.bitDepth == 8)
        #expect(video.colorMetadata.primaries == "bt709")
        #expect(video.colorMetadata.transfer == "bt709")
        #expect(video.colorMetadata.space == "bt709")
        #expect(video.colorMetadata.range == "tv")
        #expect(video.dynamicRange == .sdr)
        #expect(video.disposition.isDefault)
    }

    @Test("Audio and subtitle only input is accepted without a video stream")
    func audioSubtitleOnly() throws {
        let info = try parseFixture("audio-subtitle-only")

        #expect(info.formatNames == ["matroska", "webm"])
        #expect(info.durationMicroseconds == 3_000_000)
        #expect(info.byteCount == 1_234)
        #expect(info.bitRate == 3_290)
        #expect(info.videoStreams.isEmpty)
        #expect(info.audioStreams.count == 1)

        let audio = try requireAudio(info.streams[0])
        #expect(audio.codecName == "aac")
        #expect(audio.sampleRate == 44_100)
        #expect(audio.channelCount == 2)
        #expect(audio.channelLayout == "stereo")
        #expect(audio.bitRate == 128_000)
        #expect(audio.languageCode == "jpn")
        #expect(audio.disposition.isDefault)

        let subtitle = try requireSubtitle(info.streams[1])
        #expect(subtitle.codecName == "ass")
        #expect(subtitle.languageCode == "eng")
        #expect(subtitle.disposition.isDefault)
    }

    @Test("Malformed JSON is reported separately from invalid metadata")
    func malformedJSON() throws {
        let data = try FFprobeFixture.data(named: "malformed")

        #expect(throws: FFprobeParsingError.malformedJSON) {
            try parser.parse(data)
        }
    }

    @Test(
        "Missing, negative, fractional, and duplicate stream indices are invalid",
        arguments: [
            #"{"streams":[{"codec_type":"video"}]}"#,
            #"{"streams":[{"index":"-1","codec_type":"audio"}]}"#,
            #"{"streams":[{"index":1.5,"codec_type":"subtitle"}]}"#,
            #"{"streams":[{"index":0},{"index":"0"}]}"#,
        ]
    )
    func invalidStreamIndices(json: String) {
        #expect(throws: FFprobeParsingError.invalidMetadata) {
            try parser.parse(Data(json.utf8))
        }
    }

    @Test(
        "Present corrupt numeric strings and numeric prefixes are invalid",
        arguments: [
            #"{"format":{"duration":"not-a-duration"}}"#,
            #"{"format":{"duration":"12.5seconds"}}"#,
            #"{"format":{"size":"bytes=4096"}}"#,
            #"{"format":{"bit_rate":"8000000bps"}}"#,
            #"{"streams":[{"index":0,"codec_type":"video","width":"1920px"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"video","height":"height=1080"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"video","bits_per_raw_sample":"10bit"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","sample_rate":"48000Hz"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","channels":"two"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","bit_rate":"128000bps"}]}"#,
        ]
    )
    func corruptNumericMetadata(json: String) {
        #expect(throws: FFprobeParsingError.invalidMetadata) {
            try parser.parse(Data(json.utf8))
        }
    }

    @Test(
        "Fractional values for integer metrics are invalid",
        arguments: [
            #"{"format":{"size":4096.5}}"#,
            #"{"format":{"bit_rate":"6241.5"}}"#,
            #"{"streams":[{"index":0,"codec_type":"video","width":1920.5}]}"#,
            #"{"streams":[{"index":0,"codec_type":"video","height":"1080.5"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"video","bits_per_sample":"8.5"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","sample_rate":44100.5}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","channels":"2.5"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","bit_rate":128000.5}]}"#,
        ]
    )
    func fractionalIntegerMetadata(json: String) {
        #expect(throws: FFprobeParsingError.invalidMetadata) {
            try parser.parse(Data(json.utf8))
        }
    }

    @Test(
        "Values outside Int64 range are invalid",
        arguments: [
            #"{"format":{"duration":"9223372036854.775808"}}"#,
            #"{"format":{"size":"9223372036854775808"}}"#,
            #"{"format":{"bit_rate":9223372036854775808}}"#,
            #"{"streams":[{"index":0,"codec_type":"video","width":"9223372036854775808"}]}"#,
            #"{"streams":[{"index":0,"codec_type":"audio","sample_rate":"9223372036854775808"}]}"#,
        ]
    )
    func overflowingNumericMetadata(json: String) {
        #expect(throws: FFprobeParsingError.invalidMetadata) {
            try parser.parse(Data(json.utf8))
        }
    }

    @Test("N/A remains unavailable for optional numeric metadata")
    func unavailableNumericMetadata() throws {
        let json = #"""
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "width": "N/A",
              "height": "N/A",
              "bits_per_raw_sample": "N/A",
              "bits_per_sample": "N/A"
            },
            {
              "index": 1,
              "codec_type": "audio",
              "sample_rate": "N/A",
              "channels": "N/A",
              "bit_rate": "N/A"
            }
          ],
          "format": {
            "duration": "N/A",
            "size": "N/A",
            "bit_rate": "N/A"
          }
        }
        """#

        let info = try parser.parse(Data(json.utf8))
        let video = try requireVideo(info.streams[0])
        let audio = try requireAudio(info.streams[1])

        #expect(info.durationMicroseconds == nil)
        #expect(info.byteCount == 0)
        #expect(info.bitRate == nil)
        #expect(video.encodedWidth == nil)
        #expect(video.encodedHeight == nil)
        #expect(video.bitDepth == nil)
        #expect(audio.sampleRate == nil)
        #expect(audio.channelCount == nil)
        #expect(audio.bitRate == nil)
    }

    @Test("Pixel formats supply omitted per-component bit depths safely")
    func infersBitDepthFromPixelFormat() throws {
        let json = #"""
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "codec_name": "hevc",
              "pix_fmt": "yuv420p10le"
            },
            {
              "index": 1,
              "codec_type": "video",
              "pix_fmt": "nv12"
            },
            {
              "index": 2,
              "codec_type": "video",
              "pix_fmt": "rgb24"
            },
            {
              "index": 3,
              "codec_type": "video",
              "pix_fmt": "v210"
            },
            {
              "index": 4,
              "codec_type": "video",
              "pix_fmt": "p210le"
            },
            {
              "index": 5,
              "codec_type": "video",
              "pix_fmt": "rgb48le"
            },
            {
              "index": 6,
              "codec_type": "video",
              "pix_fmt": "xyz12le"
            }
          ],
          "format": {}
        }
        """#

        let info = try parser.parse(Data(json.utf8))
        let videos = info.videoStreams

        #expect(videos.map(\.pixelFormat) == [
            "yuv420p10le",
            "nv12",
            "rgb24",
            "v210",
            "p210le",
            "rgb48le",
            "xyz12le",
        ])
        #expect(videos.map(\.bitDepth) == [10, 8, 8, 10, 10, 16, 12])
        #expect(videos.allSatisfy { $0.dynamicRange == .unknown })
    }

    @Test("Sample aspect ratio is retained for safe geometry preflight")
    func sampleAspectRatio() throws {
        let json = #"""
        {
          "streams": [
            {
              "index": 0,
              "codec_type": "video",
              "sample_aspect_ratio": "32:27"
            },
            {
              "index": 1,
              "codec_type": "video",
              "sample_aspect_ratio": "1:1"
            }
          ],
          "format": {}
        }
        """#

        let videos = try parser.parse(Data(json.utf8)).videoStreams
        let anamorphic = try RationalAspectRatio(
            numerator: 32,
            denominator: 27
        )

        #expect(videos[0].sampleAspectRatio == anamorphic)
        #expect(videos[1].sampleAspectRatio?.isSquare == true)
    }

    private func parseFixture(_ name: String) throws -> MediaInfo {
        try parser.parse(FFprobeFixture.data(named: name))
    }

    private func requireVideo(_ stream: MediaStream) throws -> VideoStreamInfo {
        guard case .video(let video) = stream else {
            throw UnexpectedStreamKind.expectedVideo
        }
        return video
    }

    private func requireAudio(_ stream: MediaStream) throws -> AudioStreamInfo {
        guard case .audio(let audio) = stream else {
            throw UnexpectedStreamKind.expectedAudio
        }
        return audio
    }

    private func requireSubtitle(
        _ stream: MediaStream
    ) throws -> SubtitleStreamInfo {
        guard case .subtitle(let subtitle) = stream else {
            throw UnexpectedStreamKind.expectedSubtitle
        }
        return subtitle
    }

    private func requireOther(_ stream: MediaStream) throws -> OtherStreamInfo {
        guard case .other(let other) = stream else {
            throw UnexpectedStreamKind.expectedOther
        }
        return other
    }
}

private enum UnexpectedStreamKind: Error {
    case expectedVideo
    case expectedAudio
    case expectedSubtitle
    case expectedOther
}
