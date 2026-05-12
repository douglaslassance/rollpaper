import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }

            FeedsSettingsView()
                .tabItem { Label("Feeds", systemImage: "list.bullet") }
        }
        .frame(width: 520, height: 360)
    }
}

struct FeedsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: FeedConfig.ID?
    @State private var showAddSheet = false

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
                    showAddSheet = true
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

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState

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

                Toggle("Fade transition", isOn: $appState.fadeEnabled)

                if appState.fadeEnabled {
                    HStack {
                        Text("Fade duration")
                        Slider(value: $appState.fadeDurationSeconds, in: 0.2...2.0)
                        Text("\(appState.fadeDurationSeconds, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            if let error = appState.lastError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
