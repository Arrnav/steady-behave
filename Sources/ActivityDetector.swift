import CoreGraphics
import Foundation

/// Tracks a "calm" level for a signal: the median of the lowest 30% of per-second
/// averages over the last 10 minutes. It follows quiet periods and ignores busy ones.
struct CalmBaseline {
    var floor: Double
    var initial: Double?
    private var seconds: [Double] = []
    private var bucketSum = 0.0
    private var bucketCount = 0
    private var bucketStart: Double?
    private(set) var value: Double

    init(floor: Double, initial: Double? = nil) {
        self.floor = floor
        self.initial = initial
        value = max(floor, initial ?? floor)
    }

    mutating func add(_ x: Double, now: Double) {
        if bucketStart == nil { bucketStart = now }
        bucketSum += x
        bucketCount += 1
        if let start = bucketStart, now - start >= 1 {
            seconds.append(bucketSum / Double(max(1, bucketCount)))
            if seconds.count > 600 { seconds.removeFirst(seconds.count - 600) }
            bucketSum = 0; bucketCount = 0; bucketStart = now
            recompute()
        }
    }

    /// True once there is a calibrated value or at least 30 seconds of data.
    var isWarm: Bool { initial != nil || seconds.count >= 30 }
    var secondsOfData: Int { seconds.count }

    mutating func setInitial(_ x: Double) {
        initial = x
        recompute()
    }

    private mutating func recompute() {
        guard seconds.count >= 30 else {
            value = max(floor, initial ?? (seconds.isEmpty ? floor : seconds.sorted()[seconds.count / 2]))
            return
        }
        let sorted = seconds.sorted()
        let low = sorted.prefix(max(1, Int(Double(sorted.count) * 0.3)))
        value = max(floor, low[low.count / 2])
    }
}

/// Fidget and over-activity signals: motion, head speed, upper-body movement and hands near the face.
/// Runs on the camera queue.
final class ActivityDetector {
    struct Output {
        var score = 1.0
        var motionRatio = 1.0
        var headRatio = 1.0
        var bodyRatio = 1.0
        var handFraction = 0.0
        var handNear = false
        var handHeld = 0.0
        var motionBaseline = 0.0
        var headBaseline = 0.0
        var bodyBaseline = 0.0
        /// Seconds of data behind each baseline (motion, head, body).
        var baselineSeconds = (0, 0, 0)
        /// The hand-near-face zone used this frame (normalized, origin bottom-left).
        var handZone: CGRect?
        var overActiveEvents: [EpisodeTracker.Event] = []
        var handsEvents: [EpisodeTracker.Event] = []
        /// True once per hands episode when it has lasted long enough to save a clip.
        var handsClipDue = false
        /// Over-active alerts wait until the motion and head baselines have about 30 seconds of data.
        var warmingUp = false
    }

    private var motion = CalmBaseline(floor: 0.6)
    private var head = CalmBaseline(floor: 0.08)
    private var body = CalmBaseline(floor: 0.03)

    private var motionWindow: [(Double, Double)] = []
    private var headWindow: [(Double, Double)] = []
    private var bodyWindow: [(Double, Double)] = []
    private var handWindow: [(Double, Bool)] = []

    private struct FaceSample {
        let time: Double
        let center: CGPoint
        let yaw: Double
        let box: CGRect
    }

    private var lastFace: FaceSample?
    private var lastBody: (time: Double, joints: [String: Joint])?
    private var handNear = false
    private var handsClipSent = false

    private var overActive = EpisodeTracker(hold: 3, cooldown: 60, maxAlerts: 1, release: 1)
    private var hands = EpisodeTracker(hold: 2, cooldown: 30, maxAlerts: 1, release: 0.8)
    private(set) var output = Output()

    func setCalmMotion(_ value: Double) {
        motion.setInitial(value)
    }

    /// Starts the calm levels over, for example after the camera quality changes.
    func resetBaselines(calmMotion: Double?) {
        motion = CalmBaseline(floor: 0.6, initial: calmMotion)
        head = CalmBaseline(floor: 0.08)
        body = CalmBaseline(floor: 0.03)
        motionWindow.removeAll(); headWindow.removeAll(); bodyWindow.removeAll(); handWindow.removeAll()
        lastFace = nil
        lastBody = nil
    }

    static func handZone(for face: CGRect) -> CGRect {
        // 15% wider on each side and 35% taller downwards, to cover the chin area below the face box.
        CGRect(x: face.minX - face.width * 0.15, y: face.minY - face.height * 0.35,
               width: face.width * 1.3, height: face.height * 1.35)
    }

    private static func trim<T>(_ window: inout [(Double, T)], now: Double, span: Double) {
        while let first = window.first, now - first.0 > span { window.removeFirst() }
    }

    private static func mean(_ window: [(Double, Double)]) -> Double? {
        guard !window.isEmpty else { return nil }
        return window.reduce(0) { $0 + $1.1 } / Double(window.count)
    }

