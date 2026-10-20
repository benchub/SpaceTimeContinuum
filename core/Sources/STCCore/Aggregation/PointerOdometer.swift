import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#else
/// swift-corelibs-foundation has CGPoint/CGRect but not CGVector.
public struct CGVector: Equatable, Sendable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }
}
#endif

/// A display's position in the global (point-based) desktop space and its physical size.
public struct DisplayGeometry: Equatable, Sendable {
    public var id: UInt32
    /// Bounds in global desktop points.
    public var bounds: CGRect
    /// Physical size reported by the OS (EDID); may be zero or nonsense for TVs/projectors.
    public var physicalSizeMM: CGSize

    /// Used when the OS can't tell us a believable physical size (~100 points per inch).
    public static let fallbackMetersPerPoint = 0.0254 / 100

    public init(id: UInt32, bounds: CGRect, physicalSizeMM: CGSize) {
        self.id = id
        self.bounds = bounds
        self.physicalSizeMM = physicalSizeMM
    }

    /// Meters per point horizontally and vertically. Accounts for scaled (Retina) modes
    /// because bounds are in points, and for rotated displays reporting unrotated sizes.
    public var metersPerPoint: (x: Double, y: Double) {
        let bw = Double(bounds.width), bh = Double(bounds.height)
        var pw = Double(physicalSizeMM.width), ph = Double(physicalSizeMM.height)
        guard bw > 0, bh > 0, pw > 0, ph > 0 else {
            return (Self.fallbackMetersPerPoint, Self.fallbackMetersPerPoint)
        }
        // Rotated display whose physical size wasn't rotated with it.
        if (bw > bh) != (pw > ph), abs(bw - bh) > 1, abs(pw - ph) > 1 { swap(&pw, &ph) }
        let x = pw / 1000 / bw, y = ph / 1000 / bh
        // Plausible range: 30–500 points per inch.
        let plausible = (0.0254 / 500)...(0.0254 / 30)
        guard plausible.contains(x), plausible.contains(y) else {
            return (Self.fallbackMetersPerPoint, Self.fallbackMetersPerPoint)
        }
        return (x, y)
    }
}

/// Converts successive pointer locations into physical distance on screen.
public struct PointerOdometer: Sendable {
    public var displays: [DisplayGeometry]
    private var last: CGPoint?

    public init(displays: [DisplayGeometry] = []) {
        self.displays = displays
    }

    /// Forget the last location (after sleep, display changes, etc.).
    public mutating func reset() { last = nil }

    /// Distance in meters from the previous location to `point`.
    /// - Parameter rawDelta: the device-reported movement for this event, if known. Used to ignore
    ///   programmatic cursor warps, which change the location without the user moving anything.
    public mutating func move(to point: CGPoint, rawDelta: CGVector? = nil) -> Double {
        defer { last = point }
        guard let from = last else { return 0 }
        let dx = Double(point.x - from.x), dy = Double(point.y - from.y)
        guard dx != 0 || dy != 0 else { return 0 }
        if let raw = rawDelta {
            let rawLen = hypot(Double(raw.dx), Double(raw.dy))
            if hypot(dx, dy) > rawLen * 3 + 50 { return 0 }
        }
        let a = scale(at: from), b = scale(at: point)
        let sx = (a.x + b.x) / 2, sy = (a.y + b.y) / 2
        return hypot(dx * sx, dy * sy)
    }

    private func scale(at p: CGPoint) -> (x: Double, y: Double) {
        if let d = displays.first(where: { $0.bounds.contains(p) }) { return d.metersPerPoint }
        // Points on the far edge (maxX/maxY) aren't "contained"; use the nearest display.
        let nearest = displays.min { distance(p, $0.bounds) < distance(p, $1.bounds) }
        return nearest?.metersPerPoint ?? (DisplayGeometry.fallbackMetersPerPoint, DisplayGeometry.fallbackMetersPerPoint)
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        let dx = max(Double(r.minX - p.x), 0, Double(p.x - r.maxX))
        let dy = max(Double(r.minY - p.y), 0, Double(p.y - r.maxY))
        return hypot(dx, dy)
    }
}
