# Documentation

Start with the [quickstart](../README.md#quickstart).

## Current guides

- [Concepts](CONCEPTS.md): tasks, notes, files, slices, reminders, appointments,
  Calendar, Attention and customer records, with a rollout example
- [Operations](OPERATIONS.md): authentication, configuration, optional services and backups
- [Development](DEVELOPMENT.md): toolchains, builds, tests and architecture
- [CLI](../cli/README.md) and [protocol reference](../protocol/README.md)
- [Tailscale proxy](../services/auth/tailscale-proxy/README.md),
  [Search](../services/bots/nrc-search/README.md),
  [AI](../services/bots/nrc-ai/README.md), [Metrics](../services/bots/nrc-metrics/README.md)
- [Publish](../services/bots/nrc-publish/README.md): public articles from reviewed
  copies of Markdown notes, with a private review interface and draft CLI

## Detailed engineering references

- [Sharded persistence](SHARDED_PERSISTENCE.md) and [attachment GC](ATTACHMENT_GC.md)
- [Historical legacy migration procedure](SHARDED_PERSISTENCE_MIGRATION.md):
  only for its pinned historical binary, never the current one
- [Request correlation](REQUEST_CORRELATION.md) and [error handling](ERROR_HANDLING.md)
- [Test matrix](TEST_MATRIX.md), [simulation architecture](DETERMINISTIC_SIMULATOR_PLAN.md)
  and [simulation budget](DETERMINISTIC_SIMULATION_BUDGET.md)
- [Benchmark commands and measurements](BENCHMARKS.md)
