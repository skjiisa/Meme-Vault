//
//  SortSessionViewController.swift
//  Meme Vault
//
//  The sort screen, rewritten as a single UIKit view controller that owns every
//  region in one coordinate space: the hero photo carousel, the morphing preview
//  strip / bulk multi-select grid, the destination album grid, the control bar,
//  the resize grabber, and both flight overlays. Hosted by `SortSessionView`
//  inside a `UINavigationController`, so the nav bar is UIKit too and the VC owns
//  the top + bottom safe areas directly.
//
//  Observes the `@Observable` `SortSessionViewModel` via `withObservationTracking`
//  and reconciles UIKit state on each change. Putting the carousel, grid, and both
//  flights in one coordinate space removes the SwiftUI↔UIKit global-frame plumbing
//  that previously desynced the hero zoom / album flight.
//

import UIKit
import UIKit.UIGestureRecognizerSubclass
import Photos
import Observation

@MainActor
final class SortSessionViewController: UIViewController {

    private let vm: SortSessionViewModel
    private let context: OrgContext

    // Chrome supplied by the SwiftUI wrapper (RootView's nav-bar items + sheets).
    var trashCount = 0 { didSet { if isViewLoaded, trashCount != oldValue { updateNavBar() } } }
    var skippedCount = 0 { didSet { if isViewLoaded, skippedCount != oldValue { updateNavBar() } } }
    var onShowContextList: () -> Void = {}
    var onShowTrash: () -> Void = {}
    var onShowSkipped: () -> Void = {}
    var onEditContext: () -> Void = {}
    var onViewAlbum: (String, String) -> Void = { _, _ in }
    var onDebugClear: (() -> Void)?
    var onDebugShowOnboarding: (() -> Void)?

    // Regions
    private let carousel = PhotoCarouselController()
    private let morph = MorphController()
    private let album = AlbumGridController()

    // Containers
    private let headerContainer = UIView()
    private let progressLabel = UILabel()
    private let sortedBadge = UIStackView()
    private let mediaRegion = UIView()
    private let flightOverlay = UIView()       // hero-zoom, over the carousel
    private let albumFlightOverlay = UIView()  // hero → album-slot, over everything
    private let resizeGrabber = UIView()
    private let controlBar = UIStackView()   // row of grouped glass capsules
    private let controlBarContainer: UIVisualEffectView = {
        let effect = UIGlassContainerEffect()
        effect.spacing = 0   // keep groups as distinct capsules (no merging)
        return UIVisualEffectView(effect: effect)
    }()
    private let messageView = UIStackView()    // loading spinner (full-screen)

    // "All sorted" celebration shown *inside* the media region, so the album
    // picker + control bar stay on screen behind/around it.
    private let completionView = UIView()
    private let completionCheckmark = UIImageView()
    private var lastCompletionShown = false

    // Photo-grid zoom bar — a floating Liquid Glass capsule shown in multi-select
    // mode, sitting in the strip band, that zooms the bulk photo grid.
    private let photoGridZoomBar: UIVisualEffectView = {
        let glass = UIGlassEffect()
        glass.isInteractive = true
        return UIVisualEffectView(effect: glass)
    }()
    private let photoZoomOutButton = UIButton(type: .system)
    private let photoZoomInButton = UIButton(type: .system)

    // Control-bar buttons (kept to update enabled / image state).
    private let undoButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let skipButton = UIButton(type: .system)
    private let favoriteButton = UIButton(type: .system)
    private let zoomOutButton = UIButton(type: .system)
    private let zoomInButton = UIButton(type: .system)
    private let multiSelectButton = UIButton(type: .system)

    // Constraints driven at runtime.
    private var mediaHeightConstraint: NSLayoutConstraint!
    private var morphTopConstraint: NSLayoutConstraint!
    private var carouselBottomConstraint: NSLayoutConstraint!
    private var grabberHeightConstraint: NSLayoutConstraint!

    // Adaptive layout: a single vertical column (compact width) vs a two-pane
    // side-by-side layout (regular width — iPad full screen / large multitasking
    // windows). The photo column (carousel + strip + grabber) sits on the left and
    // the album grid on the right; the floating glass toolbar spans the bottom in
    // both. `leftColumnGuide`'s trailing edge is the column divider.
    private let leftColumnGuide = UILayoutGuide()
    private var leftColumnWidthConstraint: NSLayoutConstraint!
    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []
    private var isRegularLayout = false
    /// Fraction of the width the photo column gets in the two-pane layout, driven by
    /// the vertical divider grabber and persisted per context.
    private var regularLeftFraction: CGFloat = 0.55
    private let minColumnWidth: CGFloat = 280
    /// Vertical divider handle shown only in two pane; dragged horizontally to
    /// rebalance the photo column against the album column.
    private let columnGrabber = UIView()
    private var dragStartLeftWidth: CGFloat?

    // Resize state. Hero height (the media region) ranges over [minPhotoHeight,
    // maxPhotoHeight], minus `MorphController.stripBandHeight` (44) of preview strip —
    // so the photo itself spans ~96pt…~516pt. Detail viewing is handled by pinch-zoom,
    // so this grabber is about layout balance (photo vs album grid), not inspection.
    private var photoHeight: CGFloat = 300
    private var dragStartHeight: CGFloat?
    private var wasInNotch = false
    private let minPhotoHeight: CGFloat = 160
    private let maxPhotoHeight: CGFloat = 560
    private let defaultPhotoHeight: CGFloat = 320
    private let notchRadius: CGFloat = 30
    private let notchDamping: CGFloat = 0.25
    /// Album grid kept on screen (single-column layout) when the hero is dragged to its
    /// tallest, so growing the photo never fully hides the destinations. On most iPhones
    /// this — not `maxPhotoHeight` — is what caps the hero height; the ceiling only binds
    /// on large screens / iPad.
    private let minAlbumVisible: CGFloat = 140

    // Column count for the album grid.
    private var columnCount = 3

    // Column count for the bulk multi-select photo grid.
    private var photoColumnCount = 5
    private let minPhotoColumns = 3
    private let maxPhotoColumns = 7
    private let photoZoomBarClearance: CGFloat = 56

    // Hero image reported by the carousel's active page (for the flights).
    private var heroImage: UIImage?
    private var heroImageID: String?
    // Pre-decoded full-aspect image for a scroll-anchored bulk exit.
    private var preloadedHeroID: String?
    private var preloadedHeroImage: UIImage?
    private var heroForegroundSuppressed = false

    // Pinch-to-zoom on the hero: a floating copy lifted into `albumFlightOverlay`
    // (above the grid + toolbar, non-clipping) so it can grow over the rest of the
    // screen, plus a scrim that darkens behind it. The carousel keeps the page's
    // blurred backdrop as a placeholder while the sharp copy is lifted.
    private var heroZoomView: UIImageView?
    private var heroZoomScrim: UIView?
    /// Holds the lifted copy; during the snap-back it's translated to track carousel
    /// scrolling so the copy rides its page home instead of springing to a stale center.
    private var heroZoomContainer: UIView?
    private var heroZoomStartCenter: CGPoint = .zero
    /// Carousel content offset captured when the snap-back begins, so scroll since then
    /// drives the container's translation.
    private var heroZoomDismissStartOffsetX: CGFloat = 0
    /// True while the lifted copy is springing back, so a re-pinch over the snap-back
    /// is ignored rather than fighting (and being torn down by) the in-flight animation.
    private var heroZoomDismissing = false

    // Hero image kept at sort time, keyed by photo ID, so an undo can start the
    // reverse flight immediately (overlapping the carousel slide) instead of
    // awaiting a fresh decode that would run only after the slide finishes.
    private var sortedHeroImages: [(id: String, image: UIImage, fit: Bool)] = []

    // Album-flight bookkeeping.
    private var albumFlightGeneration = 0

    // Observation diff cache.
    private var lastQueue: [String] = []
    private var lastCurrentID: String?
    private var lastBulkMode = false
    private var lastSelected: Set<String> = []
    private var lastMultiSelect = false
    private var lastFavorite = false
    private var lastCanUndo = false
    private var lastActionsDisabled = false
    private var lastProgress = ""
    private var lastSatisfied = false
    private var lastDeparted: String?
    private var lastExtraAlert = false
    private var lastNavTitle = ""
    private var lastWriteErrorToken = 0
    private var didInitialContent = false

    private var writeErrorBanner: UIView?

    private let columnKey: String
    private let photoColumnKey: String
    private let photoHeightKey: String
    private let splitFractionKey: String

