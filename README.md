# Desktop Organizer (Windows / PowerShell)

Automatically sorts the loose files cluttering your Windows Desktop into clearly
named category folders — **Documents, Images, Screenshots, Videos, Installers,
Archives, Spreadsheets, PDFs**, and **Misc** for anything else.

- **OneDrive-aware** — finds your real Desktop even if it's redirected into OneDrive.
- **Folders are never touched** — only loose files get moved.
- **Dry-run preview + confirmation** before anything moves (interactive runs).
- **Never overwrites** — duplicate names get a ` (1)`, ` (2)` suffix.
- **Full undo** — every move is logged; one command puts everything back.
- **Weekly auto-run** via Task Scheduler, which skips the prompt but still logs.

No installation, no modules, no admin rights. Plain PowerShell.

---

## Files in this repo

| Script | What it does |
|---|---|
| `Organize-Desktop.ps1` | Scans the Desktop, previews, confirms, and moves files. |
| `Undo-LastOrganize.ps1` | Reverses a run using its log (newest by default). |
| `Register-WeeklyTask.ps1` | Sets up the weekly scheduled task. |
| `Unregister-WeeklyTask.ps1` | Removes the scheduled task. |

Logs are written to `%LOCALAPPDATA%\DesktopOrganizer\logs` (i.e.
`C:\Users\<you>\AppData\Local\DesktopOrganizer\logs`). They live **off** the
Desktop on purpose, so the organizer never sorts its own logs.

---

## Quick start

1. Download/clone this repo somewhere permanent (e.g. `C:\Tools\desktop-organizer`).
   **Don't** keep it on the Desktop — pick a stable folder so the scheduled task
   always finds it.

2. Open **PowerShell** (Windows PowerShell or PowerShell 7, normal user — no admin needed)
   and `cd` into the folder:

   ```powershell
   cd C:\Tools\desktop-organizer
   ```

3. **See what it would do, without moving anything:**

   ```powershell
   .\Organize-Desktop.ps1 -WhatIfOnly
   ```

