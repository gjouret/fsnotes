//
//  PreferencesAIViewController.swift
//  FSNotes
//
//  Settings tab for the AI chat feature. Programmatic UI (no storyboard scene)
//  so it can be added to PrefsViewController at runtime without surgery on
//  Main.storyboard. Exposes provider selection (Ollama / Anthropic / OpenAI),
//  Ollama-specific host + model picker + reachability indicator, and the
//  existing API-key field for cloud providers.
//

import Cocoa

final class PreferencesAIViewController: NSViewController {

    // MARK: - State

    private let providerOptions: [(value: String, title: String)] = [
        ("ollama", "Ollama (local)"),
        ("anthropic", "Anthropic"),
        ("openai", "OpenAI")
    ]

    // MARK: - Subviews

    private let providerLabel = NSTextField(labelWithString: "Provider:")
    private let providerPopUp = NSPopUpButton()

    // Ollama-specific section
    private let ollamaHostLabel = NSTextField(labelWithString: "Host URL:")
    private let ollamaHostField = NSTextField()
    private let ollamaModelLabel = NSTextField(labelWithString: "Model:")
    private let ollamaModelPopUp = NSPopUpButton()
    private let ollamaRefreshButton = NSButton(title: "Refresh Models", target: nil, action: nil)
    private let ollamaStatusLabel = NSTextField(labelWithString: "Status: unknown")

    // Cloud-provider section (Anthropic / OpenAI)
    private let cloudKeyLabel = NSTextField(labelWithString: "API Key:")
    private let cloudKeyField = NSSecureTextField()
    private let cloudModelLabel = NSTextField(labelWithString: "Model:")
    private let cloudModelField = NSTextField()
    private let cloudEndpointLabel = NSTextField(labelWithString: "Endpoint:")
    private let cloudEndpointField = NSTextField()

    private let ollamaSection = NSStackView()
    private let cloudSection = NSStackView()

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        root.translatesAutoresizingMaskIntoConstraints = false

        let providerRow = makeRow(label: providerLabel, control: providerPopUp)

