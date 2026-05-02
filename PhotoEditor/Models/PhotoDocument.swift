import Foundation
import AppKit
import CoreImage

struct PhotoDocument {
    let fileURL: URL
    let originalImage: NSImage
    let ciImage: CIImage
    
    /// File name without extension.
    var displayName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
    
    static let thumbnailMaxDimension: CGFloat = 512
    
    enum PhotoDocumentError: Error {
        case failedToLoadImage(String)
        case failedToGenerateThumbnail
    }

    init(url: URL) throws {
        self.fileURL = url
        
        guard let nsImage = NSImage(contentsOf: url) else {
            throw PhotoDocumentError.failedToLoadImage(url.lastPathComponent)
        }
        self.originalImage = nsImage
        
        guard let ci = nsImage.orientedCIImage() else {
            throw PhotoDocumentError.failedToLoadImage(url.lastPathComponent)
        }
        self.ciImage = ci
    }
    
    func thumbnailJPEGData() throws -> Data {
        guard let thumbnail = originalImage.resized(maxDimension: Self.thumbnailMaxDimension),
              let jpegData = thumbnail.jpegData(quality: 0.7) else {
            throw PhotoDocumentError.failedToGenerateThumbnail
        }
        return jpegData
    }
}