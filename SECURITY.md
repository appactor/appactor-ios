# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in the AppActor iOS SDK, please report it responsibly.

**Please do NOT open a public GitHub issue for security vulnerabilities.**

Instead, email us at **security@appactor.com** with:

- A description of the vulnerability
- Steps to reproduce the issue
- The potential impact
- Any suggested fixes (optional)

We will acknowledge your report within **48 hours** and aim to provide a fix or mitigation within **7 business days**, depending on severity.

## Scope

This policy applies to the AppActor iOS SDK source code in this repository.

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | Yes       |

## Security Practices

- All API communication uses HTTPS with TLS 1.2+
- Response integrity is verified using Ed25519 signatures
- Identity data is stored in the app sandbox via UserDefaults
- No credentials or API keys are hardcoded in the SDK
- Debug logging redacts sensitive identifiers
