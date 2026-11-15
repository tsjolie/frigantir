import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var isOnboarding = false

    @State private var urlText = ""
    @State private var fallbackText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var keepAudio = true
    @State private var audioOnlyInBackground = true
    @State private var isSaving = false
    /// Shown under the button when the address can't be used.
    @State private var urlError: String?
    @AppStorage("livePreviews") private var livePreviews = true

    var body: some View {
        Form {
            Section {
                TextField("frigate.example.com", text: $urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Fallback address (optional)", text: $fallbackText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username (if auth is enabled)", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                if !isOnboarding, model.isUsingFallbackAddress {
                    Label("Connected through the fallback address", systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Frigate server")
            } footer: {
                Text("""
                    Enter Frigate's address, e.g. frigate.example.com or 192.168.1.10:8971. HTTPS is used \
                    unless the address starts with http://. Use Frigate's port 8971 (or your reverse proxy). \
                    Live video uses go2rtc through Frigate at /live/mse.

                    The fallback address is used whenever the first one can't be reached, e.g. a local \
                    address first and a public one for when you're away from home. The app checks again \
                    when the network changes and when it opens.
                    """)
            }

            Section {
                Toggle("Keep audio when leaving a camera", isOn: $keepAudio)
                Toggle("Audio-only stream in background", isOn: $audioOnlyInBackground)
            } header: {
                Text("Playback")
            } footer: {
                Text("""
                    With the first option on, a camera keeps playing (lock screen and Control Center \
                    included) until you stop it — useful as a baby monitor. Audio-only mode stops \
                    downloading video 10 s after the app goes to the background, unless Picture in \
                    Picture is showing.
                    """)
            }

            if !isOnboarding {
                Section {
                    Toggle("Live video on activity", isOn: $livePreviews)
                } header: {
                    Text("Dashboard")
                } footer: {
                    Text("""
                        Like Frigate's web UI: camera tiles show a still that refreshes every 5 s, and switch \
                        to silent live video while the camera sees motion or a moving object. Each live tile \
                        streams the camera's selected stream, so a low-resolution sub-stream saves data.
                        """)
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    HStack {
                        Text(isOnboarding ? "Connect" : "Save")
                        if isSaving {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isSaving)
                if let urlError {
                    Text(urlError).foregroundStyle(.red).font(.footnote)
                } else if let error = model.loadError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }

            if !isOnboarding {
                Section {
                    NavigationLink("Notifications") { NotificationSettingsView() }
                    NavigationLink("System") { SystemView() }
                    if model.canEditConfig {
                        NavigationLink("Configuration") { ConfigEditorView() }
                    }
                }
            }
        }
        .navigationTitle(isOnboarding ? "Connect to Frigate" : "Settings")
        .onAppear(perform: loadFields)
        .onChange(of: urlText) { urlError = nil }
        .onChange(of: fallbackText) { urlError = nil }
    }

    private func loadFields() {
        let settings = model.settings
        urlText = settings.baseURL?.absoluteString ?? ""
        fallbackText = settings.fallbackURL?.absoluteString ?? ""
        username = settings.username
        keepAudio = settings.keepAudioWhenLeavingCamera
        audioOnlyInBackground = settings.audioOnlyAfterBackgroundSeconds != nil
    }

    private func save() {
        guard let url = URL.serverAddress(urlText) else {
            urlError = urlText.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Enter your Frigate server's address."
                : "That isn't a valid address. Try something like frigate.example.com or https://192.168.1.10:8971."
            return
        }
        var fallback: URL?
        if !fallbackText.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let url = URL.serverAddress(fallbackText) else {
                urlError = "The fallback address isn't valid. Try something like frigate.example.com."
                return
            }
            fallback = url
        }
        // Show what will be used, e.g. with https:// added.
        urlText = url.absoluteString
        fallbackText = fallback?.absoluteString ?? ""
        urlError = nil
        var settings = model.settings
        settings.baseURL = url
        settings.fallbackURL = fallback
        settings.username = username
        settings.keepAudioWhenLeavingCamera = keepAudio
        settings.audioOnlyAfterBackgroundSeconds = audioOnlyInBackground ? 10 : nil
        isSaving = true
        Task {
            await model.update(settings: settings, password: password.isEmpty ? nil : password,
                               requireConnection: isOnboarding)
            isSaving = false
        }
    }
}
