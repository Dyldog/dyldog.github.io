import SwiftUI

/// Downsampled, upright previews of source images, shared between the editor and crop sheet.
@MainActor
final class ImagePreviewCache {
    static let shared = ImagePreviewCache()

    private var previews: [URL: CGImage] = [:]
    private var sizes: [URL: CGSize] = [:]

    func preview(for url: URL) -> CGImage? {
        if let preview = previews[url] { return preview }
        let preview = ImageProcessing.loadUpright(url, maxPixelSize: 1800)
        previews[url] = preview
        return preview
    }

    /// Full-resolution upright pixel size.
    func pixelSize(for url: URL) -> CGSize? {
        if let size = sizes[url] { return size }
        let size = ImageProcessing.uprightPixelSize(of: url)
        sizes[url] = size
        return size
    }
}

struct ImageBlockView: View {
    @Binding var image: ImageItem
    @State private var isEditing = false

    private var preview: CGImage? { ImagePreviewCache.shared.preview(for: image.source) }
    private var sourceSize: CGSize? { ImagePreviewCache.shared.pixelSize(for: image.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let preview, let cropped = ImageProcessing.crop(preview, to: image.crop) {
                let fraction = CGFloat(image.displayPercent) / 100
                let ratio = CGFloat(cropped.width) / CGFloat(cropped.height)
                GeometryReader { geometry in
                    // A photo print taped to the poster.
                    Image(decorative: cropped, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(7)
                        .background(.white)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                        .overlay(alignment: .top) { Tape(width: 70, angle: .degrees(-3)).offset(y: -12) }
                        .frame(width: geometry.size.width * fraction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .aspectRatio(ratio / fraction, contentMode: .fit)
                .frame(maxHeight: 520, alignment: .topLeading)
                .onTapGesture(count: 2) { isEditing = true }
                .help("Double-click to crop and resize")
            } else {
                Label("Can't load \(image.source.lastPathComponent)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            TextField("Describe the image (alt text)", text: $image.alt)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.ink.opacity(0.55))
                Spacer()
                Button("Replace") {
                    if let url = AppModel.pickFiles(types: [.image], multiple: false, message: "Choose a replacement image.").first {
                        image.source = url
                        image.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                    }
                }
                .buttonStyle(StickerButtonStyle(color: Theme.cyan, tilt: .degrees(1.5)))
                Button("Crop & Size") { isEditing = true }
                    .buttonStyle(StickerButtonStyle(color: Theme.acid, tilt: .degrees(-2)))
                    .disabled(preview == nil)
            }
        }
        .padding(.top, 6)
        .sheet(isPresented: $isEditing) {
            if let preview {
                ImageEditorView(image: $image, preview: preview, sourceSize: sourceSize ?? CGSize(width: preview.width, height: preview.height))
            }
        }
    }

    private var summary: String {
        var parts = [image.source.lastPathComponent]
        if let sourceSize {
            let output = image.outputSize(sourceSize: sourceSize)
            parts.append("\(Int(output.width)) × \(Int(output.height)) px \(image.outputFormat.label)")
        }
        parts.append("\(image.displayPercent)% wide")
        return parts.joined(separator: " · ")
    }
}
