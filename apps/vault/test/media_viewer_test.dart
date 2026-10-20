import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/features/player/media_viewer.dart';
import 'package:vault_net/vault_net.dart';

class _Session extends Fake implements PeerSession {
  final changes = StreamController<PeerSessionState>.broadcast(sync: true);
  PeerSessionState current = PeerSessionState.connected;

  @override
  PeerSessionState get state => current;

  @override
  Stream<PeerSessionState> get states => changes.stream;

  void changeState(PeerSessionState state) {
    current = state;
    changes.add(state);
  }

  void disconnect() => changeState(PeerSessionState.closed);
}

ViewerItem _pending(String name, Future<ViewerSource> Function() open) =>
    ViewerItem(name: name, mimeType: 'image/png', open: open);

Widget _app(List<ViewerItem> items, {PeerSession? session, int index = 0}) =>
    MaterialApp(
      home: MediaViewer(
        items: items,
        initialIndex: index,
        sourceLabel: 'Test library',
        session: session,
      ),
    );

void main() {
  testWidgets(
    'recovery reopens a decoded photo and terminal failure releases it',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'vault-viewer-recovery-',
        );
        final file = File('${directory.path}/photo.png');
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.green, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(2, 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await file.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
        final session = _Session();
        final released = Completer<void>();
        final releaseStarted = Completer<void>();
        final reopened = Completer<void>();
        final terminalRelease = Completer<void>();
        var opens = 0;
        var releases = 0;
        try {
          await tester.pumpWidget(
            _app([
              _pending('Selected photo', () async {
                opens++;
                if (opens == 2) reopened.complete();
                return ViewerSource(
                  uri: file.uri,
                  release: () async {
                    releases++;
                    if (releases == 1) {
                      releaseStarted.complete();
                      await released.future;
                    } else {
                      terminalRelease.complete();
                    }
                  },
                );
              }),
            ], session: session),
          );
          Future<void> finishDecoding() async {
            final watch = Stopwatch()..start();
            while (find.byType(InteractiveViewer).evaluate().isEmpty) {
              await tester.pump();
              if (find.text('Unable to open media').evaluate().isNotEmpty ||
                  watch.elapsed > const Duration(seconds: 5)) {
                fail('The selected photo did not finish decoding.');
              }
              // File IO and engine decoding use real events, not fake time.
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
          }

          await finishDecoding();
          expect(find.byType(InteractiveViewer), findsOneWidget);
          expect(opens, 1);
          session.changeState(PeerSessionState.negotiating);
          await tester.pump();
          await releaseStarted.future;
          expect(releases, 1);
          expect(find.byType(InteractiveViewer), findsNothing);
          expect(find.text('Reconnecting to the library'), findsOneWidget);
          session.changeState(PeerSessionState.authenticating);
          await tester.pump();
          expect(opens, 1);
          session.changeState(PeerSessionState.connected);
          await tester.pump();
          expect(opens, 1);
          released.complete();
          await reopened.future;
          await finishDecoding();
          expect(opens, 2);
          expect(find.byType(InteractiveViewer), findsOneWidget);
          expect(find.text('Unable to open media'), findsNothing);
          session.changeState(PeerSessionState.failed);
          await tester.pump();
          await terminalRelease.future;
          expect(releases, 2);
          expect(find.byType(InteractiveViewer), findsNothing);
          expect(find.text('This connection has ended'), findsOneWidget);
          session.changeState(PeerSessionState.connected);
          await tester.pump();
          expect(opens, 2);
          expect(tester.takeException(), isNull);
        } finally {
          if (!released.isCompleted) released.complete();
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          await session.changes.close();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets(
    'opens only selected items and releases late sources exactly once',
    (tester) async {
      final first = Completer<ViewerSource>();
      final second = Completer<ViewerSource>();
      var firstOpens = 0;
      var secondOpens = 0;
      var firstReleases = 0;
      var secondReleases = 0;
      await tester.pumpWidget(
        _app([
          _pending('First photo', () {
            firstOpens++;
            return first.future;
          }),
          _pending('Second photo', () {
            secondOpens++;
            return second.future;
          }),
        ]),
      );
      await tester.pump();
      expect(firstOpens, 1);
      expect(secondOpens, 0);
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(secondOpens, 1);
      expect(find.text('2 of 2'), findsOneWidget);
      first.complete(
        ViewerSource(
          uri: Uri.file('/unused-late-source.png'),
          release: () async {
            firstReleases++;
          },
        ),
      );
      await tester.pump();
      expect(firstReleases, 1);
      await tester.pumpWidget(const SizedBox());
      second.complete(
        ViewerSource(
          uri: Uri.file('/unused-disposed-source.png'),
          release: () async {
            secondReleases++;
          },
        ),
      );
      await tester.pump();
      expect(firstReleases, 1);
      expect(secondReleases, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'session closure denies navigation and releases an in-flight source',
    (tester) async {
      final session = _Session();
      final pending = Completer<ViewerSource>();
      var opens = 0;
      var releases = 0;
      await tester.pumpWidget(
        _app([
          _pending('First photo', () {
            opens++;
            return pending.future;
          }),
          _pending('Second photo', () {
            opens++;
            return Completer<ViewerSource>().future;
          }),
        ], session: session),
      );
      await tester.pump();
      session.disconnect();
      await tester.pump();
      expect(find.text('This connection has ended'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(opens, 1);
      pending.complete(
        ViewerSource(
          uri: Uri.file('/unused-closed-source.png'),
          release: () async {
            releases++;
          },
        ),
      );
      await tester.pump();
      expect(releases, 1);
      expect(find.text('1 of 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await session.changes.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transient recovery retains selection and reopens only after connected',
    (tester) async {
      final session = _Session();
      final first = Completer<ViewerSource>();
      final restored = Completer<ViewerSource>();
      var selectedOpens = 0;
      var adjacentOpens = 0;
      var lateReleases = 0;
      await tester.pumpWidget(
        _app(
          [
            _pending('Previous photo', () async {
              adjacentOpens++;
              throw StateError('Must not prefetch');
            }),
            _pending('Selected photo', () {
              selectedOpens++;
              return selectedOpens == 1 ? first.future : restored.future;
            }),
            _pending('Next photo', () async {
              adjacentOpens++;
              throw StateError('Must not prefetch');
            }),
          ],
          session: session,
          index: 1,
        ),
      );
      await tester.pump();
      session.changeState(PeerSessionState.negotiating);
      await tester.pump();
      expect(find.text('Reconnecting to the library'), findsOneWidget);
      expect(find.text('This connection has ended'), findsNothing);
      await tester.tap(find.text('Next'));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      session.changeState(PeerSessionState.authenticating);
      await tester.pump();
      expect(selectedOpens, 1);
      expect(adjacentOpens, 0);
      expect(find.text('2 of 3'), findsOneWidget);
      session
        ..changeState(PeerSessionState.connected)
        ..changeState(PeerSessionState.connected);
      await tester.pump();
      expect(selectedOpens, 2);
      expect(find.text('Selected photo'), findsOneWidget);
      expect(find.text('Reconnecting to the library'), findsNothing);
      expect(find.text('This connection has ended'), findsNothing);
      first.complete(
        ViewerSource(
          uri: Uri.file('/old-recovery-source.png'),
          release: () async {
            lateReleases++;
          },
        ),
      );
      await tester.pump();
      expect(lateReleases, 1);
      expect(selectedOpens, 2);
      await tester.pumpWidget(const SizedBox());
      restored.complete(
        ViewerSource(uri: Uri.file('/new-recovery-source.png')),
      );
      await tester.pump();
      await session.changes.close();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recovery joins cancelled transfer teardown across repeated route flaps',
    (tester) async {
      final session = _Session();
      final first = Completer<ViewerSource>();
      final cancelled = Completer<void>();
      final restored = Completer<ViewerSource>();
      var opens = 0;
      var cancellations = 0;
      await tester.pumpWidget(
        _app([
          ViewerItem(
            name: 'Selected photo',
            mimeType: 'image/png',
            open: () {
              opens++;
              return opens == 1 ? first.future : restored.future;
            },
            cancelOpen: () async {
              cancellations++;
              if (cancellations == 1) await cancelled.future;
            },
          ),
        ], session: session),
      );
      await tester.pump();
      session
        ..changeState(PeerSessionState.negotiating)
        ..changeState(PeerSessionState.connected);
      await tester.pump();
      expect(cancellations, 1);
      expect(opens, 1);
      session
        ..changeState(PeerSessionState.negotiating)
        ..changeState(PeerSessionState.authenticating)
        ..changeState(PeerSessionState.connected);
      await tester.pump();
      expect(opens, 1);
      first.completeError(StateError('Cancelled old download'));
      cancelled.complete();
      await tester.pump();
      expect(opens, 2);
      expect(cancellations, 1);
      expect(find.text('Unable to open media'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      restored.complete(ViewerSource(uri: Uri.file('/restored-photo.png')));
      await tester.pump();
      await session.changes.close();
      expect(tester.takeException(), isNull);
    },
  );

  for (final terminal in [PeerSessionState.closed, PeerSessionState.failed]) {
    testWidgets('$terminal during recovery permanently stops this viewer', (
      tester,
    ) async {
      final session = _Session();
      final source = Completer<ViewerSource>();
      var opens = 0;
      var releases = 0;
      await tester.pumpWidget(
        _app([
          _pending('Selected photo', () {
            opens++;
            return source.future;
          }),
        ], session: session),
      );
      await tester.pump();
      session
        ..changeState(PeerSessionState.negotiating)
        ..changeState(terminal)
        ..changeState(PeerSessionState.connected);
      await tester.pump();
      expect(find.text('This connection has ended'), findsOneWidget);
      expect(opens, 1);
      source.complete(
        ViewerSource(
          uri: Uri.file('/terminal-recovery-source.png'),
          release: () async {
            releases++;
          },
        ),
      );
      await tester.pump();
      expect(releases, 1);
      expect(opens, 1);
      await tester.pumpWidget(const SizedBox());
      await session.changes.close();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('initial authentication waits instead of ending the viewer', (
    tester,
  ) async {
    final session = _Session()..current = PeerSessionState.authenticating;
    final source = Completer<ViewerSource>();
    var opens = 0;
    await tester.pumpWidget(
      _app([
        _pending('Selected photo', () {
          opens++;
          return source.future;
        }),
      ], session: session),
    );
    await tester.pump();
    expect(opens, 0);
    expect(find.text('Reconnecting to the library'), findsOneWidget);
    session.changeState(PeerSessionState.connected);
    await tester.pump();
    expect(opens, 1);
    expect(find.text('Reconnecting to the library'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    source.complete(ViewerSource(uri: Uri.file('/initial-auth-source.png')));
    await tester.pump();
    await session.changes.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard navigation is bounded and clears an earlier error', (
    tester,
  ) async {
    var firstOpens = 0;
    var secondOpens = 0;
    final pending = Completer<ViewerSource>();
    await tester.pumpWidget(
      _app([
        _pending('Unavailable photo', () async {
          firstOpens++;
          throw StateError('Unavailable source');
        }),
        _pending('Next photo', () {
          secondOpens++;
          return pending.future;
        }),
      ]),
    );
    await tester.pump();
    expect(find.text('Unable to open media'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pump();
    expect(firstOpens, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(find.text('Unable to open media'), findsNothing);
    expect(find.text('Next photo'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pump();
    expect(secondOpens, 1);
    await tester.pumpWidget(const SizedBox());
    pending.complete(ViewerSource(uri: Uri.file('/unused-source.png')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact large text keeps details and gallery controls usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<ViewerSource>();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: MediaViewer(
          items: [
            _pending(
              'A long but real photo filename.png',
              () => pending.future,
            ),
          ],
          sourceLabel: 'A shared library',
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Show media details'));
    await tester.pump();
    expect(find.text('Media details'), findsOneWidget);
    expect(find.byTooltip('Back to library (Escape)'), findsOneWidget);
    expect(find.text('1 of 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    pending.complete(ViewerSource(uri: Uri.file('/unused-source.png')));
    await tester.pump();
  });
  testWidgets('skipping a cancellable load waits for its transfer slot', (
    tester,
  ) async {
    final first = Completer<ViewerSource>();
    final second = Completer<ViewerSource>();
    var firstActive = false;
    var secondOpened = false;
    await tester.pumpWidget(
      _app([
        ViewerItem(
          name: 'Downloading photo',
          mimeType: 'image/png',
          open: () {
            firstActive = true;
            return first.future;
          },
          cancelOpen: () async {
            try {
              await first.future;
            } on Object {
              // Simulates transfer teardown after cancellation.
            }
            firstActive = false;
          },
        ),
        _pending('Selected photo', () {
          expect(firstActive, isFalse);
          secondOpened = true;
          return second.future;
        }),
      ]),
    );
    await tester.pump();
    await tester.tap(find.text('Next'));
    await tester.pump();
    expect(secondOpened, isFalse);
    first.completeError(StateError('Cancelled'));
    await tester.pump();
    expect(secondOpened, isTrue);
    expect(find.text('2 of 2'), findsOneWidget);
    expect(find.text('Unable to open media'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    second.complete(ViewerSource(uri: Uri.file('/unused-cancelled.png')));
    await tester.pump();
  });
}
