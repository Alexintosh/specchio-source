import Foundation

class FrameRateController: ObservableObject {
    @Published var targetFPS: Double = 10
    @Published var actualFPS: Double = 0

    var interval: TimeInterval {
        1.0 / targetFPS
    }

    func adjustForLatency(_ latencyMs: Double) {
        // If latency is too high, reduce target FPS to avoid queuing
        if latencyMs > 200 {
            targetFPS = max(2, targetFPS - 1)
        } else if latencyMs < 50 && targetFPS < 30 {
            targetFPS = min(30, targetFPS + 1)
        }
    }
}
