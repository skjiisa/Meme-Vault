//
//  SortSessionView.swift
//  Meme Vault
//
//  Thin SwiftUI host for the UIKit sort screen. Owns the view-model lifecycle
//  (create / start / library-change / reappear) and the SwiftUI-presented sheets
//  (context editor, album contents), and hosts `SortSessionViewController` inside
//  a `UINavigationController` so the nav bar is UIKit too — the VC owns the top
//  and bottom safe areas. The whole sort UI (carousel, strip/grid, album grid,
//  control bar, flights) lives in the view controller.
//

import SwiftUI
import SwiftData
import Photos

struct SortSessionView: View {
    let context: OrgContext

    // Chrome relocated into the UIKit nav bar; the actions stay in SwiftUI
    // (RootView owns the sheets they present).
    var onShowContextList: () -> Void = {}
    var onShowTrash: () -> Void = {}
    var onShowSkipped: () -> Void = {}
    var onDebugClear: (() -> Void)?
    var onDebugShowOnboarding: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Trash count for the nav-bar "More" menu. Held here (not in RootView) so the
    // @Query churn stays scoped to this lightweight host.
    @Query private var pendingDeletes: [PendingDelete]

    @State private var vm: SortSessionViewModel?
    @State private var hasAppeared = false
    @State private var showingContextEditor = false
    @State private var viewingAlbum: AlbumSheetItem?

    /// One-time coach tip on the first sort, pointing at the album grid. The
    /// persisted flag gates whether it's ever shown again; `coachTipDismissed` is
    /// local state that drives the *exit* animation — mutating `@AppStorage` inside
    /// `withAnimation` doesn't animate (UserDefaults publishes outside the
    /// transaction), so the dismissal is animated via this and `hasSeenSortTip` is
    /// persisted only after the exit has played.
    @AppStorage("hasSeenSortTip") private var hasSeenSortTip = false
    @State private var coachTipDismissed = false

    var body: some View {
        Group {
            if let vm {
                SortSessionRepresentable(
                    vm: vm,
                    trashCount: pendingDeletes.count,
                    skippedCount: context.skips.count,
                    onShowContextList: onShowContextList,
                    onShowTrash: onShowTrash,
                    onShowSkipped: onShowSkipped,
                    onEditContext: { showingContextEditor = true },
                    onViewAlbum: { id, title in viewingAlbum = AlbumSheetItem(id: id, title: title) },
                    onDebugClear: onDebugClear,
                    onDebugShowOnboarding: onDebugShowOnboarding
                )
                .ignoresSafeArea()
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) {
            if vm != nil, !hasSeenSortTip, !coachTipDismissed {
                SortCoachTip { dismissCoachTip() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                    // Insertion is instant (.identity) so the tip is always visible
                    // even when it's added after the first render without animation.
                    // The exit is the animated part — driven inside withAnimation via
                    // coachTipDismissed, so the removal transition reliably plays.
                    .transition(
                        reduceMotion
                        ? .asymmetric(insertion: .identity, removal: .opacity)
                        : .asymmetric(
                            insertion: .identity,
                            // Shrink toward the album grid and drop away with a little
                            // spring overshoot, rather than blinking out.
                            removal: .scale(scale: 0.84, anchor: .bottom)
                                .combined(with: .move(edge: .bottom))
                                .combined(with: .opacity)
                        )
                    )
            }
        }
        // RootView's NavigationStack bar is hidden for this screen; the UIKit
        // UINavigationController provides the bar instead.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingContextEditor, onDismiss: {
            Task { await vm?.rebuildQueue() }
        }) {
            ContextEditorView(mode: .edit(context))
        }
        .sheet(item: $viewingAlbum, onDismiss: { vm?.refreshAlbumCounts() }) { album in
            PhotoCollectionView(mode: .album(album))
        }
        .task {
            if vm == nil {
                vm = SortSessionViewModel(context: context, modelContext: modelContext)
                await vm?.start()
            }
        }
        .task(id: library.changeTick) {
            guard let vm, library.changeTick > 0 else { return }
            vm.handleLibraryChange()
        }
        .onAppear {
            if hasAppeared {
                Task { await vm?.refreshAfterReappear() }
            }
            hasAppeared = true
        }
        .onDisappear { ImageLoader.shared.reset() }
    }

    /// Animate the coach tip away via local @State (so the exit transition plays),
    /// then persist `hasSeenSortTip` once it's offscreen — persisting immediately
    /// would flip the derived show-condition and yank the view out without animating.
    private func dismissCoachTip() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.6)) {
            coachTipDismissed = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            hasSeenSortTip = true
        }
    }
}

// MARK: - UIKit host

/// Hosts `SortSessionViewController` inside a `UINavigationController` so the nav
/// bar is UIKit. The VC observes the view model itself, so `updateUIViewController`
/// only forwards the nav-bar chrome (counts + action closures).
private struct SortSessionRepresentable: UIViewControllerRepresentable {
    let vm: SortSessionViewModel
    var trashCount: Int
    var skippedCount: Int
    var onShowContextList: () -> Void
    var onShowTrash: () -> Void
    var onShowSkipped: () -> Void
    var onEditContext: () -> Void
    var onViewAlbum: (String, String) -> Void
    var onDebugClear: (() -> Void)?
    var onDebugShowOnboarding: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = SortSessionViewController(vm: vm)
        context.coordinator.sortVC = vc
        applyChrome(to: vc)
        let nav = UINavigationController(rootViewController: vc)
        nav.navigationBar.prefersLargeTitles = false
        return nav
    }

    func updateUIViewController(_ nav: UINavigationController, context: Context) {
        guard let vc = context.coordinator.sortVC else { return }
        applyChrome(to: vc)
    }

    private func applyChrome(to vc: SortSessionViewController) {
        vc.trashCount = trashCount
        vc.skippedCount = skippedCount
        vc.onShowContextList = onShowContextList
        vc.onShowTrash = onShowTrash
        vc.onShowSkipped = onShowSkipped
        vc.onEditContext = onEditContext
        vc.onViewAlbum = onViewAlbum
        vc.onDebugClear = onDebugClear
        vc.onDebugShowOnboarding = onDebugShowOnboarding
    }

    final class Coordinator {
        weak var sortVC: SortSessionViewController?
    }
}
