import Foundation

@MainActor
struct AppComposition {
    let compressionFeatureModel: CompressionFeatureModel

    init(dependencies: CompressionCoordinatorDependencies) {
        let coordinator = CompressionCoordinator(dependencies: dependencies)
        compressionFeatureModel = CompressionFeatureModel(coordinator: coordinator)
    }

    #if DEBUG
    static func preview() throws -> AppComposition {
        let mediaInfo = try MediaInfo(
            formatNames: ["mov", "mp4"],
            durationMicroseconds: 3_000_000,
            byteCount: 381_000,
            bitRate: nil,
            streams: [
                .video(
                    try VideoStreamInfo(
                        index: 0,
                        codecName: "h264",
                        encodedWidth: 640,
                        encodedHeight: 360,
                        frameRate: nil,
                        rotationDegrees: nil,
                        pixelFormat: "yuv420p",
                        bitDepth: 8,
                        dynamicRange: .sdr
                    )
                ),
            ]
        )

        let dependencies = CompressionCoordinatorDependencies(
            mediaProber: FakeMediaProber { _ in mediaInfo },
            transcoder: FakeTranscoder(
                handler: { _, _ in
                    try TranscodeResult(
                        byteCount: 1,
                        temporaryMetadata: FileMetadata(
                            byteCount: 1,
                            isDirectory: false,
                            identity: FileIdentity(device: 1, inode: 1)
                        )
                    )
                },
                cancellationHandler: { _ in }
            ),
            outputPlanner: FakeOutputPlanner { request in
                let identifier = request.jobID.uuidString
                let directory = request.policy.directoryURL
                return try OutputPlan(
                    request: request,
                    temporaryURL: directory.appendingPathComponent(
                        "\(identifier).partial.mp4"
                    ),
                    finalURL: directory.appendingPathComponent(
                        "\(identifier).mp4"
                    )
                )
            },
            fileAccess: PassthroughFileAccess(
                metadataProvider: { _ in nil },
                commitHandler: { _ in },
                cleanupHandler: { _ in }
            )
        )

        return AppComposition(dependencies: dependencies)
    }
    #endif
}
