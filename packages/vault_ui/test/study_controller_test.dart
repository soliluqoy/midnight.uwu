import 'package:flutter_test/flutter_test.dart';
import 'package:vault_ui/vault_ui.dart';

void main() {
  test('approval and publication expose only the approved sample scope', () {
    final controller = StudyController()..switchPerspective(asViewer: true);
    addTearDown(controller.dispose);
    controller.change(() {
      controller
        ..browsingRemote = true
        ..access = StudyAccess.approved;
    });
    expect(controller.visibleItems, isEmpty);
    controller.switchPerspective(asViewer: false);
    controller.change(() {
      controller.publishing = true;
    });
    controller.switchPerspective(asViewer: true);
    controller.change(() {
      controller.browsingRemote = true;
    });
    expect(
      controller.visibleItems.map((item) => item.id),
      unorderedEquals(['lake', 'film', 'alpine']),
    );
    controller.change(() {
      controller.access = StudyAccess.revoked;
    });
    expect(controller.visibleItems, isEmpty);
  });

  test('intentional disconnect survives restore and network recovery', () {
    final original = StudyController();
    addTearDown(original.dispose);
    original.change(() {
      original.connection = StudyConnection.disconnected;
    });
    final restored = StudyController(restored: original.toJson());
    addTearDown(restored.dispose);
    restored.restoreNetwork();
    expect(restored.connection, StudyConnection.disconnected);
    expect(restored.remoteReadable, isFalse);
  });

  test('publication listing and human verification are per perspective', () {
    final controller = StudyController();
    addTearDown(controller.dispose);
    controller.change(() {
      controller
        ..publishing = true
        ..publicListing = true
        ..verified = true;
    });
    controller.switchPerspective(asViewer: true);
    expect(controller.publishing, isFalse);
    expect(controller.publicListing, isFalse);
    expect(controller.verified, isFalse);
    expect(controller.ownerPublishing, isTrue);
    controller.switchPerspective(asViewer: false);
    expect(controller.publishing, isTrue);
    expect(controller.publicListing, isTrue);
    expect(controller.verified, isTrue);
  });

  test('empty start removes sample access and every sample media entry', () {
    final controller = StudyController();
    addTearDown(controller.dispose);
    controller.change(() {
      controller
        ..access = StudyAccess.approved
        ..publishing = true
        ..rememberApproval = true;
    });
    controller.reset(withSamples: false);
    expect(controller.localItems, isEmpty);
    expect(controller.access, StudyAccess.none);
    expect(controller.publishing, isFalse);
    expect(controller.rememberApproval, isFalse);
    expect(controller.contactName, isEmpty);
    expect(controller.connection, StudyConnection.idle);
  });
}
