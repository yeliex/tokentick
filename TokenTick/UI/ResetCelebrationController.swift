import AppKit
import SwiftUI

/// CodexBar-style, click-through overlays: the primary display, no activation, and a bounded lifetime.
@MainActor
final class ResetCelebrationController {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func play(_ method: ResetReminderController.Method) {
        // The first screen owns the system menu bar; NSScreen.main follows the focused window instead.
        guard panel == nil, let screen = NSScreen.screens.first else { return }
        let panel = CelebrationPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CelebrationView(method: method))
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private final class CelebrationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CelebrationView: View {
    let method: ResetReminderController.Method
    @State private var startedAt = Date()
    @State private var pieces = (0..<220).map { _ in ConfettiPiece() }
    private let colors: [Color] = [.mint, .yellow, .orange, .pink, .cyan, .purple]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                if method == .confetti { confetti(context: context, size: size, time: elapsed) }
                else { fireworks(context: context, size: size, time: elapsed) }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func confetti(context: GraphicsContext, size: CGSize, time: Double) {
        let scale = min(1.4, max(0.8, min(size.width, size.height) / 900))
        for piece in pieces {
            let t = time - piece.delay
            guard t >= 0, t < piece.lifetime else { continue }
            // Air resistance slows the initial burst; gravity approaches a gentle terminal fall speed.
            let travel = (1 - exp(-piece.drag * t)) / piece.drag
            let flutter = sin(t * piece.flutterRate + piece.phase) - sin(piece.phase)
            let drift = flutter * piece.sway * (1 - exp(-t * 2))
            let x = size.width / 2 + (cos(piece.angle) * piece.speed * travel + drift) * scale
            let y = size.height / 2 + ((sin(piece.angle) * piece.speed - 160) * travel
                + piece.fallSpeed * (t - travel)) * scale
            let tumble = cos(piece.phase + t * piece.flutterRate)
            var particle = context
            particle.opacity = min(1, max(0, (piece.lifetime - t) / 0.55)) * (0.7 + 0.3 * abs(tumble))
            particle.translateBy(x: x, y: y)
            particle.rotate(by: .radians(piece.phase + piece.spin * (0.35 * t + 0.65 * travel)))
            particle.scaleBy(x: 1, y: max(0.08, abs(tumble)))
            let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2,
                              width: piece.width, height: piece.height)
            particle.fill(Path(roundedRect: rect, cornerRadius: 0.8), with: .color(colors[piece.color]))
        }
    }

    private func fireworks(context: GraphicsContext, size: CGSize, time: Double) {
        for burst in 0..<6 {
            let t = time - Double(burst) * 0.22
            guard t >= 0, t < 1.8 else { continue }
            let destination = CGPoint(x: size.width * (0.22 + Double(burst * 17 % 60) / 100),
                                      y: size.height * (0.18 + Double(burst * 13 % 32) / 100))
            let age = t
            for spark in 0..<64 {
                let angle = Double(spark) * .pi * 2 / 64
                let speed = Double(100 + spark * 37 % 150)
                let distance = speed * (1 - exp(-age * 2.4))
                let position = CGPoint(x: destination.x + cos(angle) * distance,
                                       y: destination.y + sin(angle) * distance + 45 * age * age)
                var particle = context
                particle.opacity = max(0, 1 - age / 1.8)
                var trail = Path()
                trail.move(to: CGPoint(x: position.x - cos(angle) * 12, y: position.y - sin(angle) * 12))
                trail.addLine(to: position)
                particle.stroke(trail, with: .color(colors[burst]), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                particle.fill(Path(ellipseIn: CGRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)),
                              with: .color(.white))
            }
        }
    }
}

/// Sample once per celebration so flutter and depth vary without introducing frame-to-frame jitter.
private struct ConfettiPiece {
    let angle = Double.random(in: 0..<(2 * .pi))
    let speed = Double.random(in: 350...1150)
    let drag = Double.random(in: 1.5...2.8)
    let fallSpeed = Double.random(in: 150...280)
    let phase = Double.random(in: 0..<(2 * .pi))
    let spin = Double.random(in: -10...10)
    let flutterRate = Double.random(in: 5...11)
    let sway = Double.random(in: 12...36)
    let width = Double.random(in: 5...9)
    let height = Double.random(in: 9...16)
    let delay = Double.random(in: 0...0.06)
    let lifetime = Double.random(in: 2.3...2.9)
    let color = Int.random(in: 0..<6)
}
