import AppKit
import CcinnMongoKit
import Observation
import os

/// Drives update checks and downloads for the whole app (design D5/D6): one state machine, generation
/// tokens so late results never overwrite newer state, and a silent daily check after launch.
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        /// `latest` is nil when the repository has no release yet.
        case upToDate(latest: String?)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case downloaded(ReleaseInfo, file: URL)
        case failed(String, release: ReleaseInfo?)
    }

    private(set) var phase: Phase = .idle
    /// Incremented whenever the Software Update window should come to the front.
    private(set) var windowRequest = 0
    private(set) var lastCheck: Date?

    private enum Keys {
        static let automatic = "updates.automaticallyCheck"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
    }

    private let defaults: UserDefaults
    private let client: any UpdateHTTPClient
    private var generation = 0
    private var work: Task<Void, Never>?
    private var scheduledAutomaticCheck = false
    private let log = Logger(subsystem: "io.github.whiteccinn.ccinnmongo", category: "updates")

    init(defaults: UserDefaults = .standard, client: any UpdateHTTPClient = URLSessionUpdateClient()) {
        self.defaults = defaults
        self.client = client
        defaults.register(defaults: [Keys.automatic: true])
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    static var automaticCheckKey: String { Keys.automatic }

    /// The version compared against releases (`--pretend-version` lets snapshots show the "available" state).
    var currentVersion: SemanticVersion {
        LaunchArguments.value("--pretend-version").flatMap(SemanticVersion.init) ?? AppInfo.semanticVersion
    }

    var skippedVersion: String? { defaults.string(forKey: Keys.skipped) }

    // MARK: Checking

    /// Checks GitHub now. A manual check always ends visibly; an automatic one only surfaces a new,
    /// not-skipped version.
    func checkForUpdates(automatic: Bool) {
        if !automatic { windowRequest &+= 1 }
        switch phase {
        case .checking, .downloading:
            return // Already working; a manual request just brings the window forward.
        default:
            break
        }
        generation &+= 1
        let token = generation
        phase = .checking
        let checker = UpdateChecker(repository: AppInfo.repository, currentVersion: currentVersion, client: client)
        work = Task { [weak self] in
            let outcome: Result<UpdateCheckResult, UpdateError>
            do {
                outcome = .success(try await checker.check())
            } catch let error as UpdateError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(UpdateError(.network, error.localizedDescription))
            }
            self?.finishCheck(outcome, token: token, automatic: automatic)
        }
    }

    private func finishCheck(_ outcome: Result<UpdateCheckResult, UpdateError>, token: Int, automatic: Bool) {
        guard token == generation else { return }
        if case .failure(let error) = outcome, error.kind == .cancelled {
            phase = .idle
            return
        }
        recordCheck()
        switch outcome {
        case .success(.available(let release)):
            if UpdateSchedule.shouldPresent(release.version, skipped: skippedVersion, automatic: automatic) {
                phase = .available(release)
                if automatic { windowRequest &+= 1 }
            } else {
                phase = .idle
            }
        case .success(.upToDate(let release)):
            phase = automatic ? .idle : .upToDate(latest: release.version.description)
        case .success(.noReleases):
            phase = automatic ? .idle : .upToDate(latest: nil)
        case .failure(let error):
            if automatic {
                log.notice("Automatic update check failed: \(error.message, privacy: .public)")
                phase = .idle
            } else {
                phase = .failed(error.message, release: nil)
            }
        }
    }

    private func recordCheck() {
        let now = Date()
        lastCheck = now
        defaults.set(now, forKey: Keys.lastCheck)
    }

    /// Once per process, 8 s after launch, when due and allowed (never in snapshot or test launches).
    func scheduleAutomaticCheck() {
        guard !scheduledAutomaticCheck, !Self.automaticChecksDisabledForThisLaunch else { return }
        scheduledAutomaticCheck = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, UpdateSchedule.isDue(now: Date(), lastCheck: lastCheck, enabled: defaults.bool(forKey: Keys.automatic)) else { return }
            if case .idle = phase { checkForUpdates(automatic: true) }
        }
    }

    static var automaticChecksDisabledForThisLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--snapshot") || arguments.contains("--no-update-check")
            || ProcessInfo.processInfo.environment["CCINNMONGO_DISABLE_UPDATE_CHECK"] == "1"
    }

    // MARK: Actions

    func download(_ release: ReleaseInfo) {
        generation &+= 1
        let token = generation
        phase = .downloading(release, progress: 0)
        let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let downloader = UpdateDownloader(repository: AppInfo.repository, client: client, destination: destination)
        let throttle = ProgressThrottle()
        // The controller lives for the whole process, so the download may hold it strongly.
        let controller = self
        work = Task {
            let outcome: Result<URL, UpdateError>
            do {
                let file = try await downloader.download(release) { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor in controller.reportProgress(fraction, release: release, token: token) }
                }
                outcome = .success(file)
            } catch let error as UpdateError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(UpdateError(.network, error.localizedDescription))
            }
            controller.finishDownload(outcome, release: release, token: token)
        }
    }

    private func reportProgress(_ fraction: Double, release: ReleaseInfo, token: Int) {
        guard token == generation, case .downloading = phase else { return }
        phase = .downloading(release, progress: fraction)
    }

    private func finishDownload(_ outcome: Result<URL, UpdateError>, release: ReleaseInfo, token: Int) {
        guard token == generation else { return }
        switch outcome {
        case .success(let file):
            phase = .downloaded(release, file: file)
            NSWorkspace.shared.open(file)
        case .failure(let error) where error.kind == .cancelled:
            phase = .available(release)
        case .failure(let error):
            phase = .failed(error.message, release: release)
        }
    }

    func cancel() {
        work?.cancel()
    }

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version.description, forKey: Keys.skipped)
        generation &+= 1
        phase = .idle
    }

    /// Forget a finished result so the next time the window opens it checks again.
    func reset() {
        switch phase {
        case .checking, .downloading: return
        default:
            generation &+= 1
            phase = .idle
        }
    }
}

/// Lets through progress updates of at least 1 % (the download delegate reports every chunk).
private final class ProgressThrottle: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: -1.0)

    func shouldReport(_ fraction: Double) -> Bool {
        last.withLock { last in
            guard fraction >= 1 || fraction - last >= 0.01 else { return false }
            last = fraction
            return true
        }
    }
}

/// The standard About panel, with the project link in the credits (design D8).
@MainActor
enum AboutPanel {
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        let credits = NSMutableAttributedString(string: "A fast, native MongoDB client for macOS.\n", attributes: body)
        var link = body
        link[.link] = AppInfo.links.repository
        credits.append(NSAttributedString(string: "github.com/\(AppInfo.repository.owner)/\(AppInfo.repository.name)", attributes: link))
        credits.append(NSAttributedString(string: "\nMIT License · © 2026 whiteCcinn", attributes: body))
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationVersion: AppInfo.version,
            .version: "",
        ])
        NSApp.activate()
    }
}
