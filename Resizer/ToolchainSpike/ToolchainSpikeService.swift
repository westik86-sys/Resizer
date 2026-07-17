import Foundation

nonisolated struct FFprobeDocument: Decodable, Sendable {
    nonisolated struct Stream: Decodable, Sendable {
        let codecName: String?
        let codecType: String?

        enum CodingKeys: String, CodingKey {
            case codecName = "codec_name"
            case codecType = "codec_type"
        }
    }

    nonisolated struct Format: Decodable, Sendable {
        let formatName: String?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
        }
    }

    let streams: [Stream]
    let format: Format?

    enum CodingKeys: String, CodingKey {
        case streams
        case format
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streams = try container.decodeIfPresent(
            [Stream].self,
            forKey: .streams
        ) ?? []
        format = try container.decodeIfPresent(Format.self, forKey: .format)
    }
}

nonisolated struct ToolchainSpikeReport: Sendable {
    let inputVideoCodec: String
    let outputURL: URL
    let outputByteCount: Int
}

nonisolated enum ToolchainSpikeFailure: Error, Sendable {
    case bundledExecutableUnavailable(String)
    case securityScopeUnavailable(String)
    case outputSelectionIsNotDirectory
    case outputNameCollision
    case inputHasNoVideo
    case probeOutputTooLarge
    case malformedProbeOutput
    case processFailed(tool: String, status: Int32, diagnosticTail: String)
    case emptyTemporaryOutput
    case invalidEncodedOutput

    var message: String {
        switch self {
        case .bundledExecutableUnavailable(let tool):
            "Bundled \(tool) is missing or is not executable."
        case .securityScopeUnavailable(let selection):
            "Could not access the selected \(selection)."
        case .outputSelectionIsNotDirectory:
            "The selected output location is not a directory."
        case .outputNameCollision:
            "A diagnostic output name unexpectedly already exists."
        case .inputHasNoVideo:
            "The selected input has no video stream."
        case .probeOutputTooLarge:
            "ffprobe returned more JSON than the diagnostic limit allows."
        case .malformedProbeOutput:
            "ffprobe returned invalid JSON."
        case let .processFailed(tool, status, diagnosticTail):
            if diagnosticTail.isEmpty {
                "\(tool) failed with status \(status)."
            } else {
                "\(tool) failed with status \(status).\n\(diagnosticTail)"
            }
        case .emptyTemporaryOutput:
            "FFmpeg did not create a non-empty temporary output."
        case .invalidEncodedOutput:
            "The temporary output did not validate as H.264 MP4."
        }
    }
}

