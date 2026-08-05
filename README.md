# Media Nexus: HEVC Forge

An FFmpeg-powered Windows conversion watcher for H.265/HEVC encoding, with a shared command-line log monitor.

## Converter support

| Converter | Encoder | Status |
|---|---|---|
| Intel Quick Sync | `hevc_qsv` | Available |
| NVIDIA NVENC | `hevc_nvenc` | In testing |
| AMD AMF | `hevc_amf` | Planned |

The currently published converter is for Intel Quick Sync only.

## Intel requirements

- Windows PowerShell 5.1 or later
- A supported Intel processor with its integrated GPU enabled
- Current Intel graphics drivers
- An FFmpeg build that includes `hevc_qsv`

Download a prebuilt FFmpeg package from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds). Extract `ffmpeg.exe` and `ffprobe.exe` into:

```text
FFmpeg\bin\
```

## Run the Intel converter

Keep `H.265ConverterINTEL.bat` and `H.265ConverterINTEL.ps1` together, alongside `FFmpeg\bin`. Double-click the batch file and enter the input, output, and quarantine folders when prompted.

You can instead set those folder paths in the batch file's clearly marked user-settings section. Review the quality, parallel encoding, polling, validation, retry, and source-file settings before starting.

The converter watches for supported video files, encodes them with Intel Quick Sync, validates duration and decodability, copies successful output into the destination, and moves suspicious source files into quarantine.

> Test with copied media first. Depending on the selected settings and validation result, source files can be moved into `_PROCESSED` or quarantine.

## Shared monitor

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