        for (_, title) in providerOptions {
            providerPopUp.addItem(withTitle: title)
        }
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged(_:))

        configureOllamaSection()
        configureCloudSection()

        let mainStack = NSStackView(views: [providerRow, ollamaSection, cloudSection])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AI"
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadFromUserDefaults()
        updateSectionVisibility()
        // Populate the model dropdown with the currently-saved value so it isn't
        // empty before the user clicks Refresh.
        let savedModel = UserDefaultsManagement.aiModel
        if !savedModel.isEmpty {
            ollamaModelPopUp.removeAllItems()
            ollamaModelPopUp.addItem(withTitle: savedModel)
        }
        // Best-effort reachability probe so the user sees status on tab open.
        refreshReachability()
    }

    // MARK: - Section configuration

    private func configureOllamaSection() {
        ollamaHostField.placeholderString = "http://localhost:11434"
        ollamaHostField.target = self
        ollamaHostField.action = #selector(ollamaHostChanged(_:))
        ollamaHostField.bezelStyle = .roundedBezel

        ollamaModelPopUp.target = self
        ollamaModelPopUp.action = #selector(ollamaModelChanged(_:))

        ollamaRefreshButton.target = self
        ollamaRefreshButton.action = #selector(refreshOllamaModels(_:))
        ollamaRefreshButton.bezelStyle = .rounded

        ollamaStatusLabel.textColor = .secondaryLabelColor

        let modelRow = NSStackView(views: [ollamaModelLabel, ollamaModelPopUp, ollamaRefreshButton])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        modelRow.alignment = .firstBaseline

        ollamaSection.orientation = .vertical
        ollamaSection.alignment = .leading
        ollamaSection.spacing = 10
        ollamaSection.translatesAutoresizingMaskIntoConstraints = false
        ollamaSection.addArrangedSubview(makeRow(label: ollamaHostLabel, control: ollamaHostField, controlWidth: 280))
        ollamaSection.addArrangedSubview(modelRow)
        ollamaSection.addArrangedSubview(ollamaStatusLabel)

        NSLayoutConstraint.activate([
            ollamaModelPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func configureCloudSection() {
        cloudKeyField.placeholderString = "sk-..."
        cloudKeyField.target = self
        cloudKeyField.action = #selector(cloudKeyChanged(_:))
        cloudKeyField.bezelStyle = .roundedBezel

        cloudModelField.placeholderString = "model name (e.g. gpt-4o)"
        cloudModelField.target = self
        cloudModelField.action = #selector(cloudModelChanged(_:))
        cloudModelField.bezelStyle = .roundedBezel

        cloudEndpointField.placeholderString = "(optional) custom endpoint"
        cloudEndpointField.target = self
        cloudEndpointField.action = #selector(cloudEndpointChanged(_:))
        cloudEndpointField.bezelStyle = .roundedBezel

        cloudSection.orientation = .vertical
        cloudSection.alignment = .leading
        cloudSection.spacing = 10
        cloudSection.translatesAutoresizingMaskIntoConstraints = false
        cloudSection.addArrangedSubview(makeRow(label: cloudKeyLabel, control: cloudKeyField, controlWidth: 280))
        cloudSection.addArrangedSubview(makeRow(label: cloudModelLabel, control: cloudModelField, controlWidth: 280))
        cloudSection.addArrangedSubview(makeRow(label: cloudEndpointLabel, control: cloudEndpointField, controlWidth: 280))
    }

    private func makeRow(label: NSTextField,
                         control: NSView,
                         controlWidth: CGFloat = 200) -> NSStackView {
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 80),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: controlWidth)
        ])
        return row
    }

    // MARK: - UserDefaults binding

    private func loadFromUserDefaults() {
        let provider = UserDefaultsManagement.aiProvider
        let providerIndex = providerOptions.firstIndex(where: { $0.value == provider }) ?? 0
        providerPopUp.selectItem(at: providerIndex)

        ollamaHostField.stringValue = UserDefaultsManagement.aiOllamaHost
        cloudKeyField.stringValue = UserDefaultsManagement.aiAPIKey
        cloudModelField.stringValue = UserDefaultsManagement.aiModel
        cloudEndpointField.stringValue = UserDefaultsManagement.aiEndpoint
    }

    private var selectedProviderValue: String {
        let idx = max(0, providerPopUp.indexOfSelectedItem)
        return providerOptions[idx].value
    }

    private func updateSectionVisibility() {
        let isOllama = selectedProviderValue == "ollama"
        ollamaSection.isHidden = !isOllama
        cloudSection.isHidden = isOllama
    }

    // MARK: - Actions

    @objc private func providerChanged(_ sender: NSPopUpButton) {
        UserDefaultsManagement.aiProvider = selectedProviderValue
        // Reset model field so the user can pick from the new provider's list.
        UserDefaultsManagement.aiModel = ""
        updateSectionVisibility()
        if selectedProviderValue == "ollama" {
            refreshReachability()
        }
    }

    @objc private func ollamaHostChanged(_ sender: NSTextField) {
        UserDefaultsManagement.aiOllamaHost = sender.stringValue
        refreshReachability()
    }

    @objc private func ollamaModelChanged(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem {
            UserDefaultsManagement.aiModel = title
        }
    }

    @objc private func refreshOllamaModels(_ sender: Any?) {
        let host = ollamaHostField.stringValue.isEmpty
            ? UserDefaultsManagement.aiOllamaHost
            : ollamaHostField.stringValue
        ollamaStatusLabel.stringValue = "Status: refreshing…"
        OllamaClient.listModels(host: host) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let models):
                    self.populateModels(models)
                    self.ollamaStatusLabel.stringValue =
                        "Status: connected — \(models.count) model\(models.count == 1 ? "" : "s") available"
                    self.ollamaStatusLabel.textColor = .systemGreen
                case .failure(let error):
                    self.ollamaStatusLabel.stringValue = "Status: \(error.localizedDescription)"
                    self.ollamaStatusLabel.textColor = .systemRed
                }
            }
        }
    }

    private func populateModels(_ models: [OllamaModel]) {
        ollamaModelPopUp.removeAllItems()
        for model in models {
            ollamaModelPopUp.addItem(withTitle: model.name)
        }
        let saved = UserDefaultsManagement.aiModel
        if !saved.isEmpty, models.contains(where: { $0.name == saved }) {
            ollamaModelPopUp.selectItem(withTitle: saved)
        } else if let first = models.first {
            ollamaModelPopUp.selectItem(withTitle: first.name)
            UserDefaultsManagement.aiModel = first.name
        }
    }

    private func refreshReachability() {
        let host = ollamaHostField.stringValue.isEmpty
            ? UserDefaultsManagement.aiOllamaHost
            : ollamaHostField.stringValue
        OllamaClient.checkReachability(host: host) { [weak self] reachable in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if reachable {
                    self.ollamaStatusLabel.stringValue = "Status: reachable"
                    self.ollamaStatusLabel.textColor = .systemGreen
                } else {
                    self.ollamaStatusLabel.stringValue = "Status: unreachable (is `ollama serve` running?)"
                    self.ollamaStatusLabel.textColor = .systemOrange
                }
            }
        }
    }

    @objc private func cloudKeyChanged(_ sender: NSSecureTextField) {
        UserDefaultsManagement.aiAPIKey = sender.stringValue
    }

    @objc private func cloudModelChanged(_ sender: NSTextField) {
        UserDefaultsManagement.aiModel = sender.stringValue
    }

    @objc private func cloudEndpointChanged(_ sender: NSTextField) {
        UserDefaultsManagement.aiEndpoint = sender.stringValue
    }
}
