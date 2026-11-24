import AppKit
import Foundation
import Testing
@testable import WorkLight
@testable import WorkLightCore

private let fakeKey = "fake_worklight_token.012345"
private let testEntity = "light.office_lamp"
private let testURL = "http://127.0.0.1:8123"
private let testEndpoint = HomeAssistantEndpoint(baseURLString: testURL, entityID: testEntity, useMiotEffects: false)
private let miotEndpoint = HomeAssistantEndpoint(baseURLString: testURL, entityID: testEntity, useMiotEffects: true)
private let stamp = "2026-11-09T12:01:02.123456+00:00"

private func report(
    state: String = "on",
    attributes: String = #"{"brightness":114.75,"color_mode":"rgb","rgb_color":[230,25,3]}"#,
    id: String = testEntity,
    revision: String = stamp
) -> String {
    """
    {"entity_id":"\(id)","state":"\(state)","last_updated":"\(revision)","attributes":\(attributes)}
    """
}

private func decode(_ json: String) throws -> LampReport {
    try JSONDecoder().decode(LampReport.self, from: Data(json.utf8))
}

private actor Stub {
    struct Reply: Sendable {
        var json: String
        var status: Int = 200
        var otherURL: Bool = false
    }

    var replies: [Reply]
    var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let next = replies.removeFirst()
        let url = next.otherURL ? URL(string: "http://example.invalid")! : request.url!
        return (Data(next.json.utf8), HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: nil)!)
    }

    nonisolated var client: HomeAssistantLight {
        HomeAssistantLight(credential: { try BearerToken(data: Data(fakeKey.utf8)) }, transport: send)
    }
}

@MainActor
private func configuredController(client: LightTransportClient, defaults: UserDefaults, autoBusy: Bool = false, returnBehavior: CallReturnBehavior = .previous) -> LampController {
    let model = LampController(light: client, defaults: defaults)
    var settings = model.settings
    settings.endpoint = testEndpoint
    settings.autoBusyOnMicrophone = autoBusy
    settings.callReturnBehavior = returnBehavior
    model.save(settings)
    return model
}

@Test(arguments: ["", " ", "\u{00a0}", "\u{feff}", "\u{200b}", "fake_worklight_token\u{200b}", "невалидный_токен_ключа", "fake_worklight\ntoken"])
func rejectsInvalidCredential(_ text: String) {
    #expect(throws: LampError.credential) { try BearerToken(data: Data(text.utf8)) }
}

@Test func normalizesCredentialInput() throws {
    let value = try BearerToken(data: Data("\u{feff}\u{00a0} \(fakeKey)\r\n".utf8))
    #expect(value.value == fakeKey)
    #expect(throws: LampError.credential) { try BearerToken(data: Data([0xff, 0xfe])) }
    #expect(throws: LampError.credential) { try BearerToken(data: Data(repeating: 97, count: 4097)) }
}

@Test func validatesHomeAssistantEndpoint() {
    #expect(HomeAssistantEndpoint(baseURLString: "http://homeassistant.local:8123", entityID: "light.office_lamp").isConfigured)
    #expect(HomeAssistantEndpoint(baseURLString: "https://ha.example.com", entityID: "light.desk_01").isConfigured)
    #expect(!HomeAssistantEndpoint(baseURLString: "ftp://homeassistant.local", entityID: "light.office_lamp").isConfigured)
    #expect(!HomeAssistantEndpoint(baseURLString: "http://user:pass@homeassistant.local:8123", entityID: "light.office_lamp").isConfigured)
    #expect(!HomeAssistantEndpoint(baseURLString: "http://homeassistant.local:8123", entityID: "switch.office_lamp").isConfigured)
    #expect(!HomeAssistantEndpoint(baseURLString: "http://homeassistant.local:8123", entityID: "light.Office-Lamp").isConfigured)
    #expect(!HomeAssistantEndpoint(baseURLString: "http://homeassistant.local:8123", entityID: "").isConfigured)
}

