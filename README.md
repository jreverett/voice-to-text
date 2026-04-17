# Voice-to-Text

Local push-to-talk speech-to-text using whisper.cpp. Hold a hotkey, speak, release — transcribed text lands in your clipboard.

## Prerequisites

- Windows 10+
- [AutoHotkey v2](https://www.autohotkey.com/)
- [.NET 10+ SDK](https://dotnet.microsoft.com/download) (to build mic-capture)

## Quick Start

```powershell
cd voice-to-text

# 1. Run setup (downloads whisper.cpp, model, generates icons)
.\setup.ps1

# 2. Build the mic-capture tool
dotnet publish tools\mic-capture -c Release -o bin

# 3. Verify config.ini has the correct microphone name
# Use "List Audio Devices" from the tray menu if unsure

# 4. Launch
# Double-click voice-to-text.ahk, or:
autohotkey voice-to-text.ahk
```

The script auto-elevates to admin (required for hotkey hooks in elevated windows like Terminal).

## Usage

1. **Hold Shift+Alt** — tray icon turns orange (initializing), then red (recording)
2. **Speak** your text
3. **Release** — icon turns yellow (transcribing), text is copied to clipboard, icon returns to green
4. **Paste** anywhere with Ctrl+V

Releasing during the orange startup phase cancels cleanly.

## Configuration

Edit `config.ini` to customize:

| Section | Setting | Default | Notes |
|---------|---------|---------|-------|
| `[Audio]` | `MicDevice` | Auto-detected | WASAPI device name from "List Audio Devices" |
| `[Hotkey]` | `PushToTalk` | `ShiftAlt` | Also supports single keys: `CapsLock`, `F13`, `ScrollLock` |
| `[Whisper]` | `Threads` | `16` | Number of CPU threads for whisper inference |
| `[Whisper]` | `ServerPort` | `8178` | Local port for whisper-server |
| `[Paths]` | `ModelPath` | `models\ggml-small.en.bin` | Swap for `medium.en` for better accuracy |
| `[Startup]` | `RunAtLogin` | `true` | Creates/removes a startup shortcut |

## Troubleshooting

**"mic-capture.exe not found"** — Run `dotnet publish tools\mic-capture -c Release -o bin` from the project root.

**"whisper-server.exe not found"** — Run `.\setup.ps1` first.

**Wrong microphone** — Right-click tray icon > "List Audio Devices". Copy the exact name into `config.ini`.

**"Too short" on every press** — Verify the mic device name matches a capture device, not a speaker/output.

**Transcription is slow** — Increase `Threads` in config (up to your physical core count). Current model (`small.en`) takes ~1.5-3s on CPU.

**CapsLock stuck** (if using CapsLock hotkey) — The script saves and restores the original CapsLock state on exit. If it crashes, press CapsLock once to toggle back.

## Project Structure

```
voice-to-text\
├── voice-to-text.ahk        # Main AHK script
├── config.ini                # User configuration
├── setup.ps1                 # Downloads whisper.cpp, model, generates icons
├── tools\mic-capture\        # .NET WASAPI capture tool (source)
├── bin\                      # mic-capture.exe, whisper-server.exe, DLLs (gitignored)
├── models\                   # ggml-small.en.bin (gitignored)
├── icons\                    # Tray icons: idle/starting/recording/transcribing
└── temp\                     # Transient recordings (gitignored)
```
