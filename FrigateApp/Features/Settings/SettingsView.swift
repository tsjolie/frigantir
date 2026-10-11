import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var isOnboarding = false

    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var keepAudio = true
    @State private var audioOnlyInBackground = true
    @State private var isSaving = false
    @AppStorage("livePreviews") private var livePreviews = true

    var body: some View {
        Form {
            Section {
                TextField("https://frigate.example.com", text: $urlText)
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
            } header: {
                Text("Frigate server")
            } footer: {
                Text("Use Frigate's port 8971 (or your reverse proxy). Live video uses go2rtc through Frigate at /live/mse.")
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
                Button(isOnboarding ? "Connect" : "Save") { save() }
                    .disabled(URL(string: urlText)?.host == nil || isSaving)
                if let error = model.loadError {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }

            if !isOnboarding {
                Section {
                    NavigationLink("Notifications") { NotificationSettingsView() }
                    NavigationLink("System") { SystemView() }
                }
            }
        }
        .navigationTitle(isOnboarding ? "Connect to Frigate" : "Settings")
        .onAppear(perform: loadFields)
    }

    private func loadFields() {
        let settings = model.settings
        urlText = settings.baseURL?.absoluteString ?? ""
        username = settings.username
        keepAudio = settings.keepAudioWhenLeavingCamera
        audioOnlyInBackground = settings.audioOnlyAfterBackgroundSeconds != nil
    }

    private func save() {
        var settings = model.settings
        settings.baseURL = URL(string: urlText.trimmingCharacters(in: .whitespaces))
        settings.username = username
        settings.keepAudioWhenLeavingCamera = keepAudio
        settings.audioOnlyAfterBackgroundSeconds = audioOnlyInBackground ? 10 : nil
        isSaving = true
        Task {
            await model.update(settings: settings, password: password.isEmpty ? nil : password)
            isSaving = false
        }
    }
}
