import Foundation
import Testing
@testable import FrigateApp

/// The config editor: who may use it, the live YAML check, and saving against
/// a fake Frigate that answers like `/api/config/raw` and `/api/config/save`.
@Suite(.serialized) struct ConfigEditorTests {
    @Test(arguments: [
        (#"{"username":"admin","role":"admin","allowed_cameras":["yard"]}"#, true),
        (#"{"username":"kid","role":"viewer","allowed_cameras":["yard"]}"#, false),
        (#"{"username":"cam","role":"garden_only","allowed_cameras":["yard"]}"#, false),
        // Before Frigate 0.16 there were no roles; every user was an admin.
        (#"{"username":"admin"}"#, true),
    ])
    func onlyAdminsEditConfig(json: String, canEdit: Bool) throws {
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
        #expect(profile.canEditConfig == canEdit)
    }

    @Test func acceptsValidYAML() {
        let yaml = """
        mqtt:
          enabled: false
        cameras:
          yard: # comment
            ffmpeg:
              inputs:
                - path: rtsp://{FRIGATE_RTSP_USER}@10.0.0.2/stream
                  roles: [detect, record]
        """
        #expect(YAMLProblem.first(in: yaml) == nil)
    }

    @Test(arguments: [
        ("cameras:\n  yard:\n    detect:\n   enabled: true\n", 4),
        ("mqtt:\n  host: \"10.0.0.2\n  port: 1883\n", 2),
        ("cameras:\n  yard: {}\n  yard: {}\n", 3),
    ])
    func flagsYAMLMistakesOnTheirLine(yaml: String, line: Int) throws {
        let problem = try #require(YAMLProblem.first(in: yaml))
        // Duplicate keys are reported at the mapping that holds them.
        #expect(problem.line == line || problem.message.hasPrefix("Duplicate key"))
        #expect(!problem.message.isEmpty)
    }

    @Test func shiftsFrigateLineNumbersToTheEditors() {
        let message = """
        Your configuration is invalid.
        See the official documentation at docs.frigate.video.

        Line 11: cameras -> yard -> detect -> fps - Input should be a valid integer
        Line 3: mqtt -> port - Input should be a valid integer
        """
        let (shifted, firstLine) = ConfigSaveError.forEditor(message)
        #expect(firstLine == 12)
        #expect(shifted.contains("Line 12: cameras -> yard"))
        #expect(shifted.contains("Line 4: mqtt -> port"))
        #expect(shifted.hasPrefix("Your configuration is invalid."))
    }

    @Test func rangeOfLineCoversThatLine() throws {
        let text = "a: 1\nbb: 2\nccc: 3"
        let ns = text as NSString
        #expect(ns.substring(with: try #require(YAMLTextEditor.range(ofLine: 2, in: text))) == "bb: 2\n")
        // Past the end (libyaml reports end-of-file errors there): the last line.
        #expect(ns.substring(with: try #require(YAMLTextEditor.range(ofLine: 9, in: text))) == "ccc: 3")
    }

    @Test func loadsRawConfigSentAsJSONString() async throws {
        FakeFrigateConfig.handle = { _ in (200, Data(#""mqtt:\n  enabled: false\n""#.utf8)) }
        let config = try await Self.client.rawConfig()
        #expect(config == "mqtt:\n  enabled: false\n")
    }

    @Test func savesAsPlainTextWithRestartOption() async throws {
        FakeFrigateConfig.handle = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            guard request.httpMethod == "POST", request.url?.path == "/api/config/save",
                  query == [URLQueryItem(name: "save_option", value: "restart")],
                  request.value(forHTTPHeaderField: "Content-Type") == "text/plain",
                  FakeFrigateConfig.body(of: request) == "mqtt:\n  enabled: true\n"
            else { return (500, Data()) }
            return (200, Data(#"{"success":true,"message":"Config successfully saved, restarting..."}"#.utf8))
        }
        let message = try await Self.client.saveConfig("mqtt:\n  enabled: true\n", restart: true)
        #expect(message == "Config successfully saved, restarting...")
    }

    @Test func rejectedSaveThrowsFrigatesReasons() async throws {
        FakeFrigateConfig.handle = { _ in
            (400, Data(#"{"success":false,"message":"Your configuration is invalid.\nLine 0: mqtt - Field required"}"#.utf8))
        }
        do {
            _ = try await Self.client.saveConfig("cameras: {}\n", restart: false)
            Issue.record("Expected Frigate to reject the config")
        } catch FrigateClient.ClientError.server(400, let message) {
            #expect(message.contains("Line 0: mqtt - Field required"))
        }
    }

    static var client: FrigateClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeFrigateConfig.self]
        return FrigateClient(baseURL: URL(string: "https://frigate.example.com")!,
                             session: URLSession(configuration: configuration))
    }
}

/// Answers with a chosen status code (`FakeFrigate` in ReviewPagingTests only
/// answers 200). Its own class, so the two suites can run side by side.
nonisolated final class FakeFrigateConfig: URLProtocol {
    nonisolated(unsafe) static var handle: @Sendable (URLRequest) -> (Int, Data) = { _ in (200, Data()) }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    static func body(of request: URLRequest) -> String? {
        if let body = request.httpBody { return String(bytes: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(bytes: data, encoding: .utf8)
    }

    override func startLoading() {
        let (status, data) = Self.handle(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
