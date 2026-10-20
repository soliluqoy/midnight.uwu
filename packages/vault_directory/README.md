# vault_directory

Two deliberately separate presence modes:

- `ContactDirectory`: private sealed announcements to explicitly selected,
  locally verified contacts. No public metadata or automatic heartbeat.
- `PublicContactDirectory`: explicit opt-in public MQTT pilot discovery and
  publication, with bounded SQLite cache and local search.

Neither mode proves a human identity, a reachable session or library access.
There is no global Internet discovery claim.

## Private contact API

```dart
final directory = ContactDirectory(
  signaling: signaling,
  resolveContact: contactsByNodeId,
  maxEntries: 256,
);

await directory.setPublishing(true, name: 'My display name');
await directory.announce(selectedVerifiedContact);
final current = directory.entries;
await directory.setPublishing(false);
await directory.close();
```

`contactsByNodeId` must return a locally verified `ContactCard`, or `null` for
unknown/removed contacts. The signaling owner configures the same trusted contact
bindings and starts `SignalingClient`; the directory subscribes on construction.
It does not start or close the shared signaling client.

Publishing defaults to **disabled**. Enabling sends nothing by itself. Each
`announce(ContactCard)` targets exactly one explicitly selected, resolved contact.
There is no automatic heartbeat and no iteration over all contacts. Disabled,
closed, unknown-contact, changed-binding and invalid-name publication fails.
Disabling also invalidates announcements still awaiting directory contact lookup.
Already submitted frames cannot be recalled: their original signed expiration
still applies, including any signaling-layer retransmission.

`ContactPresence` exposes `contact`, `nodeId`, announced `name`, `issuedAt` (Unix
seconds) and `expiresAt` (UTC). `entries` returns an immutable snapshot, pruning
expired entries every time it is read. Receiving is independent of publishing;
turning publication off does not hide valid announcements from known contacts.
`errors` is a broadcast stream of local contact-lookup/source errors as data
events. Unknown contacts and invalid announcements are simply not admitted.

## Private authentication, expiration and resource bounds

Inbound data comes only from `SignalingClient.messages`, after sealed-envelope,
signature, recipient and known-binding authentication. The directory additionally
derives the sender's node ID from its signing key, resolves that exact contact,
and compares the contact signing key before admitting presence.

Only type `MsgType.announce` with the exact payload
`{'presence': true, 'name': String, 'expires': int}` is accepted. Names are at most
80 UTF-8 bytes, including on publication. Signed envelope expiry must equal
payload expiry, with `now < expires <= now + 90`, non-future issuance and a signed
issuance-to-expiry lifetime of at most 90 seconds. Older-issued updates cannot
overwrite newer entries. Neither reads nor repeated receipt changes expiration.
Clocks must be reasonably synchronized; future-issued announcements fail closed.

At most `maxEntries` contacts are cached (default 256, required positive).
Expired slots are reclaimed before admission. At capacity, existing contacts may
refresh but new contacts are dropped rather than evicting an active contact.
Inbound pending contact lookups are separately bounded to `maxEntries`, with at
most one lookup in progress; overflow is dropped. Signaling imposes its own wire,
authentication, rate and replay budgets. The private-contact cache is memory-only;
only the separate public directory persists signed public announcements.

`ContactPresenceCache` exposes the same validation/admission rules with an explicit
clock for deterministic use and tests. It **does not authenticate raw envelopes**:
only pass envelopes already authenticated by `SignalingClient`, alongside a
verified contact. Its tests cover exact TTL boundaries, UTF-8 limits, strict
schema/source matching, replay expiration, monotonic updates and capacity. Further
tests cover disabled publication, lookup races, lifecycle and actual signed/sealed
manual-transport exchange. No public discovery or native reachability claim is
made by these tests.

## Public MQTT pilot directory

