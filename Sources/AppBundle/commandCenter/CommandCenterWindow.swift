import AppKit
import Common

final class CommandCenterWindow: NSWindow {
    let monitor: MonitorSnapshot
    let layout: CommandCenterLayout

    init(monitor: MonitorSnapshot) {
        self.monitor = monitor
        self.layout = CommandCenterLayout(monitor: monitor)
        super.init(contentRect: monitor.rect.toNSRect(), styleMask: [.borderless], backing: .buffered, defer: false)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        contentView = CommandCenterView(window: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Screen point (top-left origin, the same coordinate space as `Rect`)
    func screenPoint(of event: NSEvent) -> CGPoint {
        let point = convertPoint(toScreen: event.locationInWindow)
        return CGPoint(x: point.x, y: mainMonitorInfo.height - point.y)
    }
}

private final class CommandCenterView: NSView {
    private let commandCenterWindow: CommandCenterWindow
    private var mouseDownPoint: CGPoint? = nil
    private var mouseDownWindow: WindowSnapshot? = nil

    init(window: CommandCenterWindow) {
        self.commandCenterWindow = window
        super.init(frame: NSRect(origin: .zero, size: window.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var layout: CommandCenterLayout { commandCenterWindow.layout }
    private var colors: CommandCenterConfig { config.commandCenter }

    // MARK: - Mouse

    private func localPoint(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        let point = localPoint(of: event)
        mouseDownPoint = point
        mouseDownWindow = layout.window(at: point)?.window
    }

    override func mouseDragged(with event: NSEvent) {
        let point = localPoint(of: event)
        if CommandCenter.shared.drag == nil {
            guard let mouseDownPoint, let mouseDownWindow, hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
            CommandCenter.shared.beginDrag(mouseDownWindow, at: commandCenterWindow.screenPoint(of: event))
        }
        CommandCenter.shared.updateDrag(to: commandCenterWindow.screenPoint(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownWindow = nil
        }
        if CommandCenter.shared.drag != nil {
            Task.startUnstructured { @MainActor in await CommandCenter.shared.endDrag() }
            return
        }
        let point = localPoint(of: event)
        if let window = mouseDownWindow {
            Task.startUnstructured { @MainActor in await CommandCenter.shared.clickWindow(window) }
        } else if let tile = layout.tile(at: point) {
            Task.startUnstructured { @MainActor in await CommandCenter.shared.clickWorkspace(tile.workspace.name) }
        } else {
            Task.startUnstructured { @MainActor in await CommandCenter.shared.close(restoreFocus: true) }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        colors.backgroundColor.nsColor.setFill()
        bounds.fill()

        let drag = CommandCenter.shared.drag
        for tile in layout.tiles {
            drawTile(tile, isDropTarget: drag?.target == .workspace(tile.workspace.name))
        }
        if let drag {
            drawDropTarget(drag)
            drawGhost(drag)
        }
    }

    private func drawTile(_ tile: CommandCenterLayout.Tile, isDropTarget: Bool) {
        let path = NSBezierPath(roundedRect: tile.frame, xRadius: 8, yRadius: 8)
        colors.workspaceColor.nsColor.setFill()
        path.fill()
        let isHighlighted = tile.workspace.isFocused || isDropTarget
        path.lineWidth = isHighlighted ? 3 : tile.workspace.isVisible ? 2 : 1
        (isHighlighted || tile.workspace.isVisible ? colors.activeColor : colors.inactiveColor).nsColor.setStroke()
        path.stroke()

        drawText(
            tile.workspace.name,
            in: CGRect(x: tile.frame.minX + 10, y: tile.frame.minY + 3, width: tile.frame.width - 20, height: CommandCenterLayout.titleHeight - 4),
            font: .systemFont(ofSize: 13, weight: .semibold),
        )
        for (window, frame) in tile.windows {
            drawWindow(window, in: frame)
        }
    }

    private func drawWindow(_ window: WindowSnapshot, in frame: CGRect) {
        let isDragged = CommandCenter.shared.drag?.source == window
        let inset = frame.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
        colors.windowColor.nsColor.withAlphaComponent(isDragged ? 0.3 : 1).setFill()
        path.fill()
        (window.isFocused ? colors.activeColor : colors.inactiveColor).nsColor.setStroke()
        path.lineWidth = window.isFocused ? 2 : 1
        path.stroke()
        if isDragged { return }

        let iconSize = min(40, inset.height * 0.4, inset.width * 0.4)
        let textHeight: CGFloat = inset.height > iconSize + 36 ? 16 : 0
        let iconOrigin = CGPoint(x: inset.midX - iconSize / 2, y: inset.midY - (iconSize + textHeight) / 2)
        window.icon?.drawFlipped(in: CGRect(origin: iconOrigin, size: CGSize(width: iconSize, height: iconSize)))
        if textHeight > 0 {
            let title = CommandCenter.shared.titles[window.windowId]?.takeIf { !$0.isEmpty } ?? window.appName
            drawText(
                title,
                in: CGRect(x: inset.minX + 6, y: iconOrigin.y + iconSize + 4, width: inset.width - 12, height: textHeight),
                font: .systemFont(ofSize: 11),
                alignment: .center,
            )
        }
    }

    private func drawDropTarget(_ drag: CommandCenter.Drag) {
        guard let target = drag.target else { return }
        colors.activeColor.nsColor.setStroke()
        colors.activeColor.nsColor.setFill()
        switch target {
            case .workspace: break // The tile border is drawn in drawTile
            case .before(let window), .after(let window):
                guard let frame = layout.frame(of: window), let orientation = window.parentOrientation else { return }
                let isBefore = if case .before = target { true } else { false }
                let thickness: CGFloat = 4
                let line = switch (orientation, isBefore) {
                    case (.h, true): CGRect(x: frame.minX - thickness / 2, y: frame.minY, width: thickness, height: frame.height)
                    case (.h, false): CGRect(x: frame.maxX - thickness / 2, y: frame.minY, width: thickness, height: frame.height)
                    case (.v, true): CGRect(x: frame.minX, y: frame.minY - thickness / 2, width: frame.width, height: thickness)
                    case (.v, false): CGRect(x: frame.minX, y: frame.maxY - thickness / 2, width: frame.width, height: thickness)
                }
                NSBezierPath(roundedRect: line, xRadius: 2, yRadius: 2).fill()
            case .join(let window):
                guard let frame = layout.frame(of: window) else { return }
                let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
                path.lineWidth = 3
                path.stroke()
        }
    }

    private func drawGhost(_ drag: CommandCenter.Drag) {
        guard let frame = layout.frame(of: drag.source) else { return } // The ghost is drawn by the monitor the drag started on
        let monitor = commandCenterWindow.monitor.rect
        let size = CGSize(width: min(frame.width, 160), height: min(frame.height, 100))
        let center = CGPoint(x: drag.point.x - monitor.topLeftX, y: drag.point.y - monitor.topLeftY)
        let ghost = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let path = NSBezierPath(roundedRect: ghost, xRadius: 4, yRadius: 4)
        colors.windowColor.nsColor.withAlphaComponent(0.9).setFill()
        path.fill()
        colors.activeColor.nsColor.setStroke()
        path.lineWidth = 2
        path.stroke()
        let iconSize = min(32, size.height * 0.6)
        drag.source.icon?.drawFlipped(in: CGRect(x: ghost.midX - iconSize / 2, y: ghost.midY - iconSize / 2, width: iconSize, height: iconSize))
    }

    private func drawText(_ text: String, in rect: CGRect, font: NSFont, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: colors.textColor.nsColor,
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}

extension Rect {
    /// AppKit coordinates: (0, 0) is the bottom left corner of the main monitor, y-axis goes up
    func toNSRect() -> NSRect {
        NSRect(x: topLeftX, y: mainMonitorInfo.height - topLeftY - height, width: width, height: height)
    }
}

extension NSImage {
    /// `draw(in:)` draws upside down in flipped views
    fileprivate func drawFlipped(in rect: CGRect) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
