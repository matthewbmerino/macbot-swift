import SwiftUI

/// A small bird's-eye overview of all canvas nodes.
/// Shows nodes as colored dots and the current viewport as a translucent rectangle.
/// Click or drag to navigate the canvas instantly.
struct CanvasMinimap: View {
    let nodes: [CanvasNode]
    let groups: [CanvasGroup]
    let viewSize: CGSize
    let scale: CGFloat
    let offset: CGSize
    var onNavigate: (CGSize) -> Void

    private let minimapWidth: CGFloat = 180
    private let minimapHeight: CGFloat = 120

    var body: some View {
        let bounds = canvasBounds
        let mapScale = mapScale(for: bounds)

        Canvas { ctx, size in
            // Draw groups
            for group in groups {
                let rect = mapRect(
                    origin: group.position,
                    size: group.size,
                    bounds: bounds,
                    mapScale: mapScale,
                    canvasSize: size
                )
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(group.color.accentColor.opacity(0.1))
                )
                ctx.stroke(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(group.color.accentColor.opacity(0.25)),
                    lineWidth: 0.5
                )
            }

            // Draw nodes as dots
            for node in nodes {
                let pt = mapPoint(node.position, bounds: bounds, mapScale: mapScale, canvasSize: size)
                let dotSize: CGFloat = max(4, node.width * mapScale * 0.3)
                let rect = CGRect(
                    x: pt.x - dotSize / 2,
                    y: pt.y - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(node.color.accentColor)
                )
            }

            // Draw viewport rectangle
            let vpRect = viewportRect(bounds: bounds, mapScale: mapScale, canvasSize: size)
            ctx.stroke(
                Path(roundedRect: vpRect, cornerRadius: 2),
                with: .color(MacbotDS.Colors.accent),
                lineWidth: 1.5
            )
            ctx.fill(
                Path(roundedRect: vpRect, cornerRadius: 2),
                with: .color(MacbotDS.Colors.accent.opacity(0.08))
            )
        }
        .frame(width: minimapWidth, height: minimapHeight)
        .background(MacbotDS.Colors.bg.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MacbotDS.Radius.sm, style: .continuous)
                .stroke(MacbotDS.Colors.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    navigateToMinimapPoint(value.location)
                }
        )
    }

    // MARK: - Geometry

    private var canvasBounds: CGRect {
        guard !nodes.isEmpty else {
            return CGRect(x: -400, y: -300, width: 800, height: 600)
        }
        let padding: CGFloat = 100
        let minX = nodes.map(\.position.x).min()! - padding
        let maxX = nodes.map { $0.position.x + $0.width }.max()! + padding
        let minY = nodes.map(\.position.y).min()! - padding
        let maxY = nodes.map(\.position.y).max()! + padding
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func mapScale(for bounds: CGRect) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(minimapWidth / bounds.width, minimapHeight / bounds.height)
    }

    private func mapPoint(_ canvasPoint: CGPoint, bounds: CGRect, mapScale: CGFloat, canvasSize: CGSize) -> CGPoint {
        let cx = (canvasPoint.x - bounds.minX) * mapScale
        let cy = (canvasPoint.y - bounds.minY) * mapScale
        // Center the map content
        let contentW = bounds.width * mapScale
        let contentH = bounds.height * mapScale
        let ox = (canvasSize.width - contentW) / 2
        let oy = (canvasSize.height - contentH) / 2
        return CGPoint(x: cx + ox, y: cy + oy)
    }

    private func mapRect(origin: CGPoint, size: CGSize, bounds: CGRect, mapScale: CGFloat, canvasSize: CGSize) -> CGRect {
        let topLeft = mapPoint(origin, bounds: bounds, mapScale: mapScale, canvasSize: canvasSize)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: size.width * mapScale,
            height: size.height * mapScale
        )
    }

    private func viewportRect(bounds: CGRect, mapScale: CGFloat, canvasSize: CGSize) -> CGRect {
        // The viewport in canvas space: top-left = viewToCanvas(0,0), size = viewSize/scale
        let vpCanvasOrigin = CGPoint(
            x: -offset.width / scale,
            y: -offset.height / scale
        )
        let vpCanvasSize = CGSize(
            width: viewSize.width / scale,
            height: viewSize.height / scale
        )
        let topLeft = mapPoint(vpCanvasOrigin, bounds: bounds, mapScale: mapScale, canvasSize: canvasSize)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: vpCanvasSize.width * mapScale,
            height: vpCanvasSize.height * mapScale
        )
    }

    private func navigateToMinimapPoint(_ minimapPoint: CGPoint) {
        let bounds = canvasBounds
        let ms = mapScale(for: bounds)
        guard ms > 0 else { return }

        let contentW = bounds.width * ms
        let contentH = bounds.height * ms
        let ox = (minimapWidth - contentW) / 2
        let oy = (minimapHeight - contentH) / 2

        // Convert minimap point to canvas space
        let canvasX = (minimapPoint.x - ox) / ms + bounds.minX
        let canvasY = (minimapPoint.y - oy) / ms + bounds.minY

        // Center the viewport on this canvas point
        let newOffset = CGSize(
            width: viewSize.width / 2 - canvasX * scale,
            height: viewSize.height / 2 - canvasY * scale
        )
        onNavigate(newOffset)
    }
}
