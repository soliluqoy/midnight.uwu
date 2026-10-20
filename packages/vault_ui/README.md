# vault_ui

Shared Flutter design system and separate historical interface-study screens.
Registered as a workspace package; implementation is in `lib/`.

- `components.dart`: warm-neutral light/dark and high-contrast semantic palettes,
  evergreen accents, bundled `VaultSerif` display headings, padded actions,
  responsive headings, section surfaces and bounded local thumbnails.
- The historical Library, People, Activity and Settings study screens share
  `StudyController`. Production owns its Chats / Libraries / My library shell,
  contextual utilities and gallery; these study screens are not its runtime.
- `StudyController` is explicitly presentation/walkthrough state, not an identity,
  transport, authorization or cache service. It contains no key or grant secret.
- Remote sample visibility requires the approved scope plus simulated publication,
  direct-session availability and source access. Identity comparison and public
  listing choices remain per perspective. Network recovery does not override an
  explicit disconnect. Tests protect these interface invariants, not P2P security.

Run from this package:

```powershell
flutter test --no-pub
```

`theme_accessibility_test.dart` checks readable text/action/error color pairings
in both light/dark themes, including the stronger high-contrast text target.
These numeric invariants are not native screen-reader or usability evidence.

OS selection/export, preferences and native video lifecycle belong to
[apps/vault](../../apps/vault/README.md). Pure-Dart identity/protocol and the single
WebRTC adapter boundary remain unchanged. The native UI is permitted before Phase
0 completion by the user-directed [main plan section6.2](../../P2P_VIDEO_SHARE_BUILD_PLAN.md#62-interface-first-sequencing-revision).

Follow the [UI/UX build plan](../../docs/UI_UX_BUILD_PLAN.md) for screen contracts,
consent/copy language, accessibility targets and remaining acceptance criteria.
Do not interpret the preview's visual state as actual security enforcement.
