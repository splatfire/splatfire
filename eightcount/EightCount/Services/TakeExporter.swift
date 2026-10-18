import AVFoundation
import CoreGraphics
import Foundation
import Photos

// Saves a take to the camera roll as a video you can post (e.g. on TikTok).
//
// Timing recap (see TakeTiming): tutorial time `t` shows take time
//     takeOffset + (t - tutorialStart) / recordRate + syncNudge
// The music starts at take time `takeOffset + syncNudge`; before that is the
// 3-second countdown, which we skip.

/// Plain values read from SwiftData on the main actor, so the export can run
/// off the main actor without touching any model object.
struct TakeSnapshot: Sendable {
    let takeURL: URL
    /// The project's tutorial video (nil if the project has none).
    let tutorialURL: URL?
    let timing: TakeTiming
}

extension TakeSnapshot {
    /// Read the model objects on the main actor.
    @MainActor
    init(take: Take, tutorialURL: URL?) {
        self.init(takeURL: take.videoURL, tutorialURL: tutorialURL, timing: take.timing)
    }
}

enum TakeExportKind: Sendable {
    /// Your video + the tutorial's audio.
    case meWithSong(realTempo: Bool, mirrored: Bool)
    /// 1080x1920: you on top, the tutorial at the bottom, with the tutorial's audio.
    /// Each video can be flipped left-right (like the compare screen shows them).
    case sideBySide(realTempo: Bool, mirrorMe: Bool, mirrorTutorial: Bool)
    /// The raw recording, saved as it is.
    case original

    var needsTutorial: Bool {
        if case .original = self { return false }
        return true
    }
}

enum TakeExportError: LocalizedError {
    case missingTake
    case missingTutorial
    case noVideoTrack
    case tooShort
    case cannotCreateSession
    case exportFailed(String)
    case photosDenied

    var errorDescription: String? {
        switch self {
        case .missingTake:
            return "The recording file could not be found."
        case .missingTutorial:
            return "This project has no tutorial video, so the song can't be added. Choose \"Original recording\" instead."
        case .noVideoTrack:
            return "The video has no picture track, so it can't be exported."
        case .tooShort:
            return "The part to export is too short. Try again after checking the sync."
        case .cannotCreateSession:
            return "Your iPhone could not prepare this video."
        case .exportFailed(let message):
            return "The video could not be prepared. \(message)"
        case .photosDenied:
            return "EightCount isn't allowed to save to Photos. Open Settings \u{2192} EightCount \u{2192} Photos and allow \"Add Photos Only\", then try again."
        }
    }
}

enum TakeExporter {

    // MARK: - Photos

