import SwiftUI
import AVFoundation

struct AudioBlockView: View {
    @Binding var playlist: AudioPlaylist
    @State private var player: AVPlayer?
    @State private var playingID: UUID?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StencilLabel(playlist.tracks.count > 1 ? "Playlist" : "Track", color: Theme.cyan, size: 13)
                    .neonGlow(Theme.cyan, radius: 3)
                TextField("Player label", text: $playlist.label, prompt: Text("label (defaults to the post title)").foregroundStyle(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(Theme.marker(17))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 0) {
                ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                    if index > 0 { Rectangle().fill(.white.opacity(0.1)).frame(height: 1) }
                    row(index: index, track: track)
                }
            }
            .background(.white.opacity(0.04))
            .overlay(Rectangle().strokeBorder(.white.opacity(0.14)))

            HStack {
                Button("Add Tracks") {
                    let urls = AppModel.pickFiles(types: [.audio], multiple: true, message: "Choose audio files to add to this playlist.")
                    playlist.tracks += urls.map(AudioTrack.init(source:))
                }
                .buttonStyle(StickerButtonStyle(color: Theme.cyan, tilt: .degrees(-1.5)))
                Spacer()
                if playlist.tracks.contains(where: \.needsConversion) {
                    Text("Non-m4a files are converted to m4a when posting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .padding(.top, 4)
        .background(Theme.ink, in: Rectangle())
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(Theme.cyan, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 3)
        .overlay(alignment: .top) { Tape(width: 74, angle: .degrees(3)).offset(y: -12) }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .tint(Theme.cyan)
        .dropDestination(for: URL.self) { urls, _ in
            let audio = urls.filter(\.isAudioFile)
            playlist.tracks += audio.map(AudioTrack.init(source:))
            return !audio.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .onDisappear { player?.pause() }
    }

    private func row(index: Int, track: AudioTrack) -> some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", index + 1))
                .font(Theme.display(12))
                .foregroundStyle(Theme.pink)
            Button { togglePlayback(track) } label: {
                Image(systemName: playingID == track.id ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(playingID == track.id ? "Pause" : "Preview")
            TextField("Title", text: title(for: track.id))
                .textFieldStyle(.plain)
            Text(track.source.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .trailing)
            HStack(spacing: 2) {
                Button { moveTrack(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move up")
                Button { moveTrack(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == playlist.tracks.count - 1)
                    .help("Move down")
                Button {
                    if playingID == track.id { togglePlayback(track) }
                    playlist.tracks.removeAll { $0.id == track.id }
                } label: { Image(systemName: "xmark") }
                    .help("Remove track")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func title(for id: UUID) -> Binding<String> {
        Binding(
            get: { playlist.tracks.first { $0.id == id }?.title ?? "" },
            set: { newValue in
                if let index = playlist.tracks.firstIndex(where: { $0.id == id }) { playlist.tracks[index].title = newValue }
            }
        )
    }

    private func moveTrack(_ index: Int, by offset: Int) {
        let target = index + offset
        guard playlist.tracks.indices.contains(target) else { return }
        playlist.tracks.swapAt(index, target)
    }

    private func togglePlayback(_ track: AudioTrack) {
        if playingID == track.id {
            player?.pause()
            playingID = nil
        } else {
            player?.pause()
            let player = AVPlayer(url: track.source)
            player.play()
            self.player = player
            playingID = track.id
        }
    }
}
