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

## Suggested concurrent conversions

The batch files use `PARALLEL` to control how many videos are converted at once. The values below are conservative starting points for typical 1080p H.264-to-HEVC conversions. They are recommendations, not guaranteed hardware limits.

### Intel Quick Sync

| Intel generation | Suggested `PARALLEL` | Notes |
|---|---:|---|
| 6th–7th generation Core | 1 | Earliest Intel generations with hardware HEVC support; start with one job. |
| 8th–10th generation Core | 1–2 | Try two only after confirming stable temperatures and playback-quality output. |
| 11th–14th generation Core | 2–4 | Start at two, then increase one job at a time while watching GPU Video Encode usage. |
| Core Ultra or Intel Arc graphics | 3–6 | Newer media engines generally handle more parallel work, but model and cooling still matter. |

Intel Core processors without enabled processor graphics cannot use Quick Sync. Confirm support for the exact processor and keep the integrated GPU enabled. Intel documents HEVC support and generation-specific media capabilities in its [Intel hardware media capabilities guide](https://www.intel.com/content/www/us/en/docs/onevpl/developer-reference-media-intel-hardware/1-0/overview.html).

### NVIDIA NVENC

| NVIDIA GPU generation | Examples | Suggested `PARALLEL` |
|---|---|---:|
| Maxwell 2nd generation | GTX 900 series | 1–2 |
| Pascal | GTX 10 series | 2–3 |
| Turing | GTX 16 and RTX 20 series | 2–4 |
| Ampere | RTX 30 series | 3–5 |
| Ada Lovelace | RTX 40 series | 4–6 |
| Blackwell | RTX 50 series | 4–8 |

NVENC capacity varies within a generation because some GPUs contain more than one encoder engine. NVIDIA also applies concurrent-session limits to some consumer GPUs. Its current documentation says non-qualified GPUs are limited to eight concurrent encode sessions per system, while qualified GPUs are limited by available hardware resources. See NVIDIA's [NVENC application note](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-application-note/index.html) and verify the exact GPU before raising `PARALLEL`.

For 4K sources, start with roughly half the suggested 1080p value. Deinterlacing, 10-bit video, slow storage, multiple audio streams, or demanding quality settings may require reducing it further. Increase by one job at a time; if total throughput stops improving, temperatures rise excessively, or jobs become unstable, return to the previous value.

## Expected file-size and quality changes

H.265/HEVC is generally more efficient than H.264, but every conversion is different. These are practical estimates for ordinary H.264 sources; they are not guaranteed results.

| Conversion goal | Expected file-size reduction | Estimated perceived quality reduction |
|---|---:|---:|
| High quality | 15–35% | 0–5% |
| Balanced | 30–50% | 3–10% |
| Maximum space savings | 50–70% | 10–25% |

With the Intel launcher's default `QSVQUALITY=20`, a reasonable first expectation is approximately **25–50% smaller files** with roughly **0–8% perceived quality reduction**. NVIDIA NVENC should generally fall within similar ranges when configured for comparable quality, although results vary by GPU generation and encoder preset.

The quality percentage is a plain-language visual estimate, not a direct measurement. Re-encoding is always lossy, even when the difference is difficult to see. Animation, film grain, dark scenes, fast motion, low-bitrate sources, and already heavily compressed files may behave very differently. An efficient source may shrink by less than 15%, fail to shrink at all, or become larger.

Test several representative videos before converting a library. Compare motion, dark scenes, fine texture, subtitles, and audio in the result. If quality loss is noticeable, use a higher-quality setting; if the files are not becoming small enough, choose a more aggressive setting. Intel notes that HEVC generally provides additional compression over H.264 without requiring a corresponding visible quality loss, but exact results depend on the source and encoder configuration.

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