import CoreGraphics
import Foundation

// Bounded projected-depth geometry for native chart visibility.
enum ChartOcclusionFailure: Error { case degenerate, unsupportedMesh, fragmentBudget, noWitness, wrongOwner }

struct ChartProjectedVertex {
    let point: CGPoint
    let depth: Double
}

struct ChartProjectedTriangle {
    let vertices: [ChartProjectedVertex]
    let faceIndex: Int
    let primitiveIndex: Int
    let a: Double, b: Double, c: Double
    init(_ vertices: [ChartProjectedVertex], faceIndex: Int, primitiveIndex: Int) throws {
        guard vertices.count == 3,
            vertices.allSatisfy({ [Double($0.point.x), Double($0.point.y), $0.depth].allSatisfy(\.isFinite) }) else {
            throw ChartOcclusionFailure.degenerate
        }
        let p = vertices[0], q = vertices[1], r = vertices[2]
        let dx = Double(q.point.x - p.point.x), dy = Double(q.point.y - p.point.y)
        let ex = Double(r.point.x - p.point.x), ey = Double(r.point.y - p.point.y)
        let determinant = dx * ey - ex * dy
        guard determinant.isFinite, abs(determinant) > 1e-9 else { throw ChartOcclusionFailure.degenerate }
        let dd = q.depth - p.depth, ed = r.depth - p.depth
        let da = (dd * ey - ed * dy) / determinant
        let db = (dx * ed - ex * dd) / determinant
        let dc = p.depth - da * Double(p.point.x) - db * Double(p.point.y)
        guard [da,db,dc].allSatisfy(\.isFinite) else { throw ChartOcclusionFailure.degenerate }
        a = da; b = db; c = dc
        self.vertices = vertices; self.faceIndex = faceIndex; self.primitiveIndex = primitiveIndex
    }
    func depth(at point: CGPoint) -> Double { a * Double(point.x) + b * Double(point.y) + c }
    var polygon: [CGPoint] { vertices.map(\.point) }
    func contains(_ point: CGPoint) -> Bool { ChartProjectedClipping.contains(polygon, point) }
}

