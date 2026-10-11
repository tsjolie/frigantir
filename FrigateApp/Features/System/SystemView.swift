import SwiftUI

/// The PWA's System page, trimmed: version, uptime, detector speed, camera FPS.
struct SystemView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: FrigateStats?

    var body: some View {
        List {
            if let stats {
                Section("Frigate") {
                    LabeledContent("Version", value: stats.service.version)
                    LabeledContent("Uptime", value: Duration.seconds(stats.service.uptime)
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                }
                Section("Detectors") {
                    ForEach(stats.detectors.keys.sorted(), id: \.self) { name in
                        LabeledContent(name, value: String(format: "%.1f ms", stats.detectors[name]!.inferenceSpeed))
                    }
                }
                Section("Cameras") {
                    ForEach(stats.cameras.keys.sorted(), id: \.self) { name in
                        let camera = stats.cameras[name]!
                        LabeledContent(name.cameraDisplayName,
                                       value: String(format: "%.0f fps · detect %.1f", camera.cameraFps, camera.detectionFps))
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("System")
        .task {
            // Poll while the page is visible, like the PWA.
            while !Task.isCancelled {
                stats = try? await model.client?.stats()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
