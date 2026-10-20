import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/production/messenger_pane.dart';
import 'package:vault/production/messenger_service.dart';
import 'package:vault/production/public_config.dart';
import 'package:vault/production/vault_runtime.dart';
import 'package:vault_identity/vault_identity.dart';
import 'package:vault_net/vault_net.dart';

// UI-only fixtures: no transport, persistence or acknowledgement is simulated.
class _History extends Fake implements MessengerService {
  final entries = <String, List<ChatMessage>>{};

  @override
  List<ChatMessage> messages(String peerId) => entries[peerId] ?? const [];

  @override
  int unreadCount(String peerId) => 0;
}

class _Runtime extends Fake implements VaultRuntime {
  new(this.contacts);

  @override
  final List<ContactCard> contacts;

  @override
  final _History messenger = _History();

  @override
  final sessions = <String, PeerSession>{};

  @override
  Null get manual => null;

  @override
  String? get transportError => null;

  @override
  String? get messengerError => null;

  @override
  PublicConfig config = const PublicConfig();

  @override
  final Map<String, DateTime> unknownSenders = {};

  @override
  ConnectionProblem? get signalingProblem => null;

  @override
  ConnectionProblem? problemFor(String peerId) => null;
}

ChatMessage _message(String peerId, int index) => ChatMessage(
  id: 'message-$index',
  peerId: peerId,
  text:
      'History entry $index. A message with enough content to wrap naturally.',
  sentAt: DateTime.utc(2026, 1, 1, 12, index),
  outgoing: false,
  status: MessageStatus.received,
);

void main() {
  late ContactCard alice;
  late ContactCard bob;
  late _Runtime runtime;

  setUp(() async {
    alice = await ContactCard.create(await Identity.generate(), name: 'Alice');
    bob = await ContactCard.create(await Identity.generate(), name: 'Bob');
    runtime = _Runtime([alice, bob]);
  });

  testWidgets(
    'draft and editing selection survive destination and adaptive changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      late StateSetter rebuild;
      var active = true;
      String? selected = alice.nodeId;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Scaffold(
                body: Offstage(
                  offstage: !active,
                  child: MessengerPane(
                    runtime: runtime,
                    active: active,
                    selectedPeerId: selected,
                    onSelectPeer: (value) => setState(() => selected = value),
                    onAddPerson: () async {},
                    onShareContact: () async {},
                    onConnectionSetup: () {},
                    onContactDetails: (_) {},
                    onPair: (_) {},
                    onConnectOverInternet: () {},
                    onShowPairingCode: () {},
                    onScanPairingCode: () {},
                  ),
                ),
              );
            },
          ),
        ),
      );
      final composer = find.byKey(ValueKey('composer-${alice.nodeId}'));
      await tester.enterText(composer, 'A local draft\nwith a second line');
      final field = tester.widget<TextField>(composer);
      field.controller!.selection = const TextSelection.collapsed(offset: 7);
      rebuild(() => active = false);
      await tester.pump();
      rebuild(() => active = true);
      await tester.pump();
      tester.view.physicalSize = const Size(430, 900);
      await tester.pump();
      final compact = tester.widget<TextField>(composer);
      expect(compact.controller!.text, 'A local draft\nwith a second line');
      expect(compact.controller!.selection.baseOffset, 7);
      expect(compact.focusNode!.hasFocus, isTrue);
      rebuild(() => selected = bob.nodeId);
      await tester.pump();
      await tester.enterText(
        find.byKey(ValueKey('composer-${bob.nodeId}')),
        'A different draft',
      );
      rebuild(() => selected = alice.nodeId);
      await tester.pump();
      final returned = tester.widget<TextField>(composer).controller!;
      expect(returned.text, 'A local draft\nwith a second line');
      expect(returned.selection.baseOffset, 7);
    },
  );

  testWidgets(
    'incoming messages preserve earlier history until a deliberate jump',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final entries = List.generate(70, (i) => _message(alice.nodeId, i));
      runtime.messenger.entries[alice.nodeId] = entries;
      late StateSetter rebuild;
      var selected = alice.nodeId;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Scaffold(
                body: MessengerPane(
                  runtime: runtime,
                  active: true,
                  selectedPeerId: selected,
                  onSelectPeer: (_) {},
                  onAddPerson: () async {},
                  onShareContact: () async {},
                  onConnectionSetup: () {},
                  onContactDetails: (_) {},
                  onPair: (_) {},
                  onConnectOverInternet: () {},
                  onShowPairingCode: () {},
                  onScanPairingCode: () {},
                ),
              );
            },
          ),
        ),
      );
      final timeline = find.byKey(PageStorageKey('timeline-${alice.nodeId}'));
      final controller = tester.widget<CustomScrollView>(timeline).controller!
        ..jumpTo(700);
      await tester.pumpAndSettle();
      final visible =
          find
                  .byType(SelectableText)
                  .evaluate()
                  .where((element) {
                    final top = tester
                        .getTopLeft(find.byWidget(element.widget))
                        .dy;
                    return top > tester.getTopLeft(timeline).dy + 20 &&
                        top < tester.getBottomLeft(timeline).dy - 80;
                  })
                  .first
                  .widget
              as SelectableText;
      final anchor = find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == visible.data,
      );
      final before = tester.getTopLeft(anchor);
      final offset = controller.offset;
      rebuild(() => entries.add(_message(alice.nodeId, 70)));
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(offset, .1));
      expect(tester.getTopLeft(anchor).dy, closeTo(before.dy, .1));
      expect(controller.position.minScrollExtent, lessThan(0));
      final jump = find.widgetWithIcon(TextButton, Icons.arrow_downward);
      expect(jump, findsOneWidget);
      tester.view.physicalSize = const Size(430, 900);
      await tester.pumpAndSettle();
      expect(
        tester.widget<CustomScrollView>(timeline).controller!.offset,
        closeTo(offset, .1),
      );
      rebuild(() => selected = bob.nodeId);
      await tester.pump();
      rebuild(() => selected = alice.nodeId);
      await tester.pumpAndSettle();
      final resumed = tester.widget<CustomScrollView>(timeline).controller!;
      expect(resumed.offset, closeTo(offset, .1));
      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(resumed.offset, closeTo(resumed.position.minScrollExtent, .1));
    },
  );

  testWidgets('first run offers the internet preset until it is chosen', (
    tester,
  ) async {
    final empty = _Runtime([]);
    var chosen = 0;
    Widget pane() => MaterialApp(
      home: Scaffold(
        body: MessengerPane(
          runtime: empty,
          active: true,
          selectedPeerId: null,
          onSelectPeer: (_) {},
          onAddPerson: () async {},
          onShareContact: () async {},
          onConnectionSetup: () {},
          onContactDetails: (_) {},
          onPair: (_) {},
          onConnectOverInternet: () => chosen++,
          onShowPairingCode: () {},
          onScanPairingCode: () {},
        ),
      ),
    );
    await tester.pumpWidget(pane());
    final preset = find.byKey(const ValueKey('first-run-internet'));
    expect(preset, findsOneWidget);
    await tester.tap(preset);
    expect(chosen, 1);

    empty.config = empty.config.withInternetPreset();
    await tester.pumpWidget(pane());
    expect(preset, findsNothing);
  });
}
