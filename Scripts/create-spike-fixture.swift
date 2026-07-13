import AVFoundation
import CoreVideo
import Foundation

enum FixtureError: Error {
    case usage
    case outputAlreadyExists
    case cannotAddWriterInput
    case cannotStartWriting
    case cannotCreatePixelBuffer
    case cannotAppendFrame(Int)
    case writerFailed(String)
}

func makeFixture(at outputURL: URL) throws {
    let fileManager = FileManager.default
    guard !fileManager.fileExists(atPath: outputURL.path) else {
        throw FixtureError.outputAlreadyExists
    }

    try fileManager.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let width = 640
    let height = 360
    let frameRate: Int32 = 30
    let frameCount = 90

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let videoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    )
    videoInput.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: videoInput,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
    )

    guard writer.canAdd(videoInput) else {
        throw FixtureError.cannotAddWriterInput
    }
    writer.add(videoInput)

    guard writer.startWriting() else {
        throw FixtureError.writerFailed(
            writer.error?.localizedDescription ?? "AVAssetWriter could not start"
        )
    }
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool else {
        throw FixtureError.cannotCreatePixelBuffer
    }

    for frameIndex in 0..<frameCount {
        while !videoInput.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.002)
        }

        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(
            nil,
            pool,
            &optionalBuffer
        ) == kCVReturnSuccess,
              let pixelBuffer = optionalBuffer else {
            throw FixtureError.cannotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    bytes[offset] = UInt8((x + frameIndex * 3) % 256)
                    bytes[offset + 1] = UInt8((y * 2 + frameIndex) % 256)
                    bytes[offset + 2] = UInt8((x + y + frameIndex * 2) % 256)
                    bytes[offset + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let presentationTime = CMTime(
            value: Int64(frameIndex),
            timescale: frameRate
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw FixtureError.cannotAppendFrame(frameIndex)
        }
    }

    videoInput.markAsFinished()
    let completion = DispatchSemaphore(value: 0)
    writer.finishWriting {
        completion.signal()
    }
    completion.wait()

    guard writer.status == .completed else {
        throw FixtureError.writerFailed(
            writer.error?.localizedDescription ?? "unknown AVAssetWriter error"
        )
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: xcrun swift Scripts/create-spike-fixture.swift OUTPUT.mp4\n".utf8)
    )
    throw FixtureError.usage
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try makeFixture(at: outputURL)
print(outputURL.path)