actor ToolchainSpikeService {
    private let ffmpegURL: URL
    private let ffprobeURL: URL
    private let processRunner: SpikeProcessRunner

    init(
        ffmpegURL: URL,
        ffprobeURL: URL,
        processRunner: SpikeProcessRunner
    ) {
        self.ffmpegURL = ffmpegURL
        self.ffprobeURL = ffprobeURL
        self.processRunner = processRunner
    }

    func run(
        inputURL: URL,
        outputDirectoryURL: URL
    ) async throws -> ToolchainSpikeReport {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: ffmpegURL.path) else {
            throw ToolchainSpikeFailure.bundledExecutableUnavailable("ffmpeg")
        }
        guard fileManager.isExecutableFile(atPath: ffprobeURL.path) else {
            throw ToolchainSpikeFailure.bundledExecutableUnavailable("ffprobe")
        }

        // Start access on the scoped URL before reducing it to a String path.
        guard inputURL.startAccessingSecurityScopedResource() else {
            throw ToolchainSpikeFailure.securityScopeUnavailable("input file")
        }
        defer { inputURL.stopAccessingSecurityScopedResource() }

        guard outputDirectoryURL.startAccessingSecurityScopedResource() else {
            throw ToolchainSpikeFailure.securityScopeUnavailable("output folder")
        }
        defer { outputDirectoryURL.stopAccessingSecurityScopedResource() }

        let outputDirectoryValues = try outputDirectoryURL.resourceValues(
            forKeys: [.isDirectoryKey]
        )
        guard outputDirectoryValues.isDirectory == true else {
            throw ToolchainSpikeFailure.outputSelectionIsNotDirectory
        }

        let identifier = UUID().uuidString
        let temporaryURL = outputDirectoryURL.appendingPathComponent(
            "Resizer.\(identifier).partial.mp4",
            isDirectory: false
        )
        let finalURL = outputDirectoryURL.appendingPathComponent(
            "Resizer.\(identifier).mp4",
            isDirectory: false
        )

        guard !fileManager.fileExists(atPath: temporaryURL.path),
              !fileManager.fileExists(atPath: finalURL.path) else {
            throw ToolchainSpikeFailure.outputNameCollision
        }

        // This exact path was absent above and contains this run's UUID.
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let inputProbe = try await probe(inputURL)
        guard let inputVideo = inputProbe.streams.first(where: {
            $0.codecType == "video"
        }) else {
            throw ToolchainSpikeFailure.inputHasNoVideo
        }

        let encodeResult = try await processRunner.run(
            executableURL: ffmpegURL,
            arguments: [
                "-hide_banner",
                "-loglevel", "warning",
                "-nostdin",
                "-i", inputURL.path,
                "-t", "3",
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-c:v", "libx264",
                "-crf", "24",
                "-preset", "medium",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                "-b:a", "128k",
                "-movflags", "+faststart",
                "-n",
                temporaryURL.path,
            ],
            standardOutputLimit: 64 * 1_024,
            standardErrorLimit: 1_024 * 1_024
        )
        try requireSuccess(encodeResult, tool: "ffmpeg")

        let temporaryOutputValues = try temporaryURL.resourceValues(
            forKeys: [.fileSizeKey]
        )
        let outputByteCount = temporaryOutputValues.fileSize ?? 0
        guard outputByteCount > 0 else {
            throw ToolchainSpikeFailure.emptyTemporaryOutput
        }

        let outputProbe = try await probe(temporaryURL)
        let hasH264Video = outputProbe.streams.contains {
            $0.codecType == "video" && $0.codecName == "h264"
        }
        let isMP4 = outputProbe.format?.formatName?
            .split(separator: ",")
            .contains("mp4") == true
        guard hasH264Video, isMP4 else {
            throw ToolchainSpikeFailure.invalidEncodedOutput
        }

        // moveItem fails on collision. FFmpeg never receives this final URL.
        try fileManager.moveItem(at: temporaryURL, to: finalURL)

        return ToolchainSpikeReport(
            inputVideoCodec: inputVideo.codecName ?? "unknown",
            outputURL: finalURL,
            outputByteCount: outputByteCount
        )
    }

    private func probe(_ inputURL: URL) async throws -> FFprobeDocument {
        let result = try await processRunner.run(
            executableURL: ffprobeURL,
            arguments: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                inputURL.path,
            ],
            standardOutputLimit: 2 * 1_024 * 1_024,
            standardErrorLimit: 512 * 1_024
        )
        try requireSuccess(result, tool: "ffprobe")

        guard !result.standardOutput.wasTruncated else {
            throw ToolchainSpikeFailure.probeOutputTooLarge
        }

        do {
            return try JSONDecoder().decode(
                FFprobeDocument.self,
                from: result.standardOutput.data
            )
        } catch {
            throw ToolchainSpikeFailure.malformedProbeOutput
        }
    }

    private func requireSuccess(
        _ result: SpikeProcessResult,
        tool: String
    ) throws {
        guard result.termination.reason == .exit,
              result.termination.status == 0 else {
            let diagnosticTail = String(
                decoding: result.standardError.data,
                as: UTF8.self
            )
            throw ToolchainSpikeFailure.processFailed(
                tool: tool,
                status: result.termination.status,
                diagnosticTail: diagnosticTail
            )
        }
    }
}
