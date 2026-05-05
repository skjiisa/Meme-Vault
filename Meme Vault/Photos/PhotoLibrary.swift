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

    /// Bumped every time PhotoKit reports a change. Views observing this can
    /// re-evaluate their state. The actual `PHChange` is published separately.
    @Published private(set) var changeTick: Int = 0

    /// Latest change passed to the observer, for callers that need fine-grained
    /// detail.
    @Published private(set) var lastChange: PHChange?

    private var didRegisterObserver = false

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
}

extension PhotoLibrary: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.lastChange = changeInstance
            self.changeTick &+= 1
        }
    }
}
