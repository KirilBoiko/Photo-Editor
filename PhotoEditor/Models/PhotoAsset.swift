import Foundation
import CoreImage
import AppKit

struct PhotoAsset: Identifiable, Equatable {
    let id = UUID()
    let document: PhotoDocument
    var adjustments: ImageAdjustments?
    var isMaskAvailable: Bool = false
    var cachedSubjectMask: CIImage?
    
    static func == (lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        lhs.id == rhs.id
    }
}
