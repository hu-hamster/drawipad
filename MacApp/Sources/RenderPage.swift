import AppKit
import PencilKit

/// 页面渲染合成器：底图 + 墨迹 → 单张图。
/// 统一使用顶层左原点（与 PencilKit 页面坐标一致），避免各处翻转处理不一致。
enum PageRenderer {
    struct Result {
        let image: NSImage
        /// 渲染覆盖的页面逻辑坐标区域。
        let rect: CGRect
    }

    /// 合成页面图像。
    /// - Parameters:
    ///   - drawing: 笔迹（可为 nil）
    ///   - background: 底图（可为 nil；有底图时渲染区域以整页为准）
    ///   - pageSize: 页面逻辑尺寸
    ///   - padding: 四周留白（页面坐标）
    ///   - scale: 渲染倍率
    ///   - fillWhite: 是否铺白底（导出用；画布/缩略图保持透明）
    static func composite(
        drawing: PKDrawing?,
        background: NSImage?,
        pageSize: CGSize,
        padding: CGFloat = 0,
        scale: CGFloat = 1,
        fillWhite: Bool = false
    ) -> Result? {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let inkBounds = drawing?.bounds ?? .null
        let hasInk = !inkBounds.isNull && !inkBounds.isEmpty

        var rect: CGRect
        if background != nil {
            rect = pageRect
            if hasInk {
                rect = rect.union(inkBounds)
            }
        } else {
            guard hasInk else { return nil }
            rect = inkBounds
        }
        if padding > 0 {
            rect = rect.insetBy(dx: -padding, dy: -padding)
        }

        let pixelWidth = max(1, Int(rect.width * scale))
        let pixelHeight = max(1, Int(rect.height * scale))
        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { return nil }

        // 转为顶层左原点坐标，再映射到渲染区域
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)

        if fillWhite {
            context.setFillColor(CGColor(gray: 1.0, alpha: 1))
            context.fill(rect)
        }
        if let background {
            drawImage(background, aspectFitIn: pageRect, context: context)
        }
        if let drawing, hasInk {
            let ink = drawing.image(from: rect, scale: scale)
            if let cg = ink.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cg, in: rect)
            }
        }

        guard let cgImage = context.makeImage() else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: rect.width, height: rect.height)
        )
        return Result(image: image, rect: rect)
    }

    private static func drawImage(_ image: NSImage, aspectFitIn dest: CGRect, context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let imageWidth = CGFloat(cg.width)
        let imageHeight = CGFloat(cg.height)
        guard imageWidth > 0, imageHeight > 0, dest.width > 0, dest.height > 0 else { return }
        let fit = min(dest.width / imageWidth, dest.height / imageHeight)
        let size = CGSize(width: imageWidth * fit, height: imageHeight * fit)
        let frame = CGRect(
            x: dest.midX - size.width / 2,
            y: dest.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.draw(cg, in: frame)
    }
}
