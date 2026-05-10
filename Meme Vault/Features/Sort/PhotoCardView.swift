//
//  PhotoCardView.swift
//  Meme Vault
//
//  Renders a PHAsset as a swipeable card. Reports swipe direction back to the
//  parent so the ViewModel can take action.
//

import SwiftUI
import Photos
import UIKit

struct PhotoCardView: View {
    let asset: PHAsset
    let onSwipeLeft: () -> Void          // delete
    let onSwipeRight: () -> Void         // skip

    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?
    @State private var dragOffset: CGSize = .zero
    @State private var isLoading = true

    private let swipeThreshold: CGFloat = 100

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else if isLoading {
                    ProgressView()
                }

                // Swipe-direction overlays
                overlayLabels(width: geo.size.width)
            }
            .offset(x: dragOffset.width, y: dragOffset.height * 0.3)
            .rotationEffect(.degrees(Double(dragOffset.width / 20)))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        if value.translation.width < -swipeThreshold {
                            withAnimation(.spring) {
                                dragOffset = CGSize(width: -geo.size.width * 1.5, height: value.translation.height)
                            }
                            onSwipeLeft()
                        } else if value.translation.width > swipeThreshold {
                            withAnimation(.spring) {
                                dragOffset = CGSize(width: geo.size.width * 1.5, height: value.translation.height)
                            }
                            onSwipeRight()
                        } else {
                            withAnimation(.spring) {
                                dragOffset = .zero
                            }
                        }
                    }
            )
            .task(id: asset.localIdentifier) {
                await loadImage(targetSize: geo.size.applying(.init(scaleX: displayScale, y: displayScale)))
            }
            .onChange(of: asset.localIdentifier) { _, _ in
                dragOffset = .zero
                image = nil
                isLoading = true
            }
        }
    }

    @ViewBuilder
    private func overlayLabels(width: CGFloat) -> some View {
        let progress = max(-1, min(1, dragOffset.width / width))

        ZStack {
            // Right swipe -> Skip
            Text("SKIP")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(.green)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(.green, lineWidth: 4)
                )
                .rotationEffect(.degrees(-15))
                .opacity(Double(max(0, progress) * 2))
                .offset(x: -width / 4)

            // Left swipe -> Delete
            Text("DELETE")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(.red)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(.red, lineWidth: 4)
                )
                .rotationEffect(.degrees(15))
                .opacity(Double(max(0, -progress) * 2))
                .offset(x: width / 4)
        }
    }

    private func loadImage(targetSize: CGSize) async {
        isLoading = true
        let img = await ImageLoader.shared.loadDisplayImage(for: asset, targetSize: targetSize)
        self.image = img
        self.isLoading = false
    }
}
