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
    @EnvironmentObject private var library: PhotoLibrary

    @State private var vm: SortSessionViewModel?
    @State private var showUndoToast = false
    @State private var undoTimer: Task<Void, Never>?
    @State private var showExtraAlbumPicker = false
    @State private var columnCount = 3

    private var columnCountKey: String {
        "albumGridColumns_\(context.uuid.uuidString)"
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
        .navigationTitle(context.name.isEmpty ? "Sort" : context.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm == nil {
                vm = SortSessionViewModel(context: context, modelContext: modelContext)
                await vm?.start()
            }
        }
        .task(id: library.changeTick) {
            // External Photos changes — only act after first load.
            guard let vm, library.changeTick > 0 else { return }
            await vm.handleLibraryChange()
        }
        .onAppear {
            let stored = UserDefaults.standard.object(forKey: columnCountKey) as? Int
            columnCount = stored ?? 3
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
        } else if vm.currentAsset != nil {
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
        VStack(spacing: 12) {
            // Progress
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

            // Photo carousel
            PhotoCardView(
                assetIDs: vm.queue,
                currentID: Binding(
                    get: { vm.currentAssetID },
                    set: { id in if let id { vm.showAsset(id: id) } }
                )
            )
            .frame(height: 360)
            .padding(.horizontal)

            // Control bar
            controlBar(vm: vm)

            // Album list
            albumList(vm: vm)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showUndoToast, let action = vm.lastAction {
                undoToast(action: action, vm: vm)
                    .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showExtraAlbumPicker) {
            if let asset = vm.currentAsset {
                ExtraAlbumSheet(
                    asset: asset,
                    contextAlbumIDs: Set(context.albumLocalIDs),
                    vm: vm
                )
            }
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
        ScrollView {
            LazyVGrid(columns: albumColumns, spacing: 12) {
                ForEach(albumInfos, id: \.id) { info in
                    let isMember = vm.memberships.first { $0.id == info.id }?.isMember ?? false
                    Button {
                        Task { await vm.toggleAlbum(info.id) }
                    } label: {
                        AlbumGridCell(
                            albumID: info.id,
                            title: info.title,
                            count: info.estimatedAssetCount,
                            isMember: isMember
                        )
                    }
                    .buttonStyle(.plain)
                }
                ForEach(extraAlbumInfos(vm: vm), id: \.id) { info in
                    let isMember = vm.memberships.first { $0.id == info.id }?.isMember ?? false
                    Button {
                        Task { await vm.toggleAlbum(info.id) }
                    } label: {
                        AlbumGridCell(
                            albumID: info.id,
                            title: info.title,
                            count: info.estimatedAssetCount,
                            isMember: isMember
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .offset(y: 20)))
                }
                if vm.isMultiSelectActive && hasNonContextAlbums {
                    Button {
                        showExtraAlbumPicker = true
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.tertiarySystemFill))
                                Image(systemName: "plus.circle")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            Text("Other Albums")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(" ")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .offset(y: 20)))
                }
            }
            .padding(.horizontal)
            .animation(.easeInOut(duration: 0.25), value: vm.extraAlbumIDs)
            .animation(.easeInOut(duration: 0.25), value: vm.isMultiSelectActive)
        }
    }

    private var hasNonContextAlbums: Bool {
        let contextIDs = Set(context.albumLocalIDs)
        return AlbumService.listUserAlbums().contains { !contextIDs.contains($0.id) }
    }

    private func extraAlbumInfos(vm: SortSessionViewModel) -> [AlbumInfo] {
        guard !vm.extraAlbumIDs.isEmpty else { return [] }
        let collections = AlbumService.collections(for: Array(vm.extraAlbumIDs))
        return collections.map { AlbumInfo(collection: $0) }
    }

    private var albumInfos: [AlbumInfo] {
        let collections = AlbumService.collections(for: context.albumLocalIDs)
        let byID = Dictionary(uniqueKeysWithValues: collections.map {
            ($0.localIdentifier, AlbumInfo(collection: $0))
        })
        return context.albumLocalIDs.compactMap { byID[$0] }
    }

    // MARK: - Control bar

    private func controlBar(vm: SortSessionViewModel) -> some View {
        HStack(spacing: 16) {
            Button {
                Task { await vm.back() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(vm.index == 0)

            Button {
                Task { await vm.queueDelete(); showToast() }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await vm.skip(); showToast() }
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .frame(width: 44, height: 44)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    columnCount = min(5, columnCount + 1)
                }
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(columnCount >= 5)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    columnCount = max(2, columnCount - 1)
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .disabled(columnCount <= 2)

            Button {
                if vm.isMultiSelectActive {
                    Task { await vm.deactivateMultiSelect() }
                } else {
                    vm.isMultiSelectActive = true
                }
            } label: {
                Image(systemName: vm.isMultiSelectActive ? "rectangle.stack.fill" : "rectangle.stack")
                    .frame(width: 44, height: 44)
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
            case .skipped: return "Skipped"
            case .queuedDelete: return "Queued for deletion"
            }
        }()
        return HStack {
            Text(label)
            Spacer()
            Button("Undo") {
                Task {
                    switch action {
                    case .skipped: await vm.undoSkip()
                    case .queuedDelete: await vm.undoQueueDelete()
                    }
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

// MARK: - Extra album sheet

private struct ExtraAlbumSheet: View {
    let asset: PHAsset
    let contextAlbumIDs: Set<String>
    let vm: SortSessionViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [AlbumInfo] = []
    @State private var memberIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    Task { await toggle(album) }
                } label: {
                    HStack {
                        Image(systemName: memberIDs.contains(album.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(memberIDs.contains(album.id)
                                             ? Color.accentColor : Color.secondary)
                        Text(album.title)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Other Albums")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { load() }
        }
    }

    private func load() {
        albums = AlbumService.listUserAlbums().filter { !contextAlbumIDs.contains($0.id) }
        for album in albums {
            if let collection = AlbumService.collection(for: album.id),
               AlbumService.isAsset(asset, memberOf: collection) {
                memberIDs.insert(album.id)
            }
        }
    }

    private func toggle(_ album: AlbumInfo) async {
        guard let collection = AlbumService.collection(for: album.id) else { return }
        do {
            if memberIDs.contains(album.id) {
                try await AlbumService.remove(asset, from: collection)
                memberIDs.remove(album.id)
                vm.extraAlbumIDs.remove(album.id)
            } else {
                try await AlbumService.add(asset, to: collection)
                memberIDs.insert(album.id)
                vm.extraAlbumIDs.insert(album.id)
            }
            vm.recomputeMemberships()
            Haptics.tap()
        } catch {
            Haptics.warning()
        }
    }
}
