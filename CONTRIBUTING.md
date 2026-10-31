# Contributing to Library GUI

Thanks for taking a look. Bug reports, ideas and pull requests are all welcome. If you're not sure whether something is a good idea, open an issue first and we can talk it through.

## Reporting a bug

Please include:

- your device and KOReader version (☰ → Help → About),
- what you did, what you expected, and what happened,
- a screenshot if it's a display problem,
- the relevant lines from `koreader/crash.log` if KOReader crashed. Lines from this plugin start with `Library`.

## Running the tests

The tests are plain Lua and need only LuaJIT (or Lua 5.1). From the repository root:

```sh
luajit spec/run.lua      # or: make test
```

It prints one dot per test and a summary such as `272 passed, 0 failed`. KOReader's own `luajit` binary works too: `make test LUA=/path/to/koreader/luajit`.

Each spec file is listed in `spec/run.lua`. If you add a new one, add it to that list.

## Testing in the KOReader emulator

Most changes should be checked on screen as well as in the tests.

Screenshots, from the repository root:

```sh
tools/emulator/shoot.sh smoke     # one shot of the library, written to emulator-out/smoke/
tools/emulator/shoot.sh footer    # footer "3 / 12", the Go to page dialog, and a long-press jump when the plugin has one
```

The first run downloads KOReader v2026.07.1 (Linux x86_64) into `~/.cache/koreader-library-gui/`, checks its sha256, and leaves the binary out of git. It seeds a public-domain library, copies `library.koplugin` into a temporary home, and runs KOReader under Xvfb at the Kindle Colorsoft size (1264×1680, 300 dpi). `EMU_OUT` sets the output directory. `EMU_PLUGIN` points at a different `library.koplugin` when the tree you want to shoot is not the one that contains the script. See [tools/emulator/README.md](tools/emulator/README.md).

To poke at the emulator by hand:

1. Build or download the KOReader desktop emulator (see KOReader's [building guide](https://github.com/koreader/koreader/blob/master/doc/Building.md)), or install the Linux AppImage.
2. Copy or symlink `library.koplugin` into the emulator's plugins folder (`~/.config/koreader/plugins/` for the AppImage).
3. To get a test library, generate public-domain dummy books:

   ```sh
   python3 tools/make_dummy_library.py --out ~/dummy-library --count 200
   ```

4. Start the emulator at a Kindle-like screen size:

   ```sh
   EMULATE_READER_W=1264 EMULATE_READER_H=1680 EMULATE_READER_DPI=300 ./kodev run
   ```

`tools/librarybench.koplugin` is a benchmark plugin for the emulator (see [bench/RESULTS.md](bench/RESULTS.md)). It's for development only and should never be installed on a device.

If you can, also try your change on a real e-reader. E-ink refresh, speed and touch behave differently from the emulator.

## Code you can't copy

Library GUI is MIT licensed. Code under the GPL or AGPL can't be copied into it, even a few lines. That includes:

- **KOReader** itself (AGPL-3.0), including its built-in plugins,
- **Project: Title** (AGPL-3.0),
- **SimpleUI** (GPL-3.0),
- **ZenOS** (GPL-3.0),
- any other GPL or AGPL plugin.

Using KOReader's APIs (requiring its modules and widgets) is fine; that's how every plugin works. Looking at how another project solves something and writing your own version from the idea is fine too. Copying or closely translating their code is not. If you're unsure, ask in the issue or PR.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each PR to one change, and explain what it does and why in the description. Screenshots help for anything visual.
3. Add or update specs for any behaviour you change, and make sure `luajit spec/run.lua` passes.
4. Only the files in `library.koplugin/` go on the device (9 right now). Keep runtime code in that folder, and if you add a file there, add it to `FILES` in the `Makefile`.
5. Don't commit books, `.sdr` folders, KOReader settings or anything from your own device. `.gitignore` blocks the usual ones.
6. Open the PR. I'll review it, may ask for changes, and merge it when it's ready.

## Building the release zip

```sh
make zip VERSION=0.3.0    # dist/library-gui-0.3.0.zip and dist/SHA256SUMS
```
