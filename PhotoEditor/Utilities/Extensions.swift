import AppKit
import CoreImage

extension NSImage {
    /// Converts NSImage to CIImage for the M3 GPU filters
    func orientedCIImage() -> CIImage? {
        guard let tiffData = self.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        let ciImage = CIImage(bitmapImageRep: bitmap)
        return ciImage
    }

    /// Resizes the image for the AI thumbnail
    func resized(maxDimension: CGFloat) -> NSImage? {
        let aspectRatio = self.size.width / self.size.height
        var newSize: NSSize
        if aspectRatio > 1 {
            newSize = NSSize(width: maxDimension, height: maxDimension / aspectRatio)
        } else {
            newSize = NSSize(width: maxDimension * aspectRatio, height: maxDimension)
        }
        
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        self.draw(in: NSRect(origin: .zero, size: newSize),
                  from: NSRect(origin: .zero, size: self.size),
                  operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    /// NEW: Converts NSImage to JPEG Data for the Gemini API
    func jpegData(quality: CGFloat) -> Data? {
        guard let tiffRepresentation = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmapImage.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}