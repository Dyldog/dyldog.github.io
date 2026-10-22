import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

enum Defaults {
    static let repoPath = "repoPath"
    static let imageMaxWidth = "imageMaxWidth"
    static let imageQuality = "imageQuality"
    static let selectedDraft = "selectedDraft"

    static func register() {
        UserDefaults.standard.register(defaults: [imageMaxWidth: 1600, imageQuality: 0.82])
    }
}

/// What's selected in the sidebar.
enum SidebarItem: Hashable {
    case draft(UUID)
    case repoPost(String)
}

@MainActor
@Observable
final class AppModel {
    private(set) var repo: BlogRepo?
    private(set) var branch: String?
    private(set) var knownCategories: [String] = []
    private(set) var publishedPosts: [RepoPost] = []
    private(set) var jekyllDrafts: [RepoPost] = []

    private(set) var drafts: [PostDraft] = []
    private(set) var selectedDraftID: UUID?
    /// A repo post being looked at. It only becomes a saved draft once it's actually changed.
    private(set) var viewedPost: PostDraft?

    var isPublishing = false
    /// Repo post awaiting delete confirmation.
    var postToDelete: RepoPost?
    var draftToDiscard: PostDraft?
    var isPickingPhotos = false
    @ObservationIgnored var photoInsertionPoint: UUID?

    let preview = PreviewServer()

    /// The text block being typed in, for the Format menu and toolbar.
    @ObservationIgnored weak var activeEditor: MarkdownEditorController?
    private(set) var isEditingText = false

    init() {
        Defaults.register()
        drafts = DraftStorage.loadAll()
        if drafts.isEmpty { drafts = [PostDraft()] }
        let saved = UserDefaults.standard.string(forKey: Defaults.selectedDraft).flatMap(UUID.init(uuidString:))
        selectedDraftID = drafts.first { $0.id == saved }?.id ?? drafts.max { $0.modified < $1.modified }?.id

        let repoPath = UserDefaults.standard.string(forKey: Defaults.repoPath).map { URL(filePath: $0) }
        setRepo(repoPath.flatMap { BlogRepo.isBlog($0) ? $0 : nil } ?? BlogRepo.defaultLocation(), remember: false)
        removeUnchangedDrafts()
        MediaStore.removeUnused(keeping: drafts)
    }

    // MARK: Drafts

    /// The draft in the editor.
    var draft: PostDraft {
        get { viewedPost ?? drafts.first { $0.id == selectedDraftID } ?? drafts.first ?? PostDraft() }
        set {
            var draft = newValue
            draft.modified = Date()
            if let viewed = viewedPost, viewed.id == newValue.id {
                // The first real change turns the post into a draft (same id, so the editor keeps focus).
                guard viewed != newValue else { return }
                drafts.append(draft)
                viewedPost = nil
                select(draft.id)
            } else {
                guard let index = drafts.firstIndex(where: { $0.id == newValue.id }), drafts[index] != newValue else { return }
                drafts[index] = draft
            }
            DraftStorage.save(draft)
        }
    }

    /// True when looking at a repo post that hasn't been changed.
    var isViewingPost: Bool { viewedPost != nil }

    var sortedDrafts: [PostDraft] {
        drafts.sorted { $0.modified > $1.modified }
    }

    var sidebarSelection: SidebarItem? {
        get {
            if let path = viewedPost?.origin?.path { return .repoPost(path) }
            return selectedDraftID.map(SidebarItem.draft)
        }
        set {
            switch newValue {
            case .draft(let id): select(id)
            case .repoPost(let path): open(path)
            case nil: break
            }
        }
    }

    func select(_ id: UUID) {
        viewedPost = nil
        selectedDraftID = id
        UserDefaults.standard.set(id.uuidString, forKey: Defaults.selectedDraft)
    }

    func newDraft() {
        viewedPost = nil
        // Reuse an untouched draft rather than piling up empty ones.
        if let empty = drafts.first(where: \.isEmpty) {
            select(empty.id)
            return
        }
        let draft = PostDraft()
        drafts.append(draft)
        DraftStorage.save(draft)
        select(draft.id)
    }

    func discard(_ draft: PostDraft) {
        if viewedPost?.id == draft.id { viewedPost = nil }
        drafts.removeAll { $0.id == draft.id }
        DraftStorage.delete(draft.id)
        if drafts.isEmpty { drafts = [PostDraft()] }
        if selectedDraftID == draft.id || !drafts.contains(where: { $0.id == selectedDraftID }) {
            select(sortedDrafts[0].id)
        }
        MediaStore.removeUnused(keeping: drafts)
    }

