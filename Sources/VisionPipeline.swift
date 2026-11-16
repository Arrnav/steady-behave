import CoreImage
import CoreVideo
import Foundation
import Vision

/// A body or hand joint in normalized image coordinates (0...1, origin bottom-left).
struct Joint {
    let name: String
    let point: CGPoint
    let confidence: Float
}

struct HandPose {
    /// -1 left, 1 right, 0 unknown (as Vision reports it from the camera's point of view).
    let chirality: Int
    let joints: [String: Joint]
}

/// Everything Vision found in one processed frame.
struct FrameAnalysis {
    var time: Double = 0
    var imageSize = CGSize(width: 640, height: 480)
    var facePresent = false
    /// Normalized face bounding box (origin bottom-left).
    var faceBox = CGRect.zero
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
    var landmarks: Landmarks = [:]
    /// Inter-ocular distance in pixels.
    var iod = 0.0
    var smileFeatures: [Double]?
    var gazeFeatures: [Double]?
    /// nil when hand pose did not run on this frame.
    var hands: [HandPose]?
    /// nil when body pose did not run on this frame.
    var body: [String: Joint]?
    /// Mean absolute difference from the previous small frame, 0...255.
    var motionEnergy = 0.0
    /// 64x48 frame difference, row 0 at the top.
    var motionMap: [UInt8] = []
    var processingMs = 0.0
}

/// Runs the Vision requests on one camera frame.
final class VisionPipeline {
    static let motionWidth = 64
    static let motionHeight = 48

    static let handJointNames: [(VNHumanHandPoseObservation.JointName, String)] = [
        (.wrist, "wrist"),
        (.thumbCMC, "thumbCMC"), (.thumbMP, "thumbMP"), (.thumbIP, "thumbIP"), (.thumbTip, "thumbTip"),
        (.indexMCP, "indexMCP"), (.indexPIP, "indexPIP"), (.indexDIP, "indexDIP"), (.indexTip, "indexTip"),
        (.middleMCP, "middleMCP"), (.middlePIP, "middlePIP"), (.middleDIP, "middleDIP"), (.middleTip, "middleTip"),
        (.ringMCP, "ringMCP"), (.ringPIP, "ringPIP"), (.ringDIP, "ringDIP"), (.ringTip, "ringTip"),
        (.littleMCP, "littleMCP"), (.littlePIP, "littlePIP"), (.littleDIP, "littleDIP"), (.littleTip, "littleTip")
    ]

    static let handChains: [[String]] = [
        ["wrist", "thumbCMC", "thumbMP", "thumbIP", "thumbTip"],
        ["wrist", "indexMCP", "indexPIP", "indexDIP", "indexTip"],
        ["wrist", "middleMCP", "middlePIP", "middleDIP", "middleTip"],
        ["wrist", "ringMCP", "ringPIP", "ringDIP", "ringTip"],
        ["wrist", "littleMCP", "littlePIP", "littleDIP", "littleTip"]
    ]

    static let bodyJointNames: [(VNHumanBodyPoseObservation.JointName, String)] = [
        (.nose, "nose"), (.leftEye, "leftEye"), (.rightEye, "rightEye"), (.leftEar, "leftEar"), (.rightEar, "rightEar"),
        (.neck, "neck"), (.leftShoulder, "leftShoulder"), (.rightShoulder, "rightShoulder"),
        (.leftElbow, "leftElbow"), (.rightElbow, "rightElbow"), (.leftWrist, "leftWrist"), (.rightWrist, "rightWrist")
    ]

    static let bodyBones: [(String, String)] = [
        ("leftShoulder", "rightShoulder"), ("neck", "nose"),
        ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
        ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
        ("nose", "leftEye"), ("nose", "rightEye"), ("leftEye", "leftEar"), ("rightEye", "rightEar")
    ]

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private var previousSmall: [UInt8]?
    private var lastFace: VNFaceObservation?
    private var framesSinceDetect = 0
    let faceDetectEvery = 3

