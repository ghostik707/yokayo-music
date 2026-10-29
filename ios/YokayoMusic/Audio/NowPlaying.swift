import MediaPlayer
import AVFoundation
import UIKit
import CryptoKit
import WidgetKit

/// Экран блокировки, Пункт управления, наушники.
@MainActor
final class NowPlaying {
    private unowned let player: Player
    private var artworkFor: String?
    private var artwork: MPMediaItemArtwork?
    private var animated: AnyObject?

    init(player: Player) { self.player = player }

    func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player.togglePlay(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.player.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.player.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(to: e.positionTime); return .success
        }
        c.likeCommand.localizedTitle = "Нравится"
        c.likeCommand.addTarget { [weak self] _ in self?.player.toggleLike(); return .success }
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let song = player.current else { center.nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.livePosition,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.activeDeck.timePitch.rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = song.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if artworkFor == song.id {
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            if #available(iOS 26.0, *), let animated, let key = animatedKey { info[key] = animated }
        } else {
            artworkFor = song.id; artwork = nil; animated = nil
            loadArtwork(for: song)
        }
        MPRemoteCommandCenter.shared().likeCommand.isActive = player.liked.contains(song.id)
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
        publishWidget(song)
    }

    // MARK: Виджеты

    private var lastWidget: WidgetState?

    /// Сообщает виджетам текущий трек; перерисовываем их, только когда что-то поменялось.
    private func publishWidget(_ song: Song) {
        let state = WidgetState(title: song.title, artist: song.artist, isPlaying: player.isPlaying,
                                djStatus: player.djStatus, hasArtwork: artwork != nil, trackId: song.id)
        guard state != lastWidget else { return }
        let newTrack = lastWidget?.trackId != song.id || (lastWidget?.hasArtwork == false && state.hasArtwork)
        lastWidget = state
        if newTrack, state.hasArtwork, let url = song.coverURL(400), let img = ImagePipeline.shared.cached(url) ?? ImagePipeline.shared.cached(song.coverURL(1000) ?? url) {
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let small = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300), format: fmt).image { _ in
                img.draw(in: CGRect(x: 0, y: 0, width: 300, height: 300))
            }
            if let jpg = small.jpegData(compressionQuality: 0.85) { SharedStore.saveArtwork(jpg) }
        }
        SharedStore.save(state)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Обложка 1000×1000: iOS показывает её на весь экран блокировки.
    private func loadArtwork(for song: Song) {
        Task {
            guard let url = song.coverURL(1000), let image = await ImagePipeline.shared.image(url) else { return }
            guard artworkFor == song.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            update()
            if AppSettings.shared.animatedCovers, let video = song.videoCoverURL {
                await loadAnimated(song: song, video: video, preview: image)
            }
            if animated == nil { await loadFullScreen(song: song, image: image) }
            update()
        }
    }

    private var animatedKey: String? {
        guard #available(iOS 26.0, *) else { return nil }
        let keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        if animatedTall, keys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) { return MPNowPlayingInfoProperty3x4AnimatedArtwork }
        return keys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) ? MPNowPlayingInfoProperty1x1AnimatedArtwork : nil
    }
    private var animatedTall = false

    /// Обложка на весь экран блокировки (iOS 26+): вертикальный ролик из обычной обложки.
    private func loadFullScreen(song: Song, image: UIImage) async {
        guard #available(iOS 26.0, *), AppSettings.shared.lockFullScreen else { return }
        guard let file = await ArtworkMotion.video(id: song.id, image: image), artworkFor == song.id else { return }
        let preview = ArtworkMotion.tallImage(image)
        animatedTall = true
        animated = MPMediaItemAnimatedArtwork(artworkID: "tall|" + song.id,
                                              previewImageRequestHandler: { size, completion in
                                                  completion(size.width > 0 ? ArtworkMotion.tallImage(image, size: size) : preview)
                                              },
                                              videoAssetFileURLRequestHandler: { _, completion in completion(file) })
    }

    /// Анимированная обложка на экране блокировки (iOS 26+).
    private func loadAnimated(song: Song, video: URL, preview: UIImage) async {
        guard #available(iOS 26.0, *) else { return }
        guard let file = await VideoCovers.shared.localFile(for: video) else { return }
        let asset = AVURLAsset(url: file)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            animatedTall = size.height > size.width * 1.1
        }
        guard artworkFor == song.id else { return }
        let still = animatedTall ? ArtworkMotion.tallImage(preview) : preview
        animated = MPMediaItemAnimatedArtwork(artworkID: song.id + "|" + video.absoluteString,
                                              previewImageRequestHandler: { _, completion in completion(still) },
                                              videoAssetFileURLRequestHandler: { _, completion in completion(file) })
    }
}

/// Загружает и кэширует видео-обложки (mp4) и превращает GIF в видео.
actor VideoCovers {
    static let shared = VideoCovers()
    private var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func localFile(for url: URL) async -> URL? {
        if url.isFileURL { return url }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".mp4"
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return nil }
        try? FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}
