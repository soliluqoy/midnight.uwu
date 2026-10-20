import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Maximum complete serialized native data-channel packet.
const int maxPacketBytes = 16 * 1024;

/// Maximum complete SDP accepted by the signaling schema.
const int maxSdpBytes = 20 * 1024;

/// ICE candidate types that can identify a direct, non-TURN path.
const directCandidateTypes = {'host', 'srflx', 'prflx'};

/// The closed set of connection problems a person can understand and fix.
enum ConnectionProblem {
  /// Private signaling arrived from an identity that is not a contact.
  notAContact,

  /// A contact's new connection was ignored because you disconnected them.
  youDisconnected,

  /// Setup messages were never answered: peer offline, closed or unreachable.
  negotiationTimedOut,

  /// Both networks refused every direct route before a connection existed.
  noDirectRoute,

  /// The connection-setup transport could not be reached.
  signalingUnavailable,
}

/// Sanitized policy or lifecycle failure suitable for local UI diagnostics.
class PeerFailure implements Exception {
  /// Creates a failure without private SDP, candidate addresses or payloads.
  const new(this.reason, {this.problem});

  /// Human-readable security or lifecycle boundary that failed.
  final String reason;

  /// Person-facing classification, when the failure has a known remedy.
  final ConnectionProblem? problem;
  @override
  String toString() => 'PeerFailure: $reason';
}

/// A fully identified direct pair whose native connectivity check is pending.
/// No traffic is authorized until a fresh report establishes success.
class DirectPathPending extends PeerFailure {
  /// Distinguishes bounded connectivity convergence from invalid route reports.
  const new() : super('Selected direct ICE pair is still being checked');
}

/// Accepts STUN only. Credentials, TURN, and URL lists hidden in a string fail.
List<String> validateStunUrls(List<String> urls) {
  if (urls.length > 8) throw const PeerFailure('Too many STUN URLs');
  for (final url in urls) {
    if (!RegExp(
      r'^stuns?:[a-zA-Z0-9.-]+(?::[0-9]{1,5})?(?:\?transport=(?:udp|tcp))?$',
    ).hasMatch(url)) {
      throw const PeerFailure('Only credential-free STUN URLs are allowed');
    }
  }
  return List<String>.unmodifiable(urls);
}

/// Binds a complete data-only SDP to its single SHA-256 DTLS fingerprint.
class SdpBinding {
  /// Parses a bounded data-only description and rejects relays or ambiguity.
  factory parse(String sdp) {
    if (utf8.encode(sdp).length > maxSdpBytes || sdp.contains('\u0000')) {
      throw const PeerFailure('SDP size or encoding rejected');
    }
    final lines = sdp.split(RegExp(r'\r?\n'));
    final fingerprints = <String>{};
    var application = 0;
    var ufrag = false;
    var password = false;
    for (final line in lines) {
      if (line.startsWith('m=')) {
        if (!line.startsWith('m=application ') || !line.contains('DTLS/SCTP')) {
          throw const PeerFailure('Only a data-only DTLS/SCTP SDP is allowed');
        }
        application++;
      }
      if (line.startsWith('a=fingerprint:')) {
        final match = RegExp(
          r'^a=fingerprint:sha-256 ((?:[0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})$',
        ).firstMatch(line);
        if (match == null) {
          throw const PeerFailure('A SHA-256 DTLS fingerprint is required');
        }
        fingerprints.add(match.group(1)!.toUpperCase());
      }
      if (line.startsWith('a=candidate:')) {
        final fields = line.split(RegExp(r'\s+'));
        final typ = fields.indexOf('typ');
        if (typ < 0 ||
            typ + 1 >= fields.length ||
            !directCandidateTypes.contains(fields[typ + 1])) {
          throw const PeerFailure('Relay or unknown ICE candidate rejected');
        }
      }
      if (line.startsWith('a=ice-ufrag:') && line.length > 12) ufrag = true;
      if (line.startsWith('a=ice-pwd:') && line.length > 10) password = true;
      if (RegExp('turns?:', caseSensitive: false).hasMatch(line)) {
        throw const PeerFailure('TURN is forbidden');
      }
    }
    if (application != 1 || fingerprints.length != 1 || !ufrag || !password) {
      throw const PeerFailure('Incomplete or ambiguous DTLS/ICE binding');
    }
    return SdpBinding._(
      sha256.convert(utf8.encode(sdp)).toString(),
      fingerprints.single,
    );
  }
  new _(this.digest, this.fingerprint);

  /// SHA-256 of the exact signed SDP bytes, including gathered candidates.
  final String digest;

  /// Canonical uppercase SHA-256 DTLS fingerprint from the SDP.
  final String fingerprint;
}

/// Plugin-independent native statistics report used by direct-route policy.
class IceReport {
  /// Captures one native report without changing its values.
  new(this.id, this.type, this.values);

  /// Native report identifier, used only for relationship validation.
  final String id;

