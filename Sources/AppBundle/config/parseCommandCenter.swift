import AppKit
import Common

struct CommandCenterConfig: ConvenienceMutable, Equatable, Sendable {
    var backgroundColor = ArgbColor(0xCC00_0000)
    var workspaceColor = ArgbColor(0xFF1E_1E1E)
    var windowColor = ArgbColor(0xFF2E_2E2E)
    var activeColor = ArgbColor(0xFFE2_E2E3)
    var inactiveColor = ArgbColor(0xFF49_4949)
    var textColor = ArgbColor(0xFFE2_E2E3)
}

/// Color in `0xAARRGGBB` format (the same format JankyBorders uses)
struct ArgbColor: Equatable, Sendable {
    let argb: UInt32

    init(_ argb: UInt32) { self.argb = argb }

    static func parse(_ raw: String) -> ResOrStr<ArgbColor> {
        let hex = raw.removePrefix("0x").removePrefix("0X").removePrefix("#")
        guard hex.count == 8, let argb = UInt32(hex, radix: 16) else {
            return .failure("Can't parse color \(raw.singleQuoted). Expected format: 0xAARRGGBB")
        }
        return .success(ArgbColor(argb))
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255,
        )
    }
}

private let commandCenterParserTable: [String: any ParserProtocol<CommandCenterConfig>] = [
    "background-color": Parser(\.backgroundColor, parseColor),
    "workspace-color": Parser(\.workspaceColor, parseColor),
    "window-color": Parser(\.windowColor, parseColor),
    "active-color": Parser(\.activeColor, parseColor),
    "inactive-color": Parser(\.inactiveColor, parseColor),
    "text-color": Parser(\.textColor, parseColor),
]

func parseCommandCenter(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> CommandCenterConfig {
    parseTable(raw, CommandCenterConfig(), commandCenterParserTable, backtrace, &c)
}

private func parseColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<ArgbColor> {
    if let int = raw.asInt64OrNil {
        return UInt32(exactly: int).map(ArgbColor.init)
            .toResult(.init(backtrace, "Color must be in [0x00000000, 0xFFFFFFFF] range. Got: \(int)"))
    }
    if let str = raw.asStringOrNil {
        return ArgbColor.parse(str).mapError { .init(backtrace, $0) }
    }
    return .failure(.init(backtrace, expectedActualTypeError(expected: [.int, .string], actual: raw.tomlType)))
}
