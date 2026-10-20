import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault/platform/instance_lock.dart';
import 'package:vault/platform/library_sources.dart';
import 'package:vault/platform/media_metadata.dart';
import 'package:vault/platform/publishing_availability.dart';
import 'package:vault/production/connection_problem.dart';
import 'package:vault/production/messenger_service.dart';
import 'package:vault/production/pairing_join.dart';
import 'package:vault/production/public_config.dart';
import 'package:vault_delivery/vault_delivery.dart';
import 'package:vault_directory/vault_directory.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_media_index/vault_media_index.dart';
import 'package:vault_net/vault_net.dart';
import 'package:vault_protocol/vault_protocol.dart'
    show ActivePairing, AuthorizationRepository, Introduction, PairingInvite;
import 'package:vault_signaling/vault_signaling.dart';

/// Owns real services. No automatic connection/publication on startup.
class VaultRuntime extends ChangeNotifier implements PairingJoinPort {
  new _(
    this.identity,
    this.contactRepository,
    this.authorization,
    this.library,
    this.delivery,
    this.messenger,
    this.preferences,
    this.config,
    this.contacts,
    this._instanceLock,
    this.availability,
    this.availabilityState,
  ) {
    messenger.addListener(_messengerChanged);
    _subscriptions.add(
      messenger.errors.listen((error) {
        messengerError = 'Messenger: $error';
        notifyListeners();
      }),
    );
    availability.onStopped = (reason) async {
      _publicationEpoch++;
      await delivery.setPublishing(false);
      availabilityNotice = 'Native availability stopped: $reason';
      notifyListeners();
    };
    _subscriptions.add(
      availability.stops.listen((_) {
        unawaited(_refreshAvailabilityAfterStop());
      }),
    );
    _subscriptions.add(
      delivery.errors.listen((error) {
        mediaError = 'Media service: $error';
        notifyListeners();
      }),
    );
    _subscriptions.add(
      delivery.accessRequestChanges.listen((pending) {
        requests
          ..clear()
          ..addAll(pending);
        notifyListeners();
      }),
    );
  }

  static const configKey = 'vault.public.v1';
  final Identity identity;
  final ContactRepository contactRepository;
  final AuthorizationRepository authorization;
  final VaultLibrary library;
  final VaultDelivery delivery;
  final MessengerService messenger;
  final SharedPreferencesAsync preferences;
  final VaultInstanceLock _instanceLock;
  final PublishingAvailability availability;
  PublishingAvailabilityStatus availabilityState;
  String? availabilityNotice;
  int _publicationEpoch = 0;
  PublicConfig config;
  List<ContactCard> contacts;
  final List<AccessRequest> requests = [];
  final Map<String, PeerSession> sessions = {};
  final Map<String, List<RemoteMedia>> remote = {};
  final Set<String> approvedThisRun = {};
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final List<StreamSubscription<Object?>> _transportSubscriptions = [];
  final _sessionStarts = StreamController<PeerSession>.broadcast(sync: true);
  Future<void>? _starting;
  Future<void> _configWrites = Future<void>.value();
  PeerMesh? mesh;
  SignalingStrategy? strategy;
  PublicContactDirectory? publicDirectory;
  bool get discovering => publicDirectory?.discovering ?? false;
  bool get publiclyListed => publicDirectory?.publishing ?? false;
  bool transportConnected = false;
  String? transportError;
  String? mediaError;
  String? messengerError;
  bool _stopping = false;

  final _ignored = IgnoredAttempts();

  /// Noncontacts whose signed signaling was ignored, oldest first.
  Map<String, DateTime> get unknownSenders => _ignored.unknownSenders;

  /// Contacts whose new connection was ignored because you disconnected them.
  Set<String> get blockedOffers => _ignored.blockedOffers;

  /// Set while the connection-setup transport is unreachable.
  ConnectionProblem? signalingProblem;
  Timer? _problemNotice;

  /// The one pairing secret this host is showing; memory only, single-use.
  ActivePairing? _pairing;

  /// A verified introduction waiting for the person to confirm it.
  ContactCard? pairingRequest;

