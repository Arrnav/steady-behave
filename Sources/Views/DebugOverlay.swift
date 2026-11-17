import SwiftUI

/// Draws the camera image and every debug layer from one engine snapshot.
/// Pure drawing; it reads a copy of the latest snapshot and never touches the Vision queue.
struct DebugOverlay {
    let snap: EngineSnapshot
    let settings: Settings
    let mirrored: Bool
    let layers: Set<DebugLayer>

    static let regionColors: [LandmarkRegion: Color] = [
        .faceContour: Color(red: 0.55, green: 0.75, blue: 1.0),
        .leftEyebrow: Color(red: 0.95, green: 0.80, blue: 0.40),
        .rightEyebrow: Color(red: 0.95, green: 0.80, blue: 0.40),
        .leftEye: Color(red: 0.45, green: 0.90, blue: 0.75),
        .rightEye: Color(red: 0.45, green: 0.90, blue: 0.75),
        .leftPupil: Color(red: 0.30, green: 1.0, blue: 0.55),
        .rightPupil: Color(red: 0.30, green: 1.0, blue: 0.55),
        .nose: Color(red: 0.85, green: 0.65, blue: 1.0),
        .noseCrest: Color(red: 0.75, green: 0.55, blue: 0.95),
        .medianLine: Color(white: 0.85),
        .innerLips: Color(red: 1.0, green: 0.75, blue: 0.55)
    ]

    /// Where the image sits inside the view (aspect fit).
    static func imageRect(imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let imageSize = snap.analysis?.imageSize ?? CGSize(width: 640, height: 480)
        let rect = Self.imageRect(imageSize: imageSize, in: size)

        // Camera image.
        if let image = snap.image {
            var layer = ctx
            if mirrored {
                layer.translateBy(x: rect.midX, y: 0)
                layer.scaleBy(x: -1, y: 1)
                layer.translateBy(x: -rect.midX, y: 0)
            }
            layer.draw(Image(decorative: image, scale: 1), in: rect)
        } else {
            ctx.fill(Path(rect), with: .color(.black.opacity(0.85)))
        }

        guard let a = snap.analysis else { return }

        let map = Mapper(imageSize: imageSize, rect: rect, mirrored: mirrored)
        let px = map.px, nm = map.nm, nmRect = map.nmRect

        if layers.contains(.motion), !a.motionMap.isEmpty, let heat = Self.heatmap(a.motionMap) {
            var layer = ctx
            layer.opacity = 0.75
            if mirrored {
                layer.translateBy(x: rect.midX, y: 0)
                layer.scaleBy(x: -1, y: 1)
                layer.translateBy(x: -rect.midX, y: 0)
            }
            layer.draw(Image(decorative: heat, scale: 1).interpolation(.medium), in: rect)
        }

        if layers.contains(.handZone), let zone = snap.activity.handZone {
            let r = nmRect(zone)
            let color = AlertKind.handsAtFace.color
            if snap.activity.handNear {
                ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(color.opacity(0.22)))
            }
            ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(color.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        }

        if layers.contains(.body) {
            drawBody(&ctx, nm: nm)
        }

        if layers.contains(.hands) {
            drawHands(&ctx, nm: nm)
        }

        guard a.facePresent else { return }

        if layers.contains(.face) {
            drawFace(&ctx, a, map: map)
        }

        let eyeMid: CGPoint? = {
            guard let le = a.landmarks[.leftEye], let re = a.landmarks[.rightEye] else { return nil }
            let c1 = px(FaceFeatures.centroid(le)), c2 = px(FaceFeatures.centroid(re))
            return CGPoint(x: (c1.x + c2.x) / 2, y: (c1.y + c2.y) / 2)
        }()

        if layers.contains(.headPose) {
            let anchor = a.landmarks[.nose].map { px(FaceFeatures.centroid($0)) } ?? nm(CGPoint(x: a.faceBox.midX, y: a.faceBox.midY))
            drawGizmo(&ctx, at: anchor, length: max(24, nmRect(a.faceBox).width * 0.35))
            let box = nmRect(a.faceBox)
            let label = String(format: "yaw %.0f°  pitch %.0f°  roll %.0f°",
                               a.yaw * 180 / .pi, a.pitch * 180 / .pi, a.roll * 180 / .pi)
            ctx.draw(Text(label).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white),
                     at: CGPoint(x: box.midX, y: box.minY - 10))
        }

