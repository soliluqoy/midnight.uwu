# vault_vault_net

PeerMesh: PeerConnection lifecycle, serialized negotiation queue, ICE/STUN configuration, the three data channels, 1 Hz stats polling, keepalive and flap recovery.

## Contract

- flutter_webrtc is imported by exactly one file: webrtc_adapter.dart.
- Negotiation is strictly serialized behind one queue (fixes the desktop addTrack/createOffer race).
- bufferedAmount is polled; bufferedAmountLow is treated as an optimization only.

