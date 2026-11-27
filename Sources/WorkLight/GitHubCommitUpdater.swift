import AppKit
import CryptoKit
import Foundation
import SwiftUI

public struct CommitUpdateInfo: Equatable, Sendable {
    public let targetSHA: String
    public let shortSHA: String
    public let version: String
    public let commitTitle: String
    public let downloadURL: URL
    public let expectedSHA256: String?
    public let commitURL: URL
}

@MainActor
public final class GitHubCommitUpdater: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate(shortSHA: String)
        case buildPending(shortSHA: String)
        case available(CommitUpdateInfo)
        case installing(String)
        case failed(String)
    }

    private struct HeadCommitResponse: Decodable {
        struct CommitBody: Decodable {
            let message: String
        }
        let sha: String
        let commit: CommitBody
    }

    private struct LatestManifestResponse: Decodable {
        let sha: String
        let short_sha: String
        let version: String
        let commit_title: String
        let asset_url: String
        let sha256: String
    }

    @Published public private(set) var state: State = .idle

    public let repository: String
    public let bundleName: String
    public let executableName: String
    public let localCommitSHA: String?
    public let localShortSHA: String
    public let localVersion: String

    private let autoCheckDefaultsKey: String
    private let lastCheckDefaultsKey: String
    private var periodicTask: Task<Void, Never>?

    public init(repository: String, bundleName: String, executableName: String) {
        self.repository = repository
        self.bundleName = bundleName
        self.executableName = executableName
        self.autoCheckDefaultsKey = "\(executableName).autoCheckUpdates"
        self.lastCheckDefaultsKey = "\(executableName).lastUpdateCheck"

        UserDefaults.standard.register(defaults: [autoCheckDefaultsKey: true])

        let info = Bundle.main.infoDictionary
        let rawSHA = info?["GitCommitSHA"] as? String
        let normalized = Self.normalizeSHA(rawSHA)
        self.localCommitSHA = normalized
        self.localShortSHA = normalized.map { String($0.prefix(7)) } ?? "dev"
        self.localVersion = (info?["CFBundleShortVersionString"] as? String) ?? "0.1.0"

        startPeriodicChecks()
    }

    deinit {
        periodicTask?.cancel()
    }

    public var autoCheckEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoCheckDefaultsKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: autoCheckDefaultsKey)
        }
    }

    public var availableUpdate: CommitUpdateInfo? {
        if case .available(let info) = state {
            return info
        }
        return nil
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .installing:
            return true
        default:
            return false
        }
    }

    public func checkForUpdates(manual: Bool) {
        guard !isBusy else { return }
        state = .checking
        Task { @MainActor [weak self] in
            await self?.performCheck(manual: manual)
        }
    }

    public func installAvailableUpdate() {
        guard case .available(let candidate) = state else { return }
        state = .installing("Downloading \(candidate.shortSHA)…")
        Task { @MainActor [weak self] in
            await self?.performInstall(candidate: candidate)
        }
    }

    private func startPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.autoCheckEnabled {
                    await self.performCheck(manual: false)
                }
                try? await Task.sleep(nanoseconds: 6 * 3_600 * 1_000_000_000)
            }
        }
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }

    private func performCheck(manual: Bool) async {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckDefaultsKey)

        let head = await fetchHeadCommit(session: session)
        let manifest = await fetchManifest(session: session)

        if head == nil && manifest == nil {
            state = manual ? .failed("Could not reach GitHub to check for updates.") : .idle
            return
        }

        let headSHA = Self.normalizeSHA(head?.sha)
        if let localCommitSHA, let headSHA, Self.isSameCommit(localCommitSHA, headSHA) {
            state = .upToDate(shortSHA: String(headSHA.prefix(7)))
            return
        }

        if let manifest,
           let manifestSHA = Self.normalizeSHA(manifest.sha),
           let downloadURL = URL(string: manifest.asset_url),
           Self.isTrustedGitHubURL(downloadURL)
        {
            if let localCommitSHA, Self.isSameCommit(localCommitSHA, manifestSHA) {
                if let headSHA, !Self.isSameCommit(headSHA, manifestSHA) {
                    state = .buildPending(shortSHA: String(headSHA.prefix(7)))
                } else {
                    state = .upToDate(shortSHA: String(manifestSHA.prefix(7)))
                }
                return
            }

            let firstLine = head?.commit.message
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = manifest.commit_title.isEmpty ? firstLine : manifest.commit_title
            let cleanSHA256 = Self.normalizeSHA(manifest.sha256)
            let commitURL = URL(string: "https://github.com/\(repository)/commit/\(manifestSHA)") ?? downloadURL

            state = .available(
                CommitUpdateInfo(
                    targetSHA: manifestSHA,
                    shortSHA: String(manifestSHA.prefix(7)),
                    version: manifest.version,
                    commitTitle: title,
                    downloadURL: downloadURL,
                    expectedSHA256: cleanSHA256?.count == 64 ? cleanSHA256 : nil,
                    commitURL: commitURL
                )
            )
            return
        }

        if let headSHA {
            state = .buildPending(shortSHA: String(headSHA.prefix(7)))
        } else {
            state = .upToDate(shortSHA: localShortSHA)
        }
    }

    private func fetchHeadCommit(session: URLSession) async -> HeadCommitResponse? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/commits/main") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(executableName)/\(localVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(HeadCommitResponse.self, from: data)
    }

    private func fetchManifest(session: URLSession) async -> LatestManifestResponse? {
        let ts = Int(Date().timeIntervalSince1970)
        guard let url = URL(string: "https://github.com/\(repository)/releases/download/latest-main/latest-main.json?t=\(ts)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("\(executableName)/\(localVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              Self.isTrustedGitHubURL(finalURL)
        else { return nil }
        return try? JSONDecoder().decode(LatestManifestResponse.self, from: data)
    }

    private func performInstall(candidate: CommitUpdateInfo) async {
        let targetApp = Bundle.main.bundleURL.standardizedFileURL
        guard targetApp.pathExtension == "app" else {
            state = .failed("In-app update requires running from \(bundleName).")
            return
        }
        let parentDir = targetApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            NSWorkspace.shared.open(candidate.commitURL)
            state = .failed("No write permission in \(parentDir.path). Move \(bundleName) to /Applications.")
            return
        }
        guard Self.isTrustedGitHubURL(candidate.downloadURL) else {
            state = .failed("Untrusted update URL.")
            return
        }

        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(executableName.lowercased())-update-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

            var req = URLRequest(url: candidate.downloadURL)
            req.setValue("\(executableName)/\(localVersion)", forHTTPHeaderField: "User-Agent")
            let (zipData, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let finalURL = http.url,
                  Self.isTrustedGitHubURL(finalURL)
            else {
                try? FileManager.default.removeItem(at: stagingDir)
                state = .failed("Failed to download update archive.")
                return
            }

            if let expectedSHA256 = candidate.expectedSHA256 {
                let actual = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                guard actual == expectedSHA256 else {
                    try? FileManager.default.removeItem(at: stagingDir)
                    state = .failed("SHA-256 checksum mismatch.")
                    return
                }
            }

            state = .installing("Verifying & unpacking…")
            let zipURL = stagingDir.appendingPathComponent("update.zip")
            try zipData.write(to: zipURL, options: .atomic)

            let unpackDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpackDir, withIntermediateDirectories: true)
            try runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpackDir.path])

            let extractedApp = unpackDir.appendingPathComponent(bundleName, isDirectory: true)
            let execPath = extractedApp.appendingPathComponent("Contents/MacOS/\(executableName)")
            let plistPath = extractedApp.appendingPathComponent("Contents/Info.plist")

            guard FileManager.default.fileExists(atPath: execPath.path),
                  let plistData = try? Data(contentsOf: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
            else {
                try? FileManager.default.removeItem(at: stagingDir)
                state = .failed("Archive did not contain a valid \(bundleName).")
                return
            }

            if let embedded = Self.normalizeSHA(plist["GitCommitSHA"] as? String),
               !Self.isSameCommit(embedded, candidate.targetSHA)
            {
                try? FileManager.default.removeItem(at: stagingDir)
                state = .failed("Embedded commit hash mismatch.")
                return
            }

            _ = try? runTool("/usr/bin/xattr", ["-cr", extractedApp.path])
            try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", extractedApp.path])

            state = .installing("Relaunching…")
            try launchDetachedSwap(stagingDir: stagingDir, extractedApp: extractedApp, targetApp: targetApp)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.5) {
                Darwin.exit(0)
            }
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
                NSApp.terminate(nil)
            }
            CFRunLoopWakeUp(mainLoop)
        } catch {
            try? FileManager.default.removeItem(at: stagingDir)
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func runTool(_ path: String, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "GitHubCommitUpdater", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: out.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return out
    }

    private func launchDetachedSwap(stagingDir: URL, extractedApp: URL, targetApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = stagingDir.appendingPathComponent("apply_update.sh")
        let backupPath = targetApp.path + ".previous-\(pid)"

        let script = """
        #!/bin/sh
        OLD_PID="\(pid)"
        NEW_APP=\(Self.shellQuote(extractedApp.path))
        TARGET_APP=\(Self.shellQuote(targetApp.path))
        BACKUP_APP=\(Self.shellQuote(backupPath))
        STAGING_DIR=\(Self.shellQuote(stagingDir.path))

        i=0
        while kill -0 "$OLD_PID" 2>/dev/null && [ "$i" -lt 40 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        if kill -0 "$OLD_PID" 2>/dev/null; then
          kill -TERM "$OLD_PID" 2>/dev/null || true
          j=0
          while kill -0 "$OLD_PID" 2>/dev/null && [ "$j" -lt 20 ]; do
            sleep 0.1
            j=$((j + 1))
          done
        fi
        if kill -0 "$OLD_PID" 2>/dev/null; then
          kill -KILL "$OLD_PID" 2>/dev/null || true
          sleep 0.2
        fi

        rm -rf "$BACKUP_APP"
        if [ -d "$TARGET_APP" ]; then
          mv "$TARGET_APP" "$BACKUP_APP" || exit 1
        fi

        if /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then
          /usr/bin/xattr -cr "$TARGET_APP" >/dev/null 2>&1 || /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" >/dev/null 2>&1 || true
          rm -rf "$BACKUP_APP"
          /usr/bin/open -n "$TARGET_APP" || /usr/bin/open "$TARGET_APP"
          rm -rf "$STAGING_DIR"
        else
          if [ -d "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$TARGET_APP"
          fi
          exit 1
        fi
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [scriptURL.path]
        launcher.standardInput = FileHandle.nullDevice
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func normalizeSHA(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              trimmed.count >= 7,
              trimmed.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return trimmed
    }

    private static func isSameCommit(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count == rhs.count { return lhs == rhs }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "github.com"
            || host == "api.github.com"
            || host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }
}

public struct CommitUpdateRowView: View {
    @ObservedObject var updater: GitHubCommitUpdater

    public init(updater: GitHubCommitUpdater) {
        self.updater = updater
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(updater.localVersion) · commit \(updater.localShortSHA)")
                        .font(.callout)
                    statusSubtitle
                }
                Spacer()
                if let candidate = updater.availableUpdate {
                    Button("Update to \(candidate.shortSHA)") {
                        updater.installAvailableUpdate()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(updater.isBusy)
                } else {
                    Button("Check for Updates") {
                        updater.checkForUpdates(manual: true)
                    }
                    .controlSize(.small)
                    .disabled(updater.isBusy)
                }
            }
            Toggle("Check GitHub commits automatically", isOn: Binding(
                get: { updater.autoCheckEnabled },
                set: { updater.autoCheckEnabled = $0 }
            ))
            .font(.caption)
        }
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        switch updater.state {
        case .idle:
            Text("Checks the latest commit on main on GitHub.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking latest GitHub commit…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let sha):
            Text("Up to date (\(sha)).")
                .font(.caption)
                .foregroundStyle(.green)
        case .buildPending(let sha):
            Text("Commit \(sha) is building in GitHub Actions — try again in a minute.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .available(let info):
            Text(info.commitTitle.isEmpty
                ? "New commit \(info.shortSHA) available."
                : "New commit \(info.shortSHA): \(info.commitTitle)")
                .font(.caption)
                .foregroundStyle(.blue)
                .lineLimit(2)
        case .installing(let step):
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(step)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
