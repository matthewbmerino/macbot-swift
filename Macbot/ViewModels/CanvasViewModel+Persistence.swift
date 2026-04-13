import Foundation
import SwiftUI

extension CanvasViewModel {
    // MARK: - Save

    /// Debounced auto-save — waits 500ms after last mutation, then writes.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.persistCanvas()
        }
    }

    func persistCanvas() {
        guard let id = currentCanvasId else { return }
        canvasStore.saveCanvas(
            canvasId: id,
            nodes: nodes,
            edges: edges,
            groups: groups,
            viewportOffset: offset,
            viewportScale: scale
        )
    }

    // MARK: - Canvas lifecycle

    func loadCanvasList() {
        canvasList = canvasStore.listCanvases()
    }

    func createCanvas(title: String = "Untitled Canvas") {
        persistCanvas()
        let record = canvasStore.createCanvas(title: title)
        currentCanvasId = record.id
        nodes = []
        edges = []
        groups = []
        offset = .zero
        lastCommittedOffset = .zero
        scale = 1.0
        lastCommittedScale = 1.0
        clearSelection()
        loadCanvasList()
    }

    func switchCanvas(_ id: String) {
        guard id != currentCanvasId else { return }
        persistCanvas()
        loadCanvasContent(id: id)
        loadCanvasList()
    }

    func deleteCanvas(_ id: String) {
        canvasStore.deleteCanvas(id: id)
        if currentCanvasId == id {
            currentCanvasId = nil
            nodes = []
            edges = []
            groups = []
        }
        loadCanvasList()
    }

    func renameCanvas(_ id: String, title: String) {
        canvasStore.renameCanvas(id: id, title: title)
        loadCanvasList()
    }

    func ensureCanvas() {
        loadCanvasList()
        if let first = canvasList.first {
            loadCanvasContent(id: first.id)
        } else {
            let record = canvasStore.createCanvas(title: "Canvas")
            currentCanvasId = record.id
            loadCanvasList()
        }
    }

    func loadCanvasContent(id: String) {
        guard let data = canvasStore.loadCanvas(id: id) else { return }
        currentCanvasId = data.canvas.id
        nodes = data.nodes
        edges = data.edges
        groups = data.groups
        offset = CGSize(width: data.canvas.viewportOffsetX, height: data.canvas.viewportOffsetY)
        lastCommittedOffset = offset
        scale = data.canvas.viewportScale
        lastCommittedScale = scale
        clearSelection()
    }
}
