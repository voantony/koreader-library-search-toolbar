# Agent notes

## Screenshots

When a change is visual, take the screenshots with the in-repo emulator and attach the PNGs. This is how screenshots are produced in this repository.

```sh
tools/emulator/shoot.sh smoke
tools/emulator/shoot.sh footer
```

The first run downloads KOReader v2026.07.1 into `~/.cache/koreader-library-gui/` (the binary is not committed) and writes PNGs to `emulator-out/<scenario>/`. Set `EMU_PLUGIN` to another checkout's `library.koplugin` to shoot that tree, and `EMU_OUT` to choose the output directory. Details are in `tools/emulator/README.md`.
