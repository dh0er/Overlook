import SwiftUI
import AppKit

struct OCRSelectionOverlay: View {
    let regions: [TextRegion]
    let selectionRectInView: CGRect?
    let viewSize: CGSize
    let videoSize: CGSize?

    var body: some View {
        let contentRect = videoContentRect(viewSize: viewSize, videoSize: videoSize)

        ZStack {
            ForEach(regions) { region in
                let r = regionRectInView(region.boundingBox, contentRect: contentRect)
                Rectangle()
                    .stroke(Color.green.opacity(0.8), lineWidth: 1)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }

            if let selectionRectInView {
                Rectangle()
                    .fill(Color.blue.opacity(0.12))
                    .overlay(
                        Rectangle().stroke(Color.blue.opacity(0.9), lineWidth: 2)
                    )
                    .frame(width: selectionRectInView.width, height: selectionRectInView.height)
                    .position(x: selectionRectInView.midX, y: selectionRectInView.midY)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }

    private func videoContentRect(viewSize: CGSize, videoSize: CGSize?) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            return CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            return CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }
    }

    private func regionRectInView(_ normalizedVisionRect: CGRect, contentRect: CGRect) -> CGRect {
        let x = contentRect.minX + normalizedVisionRect.minX * contentRect.width
        let y = contentRect.minY + (1.0 - normalizedVisionRect.maxY) * contentRect.height
        let width = normalizedVisionRect.width * contentRect.width
        let height = normalizedVisionRect.height * contentRect.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct OCRResultView: View {
    @Binding var selectedText: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Recognized Text")
                .font(.headline)

            ScrollView {
                Text(selectedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(height: 200)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedText, forType: .string)
                    dismiss()
                }

                Button("Close") {
                    dismiss()
                }
            }
        }
        .padding()
        .frame(width: 400, height: 300)
    }
}

struct SnippetSelectionOverlay: View {
    let selectionRectInView: CGRect?
    let viewSize: CGSize

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)

            if let selectionRectInView {
                Rectangle()
                    .fill(Color.blue.opacity(0.12))
                    .overlay(
                        Rectangle().stroke(Color.blue.opacity(0.9), lineWidth: 2)
                    )
                    .frame(width: selectionRectInView.width, height: selectionRectInView.height)
                    .position(x: selectionRectInView.midX, y: selectionRectInView.midY)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }
}

struct SnippetHUD: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(radius: 4)
    }
}
