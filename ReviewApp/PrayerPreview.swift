import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreviewPreset: Decodable {
    struct Position: Decodable {
        let x: Double
        let y: Double
    }
    struct DateStyle: Decodable {
        let font: String
        let size: Double
        let x: Double
        let y: Double
    }
    struct Logo: Decodable {
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
    }
    struct Word: Decodable {
        struct Style: Decodable {
            let fontName: String
            let fontSize: Double
            let widthScale: Double
            let heightScale: Double
        }
        let text: String
        let style: Style
        let transform: Position
    }
    let layout: String
    let logo: String
    let logoGeometry: Logo
    let date: DateStyle
    let subtitleFont: String
    let subtitleSize: Double
    let lineSpacing: Double
    let blur: Double
    let matte: Double
    let bodyMatte: Double
    let words: [Word]
}

struct PreviewRequest: Hashable {
    let crop: CropOptions
    let date: String
    let texts: [String]
    var assets = ""
}

struct PreviewCard: Identifiable {
    let id: Int
    let title: String
    let image: CGImage
}

enum PrayerPreview {
    static let canvas = CGRect(x: 0, y: 0, width: 1080, height: 1920)
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let fontScale = canvas.height / canvas.width

    static func render(_ request: PreviewRequest, preset: PreviewPreset) throws -> [PreviewCard] {
        let jpeg = try request.crop.jpeg(width: Int(canvas.width))
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReviewError("크롭한 배경 사진을 읽을 수 없습니다.")
        }
        let ci = CIImage(cgImage: original)
        let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: preset.blur).cropped(to: canvas)
        let ciContext = CIContext(options: [.workingColorSpace: srgb])
        guard let prayerBackground = ciContext.createCGImage(blurred, from: canvas,
                                                            format: .RGBA8, colorSpace: srgb) else {
            throw ReviewError("기도 배경을 렌더링할 수 없습니다.")
        }
        let layout = try artwork(preset.layout, size: Int(canvas.height))
        let logo = try artwork(preset.logo)
        let captions = request.texts.isEmpty ? [[]] : try Runner.subtitlePages(request.texts)
        var pages: [PreviewCard] = []
        for (index, rows) in captions.enumerated() {
            let ctx = try context()
            drawBackground(prayerBackground, in: ctx, opacity: preset.matte)
            dim(preset.bodyMatte, in: ctx)
            ctx.draw(layout, in: canvas)
            for (row, text) in rows.enumerated() {
                let centerY = 0.5 + (Double(row) - Double(rows.count - 1) / 2) * preset.lineSpacing
                try drawText(text, font: preset.subtitleFont, size: preset.subtitleSize,
                             x: 0.5, y: centerY, in: ctx)
            }
            try drawText(request.date, font: preset.date.font, size: preset.date.size,
                         x: preset.date.x, y: preset.date.y, in: ctx)
            pages.append(PreviewCard(id: index, title: "자막 \(index + 1)", image: try finished(ctx)))
        }
        let ending = try context()
        drawBackground(original, in: ending, opacity: preset.matte)
        for word in preset.words {
            // Match Palmier's raster bounds for the fixed end card. Core Text's
            // kerning and the Day descender differ slightly in our canvas.
            let adjustment: (width: Double, height: Double, y: Double)
            switch word.text {
            case "Bless": adjustment = (1, 1, -1)
            case "Your": adjustment = (181 / 169, 1, 0)
            case "Day": adjustment = (1, 80 / 83, -1.5)
            default: adjustment = (1, 1, 0)
            }
            try drawText(word.text, font: word.style.fontName, size: word.style.fontSize,
                         x: word.transform.x, y: word.transform.y + adjustment.y / canvas.height,
                         scaleX: word.style.widthScale * adjustment.width,
                         scaleY: word.style.heightScale * adjustment.height, in: ending)
        }
        let g = preset.logoGeometry
        ending.draw(logo, in: CGRect(x: (g.centerX - g.width / 2) * canvas.width,
                                      y: (1 - g.centerY - g.height / 2) * canvas.height + 1,
                                      width: g.width * canvas.width, height: g.height * canvas.height - 1))
        pages.append(PreviewCard(id: captions.count, title: "엔딩", image: try finished(ending)))
        return pages
    }

    private static func context() throws -> CGContext {
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ReviewError("미리보기 화면을 만들 수 없습니다.")
        }
        ctx.interpolationQuality = .high
        return ctx
    }

    private static func finished(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw ReviewError("미리보기를 만들 수 없습니다.") }
        return image
    }

    private static func artwork(_ path: String, size: Int? = nil) throws -> CGImage {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReviewError("\(url.lastPathComponent) 파일을 열 수 없습니다.")
        }
        if let size, let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as CFDictionary) {
            return thumbnail
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReviewError("\(url.lastPathComponent) 이미지를 읽을 수 없습니다.")
        }
        return image
    }

    private static func drawBackground(_ image: CGImage, in ctx: CGContext, opacity: Double) {
        ctx.draw(image, in: canvas)
        dim(opacity, in: ctx)
    }

    private static func dim(_ opacity: Double, in ctx: CGContext) {
        ctx.setFillColor(gray: 0, alpha: opacity)
        ctx.fill(canvas)
    }

    private static func drawText(_ text: String, font name: String, size: Double, x: Double, y: Double,
                                 scaleX: Double = 1, scaleY: Double = 1, in ctx: CGContext) throws {
        guard !text.isEmpty else { return }
        let font = CTFontCreateWithName(name as CFString, size * fontScale, nil)
        guard (CTFontCopyPostScriptName(font) as String) == name else {
            throw ReviewError("지정된 글꼴 \(name)을 이 Mac에서 찾을 수 없습니다.")
        }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var offset = 0
        var lines: [CTLine] = []
        while offset < attributed.length {
            let length = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, canvas.width * 0.9 / scaleX))
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length)))
            offset += length
        }
        let leading = (CTFontGetAscent(font) + CTFontGetDescent(font)) * scaleY
        ctx.saveGState()
        ctx.translateBy(x: x * canvas.width, y: (1 - y) * canvas.height)
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let relativeY = (Double(lines.count - 1) / 2 - Double(index)) * leading / scaleY
            ctx.textPosition = CGPoint(x: -width / 2, y: (descent - ascent) / 2 + relativeY)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}
