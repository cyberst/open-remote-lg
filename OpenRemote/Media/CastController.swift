import PhotosUI
import SwiftUI
import UIKit
import LGKit

/// Owns a casting session: the picked queue, media preparation, the local `MediaServer`, the TV-side player
/// (DLNA renderer when the TV has one, else `TVControlling.openMedia`), the slideshow and background handling.
/// A shared instance so casting survives switching between app modes.
@MainActor
@Observable
final class CastController {
    static let shared = CastController()

    enum Kind: Sendable { case photo, video }

    enum ItemState: Equatable {
        case loading
        case preparing(Double)
        case ready
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let kind: Kind
        var state: ItemState = .loading
        var thumbnail: UIImage?
        var fileURL: URL?
        var duration: TimeInterval?
        var mimeType: String { kind == .photo ? "image/jpeg" : "video/mp4" }
    }

    enum Phase: Equatable {
        case idle
        /// The selected item is still being prepared; it is sent as soon as it is ready.
        case waiting
        case sending
        case showing
        case failed
    }

    enum SlideshowInterval: Int, CaseIterable, Identifiable {
        case three = 3, five = 5, ten = 10
        var id: Int { rawValue }
        var duration: Duration { .seconds(rawValue) }
    }

    private(set) var items: [Item] = []
    private(set) var currentIndex: Int?
    private(set) var phase: Phase = .idle
    private(set) var slideshowRunning = false
    /// Latest renderer report while a video is on the TV (DLNA only).
    private(set) var videoStatus: DLNARenderer.TransportInfo?
    private(set) var videoPaused = false
    var errorMessage: String?
    var interval: SlideshowInterval {
        didSet { UserDefaults.standard.set(interval.rawValue, forKey: Self.intervalKey) }
    }

    var current: Item? { currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    var isActive: Bool { !items.isEmpty }
    var photoCount: Int { items.filter { $0.kind == .photo }.count }

    private static let intervalKey = "cast.slideshowInterval"
    private enum Backend {
        case dlna(DLNARenderer)
        /// The TV's own media viewer, reached through `session.tv` at each use: the client is replaced when
        /// the app returns from the background, so it must never be stored here.
        case viewer
    }
    private var backend: Backend?
    private var backendDeviceID: String?
    private var server: MediaServer?
    private var registered: [UUID: URL] = [:]
    private var prepTasks: [UUID: Task<Void, Never>] = [:]
    private var sendTask: Task<Void, Never>?
    private var slideshowTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var sendGeneration = 0
    private var previousAppID: String?
    private weak var session: TVSession?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundStop: Task<Void, Never>?

    private init() {
        interval = SlideshowInterval(rawValue: UserDefaults.standard.integer(forKey: Self.intervalKey)) ?? .five
        CastStorage.removeAll() // leftovers from a previous run that was killed mid-cast
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        }
    }

    // MARK: - Queue

    /// Adds picked photos/videos, prepares them in the background, and starts casting the first one if idle.
    func add(_ picks: [PhotosPickerItem], session: TVSession) {
        self.session = session
        errorMessage = nil
        let startIndex = items.count
        for pick in picks {
            let isVideo = pick.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let item = Item(kind: isVideo ? .video : .photo)
            items.append(item)
            prepTasks[item.id] = Task { [weak self] in await self?.prepare(pick, id: item.id) }
        }
        if currentIndex == nil, items.indices.contains(startIndex) { show(startIndex) }
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        prepTasks.removeValue(forKey: id)?.cancel()
        if let url = registered.removeValue(forKey: id) { server?.unregister(url) }
        CastStorage.remove(items[index].fileURL)
        items.remove(at: index)
        if items.isEmpty { stopCasting(); return }
        if let cur = currentIndex {
            if cur == index { show(min(index, items.count - 1)) }
            else if cur > index { currentIndex = cur - 1 }
        }
    }

