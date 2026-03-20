# recall

`recall` is a local-first macOS app for turning long audio and video into searchable transcripts you can chat with on-device.

It combines WhisperKit for transcription, FluidAudio for speaker diarization, and Apple MLX models for transcript Q&A. You can import files from disk or a YouTube link, review the transcript with synced playback, rename speakers, and ask follow-up questions without sending the transcript to a hosted LLM.

## Highlights

- Local transcription on macOS with WhisperKit and Core ML
- Optional speaker diarization for multi-speaker recordings
- Local transcript chat powered by MLX language models
- Synced playback with transcript scrubbing and timestamp seek
- Import from local audio and video files
- Import from YouTube URLs, with caption fast-path when available
- Persistent transcript and chat history with SwiftData
- Cached model reuse so existing Whisper and MLX downloads are picked up automatically

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- Enough RAM and disk space for local models

Recommended RAM for the default models:

- `Qwen3-4B-4bit` (default): `16 GB`
- `Qwen3-8B-4bit`: `24 GB`

Notes:

- The first launch can take a while because models may need to download.
- Larger MLX models need more memory and will respond more slowly on smaller Macs.
- YouTube import works best with `yt-dlp` available as a fallback:

```bash
brew install yt-dlp
```

## Supported Inputs

- Audio: `mp3`, `wav`, `m4a`, `flac`
- Video: `mp4`, `mov`
- YouTube video URLs

Video files are converted to audio automatically before transcription.

## Getting Started

### Install the latest release

Download the current macOS build directly: [recall-v1.0.0-macos.zip](https://github.com/arthurliebhardt/recall/releases/download/v1.0.0/recall-v1.0.0-macos.zip)

```bash
./install.sh
```

Run that from a local checkout of the repository. The installer downloads the latest macOS release zip automatically. If the repo is private, install with authenticated `gh` access so the release download can resolve.

If you already downloaded a release zip, you can install that directly instead:

```bash
./install.sh /path/to/recall-v1.0.0-macos.zip
```

The installer places `recall.app` in `/Applications` when writable, otherwise `~/Applications`. It also migrates existing legacy `default.store` and `AudioFiles` data into the sandbox container when needed.

### Build in Xcode

1. Clone the repository.
2. Open `recall.xcodeproj`.
3. Select the `recall` scheme.
4. Build and run.

### Build from the command line

```bash
xcodebuild -project recall.xcodeproj -scheme recall build
```

## First Launch

On first launch, `recall` walks through model setup:

1. Choose a Whisper model for transcription.
2. Reuse a cached MLX model if one already exists on your Mac, or download a new one.
3. Finish onboarding and let the app prepare the selected models.

The default LLM is `Qwen3-4B-4bit`, which is the safest choice for most Macs. If you want better answer quality and have more headroom, you can switch to a larger model later in Settings.

## Usage

### Import a local file

1. Click the `+` button in the sidebar.
2. Choose `From File`.
3. Pick an audio or video file.

### Import from YouTube

1. Click the `+` button in the sidebar.
2. Choose `YouTube Link`.
3. Paste a valid YouTube URL.

When captions are available, `recall` uses them first. Otherwise it falls back to local Whisper transcription after downloading audio.

### Review the transcript

- Play back the imported media from the transcript view
- Scrub through the timeline
- Click timestamps or words to jump playback
- Double-click a speaker label to rename it

### Chat with the transcript

- Open the chat panel for any transcription
- Ask questions about the recording
- Responses are generated from the saved transcript using a local MLX model

## Privacy and Storage

The app is local-first, but not fully offline in every workflow.

Runs locally on your Mac:

- Audio transcription
- Speaker diarization
- Transcript chat and generation
- Transcript persistence

Uses the network for:

- Downloading models
- YouTube imports
- Fetching YouTube captions

Important storage locations:

- Whisper downloads:
  `~/Library/Caches/huggingface`
- MLX language model cache:
  `~/Library/Caches/models/mlx-community`
- FluidAudio diarization models:
  `~/Library/Application Support/FluidAudio/Models`
- App-managed audio copies:
  `~/Library/Application Support/AudioFiles`
- SwiftData store:
  `~/Library/Application Support/default.store`

Imported media is copied into the app sandbox so playback keeps working after import.

## Tech Stack

- SwiftUI for the app UI
- SwiftData for persistence
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) for speech-to-text
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) for local LLM inference
- [FluidAudio](https://github.com/FluidInference/FluidAudio) for diarization
- [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) for YouTube import

## Project Structure

```text
recall/
  Services/       Core transcription, LLM, diarization, playback, and YouTube logic
  ViewModels/     App state and import/chat orchestration
  Views/          SwiftUI screens and components
  Models/         SwiftData models and transcript/chat entities
```

Other top-level files:

- `project.yml`: XcodeGen project definition
- `Package.swift`: Swift Package definition for dependencies
- `recall.xcodeproj`: checked-in Xcode project

## Development Notes

- The app target is macOS-only.
- The repository includes both `project.yml` and a checked-in Xcode project.
- If you change project structure, keep `project.yml` and `recall.xcodeproj` in sync.
- Model downloads happen on first use, so a clean environment may take a while to become ready.

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, workflow notes, and pull request guidelines.

## License

This project is available under the [MIT License](LICENSE).
