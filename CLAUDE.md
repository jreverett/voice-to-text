# Voice-to-Text

**This file must be kept up to date when committing changes.** If a commit changes architecture, design decisions, constraints, files, or configuration, update the relevant sections here as part of the same commit.

## Purpose

Push-to-talk speech-to-text for Windows. The primary use case is dictating prompts — hold Shift+Alt, speak, release, paste the transcribed text. Groq API transcription is the default (fast, low-latency, requires a free user-supplied API key); local Whisper is an optional fully-offline engine. No local model is downloaded by default.

## Architecture

An AutoHotkey v2 application (`voice-to-text.ahk`) orchestrates capture, transcription, and the settings UI:

- **mic-capture** (custom .NET tool using NAudio WASAPI) captures mic audio to WAV. Uses a named event (`Global\VoiceToText_StopCapture`) for cross-process stop signaling, ensuring clean WAV header finalization. Writes a ready-file when capture starts so AHK knows exactly when audio is flowing.
- **whisper-server** (whisper.cpp with OpenBLAS) runs as a persistent local HTTP server on port 8178 with the model pre-loaded in memory when `Transcription.Engine=Whisper`. Accepts WAV files via multipart POST and returns transcribed text.
- **Groq API** is selected with `Transcription.Engine=Groq`. It sends the captured WAV to `https://api.groq.com/openai/v1/audio/transcriptions` (OpenAI-compatible). The key is entered in Settings and stored at `%LOCALAPPDATA%\VoiceToText\groq_api_key.txt`, or read from the `GROQ_API_KEY` environment variable as a fallback.
- **curl** (ships with Windows 10+) sends the WAV to either the local whisper-server or the Groq speech-to-text endpoint.
- **WebView2** renders a lightweight HTML/CSS/JavaScript settings window. A small AHK host bridge reads and writes `config.ini`, manages the startup shortcut, and relaunches the app when settings change.

Local flow: `Script start → whisper-server launch → Hotkey Down → mic-capture starts WASAPI recording → ready-file appears → icon turns red → Hotkey Up → mic-capture stop (named event) → curl POST to whisper-server → text to clipboard + auto-paste (Ctrl+V)`

Groq flow: `Script start → API key check → Hotkey Down → mic-capture starts WASAPI recording → ready-file appears → icon turns red → Hotkey Up → mic-capture stop (named event) → curl POST to Groq STT → text to clipboard + auto-paste (Ctrl+V)`

## Key Design Decisions

