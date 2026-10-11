import SwiftUI

/// Settings → Notifications: connect to the self-hosted notification server
/// (see notifier/README.md) and choose what to be notified about.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var isEnabled = false
    @State private var serverText = ""
    @State private var apiToken = ""
    @State private var includeDetections = false
    @State private var allCameras = true
    @State private var selectedCameras: Set<String> = []
    @State private var isSaving = false
    @State private var testResult: String?

    private var push: PushNotifications { model.push }

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: $isEnabled)
            } footer: {
                Text("""
                    Notifications come from a small server you run next to Frigate, which watches for \\
                    new alerts and sends them through Apple. See notifier/README.md to set it up.
                    """)
            }

            Section("Notification server") {
                TextField("https://notify.example.com", text: $serverText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API token", text: $apiToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Notify me about") {
                Picker("Severity", selection: $includeDetections) {
                    Text("Alerts").tag(false)
                    Text("Alerts and detections").tag(true)
                }
                Toggle("All cameras", isOn: $allCameras)
                if !allCameras {
                    ForEach(model.config?.dashboardCameras ?? []) { camera in
                        Toggle(camera.name.cameraDisplayName, isOn: Binding(
                            get: { selectedCameras.contains(camera.name) },
                            set: { if $0 { selectedCameras.insert(camera.name) } else { selectedCameras.remove(camera.name) } }))
                    }
                }
            }

            Section {
                Button("Save") { save() }
                    .disabled(isSaving || (isEnabled && (serverURL == nil || apiToken.isEmpty)))
                if push.settings.isEnabled {
                    Button("Send test notification") {
                        Task { testResult = await push.sendTest() }
                    }
                    .disabled(push.status != .registered)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if push.settings.isEnabled { Text(push.status.label) }
                    if let testResult { Text(testResult) }
                }
            }
        }
        .navigationTitle("Notifications")
        .onAppear(perform: loadFields)
    }

    private var serverURL: URL? {
        let url = URL(string: serverText.trimmingCharacters(in: .whitespaces))
        return url?.host == nil ? nil : url
    }

    private func loadFields() {
        let settings = push.settings
        isEnabled = settings.isEnabled
        serverText = settings.serverURL?.absoluteString ?? ""
        apiToken = push.apiToken
        includeDetections = settings.includeDetections
        allCameras = settings.cameras.isEmpty
        selectedCameras = Set(settings.cameras)
    }

    private func save() {
        var settings = push.settings
        settings.isEnabled = isEnabled
        settings.serverURL = serverURL
        settings.includeDetections = includeDetections
        settings.cameras = allCameras ? [] : selectedCameras.sorted()
        isSaving = true
        testResult = nil
        Task {
            await push.update(settings, apiToken: apiToken.trimmingCharacters(in: .whitespaces))
            isSaving = false
        }
    }
}
