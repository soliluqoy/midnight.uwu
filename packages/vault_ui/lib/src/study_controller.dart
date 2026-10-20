import 'package:flutter/foundation.dart';

/// Kind of local media presented by the interface preview.
enum MediaKind {
  /// A still image.
  photo,

  /// A locally playable video.
  video,
}

/// Sort modes for the small local preview library.
enum MediaSort {
  /// Most recent first.
  newest,

  /// Alphabetical by title.
  name,
}

/// Simulated owner authorization, never a production grant.
enum StudyAccess {
  /// No request has been made.
  none,

  /// Waiting for the owner's decision.
  pending,

  /// Owner approved the sample collection.
  approved,

  /// Owner declined the request.
  denied,

  /// Owner stopped future access.
  revoked,

  /// Identity is blocked from requesting access.
  blocked,
}

/// Simulated connection, independent of access and human verification.
enum StudyConnection {
  /// No connection yet.
  idle,

  /// A connected state selected in the walkthrough.
  connected,

  /// Unintentional interruption.
  interrupted,

  /// Deliberately disconnected; recovery cannot override this state.
  disconnected,

  /// A direct route could not be established.
  noRoute,
}

/// Metadata for bundled illustrations or media explicitly selected by the user.
@immutable
class LibraryItem {
  /// Creates one media entry without reading or copying its contents.
  const new({
    required this.id,
    required this.title,
    required this.path,
    required this.kind,
    required this.collection,
    required this.date,
    this.thumbnail,
    this.isAsset = true,
    this.ownerIsViewer = false,
    this.bytes,
  });

  /// Stable within this preview session.
  final String id;

  /// Display title; imported entries retain their filename.
  final String title;

  /// Asset key or actual local file path.
  final String path;

  /// Rendering/playback category.
  final MediaKind kind;

  /// Display collection, not an authorization identifier.
  final String collection;

  /// Date used for the preview's sort order.
  final DateTime date;

  /// Optional still image for a video.
  final String? thumbnail;

  /// Whether paths refer to bundled app assets.
  final bool isAsset;

  /// Which study perspective selected this local file.
  final bool ownerIsViewer;

  /// Actual file length when known; not a fabricated transfer counter.
  final int? bytes;
}

/// Local saved-copy record, separate from the illustrative cache.
@immutable
class SavedCopy {
  /// Records an actually completed export.
  const new({required this.name, required this.destination});

  /// Original filename or bundled-media title.
  final String name;

  /// OS-selected path or content URI, kept locally.
  final String destination;
}

/// Bundled, explicitly illustrative media; never a device scan.
final List<LibraryItem> sampleLibrary = List.unmodifiable([
  LibraryItem(
    id: 'lake',
    title: 'A quiet morning',
    path: 'assets/media/lake.jpg',
    kind: MediaKind.photo,
    collection: 'Alpine days',
    date: DateTime(2026, 6, 18),
  ),
  LibraryItem(
    id: 'film',
    title: 'The long way home',
    path: 'assets/media/lake-study.mp4',
    thumbnail: 'assets/media/lake.jpg',
    kind: MediaKind.video,
    collection: 'Alpine days',
    date: DateTime(2026, 6, 18),
  ),
  LibraryItem(
    id: 'forest',
    title: 'Into the evergreens',
    path: 'assets/media/forest.jpg',
    kind: MediaKind.photo,
    collection: 'Slow weekends',
    date: DateTime(2026, 6, 12),
  ),
  LibraryItem(
    id: 'alpine',
    title: 'Somewhere in the mountains',
    path: 'assets/media/alpine.jpg',
    kind: MediaKind.photo,
    collection: 'Alpine days',
    date: DateTime(2026, 6, 11),
  ),
  LibraryItem(
    id: 'coast',
    title: 'The last light',
    path: 'assets/media/coast.jpg',
    kind: MediaKind.photo,
    collection: 'Coastal notes',
    date: DateTime(2026, 5, 24),
  ),
]);

