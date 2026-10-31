# Library GUI for KOReader

Library GUI (`library.koplugin`) is a KOReader plugin that replaces the file browser with a library screen that looks and works more like the Kindle's own home screen: book covers with reading progress, a search bar with the clock and battery at the top, tabs for Books, Collections, Authors and Series, the menu and Resume buttons in the footer, and a Controls panel you pull down from the top-right corner.

It sits alongside KOReader's file browser, History and Collections. It never moves or renames your books, and closing it takes you back to the normal file browser.

<p align="center"><img src="docs/screenshots/16-books-header-footer.png" width="420" alt="Books tab: search bar, clock and battery on the top row, Continue reading row of covers, and the menu, Resume, sort label and page number in the footer"></p>

## Screenshots

| Compact · 2 columns | Compact with dates | Recently opened |
|---|---|---|
| ![Compact view in two columns, sorted by Last read](docs/screenshots/02-compact-2-columns.png) | ![Compact view sorted by Last read, with dates](docs/screenshots/03-compact.png) | ![The top row switched to Recently opened](docs/screenshots/20-recently-opened.png) |

| Authors | Series | Search with typos |
|---|---|---|
| ![Authors tab as a list with a book count for each author](docs/screenshots/04-authors.png) | ![Series tab with covers and progress for each series](docs/screenshots/05-series.png) | !["wutherng hieghts" still finds Wuthering Heights](docs/screenshots/06-search-typos.png) |

