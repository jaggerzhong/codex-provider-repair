# codex-provider-repair

One shell script to repair your Codex session history after switching providers.

When you change `model_provider` in `~/.codex/config.toml` (e.g. from one provider to another), your old chat sessions disappear from the sidebar — because every session rollout file, the SQLite `threads` table and the local catalog still record the **old** provider. This tool rewrites the provider across all four data sources so your history comes back.

Zero dependencies. Only macOS built-ins: `bash` + `python3` + `tar`.

Inspired by [OC-Codex](https://github.com/yiye-github/OC-Codex) (`Repair-Codex-Chat-History.ps1`).

## Usage

```bash
./codex-migrate.sh old-provider                    # migrate sessions from provider "old-provider" to the current one
./codex-migrate.sh old-provider-a old-provider-b   # migrate from multiple old providers
./codex-migrate.sh                    # no args = migrate from every provider != current
./codex-migrate.sh --dry-run          # preview only, changes nothing
```

The **target** provider is auto-detected from `model_provider` in `~/.codex/config.toml` — no configuration needed.

### Example

```bash
$ ./codex-migrate.sh old-provider
目标 provider: current-provider  来源: old-provider
备份: /Users/you/codex-migration-backup/codex-backup-20260812-181301.tar.gz
[1/4] rollout 重写 215/215
[2/4] threads 同步 215 行, 回填 45 行
[3/4] session_index 重建 301 条
[4/4] catalog 重建 301 行
```

## What it does

| # | Data source | Action |
|---|-------------|--------|
| 1 | Rollout files (`~/.codex/sessions|archived_sessions/rollout-*.jsonl`) | Rewrite every structured `model_provider` occurrence: the first `session_meta` line, *resumed* `session_meta` lines appended mid-file, and each turn's `thread_settings.model_provider_id`. Historical text (e.g. error messages containing provider URLs) is left untouched |
| 2 | `state_5.sqlite` → `threads` | Update provider for matching rows, backfill missing rows from rollout files |
| 3 | `session_index.jsonl` | Rebuild with every thread (merge, never delete) |
| 4 | `sqlite/codex-dev.db` → `local_thread_catalog` | Rebuild the sidebar catalog (with `observation_sequence`) |

Every run **auto-backs up** to `~/codex-migration-backup/codex-backup-<timestamp>.tar.gz` (config, auth, SQLite files + all rollout files). Restore with:

```bash
tar -xzf ~/codex-migration-backup/codex-backup-<timestamp>.tar.gz -C ~
```

## Safety

- **Quit ChatGPT.app / Codex / Zed before migrating** — the script refuses to run while Codex processes hold the SQLite locks (skip with `CODEX_SKIP_PRECHECK=1`, or use `--dry-run`).
- Idempotent — safe to re-run; already-synced data is skipped.
- Partial migration is supported: only the providers you name are rewritten; backfilled `threads` rows keep the rollout's actual provider.

## FAQ

**I get "Fix config.toml: Model provider \`old-provider\` not found" when resuming a thread**

Your rollout files are fine — the ChatGPT/Codex app re-writes stale provider values into `state_5.sqlite → threads` from its own cache while it is running, so a few rows can flip back to the old provider even after a successful migration. Re-run the script to re-sync:

```bash
# quit ChatGPT.app first, then:
./codex-migrate.sh old-provider
```

This heals the stale `threads` rows without touching your rollout files. If the same thread breaks again, the app was running during the previous run — the pre-check blocks this by default, so always quit the app before migrating.

## Install

```bash
# standalone use
curl -O https://raw.githubusercontent.com/jaggerzhong/codex-provider-repair/main/codex-migrate.sh
chmod +x codex-migrate.sh
./codex-migrate.sh --dry-run
```

## License

MIT
