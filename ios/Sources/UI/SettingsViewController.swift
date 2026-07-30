import Combine
import PedalsKit
import UIKit

/// Grouped inset settings: bound computers (status, unbind, add), font size,
/// theme, about.
@MainActor
final class SettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case computers
        case appearance
        case about
    }

    private let services: AppServices
    private var cancellables: Set<AnyCancellable> = []
    private var computerCancellables: Set<AnyCancellable> = []

    init(services: AppServices) {
        self.services = services
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.tintColor = PedalsTheme.uiContent
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )

        services.terminals.$computers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] computers in
                guard let self else { return }
                observe(computers: computers)
                reloadComputers()
            }
            .store(in: &cancellables)

    }

    /// Live per-computer state (name, link state, RTT) → refresh the section.
    private func observe(computers: [ComputerConnection]) {
        computerCancellables.removeAll()
        for computer in computers {
            computer.$linkState
                .combineLatest(computer.$hostOnline, computer.$hostName)
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _, _ in self?.reloadComputers() }
                .store(in: &computerCancellables)
        }
    }

    private func reloadComputers() {
        guard isViewLoaded else { return }
        tableView.reloadSections(IndexSet([Section.computers.rawValue]), with: .none)
    }

    private var computers: [ComputerConnection] { services.terminals.computers }

    // MARK: - Table structure

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .computers: "Computers"
        case .appearance: "Terminal"
        case .about: "About"
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .computers: computers.count + 1 // + "Add Computer…"
        case .appearance: 3
        case .about: 1
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .computers: computerCell(row: indexPath.row)
        case .appearance: appearanceCell(row: indexPath.row)
        case .about: aboutCell()
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
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if row == computers.count {
            content.text = "Add Computer…"
            content.textProperties.color = PedalsTheme.uiContent
            content.image = UIImage(systemName: "number")
            content.imageProperties.tintColor = PedalsTheme.uiContent
            cell.contentConfiguration = content
            return cell
        }

        let computer = computers[row]
        content.text = computer.displayName
        content.secondaryText = statusText(for: computer)
        content.secondaryTextProperties.color = .secondaryLabel
        content.image = UIImage(systemName: "desktopcomputer")
        content.imageProperties.tintColor = computer.hostOnline
            ? PedalsTheme.uiContent : .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    private func statusText(for computer: ComputerConnection) -> String {
        if computer.directoryKnown, !computer.hostOnline { return "Offline" }
        switch computer.linkState {
        case .idle:
            return "Disconnected"
        case .connecting(let attempt):
            return attempt == 0 ? "Connecting…" : "Reconnecting (attempt \(attempt))…"
        case .connected:
            let rtt = computer.roundTripTime.map { " · \(Int(($0 * 1000).rounded())) ms" } ?? ""
            return "Connected · E2EE" + rtt
        }
    }

    private func appearanceCell(row: Int) -> UITableViewCell {
        if row == 0 {
            let cell = valueCell(
                "Font Size", "\(Int(services.preferences.fontSize)) pt"
            )
            let stepper = UIStepper()
            stepper.minimumValue = Double(TerminalPreferences.fontSizeRange.lowerBound)
            stepper.maximumValue = Double(TerminalPreferences.fontSizeRange.upperBound)
            stepper.stepValue = 1
            stepper.value = Double(services.preferences.fontSize)
            stepper.tintColor = PedalsTheme.uiContent
            stepper.addAction(
                UIAction { [weak self, weak stepper] _ in
                    guard let self, let stepper else { return }
                    services.preferences.fontSize = Float(stepper.value)
                    services.applyTerminalAppearance()
                    tableView.reloadRows(
                        at: [IndexPath(row: 0, section: Section.appearance.rawValue)],
                        with: .none
                    )
                },
                for: .valueChanged
            )
            cell.accessoryView = stepper
            return cell
        }
        if row == 1 {
            let cell = valueCell("Theme", services.preferences.themeName)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
        let hex = services.preferences.backgroundHex
        let label = switch hex {
        case nil: "Theme"
        case "#000000": "Black"
        case let .some(value): value.uppercased()
        }
        let cell = valueCell("Background", label)
        let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        swatch.backgroundColor = services.preferences.backgroundColor
        swatch.layer.cornerRadius = 11
        swatch.layer.borderWidth = 1
        swatch.layer.borderColor = UIColor.separator.cgColor
        cell.accessoryView = swatch
        cell.selectionStyle = .default
        return cell
    }

    private func aboutCell() -> UITableViewCell {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        return valueCell("Version", version ?? "1.0")
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .computers:
            if indexPath.row == computers.count {
                presentPairingCode()
            } else {
                presentComputerActions(computers[indexPath.row])
            }
        case .appearance where indexPath.row == 1:
            navigationController?.pushViewController(
                ThemePickerViewController(services: services), animated: true
            )
        case .appearance where indexPath.row == 2:
            presentBackgroundOptions()
        case .appearance, .about:
            break
        }
    }

    // MARK: - Computers

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete,
              indexPath.section == Section.computers.rawValue,
              indexPath.row < computers.count
        else { return }
        confirmUnbind(computers[indexPath.row])
    }

    override func tableView(
        _ tableView: UITableView, canEditRowAt indexPath: IndexPath
    ) -> Bool {
        indexPath.section == Section.computers.rawValue && indexPath.row < computers.count
    }

    private func presentComputerActions(_ computer: ComputerConnection) {
        // The destructive action sheet IS the confirmation — no second alert
        // (swipe-to-delete keeps its own single confirm in confirmUnbind).
        let sheet = UIAlertController(
            title: computer.displayName,
            message: """
            \(statusText(for: computer))

            Unbinding removes its terminals from this device and the stored \
            key. Sessions keep running on the computer.
            """,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Unbind", style: .destructive) { [weak self] _ in
            self?.unbind(computer)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func confirmUnbind(_ computer: ComputerConnection) {
        let alert = UIAlertController(
            title: "Unbind “\(computer.displayName)”?",
            message: "Its terminals disappear from this device and the stored key is removed. Sessions keep running on the computer.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Unbind", style: .destructive) { [weak self] _ in
            self?.unbind(computer)
        })
        present(alert, animated: true)
    }

    private func presentPairingCode() {
        let controller = PairingCodeViewController()
        let services = services
        controller.onPair = { [weak self] code in
            try await services.bind(code: code)
            self?.tableView.reloadData()
        }
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    private func unbind(_ computer: ComputerConnection) {
        Task { @MainActor [weak self] in
            do {
                try await self?.services.terminals.removeComputer(id: computer.id)
            } catch {
                self?.showBindingError(error)
            }
        }
    }

    private func showBindingError(_ error: Error) {
        let alert = UIAlertController(
            title: "Pedals Service Error",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Terminal background

    private func presentBackgroundOptions() {
        let sheet = UIAlertController(
            title: "Terminal Background", message: nil, preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Black", style: .default) { [weak self] _ in
            self?.setBackground("#000000")
        })
        sheet.addAction(UIAlertAction(title: "Theme Default", style: .default) { [weak self] _ in
            self?.setBackground(nil)
        })
        sheet.addAction(UIAlertAction(title: "Custom Color…", style: .default) { [weak self] _ in
            self?.presentColorPicker()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }

    private func presentColorPicker() {
        let picker = UIColorPickerViewController()
        picker.title = "Terminal Background"
        picker.supportsAlpha = false
        picker.selectedColor = services.preferences.backgroundColor
        picker.delegate = self
        present(picker, animated: true)
    }

    private func setBackground(_ hex: String?) {
        services.preferences.backgroundHex = hex
        services.applyTerminalAppearance()
        tableView.reloadRows(
            at: [IndexPath(row: 2, section: Section.appearance.rawValue)], with: .none
        )
    }
}

extension SettingsViewController: UIColorPickerViewControllerDelegate {
    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        setBackground(viewController.selectedColor.pedalsHexString)
    }
}

private extension UIColor {
    /// "#RRGGBB" of the color's sRGB components.
    var pedalsHexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: nil)
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255))
        )
    }
}
