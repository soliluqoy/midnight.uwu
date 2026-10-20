import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';

/// Delivered means the authenticated recipient committed this message locally.
enum MessageStatus { sending, delivered, unconfirmed, received }

/// An immutable local conversation entry. Message bodies are never trimmed.
class ChatMessage {
  const new({
    required this.id,
    required this.peerId,
    required this.text,
    required this.sentAt,
    required this.outgoing,
    required this.status,
  });

  final String id;
  final String peerId;
  final String text;
  final DateTime sentAt;
  final bool outgoing;
  final MessageStatus status;

  ChatMessage _withStatus(MessageStatus value) => ChatMessage(
    id: id,
    peerId: peerId,
    text: text,
    sentAt: sentAt,
    outgoing: outgoing,
    status: value,
  );
}

class _Attachment {
  new(this.session);
  final PeerSession session;
  // MessengerService.detach/close cancels this attachment's subscription.
  // ignore: cancel_subscriptions
  StreamSubscription<PeerSessionState>? subscription;
  int epoch = 0;
}

class _Acknowledgement {
  new(this.attachment, this.epoch);
  final _Attachment attachment;
  final int epoch;
  Timer? timer;
}

/// Direct, authenticated text chat with bounded, private-app-local history.
///
/// SQLite is not encrypted at rest. No mailbox or automatic resend exists.
/// The packet consumer must route messenger controls to [receiveControl]; this
/// service deliberately never subscribes to the single-consumer packet stream.
class MessengerService extends ChangeNotifier {
  new({
    required String databasePath,
    this.acknowledgementTimeout = const Duration(seconds: 15),
    this.maxMessages = 10000,
  }) {
    if (databasePath.isEmpty || databasePath == ':memory:') {
      throw ArgumentError.value(databasePath, 'databasePath');
    }
    if (maxMessages < 1 || maxMessages > 100000) {
      throw ArgumentError.value(maxMessages, 'maxMessages');
    }
    if (acknowledgementTimeout <= Duration.zero) {
      throw ArgumentError.value(
        acknowledgementTimeout,
        'acknowledgementTimeout',
      );
    }
    final file = File(databasePath);
    final maxBytes = maxMessages * 8192 + 1024 * 1024;
    if (file.existsSync() && file.lengthSync() > maxBytes) {
      throw StateError('Message history exceeds its configured disk budget.');
    }
    file.parent.createSync(recursive: true);
    _database = sqlite3.open(databasePath);
    try {
      _database
        ..execute('PRAGMA page_size = 4096')
        ..execute('PRAGMA max_page_count = ${maxBytes ~/ 4096}')
        ..execute('PRAGMA journal_mode = DELETE')
        ..execute('PRAGMA synchronous = FULL')
        ..execute('PRAGMA busy_timeout = 1000');
      final version = _database
          .select('PRAGMA user_version')
          .single
          .values
          .single;
      if (version != 0 && version != 1) {
        throw StateError('Unsupported message history version.');
      }
      _database
        ..execute('''
        CREATE TABLE IF NOT EXISTS messages (
          sequence INTEGER PRIMARY KEY,
          peer_id TEXT NOT NULL CHECK(length(peer_id) = 52),
          id TEXT NOT NULL CHECK(length(id) = 32),
          text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 4096),
          sent_at INTEGER NOT NULL CHECK(sent_at BETWEEN 0 AND 253402300799999),
          outgoing INTEGER NOT NULL CHECK(outgoing IN (0, 1)),
          status TEXT NOT NULL CHECK(status IN ('sending', 'delivered', 'unconfirmed', 'received')),
          is_read INTEGER NOT NULL CHECK(is_read IN (0, 1)),
          UNIQUE(peer_id, id),
          CHECK((outgoing = 0 AND status = 'received') OR
                (outgoing = 1 AND status != 'received'))
        )
      ''')
        ..execute('PRAGMA user_version = 1');
      final count =
          _database
                  .select('SELECT COUNT(*) AS count FROM messages')
                  .single['count']
              as int;
      if (count > maxMessages) {
        throw StateError('Message history exceeds its configured entry limit.');
      }
      // A process restart cannot establish whether the recipient committed it.
      _database.execute(
        "UPDATE messages SET status = 'unconfirmed' WHERE status = 'sending'",
      );
      for (final row in _database.select(
        'SELECT * FROM messages ORDER BY sequence',
      )) {
        final peerId = row['peer_id'] as String;
        nodeIdFromText(peerId);
        final message = ChatMessage(
          id: row['id'] as String,
          peerId: peerId,
          text: row['text'] as String,
          sentAt: DateTime.fromMillisecondsSinceEpoch(
            row['sent_at'] as int,
            isUtc: true,
          ),
          outgoing: row['outgoing'] == 1,
          status: MessageStatus.values.byName(row['status'] as String),
        );
        _validateId(message.id);
        _validateText(message.text);
        _remember(message, unread: !message.outgoing && row['is_read'] == 0);
      }
    } on Object {
      _database.close();
      rethrow;
    }
  }

