# vault_vault_signaling

The SignalingStrategy interface plus MQTT (default), Nostr (fallback) and Manual (escape hatch) implementations, backoff, endpoint lists, relay byte-budget guard.

## Contract

- Only signaling payloads may cross a relay; enforced by relay_byte_budget.dart and a unit test.
- Failure of every strategy must degrade to ManualSignaling, never to a hard error.

