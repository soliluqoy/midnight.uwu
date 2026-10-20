import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/src/policy.dart';
import 'package:vault_protocol/vault_protocol.dart' show cborEncode;

/// Generates cryptographically secure bytes for session IDs and challenges.
Uint8List freshBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

/// Compares equal-length byte sequences without data-dependent early returns.
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// Requires the complete stored signing/encryption binding to remain unchanged.
bool sameBinding(KeyBinding a, KeyBinding b) =>
    sameBytes(a.signingKey, b.signingKey) &&
    sameBytes(a.encryptionKey, b.encryptionKey) &&
    a.issuedAt == b.issuedAt &&
    sameBytes(a.signature, b.signature);

/// Used by the native session and pure regression tests. Each generation has
/// fresh independent challenges; signatures bind BOTH complete signed SDPs,
/// fingerprints, identities, session ID, generation and challenge directions.
class SessionAuthenticator {
  /// Creates a fresh challenge bound to the supplied signed SDP generation.
  new({
    required this.identity,
    required this.peer,
    required Uint8List session,
    required this.generation,
    required this.offererId,
    required String offer,
    required String answer,
  }) : session = Uint8List.fromList(session),
       offerBinding = SdpBinding.parse(offer),
       answerBinding = SdpBinding.parse(answer),
       challenge = freshBytes(32) {
    if (session.length != 16 || generation < 0) {
      throw const PeerFailure('Invalid session authentication context');
    }
  }

  /// Local identity that signs this endpoint's proof.
  final Identity identity;

  /// Expected trusted signing/encryption binding for the remote endpoint.
  final KeyBinding peer;

  /// Random connection identifier shared through authenticated signaling.
  final Uint8List session;

  /// Negotiated ICE generation; proofs never transfer across generations.
  final int generation;

  /// Expected canonical node ID of the original offerer.
  final String offererId;

  /// Digest and DTLS fingerprint of the complete signed offer.
  final SdpBinding offerBinding;

  /// Digest and DTLS fingerprint of the complete signed answer.
  final SdpBinding answerBinding;

  /// Fresh local challenge for this authentication attempt.
  final Uint8List challenge;
  Uint8List? _remoteChallenge;
  bool _verified = false;
  bool _proofSent = false;
  bool _ready = false;

  /// Whether the peer proof verified and the local proof reached native send.
  bool get authenticated => _verified && _proofSent;

  /// Whether mutually authenticated readiness was also received.
  bool get connected => authenticated && _ready;

  /// Accepts exactly one non-reflected, 32-byte remote challenge.
  void acceptChallenge(Uint8List nonce) {
    if (nonce.length != 32 || sameBytes(nonce, challenge)) {
      throw const PeerFailure('Invalid or reflected authentication challenge');
    }
    if (_remoteChallenge != null) {
      throw const PeerFailure('Repeated authentication challenge');
    }
    _remoteChallenge = Uint8List.fromList(nonce);
  }

  Uint8List _transcript({required bool localSigner}) {
    final remote = _remoteChallenge;
    if (remote == null) throw const PeerFailure('Missing peer challenge');
    return cborEncode({
      1: 'vault/v1/session-auth',
      2: session,
      3: generation,
      4: offererId,
      5: offerBinding.digest,
      6: offerBinding.fingerprint,
      7: answerBinding.digest,
      8: answerBinding.fingerprint,
      9: localSigner ? identity.signingPublic : peer.signingKey,
      10: localSigner ? peer.signingKey : identity.signingPublic,
      11: localSigner ? challenge : remote,
      12: localSigner ? remote : challenge,
    });
  }

  /// Signs the mutually bound transcript without marking it as sent.
  Future<Uint8List> createProof() async {
    if (_proofSent) {
      throw const PeerFailure('Authentication proof already sent');
    }
    if (!await peer.verify()) throw const PeerFailure('Invalid peer binding');
    // Mark only after native send succeeds through markProofSent().
    return await identity.sign(_transcript(localSigner: true));
  }

  /// Marks proof delivery only after the native send completed successfully.
  void markProofSent() {
    if (_remoteChallenge == null || _proofSent) {
      throw const PeerFailure('Invalid authentication send state');
    }
    _proofSent = true;
  }

  /// Verifies a single peer proof against the expected transcript and key.
  Future<void> acceptProof(Uint8List signature) async {
    if (_verified ||
        signature.length != 64 ||
        !await verifyEd25519(
          peer.signingKey,
          _transcript(localSigner: false),
          signature,
        )) {
      throw const PeerFailure('Peer session proof rejected');
    }
    _verified = true;
  }

  /// Accepts peer readiness only after both proof obligations are satisfied.
  void acceptReady() {
    if (!authenticated || _ready) {
      throw const PeerFailure('Premature or repeated authenticated readiness');
    }
    _ready = true;
  }
}

/// Canonical printable connection identifier used in mesh lookup and UI.
String sessionText(Uint8List session) => base64Url.encode(session);
