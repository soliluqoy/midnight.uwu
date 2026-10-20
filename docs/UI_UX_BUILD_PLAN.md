# Vault UI/UX build plan

Revised 2026-10-19: messenger-first experimental native application, with secondary
media libraries and a separate historical browser study. Product gates remain open.

The [main build plan](../P2P_VIDEO_SHARE_BUILD_PLAN.md) remains authoritative for
product scope, security, architecture and feasibility gates. This companion owns
navigation, interaction contracts, visual direction and UI acceptance criteria.
If a technical result invalidates a design assumption, record and revise the
interaction before implementation; do not weaken the main plan to fit a mockup.

The user-approved [Quietly personal redesign](INTERFACE_REDESIGN_PLAN.md) is the
current implementation contract for the first-principles, dating-app-informed
interface revision. It replaces the former five equal destinations with three
primary destinations and persistent utilities without changing product/security
scope or feasibility gates.

User-directed sequencing revision, 2026-10-18: build the native interface first,
then resume Phase0 testing. [Main plan section6.2](../P2P_VIDEO_SHARE_BUILD_PLAN.md#62-interface-first-sequencing-revision)
permits UI/local-media implementation now; production networking, identity and
authorization still require the core feasibility gates. This is not a Phase1 go.

The [interactive interface study](../design/vault/README.md) is available under
`design/vault/`. It exercises visual layouts and paired consent/media journeys
with labeled simulated peer states. Local file viewing/playback is real browser
behavior; it does not implement production networking, identity or authorization.
The [native Flutter app](../apps/vault/README.md) now composes real experimental
services under the authorized implementation-first revision. Its current
messenger-first navigation supersedes the older browse-first interface.
See the app README for exact native observations and remaining feasibility gates;
the historical browser study is not production transport or authorization evidence.

## 1. Manyverse research: inspiration, not a feature import

Research used official descriptions, FAQs, dated release notes and published
mobile/desktop screenshots. No installed Manyverse binary was exercised. The
screenshots establish visible layouts, not current runtime behavior. Historical
FAQs use older navigation names; release notes and design proposals are dated
below rather than presented as one verified current interface.

| Evidence | Manyverse pattern | Vault decision |
|---|---|---|
| [Product page and mobile/desktop screenshots](https://www.manyver.se/), [desktop launch, 2022-01-05](https://www.manyver.se/blog/2022-01-update/) | Familiar labeled destinations; mobile bottom navigation becomes a desktop sidebar; shared feature model | Adapt the responsive shell, not Public/Private social feeds or compose controls |
| [Connections redesign, 2021-12-05](https://www.manyver.se/blog/2021-12-update/) | Explains connectivity and recommends steps instead of merely listing peers; attention requested only when useful | Adopt status + explanation + next action. Reject a peer-count health gauge: zero peers can be correct, and one approved viewer is useful |
| [Connecting with people FAQ](https://www.manyver.se/faq/connections/), [Wi-Fi FAQ](https://www.manyver.se/faq/connect-wifi/) | Deliberate relationship-building; distinguishes Connect from Connect and follow; advises checking identity | Separate adding a contact, verifying identity, connecting and granting access. Do not import Bluetooth, automatic LAN discovery, DHT invites, rooms or pubs |
| [Storage release, 2022-08-05](https://www.manyver.se/blog/2022-08-update/) | Shows local usage by category and person, with a configurable blob limit | Show playback cache, app metadata and app-managed downloads distinctly. No SSB compaction workflow or block-to-delete coupling |
| [Early adoption report, 2018-09-29](https://www.manyver.se/blog/early-days/) | Empty-network confusion and expensive initial sync obstruct first use | Empty states explain the next action; stage indexing and page remote browsing. Never require whole-library replication before viewing |
| [Permanence and safety, 2022-10-28](https://www.manyver.se/blog/2022-10-permanence-and-safety/), [permanence FAQ](https://www.manyver.se/faq/permanence/) | Risk wording needs nuance, not a reassuring slogan | Explain received-copy limits at first publish and revocation; distinguish deleting a local file from stopping future delivery |
| [Private Groups UX proposal, 2023-05-19](https://www.manyver.se/blog/2023-05-19/) | Validates assumptions/personas; models relationship-specific profiles and explicit joining consent | Adopt state-dependent actions and consent review. This was a design proposal, not evidence of a shipped flow. Do not add groups, request chats, admins or hosted invitation pages |
| [Multi-device FAQ](https://www.manyver.se/faq/account-on-many-devices/) | Local identity is not a cloud account; recovery is not simultaneous device login | Explain device-local identity. Do not copy a 24-word recovery system or promise identity synchronization; Vault backup/rotation policy requires its own ADR |

The product difference is decisive: Manyverse replicates social content for
later offline reading and further exchange. Vault v1 serves an owner's approved
original files directly, on demand, without viewer redistribution. Local files
and already received bytes may work offline; an uncached remote item does not.
No Manyverse branding, artwork, source code or exact visual assets are imported.

### Browse-first revision: research and decisions (2026-10-19)

The user's priority is exploring other people's libraries, with an immersive
media viewer. These sources inform design choices; they are not a claim of
comparative user testing or that one visual style is objectively best.

| Primary guidance | Applied decision |
|---|---|
| [NN/g: Recognition rather than recall](https://www.nngroup.com/articles/recognition-and-recall/) | Labeled destinations, recognizable media covers, explicit Connect / Request access / Open library actions; gestures are optional, not the sole controls |
| [NN/g: Progressive disclosure](https://www.nngroup.com/articles/progressive-disclosure/) | Browsing first; connection configuration, fingerprints, source administration and metadata remain clearly labeled secondary surfaces; pending manual frames are never buried |
| [Material: Navigation bars](https://m3.material.io/components/navigation-bar/guidelines), [navigation rail accessibility](https://m3.material.io/components/navigation-rail/accessibility) | One destination model across compact bottom navigation and the wide sidebar; visible selection and labels |
| [Flutter: Accessible UI design](https://docs.flutter.dev/ui/accessibility/ui-design-and-styling) | 48px action targets, wrapping controls, dark/light contrast and 200% text checks rather than fixed-height text containers |
| [WAI: Accessible carousels/galleries](https://www.w3.org/WAI/tutorials/carousels/) | User-controlled Previous/Next, keyboard navigation and announced item position; no automatic slideshow or motion-dependent discovery |
| [Apple Photos: Viewing photos and videos](https://support.apple.com/guide/photos/view-photos-and-videos-pht8b9ba4aa9/mac) | Familiar fit/zoom/pan, arrow navigation and Escape; original media stays visually dominant, with information on demand |

Direction: warm neutral surfaces, evergreen accents, bundled Lora display
headings, restrained borders and a dark media stage. No new product plugin,
online font dependency, recommendation feed or implicit public listing is needed.
“Ready to browse” means a connected library whose authorized index was loaded;
each preview/media read still rechecks owner authorization. Local filenames and
types are filters, not an Internet search. Actual authorization failures and
disconnection replace the active grid rather than presenting stale access as valid.


## 2. Experience priorities and scope

Priority order: verified-contact consent, useful direct conversations, honest
delivery/availability, recoverable interruptions, then visual polish.

Primary journey: exchange public contact cards, compare complete fingerprints,
add each other, connect, send text, receive a persisted acknowledgement, reply,
restart and read local history. Both devices must be running and reachable.
No library publication or media grant is required to chat. A failed or timed-out
send remains unconfirmed; Retry keeps its ID to avoid a duplicate received copy.

Secondary owner/viewer journeys retain explicit publication, access approval,
paged media browse, gallery/seek/download, recovery and revocation. Chat history
and drafts must not disappear when opening a library or changing destinations.

No signup, email/password, cloud upload/recovery, groups, calls, posts, reactions,
recommendation feed, remote push, TURN setting or viewer re-sharing. Live controls
are absent unless the exact platform pair passes its gate. No original-file VOD
quality ladder implying transcoding. Public discovery is optional and incomplete.

## 3. Navigation and responsive layout

| Destination | Owns | Primary action / secondary routes |
|---|---|---|
| Chats (default) | Verified contacts, conversations, local history, unread state and delivery status | Add person; connect; send; same-ID retry; contact fingerprint; connection setup |
| Libraries | Known people's libraries, connection/access steps, optional directory | Open library; connect/request access; secondary contact/discovery controls |
| My library | Own selected sources, local grid, indexing state, explicit publishing control | Add media; Folders & imports; publication review; local photo/video |
| Activity utility | Current access requests, downloads, cache/save actions and this-run outcomes | Open globally or from My library; review/deny request; cancel transfer; save copy; delete cache |
| Identity & Settings utility | Local identity, appearance, network configuration, native availability, privacy and build limits | Open from identity control; share public contact; edit name; configure connection settings |

Chats is the first destination. Adding a verified contact permits direct text,
not private media access. Public discovery stays a separate opt-in under Libraries,
not a default global feed. Each remote library retains its owner, filters and
page independently.

Compact Android/Windows layouts use three labeled bottom destinations; medium
windows use a compact rail when useful and wide windows use a labeled sidebar.
Activity and Identity & Settings remain globally reachable utilities. Connection
setup, public discovery and source management are secondary task routes, not
additional primary tabs. Inside Chats, master/detail begins at 760 available
logical pixels when text scaling permits; narrower workspaces show the list or
one conversation with Back. The timeline and composer have bounded independent
scrolling, not a page-sized outer ListView. Preserve per-person drafts and useful
position across navigation/resize. Keep actual delivery/connection state and
uncertainty understandable; never imply read receipts.

Remote library, contact/access review, identity verification, gallery and utility
routes return to their originating context. Pending Manual frames remain
actionable through the canonical exchange queue. Activity is a persistent
navigation entry, not a claim that transient requests/download lists survive
restart. Badges count unread messages or pending local decisions; zero
connections and intentionally stopped sharing are not warnings.

## 4. Screen and interaction contracts

Every wireframe must specify entry, data visibility, states, actions, exit and
recovery. These contracts are implementation requirements, not screenshots of
features already built.

| Screen / flow | Required behavior |
|---|---|
| Welcome / local identity | Briefly explain no account, device-local identity, direct delivery and owner availability. Create identity explicitly; optional display name is not a unique username. Continue without publishing or listing publicly. Identity-creation failure stays recoverable and does not present a successful profile |
| Add person / verify | Show own identity QR and copyable identity/contact data; scan or paste the peer's supported identity data. Request camera only on Scan; paste remains available. Confirm parsed identity and compare safety information through a trusted channel. Contact exchange authenticates no network route and grants no media access |
| Manual connection | Advanced fallback exchanges complete gathered offer and answer with size/progress/error guidance. Multipart QR must show part count, completion and reset if supported by the frozen protocol. A safety phrase verifies a transcript; never present a short identity code as a complete SDP exchange or guaranteed connection |
| Sources / indexing | Use Windows folder picker or Android SAF. Preview selected source before publication. Enumerated items appear while metadata, thumbnails and hashes progress separately. Show real counts/stages; no fabricated percent/ETA when total work is unknown. Recover permission per source without removing unrelated libraries |
| Publishing review | Show selected scope, current approved contacts/rules, availability limitation and received-copy warning. Start publishing is separate from Add folder. Public listing is a separate opt-in, off for first setup. Stop publishing remains reachable from the shell while active |
| People / discovery | Distinguish locally known identity, manually verified identity, connection state and access state. Public results expose only permitted name/tags/coarse counts/identity/presence; no private filenames, paths or posters. State results are partial; empty does not mean nobody exists |
| Peer profile / access request | Before approval show only own local contact information and permitted public/handshake data. No private thumbnail placeholders based on hidden content. Show verification state and requested scope/actions; request is bounded. Pending request has an explanatory state, not repeated automatic prompts |
| Owner access review | Display requester identity and verification state, exact scope, actions and expiry from the authorization contract. Approve, deny or block deliberately. Remembered approval is a separately chosen rule for a known contact, not the default. Recheck current request state before committing; expired/already-handled requests are not actionable |
| Approved remote library | Paged photo/video grid with scope title, owner identity and availability. Search/filter/sort only authorized indexed content; say when search covers loaded pages only. Preserve position on return from a viewer; distinguish empty scope, loading, unavailable owner and revoked access |
| Photo viewer | Fit/zoom/pan, next/previous and metadata within approved scope. Loading/error/retry for missing bytes. Local already-received images may remain visible after a stop; do not claim recall. Save appears only for an allowed action |
| Video player | Play/pause, seek, elapsed/duration, audio, fullscreen and accessible controls. Separate requested seek position from confirmed playback; sparse gaps are not buffered data. Explain waiting for owner, unsupported codec, changed/missing file and permission loss distinctly. No fabricated ETA, bandwidth estimate or adaptive VOD quality menu |
| Downloads / saved files | Deliberate save destination and permission; real bytes/progress, cancel, failed destination/no-space state and supported resumability. Distinguish app-managed download, external saved copy and evictable cache. Revalidate authorization before fetching more; an expired/revoked grant cannot be bypassed by Resume |
| Session / access controls | Show direction, person, scope, state, measured rates/bytes and direct-path detail when known. Disconnect stops this session and its automatic reconnect; Revoke access stops future protected delivery; Block rejects further access/requests; Stop publishing stops serving all viewers. Removing a contact or clearing cache is not revocation |
| Settings / diagnostics | Identity/safety information, remembered access rules, cache budget/usage, saved-copy locations, uplink cap, platform availability and advanced STUN/signaling. No TURN. Diagnostics remain local/redacted and export requires user action; do not include secret keys, grants or source paths by default |

A download button is not DRM: even a browse/play-only grant cannot stop a viewer
recording or retaining received bytes. Do not imply that hiding Save protects
against copies. Grant expiry and exact supported scope choices follow the frozen
protocol; do not invent a second authorization model in UI state.

## 5. Independent state dimensions

Do not flatten these into one green Online/Connected badge. Cryptographic peer
authentication, a human's safety-number verification and owner approval are three
different facts. A signed directory presence is not a proven reachable session.

| Dimension | Required UI states | Authority / meaning |
|---|---|---|
| Identity | Known key; not manually verified; verified; mismatch | Identity proof and local verification record; same name never transfers trust to a different key |
| Signaling | Connecting; available; degraded; unavailable | Signaling adapter state; broker failure need not terminate an already working direct session |
| Direct session | Idle; connecting; authenticating; connected; interrupted; failed; intentionally disconnected | Authenticated transport; permits chat with an added contact, never implies a media grant |
| Access | Not requested; pending; approved; denied; expired; revoked; blocked | Owner-enforced grant/rule state, never a UI-only toggle |
| Local publishing | Stopped; starting; publishing; impaired; suspended where observed | Local lifecycle/storage/network evidence; publishing does not guarantee reachability from every network |
| Remote availability | Recently announced; session reachable; unavailable/unknown | Expiring presence and actual session observations; no guessed sleeping/Doze/NAT diagnosis |
| Source / item | Enumerating; enriching; ready; permission required; missing/changed; unsupported | Source/index state per item/source, not a global endless loader |
| Transfer / playback | Loading; playing/viewing; buffering; seeking; saving; interrupted; complete; failed; cancelled | Actual delivery/player events and verified byte availability |
| Message delivery | Sending; delivered; unconfirmed; received | Delivered requires recipient persistence; unread is local only, not a remote read receipt |

### Recovery and attention rules

| Situation | User-facing explanation | Next action and boundary |
|---|---|---|
| No contacts yet | Your library stays on this device. Add someone to connect | Add person or add folder; no fake sample people/media |
| No direct route | A direct connection could not be established | Retry, coordinate with owner, or try a different permitted network; no certain NAT claim or promise manual signaling repairs the route |
| Directory/signaling unavailable | Discovery or new connections are temporarily unavailable | Inspect endpoint status/retry; keep usable local content and established sessions accessible |
| Owner stops responding | Owner unavailable; new bytes cannot be fetched | Preserve position/verified partial data. Resume only when execution, route and authorization permit; no cloud fallback |
| User disconnects | Disconnected by you | Explicit Connect/Resume required before further transfer; no background reconnect loop |
| Access revoked/expired | Access ended; no further content will be fetched | End protected requests; explain existing copies remain. A fresh permitted request is deliberate, never an automatic prompt loop |
| Storage permission lost | Vault can no longer read this source | Reselect/re-authorize the source with OS UI; no repeated global storage permission request |
| Identity mismatch | This identity differs from the saved contact | Stop reuse of trust/approval and offer independent verification; never silently merge by display name |
| Cache/destination full | Not enough storage for this operation | Offer cache management or another save destination; never delete originals or saved files to make automatic room |

Persisted rules survive restart; transient UI must reconcile with real services
before enabling protected actions. Restore useful navigation/playback position,
not a stale Approved badge. Owner revocation stops new bytes even if the remote
notice is lost. UI acknowledgement is not proof of enforcement.

Use one contextual status strip with a Details action, plus local inline errors.
Do not stack banners for the same outage. Use persistent rows for access requests
and transfer failures. Announce meaningful changes to assistive technology without
announcing every throughput sample. No recurring alarm for zero peers or an
intentionally stopped publisher.

## 6. Consent, publication and copy language

Use concrete verbs with distinct consequences:

- **Add folder:** choose what Vault may read; does not start serving or public listing.
- **Start publishing:** serve selected content to approved viewers while available.
- **List publicly:** publish a preview of exactly name, selected tags, coarse counts,
  stable identity and presence. Explain public/test services may observe metadata;
  disabling listing stops new announcements, not copies of prior announcements.
- **Approve access:** authorize the stated identity, scope/actions and expiry.
- **Remember approval:** deliberately persist a bounded owner-controlled rule for
  a known contact; never label this unconditional forever access.
- **Disconnect:** stop this session and automatic reconnect until explicitly allowed.
- **Revoke access:** stop further delivery and invalidate the affected grant/rule;
  existing downloaded, cached or captured bytes cannot be recalled.
- **Block:** reject further access and requests for that identity; not remote deletion.
- **Clear cache:** delete local temporary copies only, not originals or saved files.

Use the received-copy warning at first publish, access review when scope changes,
and revoke confirmation; keep a short explanation available later. Confirm
consequential revoke/block/stop-all with affected people/scope, not vague Are you
sure? dialogs. Do not offer Undo until the security state has a real safe reversal;
re-approval is not restoring a revoked token. Normal play/seek needs no dialog.

## 7. Platform behavior and visual system

### Android

Request SAF, camera, notification and other required permissions at the action
that needs them, with denied/restricted recovery. Do not ask for blanket storage
or battery exemptions during onboarding. Publishing/transfer start, notification
and Stop behavior must reflect the service type and execution modes established
by Phase 0. Explain any degraded mode after denied notification permission from
actual tested OS behavior, not a presumed universal rule. No always-online claim.
Handle rotation, system Back, app interruption and large text without lost state.

### Windows

Keyboard-complete navigation with visible focus; Enter activates selected content,
Escape exits transient/fullscreen surfaces, Space toggles playback only when focus
is not editing or using another control. Right-click actions duplicate visible
commands; hover is never the only route. Use native folder/save dialogs. Keep
sidebar/detail proportions sensible on resize and DPI scaling.

Offer explicit Close to tray versus Quit behavior, explained before first hidden
publishing. Tray exposes current local publishing state, Open, Stop publishing
and Quit. Quit stops serving; autostart is opt-in and must respect persisted user
stop/disconnect intent. Sleep/resume shows interruption, not false reachability.

### Shared visual direction

Calm, media-first surfaces; original thumbnails dominate the library, not dashboard
metrics. Use a neutral light/dark palette with one action accent, semantic status
colors plus labels/icons, modest borders and restrained elevation. No copied
Manyverse palette/branding, wallpaper gradients or connectivity gauges. Avoid a
floating action button whose meaning changes unpredictably between destinations.

Implemented shared tokens use 4/8-based spacing, padded 48px actions, neutral
light/dark surfaces and an evergreen action accent. Bundled Lora is reserved for
display headings; functional text stays sans-serif. Native Material controls
retain focus and selection behavior. Media does not auto-advance.

Baseline targets: 48 logical-pixel touch targets; at least WCAG AA 4.5:1 normal
text / 3:1 large text and 3:1 essential control contrast; keyboard focus and screen
reader labels; 200% text scaling without loss of essential actions; reduced
motion; localization-safe layouts and RTL. Accessibility starts in wireframes,
not Phase 6. Phase 6 verifies and hardens it on native assistive technology.

## 8. Design-to-service boundaries

| Owner | Design/implementation responsibility |
|---|---|
| apps/vault | Routing, injected feature state/controllers and OS integration; permission/tray surfaces |
| vault_ui | Tokens/components, responsive shell, consent/status presentation and accessible interactions |
| vault_identity / vault_protocol | Identity/authentication/grant facts; UI cannot mint authority or decide trust from names |
| vault_directory / vault_signaling / vault_net | Expiring public data, endpoint state and authenticated direct-session facts |
| vault_media_index | Source capabilities/permission outcomes and staged index progress |
| vault_delivery / vault_player | Actual byte/cancellation/cache/transfer and playback state; optional live remains separate |

View state derives from injected service events and durable data, not duplicate
permission booleans in widgets. Screen contracts specify command, in-flight state,
cancellation, service outcome and recovery. Ignore obsolete results after route,
peer, content generation or seek changes. UI never imports flutter_webrtc; the
single native adapter boundary and pure-Dart identity/protocol remain unchanged.

## 9. UI/UX work packages and gates

These UX labels do not renumber or waive product Phases 0-7. The
[browser study](../design/vault/README.md) records its current coverage and observed
checks; its existence does not mean every work package or acceptance criterion passed.

| Work package | Deliverables and exit criteria | Product dependency |
|---|---|---|
| UX-0: scope and model | This plan, sourced inspiration choices, screen inventory and independent state model; reconcile terminology with latest ADRs | Can proceed during Phase 0; this document is the baseline, not validation |
| UX-1: journeys and low-fidelity wireframes | Both platform roles; every section 4 screen, section 5 failure/recovery and section 6 consequential action. Annotate private/public visibility and Back/exit behavior. Every action has a service owner | Can proceed during Phase 0; flag unresolved OS/protocol details explicitly |
| UX-2: visual and responsive specification | Tokens, light/dark, compact/medium/wide layouts, component states and keyboard/assistive interaction spec. Show 360px Android and narrow/wide Windows examples plus large text | Native UI implementation is permitted by section6.2; protocol/transport functionality remains gated |
| UX-3: clickable design walkthrough | Linked happy path and no-route, denied access, revoked permission, interrupted seek, explicit disconnect and revocation branches. External simulations labeled as such; never used as native feasibility evidence | Prototype may run during Phase 0; real behaviors remain gated |
| UX-3a: installable native interface preview | Shared Flutter screens, real local media selection/viewing/playback/save, non-secret UI preferences and labeled consent/failure simulations; document APK and actual native smoke observations | User-directed interface-first exception, main section6.2; no Phase0 transport checks required for this UI task |
| UX-4: production shell and identity/session slice | Implement navigation, local identity/contact verification and truthful direct-session status; exercise actual Android/Windows service state | Main Phase 0 core gates, then Phase 1 identity/protocol/net contracts |
| UX-5: sources, consent and browsing | Integrate sources/progressive index, public-listing review, access review and paged authorized media; no private content before approval | Main Phases 2-3; no public discovery dependency for a known-contact session |
| UX-6: photo/video/download recovery | Real photo and video surfaces, seek/cache/save controls and interrupted/revoked paths on both platform roles | Main Phase 4 plus its player/storage gates |
| UX-7: release hardening | Native accessibility, localization, tray/autostart, lifecycle recovery and diagnostics/privacy review; no fake online interval in soak results | Main Phase 6; optional live UI only under Phase 5's separate gate |

Review UX-3 with people unfamiliar with Vault, including an owner and viewer.
Record task outcome, misunderstandings and interventions locally with consent; no
product analytics. Pass when participants can identify what is shared, who may
access it, why uncached offline playback fails, and what revoke/disconnect each
do, without facilitator correction. A failure revises the flow and is retried;
completion speed is not evidence of correct understanding. Record actual sample
and limitations, not a statistically representative usability claim.

## 10. Acceptance scenarios and evidence

For UX-1/3, walk through annotated frames/prototype; for UX-4 onward, exercise the
real app on Android and Windows with the service owners' integration evidence.
UI visibility cannot prove network authorization, no-relay routing or cancellation.
Link UI observations to those lower-layer results; do not replace them with badges.

1. Fresh viewer skips source selection/public listing, adds a person and reaches
   a requestable authenticated session without registering an account.
2. Owner adds a folder without serving it; first publish reviews scope and copy
   limits. Public listing remains off unless separately chosen and confirmed.
3. Same-name different-key person does not inherit verification or remembered
   approval. An identity mismatch has an explicit blocking verification path.
4. Unapproved viewer receives no protected index/poster/media bytes; approved
   viewer sees only granted scope. UI review and underlying rejection evidence agree.
5. Both Android->Windows and Windows->Android sessions show photos, play/seek a
   supported original video and recover position after a recoverable interruption.
6. No-route, endpoint outage and unavailable-owner states offer accurate distinct
   actions; no NAT guess, cloud fallback, remote push or manual-signaling promise.
7. User Disconnect prevents automatic reconnect/transfer across navigation and
   restart until explicitly allowed. Network recovery alone does not override it.
8. Owner Revoke ends new protected delivery, including after restart/replayed
   grants; received-copy wording is accurate even if the viewer misses the notice.
9. SAF permission loss, changed/deleted source, unsupported media and full save
   destination each recover without deleting unrelated sources or originals.
10. Cancelling a download/seek retires its old operation; late progress or frames
    cannot overwrite the new request. Resume requires current authorization and
    verified partial data; cancellation UI matches observed service completion.
11. Storage view distinguishes temporary cache, app metadata and app-managed
    saved files; external copies are labeled outside managed storage accounting.
    Clearing cache neither deletes saved originals nor promises remote deletion.
12. Keyboard-only Windows and Android TalkBack/Windows Narrator walkthroughs can
    complete connect, approve, browse, seek and stop; focus returns sensibly after
    dialogs. Compact/wide, light/dark, 200% text and RTL retain essential actions.
13. Windows tray/quit and Android start/stop/notification flows match tested
    lifecycle modes; user stop persists and sleeping/suspended time is not online.
14. Optional live, TURN, Bluetooth, automatic LAN discovery, room/pub and social
    features are absent from v1 navigation unless the authoritative scope changes.

For each executed scenario record build/revision, platform/device, source/media,
network topology, steps, observed result and limitation. No sample-data screen,
prototype or empty-template build counts as native feature acceptance.

## 11. Decisions to reconcile before detailed UI implementation

- Android supported publishing/notification/service modes: Phase 0 physical-device
  evidence decides wording and enabled actions, not a designer's persistent badge.
- Identity backup/rotation and contact/QR payload: follow identity/protocol ADRs;
  do not invent recovery words, multi-device linking, hosted invite links or
  routable short codes. [ADR 0003](adr/0003-crypto-and-wire-profile.md) explicitly
  leaves backup/rotation policy open.
- Grant resource/action/expiry choices and remembered-rule storage: consume the
  frozen protocol and persisted authorization behavior; keep visible scope exact.
- Player/cache and SAF provider capabilities: enable only measured operations;
  do not disguise unsupported/non-seekable providers as successful playback.
- Final tokens and responsive thresholds: validate at UX-2/3; they can change
  without changing consent, direct-only delivery or Phase 0 feasibility gates.

Next design review: walk through the browser study as owner and viewer, starting
with a known contact rather than public discovery. Validate consent wording,
responsive layouts and failure recovery against the screen contracts above.