    func update(analysis a: FrameAnalysis, overActiveEnabled: Bool, handsEnabled: Bool, settings: Settings, now: Double) -> Output {
        overActive.hold = settings.activityHold
        overActive.cooldown = settings.activityCooldown
        hands.hold = settings.handsHold
        hands.cooldown = settings.handsCooldown

        var out = Output()

        // Motion energy.
        motionWindow.append((now, a.motionEnergy))
        motion.add(a.motionEnergy, now: now)

        // Head speed: face centre movement in IODs per second plus yaw change in radians per second.
        if a.facePresent, a.iod > 1 {
            let center = CGPoint(x: a.faceBox.midX * a.imageSize.width, y: a.faceBox.midY * a.imageSize.height)
            if let last = lastFace, now - last.time > 0.01, now - last.time < 1 {
                let dt = now - last.time
                let move = FaceFeatures.distance(center, last.center) / max(a.iod, 1)
                let speed = (move + abs(a.yaw - last.yaw)) / dt
                headWindow.append((now, speed))
                head.add(speed, now: now)
            }
            lastFace = FaceSample(time: now, center: center, yaw: a.yaw, box: a.faceBox)
        }

        // Upper-body movement: mean joint displacement, in shoulder widths per second.
        if let joints = a.body {
            if let last = lastBody, now - last.time < 1.5, now - last.time > 0.01 {
                var total = 0.0, count = 0.0
                for (name, j) in joints {
                    if let prev = last.joints[name] {
                        total += FaceFeatures.distance(j.point, prev.point); count += 1
                    }
                }
                var scale = 0.25
                if let ls = joints["leftShoulder"], let rs = joints["rightShoulder"] {
                    scale = max(0.05, FaceFeatures.distance(ls.point, rs.point))
                }
                if count > 0 {
                    let speed = (total / count) / scale / (now - last.time)
                    bodyWindow.append((now, speed))
                    body.add(speed, now: now)
                }
            }
            lastBody = (now, joints)
        }

        // Hand near face. Keep using the last face box for a moment, because a hand can hide the face.
        var faceBox: CGRect?
        if a.facePresent { faceBox = a.faceBox } else if let last = lastFace, now - last.time < 3 { faceBox = last.box }
        if let faceBox { out.handZone = Self.handZone(for: faceBox) }
        if let handList = a.hands {
            var near = false
            if let zone = out.handZone {
                for hand in handList where hand.joints.values.contains(where: { zone.contains($0.point) }) {
                    near = true
                }
            }
            handNear = near
            handWindow.append((now, near))
        }

        Self.trim(&motionWindow, now: now, span: 6)
        Self.trim(&headWindow, now: now, span: 6)
        Self.trim(&bodyWindow, now: now, span: 6)
        Self.trim(&handWindow, now: now, span: 5)

        out.motionBaseline = motion.value
        out.headBaseline = head.value
        out.bodyBaseline = body.value
        out.motionRatio = min(10, (Self.mean(motionWindow) ?? motion.value) / motion.value)
        out.headRatio = min(10, (Self.mean(headWindow) ?? head.value) / head.value)
        // Body pose is an extra signal (shoulders are not always in view): neutral until it has 30 s of data.
        out.bodyRatio = body.isWarm ? min(10, (Self.mean(bodyWindow) ?? body.value) / body.value) : 1
        out.handFraction = handWindow.isEmpty ? 0 : Double(handWindow.filter { $0.1 }.count) / Double(handWindow.count)
        out.handNear = handNear

        // Weighted average of the parts, so a calm moment scores about 1.
        // With hands-at-face switched off, hands near the face don't raise the score either.
        let handPart = handsEnabled ? 1 + 4 * out.handFraction : 1
        let wSum = settings.weightMotion + settings.weightHead + settings.weightBody + settings.weightHands
        if wSum > 0 {
            out.score = (settings.weightMotion * out.motionRatio + settings.weightHead * out.headRatio
                         + settings.weightBody * out.bodyRatio + settings.weightHands * handPart) / wSum
        }

        out.warmingUp = !(motion.isWarm && head.isWarm)
        out.baselineSeconds = (motion.secondsOfData, head.secondsOfData, body.secondsOfData)
        out.overActiveEvents = overActiveEnabled
            ? overActive.update(active: out.score > settings.activityThreshold && !out.warmingUp, value: out.score, now: now)
            : overActive.reset(now: now)
        out.handsEvents = handsEnabled
            ? hands.update(active: handNear, value: out.handFraction, now: now)
            : hands.reset(now: now)
        out.handHeld = hands.heldFor(now: now)
        if !hands.inEpisode { handsClipSent = false }
        if handsEnabled, hands.inEpisode, !handsClipSent, out.handHeld >= settings.handsClipAfter {
            handsClipSent = true
            out.handsClipDue = true
        }
        output = out
        return out
    }

    func reset(now: Double) {
        _ = overActive.reset(now: now)
        _ = hands.reset(now: now)
        lastFace = nil
        lastBody = nil
        handNear = false
        motionWindow.removeAll(); headWindow.removeAll(); bodyWindow.removeAll(); handWindow.removeAll()
    }
}
