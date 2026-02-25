import AVFoundation
import Foundation

@Observable
@MainActor
final class AudioPlayerService {

    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoaded = false
    private(set) var error: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var loadedRecordId: UUID?

    /// Ensure the player is loaded for this record, then play
    func playRecord(_ record: TranscriptionRecord) {
        if loadedRecordId != record.id {
            loadFromRecord(record)
        }
        play()
    }

    /// Ensure the player is loaded for this record (lazy load)
    func ensureLoaded(_ record: TranscriptionRecord) {
        if loadedRecordId != record.id {
            loadFromRecord(record)
        }
    }

    private func loadFromRecord(_ record: TranscriptionRecord) {
        stop()
        error = nil

        guard let url = record.localAudioURL else {
            error = "No audio file available"
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            error = "Audio file not found"
            return
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        loadedRecordId = record.id

        // Observe when playback reaches end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
            }
        }

        // Periodic time observer
        let interval = CMTime(seconds: 0.05, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
            }
        }

        // Get duration once ready
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay {
                Task { @MainActor in
                    self?.duration = item.duration.seconds
                    self?.isLoaded = true
                }
            } else if item.status == .failed {
                let msg = item.error?.localizedDescription ?? "Unknown error"
                Task { @MainActor in
                    self?.error = msg
                }
            }
        }
    }

    func play() {
        player?.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func stop() {
        player?.pause()
        removeTimeObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        NotificationCenter.default.removeObserver(self)
        player = nil
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
        loadedRecordId = nil
    }

    private func removeTimeObserver() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }
}
