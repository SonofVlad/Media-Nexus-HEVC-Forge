# Media Nexus: HEVC Forge

A Windows PowerShell watcher that converts H.264 video to H.265/HEVC with FFmpeg and displays conversion logs in a separate monitor.

## Support

| Hardware | FFmpeg encoder | Status |
|---|---|---|
| Intel Quick Sync | `hevc_qsv` | Available |
| NVIDIA NVENC | `hevc_nvenc` | In testing |
| AMD AMF | `hevc_amf` | Planned |

The currently published converter supports Intel Quick Sync. The monitor works with all three versions.

## Requirements

- Windows PowerShell 5.1 or later
- Current graphics drivers
- FFmpeg with the required hardware encoder

Download FFmpeg from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), then place `ffmpeg.exe` and `ffprobe.exe` in:

```text
FFmpeg\bin\
```

## Converter setup

Keep these files together:

- `H.265ConverterINTEL.bat`
- `H.265ConverterINTEL.ps1`
- `FFmpeg\bin\ffmpeg.exe`
- `FFmpeg\bin\ffprobe.exe`

Run `H.265ConverterINTEL.bat`. Enter the input, output, and quarantine folders when prompted, or set them in the batch file's **EDIT THESE VALUES ONLY** section.

> Test with copied media first. Completed or failed source files may be moved to `_PROCESSED` or the quarantine folder.

## Suggested concurrent conversions

These are conservative starting points for 1080p video. Use roughly half as many jobs for 4K.

| Hardware generation | Suggested `PARALLEL` |
|---|---:|
| Intel Core 6th–7th generation | 1 |
| Intel Core 8th–10th generation | 1–2 |
| Intel Core 11th–14th generation | 2–4 |
| Intel Core Ultra or Arc | 3–6 |
| NVIDIA Maxwell 2 | 1–2 |
| NVIDIA Pascal | 2–3 |
| NVIDIA Turing | 2–4 |
| NVIDIA Ampere | 3–5 |
| NVIDIA Ada | 4–6 |
| NVIDIA Blackwell | 4–8 |

Increase `PARALLEL` one step at a time. Reduce it if temperatures rise, conversions become unstable, or total throughput stops improving.

## Expected results

| Converter | Quality setting | File-size reduction | Quality reduction |
|---|---:|---:|---:|
| Intel QSV | 20 | ~66% | ~5% |
| NVIDIA NVENC | 25 | ~68% | ~5% |
| AMD AMF | 26 | ~62% | ~5% |

These are rough practical estimates, not guaranteed measurements. Results depend on the source video, hardware generation, and encoder settings.

## Monitor

Keep `H.265 Monitor.bat` and `H.265Monitor.ps1` together, then run the batch file and select the converter's `_logs` folder.

The monitor follows the newest `Watcher_*.log`, displays its latest 200 lines, and refreshes every three seconds.
