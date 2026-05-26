# Changelog

## 1.0.0 (2026-05-25)

Initial public release.

### Features

* Standalone Windows bundle — no installer, no dependencies to fetch
* Push-to-talk speech-to-text powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (small.en model)
* WASAPI microphone capture via bundled mic-capture tool
* Tray icon with idle / starting / recording / transcribing states
* Configurable hotkey, model, threads, and audio device via `config.ini`
