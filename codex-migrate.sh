#!/usr/bin/env bash
# =============================================================================
# codex-migrate.sh — macOS Codex 会话 Provider 迁移（极简版）
#
# 用法:
#   ./codex-migrate.sh [旧provider...]    # 把指定旧 provider 的会话迁移到当前 provider
#   ./codex-migrate.sh                    # 不传参 = 迁移所有非当前 provider 的会话
#   ./codex-migrate.sh --dry-run          # 预演，不修改任何数据
#
# 目标 provider 自动从 ~/.codex/config.toml 的 model_provider 检测。
# 原理参考 OC-Codex (Repair-Codex-Chat-History.ps1):
#   1) 重写 rollout 文件内所有结构化 provider 字段（首行 + 续传追加的 session_meta +
#      thread_settings.model_provider_id；error 等历史文本不动）
#   2) 更新 state_5.sqlite threads 表（并回填缺失记录）
#   3) 重建 session_index.jsonl
#   4) 重建 sqlite/codex-dev.db 的 local_thread_catalog（侧边栏数据源）
# 零依赖：仅用 macOS 自带的 bash + python3 + tar。
# 执行前请先退出 ChatGPT.app / Codex / Zed。
# =============================================================================
set -euo pipefail

CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
DRY=0
FROM=()
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)
      sed -n '5,12p' "$0"
      exit 0 ;;
    *) FROM+=("$a") ;;
  esac
done

# 0) 前置检查：Codex/ChatGPT 进程占用数据库时不操作（--dry-run 跳过；CI 可用 CODEX_SKIP_PRECHECK=1 跳过）
if [ "$DRY" = 0 ] && [ -z "${CODEX_SKIP_PRECHECK:-}" ]; then
  RUNNING=$(pgrep -fil 'codex|chatgpt' 2>/dev/null | grep -viE 'grep|codex-migrate|workbuddy' || true)
  if [ -n "$RUNNING" ]; then
    echo "⚠ 检测到 Codex 相关进程正在运行，数据库可能被占用:"
    echo "$RUNNING" | head -5
    echo "请先退出 ChatGPT.app / Codex / Zed 后再执行（或加 --dry-run 预演）。"
    exit 1
  fi
fi

# 1) 从 config.toml 自动检测目标 provider
TARGET=$(/usr/bin/python3 - "$CODEX_DIR" <<'PY'
import re, sys
try:
    s = open(sys.argv[1] + "/config.toml", encoding="utf-8").read()
except FileNotFoundError:
    s = ""
m = re.search(r'^\s*model_provider\s*=\s*"([^"]+)"', s, re.M)
print(m.group(1) if m else "")
PY
)
if [ -z "$TARGET" ]; then
  echo "⚠ 无法从 $CODEX_DIR/config.toml 检测到 model_provider，请先确认配置。"
  exit 1
