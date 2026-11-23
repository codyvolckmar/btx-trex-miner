#!/usr/bin/env bash
# trex-btx — control panel for T-Rex mining BitCore (BTX, megabtx) on zpool.ca.
# Interactive (whiptail) or headless (--status/--start/--stop/--restart/--install/--preflight).
#
# GPU self-healing: if a GPU crashes (CUDA error) or stops hashing, the supervisor restarts
# T-Rex and lowers that GPU's intensity one step. At the minimum intensity it enables
# low-load mode; if it still crashes, the GPU is disabled so the others keep mining.
# Tuning is kept in gpu-tune; reset it from Settings.
set -uo pipefail

APP_TITLE="BTX T-REX"
VERSION="0.19.14"
DIR="${BTX_TREX_DIR:-/opt/btx-trex}"
CONF="$DIR/miner.conf"
TUNE="$DIR/gpu-tune"
PIDFILE="$DIR/supervisor.pid"
LOGFILE="$DIR/miner.log"
SUPOUT="$DIR/supervisor.out"
BIN="$DIR/t-rex"
SELF="$(readlink -f "$0")"
URL="https://github.com/trexminer/T-Rex/releases/download/$VERSION/t-rex-$VERSION-linux-cuda11.1.tar.gz"
SHA="456a273ad7c459a6b764b20b79ab8158a4cd9d6cd68d967dca0632a67df49023"

# ---------- defaults (overridden by miner.conf) ----------
POOL="stratum+tcp://megabtx.na.mine.zpool.ca:3558"
WALLET="${BTX_WALLET:-}"
PASS="c=BTC,zap=BTX"
WORKER="${BTX_WORKER:-$(hostname -s 2>/dev/null || echo rig)}"
ALGO="megabtx"
API_PORT="4067"
DEVICES=""            # GPUs to mine on, e.g. "0,1" - blank = all GPUs
EXTRA=""              # extra T-Rex flags
DEFAULT_INTENSITY="20" # used when T-Rex hasn't reported a GPU's auto intensity yet
STEP="2"              # intensity drop per crash
MIN_INTENSITY="14"    # floor before low-load mode
DISABLE_UNSTABLE="yes" # disable a GPU that still crashes at the floor + low-load
DEAD_AFTER="120"      # seconds at 0 H/s before a GPU counts as dead
GRACE="120"           # seconds after start before health checks begin
CHECK_EVERY="30"
RESTART_DELAY="10"

