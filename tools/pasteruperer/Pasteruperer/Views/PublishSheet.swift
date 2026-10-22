import SwiftUI

struct PublishSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var target: PostTarget = .post
    @State private var plan: PostPlan?
    @State private var problems: [String] = []
    @State private var warnings: [String] = []
    @State private var message = ""
    @State private var push = true
    @State private var tab = Tab.markdown
    @State private var publisher = Publisher()
    @State private var draftID: UUID?

    private enum Tab { case markdown, files }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if publisher.phase != .ready, let plan {
                CommitProgressView(publisher: publisher, successMessage: successMessage) {
                    if plan.target == .post, publisher.pushed, let site = model.repo?.siteURL(), let url = URL(string: site + plan.postURL) {
                        Button("Open Post") { openURL(url) }
                    }
                }
            } else {
                Picker("Save as", selection: $target) {
                    Text("Publish to _posts").tag(PostTarget.post)
                    Text("Save to _drafts").tag(PostTarget.draft)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if !problems.isEmpty {
                    problemsView
                } else if let plan {
                    review(plan)
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 620)
        .onAppear {
            draftID = model.draft.id
            if model.draft.origin?.isJekyllDraft == true { target = .post }
            makePlan()
        }
        .onChange(of: target) { makePlan() }
    }

    private var successMessage: String {
        guard let plan else { return "" }
        if plan.target == .draft {
            return publisher.pushed ? "Saved to \(plan.post.path) and pushed. It isn't on the site." : "Saved to \(plan.post.path). It isn't on the site."
        }
        return publisher.pushed
            ? "Committed and pushed. GitHub Pages usually takes a minute or two to rebuild the site."
            : "Committed. Push when you're ready."
    }

    private func makePlan() {
        guard let builder = model.makeBuilder(target: target) else { return }
        warnings = builder.warnings()
        do {
            plan = try builder.build()
            problems = []
        } catch let error as PlanError {
            plan = nil
            problems = error.problems
        } catch {
            plan = nil
            problems = [error.localizedDescription]
        }
        let title = builder.draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        message = switch target {
        case .draft: "DRAFT: \(title)"
        case .post: builder.draft.origin.map { !$0.isJekyllDraft } == true ? "EDIT: \(title)" : "POST: \(title)"
        }
    }

    // MARK: Problems

    private var problemsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("This post isn't ready yet", systemImage: "exclamationmark.triangle.fill")
                .font(Theme.display(20))
                .foregroundStyle(.orange)
            ForEach(problems, id: \.self) { problem in
                Text("• " + problem)
            }
            Spacer()
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Review

    private func review(_ plan: PostPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("File").foregroundStyle(.secondary)
                    Text(plan.post.path).font(.callout.monospaced()).textSelection(.enabled)
                }
                if plan.target == .post {
                    GridRow {
                        Text("URL").foregroundStyle(.secondary)
                        Text((model.repo?.siteURL() ?? "") + plan.postURL).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }

            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Picker("Show", selection: $tab) {
                Text("Markdown").tag(Tab.markdown)
                Text("Files (\(plan.paths.count))").tag(Tab.files)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Group {
                    switch tab {
                    case .markdown:
                        Text(plan.post.contents + plan.dataFiles.map { "\n── \($0.path) ──\n\($0.contents)" }.joined())
                    case .files:
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(plan.writtenPaths, id: \.self) { path in
                                Label(path + (plan.overwrites.contains(path) ? "  (updated)" : ""), systemImage: icon(for: path))
                            }
                            ForEach(plan.deletions, id: \.self) { path in
                                Label(path + "  (removed)", systemImage: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

            TextField("Commit message", text: $message)
                .textFieldStyle(.roundedBorder)
            Toggle("Push to GitHub after committing", isOn: $push)

            HStack {
                Text("Only the files listed here are committed. Other changes in the repo are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(push ? "Commit & Push" : "Commit") { start(plan) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func icon(for path: String) -> String {
        if path.hasPrefix("_posts/") || path.hasPrefix("_drafts/") { return "doc.text" }
        if path.hasPrefix("_data/") { return "list.bullet.rectangle" }
        if path.hasPrefix("art/") { return "waveform" }
        return "photo"
    }

    private func start(_ plan: PostPlan) {
        guard let repo = model.repo, let draftID else { return }
        Task {
            await publisher.publish(plan, to: repo, message: message, push: push)
            if publisher.commit != nil { model.didCommit(draftID) }
        }
    }
}

/// Removes a post (or `_drafts` file), its playlists, and optionally media nothing else uses.
struct DeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let post: RepoPost

    @State private var plan: DeletionPlan?
    @State private var error: String?
    @State private var includeMedia = true
    @State private var push = true
    @State private var message = ""
    @State private var publisher = Publisher()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if publisher.phase != .ready {
                CommitProgressView(publisher: publisher, successMessage: publisher.pushed
                                   ? "Deleted and pushed. GitHub Pages takes a minute or two to update."
                                   : "Deleted and committed. Push when you're ready.") { EmptyView() }
            } else if let error {
                Text(error).foregroundStyle(.red)
                Spacer()
                HStack { Spacer(); Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else if let plan {
                review(plan)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task {
            guard let repo = model.repo else { return }
            do {
                let plan = try DeletionPlan.make(for: post.path, in: repo)
                self.plan = plan
                message = (post.isJekyllDraft ? "DELETE DRAFT: " : "DELETE: ") + plan.title
            } catch {
                self.error = "Couldn't read \(post.path): \(error.localizedDescription)"
            }
        }
    }

    private func review(_ plan: DeletionPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Delete “\(plan.title)”?", systemImage: "trash")
                .font(Theme.display(20))
            Text(post.isJekyllDraft
                 ? "The draft is removed from the repo. It stays in the git history."
                 : "The post comes off the site. It stays in the git history if you ever want it back.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach([plan.postPath] + plan.dataFiles, id: \.self) { path in
                        Label(path, systemImage: "minus.circle").foregroundStyle(.red)
                    }
                    ForEach(plan.media, id: \.self) { path in
                        Label(path, systemImage: includeMedia ? "minus.circle" : "circle")
                            .foregroundStyle(includeMedia ? .red : .secondary)
                    }
                    ForEach(plan.sharedMedia, id: \.self) { path in
                        Label(path + "  (kept: used elsewhere)", systemImage: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))

            if !plan.media.isEmpty {
                Toggle("Also delete images and audio only this post uses (\(plan.media.count))", isOn: $includeMedia)
            }
            if model.drafts.contains(where: { $0.origin?.path == post.path }) {
                Label("Your unsaved edits of this post will be discarded too.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            TextField("Commit message", text: $message)
                .textFieldStyle(.roundedBorder)
            Toggle("Push to GitHub after committing", isOn: $push)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(post.isJekyllDraft ? "Delete Draft" : "Delete Post", role: .destructive) { start(plan) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func start(_ plan: DeletionPlan) {
        guard let repo = model.repo else { return }
        Task {
            await publisher.delete(plan.paths(includingMedia: includeMedia), from: repo, message: message, push: push)
            if publisher.commit != nil { model.didDelete(post.path) }
        }
    }
}

/// Steps, errors and the closing buttons shared by posting and deleting.
struct CommitProgressView<Extra: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let publisher: Publisher
    let successMessage: String
    @ViewBuilder let extraButtons: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Theme.display(20))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(publisher.steps) { step in
                    HStack(spacing: 8) {
                        switch step.state {
                        case .running: ProgressView().controlSize(.small)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                        Text(step.title)
                    }
                }
            }

            if let error = publisher.errorMessage {
                ScrollView {
                    Text(error)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                Text(publisher.phase == .failed(committed: true)
                     ? "The change is committed locally (\(publisher.commit ?? "HEAD")). Fix the problem and retry, or push from the terminal later."
                     : "Nothing was committed, and the repo is back the way it was.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if publisher.phase == .succeeded {
                Text(successMessage + (publisher.commit.map { " (\($0))" } ?? ""))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                switch publisher.phase {
                case .running, .ready:
                    Button("Close") {}.disabled(true)
                case .succeeded:
                    extraButtons()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                case .failed(let committed):
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if committed, let repo = model.repo {
                        Button("Retry Push") { Task { await publisher.push(repo) } }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .interactiveDismissDisabled(publisher.phase == .running)
    }

    private var title: String {
        switch publisher.phase {
        case .ready, .running: "Working…"
        case .succeeded: "Done!"
        case .failed: "That didn't work"
        }
    }
}
