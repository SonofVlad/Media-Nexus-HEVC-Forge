# Media Nexus: HEVC Forge

An FFmpeg-powered Windows conversion watcher that transcodes H.264 video to H.265/HEVC with Intel Quick Sync Video, validates each result, quarantines suspicious output, and provides a live log monitor.

## Hardware support

| Backend | Hardware | Status |
|---|---|---|
| Intel Quick Sync (`hevc_qsv`) | Supported Intel processors with an enabled iGPU | Supported |
| AMD AMF (`hevc_amf`) | AMD GPUs and supported APUs | Planned |
| NVIDIA NVENC (`hevc_nvenc`) | NVIDIA GPUs with NVENC | Planned rewrite |

The converter in this version is Intel-only. The AMD and NVIDIA entries describe the project roadmap; their encoders are not included yet. The log monitor is hardware-independent and is intended to work with all three converter backends.

## Requirements

- Windows PowerShell 5.1 or later
- An Intel processor with Quick Sync Video support and current graphics drivers
- An FFmpeg build containing `hevc_qsv`

Download a prebuilt FFmpeg package from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds). Extract `ffmpeg.exe` and `ffprobe.exe` into:

```text
scripts\FFmpeg\bin\
```

Confirm that the encoder is available:

```powershell
.\scripts\FFmpeg\bin\ffmpeg.exe -hide_banner -encoders | Select-String hevc_qsv
```

## Run the converter

Launch `scripts\H.265 Convert.bat`. It prompts for input, output, and quarantine folders when they are not supplied.

You can also pass all three folders directly:

```bat
"scripts\H.265 Convert.bat" "D:\Media\Input" "D:\Media\Output" "D:\Media\Quarantine"
```

The launcher contains quality, parallelism, polling, validation, retry, and source-file behavior settings. Review them before processing files.

## Run the monitor

Launch the monitor and supply the converter's `_logs` folder:

```bat
"scripts\H.265 Monitor.bat" "D:\Media\Output\_logs"
```

The monitor follows the most recently updated watcher log. It does not depend on Intel Quick Sync and can also monitor future AMD AMF and NVIDIA NVENC converter logs that use the same logging format.

## Safety

Test the converter on copied media before using it on a library. Depending on configuration and validation results, the application can move source files into `_PROCESSED` or the quarantine directory. Keep backups and verify the output before removing originals.
