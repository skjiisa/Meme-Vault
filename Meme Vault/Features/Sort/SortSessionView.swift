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

    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoLibrary.self) private var library

    // Trash count for the nav-bar "More" menu. Held here (not in RootView) so the
    // @Query churn stays scoped to this lightweight host.
    @Query private var pendingDeletes: [PendingDelete]

    @State private var vm: SortSessionViewModel?
    @State private var hasAppeared = false
    @State private var showingContextEditor = false
    @State private var viewingAlbum: AlbumSheetItem?

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
                    onDebugClear: onDebugClear
                )
                .ignoresSafeArea()
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    final class Coordinator {
        weak var sortVC: SortSessionViewController?
    }
}
