# Changelog

## 1.3.1 (2026-07-21)

### Bug Fixes

* Fixed long dictations failing with an "entity too large" error and nothing reaching the clipboard. Recordings are now compressed before being sent to Groq, so even multi-minute dictations transcribe fine. If a recording is still somehow too large, the tooltip now says so clearly.

## 1.3.0 (2026-07-16)

### Features

* Trigger words now map to any keyboard shortcut, not just Enter. Define as many as you like in Settings — say a word at the end of your speech (e.g. "close") and it presses your chosen combo (Ctrl+W, Alt+F4, Win+L to lock, and so on). The original "go" still presses Enter.
* Added voice commands. Turn them on in Settings and start speaking with a wake word ("computer" by default), then say a natural command — "computer, switch to Edge", "computer, open notepad", "computer, go to my GitHub tab in Edge", "computer, start drafting an email", "computer, lock the screen". It opens or switches to apps, moves between browser tabs, runs shortcuts, and can do a follow-up action like starting a new email. Normal dictation without the wake word is unchanged. Uses Groq, so it needs your Groq API key.

## 1.2.0 (2026-07-15)

### Features

* Headset volume buttons now switch Windows Terminal tabs. With a wired headset remote focused on Windows Terminal, volume up moves to the next tab and volume down to the previous, instead of changing the volume — your volume level is kept where it was. Turn it on or off in Settings (on by default); it only applies while Windows Terminal is focused, so the buttons work as normal volume everywhere else.

### Notes

* When switching tabs this way, Windows briefly shows its volume flyout even though the volume doesn't actually change — a Windows limitation that can't be prevented from within the app.

## 1.1.1 (2026-07-15)

### Bug Fixes

* Fixed a fresh install not detecting microphones, and the headphone auto-switch not working.

## 1.1.0 (2026-07-15)

### Features

* **Groq is now the default transcription engine** — fast, low-latency cloud transcription. Requires a free Groq API key ([console.groq.com](https://console.groq.com), no credit card). Local Whisper remains available as a fully-offline option.
* In-app API key entry — paste your Groq key in Settings; stored locally, no environment variable needed. It can be replaced or cleared in place.
* First-run onboarding to set up Groq or switch to offline Local Whisper.
* Headphone remote button as a push-to-talk option — click to start, click again to stop (holding grounds the mic, so it toggles). Automatically switches to it when a wired headset (e.g. Apple EarPods) becomes the default input and reverts on unplug, resiliently across sleep/resume.
* Auto-paste — transcribed text is pasted into the focused input and left on the clipboard, with a trailing space so back-to-back dictations don't run together.
* Optional spoken "send" trigger word (e.g. "go") that presses Enter after pasting.
* Modern settings window with live updates — microphone, hotkey, and engine changes apply without restarting the app.
* Startup and model-download progress window.
* Follows the current Windows default microphone; administrator mode is now optional and disabled by default.

### Notes

* No local model is downloaded by default now that Groq is the default engine. For offline Local Whisper, run `setup.ps1 -IncludeLocalModel` or choose it during onboarding/Settings.

## 1.0.0 (2026-05-25)

Initial public release.

### Features

* Standalone Windows bundle — no installer, no dependencies to fetch
* Push-to-talk speech-to-text powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (small.en model)
* WASAPI microphone capture via bundled mic-capture tool
* Tray icon with idle / starting / recording / transcribing states
* Configurable hotkey, model, threads, and audio device via `config.ini`
