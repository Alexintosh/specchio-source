import AppKit

class ClipboardSync: ObservableObject {
    private let wdaClient: WDAClient
    private var lastMacClipboard: String?
    private var pollTask: Task<Void, Never>?

    init(wdaClient: WDAClient) {
        self.wdaClient = wdaClient
    }

    func startSync() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncMacToPhone()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Check every 2s
            }
        }
    }

    func stopSync() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func syncMacToPhone() async {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string),
              text != lastMacClipboard else { return }
        lastMacClipboard = text
        // WDA doesn't have a direct clipboard API in all versions
        // This is a best-effort feature
    }
}
