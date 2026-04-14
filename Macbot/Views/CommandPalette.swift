import SwiftUI

// MARK: - Palette item

/// One row in the command palette. Either a global action (mode switch,
/// "new X") or a navigable object (notebook, page, canvas, chat). The
/// palette is the universal keyboard-first nav surface — all objects
/// across all modes can be reached without leaving the keyboard.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let category: Category
    let action: () -> Void

    enum Category: Int, Comparable {
        case action   = 0 // Switch modes, New <thing>
        case notebook = 1
        case page     = 2
        case canvas   = 3
        case chat     = 4

        var label: String {
            switch self {
            case .action:   return "Actions"
            case .notebook: return "Notebooks"
            case .page:     return "Pages"
            case .canvas:   return "Canvases"
            case .chat:     return "Chats"
            }
        }

        static func < (lhs: Category, rhs: Category) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

// MARK: - Palette view

/// Modal overlay invoked via Cmd+K. Fuzzy-searches across every
/// navigable object and every global action in the app.
struct CommandPalette: View {
    @Bindable var viewModel: ChatViewModel
    let items: [PaletteItem]
    let onSelect: (PaletteItem) -> Void
    let onDismiss: () -> Void

    @FocusState private var inputFocused: Bool
    @State private var selectedIndex: Int = 0

    /// Filtered + sorted items. Actions always appear first, then matches
    /// sorted by category. Empty query returns all actions + recent objects.
    private var filtered: [PaletteItem] {
        let q = viewModel.paletteQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let matches: [PaletteItem]
        if q.isEmpty {
            // Empty query: show all actions + a few recent objects per bucket.
            matches = items.filter { $0.category == .action }
                + items.filter { $0.category != .action }.prefix(15)
        } else {
            matches = items.filter {
                $0.title.lowercased().contains(q)
                    || ($0.subtitle?.lowercased().contains(q) ?? false)
            }
        }
        return matches.sorted { a, b in
            if a.category != b.category { return a.category < b.category }
            return a.title < b.title
        }
    }

    var body: some View {
        ZStack {
            // Scrim — click to dismiss
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            palette
                .frame(width: 560, height: 480)
                .background(.thickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MacbotDS.Colors.separator.opacity(0.6), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        }
        .onAppear {
            inputFocused = true
            selectedIndex = 0
        }
        .onChange(of: viewModel.paletteQuery) { _, _ in
            selectedIndex = 0
        }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
            Divider()
            footer
        }
    }

    private var searchField: some View {
        HStack(spacing: MacbotDS.Space.sm) {
            Image(systemName: "command")
                .font(.callout)
                .foregroundStyle(MacbotDS.Colors.textTer)
            TextField("Search anything — notebooks, pages, canvases, chats, actions", text: $viewModel.paletteQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(MacbotDS.Colors.textPri)
                .focused($inputFocused)
                .onSubmit(commitSelection)
                .onKeyPress(.escape) { onDismiss(); return .handled }
                .onKeyPress(.downArrow) {
                    selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedIndex = max(selectedIndex - 1, 0)
                    return .handled
                }
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.md)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let groups = groupedResults()
                    ForEach(PaletteItem.Category.allCases, id: \.self) { category in
                        if let items = groups[category], !items.isEmpty {
                            sectionHeader(category.label)
                            ForEach(items, id: \.id) { item in
                                paletteRow(item)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .padding(.vertical, MacbotDS.Space.xs)
            }
            .onChange(of: selectedIndex) { _, new in
                let flat = filtered
                guard new >= 0, new < flat.count else { return }
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(flat[new].id, anchor: .center)
                }
            }
        }
    }

    private func groupedResults() -> [PaletteItem.Category: [PaletteItem]] {
        Dictionary(grouping: filtered, by: { $0.category })
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .kerning(0.5)
            .foregroundStyle(MacbotDS.Colors.textTer)
            .padding(.horizontal, MacbotDS.Space.md)
            .padding(.vertical, MacbotDS.Space.xs)
    }

    private func paletteRow(_ item: PaletteItem) -> some View {
        let isSelected = indexOf(item) == selectedIndex
        return HStack(spacing: MacbotDS.Space.md) {
            Image(systemName: item.icon)
                .font(.callout)
                .foregroundStyle(isSelected ? MacbotDS.Colors.accent : MacbotDS.Colors.textSec)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(MacbotDS.Colors.textPri)
                    .lineLimit(1)
                if let sub = item.subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(MacbotDS.Colors.textTer)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.sm)
        .background(isSelected ? AnyShapeStyle(MacbotDS.Colors.accent.opacity(0.15)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item) }
        .onHover { hovering in
            if hovering, let idx = indexOf(item) { selectedIndex = idx }
        }
    }

    private func indexOf(_ item: PaletteItem) -> Int? {
        filtered.firstIndex(where: { $0.id == item.id })
    }

    private func commitSelection() {
        let list = filtered
        guard selectedIndex >= 0, selectedIndex < list.count else { return }
        onSelect(list[selectedIndex])
    }

    private var footer: some View {
        HStack(spacing: MacbotDS.Space.md) {
            footerHint(key: "↵", label: "Open")
            footerHint(key: "↑↓", label: "Navigate")
            footerHint(key: "⎋", label: "Dismiss")
            Spacer()
            Text("\(filtered.count) result\(filtered.count == 1 ? "" : "s")")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(MacbotDS.Colors.textTer)
        }
        .padding(.horizontal, MacbotDS.Space.md)
        .padding(.vertical, MacbotDS.Space.xs)
    }

    private func footerHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.weight(.medium))
                .foregroundStyle(MacbotDS.Colors.textSec)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(label)
                .font(.caption2)
                .foregroundStyle(MacbotDS.Colors.textTer)
        }
    }
}

// MARK: - CaseIterable helper (so we can ForEach Category for section order)

extension PaletteItem.Category: CaseIterable {}
