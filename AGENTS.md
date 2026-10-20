# Repository guidance

## Task focus

- Always focus on the user's active task and carry it through to completion.
- Make only changes needed for that task. Avoid unrelated refactors, cleanup,
  dependency updates, research, or feature work.
- Preserve existing user changes. Inspect the working tree before editing and
  never revert unrelated work.
- Resolve routine implementation choices from repository context. Ask for
  clarification only when missing information materially blocks progress.
- Keep progress updates and final responses concise, with the outcome,
  relevant verification, and any remaining blocker.

## Project context

Vault is a personal photo/video library targeting Android and Windows, with
local identities, explicit owner approval, and direct WebRTC delivery.

- Read `README.md` for current status and reproduction commands.
- Treat `P2P_VIDEO_SHARE_BUILD_PLAN.md` as the authoritative product and build
  plan. Consult the relevant ADRs and package README before implementation.
- Use `docs/FILE_TREE.md` to distinguish implemented components from plans.
- Phase 0 probes live in `spikes/phase0_probe/` and
  `tools/interop_harness/`. Read their local instructions before working there.
- Production app and library paths are `apps/vault/` and `packages/vault_*`.
  Do not assume a directory or README means its implementation exists.

## Architectural constraints

- No operated backend, accounts, API keys, telemetry, crash reporting, or
  remote configuration services.
- Media delivery is direct; v1 excludes TURN, including user-supplied TURN.
- Keep `vault_identity` and `vault_protocol` pure Dart.
- The planned production WebRTC boundary is
  `packages/vault_net/lib/src/webrtc_adapter.dart`.
- Respect feasibility gates. Tool installation, empty-template builds, and
  synthetic spike results do not establish product readiness or clear Phase 1.

## Development and verification

- Use PowerShell on this Windows workspace. Prefer existing verification
  scripts over reinstalling or changing the machine toolchain.
- Melos configuration is in the root `pubspec.yaml`; use the pinned local
  runner with `dart run melos`, not a global installation or `melos.yaml`.
- Register new workspace members explicitly and use `resolution: workspace`.
- Follow `analysis_options.yaml` and format changed Dart files.
- Run checks appropriate to the change. Root tooling checks are:

  ```powershell
  dart pub get
  dart run melos bootstrap
  dart run melos run analyze
  dart run melos run format
  ```

- For setup/verifier changes, also run:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File tools/setup/test-verifier.ps1
  ```

- Run component-specific checks from the relevant README when changing probes
  or the interop harness. Root analysis excludes those directories.
- Report what was actually checked and the limits of the evidence. Do not
  claim native builds, physical-device behavior, or feature gates passed
  without observing their results.
