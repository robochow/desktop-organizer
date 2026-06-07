# Desktop Organizer (Windows / PowerShell)

Automatically sorts the loose files cluttering your Windows Desktop into clearly
named category folders — **Documents, Images, Screenshots, Videos, Installers,
Archives, Spreadsheets, PDFs**, and **Misc** for anything else.

- **Three cleanup modes in the GUI** — **Organize Files** into categories,
  **Consolidate Folders** (merge redundant folders like *Assorted Pictures* + *More
  Random Pics*), and **Clean Names** (Title-Case messy filenames). All preview-first
  and undoable.
- **Two ways to use it** — a clean windowed **GUI** for clicking around, or the
  console scripts for automation. Both run on the *same engine*.
- **OneDrive-aware** — finds your real Desktop even if it's redirected into OneDrive.
- **Folders are never touched** — only loose files get moved.
- **Dry-run preview + confirmation** before anything moves (interactive runs).
- **Never overwrites** — duplicate names get a ` (1)`, ` (2)` suffix.
- **Full undo** — every move is logged; one command (or one button) puts everything back.
- **Weekly auto-run** via Task Scheduler, which skips the prompt but still logs.

No installation, no modules, no admin rights. Plain PowerShell (the GUI uses WPF,
which ships with every modern Windows).

---

## Files in this repo

| Script | What it does |
|---|---|
| `Organize-Desktop-GUI.ps1` | **The windowed app.** Scan, tick/untick files, organize, undo. |
| `Create-Shortcut.ps1` | Puts a double-click shortcut (with icon) on your Desktop / Start Menu. |
| `Organize-Desktop.ps1` | Console version: scans the Desktop, previews, confirms, and moves files. |
| `Undo-LastOrganize.ps1` | Reverses a run using its log (newest by default). |
| `Register-WeeklyTask.ps1` | Sets up the weekly scheduled task. |
| `Unregister-WeeklyTask.ps1` | Removes the scheduled task. |
| `DesktopOrganizer.Engine.ps1` | **Shared engine.** All the scanning/moving/undo/logging logic lives here; every script above (GUI and console) is just a front end over it. Keep it next to the others. |

Logs are written to `%LOCALAPPDATA%\DesktopOrganizer\logs` (i.e.
`C:\Users\<you>\AppData\Local\DesktopOrganizer\logs`). They live **off** the
Desktop on purpose, so the organizer never sorts its own logs. The GUI, the
console script and the scheduled task all read and write the **same** logs, so you
can organize in one and undo in another.

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

