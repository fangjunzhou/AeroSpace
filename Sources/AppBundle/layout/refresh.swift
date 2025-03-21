import AppKit
import Common


var newWindowDetected = ThreadSafeValue(false)

var debouncer = Debouncer()

func timestamp() -> String {
    let date = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: date)
}

func maybeDetectNewWindows<T>(_ event: RefreshSessionEvent, screenIsDefinitelyUnlocked: Bool, startup: Bool, body: @escaping () -> T) {
    debouncer.debounce(delay: Double(config.newWindowDetectionDebounce) / 1000, action: {
        let td = TimeoutDetector()

        td.run(
            task: {td in
                newWindowDetected.value = false
                detectNewWindowsAndAttachThemToWorkspaces(startup: false)
            },
            onFinish: {td in
                if td.didTimeout && newWindowDetected.value {
                    DispatchQueue.main.async {
                        _ = refreshSession(event, screenIsDefinitelyUnlocked: screenIsDefinitelyUnlocked, startup: startup, body: body)
                    }
                }
            })

        td.wait(timeout: Double(config.newWindowDetectionTimeout) / 1000)
    })
}

/// It's one of the most important function of the whole application.
/// The function is called as a feedback response on every user input.
/// The function is idempotent.
func refreshSession<T>(_ event: RefreshSessionEvent, screenIsDefinitelyUnlocked: Bool, startup: Bool = false, body:
    @escaping () -> T) -> T {
    check(Thread.current.isMainThread)
    refreshSessionEventForDebug = event
    defer { refreshSessionEventForDebug = nil }
    if screenIsDefinitelyUnlocked { resetClosedWindowsCache() }
    gc()
    gcMonitors()

    detectNewAppsAndWindows(startup: startup)

    let nativeFocused = getNativeFocusedWindow(startup: startup)
    if let nativeFocused { debugWindowsIfRecording(nativeFocused) }
    updateFocusCache(nativeFocused)
    let focusBefore = focus.windowOrNil


    refreshModel()
    let result = body()
    refreshModel()

    let focusAfter = focus.windowOrNil

    if startup {
        smartLayoutAtStartup()
    }

    if TrayMenuModel.shared.isEnabled {
        if focusBefore != focusAfter {
            focusAfter?.nativeFocus() // syncFocusToMacOs
        }

        updateTrayText()
        normalizeLayoutReason(startup: startup)
        layoutWorkspaces()
    }
    return result
}

func refreshAndLayout(_ event: RefreshSessionEvent, screenIsDefinitelyUnlocked: Bool, startup: Bool = false) {
    refreshSession(event, screenIsDefinitelyUnlocked: screenIsDefinitelyUnlocked, startup: startup, body: {})
}


func refreshModel() {
    gc()
    checkOnFocusChangedCallbacks()
    normalizeContainers()
}

private func gc() {
    // Garbage collect terminated apps and windows before working with all windows
    MacApp.garbageCollectTerminatedApps()
    gcWindows()
    // Garbage collect workspaces after apps, because workspaces contain apps.
    Workspace.garbageCollectUnusedWorkspaces()
}

func gcWindows() {
    // Second line of defence against lock screen. See the first line of defence: closedWindowsCache
    // Second and third lines of defence are technically needed only to avoid potential flickering
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lockScreenAppBundleId { return }
    let toKill = MacWindow.allWindowsMap.filter { $0.value.axWindow.containingWindowId(signpostEvent: $0.value.app.name) == nil }
    // If all windows are "unobservable", it's highly propable that loginwindow might be still active and we are still
    // recovering from unlock
    if toKill.count == MacWindow.allWindowsMap.count { return }
    for window in toKill {
        window.value.garbageCollect(skipClosedWindowsCache: false)
    }
}

func refreshObs(_ obs: AXObserver, ax: AXUIElement, notif: CFString, data: UnsafeMutableRawPointer?) {
    refreshAndLayout(.ax(notif as String), screenIsDefinitelyUnlocked: false)
}

enum OptimalHideCorner {
    case bottomLeftCorner, bottomRightCorner
}

private func layoutWorkspaces() {
    let monitors = monitors
    var monitorToOptimalHideCorner: [CGPoint: OptimalHideCorner] = [:]
    for monitor in monitors {
        let xOff = monitor.width * 0.1
        let yOff = monitor.height * 0.1
        // brc = bottomRightCorner
        let brc1 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: -yOff)
        let brc2 = monitor.rect.bottomRightCorner + CGPoint(x: -xOff, y: 2)
        let brc3 = monitor.rect.bottomRightCorner + CGPoint(x: 2, y: 2)

        // blc = bottomLeftCorner
        let blc1 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: -yOff)
        let blc2 = monitor.rect.bottomLeftCorner + CGPoint(x: xOff, y: 2)
        let blc3 = monitor.rect.bottomLeftCorner + CGPoint(x: -2, y: 2)

        let corner: OptimalHideCorner =
            monitors.contains(where: { m in m.rect.contains(brc1) || m.rect.contains(brc2) || m.rect.contains(brc3) }) &&
            monitors.allSatisfy { m in !m.rect.contains(blc1) && !m.rect.contains(blc2) && !m.rect.contains(blc3) }
            ? .bottomLeftCorner
            : .bottomRightCorner
        monitorToOptimalHideCorner[monitor.rect.topLeftCorner] = corner
    }

    // to reduce flicker, first unhide visible workspaces, then hide invisible ones
    for monitor in monitors {
        let workspace = monitor.activeWorkspace
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).unhideFromCorner() } // todo as!
        workspace.layoutWorkspace()
    }
    for workspace in Workspace.all where !workspace.isVisible {
        let corner = monitorToOptimalHideCorner[workspace.workspaceMonitor.rect.topLeftCorner] ?? .bottomRightCorner
        workspace.allLeafWindowsRecursive.forEach { ($0 as! MacWindow).hideInCorner(corner) } // todo as!
    }
}

private func normalizeContainers() {
    // Can't do it only for visible workspace because most of the commands support --window-id and --workspace flags
    for workspace in Workspace.all {
        workspace.normalizeContainers()
    }
}

private func detectNewAppsAndWindows(startup: Bool) {
    for app in apps {
        app.detectNewWindows(startup: startup)
    }
}

private func smartLayoutAtStartup() {
    let workspace = focus.workspace
    let root = workspace.rootTilingContainer
    if root.children.count <= 3 {
        root.layout = .tiles
    } else {
        root.layout = .accordion
    }
}
