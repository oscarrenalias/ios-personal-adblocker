#!/usr/bin/env swift
// Regenerates the Regular-M glyph of the pause.{5,10,30,60} custom symbols
// from real font outlines (heavy rounded system font, Helvetica-Bold fallback).
//
//   swift scripts/make-pause-symbols.swift
//
// Each symbol is a thin ring with the number centred inside. Ring and digits
// are written as one path with fill-rule nonzero: the ring's inner circle
// winds opposite to its outer circle, and glyph outlines carry their own
// winding, so only the ring interior and the natural counters ('0', '6') are open.
import AppKit
import CoreText
import Foundation

let minutesList = [5, 10, 30, 60]
let outerRadius = 49.0
let ringWidth = 4.5
let centreY = -35.0          // ring centre, inside Regular-M (baseline 0, capline -70)
let targetHeight = 0.63 * 2 * outerRadius
let maxCornerRadius = outerRadius - ringWidth - 4.5   // margin inside the ring
let minCondense = 0.8        // narrowest horizontal squeeze before shrinking uniformly

func makeFont() -> CTFont {
    let base = NSFont.systemFont(ofSize: 100, weight: .heavy)
    if let desc = base.fontDescriptor.withDesign(.rounded),
       let rounded = NSFont(descriptor: desc, size: 100) {
        return rounded
    }
    return NSFont(name: "Helvetica-Bold", size: 100) ?? base
}

func num(_ v: Double) -> String {
    let s = String(format: "%.2f", v)
    return s.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
}

func circle(_ r: Double, cy: Double, clockwise: Bool) -> String {
    let sweep = clockwise ? 1 : 0
    return "M\(num(-r)) \(num(cy))a\(num(r)) \(num(r)) 0 1 \(sweep) \(num(2 * r)) 0a\(num(r)) \(num(r)) 0 1 \(sweep) \(num(-2 * r)) 0Z"
}

/// Path data for the digits of `text`, centred on (0, centreY), in SVG coordinates.
func digitsPath(_ text: String, font: CTFont) -> String {
    var chars = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    var advances = [CGSize](repeating: .zero, count: chars.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, chars.count)

    // Lay glyphs out in font units (y up), then take the union bounds.
    let combined = CGMutablePath()
    var x = 0.0
    for (i, g) in glyphs.enumerated() {
        if let p = CTFontCreatePathForGlyph(font, g, nil) {
            combined.addPath(p, transform: CGAffineTransform(translationX: x, y: 0))
        }
        x += Double(advances[i].width)
    }
    let b = combined.boundingBoxOfPath
    // All digits share one height so the 5 matches the others.
    let digitHeight = Double(CTFontGetCapHeight(font))
    var sy = targetHeight / digitHeight
    var sx = sy
    // Fit the bounding box's corner inside the ring; condense first, then shrink.
    func corner(_ sx: Double, _ sy: Double) -> Double {
        let hw = Double(b.width) * sx / 2, hh = digitHeight * sy / 2
        return (hw * hw + hh * hh).squareRoot()
    }
    while corner(sx, sy) > maxCornerRadius && sx > sy * minCondense { sx -= 0.001 }
    while corner(sx, sy) > maxCornerRadius { sx *= 0.999; sy *= 0.999 }

    let cx = Double(b.midX), cyFont = digitHeight / 2
    func pt(_ p: CGPoint) -> String {
        "\(num((Double(p.x) - cx) * sx)) \(num(centreY - (Double(p.y) - cyFont) * sy))"
    }
    var d = ""
    combined.applyWithBlock { e in
        let el = e.pointee
        let p = el.points
        switch el.type {
        case .moveToPoint: d += "M\(pt(p[0]))"
        case .addLineToPoint: d += "L\(pt(p[0]))"
        case .addQuadCurveToPoint: d += "Q\(pt(p[0])) \(pt(p[1]))"
        case .addCurveToPoint: d += "C\(pt(p[0])) \(pt(p[1])) \(pt(p[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(minutes: Int, pathData: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!--Generator: scripts/make-pause-symbols.swift-->
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <g id="Notes">
      <rect id="artboard" width="3300" height="2200" fill="white" opacity="0"/>
      <text transform="matrix(1 0 0 1 263 322)" font-family="'SF Pro Text'" font-size="13" font-weight="bold">Notes</text>
      <text transform="matrix(1 0 0 1 263 342)" font-family="'SF Pro Text'" font-size="13">Custom symbol: pause for \(minutes) minutes (Regular-M only).</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" x1="263" x2="3036" y1="696" y2="696" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
      <line id="Capline-S" x1="263" x2="3036" y1="625.541" y2="625.541" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
      <line id="Baseline-M" x1="263" x2="3036" y1="1126" y2="1126" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
      <line id="Capline-M" x1="263" x2="3036" y1="1056" y2="1056" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
      <line id="Baseline-L" x1="263" x2="3036" y1="1556" y2="1556" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
      <line id="Capline-L" x1="263" x2="3036" y1="1485.54" y2="1485.54" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"/>
     </g>
     <g id="Symbols">
      <g id="Regular-M" transform="matrix(1 0 0 1 1559.6 1126)">
       <path d="\(pathData)" fill-rule="nonzero"/>
      </g>
     </g>
    </svg>

    """
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let font = makeFont()
for m in minutesList {
    let ring = circle(outerRadius, cy: centreY, clockwise: true)
        + circle(outerRadius - ringWidth, cy: centreY, clockwise: false)
    let data = ring + digitsPath(String(m), font: font)
    let url = root.appendingPathComponent("ios/Widgets/Assets.xcassets/pause.\(m).symbolset/pause.\(m).svg")
    try svg(minutes: m, pathData: data).write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(url.path)")
}