  static int get _unixNow => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Starts signaling and returns a fresh single-use invite for this device.
  /// Any earlier code stops working.
  Future<PairingInvite> startPairing() async {
    if (config.transport != 'mqtt') {
      throw StateError('Pairing needs connection setup over the internet.');
    }
    await start();
    final pairing = ActivePairing.start(now: _unixNow);
    _pairing = pairing;
    pairingRequest = null;
    notifyListeners();
    return pairing.invite(
      await ContactCard.create(identity, name: config.name),
      brokerHost: config.brokerHost,
      brokerPort: config.brokerPort,
    );
  }

  /// Forgets the pairing secret and any unconfirmed introduction.
  void endPairing() {
    if (_pairing == null && pairingRequest == null) return;
    _pairing = null;
    pairingRequest = null;
    notifyListeners();
  }

  /// Adds the introduced device as a contact and dials it, because the
  /// scanner waits for this device's offer. Grants no library access.
  Future<void> approvePairing() async {
    final card = pairingRequest;
    if (card == null) return;
    await addContact(card);
    endPairing();
    try {
      await connect(card);
    } on Object catch (error) {
      // The contact stays added; its chat shows why it is not connecting.
      transportError = '$error';
      notifyListeners();
    }
  }

  Future<bool> _introduced(Introduction introduction) async {
    final pairing = _pairing;
    if (pairing == null ||
        pairingRequest != null ||
        introduction.card.nodeId == nodeId) {
      return false;
    }
    final redeemed = await pairing.redeem(
      introduction,
      recipientNodeId: identity.nodeId,
      now: _unixNow,
    );
    if (!redeemed || !identical(_pairing, pairing)) return false;
    pairingRequest = introduction.card;
    _ignored.dismissUnknown(introduction.card.nodeId);
    notifyListeners();
    return true;
  }

  @override
  bool needsBrokerSwitch(PairingInvite invite) =>
      config.transport != 'mqtt' ||
      config.brokerHost != invite.brokerHost ||
      config.brokerPort != invite.brokerPort;

  @override
  Future<void> useBroker(String host, int port) => saveConfig(
    config.copyWith(transport: 'mqtt', brokerHost: host, brokerPort: port),
  );

  @override
  Future<void> introduce(PairingInvite invite) async {
    await start();
    final introduction = await Introduction.create(
      card: await ContactCard.create(identity, name: config.name),
      invite: invite,
    );
    try {
      await mesh!.signaling.introduce(
        host: invite.card.binding,
        introduction: introduction,
      );
    } on TimeoutException {
      throw const ConnectionProblemException(
        ConnectionProblem.signalingUnavailable,
      );
    }
  }

  /// The one problem to show for [peerId], most specific first.
  ConnectionProblem? problemFor(String peerId) {
    final session = sessions[peerId];
    final state = session?.state;
    if (state == PeerSessionState.failed && session!.problem != null) {
      return session.problem;
    }
    if (_ignored.blockedOffers.contains(peerId)) {
      return ConnectionProblem.youDisconnected;
    }
    if (state == null ||
        state == PeerSessionState.failed ||
        state == PeerSessionState.closed) {
      return signalingProblem;
    }
    return null;
  }

  void dismissUnknownSender(String peerId) {
    if (_ignored.dismissUnknown(peerId)) notifyListeners();
  }

  void dismissBlockedOffer(String peerId) {
    if (_ignored.dismissBlocked(peerId)) notifyListeners();
  }

  void _recordProblem(PeerProblem problem) {
    if (problem.problem == ConnectionProblem.notAContact &&
        (problem.peerId == pairingRequest?.nodeId ||
            contacts.any((contact) => contact.nodeId == problem.peerId))) {
      return;
    }
    if (!_ignored.record(problem, now: DateTime.now())) return;
    // Coalesce bursts from many identities into one rebuild per second.
    _problemNotice ??= Timer(const Duration(seconds: 1), () {
      _problemNotice = null;
      notifyListeners();
    });
  }