        if layers.contains(.gaze), let from = eyeMid {
            // Direction from head angle plus the average pupil offset.
            var dx = sin(a.yaw), dy = -sin(a.pitch)
            if let g = a.gazeFeatures {
                dx += (g[3] + g[5]) / 2 * 2
                dy -= (g[4] + g[6]) / 2 * 2
            }
            if mirrored { dx = -dx }
            let len = max(40, nmRect(a.faceBox).width * 0.8)
            let to = CGPoint(x: from.x + dx * len, y: from.y + dy * len)
            let away = snap.gaze.smoothed > settings.gazeThreshold
            let color: Color = away ? Color(red: 0.95, green: 0.35, blue: 0.35) : Color(red: 0.35, green: 0.85, blue: 0.45)
            var arrow = Path()
            arrow.move(to: from); arrow.addLine(to: to)
            let angle = atan2(to.y - from.y, to.x - from.x)
            for side in [-0.5, 0.5] {
                arrow.move(to: to)
                arrow.addLine(to: CGPoint(x: to.x - 9 * cos(angle + side), y: to.y - 9 * sin(angle + side)))
            }
            ctx.stroke(arrow, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    /// Face box, every landmark region, mouth corners and the measured mouth width.
    private func drawFace(_ ctx: inout GraphicsContext, _ a: FrameAnalysis, map: Mapper) {
        let px = map.px, nmRect = map.nmRect
        let box = nmRect(a.faceBox)
        ctx.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(.white.opacity(0.55)), lineWidth: 1)
        for region in LandmarkRegion.allCases {
            guard let points = a.landmarks[region], !points.isEmpty else { continue }
            let base = region == .outerLips ? AlertKind.smile.color : (Self.regionColors[region] ?? .white)
            let color = base.opacity(0.85)
            if region == .leftPupil || region == .rightPupil {
                for p in points {
                    let v = px(p)
                    ctx.fill(Path(ellipseIn: CGRect(x: v.x - 2.5, y: v.y - 2.5, width: 5, height: 5)), with: .color(color))
                }
                continue
            }
            var path = Path()
            path.addLines(points.map(px))
            if region.isClosed { path.closeSubpath() }
            ctx.stroke(path, with: .color(color), lineWidth: 1.2)
        }
        // Mouth corners and the measured width.
        if let outer = a.landmarks[.outerLips], let left = outer.min(by: { $0.x < $1.x }), let right = outer.max(by: { $0.x < $1.x }) {
            let l = px(left), r = px(right)
            var line = Path()
            line.move(to: l); line.addLine(to: r)
            ctx.stroke(line, with: .color(AlertKind.smile.color.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for p in [l, r] {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(AlertKind.smile.color))
            }
            // Labels only when the preview is big enough to read them.
            if map.rect.width >= 560, let width = a.smileFeatures?.first {
                let mid = CGPoint(x: (l.x + r.x) / 2, y: max(l.y, r.y) + 14)
                ctx.draw(Text(String(format: "width %.2f", width)).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(AlertKind.smile.color), at: mid)
            }
            if map.rect.width >= 560 {
                ctx.draw(Text("corner").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)),
                         at: CGPoint(x: l.x - 14, y: l.y - 10))
                ctx.draw(Text("corner").font(.system(size: 9)).foregroundStyle(.white.opacity(0.8)),
                         at: CGPoint(x: r.x + 14, y: r.y - 10))
            }
        }
    }

