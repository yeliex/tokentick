import Foundation
import Sparkle
import Synchronization
import Testing
@testable import TokenTickUpdates

@MainActor
struct UpdateDiagnosticsTests {
    @Test func ignoresExpectedOutcomesAndClassifiesUpdateFailures() {
        let reported = Mutex<[(String, Int)]>([])
        let diagnostics = UpdateDiagnostics { error, operation in
            reported.withLock { $0.append((String(describing: operation), (error as NSError).code)) }
        }
        for code in [1001, 4007, 4008] {
            diagnostics.report(NSError(domain: SUSparkleErrorDomain, code: code))
        }
        diagnostics.report(URLError(.cancelled))
        #expect(reported.withLock { $0.isEmpty })
        for code in [1000, 2001, 3001, 4005] {
            diagnostics.report(NSError(domain: SUSparkleErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "private-path-and-url"]))
        }
        #expect(reported.withLock { $0.map(\.0) } == ["update.feed", "update.download", "update.validation", "update.install"])
        #expect(reported.withLock { $0.map(\.1) } == [1000, 2001, 3001, 4005])
    }
}