    /// Average milliseconds per stage, smoothed, for the debug window.
    static let stageTimes = Locked<[String: Double]>([:])
    private var stageAccum: [String: Double] = [:]

    private func timed<T>(_ stage: String, _ work: () -> T) -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = work()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        stageAccum[stage] = (stageAccum[stage] ?? ms) * 0.9 + ms * 0.1
        return result
    }

    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        return r
    }()

    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        return r
    }()

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    private let bodyRequest = VNDetectHumanBodyPoseRequest()

    func reset() {
        previousSmall = nil
        lastFace = nil
    }

    func analyze(_ pixelBuffer: CVPixelBuffer, time: Double, runHands: Bool, runBody: Bool) -> FrameAnalysis {
        let start = CFAbsoluteTimeGetCurrent()
        var a = FrameAnalysis()
        a.time = time
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        a.imageSize = CGSize(width: w, height: h)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        // 1. Face rectangles (largest face), then 2. landmarks for that face only.
        // Full face detection runs every `faceDetectEvery` frames. In between, the last landmark
        // observation is passed back in as the face, which costs about a third less CPU. A low
        // landmark confidence forces a full detection on the next frame.
        var faceObs: VNFaceObservation?
        if let last = lastFace, framesSinceDetect < faceDetectEvery - 1 {
            faceObs = last
            framesSinceDetect += 1
        } else {
            timed("Face") { try? handler.perform([faceRequest]) }
            faceObs = (faceRequest.results ?? []).max(by: { $0.boundingBox.area < $1.boundingBox.area })
            framesSinceDetect = 0
        }
        lastFace = nil
        if let face = faceObs {
            landmarksRequest.inputFaceObservations = [face]
            timed("Landmarks") { try? handler.perform([landmarksRequest]) }
            if let lmFace = landmarksRequest.results?.first, let lm = lmFace.landmarks, lm.confidence >= 0.5 {
                faceObs = lmFace
                lastFace = lmFace
            } else {
                faceObs = nil
            }
        }
        if let face = faceObs {
            a.facePresent = true
            a.faceBox = face.boundingBox
            a.yaw = face.yaw?.doubleValue ?? 0
            a.pitch = face.pitch?.doubleValue ?? 0
            a.roll = face.roll?.doubleValue ?? 0
            if let lm = face.landmarks {
                a.landmarks = Self.regions(lm, imageSize: a.imageSize)
                if let le = a.landmarks[.leftEye], let re = a.landmarks[.rightEye] {
                    a.iod = FaceFeatures.distance(FaceFeatures.centroid(le), FaceFeatures.centroid(re))
                }
                // Smile features get unreliable when the head turns or the face is tiny.
                if abs(a.yaw) <= 0.35, a.iod >= 22 {
                    a.smileFeatures = FaceFeatures.smile(a.landmarks)
                }
                a.gazeFeatures = FaceFeatures.gaze(a.landmarks, yaw: a.yaw, pitch: a.pitch, roll: a.roll, faceBox: a.faceBox)
            }
        }

        // 3. Hands.
        if runHands {
            timed("Hands") { try? handler.perform([handRequest]) }
            a.hands = (handRequest.results ?? []).map { obs in
                var joints: [String: Joint] = [:]
                if let points = try? obs.recognizedPoints(.all) {
                    for (key, name) in Self.handJointNames {
                        if let p = points[key], p.confidence > 0.3 {
                            joints[name] = Joint(name: name, point: p.location, confidence: p.confidence)
                        }
                    }
                }
                let chir: Int
                switch obs.chirality {
                case .left: chir = -1
                case .right: chir = 1
                default: chir = 0
                }
                return HandPose(chirality: chir, joints: joints)
            }
        }

        // 4. Upper body.
        if runBody {
            timed("Body") { try? handler.perform([bodyRequest]) }
            var joints: [String: Joint] = [:]
            if let obs = bodyRequest.results?.first, let points = try? obs.recognizedPoints(.all) {
                for (key, name) in Self.bodyJointNames {
                    if let p = points[key], p.confidence > 0.3 {
                        joints[name] = Joint(name: name, point: p.location, confidence: p.confidence)
                    }
                }
            }
            a.body = joints
        }

        // 5. Motion energy on a tiny grayscale frame.
        timed("Motion") { computeMotion(pixelBuffer, width: w, height: h, into: &a) }

        a.processingMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Self.stageTimes.set(stageAccum)
        return a
    }

    private func computeMotion(_ pixelBuffer: CVPixelBuffer, width: Int, height: Int, into a: inout FrameAnalysis) {
        guard let small = Self.smallGray(pixelBuffer, context: ciContext) else { return }
        let count = Self.motionWidth * Self.motionHeight
        if let prev = previousSmall, prev.count == count {
            var sum = 0
            var diff = [UInt8](repeating: 0, count: count)
            for i in 0..<count {
                let d = abs(Int(small[i]) - Int(prev[i]))
                sum += d
                diff[i] = UInt8(min(255, d))
            }
            a.motionEnergy = Double(sum) / Double(count)
            a.motionMap = diff
        }
        previousSmall = small
    }

    /// A 64x48 grayscale copy of the frame, row 0 at the top.
    /// For YUV frames this block-averages the luma plane directly, which is very cheap.
    /// Other formats go through CoreImage.
    static func smallGray(_ pixelBuffer: CVPixelBuffer, context: CIContext) -> [UInt8]? {
        let mw = motionWidth, mh = motionHeight
        var small = [UInt8](repeating: 0, count: mw * mh)
        if CVPixelBufferIsPlanar(pixelBuffer) {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
            let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let luma = base.assumingMemoryBound(to: UInt8.self)
            let bw = max(1, w / mw), bh = max(1, h / mh)
            // Sample a 4x4 grid inside each block; enough for an average and much faster than every pixel.
            let sx = max(1, bw / 4), sy = max(1, bh / 4)
            for by in 0..<mh {
                for bx in 0..<mw {
                    var total = 0, n = 0
                    var y = by * bh
                    while y < min(h, (by + 1) * bh) {
                        let row = luma + y * rowBytes
                        var x = bx * bw
                        while x < min(w, (bx + 1) * bw) {
                            total += Int(row[x]); n += 1
                            x += sx
                        }
                        y += sy
                    }
                    small[by * mw + bx] = UInt8(total / max(1, n))
                }
            }
            return small
        }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(mw) / CGFloat(w), y: CGFloat(mh) / CGFloat(h)))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        small.withUnsafeMutableBytes { ptr in
            context.render(image, toBitmap: ptr.baseAddress!, rowBytes: mw,
                           bounds: CGRect(x: 0, y: 0, width: mw, height: mh), format: .L8, colorSpace: nil)
        }
        return small
    }

    static func regions(_ lm: VNFaceLandmarks2D, imageSize: CGSize) -> Landmarks {
        var out: Landmarks = [:]
        let pairs: [(LandmarkRegion, VNFaceLandmarkRegion2D?)] = [
            (.faceContour, lm.faceContour), (.leftEyebrow, lm.leftEyebrow), (.rightEyebrow, lm.rightEyebrow),
            (.leftEye, lm.leftEye), (.rightEye, lm.rightEye), (.leftPupil, lm.leftPupil), (.rightPupil, lm.rightPupil),
            (.nose, lm.nose), (.noseCrest, lm.noseCrest), (.medianLine, lm.medianLine),
            (.outerLips, lm.outerLips), (.innerLips, lm.innerLips)
        ]
        for (key, region) in pairs {
            if let region, region.pointCount > 0 {
                out[key] = region.pointsInImage(imageSize: imageSize)
            }
        }
        return out
    }
}

extension CGRect {
    var area: CGFloat { width * height }
}
