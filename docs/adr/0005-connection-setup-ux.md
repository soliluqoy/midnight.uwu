# ADR 0005: Connection setup UX

Date: 2026-10-20. Status: accepted for the experimental app. The product
owner approved the two relaxed rules below. No independent security review has
been done.

## Context

A person could not connect an Android phone on LTE to a Windows laptop on home
Wi-Fi with `apps/vault`. Three causes made the failure likely and invisible:

- Manual signaling was the default and the only setup without configuration.
  A connection needs at least four encrypted frames copied by hand between the
  devices before the three-minute negotiation deadline in
  `packages/vault_net/lib/src/session.dart`. The app bundled no broker.
- Vault dropped some attempts silently. `PeerMesh` ignored offers from peers on
  the explicit-disconnect list with no signal. `SignalingClient` reported a
  frame from an unknown sender only as the generic transport error
  `unknown or changed contact binding`.
- Both people had to copy contact cards to each other before anything worked.

## Decision

### Name every connection problem the person can fix

`ConnectionProblem` in `packages/vault_net/lib/src/policy.dart` is a closed set
of five values: `notAContact`, `youDisconnected`, `negotiationTimedOut`,
`noDirectRoute` and `signalingUnavailable`. The packages emit them as typed
values, not strings:

- `SignalingFailure.kind` classifies unknown senders, transport outages and
  acknowledgment timeouts.
- `PeerFailure.problem` and `PeerSession.problem` carry the session's problem.
  The adapter's `Native peer connection failed` path, which fires only before
  a session ever connected, is `noDirectRoute`.
- `PeerMesh.problems` reports `youDisconnected` for an ignored offer and
  `notAContact` for an ignored noncontact frame.

`problemCopy` in `apps/vault/lib/production/connection_problem.dart` is the one
table that maps each problem to its text and its single remedy (**Pair**,
**Connect** or **Try again**). The app shows the problem in the conversation
header, Contact details, Connection setup and the Chats list. Ignored
noncontact attempts are bounded to five senders. A repeat from one sender
inside one minute does not notify again, and bursts rebuild the UI at most once
per second. The `noDirectRoute` text suggests one device on Wi-Fi or both on
the same network. It never suggests TURN.

### Offer a one-tap internet preset

**Connect over the internet** sets transport `mqtt` with `broker.emqx.io:8883`.
That endpoint passed the Phase 0 public probe
(`docs/spikes/phase0-2026-10-18/mqtt-public.json`, ADR 0004) and a later live
TLS MQTT5 exchange recorded in the app README. The confirm dialog says that the
broker relays only encrypted connection-setup messages, never chats or media,
and that it is a third-party public service with no availability guarantee.

Saved configurations keep their transport, and a new install still defaults to
Manual. The first-run Chats screen and Connection setup offer the preset as the
primary button. Manual exchange and a custom broker stay available.
`PublicConfig` still holds public fields only.

### Pair with a QR code

The host (normally Windows) shows a code, and the scanner (normally Android)
scans or pastes it:

1. The host creates one in-memory `ActivePairing` with 32 random bytes and an
   expiry at most ten minutes away. It shows a `PairingInvite` as
   `vault-pair:1:<base64url CBOR>`. The invite holds the host's verified
   contact card, the broker host and port, the token and the expiry. A typical
   invite is 305 characters, a 61 by 61 module QR code.
2. The scanner parses the invite strictly: a size cap, exact CBOR keys, a
   verified card and the expiry. The scanner shows the host's name and complete
   fingerprint. After the person confirms, the scanner imports the host card.
   If its connection setup differs, it moves to the invite's broker, and it
   asks first when signaling is running.
3. The scanner sends the new signaling type `introduce` (`MsgType.introduce`,
   value 8). The payload is the scanner's encoded contact card and
   `HMAC-SHA256(token, "vault-introduce-v1" ‖ recipient nodeId ‖ card bytes)`.
4. For `introduce` only, `SignalingClient` takes the sender's binding from the
   payload card instead of from contacts. The card's signing key must equal the
   envelope signer, and the card must verify. The app callback then checks the
   MAC in constant time against the active pairing. Only an accepted
   introduction is acknowledged. Every other message type still requires a
   known contact.
5. The host asks once, "<name> wants to pair", with the complete fingerprint.
   **Add contact** adds a contact and dials it. It grants nothing else.
   Library access still needs a separate request and approval.
