//
//  PhotoLibrary.swift
//  Meme Vault
//
//  Auth + change-observer wrapper around PHPhotoLibrary.
//

import Foundation
import Photos
import Combine

/// Singleton-style observable wrapper around `PHPhotoLibrary`. Owns the
/// authorization state and a `PHPhotoLibraryChangeObserver` that publishes
/// changes via Combine so views can refresh.
@MainActor
final class PhotoLibrary: NSObject, ObservableObject {
    static let shared = PhotoLibrary()

    @Published private(set) var authorization: PHAuthorizationStatus

    /// Bumped every time PhotoKit reports an *external* change. Views observing
    /// this can re-evaluate their state. Self-initiated writes (those marked
    /// via `noteSelfWriteBegin()`) are consumed by the change observer instead
    /// of bumping this tick — the caller already knows what changed and can
    /// update incrementally without a full reload.
    @Published private(set) var changeTick: Int = 0

    /// Latest change passed to the observer, for callers that need fine-grained
    /// detail.
    @Published private(set) var lastChange: PHChange?

    private var didRegisterObserver = false

    /// Number of in-flight self-writes. The change observer consumes one of
    /// these per fired change, so the next external change is what actually
    /// bumps `changeTick`. Cleared after a short timeout to handle the rare
    /// case of a write that produces no observer callback (e.g. a no-op).
    private var pendingSelfWrites: Int = 0
    private var pendingSelfWriteResetTask: Task<Void, Never>?

    override init() {
        self.authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
    }

    /// Request `.readWrite` access. Safe to call repeatedly; if already granted,
    /// returns immediately.
    @discardableResult
    func requestAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited {
            self.authorization = current
            registerObserverIfNeeded()
            return current
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        self.authorization = status
        if status == .authorized || status == .limited {
            registerObserverIfNeeded()
        }
        return status
    }

    var isAuthorized: Bool {
        authorization == .authorized || authorization == .limited
    }

    private func registerObserverIfNeeded() {
        guard !didRegisterObserver else { return }
        PHPhotoLibrary.shared().register(self)
        didRegisterObserver = true
    }

    /// Mark that a self-initiated write is about to begin. The next change
    /// observer fire is treated as ours and won't bump `changeTick`. Safety
    /// timeout clears stale markers if `performChanges` somehow produces no
    /// observer callback (e.g. PhotoKit deduplicates a no-op).
    func noteSelfWriteBegin() {
        pendingSelfWrites += 1
        pendingSelfWriteResetTask?.cancel()
        pendingSelfWriteResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingSelfWrites = 0
        }
    }
}

extension PhotoLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.lastChange = changeInstance
            if self.pendingSelfWrites > 0 {
                self.pendingSelfWrites -= 1
                if self.pendingSelfWrites == 0 {
                    self.pendingSelfWriteResetTask?.cancel()
                    self.pendingSelfWriteResetTask = nil
                }
                return
            }
            self.changeTick &+= 1
        }
    }
}
