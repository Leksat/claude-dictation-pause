> [!WARNING]
> This project is vibe-coded. It was written by an AI agent and only lightly reviewed. Use at your own risk.

# claude-dictation-pause

Pauses your music while you dictate to [Claude Code](https://code.claude.com/docs/en/voice-dictation), and resumes it when you stop.

Works with any player that shows up in the macOS Now Playing widget and reacts to the media keys: YouTube Music desktop apps, Spotify, Apple Music, YouTube in a browser, and so on.

## Requirements

- macOS 14.2 or later
- Claude Code installed with the native installer (binaries in `~/.local/share/claude/`)
- [media-control](https://github.com/ungive/media-control): `brew install media-control`

## Install

```sh
make install
```

Builds the binary into `~/.local/bin/` and registers a launch agent that starts it at login and restarts it if it exits.

Other commands:

- `make uninstall` removes the binary and the launch agent
- `make logs` streams the log

## How it works

1. It listens for any input device starting or stopping. While no microphone is in use, it does nothing.
2. While a microphone is in use, it checks every 200 ms which processes are recording. A process counts as Claude Code if its executable, or one of its parent processes' executables, is under `~/.local/share/claude/`.
3. When Claude Code starts recording and something is playing, it pauses the Now Playing app via `media-control` and remembers which app it paused.
4. 500 ms after Claude Code stops recording, it resumes that app, but only if it is still the Now Playing app and still paused.

## Limitations

- `media-control` reads Now Playing state through a workaround for a private macOS API. A macOS update may break it.
- Claude Code installed via npm runs as `node` and is not detected.
- If your input device also plays audio (e.g. AirPods), macOS reports it as in use during playback, so the 200 ms check keeps running while music plays. It still works, at a slightly higher CPU cost.