6. The scanner does not dial. Before it introduces itself, it clears any
   earlier disconnect of the host, the same way **Connect** does, so the
   host's offer is accepted. It then waits for that offer until the invite
   expires, follows the session, and ends as connected or as a named
   `ConnectionProblem`. Hiding the progress dialog stops the wait.

The host dials because only the host knows when its person approves. On
2026-10-20 a scanner that dialed right after the introduction had its offer
rejected as a noncontact frame until the host's person chose **Add contact**.
Its retries backed off, the offer arrived late, and both deadlines expired,
although **Connect** pressed afterwards connected in under a second. If both
devices dial anyway, `PeerMesh` keeps resolving simultaneous offers as before.

When a session fails, its `bye` says so and carries `noDirectRoute` or
`negotiationTimedOut` when that was the cause. The other device then ends
that session as failed with the same problem, instead of as an ordinary
close with no reason. This applies to both the device that dialed and the
device that answered.

## Relaxed rules

**Default broker.** Earlier docs said that no broker is bundled and that Vault
never chooses one. Manual exchange asks too much of most people: several frames
must cross between two devices, by hand, within the deadline. The preset is
still a choice that the person confirms. Vault never switches a saved
configuration silently. The broker is a third-party test service that Vault
does not operate, and the copy says so.

**Camera.** Earlier docs said there is no camera feature. Typing or pasting a
pairing code between a laptop and a phone is the step that fails most often,
and a QR scan removes it. The scanner uses the `camera` plugin (AndroidX
CameraX) and decodes frames with the pure-Dart `zxing2` reader. Google ML Kit
was rejected because it reports usage to Google, which is telemetry. Android
asks for the camera permission only when **Scan pairing code** opens the
camera. The manifest removes the microphone and storage permissions that the
camera plugin declares. Windows scans nothing and accepts pasted code text.

## Threat notes for the pairing token

- Anyone who reads the code before it is used or expires can introduce one
  device. That includes a photo of the screen or the copied text. The host
  confirms each introduction by name and complete fingerprint, and one code
  admits one device.
- The token is single-use and exists only in host memory. Use, expiry, closing
  the dialog and stopping signaling all clear it. A wrong MAC does not consume
  it, so random frames cannot cancel a pairing.
- The MAC binds the token to the intended host (`recipient nodeId`) and to the
  exact card text. The envelope signature binds the card to the sender's key,
  so a valid MAC cannot carry someone else's card.
- The scanner trusts the card in the code. That trust rests on the person
  seeing the host's screen. Display names are not signed, so the complete
  fingerprint is the identity.
- The invite chooses the scanner's broker. A hostile invite can name a hostile
  broker. That broker learns the same metadata as any broker, and it can drop
  frames. It cannot read or forge signaling (ADR 0003). The scanner shows the
  broker host and port before it switches.
- A broker sees the recipient nodeId in the topic, frame timing and frame
  sizes. It does not see setup contents, chats or media.
- Bounds: invite text is at most 1024 characters, the card in an introduction
  is at most 2048 bytes, and each client checks at most four introductions per
  second. The existing 24 KiB frame cap and inbound rate budget still apply.

## What does not change

- There is no TURN relay, including a user-supplied one. Messages and media
  still need a direct route between the devices.
- Carrier NAT can still block every direct route, especially on LTE. Vault then
  reports `noDirectRoute` and suggests a shared network. It does not hide the
  failure or retry through a relay.
- Vault operates no backend and adds no accounts, API keys, telemetry or remote
  configuration.
- `vault_identity` and `vault_protocol` stay pure Dart. Only
  `packages/vault_net/lib/src/webrtc_adapter.dart` imports WebRTC.
- Launch never connects, and pairing starts only when the person chooses it.

## Evidence and limits

Unit and widget tests cover the problem table, the mesh emitting
`youDisconnected` and `notAContact`, strict invite parsing, introduction
acceptance and rejection, the scanner state machine, and a QR encode and
decode round trip through a camera-like frame. Later tests cover the scanner
waiting for the host's session (and never dialing), its expiry and cancel,
the host dialing on **Add contact**, the scanner's allow path through a
persisted disconnect, and an answering session that fails with the other
device's problem. Windows Release and Android
ARM64 Release builds succeed. The merged Android manifest adds only `CAMERA`,
and the APK contains no ML Kit, Google Play services or Firebase classes.
No physical device has run the pairing flow or the camera scanner for this
change, and no LTE-to-Wi-Fi connection has been observed with it.
