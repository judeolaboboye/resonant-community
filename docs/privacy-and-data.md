# Privacy and Local Data

This document describes Resonant Community Edition's intended behavior when built
without operator service or telemetry configuration. A downstream distributor that
changes configuration or code must publish disclosures matching its build.

## Default network behavior

An unconfigured Community build has no hosted processing or authentication
endpoint. Network activity is limited to actions that the user explicitly starts:

| Destination | Trigger | Data sent |
|---|---|---|
| Hugging Face model repositories | The user downloads a speech/helper model | Standard HTTP request metadata; no transcript or recording |
| User-configured meeting webhook | The user enables a webhook and a meeting completes | The configured meeting payload, signed when a secret is set |
| Loopback HTTP API | The user enables the local API and a local client connects | Requested local records over `127.0.0.1`, protected by a bearer token |

Analytics, crash reporting, automatic updates, cloud processing, workspace upload,
and hosted authentication remain inactive without both user opt-in and distributor
configuration. A distributor-provided service can change the network boundary; ask
that distributor for its privacy policy.

## Data stored on the Mac

Depending on enabled features, Resonant can retain:

- Delivered and raw dictation text, timestamps, modes, and delivery status
- Meeting transcripts, memos, journal entries, dictionary terms, and preferences
- Audio for dictations, memos, or meetings when the matching retention setting is on
- Application, window, browser, focused-field, clipboard, notification, and visible
  text context when context and ambient capture are on
- Recovery audio and metadata while an interrupted capture is being recovered
- Downloaded model weights and compiled Core ML artifacts
- API tokens, webhook secrets, or authentication material in macOS Keychain

Primary Community Edition user content is stored under
`~/Library/Application Support/Resonant Community/`,
including SwiftData, stream, archive, audio, and recovery files. Preferences use
the build's macOS defaults suite. Models use FluidAudio/Core ML cache locations.
Development packages use `Resonant Community Dev`; downstream forks derive a
separate directory from their bundle identifier.

Application-support files are not end-to-end encrypted by Resonant. Protect the
macOS account, enable FileVault, secure backups, and treat copied application data
as sensitive.

The default history retention period is 90 days. Audio retention, meeting audio,
context metadata, and ambient capture start off. Temporary recovery audio may
exist after an interrupted recording even when long-term audio retention is off;
the recovery flow removes or resolves orphaned files on a later launch.

## Ambient context

Ambient context is optional and disabled by default. When enabled alongside
context metadata, it can periodically inspect the frontmost application and may
collect window titles, browser URLs/tabs, focused-field or visible text, clipboard
text, code-file information, notification title/body, and communication recipient
metadata.

Password-manager bundle identifiers and sensitive-looking values are filtered,
but no detector is perfect. Exclude sensitive applications and keep ambient
capture off if you work with credentials, health, legal, financial, customer, or
other confidential information. Enabling Accessibility or Screen Recording at the
macOS level does not itself enable ambient capture inside Resonant.

## MCP and local API

MCP and the local API are disabled by default. Enabling MCP can modify supported
agent configuration files so those agents can read Resonant's local data. Review
each client before registration and disable the integration to remove it.

The HTTP API listens only on loopback and requires the bearer token stored in
`~/.resonant-community/api.token` for the production Community identity (development
and downstream identities use their own derived names). Keep that file private.
Localhost is a security boundary,
not a guarantee: software running as your macOS user may be able to reach local
services or read user-owned files.

## Permissions

- **Microphone:** records your voice after a dictation or meeting action.
- **Accessibility/Input Monitoring:** detects the global hotkey and delivers text
  to the frontmost app; it can also enable richer context when you opt in.
- **Screen/System Audio Recording:** captures system audio for meetings.
- **Contacts:** reads names locally to improve name handling.
- **Calendar:** optionally supplies meeting hints and titles.
- **Network client:** downloads models and supports explicitly configured services,
  telemetry, updates, or webhooks.

Revoke permissions in macOS System Settings → Privacy & Security. Revocation can
disable the corresponding feature but does not delete content already stored.

## Review, deletion, and uninstall

Use Resonant's history and meeting deletion controls and storage/retention settings
first. Confirm deletions before removing data because they may include recordings
that cannot be recovered.

To fully remove an installation, quit the app, revoke its macOS
permissions, remove its Application Support data, remove its defaults domain and
Keychain items if desired, remove the matching derived local-API directory, and
undo that build's MCP client registrations. Model caches may be shared with other FluidAudio applications, so
inspect them rather than deleting them indiscriminately.

If you believe data crossed a boundary without consent, preserve only the minimum
synthetic reproduction information and follow [SECURITY.md](../SECURITY.md).
