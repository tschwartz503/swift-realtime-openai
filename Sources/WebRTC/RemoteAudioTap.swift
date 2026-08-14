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
/// buffers as a stream. It observes only - it does not consume, modify, or
/// delay the audio, and playback is untouched whether or not anyone listens.
public final class RemoteAudioTap: NSObject, LKRTCAudioRenderer, @unchecked Sendable {

	/// Buffers of the model's voice, in whatever format WebRTC renders.
	public let buffers: AsyncStream<AVAudioPCMBuffer>
	private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

	override public init() {
		// Newest-first with a small bound: a consumer that stalls should drop
		// stale audio rather than grow without limit or block the render
		// callback, which runs on WebRTC's realtime thread.
		(buffers, continuation) = AsyncStream.makeStream(
			of: AVAudioPCMBuffer.self,
			bufferingPolicy: .bufferingNewest(32)
		)
		super.init()
	}

	public func render(pcmBuffer: AVAudioPCMBuffer) {
		continuation.yield(pcmBuffer)
	}

	public func finish() {
		continuation.finish()
	}
}
