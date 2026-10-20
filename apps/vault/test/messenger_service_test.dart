import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vault/production/messenger_service.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';

void main() {
  late Directory temp;
  late String aliceId;
  late String bobId;
  late MessengerService alice;
  late MessengerService bob;
  late _Peer alicePeer;
  late _Peer bobPeer;
  final peers = <_Peer>[];
  final bobErrors = <Object>[];

  String path(String name) => '${temp.path}/$name.sqlite3';

  MessengerService open(String name, {int maxMessages = 10000}) {
    final service = MessengerService(
      databasePath: path(name),
      acknowledgementTimeout: const Duration(milliseconds: 250),
      maxMessages: maxMessages,
    );
    if (name == 'bob') service.errors.listen(bobErrors.add);
    return service;
  }

  Future<void> connect() async {
    await alice.detachAll();
    await bob.detachAll();
    final session = 'session-${peers.length}';
    alicePeer = _Peer(alice, bobId, session);
    bobPeer = _Peer(bob, aliceId, session);
    alicePeer.other = bobPeer;
    bobPeer.other = alicePeer;
    peers.addAll([alicePeer, bobPeer]);
    alice.attach(alicePeer);
    bob.attach(bobPeer);
  }

  setUp(() async {
    peers.clear();
    bobErrors.clear();
    temp = await Directory.systemTemp.createTemp('vault-messenger-');
    aliceId = nodeIdText((await Identity.generate()).nodeId);
    bobId = nodeIdText((await Identity.generate()).nodeId);
    alice = open('alice');
    bob = open('bob');
    await connect();
  });

  tearDown(() async {
    await alice.close();
    await bob.close();
    for (final peer in peers) {
      await peer.dispose();
    }
    await temp.delete(recursive: true);
  });

  test(
    'consumer sees preserved text and delivered only after recipient commit',
    () async {
      const text = '  hello\nworld  ';
      final aliceStates = <MessageStatus>[];
      alice.addListener(() {
        final messages = alice.messages(bobId);
        if (messages.isNotEmpty) aliceStates.add(messages.single.status);
      });
      bobPeer.beforeControl = (control) async {
        if (control['op'] != 'ack') return;
        final database = sqlite3.open(path('bob'));
        try {
          final row = database
              .select('SELECT text, status FROM messages')
              .single;
          expect(row['text'], text);
          expect(row['status'], 'received');
          expect(alice.messages(bobId).single.status, MessageStatus.sending);
        } finally {
          database.close();
        }
      };
      await alice.send(alicePeer, text);
      expect(aliceStates, [MessageStatus.sending, MessageStatus.delivered]);
      final sent = alice.messages(bobId).single;
      final received = bob.messages(aliceId).single;
      expect(sent.id, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(sent.status, MessageStatus.delivered);
      expect(sent.outgoing, isTrue);
      expect(received.id, sent.id);
      expect(received.text, text);
      expect(received.outgoing, isFalse);
      expect(received.status, MessageStatus.received);
      expect(bob.unreadCount(aliceId), 1);
      expect(() => bob.messages(aliceId).clear(), throwsUnsupportedError);
    },
  );

  test(
    'acknowledged history and unread markers survive both peers restarting',
    () async {
      await alice.send(alicePeer, 'persisted acknowledgement');
      final id = alice.messages(bobId).single.id;
      await bob.close();
      bob = open('bob');
      expect(bob.messages(aliceId).single.id, id);
      expect(bob.unreadCount(aliceId), 1);
      bob.markRead(aliceId);
      await bob.close();
      bob = open('bob');
      expect(bob.unreadCount(aliceId), 0);
      await alice.close();
      alice = open('alice');
      expect(alice.messages(bobId).single.id, id);
      expect(alice.messages(bobId).single.status, MessageStatus.delivered);
    },
  );

  test(
    'lost ack stays unconfirmed; same-ID retry deduplicates after restart',
    () async {
      bobPeer.dropAcks = true;
      await alice.send(alicePeer, 'received once');
      await _until(
        alice,
        () => alice.messages(bobId).single.status == MessageStatus.unconfirmed,
      );
      final original = alice.messages(bobId).single;
      final wire = alicePeer.sent.single;
      bob.markRead(aliceId);
      await bob.close();
      bob = open('bob');
      await connect();
      await alice.retry(alicePeer, original.id);
      expect(alice.messages(bobId).single.status, MessageStatus.delivered);
      expect(alicePeer.sent.single['id'], original.id);
      expect(bob.messages(aliceId), hasLength(1));
      expect(bob.unreadCount(aliceId), 0);
      await bob.receiveControl(bobPeer, wire);
      expect(bob.messages(aliceId), hasLength(1));
      expect(bob.unreadCount(aliceId), 0);
      final acknowledgements = bobPeer.sent.length;
      await bob.receiveControl(bobPeer, {
        ...wire,
        'body': base64Encode(utf8.encode('changed')),
      });
      expect(bob.messages(aliceId).single.text, original.text);
      expect(bobPeer.sent, hasLength(acknowledgements));
      expect(bobErrors.whereType<FormatException>(), isNotEmpty);
    },
  );

  test(
    'a committed pending snapshot restarts as unconfirmed without resend',
    () async {
      await alice.close();
      alice = MessengerService(
        databasePath: path('alice'),
        acknowledgementTimeout: const Duration(seconds: 10),
      );
      await connect();
      bobPeer.dropAcks = true;
      await alice.send(alicePeer, 'pending at crash');
      expect(alice.messages(bobId).single.status, MessageStatus.sending);
      // DELETE journaling leaves a complete committed snapshot between writes.
      final snapshot = await File(path('alice')).copy(path('crash-snapshot'));
      final restarted = MessengerService(databasePath: snapshot.path);
      try {
        expect(
          restarted.messages(bobId).single.status,
          MessageStatus.unconfirmed,
        );
        expect(alicePeer.sent, hasLength(1));
        expect(restarted.messages(bobId).single.text, 'pending at crash');
      } finally {
        await restarted.close();
      }
    },
  );

  test(
    '4096 UTF-8 bytes and JSON-escaped bodies fit; blank and oversize refuse',
    () async {
      final boundary = List.filled(1024, '\u{1f642}').join();
      expect(utf8.encode(boundary), hasLength(MessengerService.maxTextBytes));
      await alice.send(alicePeer, boundary);
      expect(bob.messages(aliceId).single.text, boundary);
      await expectLater(
        alice.send(alicePeer, '$boundary\u{1f642}'),
        throwsFormatException,
      );
      await expectLater(alice.send(alicePeer, ' \n\t '), throwsFormatException);
      await expectLater(alice.send(alicePeer, '\ud800'), throwsFormatException);
      final escaped = '${List.filled(4095, '\u0000').join()}a';
      await alice.send(alicePeer, escaped);
      expect(bob.messages(aliceId).last.text, escaped);
      expect(alice.messages(bobId), hasLength(2));
      final oversized = {
        ...alicePeer.sent.first,
        'id': List.filled(32, 'f').join(),
        'body': base64Encode(utf8.encode('$boundary\u{1f642}')),
      };
      await bob.receiveControl(bobPeer, oversized);
      await bob.receiveControl(bobPeer, {
        ...alicePeer.sent.first,
        'unexpected': true,
      });
      await bob.receiveControl(bobPeer, {...alicePeer.sent.first, 'v': 2});
      expect(bob.messages(aliceId), hasLength(2));
    },
  );

  test(
    'wrong peer, replacement session and interrupted ack cannot deliver',
    () async {
      final strangerId = nodeIdText((await Identity.generate()).nodeId);
      bobPeer.dropAcks = true;
      await alice.send(alicePeer, 'session-bound acknowledgement');
      final id = alice.messages(bobId).single.id;
      final ack = <String, Object?>{
        'vault': 'messenger',
        'v': 1,
        'op': 'ack',
        'id': id,
      };
      final stranger = _Peer(alice, strangerId, alicePeer.sessionId);
      peers.add(stranger);
      alice.attach(stranger);
      await alice.receiveControl(stranger, ack);
      expect(alice.messages(bobId).single.status, MessageStatus.sending);
      final stale = alicePeer;
      await connect();
      expect(alice.messages(bobId).single.status, MessageStatus.unconfirmed);
      bobPeer.dropAcks = true;
      await alice.retry(alicePeer, id);
      await alice.receiveControl(stale, ack);
      expect(alice.messages(bobId).single.status, MessageStatus.sending);
      alicePeer.changeState(PeerSessionState.negotiating);
      expect(alice.messages(bobId).single.status, MessageStatus.unconfirmed);
      alicePeer.changeState(PeerSessionState.connected);
      await alice.receiveControl(alicePeer, ack);
      expect(alice.messages(bobId).single.status, MessageStatus.unconfirmed);
      bobPeer.dropAcks = false;
      await alice.retry(alicePeer, id);
      expect(alice.messages(bobId).single.status, MessageStatus.delivered);
      expect(bob.messages(aliceId), hasLength(1));
    },
  );

  test(
    'interrupted sends remain unconfirmed without automatic resend',
    () async {
      final gate = Completer<void>();
      alicePeer.beforeControl = (_) => gate.future;
      final sending = alice.send(alicePeer, 'interrupted send');
      final failed = expectLater(sending, throwsStateError);
      expect(alice.messages(bobId).single.status, MessageStatus.sending);
      alicePeer.changeState(PeerSessionState.negotiating);
      expect(alice.messages(bobId).single.status, MessageStatus.unconfirmed);
      gate.complete();
      await failed;
      alicePeer.changeState(PeerSessionState.connected);
      expect(alicePeer.sent, isEmpty);
      expect(bob.messages(aliceId), isEmpty);
      await alice.retry(alicePeer, alice.messages(bobId).single.id);
      expect(alice.messages(bobId).single.status, MessageStatus.delivered);
    },
  );

  test(
    'full history refuses new messages but retains duplicate acknowledgements',
    () async {
      await bob.close();
      bob = open('bob', maxMessages: 1);
      await connect();
      await alice.send(alicePeer, 'last available entry');
      final first = alicePeer.sent.single;
      await alice.send(alicePeer, 'refused, not delivered');
      await _until(
        alice,
        () => alice.messages(bobId).last.status == MessageStatus.unconfirmed,
      );
      expect(bob.messages(aliceId), hasLength(1));
      final before = bobPeer.sent.length;
      await bob.receiveControl(bobPeer, first);
      expect(bobPeer.sent, hasLength(before + 1));
      expect(bobErrors.whereType<StateError>(), isNotEmpty);
      await bob.close();
      bob = open('bob', maxMessages: 1);
      expect(bob.messages(aliceId).single.text, 'last available entry');
    },
  );

  test(
    'incoming work is bounded and close joins active acknowledgements',
    () async {
      final gate = Completer<void>();
      bobPeer.beforeControl = (_) => gate.future;
      final work = <Future<void>>[];
      for (var i = 0; i < 33; i++) {
        work.add(
          bob.receiveControl(bobPeer, {
            'vault': 'messenger',
            'v': 1,
            'op': 'message',
            'id': i.toRadixString(16).padLeft(32, '0'),
            'sentAt': 1000,
            'body': base64Encode(utf8.encode('bounded $i')),
          }),
        );
      }
      expect(bob.messages(aliceId), hasLength(32));
      var closed = false;
      final closing = bob.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      gate.complete();
      await Future.wait(work);
      await closing;
      bob = open('bob');
      expect(bob.messages(aliceId), hasLength(32));
      expect(bobErrors.whereType<StateError>(), isNotEmpty);
    },
  );
}

Future<void> _until(MessengerService service, bool Function() predicate) async {
  if (predicate()) return;
  final result = Completer<void>();
  void changed() {
    if (predicate() && !result.isCompleted) result.complete();
  }

  service.addListener(changed);
  try {
    await result.future.timeout(const Duration(seconds: 3));
  } finally {
    service.removeListener(changed);
  }
}

/// Only the peer boundary is simulated; storage and acknowledgements are real.
/// The native application smoke separately exercises authenticated transport.
class _Peer implements PeerSession {
  new(this.messenger, this.peerId, this.sessionId);
  final MessengerService messenger;
  @override
  final String peerId;
  @override
  final String sessionId;
  _Peer? other;
  final _states = StreamController<PeerSessionState>.broadcast(sync: true);
  final sent = <Map<String, Object?>>[];
  Future<void> Function(Map<String, Object?>)? beforeControl;
  bool dropAcks = false;
  int _epoch = 0;
  @override
  PeerSessionState state = PeerSessionState.connected;
  @override
  Stream<PeerSessionState> get states => _states.stream;

  void changeState(PeerSessionState next) {
    if (next != PeerSessionState.connected) _epoch++;
    state = next;
    _states.add(next);
  }

  @override
  Future<void> sendControl(Map<String, Object?> control) async {
    if (state != PeerSessionState.connected) throw StateError('Disconnected');
    final epoch = _epoch;
    await beforeControl?.call(control);
    if (state != PeerSessionState.connected || epoch != _epoch) {
      throw StateError('Route interrupted');
    }
    if (utf8.encode(jsonEncode(control)).length > maxPeerPayloadBytes) {
      throw StateError('Oversized native control payload');
    }
    sent.add(Map<String, Object?>.unmodifiable(control));
    if (control['op'] == 'ack' && dropAcks) return;
    final recipient = other;
    if (recipient == null) throw StateError('No connected recipient');
    await recipient.messenger.receiveControl(recipient, control);
  }

  @override
  Future<void> close() async {
    changeState(PeerSessionState.closed);
  }

  Future<void> dispose() => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
