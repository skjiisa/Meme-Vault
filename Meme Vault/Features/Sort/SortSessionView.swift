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
    @Environment(\.displayScale) private var displayScale

    @State private var vm: SortSessionViewModel?
    @State private var showingContextEditor = false
    @State private var columnCount = 3
    @State private var hasAppeared = false
    @State private var bottomSafeInset: CGFloat = 0
    /// Global Y of the content's top (≈ the nav bar's bottom edge). In bulk mode the
    /// grid rests below this and scrolls up under the translucent nav bar.
    @State private var topSafeInset: CGFloat = 0
    /// Global Y of the media region's top (below the header). The bulk grid extends
    /// up by this much so its frame reaches the screen top, under the nav bar.
    @State private var regionTopInset: CGFloat = 0
    /// True for the duration of a bulk-mode transition: the carousel hides its own
    /// photo so the hero-zoom flight owns it, then the flight hands it back.
    @State private var heroForegroundSuppressed = false
    /// Lets the toolbar read the bulk grid's top-visible photo when exiting, so the
    /// carousel opens at the scroll position rather than where it was left.
    @State private var bulkAnchor = BulkGridAnchor()
    /// Display image pre-decoded for a scroll-anchored exit, so the hero zoom uses
    /// the full-aspect image (fit→fill) rather than the square thumbnail. Kept
    /// separate from `heroImage` so PhotoCardView's (asset, nil) report for the
    /// freshly-activated anchor page can't clobber it; the flight prefers it.
    @State private var preloadedHeroID: String?
    @State private var preloadedHeroImage: UIImage?
    /// Flies a copy of the hero photo into an album cell's first preview slot
    /// when a tap sorts it there. The media region feeds it the hero image and
    /// frame; the album grid cells feed it their slot frames.
    @State private var albumFlight = AlbumFlightCoordinator()

    /// In bulk mode the selection count lives in the nav bar (the grid scrolls
    /// under the bar, so there's no room for an in-content header).
    private var navTitle: String {
        if let vm, vm.isBulkMode {
            return "\(vm.bulkSelectedIDs.count) selected"
        }
        return context.name.isEmpty ? "Sort" : context.name
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
        // The album list extends under the home indicator and re-adds this inset
        // as a content margin. The bottom inset is read from the safe area
        // directly so it stays correct even though the list extends under the
        // home indicator — reading the content's own maxY would just report the
        // extended (screen) edge.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeInset = $0 }
        // The content's global top sits just under the nav bar; the bulk grid uses
        // it to inset its resting content below the bar while extending under it.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { topSafeInset = $0 }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if let vm {
                        Button {
                            if vm.isBulkMode {
                                exitBulkMode(vm: vm)
                            } else {
                                enterBulkMode(vm: vm)
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
        .onDisappear { ImageLoader.shared.reset() }
        .onChange(of: columnCount) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: columnCountKey)
        }
    }

    // MARK: - Bulk mode toggle

    private func enterBulkMode(vm: SortSessionViewModel) {
        preloadedHeroID = nil
        preloadedHeroImage = nil
        // Suppress the carousel's own photo for the whole transition so the
        // hero-zoom flight owns it; the flight hands it back on completion. The
        // card's backdrop and peeking neighbors fade via its opacity (bound to bulk
        // mode), concurrent with the flight.
        heroForegroundSuppressed = true
        withAnimation(.easeInOut(duration: 0.3)) { vm.enterBulkMode() }
    }

    /// Exit multi-select, opening the carousel at the first selected photo (in queue
    /// order) — or, if nothing is selected, at the grid's scroll position. Before
    /// flipping modes, pre-decode that photo's display image so the hero zoom uses
    /// the full-aspect image (fit→fill) instead of the square thumbnail.
    private func exitBulkMode(vm: SortSessionViewModel) {
        let firstSelected = vm.queue.first { vm.bulkSelectedIDs.contains($0) }
        guard let id = firstSelected ?? bulkAnchor.topVisibleID() else {
            heroForegroundSuppressed = true
            withAnimation(.easeInOut(duration: 0.3)) { vm.exitBulkMode() }
            return
        }
        // Point the carousel at the anchor up front, without animation, so it
        // doesn't visibly whip-scroll to the new page once it reappears — it jumps
        // there (invisibly, behind the grid) while the display image decodes.
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) { vm.showAsset(id: id) }
        Task {
            if let image = await preloadDisplayImage(for: id) {
                preloadedHeroID = id
                preloadedHeroImage = image
            }
            heroForegroundSuppressed = true
            withAnimation(.easeInOut(duration: 0.3)) { vm.exitBulkMode() }
        }
    }

    /// Decode the asset's display image at hero size, capped so a slow (e.g. iCloud)
    /// fetch can't stall the exit — returns nil on timeout and the flight falls back
    /// to the cached thumbnail.
    private func preloadDisplayImage(for id: String) async -> UIImage? {
        let side = 600 * displayScale
        let target = CGSize(width: side, height: side)
        return await withTaskGroup(of: UIImage?.self) { group in
            group.addTask {
                guard let asset = AlbumService.asset(for: id) else { return nil }
                return await ImageLoader.shared.loadDisplayImage(for: asset, targetSize: target)
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
            // Header — always present (height reserved) so toggling bulk mode
            // doesn't reflow the content below it; a shift would desync the in-flight
            // hero zoom. Shows browse progress; in bulk it's hidden (the selection
            // count is in the nav bar) and the grid scrolls up over its area.
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
            .opacity(vm.isBulkMode ? 0 : 1)

            // Resizable media region — a single morphing collection view that is
            // the strip in browse mode and the multi-select grid in bulk mode,
            // with the PhotoCardView overlaid in browse mode — plus its resize
            // grabber. Extracted into a child view that owns photoHeight so
            // dragging the grabber re-evaluates only that subtree, leaving the
            // album grid and control bar (siblings here) out of the per-frame
            // invalidation scope.
            MediaRegionView(
                vm: vm,
                heroForegroundSuppressed: $heroForegroundSuppressed,
                anchor: bulkAnchor,
                albumFlight: albumFlight,
                preloadedHeroID: preloadedHeroID,
                preloadedHeroImage: preloadedHeroImage,
                topSafeInset: topSafeInset,
                regionTopInset: regionTopInset,
                photoHeightKey: photoHeightKey
            )
            // The media region's global top — the bulk grid extends up by this much
            // (to reach the screen top, under the nav bar).
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { regionTopInset = $0 }

            // Control bar and album grid are extracted into their own views so
            // their observation is scoped: a favorite toggle (read only by the
            // control bar) or a column change no longer re-evaluates the
            // carousel or progress header, and the album grid diffs on its own.
            ControlBarView(
                vm: vm,
                columnCount: $columnCount
            )

            AlbumListView(
                vm: vm,
                columnCount: columnCount,
                bottomSafeInset: bottomSafeInset,
                albumFlight: albumFlight
            )
        }
        // No bottom padding: the album list extends to the screen edge and its
        // content inset respects the home indicator. Constant top padding so the
        // layout doesn't shift when toggling bulk mode.
        .padding(.top, 4)
        // Topmost, spanning the whole sort screen: hosts the hero → album-slot
        // flight image so it can travel from the carousel down into the album
        // grid. Transparent and non-interactive otherwise.
        .overlay { HeroFlightOverlay(layer: albumFlight.layer) }
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

}

// MARK: - Media region

/// The resizable media region. It stacks the `MorphingThumbnailGrid` (which is
/// the horizontal strip in browse mode and the multi-select grid in bulk mode)
/// with the `PhotoCardView` overlaid in browse mode, plus the resize grabber that
/// drives its height. `photoHeight` lives here rather than in `SortSessionView`
/// so a resize drag re-evaluates only this subtree; the album grid and control
/// bar are siblings in the parent and stay out of the per-frame invalidation
/// scope. Identity is stable across a bulk-mode toggle (the parent always builds
/// this view in the same slot), so the region keeps its size when switching
/// modes and the collection view morphs in place rather than being rebuilt.
private struct MediaRegionView: View {
    let vm: SortSessionViewModel
    /// True for the duration of a bulk-mode transition. The carousel hides its own
    /// photo so the hero-zoom flight owns it; the flight's completion sets it back
    /// to false for a seamless handoff. Owned by `SortSessionView` and set true in
    /// the same action that toggles bulk mode (before the body commits).
    @Binding var heroForegroundSuppressed: Bool
    let anchor: BulkGridAnchor
    /// Receives the hero photo's latest image and on-screen frame, for the
    /// hero → album-slot flight that runs when a tap sorts the photo.
    let albumFlight: AlbumFlightCoordinator
    /// Pre-decoded full-aspect image for a scroll-anchored exit, with the asset it
    /// belongs to. Preferred by the flight over `heroImage` so the anchor photo
    /// zooms fit→fill even before PhotoCardView has loaded it.
    let preloadedHeroID: String?
    let preloadedHeroImage: UIImage?
    /// Content-top / media-region-top global Ys; in bulk the grid extends up under
    /// the nav bar by `regionTopInset` and rests `topSafeInset` below the top.
    let topSafeInset: CGFloat
    let regionTopInset: CGFloat
    let photoHeightKey: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var photoHeight: CGFloat = 300
    @State private var dragStartHeight: CGFloat?
    @State private var wasInNotch = false
    /// Latest decoded display image of the hero photo, reported by PhotoCardView,
    /// and the asset it belongs to. The hero-zoom flight uses the image (full
    /// aspect) rather than the cropped grid thumbnail — but only when `heroImageID`
    /// still matches the current photo, so a scroll-anchored exit doesn't fly the
    /// previous photo's image while the new one is still loading.
    @State private var heroImage: UIImage?
    @State private var heroImageID: String?
    /// Top overlay hosting the hero-zoom flight image, so it draws above the
    /// PhotoCardView as that fades its backdrop and peeking neighbors out/in.
    @State private var flightLayer = FlightLayer()

    private let minPhotoHeight: CGFloat = 120
    private let maxPhotoHeight: CGFloat = 500
    private let defaultPhotoHeight: CGFloat = 300
    private let notchRadius: CGFloat = 30
    private let notchDamping: CGFloat = 0.25

    /// The full-aspect image the hero-zoom flight should use for the current photo:
    /// the pre-decoded anchor image when present (scroll-anchored exit), otherwise
    /// PhotoCardView's reported image when it still matches the current photo.
    private var effectiveHeroImage: UIImage? {
        if preloadedHeroID == vm.currentAssetID, let image = preloadedHeroImage {
            return image
        }
        return heroImageID == vm.currentAssetID ? heroImage : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            // One collection view spans the whole region and morphs its cells
            // between the strip (browse) and grid (bulk) layouts in place. In
            // browse mode the PhotoCardView overlays the top, leaving the strip
            // band exposed at the bottom; in bulk mode the grid fills the region
            // and extends up under the nav bar (the selection count is in the bar).
            ZStack(alignment: .topLeading) {
                MorphingThumbnailGrid(
                    assetIDs: vm.queue,
                    isBulkMode: vm.isBulkMode,
                    currentID: vm.currentAssetID,
                    selectedIDs: vm.bulkSelectedIDs,
                    heroImage: effectiveHeroImage,
                    flightLayer: flightLayer,
                    anchor: anchor,
                    topSafeInset: topSafeInset,
                    regionTopInset: regionTopInset,
                    onTap: { id in
                        if vm.isBulkMode {
                            vm.toggleBulkSelection(id)
                        } else {
                            vm.showAsset(id: id)
                        }
                    },
                    onFlightComplete: { _ in heroForegroundSuppressed = false }
                )

                // The carousel stays mounted across the bulk toggle (so it never
                // reloads / flashes on return) and fades via opacity. Its own photo
                // is suppressed during the flight, which draws the photo instead;
                // the backdrop + peeking neighbors fade concurrently. Hit testing is
                // off in bulk so the (invisible) card doesn't eat grid taps.
                PhotoCardView(
                    assetIDs: vm.queue,
                    currentID: Binding(
                        get: { vm.currentAssetID },
                        set: { id in if let id { vm.showAsset(id: id) } }
                    ),
                    onActiveImage: { id, image in
                        heroImageID = id
                        heroImage = image
                        albumFlight.heroImageID = id
                        albumFlight.heroImage = image
                    },
                    suppressForeground: heroForegroundSuppressed,
                    departedID: albumFlight.flyingPhotoID ?? vm.heroDepartedID,
                    isForeground: !vm.isBulkMode
                )
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: photoHeight - MorphingThumbnailGrid.stripBandHeight)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    // The carousel insets its photo 24pt from each side (the same
                    // margin MorphingThumbnailGrid's heroRect uses); the flight
                    // aspect-fits the image within that page rect.
                    albumFlight.heroFrame = frame.insetBy(dx: 24, dy: 0)
                }
                .opacity(vm.isBulkMode ? 0 : 1)
                .allowsHitTesting(!vm.isBulkMode)

                // Topmost: the hero-zoom flight image draws here, above the fading
                // card. Transparent and non-interactive otherwise.
                HeroFlightOverlay(layer: flightLayer)
            }
            .frame(height: photoHeight)

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

// MARK: - Control bar

/// Bottom toolbar (undo, delete, skip, favorite, zoom, multi-select). Reads the
/// view model's transient per-asset state (`isFavorite`, `canUndo`, selection),
/// so isolating it here keeps a favorite toggle or undo-state change from
/// re-evaluating the carousel, progress header, or album grid.
private struct ControlBarView: View {
    let vm: SortSessionViewModel
    @Binding var columnCount: Int

    var body: some View {
        let bulkNoSelection = vm.isBulkMode && vm.bulkSelectedIDs.isEmpty
        HStack {
            Button {
                Task { await vm.undo() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 36)
            }
            .disabled(!vm.canUndo)

            Spacer()

            Button {
                if vm.isBulkMode {
                    Task { await vm.bulkQueueDelete() }
                } else {
                    Task { await vm.queueDelete() }
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
                    Task { await vm.bulkSkip() }
                } else {
                    Task { await vm.skip() }
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
                    Task { await vm.deactivateMultiSelect() }
                } else {
                    Task { await vm.activateMultiSelect() }
                }
            } label: {
                Image(systemName: vm.isMultiSelectActive ? "rectangle.stack.fill" : "rectangle.stack")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(vm.isMultiSelectActive ? Color.accentColor : Color.primary)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Album grid

/// The scrollable destination-album grid (context albums, pinned albums, and
/// extras). Extracted into its own view so it diffs independently of the
/// carousel and control bar, and owns the "view contents" sheet it presents.
private struct AlbumListView: View {
    let vm: SortSessionViewModel
    let columnCount: Int
    let bottomSafeInset: CGFloat
    let albumFlight: AlbumFlightCoordinator

    @State private var viewingAlbum: AlbumSheetItem?

    private var albumColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    var body: some View {
        let infos = vm.albumInfos
        let memberIDs = Set(vm.memberships.filter(\.isMember).map(\.id))
        let bulkDirect = vm.isBulkMode && !vm.isMultiSelectActive
        ScrollView {
            LazyVGrid(columns: albumColumns, spacing: 8) {
                AlbumsItems(
                    infos: infos,
                    bulkDirect: bulkDirect,
                    isMember: { info in memberIDs.contains(info.id) },
                    shouldFadeIfNotMember: false,
                    recentAdds: vm.recentAddsByAlbum,
                    albumFlight: albumFlight,
                    viewingAlbum: $viewingAlbum,
                ) { info in
                    if vm.isBulkMode {
                        await vm.bulkAlbumTap(info.id)
                    } else {
                        // Sorting (not removing) the photo: fly the hero image
                        // into the album preview's first slot as it's added.
                        // When the flight launches, the carousel page hands its
                        // photo over to it (goes blank, backdrop fades).
                        if !vm.isMultiSelectActive, !memberIDs.contains(info.id),
                           albumFlight.fly(toAlbum: info.id, heroID: vm.currentAssetID) {
                            vm.noteHeroFlightDeparture(vm.currentAssetID)
                        }
                        await vm.toggleAlbum(info.id)
                    }
                }

                AlbumsItems(
                    infos: vm.pinnedAlbumInfos,
                    bulkDirect: bulkDirect,
                    isMember: { info in vm.memberships.first { $0.id == info.id }?.isMember ?? false },
                    shouldFadeIfNotMember: true,
                    recentAdds: vm.recentAddsByAlbum,
                    albumFlight: albumFlight,
                    viewingAlbum: $viewingAlbum,
                ) { info in
                    if vm.isBulkMode {
                        await vm.bulkAlbumTap(info.id)
                    } else {
                        if !vm.isMultiSelectActive {
                            await vm.activateMultiSelect()
                        }
                        await vm.toggleAlbum(info.id)
                    }
                }

                AlbumsItems(
                    infos: vm.extraAlbumInfos,
                    bulkDirect: bulkDirect,
                    isMember: { info in memberIDs.contains(info.id) },
                    shouldFadeIfNotMember: true,
                    recentAdds: vm.recentAddsByAlbum,
                    albumFlight: albumFlight,
                    viewingAlbum: $viewingAlbum,
                ) { info in
                    await vm.toggleAlbum(info.id)
                }
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.25), value: Set(infos.map(\.id)))
            .animation(.easeInOut(duration: 0.25), value: Set(vm.pinnedAlbumInfos.map(\.id)))
            .animation(.easeInOut(duration: 0.25), value: vm.extraAlbumIDs)
            .animation(.easeInOut(duration: 0.25), value: vm.isMultiSelectActive)
        }
        // Extend under the home indicator, then re-add it as a content margin
        // so the resting content and scroll indicator stay within the safe area.
        .contentMargins(.bottom, bottomSafeInset)
        .ignoresSafeArea(.container, edges: .bottom)
        // Removals made in the contents sheet are self-writes that don't bump
        // `changeTick`, so refresh the counts (and thus the previews) here.
        .sheet(item: $viewingAlbum, onDismiss: { vm.refreshAlbumCounts() }) { album in
            PhotoCollectionView(mode: .album(album))
        }
    }
}

private struct AlbumsItems: View {
    let infos: [AlbumInfo]
    let bulkDirect: Bool
    let isMember: (AlbumInfo) -> Bool
    let shouldFadeIfNotMember: Bool
    /// Per-album photos added this session, surfaced first in the previews.
    var recentAdds: [String: [String]] = [:]
    /// Collects each cell's first-slot frame for the hero → album-slot flight.
    var albumFlight: AlbumFlightCoordinator? = nil
    @Binding var viewingAlbum: AlbumSheetItem?
    let onTap: (AlbumInfo) async -> Void

    var body: some View {
        ForEach(infos) { info in
            let isMember = self.isMember(info)
            Button {
                Task {
                    await onTap(info)
                }
            } label: {
                AlbumGridCell(
                    albumID: info.id,
                    title: info.title,
                    count: info.assetCount,
                    isMember: bulkDirect ? false : isMember,
                    recentIDs: recentAdds[info.id] ?? [],
                    hiddenThumbID: albumFlight?.flyingToAlbumID == info.id
                        ? albumFlight?.flyingPhotoID
                        : nil,
                    onFirstSlotFrame: albumFlight.map { flight in
                        { flight.slotFrames[info.id] = $0 }
                    }
                )
                .opacity((shouldFadeIfNotMember && !isMember) ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .onDisappear { albumFlight?.slotFrames.removeValue(forKey: info.id) }
            .contextMenu {
                Button("Sort to Album", systemImage: "rectangle.portrait.and.arrow.forward") {
                    Task {
                        await onTap(info)
                    }
                }
                
                Button("View Contents", systemImage: "photo.on.rectangle") {
                    viewingAlbum = AlbumSheetItem(id: info.id, title: info.title)
                }
            }
            .transition(.opacity.combined(with: .offset(y: 20)))
        }
    }
}

// MARK: - Album flight

/// Coordinates the hero → album-cell flight: when a tap sorts the current
/// photo into an album, a floating copy of the hero image flies from the
/// carousel into that album preview's first slot — the same UIKit flight
/// technique as the bulk-mode hero zoom, so it stays off SwiftUI's graph.
/// The media region reports the hero image/frame, the album grid cells report
/// their first-slot frames, and `fly` animates between them in the overlay.
@MainActor
@Observable
final class AlbumFlightCoordinator {
    /// Overlay spanning the sort screen that hosts the flight image view.
    let layer = FlightLayer()
    /// Latest full-aspect hero image and the asset it belongs to.
    @ObservationIgnored var heroImage: UIImage?
    @ObservationIgnored var heroImageID: String?
    /// Global frame of the carousel's photo page rect (inset by its margin).
    @ObservationIgnored var heroFrame: CGRect = .zero
    /// Global frame of each album preview's first slot, keyed by album ID.
    @ObservationIgnored var slotFrames: [String: CGRect] = [:]

    /// Set while a flight is airborne: the destination album and the photo in
    /// transit. The album cell keeps that thumbnail's slot blank until the
    /// flight lands, so the photo never shows twice at once.
    private(set) var flyingToAlbumID: String?
    private(set) var flyingPhotoID: String?
    /// Distinguishes overlapping flights so a stale completion doesn't clear
    /// a newer flight's in-transit state.
    @ObservationIgnored private var flightGeneration = 0

    private static let flightDuration: TimeInterval = 0.35
    private static let landingFadeDuration: TimeInterval = 0.18

    /// Returns true when the flight actually launched (album cell on screen,
    /// image available) — the caller hides the carousel photo only then.
    @discardableResult
    func fly(toAlbum albumID: String, heroID: String?) -> Bool {
        let host = layer.view
        guard let heroID, host.window != nil,
              let slotGlobal = slotFrames[albumID],
              heroFrame.width > 0
        else { return false }

        // Prefer the full-aspect hero image (fit→fill morph, like the bulk
        // hero zoom); fall back to the square strip thumbnail (fill→fill)
        // when it hasn't decoded yet.
        let displayImage = heroImageID == heroID ? heroImage : nil
        let thumbSide = 80 * host.traitCollection.displayScale
        let image = displayImage ?? ImageLoader.shared.cachedThumbnail(
            localID: heroID,
            targetSize: CGSize(width: thumbSide, height: thumbSide)
        )
        guard let image else { return false }

        // SwiftUI's global space is the window's coordinate space; convert
        // both endpoints into the overlay and skip if the slot scrolled away.
        let fromGlobal = displayImage != nil
            ? Self.aspectFitRect(for: image.size, in: heroFrame)
            : heroFrame
        let from = host.convert(fromGlobal, from: nil)
        let to = host.convert(slotGlobal, from: nil)
        guard host.bounds.intersects(to) else { return false }

        // Mark the photo as in transit so the album cell leaves its slot
        // blank until the flight lands (all guards passed — the flight is on).
        flightGeneration += 1
        let generation = flightGeneration
        flyingToAlbumID = albumID
        flyingPhotoID = heroID

        let fv = UIImageView(image: image)
        fv.contentMode = .scaleAspectFill
        fv.clipsToBounds = true
        fv.frame = from
        host.addSubview(fv)

        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = 0
        corner.toValue = 6
        corner.duration = Self.flightDuration
        corner.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fv.layer.add(corner, forKey: "cornerRadius")
        fv.layer.cornerRadius = 6

        UIView.animate(withDuration: Self.flightDuration, delay: 0, options: [.curveEaseInOut]) {
            fv.frame = to
        } completion: { _ in
            // Landed: reveal the real thumbnail beneath, then fade the flight
            // image out over it for a seamless handoff.
            if self.flightGeneration == generation {
                self.flyingToAlbumID = nil
                self.flyingPhotoID = nil
            }
            UIView.animate(withDuration: Self.landingFadeDuration, delay: 0, options: [.curveEaseOut]) {
                fv.alpha = 0
            } completion: { _ in
                fv.removeFromSuperview()
            }
        }
        return true
    }

    /// The rect an `imageSize` photo occupies when aspect-fit (letterboxed)
    /// inside `bounds`, centered — where an aspectFill view shows the whole
    /// photo with no crop, matching the hero's appearance.
    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}