mkdir -p "$DIR" 2>/dev/null || { echo "Cannot create $DIR (run as root or set BTX_TREX_DIR)" >&2; exit 1; }
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
save_conf() {
  {
    echo "# T-Rex BTX config — edit via the menu, or directly here"
    local v; for v in POOL WALLET PASS WORKER ALGO API_PORT DEVICES EXTRA DEFAULT_INTENSITY STEP \
                      MIN_INTENSITY DISABLE_UNSTABLE DEAD_AFTER GRACE CHECK_EVERY RESTART_DELAY; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$CONF"
}
[ -f "$CONF" ] || save_conf
touch "$TUNE"

# ---------- helpers ----------
strip_ansi() { sed -u 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//g'; }
log()        { echo "[$(date '+%F %T')] supervisor: $*" >> "$LOGFILE"; }
hr()         { awk -v h="${1:-0}" 'BEGIN{split("H/s kH/s MH/s GH/s TH/s",u," "); i=1; while (h>=1000 && i<5) {h/=1000; i++} printf "%.2f %s", h, u[i]}'; }
size_h()     { [ -s "$1" ] && du -h "$1" | cut -f1 || echo empty; }
api()        { curl -fs --max-time 5 "http://127.0.0.1:$API_PORT/summary"; }
pretty_time() {
  local t=${1:-0} d h m
  d=$((t/86400)); h=$((t%86400/3600)); m=$((t%3600/60))
  (( d )) && { printf '%dd%dh' "$d" "$h"; return; }
  (( h )) && { printf '%dh%dm' "$h" "$m"; return; }
  printf '%dm%ds' "$m" "$((t%60))"
}
last_error() {
  [ -f "$LOGFILE" ] || return 0
  tail -n 80 "$LOGFILE" | strip_ansi | grep -i -E 'error|fail|exception|illegal|cannot|denied|refused' | tail -n 1 | cut -c1-90
}

# ---------- GPU tuning state ----------
# gpu-tune: one line per GPU: "<id> <seen_intensity> <override_intensity> <lowload 0|1> <disabled 0|1> <crashes>"
# "-" = unknown / not set. IDs are PCI-ordered (T-Rex --pci-indexing), same as nvidia-smi.
C_SEEN=2 C_OVR=3 C_LOW=4 C_DIS=5 C_CRASH=6
tune_get() { awk -v i="$1" -v c="$2" '$1==i {v=$c} END {print (v=="" ? (c>=4 ? 0 : "-") : v)}' "$TUNE"; }
tune_set() {
  grep -q "^$1 " "$TUNE" || echo "$1 - - 0 0 0" >> "$TUNE"
  awk -v i="$1" -v c="$2" -v v="$3" '$1==i {$c=v} 1' "$TUNE" > "$TUNE.tmp" && mv "$TUNE.tmp" "$TUNE"
}
gpu_count() { nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true; }
all_gpus()  { if [ -n "$DEVICES" ]; then tr ',' ' ' <<< "$DEVICES"; else seq 0 $(( $(gpu_count) - 1 )) | tr '\n' ' '; fi; }
active_gpus() { local g; for g in $(all_gpus); do [ "$(tune_get "$g" $C_DIS)" = 1 ] || printf '%s ' "$g"; done; }
gpu_line()  { echo "$(gpu_count) detected, mining on: $(active_gpus)"; }

# A GPU crashed or died: step it down. intensity -STEP ... MIN_INTENSITY -> low-load -> disabled.
derate() {
  local g=$1 crashes cur new
  crashes=$(( $(tune_get "$g" $C_CRASH) + 1 )); tune_set "$g" $C_CRASH "$crashes"
  cur=$(tune_get "$g" $C_OVR); [ "$cur" = - ] && cur=$(tune_get "$g" $C_SEEN); [ "$cur" = - ] && cur=$DEFAULT_INTENSITY
  new=$(awk -v c="$cur" -v s="$STEP" -v m="$MIN_INTENSITY" 'BEGIN {n=c-s; if (n<m) n=m; print n}')
  if awk -v n="$new" -v c="$cur" 'BEGIN {exit !(n<c)}'; then
    tune_set "$g" $C_OVR "$new"; log "TUNE: GPU #$g failed ($crashes total) - intensity $cur -> $new"
  elif [ "$(tune_get "$g" $C_LOW)" != 1 ]; then
    tune_set "$g" $C_OVR "$cur"; tune_set "$g" $C_LOW 1; log "TUNE: GPU #$g failed at min intensity $cur - enabling low-load"
  elif [ "$DISABLE_UNSTABLE" = yes ]; then
    tune_set "$g" $C_DIS 1; log "TUNE: GPU #$g still failing at intensity $cur + low-load - DISABLED (Settings > Reset GPU tuning)"
  else
    log "TUNE: GPU #$g failed at lowest settings ($crashes total) - nothing left to lower"
  fi
}

# Build T-Rex args into ARGS from config + tuning. Returns 1 if no GPU is usable.
build_args() {
  local g ids=() ints=() lows=() any_i=0 any_l=0 o s l pass=$PASS
  for g in $(active_gpus); do
    ids+=("$g"); o=$(tune_get "$g" $C_OVR); s=$(tune_get "$g" $C_SEEN); l=$(tune_get "$g" $C_LOW)
    if [ "$o" != - ]; then any_i=1; ints+=("$o"); elif [ "$s" != - ]; then ints+=("$s"); else ints+=("$DEFAULT_INTENSITY"); fi
    lows+=("$l"); [ "$l" = 1 ] && any_l=1
  done
  [ ${#ids[@]} -gt 0 ] || return 1
  [ -n "$WORKER" ] && pass+=",ID=$WORKER"
  ARGS=(-a "$ALGO" -o "$POOL" -u "$WALLET" -p "$pass" -w "${WORKER:-rig}"
        --pci-indexing --no-watchdog --exit-on-cuda-error --no-color
        --api-bind-http "127.0.0.1:$API_PORT" --api-bind-telnet 0
        -d "$(IFS=,; echo "${ids[*]}")")
  (( any_i )) && ARGS+=(-i "$(IFS=,; echo "${ints[*]}")")
  (( any_l )) && ARGS+=(--low-load "$(IFS=,; echo "${lows[*]}")")
  # EXTRA is intentionally word-split into separate flags
  # shellcheck disable=SC2206
  ARGS+=($EXTRA)
}

# ---------- supervisor (runs detached via --supervise) ----------
supervise() {
  local mpid off start now json reason blame rc apifail fast=0 delay id hs int dis t
  local spid=""
  nap() { sleep "$1" & spid=$!; wait "$spid"; spid=""; }   # interruptible sleep, so TERM acts at once
  trap 'kill -TERM ${mpid:-} ${spid:-} 2>/dev/null; exit 0' TERM INT
  while true; do
    # shellcheck disable=SC1090
    . "$CONF"
    if ! build_args; then log "no usable GPUs (all disabled?) - retrying in 5 min"; nap 300; continue; fi
    off=$(stat -c %s "$LOGFILE" 2>/dev/null || echo 0)
    log "starting t-rex ${ARGS[*]}"
    "$BIN" "${ARGS[@]}" >> "$LOGFILE" 2>&1 < /dev/null &
    mpid=$!; start=$(date +%s); apifail=0; reason=""; blame=""
    declare -A zero=()
    while kill -0 "$mpid" 2>/dev/null; do
      for (( t = 0; t < CHECK_EVERY; t++ )); do kill -0 "$mpid" 2>/dev/null || continue 2; nap 1; done   # react to a crash within 1s
      now=$(date +%s); (( now - start < GRACE )) && continue
      if ! json=$(api); then
        (( ++apifail >= 3 )) && { reason="API not responding for 3 checks (miner hung)"; break; }
        continue
      fi
      apifail=0
      while read -r id hs int dis; do
        # remember T-Rex's auto intensity so a later derate starts from it
        [ "$int" != null ] && [ "$(tune_get "$id" $C_OVR)" = - ] && [ "$(tune_get "$id" $C_SEEN)" != "$int" ] && tune_set "$id" $C_SEEN "$int"
        if [ "$dis" = true ] || awk -v h="$hs" 'BEGIN {exit !(h>0)}'; then unset "zero[$id]"; continue; fi
        [ -z "${zero[$id]:-}" ] && zero[$id]=$now
        if (( now - zero[$id] >= DEAD_AFTER )); then reason="GPU #$id at 0 H/s for $(( now - zero[$id] ))s"; blame=$id; break 2; fi
      done < <(jq -r '.gpus[]? | "\(.gpu_id) \(.hashrate // 0) \(.intensity // "null") \(.disabled // false)"' <<< "$json")
    done
    if [ -n "$reason" ]; then
      log "WATCHDOG: $reason - restarting miner"
      kill -TERM "$mpid" 2>/dev/null
      for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$mpid" 2>/dev/null || break; sleep 1; done
      kill -KILL "$mpid" 2>/dev/null
    fi
    wait "$mpid"; rc=$?; mpid=""
    # which GPU crashed? e.g. "Can't find nonce with device [ID=0, GPU #0], cuda exception ... illegal memory access"
    [ -z "$blame" ] && blame=$(tail -c +$(( off + 1 )) "$LOGFILE" | strip_ansi \
      | grep -i -E 'cuda exception|illegal|cuda error|CUDA_ERROR|launch fail' | grep -o -E 'GPU #[0-9]+' | tail -n 1 | tr -dc '0-9')
    log "miner exited rc=$rc${blame:+ - GPU #$blame failed}"
    [ -n "$blame" ] && derate "$blame"
    if (( $(date +%s) - start < 120 )); then fast=$(( fast + 1 )); else fast=0; fi
    delay=$RESTART_DELAY; (( fast >= 3 )) && delay=15
    log "restarting in ${delay}s"; nap "$delay"
  done
}

# ---------- environment preflight ----------
nvml_present() { { ls /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 /usr/lib64/libnvidia-ml.so.1 /usr/lib/libnvidia-ml.so.1 2>/dev/null
                   ldconfig -p 2>/dev/null | grep -o '/[^ ]*libnvidia-ml.so.1'; } | head -n1; }
gpu_names() {
  if nvidia-smi -L >/dev/null 2>&1; then nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd',' -
  else local g; g=$(lspci 2>/dev/null | grep -i -E 'vga|3d controller' | sed 's/.*: //' | paste -sd';' -); echo "${g:-none detected}"; fi
}
preflight() {   # preflight [quiet]
  local problems=() p t
  [ -x "$BIN" ] || problems+=("t-rex not installed (Install / --install)")
  [ -n "$(nvml_present)" ] || problems+=("libnvidia-ml.so.1 missing (no NVIDIA driver)")
  command -v nvidia-smi >/dev/null 2>&1 || problems+=("nvidia-smi missing")
  command -v jq >/dev/null 2>&1 || problems+=("jq missing (apt install jq)")
  command -v curl >/dev/null 2>&1 || problems+=("curl missing")
  [[ -n "$WALLET" && "$WALLET" != *[[:space:]]* ]] || problems+=("wallet not set (Settings > Wallet, or BTX_WALLET=...)")
  [ -n "$(active_gpus)" ] || problems+=("no active GPUs (all disabled by tuning? Settings > Reset GPU tuning)")
  [ ${#problems[@]} -eq 0 ] && return 0
  t="Preflight FAILED.\n\nDetected GPU(s): $(gpu_names)\n\n"
  for p in "${problems[@]}"; do t+="  x $p\n"; done
  t+="\nT-Rex is a CUDA (NVIDIA) miner: needs an NVIDIA card and driver >= 455."
  if [ "${1:-}" = quiet ]; then printf '%b\n' "$t" >&2; else err "$t"; fi
  return 1
}

# ---------- process control ----------
supervisor_pid() {
  local p; p=$(cat "$PIDFILE" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
  return 1
}
is_running() { supervisor_pid >/dev/null; }
miner_pids() { pgrep -f "$BIN -a" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

start_core() {
  is_running && return 0
  setsid nohup "$SELF" --supervise >> "$SUPOUT" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"
  sleep 3
  is_running
}
stop_core() {
  local p i; p=$(supervisor_pid) || true
  if [ -n "${p:-}" ]; then
    kill -TERM -- "-$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null
    for i in 1 2 3 4 5; do is_running || break; sleep 1; done
    is_running && kill -KILL -- "-$p" 2>/dev/null
  fi
  pkill -KILL -f "$BIN -a" 2>/dev/null
  rm -f "$PIDFILE"
}
state_line() {
  if is_running; then [ -n "$(miner_pids)" ] && echo RUNNING || echo "RESTARTING"; else echo STOPPED; fi
}

# ---------- stats (from the T-Rex HTTP API + tuning state) ----------
totals() {   # "accepted rejected hashing/gpus hashrate"
  local json a r h live n
  json=$(api 2>/dev/null) || { echo "0 0 0/0 n/a"; return; }
  read -r a r h live n <<< "$(jq -r '"\(.accepted_count // 0) \(.rejected_count // 0) \(.hashrate // 0) \([.gpus[]? | select(.hashrate > 0)] | length) \(.gpus | length)"' <<< "$json")"
  echo "$a $r $live/$n $(hr "$h")"
}
gpu_rows() {
  local json g name hs temp fan int tags
  json=$(api 2>/dev/null) || json='{}'
  for g in $(all_gpus); do
    read -r name hs temp fan int <<< "$(jq -r --argjson g "$g" '.gpus[]? | select(.gpu_id == $g) | "\(.name | gsub(" "; "_")) \(.hashrate // 0) \(.temperature // "-") \(.fan_speed // "-") \(.intensity // "-")"' <<< "$json")"
    tags=""
    [ "$(tune_get "$g" $C_OVR)" != - ] && tags+=" tuned"
    [ "$(tune_get "$g" $C_LOW)" = 1 ] && tags+=" low-load"
    [ "$(tune_get "$g" $C_CRASH)" != 0 ] && tags+=" crashes=$(tune_get "$g" $C_CRASH)"
    if [ "$(tune_get "$g" $C_DIS)" = 1 ]; then tags+=" DISABLED"
    elif [ -n "${name:-}" ] && ! awk -v h="$hs" 'BEGIN {exit !(h>0)}'; then tags+="  <-- NOT HASHING"; fi
    printf 'GPU#%-2s %-22s %12s %4sC fan %3s%% i=%-4s%s\n' "$g" "${name:--}" "$( [ -n "${name:-}" ] && hr "$hs" || echo -)" "${temp:--}" "${fan:--}" "${int:--}" "$tags"
  done
}
log_events() {
  tail -n 400 "$LOGFILE" 2>/dev/null | strip_ansi | grep -E 'supervisor:|OK \]|WARN|ERROR|TREX:' | tail -n "$1" | cut -c1-$(( BOX_W - 8 )) | grep . || echo "  (none)"
}
watchdog_count() { grep -c -E 'GPU #[0-9]+ failed|WATCHDOG:' "$LOGFILE" 2>/dev/null || true; }

# ---------- install ----------
install_core() {
  local tmp="$DIR/.t-rex.dl" x="$DIR/.t-rex.x" got; rm -rf "$tmp" "$x"
  curl -fL --progress-bar -o "$tmp" "$URL" || { rm -f "$tmp"; echo "Download failed."; return 1; }
  got=$(sha256sum "$tmp" | awk '{print $1}')
  [ "$got" = "$SHA" ] || { rm -f "$tmp"; echo "CHECKSUM MISMATCH - refusing to install. Expected $SHA got $got"; return 1; }
  mkdir -p "$x" && tar xzf "$tmp" -C "$x" t-rex || { rm -rf "$tmp" "$x"; echo "Extract failed."; return 1; }
  is_running && echo "Note: miner is running; restart it to use the new binary."
  chmod +x "$x/t-rex" && mv -f "$x/t-rex" "$BIN" && rm -rf "$tmp" "$x" && echo "Installed $BIN $VERSION (sha256 OK)"
}

ensure_pkgs() {   # install missing commands via apt
  local missing=() p SUDO=""
  for p in "$@"; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "Installing: ${missing[*]} ..."
  if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null || { echo "Need root to install ${missing[*]}." >&2; return 1; }; SUDO=sudo; fi
  command -v apt-get >/dev/null || { echo "apt-get not found; install ${missing[*]} manually." >&2; return 1; }
  $SUDO apt-get update && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${missing[@]}"
}

# ---------- headless CLI ----------
cli_status() {
  local st sp up acc rej live rate; st=$(state_line)
  case $st in
    STOPPED) printf '\033[1;31mMINER STOPPED\033[0m\n' ;;
    *) sp=$(supervisor_pid); up=$(ps -o etimes= -p "$sp" 2>/dev/null | tr -d ' ')
       printf '\033[1;32mMINER %s\033[0m  sup=%s up=%s pids=[%s]\n' "$st" "$sp" "$(pretty_time "${up:-0}")" "$(miner_pids)" ;;
  esac
  printf 'pool   %s\nworker %s / %s\nlog    %s\ngpus   %s\n' "$POOL" "$WALLET" "$WORKER" "$LOGFILE" "$(gpu_line)"
  read -r acc rej live rate <<< "$(totals)"
  printf 'hash   %s (%s GPUs hashing)   shares accepted %s / rejected %s   GPU restarts %s\n' "$rate" "$live" "$acc" "$rej" "$(watchdog_count)"
  gpu_rows | sed 's/^/       /'
  [ -f "$LOGFILE" ] && { echo "--- tail ---"; tail -n "${1:-8}" "$LOGFILE" | strip_ansi; }
  return 0
}
cli_start() {
  preflight quiet || return 2
  is_running && { echo "already running"; return 0; }
  if start_core; then echo "started sup=$(supervisor_pid)"; else echo "start failed" >&2; return 1; fi
}

case "${1:-}" in
  --supervise) supervise; exit 0 ;;
  --status)    cli_status "${2:-8}"; exit 0 ;;
  --preflight) preflight quiet && echo "preflight OK"; exit $? ;;
  --start)     ensure_pkgs jq curl || exit 1; cli_start; exit $? ;;
  --stop)      stop_core; echo stopped; exit 0 ;;
  --restart)   ensure_pkgs jq curl || exit 1; stop_core; cli_start; exit $? ;;
  --install)   ensure_pkgs jq curl || exit 1; install_core; exit $? ;;
  --reset-tuning) : > "$TUNE"; echo "GPU tuning reset (restart to apply)"; exit 0 ;;
  -h|--help)
    cat <<'EOF'
