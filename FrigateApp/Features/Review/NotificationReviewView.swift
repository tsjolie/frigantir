import SwiftUI

/// A review opened from a notification, shown full screen over whatever was on
/// screen (any tab, an open review, a camera), so it doesn't depend on the
/// Review tab's navigation state.
///
/// It appears straight away and loads the review itself, retrying a few times:
/// right after a tap wakes the app, the network often isn't ready for the first
/// request.
struct NotificationReviewView: View {
    @Environment(AppModel.self) private var model
    let reviewID: String

    private enum Phase {
        case loading
        case loaded(ReviewItem)
        case failed(String)
    }

    @State private var phase = Phase.loading

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Loading alert…")
                case .loaded(let item):
                    ReviewDetailView(item: item)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't load this alert", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { model.closeReview() }
                }
            }
        }
        .task(id: reviewID) { await load() }
    }

    private func load() async {
        phase = .loading
        guard let client = model.client else {
            phase = .failed("Not connected to a Frigate server.")
            return
        }
        var lastError: Error?
        for attempt in 1 ... 4 {
            do {
                phase = .loaded(try await client.review(id: reviewID))
                return
            } catch {
                if Task.isCancelled { return }
                lastError = error
                if attempt < 4 { try? await Task.sleep(for: .seconds(attempt)) }
            }
        }
        phase = .failed(lastError?.localizedDescription ?? "Unknown error")
    }
}
