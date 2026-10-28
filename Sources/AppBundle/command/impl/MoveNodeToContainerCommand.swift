import Common

struct MoveNodeToContainerCommand: Command {
    let args: MoveNodeToContainerCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        switch window.windowParentCases {
            case .unbound: return .fail
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
                return .fail(io.err(moveOutMacosUnconventionalWindow))
            case .macosPopupWindowsContainer:
                return .fail(io.err(bugPrompt())) // Impossible
            case .tilingContainer, .floatingWindowsContainer: break
        }
        let workspace = Workspace.get(byName: args.targetWorkspace.val.raw)
        let path = args.containerPath.val
        guard let container = workspace.rootTilingContainer.resolve(path) else {
            return .fail(io.err("Container \(path.description.singleQuoted) doesn't exist in workspace \(workspace.name.singleQuoted)"))
        }
        var index = args.index.val
        if index > container.children.count {
            return .fail(io.err("Index \(index) is out of bounds. Container \(path.description.singleQuoted) in workspace \(workspace.name.singleQuoted) has \(container.children.count) children"))
        }
        if window.parent === container, let ownIndex = window.ownIndex {
            // <index> refers to the children list before the move. The window itself is a part of that list
            if ownIndex < index { index -= 1 }
            let prevBinding = window.unbindFromParent()
            window.bind(to: container, adaptiveWeight: prevBinding.adaptiveWeight, index: index)
        } else {
            window.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: index)
        }
        return .from(bool: args.focusFollowsWindow ? window.focusWindow() : true)
    }
}

extension TilingContainer {
    func resolve(_ path: ContainerPath) -> TilingContainer? {
        var container = self
        for index in path.indices {
            guard let child = container.children.getOrNil(atIndex: index) as? TilingContainer else { return nil }
            container = child
        }
        return container
    }
}
