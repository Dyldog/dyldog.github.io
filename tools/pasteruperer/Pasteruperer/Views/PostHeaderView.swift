import SwiftUI

struct PostHeaderView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingCalendar = false
    @State private var newCategory = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            TextField("Title", text: $model.draft.title, prompt: Text("Untitled").foregroundStyle(Theme.ink.opacity(0.25)), axis: .vertical)
                .font(Theme.display(34))
                .textFieldStyle(.plain)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Date")
                    HStack(spacing: 8) {
                        DatePicker("Date", selection: $model.draft.date, displayedComponents: [.date, .hourAndMinute])
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                        Button { isShowingCalendar.toggle() } label: {
                            Image(systemName: "calendar")
                        }
                        .help("Pick a date from a calendar")
                        .popover(isPresented: $isShowingCalendar, arrowEdge: .bottom) {
                            DatePicker("Date", selection: $model.draft.date, displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .labelsHidden()
                                .padding()
                        }
                        Button("Now") { model.draft.date = Date() }
                            .buttonStyle(StickerButtonStyle(color: Theme.cyan, tilt: .degrees(1.5)))
                    }
                }
                GridRow {
                    label("Slug")
                    TextField(model.draft.autoSlug.isEmpty ? "post-slug" : model.draft.autoSlug, text: $model.draft.customSlug)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .help("Used for the file name and URL. Leave empty to use the title.")
                }
                GridRow {
                    label("Categories")
                    FlowLayout(spacing: 6) {
                        ForEach(model.allCategories, id: \.self) { category in
                            CategoryChip(
                                name: category,
                                position: model.draft.categories.firstIndex(of: category)
                            ) { model.toggleCategory(category) }
                        }
                        TextField("New category", text: $newCategory)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .onSubmit {
                                model.addCategory(newCategory)
                                newCategory = ""
                            }
                    }
                }
                if let builder = model.makeBuilder(), !builder.slug.isEmpty {
                    GridRow {
                        label("URL")
                        Text((model.repo?.siteURL() ?? "") + builder.postURL)
                            .font(.callout.monospaced())
                            .foregroundStyle(Theme.ink.opacity(0.6))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        StencilLabel(text)
            .gridColumnAlignment(.trailing)
    }
}

private struct CategoryChip: View {
    let name: String
    /// Index in the draft's categories, or nil when not selected.
    let position: Int?
    let action: () -> Void

    var body: some View {
        let selected = position != nil
        Button(action: action) {
            Text(name)
                .font(Theme.marker(16))
                .padding(.horizontal, 11)
                .padding(.vertical, 2)
                .foregroundStyle(Theme.ink.opacity(selected ? 1 : 0.55))
                .background(selected ? Theme.neon(for: name) : Color.clear, in: RoundedRectangle(cornerRadius: 3))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Theme.ink.opacity(selected ? 1 : 0.35), style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: selected ? [] : [4, 3]))
                }
                .rotationEffect(Theme.tilt(for: name))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(position != nil ? .isSelected : [])
        .help(position != nil ? "Remove \(name)" : "Add \(name)")
    }
}

/// Lays children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = rows[rows.count - 1].width + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if !rows[rows.count - 1].indices.isEmpty && proposedWidth > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
