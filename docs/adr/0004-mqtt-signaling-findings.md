# ADR 0004: MQTT signaling findings

Date: 2026-10-18. Status: accepted for Phase 1 design; evidence is local-broker and
short public-broker probes only. Nostr and manual signaling are not covered.

## Context

Plan section 2.3 chooses MQTT 5 first and requires verified broker behavior, bounded
reconnect, application acknowledgment, replay defense and end-to-end encryption
(ADR 0003). Evidence is in `docs/spikes/phase0-2026-10-18/mqtt-*.json`; code is in
`spikes/phase0_mqtt/` and `tools/mqtt_testbroker/`.

## Decisions

- Client: `mqtt5_client` 5.1.0 over TLS, QoS 1, clean sessions, one client id per connection.
- Topics: private `vault/v1/in/<nodeId base32>` carries only sealed frames; presence
  `vault/v1/presence/<nodeId base32>` carries signed, unencrypted ANNOUNCE broadcasts
  and must match the signing node. A private topic reveals the recipient nodeId to the broker.
- Never retain. The test broker disables retain; a retained publish reached no later subscriber.
- Reliability above QoS 1: every state-changing message gets a signed, sealed ACK type (7).
  Senders retry with exponential backoff and jitter until ACKed. Receivers deliver once
  and re-ACK duplicates.
- Receivers drop oversize frames (above 24 KiB), apply a per-second frame and byte limit
  before decryption, and surface rejection reasons as counters.
- Reconnect uses full-jitter backoff (400 ms doubling to 6 s) and rotates endpoints in order.
- The client must run inside a guarded zone: killing a broker leaked `SocketException`
  from the library's write path as an uncaught async error in the failover run.

## Results (each one local run, not a statistical claim)

| Check | Result |
|---|---|
| Auth, TLS, ACL | Wrong password, plaintext and untrusted CA all refused; subscribe outside `vault/v1/` refused in SUBACK; retained message not delivered |
| 40% outbound loss on both sides | 9 of 9 messages ACKed, 8 trickle candidates delivered exactly once, 7 duplicate re-ACKs; per-message latency from 26 ms to 12.2 s (retry backoff dominates the tail) |
| Endpoint failure | Primary killed; both peers reconnected to the second broker; next message ACKed 893 ms after the kill |
| Abuse by a credentialed attacker | Replays, garbage, truncated, tampered, expired and oversize frames rejected; 400-frame flood mostly rate limited; honest traffic still ACKed afterwards |
| Pilot discovery, 10 nodes, 30 s heartbeat | Cold-start node found 8 in 19.1 s and 10 in 25.4 s on one shared broker |
| Public broker.emqx.io:8883 | MQTT 5 CONNACK success 1.7 s, SUBACK ok, QoS 1 echo 298 ms |
| Public test.mosquitto.org | 8886 (trusted CA) worked, echo 269 ms. 8883 failed the Dart TLS handshake even though OpenSSL verifies its CA; do not use it from this client |

## Limits and open work

- Any credentialed client can publish to any private topic. Rate limits are global per
  node, so a flood in the same second can starve honest frames. A validly signed message
  from an unknown sender reaches the session layer; approval policy sits above transport.
- Subscription race: `MqttLink` does not await the SUBACK, so an early frame can be missed.
  Retries cover it for ACKed messages; presence and announcements need subscribe-then-announce.
- Redundant brokers are not federated: peers on different endpoints cannot reach each other.
  The failover run only worked because both peers shared the endpoint order.
- Presence replay (stale sequence) and presence-specific spam are implemented but not exercised.
- Public brokers are shared test infrastructure; they may rate-limit, change TLS, or log metadata.
  Disjoint-endpoint discovery, longer outages, mobile networks and the Android client were not tested.
- The 8883 mosquitto failure was not root-caused.

## Experimental core promotion

`packages/vault_signaling` promotes this profile under the implementation-first
revision. The core waits for subscription acknowledgment, keeps private
signaling separate from opt-in signed public presence, bounds raw MQTT Remaining
Length before payload accumulation and advertises a maximum packet size.
Public discovery is metadata-only; unknown public signers do not become trusted
private contacts. Persisted directory records are revalidated from signed bytes.

Discovery policy changes can reconnect the shared transport. An in-flight ACK
may then need duplicate reACK recovery; this is reported as a recoverable
acknowledgment-publish diagnostic, not as malformed incoming ciphertext.
The app/package READMEs record current commands and exercised integration
evidence. Original spike limitations above remain historical observations,
not claims that the experimental core has passed the full outage/mobile matrix.
