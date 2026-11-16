import CoreGraphics
import Foundation

/// Landmark regions Vision returns for a face, in image pixel coordinates (origin bottom-left).
enum LandmarkRegion: String, CaseIterable {
    case faceContour, leftEyebrow, rightEyebrow, leftEye, rightEye, leftPupil, rightPupil
    case nose, noseCrest, medianLine, outerLips, innerLips

    /// Regions drawn as closed loops in debug mode.
    var isClosed: Bool {
        switch self {
        case .leftEye, .rightEye, .outerLips, .innerLips, .nose: return true
        default: return false
        }
    }
}

typealias Landmarks = [LandmarkRegion: [CGPoint]]

/// Turns face landmarks into small feature vectors that don't depend on distance or head roll.
enum FaceFeatures {
    static let smileNames = [
        "Mouth width", "Outer lip height", "Inner lip opening", "Corner lift", "Mouth to eye line",
        "Nose to mouth", "Left eye openness", "Right eye openness", "Brow to eye", "Mouth / jaw width",
        "Upper lip curve"
    ]
    static let smileCount = 11

    static let gazeNames = [
        "Yaw", "Pitch", "Roll", "Left pupil x", "Left pupil y", "Right pupil x", "Right pupil y",
        "Left eye openness", "Right eye openness", "Face x", "Face y", "Face height"
    ]
    static let gazeCount = 12

    /// Maps image points into a face frame: origin at the eye midpoint, x along the eye line,
    /// one unit = inter-ocular distance (IOD). This removes scale and head roll.
    struct Normalizer {
        let origin: CGPoint
        let cosA: Double
        let sinA: Double
        let iod: Double

        init?(leftEye: [CGPoint], rightEye: [CGPoint]) {
            guard !leftEye.isEmpty, !rightEye.isEmpty else { return nil }
            var a = centroid(leftEye), b = centroid(rightEye)
            // Always run from the lower-x eye to the higher-x eye.
            if a.x > b.x { swap(&a, &b) }
            let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
            let d = (dx * dx + dy * dy).squareRoot()
            guard d > 1e-6 else { return nil }
            origin = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let angle = atan2(dy, dx)
            cosA = cos(-angle)
            sinA = sin(-angle)
            iod = d
        }

        func apply(_ p: CGPoint) -> CGPoint {
            let x = Double(p.x - origin.x), y = Double(p.y - origin.y)
            return CGPoint(x: (x * cosA - y * sinA) / iod, y: (x * sinA + y * cosA) / iod)
        }

        func apply(_ points: [CGPoint]) -> [CGPoint] { points.map(apply) }
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in points { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }

    static func extent(_ points: [CGPoint]) -> (width: Double, height: Double) {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return (0, 0) }
        return (Double(maxX - minX), Double(maxY - minY))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func openness(_ eye: [CGPoint]) -> Double {
        let e = extent(eye)
        return e.width > 1e-6 ? e.height / e.width : 0
    }

    /// Mouth corners: the lowest-x and highest-x outer-lip points in the face frame.
    static func corners(_ outer: [CGPoint]) -> (CGPoint, CGPoint)? {
        guard let left = outer.min(by: { $0.x < $1.x }), let right = outer.max(by: { $0.x < $1.x }) else { return nil }
        return (left, right)
    }

    /// The 11-value smile vector. Returns nil when a needed region is missing.
    static func smile(_ lm: Landmarks) -> [Double]? {
        guard let le = lm[.leftEye], let re = lm[.rightEye],
              let n = Normalizer(leftEye: le, rightEye: re),
              let outerRaw = lm[.outerLips], outerRaw.count >= 6,
              let innerRaw = lm[.innerLips], !innerRaw.isEmpty,
              let noseRaw = lm[.nose], !noseRaw.isEmpty,
              let contourRaw = lm[.faceContour], contourRaw.count >= 3
        else { return nil }

        let outer = n.apply(outerRaw)
        let inner = n.apply(innerRaw)
        let leftEye = n.apply(le), rightEye = n.apply(re)
        guard let (c1, c2) = corners(outer) else { return nil }

        let width = distance(c1, c2)
        let outerHeight = extent(outer).height
        let innerHeight = extent(inner).height
        let cornerY = Double(c1.y + c2.y) / 2
        let mouthCenter = centroid(outer)
        let cornerLift = cornerY - Double(mouthCenter.y)
        // The eye line is the x axis of the face frame, so this is just |y|.
        let mouthToEyeLine = abs(Double(mouthCenter.y))
        let noseToMouth = distance(centroid(n.apply(noseRaw)), mouthCenter)
        let leftOpen = openness(leftEye)
        let rightOpen = openness(rightEye)

        var browToEye = 0.0
        var sides = 0.0
        if let lb = lm[.leftEyebrow], !lb.isEmpty {
            browToEye += abs(Double(centroid(n.apply(lb)).y - centroid(leftEye).y)); sides += 1
        }
        if let rb = lm[.rightEyebrow], !rb.isEmpty {
            browToEye += abs(Double(centroid(n.apply(rb)).y - centroid(rightEye).y)); sides += 1
        }
        browToEye = sides > 0 ? browToEye / sides : 0

        let jawWidth = extent(n.apply(contourRaw)).width
        let mouthOverJaw = jawWidth > 1e-6 ? width / jawWidth : 0

        // Upper lip midpoint: of the outer-lip points nearest the mouth's centre line,
        // take the one closest to the eye line.
        let midX = Double(c1.x + c2.x) / 2
        let nearCenter = outer.sorted { abs(Double($0.x) - midX) < abs(Double($1.x) - midX) }.prefix(2)
        let upperMid = nearCenter.min { abs($0.y) < abs($1.y) } ?? mouthCenter
        let upperCurve = Double(upperMid.y) - cornerY

        return [width, outerHeight, innerHeight, cornerLift, mouthToEyeLine, noseToMouth,
                leftOpen, rightOpen, browToEye, mouthOverJaw, upperCurve]
    }

    /// The 12-value gaze vector: head pose, pupil offsets, eye openness and face position.
    static func gaze(_ lm: Landmarks, yaw: Double, pitch: Double, roll: Double, faceBox: CGRect) -> [Double]? {
        guard let le = lm[.leftEye], let re = lm[.rightEye],
              let n = Normalizer(leftEye: le, rightEye: re) else { return nil }
        let leftEye = n.apply(le), rightEye = n.apply(re)

        func pupilOffset(_ pupil: [CGPoint]?, eye: [CGPoint]) -> (Double, Double) {
            guard let pupil, let p = pupil.first else { return (0, 0) }
            let c = centroid(eye)
            let w = max(extent(eye).width, 1e-6)
            let q = n.apply(p)
            return (Double(q.x - c.x) / w, Double(q.y - c.y) / w)
        }
        let (lx, ly) = pupilOffset(lm[.leftPupil], eye: leftEye)
        let (rx, ry) = pupilOffset(lm[.rightPupil], eye: rightEye)

        return [yaw, pitch, roll, lx, ly, rx, ry, openness(leftEye), openness(rightEye),
                Double(faceBox.midX), Double(faceBox.midY), Double(faceBox.height)]
    }
}