fi
if [ ${#FROM[@]} -eq 0 ]; then FROM_DESC="全部非目标 provider"; else FROM_DESC="${FROM[*]}"; fi
echo "目标 provider: $TARGET  来源: $FROM_DESC"

# 2) 安全备份（关键文件 + 全部 rollout 文件）
if [ "$DRY" = 0 ]; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  BACKUP_DIR="$HOME/codex-migration-backup"
  mkdir -p "$BACKUP_DIR"
  OUT="$BACKUP_DIR/codex-backup-$STAMP.tar.gz"
  LIST=$(mktemp)
  (
    cd "$HOME" && for f in .codex/state_5.sqlite .codex/state_5.sqlite-wal \
      .codex/state_5.sqlite-shm .codex/session_index.jsonl .codex/config.toml \
      .codex/auth.json .codex/sqlite/codex-dev.db .codex/sqlite/codex-dev.db-wal \
      .codex/sqlite/codex-dev.db-shm; do
      [ -f "$f" ] && echo "$f"
    done
    # rollout 文件：统一转为相对 $HOME 的路径（兼容自定义 CODEX_DIR）
    if [ -d "$CODEX_DIR" ]; then
      (cd "$CODEX_DIR" && for d in sessions archived_sessions; do
        if [ -d "$d" ]; then find "$d" -name 'rollout-*.jsonl' 2>/dev/null; fi
      done) | while IFS= read -r p; do
        abs="$CODEX_DIR/$p"
        case "$abs" in
          "$HOME"/*) echo "${abs#"$HOME"/}" ;;
        esac
      done
    fi
  ) > "$LIST"
  if tar -C "$HOME" -czf "$OUT" -T "$LIST" 2>/dev/null; then
    echo "备份: $OUT"
  else
    echo "⚠ 备份失败，继续执行（风险自负）。"
  fi
  rm -f "$LIST"
fi

# 3) 迁移（rollout 重写 → threads 同步/回填 → session_index → catalog）
PY_ARGS=("$CODEX_DIR" "$TARGET" "$DRY")
if [ ${#FROM[@]} -gt 0 ]; then PY_ARGS+=("${FROM[@]}"); fi
/usr/bin/python3 - "${PY_ARGS[@]}" <<'PY'
import json, os, re, sqlite3, sys, tempfile, time
import datetime

CODEX_DIR, TARGET, DRY = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
FROM = sys.argv[4:]
SESSIONS = os.path.join(CODEX_DIR, "sessions")
ARCHIVED = os.path.join(CODEX_DIR, "archived_sessions")
STATE_DB = os.path.join(CODEX_DIR, "state_5.sqlite")
CATALOG_DB = os.path.join(CODEX_DIR, "sqlite", "codex-dev.db")
INDEX = os.path.join(CODEX_DIR, "session_index.jsonl")

def parse_iso_ms(s):
    if not s: return None
    try:
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

def iso_from_ms(ms):
    if not ms: return None
    try:
        return datetime.datetime.fromtimestamp(ms / 1000, tz=datetime.timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
        return None

def find_rollouts():
    out = []
    for base in (SESSIONS, ARCHIVED):
        if os.path.isdir(base):
            for root, _, fs in os.walk(base):
                for f in fs:
                    if f.startswith("rollout-") and f.endswith(".jsonl"):
                        out.append(os.path.join(root, f))
    return out

def rid_from_path(p):
    parts = os.path.basename(p).replace("rollout-", "").replace(".jsonl", "").split("-")
    return "-".join(parts[-5:]) if len(parts) >= 5 else "-".join(parts)

def scan():
    info = {}
    for f in find_rollouts():
        rid = rid_from_path(f)
        try:
            with open(f, encoding="utf-8") as fh:
                lines = fh.readlines()
            obj = json.loads(lines[0])
            inner = set()
            for line in lines[1:]:               # 内部字段也可能记录旧 provider（续传追加的 session_meta / thread_settings）
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                p = o.get("payload")
                if not isinstance(p, dict):
                    continue
                if p.get("model_provider"):
                    inner.add(p["model_provider"])
                ts = p.get("thread_settings")
                if isinstance(ts, dict) and ts.get("model_provider_id"):
                    inner.add(ts["model_provider_id"])
            info[rid] = {"path": f, "provider": obj.get("payload", {}).get("model_provider"),
                         "meta": obj.get("payload", {}), "inner": inner}
        except Exception as e:
            info[rid] = {"path": f, "provider": None, "meta": None, "error": str(e)}
    return info

def fix_provider(obj, olds, target):
    """结构化替换旧 provider。只动 payload.model_provider 与 thread_settings.model_provider_id，
    保留历史文本（如 error.message 里的 URL）。olds=None 表示替换所有 != target 的值。"""
    p = obj.get("payload")
    if not isinstance(p, dict):
        return False
    def hit(v):
        return isinstance(v, str) and v != target and (olds is None or v in olds)
    changed = False
    if hit(p.get("model_provider")):
        p["model_provider"] = target; changed = True
    ts = p.get("thread_settings")
    if isinstance(ts, dict) and hit(ts.get("model_provider_id")):
        ts["model_provider_id"] = target; changed = True
    return changed

def rewrite(path, olds, target):
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    out, cnt = [], 0
    for line in lines:
        s = line.rstrip("\n")
        if not s:
            out.append("\n"); continue
        try:
            obj = json.loads(s)
        except Exception:
            out.append(line); continue          # 损坏行原样保留
        if fix_provider(obj, olds, target):
            cnt += 1
            s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
        out.append(s + "\n")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(out)
    os.replace(tmp, path)
    return cnt

def connect_state():
    conn = sqlite3.connect(STATE_DB)
    conn.execute("PRAGMA busy_timeout=5000")
    return conn

def load_threads(conn):
    cur = conn.cursor()
    cur.execute("SELECT id, rollout_path, model_provider, created_at, updated_at, created_at_ms,"
                " updated_at_ms, title, name, first_user_message, source, thread_source, cwd,"
                " git_branch, recency_at_ms, archived FROM threads")
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]

def upsert_thread(conn, t):
    cur = conn.cursor()
    cur.execute(
        """INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider,
           cwd, cli_version, title, created_at_ms, updated_at_ms, thread_source, sandbox_policy, approval_mode)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(id) DO UPDATE SET
             model_provider=excluded.model_provider, rollout_path=excluded.rollout_path,
             updated_at=excluded.updated_at, updated_at_ms=excluded.updated_at_ms""",
        (t["id"], t["rollout_path"], t["created_at"], t["updated_at"], t["source"],
         t["model_provider"], t.get("cwd") or "", t.get("cli_version") or "", t.get("title", ""),
         t["created_at_ms"], t["updated_at_ms"], t.get("thread_source"),
         t.get("sandbox_policy", '{"type":"read-only"}'), t.get("approval_mode", "on-request")))
    conn.commit()

def backfill(conn, info, target):
    existing = {t["id"] for t in load_threads(conn)}
    added = 0
    for rid, i in info.items():
        if rid in existing or i.get("error") or not i.get("meta"):
            continue
        ms = parse_iso_ms(i["meta"].get("timestamp"))
        if ms is None:
            ms = int(os.path.getmtime(i["path"]) * 1000)   # 无时间戳时用文件 mtime 兜底
        upsert_thread(conn, {"id": rid, "rollout_path": i["path"], "created_at": ms // 1000,
                             "updated_at": ms // 1000, "created_at_ms": ms, "updated_at_ms": ms,
                             "source": "cli", "model_provider": i["provider"] or target,
                             "cwd": i["meta"].get("cwd"),
                             "cli_version": i["meta"].get("cli_version"), "title": "", "thread_source": "user"})
        added += 1
    return added

def rebuild_index(conn):
    existing = {}
    if os.path.exists(INDEX):
        with open(INDEX, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try: existing[json.loads(line)["id"]] = json.loads(line)
                    except Exception: pass
    changed = False
    for t in load_threads(conn):
        if t["id"] in existing: continue
        title = t.get("title") or t.get("name") or t.get("first_user_message") or t["id"]
        updated = iso_from_ms(t.get("updated_at_ms") or t.get("updated_at") or 0) or ""
        existing[t["id"]] = {"id": t["id"], "thread_name": title, "updated_at": updated}
        changed = True
    entries = sorted(existing.values(), key=lambda e: e.get("updated_at", ""), reverse=True)
    if changed:
        fd, tmp = tempfile.mkstemp(dir=CODEX_DIR, suffix=".jsonl")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for e in entries:
                fh.write(json.dumps(e, ensure_ascii=False) + "\n")
        os.replace(tmp, INDEX)
    return changed, len(entries)

def rebuild_catalog():
    conn = sqlite3.connect(CATALOG_DB)
    conn.execute("PRAGMA busy_timeout=5000")
    cur = conn.cursor()
    cur.execute("SELECT host_id FROM local_thread_catalog_hosts LIMIT 1")
    hosts = cur.fetchall()
    host_id = hosts[0][0] if hosts else "local"
    cur.execute("DELETE FROM local_thread_catalog")
    cur.execute("SELECT observation_sequence FROM local_thread_catalog_sync_state WHERE host_id=?", (host_id,))
    row = cur.fetchone()
    seq = row[0] if row and row[0] else 0
    sconn = connect_state()
    threads = load_threads(sconn)
    sconn.close()
    n = 0
    for t in threads:
        seq += 1
        display = t.get("title") or t.get("name") or t.get("first_user_message") or t["id"]
        src_kind = "cli" if t.get("source") in ("cli", "exec", "unknown", None) else str(t.get("source"))
        created = float(t.get("created_at_ms") or t.get("created_at") or 0) / 1000.0
        updated = float(t.get("updated_at_ms") or t.get("updated_at") or 0) / 1000.0
        recency = float(t.get("recency_at_ms") or t.get("updated_at_ms") or t.get("updated_at") or 0) / 1000.0
        cur.execute("INSERT INTO local_thread_catalog (host_id, thread_id, display_title, source_created_at,"
                    " source_updated_at, cwd, source_kind, source_detail, model_provider, git_branch,"
                    " observation_sequence, missing_candidate, thread_source, source_recency_at)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?,?)",
                    (host_id, t["id"], display, created, updated, t.get("cwd"), src_kind,
                     t.get("rollout_path"), t.get("model_provider"), t.get("git_branch"), seq,
                     t.get("thread_source"), recency))
        n += 1
    # 关键：重建后必须标记"初始构建完成"并更新观察水位，
    # 否则 app 认为本地索引从未构建完成，重启后侧边栏不显示任何历史
    cur.execute("UPDATE local_thread_catalog_sync_state SET initial_build_complete=1,"
                " observation_sequence=?, watermark_updated_at=?, last_full_reconciled_at=?"
                " WHERE host_id=?", (seq, time.time(), int(time.time()), host_id))
    conn.commit()
    conn.close()
    return host_id, n

# ---- main ----
info = scan()
total = len(info)
if not total:
    print("未找到 rollout 文件，退出。")
    sys.exit(0)
prov = {}
for i in info.values():
    prov[i["provider"] if i["provider"] else "(missing)"] = prov.get(i["provider"] if i["provider"] else "(missing)", 0) + 1
print(f"rollout 文件 {total} 个: {prov}")

def match(i):
    """判断是否需要迁移：首行或内部结构化字段含旧 provider 都算。"""
    if i.get("error"): return False
    cand = set(i.get("inner") or ())
    if i["provider"]: cand.add(i["provider"])
    if not cand: return not FROM              # provider 完全缺失: 仅全量迁移时修复
    if not FROM: return any(p != TARGET for p in cand)   # 全量: 所有非目标
    return bool(cand & set(FROM))             # 指定来源

to_change = [i for i in info.values() if match(i)]
all_old = sorted({p for i in to_change for p in ((i.get("inner") or set()) | ({i["provider"]} if i["provider"] else set()))})
print(f"需迁移: {len(to_change)} 个（{TARGET} ← {all_old if all_old else '-'}）")

if DRY:
    for i in to_change[:10]:
        oldv = sorted((set(i.get("inner") or ()) | ({i["provider"]} if i["provider"] else set())) - {TARGET})
        print(f"  [dry] {os.path.basename(i['path'])[:60]}... {oldv if oldv else i['provider']} -> {TARGET}")
    sys.exit(0)

# 1) rollout 重写（整文件结构化替换，含续传追加的 session_meta 与 thread_settings）
n = 0
olds = set(FROM) if FROM else None           # None = 全量替换所有 != target 的值
for i in to_change:
    try:
        n += rewrite(i["path"], olds, TARGET)
    except Exception as e:
        print(f"  [ERR] {i['path']}: {e}")
print(f"[1/4] rollout 重写 {n} 处字段 / {len(to_change)} 个文件")
if n:
    info = scan()   # 重写后重新扫描，回填时使用各 rollout 当前真实 provider

# 2) threads 同步 + 回填
conn = connect_state()
cur = conn.cursor()
upd = 0
if FROM:
    ph = ",".join("?" * len(FROM))
    cur.execute(f"UPDATE threads SET model_provider=? WHERE model_provider IN ({ph})", (TARGET, *FROM))
    upd = cur.rowcount
else:
    cur.execute("SELECT DISTINCT model_provider FROM threads")
    old = [r[0] for r in cur.fetchall() if r[0] and r[0] != TARGET]
    if old:
        ph = ",".join("?" * len(old))
        cur.execute(f"UPDATE threads SET model_provider=? WHERE model_provider IN ({ph})", (TARGET, *old))
        upd = cur.rowcount
conn.commit()
added = backfill(conn, info, TARGET)
conn.close()
print(f"[2/4] threads 同步 {upd} 行, 回填 {added} 行")

# 3) session_index
conn = connect_state()
changed, total_idx = rebuild_index(conn)
conn.close()
print(f"[3/4] session_index: {'有更新' if changed else '无变化'}（共 {total_idx} 条）")

# 4) catalog（侧边栏数据源）
host, cat_n = rebuild_catalog()
print(f"[4/4] local_thread_catalog 重建: {cat_n} 行 (host_id={host})")

print("\n✓ 迁移完成! 现在可以重新打开 Codex / ChatGPT 查看历史记录。")
PY

if [ "$DRY" = 1 ]; then
  echo "（预演模式，未修改任何数据）"
fi