    init(vm: SortSessionViewModel) {
        self.vm = vm
        self.context = vm.context
        self.columnKey = "albumGridColumns_\(vm.context.uuid.uuidString)"
        self.photoColumnKey = "photoGridColumns_\(vm.context.uuid.uuidString)"
        self.photoHeightKey = "photoHeight_\(vm.context.uuid.uuidString)"
        self.splitFractionKey = "sortSplitFraction_\(vm.context.uuid.uuidString)"
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        edgesForExtendedLayout = .all
        extendedLayoutIncludesOpaqueBars = true

        columnCount = (UserDefaults.standard.object(forKey: columnKey) as? Int) ?? 3
        album.columns = max(2, min(5, columnCount))
        photoColumnCount = max(minPhotoColumns, min(maxPhotoColumns,
            (UserDefaults.standard.object(forKey: photoColumnKey) as? Int) ?? 5))
        morph.gridColumns = photoColumnCount
        morph.gridBottomInset = photoZoomBarClearance
        if let stored = UserDefaults.standard.object(forKey: photoHeightKey) as? Double {
            photoHeight = min(maxPhotoHeight, max(minPhotoHeight, CGFloat(stored)))
        }
        if let storedFraction = UserDefaults.standard.object(forKey: splitFractionKey) as? Double {
            regularLeftFraction = min(0.7, max(0.3, CGFloat(storedFraction)))
        }

        buildHierarchy()
        wireRegions()
        configureControlBar()
        configurePhotoZoomBar()
        configureGrabber()
        configureColumnGrabber()
        configureHeroPinch()
        updateNavBar()
        observeVM()

        // Swap between the single-column and two-pane layouts when the window
        // crosses the horizontal size-class boundary (iPad resize / rotation).
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: SortSessionViewController, _) in
            self.applyAdaptiveLayout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        morph.targetSize = thumbTargetSize
        carousel.updateLayoutMetrics()
        applyInsets()
        // Keep the column split + photo region within the space the window actually
        // has — a short or resized window must never starve the album grid / controls.
        applyColumnWidth()
        clampMediaHeight()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyInsets()
    }

    private var thumbTargetSize: CGSize {
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let side = 80 * scale
        return CGSize(width: side, height: side)
    }

    /// Top/bottom safe-area handling — the single source of truth that replaces
    /// the old SwiftUI `.onGeometryChange(.global)` plumbing.
    private func applyInsets() {
        // Inset the grid so its content scrolls clear of the floating glass
        // toolbar (whose top sits above the bottom safe area), plus a small gap.
        let toolbarClearance = max(view.safeAreaInsets.bottom,
                                   view.bounds.maxY - controlBarContainer.frame.minY + 8)
        album.setBottomInset(toolbarClearance)
        let topSafeInset = view.safeAreaInsets.top
        let regionTopInset = mediaRegion.frame.minY
        morph.applyBulkInsets(topConstraint: morphTopConstraint, topSafeInset: topSafeInset, regionTopInset: regionTopInset)
    }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        // Header
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerContainer)

        progressLabel.font = .preferredFont(forTextStyle: .caption1)
        progressLabel.textColor = .secondaryLabel
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(progressLabel)

        let badgeIcon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        badgeIcon.tintColor = .systemGreen
        badgeIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        let badgeLabel = UILabel()
        badgeLabel.text = "Sorted"
        badgeLabel.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        badgeLabel.textColor = .systemGreen
        badgeLabel.adjustsFontForContentSizeCategory = true
        sortedBadge.axis = .horizontal
        sortedBadge.spacing = 3
        sortedBadge.alignment = .center
        sortedBadge.addArrangedSubview(badgeIcon)
        sortedBadge.addArrangedSubview(badgeLabel)
        sortedBadge.isHidden = true
        sortedBadge.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(sortedBadge)

        // Media region (does not clip — the bulk grid extends up under the nav bar)
        mediaRegion.clipsToBounds = false
        mediaRegion.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mediaRegion)

        morph.collectionView.translatesAutoresizingMaskIntoConstraints = false
        mediaRegion.addSubview(morph.collectionView)
        carousel.collectionView.translatesAutoresizingMaskIntoConstraints = false
        mediaRegion.addSubview(carousel.collectionView)
        flightOverlay.isUserInteractionEnabled = false
        flightOverlay.clipsToBounds = false
        flightOverlay.translatesAutoresizingMaskIntoConstraints = false
        mediaRegion.addSubview(flightOverlay)
        morph.flightOverlay = flightOverlay

        buildCompletionView()

        // Photo-grid zoom bar — floats in the strip band, shown only in bulk mode.
        photoGridZoomBar.translatesAutoresizingMaskIntoConstraints = false
        photoGridZoomBar.cornerConfiguration = .capsule()
        photoGridZoomBar.isHidden = true
        photoGridZoomBar.alpha = 0
        mediaRegion.addSubview(photoGridZoomBar)

        // Resize grabber
        resizeGrabber.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resizeGrabber)
        let grabBar = UIView()
        grabBar.backgroundColor = .tertiaryLabel
        grabBar.layer.cornerRadius = 2.5
        grabBar.translatesAutoresizingMaskIntoConstraints = false
        resizeGrabber.addSubview(grabBar)

        // Control bar — a floating Liquid Glass toolbar at the bottom, split into
        // logical button groups (each its own glass capsule) inside one container.
        controlBar.axis = .horizontal
        controlBar.distribution = .equalSpacing
        controlBar.alignment = .center
        controlBar.translatesAutoresizingMaskIntoConstraints = false
        controlBarContainer.translatesAutoresizingMaskIntoConstraints = false
        controlBarContainer.contentView.addSubview(controlBar)

        // Album grid (fills behind the floating toolbar)
        album.collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(album.collectionView)
        // Added after the grid so the glass toolbar floats above it.
        view.addSubview(controlBarContainer)

        // Top-level album flight overlay
        albumFlightOverlay.isUserInteractionEnabled = false
        albumFlightOverlay.clipsToBounds = false
        albumFlightOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(albumFlightOverlay)

        // Message (loading / all-sorted) overlay
        messageView.axis = .vertical
        messageView.alignment = .center
        messageView.spacing = 8
        messageView.isHidden = true
        messageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageView)

        // Vertical divider handle (two-pane only) — drag horizontally to rebalance
        // the photo column against the album column. Added above the content so it
        // takes touches; the flight overlays above it are non-interactive.
        columnGrabber.translatesAutoresizingMaskIntoConstraints = false
        columnGrabber.isHidden = true
        view.addSubview(columnGrabber)
        let columnBar = UIView()
        columnBar.backgroundColor = .tertiaryLabel
        columnBar.layer.cornerRadius = 2.5
        columnBar.translatesAutoresizingMaskIntoConstraints = false
        columnGrabber.addSubview(columnBar)

        let safe = view.safeAreaLayoutGuide
        view.addLayoutGuide(leftColumnGuide)
        mediaHeightConstraint = mediaRegion.heightAnchor.constraint(equalToConstant: photoHeight)
        morphTopConstraint = morph.collectionView.topAnchor.constraint(equalTo: mediaRegion.topAnchor)
        carouselBottomConstraint = carousel.collectionView.bottomAnchor.constraint(equalTo: mediaRegion.bottomAnchor, constant: -MorphController.stripBandHeight)
        grabberHeightConstraint = resizeGrabber.heightAnchor.constraint(equalToConstant: 20)
        // Constant-based so the divider grabber can drive it; refined each layout
        // from `regularLeftFraction` by `applyColumnWidth()`.
        leftColumnWidthConstraint = leftColumnGuide.widthAnchor.constraint(equalToConstant: 320)

        // Constraints shared by both layouts. The per-layout pieces (the trailing
        // edges of the photo column and the album grid's top/leading) live in
        // `compactConstraints` / `regularConstraints` and are swapped on a size-class
        // change by `applyAdaptiveLayout()`.
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: safe.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 22),

            progressLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            progressLabel.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            sortedBadge.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            sortedBadge.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            mediaRegion.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 4),
            mediaRegion.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mediaHeightConstraint,

            morphTopConstraint,
            morph.collectionView.leadingAnchor.constraint(equalTo: mediaRegion.leadingAnchor),
            morph.collectionView.trailingAnchor.constraint(equalTo: mediaRegion.trailingAnchor),
            morph.collectionView.bottomAnchor.constraint(equalTo: mediaRegion.bottomAnchor),

            carousel.collectionView.topAnchor.constraint(equalTo: mediaRegion.topAnchor),
            carousel.collectionView.leadingAnchor.constraint(equalTo: mediaRegion.leadingAnchor),
            carousel.collectionView.trailingAnchor.constraint(equalTo: mediaRegion.trailingAnchor),
            carouselBottomConstraint,

            flightOverlay.topAnchor.constraint(equalTo: mediaRegion.topAnchor),
            flightOverlay.leadingAnchor.constraint(equalTo: mediaRegion.leadingAnchor),
            flightOverlay.trailingAnchor.constraint(equalTo: mediaRegion.trailingAnchor),
            flightOverlay.bottomAnchor.constraint(equalTo: mediaRegion.bottomAnchor),

            photoGridZoomBar.leadingAnchor.constraint(equalTo: mediaRegion.leadingAnchor, constant: 16),
            photoGridZoomBar.bottomAnchor.constraint(equalTo: mediaRegion.bottomAnchor, constant: -6),

            resizeGrabber.topAnchor.constraint(equalTo: mediaRegion.bottomAnchor),
            resizeGrabber.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grabberHeightConstraint,
            grabBar.centerXAnchor.constraint(equalTo: resizeGrabber.centerXAnchor),
            grabBar.centerYAnchor.constraint(equalTo: resizeGrabber.centerYAnchor),
            grabBar.widthAnchor.constraint(equalToConstant: 36),
            grabBar.heightAnchor.constraint(equalToConstant: 5),

            // Album grid bottom + trailing are shared; its top + leading vary by layout.
            album.collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            album.collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Floating Liquid Glass toolbar pinned to the bottom safe area, full width
            // in both layouts (it spans under the album column too; the grid insets
            // its content to clear it).
            controlBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            controlBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            controlBarContainer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),

            controlBar.topAnchor.constraint(equalTo: controlBarContainer.contentView.topAnchor),
            controlBar.bottomAnchor.constraint(equalTo: controlBarContainer.contentView.bottomAnchor),
            controlBar.leadingAnchor.constraint(equalTo: controlBarContainer.contentView.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: controlBarContainer.contentView.trailingAnchor),

            albumFlightOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            albumFlightOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            albumFlightOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            albumFlightOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            messageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            messageView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            // The left-column divider: its trailing edge splits the two panes.
            leftColumnGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leftColumnWidthConstraint,

            // Divider handle straddles the column boundary, spanning the panes'
            // height (from the safe-area top down to the floating toolbar).
            columnGrabber.centerXAnchor.constraint(equalTo: leftColumnGuide.trailingAnchor),
            columnGrabber.topAnchor.constraint(equalTo: safe.topAnchor),
            columnGrabber.bottomAnchor.constraint(equalTo: controlBarContainer.topAnchor),
            columnGrabber.widthAnchor.constraint(equalToConstant: 24),
            columnBar.centerXAnchor.constraint(equalTo: columnGrabber.centerXAnchor),
            columnBar.centerYAnchor.constraint(equalTo: columnGrabber.centerYAnchor),
            columnBar.widthAnchor.constraint(equalToConstant: 5),
            columnBar.heightAnchor.constraint(equalToConstant: 40),
        ])

        // Compact (single column): photo column is full width; the album grid sits
        // below the grabber and runs to the bottom.
        compactConstraints = [
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mediaRegion.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resizeGrabber.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            album.collectionView.topAnchor.constraint(equalTo: resizeGrabber.bottomAnchor, constant: 6),
            album.collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        ]

        // Regular (two pane): photo column is the left pane; the album grid is the
        // right pane, spanning the full height from the safe-area top.
        regularConstraints = [
            headerContainer.trailingAnchor.constraint(equalTo: leftColumnGuide.trailingAnchor),
            mediaRegion.trailingAnchor.constraint(equalTo: leftColumnGuide.trailingAnchor),
            resizeGrabber.trailingAnchor.constraint(equalTo: leftColumnGuide.trailingAnchor),
            album.collectionView.topAnchor.constraint(equalTo: safe.topAnchor),
            album.collectionView.leadingAnchor.constraint(equalTo: leftColumnGuide.trailingAnchor),
        ]

        applyAdaptiveLayout()
    }

    // MARK: - Adaptive layout (single column vs two pane)

    /// Activate the constraint set for the current horizontal size class and
    /// configure the grabber (only meaningful in the single-column layout, where it
    /// trades photo height for album-grid height; in two pane the photo fills the
    /// column so the grabber is collapsed away).
    private func applyAdaptiveLayout() {
        let regular = traitCollection.horizontalSizeClass == .regular
        isRegularLayout = regular
        if regular {
            NSLayoutConstraint.deactivate(compactConstraints)
            NSLayoutConstraint.activate(regularConstraints)
        } else {
            NSLayoutConstraint.deactivate(regularConstraints)
            NSLayoutConstraint.activate(compactConstraints)
        }
        grabberHeightConstraint.constant = regular ? 0 : 20
        resizeGrabber.isHidden = regular
        columnGrabber.isHidden = !regular
        // The carousel is full width in single column, so its own clip is redundant
        // (off-screen peeks are window-clipped) and would catch the hero card's rounded
        // top corners during the resize spring — let it not clip there. Two pane keeps
        // clipping so peeks don't bleed past the column divider into the album grid.
        carousel.collectionView.clipsToBounds = regular
        // A size-class flip can land mid hero-flight (entering/exiting bulk); make
        // sure the carousel is never left with its foreground suppressed (blank).
        heroForegroundSuppressed = false
        carousel.suppressForeground = false
        applyColumnWidth()
        clampMediaHeight()
    }

    private func wireRegions() {
        carousel.hostViewController = self
        // Decode hero stills for the tallest the region can get, so a small-preview swipe
        // doesn't cache low-res frames that blur when the hero is later dragged bigger.
        carousel.maxPageHeight = maxPhotoHeight - MorphController.stripBandHeight
        carousel.onShowAsset = { [weak self] id in self?.vm.showAsset(id: id) }
        // Mid-drag the carousel only nudges the strip's selection — no VM commit —
        // so the album grid / current photo stay put and the drag isn't interrupted.
        carousel.onLivePageChange = { [weak self] id in self?.morph.updateCurrent(id) }
        carousel.onActiveImage = { [weak self] id, image in
            self?.heroImageID = id
            self?.heroImage = image
        }
        carousel.onDidScroll = { [weak self] in self?.trackHeroZoomDismissalScroll() }
        morph.onTap = { [weak self] id in
            guard let self else { return }
            if self.vm.isBulkMode { self.vm.toggleBulkSelection(id) } else { self.vm.showAsset(id: id) }
        }
        morph.onDragSelectionChanged = { [weak self] ids in self?.vm.setBulkSelection(ids) }
        album.onTap = { [weak self] group, albumID in self?.handleAlbumTap(group: group, albumID: albumID) }
        album.onViewContents = { [weak self] id, title in self?.onViewAlbum(id, title) }

        morph.applySnapshot(vm.queue, animated: false)
        carousel.applySnapshot(vm.queue, animated: false)
        morph.setCurrentSilently(vm.currentAssetID)
        carousel.setCurrent(vm.currentAssetID, animated: false)
    }

    // MARK: - Control bar

    private func configureControlBar() {
        func button(_ btn: UIButton, _ symbol: String, _ label: String, _ action: @escaping () -> Void) {
            btn.setImage(UIImage(systemName: symbol), for: .normal)
            btn.accessibilityLabel = label
            btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        button(undoButton, "arrow.uturn.backward", "Undo") { [weak self] in self?.handleUndo() }
        button(deleteButton, "trash", "Move to Trash") { [weak self] in
            guard let self else { return }
            self.commitVisiblePhotoIfBrowsing()
            Task { @MainActor in
                guard !self.vm.isBulkMode else { await self.vm.bulkQueueDelete(); return }
                if self.flyHeroToButton(self.deleteButton, heroID: self.vm.currentAssetID) {
                    self.vm.noteHeroFlightDeparture(self.vm.currentAssetID)
                }
                await self.vm.queueDelete()
            }
        }
        deleteButton.tintColor = .systemRed
        button(skipButton, "arrow.right.to.line", "Skip") { [weak self] in
            guard let self else { return }
            self.commitVisiblePhotoIfBrowsing()
            Task { @MainActor in
                guard !self.vm.isBulkMode else { await self.vm.bulkSkip(); return }
                if self.flyHeroToButton(self.skipButton, heroID: self.vm.currentAssetID) {
                    self.vm.noteHeroFlightDeparture(self.vm.currentAssetID)
                }
                await self.vm.skip()
            }
        }
        button(favoriteButton, "heart", "Favorite") { [weak self] in
            guard let self else { return }
            self.commitVisiblePhotoIfBrowsing()
            Task { self.vm.isBulkMode ? await self.vm.bulkToggleFavorite() : await self.vm.toggleFavorite() }
        }
        favoriteButton.tintColor = .secondaryLabel
        button(zoomOutButton, "minus.magnifyingglass", "Zoom out, more albums per row") { [weak self] in self?.changeColumns(by: +1) }
        button(zoomInButton, "plus.magnifyingglass", "Zoom in, fewer albums per row") { [weak self] in self?.changeColumns(by: -1) }
        button(multiSelectButton, "rectangle.stack", "Multi-select albums") { [weak self] in
            guard let self else { return }
            Task {
                self.vm.isMultiSelectActive ? await self.vm.deactivateMultiSelect() : await self.vm.activateMultiSelect()
            }
        }

        // Wrap a logical set of buttons in their own Liquid Glass capsule.
        func group(_ buttons: UIButton...) {
            let row = UIStackView(arrangedSubviews: buttons)
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 2
            row.translatesAutoresizingMaskIntoConstraints = false
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let pill = UIVisualEffectView(effect: glass)
            pill.cornerConfiguration = .capsule()
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 8),
                row.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -8),
                row.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 6),
                row.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -6),
            ])
            controlBar.addArrangedSubview(pill)
        }

        // Undo · photo actions · grid view & selection.
        group(undoButton)
        group(deleteButton, skipButton, favoriteButton)
        group(zoomOutButton, zoomInButton, multiSelectButton)
    }

    private func changeColumns(by delta: Int) {
        let new = max(2, min(5, columnCount + delta))
        guard new != columnCount else { return }
        columnCount = new
        UserDefaults.standard.set(new, forKey: columnKey)
        album.setColumns(new, animated: true)
        zoomOutButton.isEnabled = columnCount < 5
        zoomInButton.isEnabled = columnCount > 2
    }

    // MARK: - Photo-grid zoom bar

    private func configurePhotoZoomBar() {
        func button(_ btn: UIButton, _ symbol: String, _ action: @escaping () -> Void) {
            btn.setImage(UIImage(systemName: symbol), for: .normal)
            btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        button(photoZoomOutButton, "minus.magnifyingglass") { [weak self] in self?.changePhotoColumns(by: +1) }
        button(photoZoomInButton, "plus.magnifyingglass") { [weak self] in self?.changePhotoColumns(by: -1) }

        let row = UIStackView(arrangedSubviews: [photoZoomOutButton, photoZoomInButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        photoGridZoomBar.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: photoGridZoomBar.contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: photoGridZoomBar.contentView.bottomAnchor, constant: -6),
            row.leadingAnchor.constraint(equalTo: photoGridZoomBar.contentView.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: photoGridZoomBar.contentView.trailingAnchor, constant: -6),
        ])
        photoZoomOutButton.isEnabled = photoColumnCount < maxPhotoColumns
        photoZoomInButton.isEnabled = photoColumnCount > minPhotoColumns
    }

    private func changePhotoColumns(by delta: Int) {
        let new = max(minPhotoColumns, min(maxPhotoColumns, photoColumnCount + delta))
        guard new != photoColumnCount else { return }
        photoColumnCount = new
        UserDefaults.standard.set(new, forKey: photoColumnKey)
        morph.setGridColumns(new, animated: true)
        photoZoomOutButton.isEnabled = photoColumnCount < maxPhotoColumns
        photoZoomInButton.isEnabled = photoColumnCount > minPhotoColumns
    }

    // MARK: - Resize grabber

    private func configureGrabber() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGrabberPan(_:)))
        resizeGrabber.addGestureRecognizer(pan)
    }

    @objc private func handleGrabberPan(_ gesture: UIPanGestureRecognizer) {
        let notchEnabled = !vm.isBulkMode
        let translation = gesture.translation(in: view).y
        switch gesture.state {
        case .began:
            dragStartHeight = photoHeight
            wasInNotch = notchEnabled && abs(photoHeight - defaultPhotoHeight) < 1
        case .changed:
            guard let start = dragStartHeight else { return }
            let raw = start + translation
            let clamped = min(maxMediaHeight(), max(minPhotoHeight, raw))
            let inNotch = notchEnabled && abs(clamped - defaultPhotoHeight) <= notchRadius
            let target = inNotch ? defaultPhotoHeight + (clamped - defaultPhotoHeight) * notchDamping : clamped
            if !inNotch, wasInNotch {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } else if inNotch, !wasInNotch {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            wasInNotch = inNotch
            setPhotoHeight(target, springy: true)
        case .ended, .cancelled, .failed:
            guard let start = dragStartHeight else { return }
            let raw = start + translation
            let clamped = min(maxMediaHeight(), max(minPhotoHeight, raw))
            if notchEnabled, abs(clamped - defaultPhotoHeight) <= notchRadius {
                setPhotoHeight(defaultPhotoHeight, springy: true, release: true)
            }
            dragStartHeight = nil
            wasInNotch = false
            UserDefaults.standard.set(Double(photoHeight), forKey: photoHeightKey)
        default:
            break
        }
    }

    private func setPhotoHeight(_ height: CGFloat, springy: Bool, release: Bool = false) {
        photoHeight = height
        mediaHeightConstraint.constant = height
        if UIAccessibility.isReduceMotionEnabled || !springy {
            UIView.animate(withDuration: release ? 0.2 : 0) { self.view.layoutIfNeeded() }
        } else {
            UIView.animate(withDuration: release ? 0.32 : 0.18,
                           delay: 0,
                           usingSpringWithDamping: release ? 0.7 : 0.6,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: - Column divider grabber (two pane)

    private func configureColumnGrabber() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleColumnGrabberPan(_:)))
        columnGrabber.addGestureRecognizer(pan)
    }

    @objc private func handleColumnGrabberPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view).x
        switch gesture.state {
        case .began:
            dragStartLeftWidth = leftColumnWidthConstraint.constant
        case .changed:
            guard let start = dragStartLeftWidth, view.bounds.width > 0 else { return }
            let target = clampedLeftWidth(start + translation)
            // Track the fraction live so the next layout pass derives the same width
            // (and a later window resize keeps the user's chosen balance).
            regularLeftFraction = target / view.bounds.width
            leftColumnWidthConstraint.constant = target
            view.layoutIfNeeded()
        case .ended, .cancelled, .failed:
            dragStartLeftWidth = nil
            UserDefaults.standard.set(Double(regularLeftFraction), forKey: splitFractionKey)
        default:
            break
        }
    }

    /// Clamp the photo column's width so neither pane drops below `minColumnWidth`.
    private func clampedLeftWidth(_ width: CGFloat) -> CGFloat {
        let total = view.bounds.width
        guard total > 0 else { return width }
        let minLeft = minColumnWidth
        let maxLeft = total - minColumnWidth
        guard maxLeft > minLeft else { return total * 0.5 }
        return min(maxLeft, max(minLeft, width))
    }

    /// Pin the column divider to the (clamped) stored fraction of the current width.
    /// No-op outside the two-pane layout.
    private func applyColumnWidth() {
        guard isRegularLayout, view.bounds.width > 0 else { return }
        let target = clampedLeftWidth(regularLeftFraction * view.bounds.width)
        if abs(leftColumnWidthConstraint.constant - target) > 0.5 {
            leftColumnWidthConstraint.constant = target
        }
    }

    // MARK: - Hero pinch-to-zoom

    /// Pinch the centered hero photo to peek at it larger. The sharp image is lifted
    /// out of the carousel's clipping card into the top-level flight overlay, so the
    /// zoom can spill over the preview grid, album grid, and toolbar; it springs back
    /// to its place on release. Lives on the carousel's collection view (browse only).
    private func configureHeroPinch() {
        let pinch = HeroZoomGestureRecognizer(target: self, action: #selector(handleHeroPinch(_:)))
        pinch.delegate = self
        carousel.collectionView.addGestureRecognizer(pinch)
    }

    @objc private func handleHeroPinch(_ gesture: HeroZoomGestureRecognizer) {
        switch gesture.state {
        case .began:   beginHeroZoom(gesture)
        case .changed: updateHeroZoom(gesture)
        case .ended, .cancelled, .failed: endHeroZoom()
        default:       break
        }
    }

    private func beginHeroZoom(_ gesture: HeroZoomGestureRecognizer) {
        // Browse mode only, with the current page's full image decoded and on screen.
        guard !vm.isBulkMode, view.window != nil, heroZoomView == nil,
              let id = vm.currentAssetID, heroImageID == id, let image = heroImage,
              let pageRect = carouselPageRect(in: albumFlightOverlay) else { return }
        let startRect = Self.aspectFitRect(for: image.size, in: pageRect)
        guard albumFlightOverlay.bounds.intersects(startRect) else { return }

        // Stop the carousel scrolling so the pinch fully owns the gesture, and hide
        // the page's sharp foreground (the lifted copy draws it) while keeping its
        // blurred backdrop as a placeholder.
        carousel.collectionView.isScrollEnabled = false
        carousel.suppressForeground = true

        let scrim = UIView(frame: albumFlightOverlay.bounds)
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = .black
        scrim.alpha = 0
        scrim.isUserInteractionEnabled = false
        albumFlightOverlay.addSubview(scrim)
        heroZoomScrim = scrim

        // The copy rides in a container matching the overlay (identity transform during
        // the pinch, so the focal math below is unchanged). The snap-back springs the
        // copy home *within* the container while the container translates with carousel
        // scroll, landing the copy on its page's live position.
        let container = UIView(frame: albumFlightOverlay.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isUserInteractionEnabled = false
        albumFlightOverlay.addSubview(container)
        heroZoomContainer = container

        let zoom = UIImageView(image: image)
        zoom.contentMode = .scaleAspectFit
        zoom.frame = startRect
        container.addSubview(zoom)
        heroZoomView = zoom

        heroZoomStartCenter = CGPoint(x: startRect.midX, y: startRect.midY)
    }

    private func updateHeroZoom(_ gesture: HeroZoomGestureRecognizer) {
        guard let zoom = heroZoomView, !heroZoomDismissing else { return }
        // Incremental zoom about the live focal point (the touch centroid), clamped so
        // the peek only grows from the original size and never collapses. Applying the
        // recognizer's per-event deltas (rather than absolutes) keeps the photo
        // continuous as fingers land or lift.
        let current = zoom.transform.a
        let proposed = min(6, max(1, current * gesture.scale))
        let step = current > 0 ? proposed / current : 1
        if step != 1 {
            let focus = gesture.centroid(in: albumFlightOverlay)
            let center = zoom.center
            zoom.center = CGPoint(x: focus.x + (center.x - focus.x) * step,
                                  y: focus.y + (center.y - focus.y) * step)
            zoom.transform = zoom.transform.scaledBy(x: step, y: step)
        }
        // Incremental pan — also moves the photo with the single remaining finger once
        // the other lifts, instead of snapping back while a finger is still down.
        let pan = gesture.translation
        zoom.center = CGPoint(x: zoom.center.x + pan.x, y: zoom.center.y + pan.y)
        heroZoomScrim?.alpha = min(0.6, max(0, zoom.transform.a - 1) * 0.5)
    }

    private func endHeroZoom() {
        // A snap-back is already in flight — ignore a stray end from a gesture that
        // began over it.
        guard !heroZoomDismissing else { return }
        carousel.collectionView.isScrollEnabled = true
        guard let zoom = heroZoomView else {
            // Nothing was lifted (begin guard failed) — make sure the page is restored.
            carousel.suppressForeground = false
            teardownHeroZoom()
            return
        }
        heroZoomDismissing = true
        // Reference offset for scroll tracking: any carousel scroll from here translates
        // the container so the copy rides its page (see trackHeroZoomDismissalScroll).
        heroZoomDismissStartOffsetX = carousel.collectionView.contentOffset.x
        let scrim = heroZoomScrim
        let restore = {
            zoom.transform = .identity
            zoom.center = self.heroZoomStartCenter
            scrim?.alpha = 0
        }
        // Reveal the page's real foreground under the now-aligned copy, then drop it.
        let finish = { [weak self] in
            guard let self, self.heroZoomDismissing else { return }
            self.carousel.suppressForeground = false
            self.teardownHeroZoom()
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.2, animations: restore) { _ in finish() }
        } else {
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82,
                           initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState],
                           animations: restore) { _ in finish() }
        }
    }

    private func teardownHeroZoom() {
        heroZoomView?.removeFromSuperview()
        heroZoomView = nil
        heroZoomContainer?.removeFromSuperview()
        heroZoomContainer = nil
        heroZoomScrim?.removeFromSuperview()
        heroZoomScrim = nil
        heroZoomDismissing = false
    }

    /// While the snap-back is in flight, translate the container by however far the
    /// carousel has scrolled since it began, so the copy rides its page and lands on the
    /// page's live position — the spring still shrinks it home, but the home target
    /// moves with the scroll, so there's no settle-to-center then jump and no fade.
    private func trackHeroZoomDismissalScroll() {
        guard heroZoomDismissing, let container = heroZoomContainer else { return }
        let dx = carousel.collectionView.contentOffset.x - heroZoomDismissStartOffsetX
        container.transform = CGAffineTransform(translationX: -dx, y: 0)
    }

    // MARK: - Media height clamping

    /// The Y of the floating toolbar's top — the lower bound the photo region (and,
    /// in single column, the album grid below it) must stay above. Falls back to an
    /// estimate before the toolbar has been laid out.
    private func toolbarTopY() -> CGFloat {
        controlBarContainer.frame.height > 0
            ? controlBarContainer.frame.minY
            : view.bounds.maxY - view.safeAreaInsets.bottom - 8 - 52
    }

    /// The largest media-region height the current window can give the photo without
    /// starving what shares its column. In two pane the album grid is in the other
    /// column, so the photo fills the left column; in single column it must leave a
    /// usable minimum for the album grid stacked beneath it.
    private func maxMediaHeight() -> CGFloat {
        let mediaTop = view.safeAreaInsets.top + 22 + 4   // header height + gap
        let bottomLimit = toolbarTopY() - 6
        if isRegularLayout {
            return max(minPhotoHeight, bottomLimit - mediaTop)
        }
        let grabberAndGap: CGFloat = 20 + 6
        let maxH = bottomLimit - mediaTop - grabberAndGap - minAlbumVisible
        return max(minPhotoHeight, min(maxPhotoHeight, maxH))
    }

    /// Pin the media region to the clamped height: it fills the column in two pane,
    /// and tracks the user's grabber preference (capped to fit) in single column.
    private func clampMediaHeight() {
        guard view.bounds.height > 0 else { return }   // wait for real geometry
        let maxH = maxMediaHeight()
        let target = isRegularLayout ? maxH : min(photoHeight, maxH)
        if abs(mediaHeightConstraint.constant - target) > 0.5 {
            mediaHeightConstraint.constant = target
        }
    }

    // MARK: - Observation

    private func observeVM() {
        withObservationTracking { [weak self] in
            self?.reconcile()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeVM() }
        }
    }

    private func reconcile() {
        // Read every observed property so tracking re-arms on all of them.
        let queue = vm.queue
        let currentID = vm.currentAssetID
        let isBulk = vm.isBulkMode
        let selected = vm.bulkSelectedIDs
        let multiSelect = vm.isMultiSelectActive
        let albumInfos = vm.albumInfos
        let pinned = vm.pinnedAlbumInfos
        let extras = vm.extraAlbumInfos
        let memberships = vm.memberships
        let recent = vm.recentAddsByAlbum
        let favorite = vm.isFavorite
        let canUndo = vm.canUndo
        let satisfied = vm.isSatisfied
        let progress = vm.progressText
        let departed = vm.heroDepartedID
        let isLoading = vm.isLoading
        let hasCurrent = vm.currentAsset != nil
        let showExtraAlert = vm.showExtraOnlyAlert
        let writeErrorToken = vm.writeErrorToken
        let writeErrorMessage = vm.writeErrorMessage

        guard isViewLoaded else { return }

        // Surface a swallowed PhotoKit write failure as a transient banner. Token
        // increments per failure, so repeats with the same text still show.
        if writeErrorToken != lastWriteErrorToken {
            lastWriteErrorToken = writeErrorToken
            if let writeErrorMessage { presentWriteErrorBanner(writeErrorMessage) }
        }

        // Top-level state.
        updateState(isLoading: isLoading, queueEmpty: queue.isEmpty, hasCurrent: hasCurrent, isBulk: isBulk)

        // An undo-restore re-inserts an item into the queue and makes it current.
        // When it lands right before the page we're on, slide one page over to it
        // (it slides in, the previous page slides back over) rather than jumping —
        // the blurred backdrop fades in across that slide. When undoing from far
        // away, jump straight to it (no long whip-scroll).
        let added = (queue != lastQueue) ? Set(queue).subtracting(lastQueue) : []
        let isRestore = currentID.map { added.contains($0) } ?? false

        if isRestore, let restoredID = currentID {
            lastQueue = queue
            lastCurrentID = restoredID
            carousel.applyRestore(queue, restoredID: restoredID, animated: !isBulk)
            morph.applySnapshot(queue, animated: true)
            morph.updateCurrent(restoredID, animated: true)
        } else {
            // Queue → both collections.
            if queue != lastQueue {
                lastQueue = queue
                carousel.applySnapshot(queue, animated: didInitialContent)
                morph.applySnapshot(queue, animated: didInitialContent)
            }
            // Current asset → carousel page + strip current cell.
            if currentID != lastCurrentID {
                lastCurrentID = currentID
                carousel.setCurrent(currentID, animated: !isBulk)
                morph.updateCurrent(currentID)
            }
        }

        // Bulk-mode transitions are run synchronously in toggleBulk(); here we only
        // detect an external flip (shouldn't happen) and keep the cache in sync.
        if isBulk != lastBulkMode {
            lastBulkMode = isBulk
        }

        // Bulk selection → strip cells.
        if selected != lastSelected {
            lastSelected = selected
            morph.updateSelection(selected)
        }

        // Departed page (hero → album flight) → carousel blanking.
        if departed != lastDeparted {
            lastDeparted = departed
            carousel.departedID = departed
        }

        // Album grid.
        let memberIDs = Set(memberships.filter(\.isMember).map(\.id))
        album.update(
            context: albumInfos,
            pinned: pinned,
            extras: extras,
            memberIDs: memberIDs,
            recentAdds: recent,
            bulkDirect: isBulk && !multiSelect,
            animated: didInitialContent
        )

        // Control bar. Skip / delete / favorite act on the current photo (or the
        // bulk selection), so disable them when there's nothing to act on — e.g. the
        // all-sorted done state, where the picker + Undo stay live.
        let actionsDisabled = (isBulk && selected.isEmpty) || (!isBulk && !hasCurrent)
        if canUndo != lastCanUndo { lastCanUndo = canUndo; undoButton.isEnabled = canUndo }
        if actionsDisabled != lastActionsDisabled {
            lastActionsDisabled = actionsDisabled
            deleteButton.isEnabled = !actionsDisabled
            skipButton.isEnabled = !actionsDisabled
            favoriteButton.isEnabled = !actionsDisabled
        }
        if favorite != lastFavorite {
            lastFavorite = favorite
            favoriteButton.setImage(UIImage(systemName: favorite ? "heart.fill" : "heart"), for: .normal)
            favoriteButton.tintColor = favorite ? .systemYellow : .secondaryLabel
            favoriteButton.accessibilityValue = favorite ? "Favorited" : "Not favorited"
        }
        if multiSelect != lastMultiSelect {
            lastMultiSelect = multiSelect
            multiSelectButton.setImage(UIImage(systemName: multiSelect ? "rectangle.stack.fill" : "rectangle.stack"), for: .normal)
            multiSelectButton.tintColor = multiSelect ? (UIColor(named: "AccentColor") ?? .systemBlue) : .label
            multiSelectButton.accessibilityValue = multiSelect ? "On" : "Off"
        }
        zoomOutButton.isEnabled = columnCount < 5
        zoomInButton.isEnabled = columnCount > 2

        // Header.
        if progress != lastProgress { lastProgress = progress; progressLabel.text = progress }
        if satisfied != lastSatisfied { lastSatisfied = satisfied; sortedBadge.isHidden = !satisfied }
        headerContainer.alpha = isBulk ? 0 : 1

        // Nav bar — only rebuild when the title/bulk state changes (the title
        // varies with bulk + selection count, which also covers the toggle icon),
        // so a favorite/selection repaint doesn't churn the bar or dismiss a menu.
        if navTitleText != lastNavTitle {
            lastNavTitle = navTitleText
            updateNavBar()
        }

        // Extra-only alert.
        if showExtraAlert != lastExtraAlert {
            lastExtraAlert = showExtraAlert
            if showExtraAlert { presentExtraOnlyAlert() }
        }

        didInitialContent = true
    }

    private func updateState(isLoading: Bool, queueEmpty: Bool, hasCurrent: Bool, isBulk: Bool) {
        if isLoading {
            showLoading(title: "Scanning library…")
            setCompletion(false)
        } else if queueEmpty && !isBulk {
            // Keep the album picker + control bar on screen; celebrate the finish in
            // the media region where the carousel was.
            setContentHidden(false)
            messageView.isHidden = true
            setCompletion(true)
        } else if hasCurrent || isBulk {
            setContentHidden(false)
            messageView.isHidden = true
            setCompletion(false)
        } else {
            showLoading(title: nil)
            setCompletion(false)
        }
    }

    private func setContentHidden(_ hidden: Bool) {
        headerContainer.isHidden = hidden
        mediaRegion.isHidden = hidden
        controlBarContainer.isHidden = hidden
        album.collectionView.isHidden = hidden
        // Each grabber belongs to one layout: the horizontal height grabber in single
        // column, the vertical divider grabber in two pane.
        resizeGrabber.isHidden = hidden || isRegularLayout
        columnGrabber.isHidden = hidden || !isRegularLayout
    }

    /// Full-screen loading takeover (spinner + optional title). The all-sorted
    /// state is handled separately by `completionView`, in-region.
    private func showLoading(title: String?) {
        setContentHidden(true)
        messageView.isHidden = false
        messageView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = UIActivityIndicatorView(style: .large)
        s.startAnimating()
        messageView.addArrangedSubview(s)
        if let title {
            let l = UILabel()
            l.text = title
            l.font = .preferredFont(forTextStyle: .title3).withWeight(.semibold)
            l.adjustsFontForContentSizeCategory = true
            l.textAlignment = .center
            l.numberOfLines = 0
            messageView.addArrangedSubview(l)
        }
    }

    // MARK: - Completion ("All Sorted") state

    /// Builds the celebratory done view that lives inside the media region, so the
    /// album picker + control bar stay on screen while it's shown.
    private func buildCompletionView() {
        completionView.isHidden = true
        completionView.translatesAutoresizingMaskIntoConstraints = false
        mediaRegion.addSubview(completionView)

        completionCheckmark.image = UIImage(systemName: "checkmark.seal.fill")
        completionCheckmark.tintColor = .systemGreen
        completionCheckmark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 52, weight: .semibold)
        completionCheckmark.contentMode = .center
        completionCheckmark.isAccessibilityElement = false

        let title = UILabel()
        title.text = "All Sorted!"
        title.font = .preferredFont(forTextStyle: .title2).withWeight(.semibold)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "You've sorted every photo in this context."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.numberOfLines = 0
        subtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [completionCheckmark, title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Group the checkmark + text so VoiceOver reads it as one element.
        stack.isAccessibilityElement = false
        completionView.addSubview(stack)

        NSLayoutConstraint.activate([
            completionView.topAnchor.constraint(equalTo: mediaRegion.topAnchor),
            completionView.leadingAnchor.constraint(equalTo: mediaRegion.leadingAnchor),
            completionView.trailingAnchor.constraint(equalTo: mediaRegion.trailingAnchor),
            completionView.bottomAnchor.constraint(equalTo: mediaRegion.bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: completionView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: completionView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: completionView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: completionView.trailingAnchor, constant: -24),
        ])
    }

    /// Show / hide the in-region done state. When shown it springs + bounces in
    /// (instant under Reduce Motion); the album picker and control bar stay put.
    private func setCompletion(_ show: Bool) {
        guard show != lastCompletionShown else { return }
        lastCompletionShown = show

        if show {
            mediaRegion.bringSubviewToFront(completionView)
            completionView.isHidden = false
            completionView.accessibilityElementsHidden = false

            if UIAccessibility.isReduceMotionEnabled {
                completionView.alpha = 1
                completionView.transform = .identity
            } else {
                completionView.alpha = 0
                completionView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                UIView.animate(withDuration: 0.5, delay: 0,
                               usingSpringWithDamping: 0.66, initialSpringVelocity: 0.3,
                               options: [.allowUserInteraction]) {
                    self.completionView.alpha = 1
                    self.completionView.transform = .identity
                }
                completionCheckmark.addSymbolEffect(.bounce, options: .nonRepeating)
            }
        } else {
            completionView.accessibilityElementsHidden = true
            if UIAccessibility.isReduceMotionEnabled {
                completionView.isHidden = true
                completionView.alpha = 1
                completionView.transform = .identity
            } else {
                UIView.animate(withDuration: 0.2) {
                    self.completionView.alpha = 0
                } completion: { _ in
                    self.completionView.isHidden = true
                    self.completionView.transform = .identity
                }
            }
        }
    }

    // MARK: - Album tap routing

    /// Before a single-photo action (sort / skip / delete / favorite), settle the
    /// carousel on its most-visible page and commit it to the VM — so the action
    /// targets what the user actually sees even if a scroll is still decelerating.
    private func commitVisiblePhotoIfBrowsing() {
        if !vm.isBulkMode { carousel.commitVisiblePage() }
    }

    private func handleAlbumTap(group: AlbumGroup, albumID: String) {
        commitVisiblePhotoIfBrowsing()
        Task { @MainActor in
            if vm.isBulkMode {
                await vm.bulkAlbumTap(albumID)
                return
            }
            switch group {
            case .context:
                let memberIDs = Set(vm.memberships.filter(\.isMember).map(\.id))
                if !vm.isMultiSelectActive, !memberIDs.contains(albumID),
                   flyHeroToAlbum(albumID: albumID, heroID: vm.currentAssetID) {
                    vm.noteHeroFlightDeparture(vm.currentAssetID)
                }
                await vm.toggleAlbum(albumID)
            case .pinned:
                if !vm.isMultiSelectActive { await vm.activateMultiSelect() }
                await vm.toggleAlbum(albumID)
            case .extra:
                await vm.toggleAlbum(albumID)
            }
        }
    }

    // MARK: - Bulk mode toggle

    func toggleBulk() {
        if vm.isBulkMode { beginExitBulk() } else { enterBulk() }
    }

    private func enterBulk() {
        preloadedHeroID = nil
        preloadedHeroImage = nil
        heroForegroundSuppressed = true
        carousel.suppressForeground = true
        morph.heroImage = effectiveHeroImage
        morph.setSelectedSilently([])

        vm.enterBulkMode()
        lastBulkMode = true
        lastSelected = []

        carousel.isForeground = false
        carousel.collectionView.isUserInteractionEnabled = false
        photoGridZoomBar.isHidden = false
        UIView.animate(withDuration: 0.3) {
            self.carousel.collectionView.alpha = 0
            self.photoGridZoomBar.alpha = 1
        }

        view.layoutIfNeeded()
        morph.enterBulk(
            topConstraint: morphTopConstraint,
            topSafeInset: view.safeAreaInsets.top,
            regionTopInset: mediaRegion.frame.minY,
            mediaRegionBounds: mediaRegion.bounds
        ) { [weak self] _ in
            self?.heroForegroundSuppressed = false
            self?.carousel.suppressForeground = false
        }
    }

    /// Exit multi-select, opening the carousel at the first selected photo (in
    /// queue order) — or, if nothing is selected, at the grid's scroll position.
    /// Pre-decode that photo's display image so the hero zoom uses the full-aspect
    /// image (fit→fill) rather than the square thumbnail.
    private func beginExitBulk() {
        let firstSelected = vm.queue.first { vm.bulkSelectedIDs.contains($0) }
        guard let id = firstSelected ?? morph.topVisibleAssetID() else {
            performExitBulk()
            return
        }
        // Point the (hidden) carousel at the anchor up front, without animation.
        vm.showAsset(id: id)
        carousel.setCurrent(id, animated: false)
        Task { @MainActor in
            if let image = await preloadDisplayImage(for: id) {
                preloadedHeroID = id
                preloadedHeroImage = image
            }
            performExitBulk()
        }
    }

    private func performExitBulk() {
        heroForegroundSuppressed = true
        carousel.suppressForeground = true
        morph.heroImage = effectiveHeroImage

        vm.exitBulkMode()
        lastBulkMode = false

        carousel.isForeground = true
        carousel.collectionView.isUserInteractionEnabled = true
        UIView.animate(withDuration: 0.3) {
            self.carousel.collectionView.alpha = 1
            self.photoGridZoomBar.alpha = 0
        } completion: { _ in self.photoGridZoomBar.isHidden = true }

        view.layoutIfNeeded()
        morph.exitBulk(
            topConstraint: morphTopConstraint,
            topSafeInset: view.safeAreaInsets.top,
            regionTopInset: mediaRegion.frame.minY,
            mediaRegionBounds: mediaRegion.bounds
        ) { [weak self] _ in
            self?.heroForegroundSuppressed = false
            self?.carousel.suppressForeground = false
        }
    }

    private var effectiveHeroImage: UIImage? {
        if preloadedHeroID == vm.currentAssetID, let image = preloadedHeroImage { return image }
        return heroImageID == vm.currentAssetID ? heroImage : nil
    }

    /// Decode the asset's display image at hero size, capped so a slow (iCloud)
    /// fetch can't stall the exit — returns nil on timeout and the flight falls
    /// back to the cached thumbnail.
    private func preloadDisplayImage(for id: String) async -> UIImage? {
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let side = 600 * scale
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

    // MARK: - Hero → album-slot flight

    @discardableResult
    private func flyHeroToAlbum(albumID: String, heroID: String?) -> Bool {
        // Reduce Motion: skip the decorative hero → album flight; the sort itself
        // still happens via the VM. Returning false tells the caller not to mark a
        // hero departure (which would blank the page awaiting a flight that never runs).
        guard !UIAccessibility.isReduceMotionEnabled else { return false }
        guard let heroID, view.window != nil,
              let pageRect = carouselPageRect(in: albumFlightOverlay),
              let slot = album.firstSlotFrame(forAlbum: albumID, in: albumFlightOverlay)
        else { return false }

        let displayImage = heroImageID == heroID ? heroImage : nil
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let thumbSide = 80 * scale
        let image = displayImage ?? ImageLoader.shared.cachedThumbnail(
            localID: heroID, targetSize: CGSize(width: thumbSide, height: thumbSide))
        guard let image else { return false }

        guard albumFlightOverlay.bounds.intersects(slot) else { return false }
        let from = displayImage != nil ? Self.aspectFitRect(for: image.size, in: pageRect) : pageRect

        // Keep this image so an undo can fly it straight back without re-decoding.
        sortedHeroImages.removeAll { $0.id == heroID }
        sortedHeroImages.append((heroID, image, displayImage != nil))
        if sortedHeroImages.count > 8 { sortedHeroImages.removeFirst() }

        albumFlightGeneration += 1
        let generation = albumFlightGeneration
        album.setFlight(albumID: albumID, photoID: heroID)

        let fv = UIImageView(image: image)
        fv.contentMode = .scaleAspectFill
        fv.clipsToBounds = true
        fv.frame = from
        albumFlightOverlay.addSubview(fv)

        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = 0
        corner.toValue = 6
        corner.duration = 0.25
        corner.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fv.layer.add(corner, forKey: "cornerRadius")
        fv.layer.cornerRadius = 6

        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            fv.frame = slot
        } completion: { [weak self] _ in
            if let self, self.albumFlightGeneration == generation {
                self.album.setFlight(albumID: nil, photoID: nil)
            }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                fv.alpha = 0
            } completion: { _ in fv.removeFromSuperview() }
        }
        return true
    }

    // MARK: - Hero → control-button flight

    /// Fly the hero photo into a control-bar button (trash / skip), mirroring the
    /// hero → album flight: the carousel page blanks (the flight draws the photo)
    /// while a copy shrinks and dissolves into the button. Unlike an album slot
    /// there's nowhere for it to land, so it fades out as it reaches the button
    /// and the button pulses to acknowledge it. Returns true if it launched, so
    /// the caller marks the hero departure.
    @discardableResult
    private func flyHeroToButton(_ button: UIButton, heroID: String?) -> Bool {
        // Reduce Motion: skip the decorative flight; the sort still happens via the
        // VM. Returning false tells the caller not to mark a hero departure (which
        // would blank the page awaiting a flight that never runs).
        guard !UIAccessibility.isReduceMotionEnabled else { return false }
        guard let heroID, view.window != nil,
              let pageRect = carouselPageRect(in: albumFlightOverlay)
        else { return false }

        let displayImage = heroImageID == heroID ? heroImage : nil
        let scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let thumbSide = 80 * scale
        let image = displayImage ?? ImageLoader.shared.cachedThumbnail(
            localID: heroID, targetSize: CGSize(width: thumbSide, height: thumbSide))
        guard let image else { return false }

        let target = button.convert(button.bounds, to: albumFlightOverlay)
        guard albumFlightOverlay.bounds.intersects(target) else { return false }
        let from = displayImage != nil ? Self.aspectFitRect(for: image.size, in: pageRect) : pageRect

        let fv = UIImageView(image: image)
        fv.contentMode = .scaleAspectFill
        fv.clipsToBounds = true
        fv.frame = from
        albumFlightOverlay.addSubview(fv)

        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = 0
        corner.toValue = 6
        corner.duration = 0.28
        corner.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fv.layer.add(corner, forKey: "cornerRadius")
        fv.layer.cornerRadius = 6

        // Ease-in so the photo lingers large then accelerates as it shrinks into
        // the button, fading out just as it arrives.
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn]) {
            fv.frame = target
            fv.alpha = 0
        } completion: { _ in fv.removeFromSuperview() }

        // Pulse the button so the photo visibly drops into it, timed to land as the
        // flight arrives.
        UIView.animateKeyframes(withDuration: 0.26, delay: 0.16, options: [.calculationModeCubic]) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.5) {
                button.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.5, relativeDuration: 0.5) {
                button.transform = .identity
            }
        }
        return true
    }

    // MARK: - Undo (reverse hero flight)

    /// Undo, flying the photo from its album slot back into the carousel when the
    /// next undo is a single sort whose album is on screen — the reverse of the
    /// sort flight. Falls back to a plain undo otherwise.
    private func handleUndo() {
        var pending: (photoID: String, from: CGRect, image: UIImage?, fit: Bool)?
        if !UIAccessibility.isReduceMotionEnabled,
           case .sorted(let photoID, let albumID)? = vm.undoStack.last,
           let slot = album.firstSlotFrame(forAlbum: albumID, in: albumFlightOverlay),
           albumFlightOverlay.bounds.intersects(slot) {
            // Reuse the image we kept when this photo was sorted, so the flight can
            // start in lockstep with the carousel slide rather than after a decode.
            let stashed = sortedHeroImages.last { $0.id == photoID }
            pending = (photoID, slot, stashed?.image, stashed?.fit ?? false)
            // Hide the restored page's foreground up front (the flight draws it) so
            // it never flashes in before the flight — but keep its blurred backdrop,
            // which fades in during the flight. Per-photo so the pre-undo current
            // photo isn't affected while the async undo runs.
            carousel.suppressForegroundID = photoID
            carousel.restoreBackdropImage = (photoID, stashed?.image)
        }
        Task { @MainActor in
            await vm.undo()
            guard let pending else { return }
            // Fast path: we still have the hero image from the sort — fly it back
            // immediately so the flight overlaps the slide and the blur fades in.
            if let image = pending.image {
                sortedHeroImages.removeAll { $0.id == pending.photoID }
                flyAlbumToHero(photoID: pending.photoID, image: image, from: pending.from, fitLanding: pending.fit)
                return
            }
            // Fallback: decode the full-aspect display image so the flight lands
            // letterboxed like the hero; else the square album thumbnail (fill).
            let display = await preloadDisplayImage(for: pending.photoID)
            let image = display ?? ImageLoader.shared.cachedThumbnail(
                localID: pending.photoID, targetSize: CGSize(width: 200, height: 200))
            guard let image else { clearUndoFlight(); return }
            flyAlbumToHero(photoID: pending.photoID, image: image, from: pending.from, fitLanding: display != nil)
        }
    }

    /// Animate a copy of the restored photo from its album preview slot back into
    /// the carousel's hero page. Mirror of `flyHeroToAlbum`.
    private func flyAlbumToHero(photoID: String, image: UIImage, from: CGRect, fitLanding: Bool) {
        let pageRect = carousel.heroPageRect(in: albumFlightOverlay)
        // With the full image, land at the aspect-fit (letterboxed) rect so it
        // matches the hero's scaled-to-fit appearance; the square thumbnail
        // fallback fills the page instead.
        let to = fitLanding ? Self.aspectFitRect(for: image.size, in: pageRect) : pageRect
        guard view.window != nil, albumFlightOverlay.bounds.intersects(to) else {
            clearUndoFlight()   // can't fly — reveal the carousel page
            return
        }

        albumFlightGeneration += 1
        let generation = albumFlightGeneration
        carousel.suppressForegroundID = photoID

        let fv = UIImageView(image: image)
        fv.contentMode = .scaleAspectFill
        fv.clipsToBounds = true
        fv.frame = from
        fv.layer.cornerRadius = 6
        albumFlightOverlay.addSubview(fv)

        let corner = CABasicAnimation(keyPath: "cornerRadius")
        corner.fromValue = 6
        corner.toValue = 0
        corner.duration = 0.25
        corner.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fv.layer.add(corner, forKey: "cornerRadius")
        fv.layer.cornerRadius = 0

        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            fv.frame = to
        } completion: { [weak self] _ in
            // Reveal the carousel photo, then fade the flight out over it.
            if let self, self.albumFlightGeneration == generation { self.clearUndoFlight() }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                fv.alpha = 0
            } completion: { _ in fv.removeFromSuperview() }
        }
    }

    private func clearUndoFlight() {
        carousel.suppressForegroundID = nil
        carousel.restoreBackdropImage = nil
    }

    private func carouselPageRect(in target: UIView) -> CGRect? {
        guard let id = vm.currentAssetID, let idx = carousel.assetIDs.firstIndex(of: id),
              let cell = carousel.collectionView.cellForItem(at: IndexPath(item: idx, section: 0))
        else { return nil }
        return cell.convert(cell.bounds, to: target)
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    // MARK: - Nav bar

    private var navTitleText: String {
        if vm.isBulkMode { return "\(vm.bulkSelectedIDs.count) selected" }
        return context.name.isEmpty ? "Sort" : context.name
    }

    private func updateNavBar() {
        navigationItem.title = navTitleText

        // Leading: context list, more (trash / skipped / debug).
        var leading: [UIBarButtonItem] = []
        let contextsItem = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), primaryAction: UIAction { [weak self] _ in self?.onShowContextList() })
        contextsItem.accessibilityLabel = "Contexts"
        leading.append(contextsItem)

        let trashAction = UIAction(title: trashCount > 0 ? "Trash (\(trashCount))" : "Trash",
                                   image: UIImage(systemName: "trash")) { [weak self] _ in self?.onShowTrash() }
        trashAction.attributes = trashCount == 0 ? [.disabled] : []
        let skippedAction = UIAction(title: skippedCount > 0 ? "Skipped (\(skippedCount))" : "Skipped",
                                     image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.onShowSkipped() }
        skippedAction.attributes = skippedCount == 0 ? [.disabled] : []

        var moreChildren: [UIMenuElement] = [trashAction, skippedAction]
        // Debug tools (DEBUG + simulator only — the closures are nil otherwise) live
        // inline at the bottom of the More menu rather than in a separate bar button.
        var debugActions: [UIAction] = []
        if let onDebugShowOnboarding {
            debugActions.append(UIAction(title: "Show Onboarding", image: UIImage(systemName: "sparkles")) { _ in onDebugShowOnboarding() })
        }
        if let onDebugClear {
            debugActions.append(UIAction(title: "Remove All Photos from Albums", image: UIImage(systemName: "xmark.bin"), attributes: .destructive) { _ in onDebugClear() })
        }
        if !debugActions.isEmpty {
            moreChildren.append(UIMenu(title: "Debug", image: UIImage(systemName: "ladybug"),
                                       options: .displayInline, children: debugActions))
        }
        let moreMenu = UIMenu(children: moreChildren)
        let moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu)
        moreItem.accessibilityLabel = "More"
        leading.append(moreItem)

        navigationItem.leftBarButtonItems = leading

        // Trailing: bulk toggle, edit context.
        let bulkItem = UIBarButtonItem(
            image: UIImage(systemName: vm.isBulkMode ? "square.grid.2x2.fill" : "square.grid.2x2"),
            primaryAction: UIAction { [weak self] _ in self?.toggleBulk() })
        bulkItem.tintColor = vm.isBulkMode ? (UIColor(named: "AccentColor") ?? .systemBlue) : .label
        bulkItem.accessibilityLabel = "Bulk select"
        bulkItem.accessibilityValue = vm.isBulkMode ? "On" : "Off"
        let editItem = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"),
                                       primaryAction: UIAction { [weak self] _ in self?.onEditContext() })
        editItem.accessibilityLabel = "Edit context"
        navigationItem.rightBarButtonItems = [editItem, bulkItem]
    }

    // MARK: - Alerts

    private func presentExtraOnlyAlert() {
        let alert = UIAlertController(
            title: "No Destination Album",
            message: "This item isn't in any of this context's destination albums. Skip it, or go back and select a destination.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Skip Item", style: .default) { [weak self] _ in
            Task { await self?.vm.skipFromExtraOnlyAlert() }
        })
        alert.addAction(UIAlertAction(title: "Select Destination", style: .cancel) { [weak self] _ in
            self?.vm.dismissExtraOnlyAlert()
        })
        present(alert, animated: true)
    }

    /// Transient top banner for a non-blocking write failure (e.g. an album add
    /// that didn't save). Auto-dismisses; non-modal so it doesn't interrupt sorting.
    private func presentWriteErrorBanner(_ message: String) {
        writeErrorBanner?.removeFromSuperview()

        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.layer.cornerRadius = 16
        blur.clipsToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        view.addSubview(blur)
        writeErrorBanner = blur

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -12),

            blur.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            blur.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            blur.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            blur.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        // Announce for VoiceOver users, who won't see the transient banner.
        UIAccessibility.post(notification: .announcement, argument: message)

        let animate = !UIAccessibility.isReduceMotionEnabled
        blur.alpha = 0
        blur.transform = CGAffineTransform(translationX: 0, y: -16)
        UIView.animate(withDuration: animate ? 0.3 : 0) {
            blur.alpha = 1
            blur.transform = .identity
        }

        Haptics.warning()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self, weak blur] in
            guard let blur, blur === self?.writeErrorBanner else { return }
            UIView.animate(withDuration: animate ? 0.25 : 0) {
                blur.alpha = 0
                blur.transform = CGAffineTransform(translationX: 0, y: -16)
            } completion: { _ in
                blur.removeFromSuperview()
                if self?.writeErrorBanner === blur { self?.writeErrorBanner = nil }
            }
        }
    }
}

