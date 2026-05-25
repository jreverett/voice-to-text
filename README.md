# Voice-to-Text

Local push-to-talk speech-to-text for Windows. Hold a hotkey, speak, release — transcribed text lands in your clipboard. 100% offline, powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

## Download

Grab the latest pre-built Windows bundle from the [releases page](https://github.com/jreverett/voice-to-text/releases/latest) — no installer, no dependencies to fetch.

```powershell
# 1. Extract voice-to-text.zip somewhere you own (e.g. C:\Tools\voice-to-text\)
# 2. Double-click voice-to-text.exe
#    (It auto-elevates for global hotkey support in admin windows like Terminal.)
# 3. On first launch you'll pick a microphone from a GUI picker.
# 4. Hold Shift+Alt, speak, release — text is in your clipboard, paste with Ctrl+V.
```

That's it. Skip to [Usage](#usage) or [Configuration](#configuration) if you want to tweak hotkeys or settings.

## Usage

1. **Hold Shift+Alt** — tray icon turns orange (initializing), then red (recording)
2. **Speak** your text
3. **Release** — icon turns yellow (transcribing), text is copied to clipboard, icon returns to green
4. **Paste** anywhere with Ctrl+V

Releasing during the orange startup phase cancels cleanly.

## Configuration

Edit `config.ini` (next to `voice-to-text.exe`) to customize:

| Section | Setting | Default | Notes |
|---------|---------|---------|-------|
| `[Audio]` | `MicDevice` | Set on first run | WASAPI device name; re-pick via tray menu > "List Audio Devices" |
| `[Hotkey]` | `PushToTalk` | `ShiftAlt` | Also supports single keys: `CapsLock`, `F13`, `ScrollLock` |
| `[Whisper]` | `Threads` | `8` | Number of CPU threads for whisper inference |
| `[Whisper]` | `ServerPort` | `8178` | Local port for whisper-server |
| `[Paths]` | `ModelPath` | `models\ggml-small.en.bin` | Swap for `medium.en` for better accuracy |
| `[Startup]` | `RunAtLogin` | `true` | Creates/removes a startup shortcut |

## Troubleshooting

**Wrong microphone** — Right-click tray icon > "List Audio Devices" and pick again.

**"Too short" on every press** — Verify the selected mic is a capture device, not a speaker/output.

**Transcription is slow** — Increase `Threads` in config (up to your physical core count). Current model (`small.en`) takes ~1.5–3s on CPU.

**SmartScreen warning** — Expected; the bundle is unsigned. Click "More info" > "Run anyway".

**CapsLock stuck** (if using CapsLock hotkey) — The script saves and restores the original CapsLock state on exit. If it crashes, press CapsLock once to toggle back.

## Build from Source

If you'd rather build locally instead of using the release bundle:

### Prerequisites

- Windows 10+
- [AutoHotkey v2](https://www.autohotkey.com/)
- [.NET 10+ SDK](https://dotnet.microsoft.com/download) (to build mic-capture)

### Build steps

```powershell
git clone https://github.com/jreverett/voice-to-text.git
cd voice-to-text

# Downloads whisper.cpp, model, generates icons
.\setup.ps1

# Build the WASAPI capture tool
dotnet publish tools\mic-capture -c Release -o bin

# Launch (auto-elevates)
autohotkey voice-to-text.ahk
```

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

## License

[MIT](./LICENSE) — © 2026 Jamie Everett
