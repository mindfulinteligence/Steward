# Memory Embedding Performance

## Goal

Keep embedding backfills from monopolizing Ollama or keeping Neon active after
every deployment while ensuring changed memories eventually receive the
current model's embedding.

## Implementation

- Store a SHA-256 fingerprint of normalized memory text plus model name with
  every embedding.
- Use a database anti-join to avoid loading the full embedding ID set into the
  application.
- Embed up to 32 memories per bounded batch request and bulk upsert successes.
- Delay the initial backfill by five seconds so application startup is not
  coupled to corpus size.
- Reprocess rows with missing or stale fingerprints.

## Follow-Up

- Add a supervised queue with configurable rate limits and exponential retry
  backoff for very large tenants.
- Add progress gauges for pending, completed, and quarantined embeddings.
- Move scheduled backfills to a dedicated worker when corpus size exceeds the
  application compute budget.

## Verification

- Fingerprints are deterministic and change when source text or model changes.
- Batch failures do not prevent successful rows in the same batch from being
  persisted.
- Deployments run the backfill asynchronously after the configured delay.
