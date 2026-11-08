#!/usr/bin/env bash
# Local-only regression tests. Run with: bash tests/regression.sh
# 远端用本地目录模拟：rsync 替身把 user@host:/path 映射到 $TEST_TMP/remote/path，
# 实际传输仍由真实的 GNU rsync 完成。
set -u

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/folder-sync-test.XXXXXX")" || exit 1
cleanup_test() {
  trap - EXIT
  local pid ppid
  ps -Ao pid=,ppid=,command= | grep -F "$TEST_TMP" | grep -v 'grep -F' | \
    while read -r pid ppid _; do
      [ "$pid" = "$$" ] && continue
      kill -KILL "$pid" 2>/dev/null || true
    done
  pkill -KILL -f "fswatch.*$TEST_TMP" 2>/dev/null || true
  rm -rf "$TEST_TMP"
}
trap cleanup_test EXIT
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/home" "$TEST_TMP/remote" "$TEST_TMP/state" "$TEST_TMP/local"
: > "$TEST_TMP/known_hosts"

export HOME="$TEST_TMP/home"
export FOLDER_SYNC_CONFIG="$TEST_TMP/config.conf"
export FOLDER_SYNC_STATE="$TEST_TMP/state"
export RSYNC_REMOTE_ROOT="$TEST_TMP/remote"
export RSYNC_CALLS="$TEST_TMP/rsync.calls"
export SSH_CALLS="$TEST_TMP/ssh.calls"
export CHOWN_LOG="$TEST_TMP/chown.calls"
export TEST_TMP
export RSYNC_BIN="$TEST_TMP/bin/rsync"
# 测试中 launchctl / pkill 一律不执行：launchd 服务名按用户全局，临时目录隔离不了，不能碰本机正在跑的服务
export FOLDER_SYNC_NO_LAUNCHD=1
REAL_RSYNC=""
for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do [ -x "$c" ] && { REAL_RSYNC="$c"; break; }; done
[ -n "$REAL_RSYNC" ] || { echo "需要 GNU rsync（brew install rsync）"; exit 1; }
export REAL_RSYNC
: > "$RSYNC_CALLS"; : > "$SSH_CALLS"; : > "$CHOWN_LOG"

cat > "$RSYNC_BIN" <<'STUB'
#!/usr/bin/env bash
[ -n "${FS_VERSION_PROBE:-}" ] && exec "$REAL_RSYNC" "$@"
printf '%s\n' "$*" >> "$RSYNC_CALLS"
if [ -n "${RSYNC_STUB_FAIL:-}" ]; then
  printf 'rsync stub failure %s\n' "$RSYNC_STUB_FAIL" >&2
  exit "$RSYNC_STUB_FAIL"
fi
# 模拟某条规则卡住：匹配到参数时一直挂着，直到被杀
if [ -n "${RSYNC_STUB_HANG_FOR:-}" ]; then
  case " $* " in *"$RSYNC_STUB_HANG_FOR"*) printf 'send|hang.bin\n'; exec /bin/sleep 60 ;; esac
fi
# 模拟大文件卡住：参数里没有排除它时，先报出文件名再挂住
if [ -n "${RSYNC_STUB_SLOW_FILE:-}" ]; then
  case " $* " in *"- /$RSYNC_STUB_SLOW_FILE"*) ;; *) printf 'send|%s\n' "$RSYNC_STUB_SLOW_FILE"; exec /bin/sleep 60 ;; esac
fi
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e) shift 2; continue ;;
    *@*:*) args+=( "$RSYNC_REMOTE_ROOT${1#*:}" ) ;;
    *) args+=( "$1" ) ;;
  esac
  shift
done
exec "$REAL_RSYNC" "${args[@]}"
STUB
chmod +x "$RSYNC_BIN"

cat > "$TEST_TMP/bin/chown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHOWN_LOG"
exit 0
STUB
chmod +x "$TEST_TMP/bin/chown"

cat > "$TEST_TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SSH_CALLS"
[ -n "${SSH_STUB_FAIL:-}" ] && exit "$SSH_STUB_FAIL"
case "$1" in -O) exit 1 ;; esac
while [ $# -gt 1 ]; do shift; done
remote_cmd="$1"
case "$remote_cmd" in
  cd\ *)
    remote_dir="${remote_cmd#cd }"; remote_dir="${remote_dir%% &&*}"
    eval "remote_dir=$remote_dir"
    cd "${RSYNC_REMOTE_ROOT}${remote_dir}" || exit 1
    export PATH="$TEST_TMP/bin:$PATH"
    bash -c "${remote_cmd#*&& }"; exit $? ;;
  test\ -d*) echo DIR_OK; echo "rsync  version 3.4.1  protocol version 32"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$TEST_TMP/bin/ssh"