```dart
final publicDirectory = PublicContactDirectory(
  signaling: signaling,
  databasePath: publicPresenceDatabasePath,
  maxEntries: 256,
);
await publicDirectory.load();
await publicDirectory.setDiscovering(true); // Browsing does not publish a profile.
final partialResults = publicDirectory.search('selected public tag', limit: 50);
await publicDirectory.setPublishing(
  true,
  name: 'Public display name',
  tags: ['photography'],
  sharedCount: 20,
);
await publicDirectory.setPublishing(false);
await publicDirectory.setDiscovering(false);
await publicDirectory.close();
```

Use an application-support **disk file** for `databasePath`. SQLite uses the
`sqlite3` 3.7.1 native-assets backend, without `sqlite3_flutter_libs`. Public browse
and publication are off initially and must be explicit user actions. The shared
`SignalingClient` must already be started with a configured TLS `MqttSignaling`
endpoint. Manual signaling does not implement public discovery: enabling it
raises `UnsupportedError`, rather than returning invented or simulated peers.

Public listing discloses the chosen name, up to eight selected tags, coarse
shared count, stable signing identity, public key binding and recent presence to
the broker and namespace subscribers. Names are at most 80 UTF-8 bytes; tags are
at most 24 UTF-8 bytes each. No filenames, paths, posters, ACLs, endpoints/IP hints,
grants or secrets are public fields. Publication sends immediately and every
30 seconds while explicitly enabled. Origin-signed expiry is at most 90 seconds;
an expiry sweep runs every 15 seconds and every read also prunes stale entries.
Stopping cannot recall previously published records before their signed expiry.

Signaling verifies the origin signature, strict public schema, exact topic
identity and self-signed encryption-key binding before emitting a record. Public
ANNOUNCE is intentionally unsealed; private signaling remains sealed and requires
a known contact. Client signature-work/byte/receive/replay budgets and directory
entry/disk/search-response budgets are independent. Only newer `(epoch, sequence)`
updates may replace a live record. Epoch is process-start Unix microseconds, not
persistent identity-rotation authority; there is no cross-clock-rollback promise.

The SQLite cache stores the **original signed envelope**, never an unsigned JSON
substitute. On `load()` a bounded number of unexpired records are cryptographically
reverified before admission. Stored timestamps are only pruning hints; the signed
expiry remains authoritative and is never extended by cache receipt or restart.
The cache holds at most `maxEntries` records, default 256; new identities are
dropped at capacity, while existing identities may refresh. SQLite has a configured
main-file page budget of `maxEntries * 8192 + 262144` bytes, bounded record sizes,
delete journaling and automatic vacuum for newly created databases. An existing
oversized database is rejected rather than silently used. Database errors surface
and stop discovery instead of silently substituting fabricated or memory-only
results. Turning browsing off clears memory and disk results. Publishing can
remain enabled independently; the transport stays subscribed while either mode
needs it, but browse-disabled directories expose no results.

`entries` is an immutable snapshot of `PublicPresenceRecord`; `changes` broadcasts
immutable snapshots on admission, sweep or opt-out, and `errors` broadcasts local
failures as data events. `search(query, limit: 50)` searches only the bounded local
cache by public name, tag or stable node ID, case-insensitively. Results are partial
observations on a common reachable endpoint: empty does not mean nobody exists,
and different brokers are not automatically federated.

`contactFor(record, name: userChosenName)` verifies the public binding and derives
the contact ID. It does **not** persist, trust, connect, or approve that contact.
The UI must show the complete fingerprint for independent comparison and require
an explicit add-contact action; an advertised name is not authentication. Library
consent and signed direct-session authentication remain separate requirements.

`PublicPresenceCache` is an explicit-clock validation/state helper, not a raw
network authenticator. Public behavioral/security tests use the production
signer/verifier and temporary SQLite databases to cover signed TTL/tampering,
strict public metadata, stale sequence/epoch rejection, bounded restart cache,
local search, independent opt-in gates, explicit contact conversion and honest
manual-mode rejection. A test-only byte transport replaces only MQTT transport,
not authentication. These tests do not establish live MQTT, native-assets or
multi-device acceptance; runtime verification belongs to the integration owner.