/// Presentation state for the native interface-first build.
///
/// There is deliberately no transport, identity key or capability token here.
/// Every peer/authorization action is labeled as a walkthrough simulation.
class StudyController extends ChangeNotifier {
  /// Restores non-secret UI state, ignoring unrecognized values.
  new({Map<String, Object?>? restored}) {
    if (restored == null) return;
    dark = restored['dark'] == true;
    sampleData = restored['sampleData'] != false;
    viewer = restored['viewer'] == true;
    _ownerPublishing = restored['ownerPublishing'] == true;
    _viewerPublishing = restored['viewerPublishing'] == true;
    _ownerListed = restored['ownerListed'] == true;
    _viewerListed = restored['viewerListed'] == true;
    _ownerVerified = restored['ownerVerified'] == true;
    _viewerVerified = restored['viewerVerified'] == true;
    rememberApproval = restored['rememberApproval'] == true;
    sourceAvailable = restored['sourceAvailable'] != false;
    access = StudyAccess.values.firstWhere(
      (v) => v.name == restored['access'],
      orElse: () => StudyAccess.pending,
    );
    connection = StudyConnection.values.firstWhere(
      (v) => v.name == restored['connection'],
      orElse: () => StudyConnection.connected,
    );
    if (restored['contact'] case final String value) contactName = value;
    if (restored['cacheMb'] case final int value) cacheMb = value.clamp(0, 512);
    if (restored['uplinkMbps'] case final num value) {
      uplinkMbps = value.toDouble().clamp(1, 50);
    }
  }

  /// Selected shell destination; remote browsing is a People detail route.
  int pageIndex = 0;

  /// Whether the shared library detail is open.
  bool browsingRemote = false;

  /// Alex owns the sample library; Sam views it. Both can pick local media.
  bool viewer = false;

  /// User-selected dark appearance.
  bool dark = false;

  /// Deliberately labeled illustrative files, not undisclosed sample user data.
  bool sampleData = true;

  /// Simulated owner decision.
  StudyAccess access = StudyAccess.pending;

  /// Simulated direct session state.
  StudyConnection connection = StudyConnection.connected;

  /// Simulated source-permission outcome.
  bool sourceAvailable = true;

  /// Explicitly chosen sample rule for this identity and scope.
  bool rememberApproval = false;

  /// Fictional/contact label; not a cryptographic identity.
  String contactName = 'Sam Chen';

  /// Selected collection filter.
  String? collection;

  /// Selected media category; null includes both categories.
  MediaKind? filter;

  /// Search over locally loaded authorized entries only.
  String query = '';

  /// Current local sort order.
  MediaSort sort = MediaSort.newest;

  /// Grid versus list layout.
  bool listView = false;

  /// Illustrative cache counter, explicitly not a native storage measurement.
  int cacheMb = 192;

  /// Illustrative cap, not an active network scheduler.
  double uplinkMbps = 14;

  /// User-selected media, valid for this process; URI lifetime is not promised.
  final List<LibraryItem> imported = [];

  /// Actually completed OS save operations in this process.
  final List<SavedCopy> savedCopies = [];

  /// Native player positions retained while navigating this process.
  final Map<String, Duration> playbackPositions = {};

  bool _ownerPublishing = false;
  bool _viewerPublishing = false;
  bool _ownerListed = false;
  bool _viewerListed = false;
  bool _ownerVerified = false;
  bool _viewerVerified = false;

  /// Own publication; changing perspective never changes the other owner.
  bool get publishing => viewer ? _viewerPublishing : _ownerPublishing;
  set publishing(bool value) {
    if (viewer) {
      _viewerPublishing = value;
    } else {
      _ownerPublishing = value;
    }
  }

  /// Publication of the actual sample owner.
  bool get ownerPublishing => _ownerPublishing;

  /// Independent public listing choice for the current perspective.
  bool get publicListing => viewer ? _viewerListed : _ownerListed;
  set publicListing(bool value) {
    if (viewer) {
      _viewerListed = value;
    } else {
      _ownerListed = value;
    }
  }

  /// Manual comparison made by this perspective, not the other person's trust.
  bool get verified => viewer ? _viewerVerified : _ownerVerified;
  set verified(bool value) {
    if (viewer) {
      _viewerVerified = value;
    } else {
      _ownerVerified = value;
    }
  }

  /// Local study identity label.
  String get localName => viewer ? contactName : 'Alex Morgan';

