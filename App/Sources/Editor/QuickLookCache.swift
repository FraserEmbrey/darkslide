import CoreImage
import CryptoKit
import Foundation

/// Renders for the Quick Look extension (App/QuickLook): Space in Finder on a
/// raw edited here shows the edit. Written when the photo is left after an
/// edit, as its thumbnail is, at the canvas's size; an HDR render is tone
/// mapped to SDR, as a plain JPEG holds no more. The extension can't read the
/// sidecar, so it trusts a render that's newer than the photo file.
enum QuickLookCache {
    /// Must match PreviewProvider.cachedRender(for:) in the extension.
    nonisolated static func file(for photo: URL) -> URL {
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Darkslide/quicklook/\(digest).jpg")
    }

    nonisolated static func store(_ frame: CGImage, for photo: URL) {
        // Finder previews files; a version (PhotoVersion) isn't one
        guard !photo.isVersion, PhotosLibrary.assetID(photo) == nil else { return }
        var image = CIImage(cgImage: frame)
        if frame.contentHeadroom > 1 {
            image = image.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": frame.contentHeadroom,
                                                                           "inputTargetHeadroom": 1])
        }
        let out = file(for: photo)
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? context.writeJPEGRepresentation(of: image, to: out, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85])
    }

    nonisolated private static let context = CIContext()
}
