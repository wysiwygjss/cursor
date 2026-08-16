#!/usr/bin/env bash
#
# keyhunt_random_scanner.sh - Production-grade randomized chunk scanner for
# KeyHunt-CUDA range searches (e.g. Bitcoin "puzzle" challenges).
#
# This is a hardened rewrite of a hand-rolled scanner script. It is meant to
# run unattended for months on a GPU box, so correctness, resumability, and
# "never silently waste GPU time / electricity" are the primary design goals.
#
# Fixes relative to the original script this was derived from:
#   1. Fatal syntax bug: `sub "$x" 1")` had a stray quote that made the whole
#      script fail to parse (`bash -n` errored out) - it could never run at
#      all. All arithmetic now goes through a single hardened `bc_calc()`.
#   2. PID/signal bug: the original piped keyhunt through `tee` in the
#      background (`cmd | tee log &`), so `$!` captured tee's PID, not
#      keyhunt's. Ctrl-C / SIGTERM therefore killed the wrong process and
#      could leave the GPU miner running as an orphan. This version launches
#      keyhunt directly under `timeout --kill-after=15`, which on its own
#      already creates a new process group for the child and forwards any
#      signal it receives to that whole group - `$!` now correctly refers to
#      the real, killable process. On top of that, every run records its
#      active PID in a state file; if this supervisor itself ever dies
#      uncleanly (SIGKILL, OOM-killer, host crash) the *next* startup detects
#      and kills any matching orphaned keyhunt process before starting new
#      work, so a crash can never leave the GPU silently mining unattended.
#      This orphan check only ever runs *after* the single-instance lock is
#      successfully acquired, so it can never mistake another still-running,
#      healthy instance (e.g. one already managed by systemd) for an orphan.
#   3. savedchunks duplication: the original copied the whole per-chunk
#      progress file to a brand-new timestamped file on every single
#      attempt, so a chunk revisited 50 times over a few months produced 50
#      redundant, ever-larger backup copies (steady disk-usage bomb, no
#      information gained). Backups are now a single periodic tar.gz
#      snapshot of the whole progress directory, decoupled from per-chunk
#      processing and pruned to a retention count.
#   4. "Already complete" fast-path in the scheduler compared a zero-padded
#      canonical hex string against the raw puzzle-file text, which could
#      silently never match depending on the puzzle file's formatting. All
#      completion checks now go through one integer-based helper
#      (`is_chunk_complete`) shared by the scheduler and the worker.
#   5. No circuit breaker: if the binary/driver is broken, the original would
#      tight-loop forever (5s sleep) "scanning" nothing for months without
#      any signal that it was doing nothing useful. This version tracks
#      consecutive abnormal exits and zero-progress runs, backs off
#      exponentially, raises loud alerts, and eventually aborts rather than
#      spinning forever burning power for zero result. Run it under systemd
#      (see the .service file next to this script) so it gets a clean
#      restart after a genuine transient failure, without hiding a
#      persistent one.
#      Failure detection compares reported progress against the segment's
#      key count, not elapsed time vs. SCAN_DURATION - a fast GPU can
#      legitimately finish an entire segment well before the requested
#      duration and exit cleanly; that's success, not a crash. If every
#      segment finishes much faster than SCAN_DURATION on your hardware,
#      consider raising DEFAULT_SEGMENT_SIZE so each GPU-kernel/bloom-filter
#      startup amortizes over more actual scanning time.
#
# Usage:
#   ./keyhunt_random_scanner.sh              # run the scanner loop (daemon)
#   ./keyhunt_random_scanner.sh --self-test  # validate env & math, no scanning
#   ./keyhunt_random_scanner.sh --status     # print progress/health summary
#   ./keyhunt_random_scanner.sh --once       # process a single chunk and exit
#   ./keyhunt_random_scanner.sh --help
#
# Every path/tunable below can be overridden via environment variables
# without editing this file, e.g.:
#   SCAN_DURATION=1800 GPU_INDEX=1 ./keyhunt_random_scanner.sh
#
set -Eeuo pipefail

### ---------------------------------------------------------------------
### Configuration (override via environment variables)
### ---------------------------------------------------------------------
SCANNING_DIR="${SCANNING_DIR:-$HOME/Documents/keyhunt_cuda_sandbox}"
PUZZLE_FILE="${PUZZLE_FILE:-$SCANNING_DIR/puzzle71_10000.txt}"
KEYHUNT_BIN="${KEYHUNT_BIN:-$SCANNING_DIR/keyhunt_cuda}"
TARGETS_FILE="${TARGETS_FILE:-$SCANNING_DIR/hash160.bin}"

SAVED_CHUNKS_DIR="${SAVED_CHUNKS_DIR:-$SCANNING_DIR/savedchunks}"
SCANNED_CHUNKS_DIR="${SCANNED_CHUNKS_DIR:-$SCANNING_DIR/scannedchunks}"
LOCK_DIR="${LOCK_DIR:-$SCANNING_DIR/locks}"
LOG_DIR="${LOG_DIR:-$SCANNING_DIR/logs}"
STATE_DIR="${STATE_DIR:-$SCANNING_DIR/state}"