- **mic-capture over ffmpeg for recording**: ffmpeg's DirectShow backend takes 2-3s to initialize the filter graph on every invocation. mic-capture uses WASAPI which starts capturing in ~50ms. The ready-file signal replaces stderr log parsing for accurate "recording started" detection.
- **Named event stop signaling**: mic-capture listens on a Windows named event. AHK runs `mic-capture stop` which signals the event, causing the recorder to flush and finalize the WAV header cleanly. No taskkill or process kill needed for normal operation.
- **Whisper server mode** instead of CLI-per-invocation: eliminates ~625ms model load on every transcription. The server starts on script launch and stays warm.
- **Groq API as default**: uses Groq's batch speech-to-text endpoint (Whisper large-v3 on their LPUs) with no local model load. The key is user-supplied (not shipped), stored locally outside the repo (or read from `GROQ_API_KEY`), never in `config.ini`. Groq has a free tier requiring no credit card. If Groq mode starts without a key, the app opens Settings rather than exiting, so the user can paste one.
- **OpenBLAS build**: setup.ps1 prefers the `whisper-blas-bin-x64.zip` release for accelerated CPU matrix operations over the plain build.
- **16 threads**: the target hardware (Intel Core Ultra 7 165H) has 16 physical cores. Configured via config.ini.
- **Optional administrator mode**: only needed for hotkeys in elevated windows. It is disabled by default and changing it relaunches at the selected privilege level.
- **Shift+Alt hotkey** uses `~*LAlt` with LShift state check. The `~` prefix lets keys pass through normally when not in a recording combo. A dedicated `*LShift Up` hook was removed because it blocked normal Shift usage.
- **Early release handling**: if the user releases the hotkey during mic startup, `IsHotkeyHeld()` detects it in the polling loop and `AbortRecording()` cleans up immediately. File deletion retries handle locked files from previous recordings. `IsHotkeyHeld()` uses `GetKeyState` for keyboard keys, but media keys have no reliable physical state so it falls back to the event-tracked `isKeyHeld` flag.
- **Toggle vs hold**: keyboard hotkeys are hold-to-talk. Headset-remote buttons (CTIA/AHJ) short the mic to ground while held — recording silence — so media-key hotkeys are click-to-toggle (`OnToggleKey`) and the startup-abort-on-release is skipped for them.
- **Auto headset-toggle switching**: when `AutoHeadsetToggle` and `FollowWindowsDefault` are on, `WM_DEVICECHANGE` and `WM_POWERBROADCAST` (resume) start a poll (`~300ms`, `mic-capture default`) that runs until the reading settles; a 10s periodic backstop self-heals anything the events miss (only queries while the feature is on). If the default input name contains `HeadsetDeviceMatch` (default `EarPods`), the runtime hotkey switches to `Media_Play_Pause`, reverting to the user's base `userHotkey` on unplug. The switch is runtime-only (never written to config, so the base preference is preserved); `userHotkey` is the config `PushToTalk` value and auto-switching sets `PushToTalkKey` without touching it.
- **Auto-paste on completion**: after transcription the text is copied to the clipboard and immediately pasted into the focused input via `SendInput("^v")` (guarded by `ClipWait`). The clipboard is left populated, so if no input is focused the user can paste manually. A trailing space is appended (unless the send word fires) so consecutive dictations don't run together.
- **Send trigger words**: opt-in (`[Send] Enabled`, default off). A list of *trigger word → keybinding* rules, stored as `RuleCount` + numbered `RuleNWord`/`RuleNKeys` keys (keys are AHK send strings, e.g. `{Enter}`, `!{F4}`, `#{r}`). When the transcript ends with a rule's trigger word it is stripped and that rule's keys are `SendInput` after pasting. Rules are matched longest-trigger-first (`SortSendRulesByLength`) so a longer phrase wins over a shorter one it contains. The default seed rule is "go" → `{Enter}`; a legacy single `Word=go` config auto-migrates to it. Trailing comma-family punctuation (`, ; :`) the model inserts before the word is removed too, but sentence-ending `. ! ?` is preserved. Done in post-processing (deterministic) rather than via the Groq prompt (Whisper prompts only bias, they don't reliably obey removal). Win+L (`#{l}`) is special-cased to `DllCall("user32\LockWorkStation")` because Windows ignores synthetic Win+L keystrokes. Settings edits the rules via a checkbox-modifier + key-dropdown builder (no live key capture — a WebView can't suppress OS combos like Win+L); rules round-trip over the bridge as `word<tab>keys` lines (`GetSendRules`/`sendRules`).
- **Voice commands (LLM intent routing)**: opt-in (`[Commands] Enabled`, default off). When the transcript starts with the wake word (`WakeWord`, default "computer") it is routed to Groq's chat endpoint instead of being pasted. `RunVoiceCommand` builds a live list of open windows (`GetCommandWindows` → title + exe, numbered) and the user's launch aliases (`[CommandAliases]`, e.g. `email=outlook.exe`), then one `chat/completions` POST (JSON mode, `Model` default `llama-3.1-8b-instant`) returns a bounded action: `focus` a window *by its number from the list*, `launch` an alias key or a bare `*.exe`, `keys` an AHK send string, or `none`. The model only ever picks from sets we supply, and `ExecuteCommandAction` validates before acting (window index in range; launch target is a config alias or matches `^[\w.\-]+\.exe$` — never an arbitrary command string). Win+L in `keys` uses `LockWorkStation` like the send rules. Needs a Groq key even in local Whisper mode (the LLM call is always Groq). Reuses the existing curl + `ParseJsonString`/`JsonUnescape` plumbing (`JsonEscape` added for request bodies; request/response go through `temp\command_request.json`/`command_output.txt`). Settings has a toggle + wake-word field in the Dictation group; the alias map is config-only for now.
- **Headset volume buttons navigate tabs**: `[TabNavigation] Enabled`/`TargetProcess` (default on/`WindowsTerminal.exe`), toggleable in Settings (Dictation group). The 3-button headset remote's volume +/- send `WM_APPCOMMAND` (not keyboard events an AHK hook can see), and `WM_APPCOMMAND` only reaches the focused window. So a shell hook (`RegisterShellHookWindow` on a dedicated hidden `Gui` + `HSHELL_APPCOMMAND`) catches the volume app-commands globally when the focused app ignores them; when `TargetProcess` is active we send `Ctrl+Tab` (volume up = next) / `Ctrl+Shift+Tab` (volume down = previous). The volume change **cannot** be suppressed from user space — when the target app ignores the command, explorer applies the volume change from its own copy of the shell notification, which our background hook can't veto. So instead we **restore** the volume: `TrackTabNavVolume` (400ms timer) remembers the real level while the target app isn't focused, and `OnShellHook` snaps the volume back to it after switching the tab. This leaves a brief volume-flyout flash; hiding the Win11 flyout would need OS-level changes (ExplorerPatcher/ModernFlyouts/a kernel input driver) so it's intentionally not attempted. The Settings toggle registers/deregisters the hook and timer live (`RegisterTabNavigation`/`UnregisterTabNavigation`), no relaunch needed.
- **First-run onboarding**: an overlay in the settings WebView (shown when not `IsOnboarded` and no key) guides the user to get a Groq key (with an "open console" button) or opt into offline local Whisper. Completion writes an `onboarded` marker in `%LOCALAPPDATA%\VoiceToText`.
- **First-connect headset notification**: the first time the headset auto-switch fires, a one-time tray notification (marker: `headset_notified`) tells the user the button is now push-to-talk. The compiled exe's icon (`app.ico`) supplies the notification logo; running the uncompiled script shows the AutoHotkey icon instead.
- **Four tray icon states**: green (idle), orange (starting/mic initializing), red (recording/audio flowing), yellow (transcribing). Icons are proper .ico files with embedded PNG, generated by setup.ps1.
- **Separate application icon**: the executable and Settings UI use `icons/app.ico` and `ui/app-icon.png`; the tray remains a simple changing status light.
- **curl for HTTP**: AHK's COM-based HTTP objects can't easily do multipart file uploads. curl ships with Windows 10+ and handles it cleanly.
- **Config-driven**: all paths, mic device, hotkey, transcription engine, Groq options, threads, server port, and tab-navigation live in `config.ini`. The AHK script reads these at startup.
- **Native-hosted settings UI**: WebView2 renders repo-owned HTML/CSS with minimal JavaScript. The hidden window is preloaded after startup and reused between opens. Microphone, hotkey, and transcription-engine changes apply in place; the app relaunches only for model/thread or privilege-level changes. No frontend framework, package manager, or local web server is used.
- **Settings transition feedback**: setting changes that can block briefly show an inline spinner before invoking the AHK bridge so the WebView can paint progress feedback.
- **WebView host bridge**: expose AHK functions on a plain object passed to `AddHostObjectToScript`; class methods add an implicit parameter that WebView treats as required.
- **Diagnostic logging**: AHK and Settings-page errors are written to `%LOCALAPPDATA%\VoiceToText\logs\voice-to-text.log`. Rotate at 1 MB and keep one `voice-to-text.previous.log`; Advanced Settings can view or export the current log.
- **Accuracy over speed for local mode**: uses `small.en` model (487MB). Do not downgrade to smaller models — accurate transcription is a hard requirement.

