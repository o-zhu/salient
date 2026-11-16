# Contributing

Thanks for your interest in Salient. Bug reports, fixes, and focused
improvements are welcome.

## Getting started

1. Follow [docs/building.md](docs/building.md) to build and run the app.
2. Keep each change small. When you change behavior, add or update tests.
3. Before opening a pull request, run:

   ```sh
   swift test
   python3 -m unittest discover -s script/tests
   python3 script/check_public_source.py --staged
   ```

   If you change `Native/PocketWorker` or packaging, also run
   `./script/build_pocket_runtime.sh --link-debug` and
   `./script/build_and_run.sh build`.

4. In your pull request, say what you changed, how you tested it, and anything
   you could not test.

## Ground rules

- **Stay local.** Do not add telemetry, analytics, or cloud inference. Any
  network access must start from a clear user action. Document it in
  [docs/privacy.md](docs/privacy.md).
- **Keep the reader focused.** This repository contains one public app.
  Keep private applications and their features outside it. Preserve the
  reader's product name and bundle ID for existing installations.
- **No private or large data.** Never commit study content, screenshots,
  recordings, model weights, logs, or credentials. Model files are downloaded
  into `.build/`, which Git ignores. Do not use Git LFS.
- **Respect licenses.** If you add a dependency, include its license notice.
  Keep the existing Pocket and CC BY 4.0 attributions. See
  [THIRD_PARTY.md](THIRD_PARTY.md).
- **Style.** Follow the nearby code and the repository's `.swift-format`.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
