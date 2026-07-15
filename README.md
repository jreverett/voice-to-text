# Voice-to-Text

Push-to-talk speech-to-text for Windows. Hold a hotkey, speak, release — transcribed text lands in your clipboard. Uses [Groq](https://groq.com)'s fast cloud transcription by default (a free API key is required), with an optional fully-offline [whisper.cpp](https://github.com/ggerganov/whisper.cpp) engine.

## Why?

I use Claude Code's `/voice` on Mac and it's great. On Windows it doesn't work nearly as well — especially in WSL through Windows Terminal — and most third-party alternatives are paywalled. So I built this. Works anywhere on Windows, free and open source, with a fully-offline mode if you'd rather not send audio anywhere.

One of the AI labs will probably ship something better eventually. Until then, this is yours — MIT-licensed and open source.

## Download

Grab the latest pre-built Windows bundle from the [releases page](https://github.com/jreverett/voice-to-text/releases/latest) — no installer, no dependencies to fetch.

```powershell
# 1. Extract voice-to-text.zip somewhere you own (e.g. C:\Tools\voice-to-text\)
# 2. Double-click voice-to-text.exe
# 3. On first launch, Settings opens — paste your Groq API key and click Save.
# 4. Hold Shift+Alt, speak, release — text is pasted into the focused input (and left on the clipboard).
```

You'll need a free Groq API key: sign up at [console.groq.com](https://console.groq.com) (no credit card) and create a key. The app does not ship with one. Prefer to run fully offline instead? See [Offline mode](#offline-mode-local-whisper).

That's it. Skip to [Usage](#usage) or [Configuration](#configuration) if you want to tweak hotkeys or settings.

## Usage

1. **Hold Shift+Alt** — tray icon turns orange (initializing), then red (recording)
2. **Speak** your text
3. **Release** — icon turns yellow (transcribing), then the text is copied to the clipboard and pasted into the focused input, and the icon returns to green

The text is always left on the clipboard, so if no input is focused you can paste it yourself with Ctrl+V. A trailing space is appended so you can dictate several times in a row without the words running together. Releasing during the orange startup phase cancels cleanly.

## Configuration

Double-click the tray icon, or right-click it and choose **Settings**, to change the microphone, hotkey, startup behaviour, transcription engine, speech model, and thread count. Changes apply automatically; switching between Local Whisper and Groq API happens without restarting the app. Custom push-to-talk shortcuts can be captured directly from the keyboard, and the **Headphone button** option maps recording to the centre button on a wired headset remote (e.g. Apple USB-C EarPods). It works as a **toggle** — click once to start, click again to stop — because these remotes short the mic to ground while the button is held, so hold-to-talk would record silence. While that option is selected the button no longer plays/pauses media.

When `FollowWindowsDefault` and `AutoHeadsetToggle` are on, plugging in a matching headset (default match: names containing "EarPods") automatically switches push-to-talk to the headphone toggle, and unplugging reverts to your configured hotkey — so you don't have to change the setting each time. The settings window uses the WebView2 runtime included with current Windows 10 and Windows 11 installations.

You can also edit `config.ini` (next to `voice-to-text.exe`) directly:

| Section | Setting | Default | Notes |
|---------|---------|---------|-------|
| `[Audio]` | `FollowWindowsDefault` | `true` | Uses the current Windows input device whenever recording starts |
| `[Audio]` | `MicDevice` | Empty | Used only when `FollowWindowsDefault=false`; select via the tray menu |
| `[Hotkey]` | `PushToTalk` | `ShiftAlt` | Also supports single keys `CapsLock`, `F13`, `ScrollLock`, or `Media_Play_Pause` (wired headphone remote button — click-to-toggle) |
| `[Hotkey]` | `AutoHeadsetToggle` | `true` | When Windows switches the default mic to a matching headset, auto-switch push-to-talk to the headphone toggle and revert on unplug (needs `FollowWindowsDefault=true`) |
| `[Hotkey]` | `HeadsetDeviceMatch` | `EarPods` | Case-insensitive substring matched against the default input device name to trigger the auto-switch |
| `[Transcription]` | `Engine` | `Groq` | Use `Groq` for cloud transcription or `Whisper` for local/offline transcription |
| `[Groq]` | `Model` | `whisper-large-v3-turbo` | Groq speech model; use `whisper-large-v3` for slightly higher accuracy |
| `[Groq]` | `Language` | `en` | Language hint sent to the Groq speech-to-text endpoint |
| `[Whisper]` | `Threads` | `8` | Number of CPU threads for whisper inference (local mode) |
| `[Whisper]` | `ServerPort` | `8178` | Local port for whisper-server (local mode) |
| `[Paths]` | `ModelPath` | `models\ggml-small.en.bin` | Local model; not downloaded by default (see Offline mode) |
| `[Startup]` | `RunAtLogin` | `true` | Creates/removes a startup shortcut |
| `[Startup]` | `RunAsAdministrator` | `false` | Enables the hotkey in elevated windows; the tray toggle relaunches the app automatically |

### Groq API key

Groq is the default engine and needs an API key, which the app does not include — get a free one at [console.groq.com](https://console.groq.com) (no credit card). In **Settings > Transcription**, paste it into the API key field and click **Save**. The key is stored locally at `%LOCALAPPDATA%\VoiceToText\groq_api_key.txt`, never in `config.ini`; a `GROQ_API_KEY` environment variable works as a fallback. You can replace or clear the key from the same screen. Recordings are sent to Groq only while this engine is selected.

### Offline mode (Local Whisper)

To transcribe fully offline with no API key, download the speech model (~466 MB) and switch to the local engine:

```powershell
.\setup.ps1 -IncludeLocalModel   # downloads models\ggml-small.en.bin
```

Then set **Settings > Transcription > Engine > Local Whisper** (or `Engine=Whisper` in `config.ini`). The model loads into a local whisper-server on startup; nothing leaves your machine.

Application errors are written to `%LOCALAPPDATA%\VoiceToText\logs\voice-to-text.log`. Open or export the log from **Settings > Advanced > Diagnostics**. The log rotates at 1 MB and retains one previous file.

## Troubleshooting

**Wrong microphone** — Check the Windows input device, or right-click the tray icon > "Change Microphone" to set an app-specific override.

**"Too short" on every press** — Verify the selected mic is a capture device, not a speaker/output.

**Groq API transcription fails** — Confirm your API key is saved (Settings shows "Saved key: …") and that your Groq account has available quota. The tray tooltip surfaces the API error message on failure.

**No transcription / Settings keeps opening** — Groq mode needs an API key. Paste one in Settings (see [Groq API key](#groq-api-key)), or switch to [Offline mode](#offline-mode-local-whisper).

**Local transcription is slow** — In local Whisper mode, increase `Threads` in config (up to your physical core count). The `small.en` model takes ~1.5–3s on CPU.

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

# Downloads ffmpeg, whisper.cpp, generates icons (add -IncludeLocalModel for offline mode)
.\setup.ps1

# Build the WASAPI capture tool
dotnet publish tools\mic-capture -c Release -o bin

# Launch
autohotkey voice-to-text.ahk
```

The default engine is Groq, so you'll enter an API key on first launch. For offline use, run `.\setup.ps1 -IncludeLocalModel` to fetch the model and select Local Whisper.

## Project Structure

```
voice-to-text\
├── voice-to-text.ahk        # Main AHK script
├── config.ini                # User configuration
├── setup.ps1                 # Downloads ffmpeg, whisper.cpp, generates icons (model optional)
├── tools\mic-capture\        # .NET WASAPI capture tool (source)
├── ui\                        # HTML/CSS/JavaScript settings interface
├── lib\                       # WebView2 bridge and loader
├── bin\                      # mic-capture.exe, whisper-server.exe, DLLs (gitignored)
├── models\                   # ggml-small.en.bin (gitignored, offline mode only)
├── icons\                    # Application icon and tray status lights
└── temp\                     # Transient recordings (gitignored)
```

## License

[MIT](./LICENSE) — © 2026 Jamie Everett