## Constraints

- **Windows only** — depends on WASAPI (mic-capture), AutoHotkey v2, and Windows startup shortcuts. Administrator mode is optional and disabled by default.
- **CPU inference only** — the hardware has Intel Arc integrated graphics but no prebuilt Vulkan whisper.cpp binary exists. CUDA builds won't work (not NVIDIA). Encode time ~1.5-3s for short clips with `small.en` and 16 threads on OpenBLAS.
- **Groq mode is cloud-based** — it is the default and requires a user-supplied Groq API key; audio is sent to Groq. Switch to local Whisper if that is not acceptable.
- **No tests** — the script is pure I/O orchestration (real mic, real processes, real HTTP). Mocking everything would test nothing useful. Validate changes manually: hold hotkey, speak, check clipboard.

## Files

| File | Purpose |
|------|---------|
| `voice-to-text.ahk` | Core script — hotkey handling, mic-capture lifecycle, whisper-server communication, clipboard, tray UI |
| `config.ini` | User configuration — mic device, hotkey, model path, server port, threads, startup |
| `setup.ps1` | Idempotent installer — downloads ffmpeg, whisper.cpp OpenBLAS build (cli + server), generates tray icons, creates startup shortcut. `-IncludeLocalModel` also downloads the local model (skipped by default since Groq is the default engine) |
| `tools/mic-capture/` | .NET console app — WASAPI audio capture with named event stop signaling. Build: `dotnet publish tools/mic-capture -c Release -o bin` |
| `ui/` | HTML, CSS, and JavaScript for the settings window |
| `lib/` | Vendored MIT-licensed AHK WebView2 bridge, support files, and Microsoft WebView2 loader |
| `bin/` | mic-capture.exe, ffmpeg.exe, whisper-cli.exe, whisper-server.exe, DLLs (gitignored, populated by setup.ps1 + dotnet publish) |
| `models/` | ggml-small.en.bin (gitignored, offline mode only — via `setup.ps1 -IncludeLocalModel` or first Whisper-mode start) |
| `icons/` | Tray icons generated by setup.ps1 — green (idle), orange (starting), red (recording), yellow (transcribing) |
| `temp/` | Transient recording.wav, capture_ready, whisper_output.txt, groq_output.txt, command_request.json, command_output.txt (gitignored) |

