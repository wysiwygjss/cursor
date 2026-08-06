# KeyHunt segment scanner wrapper

## Which file to use

**Use only `v3.ps1`.** That is the full production wrapper (resume, scanning, auto-restart, Task Scheduler).

There is no second script to choose from in this repo. Copy `v3.ps1`, `v3-gui.ps1`, `Run-V3-GUI.cmd`, and the `lib\` folder to:

`C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\`

(`lib\BtcAddress.ps1` is required for the live private-key / address table.)

## Start command

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3.ps1" -startIndex 7790 -saveIntervalHours 6 -RegisterAutoStart
```

## Resume behavior (Option B)

Resume uses the **highest completed SUB** in `{segment}-resume.txt`, not the last line. Stray low lines after a restart (e.g. SUB 0 after SUB 776) are ignored.

Resume line format:

```
7790,776,71DB28E0E60D099E5C,71DB28E2E60D429E62,07/13/2026 05:58:33
```

Max SUB 776 → next run starts at SUB 777.

## GUI dashboard (`v3-gui.ps1`)

A WPF monitor modeled after browser key-hunt dashboards. It **does not** scan keys itself.

```text
Double-click Run-V3-GUI.cmd
```

Or:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "C:\Users\Admin\Documents\KeyhuntSuite\Wrappers\v3-gui.ps1"
```

Copy `v3-gui.ps1` and `Run-V3-GUI.cmd` next to `v3.ps1` under `Wrappers\`.

### Speed impact

| Layer | Role | Typical impact on keys/sec |
|-------|------|----------------------------|
| `KeyHunt-Cuda.exe` | GPU scan | 100% of throughput |
| `v3.ps1` | Launches CUDA, writes resume | &lt; 0.1% (blocked on GPU) |
| `v3-gui.ps1` | Polls resume/log every 2s | **~0%** |

The sample screenshot uses **browser WASM workers** (~10⁵–10⁶ keys/s). Your wrapper uses **CUDA** (~10⁹+ keys/s). A monitor GUI adds no meaningful GPU load as long as it only reads files and does not run KeyHunt in-process.

Real-time speed in the GUI is estimated from resume timestamps (updates every `saveIntervalHours` chunk by default). For smoother speed/ETA, add a small `status.json` write inside `v3.ps1` after each chunk (optional enhancement).