4. **Do it for real** (you'll get a preview and a `y/N` prompt):

   ```powershell
   .\Organize-Desktop.ps1
   ```

5. **Changed your mind? Undo the last run:**

   ```powershell
   .\Undo-LastOrganize.ps1
   ```

---

## About the PowerShell execution policy

Windows blocks unsigned scripts by default. You do **not** need to weaken your
machine's security globally. Two good options:

- **Per-command (no permanent change):** the scheduled task already uses
  `-ExecutionPolicy Bypass`, and you can do the same for manual runs:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Organize-Desktop.ps1
  ```

- **For your user only (convenient, still safe):**

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

  `RemoteSigned` lets local scripts you wrote run, while still blocking unsigned
  scripts downloaded from the internet. This affects only your account, not the
  whole machine, and needs no admin rights.

If Windows marked the downloaded `.ps1` files as "blocked", unblock them once:

```powershell
Get-ChildItem .\*.ps1 | Unblock-File
```

---

## Set up the weekly auto-run (Task Scheduler)

This registers a task that runs the organizer **unattended** — no prompt, but it
still writes a log so you can always undo.

```powershell
# Default: every Sunday at 09:00
.\Register-WeeklyTask.ps1

# Or pick your own day/time:
.\Register-WeeklyTask.ps1 -DayOfWeek Monday -Time 18:30
```

**Permissions / setup notes:**

- **No administrator rights required.** The task runs as *you*, only when you're
  logged on, and only moves files you already own. We deliberately register it at
  the normal ("Limited") privilege level — it never needs elevation.
- If `Register-ScheduledTask` ever complains about policy on a locked-down work
  PC, that's a Group Policy restriction from your IT department, not a bug — in
  that case run the script manually or ask IT to allow per-user scheduled tasks.
- The task is set to **start late if a run was missed** (e.g. the PC was off at
  the scheduled time) and to **not run on battery** to be polite to laptops.

**Verify / manage the task:**

```powershell
# Run it right now to test the unattended path:
Start-ScheduledTask -TaskName 'DesktopOrganizer-Weekly'

# Check last run time and result:
Get-ScheduledTaskInfo -TaskName 'DesktopOrganizer-Weekly'

# Remove it entirely (scripts and logs are left intact):
.\Unregister-WeeklyTask.ps1
```

You can also see it in the **Task Scheduler** GUI: press `Win+R`, type
`taskschd.msc`, and look in **Task Scheduler Library** for
`DesktopOrganizer-Weekly`.

---

## How files are categorized

| Category | Examples |
|---|---|
| **Screenshots** | image files whose name starts with `Screenshot`, `Screen Shot`, `Snip`, etc. |
| **Images** | `.jpg .jpeg .png .gif .bmp .tiff .webp .heic .svg .ico` |
| **Videos** | `.mp4 .mov .avi .mkv .wmv .flv .webm .m4v .mpg` |
| **PDFs** | `.pdf` |
| **Spreadsheets** | `.xls .xlsx .xlsm .csv .ods .tsv` |
| **Documents** | `.doc .docx .txt .rtf .odt .md .ppt .pptx .epub .tex` |
| **Installers** | `.exe .msi .msix .appx` |
| **Archives** | `.zip .rar .7z .tar .gz .bz2 .xz .iso` |
| **Misc** | anything not matched above |

Screenshots are checked **before** Images, so a `Screenshot ....png` lands in
`Screenshots`, not `Images`.

**Left alone by design:**
- Existing folders on the Desktop (only loose files move).
- Shortcuts (`.lnk`, `.url`) — people usually want these on the Desktop. Add
  `-IncludeShortcuts` if you want them filed too.
- Hidden/system files like `desktop.ini`, and the organizer's own scripts.

Want to tweak the mapping? Edit the `$ExtensionMap` and `$ScreenshotPatterns`
tables near the top of `Organize-Desktop.ps1` — they're plain hashtables.

---

## How undo works

Each run writes a JSON log like
`organize_2026-06-07_09-00-00.json` containing the exact
`from → to` path of every move. `Undo-LastOrganize.ps1`:

1. Picks the newest log (or one you pass with `-LogFile`).
2. Shows you what it will restore and prompts (use `-Force` to skip).
3. Moves each file back **only if** the original spot is free — it never
   overwrites. Anything it can't safely restore is reported and skipped.
4. Renames the log to `*.undone.json` so it won't be picked up again.

To undo a *specific* earlier run:

```powershell
.\Undo-LastOrganize.ps1 -LogFile "$env:LOCALAPPDATA\DesktopOrganizer\logs\organize_2026-06-07_09-00-00.json"
```

---

## Command reference

**`Organize-Desktop.ps1`**

| Parameter | Purpose |
|---|---|
| `-WhatIfOnly` | Show the preview and exit. Moves nothing, no prompt. |
| `-Unattended` | Skip the prompt and organize. Still writes a log. (Used by the task.) |
| `-IncludeShortcuts` | Also file `.lnk` / `.url` shortcuts. |
| `-DesktopPath <path>` | Override the auto-detected Desktop (rarely needed). |
| `-LogDirectory <path>` | Where to write logs. Defaults to `%LOCALAPPDATA%\DesktopOrganizer\logs`. |

**`Register-WeeklyTask.ps1`**

| Parameter | Purpose |
|---|---|
| `-DayOfWeek <day>` | Day to run (default `Sunday`). |
| `-Time <HH:mm>` | Time to run (default `09:00`). |
| `-TaskName <name>` | Task name (default `DesktopOrganizer-Weekly`). |

---

## Troubleshooting

- **"Some files couldn't be moved."** They were probably open or locked by
  another program. Close them and run again — the rest already moved, and the log
  reflects only what actually moved.
- **"Running scripts is disabled on this system."** See *execution policy* above.
- **Wrong Desktop detected** (multiple profiles, custom redirection): pass
  `-DesktopPath` explicitly, e.g. `.\Organize-Desktop.ps1 -DesktopPath "$env:OneDrive\Desktop"`.
