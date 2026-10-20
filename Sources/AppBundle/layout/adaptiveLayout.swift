import AppKit

struct TilingFootprint: Equatable {
    let columns: Int
    let rows: Int
}

extension TreeNode {
    @MainActor
    var tilingFootprint: TilingFootprint? {
        switch nodeCases {
            case .window(let window):
                return window.isAwaitingOnWindowDetected ? nil : TilingFootprint(columns: 1, rows: 1)
            case .tilingContainer(let container):
                let childFootprints = container.children.compactMap(\.tilingFootprint)
                guard !childFootprints.isEmpty else { return nil }
                if container.layout == .accordion {
                    return TilingFootprint(
                        columns: childFootprints.map(\.columns).max().orDie(),
                        rows: childFootprints.map(\.rows).max().orDie(),
                    )
                }
                return switch container.orientation {
                    case .h: TilingFootprint(
                            columns: childFootprints.reduce(0) { $0 + $1.columns },
                            rows: childFootprints.map(\.rows).max().orDie(),
                        )
                    case .v: TilingFootprint(
                            columns: childFootprints.map(\.columns).max().orDie(),
                            rows: childFootprints.reduce(0) { $0 + $1.rows },
                        )
                }
            case .workspace, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosFullscreenWindowsContainer, .macosPopupWindowsContainer,
                 .macosHiddenAppsWindowsContainer:
                return nil
        }
    }
}

func adaptiveWorkspaceRect(
    available: Rect,
    footprint: TilingFootprint,
    config: AdaptiveLayoutConfig,
) -> Rect {
    let widthPercent = switch footprint.columns {
        case 1: config.oneColumnWidthPercent
        case 2: config.twoColumnWidthPercent
        default: 100
    }
    let heightPercent = footprint.rows == 1 ? config.singleRowHeightPercent : 100
    let width = available.width * CGFloat(widthPercent) / 100
    let height = available.height * CGFloat(heightPercent) / 100
    return Rect(
        topLeftX: available.topLeftX + (available.width - width) / 2,
        topLeftY: available.topLeftY + (available.height - height) / 2,
        width: width,
        height: height,
    )
}
