# Contributing

Thanks for your interest! The project is at an early stage; feel free to open an issue to
discuss ideas first.

## License of contributions

By submitting a pull request you agree that your contribution is licensed under the
[MIT License](LICENSE) of this project.

## Dependency policy

The project must stay redistributable under MIT:

- ✅ MIT, BSD, ISC, Zlib, Apache-2.0 (keep the NOTICE file).
- ⚠️ LGPL: only as an **optional, dynamically loaded** component. Discuss it in an issue
  first.
- ❌ GPL/AGPL, "non-commercial" licenses, code without a license.

Add every new third-party component to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Reusing code from other projects

- **Open-source code under a compatible license** (e.g. [Blue Bloom](https://github.com/jonathanlu98/bluebloom),
  MIT) may be reused. Keep its copyright notice in the file header and mention it in
  THIRD_PARTY_NOTICES.md.
- **Proprietary software** (third-party apps, Apple frameworks, firmware): never submit its
  code, binaries or disassembly. Behaviour observed on your own machine (XPC traces, logs,
  packet captures) and public specifications are fine.

## Hardware testing

CodecBlue talks to `bluetoothd` through private interfaces. When you change channel or
session handling, test with real headphones and describe the result in the pull request:
Mac model, macOS version (build number), headphones and firmware.