  static const maxTextBytes = 4096;
  static const _maxWork = 32;
  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');
  final Duration acknowledgementTimeout;

  /// At capacity new entries are refused; deduplication records are retained.
  final int maxMessages;
  late final Database _database;
  final _history = <String, List<ChatMessage>>{};
  final _entries = <(String, String), ChatMessage>{};
  final _unread = <String, Set<String>>{};
  final _attachments = <String, _Attachment>{};
  final _pending = <(String, String), _Acknowledgement>{};
  final _active = <Future<void>>{};
  final _errors = StreamController<Object>.broadcast();
  final _random = Random.secure();
  int _incomingWork = 0;
  int _outgoingWork = 0;
  bool _closing = false;
  Future<void>? _closeFuture;

  /// Storage/protocol/send errors are separate from media service failures.
  Stream<Object> get errors => _errors.stream;

  List<ChatMessage> messages(String peerId) =>
      List<ChatMessage>.unmodifiable(_history[peerId] ?? const <ChatMessage>[]);

  int unreadCount(String peerId) => _unread[peerId]?.length ?? 0;

  /// SQLite mutations serialize with receive commits on this isolate.
  /// Failed read-marker writes preserve unread state and report the error.
  void markRead(String peerId) {
    if (_closing || unreadCount(peerId) == 0) return;
    try {
      _database.execute(
        'UPDATE messages SET is_read = 1 WHERE peer_id = ? AND outgoing = 0',
        <Object?>[peerId],
      );
      _unread.remove(peerId);
      notifyListeners();
    } on Object catch (error) {
      _report(error);
    }
  }

  void attach(PeerSession session) {
    _ensureOpen();
    nodeIdFromText(session.peerId);
    final previous = _attachments[session.peerId];
    if (identical(previous?.session, session)) return;
    if (previous != null) unawaited(detach(previous.session));
    if (_attachments.length >= 16) throw StateError('Messenger session limit.');
    final attachment = _Attachment(session);
    _attachments[session.peerId] = attachment;
    attachment.subscription = session.states.listen((state) {
      if (!identical(_attachments[session.peerId], attachment)) return;
      if (state != PeerSessionState.connected) _interrupt(attachment);
      if (state == PeerSessionState.closed ||
          state == PeerSessionState.failed) {
        unawaited(detach(session));
      }
    });
  }

  Future<void> detach(PeerSession session) async {
    final attachment = _attachments[session.peerId];
    if (attachment == null || !identical(attachment.session, session)) return;
    _attachments.remove(session.peerId);
    _interrupt(attachment);
    await attachment.subscription?.cancel();
  }

  Future<void> detachAll() async {
    await Future.wait([
      for (final attachment in _attachments.values.toList())
        detach(attachment.session),
    ]);
  }

  Future<void> send(PeerSession session, String text) async {
    final attachment = _requireSession(session);
    _validateText(text);
    _requireOutgoingCapacity();
    String id;
    do {
      id = List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    } while (_entries.containsKey((session.peerId, id)));
    final message = ChatMessage(
      id: id,
      peerId: session.peerId,
      text: text,
      sentAt: DateTime.now().toUtc(),
      outgoing: true,
      status: MessageStatus.sending,
    );
    _insert(message, unread: false);
    await _transmit(attachment, message);
  }

  Future<void> retry(PeerSession session, String messageId) async {
    final attachment = _requireSession(session);
    final message = _entries[(session.peerId, messageId)];
    if (message == null ||
        !message.outgoing ||
        message.status != MessageStatus.unconfirmed) {
      throw StateError(
        'Only an unconfirmed message to this contact can be retried.',
      );
    }
    _requireOutgoingCapacity();
    try {
      _setStatus(message, MessageStatus.sending);
    } on Object catch (error) {
      _report(error);
      rethrow;
    }
    await _transmit(attachment, message);
  }

