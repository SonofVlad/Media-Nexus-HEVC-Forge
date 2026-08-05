# Media Nexus: HEVC Forge Monitor

A lightweight Windows command-line monitor that follows the newest log produced by an HEVC Forge converter.

The monitor is hardware-independent. It can display logs from Intel Quick Sync, AMD AMF, and NVIDIA NVENC converters as long as they use the same `Watcher_*.log` naming and logging format.

## Run

Keep `H.265 Monitor.bat` and `H.265Monitor.ps1` in the same folder, then double-click the batch file. Enter the converter's `_logs` directory when prompted.

You can instead set `LOGDIR` in the clearly marked user-settings section of the batch file.

The default behavior is to:

- Follow the newest `Watcher_*.log` file.
- Display its most recent 200 lines.
- Retry every three seconds if the log is temporarily unavailable.
- Hide repetitive `START:` entries.

The filename filter, line count, and retry interval can also be changed in the batch file's user-settings section.

## Requirements

- Windows
- Windows PowerShell 5.1 or later
- Converter logs using the HEVC Forge watcher format
