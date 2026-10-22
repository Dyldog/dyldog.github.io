import SwiftUI

struct ImageEditorView: View {
    @Binding var image: ImageItem
    let preview: CGImage
    let sourceSize: CGSize

    @State private var working: ImageItem
    @Environment(\.dismiss) private var dismiss

    init(image: Binding<ImageItem>, preview: CGImage, sourceSize: CGSize) {
        _image = image
        self.preview = preview
        self.sourceSize = sourceSize
        _working = State(initialValue: image.wrappedValue)
    }

    private var ratio: CGFloat? { working.aspect.ratio(imageSize: sourceSize) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Aspect ratio", selection: $working.aspect) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Button("Reset") {
                    working.aspect = .free
                    working.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                Spacer()
                Text("Drag the corners to crop. Drag inside to move.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding()

            CropCanvas(image: preview, crop: $working.crop, ratio: ratio)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.85))

            Form {
                LabeledContent("Max width") {
                    HStack {
                        TextField("Max width", value: $working.maxWidth, format: .number.grouping(.never))
                            .labelsHidden()
                            .frame(width: 70)
                        Stepper("Max width", value: $working.maxWidth, in: 100...8000, step: 100)
                            .labelsHidden()
                        Text("px")
                        Menu("Presets") {
                            ForEach([800, 1200, 1600, 2400], id: \.self) { width in
                                Button("\(width) px") { working.maxWidth = width }
                            }
                            Button("Full size") { working.maxWidth = 8000 }
                        }
                        .fixedSize()
                        Spacer()
                        let output = working.outputSize(sourceSize: sourceSize)
                        Text("Saves as \(String(Int(output.width))) × \(String(Int(output.height))) px \(working.outputFormat.label)")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Width in post") {
                    HStack {
                        Slider(value: Binding(get: { Double(working.displayPercent) }, set: { working.displayPercent = Int($0) }), in: 25...100, step: 5)
                        Text("\(working.displayPercent)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                if working.outputFormat == .jpeg {
                    LabeledContent("JPEG quality") {
                        HStack {
                            Slider(value: $working.quality, in: 0.4...1, step: 0.02)
                            Text("\(Int((working.quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                TextField("Alt text", text: $working.alt, prompt: Text("Describe the image for screen readers"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: working.outputFormat == .jpeg ? 205 : 165)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    working.maxWidth = max(100, working.maxWidth)
                    image = working
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 720, idealHeight: 820)
        .onChange(of: working.aspect) {
            if let ratio { working.crop = CropMath.fitted(ratio: ratio, around: working.crop, imageSize: sourceSize) }
        }
    }
}

enum CropMath {
    /// The largest rect with the given pixel aspect ratio, centred on `crop`, that fits in the image.
    static func fitted(ratio: CGFloat, around crop: CGRect, imageSize: CGSize) -> CGRect {
        // In normalised space a pixel ratio r becomes r * H / W.
        let normalisedRatio = ratio * imageSize.height / imageSize.width
        var width: CGFloat = 1
        var height = width / normalisedRatio
        if height > 1 {
            height = 1
            width = normalisedRatio
        }
        let x = min(max(0, crop.midX - width / 2), 1 - width)
        let y = min(max(0, crop.midY - height / 2), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Shows the image with a draggable crop rectangle. `crop` is normalised (0...1, top-left origin).
struct CropCanvas: View {
    let image: CGImage
    @Binding var crop: CGRect
    /// Pixel width / height to lock to, or nil for free cropping.
    let ratio: CGFloat?

    @State private var dragStart: CGRect?
    private let minimumSize: CGFloat = 24

    private enum Corner: CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: Self { self }
        /// Direction the corner moves away from the opposite (anchored) corner.
        var direction: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeft: (-1, -1)
            case .topRight: (1, -1)
            case .bottomLeft: (-1, 1)
            case .bottomRight: (1, 1)
            }
        }
        func point(in rect: CGRect) -> CGPoint {
            CGPoint(x: direction.x < 0 ? rect.minX : rect.maxX, y: direction.y < 0 ? rect.minY : rect.maxY)
        }
        func anchor(in rect: CGRect) -> CGPoint {
            CGPoint(x: direction.x < 0 ? rect.maxX : rect.minX, y: direction.y < 0 ? rect.maxY : rect.minY)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = fitted(CGSize(width: image.width, height: image.height), in: geometry.size)
            let rect = CGRect(
                x: frame.minX + crop.minX * frame.width,
                y: frame.minY + crop.minY * frame.height,
                width: crop.width * frame.width,
                height: crop.height * frame.height
            )

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                Path { path in
                    path.addRect(frame)
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                // Rule-of-thirds grid and border; dragging inside moves the crop.
                Path { path in
                    for i in 1...2 {
                        let x = rect.minX + rect.width * CGFloat(i) / 3
                        let y = rect.minY + rect.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: y))
                        path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(rect: rect, frame: frame))

                ForEach(Corner.allCases) { corner in
                    let point = corner.point(in: rect)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(radius: 1)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .offset(x: point.x - 14, y: point.y - 14)
                        .gesture(resizeGesture(corner, rect: rect, frame: frame))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func fitted(_ size: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / size.width, container.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2, width: width, height: height)
    }

    private func moveGesture(rect: CGRect, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                var moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(frame.minX, moved.minX), frame.maxX - moved.width)
                moved.origin.y = min(max(frame.minY, moved.minY), frame.maxY - moved.height)
                crop = normalise(moved, in: frame)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ corner: Corner, rect: CGRect, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let anchor = corner.anchor(in: start)
                let (dx, dy) = corner.direction
                let point = corner.point(in: start)
                let target = CGPoint(x: point.x + value.translation.width, y: point.y + value.translation.height)

                // Room between the anchor and the image edge in the corner's direction.
                let maxWidth = dx > 0 ? frame.maxX - anchor.x : anchor.x - frame.minX
                let maxHeight = dy > 0 ? frame.maxY - anchor.y : anchor.y - frame.minY
                var width = min(max(minimumSize, (target.x - anchor.x) * dx), maxWidth)
                var height = min(max(minimumSize, (target.y - anchor.y) * dy), maxHeight)

                if let ratio {
                    if width / height > ratio { width = height * ratio } else { height = width / ratio }
                    if width > maxWidth { width = maxWidth; height = width / ratio }
                    if height > maxHeight { height = maxHeight; width = height * ratio }
                }

                let resized = CGRect(
                    x: dx > 0 ? anchor.x : anchor.x - width,
                    y: dy > 0 ? anchor.y : anchor.y - height,
                    width: width,
                    height: height
                )
                crop = normalise(resized, in: frame)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func normalise(_ rect: CGRect, in frame: CGRect) -> CGRect {
        let normalised = CGRect(
            x: (rect.minX - frame.minX) / frame.width,
            y: (rect.minY - frame.minY) / frame.height,
            width: rect.width / frame.width,
            height: rect.height / frame.height
        )
        return normalised.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
