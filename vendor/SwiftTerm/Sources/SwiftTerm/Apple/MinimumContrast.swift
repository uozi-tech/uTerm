//
//  MinimumContrast.swift
//  SwiftTerm (uTerm vendored patch — see UTERM-PATCHES.md)
//
//  WCAG-style minimum-contrast enforcement for terminal cells, in the spirit
//  of xterm.js / VS Code `terminal.integrated.minimumContrastRatio`. Remote
//  prompts and TUIs frequently hardcode 256-color / true-color values that
//  were designed for dark backgrounds; those never go through the themable
//  16-color ANSI palette, so the only robust fix is clamping foreground
//  colors against their cell background at render time.
//
//  Unlike xterm.js (which blends toward black/white and therefore bleaches
//  hue), the adjustment here is hue-preserving: the foreground's OKLCH
//  lightness is moved toward the WCAG luminance target while hue stays fixed
//  and chroma only shrinks as far as the sRGB gamut requires. An amber prompt
//  segment gets a lighter/darker amber, not white/black.
//
#if os(macOS) || os(iOS) || os(visionOS) || os(tvOS)
import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public enum TerminalContrast {
    /// `TTColor` is internal to SwiftTerm; public API needs a public alias.
    #if os(macOS)
    public typealias PlatformColor = NSColor
    #else
    public typealias PlatformColor = UIColor
    #endif

    // MARK: sRGB / WCAG plumbing

    /// sRGB components of a color, each clamped to 0...1.
    static func srgbComponents(_ color: PlatformColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if os(macOS)
        guard let converted = color.usingColorSpace(.sRGB) else { return (0, 0, 0) }
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return (clamp(r), clamp(g), clamp(b))
    }

    static func linearize(_ v: CGFloat) -> CGFloat {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func delinearize(_ v: CGFloat) -> CGFloat {
        v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// WCAG 2.x relative luminance of a color.
    public static func relativeLuminance(_ color: PlatformColor) -> CGFloat {
        let c = srgbComponents(color)
        return relativeLuminance(r: c.r, g: c.g, b: c.b)
    }

    static func relativeLuminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        luminance(linearR: linearize(r), linearG: linearize(g), linearB: linearize(b))
    }

    static func luminance(linearR r: CGFloat, linearG g: CGFloat, linearB b: CGFloat) -> CGFloat {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG 2.x contrast ratio between two colors, in 1...21.
    public static func contrastRatio(_ a: PlatformColor, _ b: PlatformColor) -> CGFloat {
        contrastRatio(luminance: relativeLuminance(a), luminance: relativeLuminance(b))
    }

    static func contrastRatio(luminance la: CGFloat, luminance lb: CGFloat) -> CGFloat {
        (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    // MARK: OKLab / OKLCH (Björn Ottosson's sRGB matrices)

    struct OKLCH {
        var L: CGFloat   // perceptual lightness 0...1
        var C: CGFloat   // chroma
        var h: CGFloat   // hue, radians
    }

    private static func cubeRoot(_ v: CGFloat) -> CGFloat {
        v < 0 ? -pow(-v, 1.0 / 3.0) : pow(v, 1.0 / 3.0)
    }

    static func oklch(linearR r: CGFloat, linearG g: CGFloat, linearB b: CGFloat) -> OKLCH {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l3 = cubeRoot(l), m3 = cubeRoot(m), s3 = cubeRoot(s)
        let L = 0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3
        let a = 1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3
        let b2 = 0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3
        return OKLCH(L: L, C: sqrt(a * a + b2 * b2), h: atan2(b2, a))
    }

    /// OKLCH → linear sRGB, unclamped (components may fall outside 0...1
    /// when the requested chroma is out of gamut).
    static func linearSRGB(_ c: OKLCH) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let a = c.C * cos(c.h)
        let b = c.C * sin(c.h)
        let l3 = c.L + 0.3963377774 * a + 0.2158037573 * b
        let m3 = c.L - 0.1055613458 * a - 0.0638541728 * b
        let s3 = c.L - 0.0894841775 * a - 1.2914855480 * b
        let l = l3 * l3 * l3, m = m3 * m3 * m3, s = s3 * s3 * s3
        return (
            +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    private static func inGamut(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Bool {
        let eps: CGFloat = 0.0005
        return rgb.r >= -eps && rgb.r <= 1 + eps
            && rgb.g >= -eps && rgb.g <= 1 + eps
            && rgb.b >= -eps && rgb.b <= 1 + eps
    }

    /// Renders (L, h) with the largest chroma ≤ `maxChroma` that fits the
    /// sRGB gamut, returning clamped linear components.
    private static func fitChroma(L: CGFloat, h: CGFloat, maxChroma: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var rgb = linearSRGB(OKLCH(L: L, C: maxChroma, h: h))
        if !inGamut(rgb) {
            var lo: CGFloat = 0, hi = maxChroma
            for _ in 0..<12 {
                let mid = (lo + hi) / 2
                if inGamut(linearSRGB(OKLCH(L: L, C: mid, h: h))) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            rgb = linearSRGB(OKLCH(L: L, C: lo, h: h))
        }
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }
        return (clamp(rgb.r), clamp(rgb.g), clamp(rgb.b))
    }

    // MARK: contrast enforcement

    /// Returns `fg` adjusted until it reaches `ratio` against `bg`; returns
    /// `fg` unchanged when the contrast is already sufficient.
    ///
    /// Direction follows xterm.js `ensureContrastRatio` (darker foregrounds
    /// darken further, lighter ones lighten; if the preferred direction
    /// cannot reach the ratio the opposite one is tried and the better result
    /// wins), but the adjustment itself is hue-preserving: OKLCH lightness is
    /// binary-searched toward the WCAG luminance target with hue fixed and
    /// chroma capped to the original value and the sRGB gamut. Only at the
    /// extreme poles does the result degenerate to black/white.
    public static func ensureContrast(fg: PlatformColor, bg: PlatformColor, ratio: CGFloat) -> PlatformColor {
        guard ratio > 1 else { return fg }
        let bgY = relativeLuminance(bg)
        let fgC = srgbComponents(fg)
        let fgY = relativeLuminance(r: fgC.r, g: fgC.g, b: fgC.b)
        if contrastRatio(luminance: fgY, luminance: bgY) >= ratio {
            return fg
        }

        let base = oklch(linearR: linearize(fgC.r), linearG: linearize(fgC.g), linearB: linearize(fgC.b))

        // Walks OKLCH lightness from the original toward a pole until the
        // WCAG luminance target for the direction is met; hue stays fixed,
        // chroma shrinks only as the gamut demands.
        func attempt(lighten: Bool) -> (r: CGFloat, g: CGFloat, b: CGFloat, achieved: CGFloat) {
            let targetY = lighten ? min(ratio * (bgY + 0.05) - 0.05, 1)
                                  : max((bgY + 0.05) / ratio - 0.05, 0)
            let poleL: CGFloat = lighten ? 1 : 0
            func render(_ t: CGFloat) -> (rgb: (r: CGFloat, g: CGFloat, b: CGFloat), y: CGFloat) {
                let rgb = fitChroma(L: base.L + (poleL - base.L) * t, h: base.h, maxChroma: base.C)
                return (rgb, luminance(linearR: rgb.r, linearG: rgb.g, linearB: rgb.b))
            }
            var lo: CGFloat = 0, hi: CGFloat = 1
            if render(1).y.isOnTargetSide(of: targetY, lighten: lighten) {
                for _ in 0..<18 {
                    let mid = (lo + hi) / 2
                    if render(mid).y.isOnTargetSide(of: targetY, lighten: lighten) {
                        hi = mid
                    } else {
                        lo = mid
                    }
                }
            }
            // `hi` is the smallest step found that satisfies the target (or
            // the pole when even that falls short — best effort).
            let final = render(hi)
            let achieved = contrastRatio(luminance: final.y, luminance: bgY)
            return (delinearize(final.rgb.r), delinearize(final.rgb.g), delinearize(final.rgb.b), achieved)
        }

        // Adjustment direction keys off the BACKGROUND, not fg-vs-bg: lighten the
        // foreground on a dark/medium background (so prompt text reads bright on a
        // powerline segment), darken it only on a genuinely light background. If
        // lightening can't reach the ratio (light-gray segment), the opposite-
        // direction fallback below darkens instead.
        //
        // (xterm.js instead keys off whether the fg is lighter/darker than the bg.
        // That preserves a color's "intent" on clearly dark/light backgrounds, but
        // on a MEDIUM-gray segment a foreground sitting a hair below the bg gets
        // driven to pure black while one a hair above goes to white — e.g. a teal
        // path separator `ansi31` #3D6D7E on a #6D6D6D powerline segment collapsing
        // to #000206 while the bright path text lightens. Keying off the background
        // keeps every foreground on that segment moving the same, readable way.)
        let preferLighten = bgY < 0.5
        var best = attempt(lighten: preferLighten)
        if best.achieved < ratio - 0.01 {
            let opposite = attempt(lighten: !preferLighten)
            if opposite.achieved > best.achieved {
                best = opposite
            }
        }
        return TTColor.make(red: best.r, green: best.g, blue: best.b, alpha: 1)
    }
}

private extension CGFloat {
    /// Whether a luminance value sits on the satisfying side of `target`
    /// for the given adjustment direction.
    func isOnTargetSide(of target: CGFloat, lighten: Bool) -> Bool {
        lighten ? self >= target : self <= target
    }
}
#endif
