import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC

/// Taps the model's spoken audio as it plays.
///
/// Upstream renders the remote audio track entirely inside WebRTC, so the app
/// never sees Chip's voice as samples - `send(audioDelta:)` is input-only, and
/// the peer connection is private. That is fine until something outside the
/// audio path needs to react to the voice: a lip-synced avatar cannot be driven
/// by a track it cannot hear.
///
/// `RTCAudioTrack` accepts renderers, so this attaches one and republishes the
/// audio. It observes only - it does not consume, modify, or delay playback,
/// which sounds identical whether or not anyone is listening here.
///
/// The stream carries `Data`, not `AVAudioPCMBuffer`: the buffer is a
/// non-Sendable reference owned by WebRTC's render thread, so handing it across
/// concurrency domains is a data race the compiler correctly rejects. Copying
/// the samples out also lets consumers take the one format that matters here -
/// 16 kHz mono PCM16, what avatar and speech services expect - instead of
/// whatever WebRTC happens to render at.
public final class RemoteAudioTap: NSObject, LKRTCAudioRenderer, @unchecked Sendable {

	/// The model's voice as 16 kHz mono PCM16, little-endian.
	public let pcm16: AsyncStream<Data>
	private let continuation: AsyncStream<Data>.Continuation

	private var converter: AVAudioConverter?
	private var converterInputFormat: AVAudioFormat?

	// The tap owns the track it is attached to. Keeping it here rather than on
	// the connector matters: WebRTCConnector is @Observable and Sendable, so a
	// mutable stored property there gets an observation-tracked backing field
	// the compiler rejects. This class is already @unchecked Sendable and
	// guards its own state.
	private let lock = NSLock()
	private var track: LKRTCAudioTrack?

	public var isAttached: Bool {
		lock.lock(); defer { lock.unlock() }
		return track != nil
	}

	/// Start observing a remote track. Ignored if already attached.
	public func attach(to track: LKRTCAudioTrack) {
		lock.lock()
		guard self.track == nil else { lock.unlock(); return }
		self.track = track
		lock.unlock()
		track.add(self)
	}

	/// Stop observing. The track retains its renderers, so failing to detach
	/// leaks the tap and can deliver audio from an already-torn-down session.
	public func detach() {
		lock.lock()
		let existing = track
		track = nil
		lock.unlock()
		existing?.remove(self)
	}

	private static let targetFormat = AVAudioFormat(
		commonFormat: .pcmFormatInt16,
		sampleRate: 16000,
		channels: 1,
		interleaved: true
	)!

	override public init() {
		// Newest-first with a small bound: a stalled consumer should drop stale
		// audio rather than grow without limit or block render(pcmBuffer:),
		// which runs on WebRTC's realtime audio thread.
		(pcm16, continuation) = AsyncStream.makeStream(
			of: Data.self,
			bufferingPolicy: .bufferingNewest(32)
		)
		super.init()
	}

	public func render(pcmBuffer: AVAudioPCMBuffer) {
		guard let data = convert(pcmBuffer) else { return }
		continuation.yield(data)
	}

	public func finish() {
		continuation.finish()
	}

	// MARK: - Conversion

	private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
		let target = Self.targetFormat

		// Rebuild if WebRTC changes rate or channel count mid-session, which it
		// can do on a route change.
		if converter == nil || converterInputFormat != buffer.format {
			converter = AVAudioConverter(from: buffer.format, to: target)
			converterInputFormat = buffer.format
		}
		guard let converter else { return nil }

		let ratio = target.sampleRate / buffer.format.sampleRate
		let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
		guard capacity > 0,
		      let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
		else { return nil }

		// One input buffer per call: hand it over once, then report end-of-data
		// so the converter drains rather than waiting for more.
		var supplied = false
		var error: NSError?
		converter.convert(to: out, error: &error) { _, status in
			if supplied {
				status.pointee = .noDataNow
				return nil
			}
			supplied = true
			status.pointee = .haveData
			return buffer
		}
		if error != nil { return nil }

		guard out.frameLength > 0, let channel = out.int16ChannelData else { return nil }
		return Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
	}
}
