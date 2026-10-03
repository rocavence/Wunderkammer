import AppKit
import AVFoundation

/// Rest the pointer on a video and it plays, muted and looping, right in its
/// tile. Move away and it stops. One at a time.
@MainActor
final class HoverVideo {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var pending: DispatchWorkItem?
    private(set) var playing: UUID?

    /// Starts after a short rest, so sweeping across the grid doesn't fire every video.
    func hover(_ item: Item?, url: URL?, frame: CGRect, in host: CALayer) {
        guard item?.id != playing else {
            withoutAnimation { playerLayer?.frame = frame }
            return
        }
        stop()
        guard let item, item.kind == .video, let url else { return }
        let work = DispatchWorkItem { [weak self, weak host] in
            MainActor.assumeIsolated {
                guard let self, let host else { return }
                self.start(item.id, url: url, frame: frame, in: host)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func start(_ id: UUID, url: URL, frame: CGRect, in host: CALayer) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.zPosition = 3
        layer.opacity = 0
        withoutAnimation { layer.frame = frame }
        host.addSublayer(layer)
        player.play()
        // Fade in once frames are coming, so the poster doesn't flash black.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        layer.opacity = 1
        CATransaction.commit()
        self.player = player
        playerLayer = layer
        playing = id
    }

    func stop() {
        pending?.cancel()
        pending = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
        playing = nil
    }
}
