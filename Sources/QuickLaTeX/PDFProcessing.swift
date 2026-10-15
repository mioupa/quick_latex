import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct QLError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Raw TeX output plus the measured ink bounding box (PDF page coordinates, points).
struct RawRender {
    var pdfData: Data
    var mediaBox: CGRect
    var inkBox: CGRect
}

private struct OpenedPDF {
    let doc: CGPDFDocument
    let page: CGPDFPage
    let mediaBox: CGRect
}

enum PDFProcessing {
    private static func open(_ data: Data) throws -> OpenedPDF {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { throw QLError("PDFを開けません") }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { throw QLError("PDFのサイズが不正です") }
        return OpenedPDF(doc: doc, page: page, mediaBox: box)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: 1. ink bounding box

    /// Rasterise page 1 at R px/pt on a transparent background and find the alpha>0 bounding box.
    static func analyze(pdfData: Data) throws -> RawRender {
        let o = try open(pdfData)
        let box = o.mediaBox
        let w = Double(box.width), h = Double(box.height)
        let r = min(8.0, (30e6 / (w * h)).squareRoot())
        let pxW = max(1, Int((w * r).rounded(.up)))
        let pxH = max(1, Int((h * r).rounded(.up)))

        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data else { throw QLError("ビットマップを作成できません") }
        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: CGFloat(r), y: CGFloat(r))
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(o.page)

        let bpr = ctx.bytesPerRow
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var minX = pxW, maxX = -1, minY = pxH, maxY = -1
        for y in 0..<pxH {
            let row = bytes + y * bpr
            var x = 0
            var rowHit = false
            while x < pxW {
                if row[x * 4 + 3] != 0 {
                    if x < minX { minX = x }
                    rowHit = true
                    break
                }
                x += 1
            }
            if rowHit {
                if y < minY { minY = y }
                maxY = y
                var xr = pxW - 1
                while xr > x {
                    if row[xr * 4 + 3] != 0 { break }
                    xr -= 1
                }
                if xr > maxX { maxX = xr }
                if x > maxX { maxX = x }
            }
        }
        guard maxX >= 0, maxY >= 0 else { throw QLError("出力が空です") }

        // Memory row 0 is the top of the image; user space has its origin at the bottom-left.
        let rr = CGFloat(r)
        let x0 = CGFloat(minX) / rr + box.minX
        let x1 = CGFloat(maxX + 1) / rr + box.minX
        let y0 = CGFloat(pxH - (maxY + 1)) / rr + box.minY
        let y1 = CGFloat(pxH - minY) / rr + box.minY
        let e = 1 / rr
        let ink = CGRect(x: x0 - e, y: y0 - e, width: (x1 - x0) + 2 * e, height: (y1 - y0) + 2 * e)
        return RawRender(pdfData: pdfData, mediaBox: box, inkBox: ink)
    }

    // MARK: 2/3. crop + scale to vector PDF

    /// Output size in points for the given settings.
    static func outputSize(raw: RawRender, fontSize: Double, padding: Double) -> CGSize {
        let scale = CGFloat(fontSize / 10)
        let pad = CGFloat(padding) / scale
        return CGSize(width: (raw.inkBox.width + 2 * pad) * scale, height: (raw.inkBox.height + 2 * pad) * scale)
    }

    static func finalize(raw: RawRender, fontSize: Double, padding: Double) throws -> Data {
        let o = try open(raw.pdfData)
        let scale = CGFloat(fontSize / 10)
        let pad = CGFloat(padding) / scale
        let size = outputSize(raw: raw, fontSize: fontSize, padding: padding)

        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { throw QLError("PDF出力を作成できません") }
        var mediaBox = CGRect(origin: .zero, size: size)
        let info: [CFString: Any] = [kCGPDFContextCreator: "Quick LaTeX" as CFString]
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw QLError("PDFコンテキストを作成できません")
        }
        ctx.beginPDFPage(nil)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -(raw.inkBox.minX - pad), y: -(raw.inkBox.minY - pad))
        ctx.drawPDFPage(o.page)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    // MARK: 4. PNG

    /// Render the final PDF at up to 4 px/pt (capped at ~40M pixels) with matching DPI metadata.
    static func pngData(fromPDF data: Data) throws -> Data {
        let o = try open(data)
        let box = o.mediaBox
        let w = Double(box.width), h = Double(box.height)
        let k = min(4.0, (40e6 / (w * h)).squareRoot())
        let pxW = max(1, Int((w * k).rounded(.up)))
        let pxH = max(1, Int((h * k).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw QLError("PNG用ビットマップを作成できません")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: CGFloat(pxW) / box.width, y: CGFloat(pxH) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(o.page)
        guard let image = ctx.makeImage() else { throw QLError("PNG画像を作成できません") }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw QLError("PNGエンコーダを作成できません")
        }
        let dpi = 72.0 * k
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw QLError("PNGのエンコードに失敗しました") }
        return out as Data
    }
}
