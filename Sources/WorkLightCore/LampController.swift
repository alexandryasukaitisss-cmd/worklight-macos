import Foundation
import OSLog

@MainActor
public final class LampController {
    public enum Status: Equatable {
        case unconfigured
        case reading
        case ready(LampScene, LampOutput)
        case applying(LampScene)
        case problem(String)

        public var canSelect: Bool {
            switch self {
            case .ready, .problem: true
            case .unconfigured, .reading, .applying: false
            }
        }

        public var title: String {
            switch self {
            case .unconfigured: "Setup Required (Click to Configure)"
            case .reading: "Checking light…"
            case let .ready(scene, output):
                output.brightness.map { "\(scene.title) · \($0)%" } ?? scene.title
            case let .applying(scene): "Switching to \(scene.title)…"
            case let .problem(message): message
            }
        }
    }

    private struct Selection {
        var revision: String
        var scene: LampScene
        var output: LampOutput
    }

    private let light: LightTransportClient
    private let defaults: UserDefaults
    private static let settingsKey = "WorkLightSettingsV1"
    private let log = Logger(subsystem: "io.github.worklight.WorkLight", category: "Lamp")
    private var selection: Selection?
    private var generation = 0
    private var refreshing = false

    // Auto-Busy tracking state
    private var autoBusyActive = false
    private var sceneBeforeAutoBusy: LampScene?
    private var manuallyOverriddenDuringCall = false

    public private(set) var settings: LampSettings
    public private(set) var isCallActive = false
    public private(set) var status: Status {
        didSet { if status != oldValue { onChange?() } }
    }
    public var onChange: (() -> Void)?

    public init(
        light: LightTransportClient = HomeAssistantLight(),
        defaults: UserDefaults = .standard
    ) {
        self.light = light
        self.defaults = defaults
        let loaded = LampSettings.read(defaults.data(forKey: Self.settingsKey))
        self.settings = loaded
        self.status = loaded.endpoint.isConfigured ? .reading : .unconfigured
    }

    public func save(_ newSettings: LampSettings) {
        guard newSettings.isValid, let data = try? JSONEncoder().encode(newSettings) else { return }
        let endpointChanged = newSettings.endpoint != settings.endpoint
        defaults.set(data, forKey: Self.settingsKey)
        self.settings = newSettings
        if !newSettings.autoBusyOnMicrophone {
            autoBusyActive = false
            sceneBeforeAutoBusy = nil
            manuallyOverriddenDuringCall = false
        }
        if !newSettings.endpoint.isConfigured {
            selection = nil
            status = .unconfigured
        } else if endpointChanged || status == .unconfigured {
            selection = nil
            status = .reading
        }
        onChange?()
    }

    public func refresh() async {
        guard settings.endpoint.isConfigured else {
            status = .unconfigured
            return
        }
        if case .applying = status { return }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let version = generation
        do {
            let report = try await light.read(endpoint: settings.endpoint)
            guard !Task.isCancelled, version == generation else { return }
            if let selection, report.revision == selection.revision {
                status = .ready(selection.scene, selection.output)
                return
            }
            guard let output = report.output else {
                status = .problem("Light state could not be confirmed")
                return
            }
            if let selection, output.matches(selection.output) {
                self.selection?.revision = report.revision
                status = .ready(selection.scene, output)
            } else {
                selection = nil
                status = .ready(settings.scene(for: output), output)
            }
        } catch {
            guard !Task.isCancelled, version == generation else { return }
            status = .problem(error.localizedDescription)
        }
    }

    public func toggle() async {
        guard case let .ready(scene, _) = status else { return }
        await select(scene == .busy ? .free : .busy, initiatedByUser: true)
    }

    public func select(_ scene: LampScene, initiatedByUser: Bool = true) async {
        guard settings.endpoint.isConfigured else {
            status = .unconfigured
            return
        }
        guard status.canSelect else { return }
        if initiatedByUser && isCallActive {
            manuallyOverriddenDuringCall = true
            autoBusyActive = false
            sceneBeforeAutoBusy = nil
        }
        let output = settings.output(for: scene)
        if case .ready(scene, output) = status { return }
        generation += 1
        status = .applying(scene)
        let start = Date()
        do {
            let report = try await light.apply(output, endpoint: settings.endpoint)
            selection = Selection(revision: report.revision, scene: scene, output: output)
            status = .ready(scene, output)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            log.info("Confirmed \(scene.title, privacy: .public) in \(elapsed) ms")
        } catch {
            selection = nil
            status = .problem(error.localizedDescription)
            log.error("Light command was not confirmed")
        }
    }

    /// Processes a debounced microphone activity update.
    /// Automatically flips the light to Busy when a call starts, and restores
    /// the configured return scene once the call ends (unless manually overridden).
    public func handleCallActivityChanged(active: Bool) async {
        let wasActive = isCallActive
        isCallActive = active

        guard settings.autoBusyOnMicrophone, settings.endpoint.isConfigured else {
            if !active {
                autoBusyActive = false
                sceneBeforeAutoBusy = nil
                manuallyOverriddenDuringCall = false
            }
            return
        }

        if active && !wasActive {
            manuallyOverriddenDuringCall = false
            guard case let .ready(currentScene, _) = status else { return }
            if currentScene != .busy {
                sceneBeforeAutoBusy = currentScene
                autoBusyActive = true
                await select(.busy, initiatedByUser: false)
            }
        } else if !active && wasActive {
            defer {
                autoBusyActive = false
                sceneBeforeAutoBusy = nil
                manuallyOverriddenDuringCall = false
            }
            guard autoBusyActive, !manuallyOverriddenDuringCall else { return }
            let target: LampScene
            switch settings.callReturnBehavior {
            case .previous:
                target = sceneBeforeAutoBusy ?? .free
            case .free:
                target = .free
            case .normal:
                target = .normal
            case .off:
                target = .off
            }
            await select(target, initiatedByUser: false)
        }
    }
}
