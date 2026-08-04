# Resonant Community Edition

Resonant is a local-first macOS dictation and meeting-transcription app. Hold a
hotkey, speak, and release to paste text into the app you are using. Speech
recognition and the deterministic cleanup pipeline run on your Mac.

Created by [sourcetms.com](https://sourcetms.com) ·
[@sourcetms on X](https://x.com/sourcetms)

This repository is the Community Edition. It is intended to build and remain
useful without a Resonant account or Resonant-operated infrastructure.

> **Project status:** early community release. Read the privacy and model notes
> before distributing a binary or enabling optional integrations.

## What works standalone

- System-wide push-to-talk dictation and paste
- Local Core ML transcription with Parakeet or Qwen3-ASR
- On-device punctuation, formatting, filler removal, and vocabulary handling
- Local meeting recording and transcription
- Local history, memos, journal, dictionary, and per-app formatting preferences
- Optional local HTTP API, MCP registration, and HMAC-signed meeting webhooks

Model weights are downloaded separately and have their own licenses and system
requirements. See [docs/models.md](docs/models.md) before selecting or
redistributing a model.

## What is not included

Some source modules support hosted AI enrichment, including generated summaries
and cloud cleanup. The compatible server, authentication deployment, email
delivery, and public sharing service are not included in this repository. An
unconfigured Community build has no hosted-service endpoint and does not expose
those features.

A distributor can connect a compatible service at package time, but then becomes
responsible for that service, its privacy policy, security, user consent, and
operating costs. Bring-your-own-key LLM support is not currently available.

## Safety defaults

In an unconfigured Community build, these features start disabled:

- Analytics and crash reporting
- Cloud processing and workspace upload
- Ambient context, clipboard, browser-tab, notification, and focused-field capture
- Saving dictation audio (passive voice enrollment is not included)
- Meeting recording and meeting-audio retention
- MCP registration and the local HTTP API
- Meeting webhooks and automatic email footers
- Automatic update checks

Enabling a local feature can still expose sensitive information. For example,
ambient context may read visible text and clipboard content, and MCP clients can
query locally retained dictations. Review [docs/privacy-and-data.md](docs/privacy-and-data.md)
before opting in.

## Requirements

- Apple Silicon Mac
- macOS 14 or newer
- Xcode 16 or newer, or matching Xcode Command Line Tools
- Several gigabytes of free disk space for dependencies, builds, and models

Qwen3-ASR requires macOS 15 or newer. Parakeet is the default and supports
macOS 14. Cohere source integration remains in the tree, but Community builds do
not offer that model while the derivative model's redistribution terms remain
ambiguous.

## Build and run

Clone the repository, then:

```sh
swift build
swift test
scripts/package_app.sh debug
scripts/run_packaged_app.sh debug
```

`swift build` compiles the Swift package. `scripts/package_app.sh` assembles the
runnable `Resonant Community.app`, embeds its frameworks, and uses an Apple Development
identity when available or ad-hoc signing for a local build.

To exercise the production-mode Community package without a private signing
identity or telemetry account:

```sh
RESONANT_DISTRIBUTION=community \
RESONANT_RELEASE_BUILD=1 \
RESONANT_CODESIGN_IDENTITY=- \
scripts/package_app.sh release
```

That artifact is suitable for local verification, not broad distribution:
public downloads should be signed with your own Developer ID and notarized by
your Apple developer account.

The first model download is a separate network operation. The app should show
the selected model and approximate size before downloading it.

### macOS permissions

Resonant asks for permissions as features need them:

| Permission | Why it is used |
|---|---|
| Microphone | Record your voice for dictation and meetings |
| Accessibility and Input Monitoring | Listen for the global hotkey and paste into the frontmost app |
| Screen/System Audio Recording | Capture the other side of a meeting when meeting recording is enabled |
| Contacts | Improve recognition of names, on device |
| Calendar | Optionally detect and title meetings |

The app is not sandboxed and disables library validation because it uses global
event taps, Accessibility APIs, and system-audio capture. That makes dependency,
update, and signing hygiene especially important. See [SECURITY.md](SECURITY.md).

## Package-time configuration

No operational keys or service endpoints belong in source control. The package
scripts read optional values from the environment; maintainers may keep local
values in the ignored `.env.local` file.

| Variable | Purpose | Unset behavior |
|---|---|---|
| `RESONANT_DISTRIBUTION` | Select `community` or a downstream `official` flavor | `community` |
| `RESONANT_APP_ENV` | Select development or production defaults for that flavor | Development for debug, production for release |
| `RESONANT_CONVEX_CLOUD_URL` | Compatible hosted processing API | Hosted features unavailable |
| `RESONANT_AUTH_BASE_URL` | Compatible authentication service | Sign-in unavailable |
| `RESONANT_POSTHOG_API_KEY` | Distributor-owned PostHog project | Analytics client does not start |
| `RESONANT_SENTRY_DSN` | Distributor-owned Sentry project | Crash reporting does not start |
| `RESONANT_SPARKLE_FEED_URL` | Distributor-owned Sparkle appcast | Update checks remain disabled |
| `RESONANT_SPARKLE_PUBLIC_ED_KEY` | Public key for that appcast | Update checks remain disabled |
| `RESONANT_BUNDLE_IDENTIFIER` | Bundle identity for a downstream build | Community development identity |
| `RESONANT_CALLBACK_SCHEME` | URL callback scheme for that identity | Community development scheme |
| `RESONANT_ALLOW_COMMUNITY_REMOTE_CONFIG` | Deliberately allow a downstream Community package to embed the caller's remote-service configuration | Remote configuration is scrubbed |

Hosted service configuration must be supplied as a coherent set; do not point a
fork at somebody else's production service. A distributable release also needs
its own bundle identifier, Developer ID signing identity, notarization, Sparkle
keypair/feed if updates are enabled, and privacy disclosures.

Local data, API token paths, and MCP registration names derive from the bundle
identifier and development/production environment. Use a bundle identifier you
control for a fork; this prevents it from reading or deleting another edition's
workspace.

## Public snapshot

Maintainers can export the reviewed public tree from a committed ref:

```sh
scripts/export_public_snapshot.sh --ref HEAD /tmp/resonant-public
```

Or include current tracked and untracked, non-ignored work without modifying the
real Git index:

```sh
scripts/export_public_snapshot.sh --working-tree /tmp/resonant-public
```

The exporter removes internal release operations and rejects known internal
identifiers and broken local Markdown links. Run a full history-aware secret
scan before publishing the resulting repository.

## Contributing and support

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Community
support expectations are in [SUPPORT.md](SUPPORT.md), and security reports belong
through the private process in [SECURITY.md](SECURITY.md).

Please do not attach recordings, transcripts, clipboard content, database files,
or API keys to a public issue.

## License

Resonant source code is available under the [MIT License](LICENSE). Dependencies,
vendored code, and downloaded models retain their own licenses. See [NOTICE](NOTICE)
and [docs/models.md](docs/models.md).
