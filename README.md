# recall

`recall` is a local-first macOS app for turning long-form audio and video into searchable transcripts you can chat with.

It uses WhisperKit for transcription, FluidAudio for speaker diarization, and Apple MLX models for transcript Q&A. Import a file from disk or a YouTube link, let the app transcribe it locally, then review the timeline, rename speakers, and ask follow-up questions in chat.

## Features

- Local transcription on macOS with WhisperKit and Core ML
- Optional speaker diarization for multi-speaker recordings
- Built-in transcript chat powered by local MLX language models
- Audio playback with transcript scrubbing and word-level seek
- Import from local audio/video files
- Import from YouTube URLs, with caption fast-path when available
- Persistent transcript and chat history with SwiftData
- Model selection during onboarding and in Settings

## Supported Inputs

`recall` currently supports:

- Audio: `mp3`, `wav`, `m4a`, `flac`
- Video: `mp4`, `mov`
- YouTube video URLs

Video files are converted to audio automatically before transcription.

## Requirements

- macOS 14+
- Xcode 16 or newer
- Enough RAM and disk space for local models

Notes:

- Larger language models can require several GB of disk and memory.
- YouTube import works best with `yt-dlp` installed as a fallback:
  `brew install yt-dlp`

## Getting Started

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

On first launch, the app walks through model setup:

1. Choose a Whisper model for transcription.
2. Reuse an existing MLX model if one is already cached on your Mac, or pick a new one.
3. Finish onboarding and let the app download/load the selected models.

After setup, `recall` will automatically reload your saved models on launch.

## Usage

### Import a local file

- Click the `+` button in the sidebar
- Choose `From File`
- Pick an audio or video file

### Import from YouTube

- Click the `+` button in the sidebar
- Choose `YouTube Link`
- Paste a valid YouTube URL

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
- Transcript chat / generation
- Transcript persistence

Uses the network for:

- Downloading models
- YouTube imports
- Fetching YouTube captions

Important storage locations:

- Whisper / Hugging Face downloads:
  `~/Library/Caches/huggingface`
- MLX language model cache:
  `~/Library/Caches/models/mlx-community`
- FluidAudio diarization models:
  `~/Library/Application Support/FluidAudio/Models`
- App-managed audio copies:
  `~/Library/Application Support/AudioFiles`
- SwiftData store:
  `~/Library/Application Support/default.store`

Imported media is copied into the app's sandbox so playback continues to work after import.

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
- `recall.xcodeproj`: current Xcode project

## Development Notes

- The app target is macOS-only.
- The project currently includes both `project.yml` and a checked-in Xcode project.
- If you change project structure, prefer updating `project.yml` and regenerating the Xcode project with XcodeGen.
- Model downloads happen on first use, so a clean environment may take a while to become ready.
- There are some existing Swift 6 concurrency warnings in the project, but the app builds successfully today.

## Roadmap Ideas

- Export transcripts in common formats
- Search across transcripts
- Better model management and cache cleanup
- Batch imports
- Richer prompt templates for transcript chat

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, workflow notes, and pull request guidelines.

## License

This project is available under the [MIT License](LICENSE).