PATH="$TEST_TMP/bin:$PATH"
export PATH

FS="$ROOT/folder-sync.sh"
passed=0; failed=0
run() {
  if /bin/bash "$FS" "$@" > "$TEST_TMP/output" 2>&1; then result=0; else result=$?; fi
}
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; sed -n '1,25p' "$TEST_TMP/output"; failed=$((failed + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
contains() { grep -Eq "$1" "$TEST_TMP/output"; }
valid_json() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }
json_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval("d"+sys.argv[2]))' "$1" "$2" 2>/dev/null; }
wait_for() { local i=0; while [ "$i" -lt "${2:-100}" ]; do eval "$1" && return 0; /bin/sleep 0.1; i=$((i+1)); done; return 1; }
wait_content() { local i=0; while [ "$i" -lt "${3:-100}" ]; do [ "$(cat "$1" 2>/dev/null)" = "$2" ] && return 0; /bin/sleep 0.1; i=$((i+1)); done; return 1; }

global_conf() {
  cat > "$FOLDER_SYNC_CONFIG" <<EOF
# 顶部注释要保留
[global]
known_hosts = $TEST_TMP/known_hosts
ssh_multiplex = false
debounce = 0.2
burst_full = 10
interval = 300
EOF
}
# rule <name> <local> <remote> [extra lines...]
rule() {
  local name="$1" l="$2" r="$3"; shift 3
  mkdir -p "$l" "$RSYNC_REMOTE_ROOT$r"
  {
    printf '\n[%s]\n# 规则内注释\nhost = example.invalid\nuser = tester\nlocal = %s\nremote = %s\n' "$name" "$l" "$r"
    for x in "$@"; do printf '%s\n' "$x"; done
  } >> "$FOLDER_SYNC_CONFIG"
}
L="$TEST_TMP/local"; R="$RSYNC_REMOTE_ROOT"

# ---------------------------------------------------------------- 校验
global_conf
printf '\n[nolocal]\nhost = h\nuser = u\nremote = /x\n' >> "$FOLDER_SYNC_CONFIG"
: > "$RSYNC_CALLS"; run sync nolocal
check "missing local is rejected before rsync" '[ "$result" -ne 0 ] && contains "缺少 local" && [ ! -s "$RSYNC_CALLS" ]'

global_conf; rule pullrule "$L/pullrule" /pullrule 'direction = remote'
run sync pullrule
check "direction = remote is no longer supported" '[ "$result" -ne 0 ] && contains "不再支持 direction = remote"'

# ---------------------------------------------------------------- 全量 + 删除开关
global_conf; rule site "$L/site" /site 'exclude = cache/**, *.log'
mkdir -p "$L/site/img/sub" "$R/site/cache"
echo a > "$L/site/a.txt"; echo n > "$L/site/img/sub/n.png"; echo x > "$L/site/skip.log"
echo old > "$R/site/old.txt"; echo c > "$R/site/cache/c"
run sync site
check "full sync copies files and honors exclude" '[ "$result" -eq 0 ] && [ -f "$R/site/a.txt" ] && [ -f "$R/site/img/sub/n.png" ] && [ ! -f "$R/site/skip.log" ]'
check "delete defaults to off (remote extras kept)" '[ -f "$R/site/old.txt" ]'
check "last result is valid JSON with file count" 'valid_json "$TEST_TMP/state/status/site.last.json" && [ "$(json_get "$TEST_TMP/state/status/site.last.json" "[\"files\"]")" = 2 ]'
check "history records the run" '[ "$(wc -l < "$TEST_TMP/state/history.jsonl" | tr -d " ")" -ge 1 ]'

global_conf; rule site "$L/site" /site 'exclude = cache/**, *.log' 'delete = true'
run sync site
check "delete = true removes remote extras without trash" '[ "$result" -eq 0 ] && [ ! -f "$R/site/old.txt" ] && [ ! -d "$R/site.folder-sync-trash" ]'
check "excluded paths are never deleted remotely" '[ -f "$R/site/cache/c" ]'
global_conf; rule site "$L/site" /site 'mode = mirror'
run list
check "legacy mode = mirror maps to delete" 'contains "site +启用 +是"'

