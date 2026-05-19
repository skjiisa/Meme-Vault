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
    @State private var showingContextEditor = false
    @State private var columnCount = 3
    @State private var hasAppeared = false
    @State private var viewingAlbum: AlbumSheetItem?

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit Context", systemImage: "slider.horizontal.3") {
                    showingContextEditor = true
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
            await vm.handleLibraryChange(change: library.lastChange)
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
        VStack(spacing: 6) {
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
            .frame(height: 300)

            // Queue strip
            QueuePreviewStrip(assetIDs: vm.queue, currentID: vm.currentAssetID) { id in
                vm.showAsset(id: id)
            }

            // Control bar
            controlBar(vm: vm)

            // Album list
            albumList(vm: vm)
        }
        .padding(.vertical, 4)
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
        ScrollView {
            LazyVGrid(columns: albumColumns, spacing: 8) {
                ForEach(infos, id: \.id) { info in
                    let isMember = vm.memberships.first { $0.id == info.id }?.isMember ?? false
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
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("View Contents", systemImage: "photo.on.rectangle") {
                            viewingAlbum = AlbumSheetItem(id: info.id, title: info.title)
                        }
                    }
                }
                ForEach(extras, id: \.id) { info in
                    let isMember = vm.memberships.first { $0.id == info.id }?.isMember ?? false
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
            .animation(.easeInOut(duration: 0.25), value: vm.extraAlbumIDs)
            .animation(.easeInOut(duration: 0.25), value: vm.isMultiSelectActive)
        }
    }

    // MARK: - Control bar

    private func controlBar(vm: SortSessionViewModel) -> some View {
        HStack {
            Button {
                Task { await vm.undo(); showUndoToast = false }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 36)
            }
            .disabled(!vm.canUndo)

            Spacer()

            Button {
                Task { await vm.queueDelete(); showToast() }
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button {
                Task { await vm.skip(); showToast() }
            } label: {
                Image(systemName: "arrow.right.to.line")
                    .frame(width: 44, height: 36)
            }

            Spacer()

            Button {
                Task { await vm.toggleFavorite() }
            } label: {
                Image(systemName: vm.isFavorite ? "heart.fill" : "heart")
                    .frame(width: 44, height: 36)
                    .foregroundStyle(vm.isFavorite ? .yellow : .secondary)
            }

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

