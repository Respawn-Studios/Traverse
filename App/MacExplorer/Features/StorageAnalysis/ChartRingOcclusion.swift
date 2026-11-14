import CoreGraphics
import Foundation

// Visibility belongs to ONE actual chart() invocation, never a
// merged scene, ancestor stack, equal-alpha group or transition crossfade.
struct ChartRingOcclusionMetrics {
    var status = "resolved"
    var faces = 0, triangles = 0, facePairs = 0, broadPairs = 0, nearClips = 0
    var cutterVertices = 0, maskVertices = 0, peakFragments = 0
    var maximumFaceCutters = 0, maskSubtractionCalls = 0, unchangedSubtractions = 0
    var currentFace = -1, currentCutter = -1, currentPiece = -1, nextFragments = 0
    var refusalCode = 0, refusalFace = -1, refusalCutter = -1, refusalPiece = -1
    var nativeBooleanCalls = 0, nativeInputVertices = 0, nativeOutputElements = 0, nativeMaxSubpaths = 0, nativeMaxPointsPerSubpath = 0
    var resolveMilliseconds = 0.0
}

enum ChartRingOcclusion {
    // Scratch/result limits are independent; a pair limit alone does not bound
    // fragmented paths. Refusal is observable and fails candidate acceptance.
    static let maximumFaces = 300, maximumTriangles = 1_200
    static let maximumFacePairs = 45_000, maximumBroadPairs = 800_000
    static let maximumNearClips = 60_000, maximumCutterVertices = 48_000
    static let maximumMaskVertices = 96_000, maximumFragmentsPerFace = 512
    static let maximumVerticesPerFragment = 128

