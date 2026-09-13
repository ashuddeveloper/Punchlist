import CoreGraphics
import Foundation
import ImageIO
import PunchlistCore
import UIKit

// ============================================================================
// Drawing a ReportDocument.
//
// This file makes no layout decisions. Every position, font, size and line
// break arrived resolved in the IR; the renderer's whole job is to put ink
// where it is told. That is what makes the layout hash a real guarantee rather
// than a hopeful one — there is no second opinion here to drift from the first.
//
// Budget: 40 pages and 150 photos in under 15 seconds on a three-year-old
// midrange phone. The cost is almost entirely image decode, so:
//
//   * one photo is decoded at a time and released before the next
//   * each is downsampled to the pixels the page frame can actually show at
//     300dpi, not to its stored 2048px
//   * pages are drawn in order and progress is reported per page, so the UI
//     shows "page 12 of 40" rather than an indeterminate spinner
// ============================================================================

public struct ReportRenderProgress: Sendable {
    public let page: Int
    public let totalPages: Int
    public var fraction: Double {
        totalPages == 0 ? 0 : Double(page) / Double(totalPages)
    }
}

enum PDFRenderError: Error, LocalizedError {
    case couldNotWrite(String)

    var errorDescription: String? {
        switch self {
        case .couldNotWrite(let detail):
            return "The report could not be written to this phone. \(detail)"
        }
    }
}

struct PDFRenderer {
    let store: MediaStore

    /// Print resolution. Photos are downsampled to the pixels the frame can
    /// show at this density; anything beyond it is bytes the client's printer
    /// will discard and seconds the inspector spends waiting in a driveway.
    private let targetDPI: CGFloat = 300

