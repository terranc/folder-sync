#!/usr/bin/env bash
# ==============================================================================
# folder-sync —— 多规则文件夹单向推送（macOS → 远端，SSH + GNU rsync）
#
#   配置文件 : ~/.config/folder-sync/config.conf   （一个文件写任意多条规则）
#   状态目录 : ~/.local/state/folder-sync          （status/*.json 供菜单栏应用读取）
#   运行依赖 : GNU rsync 3.1+、ssh、lockf、perl；fswatch 用于监听本地改动
#   后台常驻 : launchd 用户级 Agent，登录自启
#
#   同步策略：
#     · 只从本地推到远端；本地改动后只推改动的文件（不扫描整棵目录）
#     · 不做定时 / 启动时全量比对；全量只能手动（folder-sync sync <规则>）
#     · delete = true 时本地删除的文件、全量时远端多余的文件会被直接删除；默认不删
#     · 停止 / 跳过 / 失败都丢弃本次未传完的文件，不补传
#
#   用法: folder-sync <命令> [选项]
# ==============================================================================

set -e

SELF="$0"
APP="folder-sync"
LABEL="com.local.folder-sync"
APP_LABEL="com.local.folder-sync.app"
U="$(id -u)"
CONFIG="${FOLDER_SYNC_CONFIG:-$HOME/.config/folder-sync/config.conf}"
STATE="${FOLDER_SYNC_STATE:-$HOME/.local/state/folder-sync}"
LA_DIR="$HOME/Library/LaunchAgents"
# 关闭"开机自动启动"后，启动项文件移到这里：登录时 launchd 不再加载，打开应用时仍可临时启动后台同步
LA_OFF_DIR="$STATE/launchd"
if [ -f "$STATE/autostart.off" ]; then PLIST_DIR="$LA_OFF_DIR"; else PLIST_DIR="$LA_DIR"; fi
PLIST="$PLIST_DIR/$LABEL.plist"
APP_PLIST="$PLIST_DIR/$APP_LABEL.plist"
APP_DEST="${FOLDER_SYNC_APP_DEST:-/Applications/FolderSync.app}"
SERVICE_LOG="$HOME/Library/Logs/folder-sync.log"
SERVICE_ERR="$HOME/Library/Logs/folder-sync.err.log"
RUN_LOG="$STATE/folder-sync.log"
STATUS_DIR="$STATE/status"
CTL_DIR="$STATE/control"
LOCK_DIR="$STATE/locks"
PEND_DIR="$STATE/pending"
WORKER_DIR="$STATE/workers"
HISTORY="$STATE/history.jsonl"
RUNS_DIR="$STATE/runs"           # 每次同步的文件清单（<run_id>.tsv）与失败输出（<run_id>.err）
HISTORY_MAX="${FOLDER_SYNC_HISTORY_MAX:-1000}"   # 日志最多保留（也是界面最多显示）的同步记录数
PATDIR="$STATE/pat.$$"
PATTERN_INC="$PATDIR/inc"
PATTERN_EXC="$PATDIR/exc"

# ---------- 全局默认（可被 [global] 覆盖） ----------
G_DEBOUNCE=1
G_KNOWN_HOSTS="$HOME/.ssh/known_hosts"
G_WATCH_IGNORE=".git node_modules .idea .vscode dist build .DS_Store"
G_SSH_MULTIPLEX="true"
G_SSH_PERSIST=600
# 切分支（.git/HEAD / reflog 变化）时自动触发一次全量
G_GIT_TRIGGER="true"
# 2 秒内收到的事件数达到该值时改走全量；0 = 关闭
G_BURST_FULL=100

OPT_PROFILE=""
OPT_DRY=0
OPT_VERBOSE=0
OPT_JSON=0
OPT_WATCH=0
OPT_YES=0
OPT_NOWAIT=0
OPT_BG=0
OPT_PREVIEW=0
OPT_REPLACE=0
OPT_APP_PATH=""
OPT_KEEP_APP=0
ARGS=()

# ============================== 基础工具 ==============================

die()  { printf '错误: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
now()  { date +%s; }
ts()   { date '+%F %T'; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

unquote() {
  local s="$1"
  case "$s" in
    \"*\") s="${s#\"}"; s="${s%\"}" ;;
    \'*\') s="${s#\'}"; s="${s%\'}" ;;
  esac
  printf '%s' "$s"
}

expand_path() {
  local p="$1"
  case "$p" in
    "~")    p="$HOME" ;;
    "~/"*)  p="$HOME/${p#\~/}" ;;
    '$HOME')   p="$HOME" ;;
    '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
  esac
  printf '%s' "$p"
}

ere_escape() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

# JSON 字符串（含引号）。只处理会破坏 JSON 的字符。
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# 文件 → JSON 字符串数组
json_lines() {
  local f="$1" line first=1
  printf '['
  if [ -f "$f" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      json_str "$line"
    done < "$f"
  fi
  printf ']'
}

atomic_write() {
  local dest="$1" tmp="$1.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$dest"
}

is_true() { case "$1" in true|yes|1|on) return 0 ;; esac; return 1; }

ensure_dirs() {
  mkdir -p "$STATE" "$STATUS_DIR" "$CTL_DIR" "$LOCK_DIR" "$PEND_DIR" "$WORKER_DIR" "$RUNS_DIR" 2>/dev/null || true
}

# ============================== 配置解析 ==============================

add_patterns() {
  local file="$1" val="$2" p oldifs="$IFS" had_f=0
  # include/exclude 里是 *.php 这类通配符：循环期间关掉路径展开，避免被当前目录的文件名替换
  case $- in *f*) had_f=1 ;; esac
  set -f
  IFS=','
  for p in $val; do
    IFS="$oldifs"
    p="$(trim "$p")"
    if [ -n "$p" ]; then printf '%s\n' "$p" >> "$file"; fi
    IFS=','
  done
  IFS="$oldifs"
  [ "$had_f" = "0" ] && set +f
  return 0
}

list_profiles() {
  [ -f "$CONFIG" ] || return 0
  sed -n 's/^[[:space:]]*\[\([^]]*\)\][[:space:]]*$/\1/p' "$CONFIG" \
    | while IFS= read -r n; do
        n="$(trim "$n")"
        case "$n" in ""|global) continue ;; esac
        printf '%s\n' "$n"
      done
}

is_profile() { list_profiles | grep -qxF -- "$1"; }

read_global() {
  local line section="" key val
  [ -f "$CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|\;*) continue ;; esac
    line="${line%% #*}"
    line="$(trim "$line")"
    [ -n "$line" ] || continue
    case "$line" in
      \[*) section="$(trim "${line#[}")"; section="${section%]}"; section="$(trim "$section")"; continue ;;
    esac
    [ "$section" = "global" ] || continue
    case "$line" in *=*) ;; *) continue ;; esac
    key="$(trim "${line%%=*}")"
    val="$(unquote "$(trim "${line#*=}")")"
    case "$key" in
      debounce)      G_DEBOUNCE="$val" ;;
      known_hosts)   G_KNOWN_HOSTS="$(expand_path "$val")" ;;
      watch_ignore)  G_WATCH_IGNORE="$val" ;;
      ssh_multiplex) G_SSH_MULTIPLEX="$val" ;;
      ssh_persist)   G_SSH_PERSIST="$val" ;;
      git_trigger)   if is_true "$val"; then G_GIT_TRIGGER="true"; else G_GIT_TRIGGER="false"; fi ;;
      burst_full)    case "$val" in ''|*[!0-9]*) ;; *) G_BURST_FULL="$val" ;; esac ;;
      # interval / notify* / engine / fast_path 等旧字段：已不再使用，静默忽略
    esac
  done < "$CONFIG"
  if [ -n "$G_KNOWN_HOSTS" ] && [ ! -f "$G_KNOWN_HOSTS" ]; then
    # 新电脑上常常还没有这个文件：建一个空的（等同 ssh 首次连接时的行为）。
    # 仍按严格模式校验：没有登记过指纹的服务器一律拒绝连接，需要先"信任服务器指纹"。
    if [ ! -d "$(dirname "$G_KNOWN_HOSTS")" ]; then
      mkdir -p "$(dirname "$G_KNOWN_HOSTS")" 2>/dev/null && chmod 700 "$(dirname "$G_KNOWN_HOSTS")" 2>/dev/null
    fi
    ( umask 077; : >> "$G_KNOWN_HOSTS" ) 2>/dev/null ||
      die "known_hosts 文件不存在且无法创建: ${G_KNOWN_HOSTS}（设为空才会关闭主机指纹校验）"
  fi
}

# 载入单个规则到 P_* 变量；include/exclude 原样写入 $PATTERN_INC / $PATTERN_EXC
load_profile() {
  local want="$1" line section="" key val
  P_LOCAL=""; P_REMOTE=""; P_PROTOCOL="sftp"; P_HOST=""; P_PORT=""
  P_USER=""; P_KEY_FILE=""; P_PASSWORD=""; P_DIRECTION="local"
  P_DELETE="false"; P_ENABLED="true"; P_EXTRA=""; P_REMOTE_OWNER=""; P_ENGINE=""
  mkdir -p "$PATDIR" 2>/dev/null || true
  : > "$PATTERN_INC"
  : > "$PATTERN_EXC"
  [ -f "$CONFIG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in \#*|\;*) continue ;; esac
    line="${line%% #*}"
    line="$(trim "$line")"
    [ -n "$line" ] || continue
    case "$line" in
      \[*) section="$(trim "${line#[}")"; section="${section%]}"; section="$(trim "$section")"; continue ;;
    esac
    [ "$section" = "$want" ] || continue
    case "$line" in *=*) ;; *) continue ;; esac
    key="$(trim "${line%%=*}")"
    val="$(unquote "$(trim "${line#*=}")")"
    case "$key" in
      local|local_dir|path)  P_LOCAL="$(expand_path "$val")" ;;
      remote|remote_dir)     P_REMOTE="$val" ;;
      protocol|type)         P_PROTOCOL="$val" ;;
      host|server)           P_HOST="$val" ;;
      port)                  P_PORT="$val" ;;
      user|username)         P_USER="$val" ;;
      key_file|keyfile)      P_KEY_FILE="$(expand_path "$val")" ;;
      password|pass)         P_PASSWORD="$val" ;;
      direction|from)        P_DIRECTION="$val" ;;
      mode)                  if [ "$val" = "mirror" ]; then P_DELETE="true"; else P_DELETE="false"; fi ;;
      delete)                if is_true "$val"; then P_DELETE="true"; else P_DELETE="false"; fi ;;
      engine)                P_ENGINE="$val" ;;
      enabled)               if is_true "$val"; then P_ENABLED="true"; else P_ENABLED="false"; fi ;;
      extra|extra_flags)     P_EXTRA="$val" ;;
      include|includes|sync|rules) add_patterns "$PATTERN_INC" "$val" ;;
      exclude|excludes)      add_patterns "$PATTERN_EXC" "$val" ;;
      remote_owner)          P_REMOTE_OWNER="$val" ;;
    esac
  done < "$CONFIG"
  while [ "$P_LOCAL" != "/" ] && [ "${P_LOCAL%/}" != "$P_LOCAL" ]; do P_LOCAL="${P_LOCAL%/}"; done
  while [ "$P_REMOTE" != "/" ] && [ "${P_REMOTE%/}" != "$P_REMOTE" ]; do P_REMOTE="${P_REMOTE%/}"; done
  return 0
}

# 校验规则；出错时打印原因并返回非零（调用方决定 die 还是跳过）
check_profile() {
  local p="$1"
  [ -n "$P_LOCAL" ] || { printf '[%s] 缺少 local（本地文件夹）\n' "$p"; return 1; }
  [ -n "$P_REMOTE" ] || { printf '[%s] 缺少 remote（远端路径）\n' "$p"; return 1; }
  [ -n "$P_HOST" ] || { printf '[%s] 缺少 host\n' "$p"; return 1; }
  [ -n "$P_USER" ] || { printf '[%s] 缺少 user\n' "$p"; return 1; }
  case "$P_REMOTE" in /*) ;; *) printf '[%s] remote 必须是绝对路径: %s\n' "$p" "$P_REMOTE"; return 1 ;; esac
  case "$P_PROTOCOL" in sftp) ;; *) printf '[%s] 只支持 SSH + rsync，当前 protocol 为 %s\n' "$p" "$P_PROTOCOL"; return 1 ;; esac
  case "$P_DIRECTION" in
    local) ;;
    remote) printf '[%s] 已不再支持 direction = remote：自动同步只推送到远端，需要下载请用 %s pull <路径>\n' "$p" "$APP"; return 1 ;;
    *) printf '[%s] direction 只能是 local，当前为 %s\n' "$p" "$P_DIRECTION"; return 1 ;;
  esac
  case "${P_ENGINE:-rsync}" in auto|rsync) ;; *) printf '[%s] 只支持 rsync，当前 engine 为 %s\n' "$p" "$P_ENGINE"; return 1 ;; esac
  [ -z "$P_PASSWORD" ] || { printf '[%s] 不支持配置密码，请使用 key_file 或 ssh-agent\n' "$p"; return 1; }
  case "${P_PORT:-22}" in *[!0-9]*) printf '[%s] port 必须是数字: %s\n' "$p" "$P_PORT"; return 1 ;; esac
  [ -d "$P_LOCAL" ] || { printf '[%s] 本地目录不存在: %s\n' "$p" "$P_LOCAL"; return 1; }
  if [ "$P_DELETE" = "true" ] && [ "$P_REMOTE" = "/" ]; then
    printf '[%s] remote 指向根目录时不能开启 delete\n' "$p"; return 1
  fi
  if [ -n "$P_REMOTE_OWNER" ] &&
     ! printf '%s' "$P_REMOTE_OWNER" | grep -qE '^[A-Za-z0-9._-]+(:[A-Za-z0-9._-]+)?$'; then
    printf '[%s] remote_owner 格式非法: %s\n' "$p" "$P_REMOTE_OWNER"; return 1
  fi
  return 0
}

validate_profile() {
  local msg
  msg="$(check_profile "$1")" || die "$msg"
  if [ -n "$P_KEY_FILE" ] && [ ! -f "$P_KEY_FILE" ]; then
    warn "[$1] 私钥不存在，将依赖 ssh-agent: $P_KEY_FILE"
  fi
  return 0
}

# ============================== rsync / ssh ==============================

# 必须是 GNU rsync 3.1+：进度（progress2）、即时删除（--delete-missing-args）都依赖它
detect_rsync() {
  if [ -z "${RSYNC_BIN:-}" ]; then
    local c
    for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
      if [ -x "$c" ]; then RSYNC_BIN="$c"; break; fi
    done
    [ -n "${RSYNC_BIN:-}" ] || RSYNC_BIN="$(command -v rsync 2>/dev/null || printf rsync)"
  fi
  local v major minor
  v="$(FS_VERSION_PROBE=1 "$RSYNC_BIN" --version 2>/dev/null | head -1)" || true
  major="$(printf '%s' "$v" | sed -nE 's/^rsync[[:space:]]+version[[:space:]]+v?([0-9]+)\.([0-9]+).*/\1/p')"
  minor="$(printf '%s' "$v" | sed -nE 's/^rsync[[:space:]]+version[[:space:]]+v?([0-9]+)\.([0-9]+).*/\2/p')"
  RSYNC_ERR=""
  case "$major" in ''|*[!0-9]*) RSYNC_ERR="需要 GNU rsync 3.1+（系统自带的 openrsync 不可用），请执行: brew install rsync"; return 1 ;; esac
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -lt 1 ]; }; then
    RSYNC_ERR="需要 GNU rsync 3.1+，当前为 ${v}，请执行: brew install rsync"; return 1
  fi
  return 0
}

