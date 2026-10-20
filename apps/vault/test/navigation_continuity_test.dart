import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _Delivery extends Fake implements VaultDelivery {
  @override
  bool get publishing => false;

  Completer<void>? requestGate;

  @override
  Future<void> requestAccess(PeerSession session) async {
    await requestGate?.future;
  }
}

// Presentation-only fixture. It creates no connection and claims no delivery.
class _Runtime extends ChangeNotifier implements VaultRuntime {
  new(this.contacts);

  @override
  List<ContactCard> contacts;
  @override
  PublicConfig config = const PublicConfig();
  @override
  final messenger = _History();
  @override
  final _Delivery delivery = _Delivery();
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

  Completer<void>? browseGate;

  @override
  Future<void> browse(PeerSession session) async {
    await browseGate?.future;
    remote[session.peerId] = [];
    notifyListeners();
  }

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

class _Session extends Fake implements PeerSession {
  new(this.peerId);

  @override
  final String peerId;
  @override
  PeerSessionState get state => PeerSessionState.connected;
  @override
  String? get failureReason => null;
}

void main() {
  testWidgets('utilities exclude hidden composer focus and preserve '
      'an editable draft on return', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final person = await ContactCard.create(
      await Identity.generate(),
      name: 'A known person',
    );
    final runtime = _Runtime([person]);
    await tester.pumpWidget(VaultApp(runtime: runtime));
    await tester.tap(find.text(person.name));
    await tester.pumpAndSettle();
    final composerKey = ValueKey('composer-${person.nodeId}');
    final composer = find.byKey(composerKey);
    await tester.enterText(composer, 'A draft kept on this device');
    final before = tester.widget<TextField>(composer);
    final controller = before.controller!
      ..selection = const TextSelection.collapsed(offset: 8);
    final saved = controller.value;
    final focus = before.focusNode!;
    expect(focus.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('open-activity')));
    await tester.pumpAndSettle();
    expect(composer, findsNothing);
    expect(focus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    expect(controller.value, saved);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final returned = tester.widget<TextField>(composer);
    expect(returned.controller!.value, saved);
    await tester.tap(composer);
    await tester.enterText(composer, '${saved.text} — still editable');
    expect(returned.controller!.text, '${saved.text} — still editable');
    expect(returned.focusNode!.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Escape from toolbar focus returns to the draft', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final person = await ContactCard.create(
      await Identity.generate(),
      name: 'A known person',
    );
    await tester.pumpWidget(VaultApp(runtime: _Runtime([person])));
    await tester.tap(find.text(person.name));
    await tester.pumpAndSettle();
    final composer = find.byKey(ValueKey('composer-${person.nodeId}'));
    await tester.enterText(composer, 'Keep this draft');
    await tester.tap(find.byKey(const ValueKey('open-activity')));
    await tester.pumpAndSettle();
    final backIcon = find.descendant(
      of: find.byTooltip('Back'),
      matching: find.byIcon(Icons.arrow_back),
    );
    Focus.of(tester.element(backIcon)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(composer, findsOneWidget);
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Keep this draft',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Escape and Back close wide library contact details', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1700, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final person = await ContactCard.create(
      await Identity.generate(),
      name: 'A known person',
    );
    await tester.pumpWidget(VaultApp(runtime: _Runtime([person])));
    await tester.tap(find.byKey(const ValueKey('destination-1')));
    await tester.pumpAndSettle();
    final details = find.byTooltip('Contact details and fingerprint');
    final fingerprint = find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == person.nodeId,
    );
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(fingerprint, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fingerprint, findsNothing);
    await tester.tap(details);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(fingerprint, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final awaitingApproval in [false, true]) {
    testWidgets(
      'late ${awaitingApproval ? 'approval' : 'index'} does not insert a '
      'library over a newly selected task',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1200, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final person = await ContactCard.create(
          await Identity.generate(),
          name: 'A known person',
        );
        final runtime = _Runtime([person]);
        final gate = Completer<void>();
        runtime.sessions[person.nodeId] = _Session(person.nodeId);
        if (awaitingApproval) {
          runtime.delivery.requestGate = gate;
        } else {
          runtime.browseGate = gate;
        }
        await tester.pumpWidget(VaultApp(runtime: runtime));
        await tester.tap(find.byKey(const ValueKey('destination-1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(
            awaitingApproval ? 'Request access' : 'Check earlier approval',
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('destination-0')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(person.name));
        await tester.pumpAndSettle();
        final composer = find.byKey(ValueKey('composer-${person.nodeId}'));
        await tester.enterText(composer, 'This task stays current');
        await tester.tap(find.byKey(const ValueKey('sidebar-activity')));
        await tester.pumpAndSettle();
        gate.complete();
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(composer, findsOneWidget);
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'This task stays current',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