    private func prepare(_ pick: PhotosPickerItem, id: UUID) async {
        do {
            switch item(id)?.kind {
            case .video:
                guard let picked = try await pick.loadTransferable(type: PickedMovieFile.self) else { throw MediaPrepError.unreadableVideo }
                defer { CastStorage.remove(picked.url) }
                try Task.checkCancellation()
                let thumb = await VideoConverter.thumbnail(of: picked.url)
                update(id) { $0.thumbnail = thumb; $0.state = .preparing(0) }
                let prepared = try await VideoConverter.prepare(picked.url) { [weak self] p in
                    Task { @MainActor in
                        self?.update(id) { if case .preparing = $0.state { $0.state = .preparing(p) } }
                    }
                }
                try Task.checkCancellation()
                update(id) { $0.fileURL = prepared.url; $0.duration = prepared.duration; $0.state = .ready }
            case .photo:
                guard let picked = try await pick.loadTransferable(type: PickedImageFile.self) else { throw MediaPrepError.unreadableImage }
                defer { CastStorage.remove(picked.url) }
                update(id) { $0.state = .preparing(0) }
                let source = picked.url
                let (thumb, jpeg) = try await Task.detached(priority: .userInitiated) {
                    (PhotoConverter.thumbnail(of: source), try PhotoConverter.makeJPEG(from: source))
                }.value
                try Task.checkCancellation()
                update(id) { $0.thumbnail = thumb; $0.fileURL = jpeg; $0.state = .ready }
            case nil:
                return
            }
        } catch is CancellationError {
            return
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
        }
        prepTasks[id] = nil
        // Removed while preparing: discard the output.
        guard let item = item(id) else { return }
        if case .ready = item.state, currentIndex == items.firstIndex(where: { $0.id == id }), phase == .waiting {
            send(item)
        } else if case .failed(let message) = item.state, currentIndex == items.firstIndex(where: { $0.id == id }), phase == .waiting {
            phase = .failed
            errorMessage = message
        }
    }