need_tools() {
  command -v ssh >/dev/null 2>&1 || die "找不到 ssh 命令"
  command -v lockf >/dev/null 2>&1 || die "找不到 macOS lockf 命令"
  command -v perl >/dev/null 2>&1 || die "找不到 perl 命令"
  detect_rsync || die "$RSYNC_ERR"
}

rsync_exclude_pat() {
  local p="$1"
  case "$p" in *"/**") p="${p%/**}/" ;; esac
  printf '%s' "$p"
}

# 生成有序过滤器（先排除后包含；排除的路径在远端也不会被删除）
build_rsync_rules() {
  local line
  RSYNC_RULES=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      !*) RSYNC_RULES+=( -f "+ ${line#!}" ) ;;
      *"/**")
        # "目录/**"：遍历时排除整个目录（不进入）；按清单推送（--files-from）时不经过目录遍历，
        # 还要用 "目录/**" 直接匹配清单里的文件路径，否则被排除目录里的文件仍会被推上去
        RSYNC_RULES+=( -f "- $(rsync_exclude_pat "$line")" -f "- $line" ) ;;
      *)  RSYNC_RULES+=( -f "- $(rsync_exclude_pat "$line")" ) ;;
    esac
  done < "$PATTERN_EXC"
  if [ -s "$PATTERN_INC" ]; then
    RSYNC_RULES+=( -f "+ */" )
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      RSYNC_RULES+=( -f "+ $line" )
    done < "$PATTERN_INC"
    RSYNC_RULES+=( -f "- *" )
  fi
}

ssh_sock() { printf '%s/ssh/cm-%s@%s:%s' "$STATE" "$P_USER" "$P_HOST" "${P_PORT:-22}"; }

build_ssh_argv() {
  SSH_ARGS=( ssh -p "${P_PORT:-22}" )
  if [ -n "$P_KEY_FILE" ]; then SSH_ARGS+=( -i "$P_KEY_FILE" ); fi
  if [ -n "$G_KNOWN_HOSTS" ]; then
    SSH_ARGS+=( -o "UserKnownHostsFile=$G_KNOWN_HOSTS" -o StrictHostKeyChecking=yes )
  else
    SSH_ARGS+=( -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no )
  fi
  if [ "$G_SSH_MULTIPLEX" = "true" ]; then
    mkdir -p "$STATE/ssh"; chmod 700 "$STATE/ssh" 2>/dev/null || true
    SSH_ARGS+=( -o ControlMaster=auto -o "ControlPath=$STATE/ssh/cm-%r@%h:%p" -o "ControlPersist=$G_SSH_PERSIST" )
  fi
  SSH_ARGS+=( -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15
              -o ServerAliveCountMax=3 -o TCPKeepAlive=yes )
}

build_ssh_e() {
  local s="" a
  build_ssh_argv
  for a in "${SSH_ARGS[@]}"; do s="$s $a"; done
  printf '%s' "${s# }"
}

# 复用的主连接可能已在休眠/换网后失效：探测一下，死了就丢弃
ssh_master_check() {
  [ "$G_SSH_MULTIPLEX" = "true" ] || return 0
  local sock; sock="$(ssh_sock)"
  [ -S "$sock" ] || return 0
  if ! ssh -O check -p "${P_PORT:-22}" -o ControlPath="$sock" -o BatchMode=yes \
       -o ConnectTimeout=3 "$P_USER@$P_HOST" >/dev/null 2>&1; then
    rm -f "$sock" 2>/dev/null || true
  fi
  return 0
}

# 停止时关掉复用连接：卡住多半是连接坏了，下次重新建立
ssh_master_drop() {
  [ "$G_SSH_MULTIPLEX" = "true" ] || return 0
  local sock; sock="$(ssh_sock)"
  [ -S "$sock" ] || return 0
  ssh -O exit -p "${P_PORT:-22}" -o ControlPath="$sock" "$P_USER@$P_HOST" >/dev/null 2>&1 || true
  rm -f "$sock" 2>/dev/null || true
}

kill_tree() {
  local IFS=$' \t\n' sig="$1" pid="$2" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$sig" "$child"; done
  kill "-$sig" "$pid" 2>/dev/null || true
}

remote_chown_transferred() {
  local prof="$1" paths_file="$2" rc owner="$P_REMOTE_OWNER"
  [ -n "$owner" ] || return 0
  [ -s "$paths_file" ] || return 0
  build_ssh_argv
  local remote_cmd
  remote_cmd="cd $(printf '%q' "$P_REMOTE") && xargs -0 chown -h -- $(printf '%q' "$owner")"
  set +e
  {
    while IFS= read -r rel || [ -n "$rel" ]; do
      case "$rel" in ''|./) continue ;; esac
      printf '%s\0' "$rel"
    done < "$paths_file"
  } | "${SSH_ARGS[@]}" "$P_USER@$P_HOST" "$remote_cmd"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    warn "[$prof] 远端 chown（${owner}）失败（退出码 ${rc}）"
    return "$rc"
  fi
  return 0
}

# ------------------------------------------------------------------------------
# 进度解析器（perl）：读 rsync 输出（--out-format='%o|%n' + --info=progress2），
# 每 0.25 秒把实时进度原子写入 <规则>.run.json，并把传输/删除的路径记到清单。
# ------------------------------------------------------------------------------
progress_parser() {
  perl -e '
    use strict; use warnings; use Time::HiRes qw(time);
    my %e = map { $_ => ($ENV{"FS_".uc $_} // "") } qw(run_json names rule trigger started run_id echo total_hint);
    sub js { my $s = shift; $s = "" unless defined $s; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
             $s =~ s/\n/\\n/g; $s =~ s/\r//g; $s =~ s/\t/\\t/g; $s =~ s/([\x00-\x1f])/sprintf("\\u%04x",ord $1)/ge; return "\"$s\""; }
    my ($files, $del) = (0, 0);
    if (open my $nf, "<", $e{names}) { while (<$nf>) { $files++ if /^F\t.*[^\/]\n?$/; $del++ if /^D\t/; } close $nf; }
    open my $out, ">>", $e{names} or die "names: $!"; $out->autoflush(1);
    my ($phase, $bytes, $pct, $rate, $eta, $chk_done, $chk_total) = ("connecting", 0, 0, "", "", 0, 0);
    my ($cur, $cur_t) = ("", 0);
    my $last = 0;
    my $skipped = $ENV{FS_SKIPPED} // "";
    sub rate_bps { my $r = shift; return 0 unless $r =~ /^([\d.]+)([kMGT]?)B\/s$/; my %m = ("" => 1, k => 1024, M => 1024**2, G => 1024**3, T => 1024**4); return int($1 * $m{$2}); }
    sub eta_s { my $t = shift; return undef unless $t =~ /^(\d+):(\d+):(\d+)$/; return $1*3600 + $2*60 + $3; }
    sub write_state {
      my $now = time;
      my $tmp = "$e{run_json}.tmp.$$";
      open my $j, ">", $tmp or return;
      my $eta = eta_s($eta);
      printf $j "{\"v\":1,\"rule\":%s,\"run_id\":%s,\"trigger\":%s,\"phase\":%s,\"started_at\":%d,\"updated_at\":%.3f,"
        . "\"files_done\":%d,\"deleted\":%d,\"files_hint\":%d,\"checked\":%d,\"check_total\":%d,\"bytes_done\":%d,"
        . "\"percent\":%d,\"speed_bps\":%d,\"eta_s\":%s,\"current_file\":%s,\"current_started_at\":%.3f,\"skipped\":[%s]}\n",
        js($e{rule}), js($e{run_id}), js($e{trigger}), js($phase), $e{started} || 0, $now,
        $files, $del, ($e{total_hint} || 0), $chk_done, $chk_total, $bytes, $pct, rate_bps($rate),
        (defined $eta ? $eta : "null"), js($cur), $cur_t, $skipped;
      close $j; rename $tmp, $e{run_json};
      $last = $now;
    }
    write_state();
    my $buf = "";
    my $rin = ""; vec($rin, fileno(STDIN), 1) = 1;
    while (1) {
      my $nf = select(my $rout = $rin, undef, undef, 0.25);
      if ($nf <= 0) { write_state(); next; }
      my $n = sysread(STDIN, my $chunk, 65536);
      last unless $n;
      $buf .= $chunk;
      while ($buf =~ s/^([^\r\n]*)[\r\n]//) {
        my $l = $1;
        if ($l =~ /^\s*([\d,]+)\s+(\d+)%\s+(\S+)\s+(\d+:\d+:\d+)(?:\s+\(xfr#\d+, (?:to|ir)-chk=(\d+)\/(\d+)\))?/) {
          ($bytes, $pct, $rate, $eta) = ($1, $2, $3, $4); $bytes =~ s/,//g;
          if (defined $5) { $chk_total = $6; $chk_done = $6 - $5; }
          $phase = "transferring" if $phase ne "transferring" && $cur ne "";
          $phase = "scanning" if $phase eq "connecting";
        } elsif ($l =~ /^(send|recv|del\.)\|(.*)$/) {
          my ($op, $name) = ($1, $2);
          if ($op eq "del.") { $del++; print $out "D\t$name\n"; print STDERR "删除 $name\n" if $e{echo}; }
          else {
            print $out "F\t$name\n";
            if ($name !~ m{/$}) { $files++; $cur = $name; $cur_t = time; $phase = "transferring"; print STDERR "$name\n" if $e{echo}; }
          }
        } elsif ($l =~ /\S/ && $phase eq "connecting") {
          $phase = "scanning";
        }
        write_state() if time - $last >= 0.25;
      }
    }
    write_state();
  '
}

# 从 ssh / rsync 错误输出判断失败类型
classify_error() {
  local rc="$1" err="$2"
  if grep -qiE 'Permission denied|Authentication failed|Too many authentication' "$err" 2>/dev/null; then
    printf 'auth'
  elif grep -qiE 'Host key verification failed|REMOTE HOST IDENTIFICATION|No .* host key is known' "$err" 2>/dev/null; then
    printf 'hostkey'
  elif [ "$rc" = 255 ] || [ "$rc" = 12 ] || [ "$rc" = 30 ] || [ "$rc" = 35 ] || [ "$rc" = 10 ] ||
       grep -qiE 'Connection (timed out|refused|reset|closed)|Broken pipe|Could not resolve|Network is unreachable|timeout' "$err" 2>/dev/null; then
    printf 'network'
  else
    printf 'remote'
  fi
}

error_summary() {
  local kind="$1" rc="$2" err="$3" line
  case "$kind" in
    auth)    printf 'SSH 认证失败（检查 key_file / ssh-agent）'; return ;;
    hostkey) printf '主机指纹未受信（先执行 ssh-keyscan 并核对）'; return ;;
  esac
  line="$(grep -vE '^\s*$|^rsync error: .*\(code|^rsync: \[sender\] write error|connection unexpectedly closed' "$err" 2>/dev/null | tail -1 | cut -c1-160)"
  if [ -z "$line" ]; then
    case "$kind" in network) line="SSH 连接中断" ;; *) line="rsync 失败" ;; esac
  fi
  printf '%s（退出码 %s）' "$line" "$rc"
}

# 只保留最近 HISTORY_MAX 条记录，并删除界面再也显示不到的文件：
#   · 被裁掉的记录对应的 runs/<id>.tsv / .err 立即删除
#   · 没有任何记录引用的残留文件，超过 60 秒才删（刚写完清单、还没来得及追加记录的同步不能误删）
# 调用方需持有日志锁（with_history_lock）
prune_history() {
  [ -f "$HISTORY" ] || return 0
  FS_MAX="$HISTORY_MAX" perl -e '
    use strict; use warnings;
    my ($hist, $dir) = @ARGV;
    my $max = $ENV{FS_MAX} =~ /^\d+$/ ? $ENV{FS_MAX} : 1000;
    open my $in, "<", $hist or exit 0;
    my @all = grep { /\S/ } <$in>;
    close $in;
    # "无变化"的成功记录不显示，也不保留（旧版本曾经记录过）
    my @l = grep { !(/"result":"ok"/ && /"files":0,/ && /"deleted":0,/ && /"skipped":\[\]/) } @all;
    my (%keep, %drop);
    if (@l > $max) {
      for (splice @l, 0, @l - $max) { $drop{$1} = 1 if /"run_id":"([^"]+)"/ }
    }
    if (@l != @all) {
      my $tmp = "$hist.tmp.$$";
      open my $o, ">", $tmp or exit 1;
      print $o @l;
      close $o or exit 1;
      rename $tmp, $hist or exit 1;
    }
    for (@l) { $keep{$1} = 1 if /"run_id":"([^"]+)"/ }
    opendir my $d, $dir or exit 0;
    for my $f (readdir $d) {
      next unless $f =~ /^(.+)\.(?:tsv|err)$/;
      my $id = $1;
      next if $keep{$id};
      my $age = time - ((stat "$dir/$f")[9] // time);
      unlink "$dir/$f" if $drop{$id} || $age > 60;
    }
  ' "$HISTORY" "$RUNS_DIR"
}

# 日志读写锁：多个项目并行同步时，追加与裁剪不能交错（否则裁剪会覆盖掉别人刚追加的记录）
with_history_lock() {
  local rc=0
  mkdir -p "$STATE" "$RUNS_DIR"
  exec 6>"$STATE/history.lock"
  lockf -s 6 || true
  "$@" || rc=$?
  exec 6>&-
  return "$rc"
}

append_history_locked() {
  printf '%s\n' "$1" >> "$HISTORY"
  prune_history
}

append_history() {
  with_history_lock append_history_locked "$1"
}

