class TrayMenuModel: ObservableObject {
    static let shared = TrayMenuModel()

    private init() {}

    @Published var trayText: String = ""
}

func updateTrayText() {
    TrayMenuModel.shared.trayText = (activeMode.takeIf { $0 != mainModeId }?.first?.lets { "[\($0)] " } ?? "") +
        sortedMonitors
            .map {
                ($0.activeWorkspace == Workspace.focused && monitors.count > 1 ? "*" : "") + $0.activeWorkspace.name
            }
            .joined(separator: " │ ")
}