  /// Current peer, distinct from the local study identity.
  String get peerName => viewer ? 'Alex Morgan' : contactName;

  /// An owner's actionable request badge, not an engagement counter.
  bool get pendingRequest =>
      !viewer && access == StudyAccess.pending && contactName.isNotEmpty;

  /// This simulation only permits one approved, available sample scope.
  bool get remoteReadable =>
      viewer &&
      sampleData &&
      access == StudyAccess.approved &&
      _ownerPublishing &&
      connection == StudyConnection.connected &&
      sourceAvailable;

  /// The owner's exact approved collection; never all bundled assets.
  List<LibraryItem> get approvedCollection => sampleLibrary
      .where((item) => item.collection == 'Alpine days')
      .toList(growable: false);

  /// Local items selected by this perspective plus the opt-in sample library.
  List<LibraryItem> get localItems => [
    if (sampleData && !viewer) ...sampleLibrary,
    ...imported.where((item) => item.ownerIsViewer == viewer),
  ];

  /// Loaded, filtered entries; denied access reveals no protected metadata.
  List<LibraryItem> get visibleItems {
    final source = browsingRemote
        ? (remoteReadable ? approvedCollection : <LibraryItem>[])
        : localItems;
    final items = source
        .where(
          (item) =>
              (collection == null ||
                  browsingRemote ||
                  collection == item.collection) &&
              (filter == null || filter == item.kind) &&
              item.title.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    if (sort == MediaSort.name) {
      items.sort((a, b) => a.title.compareTo(b.title));
    } else {
      items.sort((a, b) => b.date.compareTo(a.date));
    }
    return items;
  }

  /// Mutates presentation state and notifies the app persistence layer.
  void change(VoidCallback mutation) {
    mutation();
    notifyListeners();
  }

  /// Navigates without implicitly connecting, publishing or granting access.
  void navigate(int destination) {
    change(() {
      pageIndex = destination;
      browsingRemote = false;
      collection = null;
      filter = null;
      query = '';
    });
  }

  /// Changes the review perspective, not a permanent product owner/viewer role.
  void switchPerspective({required bool asViewer}) {
    change(() {
      viewer = asViewer;
      pageIndex = 1;
      browsingRemote = false;
      collection = null;
      filter = null;
      query = '';
    });
  }

  /// Restores a simulated path, never an explicit user disconnect.
  void restoreNetwork() {
    if (connection == StudyConnection.disconnected ||
        access == StudyAccess.blocked) {
      return;
    }
    change(() {
      connection = StudyConnection.connected;
    });
  }

  /// Replaces the walkthrough or opens a truly empty local interface.
  void reset({required bool withSamples}) {
    change(() {
      sampleData = withSamples;
      viewer = false;
      pageIndex = 0;
      browsingRemote = false;
      _ownerPublishing = false;
      _viewerPublishing = false;
      _ownerListed = false;
      _viewerListed = false;
      _ownerVerified = false;
      _viewerVerified = false;
      access = withSamples ? StudyAccess.pending : StudyAccess.none;
      connection = withSamples
          ? StudyConnection.connected
          : StudyConnection.idle;
      sourceAvailable = true;
      rememberApproval = false;
      contactName = withSamples ? 'Sam Chen' : '';
      collection = null;
      filter = null;
      query = '';
      cacheMb = 192;
      imported.clear();
      savedCopies.clear();
      playbackPositions.clear();
    });
  }

  /// Only non-secret UI data; no files, paths, keys or grants are persisted.
  Map<String, Object?> toJson() => {
    'dark': dark,
    'sampleData': sampleData,
    'viewer': viewer,
    'ownerPublishing': _ownerPublishing,
    'viewerPublishing': _viewerPublishing,
    'ownerListed': _ownerListed,
    'viewerListed': _viewerListed,
    'ownerVerified': _ownerVerified,
    'viewerVerified': _viewerVerified,
    'access': access.name,
    'connection': connection.name,
    'sourceAvailable': sourceAvailable,
    'rememberApproval': rememberApproval,
    'contact': contactName,
    'cacheMb': cacheMb,
    'uplinkMbps': uplinkMbps,
  };
}
