import SwiftUI

/// Saves a span of a camera's recordings as an export on the Frigate server,
/// like the web UI's Export button. Opened with times picked on the History
/// timeline, or with defaults to type over.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: CameraConfig

    @State private var start: Date
    @State private var end: Date
    @State private var name = ""
    @State private var isExporting = false
    @State private var error: String?
    @State private var didExport = false
    /// Which time's wheels are open; one at a time keeps the form short.
    @State private var editing: Field?

    enum Field { case start, end }

    init(camera: CameraConfig, range: ClosedRange<Date>) {
        self.camera = camera
        _start = State(initialValue: range.lowerBound)
        _end = State(initialValue: range.upperBound)
    }

    /// Why the times can't be exported, if they can't.
    private var problem: String? {
        if end <= start { return "The end must be after the start." }
        if start >= .now { return "The start is in the future." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PreciseDatePicker(title: "Start", date: $start, isExpanded: expanded(.start))
                    PreciseDatePicker(title: "End", date: $end, isExpanded: expanded(.end))
                    LabeledContent("Length", value: Duration.seconds(max(0, end.timeIntervalSince(start)))
                        .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                } header: {
                    Text(camera.name.cameraDisplayName)
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }

                Section {
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("""
                        Frigate saves the export as an MP4 on the server. It appears in the Exports tab \
                        on the Review page (and in Frigate's web UI) when it's ready.
                        """)
                }

                Section {
                    Button {
                        Task { await export() }
                    } label: {
                        HStack {
                            Text("Export")
                            if isExporting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(problem != nil || isExporting)
                    if let error {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Export started", isPresented: $didExport) {
                Button("OK") { dismiss() }
            } message: {
                Text("Find it in the Exports tab on the Review page once it's done, to watch, download or share it.")
            }
        }
    }

    private func expanded(_ field: Field) -> Binding<Bool> {
        Binding(get: { editing == field }, set: { editing = $0 ? field : nil })
    }

    private func export() async {
        guard let client = model.client else { return }
        isExporting = true
        error = nil
        do {
            try await client.exportRecording(camera: camera.name, start: start, end: min(end, .now),
                                             name: name.trimmingCharacters(in: .whitespaces))
            didExport = true
        } catch {
            self.error = error.localizedDescription
        }
        isExporting = false
    }
}
