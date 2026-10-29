import SwiftUI
import UIKit

/// A date and time to the second, for export spans. The system DatePicker
/// stops at minutes, so the time is set on hour : minute : second wheels.
///
/// Shows as one row with the value; tap it to edit. Use inside a Form section.
struct PreciseDatePicker: View {
    let title: String
    @Binding var date: Date
    @Binding var isExpanded: Bool
    var latest = Date.now

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            LabeledContent(title) {
                Text(date, format: .dateTime.month(.abbreviated).day().year().hour().minute().second())
                    .monospacedDigit()
                    .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
            }
            .foregroundStyle(.primary)
        }
        if isExpanded {
            DatePicker("Date", selection: day, in: ...latest, displayedComponents: .date)
            TimeOfDayWheel(date: $date)
                .frame(height: 160)
        }
    }

    /// The day part only; changing it keeps the time of day.
    private var day: Binding<Date> {
        Binding(get: { date }, set: { newDay in
            let calendar = Calendar.current
            var parts = calendar.dateComponents([.year, .month, .day], from: newDay)
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            (parts.hour, parts.minute, parts.second) = (time.hour, time.minute, time.second)
            date = calendar.date(from: parts) ?? newDay
        })
    }
}

/// Hour, minute and second wheels for a date's time of day, plus an AM/PM
/// wheel when the phone uses 12-hour time (hours then run 12, 1 … 11).
private struct TimeOfDayWheel: UIViewRepresentable {
    @Binding var date: Date

    private enum Column: Equatable {
        case hour, minute, second, period, separator
    }

    /// Follows the iOS 24-Hour Time setting, like the system pickers.
    private static var usesTwelveHourClock: Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
    }

    private let twelveHour = Self.usesTwelveHourClock
    private var hourCount: Int { twelveHour ? 12 : 24 }

    /// Wheels, with ":" columns between them.
    private var columns: [Column] {
        [.hour, .separator, .minute, .separator, .second] + (twelveHour ? [.period] : [])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIPickerView {
        let picker = UIPickerView()
        picker.dataSource = context.coordinator
        picker.delegate = context.coordinator
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return picker
    }

    func updateUIView(_ picker: UIPickerView, context: Context) {
        context.coordinator.parent = self
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = time.hour ?? 0
        let clock = TwelveHourClock(hour: hour)
        for (index, column) in columns.enumerated() {
            let row: Int? = switch column {
            case .hour: twelveHour ? clock.hourRow : hour
            case .minute: time.minute
            case .second: time.second
            case .period: clock.isPM ? 1 : 0
            case .separator: nil
            }
            guard let row, picker.selectedRow(inComponent: index) != row else { continue }
            picker.selectRow(row, inComponent: index, animated: false)
        }
    }

    final class Coordinator: NSObject, UIPickerViewDataSource, UIPickerViewDelegate {
        var parent: TimeOfDayWheel

        init(_ parent: TimeOfDayWheel) { self.parent = parent }

        func numberOfComponents(in pickerView: UIPickerView) -> Int { parent.columns.count }

        func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
            switch parent.columns[component] {
            case .hour: parent.hourCount
            case .minute, .second: 60
            case .period: 2
            case .separator: 1
            }
        }

        func pickerView(_ pickerView: UIPickerView, widthForComponent component: Int) -> CGFloat {
            switch parent.columns[component] {
            case .separator: 12
            case .period: 72
            default: 64
            }
        }

        func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int,
                        reusing view: UIView?) -> UIView {
            let label = view as? UILabel ?? UILabel()
            label.textAlignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
            let column = parent.columns[component]
            let hour = parent.twelveHour ? TwelveHourClock.displayHour(row: row) : row
            let calendar = Calendar.current
            label.text = switch column {
            // 12-hour clocks write "9", 24-hour ones "09".
            case .hour: String(format: parent.twelveHour ? "%d" : "%02d", hour)
            case .minute, .second: String(format: "%02d", row)
            case .period: row == 0 ? calendar.amSymbol : calendar.pmSymbol
            case .separator: ":"
            }
            label.accessibilityLabel = switch column {
            case .hour: "\(hour) hours"
            case .minute: "\(row) minutes"
            case .second: "\(row) seconds"
            case .period, .separator: label.text
            }
            label.isAccessibilityElement = column != .separator
            return label
        }

        func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
            func selected(_ column: Column) -> Int {
                guard let index = parent.columns.firstIndex(of: column) else { return 0 }
                return pickerView.selectedRow(inComponent: index)
            }
            let hour = parent.twelveHour
                ? TwelveHourClock(hourRow: selected(.hour), isPM: selected(.period) == 1).hour
                : selected(.hour)
            if let date = Calendar.current.date(bySettingHour: hour, minute: selected(.minute),
                                                second: selected(.second), of: parent.date) {
                parent.date = date
            }
        }
    }
}

/// Converts between a 0–23 hour and the 12-hour wheels: hour row 0 is "12",
/// rows 1–11 are "1"–"11", and AM/PM picks the half of the day.
nonisolated struct TwelveHourClock: Equatable {
    let hourRow: Int
    let isPM: Bool

    init(hour: Int) {
        hourRow = hour % 12
        isPM = hour >= 12
    }

    init(hourRow: Int, isPM: Bool) {
        self.hourRow = hourRow
        self.isPM = isPM
    }

    var hour: Int { hourRow + (isPM ? 12 : 0) }

    static func displayHour(row: Int) -> Int { row == 0 ? 12 : row }
}
