import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import Vision

/// What Apple Intelligence produces for one item.
@Generable(description: "A catalogue entry for an image or animated GIF saved in a personal searchable library")
nonisolated struct ImageInsight: Equatable {
    @Guide(description: "A short, specific title of 2 to 6 words, the way someone would name this GIF or image")
    var title: String

    @Guide(description: "One or two plain sentences describing what is shown and what is happening")
    var summary: String

    @Guide(description: "Lowercase single-word or two-word search keywords: subjects, actions, emotions, setting, style", .count(4...12))
    var tags: [String]

    @Guide(description: "Short reaction phrases someone might type to find this when replying to a friend, like 'mind blown' or 'thank you'. Empty if it is not a reaction image.", .count(0...5))
    var reactions: [String]
}

nonisolated struct AnalysisResult: Sendable, Equatable {
    var title: String
    var summary: String
    var tags: [String]
    var reactions: [String]
    var ocrText: String
    var usedFoundationModel: Bool
}

/// Describes images on device: Vision for labels + text, Foundation Models for language.
nonisolated enum ImageAnalyzer {
    enum Failure: Error { case undecodable }

    /// Describes the current Apple Intelligence state for Settings.
    static var modelStatus: ModelStatus {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return model.capabilities.contains(.vision) ? .availableWithVision : .availableTextOnly
        case .unavailable(.deviceNotEligible): return .unavailable(String(localized: "This device doesn’t support Apple Intelligence."))
        case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(String(localized: "Turn on Apple Intelligence in Settings."))
        case .unavailable(.modelNotReady): return .unavailable(String(localized: "Apple Intelligence is still downloading."))
        case .unavailable: return .unavailable(String(localized: "Apple Intelligence is unavailable."))
        }
    }

    enum ModelStatus: Equatable {
        case availableWithVision, availableTextOnly, unavailable(String)
    }

    @concurrent
    static func analyze(fileURL: URL) async throws -> AnalysisResult {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { throw Failure.undecodable }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let key = FrameTiming.downsample(source, index: count / 2, maxPixel: 1024) else { throw Failure.undecodable }
        // Caption text often appears only on some frames; read the first and middle.
        var ocrFrames = [key]
        if count > 2, let first = FrameTiming.downsample(source, index: 0, maxPixel: 1024) { ocrFrames.insert(first, at: 0) }

        async let labels = classify(key)
        async let text = recognizeText(in: ocrFrames)
        let (visionLabels, ocr) = try await (labels, text)

        if let insight = await describe(key, labels: visionLabels, ocr: ocr, animated: count > 1) {
            return AnalysisResult(
                title: insight.title.trimmed,
                summary: insight.summary.trimmed,
                tags: normalizeTags(insight.tags + visionLabels.prefix(4)),
                reactions: insight.reactions.map(\.trimmed).filter { !$0.isEmpty },
                ocrText: ocr,
                usedFoundationModel: true
            )
        }
        // No model available: Vision labels still make items searchable.
        return AnalysisResult(
            title: "",
            summary: visionLabels.prefix(3).joined(separator: ", ").capitalizedFirst,
            tags: normalizeTags(visionLabels),
            reactions: [],
            ocrText: ocr,
            usedFoundationModel: false
        )
    }

    // MARK: Foundation Models

    private static func describe(_ image: CGImage, labels: [String], ocr: String, animated: Bool) async -> ImageInsight? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }

        let session = LanguageModelSession(model: model, instructions: """
            You catalogue images and GIFs for a personal library so they can be found again by search. \
            Be literal and specific about what is visible. Do not guess the names of real people. \
            Keep titles short and natural.
            """)
        let kind = animated ? "a frame from an animated GIF" : "an image"
        let hints = labels.isEmpty ? "" : "Detected objects: \(labels.joined(separator: ", "))."
        let textHint = ocr.isEmpty ? "" : "Text visible in it: \"\(ocr.prefix(400))\"."

        do {
            if model.capabilities.contains(.vision) {
                return try await session.respond(generating: ImageInsight.self) {
                    "Catalogue \(kind). \(textHint)"
                    Attachment(image)
                }.content
            }
            // Text-only model: reason from Vision's labels and OCR.
            guard !labels.isEmpty || !ocr.isEmpty else { return nil }
            return try await session.respond(
                to: "Catalogue \(kind) using only these clues. \(hints) \(textHint)",
                generating: ImageInsight.self
            ).content
        } catch {
            return nil
        }
    }

    // MARK: Vision

    private static func classify(_ image: CGImage) async throws -> [String] {
        let observations = try await ClassifyImageRequest().perform(on: image)
        return observations
            .filter { $0.confidence > 0.35 }
            .prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    private static func recognizeText(in frames: [CGImage]) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        var lines: [String] = []
        for frame in frames {
            for observation in try await request.perform(on: frame) {
                guard let line = observation.topCandidates(1).first?.string.trimmed, !line.isEmpty else { continue }
                if !lines.contains(where: { $0.caseInsensitiveCompare(line) == .orderedSame }) { lines.append(line) }
            }
        }
        return lines.joined(separator: " ")
    }

    // MARK: Helpers

    static func normalizeTags(_ tags: some Sequence<String>) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            let tag = raw.trimmed.lowercased()
            guard !tag.isEmpty, tag.count <= 40, seen.insert(tag).inserted else { return nil }
            return tag
        }
    }
}