trex-btx.sh                       interactive menu (whiptail)
  --status [lines]                one-shot status + log tail
  --preflight                     check NVIDIA driver / binary / wallet
  --start | --stop | --restart    headless control
  --install                       download + verify + install T-Rex
  --reset-tuning                  forget per-GPU intensity drops / disabled GPUs
Env: BTX_TREX_DIR (default /opt/btx-trex), BTX_WALLET, BTX_WORKER (defaults on first run)
EOF
    exit 0 ;;
  "") ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 64 ;;
esac

# ---------- interactive UI ----------
BOX_H=22 BOX_W=78
box_fit() {
  local l c; l=$(tput lines 2>/dev/null || echo 24); c=$(tput cols 2>/dev/null || echo 80)
  BOX_H=$(( l - 4 )); (( BOX_H < 8 )) && BOX_H=8; (( BOX_H > 26 )) && BOX_H=26
  BOX_W=$(( c - 4 )); (( BOX_W < 40 )) && BOX_W=40; (( BOX_W > 110 )) && BOX_W=110
}
msg()   { box_fit; whiptail --title "$APP_TITLE" --backtitle "$DIR" --msgbox "$1" "$BOX_H" "$BOX_W"; }
err()   { box_fit; whiptail --title "$APP_TITLE — ERROR" --backtitle "$DIR" --msgbox "$1" "$BOX_H" "$BOX_W"; }
ask()   { local h; h=$(( $(printf '%b\n' "$1" | wc -l) + 8 )); box_fit; (( h > BOX_H )) && h=$BOX_H
          whiptail --title "$APP_TITLE" --backtitle "Settings" --inputbox "$1" "$h" 74 "$2" 3>&1 1>&2 2>&3; }
