import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_protocol/vault_protocol.dart';

Uint8List bytes(int length, int value) =>
    Uint8List.fromList(List.filled(length, value));

void main() {
  test(
    'envelope snapshots nested payload and authentication identifiers',
    () async {
      final identity = await Identity.generate();
      final recipient = await Identity.generate();
      final session = bytes(16, 3);
      final content = bytes(8, 4);
      final nested = <Object?>[content];
      final payload = <Object, Object?>{'nested': nested};
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final envelope = Envelope(
        type: MsgType.hello,
        sender: identity.signingPublic,
        recipient: recipient.nodeId,
        messageId: bytes(16, 2),
        sessionId: session,
        issuedAt: now,
        expiresAt: now + 60,
        iceGeneration: 0,
        payload: payload,
      );
      session[0] = 99;
      content[0] = 99;
      nested.clear();
      payload.clear();
      final decoded = await decodeEnvelope(
        await encodeEnvelope(identity, envelope),
        now: now,
      );
      expect(decoded.sessionId, bytes(16, 3));
      expect((decoded.payload['nested']! as List<Object?>).single, bytes(8, 4));
      expect(decoded.payload.clear, throwsUnsupportedError);
      expect(
        () => (decoded.payload['nested']! as List<Object?>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            ((decoded.payload['nested']! as List<Object?>).single!
                    as Uint8List)[0] =
                1,
        throwsUnsupportedError,
      );
    },
  );

  test('expired messages cannot reenter state cache after eviction', () async {
    final identity = await Identity.generate();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final envelope = Envelope(
      type: MsgType.hello,
      sender: identity.signingPublic,
      recipient: identity.nodeId,
      messageId: bytes(16, 1),
      sessionId: bytes(16, 2),
      issuedAt: now,
      expiresAt: now + 60,
      iceGeneration: 0,
      payload: {},
    );
    final decoded = await decodeEnvelope(
      await encodeEnvelope(identity, envelope),
      now: now,
    );
    final checks = EnvelopeChecks(identity)..accept(decoded, now: now);
    expect(
      () => checks.accept(decoded, now: now + 60 + clockSkewSeconds + 1),
      throwsA(
        isA<WireReject>().having(
          (e) => e.reason,
          'reason',
          contains('validity'),
        ),
      ),
    );
  });

  test(
    'decode takes an immutable input snapshot before signature await',
    () async {
      final identity = await Identity.generate();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final envelope = Envelope(
        type: MsgType.hello,
        sender: identity.signingPublic,
        recipient: identity.nodeId,
        messageId: bytes(16, 1),
        sessionId: bytes(16, 2),
        issuedAt: now,
        expiresAt: now + 60,
        iceGeneration: 0,
        payload: {'name': 'public'},
      );
      final wire = await encodeEnvelope(identity, envelope);
      final pending = decodeEnvelope(wire, now: now);
      wire.fillRange(0, wire.length, 0);
      expect((await pending).payload['name'], 'public');
    },
  );
}
