# A modern Swift SDK for OpenAI's Realtime API

[![Install Size](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fwww.emergetools.com%2Fapi%2Fv2%2Fpublic_new_build%3FexampleId%3Dswift-realtime-openai.OpenAIRealtime%26platform%3Dios%26badgeOption%3Dmax_install_size_only%26buildType%3Drelease&query=$.badgeMetadata&label=OpenAI&logo=apple)](https://www.emergetools.com/app/example/ios/swift-realtime-openai.OpenAIRealtime/release)
[![Swift Version](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fm1guelpf%2Fswift-realtime-openai%2Fbadge%3Ftype%3Dswift-versions&color=brightgreen)](https://swiftpackageindex.com/m1guelpf/swift-realtime-openai)
[![GitHub license](https://img.shields.io/badge/license-MIT-blue.svg)](https://raw.githubusercontent.com/m1guelpf/swift-realtime-openai/main/LICENSE)

This library provides a simple interface for implementing multi-modal conversations using OpenAI's new Realtime API.

It can handle automatically recording the user's microphone and playing back the assistant's response, and also gives you a transparent layer over the API for advanced use cases.

## Installation

### Swift Package Manager

For the production WebRTC surface described below, use the `RealtimeWebRTC`
product from `https://github.com/ryumiel/swift-realtime-openai.git`. Consumers
must select an independently reviewed immutable commit. The mutable `main`
branch and all other branch references are forbidden production selectors.

## Getting started 🚀

You can build an iMessage-like app with built-in AI chat in less than 60 lines of code (UI included!):

```swift
import SwiftUI
import RealtimeAPI

struct ContentView: View {
	@State private var newMessage: String = ""
	@State private var conversation = try! Conversation()

	var messages: [Item.Message] {
		conversation.entries.compactMap { switch $0 {
			case let .message(message): return message
			default: return nil
		} }
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
                VStack(spacing: 12) {
                    ForEach(messages, id: \.id) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding()
			}

			HStack(spacing: 12) {
				HStack {
					TextField("Chat", text: $newMessage, onCommit: { sendMessage() })
						.frame(height: 40)
						.submitLabel(.send)

					if newMessage != "" {
						Button(action: sendMessage) {
							Image(systemName: "arrow.up.circle.fill")
								.resizable()
								.aspectRatio(contentMode: .fill)
								.frame(width: 28, height: 28)
								.foregroundStyle(.white, .blue)
						}
					}
				}
				.padding(.leading)
				.padding(.trailing, 6)
				.overlay(RoundedRectangle(cornerRadius: 20).stroke(.quaternary, lineWidth: 1))
			}
			.padding()
		}
		.navigationTitle("Chat")
		.navigationBarTitleDisplayMode(.inline)
		.task { try! await conversation..connect(ephemeralKey: YOUR_EPHEMERAL_KEY_HERE) }
	}

	func sendMessage() {
		guard newMessage != "" else { return }

		Task {
			try await conversation.send(from: .user, text: newMessage)
			newMessage = ""
		}
	}
}
```

Or, if you just want a simple app that lets the user talk and the AI respond:

```swift
import SwiftUI
import RealtimeAPI

struct ContentView: View {
	@State private var conversation = try! Conversation()

	var body: some View {
		Text("Say something!")
			.task { try! await conversation..connect(ephemeralKey: YOUR_EPHEMERAL_KEY_HERE) }
	}
}
```


## Architecture

### `Conversation`

The `Conversation` class provides a high-level interface for managing a conversation with the model. It wraps the `RealtimeAPI` class and handles the details of sending and receiving messages, managing the conversation history, recording the user's mic, and playing model responses as they stream in.

#### Reading messages

You can access the messages in the conversation through the `messages` property. Note that this won't include function calls and its responses, only the messages between the user and the model. To access the full conversation history, use the `entries` property. For example:

```swift
ScrollView {
    ScrollViewReader { scrollView in
        VStack(spacing: 12) {
            ForEach(conversation.messages, id: \.id) { message in
                MessageBubble(message: message).id(message.id)
            }
        }
        .onReceive(conversation.messages.publisher) { _ in
            withAnimation { scrollView.scrollTo(conversation.messages.last?.id, anchor: .center) }
        }
    }
}
```

#### Customizing the session

You can customize the current session using the `setSession(_: Session)` or `updateSession(withChanges: (inout Session) -> Void)` methods. Note that they requires that a session has already been established, so it's recommended you call them from a `whenConnected(_: @Sendable () async throws -> Void)` callback or await `waitForConnection()` first. For example:

```swift
try await conversation.whenConnected {
    try await conversation.updateSession { session in
        // update system prompt
        session.instructions = "You are a helpful assistant."

        // enable transcription of users' voice messages
        session.inputAudioTranscription = Session.InputAudioTranscription()

        // ...
    }
}
```

#### Manually sending messages

To send a text message, call the `send(from: Item.ItemRole, text: String, response: Response.Config? = nil)` providing the role of the sender (`.user`, `.assistant`, or `.system`) and the contents of the message. You can optionally also provide a `Response.Config` object to customize the response, such as enabling or disabling function calls.

To manually send an audio message (or part of one), call the `send(audioDelta: Data, commit: Bool = false)` with a valid audio chunk. If `commit` is `true`, the model will consider the message finished and begin responding to it. Otherwise, it might wait for more audio depending on your `Session.turnDetection` settings.

#### Manually sending events

To manually send an event to the API, use the `send(event: RealtimeAPI.ClientEvent)` method. Note that this bypasses some of the logic in the `Conversation` class such as handling interrupts, so you should prefer to use other methods whenever possible.

### Production WebRTC peer

Regular imports use `WebRTCConnectorPeerFactory` for the production WebRTC boundary. Provider identity and initial audio state are bound before any peer or media resource is created. LocalAI starts enabled; OpenAI starts disabled until its exact session acknowledgement has been received.

```swift
import WebRTC

@MainActor
func runOpenAISession() async throws {
    let factory = WebRTCConnectorPeerFactory(provider: .openAI, initialAudioState: .disabled)
    let peer = try factory.makePeer()
    var events = peer.events.makeAsyncIterator()
    let eventTask = Task { @MainActor in
        while let event = try await events.next() {
            switch event {
            case .ready:
                try peer.configure(.openAI(language: "en"))
            case .openAISessionConfigured(language: "en"):
                // The exact acknowledgement opens the audio gate.
                peer.setLocalAudioState(.enabled)
            default:
                handle(event)
            }
        }
    }

    do {
        let offer = try await peer.makeOffer()
        let answer = try await exchangeOfferForAnswer(offer)
        try await peer.apply(remoteAnswer: answer)
        try await waitForCallerStop()
        await peer.closeAndJoin()
        try await eventTask.value
    } catch {
        await peer.closeAndJoin()
        eventTask.cancel()
        _ = try? await eventTask.value
        throw error
    }
}
```

To cancel a response, call `cancelResponse()`, then `clearOutputAudio()`, then
establish the caller-owned bounded proof that predecessor output is quiescent.
Only after that proof succeeds, call `settleCancelledResponse()` before
admitting a successor response. `.responseCancellationTerminalObserved` is an
optional correlated signal; by itself it is neither necessary nor sufficient
for that proof. The legacy `RealtimeAPI.webRTC` credential and signaling
helpers are qualification-only SPI and are unavailable to ordinary imports.
WebSocket sources are retained outside the package's published product graph
and are not part of this production surface.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
