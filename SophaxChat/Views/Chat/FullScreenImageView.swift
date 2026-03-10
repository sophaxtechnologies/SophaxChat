// FullScreenImageView.swift
// SophaxChat
//
// Pinch-to-zoom full-screen image viewer with a dismiss button.

import SwiftUI

struct FullScreenImageView: View {
    @Environment(\.dismiss) private var dismiss
    let imageData: Data

    @State private var scale:  CGFloat = 1.0
    @State private var offset: CGSize  = .zero

    private var uiImage: UIImage? { UIImage(data: imageData) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = max(1, v) }
                            .onEnded   { _ in
                                withAnimation(.spring()) {
                                    if scale < 1.2 { scale = 1; offset = .zero }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                guard scale > 1 else { return }
                                offset = v.translation
                            }
                            .onEnded { _ in
                                if scale <= 1 {
                                    withAnimation(.spring()) { offset = .zero }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            scale  = scale > 1 ? 1 : 2
                            offset = .zero
                        }
                    }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(16)
            }
        }
        .statusBarHidden()
    }
}