# 终端单行进度：从 run.json 读数据，原地刷新
term_progress_loop() {
  local f="$1" prof="$2" s phase files pct speed cur chk tot spd line
  while :; do
    if [ -f "$f" ]; then
      s="$(cat "$f" 2>/dev/null || true)"
      phase="$(printf '%s' "$s" | sed -nE 's/.*"phase":"([a-z]+)".*/\1/p')"
      files="$(printf '%s' "$s" | sed -nE 's/.*"files_done":([0-9]+).*/\1/p')"
      pct="$(printf '%s' "$s" | sed -nE 's/.*"percent":([0-9]+).*/\1/p')"
      speed="$(printf '%s' "$s" | sed -nE 's/.*"speed_bps":([0-9]+).*/\1/p')"
      chk="$(printf '%s' "$s" | sed -nE 's/.*"checked":([0-9]+).*/\1/p')"
      tot="$(printf '%s' "$s" | sed -nE 's/.*"check_total":([0-9]+).*/\1/p')"
      cur="$(printf '%s' "$s" | sed -nE 's/.*"current_file":"(([^"\\]|\\.)*)".*/\1/p')"
      case "$phase" in
        connecting) line="连接中…" ;;
        scanning)   line="比对中 ${chk:-0}/${tot:-?}" ;;
        *)
          spd="$(awk -v b="${speed:-0}" 'BEGIN{ if (b>=1048576) printf "%.1f MB/s", b/1048576; else printf "%.0f KB/s", b/1024 }')"
          line="传输中 ${pct:-0}% · 已传 ${files:-0} 个 · ${spd}"
          [ -n "$cur" ] && line="${line} · ${cur}" ;;
      esac
      line="[$prof] $line"
      printf '\r\033[K%s' "$(printf '%s' "$line" | cut -c1-$(( $(tput cols 2>/dev/null || echo 100) - 1 )))" >&2
    fi
    /bin/sleep 0.3
  done
}

# ------------------------------------------------------------------------------
# 执行一条规则的一次同步。
#   run_rule <规则> <trigger> [清单文件]
#   trigger: change（监听到改动，只推清单）| full（全量）| push（手动推清单）
#            | pull（从远端下载清单里的路径）| preview（pull 预演，只列出变化）
# 返回: 0 成功 / 130 已停止 / 75 规则正忙（--no-wait）/ 其他 = 失败
# ------------------------------------------------------------------------------
run_rule() {
  local prof="$1" trigger="$2" list="${3:-}"
  load_profile "$prof"
  validate_profile "$prof"
  ensure_dirs
  build_rsync_rules
  rm -rf "$PATDIR" 2>/dev/null || true

  # ---- 每规则锁：不同规则并行，同一规则串行 ----
  exec 9>"$LOCK_DIR/$prof.lock"
  if ! lockf -s -t 0 9; then
    if [ "$OPT_NOWAIT" = "1" ]; then
      exec 9>&-
      info "[$prof] 正在同步中，已放弃（--no-wait）"
      return 75
    fi
    info "[$prof] 正在同步中，等待当前同步结束…（可执行 $APP cancel $prof 停止它）"
    lockf -s 9 || { exec 9>&-; return 1; }
  fi

  local run_id t0 work run_json last_json names err
  run_id="$(now).$$.$RANDOM"
  t0="$(now)"
  work="$(mktemp -d "$STATE/run.XXXXXX")"
  run_json="$STATUS_DIR/$prof.run.json"
  last_json="$STATUS_DIR/$prof.last.json"
  names="$work/names"
  err="$work/err"
  : > "$names"
  rm -f "$CTL_DIR/$prof.cancel" "$CTL_DIR/$prof.skip"

  # ---- 清单拆分：存在的推送；不存在的按 delete 决定删远端还是忽略 ----
  local flist="$work/files" nfiles=0 rel
  : > "$flist"
  if [ -n "$list" ]; then
    while IFS= read -r rel || [ -n "$rel" ]; do
      rel="${rel#./}"; rel="${rel#/}"
      [ -n "$rel" ] || continue
      case "$trigger" in
        pull|preview) printf '%s\n' "$rel" >> "$flist" ;;
        *)
          if [ -e "$P_LOCAL/$rel" ] || [ -L "$P_LOCAL/$rel" ] || [ "$P_DELETE" = "true" ]; then
            printf '%s\n' "$rel" >> "$flist"
          fi ;;
      esac
    done < <(LC_ALL=C sort -u "$list")
    nfiles="$(wc -l < "$flist" | tr -d ' ')"
    if [ "$nfiles" = 0 ]; then
      exec 9>&-; rm -rf "$work"
      return 0
    fi
  fi

  local src dst sshbin
  sshbin="$(build_ssh_e)"
  ssh_master_check
  case "$trigger" in
    pull|preview) src="$P_USER@$P_HOST:$P_REMOTE/"; dst="$P_LOCAL/" ;;
    *)            src="$P_LOCAL/"; dst="$P_USER@$P_HOST:$P_REMOTE/" ;;
  esac

  local args=( -rlt --no-links --omit-dir-times --timeout=60 --outbuf=L
               --info=progress2 --out-format='%o|%n' )
  case "$trigger" in
    full)
      args+=( --no-inc-recursive )
      [ "$P_DELETE" = "true" ] && args+=( --delete )
      ;;
    change|push)
      args+=( "--files-from=$flist" --checksum )
      # --checksum：rsync 默认只看 size + 整秒 mtime，同一秒内改写且大小不变会被误判为未变化
      if [ "$P_DELETE" = "true" ]; then args+=( --delete-missing-args ); else args+=( --ignore-missing-args ); fi
      ;;
    pull)    args+=( "--files-from=$flist" --ignore-missing-args ) ;;
    preview) args+=( "--files-from=$flist" --ignore-missing-args --dry-run ) ;;
  esac
  [ "$OPT_DRY" = "1" ] && [ "$trigger" != "preview" ] && args+=( --dry-run )
  local extra=()
  if [ -n "$P_EXTRA" ]; then set -f; extra=( $P_EXTRA ); set +f; fi

  local verb
  case "$trigger" in
    change)  verb="推送 ${nfiles} 个改动" ;;
    full)    verb="全量同步" ;;
    push)    verb="上传 ${nfiles} 项" ;;
    pull)    verb="从远端下载 ${nfiles} 项" ;;
    preview) verb="下载预览" ;;
  esac
  [ "$trigger" = "preview" ] || info "[$(ts)] [$prof] ${verb} $P_LOCAL → $P_USER@$P_HOST:$P_REMOTE"

  local tty_pid=""
  if [ "$trigger" != "preview" ] && [ "${DAEMON:-0}" != "1" ] && [ "$OPT_VERBOSE" != "1" ] && [ -t 2 ]; then
    term_progress_loop "$run_json" "$prof" &
    tty_pid=$!
  fi

  # ---- 执行：支持停止、跳过（重启剩余部分）、断线快速重试 ----
  local rc=0 attempt=1 cancelled=0 skipped_json="" skip_excl=() rpid ppid target skip_n=0
  # 手动"从远端下载"是用户明确选中的路径：不受该规则 include / exclude 的限制
  local filter_rules=()
  case "$trigger" in pull|preview) ;; *) filter_rules=( "${RSYNC_RULES[@]}" ) ;; esac
  local fifo="$work/pipe"
  while :; do
    rm -f "$fifo"; mkfifo "$fifo"
    FS_RUN_JSON="$run_json" FS_NAMES="$names" FS_RULE="$prof" FS_TRIGGER="$trigger" \
    FS_STARTED="$t0" FS_RUN_ID="$run_id" FS_SKIPPED="$skipped_json" FS_TOTAL_HINT="$nfiles" \
    FS_ECHO="$( [ "$OPT_VERBOSE" = 1 ] && [ "${DAEMON:-0}" != 1 ] && echo 1 )" \
      progress_parser < "$fifo" &
    ppid=$!
    LC_ALL=C "$RSYNC_BIN" "${args[@]}" "${filter_rules[@]}" "${skip_excl[@]}" -e "$sshbin" \
      "${extra[@]}" "$src" "$dst" > "$fifo" 2>> "$err" &
    rpid=$!
    local restart=0
    while kill -0 "$rpid" 2>/dev/null; do
      if [ -f "$CTL_DIR/$prof.cancel" ]; then
        rm -f "$CTL_DIR/$prof.cancel"
        cancelled=1
        kill_tree TERM "$rpid"
        break
      fi
      if [ -f "$CTL_DIR/$prof.skip" ]; then
        target="$(head -1 "$CTL_DIR/$prof.skip" 2>/dev/null || true)"
        rm -f "$CTL_DIR/$prof.skip"
        if [ -z "$target" ]; then
          target="$(sed -nE 's/.*"current_file":"(([^"\\]|\\.)*)".*/\1/p' "$run_json" 2>/dev/null || true)"
        fi
        if [ -n "$target" ]; then
          info "[$(ts)] [$prof] 跳过 $target"
          skipped_json="${skipped_json}${skipped_json:+,}$(json_str "$target")"
          skip_n=$((skip_n + 1))
          if [ -s "$flist" ]; then
            grep -vxF -- "$target" "$flist" > "$flist.new" || true
            mv -f "$flist.new" "$flist"
          fi
          skip_excl+=( -f "- /$target" )
          restart=1
          kill_tree TERM "$rpid"
          break
        fi
      fi
      /bin/sleep 0.2
    done
    set +e
    wait "$rpid" 2>/dev/null; rc=$?
    wait "$ppid" 2>/dev/null
    if [ "$restart" = 1 ]; then
      # 被跳过的文件已经在清单里登记为"开始传输"，从计数中去掉
      grep -vxF -- "F	$target" "$names" > "$names.new" || true
      mv -f "$names.new" "$names"
    fi
    set -e
    [ "$rc" -eq 24 ] && rc=0
    if [ "$cancelled" = 1 ]; then rc=130; break; fi
    if [ "$restart" = 1 ]; then
      case "$trigger" in change|push|pull) [ -s "$flist" ] || { rc=0; break; } ;; esac
      continue
    fi
    if [ "$rc" -eq 255 ] && [ "$attempt" -lt 3 ] && [ "$trigger" != "preview" ] &&
       ! grep -qiE 'Permission denied|Host key verification failed|REMOTE HOST IDENTIFICATION' "$err"; then
      warn "[$prof] 连接被中断（退出码 255），第 ${attempt}/2 次重试"
      ssh_master_drop
      /bin/sleep "$attempt"
      attempt=$((attempt + 1))
      continue
    fi
    break
  done

  if [ -n "$tty_pid" ]; then kill "$tty_pid" 2>/dev/null || true; wait "$tty_pid" 2>/dev/null || true; printf '\r\033[K' >&2; fi
  [ "$cancelled" = 1 ] && ssh_master_drop

  local files deleted dur
  files="$(grep -cE '^F	.*[^/]$' "$names" 2>/dev/null || true)"; files="${files:-0}"
  deleted="$(grep -c '^D	' "$names" 2>/dev/null || true)"; deleted="${deleted:-0}"

  # 预览：输出将新增/覆盖的本地文件，不记录历史
  if [ "$trigger" = "preview" ]; then
    rm -f "$run_json"; exec 9>&-
    if [ "$rc" -ne 0 ]; then
      local k; k="$(classify_error "$rc" "$err")"
      printf '{"ok":false,"rule":%s,"error":%s}\n' "$(json_str "$prof")" "$(json_str "$(error_summary "$k" "$rc" "$err")")"
      rm -rf "$work"; return "$rc"
    fi
    local newf="$work/new" over="$work/over" p
    : > "$newf"; : > "$over"
    sed -nE 's/^F	(.*[^/])$/\1/p' "$names" | while IFS= read -r p; do
      if [ -e "$P_LOCAL/$p" ]; then printf '%s\n' "$p" >> "$over"; else printf '%s\n' "$p" >> "$newf"; fi
    done
    printf '{"ok":true,"rule":%s,"local":%s,"new_count":%s,"overwrite_count":%s,"new":%s,"overwrite":%s}\n' \
      "$(json_str "$prof")" "$(json_str "$P_LOCAL")" \
      "$(wc -l < "$newf" | tr -d ' ')" "$(wc -l < "$over" | tr -d ' ')" \
      "$(head -200 "$newf" > "$newf.h"; json_lines "$newf.h")" "$(head -200 "$over" > "$over.h"; json_lines "$over.h")"
    rm -rf "$work"
    return 0
  fi

  if [ "$rc" -eq 0 ] && [ "$OPT_DRY" != "1" ] && [ "$trigger" != "pull" ] &&
     [ -n "$P_REMOTE_OWNER" ] && [ "$files" != "0" ]; then
    sed -nE 's/^F	(.*)$/\1/p' "$names" > "$work/chown"
    remote_chown_transferred "$prof" "$work/chown" || rc=$?
  fi

  dur=$(( $(now) - t0 ))
  local result kind="" msg="" line acked
  if [ "$rc" -eq 0 ]; then
    result="ok"; acked=true
    line=""
    [ "$files" != 0 ] && line="同步 ${files} 个文件"
    [ "$deleted" != 0 ] && line="${line}${line:+、}删除 ${deleted} 个"
    [ -n "$line" ] || line="无变化"
    [ "$skip_n" -gt 0 ] && line="${line}（跳过 ${skip_n} 个）"
  elif [ "$rc" -eq 130 ]; then
    result="cancelled"; acked=true; line="已停止（已传 ${files} 个，其余丢弃）"
  else
    result="failed"; acked=false
    kind="$(classify_error "$rc" "$err")"
    msg="$(error_summary "$kind" "$rc" "$err")"
    line="失败：${msg}"
    cat "$err" >> "$RUN_LOG" 2>/dev/null || true
    [ "$kind" = hostkey ] && printf '        提示: ssh-keyscan -p %s %s >> %s\n' "${P_PORT:-22}" "$P_HOST" "$G_KNOWN_HOSTS" >&2
  fi
  [ "$OPT_DRY" = 1 ] && line="（预演）${line}"

  # 本次同步的文件清单：U 上传 / G 下载 / D 远端删除 / S 跳过（目录项不记）
  local runlist="$RUNS_DIR/$run_id.tsv" sample=""
  if [ "$OPT_DRY" != 1 ]; then
    mkdir -p "$RUNS_DIR"
    {
      if [ "$trigger" = pull ]; then sed -nE 's/^F	(.*[^/])$/G	\1/p' "$names"
      else sed -nE 's/^F	(.*[^/])$/U	\1/p' "$names"; fi
      sed -nE 's/^D	(.*)$/D	\1/p' "$names"
      [ -n "$skipped_json" ] && printf '%s' "[$skipped_json]" | perl -ne 'while (/"((?:[^"\\]|\\.)*)"/g) { (my $p = $1) =~ s/\\(.)/$1/g; print "S\t$p\n" }'
    } > "$runlist" 2>/dev/null || true
    [ -s "$runlist" ] || rm -f "$runlist"
    if [ -s "$runlist" ]; then
      sample="$(head -3 "$runlist" | while IFS= read -r l; do printf ',%s' "$(json_str "$l")"; done)"
      sample="${sample#,}"
    fi
    if [ "$result" = failed ]; then tail -n 30 "$err" > "$RUNS_DIR/$run_id.err" 2>/dev/null || true; fi
  fi

  local rec
  rec="{\"v\":1,\"rule\":$(json_str "$prof"),\"run_id\":$(json_str "$run_id"),\"trigger\":$(json_str "$trigger"),\"result\":$(json_str "$result"),\"started_at\":$t0,\"finished_at\":$(now),\"duration_s\":$dur,\"files\":$files,\"deleted\":$deleted,\"skipped\":[${skipped_json}],\"error_kind\":$(json_str "$kind"),\"error\":$(json_str "$msg"),\"summary\":$(json_str "$line"),\"sample\":[${sample}],\"dry_run\":$( [ "$OPT_DRY" = 1 ] && echo true || echo false ),\"acked\":$acked}"
  if [ "$OPT_DRY" != 1 ]; then
    printf '%s\n' "$rec" | atomic_write "$last_json"
    # "无变化"的成功同步不写日志（项目卡片上的"最近结果"照常更新）
    if [ "$result" != ok ] || [ "$files" != 0 ] || [ "$deleted" != 0 ] || [ "$skip_n" -gt 0 ]; then
      append_history "$rec"
    fi
  fi
  rm -f "$run_json"
  printf '[%s] [%s] %s（耗时 %ss）\n' "$(ts)" "$prof" "$line" "$dur" | tee -a "$RUN_LOG"
  if [ "$result" = failed ] && [ "${DAEMON:-0}" != 1 ]; then sed -n '1,10p' "$err" >&2; fi
  exec 9>&-
  rm -rf "$work"
  return "$rc"
}

# ============================== 守护进程 ==============================

daemon_alive() {
  local pid
  pid="$(cat "$STATE/daemon.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -p "$STATE/events.fifo" ]
}

