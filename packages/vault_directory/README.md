# vault_vault_directory

Serverless presence directory: 30 s announce heartbeat, blake3 shard function, bloom-filter queries, 60 s gossip fan-out, SQLite presence cache with expiry, result ranking.

## Contract

- No central index, no operator, no telemetry.
- Expired entries are swept every 15 s; announcements are never retained on a relay.

