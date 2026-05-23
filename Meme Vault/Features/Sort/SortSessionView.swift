//
//  SortSessionView.swift
//  Meme Vault
//
//  Main sort screen: photo card on top, flat album list with checkmarks,
//  bottom toolbar.
//

import SwiftUI
import SwiftData
import Photos

struct SortSessionView: View {
    let context: OrgContext

    @Environment(\.modelContext) private var modelContext
    @Environment(PhotoLibrary.self) private var library

    @State private var vm: SortSessionViewModel?
    @State private var showUndoToast = false
    @State private var undoTimer: Task<Void, Never>?
    @State private var showingContextEditor = false
    @State private var columnCount = 3
    @State private var hasAppeared = false
    @State private var viewingAlbum: AlbumSheetItem?
    @State private var topSafeInset: CGFloat = 0
    @State private var contentMaxY: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @Namespace private var thumbnailNamespace

    // The bottom inset (home indicator) the album list extends under and must
    // re-add as a content margin so its content rests above the indicator.
    private var bottomSafeInset: CGFloat {
        max(0, screenHeight - contentMaxY)
    }

    private var columnCountKey: String {
        "albumGridColumns_\(context.uuid.uuidString)"
    }

    private var photoHeightKey: String {
        "photoHeight_\(context.uuid.uuidString)"
    }


    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The content area sits between the nav bar and the home indicator, so
        // its global top/bottom offsets give the insets the grid and album list
        // extend under and must re-add as content margins.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            topSafeInset = frame.minY
            contentMaxY = frame.maxY
        }
        .background {
            // Full-screen probe for the device height, used to derive the
            // bottom inset (height − content bottom).
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { screenHeight = $0 }
        }
        .navigationTitle(context.name.isEmpty ? "Sort" : context.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if let vm {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if vm.isBulkMode {
                                    vm.exitBulkMode()
                                } else {
                                    vm.enterBulkMode()
                                }
                            }
                        } label: {
                            Image(systemName: vm.isBulkMode
                                   ? "square.grid.2x2.fill"
                                   : "square.grid.2x2")
                                .foregroundStyle(vm.isBulkMode ? Color.accentColor : Color.primary)
                        }
                    }
                    Button("Edit Context", systemImage: "slider.horizontal.3") {
                        showingContextEditor = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingContextEditor, onDismiss: {
            Task { await vm?.rebuildQueue() }
        }) {
            ContextEditorView(mode: .edit(context))
        }
        .task {
            if vm == nil {
                vm = SortSessionViewModel(context: context, modelContext: modelContext)
                await vm?.start()
            }
        }
        .task(id: library.changeTick) {
            // External Photos changes — only act after first load.
            guard let vm, library.changeTick > 0 else { return }
            vm.handleLibraryChange()
        }
        .onAppear {
            let stored = UserDefaults.standard.object(forKey: columnCountKey) as? Int
            columnCount = stored ?? 3
            if hasAppeared {
                Task { await vm?.refreshAfterReappear() }
            }
            hasAppeared = true
        }
        .onChange(of: columnCount) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: columnCountKey)
        }
    }

    @ViewBuilder
    private func content(vm: SortSessionViewModel) -> some View {
        if vm.isLoading {
            ProgressView("Scanning library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.queue.isEmpty {
            allDoneView
        } else if vm.currentAsset != nil || vm.isBulkMode {
            sortContent(vm: vm)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Done state

    private var allDoneView: some View {
        ContentUnavailableView {
            Label("All Sorted!", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } description: {
            Text("Every photo in this context belongs to at least one destination album.")
        }
    }

    // MARK: - Sort content

    @ViewBuilder
    private func sortContent(vm: SortSessionViewModel) -> some View {
        VStack(spacing: 6) {
            // Progress header — browse mode only. In bulk mode the selection
            // count floats over the grid so the grid can reach the nav bar.
            if !vm.isBulkMode {
                HStack {
                    Text(vm.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if vm.isSatisfied {
                        Label("Sorted", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
            }

            // Resizable media region (browse card or selection grid) plus its
            // resize grabber, extracted into a child view that owns photoHeight.
            // Dragging the grabber then re-evaluates only that subtree, leaving
            // the album grid, control bar, and queue strip — siblings here —
            // out of the per-frame invalidation scope.
            MediaRegionView(
                vm: vm,
                namespace: thumbnailNamespace,
                topSafeInset: topSafeInset,
                photoHeightKey: photoHeightKey
            )

            // Browse mode keeps the horizontal queue strip below the grabber.
            if !vm.isBulkMode {
                QueueThumbnailsView(
                    assetIDs: vm.queue,
                    isBulkMode: false,
                    currentID: vm.currentAssetID,
                    selectedIDs: vm.bulkSelectedIDs,
                    onTap: { vm.showAsset(id: $0) },
                    namespace: thumbnailNamespace
                )
            }

            // Control bar
            controlBar(vm: vm)

            // Album list
            albumList(vm: vm)
        }
        // No bottom padding: the album list extends to the screen edge and its
        // content inset respects the home indicator. No top padding in bulk
        // mode so the grid sits flush against the nav bar.
        .padding(.top, vm.isBulkMode ? 0 : 4)
        .overlay(alignment: .bottom) {
            if showUndoToast, let action = vm.lastAction {
                undoToast(action: action, vm: vm)
                    .padding(.bottom, 16)
            }
        }
        .sheet(item: $viewingAlbum) { album in
            AlbumContentsView(album: album)
        }
        .alert(
            "No Destination Album",
            isPresented: Binding(
                get: { vm.showExtraOnlyAlert },
                set: { vm.showExtraOnlyAlert = $0 }
            )
        ) {
            Button("Skip Item") {
                Task { await vm.skipFromExtraOnlyAlert() }
            }
            Button("Select Destination", role: .cancel) {
                vm.dismissExtraOnlyAlert()
            }
        } message: {
            Text("This item isn't in any of this context's destination albums. Skip it, or go back and select a destination.")
        }
    }

    // MARK: - Album grid

    private var albumColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    @ViewBuilder
    private func albumList(vm: SortSessionViewModel) -> some View {
        let infos = vm.albumInfos
        let extras = vm.extraAlbumInfos
        let memberIDs = Set(vm.memberships.filter(\.isMember).map(\.id))
        let bulkDirect = vm.isBulkMode && !vm.isMultiSelectActive
        let bulkDisabled = bulkDirect && vm.bulkSelectedIDs.isEmpty
        ScrollView {
            LazyVGrid(columns: albumColumns, spacing: 8) {
                ForEach(infos, id: \.id) { info in
                    let isMember = memberIDs.contains(info.id)
                    Button {
                        if bulkDirect {
                            Task {
                                await vm.bulkSortToAlbum(info.id)
                                if case .bulkSorted = vm.lastAction { showToast() }
                            }
                        } else {
                            Task {
                                await vm.toggleAlbum(info.id)
                                if case .sorted = vm.lastAction { showToast() }
                            }
                        }
                    } label: {
                        AlbumGridCell(
                            albumID: info.id,
                            title: info.title,
                            count: info.assetCount,
                            isMember: bulkDirect ? false : isMember,
                            refreshTrigger: vm.albumRefreshVersions[info.id] ?? 0
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(bulkDisabled)
                    .contextMenu {
                        Button("View Contents", systemImage: "photo.on.rectangle") {
                            viewingAlbum = AlbumSheetItem(id: info.id, title: info.title)
                        }
                    }
                }
                ForEach(vm.pinnedAlbumInfos, id: \.id) { info in
                    let isMember = vm.memberships.first { $0.id == info.id }?.isMember ?? false
                    Button {
                        if bulkDirect {
                            Task {
                                await vm.bulkSortToAlbum(info.id)
                                if case .bulkSorted = vm.lastAction { showToast() }
                            }
                        } else {
                            if !vm.isMultiSelectActive {
                                vm.activateMultiSelect()
                            }
                            Task { await vm.toggleAlbum(info.id) }
                        }
                    } label: {
                        AlbumGridCell(
                            albumID: info.id,
                            title: info.title,
                            count: info.assetCount,
                            isMember: bulkDirect ? false : isMember,
                            refreshTrigger: vm.albumRefreshVersions[info.id] ?? 0
                        )
                        .opacity(isMember ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .disabled(bulkDisabled)
                    .contextMenu {
                        Button("View Contents", systemImage: "photo.on.rectangle") {
                            viewingAlbum = AlbumSheetItem(id: info.id, title: info.title)
                        }
                    }
                }
                ForEach(extras, id: \.id) { info in
                    let isMember = memberIDs.contains(info.id)
                    Button {
                        Task {
                            await vm.toggleAlbum(info.id)
                            if case .sorted = vm.lastAction { showToast() }
                        }
                    } label: {
                        AlbumGridCell(
                            albumID: info.id,
                            title: info.title,
                            count: info.assetCount,
                            isMember: isMember,
                            refreshTrigger: vm.albumRefreshVersions[info.id] ?? 0
                        )
                        .opacity(isMember ? 1 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("View Contents", systemImage: "photo.on.rectangle") {
                            viewingAlbum = AlbumSheetItem(id: info.id, title: info.title)
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 20)))
                }
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.25), value: infos.map(\.id))
            .animation(.easeInOut(duration: 0.25), value: vm.pinnedAlbumInfos.map(\.id))
            .animation(.easeInOut(duration: 0.25), value: vm.extraAlbumIDs)
            .animation(.easeInOut(duration: 0.25), value: vm.isMultiSelectActive)
        }
        // Extend under the home indicator, then re-add it as a content margin
        // so the resting content and scroll indicator stay within the safe area.
        .contentMargins(.bottom, bottomSafeInset)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: - Control bar

    private func controlBar(vm: SortSessionViewModel) -> some View {
        let bulkNoSelection = vm.isBulkMode && vm.bulkSelectedIDs.isEmpty
        return HStack {
            Button {
                Task { await vm.undo(); showUndoToast = false }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 36)
            }
            .disabled(!vm.canUndo)

            Spacer()

            Button {
                if vm.isBulkMode {
                    Task { await vm.bulkQueueDelete(); showToast() }
                } else {
                    Task { await vm.queueDelete(); showToast() }
                }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(.red)
            }
            .disabled(bulkNoSelection)

            Spacer()

            Button {
                if vm.isBulkMode {
                    Task { await vm.bulkSkip(); showToast() }
                } else {
                    Task { await vm.skip(); showToast() }
                }
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .frame(width: 44, height: 36)
            }
            .disabled(bulkNoSelection)

            Spacer()

            Button {
                if vm.isBulkMode {
                    Task { await vm.bulkToggleFavorite() }
                } else {
                    Task { await vm.toggleFavorite() }
                }
            } label: {
                Image(systemName: vm.isFavorite ? "heart.fill" : "heart")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(vm.isFavorite ? .yellow : .secondary)
            }
            .disabled(bulkNoSelection)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    columnCount = min(5, columnCount + 1)
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 36)
            }
            .disabled(columnCount >= 5)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    columnCount = max(2, columnCount - 1)
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 36)
            }
            .disabled(columnCount <= 2)

            Button {
                if vm.isMultiSelectActive {
                    Task {
                        await vm.deactivateMultiSelect()
                        if case .sortedMulti = vm.lastAction { showToast() }
                        if case .bulkSorted = vm.lastAction { showToast() }
                    }
                } else {
                    vm.activateMultiSelect()
                }
            } label: {
                Image(systemName: vm.isMultiSelectActive ? "rectangle.stack.fill" : "rectangle.stack")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(vm.isMultiSelectActive ? Color.accentColor : Color.primary)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Undo toast

    private func showToast() {
        showUndoToast = true
        undoTimer?.cancel()
        undoTimer = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled {
                showUndoToast = false
            }
        }
    }

    private func undoToast(action: SortSessionViewModel.SortAction, vm: SortSessionViewModel) -> some View {
        let label: String = {
            switch action {
            case .sorted: return "Sorted"
            case .sortedMulti: return "Sorted"
            case .skipped: return "Skipped"
            case .queuedDelete: return "Queued for deletion"
            case .bulkSorted(_, _, let removed):
                return "Sorted \(removed.count) photo\(removed.count == 1 ? "" : "s")"
            case .bulkSkipped(let ids):
                return "Skipped \(ids.count) photo\(ids.count == 1 ? "" : "s")"
            case .bulkDeleted(let ids):
                return "Queued \(ids.count) for deletion"
            }
        }()
        return HStack {
            Text(label)
            Spacer()
            Button("Undo") {
                Task {
                    await vm.undo()
                    showUndoToast = false
                }
            }
            .bold()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Media region

/// The resizable media region — the browse card or the bulk-selection grid —
/// plus the resize grabber that drives its height. `photoHeight` lives here
/// rather than in `SortSessionView` so a resize drag re-evaluates only this
/// subtree; the album grid, control bar, and queue strip are siblings in the
/// parent and stay out of the per-frame invalidation scope. Identity is stable
/// across a bulk-mode toggle (the parent always builds this view in the same
/// slot), so the region keeps its size when switching modes.
private struct MediaRegionView: View {
    let vm: SortSessionViewModel
    let namespace: Namespace.ID
    let topSafeInset: CGFloat
    let photoHeightKey: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var photoHeight: CGFloat = 300
    @State private var dragStartHeight: CGFloat?
    @State private var wasInNotch = false

    private let minPhotoHeight: CGFloat = 120
    private let maxPhotoHeight: CGFloat = 500
    private let defaultPhotoHeight: CGFloat = 300
    private let notchRadius: CGFloat = 30
    private let notchDamping: CGFloat = 0.25

    var body: some View {
        VStack(spacing: 6) {
            if vm.isBulkMode {
                // The grid extends up under the translucent nav bar; its
                // ScrollView re-adds a content inset equal to the consumed
                // safe area, so resting content stays below the bar while
                // scrolling reveals it underneath. The selection count is a
                // sibling in the ZStack (not inside the safe-area-ignoring
                // grid), so it floats just below the bar.
                ZStack(alignment: .topLeading) {
                    QueueThumbnailsView(
                        assetIDs: vm.queue,
                        isBulkMode: true,
                        currentID: vm.currentAssetID,
                        selectedIDs: vm.bulkSelectedIDs,
                        onTap: { vm.toggleBulkSelection($0) },
                        namespace: namespace
                    )
                    .contentMargins(.top, topSafeInset)
                    .ignoresSafeArea(.container, edges: .top)

                    Text("\(vm.bulkSelectedIDs.count) selected")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .padding(.leading, 8)
                }
                .frame(height: photoHeight)
            } else {
                PhotoCardView(
                    assetIDs: vm.queue,
                    currentID: Binding(
                        get: { vm.currentAssetID },
                        set: { id in if let id { vm.showAsset(id: id) } }
                    )
                )
                .frame(height: photoHeight)
                .transition(.blurReplace)
            }

            // Resize grabber — drives photoHeight in both modes. The snap-to-
            // default notch only applies in browse mode; the grid has no
            // meaningful default height, so there it tracks the finger freely.
            resizeGrabber(notchEnabled: !vm.isBulkMode)
        }
        .onAppear {
            if let stored = UserDefaults.standard.object(forKey: photoHeightKey) as? Double {
                photoHeight = CGFloat(stored)
            }
        }
        .onChange(of: photoHeight) { _, newValue in
            UserDefaults.standard.set(Double(newValue), forKey: photoHeightKey)
        }
    }

    // MARK: - Resize grabber

    private func resizeGrabber(notchEnabled: Bool) -> some View {
        Capsule()
            .fill(Color(.tertiaryLabel))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = photoHeight
                            wasInNotch = notchEnabled && abs(photoHeight - defaultPhotoHeight) < 1
                        }
                        let raw = dragStartHeight! + value.translation.height
                        let clamped = min(maxPhotoHeight, max(minPhotoHeight, raw))
                        let inNotch = notchEnabled && abs(clamped - defaultPhotoHeight) <= notchRadius
                        let target = inNotch ? applyNotch(clamped) : clamped

                        if !inNotch, wasInNotch {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } else if inNotch, !wasInNotch {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        wasInNotch = inNotch

                        // Re-target the same interactive spring every frame. Springs
                        // are retargetable and preserve velocity, so continued
                        // dragging smoothly re-aims the height rather than cancelling
                        // the catch-up that fires when we leave the notch.
                        if reduceMotion {
                            photoHeight = target
                        } else {
                            withAnimation(trackingAnimation) {
                                photoHeight = target
                            }
                        }
                    }
                    .onEnded { value in
                        guard let start = dragStartHeight else { return }
                        let raw = start + value.translation.height
                        let clamped = min(maxPhotoHeight, max(minPhotoHeight, raw))
                        if notchEnabled, abs(clamped - defaultPhotoHeight) <= notchRadius {
                            withAnimation(releaseAnimation) {
                                photoHeight = defaultPhotoHeight
                            }
                        }
                        dragStartHeight = nil
                        wasInNotch = false
                    }
            )
    }

    // Springy resize tracking. interactiveSpring is built for gesture-driven
    // values: re-targeting it each frame merges with the in-flight motion
    // (preserving velocity) instead of restarting, so the height springs to the
    // finger and keeps following without judder.
    private var trackingAnimation: Animation {
        .interactiveSpring(response: 0.18, dampingFraction: 0.6, blendDuration: 0.2)
    }

    // Used for the snap-back to default on release; a quick non-bouncing ease
    // when the user has Reduce Motion enabled.
    private var releaseAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.32, dampingFraction: 0.7)
    }

    // Damped resistance while inside the notch; callers track the finger
    // directly once outside it.
    private func applyNotch(_ rawHeight: CGFloat) -> CGFloat {
        let delta = rawHeight - defaultPhotoHeight
        return defaultPhotoHeight + delta * notchDamping
    }
}

