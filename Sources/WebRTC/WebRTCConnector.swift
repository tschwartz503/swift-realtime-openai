import Core
import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	public enum WebRTCError: Error {
		case invalidEphemeralKey
		case missingAudioPermission
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case badServerResponse(URLResponse)
		case failedToCreateSDPOffer(Swift.Error)
		case failedToSetLocalDescription(Swift.Error)
		case failedToSetRemoteDescription(Swift.Error)
	}

	public let events: AsyncThrowingStream<ServerEvent, Error>
	@MainActor public private(set) var status = RealtimeAPI.Status.disconnected

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	package let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection

	/// The model's spoken audio, as it plays. Attached to the remote track the
	/// moment it arrives; see RemoteAudioTap for why this exists. Observing
	/// only - playback is identical whether or not anything reads this.
	private let audioTap = RemoteAudioTap()

	/// The model's voice as 16 kHz mono PCM16, for anything that needs to react
	/// to Chip speaking. Observing only; playback is unaffected.
	public var remoteAudio: AsyncStream<Data> { audioTap.pcm16 }

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self
	}

	deinit {
		disconnect()
	}

	package func connect(using request: URLRequest) async throws {
		guard connection.connectionState == .new else { return }

		guard AVAudioApplication.shared.recordPermission == .granted else {
			throw WebRTCError.missingAudioPermission
		}

		try await performHandshake(using: request)
		Self.configureAudioSession()
	}

	public func send(event: ClientEvent) throws {
		try dataChannel.sendData(LKRTCDataBuffer(data: encoder.encode(event), isBinary: false))
	}

	// PATCH (Chip): send a pre-serialized event straight to the data channel.
	// Used for input_image conversation items, which the typed ClientEvent/Item
	// models don't support (realtime-camera-video spec).
	public func sendRaw(_ data: Data) throws {
		try dataChannel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
	}

	public func disconnect() {
		// Detach before closing: the renderer is retained by the track, and
		// leaving it attached across sessions leaks the tap and can deliver
		// buffers from a session the app has already torn down.
		audioTap.detach()
		audioTap.finish()

		connection.close()
		stream.finish()
	}

	public func toggleMute() {
		audioTrack.isEnabled.toggle()
	}
}

extension WebRTCConnector {
	public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
		let connector = try create()
		try await connector.connect(using: request)
		return connector
	}

	package static func create() throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel)
	}
}

private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			connection.add(audioTrack, streamIds: ["local_stream"])
		}
	}

	static func configureAudioSession() {
		#if !os(macOS)
		do {
			let audioSession = AVAudioSession.sharedInstance()
			#if os(tvOS)
			try audioSession.setCategory(.playAndRecord, options: [])
			#else
			try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
			#endif
			try audioSession.setMode(.videoChat)
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
		} catch {
			print("Failed to configure AVAudioSession: \(error)")
		}
		#endif
	}

	func performHandshake(using request: URLRequest) async throws {
		let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
			.mapError(WebRTCError.failedToCreateSDPOffer)
			.get()

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }

		let remoteSdp = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: remoteSdp)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }
	}

	private func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> String {
		var request = request
		request.httpBody = localSdp.data(using: .utf8)
		request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let response = response as? HTTPURLResponse, response.statusCode == 201, let remoteSdp = String(data: data, encoding: .utf8) else {
			if (response as? HTTPURLResponse)?.statusCode == 401 { throw WebRTCError.invalidEphemeralKey }
			throw WebRTCError.badServerResponse(response)
		}

		return remoteSdp
	}
}

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	public func peerConnection(_: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
		// The model's voice arrives here as a remote track. Attaching the tap is
		// what makes the audio observable at all; upstream left this empty and
		// let WebRTC render the track with nothing able to see it.
		guard let track = stream.audioTracks.first else { return }
		audioTap.attach(to: track)
	}
	public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		// Skip (don't crash the stream on) unknown/undecodable events. Patch:
		// must NOT stream.finish(throwing:) here or one unknown event kills the
		// whole voice session. Silent — no console dump of the event payload.
		do { try stream.yield(decoder.decode(ServerEvent.self, from: buffer.data)) }
		catch {}
	}

	public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		Task { @MainActor [state = dataChannel.readyState] in
			switch state {
				case .open: status = .connected
				case .closing, .closed: status = .disconnected
				default: break
			}
		}
	}
}
