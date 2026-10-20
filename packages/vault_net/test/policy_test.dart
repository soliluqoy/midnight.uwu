import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_net/src/policy.dart';

String sdp({String candidateType = 'host', String fingerprint = 'AB'}) =>
    'v=0\r\n'
    'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
    'a=ice-ufrag:local123\r\n'
    'a=ice-pwd:long-enough-ice-password\r\n'
    'a=fingerprint:sha-256 ${List.filled(32, fingerprint).join(':')}\r\n'
    'a=candidate:1 1 udp 123 192.0.2.1 12345 typ $candidateType\r\n';

List<IceReport> reports({
  String local = 'host',
  String remote = 'srflx',
  bool transport = true,
  bool selected = false,
  bool nominated = true,
  String state = 'succeeded',
}) => [
  if (transport) IceReport('t', 'transport', {'selectedCandidatePairId': 'p'}),
  IceReport('p', 'candidate-pair', {
    'state': state,
    'selected': selected,
    'nominated': nominated,
    'localCandidateId': 'l',
    'remoteCandidateId': 'r',
  }),
  IceReport('l', 'local-candidate', {'candidateType': local}),
  IceReport('r', 'remote-candidate', {'candidateType': remote}),
];

void main() {
  test('STUN only rejects TURN, credentials and injected URLs', () {
    expect(validateStunUrls(['stun:stun.example:3478']), hasLength(1));
    expect(validateStunUrls([]), isEmpty);
    for (final url in [
      'turn:relay:3478',
      'turns:relay',
      'stun:user@host',
      'stun:host\nturn:host',
      'https://host',
    ]) {
      expect(() => validateStunUrls([url]), throwsA(isA<PeerFailure>()));
    }
  });

  test('SDP binds complete bytes and SHA256 fingerprint', () {
    final a = SdpBinding.parse(sdp());
    final b = SdpBinding.parse('${sdp()}a=end-of-candidates\r\n');
    expect(a.fingerprint, List.filled(32, 'AB').join(':'));
    expect(a.digest, isNot(b.digest));
  });

  test('SDP rejects relay, unknown type, media and changed fingerprint', () {
    for (final text in [
      sdp(candidateType: 'relay'),
      sdp(candidateType: 'mystery'),
      '${sdp()}m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n',
      '${sdp()}a=fingerprint:sha-256 ${List.filled(32, 'CD').join(':')}\r\n',
      sdp().replaceFirst('sha-256', 'sha-1'),
      sdp().replaceFirst('a=ice-pwd:', 'a=unknown:'),
      '${sdp()}a=x:turn:relay.example\r\n',
    ]) {
      expect(() => SdpBinding.parse(text), throwsA(isA<PeerFailure>()));
    }
  });

  test('selected transport proves a direct successful pair', () {
    final path = requireDirectPath(reports());
    expect(path.pairId, 'p');
    expect(path.localType, 'host');
    expect(path.remoteType, 'srflx');
    expect(
      requireDirectPath(reports(transport: false, selected: true)).pairId,
      'p',
    );
  });

  test('nominated, successful, nonrelay is not proof of selected', () {
    expect(
      () => requireDirectPath(reports(transport: false)),
      throwsA(isA<PeerFailure>()),
    );
    expect(() => requireDirectPath([]), throwsA(isA<PeerFailure>()));
  });

  test('selected relay, unknown candidate or incomplete route fail closed', () {
    for (final values in [
      reports(local: 'relay'),
      reports(remote: 'relay'),
      reports(remote: 'unknown'),
      reports(state: 'in-progress'),
      reports()..removeLast(),
      reports()..add(IceReport('p2', 'candidate-pair', {'selected': true})),
      reports()
        ..add(IceReport('l', 'local-candidate', {'candidateType': 'host'})),
    ]) {
      expect(() => requireDirectPath(values), throwsA(isA<PeerFailure>()));
    }
  });

  test('only fully identified direct pending checks may converge', () {
    for (final state in ['waiting', 'in-progress']) {
      expect(
        () => requireDirectPath(reports(state: state)),
        throwsA(isA<DirectPathPending>()),
      );
      for (final invalid in [
        reports(state: state, local: 'relay'),
        reports(state: state, remote: 'relay'),
        reports(state: state, remote: 'unknown'),
        reports(state: state, transport: false),
        reports(state: state)..removeLast(),
      ]) {
        expect(
          () => requireDirectPath(invalid),
          throwsA(
            isA<PeerFailure>().having(
              (error) => error is DirectPathPending,
              'eligible for convergence',
              isFalse,
            ),
          ),
        );
      }
    }
    for (final state in ['failed', 'frozen', 'unknown']) {
      expect(
        () => requireDirectPath(reports(state: state)),
        throwsA(
          isA<PeerFailure>().having(
            (error) => error is DirectPathPending,
            'eligible for convergence',
            isFalse,
          ),
        ),
      );
    }
    expect(requireDirectPath(reports()).remoteType, 'srflx');
  });

  test('route change cannot reuse a formerly direct verification', () {
    expect(requireDirectPath(reports()).remoteType, 'srflx');
    expect(
      () => requireDirectPath(reports(remote: 'relay')),
      throwsA(isA<PeerFailure>()),
    );
  });

  test('total JSON wire budget includes five-byte header and UTF8', () {
    expect(
      encodeControl({'x': 'a' * (maxPacketBytes - 13)}, overhead: 5).length,
      maxPacketBytes - 5,
    );
    expect(
      () => encodeControl({'x': 'a' * (maxPacketBytes - 12)}, overhead: 5),
      throwsA(isA<PeerFailure>()),
    );
    expect(
      () => encodeControl({'x': 'é' * 8192}, overhead: 5),
      throwsA(isA<PeerFailure>()),
    );
  });

  test('control rejects nested, nonfinite and non-object payloads', () {
    expect(() => encodeControl({'x': double.nan}), throwsA(isA<PeerFailure>()));
    Object? nested = true;
    for (var i = 0; i < 30; i++) {
      nested = [nested];
    }
    expect(() => encodeControl({'x': nested}), throwsA(isA<PeerFailure>()));
    expect(
      () => decodeControl(Uint8List.fromList([91, 93])),
      throwsA(isA<PeerFailure>()),
    );
    expect(
      () => decodeControl(Uint8List(maxPacketBytes + 1)),
      throwsA(isA<PeerFailure>()),
    );
  });
}