  static Future<VaultRuntime> load({
    required SecretStore store,
    SharedPreferencesAsync? preferences,
    Directory? root,
  }) async {
    final base = root ?? await getApplicationSupportDirectory();
    final instanceLock = await VaultInstanceLock.acquire(base);
    AuthorizationRepository? loadedAuthorization;
    VaultLibrary? loadedLibrary;
    VaultDelivery? loadedDelivery;
    PublishingAvailability? loadedAvailability;
    MessengerService? loadedMessenger;
    try {
      // Lock precedes protected state: only one process may mint or mutate it.
      final identity = await IdentityRepository(store).loadOrCreate();
      final contacts = ContactRepository(store);
      final cards = await contacts.list();
      final authorization = AuthorizationRepository(store, identity);
      loadedAuthorization = authorization;
      await authorization.load();
      final prefs = preferences ?? SharedPreferencesAsync();
      final saved = await prefs.getString(configKey);
      final config = saved == null
          ? const PublicConfig()
          : PublicConfig.decode(saved);
      final messenger = MessengerService(
        databasePath:
            '${base.path}/messages-${nodeIdText(identity.nodeId)}.sqlite3',
      );
      loadedMessenger = messenger;
      final library = VaultLibrary(
        Directory('${base.path}/library'),
        sourceAccess: Platform.isAndroid ? AndroidSourceAccess() : null,
        metadataExtractor: NativeMediaMetadata.extract,
      );
      loadedLibrary = library;
      await library.load();
      final availability = PublishingAvailability();
      loadedAvailability = availability;
      final availabilityState = await availability.status();
      final delivery = VaultDelivery(
        library: library,
        authorization: authorization,
        cacheDirectory: Directory('${base.path}/delivery-cache'),
      );
      loadedDelivery = delivery;
      await delivery.load();
      return VaultRuntime._(
        identity,
        contacts,
        authorization,
        library,
        delivery,
        messenger,
        prefs,
        config,
        cards,
        instanceLock,
        availability,
        availabilityState,
      );
    } on Object {
      try {
        await loadedAvailability?.dispose();
      } finally {
        try {
          try {
            try {
              await loadedDelivery?.close();
            } finally {
              await loadedMessenger?.close();
            }
          } finally {
            await loadedLibrary?.close();
          }
        } finally {
          try {
            await loadedAuthorization?.close();
          } finally {
            await instanceLock.close();
          }
        }
      }
      rethrow;
    }
  }

  late final String nodeId = nodeIdText(identity.nodeId);
  ManualSignaling? get manual =>
      strategy is ManualSignaling ? strategy! as ManualSignaling : null;
  bool get running => mesh != null;

  void _messengerChanged() => notifyListeners();

  Future<void> saveConfig(PublicConfig value) => _writeConfig(
    (current) => value.copyWith(
      disconnectedPeerIds: {
        ...current.disconnectedPeerIds,
        ...value.disconnectedPeerIds,
      },
    ),
  );