@Test func storesAndValidatesPresets() throws {
    var draft = LampSettings.defaults
    draft.endpoint = testEndpoint
    draft.normalStyle = .color
    draft.normalRGB = 0x00A2FF
    draft.normalBrightness = 67
    draft.autoBusyOnMicrophone = true
    draft.callReturnBehavior = .free
    let bytes = try JSONEncoder().encode(draft)
    #expect(LampSettings.read(bytes) == draft)
    #expect(draft.output(for: .normal) == .color(RGB(packed: 0x00A2FF)!, brightness: 67))
    #expect(LampSettings.read(nil) == .defaults)
    #expect(LampSettings.read(Data([0xff])) == .defaults)
    for malformed in ["", " ", "\u{00a0}", "\u{200b}", "null", "{}", String(repeating: " ", count: 8193)] {
        #expect(LampSettings.read(Data(malformed.utf8)) == .defaults)
    }
    for (key, value) in [("normalBrightness", -1), ("busyBrightness", 0), ("freeBrightness", 101), ("kelvin", 6501), ("normalRGB", 0)] {
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object[key] = value
        #expect(try LampSettings.read(JSONSerialization.data(withJSONObject: object)) == .defaults)
    }
}

@Test func readsStandardAndMiotLightReports() throws {
    let red = try decode(report())
    #expect(red.output == .color(.red, brightness: 45))
    #expect(red.acknowledges(.color(.red, brightness: 45), miotEffects: false))

    let hueWhite = try decode(report(attributes: #"{"color_mode":"color_temp","brightness":191,"color_temp_kelvin":2700}"#))
    #expect(hueWhite.output == .white(kelvin: 2700, brightness: 75))
    #expect(hueWhite.acknowledges(.white(kelvin: 2700, brightness: 75), miotEffects: false))

    let miotGreen = try decode(report(attributes: #"{"effect":"Color","color_mode":"color_temp","brightness":102,"rgb_color":[255,167,87],"light.mode":1,"light.color":52224,"light.brightness":40}"#))
    #expect(miotGreen.output == .color(.green, brightness: 40))
    #expect(miotGreen.acknowledges(.color(.green, brightness: 40), miotEffects: true))
}

@Test func sendsStandardOrMiotServicePayloads() async throws {
    let off = report(state: "off", attributes: "{}")
    let white = report(attributes: #"{"color_mode":"color_temp","brightness":191,"color_temp_kelvin":2700}"#)
    let greenMiot = report(attributes: #"{"effect":"Color","color_mode":"color_temp","brightness":102,"light.mode":2}"#)
    let stub = Stub([.init(json: "[\(off)]"), .init(json: "[\(white)]"), .init(json: "[\(greenMiot)]")])
    let client = stub.client

    #expect(try await client.apply(.off, endpoint: testEndpoint).state == "off")
    #expect(try await client.apply(.white(kelvin: 2700, brightness: 75), endpoint: testEndpoint).output == .white(kelvin: 2700, brightness: 75))
    #expect(try await client.apply(.color(.green, brightness: 40), endpoint: miotEndpoint).attributes.effect == "Color")

    let requests = await stub.requests
    #expect(requests.map { $0.url?.path } == ["/api/services/light/turn_off", "/api/services/light/turn_on", "/api/services/light/turn_on"])
    let bodies = try requests.map {
        let data = try #require($0.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    #expect(bodies.allSatisfy { $0["entity_id"] as? String == testEntity })
    #expect(bodies[1]["effect"] == nil)
    #expect(bodies[1]["color_temp_kelvin"] as? Int == 2700)
    #expect(bodies[2]["effect"] as? String == "Color")
    #expect(bodies[2]["rgb_color"] as? [Int] == [0, 204, 0])
}

@Test func readsBackWithoutRetryWhenServiceDidNotConfirm() async throws {
    let stub = Stub([.init(json: "[]"), .init(json: report())])
    await #expect(throws: LampError.unconfirmed) { try await stub.client.apply(.off, endpoint: testEndpoint) }
    #expect(await stub.requests.map(\.httpMethod) == ["POST", "GET"])

    let verified = Stub([.init(json: "[]"), .init(json: report(state: "off", attributes: "{}"))])
    #expect(try await verified.client.apply(.off, endpoint: testEndpoint).output == .off)
}

@Test func rejectsUnconfiguredEndpointAndMalformedReplies() async {
    let stub = Stub([
        .init(json: "{}"), .init(json: report(id: "light.other")),
        .init(json: report(revision: "\u{00a0}")), .init(json: report(state: "unavailable")),
        .init(json: report(), otherURL: true), .init(json: "{}", status: 401),
    ])
    await #expect(throws: LampError.notConfigured) {
        try await stub.client.read(endpoint: HomeAssistantEndpoint(baseURLString: testURL, entityID: ""))
    }
    await #expect(throws: LampError.invalidPreset) {
        try await stub.client.apply(.white(kelvin: 100, brightness: 70), endpoint: testEndpoint)
    }
    #expect(await stub.requests.isEmpty)
    for expected in [LampError.response, .response, .response, .unavailable, .response, .denied] {
        await #expect(throws: expected) { try await stub.client.read(endpoint: testEndpoint) }
    }
}

@MainActor
@Test func autoBusySwitchesToBusyOnCallAndRestoresPreviousScene() async throws {
    let isolated = "WorkLightTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: isolated))
    defer { defaults.removePersistentDomain(forName: isolated) }

    let initialNormal = report(attributes: #"{"color_mode":"color_temp","brightness":191,"color_temp_kelvin":2700}"#)
    let busyReply = report(attributes: #"{"color_mode":"rgb","brightness":114.75,"rgb_color":[230,25,3]}"#)
    let restoredNormal = report(attributes: #"{"color_mode":"color_temp","brightness":191,"color_temp_kelvin":2700}"#)

    let stub = Stub([
        .init(json: initialNormal),
        .init(json: "[\(busyReply)]"),
        .init(json: "[\(restoredNormal)]"),
    ])

    let model = configuredController(client: stub.client, defaults: defaults, autoBusy: true, returnBehavior: .previous)
    await model.refresh()
    #expect(model.status == .ready(.normal, .white(kelvin: 2700, brightness: 75)))

    await model.handleCallActivityChanged(active: true)
    #expect(model.status == .ready(.busy, .color(.red, brightness: 45)))

    await model.handleCallActivityChanged(active: false)
    #expect(model.status == .ready(.normal, .white(kelvin: 2700, brightness: 75)))
    #expect(await stub.requests.map(\.httpMethod) == ["GET", "POST", "POST"])
}

@MainActor
@Test func manualOverrideDuringCallPreventsAutoRestoreFromFightingUser() async throws {
    let isolated = "WorkLightTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: isolated))
    defer { defaults.removePersistentDomain(forName: isolated) }

    let initialFree = report(attributes: #"{"color_mode":"rgb","brightness":102,"rgb_color":[0,204,0]}"#)
    let busyReply = report(attributes: #"{"color_mode":"rgb","brightness":114.75,"rgb_color":[230,25,3]}"#)
    let offReply = report(state: "off", attributes: "{}")

    let stub = Stub([
        .init(json: initialFree),
        .init(json: "[\(busyReply)]"),
        .init(json: "[\(offReply)]"),
    ])

    let model = configuredController(client: stub.client, defaults: defaults, autoBusy: true, returnBehavior: .previous)
    await model.refresh()
    await model.handleCallActivityChanged(active: true)
    #expect(model.status == .ready(.busy, .color(.red, brightness: 45)))

    // User explicitly turns off lamp mid-call
    await model.select(.off, initiatedByUser: true)
    #expect(model.status == .ready(.off, .off))

    // Call ends -> should NOT override user's explicit off command
    await model.handleCallActivityChanged(active: false)
    #expect(model.status == .ready(.off, .off))
    #expect(await stub.requests.count == 3)
}

@MainActor
@Test func nativeMenuShowsTurnOffAndUpdatesCheckmark() async throws {
    _ = NSApplication.shared
    let isolated = "WorkLightTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: isolated))
    defer { defaults.removePersistentDomain(forName: isolated) }

    let off = report(state: "off", attributes: "{}")
    let stub = Stub([.init(json: report()), .init(json: "[\(off)]")])
    let model = configuredController(client: stub.client, defaults: defaults)
    let delegate = MenuBarDelegate(lamp: model)

    await model.refresh()
    let menu = delegate.makeMenu()
    let entry = try #require(menu.item(withTitle: "Turn Off"))
    #expect(entry.isEnabled && entry.state == .off)
    menu.performActionForItem(at: menu.index(of: entry))
    for _ in 0..<50 {
        if model.status == .ready(.off, .off) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.status == .ready(.off, .off))
    #expect(delegate.makeMenu().item(withTitle: "Turn Off")?.state == .on)
}
