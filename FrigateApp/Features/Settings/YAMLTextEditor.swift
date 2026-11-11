import Runestone
import SwiftUI
import TreeSitterYAMLRunestone
import Yams

/// A YAML mistake that stops the file from parsing at all.
nonisolated struct YAMLProblem: Equatable, Sendable {
    /// 1-based, like the line numbers in the editor's gutter.
    let line: Int?
    let message: String

    /// The first syntax error in `text`, or nil if it parses. This only knows
    /// YAML; Frigate checks its own rules when the config is saved.
    static func first(in text: String) -> YAMLProblem? {
        do {
            _ = try Yams.compose(yaml: text)
            return nil
        } catch let error as YamlError {
            switch error {
            case let .scanner(context, problem, mark, _), let .parser(context, problem, mark, _),
                 let .composer(context, problem, mark, _):
                // Something left open (say, a quote) is only noticed at the end
                // of the file; point at where it started instead.
                if problem.contains("end of stream"), let context {
                    return YAMLProblem(line: context.mark.line,
                                       message: "\(problem.capitalizingFirstLetter) \(context.text)")
                }
                return YAMLProblem(line: mark.line, message: problem.capitalizingFirstLetter)
            case let .duplicatedKeysInMapping(duplicates, context):
                let keys = duplicates.map { "“\($0)”" }.joined(separator: ", ")
                return YAMLProblem(line: context.mark.line, message: "Duplicate key \(keys)")
            default:
                return YAMLProblem(line: nil, message: error.description)
            }
        } catch {
            return YAMLProblem(line: nil, message: error.localizedDescription)
        }
    }
}

nonisolated private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

/// Runestone's code editor set up for YAML: syntax colours, line numbers,
/// two-space indentation that follows the line above, and none of the
/// keyboard "help" (autocorrect, smart quotes) that would break the file.
/// `errorLine` is tinted red.
struct YAMLTextEditor: UIViewRepresentable {
    @Binding var text: String
    var errorLine: Int?
    /// Set to a line number to scroll there and put the cursor on it.
    @Binding var goToLine: Int?

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.editorDelegate = context.coordinator
        view.backgroundColor = .systemBackground
        view.showLineNumbers = true
        view.lineSelectionDisplayType = .line
        view.indentStrategy = .space(length: 2)
        view.isLineWrappingEnabled = false
        view.alwaysBounceVertical = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inputAccessoryView = Self.keyboardToolbar(for: view)
        view.setState(TextViewState(text: text, language: .yaml))
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        // Only text replaced from outside (loading the file) is set here;
        // typing already updated the binding.
        if view.text != text {
            view.setState(TextViewState(text: text, language: .yaml))
        }
        let errorRange = errorLine.flatMap { Self.range(ofLine: $0, in: text) }
        view.highlightedRanges = errorRange.map {
            [HighlightedRange(id: "yaml-error", range: $0, color: .systemRed.withAlphaComponent(0.25))]
        } ?? []
        if let line = goToLine {
            view.goToLine(line - 1)
            DispatchQueue.main.async { goToLine = nil }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: TextViewDelegate {
        var parent: YAMLTextEditor
        init(parent: YAMLTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: TextView) {
            parent.text = textView.text
        }
    }

    /// The iPhone keyboard has no Tab key; YAML is all indentation.
    private static func keyboardToolbar(for view: TextView) -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(image: UIImage(systemName: "decrease.indent"),
                            primaryAction: UIAction { [weak view] _ in view?.shiftLeft() }),
            UIBarButtonItem(image: UIImage(systemName: "increase.indent"),
                            primaryAction: UIAction { [weak view] _ in view?.shiftRight() }),
            .flexibleSpace(),
            UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"),
                            primaryAction: UIAction { [weak view] _ in _ = view?.resignFirstResponder() }),
        ]
        toolbar.sizeToFit()
        return toolbar
    }

    /// The UTF-16 range of a 1-based line; past the end, the last line.
    static func range(ofLine line: Int, in text: String) -> NSRange? {
        let string = text as NSString
        guard line >= 1, string.length > 0 else { return nil }
        var range = string.lineRange(for: NSRange(location: 0, length: 0))
        for _ in 1 ..< line where NSMaxRange(range) < string.length {
            range = string.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
        }
        return range
    }
}
