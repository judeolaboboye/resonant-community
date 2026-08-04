# Security Policy

Resonant handles microphone audio, transcripts, clipboard and application context
when enabled, and macOS Accessibility permissions. Please report vulnerabilities
privately.

## Supported versions

Security fixes target the latest Community Edition release and the default branch.
Older releases and downstream forks may no longer receive fixes. A downstream
distributor is responsible for its own binary, services, update feed, and support
policy.

## Reporting a vulnerability

Use this repository's **Security → Report a vulnerability** form to open a private
security advisory. If private reporting is unavailable, open a minimal issue asking
a maintainer for a private contact channel. Do not include exploit details, user
data, credentials, recordings, transcripts, or production endpoints in that issue.

Include, where safe:

- Affected version or commit and macOS version
- Required settings and permissions
- Reproduction steps using synthetic data
- Expected and observed behavior
- Impact and whether data crosses a process or network boundary
- A proposed patch, if you have one

Please allow maintainers time to reproduce and prepare a coordinated fix before
public disclosure. This project does not currently offer a bug bounty or guarantee
a response deadline.

## High-risk areas

Reports are especially useful around:

- Microphone and system-audio capture lifecycle
- Accessibility, Input Monitoring, paste, and global event taps
- Ambient context, clipboard, notification, browser, and focused-field redaction
- Local history, retained audio, deletion, and recovery files
- MCP configuration and the loopback HTTP API authentication boundary
- Webhooks and optional hosted-service requests
- Model and application update integrity
- Package signing, entitlements, and dynamic library loading

## Safe research

Test only on systems and data you own or are authorized to use. Do not access
another user's information, degrade shared services, persist access, or publish
sensitive material. Stop and report if testing exposes real user data.

General support requests belong in the channels described by [SUPPORT.md](SUPPORT.md).
