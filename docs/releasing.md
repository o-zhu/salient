# Releasing

[`script/release.sh`](../script/release.sh) separates local builds from
anything that contacts Apple. It builds and releases **Salient**, the reader.

| Command | Signs | Uploads to Apple | Output |
|---|---|---|---|
| `check` | No | No | A read-only check of Xcode, `notarytool`, `stapler`, and your signing identities |
| `preview` | Ad-hoc | No | `dist/Salient-<version>-development.dmg` and a `.sha256` file. **Not for distribution.** |
| `prepare` | Developer ID | No | A signed `dist/Salient.app` and a notarization ZIP |
| `notarize` | Developer ID | **Yes** | A notarized, stapled `dist/Salient-<version>.dmg` and a `.sha256` file |

## Steps

```sh
SALIENT_APP_VERSION=1.2.3 ./script/release.sh preview      # local test DMG only

export SALIENT_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export SALIENT_APP_VERSION=1.2.3
./script/release.sh check
./script/release.sh prepare     # signs; does not upload
./script/release.sh notarize    # sends the ZIP and DMG to Apple
```

- `notarize` sends the app to Apple. Run it only for a release that has been
  approved for signed distribution.
- `notarize` can resume. It saves Apple's submission ID next to the artifact
  before waiting for a result. If the wait is interrupted, run `notarize`
  again. It reuses the saved submission instead of uploading again.
- Optional variables:
  - `SALIENT_TEAM_ID`: checks that the signature belongs to your team.
  - `SALIENT_NOTARY_PROFILE`: the name of a `notarytool` Keychain profile.
    The default is `SalientNotary`.

## Credentials

Store your notary credentials in your own login Keychain:

```sh
xcrun notarytool store-credentials SalientNotary   # prompts locally
```

Never commit passwords, API keys, certificates, private keys, or notary
submission logs. Public CI never signs or uploads to Apple.

## Before publishing

- Rebuild Salient from a clean clone.
- Run the tests listed in [building.md](building.md#tests).
- Keep the Pocket attributions and third-party notices inside the app.
  `prepare` and `notarize` check the bundled assets automatically.
- When you update Pocket, follow
  [Native/PocketWorker/UPSTREAM.md](../Native/PocketWorker/UPSTREAM.md).
