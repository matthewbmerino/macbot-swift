import SwiftUI

// MARK: - Metal Shader Orb View

/// Renders the companion orb using a Metal SDF shader via SwiftUI's
/// `.colorEffect()` modifier. The shader produces a raymarched metaball
/// with fresnel rim lighting, angular color mixing, harmonic displacement,
/// and cursor-reactive deformation.

struct OrbShaderView: View {
    let mood: CompanionMood
    let cursorDistance: CGFloat   // 0..1 normalized distance from cursor to orb center
    let cursorAngle: CGFloat     // angle from orb center to cursor in radians
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            orbCanvas(time: Float(timeline.date.timeIntervalSinceReferenceDate))
        }
    }

    @ViewBuilder
    private func orbCanvas(time: Float) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: size, height: size)
            .colorEffect(
                ShaderLibrary.companionOrb(
                    .float(time),
                    .float(mood.shaderIndex),
                    .float(Float(cursorDistance)),
                    .float(Float(cursorAngle)),
                    .float(mood.color1.x), .float(mood.color1.y),
                    .float(mood.color2.x), .float(mood.color2.y)
                )
            )
    }
}

// MARK: - CompanionMood Shader Extensions

extension CompanionMood {
    /// Maps each mood to a float index for the shader's frequency/amplitude curves.
    var shaderIndex: Float {
        switch self {
        case .idle:      return 0
        case .listening: return 1
        case .thinking:  return 2
        case .excited:   return 3
        case .sleeping:  return 4
        case .error:     return 5
        }
    }

    /// Primary mood color encoded as (red, green) — blue is derived in the shader.
    var color1: SIMD2<Float> {
        switch self {
        case .idle:      return SIMD2(0.35, 0.65)   // soft blue
        case .listening: return SIMD2(0.4, 0.55)    // brighter blue
        case .thinking:  return SIMD2(0.6, 0.45)    // lavender
        case .excited:   return SIMD2(0.95, 0.6)    // amber
        case .sleeping:  return SIMD2(0.45, 0.45)   // gray
        case .error:     return SIMD2(0.95, 0.35)   // red
        }
    }

    /// Secondary mood color encoded as (red, green) — blue is derived in the shader.
    var color2: SIMD2<Float> {
        switch self {
        case .idle:      return SIMD2(0.3, 0.85)    // teal accent
        case .listening: return SIMD2(0.55, 0.4)    // indigo
        case .thinking:  return SIMD2(0.85, 0.35)   // magenta
        case .excited:   return SIMD2(1.0, 0.4)     // coral
        case .sleeping:  return SIMD2(0.35, 0.35)   // darker gray
        case .error:     return SIMD2(0.85, 0.2)    // deeper red
        }
    }
}
