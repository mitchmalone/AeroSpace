import AppKit
import Common

/// The command center: a full-screen overview of all workspaces on all monitors
@MainActor
final class CommandCenter {
    static let shared = CommandCenter()
    private init() {}

    private var windows: [CommandCenterWindow] = []
    private(set) var snapshot: CommandCenterSnapshot? = nil
    private(set) var titles: [UInt32: String] = [:]
    private(set) var drag: Drag? = nil
    private var prevFocus: (windowId: UInt32?, workspaceName: String)? = nil
    private var titlesTask: Task<(), Never>? = nil
    private var keyMonitor: Any? = nil

    struct Drag {
        let source: WindowSnapshot
        /// Top-left origin. The same coordinate space as `Rect`
        var point: CGPoint
        var target: DropTarget?
    }

    var isOpen: Bool { !windows.isEmpty }

    func open(_ snapshot: CommandCenterSnapshot) {
        if isOpen { return }
        let focus = focus
        prevFocus = (focus.windowOrNil?.windowId, focus.workspace.name)
        self.snapshot = snapshot
        titles = [:]
        for monitor in snapshot.monitors {
            let window = CommandCenterWindow(monitor: monitor)
            windows.append(window)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                Task.startUnstructured { @MainActor in await CommandCenter.shared.close(restoreFocus: true) }
                return nil
            }
            return event
        }
        fetchTitles()
    }

    /// - Parameter restoreFocus: Restore the focus to where it was when the command center was opened
    func close(restoreFocus: Bool) async {
        if !isOpen { return }
        titlesTask?.cancel()
        titlesTask = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for window in windows {
            window.close()
        }
        windows = []
        drag = nil
        snapshot = nil
        let prevFocus = prevFocus
        self.prevFocus = nil
        guard restoreFocus, let prevFocus else { return }
        await inSession {
            if let windowId = prevFocus.windowId, let window = Window.get(byId: windowId), window.focusWindow() {
                window.nativeFocus()
            } else {
                _ = Workspace.get(byName: prevFocus.workspaceName).focusWorkspace()
                NSApp.deactivate()
            }
        }
    }

    /// Reflects the changes the command center made
    private func refresh() async {
        guard isOpen, let snapshot = try? await CommandCenterSnapshot.capture(.nonCancellable) else { return }
        self.snapshot = snapshot
        redraw()
        fetchTitles()
    }

    private func redraw() {
        for window in windows {
            window.contentView?.needsDisplay = true
        }
    }

    /// Window titles are fetched after the command center is shown, because they require an AX request per window
    private func fetchTitles() {
        titlesTask?.cancel()
        titlesTask = Task.startUnstructured { @MainActor [weak self] in
            guard let snapshot = self?.snapshot else { return }
            for windowSnapshot in snapshot.allWindows where self?.titles[windowSnapshot.windowId] == nil {
                guard let window = Window.get(byId: windowSnapshot.windowId) else { continue }
                guard let title = try? await window.getTitle(.cancellable) else { return }
                guard let self, !Task.isCancelled else { return }
                self.titles[windowSnapshot.windowId] = title
            }
            self?.redraw()
        }
    }

    // MARK: - Gestures

    func clickWorkspace(_ name: String) async {
        await close(restoreFocus: false)
        await run(["workspace", "--", name])
    }

    func clickWindow(_ window: WindowSnapshot) async {
        await close(restoreFocus: false)
        await run(["focus", "--window-id", String(window.windowId)])
    }

    func beginDrag(_ window: WindowSnapshot, at point: CGPoint) {
        drag = Drag(source: window, point: point, target: nil)
        redraw()
    }

    func updateDrag(to point: CGPoint) {
        guard var drag else { return }
        drag.point = point
        drag.target = dropTarget(at: point, dragging: drag.source)
        self.drag = drag
        redraw()
    }

    func endDrag() async {
        guard let drag else { return }
        self.drag = nil
        redraw()
        guard let target = drag.target else { return }
        let source = drag.source
        let windowId = String(source.windowId)
        switch target {
            case .workspace(let name):
                if name == source.workspace && !source.isFloating { return }
                await run(["move-node-to-workspace", "--window-id", windowId, "--", name])
            case .before(let target):
                guard let parent = target.parentPath, let index = target.indexInParent else { return }
                await run(["move-node-to-container", "--window-id", windowId, "--", target.workspace, parent.description, String(index)])
            case .after(let target):
                guard let parent = target.parentPath, let index = target.indexInParent else { return }
                await run(["move-node-to-container", "--window-id", windowId, "--", target.workspace, parent.description, String(index + 1)])
            case .join(let target):
                guard let parent = target.parentPath, let index = target.indexInParent, let orientation = target.parentOrientation else { return }
                await run([
                    ["move-node-to-container", "--window-id", windowId, "--", target.workspace, parent.description, String(index + 1)],
                    ["join-with", "--window-id", windowId, orientation == .h ? "left" : "up"],
                ])
        }
        await refresh()
    }

    private func dropTarget(at point: CGPoint, dragging source: WindowSnapshot) -> DropTarget? {
        guard let window = windows.first(where: { $0.monitor.rect.contains(point) }) else { return nil }
        let local = CGPoint(x: point.x - window.monitor.rect.topLeftX, y: point.y - window.monitor.rect.topLeftY)
        return DropTarget(window.layout, at: local, dragging: source)
    }

    private func run(_ commands: [[String]]) async {
        await inSession {
            for args in commands {
                guard let command = parseCommand(args).cmdOrNil else { return }
                let result = await command.run(.defaultEnv, .emptyStdin)
                if result.exitCode.rawValue != 0 { return }
            }
        }
    }

    /// Gestures come from AppKit events (outside of any session), while the toggle command runs inside of a session.
    /// Sessions must not be nested
    private func inSession(_ body: @MainActor () async -> ()) async {
        if refreshSessionEvent != nil {
            await body()
        } else if let guard_ = RunSessionGuard.isServerEnabled {
            _ = try? await runLightSession(.commandCenter, guard_) { await body() }
        }
    }

    private func run(_ args: [String]) async {
        await run([args])
    }
}
