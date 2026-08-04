#!/usr/bin/env swift

import Foundation
import CoreGraphics
import CoreText
import ImageIO

let W: CGFloat = 660
let H: CGFloat = 480
let scale: CGFloat = 2
let pxW = Int(W * scale)
let pxH = Int(H * scale)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: pxW, height: pxH,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext") }

ctx.scaleBy(x: scale, y: scale)

// ──────────────────────────────────────────────
// COLORS
// ──────────────────────────────────────────────
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r/255, g/255, b/255, a])!
}

let titleColor     = rgb(32, 36, 44)
let subtitleColor  = rgb(110, 116, 126)
let arrowColor     = rgb(110, 116, 126, 0.45)
let markColor      = rgb(32, 36, 44)
let ruleColor      = rgb(32, 36, 44, 0.12)

// ──────────────────────────────────────────────
// DIAMOND MARK
// ──────────────────────────────────────────────
func drawDiamond(center: CGPoint, size: CGFloat, lineWidth: CGFloat, color: CGColor, alpha: CGFloat = 1) {
    let side = size / sqrt(2)
    let cornerR = side * 0.22
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: .pi / 4)
    let rect = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
    let path = CGPath(roundedRect: rect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(lineWidth)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

// ──────────────────────────────────────────────
// TEXT HELPER
// ──────────────────────────────────────────────
func drawText(
    _ text: String, at point: CGPoint,
    fontName: String, fontSize: CGFloat,
    color: CGColor, centered: Bool = false, tracking: CGFloat = 0
) {
    let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
    var attrs: [String: Any] = [
        kCTFontAttributeName as String: font,
        kCTForegroundColorAttributeName as String: color
    ]
    if tracking != 0 { attrs[kCTKernAttributeName as String] = tracking }
    let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrStr)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    ctx.saveGState()
    ctx.textPosition = centered
        ? CGPoint(x: point.x - bounds.width / 2, y: point.y)
        : point
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// ──────────────────────────────────────────────
// 1. BACKGROUND — #EEE8D5 beige → white gradient
// ──────────────────────────────────────────────
let beige = rgb(238, 232, 213)
let white = rgb(255, 255, 255)
let bgGrad = CGGradient(
    colorsSpace: colorSpace,
    colors: [white, beige] as CFArray,
    locations: [0.0, 1.0]
)!
ctx.drawLinearGradient(
    bgGrad,
    start: CGPoint(x: W / 2, y: H),
    end: CGPoint(x: W / 2, y: 0),
    options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
)

// ──────────────────────────────────────────────
// 2. LARGE DECORATIVE DIAMOND (bottom, very subtle)
// ──────────────────────────────────────────────
drawDiamond(
    center: CGPoint(x: W / 2, y: -25),
    size: 360, lineWidth: 30,
    color: markColor, alpha: 0.04
)

// ──────────────────────────────────────────────
// 3. CENTERED BRAND LOCKUP (diamond + title + rule + subtitle)
// ──────────────────────────────────────────────

// Diamond mark — hero size, centered
let heroY: CGFloat = H - 55
drawDiamond(center: CGPoint(x: W / 2, y: heroY), size: 44, lineWidth: 3.6, color: markColor)

// Title — same font family as wordmark, bold weight, generous tracking
drawText(
    "Resonant",
    at: CGPoint(x: W / 2, y: heroY - 90),
    fontName: "AvenirNext-DemiBold",
    fontSize: 38,
    color: titleColor,
    centered: true,
    tracking: 5
)

// Thin rule accent
let ruleY = heroY - 106
let ruleW: CGFloat = 40
ctx.saveGState()
ctx.setStrokeColor(ruleColor)
ctx.setLineWidth(0.8)
ctx.move(to: CGPoint(x: W / 2 - ruleW / 2, y: ruleY))
ctx.addLine(to: CGPoint(x: W / 2 + ruleW / 2, y: ruleY))
ctx.strokePath()
ctx.restoreGState()

// Subtitle
drawText(
    "Drag Resonant into Applications to install",
    at: CGPoint(x: W / 2, y: ruleY - 22),
    fontName: "AvenirNext-Regular",
    fontSize: 13,
    color: subtitleColor,
    centered: true,
    tracking: 0.3
)

// ──────────────────────────────────────────────
// 4. DASHED ARROW (Resonant.app LEFT → Applications RIGHT)
// ──────────────────────────────────────────────
// Finder positions: App (175, 300) → CG (175, 180)
//                   Applications (485, 300) → CG (485, 180)
let aStart = CGPoint(x: 224, y: 188)
let aEnd   = CGPoint(x: 438, y: 188)
let aCtrl  = CGPoint(x: (aStart.x + aEnd.x) / 2, y: 238)

ctx.saveGState()
ctx.setStrokeColor(arrowColor)
ctx.setLineWidth(1.2)
ctx.setLineCap(.round)
ctx.setLineDash(phase: 0, lengths: [6, 5])

let arrow = CGMutablePath()
arrow.move(to: aStart)
arrow.addQuadCurve(to: aEnd, control: aCtrl)
ctx.addPath(arrow)
ctx.strokePath()

// Arrowhead
ctx.setLineDash(phase: 0, lengths: [])
let tX = aEnd.x - aCtrl.x, tY = aEnd.y - aCtrl.y
let tLen = hypot(tX, tY)
let ux = tX / tLen, uy = tY / tLen
let hLen: CGFloat = 8
let hAng: CGFloat = .pi / 6
func rot(_ vx: CGFloat, _ vy: CGFloat, _ a: CGFloat) -> (CGFloat, CGFloat) {
    (vx * cos(a) - vy * sin(a), vx * sin(a) + vy * cos(a))
}
let (r1x, r1y) = rot(-ux, -uy, hAng)
let (r2x, r2y) = rot(-ux, -uy, -hAng)
ctx.move(to: CGPoint(x: aEnd.x + r1x * hLen, y: aEnd.y + r1y * hLen))
ctx.addLine(to: aEnd)
ctx.addLine(to: CGPoint(x: aEnd.x + r2x * hLen, y: aEnd.y + r2y * hLen))
ctx.strokePath()
ctx.restoreGState()

// ──────────────────────────────────────────────
// SAVE
// ──────────────────────────────────────────────
guard let cgImage = ctx.makeImage() else { fatalError("CGImage") }
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : scriptDir.appendingPathComponent("dmg_background.png").path
let outputURL = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL, "public.png" as CFString, 1, nil
) else { fatalError("Dest") }
let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
guard CGImageDestinationFinalize(dest) else { fatalError("Write") }
print("✓ \(pxW)×\(pxH)px @2x → \(outputPath)")
