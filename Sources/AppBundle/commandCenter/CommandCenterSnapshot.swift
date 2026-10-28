import AppKit
import Common

/// Everything the command center draws. Captured once when the command center opens, and after every change it makes
struct CommandCenterSnapshot {
    let monitors: [MonitorSnapshot]

    @MainActor
    static func capture(_ cm: CancellationMode) async throws -> CommandCenterSnapshot {
        let focus = focus
        var monitors: [MonitorSnapshot] = []
        for monitor in sortedMonitorInfos {
            var workspaces: [WorkspaceSnapshot] = []
            for workspace in Workspace.all where workspace.workspaceMonitor.rect.topLeftCorner == monitor.rect.topLeftCorner {
                workspaces.append(try await WorkspaceSnapshot.capture(workspace, focus: focus, cm))
            }
            monitors.append(MonitorSnapshot(rect: monitor.rect, workspaces: workspaces))
        }
        return CommandCenterSnapshot(monitors: monitors)
    }

    var allWindows: [WindowSnapshot] { monitors.flatMap { $0.workspaces.flatMap(\.windows) } }
}

struct MonitorSnapshot {
    let rect: Rect
    let workspaces: [WorkspaceSnapshot]
}

struct WorkspaceSnapshot {
    let name: String
    let isFocused: Bool
    let isVisible: Bool
    /// Tiling windows come first, floating windows come last (so that floating windows are drawn on top)
    let windows: [WindowSnapshot]

    @MainActor
    static func capture(_ workspace: Workspace, focus: LiveFocus, _ cm: CancellationMode) async throws -> WorkspaceSnapshot {
        let measurement = try await workspace.measureLayout()
        var windows: [WindowSnapshot] = []
        workspace.rootTilingContainer.visitWindows(path: []) { window, path in
            if let frame = measurement.rect(of: window) {
                windows.append(WindowSnapshot(window, workspace: workspace.name, frame: frame, path: path, focus: focus))
            }
        }
        for window in workspace.floatingWindows {
            let frame = if let rect = window.unhiddenFloatingRect { rect } else { try await window.getAxRect(cm) }
            if let frame {
                windows.append(WindowSnapshot(window, workspace: workspace.name, frame: frame, path: nil, focus: focus))
            }
        }
        return WorkspaceSnapshot(name: workspace.name, isFocused: focus.workspace == workspace, isVisible: workspace.isVisible, windows: windows)
    }
}

struct WindowSnapshot: Equatable {
    let windowId: UInt32
    let workspace: String
    let appName: String
    let icon: NSImage?
    let isFocused: Bool
    /// In the coordinates of the monitor layout (as if the workspace was visible)
    let frame: Rect
    /// nil for floating windows
    let path: ContainerPath?
    let parentOrientation: Orientation?

    @MainActor
    fileprivate init(_ window: Window, workspace: String, frame: Rect, path: ContainerPath?, focus: LiveFocus) {
        self.windowId = window.windowId
        self.workspace = workspace
        self.appName = window.app.name ?? ""
        self.icon = (window.app as? MacApp)?.nsApp.icon
        self.isFocused = focus.windowOrNil == window
        self.frame = frame
        self.path = path
        self.parentOrientation = (window.parent as? TilingContainer)?.orientation
    }

    var isFloating: Bool { path == nil }
    var parentPath: ContainerPath? { path.map { ContainerPath($0.indices.dropLast()) } }
    var indexInParent: Int? { path?.indices.last }

    static func == (lhs: WindowSnapshot, rhs: WindowSnapshot) -> Bool { lhs.windowId == rhs.windowId }
}

extension TilingContainer {
    fileprivate func visitWindows(path: [Int], _ visit: (Window, ContainerPath) -> ()) {
        for (index, child) in children.enumerated() {
            switch child.tilingTreeNodeCasesOrDie() {
                case .window(let window): visit(window, ContainerPath(path + [index]))
                case .tilingContainer(let container): container.visitWindows(path: path + [index], visit)
            }
        }
    }
}