# ---------------------------------------------------------------- push / pull
global_conf; rule site "$L/site" /site
echo p1 > "$L/site/p1.txt"; echo p2 > "$L/site/p2.txt"
: > "$RSYNC_CALLS"; run push "$L/site/p1.txt"
check "push uploads only the given path" '[ "$result" -eq 0 ] && [ -f "$R/site/p1.txt" ] && [ ! -f "$R/site/p2.txt" ] && grep -q -- "--files-from" "$RSYNC_CALLS"'
RID="$(json_get "$TEST_TMP/state/status/site.last.json" '["run_id"]')"
run run-files "$RID"
check "run-files lists the uploaded file" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"total\"]==1 and d[\"files\"][0]==dict(op=\"U\",path=\"p1.txt\")" "$TEST_TMP/output"'
check "history record carries a file sample" 'tail -1 "$TEST_TMP/state/history.jsonl" | grep -q "\"sample\":\[\"U\\\\tp1.txt\"\]"'
run push "$TEST_TMP/home"
check "path outside any rule is rejected" '[ "$result" -ne 0 ] && contains "不属于任何同步规则"'

echo remote-new > "$R/site/r-new.txt"; echo remote-ver > "$R/site/a.txt"; echo mine > "$L/site/local-only.txt"
run pull "$L/site" --preview
check "pull preview lists new and overwritten local files" '[ "$result" -eq 0 ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert \"r-new.txt\" in d[\"new\"] and \"a.txt\" in d[\"overwrite\"]" "$TEST_TMP/output"'
check "preview does not change local files" '[ ! -f "$L/site/r-new.txt" ] && [ "$(cat "$L/site/a.txt")" = a ]'
run pull "$L/site" --yes
check "pull downloads and never deletes local files" '[ "$result" -eq 0 ] && [ -f "$L/site/r-new.txt" ] && [ "$(cat "$L/site/a.txt")" = remote-ver ] && [ -f "$L/site/local-only.txt" ]'

global_conf; rule ex "$L/ex" /ex 'exclude = workerman/**, *.log'
mkdir -p "$R/ex/workerman/sub" "$L/ex/workerman"; echo w > "$R/ex/workerman/sub/w.php"; echo l > "$R/ex/workerman/a.log"
run pull "$L/ex/workerman" --yes
check "manual pull ignores the rule's exclude patterns" '[ "$result" -eq 0 ] && [ -f "$L/ex/workerman/sub/w.php" ] && [ -f "$L/ex/workerman/a.log" ]'
echo z > "$L/ex/workerman/new.php"; : > "$RSYNC_CALLS"
run push "$L/ex/workerman/new.php"
check "manual push still honors exclude" '[ ! -f "$R/ex/workerman/new.php" ]'

# ---------------------------------------------------------------- mirror（同步到云端）
global_conf; rule mir "$L/mir" /mir 'enabled = false' 'delete = false' 'exclude = keep/**'
mkdir -p "$L/mir/sub" "$R/mir/sub" "$R/mir/keep"
echo new > "$L/mir/sub/new.txt"; echo old > "$R/mir/sub/old.txt"
echo k > "$R/mir/keep/k.txt"; echo stale > "$R/mir/root-only.txt"
: > "$RSYNC_CALLS"; run mirror "$L/mir"
check "mirror uploads and deletes remote extras regardless of enabled/delete" \
  '[ "$result" -eq 0 ] && [ -f "$R/mir/sub/new.txt" ] && [ ! -f "$R/mir/sub/old.txt" ] && [ ! -f "$R/mir/root-only.txt" ]'
check "mirror still protects excluded remote paths" '[ -f "$R/mir/keep/k.txt" ]'
check "mirror uses files-from together with delete" \
  'grep -q -- "--files-from" "$RSYNC_CALLS" && grep -Eq -- "(^| )--delete( |$)" "$RSYNC_CALLS"'

echo old2 > "$R/mir/sub/old2.txt"; echo keeproot > "$R/mir/root2.txt"
run mirror "$L/mir/sub"
check "mirror limits deletion to the selected folder" \
  '[ "$result" -eq 0 ] && [ ! -f "$R/mir/sub/old2.txt" ] && [ -f "$R/mir/root2.txt" ]'

global_conf; rule rroot "$L/rroot" /
run mirror "$L/rroot"
check "mirror refuses a rule whose remote is the root directory" \
  '[ "$result" -ne 0 ] && contains "不能同步到云端"'

# ---------------------------------------------------------------- 失败 / ack
global_conf; rule site "$L/site" /site
RSYNC_STUB_FAIL=12 run sync site
F="$TEST_TMP/state/status/site.last.json"
check "failure is recorded unacknowledged with error kind" '[ "$result" -ne 0 ] && [ "$(json_get "$F" "[\"result\"]")" = failed ] && [ "$(json_get "$F" "[\"acked\"]")" = False ] && [ "$(json_get "$F" "[\"error_kind\"]")" = network ]'
RID="$(json_get "$F" '["run_id"]')"
run run-files "$RID"
check "failed run keeps its error output" 'grep -q "rsync stub failure 12" "$TEST_TMP/output"'
run ack site
check "ack marks the failure as seen" '[ "$(json_get "$F" "[\"acked\"]")" = True ]'
printf 'Permission denied (publickey).\n' > "$TEST_TMP/perm"
RSYNC_STUB_FAIL=255 run sync site
check "auth-like 255 is not retried endlessly" '[ "$result" -ne 0 ]'

