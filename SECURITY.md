# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature when it is enabled for this repository. Do not include customer data, credentials, private URLs, tenant identifiers, or production screenshots in a public issue.

## Sensitive data

This public repository must contain fictional demonstration data only.

- Keep real configuration in `config.local.json` or another ignored file.
- Never commit generated scripts, CSV exports, build artifacts, environment files, certificates, or credential material.
- Treat compiled installers as recoverable archives. A configuration embedded during packaging is not secret.
- Before publishing a release, build with the default `config.example.json` and inspect the staged `default_config.json` under `dist\release\app\StuffOpener\`.

Stuff Opener relies on existing interactive browser and PowerShell sessions. API keys, passwords, and long-lived access tokens should not be stored in this project.

## Generated PowerShell

Generated scripts can modify directory, identity, licensing, and mailbox state. Review the generated file, test it in a lab, and use an account with the minimum required privileges before running it in a production environment.
