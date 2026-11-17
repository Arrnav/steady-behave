# Contributing

Thanks for taking a look. Bug reports, detection improvements and support for more Macs are all welcome.

## Getting started

```bash
git clone https://github.com/arrnav/steady-behave.git
cd steady-behave
./build.sh --selftest
./build.sh --run
```

You need an Apple Silicon Mac with macOS 14 or later and the Xcode Command Line Tools. There are no dependencies to install.

## Ground rules

- **No network code.** The app must never make a connection. CI fails if networking symbols show up in the binary.
- **Apple frameworks only.** No packages, pods or bundled models.
- **Camera data stays on the Mac.** Never commit clips, models, stats or screenshots that show a face.
- **Plain, neutral wording** in everything the app shows: short sentences, real numbers, no exclamation marks, nothing that judges the user.

## Before opening a pull request

```bash
./build.sh --selftest
swiftlint lint
shellcheck build.sh
```

- Keep each file focused, and add a short comment only where the logic isn't obvious.
- Add a self-test check for new detection or storage logic where it can run without a camera.
- If you change a non-obvious behaviour, add a line to [docs/DESIGN.md](docs/DESIGN.md).
- Debug mode (⌃⌥D) shows what each detector sees, and `--show debug,settings` opens windows at launch for checking layouts.

## Reporting bugs

Please include your Mac model, macOS version and, if detection is involved, the text from **Copy Log** in debug mode. Don't attach clips or screenshots that show your face unless you are comfortable sharing them publicly.