  Future<void> _writeConfig(PublicConfig Function(PublicConfig) update) {
    final next = _configWrites.then((_) async {
      final value = PublicConfig.decode(update(config).encode());
      if (running &&
          (value.transport != config.transport ||
              value.brokerHost != config.brokerHost ||
              value.brokerPort != config.brokerPort)) {
        throw StateError(
          'Disconnect signaling before changing its configuration.',
        );
      }
      await preferences.setString(configKey, value.encode());
      if (value.transport != config.transport ||
          value.brokerHost != config.brokerHost ||
          value.brokerPort != config.brokerPort) {
        signalingProblem = null;
      }
      config = value;
      notifyListeners();
    });
    _configWrites = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> _rememberDisconnect(String peerId, bool disconnected) =>
      _writeConfig((current) {
        final ids = {...current.disconnectedPeerIds};
        if (disconnected) {
          ids.add(peerId);
        } else {
          ids.remove(peerId);
        }
        return current.copyWith(disconnectedPeerIds: ids);
      });

  @override
  Future<void> addContact(ContactCard card) async {
    if (card.nodeId == nodeId) throw StateError('This is your own identity.');
    await contactRepository.add(card);
    contacts = await contactRepository.list();
    _ignored.dismissUnknown(card.nodeId);
    notifyListeners();
  }

  Future<void> removeContact(ContactCard card) async {
    await delivery.revoke(card.nodeId);
    await _rememberDisconnect(card.nodeId, true);
    await sessions[card.nodeId]?.close();
    await contactRepository.remove(card.nodeId);
    contacts = await contactRepository.list();
    sessions.remove(card.nodeId);
    remote.remove(card.nodeId);
    approvedThisRun.remove(card.nodeId);
    notifyListeners();
  }

  Future<KeyBinding?> _binding(String id) async {
    for (final card in contacts) {
      if (card.nodeId == id) return card.binding;
    }
    return null;
  }

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (_stopping) {
      throw StateError(
        'Signaling is stopping; retry after disconnect completes.',
      );
    }
    if (running) return;
    transportError = null;
    signalingProblem = null;
    final next = config.transport == 'manual'
        ? ManualSignaling()
        : MqttSignaling([
            MqttEndpoint(config.brokerHost, port: config.brokerPort),
          ]);
    strategy = next;
    final client = SignalingClient(
      identity: identity,
      strategy: next,
      resolveBinding: _binding,
      onIntroduce: _introduced,
    );
    final directory = PublicContactDirectory(
      signaling: client,
      databasePath: '${library.root.parent.path}/public-presence.sqlite3',
    );
    publicDirectory = directory;
    _transportSubscriptions.add(
      directory.changes.listen((_) => notifyListeners()),
    );
    _transportSubscriptions.add(
      directory.errors.listen((error) {
        transportError = 'Public discovery: $error';
        notifyListeners();
      }),
    );
    final mesh = PeerMesh(
      identity: identity,
      signaling: client,
      resolveBinding: _binding,
      initiallyDisconnectedPeerIds: config.disconnectedPeerIds,
    );
    this.mesh = mesh;
    _transportSubscriptions.add(
      next.connectionChanges.listen((connected) {
        transportConnected = connected;
        if (connected) signalingProblem = null;
        notifyListeners();
      }),
    );
    _transportSubscriptions.add(
      client.failures.listen((failure) {
        switch (failure.kind) {
          case SignalingFailureKind.unknownSender:
            // Shown as a typed notice through mesh problems.
            return;
          case SignalingFailureKind.transportUnavailable:
            signalingProblem = ConnectionProblem.signalingUnavailable;
          case SignalingFailureKind.acknowledgmentTimeout ||
              SignalingFailureKind.other:
            break;
        }
        transportError = failure.message;
        notifyListeners();
      }),
    );
    _transportSubscriptions.add(mesh.problems.listen(_recordProblem));
    if (next is ManualSignaling) {
      _transportSubscriptions.add(
        next.exports.listen((_) => notifyListeners()),
      );
    }
    _transportSubscriptions.add(mesh.sessions.listen(_attach));
    var startingTransport = false;
    try {
      await directory.load();
      startingTransport = true;
      await mesh.start();
      transportConnected = next.connected;
      notifyListeners();
    } on Object {
      await stop();
      if (startingTransport && next is! ManualSignaling) {
        signalingProblem = ConnectionProblem.signalingUnavailable;
        notifyListeners();
        throw const ConnectionProblemException(
          ConnectionProblem.signalingUnavailable,
        );
      }
      rethrow;
    }
  }

  void _attach(PeerSession session) {
    if (identical(sessions[session.peerId], session)) return;
    if (!contacts.any((contact) => contact.nodeId == session.peerId)) {
      unawaited(session.close());
      return;
    }
    sessions[session.peerId] = session;
    remote.remove(session.peerId);
    messenger.attach(session);
    delivery.attach(session, onMessengerControl: messenger.receiveControl);
    _sessionStarts.add(session);
    _transportSubscriptions.add(
      session.states.listen((state) {
        if (!identical(sessions[session.peerId], session)) return;
        if (state == PeerSessionState.closed ||
            state == PeerSessionState.failed) {
          remote.remove(session.peerId);
        }
        notifyListeners();
      }),
    );
    notifyListeners();
  }

  @override
  Stream<PeerSession> get sessionStarts => _sessionStarts.stream;

  @override
  PeerSession? liveSession(String peerId) => switch (sessions[peerId]) {
    final session?
        when session.state != PeerSessionState.closed &&
            session.state != PeerSessionState.failed =>
      session,
    _ => null,
  };

  /// Clears your earlier disconnect of [card] so its offers are accepted
  /// again, without dialing it.
  @override
  Future<void> allowConnections(ContactCard card) async {
    _ignored.dismissBlocked(card.nodeId);
    await _rememberDisconnect(card.nodeId, false);
    mesh?.allow(card.nodeId);
    notifyListeners();
  }