COIN="${COIN:-BTC}"
KEYHUNT_MODE="${KEYHUNT_MODE:-ADDRESSES}"
GPU_INDEX="${GPU_INDEX:-0}"

DEFAULT_SEGMENT_SIZE="${DEFAULT_SEGMENT_SIZE:-4144806000000}"
SCAN_DURATION="${SCAN_DURATION:-3600}"          # seconds per segment attempt
LOOP_SLEEP_SECONDS="${LOOP_SLEEP_SECONDS:-5}"   # idle pause between healthy attempts
MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-5}"

MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-5}"
FAILURE_BACKOFF_BASE_SECONDS="${FAILURE_BACKOFF_BASE_SECONDS:-30}"
FAILURE_BACKOFF_MAX_SECONDS="${FAILURE_BACKOFF_MAX_SECONDS:-1800}"
ZERO_PROGRESS_ALERT_THRESHOLD="${ZERO_PROGRESS_ALERT_THRESHOLD:-3}"

BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-21600}"   # 6h
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-30}"
MAINTENANCE_INTERVAL_SECONDS="${MAINTENANCE_INTERVAL_SECONDS:-3600}" # 1h
LOG_COMPRESS_AFTER_DAYS="${LOG_COMPRESS_AFTER_DAYS:-2}"
LOG_DELETE_AFTER_DAYS="${LOG_DELETE_AFTER_DAYS:-30}"

SEGMENT_COMPLETION_TOLERANCE_PERCENT="${SEGMENT_COMPLETION_TOLERANCE_PERCENT:-1}" # see process_chunk
STOP_ON_FOUND="${STOP_ON_FOUND:-1}"    # halt the whole scanner once a key is found anywhere
# Refuses to run a second scanner against the same SCANNING_DIR (default: on).
# If you run one instance per GPU, give each instance its own SCANNING_DIR
# (or at least its own STATE_DIR/LOG_DIR) and set SINGLE_INSTANCE=0 - state
# such as the orphan-reaper PID file is not safe to share between instances.
SINGLE_INSTANCE="${SINGLE_INSTANCE:-1}"

export BC_LINE_LENGTH=0  # disable bc's 70-col output wrapping; large numbers must stay one line

### ---------------------------------------------------------------------
### Globals (do not override)
### ---------------------------------------------------------------------
LOCK_FD=""
INSTANCE_LOCK_FD=""
KH_PID=""
TAIL_PID=""
KH_PID_FILE="${STATE_DIR}/current_keyhunt.pid"
CONSECUTIVE_FAILURES=0
ZERO_PROGRESS_STREAK=0
ITERATIONS=0
LAST_SEGMENT_HAD_PROGRESS=0
CHUNK_COUNT=0
SCANNER_START_TIME=""

### ---------------------------------------------------------------------
### Logging
### ---------------------------------------------------------------------
log() {
    local level="$1"; shift
    local line
    line="[$(date -Is)] [$level] $*"
    echo "$line" >&2
    if [[ -d "$LOG_DIR" ]]; then
        echo "$line" >> "$LOG_DIR/scanner.log" 2>/dev/null || true
    fi
}

die() {
    log "ERROR" "$1"
    exit "${2:-1}"
}

alert() {
    local msg="$1"
    log "CRITICAL" "$msg"
    echo "[$(date -Is)] $msg" >> "$SCANNING_DIR/ALERTS.log" 2>/dev/null || true
}

### ---------------------------------------------------------------------
### Signal handling / cleanup
### ---------------------------------------------------------------------
terminate_current_segment() {
    local sig="${1:-TERM}"
    if [[ -n "$KH_PID" ]] && kill -0 "$KH_PID" 2>/dev/null; then
        log "WARN" "Sending SIG$sig to keyhunt process group (leader pid $KH_PID)"
        kill -s "$sig" -- "-$KH_PID" 2>/dev/null || kill -s "$sig" "$KH_PID" 2>/dev/null || true
    fi
    if [[ -n "$TAIL_PID" ]] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
}

release_instance_lock() {
    if [[ -n "$INSTANCE_LOCK_FD" ]]; then
        flock -u "$INSTANCE_LOCK_FD" 2>/dev/null || true
    fi
}

cleanup_and_exit() {
    log "INFO" "Signal received - stopping scanner gracefully..."
    terminate_current_segment TERM
    sleep 1
    terminate_current_segment KILL
    rm -f "$KH_PID_FILE" 2>/dev/null || true
    release_instance_lock
    exit 130
}
trap cleanup_and_exit INT TERM

### ---------------------------------------------------------------------
### Arbitrary-precision integer helpers (256-bit keyspace needs bc, not
### bash's 64-bit arithmetic)
### ---------------------------------------------------------------------
bc_calc() {
    local expr="$1" result
    result="$(bc <<< "$expr" 2>/dev/null)" || die "bc failed evaluating: $expr"
    result="${result//$'\n'/}"
    result="${result//$'\r'/}"
    [[ -n "$result" ]] || die "bc produced empty output for: $expr"
    printf '%s' "$result"
}

