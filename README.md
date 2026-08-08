# Media Nexus: HEVC Forge

A Windows PowerShell watcher that converts H.264 video to H.265/HEVC with FFmpeg and displays conversion logs in a separate monitor.

## Support

| Hardware | FFmpeg encoder | Status |
|---|---|---|
| Intel Quick Sync | `hevc_qsv` | Available |
| NVIDIA NVENC | `hevc_nvenc` | Available |
| AMD AMF | `hevc_amf` | Planned |

Intel Quick Sync and NVIDIA NVENC converters are available. The monitor works with Intel, NVIDIA, and future AMD versions.

## Requirements

- Windows PowerShell 5.1 or later
- Current graphics drivers
- FFmpeg with the required hardware encoder

Download FFmpeg from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), then place `ffmpeg.exe` and `ffprobe.exe` in:

```text
FFmpeg\bin\
```

## Converter setup

Keep the matching launcher and script together with `FFmpeg\bin\ffmpeg.exe` and `FFmpeg\bin\ffprobe.exe`.

| Hardware | Launcher | PowerShell script |
|---|---|---|
| Intel | `H.265ConverterINTEL.bat` | `H.265ConverterINTEL.ps1` |
| NVIDIA | `H.265ConverterNVIDIA.bat` | `H.265ConverterNVIDIA.ps1` |

Run the launcher for your hardware. Enter the input, output, and quarantine folders when prompted, or set them in the batch file's **EDIT THESE VALUES ONLY** section.

> Test with copied media first. Completed or failed source files may be moved to `_PROCESSED` or the quarantine folder.

## Suggested concurrent conversions

These are conservative starting points for 1080p video. Release years are approximate; use roughly half as many jobs for 4K.

| Platform | Hardware generation | Approx. release years | Suggested `PARALLEL` |
|---|---|---:|---:|
| Intel | Core 6th–7th generation | 2015–2017 | 1 |
| Intel | Core 8th–10th generation | 2017–2020 | 1–2 |
| Intel | Core 11th–14th generation | 2020–2024 | 2–4 |
| Intel | Core Ultra or Arc | 2022–present | 3–6 |
| AMD | Ryzen 2000G–3000G with Radeon graphics | 2018–2020 | 1 |
| AMD | Ryzen 4000G–5000G with Radeon graphics | 2020–2022 | 1–2 |
| AMD | Ryzen 6000–8000 with Radeon graphics | 2022–2024 | 2–4 |
| AMD | Ryzen AI 300 with Radeon graphics | 2024–2025 | 2–4 |
| NVIDIA | Maxwell 2 | 2014–2016 | 1–2 |
| NVIDIA | Pascal | 2016–2018 | 2–3 |
| NVIDIA | Turing | 2018–2020 | 2–4 |
| NVIDIA | Ampere | 2020–2022 | 3–5 |
| NVIDIA | Ada | 2022–2024 | 4–6 |
| NVIDIA | Blackwell | 2025–present | 4–8 |

AMD AMF uses Radeon graphics. A Ryzen CPU without supported integrated graphics requires a compatible Radeon graphics card.

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