Prefer clicking to typing? Jump to **[Use the GUI](#use-the-gui-windowed-app)**.

---

## Use the GUI (windowed app)

The GUI is the friendliest way to drive the organizer. It does everything the
console script does, with a live preview you can edit before anything moves.

### Launch it

The nicest way is to make a desktop shortcut once, then double-click it:

```powershell
.\Create-Shortcut.ps1            # adds a "Desktop Organizer" shortcut to your Desktop
# or
.\Create-Shortcut.ps1 -Location Both   # Desktop + Start Menu
```

Double-click the shortcut and the window opens — **no PowerShell window appears
behind it.** (The shortcut launches Windows PowerShell hidden, and the GUI also
hides its own console on startup.)

You can also start it directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\Organize-Desktop-GUI.ps1
```

> WPF needs a single-threaded apartment (STA). Windows PowerShell 5.1 — the
> `powershell.exe` that's preinstalled on every Windows machine — is STA by
> default, so the shortcut uses it. If you launch the GUI from PowerShell 7
> (`pwsh`), it automatically relaunches itself STA, so it still works.

### Three tabs, one safety model

The window has three tabs. Every one is **preview-first** (scan, review, tick the
rows you want), **never overwrites**, and **writes to the same undo log** — so the
shared **Undo Last Run** button (and the bottom **status bar**, e.g. `32 files
moved, 0 errors`) work no matter which tab you used last.

**1. Organize Files** *(the original feature)*
- **Scan** previews every loose file that would move, in a grid with **File Name**,
  **Current Location**, **Destination Category**. (Scans automatically on open.)
- Each row has a **Move?** checkbox (all start ticked). **Check all / Uncheck all**
  flip them in bulk.
- **Organize Now** moves only the ticked files (after a confirm).
- **Settings**: tick/untick whole **categories** (unticked ones are left alone), and
  **Group screenshots into month subfolders** (`Screenshots\yyyy-MM`, month taken
  from the filename's date, falling back to the file's date). Re-**Scan** to apply.

**2. Consolidate Folders** *(folder cleanup — opt-in)*
- Off by default: tick **Include folders in the scan**, then **Scan Folders**.
- Finds *obviously redundant* folders that share a theme — e.g. `Assorted Pictures`
  + `More Random Pics` + `Pictures` → **Pictures**, or `Assorted Documents` + `word
  docs` → **Documents** — and lists each source folder with its **file count** and
  the **target** it would merge into.
- A **Merge?** checkbox per row lets you approve each consolidation individually —
  **nothing merges automatically**.
- **Consolidate Checked** moves the files (de-duping names, never overwriting) and
  removes each source folder once it's emptied.
- **Never touches** system/app folders: hidden/system folders, anything starting
  with `.`, `__` (e.g. `__MACOSX`) or `$`, known names like `config` / `node_modules`
  / `Program Files`, the organizer's own category folders, and **any folder
  containing an executable** (`.exe`, `.dll`, …).

**3. Clean Names** *(filename cleanup)*
- **Scan Names** proposes tidier names, shown **Old Name → New Name** side by side.
- Fixes: `New folder`, ALL CAPS, double spaces, underscores-as-spaces, leading
  `Copy of`, trailing `- Copy` / `(1) (2)` copy markers, and long random number
  runs — all rendered in **Title Case**. **File extensions are left untouched.**
- A **Rename?** checkbox per row; **Rename Checked** applies only the ticked ones
  (after a confirm). Renames go into the **same undo log**, so **Undo Last Run**
  reverses them.

The window uses a dark theme with sensible padding and the Segoe UI font — not a
1998 gray dialog.

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

Want to tweak the mapping? Edit the `ExtensionMap` and `ScreenshotPatterns` tables
in `Get-DesktopOrganizerConfig` near the top of `DesktopOrganizer.Engine.ps1` —
they're plain hashtables, and the change applies to the GUI, the console script
and the scheduled task at once.

---

## How undo works

Every operation — organizing, **folder consolidation**, and **renaming** — writes
the same kind of JSON log (`organize_2026-06-07_09-00-00.json`) recording the exact
`from → to` path of each change. Because a rename and a folder merge are just file
moves under the hood, one undo mechanism reverses all three. **Undo Last Run** (in
the GUI) and `Undo-LastOrganize.ps1`:

1. Pick the newest log (or one you pass with `-LogFile`).
2. Show what they'll restore and prompt (use `-Force` to skip).
3. Move each file back **only if** the original spot is free — never overwriting.
   Anything that can't be safely restored is reported and skipped. (Consolidated
   source folders are recreated automatically as their files return.)
4. Rename the log to `*.undone.json` so it won't be picked up again.

To undo a *specific* earlier run:

```powershell
.\Undo-LastOrganize.ps1 -LogFile "$env:LOCALAPPDATA\DesktopOrganizer\logs\organize_2026-06-07_09-00-00.json"
```

---

## Command reference

**`Organize-Desktop-GUI.ps1`**

| Parameter | Purpose |
|---|---|
| `-DesktopPath <path>` | Override the auto-detected Desktop (rarely needed). |
| `-LogDirectory <path>` | Where to read/write logs. Defaults to `%LOCALAPPDATA%\DesktopOrganizer\logs`. |

**`Create-Shortcut.ps1`**

| Parameter | Purpose |
|---|---|
| `-Location <where>` | `Desktop` (default), `StartMenu`, or `Both`. |
| `-Name <name>` | Shortcut name (default `Desktop Organizer`). |
| `-IconPath <path>` | Custom icon (`.ico`, or `file.dll,index`). Defaults to a system folder icon. |

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
- **The GUI doesn't open / closes immediately.** Make sure
  `DesktopOrganizer.Engine.ps1` sits in the *same folder* as the GUI script (every
  script depends on it). Try launching it directly to see any error:
  `powershell -ExecutionPolicy Bypass -File .\Organize-Desktop-GUI.ps1`.
- **Shortcut opens a blank console instead of the window.** Re-run
  `.\Create-Shortcut.ps1` after moving the scripts — the shortcut stores the
  folder path, so it must be regenerated if you relocate the files.