# ---------------------------------------------------------------- remote_owner
global_conf; rule own "$L/own" /own 'remote_owner = www:www'
echo n > "$L/own/new.txt"; : > "$CHOWN_LOG"
run sync own
check "remote_owner chowns only transferred paths" '[ "$result" -eq 0 ] && grep -q "www:www new.txt" "$CHOWN_LOG"'
: > "$CHOWN_LOG"; run sync own
check "remote_owner skips chown when nothing transferred" '[ "$result" -eq 0 ] && [ ! -s "$CHOWN_LOG" ]'

# ---------------------------------------------------------------- 停止 / 正忙 / 跳过 / 并行
global_conf; rule hang "$L/hang" /hang; rule other "$L/other" /other
echo h > "$L/hang/h.txt"; echo o > "$L/other/o.txt"
RSYNC_STUB_HANG_FOR="/hang/" /bin/bash "$FS" sync hang > "$TEST_TMP/hang.out" 2>&1 &
HP=$!
wait_for '[ -f "$TEST_TMP/state/status/hang.run.json" ]' 50
check "running sync exposes live JSON state" 'valid_json "$TEST_TMP/state/status/hang.run.json"'
run sync other
check "another rule syncs while one is stuck (per-rule lock)" '[ "$result" -eq 0 ] && [ -f "$R/other/o.txt" ]'
run sync hang --no-wait
check "--no-wait returns 75 when the rule is busy" '[ "$result" -eq 75 ] && contains "正在同步中"'
run cancel hang
wait "$HP"; HRC=$?
check "cancel stops a stuck sync and records cancelled" '[ "$HRC" -eq 130 ] && [ "$(json_get "$TEST_TMP/state/status/hang.last.json" "[\"result\"]")" = cancelled ] && [ ! -f "$TEST_TMP/state/status/hang.run.json" ]'

global_conf; rule big "$L/big" /big
echo b > "$L/big/big.bin"; echo s > "$L/big/small.txt"
RSYNC_STUB_SLOW_FILE=big.bin /bin/bash "$FS" sync big > "$TEST_TMP/big.out" 2>&1 &
BP=$!
wait_for 'grep -q big.bin "$TEST_TMP/state/status/big.run.json" 2>/dev/null' 50
run skip big
wait "$BP"; BRC=$?
check "skip drops the stuck file and finishes the rest" '[ "$BRC" -eq 0 ] && [ -f "$R/big/small.txt" ] && [ ! -f "$R/big/big.bin" ] && grep -q "big.bin" "$TEST_TMP/state/status/big.last.json"'

