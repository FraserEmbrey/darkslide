import CryptoKit
import Foundation
import ImageIO
import OSLog
import QuickLookUI

/// Space in Finder on a raw shows it as edited in Darkslide: the render the
/// app keeps in ~/Library/Caches/Darkslide/quicklook (QuickLookCache in the
/// app), else the camera's embedded preview, as Quick Look would show.
///
/// The extension is sandboxed; it reads that folder through a read-only
/// temporary exception in its entitlements, and the photo through the file
/// Quick Look hands it. It can't see the sidecar, so a render is matched to
/// the photo by its path and the file's modification date.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let log = Logger(subsystem: "me.frsr.darkslide.quicklook", category: "preview")

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        if let render = Self.cachedRender(for: url) {
            Self.log.notice("render for \(url.lastPathComponent, privacy: .public)")
            return QLPreviewReply(fileURL: render)
        }
        Self.log.notice("camera preview for \(url.lastPathComponent, privacy: .public)")
        // not edited in Darkslide: the camera's preview
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary)
        else { throw CocoaError(.fileReadCorruptFile) }
        let size = CGSize(width: image.width, height: image.height)
        return QLPreviewReply(contextSize: size, isBitmap: true) { context, _ in
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
    }

    /// Must match QuickLookCache.file(for:) in the app.
    static func cachedRender(for photo: URL) -> URL? {
        // the real home: in the sandbox, NSHomeDirectory is the extension's container
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        let home = URL(fileURLWithPath: String(cString: dir))
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = home.appendingPathComponent("Library/Caches/Darkslide/quicklook/\(digest).jpg")
        guard let made = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date,
              let photoDate = (try? FileManager.default.attributesOfItem(atPath: photo.path)[.modificationDate]) as? Date,
              made >= photoDate else { return nil }
        return file
    }
}
