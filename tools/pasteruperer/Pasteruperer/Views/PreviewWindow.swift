import SwiftUI
import WebKit

struct PreviewWindow: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingLog = false

    var body: some View {
        let preview = model.preview
        VStack(spacing: 0) {
            Group {
                if let url = preview.pageURL, preview.status == .ready || preview.status == .building {
                    WebView(url: url, reloadToken: preview.reloadToken)
                } else if case .failed(let message) = preview.status {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Show Log") { isShowingLog = true }
                        Button("Try Again") { restart() }
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(preview.status == .preparing ? "Copying the site…" : "Starting Jekyll…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            HStack(spacing: 8) {
                statusLabel
                if let error = preview.buildError {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
                Spacer()
                Button("Log") { isShowingLog.toggle() }
                    .controlSize(.small)
                    .popover(isPresented: $isShowingLog) { LogView(log: preview.log) }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 480, minHeight: 500)
        .navigationTitle("Preview: \(model.draft.displayTitle)")
        .toolbar {
            Button { restart() } label: { Label("Restart", systemImage: "arrow.clockwise") }
                .help("Copy the site again and restart Jekyll")
            Button {
                if let url = preview.pageURL { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .disabled(preview.pageURL == nil || preview.status != .ready)
        }
        .task(id: model.repo) { restart() }
        .onChange(of: model.draft) { preview.update(model.draft) }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.preview.status {
        case .idle: Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .preparing, .starting: Label("Starting", systemImage: "hourglass").foregroundStyle(.secondary)
        case .building: Label("Rebuilding", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .ready: Label("Up to date", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed: Label("Stopped", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    private func restart() {
        guard let repo = model.repo else { return }
        Task { await model.preview.start(repo: repo, draft: model.draft) }
    }
}

private struct LogView: View {
    let log: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "Nothing yet." : log)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear { proxy.scrollTo("end") }
        }
        .frame(width: 620, height: 360)
    }
}

/// Shows a page, reloading it (keeping the scroll position) when `reloadToken` changes.
struct WebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    final class Coordinator {
        var url: URL?
        var reloadToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        context.coordinator.url = url
        context.coordinator.reloadToken = reloadToken
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.url != url {
            webView.load(URLRequest(url: url))
        } else if context.coordinator.reloadToken != reloadToken {
            webView.reload()
        }
        context.coordinator.url = url
        context.coordinator.reloadToken = reloadToken
    }
}