send_event() {
  daemon_alive || return 1
  # 非阻塞写：守护持有读写端，正常不会阻塞；加超时以防万一
  ( printf '%s\n' "$1" > "$STATE/events.fifo" ) &
  local w=$!
  local i=0
  while kill -0 "$w" 2>/dev/null && [ "$i" -lt 20 ]; do /bin/sleep 0.1; i=$((i+1)); done
  kill "$w" 2>/dev/null && return 1
  return 0
}

# 取出某规则的待推清单（短锁内交换，监听器的追加不会丢）
take_pending() {
  local prof="$1" dest="$2" list="$PEND_DIR/$prof.list"
  : > "$dest"
  exec 7>"$PEND_DIR/$prof.lock"
  lockf -s 7 || { exec 7>&-; return 1; }
  if [ -s "$list" ]; then
    cat "$list" > "$dest"
    : > "$list"
  fi
  exec 7>&-
  return 0
}

worker_loop() {
  local prof="$1" batch="$PEND_DIR/$prof.batch"
  while :; do
    if [ -f "$PEND_DIR/$prof.full" ]; then
      rm -f "$PEND_DIR/$prof.full"
      take_pending "$prof" "$batch" || true     # 全量会覆盖这些改动
      ( run_rule "$prof" full ) || true
      continue
    fi
    take_pending "$prof" "$batch" || break
    if [ ! -s "$batch" ]; then
      # 取空后先别急着退出：新写入可能刚好落在"取空"和"退出"之间
      /bin/sleep 0.3
      take_pending "$prof" "$batch" || break
      [ -s "$batch" ] || break
    fi
    ( run_rule "$prof" change "$batch" ) || true
  done
  rm -f "$batch"
}

start_worker() {
  local prof="$1" pidf="$WORKER_DIR/$1.pid" pid
  pid="$(cat "$pidf" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  (
    exec 3>&- 8>&-
    worker_loop "$prof"
    printf 'wdone:%s\n' "$prof" > "$STATE/events.fifo" 2>/dev/null || true
  ) &
  printf '%s\n' "$!" > "$pidf"
}

