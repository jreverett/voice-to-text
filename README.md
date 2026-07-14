# Voice-to-Text

Local push-to-talk speech-to-text for Windows. Hold a hotkey, speak, release — transcribed text lands in your clipboard. 100% offline, powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp).

## Why?

I use Claude Code's `/voice` on Mac and it's great. On Windows it doesn't work nearly as well — especially in WSL through Windows Terminal — and most third-party alternatives are cloud-based or paywalled. So I built this. Works anywhere on Windows, runs entirely on your machine, free.

One of the AI labs will probably ship something better eventually. Until then, this is yours — MIT-licensed and open source.

## Download

Grab the latest pre-built Windows bundle from the [releases page](https://github.com/jreverett/voice-to-text/releases/latest) — no installer, no dependencies to fetch.

```powershell
# 1. Extract voice-to-text.zip somewhere you own (e.g. C:\Tools\voice-to-text\)
# 2. Double-click voice-to-text.exe
# 3. The first launch downloads the speech model with visible progress.
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

Double-click the tray icon, or right-click it and choose **Settings**, to change the microphone, hotkey, startup behaviour, speech model, and thread count. Changes apply automatically; settings that affect the speech engine restart the app and reopen the same pane. Custom push-to-talk shortcuts can be captured directly from the keyboard. The settings window uses the WebView2 runtime included with current Windows 10 and Windows 11 installations.

You can also edit `config.ini` (next to `voice-to-text.exe`) directly:

| Section | Setting | Default | Notes |
|---------|---------|---------|-------|
| `[Audio]` | `FollowWindowsDefault` | `true` | Uses the current Windows input device whenever recording starts |
| `[Audio]` | `MicDevice` | Empty | Used only when `FollowWindowsDefault=false`; select via the tray menu |
| `[Hotkey]` | `PushToTalk` | `ShiftAlt` | Also supports single keys: `CapsLock`, `F13`, `ScrollLock` |
| `[Whisper]` | `Threads` | `8` | Number of CPU threads for whisper inference |
| `[Whisper]` | `ServerPort` | `8178` | Local port for whisper-server |
| `[Paths]` | `ModelPath` | `models\ggml-small.en.bin` | Swap for `medium.en` for better accuracy |
| `[Startup]` | `RunAtLogin` | `true` | Creates/removes a startup shortcut |
| `[Startup]` | `RunAsAdministrator` | `false` | Enables the hotkey in elevated windows; the tray toggle relaunches the app automatically |

Application errors are written to `%LOCALAPPDATA%\VoiceToText\logs\voice-to-text.log`. Open or export the log from **Settings > Advanced > Diagnostics**. The log rotates at 1 MB and retains one previous file.

## Troubleshooting

**Wrong microphone** — Check the Windows input device, or right-click the tray icon > "Change Microphone" to set an app-specific override.

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

# Launch
autohotkey voice-to-text.ahk
```

## Project Structure

```
voice-to-text\
├── voice-to-text.ahk        # Main AHK script
├── config.ini                # User configuration
├── setup.ps1                 # Downloads whisper.cpp, model, generates icons
├── tools\mic-capture\        # .NET WASAPI capture tool (source)
├── ui\                        # HTML/CSS/JavaScript settings interface
├── lib\                       # WebView2 bridge and loader
├── bin\                      # mic-capture.exe, whisper-server.exe, DLLs (gitignored)
├── models\                   # ggml-small.en.bin (gitignored)
├── icons\                    # Application icon and tray status lights
└── temp\                     # Transient recordings (gitignored)
```

## License

[MIT](./LICENSE) — © 2026 Jamie Everett
