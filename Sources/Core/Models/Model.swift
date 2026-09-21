public enum Model: RawRepresentable, Equatable, Hashable, Codable, Sendable {
	case gptRealtime
	case gptRealtimeMini
	case custom(String)

	public var rawValue: String {
		switch self {
			case .gptRealtime: return "gpt-realtime"
			case .gptRealtimeMini: return "gpt-realtime-mini"
			case let .custom(value): return value
		}
	}

	public init?(rawValue: String) {
		switch rawValue {
			case "gpt-realtime": self = .gptRealtime
			case "gpt-realtime-mini": self = .gptRealtimeMini
			default: self = .custom(rawValue)
		}
	}
}

public extension Model {
	/// An input-transcription model name.
	///
	/// THE `.custom` CASE IS THE POINT, and it is here because its absence cost
	/// months. This was a plain `String` enum with four cases and no escape
	/// hatch, which meant an unfamiliar name did not degrade — it threw, and
	/// because `Codable` is depth-first the throw took down the ENTIRE enclosing
	/// event, silently.
	///
	/// Measured in Chip on 2026-09-20: the broker mints sessions with
	/// `gpt-realtime-whisper`, a name this enum had never heard of, so EVERY
	/// `session.created` and `session.updated` failed to decode and was
	/// swallowed by the connector's `catch {}`. `Conversation.session` therefore
	/// stayed nil for entire calls, and the typed `updateSession` threw
	/// `sessionNotFound` 24 times out of 24 in one measured call — which is why
	/// turn detection, voice sensitivity and response pace were all silently
	/// inert on that path and had to be worked around by sending raw JSON. One
	/// unrecognised string, a whole class of events that quietly stopped
	/// existing, and no error anywhere.
	///
	/// `Model` twenty lines above already had the fallback, which is exactly why
	/// `gpt-realtime-2.1` sailed through the same payload. This type now has the
	/// same shape, so the next transcription model OpenAI ships is a string we
	/// do not recognise rather than an outage we cannot see.
	enum Transcription: RawRepresentable, Equatable, Hashable, Codable, Sendable {
		case whisper
		case gpt4o
		case gpt4oMini
		case gpt4oDiarize
		case gptRealtimeWhisper
		case custom(String)

		/// The names this package knows by name. Not `CaseIterable` — `.custom`
		/// makes the set open — but this keeps the four originals enumerable for
		/// anything that was listing them.
		public static let known: [Transcription] = [.whisper, .gpt4o, .gpt4oMini, .gpt4oDiarize, .gptRealtimeWhisper]

		public var rawValue: String {
			switch self {
				case .whisper: return "whisper-1"
				case .gpt4o: return "gpt-4o-transcribe-latest"
				case .gpt4oMini: return "gpt-4o-mini-transcribe"
				case .gpt4oDiarize: return "gpt-4o-transcribe-diarize"
				case .gptRealtimeWhisper: return "gpt-realtime-whisper"
				case let .custom(value): return value
			}
		}

		public init?(rawValue: String) {
			switch rawValue {
				case "whisper-1": self = .whisper
				case "gpt-4o-transcribe-latest": self = .gpt4o
				case "gpt-4o-mini-transcribe": self = .gpt4oMini
				case "gpt-4o-transcribe-diarize": self = .gpt4oDiarize
				case "gpt-realtime-whisper": self = .gptRealtimeWhisper
				default: self = .custom(rawValue)
			}
		}
	}
}
