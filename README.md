# KeyHunt segment scanner wrappers

This repo has two independent wrappers for two different platforms. Pick the
one that matches your OS/GPU setup - they do not interoperate and don't need
to.

## Windows (PowerShell): `v3.ps1`

**Use only `v3.ps1`.** That is the full production wrapper (resume, scanning, auto-restart, Task Scheduler).

There is no second Windows script to choose from in this repo. Copy `v3.ps1` to:

`C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1`

### Start command

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1" -startIndex 7790 -saveIntervalHours 6 -RegisterAutoStart
```

### Resume behavior (Option B)

Resume uses the **highest completed SUB** in `{segment}-resume.txt`, not the last line. Stray low lines after a restart (e.g. SUB 0 after SUB 776) are ignored.

Resume line format:

```
7790,776,71DB28E0E60D099E5C,71DB28E2E60D429E62,07/13/2026 05:58:33
```

Max SUB 776 → next run starts at SUB 777.

## Linux / CUDA (bash): `keyhunt_random_scanner.sh`

Production-grade randomized chunk scanner for `KeyHunt-Cuda` on Linux, meant
to run unattended for months. It supersedes an earlier hand-rolled scanner
script that had a fatal syntax bug (couldn't even parse/run), a PID-tracking
bug that let the GPU process survive Ctrl-C as an orphan, and a
backup-per-attempt design that piled up redundant files under `savedchunks/`
forever. See the header comment in the script for the full list of fixes.

### Setup

Drop the script anywhere on the GPU box (commonly next to your KeyHunt-Cuda
binary) and make it executable:

```bash
chmod +x keyhunt_random_scanner.sh
```

All paths and tunables are overridable via environment variables (defaults
target `$HOME/Documents/keyhunt_cuda_sandbox`); see the comment block at the
top of the script for the full list, e.g.:

```bash
SCANNING_DIR="$HOME/Documents/keyhunt_cuda_sandbox" \
SCAN_DURATION=3600 \
GPU_INDEX=0 \
./keyhunt_random_scanner.sh
```

### Before letting it run unattended

Always run `--self-test` after any edit or on a new machine, before trusting
it with months of unattended GPU time:

```bash
./keyhunt_random_scanner.sh --self-test
```

This validates required tools, big-integer hex/int round-trips, segment
boundary math (no gaps/overlaps), file paths, disk space, and GPU visibility
without launching any real scan.

### Usage

```bash
./keyhunt_random_scanner.sh              # run the scanner loop (daemon)
./keyhunt_random_scanner.sh --self-test  # validate env & math, no scanning
./keyhunt_random_scanner.sh --status     # print progress/health summary
./keyhunt_random_scanner.sh --once       # process a single chunk and exit
./keyhunt_random_scanner.sh --help
```

### Running it for months: recommended deployment

Run it under systemd rather than a bare `nohup ... &`, so a genuine crash
(driver hiccup, OOM, host reboot) gets a clean, rate-limited restart instead
of silently leaving the GPU idle - or worse, leaving an orphaned scan running
with nobody tracking it. A template unit is included at
`keyhunt-scanner.service`:

```bash
sudo cp keyhunt-scanner.service /etc/systemd/system/keyhunt-scanner@yourusername.service
sudo systemctl daemon-reload
sudo systemctl enable --now keyhunt-scanner@yourusername.service
sudo journalctl -u keyhunt-scanner@yourusername -f
```

### What makes this "not just wasting electricity"

- **Circuit breaker**: if keyhunt keeps exiting abnormally (bad args, driver
  fault, missing GPU), the scanner backs off exponentially and aborts after
  `MAX_CONSECUTIVE_FAILURES` instead of tight-looping forever.
- **Zero-progress watchdog**: if a segment runs its full duration but reports
  no progress repeatedly, it raises a loud alert (`ALERTS.log`) so a stuck
  GPU/driver doesn't go unnoticed for weeks.
- **Orphan reaper**: if the scanner itself is killed uncleanly (`kill -9`,
  OOM-killer, crash) mid-segment, the *next* startup detects and kills the
  orphaned keyhunt process before starting new work, so a crash can never
  leave the GPU mining unattended indefinitely.
- **Single consolidated backup**: `savedchunks/` gets one periodic
  `tar.gz` snapshot of the whole progress directory (pruned to a retention
  count), not a new duplicate file per chunk attempt.
- **Correct resume math**: every completion check goes through one
  integer-based helper, so a chunk is never silently treated as "done" (or
  perpetually "not done") due to string-formatting mismatches.
