import Combine
import Sparkle

@MainActor
public final class UpdateController: ObservableObject {
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = false
    private let controller: SPUStandardUpdaterController

    public init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    public func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        // 使用 Sparkle 自己持久化的偏好，避免重启时覆盖用户选择。
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
