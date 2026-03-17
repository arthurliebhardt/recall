# Contributing

Thanks for your interest in improving `recall`.

This project is still evolving, so the best contributions are usually small, focused changes with a clear user-facing improvement or a well-scoped bug fix.

## Development Setup

- macOS 14+
- Xcode 16+
- Optional: `yt-dlp` for more reliable YouTube imports

Clone the repo, open `recall.xcodeproj`, and run the `recall` scheme.

You can also build from the command line:

```bash
xcodebuild -project recall.xcodeproj -scheme recall build
```

## Project Notes

- `recall` is a macOS SwiftUI app.
- Persistence uses SwiftData.
- Transcription uses WhisperKit.
- Transcript chat uses local MLX models.
- Speaker diarization uses FluidAudio.
- The repo includes both `project.yml` and a checked-in Xcode project.

If you change project structure or target settings, prefer updating `project.yml` and regenerating the Xcode project with XcodeGen.

## Contribution Guidelines

- Keep pull requests focused and easy to review.
- Prefer fixes that preserve the app's local-first behavior.
- Avoid introducing unnecessary network dependencies for core flows.
- Do not commit build products, downloaded models, personal transcripts, or other machine-specific artifacts.
- Update documentation when behavior, setup, storage paths, or user-facing workflows change.

## Before Opening a Pull Request

Please do as many of these as are relevant:

- Build the app successfully with `xcodebuild -project recall.xcodeproj -scheme recall build`
- Smoke test the feature or fix in the app
- Call out any tradeoffs, follow-up work, or known limitations in the PR description

There are some existing Swift 6 concurrency warnings in the codebase. If your change does not affect them, you do not need to fix them as part of an unrelated PR.

## Reporting Bugs

Helpful bug reports usually include:

- What you were trying to do
- What happened instead
- Steps to reproduce
- macOS version
- Whether the issue involved file import, model download, YouTube import, playback, or chat

If a crash or model-loading issue is involved, include any relevant console or build output you have.

## Good First Contributions

- UI polish and small workflow improvements
- Documentation updates
- Better error messages
- Import and playback bug fixes
- Model management improvements

## Questions

If something is ambiguous, open an issue or draft PR with your proposed direction before doing a larger refactor.