yesno() { whiptail --title "$APP_TITLE" --backtitle "$DIR" --yesno "$1" 14 72; }

do_start() {
  is_running && { msg "Miner is already running (supervisor PID $(supervisor_pid))."; return; }
  [ -x "$BIN" ] || { err "T-Rex is not installed in $DIR.\n\nUse 'Install / update miner' first."; return; }
  if [ -z "$WALLET" ]; then local v; v=$(ask "Your wallet address:" "$WALLET") || return; WALLET=$v; save_conf; fi
  preflight || return
  if start_core; then msg "Miner started.\n\nSupervisor PID: $(supervisor_pid)\nPool:   $POOL\nWorker: $WORKER\nGPUs:   $(active_gpus)\n\nLog: $LOGFILE"
  else err "Startup failed. supervisor.out:\n\n$(tail -n 15 "$SUPOUT" 2>/dev/null | strip_ansi)"; fi
}
do_stop() { if is_running || [ -n "$(miner_pids)" ]; then stop_core; msg "Miner stopped."; else msg "Miner is not running."; fi; }

do_status() {
  local s st sp up acc rej live rate; st=$(state_line); box_fit
  s="T-Rex $VERSION in $DIR\n$(printf '%.0s-' {1..45})\nSTATE         $st\n"
  if is_running; then sp=$(supervisor_pid); up=$(ps -o etimes= -p "$sp" 2>/dev/null | tr -d ' ')
    s+="Supervisor    PID $sp (up $(pretty_time "${up:-0}"))\nMiner PID(s)  $(miner_pids)\n"
  else
    [ -x "$BIN" ] && s+="Binary        installed\n" || s+="Binary        NOT installed\n"
    [ -n "$(nvml_present)" ] && s+="NVIDIA        driver present\n" || s+="NVIDIA        NOT present - GPU: $(gpu_names)\n"
  fi
  read -r acc rej live rate <<< "$(totals)"
  s+="Pool          $POOL\nWorker        $WALLET / $WORKER\nGPUs          $(gpu_line)\n"
  s+="Hashrate      $rate ($live GPUs hashing)\nShares        accepted $acc | rejected $rej\nGPU restarts  $(watchdog_count)\n"
  s+="Last error    $(last_error)\nLog           $LOGFILE ($(size_h "$LOGFILE"))\n"
  s+="$(printf '%.0s-' {1..45})\n$(gpu_rows)\n\nRecent events:\n$(log_events 6)"
  whiptail --title "$APP_TITLE — STATUS" --backtitle "$DIR" --msgbox "$s" "$BOX_H" "$BOX_W"
}
do_tuning() {
  local s; box_fit
  s="Per-GPU auto-tuning (crash -> intensity -$STEP, floor $MIN_INTENSITY -> low-load -> "
  s+="$( [ "$DISABLE_UNSTABLE" = yes ] && echo disable || echo keep trying ))\n\n$(gpu_rows)\n\nTuning events:\n"
  s+="$(grep -E 'TUNE:|WATCHDOG:|GPU #[0-9]+ failed' "$LOGFILE" 2>/dev/null | tail -n 10 | cut -c1-$(( BOX_W - 6 )) || true)"
  whiptail --title "$APP_TITLE — GPU TUNING" --backtitle "$DIR" --msgbox "$s" "$BOX_H" "$BOX_W"
}
do_live_log() {
  [ -f "$LOGFILE" ] || { err "No log file yet at $LOGFILE"; return; }
  clear; printf '\033[1;36m  LIVE LOG — %s   (Ctrl+C to return)\033[0m\n\n' "$LOGFILE"
  trap ':' INT; tail -n 40 -f "$LOGFILE" | strip_ansi; trap 'clear; exit 0' INT TERM
  printf '\n\033[0;90m  press Enter...\033[0m'; read -r _
}
do_view_log() {
  [ -f "$LOGFILE" ] || { err "No log file yet at $LOGFILE"; return; }
  local n; n=$(ask "How many lines from the end?" 200) || return
  tail -n "${n:-200}" "$LOGFILE" | strip_ansi | ${PAGER:-less} -R
}
do_install() {
  yesno "Download T-Rex $VERSION (CUDA 11.1) into $DIR and verify SHA-256?\n\n$SHA" || return
  clear; echo "Downloading T-Rex $VERSION ..."
  local out rc; out=$(install_core); rc=$?; echo "$out"; sleep 1
  if [ $rc -eq 0 ]; then msg "$out"; else err "$out"; fi
}
do_settings() {
  local c v
  while true; do
    box_fit
    c=$(whiptail --title "$APP_TITLE — SETTINGS" --backtitle "$DIR" --menu "Changes apply on next (re)start." "$BOX_H" "$BOX_W" 12 \
      1 "Pool          : $POOL" \
      2 "Wallet        : $WALLET" \
      3 "Password      : $PASS" \
      4 "Worker        : $WORKER" \
      5 "GPUs          : ${DEVICES:-all} ($(gpu_count) detected)" \
      6 "Extra args    : ${EXTRA:--}" \
      7 "Tuning step   : -$STEP per crash, floor $MIN_INTENSITY" \
      8 "Disable GPU if still unstable: $DISABLE_UNSTABLE" \
      9 "Dead GPU = 0 H/s for (s): $DEAD_AFTER" \
      R "Reset GPU tuning (back to auto intensity)" \
      T "Truncate log file" \
      0 "Back" 3>&1 1>&2 2>&3) || return
    case "$c" in
      1) v=$(ask "Pool URL:" "$POOL") && POOL=$v ;;
      2) v=$(ask "Wallet address:" "$WALLET") && WALLET=$v ;;
      3) v=$(ask "Pool password (zpool: c=PAYOUT_COIN,zap=BTX):" "$PASS") && PASS=$v ;;
      4) v=$(ask "Worker name:" "$WORKER") && WORKER=$v ;;
      5) v=$(ask "GPU indices to mine on (PCI order, e.g. 0,2). Blank = all.\n\n$(nvidia-smi -L 2>/dev/null | cut -c1-60)" "$DEVICES") || continue
         if [[ -z "$v" || "$v" =~ ^[0-9]+(,[0-9]+)*$ ]]; then DEVICES=$v; else err "Use GPU numbers like 0,1,3 (or blank for all)."; continue; fi ;;
      6) v=$(ask "Extra T-Rex flags (blank for none):" "$EXTRA") && EXTRA=$v ;;
      7) v=$(ask "Intensity drop per crash:" "$STEP") && STEP=$v
         v=$(ask "Minimum intensity (8-25):" "$MIN_INTENSITY") && MIN_INTENSITY=$v ;;
      8) if yesno "Disable a GPU that keeps crashing at the minimum intensity + low-load?\n\n(Otherwise it keeps restarting the whole miner.)"; then DISABLE_UNSTABLE=yes; else DISABLE_UNSTABLE=no; fi ;;
      9) v=$(ask "Seconds at 0 H/s before a GPU is treated as dead:" "$DEAD_AFTER") && DEAD_AFTER=$v ;;
      R) yesno "Forget all per-GPU intensity drops, low-load and disabled GPUs?" && : > "$TUNE" && msg "Tuning reset. Restart the miner to apply." ;;
      T) [ -f "$LOGFILE" ] && : > "$LOGFILE" && msg "Log truncated." ;;
      0|"") return ;;
    esac
    save_conf
  done
}
do_advanced() {
  local c
  while true; do
    box_fit
    c=$(whiptail --title "$APP_TITLE — ADVANCED" --backtitle "$DIR" --menu "" "$BOX_H" "$BOX_W" 5 \
      1 "Show supervisor output" 2 "Show config file" 3 "Kill all miner processes" \
      4 "Uninstall (remove $DIR)" 0 "Back" 3>&1 1>&2 2>&3) || return
    case "$c" in
      1) [ -f "$SUPOUT" ] && ${PAGER:-less} -R "$SUPOUT" || msg "No supervisor output." ;;
      2) ${PAGER:-less} -R "$CONF" ;;
      3) stop_core; msg "All T-Rex processes killed." ;;
      4) yesno "Stop the miner and DELETE $DIR (binary, log, config, tuning)?" || continue
         stop_core; cd / && rm -rf "$DIR"; msg "Removed $DIR."; exit 0 ;;
      0|"") return ;;
    esac
  done
}

