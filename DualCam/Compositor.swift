import CoreImage
import CoreVideo
import UIKit

/// 把两路画面按当前布局合成为一张图 / 一帧视频。
final class Compositor {
    static let shared = Compositor()

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    // MARK: - 视频帧合成

    func compose(videoFrames frames: [CameraSlot: CVPixelBuffer],
                 layout: LayoutConfig,
                 canvas size: CGSize,
                 into destination: CVPixelBuffer) {
        let canvasRect = CGRect(origin: .zero, size: size)
        let (first, second) = ciFrames(layout, in: size)

        var image = CIImage(color: .black).cropped(to: canvasRect)

        if let back = frames[.back] {
            image = fitted(CIImage(cvPixelBuffer: back), into: first, mirrored: false)
                .composited(over: image)
        }
        if let front = frames[.front] {
            image = fitted(CIImage(cvPixelBuffer: front), into: second, mirrored: true)
                .composited(over: image)
        }

        context.render(image, to: destination, bounds: canvasRect, colorSpace: colorSpace)
    }

    // MARK: - 照片合成

    func compose(photos: [CameraSlot: UIImage], layout: LayoutConfig) -> UIImage? {
        guard let base = photos[.back] ?? photos[.front] else { return nil }
        let size = base.size
        guard size.width > 0, size.height > 0 else { return nil }

        let (first, second) = layout.frames(in: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let cg = rendererContext.cgContext
            UIColor.black.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            if let back = photos[.back] {
                draw(back, into: first, mirrored: false, context: cg)
            }
            if let front = photos[.front] {
                draw(front, into: second, mirrored: true, context: cg)
            }
        }
    }

    // MARK: - 私有

    /// Core Image 坐标系原点在左下角，需要把 UIKit 的 frame 翻转过来。
    private func ciFrames(_ layout: LayoutConfig, in size: CGSize) -> (CGRect, CGRect) {
        let (first, second) = layout.frames(in: size)
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX,
                   y: size.height - rect.maxY,
                   width: rect.width,
                   height: rect.height)
        }
        return (flip(first), flip(second))
    }

    /// 等比填满目标区域（居中裁切），并处理竖屏旋转和前置镜像。
    private func fitted(_ image: CIImage, into rect: CGRect, mirrored: Bool) -> CIImage {
        var img = image
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }

        // 传感器出图通常是横向的，竖屏需要顺时针旋转 90°。
        if source.width > source.height {
            img = img.oriented(.right)
        }

        let extent = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        let scale = max(rect.width / extent.width, rect.height / extent.height)
        var transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        transform = transform.scaledBy(x: mirrored ? -scale : scale, y: scale)
        transform = transform.translatedBy(x: -extent.width / 2, y: -extent.height / 2)

        // 等比填充会超出目标区域，必须裁掉，否则两路画面会互相覆盖。
        return img.transformed(by: transform).cropped(to: rect)
    }

    private func draw(_ image: UIImage, into rect: CGRect, mirrored: Bool, context: CGContext) {
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0, rect.width > 0, rect.height > 0 else { return }

        let scale = max(rect.width / width, rect.height / height)
        let drawSize = CGSize(width: width * scale, height: height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2,
                             y: rect.midY - drawSize.height / 2)

        context.saveGState()
        context.clip(to: rect)
        if mirrored {
            context.translateBy(x: rect.midX, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -rect.midX, y: 0)
        }
        image.draw(in: CGRect(origin: origin, size: drawSize))
        context.restoreGState()
    }
}
