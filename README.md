# Word Note

Word Note is a native macOS app for AI / CS graduate students who study in English and want to capture, explain, organize, and review technical vocabulary.

The current implementation follows the engineering plan in [docs](docs/README.md). The original requirements file is retained as background reference only.

## Current MVP Features

- Native macOS SwiftUI app shell.
- Versioned local SwiftData persistence with one-time legacy-store backup and migration.
- Quick Add for saving raw English input.
- Local vocabulary prefix completion in the main and floating Quick Add inputs, with Tab acceptance.
- Non-blocking, persistent AI analysis queue shared by the main window and menu bar panel.
- DeepSeek-powered analysis through OpenAI-compatible chat completions.
- Candidate review with editable AI-generated terms.
- Manual term creation when AI returns no useful candidate.
- Vocabulary list, search, filters, detail editing, and deletion.
- Course creation, editing, deletion guard, and course statistics.
- Adaptive review queues, bidirectional cards, keyboard shortcuts, and session statistics.
- Menu bar Quick Add panel with temporary Chinese explanation preview.
- Environment-file storage for DeepSeek API key, with `DEEPSEEK_API_KEY` process environment fallback.

## Requirements

- macOS 14 or later.
- Xcode 26.x command line tools or compatible Swift 5.9+ toolchain.
- DeepSeek API key for live AI analysis.

## Build And Run

Use the root app entrypoint:

```bash
./WordNote.command
```

It builds the SwiftPM target, stages `dist/WordNote.app`, and launches the app bundle.

For lower-level launch modes, use the project-local run script directly:

```bash
./script/build_and_run.sh
```

Verification mode builds the app bundle, launches it, and checks the app process:

```bash
./script/build_and_run.sh --verify
```

The selected 1024px app icon master is stored at `Resources/AppIcon-1024.png`; alternative concepts are retained under `design/app-icons/`. Regenerate the complete iconset and `AppIcon.icns` with `./script/generate_app_icon.sh`. The build-and-run script embeds the generated ICNS in the staged app bundle.

The Codex desktop Run action is wired to the same script through `.codex/environments/environment.toml`.

## Tests

Run the full non-live test suite:

```bash
swift test
```

The default suite skips paid network tests. Explicitly enable the live DeepSeek smoke test when a key is available:

```bash
RUN_LIVE_DEEPSEEK_TESTS=1 swift test --filter LiveDeepSeekSmokeTests
```

The live test calls DeepSeek with `latent representation` and verifies that a structured candidate is returned.

## DeepSeek Key Handling

The app resolves the DeepSeek key in this order:

1. Optional override file from `WORD_NOTE_ENV_FILE`.
2. Environment file managed from Settings: `~/Library/Application Support/WordNote/deepseek.env`.
3. Local development files: `.env.local`, then `.env`.
4. `DEEPSEEK_API_KEY` process environment variable.

On first launch, a process-level `DEEPSEEK_API_KEY` is copied to the private environment file only when that file does not already contain a key. The file is created with owner-only permissions.

The API key must not be committed to the repository. Local key files such as `.env`, `.env.local`, `.env.*`, and `key.md` are ignored by `.gitignore`.

## Development Milestones

Implemented:

- M1: Project foundation.
- M2: Quick Add and Inbox.
- M3: DeepSeek analysis integration.
- M4: Candidate Review to Vocabulary.
- M5: Course management and filters.
- M6: Review loop.
- M7: QA and release polish.
- P1: duplicate-term AI bypass, adaptive review, weak-term queue, bidirectional cards, shortcuts, and session statistics.

## Known Limits

- Candidate merge into existing terms is not implemented yet; duplicate terms are rejected.
- Global system-wide hotkey, clipboard import, and export are not implemented.
- Live AI behavior depends on DeepSeek service availability and model behavior.
- No cloud sync, accounts, or multi-device support in MVP.