ensure_pkgs whiptail jq curl || exit 1

trap 'clear; exit 0' INT TERM
[ -x "$BIN" ] || { yesno "T-Rex is not installed in $DIR.\n\nInstall it now?" && do_install; }
[ -x "$BIN" ] && ! is_running && yesno "The miner is not running.\n\nStart mining now?" && do_start
while true; do
  state=$(state_line); [ -z "$(nvml_present)" ] && state="$state | NO NVIDIA DRIVER"
  clear
  printf '\033[1;36m=== %s  %s ===\033[0m\n' "$APP_TITLE" "$VERSION"
  printf '\033[0;90m%s | %s\033[0m\n' "$POOL" "$DIR"
  printf 'State: \033[1m%s\033[0m\n\n' "$state"
  cat <<'MENU'
  1) Status dashboard
  2) Start mining
  3) Stop mining
  4) Restart
  5) Live log (follow)
  6) View log
  7) GPU tuning / crash history
  8) Settings (pool, wallet, GPUs, tuning)
  9) Install / update T-Rex (verify sha256)
  A) Advanced / uninstall
  0) Quit  (or q)

MENU
  printf 'Press a key: '
  IFS= read -rsn1 choice || break
  [ "$choice" = q ] || [ "$choice" = Q ] && choice=0
  case "$choice" in
    1) do_status ;;   2) do_start ;;    3) do_stop ;;
    4) stop_core; do_start ;;           5) do_live_log ;;
    6) do_view_log ;; 7) do_tuning ;;   8) do_settings ;;
    9) do_install ;;  A|a) do_advanced ;;
    0) break ;;
  esac
done
clear