workers_alive() {
  local f pid
  for f in "$WORKER_DIR"/*.pid; do
    [ -f "$f" ] || continue
    pid="$(cat "$f" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 0; fi
  done
  return 1
}

# 列出某进程的全部后代（不含看门狗和 stderr 过滤器）
list_descendants() {
  # 可能在 trap 里执行：此时 IFS 可能被 `IFS= read` 临时置空，必须恢复默认才能按行拆分 PID
  local IFS=$' \t\n' pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    case "$child" in "${ERR_FILTER_PID:-__none__}"|"${WATCHDOG_PID:-__none__}") continue ;; esac
    printf '%s\n' "$child"
    list_descendants "$child"
  done
}

# 先记下整棵进程树再发信号：父 shell 先退出后，fswatch 会被收养，届时按父子关系就找不到了
kill_descendants() {
  local IFS=$' \t\n' pids p
  pids="$(list_descendants "$1")"
  [ -n "$pids" ] || return 0
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  /bin/sleep 0.3
  for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
  return 0
}

config_stamp() { stat -f '%m.%z' "$CONFIG" 2>/dev/null || echo none; }

start_watcher() {
  local p="$1" names="$2"
  load_profile "$p"
  [ -d "$P_LOCAL" ] || return 0
  local WATCH_ROOT WATCH_LIST WATCH_GEN WATCH_EX=""
  WATCH_ROOT="$(cd "$P_LOCAL" && pwd -P)"
  WATCH_LIST="$PEND_DIR/$p.list"
  WATCH_GEN="$PEND_DIR/$p.gen"
  [ -n "$names" ] && WATCH_EX="^$(ere_escape "$WATCH_ROOT")/(.*/)?($names)(/|$)"
  local fifo="$STATE/events.fifo"
  (
    exec 3>&- 8>&- 9>&-
    trap 'exit 0' TERM INT
    burst_n=0; burst_t0=0
    while :; do
      if [ -n "$WATCH_EX" ]; then
        fswatch -r --latency "$G_DEBOUNCE" --format '%f|%p' --event-flag-separator=, --exclude "$WATCH_EX" "$WATCH_ROOT"
      else
        fswatch -r --latency "$G_DEBOUNCE" --format '%f|%p' --event-flag-separator=, "$WATCH_ROOT"
      fi | while IFS= read -r ev; do
        flags="${ev%%|*}"; evp="${ev#*|}"
        rel=""
        case "$evp" in
          "$WATCH_ROOT"/*)         rel="${evp#"$WATCH_ROOT"/}" ;;
          "/private$WATCH_ROOT"/*) rel="${evp#"/private$WATCH_ROOT"/}" ;;
        esac
        [ -n "$rel" ] || continue
        case ",$flags," in *,IsSymLink,*) continue ;; esac
        case ",$flags," in
          *,IsDir,*)
            # 目录只在新建 / 改名 / 删除时记录（推送时递归）；属性变化不触发整目录比对
            case ",$flags," in *,Created,*|*,Renamed,*|*,Removed,*|*,MovedFrom,*|*,MovedTo,*) ;; *) continue ;; esac ;;
        esac
        exec 7>"$PEND_DIR/$p.lock"
        lockf -s 7 || exit 1
        printf '%s\n' "$rel" >> "$WATCH_LIST"
        # 单调递增的版本号：同样的路径再次写入也算新事件，不会被去重吞掉
        wgen=0
        [ -s "$WATCH_GEN" ] && { IFS= read -r wgen < "$WATCH_GEN" || true; }
        case "$wgen" in ''|*[!0-9]*) wgen=0 ;; esac
        printf '%s\n' "$((wgen + 1))" > "$WATCH_GEN.tmp" && mv -f "$WATCH_GEN.tmp" "$WATCH_GEN"
        # 短时间大量事件（整目录复制、批量生成文件等）：逐文件清单不可靠也低效，
        # 直接丢弃清单并触发一次全量
        burst_hit=0
        if [ "${G_BURST_FULL:-0}" -gt 0 ] 2>/dev/null; then
          if [ "$burst_n" -eq 0 ] || [ $((SECONDS - burst_t0)) -gt 2 ]; then
            burst_n=1; burst_t0=$SECONDS
          else
            burst_n=$((burst_n + 1))
          fi
          if [ "$burst_n" -ge "$G_BURST_FULL" ]; then
            : > "$WATCH_LIST"
            burst_n=0; burst_t0=0
            burst_hit=1
          fi
        fi
        exec 7>&-
        [ "$burst_hit" = "1" ] && { send_event "full:$p" || true; }
      done
      wrc=${PIPESTATUS[0]:-0}
      case "$wrc" in 0|130|143) break ;; esac
      warn "[$p] fswatch 异常退出（退出码 ${wrc}），2 秒后重启监听"
      /bin/sleep 2
    done
  ) &
  # 通知主循环：按版本号判断，清单被清空后写入相同路径也会再次通知
  (
    exec 3>&- 8>&- 9>&-
    fl_gen=""
    while :; do
      /bin/sleep 0.1
      if [ -s "$WATCH_LIST" ]; then
        fl_cur="$(cat "$WATCH_GEN" 2>/dev/null || echo 0)"
        if [ "$fl_cur" != "$fl_gen" ]; then
          printf 'evt:%s\n' "$p" > "$fifo" 2>/dev/null || exit 0
          fl_gen="$fl_cur"
        fi
      fi
    done
  ) &
  info "[$(ts)] 监听 [$p] $P_LOCAL"
  start_git_watcher "$p" "$WATCH_ROOT" "$fifo"
}

# 监听 git 元数据：切分支 / merge / reset 等大范围改动会改写 .git/HEAD 和 reflog。
# 事件到达后先等 git 释放 index 锁（checkout 更新工作区期间一直持有），
# 再确认 1 秒内没有新一轮写入，才触发一次全量。
start_git_watcher() {
  local p="$1" root="$2" fifo="$3"
  local head="$root/.git/HEAD" reflog="$root/.git/logs/HEAD" lock="$root/.git/index.lock"
  [ "$G_GIT_TRIGGER" = "true" ] || return 0
  case "$P_DIRECTION" in local|both) ;; *) return 0 ;; esac
  [ -f "$head" ] || return 0
  local paths=("$head")
  [ -f "$reflog" ] && paths+=("$reflog")
  (
    exec 3>&- 8>&- 9>&-
    trap 'exit 0' TERM INT
    last_full=-100
    while :; do
      fswatch --latency "$G_DEBOUNCE" "${paths[@]}" 2>/dev/null | while IFS= read -r _; do
        # 等 git 写完工作区；异常残留的锁最多等 10 轮 × 60 秒
        tries=0
        while [ "$tries" -lt 10 ]; do
          wait_i=0
          while [ -e "$lock" ] && [ "$wait_i" -lt 600 ]; do
            /bin/sleep 0.1; wait_i=$((wait_i + 1))
          done
          /bin/sleep 1
          [ -e "$lock" ] || break
          tries=$((tries + 1))
        done
        # 一次切分支会同时改写 HEAD 和 reflog，3 秒内的重复事件只触发一次
        [ $((SECONDS - last_full)) -lt 3 ] && continue
        last_full=$SECONDS
        send_event "full:$p" || true
      done
      wrc=${PIPESTATUS[0]:-0}
      case "$wrc" in 0|130|143) break ;; esac
      warn "[$p] .git 监听异常退出（退出码 ${wrc}），2 秒后重启"
      /bin/sleep 2
    done
  ) &
}

cmd_daemon() {
  exec 4>&2
  exec 2> >(while IFS= read -r line || [ -n "$line" ]; do
    printf '[%s] %s\n' "$(ts)" "$line" >&4
  done)
  ERR_FILTER_PID=$!

  [ -f "$CONFIG" ] || die "找不到配置文件: ${CONFIG}（先执行 $APP init）"
  read_global
  need_tools
  ensure_dirs
  exec 8>"$STATE/daemon.lock"
  lockf -s -t 0 8 || die "已有一个守护进程在运行"
  touch "$RUN_LOG"
  printf '%s\n' "$$" > "$STATE/daemon.pid"
  DAEMON=1

  local profs="" p msg
  for p in $(list_profiles); do
    load_profile "$p"
    [ "$P_ENABLED" = "true" ] || continue
    if msg="$(check_profile "$p")"; then
      profs="$profs $p"
    else
      warn "${msg}（该规则不启动）"
    fi
  done
  rm -rf "$PATDIR" 2>/dev/null || true
  # 上次异常退出残留的运行状态 / 控制文件
  rm -f "$STATUS_DIR"/*.run.json "$CTL_DIR"/* "$WORKER_DIR"/*.pid "$PEND_DIR"/*.full "$PEND_DIR"/*.batch 2>/dev/null || true
  with_history_lock prune_history || true      # 启动时顺手清理日志：裁到上限、删掉不再显示的文件清单
  for p in $profs; do : > "$PEND_DIR/$p.list"; printf '0\n' > "$PEND_DIR/$p.gen"; done

  # 看门狗：launchd 只对主进程发 TERM；主进程消失时清掉整个进程组
  local pgid
  pgid="$(ps -o pgid= -p $$ | tr -d '[:space:]')"
  if [ -n "${FS_WATCHDOG_PID:-}" ] && kill -0 "$FS_WATCHDOG_PID" 2>/dev/null; then
    WATCHDOG_PID="$FS_WATCHDOG_PID"      # 重载前的看门狗盯的是同一个 PID，继续沿用
  elif [ "$pgid" = "$$" ]; then
    (
      exec 3>&- 7>&- 8>&- 9>&-
      exec perl -e '
        use POSIX qw(setsid);
        exit 0 unless defined setsid();
        my ($pid, $pgid) = @ARGV;
        while (kill 0, $pid) { sleep 1 }
        kill "TERM", -$pgid; sleep 1; kill "KILL", -$pgid;
      ' "$$" "$pgid" >/dev/null 2>&1
    ) &
    WATCHDOG_PID=$!
  fi

  local fifo="$STATE/events.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  exec 3<>"$fifo"

  DAEMON_CLEANED=0
  daemon_cleanup() {
    [ "$DAEMON_CLEANED" = "1" ] && return 0
    DAEMON_CLEANED=1
    trap '' TERM INT
    kill_descendants $$
    rm -f "$STATUS_DIR"/*.run.json 2>/dev/null || true
    return 0
  }
  cleanup() {
    trap - INT TERM EXIT
    daemon_cleanup
    exec 3>&- 2>/dev/null || true
    rm -f "$fifo" "$STATE/daemon.pid"
    rm -rf "$PATDIR" 2>/dev/null || true
    info "[$(ts)] 守护退出"
  }
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap cleanup EXIT

  info "[$(ts)] 守护启动，规则:${profs:- （无）}"
  info "[$(ts)] 改动即推送（去抖 ${G_DEBOUNCE} 秒）；切分支或大批量改动自动全量；不做定时 / 启动全量"

  if command -v fswatch >/dev/null 2>&1; then
    local names="" name
    for name in $G_WATCH_IGNORE; do
      name="$(ere_escape "$name")"
      names="${names}${names:+|}$name"
    done
    for p in $profs; do start_watcher "$p" "$names"; done
  else
    warn "未安装 fswatch，无法监听本地改动（brew install fswatch）；只能手动全量同步"
  fi
  rm -rf "$PATDIR" 2>/dev/null || true

  # 配置文件监听：变化后自动重载（等进行中的同步结束）
  local stamp0; stamp0="$(config_stamp)"
  (
    exec 3>&- 8>&- 9>&-
    s="$stamp0"
    while :; do
      /bin/sleep 2
      c="$(config_stamp)"
      if [ "$c" != "$s" ]; then
        s="$c"
        printf 'cfg\n' > "$fifo" 2>/dev/null || exit 0
      fi
    done
  ) &

  local RELOAD=0 ev r
  while IFS= read -r ev; do
    case "$ev" in
      evt:*|full:*)
        r="${ev#*:}"
        case " $profs " in *" $r "*) ;; *) continue ;; esac
        [ "${ev%%:*}" = full ] && : > "$PEND_DIR/$r.full"
        [ "$RELOAD" = 1 ] && continue          # 重载前不再启动新的同步
        start_worker "$r"
        ;;
      cfg)
        if /bin/bash "$SELF" validate >/dev/null 2>&1; then
          info "[$(ts)] 配置已变化，进行中的同步结束后自动重载"
          RELOAD=1
        else
          warn "配置已变化但校验未通过，继续使用旧配置（执行 $APP validate 查看原因）"
        fi
        ;;
      wdone:*) ;;
    esac
    if [ "$RELOAD" = 1 ] && ! workers_alive; then
      info "[$(ts)] 重载配置"
      trap - INT TERM EXIT
      daemon_cleanup
      exec 2>&4 3>&- 8>&- 4>&-
      rm -f "$fifo" "$STATE/daemon.pid"
      # daemon_cleanup 把 TERM/INT 设成了忽略；忽略状态会被 exec 继承且无法再 trap，必须先恢复
      trap - TERM INT
      FS_WATCHDOG_PID="${WATCHDOG_PID:-}" exec /bin/bash "$SELF" daemon
    fi
  done < "$fifo"
}

# ============================== 子命令 ==============================

# 选择规则：参数 / -p / "." 或路径（按目录归属识别）；空 = 全部启用的规则
resolve_rule_for_path() {
  local path="$1" abs p best="" bestlen=0 root
  if [ -d "$path" ]; then abs="$(cd "$path" && pwd -P)"
  elif [ -e "$path" ] || [ -L "$path" ]; then abs="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  else
    abs="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)/$(basename "$path")" || return 1
  fi
  for p in $(list_profiles); do
    load_profile "$p"
    [ -n "$P_LOCAL" ] && [ -d "$P_LOCAL" ] || continue
    root="$(cd "$P_LOCAL" && pwd -P)"
    case "$abs/" in
      "$root/"*)
        if [ "${#root}" -gt "$bestlen" ]; then best="$p"; bestlen="${#root}"; RESOLVED_ROOT="$root"; fi ;;
    esac
  done
  [ -n "$best" ] || return 1
  RESOLVED_ABS="$abs"
  RESOLVED_RULE="$best"
  return 0
}

select_profiles() {
  local out="" p want
  want="$OPT_PROFILE"
  if [ "${#ARGS[@]}" -gt 0 ]; then want="$want${want:+,}$(IFS=,; printf '%s' "${ARGS[*]}")"; fi
  if [ -n "$want" ]; then
    local oldifs="$IFS"; IFS=','
    for p in $want; do
      IFS="$oldifs"
      p="$(trim "$p")"
      [ -n "$p" ] || continue
      if is_profile "$p"; then out="$out $p"
      elif [ -e "$p" ] || [ "$p" = "." ]; then
        resolve_rule_for_path "$p" || die "路径 $p 不属于任何同步规则"
        out="$out $RESOLVED_RULE"
      else die "配置里没有名为 $p 的规则"; fi
      IFS=','
    done
    IFS="$oldifs"
  else
    for p in $(list_profiles); do
      load_profile "$p"
      [ "$P_ENABLED" = "true" ] && out="$out $p"
    done
  fi
  printf '%s' "$out"
}

write_example_config() {
  mkdir -p "$(dirname "$CONFIG")"
  if [ -f "$CONFIG" ]; then info "配置已存在，未覆盖: $CONFIG"; return 0; fi
  cat > "$CONFIG" <<'EXAMPLE'
# folder-sync 配置：每个 [名字] 段是一个项目（本地 → 远端单向推送）
# 可以直接在 FolderSync 应用里新增 / 编辑项目；手工修改后守护进程也会自动重载。

[global]
debounce = 1
known_hosts = ~/.ssh/known_hosts
ssh_multiplex = true
watch_ignore = .git node_modules .idea .vscode .DS_Store
# 切分支（.git/HEAD / reflog 变化）时自动触发一次全量
git_trigger = true
# 2 秒内收到的事件数达到该值时改走全量；0 = 关闭
burst_full = 100

# 示例（去掉行首的 # 并改成自己的值后生效）：
# [site]
# local = ~/work/site
# remote = /var/www/site
# host = example.com
# port = 22
# user = deploy
# key_file = ~/.ssh/id_ed25519
# # true = 本地删除的文件、全量时远端多余的文件会在远端直接删除（不可恢复）；exclude 的路径永不删除
# delete = false
# exclude = .git/**, node_modules/**, .DS_Store
EXAMPLE
  chmod 600 "$CONFIG" 2>/dev/null || true
  info "已生成配置模板: $CONFIG"
}

cmd_init() { write_example_config; }

disp_width() {
  local s="$1" ch cb
  ch="${#s}"
  cb="$(LC_ALL=C printf '%s' "$s" | wc -c | tr -d ' ')"
  printf '%s' $(( ch + (cb - ch) / 2 ))
}
pad_to() {
  local s="$1" want="$2" w
  w="$(disp_width "$s")"
  printf '%s' "$s"
  while [ "$w" -lt "$want" ]; do printf ' '; w=$(( w + 1 )); done
}

cmd_list() {
  [ -f "$CONFIG" ] || die "找不到配置文件: ${CONFIG}（先执行 $APP init）"
  read_global
  info "配置文件: $CONFIG"
  printf '%s %s %s %s\n' "$(pad_to 规则 16)" "$(pad_to 状态 6)" "$(pad_to 删除 6)" "路径"
  local p
  for p in $(list_profiles); do
    load_profile "$p"
    printf '%s %s %s %s\n' "$(pad_to "$p" 16)" "$(pad_to "$( [ "$P_ENABLED" = true ] && echo 启用 || echo 停用 )" 6)" \
      "$(pad_to "$( [ "$P_DELETE" = true ] && echo 是 || echo 否 )" 6)" "$P_LOCAL  →  $P_USER@$P_HOST:$P_REMOTE"
  done
}

cmd_validate() {
  [ -f "$CONFIG" ] || die "找不到配置文件: $CONFIG"
  read_global
  local p rc=0 msg seen=""
  for p in $(list_profiles); do
    case " $seen " in *" $p "*) info "[$p] 规则名重复"; rc=1; continue ;; esac
    seen="$seen $p"
    if [ -n "$OPT_PROFILE" ] && [ "$p" != "$OPT_PROFILE" ]; then continue; fi
    load_profile "$p"
    [ "$P_ENABLED" = true ] || [ -n "$OPT_PROFILE" ] || continue
    msg="$(check_profile "$p")" || { info "$msg"; rc=1; }
  done
  [ "$rc" = 0 ] && info "配置有效"
  return "$rc"
}

cmd_check() {
  read_global
  local profs; profs="$(select_profiles)"
  [ -n "$profs" ] || die "没有可运行的同步规则"
  need_tools
  local prof rc=0 out r
  for prof in $profs; do
    load_profile "$prof"; validate_profile "$prof"; build_rsync_rules; rm -rf "$PATDIR"
    info ""; info "=== [$prof] 差异对比"
    local oargs=(); [ "$P_DELETE" = true ] && oargs=( --delete )
    set +e
    out="$(LC_ALL=C "$RSYNC_BIN" -rlt --no-links --omit-dir-times -n -i "${oargs[@]}" "${RSYNC_RULES[@]}" \
      -e "$(build_ssh_e)" "$P_LOCAL/" "$P_USER@$P_HOST:$P_REMOTE/" 2>&1)"
    r=$?
    set -e
    out="$(printf '%s\n' "$out" | grep -v '^skipping non-regular file' || true)"
    [ -n "$out" ] && printf '%s\n' "$out"
    if [ "$r" -eq 0 ]; then
      if [ -n "$out" ]; then info "    存在差异"; rc=1; else info "    两端一致"; fi
    else
      info "    对比失败（退出码 ${r}）"; rc=$r
    fi
  done
  return "$rc"
}

# 全量同步（手动）。--bg：交给守护执行（守护未运行则后台起一个进程）后立即返回
cmd_sync() {
  read_global
  local profs; profs="$(select_profiles)"
  [ -n "$profs" ] || die "没有可运行的同步规则"
  need_tools
  ensure_dirs
  local prof rc=0 r
  if [ "$OPT_BG" = 1 ]; then
    for prof in $profs; do
      load_profile "$prof"; validate_profile "$prof"
      if send_event "full:$prof"; then info "[$prof] 已交给守护执行全量同步"
      else
        nohup /bin/bash "$SELF" sync "$prof" >> "$RUN_LOG" 2>&1 < /dev/null &
        info "[$prof] 已在后台开始全量同步"
      fi
    done
    return 0
  fi
  for prof in $profs; do
    set +e
    ( run_rule "$prof" full ); r=$?
    set -e
    if [ "$r" -ne 0 ]; then rc=$r; fi
  done
  return "$rc"
}

# 把命令行给出的路径换算成 <规则> + 相对路径清单
paths_to_list() {
  local listf="$1" p rel r
  RULE_OF_PATHS=""
  [ "${#ARGS[@]}" -gt 0 ] || die "请给出要处理的文件或文件夹路径"
  : > "$listf"
  for p in "${ARGS[@]}"; do
    resolve_rule_for_path "$p" || die "路径 $p 不属于任何同步规则"
    r="$RESOLVED_RULE"
    if [ -n "$RULE_OF_PATHS" ] && [ "$r" != "$RULE_OF_PATHS" ]; then
      die "所选路径属于不同规则（$RULE_OF_PATHS / ${r}），请分开操作"
    fi
    RULE_OF_PATHS="$r"
    rel="${RESOLVED_ABS#"$RESOLVED_ROOT"}"; rel="${rel#/}"
    [ -n "$rel" ] || rel="."
    printf '%s\n' "$rel" >> "$listf"
  done
}

cmd_push() {
  read_global; need_tools; ensure_dirs
  local listf; listf="$(mktemp "$STATE/push.XXXXXX")"
  paths_to_list "$listf"
  local rc=0
  set +e; ( run_rule "$RULE_OF_PATHS" push "$listf" ); rc=$?; set -e
  rm -f "$listf"
  return "$rc"
}

cmd_pull() {
  read_global; need_tools; ensure_dirs
  local listf; listf="$(mktemp "$STATE/pull.XXXXXX")"
  paths_to_list "$listf"
  local rc=0
  if [ "$OPT_PREVIEW" = 1 ]; then
    set +e; ( run_rule "$RULE_OF_PATHS" preview "$listf" ); rc=$?; set -e
  elif [ "$OPT_YES" != 1 ] && [ -t 0 ]; then
    local pv; pv="$( ( run_rule "$RULE_OF_PATHS" preview "$listf" ) )" || { printf '%s\n' "$pv"; rm -f "$listf"; return 1; }
    info "将从远端下载到 [$RULE_OF_PATHS]：新增 $(printf '%s' "$pv" | sed -nE 's/.*"new_count":([0-9]+).*/\1/p') 个，覆盖本地 $(printf '%s' "$pv" | sed -nE 's/.*"overwrite_count":([0-9]+).*/\1/p') 个（不会删除本地文件）"
    printf '确认下载？[y/N] '
    local ans; read -r ans
    case "$ans" in y|Y|yes) set +e; ( run_rule "$RULE_OF_PATHS" pull "$listf" ); rc=$?; set -e ;; *) info "已取消"; rc=1 ;; esac
  elif [ "$OPT_YES" = 1 ]; then
    set +e; ( run_rule "$RULE_OF_PATHS" pull "$listf" ); rc=$?; set -e
  else
    rm -f "$listf"; die "非交互环境请加 --yes 确认下载，或用 --preview 先查看"
  fi
  rm -f "$listf"
  return "$rc"
}