hex_to_int() {
    local hex="${1//[[:space:]]/}"
    [[ "$hex" =~ ^[0-9a-fA-F]+$ ]] || die "hex_to_int: invalid hex value '$1'"
    bc_calc "ibase=16; ${hex^^}"
}

int_to_hex() {
    local n="$1" hex
    [[ "$n" =~ ^[0-9]+$ ]] || die "int_to_hex: invalid integer '$1'"
    hex="$(bc_calc "obase=16; $n")"
    hex="${hex,,}"
    printf '%064s\n' "$hex" | tr ' ' '0'
}

add() { bc_calc "$1 + $2"; }
sub() { bc_calc "$1 - $2"; }
gt()  { bc_calc "$1 > $2"; }
ge()  { bc_calc "$1 >= $2"; }

### ---------------------------------------------------------------------
### Environment validation
### ---------------------------------------------------------------------
check_disk_space() {
    local available_gb
    available_gb=$(df -BG "$SCANNING_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
    [[ -n "$available_gb" ]] || return 1
    (( available_gb > MIN_FREE_SPACE_GB ))
}

# Safety net for the one case ordinary signal handling cannot cover: this
# supervisor being killed uncleanly (SIGKILL, OOM-killer, host crash, `kill -9`)
# while a keyhunt segment was running. In that case the trap never runs and
# keyhunt is reparented to init - it would otherwise keep the GPU running,
# unattended and unchecked, for as long as the machine stays up (exactly the
# "burning electricity for nothing, and nobody notices" failure mode). Every
# run records the active PID in $KH_PID_FILE; on the next startup we check it
# and kill any matching orphan before starting fresh work.
#
# IMPORTANT: must only be called *after* acquire_instance_lock() has
# succeeded. Only holding the lock proves no other instance is currently
# running - otherwise a PID recorded by a still-alive, perfectly healthy
# instance (e.g. one already running under systemd) would be misidentified
# as an orphan and killed by a second, redundant manual invocation.
reap_orphaned_segment() {
    [[ -f "$KH_PID_FILE" ]] || return 0
    local pid
    pid="$(cat "$KH_PID_FILE" 2>/dev/null)"
    rm -f "$KH_PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0

    if [[ -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qF "$KEYHUNT_BIN"; then
        alert "Found an orphaned keyhunt process (pid $pid) left running from a previous unclean shutdown - it may have been scanning unattended. Killing it before starting fresh work."
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
        log "INFO" "Orphaned keyhunt process (pid $pid) reaped"
    fi
}

validate_environment() {
    local missing=() cmd
    for cmd in bc timeout flock tail awk sed grep date df tar find; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"

    [[ -x "$KEYHUNT_BIN" ]] || die "Keyhunt binary not executable: $KEYHUNT_BIN"
    [[ -f "$PUZZLE_FILE" ]] || die "Puzzle file not found: $PUZZLE_FILE"
    [[ -f "$TARGETS_FILE" ]] || die "Targets file not found: $TARGETS_FILE"

    mkdir -p "$SAVED_CHUNKS_DIR" "$SCANNED_CHUNKS_DIR" "$LOCK_DIR" "$LOG_DIR" "$STATE_DIR"

    check_disk_space || die "Need > ${MIN_FREE_SPACE_GB}GB free in $SCANNING_DIR"

    if command -v nvidia-smi >/dev/null 2>&1; then
        log "INFO" "GPU: $(nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,utilization.gpu --format=csv,noheader 2>/dev/null || echo 'nvidia-smi query failed')"
    else
        log "WARN" "nvidia-smi not found - GPU health telemetry disabled"
    fi
}

### ---------------------------------------------------------------------
### Locking
### ---------------------------------------------------------------------
acquire_lock() {
    local chunk="$1" fd
    exec {fd}>"$LOCK_DIR/chunk_${chunk}.lock"
    if ! flock -n "$fd"; then
        eval "exec ${fd}>&-"
        return 1
    fi
    LOCK_FD="$fd"
    return 0
}

release_lock() {
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
        LOCK_FD=""
    fi
}

acquire_instance_lock() {
    [[ "$SINGLE_INSTANCE" == "1" ]] || return 0
    local lock_file="$STATE_DIR/scanner.instance.lock"
    exec {INSTANCE_LOCK_FD}>"$lock_file"
    flock -n "$INSTANCE_LOCK_FD" || die "Another instance is already running against $SCANNING_DIR (SINGLE_INSTANCE=1). Lock: $lock_file"
    echo "$$" > "$STATE_DIR/scanner.pid"
}

### ---------------------------------------------------------------------
### Chunk / checkpoint helpers
### ---------------------------------------------------------------------
# Validates both hex fields here (rather than letting a malformed line reach
# hex_to_int later) so one bad/corrupt line in a 10,000-line puzzle file
# results in that single chunk being skipped and logged, not the whole
# scanner crashing via hex_to_int's die() on invalid input.
get_chunk_range() {
    local chunk_num="$1" line s e
    line="$(sed -n "${chunk_num}p" "$PUZZLE_FILE")"
    [[ -n "$line" && "$line" == *:* ]] || return 1
    s="${line%%:*}"
    e="${line##*:}"
    s="${s//[[:space:]]/}"
    e="${e//[[:space:]]/}"
    [[ "$s" =~ ^[0-9a-fA-F]+$ ]] || return 1
    [[ "$e" =~ ^[0-9a-fA-F]+$ ]] || return 1
    printf '%s %s\n' "$s" "$e"
}

get_last_scanned() {
    local scanned_file="$1" last_hex
    [[ -s "$scanned_file" ]] || { printf ''; return 0; }
    last_hex="$(tail -n1 "$scanned_file" 2>/dev/null | awk '{print $NF}')"
    if [[ ! "$last_hex" =~ ^[0-9a-fA-F]{1,64}$ ]]; then
        printf ''
        return 0
    fi
    hex_to_int "$last_hex"
}

write_checkpoint() {
    local file="$1" hex_value="$2"
    printf '%s %s\n' "$(date -Is)" "$hex_value" >> "$file"
    sync "$file" 2>/dev/null || true
}

is_chunk_complete() {
    local chunk_num="$1" scanned_file="$2"
    [[ -s "$scanned_file" ]] || return 1
    local range end_hex end_int last_int
    range="$(get_chunk_range "$chunk_num")" || return 1
    end_hex="${range#* }"
    end_int="$(hex_to_int "$end_hex")"
    last_int="$(get_last_scanned "$scanned_file")"
    [[ -n "$last_int" ]] || return 1
    [[ "$(ge "$last_int" "$end_int")" -eq 1 ]]
}

### ---------------------------------------------------------------------
### keyhunt execution
### ---------------------------------------------------------------------
get_progress_count() {
    local log_file="$1" val
    [[ -f "$log_file" ]] || { echo 0; return 0; }
    val="$(grep -oE '\[T: [0-9,]+' "$log_file" 2>/dev/null | tail -n1 | grep -oE '[0-9,]+' | tr -d ',')"
    echo "${val:-0}"
}

# File descriptors bash opens (like our lock fds) are inherited by every
# child process by default. If a spawned keyhunt/tail process kept a
# duplicate of LOCK_FD or INSTANCE_LOCK_FD open, that lock would keep
# looking "held" to the OS for as long as that child (or an orphaned
# descendant of it) is alive - even long after this supervisor itself has
# exited or been killed. That would deadlock the very orphan-reaper meant to
# clean up after it: a fresh instance couldn't acquire the instance lock to
# get far enough to reap the orphan holding it. Always launch child
# processes through this helper (in a subshell, right before the final exec)
# so they start with a clean fd table.
close_inherited_locks_and_exec() {
    [[ -n "$LOCK_FD" ]] && eval "exec ${LOCK_FD}>&-" 2>/dev/null
    [[ -n "$INSTANCE_LOCK_FD" ]] && eval "exec ${INSTANCE_LOCK_FD}>&-" 2>/dev/null
    exec "$@"
}

# Runs one keyhunt segment. Returns 0 if it ran the full requested duration
# (or found a key), or 2 if it exited before that - which is NOT necessarily
# a failure (a fast GPU can legitimately finish its whole assigned segment
# early). The caller (process_chunk) makes the actual failure determination
# by comparing reported progress against the segment size, since elapsed
# time alone can't distinguish "finished early" from "crashed early".
#
# Launched via plain `timeout` (no extra setsid session): GNU timeout already
# puts the child in its own process group and forwards any signal it receives
# to that whole group, which is exactly what we need for clean shutdown while
# keeping the child in the same session as this script. Using setsid here
# would create a fully independent session that survives even if this
# supervisor itself dies uncleanly (SIGKILL/OOM/crash) - see
# reap_orphaned_segment() for the actual safety net against that case.
run_keyhunt_segment() {
    local start_hex="$1" end_hex="$2" found_file="$3" log_file="$4"
    rm -f "$found_file"
    : > "$log_file"

    (
        close_inherited_locks_and_exec timeout --kill-after=15 "$SCAN_DURATION" "$KEYHUNT_BIN" \
            -m "$KEYHUNT_MODE" --coin "$COIN" -i "$TARGETS_FILE" \
            --range "${start_hex}:${end_hex}" \
            -u -g --gpui "$GPU_INDEX" \
            -o "$found_file"
    ) > "$log_file" 2>&1 &
    KH_PID=$!
    echo "$KH_PID" > "$KH_PID_FILE" 2>/dev/null || true

    if command -v tail >/dev/null 2>&1; then
        ( close_inherited_locks_and_exec tail -n +1 -f "$log_file" --pid="$KH_PID" ) 2>/dev/null &
        TAIL_PID=$!
    fi

    local start_ts end_ts elapsed exit_code=0
    start_ts=$(date +%s)
    set +e
    wait "$KH_PID"
    exit_code=$?
    set -e
    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))

    if [[ -n "$TAIL_PID" ]]; then
        kill "$TAIL_PID" 2>/dev/null || true
        wait "$TAIL_PID" 2>/dev/null || true
        TAIL_PID=""
    fi
    KH_PID=""
    rm -f "$KH_PID_FILE" 2>/dev/null || true

    log "INFO" "keyhunt exited with code $exit_code after ${elapsed}s (requested ${SCAN_DURATION}s)"

    [[ -s "$found_file" ]] && return 0
    (( elapsed >= SCAN_DURATION - 5 )) && return 0

    log "INFO" "keyhunt exited after only ${elapsed}s (expected ~${SCAN_DURATION}s, exit=$exit_code) - checking whether it covered its assigned range"
    return 2
}

process_chunk() {
    local chunk_num="$1"
    local scanned_file="$SCANNED_CHUNKS_DIR/${chunk_num}.scanned.txt"
    local found_local="$SCANNING_DIR/Found_chunk_${chunk_num}.txt"
    local ts_now kh_log
    ts_now="$(date +%Y%m%d_%H%M%S)"
    kh_log="$LOG_DIR/keyhunt_${chunk_num}_${ts_now}.log"

    local range start_hex end_hex start_int end_int
    if ! range="$(get_chunk_range "$chunk_num")"; then
        log "WARN" "Chunk $chunk_num: missing or malformed line in puzzle file (expected 'starthex:endhex'), skipping this chunk only"
        return 1
    fi
    start_hex="${range% *}"
    end_hex="${range#* }"
    start_int="$(hex_to_int "$start_hex")"
    end_int="$(hex_to_int "$end_hex")"

    local last_int current_start_int
    last_int="$(get_last_scanned "$scanned_file")"

    if [[ -n "$last_int" ]]; then
        current_start_int="$(add "$last_int" 1)"
        log "INFO" "Chunk $chunk_num: resuming from $(int_to_hex "$current_start_int")"
    else
        current_start_int="$start_int"
        log "INFO" "Chunk $chunk_num: starting fresh"
    fi

    if [[ "$(gt "$current_start_int" "$end_int")" -eq 1 ]]; then
        log "INFO" "Chunk $chunk_num complete"
        return 0
    fi

    local seg_end_int
    seg_end_int="$(add "$current_start_int" "$DEFAULT_SEGMENT_SIZE")"
    seg_end_int="$(sub "$seg_end_int" 1)"
    [[ "$(gt "$seg_end_int" "$end_int")" -eq 1 ]] && seg_end_int="$end_int"

    local seg_start_hex seg_end_hex
    seg_start_hex="$(int_to_hex "$current_start_int")"
    seg_end_hex="$(int_to_hex "$seg_end_int")"

    log "INFO" "Chunk $chunk_num: scanning $seg_start_hex -> $seg_end_hex (up to ${SCAN_DURATION}s)"

    local rc=0
    run_keyhunt_segment "$seg_start_hex" "$seg_end_hex" "$found_local" "$kh_log" || rc=$?

    if [[ -s "$found_local" ]]; then
        alert "KEY FOUND in chunk $chunk_num! Saved to $SCANNING_DIR/FOUND_KEY_CHUNK_${chunk_num}.txt"
        write_checkpoint "$scanned_file" "$seg_end_hex"
        cp "$found_local" "$SAVED_CHUNKS_DIR/Found_${chunk_num}_$(date +%Y%m%d_%H%M%S).txt"
        cp "$found_local" "$SCANNING_DIR/FOUND_KEY_CHUNK_${chunk_num}.txt"
        rm -f "$found_local"
        touch "$STATE_DIR/FOUND"
        CONSECUTIVE_FAILURES=0
        LAST_SEGMENT_HAD_PROGRESS=1
        return 0
    fi

    local checked
    checked="$(get_progress_count "$kh_log")"

    if [[ "$checked" != "0" ]]; then
        local partial_end_int
        partial_end_int="$(add "$current_start_int" "$checked")"
        partial_end_int="$(sub "$partial_end_int" 1)"
        [[ "$(gt "$partial_end_int" "$seg_end_int")" -eq 1 ]] && partial_end_int="$seg_end_int"
        write_checkpoint "$scanned_file" "$(int_to_hex "$partial_end_int")"
        log "INFO" "Chunk $chunk_num: checkpoint saved at $(int_to_hex "$partial_end_int") ($checked hashes reported)"
        LAST_SEGMENT_HAD_PROGRESS=1
    else
        LAST_SEGMENT_HAD_PROGRESS=0
    fi

    # A fast GPU can fully scan a segment well before SCAN_DURATION elapses -
    # keyhunt then exits cleanly (exit 0) having covered its whole assigned
    # range, which is a completed segment, not a failure. Only treat an
    # early/short exit as abnormal if it did NOT actually cover the segment
    # (e.g. the binary crashed or the driver faulted right away). Compare
    # against the segment's own key count rather than elapsed time, since
    # elapsed time alone can't tell "finished early" apart from "crashed
    # early" - GPU throughput varies enormously across hardware.
    #
    # A small tolerance (SEGMENT_COMPLETION_TOLERANCE_PERCENT, default 1%) is
    # allowed below the exact segment size: keyhunt's progress log updates
    # periodically, not on every single key, so the very last line printed
    # before a clean exit can slightly understate the true final count.
    # A genuine crash reports nowhere close to the segment size, so this
    # tolerance doesn't meaningfully weaken failure detection.
    local segment_size segment_fully_covered=0 completion_threshold
    segment_size="$(add "$(sub "$seg_end_int" "$current_start_int")" 1)"
    completion_threshold="$(bc_calc "($segment_size * (100 - $SEGMENT_COMPLETION_TOLERANCE_PERCENT)) / 100")"
    if [[ "$checked" != "0" ]] && [[ "$(ge "$checked" "$completion_threshold")" -eq 1 ]]; then
        segment_fully_covered=1
    fi

    if [[ "$rc" -eq 2 ]] && [[ "$segment_fully_covered" -eq 0 ]]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "WARN" "Chunk $chunk_num: abnormal exit (consecutive failures now $CONSECUTIVE_FAILURES)"
    else
        if [[ "$rc" -eq 2 ]] && [[ "$segment_fully_covered" -eq 1 ]]; then
            log "INFO" "Chunk $chunk_num: finished early because it covered its whole assigned range at this GPU's speed - not a failure"
        fi
        CONSECUTIVE_FAILURES=0
    fi

    return 0
}

### ---------------------------------------------------------------------
### Maintenance: consolidated backups + log rotation (replaces the old
### "new timestamped copy per attempt" behaviour)
### ---------------------------------------------------------------------
maintenance_due() {
    local state_file="$1" interval="$2" last=0 now
    [[ -f "$state_file" ]] && last=$(cat "$state_file" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    now=$(date +%s)
    if (( now - last >= interval )); then
        echo "$now" > "$state_file"
        return 0
    fi
    return 1
}

run_backup_snapshot() {
    maintenance_due "$STATE_DIR/last_backup" "$BACKUP_INTERVAL_SECONDS" || return 0
    [[ -d "$SCANNED_CHUNKS_DIR" ]] || return 0

    local ts tmp_tar final_tar
    ts="$(date +%Y%m%d_%H%M%S)"
    final_tar="$SAVED_CHUNKS_DIR/scannedchunks_${ts}.tar.gz"
    tmp_tar="${final_tar}.tmp"

    if tar -C "$SCANNING_DIR" -czf "$tmp_tar" "$(basename "$SCANNED_CHUNKS_DIR")" 2>/dev/null; then
        mv -f "$tmp_tar" "$final_tar"
        log "INFO" "Backup snapshot written: $final_tar"
    else
        rm -f "$tmp_tar"
        log "WARN" "Backup snapshot failed"
        return 0
    fi

    local -a snapshots
    mapfile -t snapshots < <(find "$SAVED_CHUNKS_DIR" -maxdepth 1 -name 'scannedchunks_*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if (( ${#snapshots[@]} > BACKUP_RETENTION_COUNT )); then
        local i
        for (( i=BACKUP_RETENTION_COUNT; i<${#snapshots[@]}; i++ )); do
            rm -f "${snapshots[$i]}"
        done
        log "INFO" "Pruned old backups, retained newest $BACKUP_RETENTION_COUNT"
    fi
}

rotate_logs() {
    maintenance_due "$STATE_DIR/last_log_rotation" "$MAINTENANCE_INTERVAL_SECONDS" || return 0
    [[ -d "$LOG_DIR" ]] || return 0

    find "$LOG_DIR" -maxdepth 1 -name '*.log' ! -name 'scanner.log' -mtime "+${LOG_COMPRESS_AFTER_DAYS}" -print0 2>/dev/null \
        | xargs -0 -r gzip -f 2>/dev/null || true
    find "$LOG_DIR" -maxdepth 1 -name '*.log.gz' -mtime "+${LOG_DELETE_AFTER_DAYS}" -delete 2>/dev/null || true
    find "$LOCK_DIR" -maxdepth 1 -name '*.lock' -mtime "+${LOG_DELETE_AFTER_DAYS}" -delete 2>/dev/null || true
}

### ---------------------------------------------------------------------
### Stats / status
### ---------------------------------------------------------------------
update_stats() {
    local chunk_num="$1" had_progress="$2" tmp="$STATE_DIR/stats.txt.tmp"
    {
        echo "last_update=$(date -Is)"
        echo "last_chunk=$chunk_num"
        echo "last_chunk_had_progress=$had_progress"
        echo "iterations=$ITERATIONS"
        echo "consecutive_failures=$CONSECUTIVE_FAILURES"
        echo "zero_progress_streak=$ZERO_PROGRESS_STREAK"
        echo "chunks_total=$CHUNK_COUNT"
        echo "scanner_started=$SCANNER_START_TIME"
        echo "pid=$$"
    } > "$tmp" && mv -f "$tmp" "$STATE_DIR/stats.txt"
}

count_completed_chunks() {
    local n=0 f cn
    for f in "$SCANNED_CHUNKS_DIR"/*.scanned.txt; do
        [[ -e "$f" ]] || continue
        cn="$(basename "$f" .scanned.txt)"
        is_chunk_complete "$cn" "$f" && n=$((n+1))
    done
    echo "$n"
}

cmd_status() {
    echo "State directory: $STATE_DIR"
    if [[ -f "$STATE_DIR/stats.txt" ]]; then
        cat "$STATE_DIR/stats.txt"
    else
        echo "No stats recorded yet (scanner may not have completed an iteration)."
    fi
    [[ -f "$STATE_DIR/FOUND" ]] && echo ">>> FOUND marker is set - a key was found <<<"
    if [[ -f "$PUZZLE_FILE" ]]; then
        local total
        total=$(awk 'END{print NR}' "$PUZZLE_FILE")
        echo "Chunks fully complete: $(count_completed_chunks) / $total"
    fi
    if [[ -f "$SCANNING_DIR/ALERTS.log" ]]; then
        echo "--- recent alerts ---"
        tail -n 20 "$SCANNING_DIR/ALERTS.log"
    fi
}

### ---------------------------------------------------------------------
### Self-test (run this after any edit, before letting it run unattended)
### ---------------------------------------------------------------------
cmd_self_test() {
    local failures=0 cmd

    echo "== tool availability =="
    for cmd in bc timeout flock tail awk sed grep date df tar find; do
        if command -v "$cmd" >/dev/null 2>&1; then
            echo "[OK]   $cmd"
        else
            echo "[FAIL] missing: $cmd"; failures=$((failures+1))
        fi
    done

    echo "== hex/int round-trip =="
    local samples=(
        "0000000000000000000000000000000000000000000000000000000000000001"
        "00000000000000000000000000000000000000000000000000007fffffffffff"
        "8000000000000000000000000000000000000000000000000000000000000000"
    )
    local h i back
    for h in "${samples[@]}"; do
        i="$(hex_to_int "$h")"
        back="$(int_to_hex "$i")"
        if [[ "$back" == "${h,,}" ]]; then
            echo "[OK]   $h"
        else
            echo "[FAIL] $h -> $i -> $back"; failures=$((failures+1))
        fi
    done

    echo "== segment boundary math (no gap / no overlap) =="
    local seg_end next_start
    seg_end="$(add 1000 250)"
    seg_end="$(sub "$seg_end" 1)"
    next_start="$(add "$seg_end" 1)"
    if [[ "$seg_end" == "1249" && "$next_start" == "1250" ]]; then
        echo "[OK]   seg_end=$seg_end next_start=$next_start"
    else
        echo "[FAIL] seg_end=$seg_end next_start=$next_start (expected 1249 / 1250)"
        failures=$((failures+1))
    fi

    echo "== line counting (no trailing newline must not lose the last chunk) =="
    local tmp_no_nl count
    tmp_no_nl="$(mktemp)"
    printf '1:2\n3:4\n5:6' > "$tmp_no_nl"
    count=$(awk 'END{print NR}' "$tmp_no_nl")
    if [[ "$count" == "3" ]]; then
        echo "[OK]   3-line file without trailing newline counted as 3"
    else
        echo "[FAIL] counted as $count, expected 3 - last chunk would be unreachable"
        failures=$((failures+1))
    fi
    rm -f "$tmp_no_nl"

    echo "== malformed puzzle line must not crash the scanner =="
    local saved_puzzle_file="$PUZZLE_FILE" tmp_bad_puzzle
    tmp_bad_puzzle="$(mktemp)"
    printf 'not-valid-hex:also-not-valid\n' > "$tmp_bad_puzzle"
    PUZZLE_FILE="$tmp_bad_puzzle"
    if get_chunk_range 1 >/dev/null 2>&1; then
        echo "[FAIL] malformed line was accepted instead of rejected"
        failures=$((failures+1))
    else
        echo "[OK]   malformed line correctly rejected (chunk would be skipped, not crash)"
    fi
    PUZZLE_FILE="$saved_puzzle_file"
    rm -f "$tmp_bad_puzzle"

    echo "== files =="
    [[ -f "$PUZZLE_FILE" ]] && echo "[OK]   puzzle file: $PUZZLE_FILE" || echo "[WARN] puzzle file missing: $PUZZLE_FILE"
    [[ -x "$KEYHUNT_BIN" ]] && echo "[OK]   keyhunt binary: $KEYHUNT_BIN" || echo "[WARN] keyhunt binary missing/not executable: $KEYHUNT_BIN"
    [[ -f "$TARGETS_FILE" ]] && echo "[OK]   targets file: $TARGETS_FILE" || echo "[WARN] targets file missing: $TARGETS_FILE"
    check_disk_space && echo "[OK]   disk space > ${MIN_FREE_SPACE_GB}GB" || echo "[WARN] low disk space in $SCANNING_DIR"

    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "[OK]   nvidia-smi present"
    else
        echo "[WARN] nvidia-smi not found (GPU telemetry disabled)"
    fi

    echo
    if (( failures > 0 )); then
        echo "SELF-TEST FAILED ($failures failure(s))"
        return 1
    fi
    echo "SELF-TEST PASSED"
    return 0
}

### ---------------------------------------------------------------------
### Main loop
### ---------------------------------------------------------------------
backoff_sleep() {
    local attempt="$1" shift_amount delay
    shift_amount=$(( attempt > 10 ? 10 : attempt ))
    delay=$(( FAILURE_BACKOFF_BASE_SECONDS * (1 << shift_amount) ))
    (( delay > FAILURE_BACKOFF_MAX_SECONDS )) && delay=$FAILURE_BACKOFF_MAX_SECONDS
    log "WARN" "Backing off for ${delay}s (consecutive failures: $attempt)"
    sleep "$delay"
}

pick_random_chunk() {
    echo $(( ( (RANDOM << 15) | RANDOM ) % CHUNK_COUNT + 1 ))
}

run_one_iteration() {
    if [[ "$STOP_ON_FOUND" == "1" ]] && [[ -f "$STATE_DIR/FOUND" ]]; then
        alert "FOUND marker present - stopping scanner. Remove $STATE_DIR/FOUND to resume."
        return 1
    fi

    if [[ -f "$SCANNING_DIR/PAUSE" ]]; then
        log "INFO" "PAUSE file present ($SCANNING_DIR/PAUSE) - idling"
        sleep 10
        return 0
    fi

    if ! check_disk_space; then
        alert "Low disk space in $SCANNING_DIR - pausing until space is freed"
        sleep 60
        return 0
    fi

    local chunk_num scanned_file
    chunk_num="$(pick_random_chunk)"
    scanned_file="$SCANNED_CHUNKS_DIR/${chunk_num}.scanned.txt"

    if is_chunk_complete "$chunk_num" "$scanned_file"; then
        return 0
    fi

    if ! acquire_lock "$chunk_num"; then
        sleep 1
        return 0
    fi

    LAST_SEGMENT_HAD_PROGRESS=0
    process_chunk "$chunk_num" || log "WARN" "process_chunk $chunk_num returned non-zero"
    release_lock

    ITERATIONS=$((ITERATIONS + 1))

    if [[ "$LAST_SEGMENT_HAD_PROGRESS" == "1" ]]; then
        ZERO_PROGRESS_STREAK=0
    else
        ZERO_PROGRESS_STREAK=$((ZERO_PROGRESS_STREAK + 1))
        if (( ZERO_PROGRESS_STREAK >= ZERO_PROGRESS_ALERT_THRESHOLD )); then
            alert "No scanning progress for $ZERO_PROGRESS_STREAK consecutive attempts - check GPU/driver health, you may be burning power for nothing"
        fi
    fi

    update_stats "$chunk_num" "$LAST_SEGMENT_HAD_PROGRESS"
    run_backup_snapshot
    rotate_logs

    if (( CONSECUTIVE_FAILURES >= MAX_CONSECUTIVE_FAILURES )); then
        alert "Aborting after $CONSECUTIVE_FAILURES consecutive keyhunt failures - refusing to spin forever burning power for nothing. Fix the environment, run --self-test, then restart."
        return 2
    fi

    if (( CONSECUTIVE_FAILURES > 0 )); then
        backoff_sleep "$CONSECUTIVE_FAILURES"
    else
        sleep "$LOOP_SLEEP_SECONDS"
    fi

    return 0
}

init_loop_state() {
    # awk counts the final line even without a trailing newline; `wc -l`
    # would silently undercount by 1 in that case, permanently hiding the
    # last chunk in the puzzle file from the random picker.
    CHUNK_COUNT=$(awk 'END{print NR}' "$PUZZLE_FILE")
    (( CHUNK_COUNT > 0 )) || die "Puzzle file has no chunks: $PUZZLE_FILE"
    CONSECUTIVE_FAILURES=0
    ZERO_PROGRESS_STREAK=0
    ITERATIONS=0
    SCANNER_START_TIME="$(date -Is)"
}

main_loop() {
    init_loop_state
    local touched
    touched=$(find "$SCANNED_CHUNKS_DIR" -maxdepth 1 -name '*.scanned.txt' -size +0 2>/dev/null | wc -l)
    log "INFO" "=== Scanner started | $CHUNK_COUNT chunks | ~$touched touched | PID $$ ==="

    while true; do
        local rc=0
        run_one_iteration || rc=$?
        if (( rc == 1 )); then
            break
        elif (( rc == 2 )); then
            exit 4
        elif (( rc != 0 )); then
            log "ERROR" "Unexpected error in iteration loop (rc=$rc), continuing after short pause"
            sleep 5
        fi
    done
}

run_single_iteration() {
    init_loop_state
    local rc=0
    run_one_iteration || rc=$?
    return "$rc"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  (none)       Run the scanner loop (default)
  --self-test  Validate environment & math helpers, then exit (no scanning)
  --status     Print current progress/health summary and exit
  --once       Process a single chunk iteration and exit
  --help       Show this help

All paths and tunables are overridable via environment variables; see the
comment block at the top of this script.
EOF
}

main() {
    case "${1:-}" in
        --help|-h)
            usage
            exit 0
            ;;
        --self-test)
            mkdir -p "$SAVED_CHUNKS_DIR" "$SCANNED_CHUNKS_DIR" "$LOCK_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null || true
            cmd_self_test
            exit $?
            ;;
        --status)
            cmd_status
            exit 0
            ;;
        --once)
            validate_environment
            acquire_instance_lock
            reap_orphaned_segment
            run_single_iteration
            exit $?
            ;;
        "")
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac

    validate_environment
    acquire_instance_lock
    reap_orphaned_segment
    main_loop
}

main "$@"
