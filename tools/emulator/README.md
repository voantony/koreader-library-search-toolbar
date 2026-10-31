# KOReader emulator

Headless screenshots of `library.koplugin` on Linux, at the Kindle Colorsoft size (1264×1680, 300 dpi).

```sh
tools/emulator/shoot.sh smoke
tools/emulator/shoot.sh footer
```

`smoke` writes `emulator-out/smoke/smoke-library.png`.

`footer` writes:

- `footer-page-label.png` — the footer page label `3 / 12`
- `footer-go-to-page.png` — the Go to page dialog opened from that label
- `footer-jump-last.png` — the last page after a long-press on the next arrow, when this build of the plugin has that long-press

KOReader itself is not committed. `tools/emulator/setup.sh` downloads the official Linux x86_64 tarball of **v2026.07.1** from the [KOReader releases](https://github.com/koreader/koreader/releases/tag/v2026.07.1), checks the sha256 pinned in `config.sh`, and extracts it under `~/.cache/koreader-library-gui/`. A public-domain dummy library (from `tools/make_dummy_library.py`) is cached in the same place.

## Requirements

- Linux x86_64, glibc 2.35 or newer (the v2026.07.1 tarball)
- `curl`, `tar`, `Xvfb`
- Python 3 and Pillow (`pip install pillow`)

This KOReader build's SDL dummy framebuffer is fixed at 600×800 and ignores `EMULATE_READER_W` / `EMULATE_READER_H`. `shoot.sh` starts Xvfb and asks SDL for the Colorsoft size instead.

## Options

| Variable | Meaning |
| --- | --- |
| `EMU_OUT` | Directory for PNGs and logs. Default `emulator-out/<scenario>/`. |
| `EMU_PLUGIN` | `library.koplugin` to copy. Default is the one in this checkout. |
| `EMU_COUNT` | How many dummy books to seed. Default 200. |
| `EMU_TIMEOUT` | Seconds before KOReader is stopped. Default 180. |
| `EMU_HOME` | Keep the KOReader home at this path instead of a temp dir. |
| `KOREADER_CACHE` | Cache directory. Default `~/.cache/koreader-library-gui`. |

`shoot.sh footer` exits successfully without `footer-jump-last.png` only when the probe log says the next arrow has no long-press. A long-press that does not move the page is a failure.

The shot is taken as soon as the page is up. Cover thumbnails are filled in afterwards, in the background, so a PNG may still show the grey placeholder covers. The footer, dialogs and gestures are already on screen.

Logs next to the PNGs: `probe.log`, `koreader.log`, and `crash.log` if KOReader wrote one.