    private func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&items[i])
    }

    // MARK: - Showing

    func show(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
        slideshowTask?.cancel(); pollTask?.cancel()
        videoStatus = nil; videoPaused = false
        let item = items[index]
        switch item.state {
        case .ready: send(item)
        case .failed(let message): phase = .failed; errorMessage = message
        case .loading, .preparing: phase = .waiting; sendTask?.cancel()
        }
    }

    func next() {
        guard !items.isEmpty else { return }
        show(((currentIndex ?? -1) + 1) % items.count)
    }

    func previous() {
        guard !items.isEmpty else { return }
        show(((currentIndex ?? 0) - 1 + items.count) % items.count)
    }

    func toggleSlideshow() {
        slideshowRunning.toggle()
        slideshowTask?.cancel()
        guard slideshowRunning else { return }
        if currentIndex == nil { show(0) } else if phase == .showing, current?.kind == .photo { scheduleNextSlide() }
    }

    func setInterval(_ value: SlideshowInterval) {
        interval = value
        if slideshowRunning, phase == .showing, current?.kind == .photo { scheduleNextSlide() }
    }

    private func scheduleNextSlide() {
        slideshowTask?.cancel()
        let wait = interval.duration
        slideshowTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.slideshowRunning else { return }
            self.next()
        }
    }

    private func send(_ item: Item) {
        guard let session, session.isConnected, let tv = session.tv, let device = session.current else {
            phase = .failed; errorMessage = LGError.notConnected.localizedDescription; return
        }
        guard let file = item.fileURL else { return }
        sendTask?.cancel()
        sendGeneration += 1
        let generation = sendGeneration
        phase = .sending
        errorMessage = nil
        let title = item.kind == .photo ? String(localized: "Photo from Open Remote") : String(localized: "Video from Open Remote")
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backend = try await self.ensureBackend(tv: tv, device: device)
                let server = try await self.ensureServer(peer: device.isDemo ? nil : device.host)
                let url = try self.registered[item.id] ?? server.register(
                    fileURL: file, mimeType: item.mimeType, fileName: item.kind == .photo ? "photo.jpg" : "video.mp4")
                self.registered[item.id] = url
                try Task.checkCancellation()
                switch backend {
                case .dlna(let r): try await r.load(url: url, mimeType: item.mimeType, title: title)
                case .viewer: try await tv.openMedia(url: url, mimeType: item.mimeType, title: title, iconURL: nil)
                }
                guard generation == self.sendGeneration, !Task.isCancelled else { return }
                self.phase = .showing
                Haptics.success()
                if item.kind == .video { self.startPolling(generation: generation) }
                else if self.slideshowRunning { self.scheduleNextSlide() }
            } catch {
                guard generation == self.sendGeneration, !(error is CancellationError) else { return }
                self.phase = .failed
                self.errorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func ensureBackend(tv: any TVControlling, device: TVDevice) async throws -> Backend {
        if let backend, backendDeviceID == device.id { return backend }
        // Not `resetTransport()`: that cancels the send in flight, i.e. the caller (the first cast never reached the TV).
        server?.stop(); server = nil; registered = [:]
        backend = nil; backendDeviceID = nil; previousAppID = nil
        if previousAppID == nil { previousAppID = try? await tv.foregroundAppID() }
        let resolved: Backend
        if !device.isDemo, let renderer = await DLNARenderer.discover(host: device.host) {
            resolved = .dlna(renderer)
        } else {
            resolved = .viewer
        }
        backend = resolved; backendDeviceID = device.id
        return resolved
    }

    private func ensureServer(peer: String?) async throws -> MediaServer {
        if let server, server.isRunning { return server }
        let s = MediaServer(peer: peer)
        try await s.start()
        server = s; registered = [:]
        return s
    }

    // MARK: - Video

    func toggleVideoPause() {
        guard current?.kind == .video, phase == .showing else { return }
        let pause = !videoPaused
        videoPaused = pause
        Task {
            do {
                switch backend {
                case .dlna(let r): try await (pause ? r.pause() : r.play())
                case .viewer:
                    guard let tv = session?.tv else { throw LGError.notConnected }
                    try await tv.media(pause ? .pause : .play)
                case nil: break
                }
            } catch {
                videoPaused = !pause
                errorMessage = error.localizedDescription
            }
        }
    }

    func restartVideo() {
        guard let index = currentIndex, current?.kind == .video else { return }
        show(index)
    }

    private func startPolling(generation: Int) {
        pollTask?.cancel()
        guard case .dlna(let renderer) = backend else { return }
        pollTask = Task { [weak self] in
            var sawPlayback = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, generation == self.sendGeneration, !Task.isCancelled else { return }
                guard let info = try? await renderer.transportInfo() else { continue }
                self.videoStatus = info
                if info.isPlaying { sawPlayback = true; self.videoPaused = false }
                if info.isPaused { self.videoPaused = true }
                let ended = sawPlayback && (info.state == "STOPPED" || info.state == "NO_MEDIA_PRESENT")
                if ended {
                    if self.slideshowRunning, self.items.count > 1 { self.next() }
                    return
                }
            }
        }
    }

    // MARK: - Ending

    /// Stops the TV player, shuts the server down, deletes temp files and clears the queue.
    func stopCasting() {
        let backend = self.backend
        let previous = previousAppID
        let tv = session?.tv
        let hadShown = phase == .showing || phase == .sending
        resetTransport()
        prepTasks.values.forEach { $0.cancel() }
        prepTasks = [:]
        items = []
        currentIndex = nil
        phase = .idle
        slideshowRunning = false
        errorMessage = nil
        CastStorage.removeAll()
        guard hadShown, let backend else { return }
        Task {
            switch backend {
            case .dlna(let r): try? await r.stop()
            case .viewer: break
            }
            try? await tv?.closeMedia()
            await Self.restoreApp(previous, on: tv)
        }
    }

    /// Returns the TV to what it showed before casting, if it is still in a media viewer.
    private static func restoreApp(_ previous: String?, on tv: (any TVControlling)?) async {
        guard let tv, let previous else { return }
        guard let now = try? await tv.foregroundAppID(), mediaApps.contains(now), now != previous else { return }
        if previous.contains("home") || previous.contains("launcher") { try? await tv.press(.home) }
        else { try? await tv.launchApp(id: previous, params: nil) }
    }

    static let mediaApps: Set<String> = ["com.webos.app.photovideo", "com.webos.app.tvsimpleviewer", "com.webos.app.mediadiscovery"]

    /// Drops the TV player and server but keeps the queue (used when the TV changes).
    private func resetTransport() {
        sendTask?.cancel(); slideshowTask?.cancel(); pollTask?.cancel()
        sendGeneration += 1
        server?.stop(); server = nil; registered = [:]
        backend = nil; backendDeviceID = nil; previousAppID = nil
        videoStatus = nil; videoPaused = false
        if phase != .idle { phase = .idle }
    }

    /// Call when the active TV changes; casting to the old TV ends.
    func tvChanged(to deviceID: String?) {
        guard let backendDeviceID, backendDeviceID != deviceID else { return }
        stopCasting()
    }

    // MARK: - Background

    private func didEnterBackground() {
        guard isActive else { return }
        endBackgroundTask()
        // iOS suspends us shortly; keep serving for the grace period so a video/photo in flight completes,
        // then end the cast cleanly instead of leaving the TV pointing at a dead server.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish casting") { [weak self] in
            MainActor.assumeIsolated {
                self?.stopCasting()
                self?.endBackgroundTask()
            }
        }
        let grace = max(1, min(UIApplication.shared.backgroundTimeRemaining - 5, 25))
        backgroundStop?.cancel()
        backgroundStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self else { return }
            self.stopCasting()
            try? await Task.sleep(for: .seconds(2)) // let the stop requests go out
            self.endBackgroundTask()
        }
    }

    private func willEnterForeground() {
        backgroundStop?.cancel(); backgroundStop = nil
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
