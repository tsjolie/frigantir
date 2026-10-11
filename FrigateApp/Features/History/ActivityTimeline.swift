import SwiftUI

/// A vertical, scrubbable timeline like the Frigate PWA's on mobile: newest at
/// the top, motion level drawn as bars, review items as coloured bands.
///
/// The time under the fixed centre line is the playback position. Dragging the
/// timeline scrubs; while it's left alone, it follows playback.
struct ActivityTimeline: View {
    /// Hour-aligned; the top of the timeline is `range.upperBound`.
    let range: ClosedRange<Date>
    let motion: [MotionActivity]
    let reviews: [ReviewItem]
    let currentDate: Date
    var canLoadEarlier = true

    var onScrubBegan: () -> Void = {}
    var onScrub: (Date) -> Void = { _ in }
    var onScrubEnded: (Date) -> Void = { _ in }
    var onTap: (Date) -> Void = { _ in }
    var onLoadEarlier: () -> Void = {}

    /// 8 pt per minute: one 30 s motion bucket is 4 pt tall.
    static let pointsPerSecond: CGFloat = 8 / 60
    static let hourHeight = 3600 * pointsPerSecond

    @State private var position = ScrollPosition()
    @State private var isUserScrolling = false
    @State private var scrubDate: Date?

    var body: some View {
        GeometryReader { geometry in
            let inset = geometry.size.height / 2
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: inset)
                    LazyVStack(spacing: 0) {
                        ForEach(hours, id: \.self) { hour in
                            TimelineHourView(hourEnd: hour,
                                             motion: motion(inHourEndingAt: hour),
                                             reviews: reviews(inHourEndingAt: hour))
                                .frame(height: Self.hourHeight)
                                .contentShape(.rect)
                                .onTapGesture { location in
                                    onTap(hour.addingTimeInterval(-Double(location.y / Self.pointsPerSecond)))
                                }
                        }
                    }
                    if canLoadEarlier {
                        Button("Load earlier", systemImage: "chevron.down", action: onLoadEarlier)
                            .buttonStyle(.bordered)
                            .padding()
                    }
                    Color.clear.frame(height: inset)
                }
            }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                let scrolling = [.tracking, .interacting, .decelerating].contains(phase)
                if scrolling, !isUserScrolling {
                    isUserScrolling = true
                    onScrubBegan()
                } else if !scrolling, isUserScrolling {
                    isUserScrolling = false
                    onScrubEnded(scrubDate ?? currentDate)
                    scrubDate = nil
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                guard isUserScrolling else { return }
                let date = clamped(range.upperBound.addingTimeInterval(-Double(offset / Self.pointsPerSecond)))
                scrubDate = date
                onScrub(date)
            }
            .onChange(of: currentDate, initial: true) { follow(currentDate) }
            .onChange(of: range) { follow(currentDate) }
            .overlay { centerLine }
        }
    }

    private var centerLine: some View {
        ZStack {
            Rectangle()
                .fill(.primary)
                .frame(height: 1.5)
            Text(scrubDate ?? currentDate, format: .dateTime.weekday(.abbreviated).hour().minute().second())
                .font(.caption.monospacedDigit().bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .capsule)
        }
        .allowsHitTesting(false)
    }

    private func follow(_ date: Date) {
        guard !isUserScrolling else { return }
        position.scrollTo(y: range.upperBound.timeIntervalSince(date) * Self.pointsPerSecond)
    }

    private func clamped(_ date: Date) -> Date {
        min(max(date, range.lowerBound), min(range.upperBound, .now))
    }

    // MARK: - Data per hour

    /// Hour boundaries from newest to oldest; each row shows the hour ending there.
    private var hours: [Date] {
        stride(from: range.upperBound.timeIntervalSince1970, to: range.lowerBound.timeIntervalSince1970, by: -3600)
            .map(Date.init(timeIntervalSince1970:))
    }

    private func motion(inHourEndingAt hourEnd: Date) -> [MotionActivity] {
        let end = hourEnd.timeIntervalSince1970
        return motion.filter { $0.startTime >= end - 3600 && $0.startTime < end }
    }

    private func reviews(inHourEndingAt hourEnd: Date) -> [ReviewItem] {
        let start = hourEnd.timeIntervalSince1970 - 3600
        let end = hourEnd.timeIntervalSince1970
        return reviews.filter { $0.startTime < end && ($0.endTime ?? Date.now.timeIntervalSince1970) > start }
    }
}

/// One hour of the timeline, drawn with a Canvas. Rows are lazy, so only the
/// hours on screen are rendered.
private struct TimelineHourView: View {
    let hourEnd: Date
    let motion: [MotionActivity]
    let reviews: [ReviewItem]

    private static let labelWidth: CGFloat = 52

    var body: some View {
        Canvas { context, size in
            let top = hourEnd.timeIntervalSince1970
            let pps = ActivityTimeline.pointsPerSecond
            func y(_ t: TimeInterval) -> CGFloat { CGFloat(top - t) * pps }
            let left = Self.labelWidth
            let width = size.width - left

            // Not yet happened: shade the part of the current hour that's in the future.
            let now = Date.now.timeIntervalSince1970
            if now < top {
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: y(now))),
                             with: .color(.secondary.opacity(0.08)))
            }

            for item in reviews {
                let color: Color = item.severity == .alert ? .red : .orange
                let top = max(0, y(item.endTime ?? now))
                let height = max(3, min(size.height, y(item.startTime)) - top)
                context.fill(Path(CGRect(x: left, y: top, width: width, height: height)),
                             with: .color(color.opacity(0.18)))
                context.fill(Path(roundedRect: CGRect(x: size.width - 7, y: top, width: 5, height: height),
                                  cornerRadius: 2.5),
                             with: .color(color))
            }

            let barWidth = width - 16
            for bucket in motion where bucket.motion > 0 {
                let level = sqrt(min(bucket.motion, 100) / 100)
                let rect = CGRect(x: left, y: y(bucket.startTime + 30) + 0.5,
                                  width: max(1, barWidth * level), height: 30 * pps - 1)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.75)))
            }

            for quarter in 0 ..< 4 {
                let lineY = CGFloat(quarter) * size.height / 4
                let isHour = quarter == 0
                context.fill(Path(CGRect(x: isHour ? 0 : left - 10, y: lineY,
                                         width: isHour ? size.width : 10, height: 0.5)),
                             with: .color(.secondary.opacity(isHour ? 0.6 : 0.4)))
                if quarter % 2 == 0 {
                    let date = hourEnd.addingTimeInterval(-Double(quarter) * 900)
                    let label = Text(date, format: Self.labelFormat(date))
                        .font(isHour ? .caption2.bold() : .caption2)
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: 4, y: lineY + 2), anchor: .topLeading)
                }
            }
        }
    }

    /// Midnight is labelled with the date so day changes stand out.
    private static func labelFormat(_ date: Date) -> Date.FormatStyle {
        let isMidnight = Calendar.current.component(.hour, from: date) == 0
            && Calendar.current.component(.minute, from: date) == 0
        return isMidnight ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
    }
}