  /// Standard WebRTC statistics report type.
  final String type;

  /// Native values required to establish pair selection and candidate types.
  final Map<String, Object?> values;
}

/// A selected, succeeded native pair whose candidate types passed policy.
class DirectPath {
  /// Captures the already-verified pair and both direct candidate types.
  new(this.pairId, this.localType, this.remoteType);

  /// Selected native pair identifier; never included in public diagnostics.
  final String pairId;

  /// Verified local host, server-reflexive or peer-reflexive candidate type.
  final String localType;

  /// Verified remote host, server-reflexive or peer-reflexive candidate type.
  final String remoteType;
}

/// A nominated pair is NOT proof that it is the selected transport pair.
/// Unknown or ambiguous native stats deliberately fail closed.
DirectPath requireDirectPath(List<IceReport> reports) {
  final byId = <String, IceReport>{};
  for (final report in reports) {
    if (byId.containsKey(report.id)) {
      throw const PeerFailure('Duplicate ICE stats identifiers');
    }
    byId[report.id] = report;
  }
  final selectedIds = <String>{};
  for (final report in reports.where((r) => r.type == 'transport')) {
    final id = report.values['selectedCandidatePairId'];
    if (id is String && id.isNotEmpty) selectedIds.add(id);
  }
  final marked = reports.where(
    (r) => r.type == 'candidate-pair' && r.values['selected'] == true,
  );
  if (selectedIds.isEmpty) {
    selectedIds.addAll(marked.map((r) => r.id));
  } else if (marked.any((r) => !selectedIds.contains(r.id))) {
    throw const PeerFailure('Conflicting selected ICE pair reports');
  }
  if (selectedIds.length != 1) {
    throw const PeerFailure('Native selected ICE pair is unverifiable');
  }
  final pair = byId[selectedIds.single];
  if (pair == null || pair.type != 'candidate-pair') {
    throw const PeerFailure('Selected ICE pair is unverifiable');
  }
  final local = byId[pair.values['localCandidateId']];
  final remote = byId[pair.values['remoteCandidateId']];
  if (local?.type != 'local-candidate' || remote?.type != 'remote-candidate') {
    throw const PeerFailure('Selected ICE candidates are unverifiable');
  }
  final localType = local!.values['candidateType'];
  final remoteType = remote!.values['candidateType'];
  if (localType is! String ||
      remoteType is! String ||
      !directCandidateTypes.contains(localType) ||
      !directCandidateTypes.contains(remoteType)) {
    throw const PeerFailure('Relayed or unknown selected ICE route rejected');
  }
  final state = pair.values['state'];
  if (state == 'waiting' || state == 'in-progress') {
    throw const DirectPathPending();
  }
  if (state != 'succeeded') {
    throw const PeerFailure('Selected ICE pair has not succeeded');
  }
  return DirectPath(pair.id, localType, remoteType);
}

/// Rejects nonfinite, deeply nested or oversized local JSON before encoding.
void validateJson(Object? value) {
  var budget = maxPacketBytes;
  void consume(int amount) {
    budget -= amount;
    if (budget < 0) throw const PeerFailure('Control size budget exceeded');
  }

  void visit(Object? item, int depth) {
    if (depth > 24) throw const PeerFailure('Control nesting limit exceeded');
    if (item == null ||
        item is bool ||
        item is int ||
        (item is double && item.isFinite)) {
      consume(item.toString().length);
    } else if (item is String) {
      consume(item.length + 2);
    } else if (item is List<Object?>) {
      consume(item.isEmpty ? 2 : item.length + 1);
      for (final entry in item) {
        visit(entry, depth + 1);
      }
    } else if (item is Map<String, Object?>) {
      consume(item.isEmpty ? 2 : item.length + 1);
      for (final entry in item.entries) {
        consume(entry.key.length + 3);
        visit(entry.value, depth + 1);
      }
    } else {
      throw const PeerFailure('Control message is not finite JSON');
    }
  }

  // A lower bound stops huge local objects before JSON allocation. Escaping
  // can expand this bounded input by at most six; the exact UTF8 limit follows.
  visit(value, 0);
}

/// Serializes one JSON object within the complete packet's remaining budget.
Uint8List encodeControl(Map<String, Object?> message, {int overhead = 0}) {
  validateJson(message);
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(message)));
  if (bytes.length + overhead > maxPacketBytes) {
    throw const PeerFailure('Serialized packet exceeds 16 KiB');
  }
  return bytes;
}

/// Decodes one bounded UTF-8 JSON object and validates its shape and depth.
Map<String, Object?> decodeControl(Uint8List bytes) {
  if (bytes.length > maxPacketBytes) {
    throw const PeerFailure('Received packet exceeds 16 KiB');
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map<String, Object?>) {
    throw const PeerFailure('Control packet must be a JSON object');
  }
  validateJson(value);
  return value;
}
