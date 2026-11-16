# Security policy

## Reporting a vulnerability

Please report security issues privately. Do not open a public issue. Use
GitHub's private vulnerability reporting: on
[o-zhu/salient](https://github.com/o-zhu/salient), go to **Security**, then
**Report a vulnerability**.

Include the affected version or commit, the steps to reproduce the issue, and
its impact. Do not include personal data or study content you do not want to
share.

## Scope

Areas of particular interest:

- Browser automation: Apple Events and the bundled JavaScript run in the front
  tab.
- The Pocket worker process and how it checks model files.
- Downloads of models and runtimes: pinning, checksums, and storage locations.
- Packaging and signing scripts.

Salient is a source preview with no published notarized release yet, so fixes go into the
`main` branch.
