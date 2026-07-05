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
    @State private var showModelLicense = false

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
                Text(upscalingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = appState.lastError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "rollpaper" {
                showModelLicense = true
                return .handled
            }
            return .systemAction
        })
        .sheet(isPresented: $showModelLicense) {
            ModelLicenseView()
        }
    }

    /// The upscaling caption, with the model name linked to its license. The
    /// `rollpaper://` scheme is intercepted above to open the license sheet
    /// rather than a browser.
    private var upscalingDescription: AttributedString {
        let markdown = entitlements.hasProAccess
            ? "Enlarges images smaller than your screen using [Real-ESRGAN](rollpaper://license) on-device, applied on each rotation."
            : "Enlarges images smaller than your screen using [Real-ESRGAN](rollpaper://license) on-device."
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }
}

/// Attribution for the bundled upscaling model. Reproducing the copyright,
/// conditions, and disclaimer here satisfies the BSD-3-Clause requirement to
/// include them with the distribution; the exact screen is not prescribed.
private struct ModelLicenseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upscaling model")
                .font(.headline)

            Text("AI upscaling uses the Real-ESRGAN “realesr-general-x4v3” model, converted to Core ML.")
                .font(.callout)
                .foregroundColor(.secondary)

            ScrollView {
                Text(Self.license)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }

    static let license = """
    Real-ESRGAN
    https://github.com/xinntao/Real-ESRGAN

    BSD 3-Clause License

    Copyright (c) 2021, Xintao Wang
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this
       list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its
       contributors may be used to endorse or promote products derived from
       this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}