running_rules() {
  local f
  for f in "$STATUS_DIR"/*.run.json; do
    [ -f "$f" ] || continue
    basename "$f" .run.json
  done
}

cmd_cancel() {
  ensure_dirs
  local profs="" p n=0
  if [ "${#ARGS[@]}" -gt 0 ] || [ -n "$OPT_PROFILE" ]; then profs="$(select_profiles)"; else profs="$(running_rules)"; fi
  for p in $profs; do
    : > "$CTL_DIR/$p.cancel"
    # 停止 = 丢弃待传：清空排队中的改动与全量请求
    : > "$PEND_DIR/$p.list" 2>/dev/null || true
    rm -f "$PEND_DIR/$p.full"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { info "当前没有正在进行的同步"; return 0; }
  # 只有正在运行的才需要等它退出
  local i=0
  for p in $profs; do
    while [ -f "$STATUS_DIR/$p.run.json" ] && [ "$i" -lt 50 ]; do /bin/sleep 0.1; i=$((i + 1)); done
    if [ -f "$STATUS_DIR/$p.run.json" ]; then info "[$p] 已发出停止指令"
    else rm -f "$CTL_DIR/$p.cancel"; info "[$p] 已停止"; fi
  done
}

cmd_skip() {
  ensure_dirs
  [ "${#ARGS[@]}" -ge 1 ] || die "用法: $APP skip <规则> [相对路径]"
  local p="${ARGS[0]}" target="${ARGS[1]:-}"
  is_profile "$p" || die "配置里没有名为 $p 的规则"
  [ -f "$STATUS_DIR/$p.run.json" ] || { info "[$p] 当前没有正在进行的同步"; return 0; }
  printf '%s\n' "$target" > "$CTL_DIR/$p.skip"
  info "[$p] 已请求跳过${target:+ $target}"
}

cmd_ack() {
  local p f
  for p in "${ARGS[@]:-}" ; do
    [ -n "$p" ] || continue
    f="$STATUS_DIR/$p.last.json"
    [ -f "$f" ] || continue
    sed 's/"acked":false/"acked":true/' "$f" | atomic_write "$f"
  done
  return 0
}

json_file_or_null() { if [ -s "$1" ]; then tr -d '\n' < "$1"; else printf 'null'; fi; }

rules_json() {
  local p first=1
  printf '{"config":%s,"daemon_running":%s,"autostart":%s,"rsync":%s,"global":{"debounce":%s,"known_hosts":%s,"ssh_multiplex":%s,"watch_ignore":%s},"rules":[' \
    "$(json_str "$CONFIG")" "$(daemon_alive && echo true || echo false)" "$( [ -f "$STATE/autostart.off" ] && echo false || echo true )" \
    "$(json_str "${RSYNC_BIN:-}")" \
    "$(json_str "$G_DEBOUNCE")" "$(json_str "$G_KNOWN_HOSTS")" "$(json_str "$G_SSH_MULTIPLEX")" "$(json_str "$G_WATCH_IGNORE")"
  for p in $(list_profiles); do
    load_profile "$p"
    local valid=true msg=""
    msg="$(check_profile "$p")" || valid=false
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"name":%s,"enabled":%s,"local":%s,"remote":%s,"host":%s,"port":%s,"user":%s,"key_file":%s,"delete":%s,"include":%s,"exclude":%s,"extra":%s,"remote_owner":%s,"valid":%s,"error":%s,"run":%s,"last":%s}' \
      "$(json_str "$p")" "$P_ENABLED" "$(json_str "$P_LOCAL")" "$(json_str "$P_REMOTE")" "$(json_str "$P_HOST")" \
      "$(json_str "${P_PORT:-22}")" "$(json_str "$P_USER")" "$(json_str "$P_KEY_FILE")" "$P_DELETE" \
      "$(json_lines "$PATTERN_INC")" "$(json_lines "$PATTERN_EXC")" "$(json_str "$P_EXTRA")" \
      "$(json_str "$P_REMOTE_OWNER")" "$valid" "$(json_str "$msg")" \
      "$(json_file_or_null "$STATUS_DIR/$p.run.json")" "$(json_file_or_null "$STATUS_DIR/$p.last.json")"
  done
  printf ']}\n'
}

cmd_rules() {
  [ -f "$CONFIG" ] || die "找不到配置文件: $CONFIG"
  read_global
  detect_rsync >/dev/null 2>&1 || RSYNC_BIN=""
  rules_json
}

cmd_status() {
  ensure_dirs
  if [ "$OPT_JSON" = 1 ]; then cmd_rules; return; fi
  [ -f "$CONFIG" ] || die "找不到配置文件: $CONFIG"
  read_global
  while :; do
    [ "$OPT_WATCH" = 1 ] && printf '\033[H\033[2J'
    info "守护进程: $(daemon_alive && echo "运行中（pid $(cat "$STATE/daemon.pid")）" || echo 未运行)"
    printf '%-14s %-8s %s\n' "规则" "状态" "详情"
    local p s phase files pct last
    for p in $(list_profiles); do
      if [ -f "$STATUS_DIR/$p.run.json" ]; then
        s="$(cat "$STATUS_DIR/$p.run.json" 2>/dev/null)"
        phase="$(printf '%s' "$s" | sed -nE 's/.*"phase":"([a-z]+)".*/\1/p')"
        files="$(printf '%s' "$s" | sed -nE 's/.*"files_done":([0-9]+).*/\1/p')"
        pct="$(printf '%s' "$s" | sed -nE 's/.*"percent":([0-9]+).*/\1/p')"
        case "$phase" in connecting) phase=连接中 ;; scanning) phase=比对中 ;; *) phase=传输中 ;; esac
        printf '%-14s %-8s %s\n' "$p" "$phase" "${pct:-0}% · 已传 ${files:-0} 个"
      else
        last="$(sed -nE 's/.*"summary":"(([^"\\]|\\.)*)".*/\1/p' "$STATUS_DIR/$p.last.json" 2>/dev/null || true)"
        if grep -q '"result":"failed"' "$STATUS_DIR/$p.last.json" 2>/dev/null; then
          printf '%-14s %-8s %s\n' "$p" "失败" "$last"
        else
          printf '%-14s %-8s %s\n' "$p" "空闲" "${last:-—}"
        fi
      fi
    done
    [ "$OPT_WATCH" = 1 ] || break
    /bin/sleep 1
  done
}

cmd_history() {
  local n="${ARGS[0]:-100}"
  printf '['
  [ -f "$HISTORY" ] && tail -n "$n" "$HISTORY" | awk 'NF{ if (c++) printf ","; printf "%s", $0 }'
  printf ']\n'
}

# 某次同步的文件清单与失败输出（JSON），供"日志"页展开查看。
# run-files <run_id> [条数] [起始偏移]：分段读取，界面先取 15 条，"查看更多"每次再取 50 条
cmd_run_files() {
  local id="${ARGS[0]:-}" limit="${ARGS[1]:-2000}" offset="${ARGS[2]:-0}" f
  case "$id" in ''|*/*|*..*) die "用法: $APP run-files <run_id> [条数] [起始偏移]" ;; esac
  case "$limit" in ''|*[!0-9]*) die "条数必须是数字" ;; esac
  case "$offset" in ''|*[!0-9]*) die "起始偏移必须是数字" ;; esac
  f="$RUNS_DIR/$id.tsv"
  local total=0
  [ -f "$f" ] && total="$(wc -l < "$f" | tr -d ' ')"
  printf '{"run_id":%s,"total":%s,"offset":%s,"files":[' "$(json_str "$id")" "$total" "$offset"
  if [ -f "$f" ]; then
    awk -F'\t' -v off="$offset" -v lim="$limit" '
      NR > off && NR <= off + lim && NF >= 2 {
        p = $2; gsub(/\\/, "\\\\", p); gsub(/"/, "\\\"", p)
        if (n++) printf ","
        printf "{\"op\":\"%s\",\"path\":\"%s\"}", $1, p
      }' "$f"
  fi
  printf '],"error_output":%s}\n' "$(json_str "$(cat "$RUNS_DIR/$id.err" 2>/dev/null || true)")"
}

cmd_logs() {
  local f="$SERVICE_LOG"
  [ -f "$f" ] || f="$RUN_LOG"
  [ -f "$f" ] || die "还没有日志"
  if [ "$OPT_JSON" = 1 ] || [ ! -t 1 ]; then tail -n "${ARGS[0]:-200}" "$f"; else tail -n 200 -f "$f"; fi
}

cmd_test() {
  read_global
  [ "${#ARGS[@]}" -ge 1 ] || die "用法: $APP test <规则>"
  local p="${ARGS[0]}"
  is_profile "$p" || die "配置里没有名为 $p 的规则"
  load_profile "$p"
  build_ssh_argv
  local out rc
  set +e
  out="$("${SSH_ARGS[@]}" "$P_USER@$P_HOST" "test -d $(printf '%q' "$P_REMOTE") && echo DIR_OK || echo DIR_MISSING; rsync --version | head -1" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qiE 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key for .* has changed'; then
      info "服务器指纹与记录不一致（可能被冒充），已拒绝连接。请手动核对 ${G_KNOWN_HOSTS} 中 $P_HOST 的记录"
      return 5
    fi
    if printf '%s' "$out" | grep -qiE 'Host key verification failed|No .* host key is known'; then
      info "首次连接 ${P_HOST}：主机指纹未受信，请核对指纹后选择信任"
      return 4
    fi
    info "连接失败（退出码 ${rc}）: $(printf '%s' "$out" | tail -1)"
    return 1
  fi
  case "$out" in *DIR_MISSING*) info "连接成功，但远端目录不存在: $P_REMOTE"; return 2 ;; esac
  case "$out" in *"rsync"*"version"*) ;; *) info "连接成功，但远端没有 rsync"; return 3 ;; esac
  info "连接成功，远端目录存在，$(printf '%s' "$out" | grep -m1 'rsync')"
}

# 信任服务器指纹：ssh-keyscan 取回主机公钥，核对指纹后追加到 known_hosts
#   trust-host <规则> --json            只返回指纹，供界面让用户核对
#   trust-host <规则> --yes <指纹...>    重新获取并只写入与给定指纹一致的公钥（防止两次获取之间被替换）
#   trust-host <规则>                   终端交互确认
cmd_trust_host() {
  read_global
  [ "${#ARGS[@]}" -ge 1 ] || die "用法: $APP trust-host <规则> [--json | --yes <指纹...>]"
  local p="${ARGS[0]}"
  is_profile "$p" || die "配置里没有名为 $p 的规则"
  load_profile "$p"
  [ -n "$G_KNOWN_HOSTS" ] || die "已关闭主机指纹校验（known_hosts 为空），无需信任"
  local port="${P_PORT:-22}" keys
  keys="$(ssh-keyscan -T 10 -p "$port" "$P_HOST" 2>/dev/null | grep -v '^#' || true)"
  [ -n "$keys" ] || die "无法从 ${P_HOST}:${port} 获取主机公钥（检查服务器地址和端口）"
  if [ "$OPT_YES" = 1 ]; then
    local want=" ${ARGS[*]:1} " line fp added=0
    [ "${#ARGS[@]}" -ge 2 ] || die "--yes 需要附上已核对的指纹"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      fp="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
      case "$want" in
        *" $fp "*) printf '%s\n' "$line" >> "$G_KNOWN_HOSTS"; added=$((added + 1)) ;;
      esac
    done <<< "$keys"
    [ "$added" -gt 0 ] || die "服务器指纹与刚才核对的不一致，已放弃写入，请重新测试连接"
    info "已信任 ${P_HOST}:${port}（写入 ${added} 条公钥）"
    return 0
  fi
  if [ "$OPT_JSON" = 1 ]; then
    printf '{"host":%s,"port":%s,"fingerprints":[' "$(json_str "$P_HOST")" "$port"
    printf '%s\n' "$keys" | ssh-keygen -lf - 2>/dev/null | awk '{ t = $NF; gsub(/[()]/, "", t); if (n++) printf ","; printf "{\"fp\":\"%s\",\"type\":\"%s\"}", $2, t }'
    printf ']}\n'
    return 0
  fi
  info "${P_HOST}:${port} 的主机指纹："
  printf '%s\n' "$keys" | ssh-keygen -lf - 2>/dev/null | sed 's/^/  /'
  printf '确认这些指纹与服务器一致并信任？[y/N] '
  local ans; read -r ans
  case "$ans" in y|Y|yes) printf '%s\n' "$keys" >> "$G_KNOWN_HOSTS"; info "已信任 ${P_HOST}:${port}" ;; *) info "已取消"; return 1 ;; esac
}

# ---------------- 配置写入（保留注释、空行、未知字段） ----------------

RULE_KEYS="local remote host port user key_file enabled delete include exclude extra remote_owner"
GLOBAL_KEYS="debounce known_hosts ssh_multiplex watch_ignore"

ini_edit() {
  # ini_edit <op:set|add|rm|rename> <section> [k=v ...]
  local op="$1" sec="$2"; shift 2
  local tmp; tmp="$(mktemp "$(dirname "$CONFIG")/.config.XXXXXX")"
  [ -f "$CONFIG" ] || : > "$CONFIG"
  FS_OP="$op" FS_SEC="$sec" perl -e '
    use strict; use warnings;
    my ($op, $sec) = ($ENV{FS_OP}, $ENV{FS_SEC});
    my @kv = @ARGV; my $file = shift @kv; my $out = shift @kv;
    open my $in, "<", $file or die; my @l = <$in>; close $in;
    chomp @l;
    my $hdr = qr/^\s*\[\s*(.*?)\s*\]\s*$/;
    my ($s, $e) = (-1, scalar @l);
    for my $i (0..$#l) { if ($l[$i] =~ $hdr) { if ($s >= 0) { $e = $i; last } $s = $i if $1 eq $sec; } }
    if ($op eq "rm") { die "NOSECTION\n" if $s < 0; my $end = $e; $end-- while $end > $s + 1 && $l[$end-1] =~ /^\s*$/; splice @l, $s, $end - $s; }
    elsif ($op eq "rename") { die "NOSECTION\n" if $s < 0; $l[$s] = "[$kv[0]]"; }
    else {
      if ($s < 0) { die "NOSECTION\n" if $op eq "set"; push @l, "" if @l && $l[-1] !~ /^\s*$/; push @l, "[$sec]"; $s = $#l; $e = scalar @l; }
      elsif ($op eq "add") { die "EXISTS\n"; }
      my %alias = (local => [qw(local local_dir path)], remote => [qw(remote remote_dir)], host => [qw(host server)], user => [qw(user username)],
                   key_file => [qw(key_file keyfile)], include => [qw(include includes sync rules)], exclude => [qw(exclude excludes)],
                   extra => [qw(extra extra_flags)], delete => [qw(delete mode)]);
      for my $pair (@kv) {
        my ($k, $v) = split /=/, $pair, 2; $v = "" unless defined $v;
        my @names = @{ $alias{$k} || [$k] };
        my $re = join "|", map { quotemeta } @names;
        my $first = -1; my @drop;
        for my $i ($s+1 .. $e-1) { next if $l[$i] =~ /^\s*[#;]/; if ($l[$i] =~ /^\s*(?:$re)\s*=/) { if ($first < 0) { $first = $i } else { push @drop, $i } } }
        if ($v eq "" && $k ne "enabled") { push @drop, $first if $first >= 0; }
        elsif ($first >= 0) { $l[$first] = "$k = $v"; }
        else { my $at = $e; $at-- while $at > $s + 1 && $l[$at-1] =~ /^\s*$/; splice @l, $at, 0, "$k = $v"; $e++; @drop = map { $_ >= $at ? $_ + 1 : $_ } @drop; }
        for my $d (sort { $b <=> $a } @drop) { splice @l, $d, 1; $e--; }
      }
    }
    open my $o, ">", $out or die; print $o join("\n", @l), "\n"; close $o;
  ' "$CONFIG" "$tmp" "$@" 2>"$tmp.err" || {
    local why; why="$(cat "$tmp.err")"; rm -f "$tmp" "$tmp.err"
    case "$why" in NOSECTION*) die "配置里没有名为 $sec 的规则" ;; EXISTS*) die "规则 $sec 已存在" ;; *) die "写入配置失败: $why" ;; esac
  }
  rm -f "$tmp.err"
  NEW_CONFIG="$tmp"
}

# 写入前用新配置校验目标规则，通过才替换（原文件留 .bak）
commit_config() {
  local sec="$1" msg
  if [ -n "$sec" ]; then
    msg="$(FOLDER_SYNC_CONFIG="$NEW_CONFIG" /bin/bash "$SELF" validate -p "$sec" 2>&1)" || {
      rm -f "$NEW_CONFIG"; printf '%s\n' "$msg" >&2; exit 1; }
  fi
  [ -f "$CONFIG" ] && cp -p "$CONFIG" "$CONFIG.bak"
  chmod 600 "$NEW_CONFIG" 2>/dev/null || true
  mv -f "$NEW_CONFIG" "$CONFIG"
  info "已保存"
}

check_keys() {
  local allowed="$1" kv k; shift
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) die "参数格式应为 key=value: $kv" ;; esac
    k="${kv%%=*}"
    case " $allowed " in *" $k "*) ;; *) die "不支持的字段: $k" ;; esac
    case "$kv" in *$'\n'*) die "字段值不能包含换行: $k" ;; esac
  done
}

valid_rule_name() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$' || die "规则名只能包含字母、数字、. _ -"
  [ "$1" != global ] || die "global 是保留名"
}

cmd_rule_set() {
  [ "${#ARGS[@]}" -ge 2 ] || die "用法: $APP rule-set <规则> key=value ..."
  local sec="${ARGS[0]}"; local kvs=( "${ARGS[@]:1}" )
  is_profile "$sec" || die "配置里没有名为 $sec 的规则"
  check_keys "$RULE_KEYS" "${kvs[@]}"
  ini_edit set "$sec" "${kvs[@]}"
  commit_config "$sec"
}

cmd_rule_add() {
  [ "${#ARGS[@]}" -ge 1 ] || die "用法: $APP rule-add <规则> key=value ..."
  local sec="${ARGS[0]}"; local kvs=( "${ARGS[@]:1}" )
  valid_rule_name "$sec"
  is_profile "$sec" && die "规则 $sec 已存在"
  check_keys "$RULE_KEYS" "${kvs[@]}"
  ini_edit add "$sec" "${kvs[@]}"
  commit_config "$sec"
}

cmd_rule_rm() {
  [ "${#ARGS[@]}" -eq 1 ] || die "用法: $APP rule-rm <规则>"
  is_profile "${ARGS[0]}" || die "配置里没有名为 ${ARGS[0]} 的规则"
  ini_edit rm "${ARGS[0]}"
  commit_config ""
  rm -f "$STATUS_DIR/${ARGS[0]}.last.json"
}

cmd_rule_rename() {
  [ "${#ARGS[@]}" -eq 2 ] || die "用法: $APP rule-rename <旧名> <新名>"
  is_profile "${ARGS[0]}" || die "配置里没有名为 ${ARGS[0]} 的规则"
  valid_rule_name "${ARGS[1]}"
  is_profile "${ARGS[1]}" && die "规则 ${ARGS[1]} 已存在"
  ini_edit rename "${ARGS[0]}" "${ARGS[1]}"
  commit_config "${ARGS[1]}"
  mv -f "$STATUS_DIR/${ARGS[0]}.last.json" "$STATUS_DIR/${ARGS[1]}.last.json" 2>/dev/null || true
}

cmd_global_set() {
  [ "${#ARGS[@]}" -ge 1 ] || die "用法: $APP global-set key=value ..."
  check_keys "$GLOBAL_KEYS" "${ARGS[@]}"
  if ! grep -qE '^[[:space:]]*\[global\][[:space:]]*$' "$CONFIG" 2>/dev/null; then
    { printf '[global]\n\n'; cat "$CONFIG" 2>/dev/null; } > "$CONFIG.tmp.$$" && mv -f "$CONFIG.tmp.$$" "$CONFIG"
  fi
  ini_edit set global "${ARGS[@]}"
  local msg; msg="$(FOLDER_SYNC_CONFIG="$NEW_CONFIG" /bin/bash "$SELF" validate 2>&1)" || {
    case "$msg" in *known_hosts*) rm -f "$NEW_CONFIG"; die "$msg" ;; esac; }
  [ -f "$CONFIG" ] && cp -p "$CONFIG" "$CONFIG.bak"
  mv -f "$NEW_CONFIG" "$CONFIG"
  info "已保存"
}

# ---------------- 配置备份：导出 / 导入 ----------------
#
# 备份文件是一个 JSON：format / format_version / exported_at / config（配置原文）。
# 应用导出时还会补上 settings（浮动状态条等）和 autostart；命令行导出只含配置。
# 不含 SSH 私钥和 known_hosts：私钥不该进备份文件，主机指纹重装后重新核对更稳妥。

CONFIG_BACKUP_FORMAT="folder-sync-config"
CONFIG_BACKUP_VERSION=1

# 从备份文件里取出配置原文（JSON 转义交给 perl 的 JSON::PP 处理，不手工解析）
backup_config_text() {
  FS_BACKUP_FORMAT="$CONFIG_BACKUP_FORMAT" FS_BACKUP_VERSION="$CONFIG_BACKUP_VERSION" perl -MJSON::PP -e '
    use strict; use warnings;
    open my $in, "<:raw", $ARGV[0] or die "无法读取备份文件：$!\n";
    my $t = do { local $/; <$in> };
    close $in;
    my $d = eval { JSON::PP->new->utf8(0)->decode($t) };
    die "备份文件不是有效的 JSON\n" unless $d && ref $d eq "HASH";
    die "不是 FolderSync 导出的配置文件\n" unless ( $d->{format} // "" ) eq $ENV{FS_BACKUP_FORMAT};
    my $v = $d->{format_version} // 0;
    die "备份文件的格式版本（$v）比当前 FolderSync 新，请先升级 FolderSync\n" if $v > $ENV{FS_BACKUP_VERSION};
    my $c = $d->{config};
    die "备份文件里没有配置内容\n" unless defined $c && length $c;
    print $c;
    print "\n" unless $c =~ /\n\z/;
  ' "$1"
}

# 配置里的所有段名（去重、保持顺序），含 global
config_sections() {
  [ -f "$1" ] || return 0
  awk '
    /^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
      n = $0
      sub(/^[[:space:]]*\[/, "", n); sub(/\][[:space:]]*$/, "", n)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
      if (n != "" && !seen[n]++) print n
    }' "$1"
}

# 合并：本机配置原样保留，只补进本机没有的段（本机没有 [global] 时才带上备份里的）。
# 备份里第一段之前的注释块是导出方的文件头，不搬过来。
merge_config_text() {   # $1=本机配置  $2=备份里的配置原文
  if [ ! -s "$1" ]; then cat "$2"; return 0; fi
  FS_BACKUP_CONFIG="$2" awk '
    function sec_name(line,   n) {
      if (line !~ /^[[:space:]]*\[[^]]*\][[:space:]]*$/) return ""
      n = line
      sub(/^[[:space:]]*\[/, "", n); sub(/\][[:space:]]*$/, "", n)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", n)
      return n
    }
    FILENAME == ENVIRON["FS_BACKUP_CONFIG"] {
      n = sec_name($0)
      if (n != "") { cur = n; keep = !(n in mine) && !(n in added) }
      if (cur == "" || !keep) next
      if (!(cur in added)) { added[cur] = 1; printf "\n" }
      print
      next
    }
    {
      print
      n = sec_name($0)
      if (n != "") mine[n] = 1
    }
  ' "$1" "$2"
}

cmd_export() {
  local out="${ARGS[0]:-}" json
  [ -f "$CONFIG" ] || die "还没有配置文件: ${CONFIG}（先在应用里新增项目）"
  json="$(printf '{"format":%s,"format_version":%s,"exported_at":%s,"config":%s}' \
    "$(json_str "$CONFIG_BACKUP_FORMAT")" "$CONFIG_BACKUP_VERSION" \
    "$(json_str "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" "$(json_str "$(cat "$CONFIG")")")"
  if [ -z "$out" ]; then printf '%s\n' "$json"; return 0; fi
  [ -d "$(dirname "$out")" ] || die "目录不存在: $(dirname "$out")"
  ( umask 077; printf '%s\n' "$json" > "$out.tmp.$$" ) && mv -f "$out.tmp.$$" "$out" || {
    rm -f "$out.tmp.$$"; die "写入失败: $out"; }
  chmod 600 "$out" 2>/dev/null || true
  info "已导出配置: $out"
}

cmd_import() {
  local file="${ARGS[0]:-}" work txt added_f skipped_f local_secs n imported added_count local_count newf backup="" mode_name total
  [ -n "$file" ] || die "用法: $APP import <备份文件> [--preview] [--replace]"
  [ -f "$file" ] || die "找不到备份文件: $file"
  work="$PATDIR/import"
  mkdir -p "$work"
  txt="$work/config.conf"; added_f="$work/added"; skipped_f="$work/skipped"
  : > "$added_f"; : > "$skipped_f"
  backup_config_text "$file" > "$txt" 2> "$work/error" || die "$(trim "$(cat "$work/error")")"
  grep -q '=' "$txt" || die "备份文件里没有配置内容"
  if grep -vE '^[[:space:]]*\[[^]]*\][[:space:]]*$' "$txt" | grep -qE '^[[:space:]]*\['; then
    die "备份文件里的配置格式不正确"
  fi
  local_secs="$(config_sections "$CONFIG")"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$n" in global) continue ;; esac
    if printf '%s\n' "$local_secs" | grep -qxF -- "$n"; then
      printf '%s\n' "$n" >> "$skipped_f"
    else
      printf '%s\n' "$n" >> "$added_f"
    fi
  done <<< "$(config_sections "$txt")"
  imported="$(config_sections "$txt" | grep -vx global | grep -c . || true)"
  added_count="$(grep -c . "$added_f" || true)"
  if [ "$OPT_PREVIEW" = 1 ]; then
    if [ "$OPT_REPLACE" = 1 ]; then mode_name=replace; total="$imported"; else
      mode_name=merge
      local_count="$(printf '%s\n' "$local_secs" | grep -vx global | grep -c . || true)"
      total=$(( local_count + added_count ))
    fi
    printf '{"ok":true,"mode":%s,"imported":%s,"added":%s,"skipped":%s,"total_after":%s}\n' \
      "$(json_str "$mode_name")" "$imported" "$(json_lines "$added_f")" "$(json_lines "$skipped_f")" "$total"
    return 0
  fi
  newf="$work/new.conf"
  if [ "$OPT_REPLACE" = 1 ]; then
    cat "$txt" > "$newf"
  else
    merge_config_text "$CONFIG" "$txt" > "$newf"
  fi
  grep -q '=' "$newf" || die "导入后没有项目配置，已放弃（本机配置未改动）"
  if grep -vE '^[[:space:]]*\[[^]]*\][[:space:]]*$' "$newf" | grep -qE '^[[:space:]]*\['; then
    die "导入后配置格式不正确，已放弃（本机配置未改动）"
  fi
  mkdir -p "$(dirname "$CONFIG")"
  if [ -f "$CONFIG" ]; then
    local stamp n=1
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="$CONFIG.bak.$stamp"
    while [ -e "$backup" ]; do backup="$CONFIG.bak.$stamp-$n"; n=$(( n + 1 )); done
    cp -p "$CONFIG" "$backup" || die "备份当前配置失败: $backup"
  fi
  chmod 600 "$newf" 2>/dev/null || true
  mv -f "$newf" "$CONFIG" || die "写入配置失败: $CONFIG"
  if [ "$OPT_JSON" = 1 ]; then
    printf '{"ok":true,"added":%s,"skipped":%s,"backup":%s}\n' \
      "$(json_lines "$added_f")" "$(json_lines "$skipped_f")" \
      "$( if [ -n "$backup" ]; then json_str "$backup"; else printf 'null'; fi )"
    return 0
  fi
  info "已导入配置: $CONFIG"
  if [ -s "$added_f" ]; then info "新增项目: $(tr '\n' ' ' < "$added_f")"; fi
  if [ -s "$skipped_f" ]; then info "同名项目保留本机配置: $(tr '\n' ' ' < "$skipped_f")"; fi
  if [ -n "$backup" ]; then info "原配置已备份: $backup"; fi
}

# ---------------- 安装 ----------------

# 复制到临时文件再改名替换：正在运行的 folder-sync（bash 边读边执行脚本）继续读旧文件，
# 不会因为原地覆盖而读到新文件中间的内容
install_script_copy() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest.tmp.$$"
  chmod +x "$dest.tmp.$$"
  mv -f "$dest.tmp.$$" "$dest"
}

boot_env_path() {
  local dirs="" d c
  for c in rsync fswatch ssh lockf perl; do
    d="$(command -v "$c" 2>/dev/null || true)"
    [ -n "$d" ] || continue
    d="$(dirname "$d")"
    case ":$dirs:" in *":$d:"*) ;; *) dirs="${dirs:+$dirs:}$d" ;; esac
  done
  printf '/opt/homebrew/bin:/usr/local/bin:%s%s/usr/bin:/bin:/usr/sbin:/sbin' "$dirs" "${dirs:+:}"
}

# launchctl / 结束应用进程的统一入口。设置 FOLDER_SYNC_NO_LAUNCHD=1（回归测试）时全部变成空操作，
# 测试就不会碰到本机正在运行的后台服务（launchd 的服务名是按用户全局的，测试目录隔离不了它）
lctl() {
  if [ -n "${FOLDER_SYNC_NO_LAUNCHD:-}" ]; then
    [ "${1:-}" = print ] && return 1
    return 0
  fi
  launchctl "$@"
}
lpkill() { [ -n "${FOLDER_SYNC_NO_LAUNCHD:-}" ] && return 1; pkill "$@"; }
lpgrep() { [ -n "${FOLDER_SYNC_NO_LAUNCHD:-}" ] && return 1; pgrep "$@"; }

launchd_load() {
  local label="$1" plist="$2"
  local i=0
  lctl bootout "gui/$U/$label" >/dev/null 2>&1 || true
  # bootout 是异步的：等旧服务真正卸载，否则新注册会被一起移除
  while lctl print "gui/$U/$label" >/dev/null 2>&1 && [ "$i" -lt 50 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  i=0
  until lctl bootstrap "gui/$U" "$plist" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -ge 10 ] && { lctl load -w "$plist" >/dev/null 2>&1 || true; break; }
    /bin/sleep 0.3
  done
  lctl enable "gui/$U/$label" 2>/dev/null || true
  # 刚注册的服务已按 RunAtLoad 启动；只有没跑起来时才补一次（-k 会杀掉重启，白等约 10 秒）
  if ! lctl print "gui/$U/$label" 2>/dev/null | grep -q 'state = running'; then
    lctl kickstart "gui/$U/$label" >/dev/null 2>&1 || true
  fi
  lctl print "gui/$U/$label" >/dev/null 2>&1
}

write_app_plist() {
  local app="$1"
  mkdir -p "$PLIST_DIR"
  cat > "$APP_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$APP_LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$app/Contents/MacOS/FolderSync</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>$(boot_env_path)</string></dict>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLISTEOF
}

# 早期开发版装在 ~/Applications；正式位置是 /Applications，迁移时删掉旧副本（只删本应用）
remove_old_app_copy() {
  local keep="$1" old="$HOME/Applications/FolderSync.app"
  [ "$keep" = "/Applications/FolderSync.app" ] || return 0
  [ -d "$old" ] || return 0
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$old/Contents/Info.plist" 2>/dev/null | grep -qx 'com.local.foldersync'; then
    rm -rf "$old" && info "已移除旧位置的应用: $old"
  fi
  return 0
}

# 开发用：把 app/build 里构建好的应用装进"应用程序"并启动（正式用户直接用 DMG 安装）
install_app() {
  local src="${FOLDER_SYNC_APP_SRC:-$(cd "$(dirname "$SELF")" && pwd)/app/build/FolderSync.app}"
  if [ ! -d "$src" ]; then
    info "未找到菜单栏应用（${src}），跳过；可先执行 app/build.sh 构建"
    return 0
  fi
  local dest="$APP_DEST"
  [ -w "$(dirname "$dest")" ] || dest="$HOME/Applications/FolderSync.app"
  mkdir -p "$(dirname "$dest")"
  # 先卸载 launchd 项再结束进程，避免 KeepAlive 把旧版本拉起来；不用 AppleScript quit（应用忙时会等到超时）
  lctl bootout "gui/$U/$APP_LABEL" >/dev/null 2>&1 || true
  lpkill -x FolderSync 2>/dev/null || true
  local i=0
  while lpgrep -x FolderSync >/dev/null 2>&1 && [ "$i" -lt 30 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  rm -rf "$dest"
  cp -R "$src" "$dest"
  remove_old_app_copy "$dest"
  write_app_plist "$dest"
  [ -n "${FOLDER_SYNC_NO_LAUNCHD:-}" ] || /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  if launchd_load "$APP_LABEL" "$APP_PLIST"; then info "菜单栏应用已安装并启动: $dest"
  else warn "菜单栏应用已复制到 ${dest}，但 launchd 注册失败，可手动打开"; fi
}

# install：安装命令行工具与后台守护。
#   开发：folder-sync install                 → 另外把 app/build 里的应用装进"应用程序"并启动
#   应用：folder-sync install --app-path <.app> → 由 FolderSync.app 首次打开 / 升级时调用，只登记开机启动项
cmd_install() {
  [ -f "$CONFIG" ] || write_example_config
  read_global
  need_tools
  chmod 600 "$CONFIG" 2>/dev/null || true
  mkdir -p "$STATE" "$HOME/.local/bin" "$PLIST_DIR" "$HOME/Library/Logs"
  local target="$HOME/.local/bin/$APP" self_abs
  self_abs="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"
  if [ "$self_abs" != "$target" ]; then install_script_copy "$self_abs" "$target"; info "已安装到: $target"; fi
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>$target</string><string>daemon</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>PATH</key><string>$(boot_env_path)</string></dict>
	<key>WorkingDirectory</key><string>$HOME</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>10</integer>
	<key>ProcessType</key><string>Standard</string>
	<key>StandardOutPath</key><string>$SERVICE_LOG</string>
	<key>StandardErrorPath</key><string>$SERVICE_ERR</string>
</dict>
</plist>
PLISTEOF
  if [ -n "$OPT_APP_PATH" ]; then
    write_app_plist "$OPT_APP_PATH"
    remove_old_app_copy "$OPT_APP_PATH"
  fi
  if [ "$OPT_DRY" = "1" ]; then info "（--dry-run：未调用 launchctl）"; return 0; fi
  if launchd_load "$LABEL" "$PLIST"; then info "守护进程已在后台运行"
  else warn "launchctl 注册失败，请在普通终端执行: launchctl bootstrap gui/\$(id -u) \"$PLIST\""; fi
  if [ -z "$OPT_APP_PATH" ]; then
    install_app
  else
    [ -n "${FOLDER_SYNC_NO_LAUNCHD:-}" ] || /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  fi
  if [ "$(command -v "$APP" 2>/dev/null)" != "$target" ]; then
    info "提示: 终端里直接使用 $APP 命令，需要把 ~/.local/bin 加入 PATH：export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

# 确保后台守护在运行（关闭开机自启后，打开应用时由应用调用）
cmd_start() {
  [ -f "$PLIST" ] || die "尚未安装后台服务（打开 FolderSync 应用会自动安装）"
  if lctl print "gui/$U/$LABEL" 2>/dev/null | grep -q 'state = running'; then
    info "守护进程已在运行"
    return 0
  fi
  launchd_load "$LABEL" "$PLIST" && info "守护进程已启动"
}

# 开机自动启动：开 = 启动项在 ~/Library/LaunchAgents（登录即运行）；关 = 移到状态目录（登录不运行）。
# 只挪文件、不停止当前正在运行的服务：改设置不影响这次登录期间的同步。
cmd_autostart() {
  local want="${ARGS[0]:-status}" f
  case "$want" in
    on)
      rm -f "$STATE/autostart.off"
      mkdir -p "$LA_DIR"
      for f in "$LA_OFF_DIR/$LABEL.plist" "$LA_OFF_DIR/$APP_LABEL.plist"; do
        if [ -f "$f" ]; then mv -f "$f" "$LA_DIR/"; fi
      done
      ;;
    off)
      mkdir -p "$LA_OFF_DIR"
      : > "$STATE/autostart.off"
      for f in "$LA_DIR/$LABEL.plist" "$LA_DIR/$APP_LABEL.plist"; do
        if [ -f "$f" ]; then mv -f "$f" "$LA_OFF_DIR/"; fi
      done
      ;;
    status) ;;
    *) die "用法: $APP autostart [on|off]" ;;
  esac
  if [ -f "$STATE/autostart.off" ]; then
    if [ "$OPT_JSON" = 1 ]; then printf '{"autostart":false}\n'; else info "开机自动启动：已关闭"; fi
  else
    if [ "$OPT_JSON" = 1 ]; then printf '{"autostart":true}\n'; else info "开机自动启动：已开启"; fi
  fi
}

# 运行环境自检：依赖是否齐全、命令行工具与启动项是否就绪（应用首次打开时据此引导安装）
cmd_doctor() {
  local rs_ok=false rs_ver="" fw="" brew="" missing="" cli="$HOME/.local/bin/$APP" f
  if detect_rsync >/dev/null 2>&1; then rs_ok=true; fi
  rs_ver="$(FS_VERSION_PROBE=1 "${RSYNC_BIN:-rsync}" --version 2>/dev/null | head -1 || true)"
  fw="$(command -v fswatch 2>/dev/null || true)"
  brew="$(command -v brew 2>/dev/null || true)"
  if [ -z "$brew" ]; then
    for f in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$f" ] && { brew="$f"; break; }; done
  fi
  [ "$rs_ok" = true ] || missing="rsync"
  [ -n "$fw" ] || missing="${missing}${missing:+ }fswatch"
  local ok=false; [ -z "$missing" ] && ok=true
  local cli_current=false; [ -f "$cli" ] && cmp -s "$SELF" "$cli" && cli_current=true
  local daemon_installed=false; [ -f "$PLIST" ] && daemon_installed=true
  local app_loc_ok=true app_reg=false
  if [ -n "$OPT_APP_PATH" ]; then
    case "$OPT_APP_PATH" in /Volumes/*|*/AppTranslocation/*) app_loc_ok=false ;; esac
    grep -qF "<string>$OPT_APP_PATH/Contents/MacOS/FolderSync</string>" "$APP_PLIST" 2>/dev/null && app_reg=true
  fi
  local autostart=true; [ -f "$STATE/autostart.off" ] && autostart=false
  if [ "$OPT_JSON" = 1 ]; then
    printf '{"ok":%s,"missing":%s,"install_cmd":%s,"rsync":{"ok":%s,"path":%s,"version":%s},"fswatch":%s,"brew":%s,"cli":%s,"cli_current":%s,"daemon_installed":%s,"daemon_running":%s,"app_location_ok":%s,"app_registered":%s,"autostart":%s,"config_exists":%s}\n' \
      "$ok" "$(json_str "$missing")" "$(json_str "${missing:+brew install $missing}")" \
      "$rs_ok" "$(json_str "${RSYNC_BIN:-}")" "$(json_str "$rs_ver")" "$(json_str "$fw")" "$(json_str "$brew")" \
      "$(json_str "$cli")" "$cli_current" "$daemon_installed" "$(daemon_alive && echo true || echo false)" \
      "$app_loc_ok" "$app_reg" "$autostart" "$( [ -f "$CONFIG" ] && echo true || echo false )"
    return 0
  fi
  info "GNU rsync 3.1+ : $( [ "$rs_ok" = true ] && echo "✓ ${RSYNC_BIN}" || echo "✗ 缺少（brew install rsync）" )"
  info "fswatch       : $( [ -n "$fw" ] && echo "✓ $fw" || echo "✗ 缺少（brew install fswatch）" )"
  info "Homebrew      : $( [ -n "$brew" ] && echo "✓ $brew" || echo "✗ 未安装（https://brew.sh）" )"
  info "命令行工具     : $( [ "$cli_current" = true ] && echo "✓ $cli" || echo "✗ 未安装或不是最新" )"
  info "后台守护       : $( [ "$daemon_installed" = true ] && echo "已安装" || echo "未安装" )，$(daemon_alive && echo 运行中 || echo 未运行)"
  info "开机自动启动   : $( [ "$autostart" = true ] && echo 开 || echo 关 )"
  [ "$ok" = true ]
}

cmd_reload() {
  [ -f "$PLIST" ] || die "尚未注册后台服务，先执行 $APP install"
  /bin/bash "$SELF" validate || die "配置校验未通过，拒绝重启"
  local target="$HOME/.local/bin/$APP" self_abs
  self_abs="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"
  if [ "$self_abs" != "$target" ]; then install_script_copy "$self_abs" "$target"; info "已刷新脚本副本: $target"; fi
  lctl kickstart -k "gui/$U/$LABEL" >/dev/null 2>&1 || launchd_load "$LABEL" "$PLIST" || true
  info "守护已重启（配置改动本身会自动生效，只有升级脚本时才需要 reload）"
}

# 卸载：停止后台同步，删除开机启动项和命令行工具；配置与同步记录保留。
# --keep-app：由应用自己发起卸载时使用（应用随后自行退出并移到废纸篓）
cmd_uninstall() {
  lctl bootout "gui/$U/$LABEL" >/dev/null 2>&1 || true
  if [ "$OPT_KEEP_APP" != 1 ]; then
    lctl bootout "gui/$U/$APP_LABEL" >/dev/null 2>&1 || true
    lpkill -x FolderSync 2>/dev/null || true
  fi
  rm -f "$LA_DIR/$LABEL.plist" "$LA_DIR/$APP_LABEL.plist" "$LA_OFF_DIR/$LABEL.plist" "$LA_OFF_DIR/$APP_LABEL.plist" \
        "$STATE/autostart.off" "$HOME/.local/bin/$APP"
  info "已卸载：后台同步已停止，开机启动项和命令行工具已删除"
  info "配置（$(dirname "$CONFIG")）和同步记录（${STATE}）已保留；重新安装后会继续使用"
}

usage() {
  cat <<TXT
$APP —— 本地 → 远端单向推送（SSH + GNU rsync）

用法: $APP <命令> [参数] [选项]

同步:
  sync [规则|路径|.]       手动全量同步（不给参数 = 所有启用的规则）；--bg 交给守护后台执行
  push <路径...>          立即上传选中的文件/文件夹
  pull <路径...>          从远端下载（先列出将新增/覆盖的本地文件，确认后执行；不删本地文件）
                          --preview 只输出 JSON 预览；--yes 跳过确认
  cancel [规则]           停止正在进行的同步（未传完的丢弃）
  skip <规则> [相对路径]   跳过当前（或指定）文件，继续同步其余部分
  check [规则]            只对比差异，不传输
状态:
  status [-w] [--json]    查看各规则状态（-w 持续刷新）
  history [N]             最近 N 条同步记录（JSON）
  run-files <run_id> [条数] [偏移]  某次同步传输/删除/跳过的文件清单（JSON，分段读取）
  ack <规则>              确认失败提示
  logs                    跟踪日志
  ui                      打开菜单栏应用的管理窗口
配置:
  init / list / validate / test <规则>
  trust-host <规则>        核对并信任服务器指纹（首次连接新服务器时）
  rules --json            规则与全局设置（JSON）
  export [文件]           导出配置为 JSON（不给文件则输出到标准输出）；不含 SSH 私钥和 known_hosts
  import <文件> [--preview] [--replace]
                          导入配置：默认只补进本机没有的项目，同名项目保留本机配置，导入前自动备份；
                          --preview 只输出将发生的变化（JSON），--replace 用备份整份替换
  rule-add <规则> k=v...   rule-set <规则> k=v...   rule-rm <规则>   rule-rename <旧> <新>
  global-set k=v...
服务:
  install / uninstall     安装 / 卸载后台守护、开机启动项和命令行工具（一般由 FolderSync 应用自动完成）
  autostart [on|off]      开机自动启动（登录后自动运行应用和后台同步）
  start / reload / daemon 启动 / 重启守护；前台运行守护
  doctor [--json]         检查运行环境（GNU rsync、fswatch 等）

规则字段: local remote host port user key_file enabled delete include exclude extra remote_owner
选项: -p 规则  -n 预演  -v 列出文件  --no-wait 规则正忙时不等待
TXT
}

# ============================== 入口 ==============================

CMD="${1:-help}"
if [ $# -gt 0 ]; then shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile)  OPT_PROFILE="${2:-}"; shift 2 ;;
    -f|--from)
      case "${2:-}" in local) ;; *) die "已不再支持 -f remote：需要下载请用 $APP pull <路径>" ;; esac
      shift 2 ;;
    -n|--dry-run)  OPT_DRY=1; shift ;;
    -v|--verbose)  OPT_VERBOSE=1; shift ;;
    -w|--watch)    OPT_WATCH=1; shift ;;
    -y|--yes)      OPT_YES=1; shift ;;
    --json)        OPT_JSON=1; shift ;;
    --no-wait)     OPT_NOWAIT=1; shift ;;
    --bg)          OPT_BG=1; shift ;;
    --preview)     OPT_PREVIEW=1; shift ;;
    --replace)     OPT_REPLACE=1; shift ;;
    --app-path)    OPT_APP_PATH="${2:-}"; shift 2 ;;
    --keep-app)    OPT_KEEP_APP=1; shift ;;
    -h|--help)     CMD="help"; shift ;;
    --)            shift; while [ $# -gt 0 ]; do ARGS+=( "$1" ); shift; done ;;
    -*)            die "未知选项: ${1}（$APP help 查看用法）" ;;
    *)             ARGS+=( "$1" ); shift ;;
  esac
done

mkdir -p "$STATE"
trap 'rm -rf "$PATDIR" 2>/dev/null || true' EXIT

case "$CMD" in
  init)        cmd_init ;;
  list|ls)     cmd_list ;;
  validate)    cmd_validate ;;
  check)       cmd_check ;;
  sync)        cmd_sync ;;
  push)        cmd_push ;;
  pull)        cmd_pull ;;
  cancel|stop) cmd_cancel ;;
  skip)        cmd_skip ;;
  ack)         cmd_ack ;;
  status)      cmd_status ;;
  rules)       cmd_rules ;;
  export)      cmd_export ;;
  import)      cmd_import ;;
  history)     cmd_history ;;
  run-files)   cmd_run_files ;;
  test)        cmd_test ;;
  trust-host)  cmd_trust_host ;;
  rule-set)    cmd_rule_set ;;
  rule-add)    cmd_rule_add ;;
  rule-rm)     cmd_rule_rm ;;
  rule-rename) cmd_rule_rename ;;
  global-set)  cmd_global_set ;;
  daemon)      cmd_daemon ;;
  install)     cmd_install ;;
  reload|restart) cmd_reload ;;
  uninstall)   cmd_uninstall ;;
  start)       cmd_start ;;
  autostart)   cmd_autostart ;;
  doctor)      cmd_doctor ;;
  logs)        cmd_logs ;;
  ui)          open "foldersync://window${ARGS[0]:+/${ARGS[0]}}" 2>/dev/null || die "无法打开菜单栏应用（先执行 $APP install）" ;;
  help|-h|--help) usage ;;
  *)           usage >&2; die "未知命令: $CMD" ;;
esac
