import Combine
import TTYBuildKit
import UIKit

/// Per-computer page pushed from Settings: connection info, remote
/// coding-agent hook management, desktop update check/install, and unbind.
///
/// All hook/update traffic is request/reply ctl frames correlated by a random
/// `req` tag (PROTOCOL.md §5). A daemon older than these kinds silently drops
/// them, so each request arms a timeout that flips the section into an
/// "update the Mac" note instead of hanging forever.
@MainActor
final class ComputerDetailViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case computer
        case agents
        case updates
        case unbind
    }

    private static let requestTimeout: Duration = .seconds(5)
    /// Update requests wait for the Mac to finish a full Sparkle appcast
    /// probe before replying, which routinely outlives the hooks timeout.
    private static let updateRequestTimeout: Duration = .seconds(20)

    private let services: AppServices
    private let computerID: String
    private var cancellables: Set<AnyCancellable> = []

    private var hookStates: [HookStateInfo]?
    private var updateInfo: UpdateStatusInfo?
    /// True once a request went unanswered; the daemon predates remote
    /// hook/update management.
    private var hooksUnsupported = false
    private var updatesUnsupported = false
    private var actionError: String?

    private var pendingHooksReq: UInt32?
    private var pendingUpdateReq: UInt32?
    /// Agent slugs with an install/uninstall in flight.
    private var busyAgents: Set<String> = []

    /// Why the in-flight update request was sent: a silent page-load refresh
    /// (fills the Version row), or a user-facing check/install whose result
    /// lands in the update sheet.
    private enum UpdateRequestKind { case background, check, install }
    private var updateRequestKind: UpdateRequestKind = .background
    private weak var updateSheet: UpdateCheckViewController?

    init(services: AppServices, computerID: String) {
        self.services = services
        self.computerID = computerID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var computer: ComputerConnection? {
        services.terminals.computer(id: computerID)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = computer?.displayName ?? "Computer"
        view.tintColor = TTYBuildTheme.uiContent

        computer?.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event: event) }
            .store(in: &cancellables)

        // Re-request only on an offline→online transition (the initial load
        // is viewWillAppear's job); pop when unbound.
        if let computer {
            var wasOnline = computer.hostOnline
            computer.$hostOnline
                .combineLatest(computer.$hostName)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] online, name in
                    guard let self else { return }
                    if let name, !name.isEmpty { title = name }
                    if online, !wasOnline { refreshRemoteState() }
                    wasOnline = online
                    reloadSections(.computer)
                }
                .store(in: &cancellables)
        }
        services.terminals.$computers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.computer == nil else { return }
                self.navigationController?.popViewController(animated: true)
            }
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshRemoteState()
    }

    // MARK: - Requests

    /// Sends fresh `hooks-status` + `update-status` requests (no-ops while
    /// the host is offline — the frames would queue pointlessly).
    private func refreshRemoteState() {
        guard computer?.hostOnline == true else { return }
        requestHooksStatus()
        updateRequestKind = .background
        requestUpdateStatus()
    }

    private func requestHooksStatus() {
        let req = UInt32.random(in: 1...UInt32.max)
        pendingHooksReq = req
        computer?.requestHooksStatus(req: req)
        armHooksTimeout(req: req)
    }

    private func requestUpdateStatus() {
        let req = UInt32.random(in: 1...UInt32.max)
        pendingUpdateReq = req
        computer?.requestUpdateStatus(req: req)
        armUpdateTimeout(req: req)
    }

    private func armHooksTimeout(req: UInt32) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard let self, !Task.isCancelled, pendingHooksReq == req else { return }
            pendingHooksReq = nil
            hooksUnsupported = hookStates == nil
            busyAgents.removeAll()
            reloadSections(.agents)
        }
    }

    private func armUpdateTimeout(req: UInt32) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.updateRequestTimeout)
            guard let self, !Task.isCancelled, pendingUpdateReq == req else { return }
            pendingUpdateReq = nil
            let kind = updateRequestKind
            updateRequestKind = .background
            updatesUnsupported = updateInfo == nil
            reloadSections(.updates)
            if kind != .background {
                updateSheet?.show(.failed(
                    title: kind == .install ? "Update Failed" : "Update Check Failed",
                    message: "No reply from the Mac. It may be running an older tty.build — update it there to manage updates from here."
                ))
            }
        }
    }

    // MARK: - Replies

    private func handle(event: ComputerConnection.Event) {
        switch event {
        case .hooksStatus(let list, let req):
            guard req == pendingHooksReq else { return }
            pendingHooksReq = nil
            hooksUnsupported = false
            actionError = nil
            hookStates = list
            busyAgents.removeAll()
            reloadSections(.agents)
        case .updateStatus(let info, let req):
            guard req == pendingUpdateReq else { return }
            pendingUpdateReq = nil
            updatesUnsupported = false
            updateInfo = info
            let kind = updateRequestKind
            updateRequestKind = .background
            reloadSections(.computer, .updates)
            presentUpdateResult(info, kind: kind)
        case .error(let msg, let req):
            if req == pendingHooksReq {
                pendingHooksReq = nil
                busyAgents.removeAll()
                actionError = msg
                reloadSections(.agents)
            } else if req == pendingUpdateReq {
                pendingUpdateReq = nil
                let kind = updateRequestKind
                updateRequestKind = .background
                // Background refreshes fail quietly (headless daemons answer
                // update-status with err); user-driven ones land in the sheet.
                if kind != .background {
                    updateSheet?.show(.failed(
                        title: kind == .install ? "Update Failed" : "Update Check Failed",
                        message: msg
                    ))
                }
            }
        case .created, .exit, .offline:
            break
        }
    }

    // MARK: - Table structure

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .computer: "Computer"
        case .agents: "Coding Agents"
        case .updates: "Updates"
        case .unbind: nil
        }
    }

    override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .agents:
            if hooksUnsupported {
                return "This Mac runs an older tty.build without remote hook management. Update tty.build on the Mac to manage hooks from here."
            }
            return actionError
        case .updates:
            if updatesUnsupported {
                return "This Mac runs an older tty.build without remote updates. Update tty.build on the Mac to check for updates from here."
            }
            return nil
        case .computer, .unbind:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .computer:
            return 2
        case .agents:
            guard let hookStates, !hookStates.isEmpty else { return 1 }
            return hookStates.count
        case .updates:
            return 1
        case .unbind:
            return 1
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .computer: computerCell(row: indexPath.row)
        case .agents: agentCell(row: indexPath.row)
        case .updates: updateCell()
        case .unbind: unbindCell()
        }
    }

    // MARK: - Cells

    private func valueCell(_ text: String, _ detail: String?) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        content.text = text
        content.secondaryText = detail
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func computerCell(row: Int) -> UITableViewCell {
        if row == 0 {
            return valueCell("Status", statusText())
        }
        return valueCell("Version", updateInfo?.current ?? "—")
    }

    private func statusText() -> String {
        guard let computer else { return "Unbound" }
        if computer.directoryKnown, !computer.hostOnline { return "Offline" }
        switch computer.linkState {
        case .idle: return "Disconnected"
        case .connecting(let attempt):
            return attempt == 0 ? "Connecting…" : "Reconnecting (attempt \(attempt))…"
        case .connected:
            let rtt = computer.roundTripTime.map { " · \(Int(($0 * 1000).rounded())) ms" } ?? ""
            return "Connected · E2EE" + rtt
        }
    }

    /// Mirrors the Mac Coding Agents panel: brand mark + name/hook-path
    /// detail on the left, install-state control on the right.
    private func agentCell(row: Int) -> UITableViewCell {
        guard let hookStates, row < hookStates.count else {
            return valueCell(
                hooksUnsupported ? "Unavailable" : "Checking…", nil
            )
        }
        let entry = hookStates[row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = Self.agentName(entry.agent)
        content.secondaryText = Self.agentDetail(entry.agent) ?? Self.stateText(entry.state)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
        content.textToSecondaryTextVerticalPadding = 2
        if let asset = HomeViewController.agentAssetName(entry.agent) {
            content.image = UIImage(named: asset)
            content.imageProperties.maximumSize = CGSize(width: 24, height: 24)
            content.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
            content.imageProperties.tintColor = TTYBuildTheme.uiContent
        }
        cell.contentConfiguration = content
        cell.accessoryView = agentAccessory(for: entry)
        cell.selectionStyle = .none
        return cell
    }

    /// Right-side control matching the Mac panel: a spinner while a request
    /// is in flight, an "Installed" pull-down (Reinstall/Uninstall) once
    /// installed, otherwise an Install/Update button.
    private func agentAccessory(for entry: HookStateInfo) -> UIView {
        if busyAgents.contains(entry.agent) {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            return spinner
        }
        let button = UIButton(type: .system)
        switch entry.state {
        case "installed":
            var config = UIButton.Configuration.plain()
            config.title = "Installed"
            config.image = UIImage(systemName: "checkmark.circle.fill")
            config.imagePadding = 4
            config.baseForegroundColor = TTYBuildTheme.uiSuccess
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                textStyle: .subheadline
            )
            config.buttonSize = .small
            config.indicator = .popup
            button.configuration = config
            button.menu = UIMenu(children: [
                UIAction(title: "Reinstall") { [weak self] _ in
                    self?.installHook(entry.agent)
                },
                UIAction(title: "Uninstall", attributes: .destructive) { [weak self] _ in
                    self?.uninstallHook(entry.agent)
                },
            ])
            button.showsMenuAsPrimaryAction = true
        case "outdated":
            button.configuration = Self.installButtonConfiguration(title: "Update…")
            button.addAction(
                UIAction { [weak self] _ in self?.installHook(entry.agent) },
                for: .primaryActionTriggered
            )
        default:
            button.configuration = Self.installButtonConfiguration(title: "Install…")
            button.addAction(
                UIAction { [weak self] _ in self?.installHook(entry.agent) },
                for: .primaryActionTriggered
            )
        }
        button.sizeToFit()
        return button
    }

    private static func installButtonConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.buttonSize = .small
        config.cornerStyle = .capsule
        config.baseForegroundColor = TTYBuildTheme.uiContent
        return config
    }

    /// Single action row; checking, results, and installing all happen in
    /// the update sheet, mirroring the Mac's Sparkle dialog flow.
    private func updateCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Check for Updates…"
        content.textProperties.color = TTYBuildTheme.uiContent
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    private func unbindCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Unbind Computer"
        content.textProperties.color = .systemRed
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .agents:
            break
        case .updates:
            beginUpdateCheck()
        case .unbind:
            confirmUnbind()
        case .computer:
            break
        }
    }

    // MARK: - Actions

    private func installHook(_ agent: String) {
        let req = UInt32.random(in: 1...UInt32.max)
        pendingHooksReq = req
        busyAgents.insert(agent)
        actionError = nil
        computer?.installHook(agent: agent, req: req)
        armHooksTimeout(req: req)
        reloadSections(.agents)
    }

    private func uninstallHook(_ agent: String) {
        let req = UInt32.random(in: 1...UInt32.max)
        pendingHooksReq = req
        busyAgents.insert(agent)
        actionError = nil
        computer?.uninstallHook(agent: agent, req: req)
        armHooksTimeout(req: req)
        reloadSections(.agents)
    }

    /// Presents the Sparkle-style sheet and sends a user-facing
    /// `update-status` request whose result lands in it.
    private func beginUpdateCheck() {
        let host = computer?.displayName ?? "the Mac"
        let sheet = UpdateCheckViewController()
        sheet.onInstall = { [weak self] in self?.sendInstallUpdate() }
        updateSheet = sheet
        guard computer?.hostOnline == true else {
            sheet.show(.failed(
                title: "Update Check Failed",
                message: "\(host) is offline."
            ))
            present(sheet, animated: true)
            return
        }
        sheet.show(.checking(host: host))
        present(sheet, animated: true)
        updateRequestKind = .check
        requestUpdateStatus()
    }

    private func sendInstallUpdate() {
        guard let computer, computer.hostOnline else { return }
        updateRequestKind = .install
        let req = UInt32.random(in: 1...UInt32.max)
        pendingUpdateReq = req
        computer.installUpdate(req: req)
        armUpdateTimeout(req: req)
        updateSheet?.show(.installing(host: computer.displayName))
    }

    /// Routes a user-facing `update-status` reply into the sheet. Dismissing
    /// the sheet mid-flight quietly downgrades the reply to a background
    /// refresh (it still fills the Version row).
    private func presentUpdateResult(_ info: UpdateStatusInfo?, kind: UpdateRequestKind) {
        guard kind != .background, let sheet = updateSheet else { return }
        let host = computer?.displayName ?? "the Mac"
        guard let info else {
            sheet.show(.failed(
                title: "Update Check Failed",
                message: "The Mac sent an empty update status."
            ))
            return
        }
        switch kind {
        case .check:
            if info.updateAvailable {
                sheet.show(.available(
                    current: info.current, latest: info.latest,
                    host: host, canInstall: info.canInstall
                ))
            } else if let detail = info.detail {
                // e.g. "update check failed: …" or "an update session is
                // already in progress" straight from the Mac.
                sheet.show(.failed(title: "Update Check Failed", message: detail))
            } else {
                sheet.show(.upToDate(version: info.current))
            }
        case .install:
            if info.updateAvailable {
                // Older Macs describe what they did in `detail` ("the updater
                // was opened on this Mac"); current ones install silently and
                // send no detail.
                sheet.show(.started(
                    message: info.detail ?? """
                        \(host) is downloading the update and will install it \
                        automatically. TTYBuild there restarts when it finishes.
                        """
                ))
            } else if let detail = info.detail {
                sheet.show(.failed(title: "Update Failed", message: detail))
            } else {
                // The re-check on the Mac found nothing to install.
                sheet.show(.upToDate(version: info.current))
            }
        case .background:
            break
        }
    }

    private func confirmUnbind() {
        guard let computer else { return }
        let alert = UIAlertController(
            title: "Unbind “\(computer.displayName)”?",
            message: "Its terminals disappear from this device and the stored key is removed. Sessions keep running on the computer.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unbind", style: .destructive) { [weak self] _ in
            self?.unbind()
        })
        present(alert, animated: true)
    }

    private func unbind() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await services.terminals.removeComputer(id: computerID)
                // The $computers sink pops this page once the binding is gone.
            } catch {
                let alert = UIAlertController(
                    title: "TTYBuild Service Error",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }

    // MARK: - Helpers

    private func reloadSections(_ sections: Section...) {
        guard isViewLoaded else { return }
        tableView.reloadSections(
            IndexSet(sections.map(\.rawValue)), with: .none
        )
    }

    /// Matches the menu bar app's Coding Agents panel names.
    private static func agentName(_ slug: String) -> String {
        switch slug {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "copilot": "Copilot CLI"
        case "grok": "Grok"
        case "hermes": "Hermes"
        case "kimi": "Kimi Code"
        case "kiro": "Kiro"
        case "omp": "Oh My Pi"
        case "opencode": "OpenCode"
        case "pi": "Pi"
        default: slug
        }
    }

    /// Matches the menu bar app's detail lines: names exactly what gets
    /// written where on the Mac — keep it honest.
    private static func agentDetail(_ slug: String) -> String? {
        switch slug {
        case "claude": "Hooks in ~/.claude/settings.json."
        case "codex": "Hooks in ~/.codex/hooks.json; enables the hooks feature in ~/.codex/config.toml."
        case "copilot": "Hook file in ~/.copilot/hooks/ttybuild.json."
        case "grok": "Hook file in ~/.grok/hooks/ttybuild.json."
        case "hermes": "Plugin in ~/.hermes/plugins/ttybuild-presence/."
        case "kimi": "Hooks in ~/.kimi-code/config.toml."
        case "kiro": "Hooks in ~/.kiro/agents/kiro_default.json. Requires Kiro CLI 2."
        case "omp": "Extension in ~/.omp/agent/extensions/ttybuild/."
        case "opencode": "Plugin in ~/.config/opencode/plugins/ttybuild-presence.js."
        case "pi": "Extension in ~/.pi/agent/extensions/ttybuild/."
        default: nil
        }
    }

    private static func stateText(_ state: String) -> String {
        switch state {
        case "installed": "Installed"
        case "outdated": "Update available"
        case "notInstalled": "Not installed"
        default: "Unknown"
        }
    }
}
