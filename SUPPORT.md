# Community Support

Resonant Community Edition is maintained on a best-effort basis without a support
SLA. The source repository does not include a hosted AI service, authentication
deployment, email delivery, public share-link service, signing identity, or update
channel.

## Where to ask

- Use GitHub Discussions for setup questions, ideas, and general troubleshooting
  when available.
- Use GitHub Issues for reproducible Community Edition bugs and focused feature
  requests.
- Use the private process in [SECURITY.md](SECURITY.md) for vulnerabilities or
  accidental exposure of sensitive information.

Before filing a bug, test the latest default branch and search existing reports.
Include the commit or version, Mac model, macOS and Xcode versions, selected speech
model, relevant settings, exact steps, and a minimal synthetic example.

Never upload real recordings, transcripts, clipboard content, contact/calendar
data, local databases, API keys, crash reports containing personal data, or
production service configuration. Redact usernames and home-directory paths from
logs.

## Support boundaries

The community can usually help with source builds, local packaging, local
transcription, and reproducible bugs in this repository. A downstream distributor
owns support for its binary, notarization, branding, telemetry, hosted services,
and update feed. Questions about a third-party model or service may need to go to
that upstream provider.

Apple Silicon and macOS 14 or newer are the supported baseline. Qwen3-ASR
requires macOS 15 or newer. Intel Macs are not supported.

See [README.md](README.md) for build instructions and
[docs/privacy-and-data.md](docs/privacy-and-data.md) before sharing diagnostics.
