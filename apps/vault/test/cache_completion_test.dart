import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/production/messenger_service.dart';
import 'package:vault/production/public_config.dart';
import 'package:vault/production/vault_app.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_delivery/vault_delivery.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';

class _History extends Fake implements MessengerService {
  @override
  List<ChatMessage> messages(String peerId) => const [];

  @override
  int unreadCount(String peerId) => 0;
}

// Connected presentation state only: no native transport is exercised here.
class _Session extends Fake implements PeerSession {
  new(this.peerId);

  @override
  final String peerId;

  @override
  String get sessionId => 'presentation-$peerId';

  @override
  PeerSessionState get state => PeerSessionState.connected;
}

// Both approved owners resolve identical content to the same completed file.
// This isolates UI cache bookkeeping; it is not delivery verification.
class _Delivery extends Fake implements VaultDelivery {
  new(this.completed);

  final File completed;

  @override
  bool get publishing => false;

  @override
  Future<File> download(
    PeerSession session,
    RemoteMedia item, {
    DeliveryCancellation? cancellation,
    void Function(int received, int total)? onProgress,
  }) async => completed;
}

class _Runtime extends ChangeNotifier implements VaultRuntime {
  new(this.contacts, File completed, RemoteMedia item)
    : delivery = _Delivery(completed) {
    for (final card in contacts) {
      sessions[card.nodeId] = _Session(card.nodeId);
      // A loaded remote index represents the owner's existing approval.
      remote[card.nodeId] = [item];
    }
  }

  @override
  List<ContactCard> contacts;
  @override
  PublicConfig config = const PublicConfig();
  @override
  final messenger = _History();
  @override
  final _Delivery delivery;
  @override
  final sessions = <String, PeerSession>{};
  @override
  final remote = <String, List<RemoteMedia>>{};
  @override
  final requests = <AccessRequest>[];
  @override
  final approvedThisRun = <String>{};
  @override
  Null get manual => null;
  @override
  String? get transportError => null;
  @override
  String? get messengerError => null;

  @override
  Future<void> close() async => dispose();

  @override
  final Map<String, DateTime> unknownSenders = const {};
  @override
  final Set<String> blockedOffers = const {};
  @override
  ConnectionProblem? get signalingProblem => null;
  @override
  ConnectionProblem? problemFor(String peerId) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('deleting shared cache clears completions for both owners', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final contacts = <ContactCard>[];
    for (var seed = 1; seed <= 2; seed++) {
      final identity = await Identity.fromSeeds(
        Uint8List.fromList(List.filled(32, seed)),
        Uint8List.fromList(List.filled(32, seed + 2)),
      );
      final signed = await ContactCard.create(identity, name: 'Owner $seed');
      contacts.add(
        await ContactCard.fromBinding(signed.binding, name: signed.name),
      );
    }
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aDV8AAAAASUVORK5CYII=',
    );
    final item = RemoteMedia(
      id: 'bf179fcad966b9cc898db7a327956c2d6ed2b6bf9487b23b1e5cba6591db0077',
      name: 'Shared image.png',
      size: bytes.length,
      mimeType: 'image/png',
      generation: List.filled(64, 'b').join(),
      chunkCount: 1,
    );
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('vault-cache-completion-'),
    ))!;
    addTearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });
    final completed = File('${directory.path}/${item.id}.media');
    await tester.runAsync(() => completed.writeAsBytes(bytes, flush: true));
    final runtime = _Runtime(contacts, completed, item);
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(VaultApp(runtime: runtime));
    await tester.tap(find.byKey(const ValueKey('destination-1')));
    await tester.pumpAndSettle();

    for (final card in contacts) {
      final browse = find.text('Open library').at(contacts.indexOf(card));
      await tester.ensureVisible(browse);
      await tester.tap(browse);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open & download options'));
      await tester.pumpAndSettle();
      final download = find.text('Download to cache');
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const ValueKey('sidebar-activity')));
    await tester.pumpAndSettle();
    expect(find.text('Save copy…'), findsNWidgets(2));
    expect(find.text('Delete cache'), findsNWidgets(2));
    expect(find.text(item.name), findsNWidgets(2));
    expect(await tester.runAsync(completed.exists), isTrue);

    final delete = find.text('Delete cache').first;
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Delete cache'),
      ),
    );
    await tester.pumpAndSettle();
    // Wait for both native deletion and its UI completion, outside fake time.
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      if (find.text('Save copy…').evaluate().length < 2) break;
    }

    expect(await tester.runAsync(completed.exists), isFalse);
    expect(find.text('Save copy…'), findsNothing);
    expect(find.text('Delete cache'), findsNothing);
    expect(find.text(item.name), findsNothing);
  });
}
