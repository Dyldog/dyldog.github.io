import SwiftUI
import Combine

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section {
                ForEach(model.sortedDrafts) { draft in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(subtitle(for: draft))
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(SidebarItem.draft(draft.id))
                    .contextMenu {
                        Button("Discard Draft…", role: .destructive) { model.draftToDiscard = draft }
                    }
                }
            } header: {
                SidebarHeader(text: "Drafts", color: Theme.acid)
            }

            if !model.jekyllDrafts.isEmpty {
                Section {
                    ForEach(model.jekyllDrafts) { post in
                        PostRow(post: post, label: "Delete Draft…")
                    }
                } header: {
                    SidebarHeader(text: "In _drafts", color: Theme.violet)
                }
            }

            Section {
                ForEach(model.publishedPosts) { post in
                    PostRow(post: post, label: "Delete Post…")
                }
            } header: {
                SidebarHeader(text: "Posts", color: Theme.cyan)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(ConcreteBackground())
        .toolbar {
            ToolbarItem {
                Button { model.newDraft() } label: {
                    Label("New Post", systemImage: "square.and.pencil")
                }
                .help("Start a new post (⌘N)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshRepo()
        }
    }

    private func subtitle(for draft: PostDraft) -> String {
        let edited = draft.modified.formatted(.relative(presentation: .named))
        guard let origin = draft.origin else { return "New · \(edited)" }
        return (origin.isJekyllDraft ? "Editing draft · " : "Editing post · ") + edited
    }
}

private struct PostRow: View {
    @Environment(AppModel.self) private var model
    let post: RepoPost
    let label: String

    var body: some View {
        let isOpen = model.drafts.contains { $0.origin?.path == post.path }
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let date = post.date {
                    Text(date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()))
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Spacer()
            if isOpen {
                Image(systemName: "pencil")
                    .foregroundStyle(Theme.acid)
                    .help("Has unsaved edits in Drafts")
            }
        }
        .tag(SidebarItem.repoPost(post.path))
        .contextMenu {
            Button("Edit") { model.open(post.path) }
            if let site = model.repo?.siteURL(), !post.isJekyllDraft, let builder = builder(), let url = URL(string: site + builder.postURL) {
                Link("Open on Site", destination: url)
            }
            Button("Show in Finder") {
                if let url = model.repo?.url(post.path) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button(label, role: .destructive) { model.postToDelete = post }
        }
    }

    /// Works out the post's live URL from its own front matter.
    private func builder() -> PostBuilder? {
        guard let repo = model.repo, let text = try? String(contentsOf: repo.url(post.path), encoding: .utf8) else { return nil }
        let draft = PostParser.parse(path: post.path, text: text, repo: repo)
        return PostBuilder(draft: draft, siteTimeZone: repo.siteTimeZone(), exists: { _ in false })
    }
}

/// A section title sprayed on the wall.
private struct SidebarHeader: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(Theme.display(13))
            .foregroundStyle(color)
            .neonGlow(color, radius: 4)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}
