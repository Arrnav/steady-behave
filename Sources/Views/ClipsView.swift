import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Plays one clip, or today's clips one after another in review mode.
final class ClipPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var speed: Float = 1
    @Published var reviewQueue: [ClipStorage.Entry] = []
    @Published var current: ClipStorage.Entry?
    private var endObserver: NSObjectProtocol?

    init() {
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.advanceReview()
        }
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var reviewing: Bool { !reviewQueue.isEmpty }

    func load(_ entry: ClipStorage.Entry?, autoplay: Bool = false) {
        current = entry
        guard let entry else { player.replaceCurrentItem(with: nil); return }
        player.replaceCurrentItem(with: AVPlayerItem(url: entry.url))
        player.defaultRate = speed
        if autoplay { player.playImmediately(atRate: speed) }
    }

    func setSpeed(_ s: Float) {
        speed = s
        player.defaultRate = s
        if player.rate != 0 { player.rate = s }
    }

    func startReview(_ entries: [ClipStorage.Entry]) {
        // Oldest first, so the day plays in order.
        reviewQueue = entries.sorted { $0.date < $1.date }
        load(reviewQueue.first, autoplay: true)
    }

    func stopReview() {
        reviewQueue = []
        player.pause()
    }

    private func advanceReview() {
        guard reviewing, let current, let i = reviewQueue.firstIndex(of: current) else { return }
        if i + 1 < reviewQueue.count {
            load(reviewQueue[i + 1], autoplay: true)
        } else {
            reviewQueue = []
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct ClipsView: View {
    @StateObject private var player = ClipPlayer()
    @State private var clips: [ClipStorage.Entry] = []
    @State private var selectedDay: String?
    @State private var selectedClip: ClipStorage.Entry?
    @State private var confirmDeleteDay = false

    private var days: [(day: String, count: Int)] {
        var counts: [String: Int] = [:]
        for c in clips { counts[c.day, default: 0] += 1 }
        return counts.keys.sorted(by: >).map { ($0, counts[$0] ?? 0) }
    }

    private var clipsForDay: [ClipStorage.Entry] {
        clips.filter { $0.day == selectedDay }
    }

    private var todayKey: String { ClipStorage.dayFormatter.string(from: Date()) }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedDay) {
                Section("Days") {
                    ForEach(days, id: \.day) { item in
                        HStack {
                            Text(dayTitle(item.day))
                            Spacer()
                            Text("\(item.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(item.day)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .overlay {
                if clips.isEmpty {
                    Text("No clips yet").foregroundStyle(.secondary)
                }
            }
        } content: {
            Group {
                if selectedDay == nil {
                    emptyState
                } else {
                    List(clipsForDay, selection: $selectedClip) { clip in
                        ClipRow(entry: clip).tag(clip)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            detail
        }
        .onAppear(perform: reload)
        .onDisappear { player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .steadyClipsChanged)) { _ in reload() }
        .onChange(of: selectedClip) { _, clip in
            if !player.reviewing { player.load(clip) }
        }
        .onChange(of: selectedDay) { _, _ in
            selectedClip = clipsForDay.first
        }
        .onChange(of: player.current) { _, clip in
            if player.reviewing, let clip { selectedDay = clip.day; selectedClip = clip }
        }
        .confirmationDialog("Delete all clips from \(selectedDay.map(dayTitle) ?? "this day")?", isPresented: $confirmDeleteDay) {
            Button("Move to Trash", role: .destructive) { deleteDay() }
        } message: {
            Text("The clips go to the Trash, so you can still restore them.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("No clips yet").font(.title3.weight(.semibold))
            Text("Clips are saved when you move a lot, keep a hand at your face, or do the stretched smile. They stay on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoPlayer(player: player.player)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .accessibilityLabel("Clip player")
            if let clip = player.current ?? selectedClip {
                HStack(spacing: 8) {
                    Circle().fill(clip.kind.color).frame(width: 9, height: 9)
                    Text(clip.kind.title).font(.headline)
                    Text(clip.date, style: .time).foregroundStyle(.secondary)
                    Spacer()
                    if player.reviewing, let i = player.reviewQueue.firstIndex(of: clip) {
                        Text("Reviewing \(i + 1) of \(player.reviewQueue.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text(clip.info?.summary ?? "No details saved for this clip.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                    Text("0.5x").tag(Float(0.5))
                    Text("1x").tag(Float(1))
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .labelsHidden()
                .accessibilityLabel("Playback speed")
                Spacer()
                if player.reviewing {
                    Button("Stop Review") { player.stopReview() }
                } else {
                    Button("Review Today") { player.startReview(clips.filter { $0.day == todayKey }) }
                        .disabled(!clips.contains { $0.day == todayKey })
                        .help("Play today's clips one after another")
                }
            }
            HStack(spacing: 10) {
                Button("Delete Clip", role: .destructive) { deleteSelected() }
                    .disabled(selectedClip == nil)
                Button("Reveal in Finder") {
                    if let url = selectedClip?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    else { NSWorkspace.shared.open(Paths.clips) }
                }
                Spacer()
                Button("Delete All from This Day", role: .destructive) { confirmDeleteDay = true }
                    .disabled(selectedDay == nil)
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.spacing)
        .frame(minWidth: 380)
    }

    private func dayTitle(_ key: String) -> String {
        guard let date = ClipStorage.dayFormatter.date(from: key) else { return key }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func reload() {
        let root = Paths.clips
        DispatchQueue.global(qos: .userInitiated).async {
            let all = ClipStorage.all(root: root)
            DispatchQueue.main.async {
                clips = all
                if selectedDay == nil || !all.contains(where: { $0.day == selectedDay }) {
                    selectedDay = all.first?.day
                }
                if let sel = selectedClip, !all.contains(sel) { selectedClip = clipsForDay.first }
                if selectedClip == nil { selectedClip = clipsForDay.first }
            }
        }
    }

    private func trash(_ entry: ClipStorage.Entry) {
        let fm = FileManager.default
        try? fm.trashItem(at: entry.url, resultingItemURL: nil)
        let sidecar = entry.url.deletingPathExtension().appendingPathExtension("json")
        if fm.fileExists(atPath: sidecar.path) { try? fm.trashItem(at: sidecar, resultingItemURL: nil) }
        let folder = entry.url.deletingLastPathComponent()
        if let rest = try? fm.contentsOfDirectory(atPath: folder.path), rest.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: folder)
        }
    }

    private func deleteSelected() {
        guard let clip = selectedClip else { return }
        if player.current == clip { player.stop() }
        trash(clip)
        selectedClip = nil
        reload()
    }

    private func deleteDay() {
        player.stop()
        for clip in clipsForDay { trash(clip) }
        selectedClip = nil
        selectedDay = nil
        reload()
    }
}

struct ClipRow: View {
    let entry: ClipStorage.Entry
    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.secondary.opacity(0.15))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 80, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(entry.kind.color).frame(width: 7, height: 7)
                    Text(entry.date, style: .time).font(.headline).monospacedDigit()
                    Text(entry.kind.title).font(.callout).foregroundStyle(.secondary)
                }
                Text(entry.info?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .task(id: entry.url) { thumbnail = await ThumbnailCache.shared.image(for: entry.url) }
        .accessibilityElement(children: .combine)
    }
}

/// Small in-memory cache of clip thumbnails made with AVAssetImageGenerator.
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: CGImage] = [:]

    func image(for url: URL) async -> CGImage? {
        if let hit = cache[url] { return hit }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 240, height: 180)
        generator.appliesPreferredTrackTransform = true
        // The trigger sits about 10 s into a clip; a frame just before it shows the moment.
        let image: CGImage
        if let i = try? await generator.image(at: CMTime(seconds: 8, preferredTimescale: 600)).image {
            image = i
        } else if let i = try? await generator.image(at: .zero).image {
            image = i
        } else {
            return nil
        }
        cache[url] = image
        return image
    }
}
