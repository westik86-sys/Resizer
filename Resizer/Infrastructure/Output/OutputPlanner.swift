import Foundation

nonisolated enum OutputPlannerError: Error, Sendable, Equatable {
    case invalidInputURL
    case invalidOutputDirectoryURL
    case invalidOutputName
    case outputCollision
    case temporaryCollision
    case invalidGeneratedPlan
}

actor OutputPlanner: OutputPlanning {
    private static let maximumNumericSuffix = 10_000

    private let fileExists: @Sendable (URL) -> Bool

    init(
        fileExists: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.fileExists = fileExists
    }

    func planOutput(
        for request: OutputPlanningRequest
    ) async throws -> OutputPlan {
        guard Self.isValidLocalAbsoluteURL(request.inputURL) else {
            throw OutputPlannerError.invalidInputURL
        }
        guard Self.isValidLocalAbsoluteURL(request.policy.directoryURL) else {
            throw OutputPlannerError.invalidOutputDirectoryURL
        }

        let inputURL = request.inputURL.standardizedFileURL
        let outputDirectoryURL = request.policy.directoryURL
            .standardizedFileURL
        let sourceStem = inputURL
            .deletingPathExtension()
            .lastPathComponent
        let policySuffix = request.policy.filenameSuffix
        guard Self.isValidNameComponent(sourceStem),
              Self.isValidNameComponent(policySuffix) else {
            throw OutputPlannerError.invalidOutputName
        }

        let baseStem = sourceStem + policySuffix
        let chosenStem = try chooseAvailableStem(
            baseStem: baseStem,
            inputURL: inputURL,
            outputDirectoryURL: outputDirectoryURL,
            conflictPolicy: request.policy.conflictPolicy
        )
        let finalURL = outputDirectoryURL.appendingPathComponent(
            "\(chosenStem).mp4",
            isDirectory: false
        )
        let jobToken = request.jobID.uuidString.lowercased()
        let temporaryURL = outputDirectoryURL.appendingPathComponent(
            "\(chosenStem).\(jobToken).partial.mp4",
            isDirectory: false
        )

        guard Self.isValidLocalAbsoluteURL(finalURL),
              Self.isValidLocalAbsoluteURL(temporaryURL) else {
            throw OutputPlannerError.invalidOutputName
        }
        guard !fileExists(temporaryURL) else {
            throw OutputPlannerError.temporaryCollision
        }

        do {
            return try OutputPlan(
                request: request,
                temporaryURL: temporaryURL,
                finalURL: finalURL
            )
        } catch {
            throw OutputPlannerError.invalidGeneratedPlan
        }
    }

    private func chooseAvailableStem(
        baseStem: String,
        inputURL: URL,
        outputDirectoryURL: URL,
        conflictPolicy: OutputConflictPolicy
    ) throws -> String {
        let baseURL = outputDirectoryURL.appendingPathComponent(
            "\(baseStem).mp4",
            isDirectory: false
        )
        guard isCollision(baseURL, inputURL: inputURL) else {
            return baseStem
        }

        guard conflictPolicy == .appendNumericSuffix else {
            throw OutputPlannerError.outputCollision
        }

        for numericSuffix in 2...Self.maximumNumericSuffix {
            let candidateStem = "\(baseStem)-\(numericSuffix)"
            let candidateURL = outputDirectoryURL.appendingPathComponent(
                "\(candidateStem).mp4",
                isDirectory: false
            )
            if !isCollision(candidateURL, inputURL: inputURL) {
                return candidateStem
            }
        }
        throw OutputPlannerError.outputCollision
    }

    private func isCollision(
        _ candidateURL: URL,
        inputURL: URL
    ) -> Bool {
        candidateURL.standardizedFileURL == inputURL
            || fileExists(candidateURL)
    }

    private static func isValidLocalAbsoluteURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.path.hasPrefix("/")
            && !url.path.contains("\0")
    }

    private static func isValidNameComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\0")
    }
}
