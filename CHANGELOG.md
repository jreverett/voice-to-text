# Changelog

## [1.0.1](https://github.com/jreverett/voice-to-text/compare/v1.0.0...v1.0.1) (2026-05-25)


### Documentation

* add MIT LICENSE and rewrite README for public release ([68bcac1](https://github.com/jreverett/voice-to-text/commit/68bcac124f3e1441d365a67b5a9cbd9ce76ef9ef))
* add Why? section explaining WSL/Terminal motivation ([8589646](https://github.com/jreverett/voice-to-text/commit/858964683704ae2e00194443622f9c8517b81478))
* mention MIT-licensed / open source in the Why? section ([203e519](https://github.com/jreverett/voice-to-text/commit/203e51954315f00f6889a0107389d5a65ebee045))
* refine Why? section — mention Claude Code's /voice ([7768df7](https://github.com/jreverett/voice-to-text/commit/7768df71e47b96344d7075c269f9a9e3f1bb61ca))

## 1.0.0 (2026-05-25)

Initial public release.

### Features

* Standalone Windows bundle — no installer, no dependencies to fetch
* Push-to-talk speech-to-text powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (small.en model)
* WASAPI microphone capture via bundled mic-capture tool
* Tray icon with idle / starting / recording / transcribing states
* Configurable hotkey, model, threads, and audio device via `config.ini`