| Sort from the footer | The ☰ menu | Controls panel |
|---|---|---|
| ![Sort picker opened from the footer label](docs/screenshots/07-sort-picker.png) | ![The ☰ menu: sort, view, Barely started, Start with Library, Show clock, Show battery and Use KOReader's keyboard](docs/screenshots/18-menu-settings.png) | ![Controls panel with brightness and warmth sliders and Light, Night mode, Refresh, Wi-Fi, Rotate and Cover sleep buttons](docs/screenshots/09-controls-panel.png) |

| Genres | Inside a genre | Go to page |
|---|---|---|
| ![Collections tab switched to Genres, with a cover and book count for each genre](docs/screenshots/10-genres.png) | ![The Mystery & Thriller genre opened, showing its books](docs/screenshots/11-genre-books.png) | ![Go to page dialog opened from the page number in the footer](docs/screenshots/19-go-to-page.png) |

| Book details | A book with no description | Library in the reader menu |
|---|---|---|
| ![Book details card with cover, progress, Continue, genre chips and the Calibre description](docs/screenshots/13-details-card.png) | ![Book details card for a book with no description](docs/screenshots/14-details-card-none.png) | ![KOReader's reader menu with Library and Book details at the top, and the Library tab icon on the left](docs/screenshots/12-reader-menu-library.png) |

| Clock and battery off |
|---|
| <img src="docs/screenshots/17-books-status-off.png" width="300" alt="The Books tab with the clock and battery turned off"> |

The screenshots were taken in the KOReader emulator at the Kindle Colorsoft's screen size (1264×1680), with a library of public-domain books and generated covers, on v0.3.4.

## Features

- **Search** is the top row of every tab. It filters as you type and searches whatever the tab shows: books on Books, author names on Authors, series on Series, collection names on Collections, and only that shelf's books inside an author, series or collection. Small typos, missing accents and punctuation are forgiven, so `charlote bronte` finds Charlotte Brontë (**Typo-tolerant search**, on by default). **Use KOReader's keyboard** (off unless you turn it on, in the ☰ menu) opens KOReader's own text box for the search instead of the Library keyboard.
- **Clock and battery** beside the search bar. **Show clock** and **Show battery** are in the ☰ menu, both on unless you turn one off. The clock changes when the Library redraws, and once a minute while it is on screen. If the device does not report a battery percentage, that part is left out.
- **Footer**: the ☰ menu and Resume buttons, the book count and sort (*201 books · Last read ▾*), and the page number with arrows. Resume opens the book you read last; long-press it to see which book that is.
- **Filters**: All, Unread, Reading, Barely started and Finished, each with a count. A book you opened but did not start (still on the cover, title page or contents) stays **Unread**. **Barely started** means past the contents but not through the first chapter; **Reading** means at least a chapter in. The Library learns a book's chapters from its table of contents the next time you open it. Until then, or without a table of contents, it goes by percentage: the first 2 % or 3 pages are Unread, then Barely started below 5, 10, 20 or 25 % (pick the cut-off in the ☰ menu).
- **Sort** by Author, Title, Date added, Last read or Series. Tap the label in the footer to change it, or use the ☰ menu.
- **Views**: Small, Medium or Large covers, List, Compact, and Compact · 2 columns. The view, sort and filter are remembered for each tab and each author, series or collection you open (**Reset default layout** in the ☰ menu forgets them).
- **Dates**: sorted by Last read or Date added, each book shows its date (*3h ago*, *Yesterday*, *12 Oct*). Under Last read, books you've never opened follow in author order.
- **Continue reading**: a row of the books you are in the middle of, at the top of the Books tab. Tap one and it opens on the page you were on. **Show Recently opened** switches the row to the last five books you opened instead, finished ones included.
- **Collections and Series** as tabs. A series lists its books in order, and swiping past its last page opens the next series.
- **Genres**: a Collections | Genres switch at the top of the Collections tab. Genres are grouped from each book's keywords and Calibre tags, with a count and progress for each.
- **Book details**: long-press a book, or choose **Book details** in the reader's ☰ menu, for its cover, progress, series, genres, collections and the Calibre description. Tap the author, series, a genre or a collection to open that shelf. Along the bottom: **Mark finished** (or **Mark unread**), **More** for KOReader's usual book menu, and **Close**.
- **Library from inside a book**: **Library** is the first item in the reader's ☰ menu, and there is a Library tab (book icon) in the reader's top menu bar. Both save your place, close the book and open the Library.
- **Go to page**: tap the page number in the footer (*1 / 50*) and type a page.
- **Cover sleep screen**: one toggle to show the cover of the book you read last on the sleep screen. Turning it off puts back the sleep screen you had.
- **Controls panel**: swipe down from the top-right corner for Brightness and Warmth sliders and buttons for Light, Night mode, Refresh (clears e-ink ghosting), Wi-Fi, Rotate, Cover sleep and Exit (asks first, then quits KOReader). Anything your device doesn't have is left out.
- **Simple reader menu**: while reading, tap the top of the page for a small menu: Library, Contents, Go to page, Search, Font & size, Light, Bookmark, Book details, Exit, and **More…** for KOReader's full reader menu. Swiping down from the top still opens the full menu. Turn it off in ☰ → Library → **Simple reader menu**.
- **Start with Library**: open the Library instead of the file browser when KOReader starts, and come back to it after closing a book.
- **Covers without other plugins.** Library GUI extracts covers itself in the background. If Project: Title or Cover browser is enabled, it reuses their cover cache.
- **Gestures**: Open Library, Search library, Resume last book, Rescan library, and Next / Previous in series can be assigned under *Taps and gestures*.

## Install

1. Download **[library-gui-0.3.8.zip](https://github.com/voantony/koreader-library-gui/releases/download/v0.3.8/library-gui-0.3.8.zip)** from the [latest release](https://github.com/voantony/koreader-library-gui/releases/latest).
2. Unzip it. You get a folder called `library.koplugin`.
3. Copy the `library.koplugin` folder into `koreader/plugins/` on your device, so you end up with `koreader/plugins/library.koplugin/main.lua`.
   - On a Kindle that is `/mnt/us/koreader/plugins/` (it shows as `koreader/plugins` when the Kindle is plugged in).
   - On a Mac, newer Kindles such as the Colorsoft connect over MTP and don't show up in Finder on their own. [Mount Kindle](https://github.com/voantony/kindle-mtp-mount) (a small menu-bar app from the same author) shows the Kindle as a drive in Finder, and [OpenMTP](https://openmtp.ganeshrvel.com/) also works for copying the folder across.
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`. PocketBook: `/mnt/ext1/applications/koreader/plugins/`. Android: `koreader/plugins/` on internal storage.
4. Restart KOReader (☰ → Exit → Restart KOReader).
5. Open ☰ → **Library** → **Open Library**. To open it every time KOReader starts, tick **Open Library at startup** in the same menu.

To update, replace the `library.koplugin` folder with the new one and restart KOReader.

If **Library** is missing from the menu, check ☰ → Tools → More tools → Plugin management, where it is listed as Library GUI.

### For developers and Mac users

[`tools/kpush/`](tools/kpush/) is an optional command-line tool for macOS that copies the plugin files to a Kindle over MTP in one go, without Calibre. It was written for the Kindle Colorsoft, whose USB connection tends to drop after each libmtp command. Version 6 can also list (`ls`) and copy files off the Kindle (`pull`). See its [README](tools/kpush/README.md) for how to build and use it. You don't need it to install the plugin.

## Compatibility

- Tested on a **Kindle Colorsoft** running KOReader v2026.07.1, and in the KOReader desktop emulator.
- Needs KOReader v2025.04 or newer.
- It should work on other devices that run KOReader (Kobo, PocketBook, Android), but I haven't tried them. If you do, please open an issue and say how it went.

## Uninstall

Delete `koreader/plugins/library.koplugin/` and restart KOReader. To remove everything it made, also delete `koreader/settings/library_index.lua` and the `koreader/cache/library_covers/` folder.

## About this project

This is the first thing I've developed in public. I built it with Grok Bot, and I'm happy to take any suggestions and feedback: [open an issue](https://github.com/voantony/koreader-library-gui/issues) for bugs, ideas or anything that looks off on your device.

Ideas came from [Project: Title](https://github.com/joshuacant/ProjectTitle), [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) and ZenOS. Only ideas: no code was copied from them or from KOReader, and Library GUI is written from scratch under the MIT licence.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the tests and the emulator. `tools/emulator/shoot.sh smoke` runs the plugin in headless KOReader and writes a PNG to `emulator-out/smoke/`. Benchmarks are in [bench/RESULTS.md](bench/RESULTS.md).

## Support

If this saves you time and you'd like to say thanks, tips are welcome. Always optional.

**Venmo:** [@Antony-Vo](https://venmo.com/u/Antony-Vo) (US)

**Crypto:**

| Coin | Address |
| --- | --- |
| Bitcoin (BTC) | `bc1pug8q2ceda7f3p30ezptg2mnz4khg9d5v9fd6p454qqs20zdyzw8qnuf8cx` |
| Ethereum (ETH, and tokens on EVM chains) | `0xf9439c4330427E45017A3c4454137474DEbB3E36` |
| Monero (XMR) | `84iCefzmu82Ha9eHPyRpsKPLcuEkBxBRxZm1FSx72T5S1CULgQkabtf9K8Lwxf6NFaLvUoJPqAqvL1EgaSvR7rMbJhKupfr` |

Please double-check the address before you send. Crypto transfers can't be reversed.

## Licence

[MIT](LICENSE)
