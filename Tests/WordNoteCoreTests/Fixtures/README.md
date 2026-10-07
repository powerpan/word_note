# Frozen V1 Store

`v1.store` is a SQLite backup generated from `WordNoteTestFixture.populated` with
the unmodified V1 model definitions. It contains only synthetic data: two
courses, four terms, three input records, three candidates, and one review event.
It contains no credentials or user vocabulary.

SHA-256: `92f4003123fb65a7763f7baf646f3558916e74ebe807832ddf51a7f94398b7de`.

Keep this fixture unchanged when adding new schemas. Tests must copy it to a
temporary directory before opening it. Do not regenerate it from newer model
definitions to make a migration test pass.

The initial generation uses the SQLite backup API so committed WAL content is
included in a standalone file:

```bash
WORD_NOTE_EXPORT_V1_FIXTURE="$PWD/Tests/WordNoteCoreTests/Fixtures/v1.store" \
  RUN_LIVE_DEEPSEEK_TESTS=0 swift test \
  --filter WordNoteTestFixtureTests.testPersistentV1FixtureCanBeReopenedWithoutChangingIdentity
```

Generation refuses to overwrite an existing file. The normal test suite does
not export or modify this fixture.
