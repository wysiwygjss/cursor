# KeyHunt segment scanner wrapper

## Which file to use

**Use only `v3.ps1`.** That is the full production wrapper (resume, scanning, auto-restart, Task Scheduler).

There is no second script to choose from in this repo. Copy `v3.ps1` to:

`C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1`

## Start command

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1" -startIndex 7790 -saveIntervalHours 6 -RegisterAutoStart
```

`-saveIntervalHours 6` sets both resume checkpoint interval and ~6-hour SUB size (unless you pass `-subCount 53687` for legacy tiny subs).

Double-click `Run-V3.cmd` for the same settings without Task Scheduler registration.

## Resume behavior (Option B)

Resume uses the **highest completed SUB** in `{segment}-resume.txt`, not the last line. Stray low lines after a restart (e.g. SUB 0 after SUB 776) are ignored.

Resume line format:

```
7790,776,71DB28E0E60D099E5C,71DB28E2E60D429E62,07/13/2026 05:58:33
```

Max SUB 776 → next run starts at SUB 777.
