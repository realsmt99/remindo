import AppKit
import SwiftUI

enum NotchMode: Equatable {
    /// Invisible: the real notch looks untouched.
    case hidden
    /// Live activity: small wings left and right of the notch.
    case compact
    /// A card drops out of the notch for a few seconds.
    case peek
    /// Hovered: every session, clickable.
    case expanded
}

/// Size of the physical notch on this screen (or a virtual one on screens without a notch).
struct NotchMetrics: Equatable {
    var notchSize: CGSize
    var hasNotch: Bool
    /// Screens without a notch get a floating Dynamic-Island-style pill instead of a tab
    /// glued to the top edge.
    var island = false
    /// Gap between the top of the screen and the island.
    var islandTop: CGFloat = 0

    static let fallback = NotchMetrics(notchSize: CGSize(width: 184, height: 32), hasNotch: false)

    /// `forceIsland` previews the island on a notched MacBook (it then floats just below the notch).
    static func measure(_ screen: NSScreen, forceIsland: Bool = false) -> NotchMetrics {
        let frame = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            if width > 40 {
                if forceIsland {
                    return NotchMetrics(notchSize: CGSize(width: 150, height: 30), hasNotch: true,
                                        island: true, islandTop: top + 6)
                }
                return NotchMetrics(notchSize: CGSize(width: width.rounded(.up), height: top), hasNotch: true)
            }
        }
        // No notch: an island pill hovering over the middle of the menu bar.
        return NotchMetrics(notchSize: CGSize(width: 150, height: 30), hasNotch: false, island: true, islandTop: 5)
    }
}

enum NotchLayout {
    /// Width of each wing beside the notch in compact mode.
    static let wing: CGFloat = 46
    static let maxRows = 4
    /// Retro pixel-arcade look (mirrors Preferences.arcadeStyle; the peek card is taller for its lane).
    static var arcade = true
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    /// The black body, excluding the concave "ears" at the top corners.
    static func bodySize(_ mode: NotchMode, metrics m: NotchMetrics, rows: Int) -> CGSize {
        let nw = m.notchSize.width
        let nh = m.notchSize.height
        switch mode {
        case .hidden:
            return CGSize(width: nw, height: nh)
        case .compact:
            return CGSize(width: nw + wing * 2, height: nh)
        case .peek:
            return CGSize(width: max(nw + 236, 424), height: nh + (arcade ? 112 : 82))
        case .expanded:
            let r = CGFloat(min(max(rows, 1), maxRows))
            return CGSize(width: max(nw + 280, 468), height: nh + 14 + r * 54 + 40)
        }
    }

    /// Radius of the concave fillets where the shape meets the top edge (none for the island).
    static func ear(_ mode: NotchMode, island: Bool = false) -> CGFloat {
        if island { return 0 }
        return notchEar(mode)
    }

    private static func notchEar(_ mode: NotchMode) -> CGFloat {
        switch mode {
        case .hidden, .compact: return 6
        case .peek, .expanded: return 14
        }
    }

    static func corner(_ mode: NotchMode) -> CGFloat {
        switch mode {
        case .hidden: return 8
        case .compact: return 10
        case .peek: return 24
        case .expanded: return 26
        }
    }

    static func shapeSize(_ mode: NotchMode, metrics: NotchMetrics, rows: Int) -> CGSize {
        let body = bodySize(mode, metrics: metrics, rows: rows)
        return CGSize(width: body.width + ear(mode, island: metrics.island) * 2, height: body.height)
    }

    /// The silhouette for a mode: grown from the notch, or a floating island.
    static func shape(_ mode: NotchMode, island: Bool, height: CGFloat) -> NotchShape {
        island
            ? NotchShape(topRadius: 0, bottomRadius: islandCorner(mode, height: height), island: true)
            : NotchShape(topRadius: ear(mode), bottomRadius: corner(mode))
    }

    /// Island corners: a full capsule when small, generous rounded corners when it grows.
    static func islandCorner(_ mode: NotchMode, height: CGFloat) -> CGFloat {
        switch mode {
        case .hidden, .compact: return height / 2
        case .peek: return 28
        case .expanded: return 30
        }
    }
}

/// The notch silhouette: concave ears at the top, rounded corners at the bottom.
/// With `island`, a floating pill/rounded card instead (bottomRadius is the corner radius).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var island = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        if island {
            let r = max(0, min(bottomRadius, rect.height / 2, rect.width / 2))
            return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        }
        let tr = max(0, min(topRadius, rect.width / 4, rect.height / 2))
        let br = max(0, min(bottomRadius, (rect.width - tr * 2) / 2, rect.height - tr))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
