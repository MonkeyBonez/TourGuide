import Foundation
import UIKit

enum ImageProcessor {
    static func jpegResized(from image: UIImage, maxLongEdge: CGFloat = 1280, quality: CGFloat = 0.75) -> Data? {
        let size = image.size
        let longEdge = max(size.width, size.height)
        let scale = min(1.0, maxLongEdge / longEdge)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return normalized.jpegData(compressionQuality: quality)
    }
}


