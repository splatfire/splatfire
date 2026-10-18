import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Lets PhotosPicker hand us a video *file* (instead of loading the whole
/// video into memory). The system gives us a temporary file that is deleted
/// right after `importing` returns, so we copy it into app storage there.
struct PickedMovie: Transferable, Sendable {
    /// File name inside `VideoStorage.directory`.
    let storedFileName: String
    /// Name the file had in Photos (e.g. "IMG_1234.MOV"), for display only.
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(VideoStorage.url(forFileName: movie.storedFileName))
        } importing: { received in
            let name = try VideoStorage.importVideo(from: received.file)
            return PickedMovie(storedFileName: name, originalName: received.file.lastPathComponent)
        }
    }
}