    static let maximumMaskSubtractions = 200_000
    static let maximumBooleanInputVerticesPerFace = 2_048
    private static func budget(_ condition: Bool, code: Int, metrics: inout ChartRingOcclusionMetrics) throws {
        if !condition { metrics.refusalCode = code; throw ChartOcclusionFailure.fragmentBudget }
    }
    private static func bounds(_ points: [CGPoint]) -> CGRect {
        points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
    private static func facets(_ vertices: [ChartProjectedVertex], face: Int,
                               next: inout Int) throws -> [ChartProjectedTriangle] {
        guard vertices.count >= 4, vertices.count.isMultiple(of: 2) else {
            throw ChartOcclusionFailure.unsupportedMesh
        }
        let half = vertices.count / 2
        var result: [ChartProjectedTriangle] = []
        for i in 0..<(half-1) {
            let quad = [vertices[i], vertices[i+1], vertices[2*half-2-i], vertices[2*half-1-i]]
            for triple in [[quad[0],quad[1],quad[2]], [quad[0],quad[2],quad[3]]] {
                do {
                    result.append(try .init(triple, faceIndex: face, primitiveIndex: next)); next += 1
                } catch ChartOcclusionFailure.degenerate { /* Zero-area edge-on patches paint no interior. */ }
            }
        }
        return result
    }
    private static func add(_ pieces: [[CGPoint]], to path: CGMutablePath) {
        for piece in pieces {
            guard let first = piece.first else { continue }
            path.move(to: first)
            for point in piece.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
    }

    static func resolve(_ original: [StorageChartFace], raised: StorageChartHit) -> [StorageChartFace] {
        var metrics = ChartRingOcclusionMetrics(); metrics.faces = original.count
        let began = ProcessInfo.processInfo.systemUptime
        do {
            var result = try resolve(original, raised: raised, metrics: &metrics)
            metrics.resolveMilliseconds = (ProcessInfo.processInfo.systemUptime-began)*1000
            if !result.isEmpty { result[0].occlusionMetrics = metrics }
            return result
        }
        catch {
            // Retain the unresolved observations and marker. The geometry
            // caller uses seated painting; qualification still rejects a
            // refused ordinary cohort rather than crediting the fallback.
            var result = original; metrics.status = "refused"
            metrics.resolveMilliseconds = (ProcessInfo.processInfo.systemUptime-began)*1000
            if metrics.refusalCode == 0 { metrics.refusalCode = 99 }
            metrics.refusalFace = metrics.currentFace; metrics.refusalCutter = metrics.currentCutter; metrics.refusalPiece = metrics.currentPiece
            if !result.isEmpty { result[0].occlusionMetrics = metrics }
            return result
        }
    }
    private static func resolve(_ original: [StorageChartFace], raised: StorageChartHit,
                                metrics: inout ChartRingOcclusionMetrics) throws -> [StorageChartFace] {
        try budget(original.count <= maximumFaces,code:1,metrics:&metrics)
        var mesh: [[ChartProjectedTriangle]] = [], next = 0
        for (index, face) in original.enumerated() {
            mesh.append(try facets(face.projectedVertices, face: index, next: &next))
            try budget(next <= maximumTriangles,code:2,metrics:&metrics)
        }
        metrics.triangles = next
        let facetBounds = mesh.map { $0.map { bounds($0.polygon) } }
        var cutters = Array(repeating: [[CGPoint]](), count: original.count)
        // Face broad phase is restricted to the one raised/unraised partition.
        // Each unordered face pair is visited once. Triangle bounds reject before
        // convex overlap/affine depth evaluation; never pair across chart calls.
        for i in original.indices {
            for j in original.indices where j > i && (original[i].hit == raised) != (original[j].hit == raised) {
                metrics.facePairs += 1
                try budget(metrics.facePairs <= maximumFacePairs,code:3,metrics:&metrics)
                guard original[i].bounds.intersects(original[j].bounds) else { continue }
                for (a, receiver) in mesh[i].enumerated() {
                    for (b, other) in mesh[j].enumerated() {
                        metrics.broadPairs += 1
                        try budget(metrics.broadPairs <= maximumBroadPairs,code:4,metrics:&metrics)
                        guard facetBounds[i][a].intersects(facetBounds[j][b]) else { continue }
                        metrics.nearClips += 2
                        try budget(metrics.nearClips <= maximumNearClips,code:5,metrics:&metrics)
                        let left = ChartProjectedClipping.frontRegion(receiver: receiver, occluder: other)
                        let right = ChartProjectedClipping.frontRegion(receiver: other, occluder: receiver)
                        metrics.cutterVertices += left.count + right.count
                        try budget(metrics.cutterVertices <= maximumCutterVertices,code:6,metrics:&metrics)
                        if !left.isEmpty { cutters[i].append(left) }
                        if !right.isEmpty { cutters[j].append(right) }
                    }
                }
            }
        }
        var result = original
        metrics.maximumFaceCutters = cutters.map(\.count).max() ?? 0
        for index in original.indices where !cutters[index].isEmpty {
            metrics.currentFace = index
            // Exclusion mask, NOT re-tessellated paint: a generous rectangle
            // minus the UNION of hidden regions leaves original boundary strokes
            // and wall seam overlap unchanged outside those hidden regions.
            // Repeated subtraction produces disjoint pieces; even-odd/XOR holes
            // are never used for overlapping occluders.
            let r = original[index].bounds.insetBy(dx: -4, dy: -4)
            var pieces = [[CGPoint(x: r.minX,y: r.minY), CGPoint(x: r.maxX,y: r.minY),
                           CGPoint(x: r.maxX,y: r.maxY), CGPoint(x: r.minX,y: r.maxY)]]
            for (cutterIndex,cutter) in cutters[index].enumerated() {
                metrics.currentCutter = cutterIndex
                var updated: [[CGPoint]] = []
                var updatedVertices = 0
                for (pieceIndex,piece) in pieces.enumerated() {
                    metrics.currentPiece = pieceIndex
                    metrics.maskSubtractionCalls += 1
                    try budget(metrics.maskSubtractionCalls <= maximumMaskSubtractions,code:10,metrics:&metrics)
                    let outside = ChartProjectedClipping.subtract(piece, cutter: cutter)
                    if outside.count == 1 && outside[0] == piece { metrics.unchangedSubtractions += 1 }
                    metrics.nextFragments = updated.count + outside.count
                    try budget(outside.allSatisfy({ $0.count <= maximumVerticesPerFragment }),code:7,metrics:&metrics)
                    updatedVertices += outside.reduce(0) { $0 + $1.count }
                    try budget(updated.count + outside.count <= maximumFragmentsPerFace,code:8,metrics:&metrics)
                    try budget(metrics.maskVertices + updatedVertices <= maximumMaskVertices,code:9,metrics:&metrics)
                    updated += outside
                }
                pieces = updated
                metrics.peakFragments = max(metrics.peakFragments, pieces.count)
                if pieces.isEmpty { break }
            }
            metrics.maskVertices += pieces.reduce(0) { $0 + $1.count }
            try budget(metrics.maskVertices <= maximumMaskVertices,code:9,metrics:&metrics)
            let path = CGMutablePath(); add(pieces, to: path)
            result[index].visibleCoverage = path
        }
        if !result.isEmpty { result[0].occlusionMetrics = metrics }
        return result
    }
}
