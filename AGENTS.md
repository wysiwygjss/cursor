# AGENTS.md

## Cursor Cloud specific instructions

### What this repo is
This repo is a **Windows PowerShell** automation wrapper (`v3.ps1`) around the external
`KeyHunt-Cuda.exe` Bitcoin key-scanning binary. It is a script-only repo: there is no
package manifest, no test suite, and no long-running service. `v3.ps1` is the only
production script (see `README.md`); `fix-v3.ps1` is a deprecated one-time patch helper
for legacy Windows PowerShell 5.1.

### Toolchain (already provided by the environment)
- PowerShell 7 (`pwsh`) is the runtime used for linting/parsing on Linux.
- `PSScriptAnalyzer` (PowerShell module) is the linter. The startup update script installs
  it if missing.

### Lint / "build" / run commands
- Lint: `pwsh -NoProfile -Command "Import-Module PSScriptAnalyzer; Invoke-ScriptAnalyzer -Path . -Recurse | Format-Table -AutoSize"`
- Syntax check ("build"): parse with `[System.Management.Automation.Language.Parser]::ParseFile(...)`.
  `v3.ps1` parses clean. `fix-v3.ps1` intentionally has a pre-existing here-string parse
  error (line ~25) and is not part of the working flow — do not treat it as a regression.

### Non-obvious caveats
- **You cannot fully run `v3.ps1` on Linux.** It hard-codes Windows paths
  (`C:\Users\Admin\Documents\KeyhuntSuite\...`), uses Windows Task Scheduler
  (`schtasks` / `*-ScheduledTask*`), a `Global\` mutex, and shells out to the Windows
  CUDA binary `KeyHunt-Cuda.exe` (not in the repo, needs an NVIDIA GPU). Running the file
  directly on Linux enters an infinite retry loop ("Segment file missing") and creates junk
  directories from the backslash paths — do not do this.
- To exercise the real logic on Linux, load only the **function definitions** via the AST
  (skipping the top-level Windows side effects) and call the pure helpers, e.g.
  `Parse-SegmentRange`, `HexToBig`/`BigToHex`, `Get-SubRange`, `Get-RangeChunks`,
  `Get-MaxResumeEntry`, `Get-ResumeState`. The `PSScriptAnalyzer` warnings on `v3.ps1`
  (`PSAvoidUsingWriteHost`, `PSUseApprovedVerbs`, etc.) are expected style findings, not bugs.
- Core resume rule (from `README.md`): resume uses the **highest completed SUB** in
  `{segment}-resume.txt`, not the last line, so a stray low line after a restart
  (e.g. SUB 0 written after SUB 776) is ignored and the next run starts at SUB 777.