    /// Render to a file.
    ///
    /// To a file rather than to `Data`: a 40-page report with 150 photos is
    /// tens of megabytes, and holding it in memory alongside the decode buffers
    /// is the difference between finishing and being jetsammed.
    func render(
        document: ReportDocument,
        to url: URL,
        onProgress: @escaping @Sendable (ReportRenderProgress) -> Void = { _ in }
    ) throws {
        let pageRect = CGRect(
            x: 0, y: 0,
            width: document.pageSize.width.doubleValue,
            height: document.pageSize.height.doubleValue)

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            // Deterministic where the API allows it. PDFKit still stamps a
            // CreationDate and a document id that we cannot suppress, which is
            // exactly why the guarantee lives in the IR hash and not in the
            // PDF bytes.
            kCGPDFContextTitle as String: document.metadata.inspectionID,
            kCGPDFContextCreator as String: "Punchlist",
        ]

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        do {
            try renderer.writePDF(to: url) { context in
                for (index, page) in document.pages.enumerated() {
                    autoreleasepool {
                        context.beginPage()
                        draw(page: page, in: context.cgContext, pageRect: pageRect)
                    }
                    onProgress(ReportRenderProgress(
                        page: index + 1, totalPages: document.pages.count))
                }
            }
        } catch {
            throw PDFRenderError.couldNotWrite(error.localizedDescription)
        }
    }

    // MARK: Page

    private func draw(page: ReportPage, in context: CGContext, pageRect: CGRect) {
        // Paper. Without it the page is transparent, which prints white but
        // looks wrong in every viewer that renders a checkerboard behind it.
        context.setFillColor(RGB.paper.cgColor)
        context.fill(pageRect)

        for element in page.elements {
            switch element {
            case .text(let run): draw(run)
            case .rule(let rule): draw(rule, in: context)
            case .box(let box): draw(box, in: context)
            case .mark(let mark): draw(mark, in: context)
            case .photo(let photo): draw(photo, in: context)
            }
        }
    }

    private func draw(_ run: ReportElement.TextRun) {
        // The IR's fonts are the PDF base-14 faces, which UIFont resolves by
        // their PostScript names. Using them is what makes the widths this text
        // was measured with the widths it is actually drawn with.
        let font = UIFont(name: run.font.rawValue, size: run.size.doubleValue)
            ?? UIFont.systemFont(ofSize: run.size.doubleValue)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(cgColor: run.color.cgColor),
        ]
        // Drawn at a point, not into a rect: a rect would let UIKit re-wrap,
        // and re-wrapping is precisely the decision this renderer must not make.
        (run.string as NSString).draw(
            at: CGPoint(x: run.origin.x.doubleValue, y: run.origin.y.doubleValue),
            withAttributes: attributes)
    }

    private func draw(_ rule: ReportElement.Rule, in context: CGContext) {
        context.setFillColor(rule.color.cgColor)
        context.fill(rule.frame.cgRect)
    }

    private func draw(_ box: ReportElement.Box, in context: CGContext) {
        if let fill = box.fill {
            context.setFillColor(fill.cgColor)
            context.fill(box.frame.cgRect)
        }
        if let stroke = box.stroke {
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(box.strokeWidth.doubleValue)
            context.stroke(box.frame.cgRect)
        }
    }

    /// Severity marks. Drawn as filled paths rather than glyphs so they survive
    /// a black-and-white photocopy as distinct shapes — which is the entire
    /// reason severity is not encoded by colour alone.
    private func draw(_ mark: ReportElement.Mark, in context: CGContext) {
        let rect = mark.frame.cgRect
        context.setFillColor(mark.color.cgColor)
        let path = CGMutablePath()

        switch mark.shape {
        case .circle:
            path.addEllipse(in: rect)
        case .triangle:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        case .diamond:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        case .octagon:
            let inset = rect.width * 0.29
            let points = [
                CGPoint(x: rect.minX + inset, y: rect.minY),
                CGPoint(x: rect.maxX - inset, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY + inset),
                CGPoint(x: rect.maxX, y: rect.maxY - inset),
                CGPoint(x: rect.maxX - inset, y: rect.maxY),
                CGPoint(x: rect.minX + inset, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY - inset),
                CGPoint(x: rect.minX, y: rect.minY + inset),
            ]
            path.addLines(between: points)
            path.closeSubpath()
        }
        context.addPath(path)
        context.fillPath()
    }

    // MARK: Photos

    private func draw(_ placement: ReportElement.PhotoPlacement, in context: CGContext) {
        let frame = placement.frame.cgRect

        // A placeholder rather than a gap. A missing file is a bug, but a
        // silent hole in a client's report is a worse one — this way the
        // inspector sees it in the preview before it is delivered.
        guard let image = loadDownsampled(placement: placement) else {
            context.setFillColor(RGB(hex: 0xEDEEEA).cgColor)
            context.fill(frame)
            return
        }

        // Aspect fill inside the fixed frame, then clip. The frame is fixed by
        // the layout engine so that page count cannot depend on image
        // dimensions; fitting rather than filling would leave uneven white
        // margins that make a photo grid look broken.
        let imageAspect = CGFloat(image.width) / CGFloat(image.height)
        let frameAspect = frame.width / frame.height
        var drawRect = frame
        if imageAspect > frameAspect {
            let width = frame.height * imageAspect
            drawRect = CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: frame.height)
        } else {
            let height = frame.width / imageAspect
            drawRect = CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
        }

        context.saveGState()
        context.clip(to: frame)
        // Core Graphics draws images bottom-up; without the flip every photo in
        // the report is upside down.
        context.translateBy(x: 0, y: drawRect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: drawRect)
        context.restoreGState()
    }

    /// Decode only the pixels the page can show.
    ///
    /// A 2048px JPEG drawn into a 250pt frame at 300dpi needs ~1040px. Decoding
    /// the full image would allocate four times the bitmap for no visible
    /// difference, and 150 of those is what turns a 12-second render into a
    /// jetsam.
    private func loadDownsampled(placement: ReportElement.PhotoPlacement) -> CGImage? {
        let url = store.url(forRelativePath: placement.relativePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let maxPixels = Int(max(
            placement.frame.width.doubleValue,
            placement.frame.height.doubleValue) / 72 * targetDPI)

        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary)
    }
}

// MARK: - Bridging

extension RGB {
    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: 1)
    }
}

extension Rect {
    var cgRect: CGRect {
        CGRect(
            x: x.doubleValue, y: y.doubleValue,
            width: width.doubleValue, height: height.doubleValue)
    }
}
