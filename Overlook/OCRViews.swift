import SwiftUI
import AppKit

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
