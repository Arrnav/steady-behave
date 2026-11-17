import AppKit
import CoreGraphics
import Foundation

/// Self-test checks for detection behaviour, settings and data handling.
extension SelfTest {
    // MARK: Looking away

    static func faceFrame(yaw: Double, t: Double) -> FrameAnalysis {
        var a = FrameAnalysis()
        a.time = t
        a.facePresent = true
        a.yaw = yaw
        a.faceBox = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.4)
        return a
    }

    static func lookAwayGrace() -> String? {
        let d = AttentionDetector()
        let settings = Settings()
        var alerts: [Double] = []
        var t = 0.0
        while t < 5 {
            _ = d.update(analysis: faceFrame(yaw: 0, t: t), model: nil, active: true, typing: false, settings: settings, now: t)
            t += 1.0 / 15
        }
        let turnedAt = t
        while t < 40 {
            let out = d.update(analysis: faceFrame(yaw: 0.8, t: t), model: nil, active: true, typing: false, settings: settings, now: t)
            for e in out.events { if case .alert = e { alerts.append(t - turnedAt) } }
            t += 1.0 / 15
        }
        guard alerts.count == 3 else { return "expected 3 alerts in 35 s, got \(alerts.count)" }
        // Smoothing takes a few frames, then the 2.5 s grace time.
        guard alerts[0] > 2.5, alerts[0] < 3.3 else { return String(format: "first alert after %.2f s", alerts[0]) }
        guard abs(alerts[1] - alerts[0] - 15) < 0.2 else { return "repeat not 15 s later" }
        guard d.awaySeconds > 30, d.eyesOnSeconds > 4 else { return "away/on-screen seconds not counted" }
        return nil
    }

    static func typingMutes() -> String? {
        let d = AttentionDetector()
        var t = 0.0
        while t < 10 {
            let out = d.update(analysis: faceFrame(yaw: 0.8, t: t), model: nil, active: true, typing: true, settings: Settings(), now: t)
            if out.events.contains(where: { if case .alert = $0 { return true } else { return false } }) { return "alerted while typing" }
            t += 1.0 / 15
        }
        return nil
    }

    static func missingFace() -> String? {
        let d = AttentionDetector()
        var t = 0.0
        while t < 3 {
            _ = d.update(analysis: faceFrame(yaw: 0, t: t), model: nil, active: true, typing: false, settings: Settings(), now: t)
            t += 1.0 / 15
        }
        var alerted = false
        var lastState = AttentionDetector.State.onScreen
        while t < 53 {
            var a = FrameAnalysis(); a.time = t
            let out = d.update(analysis: a, model: nil, active: true, typing: false, settings: Settings(), now: t)
            if out.events.contains(where: { if case .alert = $0 { return true } else { return false } }) { alerted = true }
            lastState = out.state
            t += 1.0 / 15
        }
        guard alerted else { return "no alert when the face disappeared" }
        guard lastState == .leftDesk else { return "state after 50 s without a face: \(lastState.rawValue)" }
        return nil
    }

    static func handZone() -> String? {
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3)
        let zone = ActivityDetector.handZone(for: face)
        guard zone.contains(CGPoint(x: 0.5, y: 0.33)) else { return "chin and beard area below the face box not covered" }
        guard zone.contains(CGPoint(x: 0.38, y: 0.5)) else { return "side of the face not covered" }
        guard !zone.contains(CGPoint(x: 0.5, y: 0.2)) else { return "zone reaches the chest" }
        let detector = ActivityDetector()
        var t = 0.0
        var alerted = false
        while t < 4 {
            var a = FrameAnalysis()
            a.time = t; a.facePresent = true; a.faceBox = face; a.iod = 40
            a.hands = [HandPose(chirality: 1, joints: ["indexTip": Joint(name: "indexTip", point: CGPoint(x: 0.5, y: 0.35), confidence: 0.9)])]
            let out = detector.update(analysis: a, overActiveEnabled: true, handsEnabled: true, settings: Settings(), now: t)
            if out.handsEvents.contains(where: { if case .alert = $0 { return true } else { return false } }) { alerted = true }
            t += 1.0 / 15
        }
        return alerted ? nil : "no hands-at-face alert after 4 s"
    }

    static func bodyMovement() -> String? {
        let detector = ActivityDetector()
        var t = 0.0, frame = 0
        var calmRatio = 0.0, busyRatio = 0.0
        while t < 80 {
            var a = FrameAnalysis(); a.time = t
            if frame % 3 == 1 {
                // Calm for 60 s (tiny sway), then swaying a lot.
                let amp = t < 60 ? 0.002 : 0.05
                let dx = amp * sin(t * 3)
                a.body = ["leftShoulder": Joint(name: "leftShoulder", point: CGPoint(x: 0.35 + dx, y: 0.3), confidence: 0.9),
                          "rightShoulder": Joint(name: "rightShoulder", point: CGPoint(x: 0.65 + dx, y: 0.3), confidence: 0.9),
                          "neck": Joint(name: "neck", point: CGPoint(x: 0.5 + dx, y: 0.32), confidence: 0.9)]
            }
            let out = detector.update(analysis: a, overActiveEnabled: true, handsEnabled: true, settings: Settings(), now: t)
            if t > 55 && t < 60 { calmRatio = out.bodyRatio }
            busyRatio = out.bodyRatio
            t += 1.0 / 15; frame += 1
        }
        guard calmRatio > 0.3, calmRatio < 3 else { return String(format: "calm ratio %.2f", calmRatio) }
        guard busyRatio > 3 else { return String(format: "busy ratio %.2f", busyRatio) }
        return nil
    }

    static func calmBaseline() -> String? {
        var b = CalmBaseline(floor: 0.1)
        var t = 0.0
        // 60 s calm at 1.0, then 60 s busy at 5.0.
        while t < 120 { b.add(t < 60 ? 1.0 : 5.0, now: t); t += 1.0 / 15 }
        guard abs(b.value - 1.0) < 0.05 else { return String(format: "baseline %.2f", b.value) }
        return nil
    }

    static func settingsMerge() -> String? {
        let stored = Data(#"{"smileThreshold": 0.8, "unknownKey": 5}"#.utf8)
        let s = Settings.load(from: stored)
        guard s.smileThreshold == 0.8 else { return "stored value lost" }
        guard s.gazeGrace == 2.5, s.clipCapMB == 500 else { return "defaults lost" }
        return nil
    }

    static func deleteData() -> String? {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (pos, neg) = syntheticData()
        let models = ModelStore(url: dir.appendingPathComponent("models.json"))
        models.update { $0.smile = LogisticModel.train(positives: pos, negatives: neg); $0.calmMotion = 1 }
        let stats = StatsStore(url: dir.appendingPathComponent("stats.json"))
        stats.update { $0.smileEpisodes = 3 }
        stats.saveNow()
        models.deleteAll()
        stats.deleteAll()
        guard models.smile == nil, models.file.calmMotion == nil else { return "model still loaded" }
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("models.json").path) else { return "models.json still on disk" }
        guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent("stats.json").path) else { return "stats.json still on disk" }
        guard StatsStore(url: dir.appendingPathComponent("stats.json")).today.smileEpisodes == 0 else { return "stats came back" }
        return nil
    }

    static func colorHex() -> String? {
        let hex = AlertKind.lookAway.defaultColor.hexString
        guard let hex, let back = NSColor(hex: hex), back.hexString == hex else { return "round trip changed the color" }
        guard NSColor(hex: "#12345") == nil, NSColor(hex: "zzzzzz") == nil else { return "accepted a malformed value" }
        return nil
    }

    static func detectionOff() -> String? {
        var settings = Settings()
        settings.detectionEnabled[AlertKind.handsAtFace.rawValue] = false
        let detector = ActivityDetector()
        var t = 0.0
        while t < 6 {
            var a = FrameAnalysis()
            a.time = t; a.facePresent = true; a.faceBox = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3); a.iod = 40
            a.hands = [HandPose(chirality: 1, joints: ["indexTip": Joint(name: "indexTip", point: CGPoint(x: 0.5, y: 0.35), confidence: 0.9)])]
            let out = detector.update(analysis: a, overActiveEnabled: true, handsEnabled: settings.detects(.handsAtFace), settings: settings, now: t)
            if !out.handsEvents.isEmpty || out.handsClipDue { return "hands-at-face fired while switched off" }
            if out.score > 1.5 { return String(format: "hands still raised the activity score to %.2f", out.score) }
            t += 1.0 / 15
        }
        return nil
    }

    static func detectionGates() -> String? {
        var focus = FocusSnapshot()
        focus.gazeReason = .session
        var settings = Settings()
        guard DetectionGates(settings: settings, focus: focus) == {
            var all = DetectionGates(settings: settings, focus: focus); all.smile = true; all.lookAway = true
            all.overActive = true; all.hands = true; return all
        }() else { return "not every detection runs by default" }
        for kind in AlertKind.allCases { settings.detectionEnabled[kind.rawValue] = false }
        let off = DetectionGates(settings: settings, focus: focus)
        guard !off.smile, !off.lookAway, !off.overActive, !off.hands else { return "a switched-off detection still runs" }
        var inputSettings = Settings()
        let typingDefault = DetectionGates(settings: inputSettings, focus: focus, inputActive: true)
        guard typingDefault.inputPaused == [.lookAway], typingDefault.smile, typingDefault.overActive, typingDefault.hands else {
            return "by default only looking away should pause during input"
        }
        inputSettings.inputPauses[AlertKind.smile.rawValue] = true
        inputSettings.inputPauses[AlertKind.lookAway.rawValue] = false
        let typingCustom = DetectionGates(settings: inputSettings, focus: focus, inputActive: true)
        guard !typingCustom.smile, typingCustom.inputPaused == [.smile] else { return "custom input pauses were not applied" }
        guard DetectionGates(settings: inputSettings, focus: focus, inputActive: false).smile else { return "smile stayed paused without input" }
        focus.paused = true
        let paused = DetectionGates(settings: Settings(), focus: focus)
        guard !paused.smile, !paused.lookAway, !paused.overActive, !paused.hands else { return "a detection runs while paused" }
        return nil
    }

    static func smoothingSpeed() -> String? {
        func after(seconds: Double, fps: Double) -> Double {
            var value = 0.0
            var t = 0.0
            while t < seconds - 1e-9 {
                let a = Smoothing.alpha(dt: 1 / fps)
                value = a * 1 + (1 - a) * value
                t += 1 / fps
            }
            return value
        }
        let fast = after(seconds: 0.6, fps: 15), slow = after(seconds: 0.6, fps: 5)
        guard abs(Smoothing.alpha(dt: 1.0 / 15) - 0.3) < 1e-9 else { return "alpha at 15 fps is not 0.3" }
        guard abs(fast - slow) < 0.01 else { return String(format: "15 fps reached %.3f, 5 fps reached %.3f", fast, slow) }
        return nil
    }

    static func haptics() -> String? {
        let backend = Haptics.shared.backend
        print("      haptic backend: \(backend.rawValue) \(Haptics.shared.detail)")
        return backend == .none ? "no backend" : nil
    }
}