    private func drawGizmo(_ ctx: inout GraphicsContext, at anchor: CGPoint, length: CGFloat) {
        guard let a = snap.analysis else { return }
        // Rotation from pitch (x), yaw (y) and roll (z), projected orthographically.
        let (cp, sp) = (cos(a.pitch), sin(a.pitch))
        let (cy, sy) = (cos(a.yaw), sin(a.yaw))
        let (cr, sr) = (cos(a.roll), sin(a.roll))
        func rotate(_ v: (Double, Double, Double)) -> (Double, Double) {
            var (x, y, z) = v
            (y, z) = (y * cp - z * sp, y * sp + z * cp)
            (x, z) = (x * cy + z * sy, -x * sy + z * cy)
            (x, y) = (x * cr - y * sr, x * sr + y * cr)
            return (x, y)
        }
        let axes: [((Double, Double, Double), Color)] = [
            ((1, 0, 0), Color(red: 0.95, green: 0.4, blue: 0.4)),
            ((0, 1, 0), Color(red: 0.4, green: 0.85, blue: 0.5)),
            ((0, 0, 1), Color(red: 0.45, green: 0.6, blue: 1.0))
        ]
        for (axis, color) in axes {
            var (x, y) = rotate(axis)
            if mirrored { x = -x }
            var p = Path()
            p.move(to: anchor)
            p.addLine(to: CGPoint(x: anchor.x + x * length, y: anchor.y - y * length))
            ctx.stroke(p, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private func drawHands(_ ctx: inout GraphicsContext, nm: (CGPoint) -> CGPoint) {
        for hand in snap.hands {
            let color: Color = hand.chirality < 0 ? Color(red: 1.0, green: 0.82, blue: 0.35)
                : hand.chirality > 0 ? Color(red: 1.0, green: 0.5, blue: 0.7) : Color(white: 0.9)
            for chain in VisionPipeline.handChains {
                let points = chain.compactMap { hand.joints[$0] }.map { nm($0.point) }
                guard points.count >= 2 else { continue }
                var path = Path()
                path.addLines(points)
                ctx.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1.2)
            }
            for joint in hand.joints.values {
                let p = nm(joint.point)
                let r = 1.5 + 2.5 * CGFloat(joint.confidence)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
    }

    private func drawBody(_ ctx: inout GraphicsContext, nm: (CGPoint) -> CGPoint) {
        let color = Color(red: 0.6, green: 0.8, blue: 1.0)
        for (a, b) in VisionPipeline.bodyBones {
            guard let ja = snap.body[a], let jb = snap.body[b] else { continue }
            var path = Path()
            path.move(to: nm(ja.point)); path.addLine(to: nm(jb.point))
            ctx.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1.5)
        }
        for joint in snap.body.values {
            let p = nm(joint.point)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color.opacity(0.9)))
        }
    }

    /// Colours the 64x48 frame difference: transparent where still, warm where moving.
    static func heatmap(_ map: [UInt8]) -> CGImage? {
        let w = VisionPipeline.motionWidth, h = VisionPipeline.motionHeight
        guard map.count == w * h else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = min(255, Int(map[i]) * 6)
            let a = UInt8(v)
            // Premultiplied purple-to-orange ramp.
            let r = 150 + v * 105 / 255, g = 70 + v * 90 / 255, b = 230 - v * 160 / 255
            rgba[i * 4] = UInt8(r * v / 255)
            rgba[i * 4 + 1] = UInt8(g * v / 255)
            rgba[i * 4 + 2] = UInt8(b * v / 255)
            rgba[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The state in words, for the banner over the video.
    static func banner(_ snap: EngineSnapshot, settings: Settings, cameraRunning: Bool) -> (String, Color) {
        if !cameraRunning { return ("Camera off", .secondary) }
        if snap.calibrating { return ("Calibrating: alerts off", .secondary) }
        if snap.paused { return ("Paused", .secondary) }
        if let quiet = snap.quietReason { return ("Quiet mode (\(quiet))", .secondary) }
        if snap.missedActive { return ("Recording a missed smile", AlertKind.smile.color) }
        if snap.smile.held > 0 { return (String(format: "Smile detected %.1f s", snap.smile.held), AlertKind.smile.color) }
        if !snap.inputPaused.isEmpty {
            return ("Keyboard or mouse in use: " + snap.inputPaused.map(\.title).joined(separator: ", ") + " paused", .secondary)
        }
        if snap.gaze.held > 0 { return (String(format: "Looking away %.1f s", snap.gaze.held), AlertKind.lookAway.color) }
        if snap.gaze.state == .leftDesk { return ("Away from desk", .secondary) }
        if snap.activity.handNear { return ("Hand near face", AlertKind.handsAtFace.color) }
        if snap.activity.score > settings.activityThreshold { return ("Moving a lot", AlertKind.overActive.color) }
        if snap.analysis?.facePresent == false { return ("No face in view", .secondary) }
        return ("Watching", .green)
    }
}

/// Converts Vision coordinates (origin bottom-left) into view coordinates for the drawn image.
struct Mapper {
    let imageSize: CGSize
    let rect: CGRect
    let mirrored: Bool

    /// From image pixel coordinates.
    func px(_ p: CGPoint) -> CGPoint {
        nm(CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height))
    }

    /// From normalized coordinates (0...1).
    func nm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + (mirrored ? 1 - p.x : p.x) * rect.width, y: rect.minY + (1 - p.y) * rect.height)
    }

    func nmRect(_ r: CGRect) -> CGRect {
        let a = nm(CGPoint(x: r.minX, y: r.minY)), b = nm(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

/// Live camera view with overlays, redrawn at display rate from the latest snapshot.
struct CameraOverlayView: View {
    var layers: Set<DebugLayer>
    var mirrored: Bool
    var showBanner = true
    @ObservedObject private var app = AppState.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let snap = Engine.shared.snapshot.get()
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    var c = ctx
                    DebugOverlay(snap: snap, settings: app.settings, mirrored: mirrored, layers: layers).draw(&c, size: size)
                }
                if showBanner {
                    let (text, color) = DebugOverlay.banner(snap, settings: app.settings, cameraRunning: app.cameraRunning)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(text).font(.callout.weight(.medium)).monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .cardBackground(cornerRadius: 14)
                    .padding(.top, 10)
                    .accessibilityLabel("Status: \(text)")
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        // Preview images are only made while a view like this is on screen.
        .onAppear { Engine.shared.previewConsumers.update { $0 += 1 } }
        .onDisappear { Engine.shared.previewConsumers.update { $0 = max(0, $0 - 1) } }
    }
}
