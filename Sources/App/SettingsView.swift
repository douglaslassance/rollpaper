import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var entitlements = EntitlementManager.shared

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            FeedsSettingsView()
                .tabItem { Label("Feeds", systemImage: "list.bullet") }

            if entitlements.hasProAccess {
                FilteredSettingsView()
                    .tabItem { Label("Filtered", systemImage: "line.3.horizontal.decrease.circle") }
            }
        }
        .frame(width: 520, height: 360)
    }
}

struct FeedsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var entitlements = EntitlementManager.shared
    @State private var selection: FeedConfig.ID?
    @State private var showAddSheet = false

    private var atFreeLimit: Bool {
        !entitlements.hasProAccess && appState.feeds.count >= AppLimits.freeMaxFeeds
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(appState.feeds) { feed in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feed.name).font(.body)
                        Text(feed.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(feed.id)
                }
            }
            Divider()
            HStack {
                Button {
                    if atFreeLimit {
                        PurchaseWindowController.shared.show(entitlementManager: entitlements)
                    } else {
                        showAddSheet = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if let id = selection,
                       let idx = appState.feeds.firstIndex(where: { $0.id == id }) {
                        appState.feeds.remove(at: idx)
                        selection = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
            }
            .padding(8)
            .buttonStyle(.borderless)
        }
        .sheet(isPresented: $showAddSheet) {
            AddFeedView { newFeed in
                appState.feeds.append(newFeed)
            }
        }
    }
}

struct AddFeedView: View {
    let onAdd: (FeedConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var kind: FeedKind = .bluesky
    @State private var name: String = ""
    @State private var handle: String = ""
    @State private var instance: String = "https://mastodon.social"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add feed").font(.headline)

            Picker("Source", selection: $kind) {
                ForEach(FeedKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField("Name", text: $name)

            switch kind {
            case .bluesky:
                TextField("Handle or DID (e.g. user.bsky.social)", text: $handle)
            case .mastodon:
                TextField("Account (e.g. user@mastodon.social)", text: $handle)
                TextField("Instance URL", text: $instance)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedHandle = handle.trimmingCharacters(in: .whitespaces)
                    let display = trimmedName.isEmpty ? trimmedHandle : trimmedName
                    let feed = FeedConfig(
                        kind: kind,
                        name: display,
                        handle: trimmedHandle,
                        instance: kind == .mastodon ? instance.trimmingCharacters(in: .whitespaces) : nil
                    )
                    onAdd(feed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct FilteredSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: FilteredEntry.ID?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No filtered wallpapers")
                        .font(.headline)
                    Text("Use \"Don't show this again\" from the menu bar to filter a wallpaper out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(appState.filtered) { entry in
                        FilteredRow(entry: entry)
                            .tag(entry.id)
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    if let id = selection,
                       let entry = appState.filtered.first(where: { $0.id == id }) {
                        appState.unfilter(entry)
                        selection = nil
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)

                Spacer()

                Button("Clear All") {
                    showClearConfirm = true
                }
                .disabled(appState.filtered.isEmpty)
            }
            .padding(8)
            .buttonStyle(.borderless)
        }
        .confirmationDialog(
            "Remove all \(appState.filtered.count) filtered wallpapers?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                appState.clearFiltered()
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct FilteredRow: View {
    let entry: FilteredEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let source = entry.sourceURL {
                Link(source.absoluteString, destination: source)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(entry.imageURL.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Filtered \(entry.addedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var entitlements = EntitlementManager.shared

    private let intervalPresets: [(String, Double)] = [
        ("Every minute", 60),
        ("Every 15 minutes", 900),
        ("Every hour", 3600),
        ("Every 6 hours", 21600),
        ("Every day", 86400)
    ]

    var body: some View {
        Form {
            Section("Rotation") {
                Picker("Update frequency", selection: $appState.rotationIntervalSeconds) {
                    ForEach(intervalPresets, id: \.1) { preset in
                        Text(preset.0).tag(preset.1)
                    }
                }
                .onChange(of: appState.rotationIntervalSeconds) { _, _ in
                    appState.restartRotation()
                }
            }

            Section("Display") {
                Picker("Fit mode", selection: $appState.fitMode) {
                    ForEach(FitMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: appState.fitMode) { _, _ in
                    appState.applyFitModeToCurrent()
                }
            }

            Section("Upscaling") {
                Toggle("Upscale wallpapers to fit your display", isOn: Binding(
                    get: { entitlements.hasProAccess && appState.upscaleEnabled },
                    set: { newValue in
                        if entitlements.hasProAccess {
                            appState.upscaleEnabled = newValue
                        } else {
                            PurchaseWindowController.shared.show(entitlementManager: entitlements)
                        }
                    }
                ))
                Text(entitlements.hasProAccess
                     ? "Enlarges images smaller than your screen with on-device AI, applied on each rotation."
                     : "Enlarges images smaller than your screen with on-device AI. Requires Rollpaper Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = appState.lastError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
