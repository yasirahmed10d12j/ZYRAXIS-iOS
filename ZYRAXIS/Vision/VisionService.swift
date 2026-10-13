import Foundation
import UIKit
import Vision
import AVFoundation

/// Future vision capability interfaces.
///
/// Phase 1: permission + single capture hooks only.
/// Continuous frame processing is explicitly OUT of scope.
public enum VisionError: LocalizedError, Equatable {
    case permissionDenied
    case captureUnavailable(String)
    case processingUnavailable

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied."
        case .captureUnavailable(let m): return "Capture unavailable: \(m)"
        case .processingUnavailable:
            return "Vision processing is not implemented yet (Phase 1 interface only)."
        }
    }
}

public protocol VisionService: Sendable {
    func requestCameraPermission() async -> Bool
    /// Single-shot analysis entry point. Throws `processingUnavailable`
    /// until a real Vision pipeline lands.
    func analyze(image: UIImage) async throws -> VisionResult
}

/// Placeholder result type so call sites compile ahead of the real pipeline.
public struct VisionResult: Equatable, Sendable {
    public var objects: [String]
    public var recognizedText: [String]
    public var summary: String

    public init(objects: [String] = [], recognizedText: [String] = [], summary: String = "") {
        self.objects = objects
        self.recognizedText = recognizedText
        self.summary = summary
    }
}

/// Phase 1 stub: honest about being unimplemented, but exposes the
/// permission path (real) so Settings can show camera status.
public struct UnimplementedVisionService: VisionService, Sendable {

    public init() {}

    public func requestCameraPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    public func analyze(image: UIImage) async throws -> VisionResult {
        throw VisionError.processingUnavailable
    }
}
