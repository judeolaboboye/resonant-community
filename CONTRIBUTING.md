# Contributing to Resonant

Thanks for helping improve Resonant Community Edition. Contributions should
preserve the standalone local dictation path, privacy-safe defaults, and the
ability to build without private infrastructure.

By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Development setup

You need an Apple Silicon Mac, macOS 14 or newer, and Xcode 16 or newer.

```sh
swift --version
swift build
swift test
scripts/package_app.sh debug
```

To package and open the app in one step:

```sh
scripts/run_packaged_app.sh debug
```

The app will request macOS permissions when you exercise the relevant features.
Use a development account and non-sensitive sample text while testing capture,
context, telemetry, API, or MCP changes.

## Design boundaries

- Core capture, local transcription, deterministic processing, and paste must
  continue to work without authentication or a hosted service.
- Optional hosted integrations must fail closed when their complete operator
  configuration is absent.
- Analytics, crash reporting, cloud upload, ambient context, retained audio,
  MCP, local API, webhooks, and automatic updates must remain opt-in in the
  unconfigured Community build.
- Capability checks belong near the capability. Do not reintroduce commercial
  entitlements or paywall behavior into the local path.
- Do not add a silent model download. Show the model source, approximate size,
  system requirements, and licensing notice before network work begins.

Domain terms are defined in [UBIQUITOUS_LANGUAGE.md](UBIQUITOUS_LANGUAGE.md).

## Tests and pull requests

Before opening a pull request:

```sh
swift build
swift test
scripts/export_public_snapshot.sh --working-tree /tmp/resonant-public-check
```

Add focused tests for behavior you change. Text-processing changes should have
deterministic fixtures. Privacy boundary, redaction, packaging, and configuration
changes need regression tests that exercise the disabled/unconfigured case.

Keep pull requests focused and explain:

- The user-visible outcome
- Any new data read, stored, transmitted, or deleted
- Any permission or network behavior added
- How an unconfigured Community build behaves
- The tests you ran

## Secrets, personal data, and fixtures

Never commit credentials, production endpoints, signing material, customer data,
real transcripts, recordings, clipboard contents, or personal filesystem paths.
Use `example.com`, synthetic names, and paths such as `/Users/example/project` in
tests and documentation.

Enable the local secret-scan hook if you have `gitleaks` installed:

```sh
brew install gitleaks
git config core.hooksPath scripts/hooks
```

The hook is a convenience, not a guarantee. Maintainers run history-aware scans
before publishing snapshots and releases.

## Dependencies and models

Discuss new dependencies in an issue before adding them. A dependency change
must include its upstream source, pinned or resolved version, license, and reason
for inclusion. Model changes must also update [docs/models.md](docs/models.md)
with source, size, runtime requirements, license evidence, and checksum/revision
strategy.

## Security issues

Do not open a public issue for a vulnerability or accidental data exposure.
Follow [SECURITY.md](SECURITY.md) instead.
