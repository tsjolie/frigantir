import SwiftUI

/// Frigate's config file, editable like the Config Editor in Frigate's web UI:
/// YAML mistakes are marked as you type, and Frigate checks its own rules when
/// you save, keeping the old config if the new one is invalid.
struct ConfigEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// What the server has; the editor has unsaved changes when `text` differs.
    @State private var saved: String?
    @State private var loadError: String?
    @State private var problem: YAMLProblem?
    /// Frigate's reasons for rejecting the last save.
    @State private var saveError: String?
    @State private var saveErrorLine: Int?
    @State private var isSaving = false
    @State private var savedMessage: String?
    @State private var confirmRestart = false
    @State private var confirmDiscard = false
    @State private var goToLine: Int?

    private var hasChanges: Bool { saved != nil && text != saved }

    var body: some View {
        Group {
            if saved != nil {
                YAMLTextEditor(text: $text, errorLine: problem?.line ?? saveErrorLine, goToLine: $goToLine)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .safeAreaInset(edge: .bottom) { messages }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load the Config", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Configuration")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar { toolbar }
        .task { await load() }
        // Checked after a short pause in typing, not on every keystroke.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let text = text
            problem = await Task.detached { YAMLProblem.first(in: text) }.value
        }
        .onChange(of: text) {
            saveError = nil
            saveErrorLine = nil
        }
        .alert("Restart Frigate?", isPresented: $confirmRestart) {
            Button("Cancel", role: .cancel) {}
            Button("Save & Restart") { save(restart: true) }
        } message: {
            Text("Cameras stop recording and detecting until Frigate is back, which can take up to a minute.")
        }
        .alert("Discard your changes?", isPresented: $confirmDiscard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
        .alert("Config Saved", isPresented: Binding(get: { savedMessage != nil },
                                                    set: { if !$0 { savedMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(savedMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if hasChanges {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { confirmDiscard = true }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSaving {
                ProgressView()
            } else {
                Menu("Save") {
                    Button("Save Only", systemImage: "square.and.arrow.down") { save(restart: false) }
                    Button("Save & Restart", systemImage: "arrow.clockwise") { confirmRestart = true }
                }
                .disabled(saved == nil || problem != nil)
            }
        }
    }

    /// The YAML mistake, or why Frigate refused the last save. Tapping a
    /// message with a line number jumps there.
    @ViewBuilder private var messages: some View {
        if let problem {
            message(problem.line.map { "Line \($0): \(problem.message)" } ?? problem.message, line: problem.line)
        } else if let saveError {
            message(saveError, line: saveErrorLine)
        }
    }

    private func message(_ text: String, line: Int?) -> some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.white)
        .background(.red.gradient)
        .onTapGesture { if let line { goToLine = line } }
    }

    private func load() async {
        guard let client = model.client else { return }
        loadError = nil
        do {
            let config = try await client.rawConfig()
            text = config
            saved = config
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save(restart: Bool) {
        guard let client = model.client else { return }
        let config = text
        isSaving = true
        Task {
            do {
                savedMessage = try await client.saveConfig(config, restart: restart)
                saved = config
            } catch FrigateClient.ClientError.server(_, let message) {
                (saveError, saveErrorLine) = ConfigSaveError.forEditor(message)
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

/// Frigate explains a rejected config with lines like
/// `Line 11: cameras -> yard -> detect -> fps - Input should be a valid integer`,
/// counting from 0. The editor counts from 1, like most editors.
nonisolated enum ConfigSaveError {
    /// The message with its line numbers shifted to match the editor, and the
    /// first line it mentions.
    static func forEditor(_ message: String) -> (message: String, firstLine: Int?) {
        let pattern = /^Line (\d+):/.anchorsMatchLineEndings()
        var firstLine: Int?
        let shifted = message.replacing(pattern) { match in
            guard let line = Int(match.output.1) else { return String(match.output.0) }
            if firstLine == nil { firstLine = line + 1 }
            return "Line \(line + 1):"
        }
        return (shifted.trimmingCharacters(in: .whitespacesAndNewlines), firstLine)
    }
}