## Common Changes

- **Change settings**: use the tray Settings window. Raw `config.ini` editing remains available under Advanced.
- **Change hotkey**: select a preset or capture a custom modifier and key combination in Settings. `ShiftAlt` is a special-cased modifier-only combo. `Media_Play_Pause` ("Headphone button") drives recording from a wired headset remote's centre button — registered suppressed (no `~`) so it doesn't control media. It is **toggle** (`isToggleHotkey`/`OnToggleKey`: click to start, click to stop), not hold-to-talk, because CTIA/AHJ remotes short the mic to ground while the button is held — holding records silence. Media/remote keys are detected by `IsMediaHotkey()`.
- **Change mic**: follows the current Windows default by default; the tray menu can set an app-specific override.
- **Administrator mode**: toggle "Run as Administrator" from the tray menu. The app relaunches at the selected privilege level.
- **Improve accuracy**: swap `ModelPath` to a larger model (small.en → medium.en). Larger models are slower but more accurate. Do not downgrade below small.en.
- **Use Groq transcription (default)**: select Groq API in Settings and paste an API key into the API key field (or set `GROQ_API_KEY`). Settings can hot-switch between Local Whisper and Groq API.
- **Enable offline/local Whisper**: run `setup.ps1 -IncludeLocalModel` to fetch the model, then select Local Whisper in Settings (or start in `Engine=Whisper`, which downloads the model at startup).
- **Add GPU support**: if a prebuilt Vulkan whisper.cpp binary becomes available, replace bin/ contents with it. No script changes needed. Intel Arc GPU could provide ~3-5x speedup.
- **Rebuild mic-capture**: `dotnet publish tools/mic-capture -c Release -o bin` from project root.
- **Create a release**: push a tag like `v1.0.0` — GitHub Actions builds everything, bundles into a zip, and creates a GitHub Release. The zip includes compiled AHK exe, self-contained mic-capture, whisper-server + DLLs, icons, and default config (`Engine=Groq`). No model is bundled; it downloads only if the user opts into local Whisper.

## Release Pipeline

`.github/workflows/build.yml` triggers on version tags (`v*`). It:
1. Builds mic-capture as self-contained single-file (no .NET install needed for end users)
2. Compiles voice-to-text.ahk to exe via AHK2Exe and packages the WebView2 loader and settings assets
3. Downloads whisper.cpp OpenBLAS binaries
4. Generates tray icons
5. Creates a default config.ini configured to follow the Windows input device, with `Engine=Groq`
6. Packages everything into `voice-to-text-{tag}.zip` and attaches to a GitHub Release

## First-Run Experience

On a fresh install from the release zip (default engine is Groq):
1. No model download — the local model is fetched only when running in Whisper mode
2. Uses the current Windows default input device
3. If Groq mode has no API key, Settings opens automatically with the onboarding overlay (get a Groq key, or opt into offline local Whisper); the app still starts to the tray (it no longer exits on a missing key)
4. Once a key is saved, hold the hotkey to dictate

Local/offline mode is opt-in: run `setup.ps1 -IncludeLocalModel` (or start in `Engine=Whisper`, which downloads `ggml-small.en.bin` ~466MB at startup with progress and Cancel support).
