# Word Note App Icon Concepts

This directory retains the four app icon explorations used during product design:

- `concept-01-smart-notebook`: notebook with an AI sparkle.
- `concept-02-term-cards`: vocabulary cards, relationship nodes, and a bookmark.
- `concept-03-code-lexicon`: open technical reference with code brackets.
- `concept-04-neural-bookmark`: neural graph combined with a book marker.

Concept 02 was selected because it communicates vocabulary capture and connected technical knowledge at small sizes. The production-ready transparent 1024px master is stored at `Resources/AppIcon-1024.png` rather than copied directly from the concept image.

Run `./script/generate_app_icon.sh` from the repository root to regenerate the standard PNG iconset and `Resources/AppIcon.icns`. `script/build_and_run.sh` embeds the ICNS in the staged app bundle.