    /// Asks (once) for permission to add to Photos. Throws a friendly error if denied.
    static func requestPhotosAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw TakeExportError.photosDenied
        }
    }

    /// Saves the video file at `url` to the camera roll, then deletes it.
    static func saveToPhotos(_ url: URL) async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        try await requestPhotosAccess()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    // MARK: - Export

    /// Builds the video in a temp folder and returns its URL.
    /// The caller saves it (`saveToPhotos`) which also deletes it; if you don't
    /// save it, delete it yourself. Cancelling the surrounding Task cancels the export.
    /// `progress` reports 0...1 from any thread.
    static func export(take: TakeSnapshot, kind: TakeExportKind,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard FileManager.default.fileExists(atPath: take.takeURL.path) else {
            throw TakeExportError.missingTake
        }

        if case .original = kind {
            let ext = take.takeURL.pathExtension.isEmpty ? "mov" : take.takeURL.pathExtension
            let out = try makeTempURL(ext: ext)
            try FileManager.default.copyItem(at: take.takeURL, to: out)
            progress(1)
            return out
        }

        guard let tutorialURL = take.tutorialURL,
              FileManager.default.fileExists(atPath: tutorialURL.path) else {
            throw TakeExportError.missingTutorial
        }

        let out = try makeTempURL(ext: "mp4")
        do {
            try Task.checkCancellation()
            let plan = try await buildComposition(take: take.takeURL, tutorial: tutorialURL,
                                                  timing: take.timing, kind: kind)
            try Task.checkCancellation()
            try await run(plan: plan, to: out, progress: progress)
            progress(1)
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    // MARK: - Composition

    /// Everything the export session needs (built once, used once).
    private struct Plan {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
    }

    private static let timescale: CMTimeScale = 600

    private static func cm(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// A video track's picture size after its rotation, and the transform
    /// that moves that rotated picture to the top-left corner (0, 0).
    private static func orientedInfo(of track: AVAssetTrack) async throws
        -> (size: CGSize, transform: CGAffineTransform) {
        let (natural, preferred) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let size = CGSize(width: abs(rect.width), height: abs(rect.height))
        let transform = preferred.concatenating(
            CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (size, transform)
    }

    /// Transform that fits a picture of `size` (already at origin 0,0) into
    /// `box`, keeping the aspect ratio and centering it.
    private static func fit(_ size: CGSize, into box: CGRect) -> CGAffineTransform {
        guard size.width > 0, size.height > 0 else { return .identity }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: box.minX + (box.width - w) / 2,
                                             y: box.minY + (box.height - h) / 2))
    }

    private static func buildComposition(take takeURL: URL, tutorial tutorialURL: URL,
                                         timing: TakeTiming, kind: TakeExportKind) async throws -> Plan {
        let takeAsset = AVURLAsset(url: takeURL)
        let tutorialAsset = AVURLAsset(url: tutorialURL)

        guard let takeTrack = try await takeAsset.loadTracks(withMediaType: .video).first else {
            throw TakeExportError.noVideoTrack
        }
        let takeDuration = try await takeAsset.load(.duration).seconds
        let tutorialDuration = try await tutorialAsset.load(.duration).seconds
        let tutorialAudio = try await tutorialAsset.loadTracks(withMediaType: .audio).first

        let sideBySide: Bool
        let realTempo: Bool
        let mirrored: Bool
        var mirrorTutorial = false
        switch kind {
        case .meWithSong(let r, let m): sideBySide = false; realTempo = r; mirrored = m
        case .sideBySide(let r, let me, let tutorial):
            sideBySide = true; realTempo = r; mirrored = me; mirrorTutorial = tutorial
        case .original: throw TakeExportError.missingTutorial   // handled by the caller
        }

        var tutorialVideo: AVAssetTrack?
        if sideBySide {
            guard let track = try await tutorialAsset.loadTracks(withMediaType: .video).first else {
                throw TakeExportError.noVideoTrack
            }
            tutorialVideo = track
        }

        // --- Which part of the take, and which part of the tutorial ---
        let rate = timing.rate
        // Skip the countdown: the music starts at takeOffset + syncNudge.
        let takeStart = max(0, timing.takeOffset + timing.syncNudge)
        var takeEnd = takeDuration.isFinite ? takeDuration : 0
        if timing.tutorialEnd > timing.tutorialStart {
            takeEnd = min(takeEnd, timing.takeTime(forTutorialTime: timing.tutorialEnd))
        }
        let tutorialStart = max(0, timing.tutorialTime(forTakeTime: takeStart))
        // Don't run past the end of the tutorial file.
        if tutorialDuration.isFinite, tutorialDuration > 0 {
            takeEnd = min(takeEnd, takeStart + (tutorialDuration - tutorialStart) / rate)
        }
        let takeLength = takeEnd - takeStart
        guard takeLength > 0.2 else { throw TakeExportError.tooShort }
        let tutorialLength = takeLength * rate

        // Length of the finished video: real tempo = tutorial time (the take
        // is sped up); otherwise = take time (the tutorial is slowed down).
        let outLength = realTempo ? tutorialLength : takeLength

        let composition = AVMutableComposition()

        // --- Your video ---
        guard let compTake = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TakeExportError.cannotCreateSession
        }
        let takeRange = CMTimeRange(start: cm(takeStart), duration: cm(takeLength))
        try compTake.insertTimeRange(takeRange, of: takeTrack, at: .zero)
        if abs(takeLength - outLength) > 0.001 {
            compTake.scaleTimeRange(CMTimeRange(start: .zero, duration: cm(takeLength)),
                                    toDuration: cm(outLength))
        }

        // --- Tutorial (picture only for the composite) ---
        let tutorialRange = CMTimeRange(start: cm(tutorialStart), duration: cm(tutorialLength))
        let scaleTutorial = abs(tutorialLength - outLength) > 0.001

        var compTutorialVideo: AVMutableCompositionTrack?
        if let tutorialVideo {
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TakeExportError.cannotCreateSession
            }
            try track.insertTimeRange(tutorialRange, of: tutorialVideo, at: .zero)
            if scaleTutorial {
                track.scaleTimeRange(CMTimeRange(start: .zero, duration: cm(tutorialLength)),
                                     toDuration: cm(outLength))
            }
            compTutorialVideo = track
        }

        // --- Tutorial audio (if it has any) ---
        if let tutorialAudio {
            if let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compAudio.insertTimeRange(tutorialRange, of: tutorialAudio, at: .zero)
                if scaleTutorial {
                    compAudio.scaleTimeRange(CMTimeRange(start: .zero, duration: cm(tutorialLength)),
                                             toDuration: cm(outLength))
                }
            }
        }

        // --- Layout ---
        let takeInfo = try await orientedInfo(of: takeTrack)
        let renderSize: CGSize
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)

        let takeLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTake)

        if let compTutorialVideo, let tutorialVideo {
            renderSize = CGSize(width: 1080, height: 1920)
            let tutorialInfo = try await orientedInfo(of: tutorialVideo)
            let top = CGRect(x: 0, y: 0, width: 1080, height: 960)
            let bottom = CGRect(x: 0, y: 960, width: 1080, height: 960)
            // Left-right flip across the frame; both videos are centered, so they stay in place.
            let flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: renderSize.width, ty: 0)
            var takeTransform = takeInfo.transform.concatenating(fit(takeInfo.size, into: top))
            if mirrored { takeTransform = takeTransform.concatenating(flip) }
            takeLayer.setTransform(takeTransform, at: .zero)
            let tutorialLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTutorialVideo)
            var tutorialTransform = tutorialInfo.transform.concatenating(fit(tutorialInfo.size, into: bottom))
            if mirrorTutorial { tutorialTransform = tutorialTransform.concatenating(flip) }
            tutorialLayer.setTransform(tutorialTransform, at: .zero)
            instruction.layerInstructions = [takeLayer, tutorialLayer]
        } else {
            renderSize = CGSize(width: max(takeInfo.size.width, 2), height: max(takeInfo.size.height, 2))
            var transform = takeInfo.transform
            if mirrored {
                transform = transform
                    .concatenating(CGAffineTransform(scaleX: -1, y: 1))
                    .concatenating(CGAffineTransform(translationX: renderSize.width, y: 0))
            }
            takeLayer.setTransform(transform, at: .zero)
            instruction.layerInstructions = [takeLayer]
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        return Plan(composition: composition, videoComposition: videoComposition)
    }

    // MARK: - Running the export

    private static func run(plan: Plan, to url: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let maybeSession: AVAssetExportSession? = AVAssetExportSession(
            asset: plan.composition, presetName: AVAssetExportPresetHighestQuality)
        guard let session = maybeSession else { throw TakeExportError.cannotCreateSession }
        session.videoComposition = plan.videoComposition
        // Keeps the pitch of the music when it is slowed down.
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true

        if #available(iOS 18.0, *) {
            try await runModern(session: session, to: url, progress: progress)
        } else {
            try await runClassic(session: session, to: url, progress: progress)
        }
    }

    @available(iOS 18.0, *)
    private static func runModern(session: AVAssetExportSession, to url: URL,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state {
                    progress(p.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }
        do {
            // Cancelling the Task cancels this call.
            try await session.export(to: url, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw TakeExportError.exportFailed(error.localizedDescription)
        }
    }

    private static func runClassic(session: AVAssetExportSession, to url: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        session.outputURL = url
        session.outputFileType = .mp4

        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poller.cancel() }

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        let message = session.error?.localizedDescription ?? "Unknown error."
                        continuation.resume(throwing: TakeExportError.exportFailed(message))
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
    }

    // MARK: - Helpers

    private static func makeTempURL(ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "EightCountExport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(UUID().uuidString).\(ext)", directoryHint: .notDirectory)
    }
}
