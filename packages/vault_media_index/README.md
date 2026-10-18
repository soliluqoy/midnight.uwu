# vault_vault_media_index

Shared-folder scanner, platform directory watchers, BLAKE3 hashing, container-header metadata parsing, background thumbnail extraction, drift index database.

## Contract

- Never decode media to inspect it; parse container headers only.
- Never touch the filesystem from the UI isolate.