    /// Shows a post or `_drafts` file, or the local draft that's already editing it.
    func open(_ path: String) {
        if let existing = drafts.first(where: { $0.origin?.path == path }) {
            select(existing.id)
            return
        }
        guard let draft = parse(path) else { return }
        viewedPost = draft
    }

    private func parse(_ path: String) -> PostDraft? {
        guard let repo, let text = try? String(contentsOf: repo.url(path), encoding: .utf8) else { return nil }
        return PostParser.parse(path: path, text: text, repo: repo)
    }

    /// Drops drafts of repo posts that are identical to the post (e.g. opened but never changed).
    private func removeUnchangedDrafts() {
        for draft in drafts {
            guard let origin = draft.origin, let current = parse(origin.path),
                  draft.contentSignature == current.contentSignature else { continue }
            drafts.removeAll { $0.id == draft.id }
            DraftStorage.delete(draft.id)
        }
        if drafts.isEmpty { drafts = [PostDraft()] }
        if !drafts.contains(where: { $0.id == selectedDraftID }) { selectedDraftID = sortedDrafts[0].id }
    }

    func didCommit(_ draftID: UUID) {
        if let draft = drafts.first(where: { $0.id == draftID }) { discard(draft) }
        if viewedPost?.id == draftID { leaveViewedPost() }
        refreshRepo()
    }

    /// After deleting a post, local edits of it no longer make sense.
    func didDelete(_ path: String) {
        for draft in drafts where draft.origin?.path == path { discard(draft) }
        if viewedPost?.origin?.path == path { leaveViewedPost() }
        refreshRepo()
    }

    private func leaveViewedPost() {
        viewedPost = nil
        if !drafts.contains(where: { $0.id == selectedDraftID }) { select(sortedDrafts[0].id) }
    }

    // MARK: Repo

    func setRepo(_ url: URL?, remember: Bool = true) {
        guard let url, BlogRepo.isBlog(url) else {
            repo = nil
            return
        }
        repo = BlogRepo(root: url)
        if remember { UserDefaults.standard.set(url.path, forKey: Defaults.repoPath) }
        refreshRepo()
    }

    func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose your Jekyll blog's folder (the one containing _config.yml and _posts)."
        panel.directoryURL = repo?.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if BlogRepo.isBlog(url) {
            setRepo(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "That doesn't look like a Jekyll blog"
            alert.informativeText = "Couldn't find _config.yml and a _posts folder in \(url.lastPathComponent)."
            alert.runModal()
        }
    }

    func refreshRepo() {
        guard let repo else { return }
        knownCategories = repo.existingCategories()
        publishedPosts = PostParser.posts(in: "_posts", of: repo)
        jekyllDrafts = PostParser.posts(in: "_drafts", of: repo)
        Task {
            branch = await Git(repo: repo.root).currentBranch()
        }
    }

    // MARK: Categories

    /// Existing categories plus any new ones added to this draft.
    var allCategories: [String] {
        Array(Set(knownCategories).union(draft.categories)).sorted()
    }

    func toggleCategory(_ category: String) {
        if let index = draft.categories.firstIndex(of: category) {
            draft.categories.remove(at: index)
        } else {
            draft.categories.append(category)
        }
    }

    /// Jekyll splits categories on spaces, so new ones are slugged ("Road Trips" → "road-trips").
    func addCategory(_ name: String) {
        let category = Slug.make(name)
        guard !category.isEmpty, !draft.categories.contains(category) else { return }
        draft.categories.append(category)
    }

    // MARK: Blocks

    func block(_ id: UUID) -> Binding<Block> {
        Binding(
            get: { self.draft.blocks.first { $0.id == id } ?? Block(.text("")) },
            set: { newValue in
                if let index = self.draft.blocks.firstIndex(where: { $0.id == id }) { self.draft.blocks[index] = newValue }
            }
        )
    }

    /// Inserts after the given block, or at the top when `after` is nil.
    func insert(_ blocks: [Block], after id: UUID?) {
        guard !blocks.isEmpty else { return }
        let index = id.flatMap { id in draft.blocks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        var blocks = blocks
        // Keep somewhere to carry on typing after media added at the end.
        if index == draft.blocks.count, blocks.last.map({ if case .text = $0.content { false } else { true } }) == true {
            blocks.append(Block(.text("")))
        }
        draft.blocks.insert(contentsOf: blocks, at: index)
    }

    /// Splits a text block at `offset` (UTF-16) and puts media between the halves.
    func insert(_ media: [Block], splitting id: UUID, at offset: Int) {
        guard !media.isEmpty, let index = draft.blocks.firstIndex(where: { $0.id == id }),
              case .text(let text) = draft.blocks[index].content else { return }
        let nsText = text as NSString
        let offset = min(max(0, offset), nsText.length)
        let before = nsText.substring(to: offset).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let after = nsText.substring(from: offset).replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)

        var blocks = draft.blocks
        var replacement: [Block] = []
        if !before.isEmpty { replacement.append(Block(id: id, .text(before))) }
        replacement += media
        let nextIsText = blocks.indices.contains(index + 1) && { if case .text = blocks[index + 1].content { true } else { false } }()
        if !after.isEmpty || !nextIsText { replacement.append(Block(.text(after))) }
        blocks.replaceSubrange(index...index, with: replacement)
        draft.blocks = blocks
    }

