#!/usr/bin/env swift
// Icon generator (M20 final "N"): CoreGraphics offscreen render of a 1024px PNG (no window server or Xcode needed)
// Design: dark graphite glass base + cyan→blue gradient geometric N: two bars = dual panes, the slash = the divider (user decision 2026-08-26)
// Usage: swift scripts/generate-icon.swift Support/icon_1024.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/icon_1024.png"
let S: CGFloat = 1024

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rounded(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// macOS icon grid: the shape takes about 824 of the 1024 canvas, with margin all around
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(rounded(plate, 184))
ctx.clip()

// Base: graphite glass (near black with a blue tint), lighter on top, darker below
let bg = CGGradient(colorsSpace: cs, colors: [
    rgba(0.10, 0.11, 0.14, 1), rgba(0.045, 0.05, 0.07, 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.minY), options: [])

// N: the two bars + slash merged into one path and gradient-filled once (winding matches CGPath(roundedRect:),
// avoiding holes from nonzero winding cancellation; a single fill has no seams or double shadows)
let inset = plate.insetBy(dx: 190, dy: 190)
let barW = inset.width * 0.26
let n = CGMutablePath()
n.addPath(rounded(CGRect(x: inset.minX, y: inset.minY, width: barW, height: inset.height), barW / 2))
n.addPath(rounded(CGRect(x: inset.maxX - barW, y: inset.minY, width: barW, height: inset.height), barW / 2))
let t: CGFloat = barW * 0.92
n.move(to: CGPoint(x: inset.minX + barW * 0.35 + t, y: inset.maxY - barW * 0.5))
n.addLine(to: CGPoint(x: inset.minX + barW * 0.35, y: inset.maxY - barW * 0.5))
n.addLine(to: CGPoint(x: inset.maxX - barW * 0.35 - t, y: inset.minY + barW * 0.5))
n.addLine(to: CGPoint(x: inset.maxX - barW * 0.35, y: inset.minY + barW * 0.5))
n.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgba(0.1, 0.55, 1, 0.5))
ctx.addPath(n)
ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [
    rgba(0.42, 0.83, 1.00, 1), rgba(0.04, 0.52, 1.00, 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: inset.midX, y: inset.maxY),
                       end: CGPoint(x: inset.midX, y: inset.minY), options: [])
ctx.restoreGState()

// Top glass sheen (single light source from above)
let sheen = CGGradient(colorsSpace: cs, colors: [rgba(1, 1, 1, 0.08), rgba(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.maxY - 280), options: [])

ctx.restoreGState()
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
print("Generated \(out)")
