import Foundation
import Observation

/// View model for the Notebook section — the third top-level destination
/// alongside Chat and Canvas. Owns the notebook list, the pages of the
/// currently-viewed notebook, and the live editor state for the open page.
///
/// Autosave mirrors `CanvasViewModel.scheduleSave`: a 500ms debounced task
/// that writes `currentContent` / `currentTitle` through `NotebookStore`.
/// Title and content have independent debounce tasks so one doesn't starve
/// the other during rapid edits.
@Observable
final class NotebookViewModel {
    let store = NotebookStore()

    // MARK: - State

    var notebooks: [NotebookRecord] = []
    var pages: [PageSummary] = []
    var currentNotebookId: String?
    var currentPageId: String?

    /// Live editor buffers — the source of truth while a page is open. Flushed
    /// to the store via debounced save tasks. The store round-trips when the
    /// user switches pages so these stay authoritative.
    var currentTitle: String = ""
    var currentContent: String = ""

    // MARK: - Save pipeline

    private var contentSaveTask: Task<Void, Never>?
    private var titleSaveTask: Task<Void, Never>?

    // MARK: - Bootstrap

    /// Called when the user first enters notebook mode. Loads notebooks,
    /// seeds a default one on first run, and opens the most recent page.
    func bootstrap() {
        notebooks = store.listNotebooks()
        if notebooks.isEmpty {
            if let first = store.createNotebook(title: "Personal") {
                notebooks = [first]
            }
        }
        let target = notebooks.first(where: { $0.id == currentNotebookId }) ?? notebooks.first
        if let target {
            selectNotebook(target.id)
        }
    }

    // MARK: - Notebook ops

    func selectNotebook(_ id: String) {
        flushPendingSaves()
        currentNotebookId = id
        pages = store.listPages(notebookId: id)
        // Open the most-recent page, or a fresh empty one if the notebook is empty.
        if let first = pages.first {
            loadPage(first.id)
        } else {
            createPage(inNotebook: id, openIt: true)
        }
    }

    func createNotebook(title: String = "New Notebook") {
        flushPendingSaves()
        guard let new = store.createNotebook(title: title) else { return }
        notebooks.append(new)
        selectNotebook(new.id)
    }

    func renameNotebook(id: String, to title: String) {
        store.renameNotebook(id: id, title: title)
        notebooks = store.listNotebooks()
    }

    func deleteNotebook(id: String) {
        store.deleteNotebook(id: id)
        notebooks = store.listNotebooks()
        // Cascade: pages are gone too.
        if currentNotebookId == id {
            currentNotebookId = nil
            currentPageId = nil
            pages = []
            currentTitle = ""
            currentContent = ""
            if let fallback = notebooks.first {
                selectNotebook(fallback.id)
            }
        }
    }

    // MARK: - Page ops

    @discardableResult
    func createPage(inNotebook notebookId: String, openIt: Bool = true) -> PageRecord? {
        flushPendingSaves()
        guard let page = store.createPage(notebookId: notebookId) else { return nil }
        // Refresh the list so position ordering is authoritative.
        pages = store.listPages(notebookId: notebookId)
        if openIt {
            loadPage(page.id)
        }
        return page
    }

    /// Create a new page in the currently-selected notebook. Used by Cmd+J.
    func createPageInCurrentNotebook() {
        if let id = currentNotebookId {
            createPage(inNotebook: id, openIt: true)
        } else if let first = notebooks.first {
            selectNotebook(first.id)
            createPage(inNotebook: first.id, openIt: true)
        }
    }

    func loadPage(_ id: String) {
        flushPendingSaves()
        guard let page = store.getPage(id: id) else { return }
        currentPageId = page.id
        currentTitle = page.title
        currentContent = page.content
    }

    /// Navigate to a page potentially in a different notebook. Used by the
    /// command palette's object-first jumps.
    func openPageAcrossNotebooks(pageId: String) {
        flushPendingSaves()
        guard let page = store.getPage(id: pageId) else { return }
        if currentNotebookId != page.notebookId {
            selectNotebook(page.notebookId)
        }
        loadPage(page.id)
    }

    func deletePage(_ id: String) {
        flushPendingSaves()
        store.deletePage(id: id)
        guard let notebookId = currentNotebookId else { return }
        pages = store.listPages(notebookId: notebookId)
        if currentPageId == id {
            if let next = pages.first {
                loadPage(next.id)
            } else {
                currentPageId = nil
                currentTitle = ""
                currentContent = ""
            }
        }
    }

    // MARK: - Autosave

    /// Called from the editor whenever `currentContent` mutates. Debounced so
    /// bursts of keystrokes collapse into one write.
    func scheduleContentSave() {
        contentSaveTask?.cancel()
        let id = currentPageId
        let content = currentContent
        contentSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let id, id == self.currentPageId else { return }
            self.store.updatePageContent(id: id, content: content)
            self.refreshCurrentNotebookPages()
        }
    }

    /// Called from the title field whenever `currentTitle` mutates.
    func scheduleTitleSave() {
        titleSaveTask?.cancel()
        let id = currentPageId
        let title = currentTitle
        titleSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let id, id == self.currentPageId else { return }
            let effective = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled"
                : title
            self.store.updatePageTitle(id: id, title: effective)
            self.refreshCurrentNotebookPages()
        }
    }

    /// Flush both debounce tasks synchronously — called before destructive
    /// navigation (switch page/notebook, delete) so we don't lose the
    /// in-flight edit.
    func flushPendingSaves() {
        if contentSaveTask != nil, let id = currentPageId {
            contentSaveTask?.cancel()
            contentSaveTask = nil
            store.updatePageContent(id: id, content: currentContent)
        }
        if titleSaveTask != nil, let id = currentPageId {
            titleSaveTask?.cancel()
            titleSaveTask = nil
            let effective = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled"
                : currentTitle
            store.updatePageTitle(id: id, title: effective)
        }
    }

    private func refreshCurrentNotebookPages() {
        if let id = currentNotebookId {
            pages = store.listPages(notebookId: id)
        }
    }
}