# ---------------------------------------------------------------- 配置读写
global_conf; rule site "$L/site" /site 'exclude = a/**' 'exclude = b/**'
cp "$FOLDER_SYNC_CONFIG" "$TEST_TMP/before.conf"
run rule-set site delete=true exclude='x/**, y/**'
DIFF="$(diff "$TEST_TMP/before.conf" "$FOLDER_SYNC_CONFIG" | grep -E '^[<>]' | tr '\n' '|')"
check "rule-set edits only target lines and keeps comments" '[ "$result" -eq 0 ] && grep -q "# 顶部注释要保留" "$FOLDER_SYNC_CONFIG" && grep -q "# 规则内注释" "$FOLDER_SYNC_CONFIG" && grep -q "interval = 300" "$FOLDER_SYNC_CONFIG" && [ "$DIFF" = "< exclude = a/**|< exclude = b/**|> exclude = x/**, y/**|> delete = true|" ]'
cp "$FOLDER_SYNC_CONFIG" "$TEST_TMP/before2.conf"
run rule-set site local="$TEST_TMP/nope"
check "invalid value is rejected and config untouched" '[ "$result" -ne 0 ] && cmp -s "$TEST_TMP/before2.conf" "$FOLDER_SYNC_CONFIG"'
mkdir -p "$L/new2"
run rule-add new2 host=h user=u local="$L/new2" remote=/new2
run rules --json
check "rule-add + rules --json" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert [r for r in d[\"rules\"] if r[\"name\"]==\"new2\" and r[\"delete\"] is False]" "$TEST_TMP/output"'
run rule-rename new2 new3; run rule-rm new3
check "rule-rename and rule-rm" '[ "$result" -eq 0 ] && ! grep -q "new[23]" "$FOLDER_SYNC_CONFIG" && grep -q "# 规则内注释" "$FOLDER_SYNC_CONFIG"'

# ---------------------------------------------------------------- 导出 / 导入配置
global_conf; rule site "$L/site" /site; rule blog "$L/blog" /blog
run export "$TEST_TMP/export.json"
check "export writes a 600 JSON backup of the whole config" '[ "$result" -eq 0 ] && [ "$(stat -f %Lp "$TEST_TMP/export.json")" = 600 ] && valid_json "$TEST_TMP/export.json"'
check "export records format, version and the full config text" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"format\"]==\"folder-sync-config\" and d[\"format_version\"]==1 and d[\"exported_at\"] and \"[site]\" in d[\"config\"] and \"[blog]\" in d[\"config\"]" "$TEST_TMP/export.json"'

mkdir -p "$L/other-site"
cat > "$TEST_TMP/other.conf" <<EOF
# 本机已有配置
[global]
known_hosts = $TEST_TMP/known_hosts
debounce = 3

[site]
host = example.invalid
user = other
local = $L/other-site
remote = /other/site
EOF
cp "$TEST_TMP/other.conf" "$TEST_TMP/other.before"
FOLDER_SYNC_CONFIG="$TEST_TMP/other.conf" run import "$TEST_TMP/export.json" --preview
check "import --preview reports what merge would add" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"ok\"] and d[\"mode\"]==\"merge\" and d[\"imported\"]==2 and d[\"added\"]==[\"blog\"] and d[\"skipped\"]==[\"site\"]" "$TEST_TMP/output"'
check "import --preview leaves the config untouched" 'cmp -s "$TEST_TMP/other.before" "$TEST_TMP/other.conf"'

FOLDER_SYNC_CONFIG="$TEST_TMP/other.conf" run import "$TEST_TMP/export.json"
check "import merges missing projects and keeps the local one" 'contains "新增项目: blog" && grep -q "remote = /blog" "$TEST_TMP/other.conf" && grep -q "remote = /other/site" "$TEST_TMP/other.conf"'
check "import keeps the local preamble and [global]" 'head -1 "$TEST_TMP/other.conf" | grep -qx "# 本机已有配置" && grep -q "^debounce = 3" "$TEST_TMP/other.conf" && ! grep -q "^debounce = 0.2" "$TEST_TMP/other.conf"'
check "import backs up the previous config" 'ls "$TEST_TMP"/other.conf.bak.* >/dev/null 2>&1'
check "imported config still parses (list shows both projects)" 'FOLDER_SYNC_CONFIG="$TEST_TMP/other.conf" /bin/bash "$FS" list 2>&1 | grep -q "blog"'

FOLDER_SYNC_CONFIG="$TEST_TMP/other.conf" run import "$TEST_TMP/export.json" --replace
check "import --replace takes the backup as is" '[ "$result" -eq 0 ] && grep -q "remote = /site" "$TEST_TMP/other.conf" && ! grep -q "/other/site" "$TEST_TMP/other.conf"'

FOLDER_SYNC_CONFIG="$TEST_TMP/fresh/config.conf" run import "$TEST_TMP/export.json"
check "import into a machine without config restores every project" '[ "$result" -eq 0 ] && grep -q "\[site\]" "$TEST_TMP/fresh/config.conf" && grep -q "\[blog\]" "$TEST_TMP/fresh/config.conf" && ! ls "$TEST_TMP/fresh"/config.conf.bak.* >/dev/null 2>&1'

printf 'not json at all\n' > "$TEST_TMP/bad.json"
cp "$FOLDER_SYNC_CONFIG" "$TEST_TMP/good.before"
run import "$TEST_TMP/bad.json"
check "a non-JSON file is rejected and the config is untouched" '[ "$result" -ne 0 ] && contains "备份文件不是有效的 JSON" && cmp -s "$TEST_TMP/good.before" "$FOLDER_SYNC_CONFIG"'
cat > "$TEST_TMP/foreign.json" <<'EOF'
{"format":"other-tool","format_version":1,"config":"[x]\nhost = h\n"}
EOF
run import "$TEST_TMP/foreign.json"
check "a foreign JSON file is rejected" '[ "$result" -ne 0 ] && contains "不是 FolderSync 导出的配置文件"'

# ---------------------------------------------------------------- 日志：分段读取 / 无变化不记录 / 自动清理
global_conf; rule logs "$L/logs" /logs
for i in $(seq 1 20); do echo "$i" > "$L/logs/f$i.txt"; done
run sync logs
LRID="$(json_get "$TEST_TMP/state/status/logs.last.json" '["run_id"]')"
run run-files "$LRID" 15 0
check "run-files returns the first page" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"total\"]==20 and len(d[\"files\"])==15" "$TEST_TMP/output"'
run run-files "$LRID" 50 15
check "run-files returns the next page from an offset" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"offset\"]==15 and len(d[\"files\"])==5" "$TEST_TMP/output"'
H="$TEST_TMP/state/history.jsonl"
N0="$(wc -l < "$H" | tr -d ' ')"
run sync logs
check "a no-change sync is not written to the log" '[ "$result" -eq 0 ] && [ "$(wc -l < "$H" | tr -d " ")" = "$N0" ] && grep -q "无变化" "$TEST_TMP/state/status/logs.last.json"'
printf '%s\n' '{"v":1,"rule":"logs","run_id":"legacy.1","trigger":"change","result":"ok","started_at":1,"finished_at":1,"duration_s":0,"files":0,"deleted":0,"skipped":[],"error_kind":"","error":"","summary":"无变化","dry_run":false,"acked":true}' >> "$H"
touch -t "$(date -v-5M +%Y%m%d%H%M.%S)" "$TEST_TMP/state/runs/orphan.1.tsv"
touch "$TEST_TMP/state/runs/inflight.1.tsv"
export FOLDER_SYNC_HISTORY_MAX=3
for i in 1 2 3 4; do echo "x$i" > "$L/logs/p$i.txt"; run push "$L/logs/p$i.txt"; done
unset FOLDER_SYNC_HISTORY_MAX
check "the log keeps only the newest N records and drops no-change ones" '[ "$(wc -l < "$H" | tr -d " ")" = 3 ] && ! grep -q "legacy.1" "$H"'
check "files of trimmed records and stale orphans are deleted; in-flight ones kept" '[ ! -e "$TEST_TMP/state/runs/orphan.1.tsv" ] && [ -e "$TEST_TMP/state/runs/inflight.1.tsv" ] && [ "$(ls "$TEST_TMP/state/runs" | grep -v "^inflight" | wc -l | tr -d " ")" = 3 ]'
KEEP="$(sed -nE 's/.*"run_id":"([^"]+)".*/\1/p' "$H" | sort | tr '\n' ' ')"
HAVE="$(ls "$TEST_TMP/state/runs" | grep -v '^inflight' | sed -E 's/\.(tsv|err)$//' | sort | tr '\n' ' ')"
check "every remaining record still has its file list" '[ "$KEEP" = "$HAVE" ]'
rm -f "$TEST_TMP/state/runs/inflight.1.tsv"

# ---------------------------------------------------------------- 安装（应用调用，--dry-run 不碰 launchctl）/ 开机自启 / 自检
FAKEAPP="$TEST_TMP/Apps/FolderSync.app"
run install --dry-run --app-path "$FAKEAPP"
LA="$HOME/Library/LaunchAgents"
check "install --app-path writes the daemon and app login items" '[ "$result" -eq 0 ] && grep -q "$HOME/.local/bin/folder-sync" "$LA/com.local.folder-sync.plist" && grep -q "$FAKEAPP/Contents/MacOS/FolderSync" "$LA/com.local.folder-sync.app.plist" && cmp -s "$FS" "$HOME/.local/bin/folder-sync"'
run doctor --json --app-path "$FAKEAPP"
check "doctor reports a ready environment" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"ok\"] and d[\"cli_current\"] and d[\"app_registered\"] and d[\"daemon_installed\"] and d[\"autostart\"]" "$TEST_TMP/output"'
run doctor --json --app-path /Volumes/FolderSync/FolderSync.app
check "doctor flags an app opened straight from the DMG" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"app_location_ok\"] is False" "$TEST_TMP/output"'
run autostart off
check "autostart off moves login items out of LaunchAgents" '[ ! -e "$LA/com.local.folder-sync.plist" ] && [ -f "$TEST_TMP/state/launchd/com.local.folder-sync.plist" ] && [ -f "$TEST_TMP/state/launchd/com.local.folder-sync.app.plist" ]'
run rules --json
check "rules --json reports autostart off" 'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"autostart\"] is False" "$TEST_TMP/output"'
run install --dry-run --app-path "$FAKEAPP"
check "reinstall keeps autostart off" '[ ! -e "$LA/com.local.folder-sync.plist" ] && [ -f "$TEST_TMP/state/launchd/com.local.folder-sync.plist" ]'
run autostart on
check "autostart on moves login items back" '[ -f "$LA/com.local.folder-sync.plist" ] && [ -f "$LA/com.local.folder-sync.app.plist" ] && [ ! -e "$TEST_TMP/state/autostart.off" ]'
run install --app-path "$FAKEAPP"
check "install --app-path runs end to end (launchd calls stubbed out)" '[ "$result" -eq 0 ] && [ -f "$LA/com.local.folder-sync.plist" ] && [ -f "$LA/com.local.folder-sync.app.plist" ] && [ -x "$HOME/.local/bin/folder-sync" ]'
run autostart off
run uninstall --keep-app
check "uninstall removes login items (both places) and the CLI, keeps config and records" '[ "$result" -eq 0 ] && [ -z "$(ls "$LA" 2>/dev/null)" ] && [ -z "$(ls "$TEST_TMP/state/launchd" 2>/dev/null)" ] && [ ! -e "$TEST_TMP/state/autostart.off" ] && [ ! -e "$HOME/.local/bin/folder-sync" ] && [ -f "$FOLDER_SYNC_CONFIG" ] && [ -f "$TEST_TMP/state/history.jsonl" ]'
FOLDER_SYNC_CONFIG="$TEST_TMP/fresh.conf" run init
FOLDER_SYNC_CONFIG="$TEST_TMP/fresh.conf" run rules --json
check "a fresh config has no placeholder project" 'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"rules\"]==[]" "$TEST_TMP/output"'
check "a missing known_hosts is created empty instead of blocking everything" '[ -f "$HOME/.ssh/known_hosts" ] && [ ! -s "$HOME/.ssh/known_hosts" ]'

# ---------------------------------------------------------------- 信任服务器指纹（ssh-keyscan 用替身，指纹用真实 ssh-keygen 计算）
ssh-keygen -q -t ed25519 -N '' -f "$TEST_TMP/hostkey" >/dev/null
printf '#!/bin/bash\nprintf "example.invalid %%s\\n" "$(cut -d" " -f1-2 %s)"\n' "$TEST_TMP/hostkey.pub" > "$TEST_TMP/bin/ssh-keyscan"
chmod +x "$TEST_TMP/bin/ssh-keyscan"
: > "$TEST_TMP/known_hosts"
global_conf; rule th "$L/th" /th
run trust-host th --json
FP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprints"][0]["fp"])' "$TEST_TMP/output" 2>/dev/null)"
check "trust-host --json returns the host fingerprint" '[ -n "$FP" ] && [ "$FP" = "$(ssh-keygen -lf "$TEST_TMP/hostkey.pub" | cut -d" " -f2)" ] && [ ! -s "$TEST_TMP/known_hosts" ]'
run trust-host th --yes SHA256:not-the-right-one
check "trust-host refuses keys that do not match the confirmed fingerprint" '[ "$result" -ne 0 ] && [ ! -s "$TEST_TMP/known_hosts" ]'
run trust-host th --yes "$FP"
check "trust-host writes the confirmed key to known_hosts" '[ "$result" -eq 0 ] && grep -q "^example.invalid ssh-ed25519 " "$TEST_TMP/known_hosts"'
: > "$TEST_TMP/known_hosts"; rm -f "$TEST_TMP/bin/ssh-keyscan"

# ---------------------------------------------------------------- 守护：改动即推送 / 即时删除 / 自动重载
if command -v fswatch >/dev/null 2>&1; then
  global_conf; rule live "$L/live" /live 'delete = true' 'exclude = runtime/**'; rule keep "$L/keep" /keep
  rule gitlive "$L/gitlive" /gitlive
  rule burst "$L/burst" /burst
  # 准备一个两分支的 git 仓库：切分支时 HEAD/reflog 变化必须触发全量
  git -C "$L/gitlive" init -q
  git -C "$L/gitlive" config user.email tester@example.invalid
  git -C "$L/gitlive" config user.name tester
  echo base > "$L/gitlive/a.txt"
  git -C "$L/gitlive" add -A && git -C "$L/gitlive" commit -qm base
  GIT_BASE_BRANCH="$(git -C "$L/gitlive" symbolic-ref --short HEAD)"
  git -C "$L/gitlive" checkout -qb other
  echo other > "$L/gitlive/a.txt"; echo new > "$L/gitlive/b.txt"
  git -C "$L/gitlive" add -A && git -C "$L/gitlive" commit -qm other
  git -C "$L/gitlive" checkout -q "$GIT_BASE_BRANCH"
  echo gone > "$R/live/untouched-extra.txt"
  /bin/bash "$FS" daemon > "$TEST_TMP/daemon.out" 2>&1 &
  DP=$!
  wait_for 'grep -q "监听 \[keep\]" "$TEST_TMP/daemon.out"' 50
  /bin/sleep 0.5
  : > "$RSYNC_CALLS"
  echo v1 > "$L/live/edit.txt"
  check "daemon pushes a changed file" 'wait_for "[ -f \"$R/live/edit.txt\" ]" 80'
  check "change push uses files-from (no full scan)" 'grep -q -- "--files-from" "$RSYNC_CALLS" && ! grep -q -- "--no-inc-recursive" "$RSYNC_CALLS"'
  check "change push compares checksums (same-size rewrites in one second)" 'grep -q -- "--checksum" "$RSYNC_CALLS"'
  check "daemon does not run a startup/periodic full sync" '[ -f "$R/live/untouched-extra.txt" ]'
  rm "$L/live/edit.txt"
  check "local delete is mirrored when delete = true" 'wait_for "[ ! -f \"$R/live/edit.txt\" ]" 80'
  echo k > "$L/keep/k.txt"; wait_for "[ -f \"$R/keep/k.txt\" ]" 80
  rm "$L/keep/k.txt"; /bin/sleep 2
  check "local delete is ignored when delete = false" '[ -f "$R/keep/k.txt" ]'
  mkdir -p "$L/live/runtime"; echo r > "$L/live/runtime/cache.txt"; echo ok > "$L/live/after.txt"
  wait_for "[ -f \"$R/live/after.txt\" ]" 80
  check "changes inside a rule-excluded dir are not pushed" '[ ! -f "$R/live/runtime/cache.txt" ]'

  # 切分支：git 元数据变化应立即触发一次全量（不依赖逐文件事件）
  : > "$RSYNC_CALLS"
  git -C "$L/gitlive" checkout -q other
  check "switching git branch triggers a full sync" 'wait_for "grep -q -- \"--no-inc-recursive\" \"$RSYNC_CALLS\"" 200'
  check "branch switch pushes the new branch content" 'wait_content "$R/gitlive/a.txt" other 200 && [ -f "$R/gitlive/b.txt" ]'

  # 大批量写入：短时间事件数超过 burst_full 时改走全量
  : > "$RSYNC_CALLS"
  for i in $(seq 1 30); do echo "b$i" > "$L/burst/f$i.txt"; done
  check "a large batch switches to a full sync" 'wait_for "grep -q -- \"--no-inc-recursive\" \"$RSYNC_CALLS\"" 200'
  check "the batch full sync pushes every file" 'wait_for "[ -f \"$R/burst/f30.txt\" ]" 200'

  # 连续快速写入同一个文件：最终远端必须是最后一次内容
  echo race1 > "$L/live/race.txt"; /bin/sleep 0.05
  echo race2 > "$L/live/race.txt"; /bin/sleep 0.05
  echo race3 > "$L/live/race.txt"
  check "rapid successive writes converge to the last content" 'wait_content "$R/live/race.txt" race3'

  # 一次推送刚结束就立刻再写：队列可能刚好被取空，这次写入也必须被消费
  echo drain1 > "$L/live/drain.txt"
  wait_for '[ -f "$R/live/drain.txt" ]' 100
  echo drain2 > "$L/live/drain.txt"
  check "a write right after the queue drains is still consumed" 'wait_content "$R/live/drain.txt" drain2'

  # 空闲时不应产生"无变化"之外的额外运行记录（先等最后一批推送落盘）
  /bin/sleep 2
  before="$(wc -l < "$TEST_TMP/state/history.jsonl" 2>/dev/null || echo 0)"
  /bin/sleep 3
  after="$(wc -l < "$TEST_TMP/state/history.jsonl" 2>/dev/null || echo 0)"
  check "an idle daemon does not add history entries" '[ "$before" = "$after" ]'
  mkdir -p "$L/added"
  /bin/bash "$FS" rule-add added host=h user=u local="$L/added" remote=/added > /dev/null 2>&1
  mkdir -p "$R/added"
  wait_for 'grep -q "监听 \[added\]" "$TEST_TMP/daemon.out"' 100
  echo z > "$L/added/z.txt"
  check "config change is picked up without reload" 'wait_for "[ -f \"$R/added/z.txt\" ]" 100'
  /bin/bash "$FS" sync keep --bg > "$TEST_TMP/output" 2>&1
  check "sync --bg hands the full sync to the daemon" 'contains "已交给守护"'
  kill -TERM "$DP" 2>/dev/null; wait "$DP" 2>/dev/null
  /bin/sleep 1
  check "daemon exits cleanly on TERM (after a reload) without leaking fswatch" '! kill -0 "$DP" 2>/dev/null && [ ! -f "$TEST_TMP/state/daemon.pid" ] && ! pgrep -f "fswatch.*$TEST_TMP" >/dev/null'
else
  echo "# fswatch 未安装，跳过守护测试"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
