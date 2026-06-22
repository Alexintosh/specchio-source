import Foundation

struct CoordinateMapper {
    let phoneScreenSize: CGSize   // e.g., 390 x 844 (points)
    let viewSize: CGSize          // Current Mac window content size

    var scale: CGFloat {
        let widthScale = phoneScreenSize.width / viewSize.width
        let heightScale = phoneScreenSize.height / viewSize.height
        return max(widthScale, heightScale)
    }

    var offset: CGPoint {
        let scaledWidth = phoneScreenSize.width / scale
        let scaledHeight = phoneScreenSize.height / scale
        return CGPoint(
            x: (viewSize.width - scaledWidth) / 2,
            y: (viewSize.height - scaledHeight) / 2
        )
    }

    func viewToPhone(_ viewPoint: CGPoint) -> CGPoint? {
        let adjusted = CGPoint(
            x: viewPoint.x - offset.x,
            y: viewPoint.y - offset.y
        )
        let phonePoint = CGPoint(
            x: adjusted.x * scale,
            y: adjusted.y * scale
        )
        guard phonePoint.x >= 0 && phonePoint.x <= phoneScreenSize.width &&
              phonePoint.y >= 0 && phonePoint.y <= phoneScreenSize.height else {
            return nil
        }
        return phonePoint
    }
}