  void _requireOutgoingCapacity() {
    if (_outgoingWork >= _maxWork || _pending.length >= _maxWork) {
      throw StateError('Too many messages awaiting confirmation.');
    }
  }

  Future<void> _transmit(_Attachment attachment, ChatMessage message) {
    final key = (message.peerId, message.id);
    final pending = _Acknowledgement(attachment, attachment.epoch);
    _pending[key] = pending;
    pending.timer = Timer(acknowledgementTimeout, () {
      if (identical(_pending[key], pending)) {
        _pending.remove(key);
        _unconfirm(message);
      }
    });
    _outgoingWork++;
    return _track(() async {
      try {
        if (!_current(attachment, pending.epoch)) {
          throw StateError('Contact disconnected before sending.');
        }
        await attachment.session.sendControl({
          'vault': 'messenger',
          'v': 1,
          'op': 'message',
          'id': message.id,
          'sentAt': message.sentAt.millisecondsSinceEpoch,
          // Base64 keeps even 4096 bytes of JSON-escaped controls below 16 KiB.
          'body': base64Encode(utf8.encode(message.text)),
        });
      } on Object catch (error) {
        if (identical(_pending[key], pending)) {
          _pending.remove(key);
          pending.timer?.cancel();
          _unconfirm(message);
        }
        _report(error);
        rethrow;
      } finally {
        _outgoingWork--;
      }
    });
  }

  /// Called only by the existing delivery packet consumer, with a work budget.
  Future<void> receiveControl(
    PeerSession session,
    Map<String, Object?> control,
  ) {
    if (_closing) return Future<void>.value();
    if (_incomingWork >= _maxWork) {
      _report(
        StateError('Messenger incoming work limit; message not acknowledged.'),
      );
      return Future<void>.value();
    }
    _incomingWork++;
    return _track(() async {
      try {
        final attachment = _requireSession(session);
        final epoch = attachment.epoch;
        final op = control['op'];
        final id = control['id'];
        if (control['vault'] != 'messenger' ||
            control['v'] is! int ||
            control['v'] != 1 ||
            id is! String ||
            (op != 'message' && op != 'ack')) {
          throw const FormatException('Invalid messenger envelope.');
        }
        _validateId(id);
        if (op == 'ack') {
          _requireKeys(control, const {'vault', 'v', 'op', 'id'});
          final key = (session.peerId, id);
          final pending = _pending[key];
          if (pending == null ||
              !identical(pending.attachment, attachment) ||
              pending.epoch != epoch ||
              !_current(attachment, epoch)) {
            return;
          }
          _pending.remove(key);
          pending.timer?.cancel();
          final message = _entries[key]!;
          try {
            _setStatus(message, MessageStatus.delivered);
          } on Object {
            _unconfirm(message);
            rethrow;
          }
          return;
        }
        _requireKeys(control, const {
          'vault',
          'v',
          'op',
          'id',
          'sentAt',
          'body',
        });
        final timestamp = control['sentAt'];
        final body = control['body'];
        if (timestamp is! int ||
            timestamp < 0 ||
            timestamp > 253402300799999 ||
            body is! String ||
            body.length > ((maxTextBytes + 2) ~/ 3) * 4) {
          throw const FormatException('Invalid messenger body.');
        }
        final bytes = base64Decode(body);
        if (base64Encode(bytes) != body || bytes.length > maxTextBytes) {
          throw const FormatException('Invalid messenger text encoding.');
        }
        final text = utf8.decode(bytes);
        _validateText(text);
        final previous = _entries[(session.peerId, id)];
        if (previous != null) {
          if (previous.outgoing ||
              previous.text != text ||
              previous.sentAt.millisecondsSinceEpoch != timestamp) {
            throw const FormatException('Message ID collision.');
          }
        } else {
          _insert(
            ChatMessage(
              id: id,
              peerId: session.peerId,
              text: text,
              sentAt: DateTime.fromMillisecondsSinceEpoch(
                timestamp,
                isUtc: true,
              ),
              outgoing: false,
              status: MessageStatus.received,
            ),
            unread: true,
          );
        }
        // Commit before acknowledging, including duplicate messages.
        if (_current(attachment, epoch)) {
          await session.sendControl({
            'vault': 'messenger',
            'v': 1,
            'op': 'ack',
            'id': id,
          });
        }
      } on Object catch (error) {
        _report(error);
      } finally {
        _incomingWork--;
      }
    });
  }