    func insertText(after id: UUID?) {
        insert([Block(.text(""))], after: id)
    }

    func insertImages(after id: UUID?) {
        let urls = Self.pickFiles(types: [.image], multiple: true, message: "Choose images to add to the post.")
        insert(urls.map { Block(.image(makeImage($0))) }, after: id)
    }

    func insertAudio(after id: UUID?) {
        let urls = Self.pickFiles(types: [.audio], multiple: true, message: "Choose one or more audio files. Several files become a playlist.")
        guard !urls.isEmpty else { return }
        insert([Block(.audio(AudioPlaylist(tracks: urls.map(AudioTrack.init(source:)))))], after: id)
    }

    func pickPhotos(after id: UUID?) {
        photoInsertionPoint = id
        isPickingPhotos = true
    }

    func insertPhotos(_ urls: [URL]) {
        insert(urls.map { Block(.image(makeImage($0))) }, after: photoInsertionPoint ?? draft.blocks.last?.id)
    }

    func pasteMedia(after id: UUID?) {
        guard let urls = MediaStore.media(from: .general), !urls.isEmpty else {
            NSSound.beep()
            return
        }
        insert(mediaBlocks(urls), after: id)
    }

    /// Each image becomes its own block, and audio files become one playlist.
    func mediaBlocks(_ urls: [URL]) -> [Block] {
        var blocks = urls.filter(\.isImageFile).map { Block(.image(makeImage($0))) }
        let audio = urls.filter(\.isAudioFile)
        if !audio.isEmpty { blocks.append(Block(.audio(AudioPlaylist(tracks: audio.map(AudioTrack.init(source:)))))) }
        return blocks
    }

    func insertFiles(_ urls: [URL], after id: UUID?) {
        insert(mediaBlocks(urls), after: id)
    }

    func remove(_ id: UUID) {
        draft.blocks.removeAll { $0.id == id }
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.blocks.indices.contains(target) else { return }
        draft.blocks.swapAt(index, target)
    }

    func makeImage(_ url: URL) -> ImageItem {
        var image = ImageItem(source: url)
        image.maxWidth = UserDefaults.standard.integer(forKey: Defaults.imageMaxWidth)
        image.quality = UserDefaults.standard.double(forKey: Defaults.imageQuality)
        return image
    }

    // MARK: Text editing

    func editorDidFocus(_ controller: MarkdownEditorController) {
        activeEditor = controller
        isEditingText = true
    }

    func editorDidBlur(_ controller: MarkdownEditorController) {
        guard activeEditor === controller else { return }
        activeEditor = nil
        isEditingText = false
    }

    func format(_ action: MarkdownAction) {
        activeEditor?.apply(action)
    }

    // MARK: Posting

    func makeBuilder(target: PostTarget = .post) -> PostBuilder? {
        guard let repo else { return nil }
        return PostBuilder(draft: draft, target: target, siteTimeZone: repo.siteTimeZone(), exists: repo.exists, repoRoot: repo.root)
    }

    static func pickFiles(types: [UTType], multiple: Bool, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }
}

extension Block {
    init(id: UUID, _ content: Content) {
        self.init(content)
        self.id = id
    }
}

/// Autosaves each draft as its own file in Application Support.
enum DraftStorage {
    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Pasteruperer/Drafts")
    }

    /// The single draft file used before there could be several drafts.
    private static var legacyURL: URL {
        URL.applicationSupportDirectory.appending(path: "Pasteruperer/draft.json")
    }

    static func loadAll() -> [PostDraft] {
        if let data = try? Data(contentsOf: legacyURL), let draft = try? JSONDecoder().decode(PostDraft.self, from: data) {
            save(draft)
            try? FileManager.default.removeItem(at: legacyURL)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(PostDraft.self, from: data)
        }
    }

    static func save(_ draft: PostDraft) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(draft).write(to: url(for: draft.id), options: .atomic)
        } catch {
            NSLog("Pasteruperer: couldn't save draft: \(error)")
        }
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }
}
