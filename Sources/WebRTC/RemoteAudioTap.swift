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

	// A resampler has to be CONTINUOUS. Converting each render callback in
	// isolation - hand over one buffer, then report end-of-data - throws away
	// the filter's tail every single time, and at 10ms buffers that is a fixed
	// ~20% of every callback. Measured on device: 15.9s of audio produced from
	// 19.8s of speech, exactly 80%, which Simli renders as a mouth running
	// ahead of words that were never sent.
	//
	// So carry the state instead: unconsumed input samples and a fractional
	// read position that survive between callbacks.
	private var phase: Double = 0
	private var inputRate: Double = 0
	/// One sample of history is all linear interpolation needs across a
	/// callback boundary. Accumulating a buffer instead meant a heap allocation
	/// and an O(n) shift on WebRTC's realtime render thread every 10ms, which
	/// glitches the audio the user is actually listening to.
	private var lastSample: Float = 0

	/// Seconds of audio in and out, for diagnosing where duration goes missing.
	public private(set) var inputSeconds: Double = 0
	public private(set) var outputSeconds: Double = 0

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

	/// Simli's ingest rate, and what every consumer of this stream expects.
	private static let targetSampleRate: Double = 16000

	override public init() {
		// Unbounded, deliberately. A consumer that renders a talking head from
		// these bytes re-speaks them: a dropped chunk is not a dropped frame,
		// it is a syllable the face never says, and the mouth stays ahead of
		// the audio for the rest of the turn. `yield` never blocks, so this
		// cannot stall render(pcmBuffer:) on WebRTC's realtime thread either
		// way - the only cost of not dropping is memory, and 16 kHz mono PCM16
		// is 32 KB/s.
		(pcm16, continuation) = AsyncStream.makeStream(
			of: Data.self,
			bufferingPolicy: .unbounded
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
		let rate = buffer.format.sampleRate
		let frames = Int(buffer.frameLength)
		guard rate > 0, frames > 0 else { return nil }

		if rate != inputRate {
			phase = 0
			lastSample = 0
			inputRate = rate
		}
		inputSeconds += Double(frames) / rate

		let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
		let step = rate / Self.targetSampleRate

		// Read straight from WebRTC's buffer. No copy, no accumulation, no
		// shifting - this runs on the realtime render thread and anything that
		// allocates or moves memory here is audible in the playback itself.
		func render(_ sampleAt: (Int) -> Float) -> [Int16] {
			var out = [Int16]()
			out.reserveCapacity(Int(Double(frames) / step) + 2)
			var pos = phase
			// Index -1 is the last sample of the previous callback, which is
			// what makes the seam between buffers continuous.
			while pos < Double(frames) - 1 {
				let index = Int(pos.rounded(.down))
				let frac = Float(pos - Double(index))
				let a = index < 0 ? lastSample : sampleAt(index)
				let b = sampleAt(index + 1)
				out.append(Int16(max(-32767, min(32767, (a + (b - a) * frac) * 32767))))
				pos += step
			}
			phase = pos - Double(frames)
			lastSample = sampleAt(frames - 1)
			return out
		}

		var samples: [Int16]
		if let floats = buffer.floatChannelData {
			let src = floats[0]
			samples = render { src[$0 * stride] }
		} else if let ints = buffer.int16ChannelData {
			let src = ints[0]
			samples = render { Float(src[$0 * stride]) / 32768.0 }
		} else {
			return nil
		}

		guard !samples.isEmpty else { return nil }
		outputSeconds += Double(samples.count) / Self.targetSampleRate
		return samples.withUnsafeBufferPointer { Data(buffer: $0) }
	}
}