  static void _requireKeys(Map<String, Object?> value, Set<String> keys) {
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      throw const FormatException('Unexpected messenger fields.');
    }
  }

  static void _validateId(String id) {
    if (!_idPattern.hasMatch(id)) {
      throw const FormatException('Invalid message ID.');
    }
  }

  static void _validateText(String text) {
    if (text.length > maxTextBytes || text.trim().isEmpty) {
      throw const FormatException(
        'Message must contain 1–4096 UTF-8 bytes of nonblank text.',
      );
    }
    final bytes = utf8.encode(text);
    if (bytes.length > maxTextBytes || utf8.decode(bytes) != text) {
      throw const FormatException(
        'Message exceeds 4096 UTF-8 bytes or contains invalid Unicode.',
      );
    }
  }

  void _insert(ChatMessage message, {required bool unread}) {
    try {
      if (_entries.length >= maxMessages) {
        throw StateError(
          'Message history is full. New messages are refused; '
          'history is not evicted.',
        );
      }
      _database.execute(
        'INSERT INTO '
        'messages(peer_id, id, text, sent_at, outgoing, status, is_read) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          message.peerId,
          message.id,
          message.text,
          message.sentAt.millisecondsSinceEpoch,
          if (message.outgoing) 1 else 0,
          message.status.name,
          if (unread) 0 else 1,
        ],
      );
      _remember(message, unread: unread);
      notifyListeners();
    } on Object catch (error) {
      _report(error);
      rethrow;
    }
  }

  void _remember(ChatMessage message, {required bool unread}) {
    _entries[(message.peerId, message.id)] = message;
    (_history[message.peerId] ??= []).add(message);
    if (unread) (_unread[message.peerId] ??= {}).add(message.id);
  }

  void _setStatus(ChatMessage message, MessageStatus status) {
    _database.execute(
      'UPDATE messages SET status = ? WHERE peer_id = ? AND id = ?',
      <Object?>[status.name, message.peerId, message.id],
    );
    _replace(message._withStatus(status));
  }

  void _replace(ChatMessage message) {
    _entries[(message.peerId, message.id)] = message;
    final history = _history[message.peerId]!;
    history[history.indexWhere((item) => item.id == message.id)] = message;
    notifyListeners();
  }

  void _unconfirm(ChatMessage message) {
    try {
      _setStatus(message, MessageStatus.unconfirmed);
    } on Object catch (error) {
      // Never leave a misleading sending/delivered snapshot after interruption.
      // A surviving disk 'sending' row also becomes unconfirmed at next open.
      _replace(message._withStatus(MessageStatus.unconfirmed));
      _report(error);
    }
  }

  void _interrupt(_Attachment attachment) {
    attachment.epoch++;
    for (final entry in _pending.entries.toList()) {
      if (!identical(entry.value.attachment, attachment)) continue;
      _pending.remove(entry.key);
      entry.value.timer?.cancel();
      _unconfirm(_entries[entry.key]!);
    }
  }

  bool _current(_Attachment attachment, int epoch) =>
      !_closing &&
      identical(_attachments[attachment.session.peerId], attachment) &&
      attachment.epoch == epoch &&
      attachment.session.state == PeerSessionState.connected;

  _Attachment _requireSession(PeerSession session) {
    _ensureOpen();
    final attachment = _attachments[session.peerId];
    if (attachment == null ||
        !identical(attachment.session, session) ||
        session.state != PeerSessionState.connected) {
      throw StateError('Contact is not connected to this messenger.');
    }
    return attachment;
  }

  void _ensureOpen() {
    if (_closing) throw StateError('Messenger closed.');
  }

  Future<void> _track(Future<void> Function() operation) {
    final future = Future<void>.sync(operation);
    _active.add(future);
    unawaited(
      future.then<void>(
        (_) {
          _active.remove(future);
        },
        onError: (Object _, StackTrace _) {
          _active.remove(future);
        },
      ),
    );
    return future;
  }

  void _report(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await detachAll();
    await Future.wait([
      for (final future in _active.toList())
        future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
    _database.close();
    await _errors.close();
    super.dispose();
  }
}