// MARK: - Gesture coexistence

extension SortSessionViewController: UIGestureRecognizerDelegate {
    /// Let the hero pinch begin even while the carousel's scroll pan is active — the
    /// pinch handler stops the scroll the moment it takes over.
    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Hero zoom gesture

/// Pinch-and-pan recognizer for the hero zoom. Unlike `UIPinchGestureRecognizer` it
/// begins only on two fingers — so single-finger carousel scrolling is untouched —
/// but then keeps tracking all the way down to one finger, so a lifted photo keeps
/// panning with the single held finger and only ends (springs back) when the *last*
/// finger lifts. Each event reports the `scale` and centroid `translation` since the
/// previous one, re-baselined whenever a finger lands or lifts so the touch-count
/// change never produces a jump; `centroid(in:)` gives the live focal point.
final class HeroZoomGestureRecognizer: UIGestureRecognizer {
    /// Multiplicative scale change since the last reported event (1 with a single
    /// finger, where there are no two points to scale between).
    private(set) var scale: CGFloat = 1
    /// Centroid movement since the last reported event, in the recognizer's view.
    private(set) var translation: CGPoint = .zero

    private var tracked: [UITouch] = []
    private var lastCentroid: CGPoint = .zero
    private var lastDistance: CGFloat = 0

    /// Live centroid of the tracked touches in `target`'s coordinate space.
    func centroid(in target: UIView?) -> CGPoint {
        guard let target, !tracked.isEmpty else { return .zero }
        let points = tracked.map { $0.location(in: target) }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches where tracked.count < 2 { tracked.append(touch) }
        rebaseline()
        if tracked.count == 2, state == .possible { state = .began }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        let centroid = currentCentroid()
        let distance = currentDistance()
        translation = CGPoint(x: centroid.x - lastCentroid.x, y: centroid.y - lastCentroid.y)
        scale = (tracked.count == 2 && lastDistance > 0) ? distance / lastDistance : 1
        lastCentroid = centroid
        lastDistance = distance
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked.removeAll { touches.contains($0) }
        if tracked.isEmpty {
            state = (state == .possible) ? .failed : .ended
        } else {
            rebaseline()   // dropped two→one: re-anchor so the held finger doesn't jump
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked.removeAll { touches.contains($0) }
        if tracked.isEmpty {
            state = (state == .possible) ? .failed : .cancelled
        } else {
            rebaseline()
        }
    }

    override func reset() {
        tracked.removeAll()
        lastCentroid = .zero
        lastDistance = 0
        translation = .zero
        scale = 1
    }

    /// Snap the scale/translation baselines to the current touches without emitting a
    /// delta, so a finger landing or lifting never causes a jump on the next move.
    private func rebaseline() {
        lastCentroid = currentCentroid()
        lastDistance = currentDistance()
        translation = .zero
        scale = 1
    }

    private func currentCentroid() -> CGPoint { centroid(in: view) }

    private func currentDistance() -> CGFloat {
        guard tracked.count == 2, let view else { return 0 }
        let a = tracked[0].location(in: view)
        let b = tracked[1].location(in: view)
        return hypot(a.x - b.x, a.y - b.y)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
