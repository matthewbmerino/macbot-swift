#include <metal_stdlib>
using namespace metal;

// MARK: - Companion Orb SDF Shader
// A raymarched signed-distance-field metaball with fresnel rim lighting,
// angular color mixing, harmonic displacement, and cursor reactivity.

[[ stitchable ]] half4 companionOrb(
    float2 position,
    half4 currentColor,
    float time,
    float mood,
    float cursorDist,
    float cursorAngle,
    float color1r,
    float color1g,
    float color2r,
    float color2g
) {
    // Normalize position to -1..1 (position comes in as 0..1 from .colorEffect)
    float2 uv = (position - 0.5) * 2.0;
    float d = length(uv);
    float angle = atan2(uv.y, uv.x);

    // --- Harmonic displacement ---
    // Frequency increases with mood intensity (idle=slow, error=fast)
    float freq = mix(1.0, 5.0, mood / 5.0);
    float amp = mix(0.05, 0.09, mood / 5.0);

    // Primary wave: angular ripple around the sphere
    float displacement = sin(angle * 3.0 + time * freq) * amp;
    // Secondary wave: radial pulsation for depth
    displacement += sin(time * 1.3 + d * 7.0) * 0.025;
    // Tertiary wave: higher-frequency detail
    displacement += sin(angle * 5.0 - time * freq * 0.7) * amp * 0.35;

    // --- Cursor deformation (ferrofluid pull) ---
    float cursorPull = (1.0 - cursorDist) * 0.1;
    displacement += cursorPull * cos(angle - cursorAngle);
    // Add a subtle secondary lobe for more organic deformation
    displacement += cursorPull * 0.3 * cos(2.0 * (angle - cursorAngle));

    // --- SDF sphere with soft edge ---
    float edgeOuter = 0.72 + displacement;
    float edgeInner = 0.62 + displacement;
    float sphere = smoothstep(edgeOuter, edgeInner, d);

    // Early out for pixels well outside the orb (performance + clean alpha)
    if (d > 1.2) {
        return half4(0.0);
    }

    // --- Fresnel rim lighting ---
    // Stronger rim = more "glass marble" appearance
    float rimFactor = saturate(d / (0.68 + displacement));
    float rim = pow(rimFactor, 4.0) * sphere;

    // --- Color construction ---
    // Derive full RGB from individual float inputs (r,g supplied; b derived for richness)
    half3 c1 = half3(color1r, color1g, saturate(1.1 - color1r * 0.5));
    half3 c2 = half3(color2r, color2g, saturate(0.9 - color2r * 0.3));

    // --- Angular color mixing (aurora effect) ---
    float colorMix = 0.5 + 0.5 * sin(angle * 2.0 + time * 0.4);
    float colorMix2 = 0.5 + 0.5 * sin(angle * 3.0 - time * 0.6 + 1.5);
    half3 col = mix(c1, c2, half(colorMix));
    // Blend in a brightened version for shimmer
    half3 shimmer = mix(c2, c1, half(colorMix2)) * 1.15;
    col = mix(col, shimmer, half(0.2));

    // --- Fresnel rim contribution ---
    // Rim adds white-ish glow biased toward the primary color
    half3 rimColor = mix(half3(1.0, 1.0, 1.0), c1, half(0.3));
    col += rimColor * half(rim * 0.55);

    // --- Specular highlight (top-left light source) ---
    float2 lightDir = normalize(float2(-0.4, -0.5));
    float2 surfNorm = normalize(uv);
    float specAngle = dot(surfNorm, -lightDir);
    float spec = pow(saturate(specAngle), 12.0) * sphere;
    col += half3(spec * 0.4);

    // --- Secondary specular (subtle bottom-right fill) ---
    float2 fillDir = normalize(float2(0.5, 0.6));
    float fillSpec = pow(saturate(dot(surfNorm, -fillDir)), 8.0) * sphere;
    col += c2 * half(fillSpec * 0.15);

    // --- Inner glow / subsurface scattering approximation ---
    float innerGlow = exp(-d * d * 4.0) * sphere * 0.15;
    col += c1 * half(innerGlow);

    // --- Outer halo glow (extends beyond the sphere) ---
    float halo = exp(-d * 3.0) * 0.1;
    half3 haloColor = c1 * 0.7 + c2 * 0.3;

    // --- Depth shading (subtle darkening toward edges for volume) ---
    float depthShade = mix(1.0, 0.75, pow(rimFactor, 2.0));
    col *= half(depthShade);

    // --- Composite ---
    half3 finalColor = col * half(sphere) + haloColor * half(halo);
    half finalAlpha = half(saturate(sphere + halo * 0.25));

    return half4(finalColor, finalAlpha);
}
