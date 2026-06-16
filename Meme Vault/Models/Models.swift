//
//  Models.swift
//  Meme Vault
//
//  SwiftData models for app-only state. Albums and assets live in PhotoKit
//  and are referenced here only by their `localIdentifier`.
//

import Foundation
import SwiftData

// MARK: - SourceKind

enum SourceKind: String, Codable, CaseIterable, Sendable {
    case allPhotos
    case album
}

// MARK: - OrgContext

/// An organization context: a source pool of photos plus a list of destination
/// albums. A photo is "satisfied" for the context when it is a member of at
/// least one album in the context's album list.
@Model
final class OrgContext {
    var name: String = ""
    var createdAt: Date = Date()

    /// Stored as the raw value of `SourceKind` so SwiftData can persist it.
    var sourceKindRaw: String = SourceKind.allPhotos.rawValue

    /// Populated when `sourceKind == .album`. The `PHAssetCollection.localIdentifier`
    /// of the source album.
    var sourceAlbumLocalID: String?

    /// The destination albums for this context. A photo is satisfied when it
    /// belongs to at least one of these albums.
    var albumLocalIDs: [String] = []

    /// Marks the single built-in default context whose album list is
    /// auto-populated from all user albums.
    var isDefault: Bool = false

    var uuid: UUID = UUID()

    /// Non-destination albums that always appear in the sort grid (faded).
    /// Tapping one enters multi-select mode.
    var pinnedAlbumLocalIDs: [String] = []

    /// When true, destination albums are sorted by item count (most first)
    /// instead of the manual order stored in `albumLocalIDs`.
    var autoSortAlbumsByCount: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \PhotoSkip.context)
    var skips: [PhotoSkip] = []

    @Relationship(deleteRule: .cascade, inverse: \PendingDelete.context)
    var pendingDeletes: [PendingDelete] = []

    init(
        name: String,
        sourceKind: SourceKind = .allPhotos,
        sourceAlbumLocalID: String? = nil,
        isDefault: Bool = false
    ) {
        self.name = name
        self.createdAt = Date()
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceAlbumLocalID = sourceAlbumLocalID
        self.isDefault = isDefault
    }

    var sourceKind: SourceKind {
        get { SourceKind(rawValue: sourceKindRaw) ?? .allPhotos }
        set { sourceKindRaw = newValue.rawValue }
    }
}

// MARK: - PhotoSkip

/// User explicitly skipped this asset for this context. Skipped photos are
/// hidden from the sort queue until the user un-skips them.
@Model
final class PhotoSkip {
    var assetLocalID: String = ""
    var skippedAt: Date = Date()

    var context: OrgContext?

    init(assetLocalID: String) {
        self.assetLocalID = assetLocalID
        self.skippedAt = Date()
    }
}

// MARK: - PendingDelete

/// Asset queued for deletion. Confirmed in batch via the Trash screen.
@Model
final class PendingDelete {
    var assetLocalID: String = ""
    var queuedAt: Date = Date()

    var context: OrgContext?

    init(assetLocalID: String) {
        self.assetLocalID = assetLocalID
        self.queuedAt = Date()
    }
}

// MARK: - Versioned schema & migration plan

/// The 1.0 schema. Anchoring a `VersionedSchema` now (rather than an unversioned
/// model list) gives every future schema change a defined starting point: add a
/// `SchemaV2`, append it to `MemeVaultMigrationPlan.schemas`, and describe the
/// `MigrationStage` between them, instead of risking an unrecoverable open against
/// an inferred schema.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [OrgContext.self, PhotoSkip.self, PendingDelete.self]
    }
}

enum MemeVaultMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    /// No migrations yet — V1 is the baseline. Future versions add stages here.
    static var stages: [MigrationStage] {
        []
    }
}

/// Convenience for the current schema's model list (previews, in-memory containers).
enum AppSchema {
    static var models: [any PersistentModel.Type] { SchemaV1.models }
}
