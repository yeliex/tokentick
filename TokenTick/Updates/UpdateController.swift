import Combine
import Sparkle

@MainActor
public final class UpdateController: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = false
    #if !DEBUG
    private let diagnostics: UpdateDiagnostics
    private let controller: SPUStandardUpdaterController
    #endif

    public init(onFailure: @escaping @Sendable (any Error, StaticString) -> Void = { _, _ in }) {
        #if !DEBUG
        diagnostics = UpdateDiagnostics(onFailure: onFailure)
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: diagnostics,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        #endif
    }

    public func checkForUpdates() {
        #if !DEBUG
        controller.checkForUpdates(nil)
        #endif
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        #if !DEBUG
        // Use Sparkle's persisted preference to avoid overwriting the user's choice on restart.
        controller.updater.automaticallyChecksForUpdates = enabled
        #endif
    }
}

/// Keep Sparkle-specific filtering here; the app owns telemetry submission.
final class UpdateDiagnostics: NSObject, SPUUpdaterDelegate {
    private let onFailure: @Sendable (any Error, StaticString) -> Void

    init(onFailure: @escaping @Sendable (any Error, StaticString) -> Void) {
        self.onFailure = onFailure
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        report(error)
    }

    func report(_ error: any Error) {
        let value = error as NSError
        if value.domain == SUSparkleErrorDomain {
            guard ![SUError.noUpdateError, SUError.installationCanceledError, SUError.installationAuthorizeLaterError]
                .contains(where: { Int($0.rawValue) == value.code }) else { return }
        }
        guard !(value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled) else { return }
        let operation: StaticString
        switch value.domain == SUSparkleErrorDomain ? value.code : -1 {
        case 0..<1000: operation = "update.configuration"
        case 1000..<2000: operation = "update.feed"
        case 2000..<3000: operation = "update.download"
        case 3000..<4000: operation = "update.validation"
        case 4000..<5000: operation = "update.install"
        default: operation = "update.check"
        }
        onFailure(error, operation)
    }
}