  Future<PeerSession> connect(ContactCard card) async {
    await allowConnections(card);
    await start();
    final session = await mesh!.connect(card);
    _attach(session);
    return session;
  }

  Future<void> disconnect(PeerSession session) async {
    await _rememberDisconnect(session.peerId, true);
    await messenger.detach(session);
    await session.close();
    remote.remove(session.peerId);
    notifyListeners();
  }

  Future<void> setPublishing({required bool enabled}) async {
    final epoch = ++_publicationEpoch;
    if (enabled) {
      final state = await availability.start();
      availabilityState = state;
      if (epoch != _publicationEpoch || !state.publishing) {
        await availability.stop();
        throw StateError(
          'OS publishing availability ended before publication could start.',
        );
      }
      try {
        await delivery.setPublishing(true);
        if (epoch != _publicationEpoch) {
          await delivery.setPublishing(false);
          throw StateError('Publication was stopped by the OS.');
        }
        availabilityNotice = null;
      } on Object {
        await availability.stop();
        rethrow;
      }
    } else {
      try {
        await delivery.setPublishing(false);
      } finally {
        availabilityState = await availability.stop();
      }
    }
    notifyListeners();
  }

  Future<void> _refreshAvailabilityAfterStop() async {
    try {
      await refreshAvailability();
    } on Object {
      availabilityNotice = 'Native availability status could not be refreshed.';
      notifyListeners();
    }
  }

  Future<void> refreshAvailability() async {
    availabilityState = await availability.status();
    notifyListeners();
  }

  Future<void> setAutostart({required bool enabled}) async {
    availabilityState = await availability.setAutostart(enabled: enabled);
    notifyListeners();
  }

  Future<void> minimizeToTray() async {
    availabilityState = await availability.minimizeToTray();
    notifyListeners();
  }

  Future<void> approve(AccessRequest request) async {
    await delivery.approve(request);
    approvedThisRun.add(request.peerId);
    notifyListeners();
  }

  Future<void> deny(AccessRequest request) => delivery.deny(request);

  Future<void> revoke(String peerId) async {
    await delivery.revoke(peerId);
    approvedThisRun.remove(peerId);
    notifyListeners();
  }

  Future<void> browse(PeerSession session) async {
    final items = await delivery.browse(session);
    remote[session.peerId] = items;
    notifyListeners();
  }

  Future<void> setDiscovering({required bool enabled}) async {
    await start();
    await publicDirectory!.setDiscovering(enabled);
    notifyListeners();
  }

  Future<void> setPubliclyListed({required bool enabled}) async {
    await start();
    await publicDirectory!.setPublishing(
      enabled,
      name: config.name,
      sharedCount: library.items.length,
    );
    notifyListeners();
  }

  Future<void> stop({bool rememberDisconnect = false}) async {
    if (_stopping) return;
    _stopping = true;
    try {
      await messenger.detachAll();
      try {
        if (rememberDisconnect) {
          await _writeConfig(
            (current) => current.copyWith(
              disconnectedPeerIds: {
                ...current.disconnectedPeerIds,
                ...sessions.keys,
              },
            ),
          );
        }
      } finally {
        try {
          await setPublishing(enabled: false);
        } finally {
          try {
            await publicDirectory?.close();
          } finally {
            await mesh?.close();
          }
        }
      }
    } finally {
      for (final subscription in _transportSubscriptions) {
        await subscription.cancel();
      }
      _transportSubscriptions.clear();
      mesh = null;
      strategy = null;
      publicDirectory = null;
      _pairing = null;
      pairingRequest = null;
      transportConnected = false;
      remote.clear();
      _stopping = false;
      notifyListeners();
    }
  }

  Future<void> close() async {
    _problemNotice?.cancel();
    try {
      try {
        await stop();
      } finally {
        try {
          await delivery.close();
        } finally {
          try {
            messenger.removeListener(_messengerChanged);
            await messenger.close();
          } finally {
            await library.close();
          }
        }
      }
    } finally {
      try {
        for (final subscription in _subscriptions) {
          await subscription.cancel();
        }
        try {
          await authorization.close();
        } finally {
          await availability.dispose();
        }
      } finally {
        await _instanceLock.close();
        await _sessionStarts.close();
        super.dispose();
      }
    }
  }
}
