import Combine
import PedalsKit
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

    /// Rows in the Updates section.
    private enum UpdateRow: Int {
        case version
        case latest
        case check
        case install
    }

    private static let requestTimeout: Duration = .seconds(5)

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
    private var installingUpdate = false

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
        view.tintColor = PedalsTheme.uiContent

        computer?.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handle(event: event) }
            .store(in: &cancellables)

        // Re-request whenever the host (re)appears; pop when unbound.
        if let computer {
            computer.$hostOnline
                .combineLatest(computer.$hostName)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] online, name in
                    guard let self else { return }
                    if let name, !name.isEmpty { title = name }
                    if online { refreshRemoteState() }
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
            try? await Task.sleep(for: Self.requestTimeout)
            guard let self, !Task.isCancelled, pendingUpdateReq == req else { return }
            pendingUpdateReq = nil
            installingUpdate = false
            updatesUnsupported = updateInfo == nil
            reloadSections(.updates)
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
            installingUpdate = false
            updateInfo = info
            reloadSections(.computer, .updates)
        case .error(let msg, let req):
            if req == pendingHooksReq {
                pendingHooksReq = nil
                busyAgents.removeAll()
                actionError = msg
                reloadSections(.agents)
            } else if req == pendingUpdateReq {
                pendingUpdateReq = nil
                installingUpdate = false
                actionError = msg
                reloadSections(.updates)
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
                return "This Mac runs an older Pedals without remote hook management. Update Pedals on the Mac to manage hooks from here."
            }
            return actionError
        case .updates:
            if updatesUnsupported {
                return "This Mac runs an older Pedals without remote updates. Update Pedals on the Mac to check for updates from here."
            }
            if let actionError { return actionError }
            return updateInfo?.detail
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
            return 4
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
        case .updates: updateCell(row: indexPath.row)
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
        content.secondaryText = busyAgents.contains(entry.agent)
            ? "Working…" : Self.stateText(entry.state)
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    private func updateCell(row: Int) -> UITableViewCell {
        switch UpdateRow(rawValue: row)! {
        case .version:
            return valueCell("Current Version", updateInfo?.current ?? "—")
        case .latest:
            return valueCell("Latest Version", updateInfo?.latest ?? "—")
        case .check:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = pendingUpdateReq != nil ? "Checking…" : "Check for Updates"
            content.textProperties.color = PedalsTheme.uiContent
            cell.contentConfiguration = content
            cell.selectionStyle = .default
            return cell
        case .install:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = installingUpdate ? "Starting Update…" : "Install Update"
            let installable = updateInfo?.canInstall == true && !installingUpdate
            content.textProperties.color = installable ? PedalsTheme.uiContent : .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = installable ? .default : .none
            return cell
        }
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
            guard let hookStates, indexPath.row < hookStates.count else { return }
            presentHookActions(for: hookStates[indexPath.row])
        case .updates:
            switch UpdateRow(rawValue: indexPath.row)! {
            case .check:
                requestUpdateStatus()
            case .install:
                guard updateInfo?.canInstall == true, !installingUpdate else { return }
                confirmInstallUpdate()
            case .version, .latest:
                break
            }
        case .unbind:
            confirmUnbind()
        case .computer:
            break
        }
    }

    // MARK: - Actions

    private func presentHookActions(for entry: HookStateInfo) {
        let name = Self.agentName(entry.agent)
        let sheet = UIAlertController(
            title: name,
            message: "Hook: \(Self.stateText(entry.state))",
            preferredStyle: .actionSheet
        )
        switch entry.state {
        case "installed":
            sheet.addAction(UIAlertAction(title: "Reinstall", style: .default) { [weak self] _ in
                self?.installHook(entry.agent)
            })
        case "outdated":
            sheet.addAction(UIAlertAction(title: "Update Hook", style: .default) { [weak self] _ in
                self?.installHook(entry.agent)
            })
        default:
            sheet.addAction(UIAlertAction(title: "Install Hook", style: .default) { [weak self] _ in
                self?.installHook(entry.agent)
            })
        }
        if entry.state == "installed" || entry.state == "outdated" {
            sheet.addAction(UIAlertAction(title: "Uninstall", style: .destructive) { [weak self] _ in
                self?.uninstallHook(entry.agent)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // iPad action sheets anchor to the tapped row.
        sheet.popoverPresentationController?.sourceView = tableView
        present(sheet, animated: true)
    }

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

    private func confirmInstallUpdate() {
        let alert = UIAlertController(
            title: "Install Update on \(computer?.displayName ?? "this Mac")?",
            message: "The Mac downloads the update with Sparkle and Pedals restarts there. Sessions keep running.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Install Update", style: .default) { [weak self] _ in
            guard let self else { return }
            let req = UInt32.random(in: 1...UInt32.max)
            self.pendingUpdateReq = req
            self.installingUpdate = true
            self.computer?.installUpdate(req: req)
            self.armUpdateTimeout(req: req)
            self.reloadSections(.updates)
        })
        present(alert, animated: true)
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
                    title: "Pedals Service Error",
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

    private static func stateText(_ state: String) -> String {
        switch state {
        case "installed": "Installed"
        case "outdated": "Update available"
        case "notInstalled": "Not installed"
        default: "Unknown"
        }
    }
}
