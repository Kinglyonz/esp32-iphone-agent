import UIKit

/// Bound each normal trial screenshot before base64 encoding; no remote URL inputs are used.
enum TrialImage {
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= 16 * 1024 * 1024, let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw TrialError(code: .invalidResponse)
        }
        let factor = min(1, 1280 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, floor(image.size.width * factor)), height: max(1, floor(image.size.height * factor)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.75, 0.55, 0.35, 0.15] {
            if let result = resized.jpegData(compressionQuality: quality), result.count <= 256 * 1024 { return result }
        }
        throw TrialError(code: .invalidResponse)
    }
}