enum ChartProjectedClipping {
    static func area(_ polygon: [CGPoint]) -> Double {
        guard polygon.count >= 3 else { return 0 }
        return polygon.indices.reduce(0) { sum, index in
            let a = polygon[index], b = polygon[(index+1)%polygon.count]
            return sum + Double(a.x*b.y-b.x*a.y)/2
        }
    }
    static func cross(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> Double {
        Double((b.x-a.x)*(p.y-a.y) - (b.y-a.y)*(p.x-a.x))
    }
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        let signedArea = area(polygon)
        guard abs(signedArea) > 1e-9 else { return false }
        let sign = signedArea >= 0 ? 1.0 : -1.0
        return polygon.indices.allSatisfy { cross(polygon[$0], polygon[($0+1)%polygon.count], point) * sign >= -1e-8 }
    }
    /// Convex clipping by one affine half-plane. Keeps value >= 0.
    static func clip(_ polygon: [CGPoint], by value: (CGPoint) -> Double) -> [CGPoint] {
        guard polygon.count >= 3 else { return [] }
        var output: [CGPoint] = []
        var previous = polygon.last!, previousValue = value(previous)
        for current in polygon {
            let currentValue = value(current)
            let before = previousValue >= 0, after = currentValue >= 0
            if before != after {
                let denominator = previousValue-currentValue
                if abs(denominator) > 1e-14 {
                    let t = min(1, max(0, previousValue/denominator))
                    output.append(CGPoint(x: previous.x + (current.x-previous.x)*t,
                        y: previous.y + (current.y-previous.y)*t))
                }
            }
            if after { output.append(current) }
            previous = current; previousValue = currentValue
        }
        var distinct: [CGPoint] = []
        for point in output {
            if let last = distinct.last, hypot(point.x-last.x, point.y-last.y) <= 1e-10 { continue }
            distinct.append(point)
        }
        if let first = distinct.first, let last = distinct.last,
            hypot(first.x-last.x, first.y-last.y) <= 1e-10 { distinct.removeLast() }
        return distinct.count >= 3 && abs(area(distinct)) > 1e-9 ? distinct : []
    }
    static func intersect(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> [CGPoint] {
        guard rhs.count >= 3 else { return [] }
        let sign = area(rhs) >= 0 ? 1.0 : -1.0
        var value = lhs
        for index in rhs.indices {
            let a = rhs[index], b = rhs[(index+1)%rhs.count]
            value = clip(value) { cross(a,b,$0)*sign }
            if value.isEmpty { break }
        }
        return value
    }
    /// Exact near region for these affine facets, not a centroid/average sort.
    /// Depth grows toward the camera. Coplanar/tied surfaces do not occlude.
    static func frontRegion(receiver: ChartProjectedTriangle, occluder: ChartProjectedTriangle,
                            epsilon: Double = 1e-7) -> [CGPoint] {
        let overlap = intersect(receiver.polygon, occluder.polygon)
        return clip(overlap) { occluder.depth(at: $0) - receiver.depth(at: $0) - epsilon }
    }
    /// Partitions one convex region outside another into disjoint convex pieces.
    /// Do not combine overlapping cutter paths with even-odd (that creates XOR).
    static func bounds(_ polygon: [CGPoint]) -> CGRect {
        guard let first = polygon.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in polygon.dropFirst() {
            minX = min(minX,p.x); maxX = max(maxX,p.x)
            minY = min(minY,p.y); maxY = max(maxY,p.y)
        }
        return .init(x:minX,y:minY,width:maxX-minX,height:maxY-minY)
    }
    static func hasPositiveConvexOverlap(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        guard lhs.count >= 3, rhs.count >= 3 else { return false }
        func separates(_ edges: [CGPoint], _ points: [CGPoint]) -> Bool {
            let sign = area(edges) >= 0 ? 1.0 : -1.0
            for i in edges.indices {
                let a = edges[i], b = edges[(i+1)%edges.count]
                if points.allSatisfy({ cross(a,b,$0)*sign <= 0 }) { return true }
            }
            return false
        }
        // Convex separating-axis test. Exact half-plane comparisons introduce
        // no new epsilon or tiny-positive-area rejection threshold.
        return !separates(lhs,rhs) && !separates(rhs,lhs)
    }
    static func subtract(_ subject: [CGPoint], cutter: [CGPoint]) -> [[CGPoint]] {
        guard !subject.isEmpty else { return [] }
        guard cutter.count >= 3 else { return [subject] }
        // Disjoint cutters must not create partitions along their infinite
        // supporting lines. Even overlapping bounds can enclose disjoint shapes.
        if !bounds(subject).intersects(bounds(cutter)) || !hasPositiveConvexOverlap(subject,cutter) { return [subject] }
        let cutterSign = area(cutter) >= 0 ? 1.0 : -1.0
        if cutter.indices.allSatisfy({ i in
            subject.allSatisfy { cross(cutter[i],cutter[(i+1)%cutter.count],$0)*cutterSign >= 0 }
        }) { return [] } // Exact half-plane containment; no new tolerance/dilation.
        let sign = area(cutter) >= 0 ? 1.0 : -1.0
        var inside = subject, result: [[CGPoint]] = []
        for index in cutter.indices {
            let a = cutter[index], b = cutter[(index+1)%cutter.count]
            let outside = clip(inside) { -cross(a,b,$0)*sign }
            if !outside.isEmpty { result.append(outside) }
            inside = clip(inside) { cross(a,b,$0)*sign }
            if inside.isEmpty { break }
        }
        return result
    }
    /// Qualification-sized prototype, per ONE logical chart call only.
    /// A budget refusal is explicit; never fall back to the known-wrong sort.
    static func visible(_ receiver: ChartProjectedTriangle, among facets: [ChartProjectedTriangle],
                        maximumFragments: Int = 256) throws -> [[CGPoint]] {
        guard maximumFragments > 0 else { throw ChartOcclusionFailure.fragmentBudget }
        var pieces = [receiver.polygon]
        for other in facets where other.primitiveIndex != receiver.primitiveIndex {
            let cutter = frontRegion(receiver: receiver, occluder: other)
            if cutter.isEmpty { continue }
            var next: [[CGPoint]] = []
            for piece in pieces {
                next += subtract(piece, cutter: cutter)
                guard next.count <= maximumFragments else { throw ChartOcclusionFailure.fragmentBudget }
            }
            pieces = next
            if pieces.isEmpty { break }
        }
        return pieces
    }
    static func nearest(_ facets: [ChartProjectedTriangle], at point: CGPoint) -> ChartProjectedTriangle? {
        var nearest: ChartProjectedTriangle?
        for facet in facets where facet.contains(point) {
            if nearest == nil || facet.depth(at: point) > nearest!.depth(at: point) + 1e-7 { nearest = facet }
        }
        return nearest
    }
}
