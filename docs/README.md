# olcOS documentation

Start with the [product overview](../README.md), then choose a guide:

| Guide | Audience |
|---|---|
| [Setup and connection modes](setup.md) | Installing, adding a connection, preparing your VPS and understanding routing |
| [Build and verification](build.md) | macOS/Xcode setup, framework generation, tests and release artifacts |
| [Architecture](architecture.md) | Data paths, SSH control plane, lifecycle ownership and trust boundaries |
| [URI and subscription formats](uri.md) | Connection sharing, import behavior and secret handling |
| [Diagnostic messages](diagnostic-messages.md) | Looking up emitted codes and reporting a reproducible failure |
| [Security policy](../SECURITY.md) | Private reporting and security limitations |
| [Contributing](../CONTRIBUTING.md) | Pull requests, style and verification evidence |
| [Technical contract](../AGENTS.md) | Essential constraints for repository changes |

The public product name is **olcOS**, release **2.0 (build 2)**, with tag
`v2.0.2`. Internal targets and URI schemes retain their compatible `olcrtc`
names; this is not a separate protocol. [Project](../project.yml) · [URI implementation](../App/Models/OlcrtcURI.swift).

The header artwork in `assets/olcos-preview.png` (Russian) and
`assets/olcos-preview-en.png` (English) is a **UI concept preview**,
not a native screenshot, benchmark or test result. It is drawn from the
current screens and localized strings of the app, including the beam and
stone-wall hero; the HTML source and render script live in `assets/src/`.
Android, Windows and macOS are plans only.

The underlying WebRTC core is the separate
[openlibrecommunity/olcrtc project](https://github.com/openlibrecommunity/olcrtc).
Follow its documentation for protocol/server details, and use this repository's
guides for iOS-specific behavior and limitations.
