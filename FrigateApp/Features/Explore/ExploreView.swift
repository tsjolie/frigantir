import SwiftUI

/// The PWA's Explore page: tracked objects, filterable by camera and label.
/// (Semantic search and face/LPR browsing are later phases; see the project plan.)
struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var camera: String?
    @State private var label: String?
    @State private var objects: [TrackedObject] = []

    private static let commonLabels = ["person", "car", "dog", "cat", "package", "bird"]

    var body: some View {
        NavigationStack {
            List(objects) { object in
                NavigationLink(value: object) { TrackedObjectRow(object: object) }
            }
            .listStyle(.plain)
            .navigationTitle("Explore")
            .navigationDestination(for: TrackedObject.self) { TrackedObjectDetailView(object: $0) }
            .toolbar {
                Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
                    Picker("Camera", selection: $camera) {
                        Text("All cameras").tag(String?.none)
                        ForEach(model.config?.dashboardCameras ?? []) { camera in
                            Text(camera.name.cameraDisplayName).tag(Optional(camera.name))
                        }
                    }
                    Picker("Label", selection: $label) {
                        Text("All labels").tag(String?.none)
                        ForEach(Self.commonLabels, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                    }
                }
            }
            .task(id: "\(camera ?? "")|\(label ?? "")") { await reload() }
            .refreshable { await reload() }
            .nowPlayingBar()
        }
    }

    private func reload() async {
        objects = (try? await model.client?.trackedObjects(camera: camera, label: label)) ?? []
    }
}

struct TrackedObjectRow: View {
    @Environment(AppModel.self) private var model
    let object: TrackedObject

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.client?.thumbnailURL(object)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text((object.subLabel ?? object.label).capitalized).font(.headline)
                Text(object.camera.cameraDisplayName).font(.subheadline).foregroundStyle(.secondary)
                Text(object.startDate, format: .relative(presentation: .named)).font(.caption)
            }
            Spacer()
            if let score = object.data?.topScore ?? object.data?.score {
                Text(score, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TrackedObjectDetailView: View {
    @Environment(AppModel.self) private var model
    let object: TrackedObject

    var body: some View {
        List {
            if let client = model.client {
                if object.hasClip {
                    let end = object.endTime.map(Date.init(timeIntervalSince1970:)) ?? .now
                    RecordingPlayerView(url: client.recordingPlaylistURL(
                        camera: object.camera,
                        start: object.startDate.addingTimeInterval(-3),
                        end: end.addingTimeInterval(3)))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .listRowInsets(EdgeInsets())
                } else if object.hasSnapshot {
                    AsyncImage(url: client.snapshotURL(object)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                        .listRowInsets(EdgeInsets())
                }
            }
            LabeledContent("Label", value: object.label.capitalized)
            if let subLabel = object.subLabel { LabeledContent("Sub label", value: subLabel) }
            LabeledContent("Camera", value: object.camera.cameraDisplayName)
            LabeledContent("Seen", value: object.startDate.formatted(date: .abbreviated, time: .standard))
            if !object.zones.isEmpty { LabeledContent("Zones", value: object.zones.joined(separator: ", ")) }
        }
        .navigationTitle((object.subLabel ?? object.label).capitalized)
        .navigationBarTitleDisplayMode(.inline)
    }
}
