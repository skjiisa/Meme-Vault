//
//  OnboardingView.swift
//  Meme Vault
//
//  First-run walkthrough: a short paged intro (value → how it works → privacy &
//  permission) that ends by requesting full photo-library access. Plus the
//  one-time `SortCoachTip` shown on the first real sort. Polished with the
//  iOS 26 Liquid Glass API (deployment target is 26.2, so no availability gate).
//

import SwiftUI

struct OnboardingView: View {
    var onFinished: () -> Void

    @Environment(PhotoLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var page = 0
    @State private var requesting = false

    private let pageCount = 3

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    WelcomePage().tag(0)
                    HowItWorksPage().tag(1)
                    PrivacyPage().tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                controls
            }
        }
    }

    /// Soft accent wash so the glass surfaces have something to refract.
    private var backdrop: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.04), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var controls: some View {
        VStack(spacing: 20) {
            PageIndicator(count: pageCount, index: page)
            Button(action: advance) {
                Group {
                    if requesting {
                        ProgressView()
                    } else {
                        Text(page == pageCount - 1 ? "Get Started" : "Continue")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(requesting)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
        .animation(reduceMotion ? nil : .default, value: requesting)
    }

    private func advance() {
        if page < pageCount - 1 {
            withAnimation(reduceMotion ? nil : .easeInOut) { page += 1 }
        } else {
            requesting = true
            Task {
                await library.requestAuthorization()
                requesting = false
                onFinished()
            }
        }
    }
}

// MARK: - Pages

private struct WelcomePage: View {
    var body: some View {
        OnboardingPageLayout(
            symbol: "photo.stack.fill",
            title: "A Tidier Photo Library",
            subtitle: "Clear out the photos cluttering your camera roll by filing them into albums — one swipe at a time."
        )
    }
}

private struct HowItWorksPage: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("How It Works")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    FeatureRow(symbol: "hand.draw",
                               title: "Swipe to browse",
                               text: "Move through photos that aren't in any album yet.")
                    FeatureRow(symbol: "rectangle.stack.badge.plus",
                               title: "Tap an album",
                               text: "File the current photo into it. Once it's in an album, it leaves your queue.")
                    FeatureRow(symbol: "arrow.right.to.line",
                               title: "Skip or trash",
                               text: "Set aside or queue for deletion anything you don't want.")
                }
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

private struct PrivacyPage: View {
    var body: some View {
        OnboardingPageLayout(
            symbol: "lock.fill",
            title: "Your Photos Stay Private",
            subtitle: "Everything happens on your device. This app never collects, uploads, or shares your photos or any data.\n\nTo sort into your albums, it needs full access to your photo library."
        )
    }
}

// MARK: - Shared layout

private struct OnboardingPageLayout: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 140, height: 140)
                .glassEffect(.regular, in: .rect(cornerRadius: 36))
            VStack(spacing: 14) {
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private struct PageIndicator: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == index ? 22 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - First-sort coach tip

/// One-time tip shown over the album grid on the user's first sort, anchored at
/// the bottom so it sits with the destination albums it describes.
struct SortCoachTip: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Tap an album to file this photo")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Once a photo's in an album it leaves your queue. Use skip or trash for the rest.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Got It", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}
