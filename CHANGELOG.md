# Changelog

## [1.0.0](https://github.com/jreverett/voice-to-text/compare/v1.1.1...v1.0.0) (2026-07-15)


### Chores

* bootstrap first release as v1.0.0 ([2776685](https://github.com/jreverett/voice-to-text/commit/2776685e2c052615a819cddf8c8e22dd5b2efc1a))

## 1.1.1 (2026-07-15)

### Bug Fixes

* Fixed no microphones being detected — and the headphone auto-switch not firing — on a fresh install. The app now creates its `temp` working directory on startup; the release archive could omit it (empty folders are dropped when zipping), and the device queries that write there returned nothing without it.

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
