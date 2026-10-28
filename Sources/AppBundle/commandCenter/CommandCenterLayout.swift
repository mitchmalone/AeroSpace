import AppKit
import Common

/// Pure geometry of the command center on one monitor: where workspace tiles and window thumbnails go
struct CommandCenterLayout {
    let tiles: [Tile]

    struct Tile {
        let workspace: WorkspaceSnapshot
        /// In view coordinates (top-left origin)
        let frame: CGRect
        let windows: [(window: WindowSnapshot, frame: CGRect)]
    }

    static let margin: CGFloat = 48
    static let gap: CGFloat = 24
    static let titleHeight: CGFloat = 22

    init(monitor: MonitorSnapshot) {
        let workspaces = monitor.workspaces
        guard !workspaces.isEmpty else {
            tiles = []
            return
        }
        let bounds = CGSize(width: monitor.rect.width, height: monitor.rect.height)
        let aspectRatio = Double(bounds.width / bounds.height)
        let idealColumns = Int(ceil(sqrt(Double(workspaces.count) * aspectRatio)))
        let columns = max(1, min(idealColumns, workspaces.count))
        let rows = Int(ceil(Double(workspaces.count) / Double(columns)))
        let cellWidth = (bounds.width - 2 * Self.margin - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
        let cellHeight = (bounds.height - 2 * Self.margin - CGFloat(rows - 1) * Self.gap) / CGFloat(rows)
        let scale = min(cellWidth / bounds.width, (cellHeight - Self.titleHeight) / bounds.height)
        let tileSize = CGSize(width: bounds.width * scale, height: bounds.height * scale + Self.titleHeight)

        tiles = workspaces.enumerated().map { index, workspace in
            let column = index % columns
            let row = index / columns
            let cellOrigin = CGPoint(
                x: Self.margin + CGFloat(column) * (cellWidth + Self.gap),
                y: Self.margin + CGFloat(row) * (cellHeight + Self.gap),
            )
            let tileOrigin = CGPoint(
                x: cellOrigin.x + (cellWidth - tileSize.width) / 2,
                y: cellOrigin.y + (cellHeight - tileSize.height) / 2,
            )
            let windows = workspace.windows.map { window in
                let frame = CGRect(
                    x: tileOrigin.x + (window.frame.topLeftX - monitor.rect.topLeftX) * scale,
                    y: tileOrigin.y + Self.titleHeight + (window.frame.topLeftY - monitor.rect.topLeftY) * scale,
                    width: window.frame.width * scale,
                    height: window.frame.height * scale,
                )
                return (window, frame)
            }
            return Tile(workspace: workspace, frame: CGRect(origin: tileOrigin, size: tileSize), windows: windows)
        }
    }

    func tile(at point: CGPoint) -> Tile? {
        tiles.first { $0.frame.contains(point) }
    }

    func window(at point: CGPoint) -> (window: WindowSnapshot, frame: CGRect)? {
        tile(at: point)?.windows.last { $0.frame.contains(point) }
    }

    func frame(of window: WindowSnapshot) -> CGRect? {
        tiles.lazy.flatMap(\.windows).first { $0.window == window }?.frame
    }
}

enum DropTarget: Equatable {
    case workspace(String)
    case before(WindowSnapshot)
    case after(WindowSnapshot)
    case join(WindowSnapshot)

    /// Drop zones of a window thumbnail: the edges along the parent container orientation insert the dragged window
    /// before/after the target, the center joins the dragged window with the target
    static let edgeZone: CGFloat = 0.3

    init?(_ layout: CommandCenterLayout, at point: CGPoint, dragging source: WindowSnapshot) {
        guard let tile = layout.tile(at: point) else { return nil }
        guard let (target, frame) = layout.window(at: point), target != source, let orientation = target.parentOrientation else {
            self = .workspace(tile.workspace.name)
            return
        }
        let proportion = orientation == .h
            ? (point.x - frame.minX) / frame.width
            : (point.y - frame.minY) / frame.height
        self = switch proportion {
            case ..<Self.edgeZone: .before(target)
            case (1 - Self.edgeZone)...: .after(target)
            default: .join(target)
        }
    }
}
