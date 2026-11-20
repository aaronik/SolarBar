import SwiftUI

enum ChartLine {
    /// A single addLines call includes the first edge even for a two-point segment.
    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    /// Reduce each continuous segment independently. Keep first, low, high and last in
    /// each pixel column in their original order so short-lived spikes and gaps survive.
    static func reduced(_ points: [CGPoint], columns: Int) -> [CGPoint] {
        guard columns > 0, points.count > columns * 4 else { return points }
        var result: [CGPoint] = []
        var start = 0
        while start < points.count {
            let column = Int(points[start].x * Double(columns))
            var end = start + 1, low = start, high = start
            while end < points.count && Int(points[end].x * Double(columns)) == column {
                if points[end].y < points[low].y { low = end }
                if points[end].y > points[high].y { high = end }
                end += 1
            }
            let indices = [start, low, high, end - 1].sorted()
            for i in indices.indices where i == 0 || indices[i] != indices[i - 1] { result.append(points[indices[i]]) }
            start = end
        }
        return result
    }
}
