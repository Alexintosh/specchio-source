import UIKit
import os.log

final class KeyboardViewController: UIInputViewController {

    // MARK: - Private state

    private let inputServer = InputServer()
    private var statusDot: UILabel!
    private var debugLabel: UILabel!
    private var isConnected = false

    private let log = OSLog(subsystem: "com.alexintosh.SpecchioKeyboard", category: "Keyboard")

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        os_log("[Keyboard] viewDidLoad", log: log, type: .info)
        buildStatusBar()
        wireInputServer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        os_log("[Keyboard] viewWillAppear — starting InputServer", log: log, type: .info)
        inputServer.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        os_log("[Keyboard] viewDidDisappear — stopping InputServer", log: log, type: .info)
        inputServer.stop()
    }

    // MARK: - Status bar UI

    private func buildStatusBar() {
        // Constrain keyboard to minimal height (just the status bar)
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 30)
        heightConstraint.priority = .required
        heightConstraint.isActive = true

        let statusBar = UIView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.backgroundColor = UIColor.systemBackground

        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: view.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // "Specchio" label
        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.text = "Specchio"
        nameLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = UIColor.label

        // Status dot: colored by connection state
        statusDot = UILabel()
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.text = "\u{25CF}" // ●
        statusDot.font = UIFont.systemFont(ofSize: 10)
        statusDot.textColor = UIColor.systemGray

        // Debug label: shows current state for diagnostics
        debugLabel = UILabel()
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        debugLabel.text = ""
        debugLabel.font = UIFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        debugLabel.textColor = UIColor.systemGray
        debugLabel.lineBreakMode = .byWordWrapping
        debugLabel.numberOfLines = 2

        // Layout: [Specchio ●] left, [debug status] right
        let leftStack = UIStackView(arrangedSubviews: [nameLabel, statusDot])
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.axis = .horizontal
        leftStack.spacing = 6
        leftStack.alignment = .center

        statusBar.addSubview(leftStack)
        statusBar.addSubview(debugLabel)
        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            debugLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            debugLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            debugLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leftStack.trailingAnchor, constant: 8),
        ])

        // Separator line at the bottom of the status bar
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor.separator
        statusBar.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])

        updateConnectionDot(connected: false)
    }

    private func updateConnectionDot(connected: Bool) {
        isConnected = connected
        statusDot.textColor = connected ? UIColor.systemGreen : UIColor.systemGray
        os_log("[Keyboard] connection dot updated — connected=%{public}@",
               log: log, type: .info, connected ? "YES" : "NO")
    }

    // MARK: - InputServer wiring

    private func wireInputServer() {
        inputServer.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async {
                self?.updateConnectionDot(connected: connected)
            }
        }

        inputServer.onCommand = { [weak self] command in
            guard let self else { return }
            DispatchQueue.main.async {
                self.handleCommand(command)
            }
        }

        // Debug status for on-screen diagnostics (CLAUDE.md: observability)
        inputServer.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.debugLabel.text = status
            }
        }
    }

    // MARK: - Command dispatch

    private func handleCommand(_ command: InputCommand) {
        switch command {
        case .insert(let text):
            os_log("[Keyboard] insert: %{public}@", log: log, type: .debug, text)
            textDocumentProxy.insertText(text)

        case .delete(let count):
            os_log("[Keyboard] delete: %d", log: log, type: .debug, count)
            for _ in 0..<count {
                textDocumentProxy.deleteBackward()
            }

        case .move(let offset):
            os_log("[Keyboard] move: %d", log: log, type: .debug, offset)
            textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)

        case .paste:
            if let content = UIPasteboard.general.string {
                os_log("[Keyboard] paste: %d chars", log: log, type: .debug, content.count)
                textDocumentProxy.insertText(content)
            } else {
                os_log("[Keyboard] paste: clipboard empty", log: log, type: .debug)
            }
        }
    }
}
