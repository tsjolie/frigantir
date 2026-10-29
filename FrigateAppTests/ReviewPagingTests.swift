import Foundation
import Testing
@testable import FrigateApp

/// "Mark all reviewed" against a fake Frigate: every unreviewed item of any
/// age, fetched page by page.
@Suite(.serialized) struct ReviewPagingTests {
    /// 1,200 unreviewed detections, one a minute, newest first, like Frigate.
    nonisolated static let startTimes = (0 ..< 1200).map { 1_790_000_000 - Double($0) * 60 }

    @Test func fetchesEveryUnreviewedItemWithNoAgeLimit() async throws {
        FakeFrigate.requests = []
        // @Sendable: called on URLSession's loading thread, not the main actor.
        FakeFrigate.respond = { @Sendable request in
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") })
            let before = query["before"].flatMap(Double.init) ?? .infinity
            let limit = Int(query["limit"] ?? "50")!
            let page = Self.startTimes.filter { $0 < before }.prefix(limit)
            return Data(("[" + page.map(Self.reviewJSON).joined(separator: ",") + "]").utf8)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeFrigate.self]
        let client = FrigateClient(baseURL: URL(string: "https://frigate.example.com")!,
                                   session: URLSession(configuration: configuration))

        let items = try await client.allUnreviewedReviews(severity: .detection)

        #expect(items.count == 1200)
        #expect(Set(items.map(\.id)).count == 1200)
        #expect(FakeFrigate.requests.count == 3)
        for request in FakeFrigate.requests {
            let after = try #require(request.queryItems?.first { $0.name == "after" }?.value)
            // Frigate treats a missing or zero `after` as "the last 24 hours".
            #expect(Double(after) ?? 0 > 0)
            #expect(Double(after) ?? .infinity < 86400)
            #expect(request.queryItems?.contains(URLQueryItem(name: "reviewed", value: "0")) == true)
        }
    }

    nonisolated static func reviewJSON(_ start: Double) -> String {
        """
        {"id":"\(start)-x","camera":"yard","start_time":\(start),"end_time":\(start + 10),"severity":"detection",
         "thumb_path":"/media/frigate/clips/review/t.webp","has_been_reviewed":false,
         "data":{"objects":["person"],"zones":[],"audio":[],"detections":[]}}
        """
    }
}

/// Answers `FrigateClient` requests in tests. The suite is serialized, so the
/// shared state is only used by one test at a time.
nonisolated final class FakeFrigate: URLProtocol {
    nonisolated(unsafe) static var respond: @Sendable (URLRequest) -> Data = { _ in Data() }
    nonisolated(unsafe) static var requests: [URLComponents] = []

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            Self.requests.append(components)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.respond(request))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
