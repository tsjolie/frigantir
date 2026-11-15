import Foundation
import Testing
@testable import FrigateApp

/// Choosing between the main and fallback server addresses.
@Suite struct ServerReachabilityTests {
    let primary = URL(string: "http://192.168.1.10:8971")!
    let fallback = URL(string: "https://frigate.example.com")!

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeNetwork.self]
        return URLSession(configuration: configuration)
    }

    @Test func prefersTheMainAddress() async {
        let chosen = await ServerReachability.firstReachable([primary, fallback], session: session)
        #expect(chosen == primary)
    }

    @Test func fallsBackWhenTheMainAddressIsUnreachable() async {
        let chosen = await ServerReachability.firstReachable(
            [URL(string: "http://unreachable.test")!, fallback], session: session)
        #expect(chosen == fallback)
    }

    /// A login prompt still means the server is there.
    @Test func countsUnauthorizedAsReachable() async {
        let chosen = await ServerReachability.firstReachable(
            [URL(string: "https://needs-login.test")!, fallback], session: session)
        #expect(chosen == URL(string: "https://needs-login.test")!)
    }

    @Test func nilWhenNothingAnswers() async {
        let chosen = await ServerReachability.firstReachable(
            [URL(string: "http://unreachable.test")!], session: session)
        #expect(chosen == nil)
    }
}

/// `unreachable.test` can't be connected to, `needs-login.test` answers 401,
/// anything else answers 200.
nonisolated final class FakeNetwork: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch request.url?.host {
        case "unreachable.test":
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case let host:
            let status = host == "needs-login.test" ? 401 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("0.16.0".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
