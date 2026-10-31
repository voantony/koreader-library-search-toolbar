--[[--
Library: a cover-grid library view for KOReader.

Always-visible search bar, cover grid with reading progress, Recent sort,
collections, authors and series, and status filters. Book metadata comes from
calibre's metadata.calibre, the cover browser's database (Project: Title or
coverbrowser), or the book sidecars; the index is cached on disk. Covers come
from the plugin's own thumbnails (librarycovers.lua), or from the cover
browser's database when one of those plugins is loaded.

@module koplugin.library
--]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local Core = require("librarycore")
local Index = require("libraryindex")
local Timing = require("librarytiming")
local _ = require("gettext")
local T = ffiUtil.template

local SETTINGS_KEY = "library_plugin"

local DEFAULTS = {
    root = nil,              -- nil: the KOReader home folder
    sort = "recent",
    columns = 4,
    view = "grid",           -- "grid" | "list"
    show_continue = true,    -- Continue reading strip on the Books tab
    top_row = "continue",    -- what that strip shows: "continue" | "recent" (Recently opened)
    max_depth = 10,
    show_hidden = false,
    start_with_library = false, -- open the Library instead of the file browser
    return_to_library = true,   -- when the Library is the home screen, come back to it after reading
    debounce_ms = 150,
    barely_threshold = 0.10,    -- "Barely started" when chapters are unknown: below this fraction
    series_skip_finished = true, -- Next in series skips books already finished
    reader_tab = true,          -- a Library tab (book icon) in the reader's top menu bar
    rounded_keyboard = true,    -- "Rounded keyboard in search": softer keys for the search bar only
    use_koreader_keyboard = false, -- "Use KOReader's keyboard": stock InputDialog for the search bar
    show_clock = true,          -- clock beside the search bar
    show_battery = true,        -- battery percentage beside the search bar
    fuzzy_search = true,        -- "Typo-tolerant search": accents ignored, small typos forgiven
    search_suggestions = true,  -- "Word suggestions": words from the library above the search keyboard
    timing_log = false,         -- "Timing log": how long opening, page turns, filters and search take (librarytiming.lua)
    remember_views = true,      -- each shelf (collection, author, series, tab) remembers its layout, sort, filter
    controls_panel = true,      -- swipe down from the Library's top-right corner: light, warmth, toggles
    simple_reader_menu = true,  -- tapping the top of a page opens our small menu; More… opens KOReader's
    bezel_lift = true,          -- Colorsoft: lift KOReader's status bar above the bezel (librarybezel.lua)
    -- bezel_prev: the status bar's bottom margin from before we lifted it
    -- view_memory: { [key] = { view =, sort =, filter =, t = } }, see Core.viewKey
    -- sleep_cover_prev: KOReader's sleep screen settings from before
    -- "Sleep screen: cover of last book" was turned on (restored when turned off)
}

local SORT_NAMES = {
    recent = _("Last read"),
    title  = _("Title"),
    author = _("Author"),
    series = _("Series"),
    added  = _("Date added"),
    size   = _("Size"),
}

local VIEW_NAMES = {
    small = _("Small covers"),
    medium = _("Medium covers"),
    large = _("Large covers"),
    list = _("List"),
    compact = _("Compact"),
    compact2 = _("Compact · 2 columns"),
}

local Library = WidgetContainer:extend{
    name = "library",
    is_doc_only = false,
}

-- Shared between FileManager and ReaderUI instances of the plugin, so the
-- index survives opening and closing books.
local shared = {
    index = nil,
    started = false,      -- the start-up Library has been shown once
    reopen = false,       -- a book was opened from the Library
    view = nil,
    controls = nil,       -- the open Controls panel
    after_book = nil,     -- "show" / "search": open the Library once the book has closed
}
Library.shared = shared

local function collate(a, b)
    return ffiUtil.strcoll(a, b)
end
Library.collate = collate

function Library:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self.ui.document then self:hookReaderMenuTap() end

    -- In the file browser: show the Library at start-up, or again after reading.
    -- (file_chooser is only created after plugins, so test for the reader instead.)
    if not self.ui.document and shared.after_book then
        -- Library was asked for from inside a book, which has now closed.
        local focus_search = shared.after_book == "search"
        shared.after_book = nil
        shared.started = true
        shared.reopen = false
        UIManager:nextTick(function() self:onShowLibrary(focus_search) end)
    elseif not self.ui.document and self.settings.start_with_library then
        local first = not shared.started
        local back_from_book = shared.reopen and self.settings.return_to_library
        if first or back_from_book then
            shared.started = true
            shared.reopen = false
            UIManager:nextTick(function() self:onShowLibrary() end)
        end
    end
end

function Library:onDispatcherRegisterActions()
    Dispatcher:registerAction("library_show",
        { category = "none", event = "ShowLibrary", title = _("Library"), general = true })
    Dispatcher:registerAction("library_search",
        { category = "none", event = "SearchLibrary", title = _("Search library"), general = true })
    Dispatcher:registerAction("library_resume",
        { category = "none", event = "LibraryResume", title = _("Resume last book (Library)"), general = true })
    Dispatcher:registerAction("library_rescan",
        { category = "none", event = "RescanLibrary", title = _("Rescan library"), general = true, separator = true })
    Dispatcher:registerAction("library_next_in_series",
        { category = "none", event = "LibraryNextInSeries", title = _("Next in series"), reader = true })
    Dispatcher:registerAction("library_prev_in_series",
        { category = "none", event = "LibraryPrevInSeries", title = _("Previous in series"), reader = true, separator = true })
end

function Library:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function Library:getRoot()
    local root = self.settings.root
    if root and lfs.attributes(root, "mode") == "directory" then
        return root
    end
    return filemanagerutil.getHomeFolder() or Device.home_dir or "/"
end

function Library:sortName(mode)
    return SORT_NAMES[mode] or mode
end

----------------------------------------------------------------------------
-- Data sources
----------------------------------------------------------------------------

--- The cover browser's BookInfoManager (Project: Title's, or coverbrowser's).
function Library:getBIM()
    local bim = package.loaded["bookinfomanager"]
    if bim == nil then
        local ok, mod = pcall(require, "bookinfomanager")
        bim = ok and mod or false
        if not ok then package.loaded["bookinfomanager"] = nil end
    end
    if type(bim) == "table" and bim.getBookInfo then return bim end
    return nil
end

local function loadCalibre(path)
    local rapidjson = require("rapidjson")
    local load = rapidjson.load_calibre or rapidjson.load
    return load(path)
end

-- load_calibre keeps the fields the grid needs and drops comments. The
-- details card wants the blurb, so it reads the whole file, and only then.
local function loadCalibreFull(path)
    local rapidjson = require("rapidjson")
    if rapidjson.load then return rapidjson.load(path) end
    return loadCalibre(path)
end

--- KOReader's own folders, never scanned for books.
function Library:getSkipDirs()
    local dirs = {}
    local ok, data_dir = pcall(DataStorage.getDataDir, DataStorage)
    if ok and data_dir then table.insert(dirs, data_dir) end
    local ok2, full = pcall(DataStorage.getFullDataDir, DataStorage)
    if ok2 and full then table.insert(dirs, full) end
    local cwd = lfs.currentdir and lfs.currentdir()
    if cwd and lfs.attributes(cwd .. "/reader.lua", "mode") == "file" then
        table.insert(dirs, cwd) -- the install folder (KOReader runs from it)
    end
    return dirs
end

function Library:getIndex()
    local root = self:getRoot()
    if shared.index and shared.index.opts.root == root
            and shared.index.opts.show_hidden == self.settings.show_hidden then
        return shared.index
    end
    local DocSettings = require("docsettings")
    local ReadHistory = require("readhistory")
    shared.index = Index.new{
        root = root,
        show_hidden = self.settings.show_hidden,
        max_depth = self.settings.max_depth,
        cache_file = DataStorage:getSettingsDir() .. "/library_index.lua",
        fs = lfs,
        is_book = Core.makeIsBook(function(path) return DocumentRegistry:hasProvider(path) end),
        skip_dirs = self:getSkipDirs(),
        lower = util.stringLower,
        bim = self:getBIM(),
        docsettings = DocSettings,
        history = ReadHistory,
        calibre_load = loadCalibre,
        calibre_load_full = loadCalibreFull,
        extra_calibre_dirs = { G_reader_settings:readSetting("inbox_dir") },
        clock = function() return require("ui/time").to_s(require("ui/time").now()) end,
    }
    shared.index.needs_build = true
    return shared.index
end

--- Build or refresh the index. `force` ignores the disk cache.
function Library:ensureIndex(force)
    local index = self:getIndex()
    force = force or index.force_next
    if index.needs_build or force then
        index.force_next = nil
        local ok, err = pcall(index.build, index, force)
        if not ok then
            logger.warn("Library: index build failed:", err)
        end
        index.needs_build = false
        logger.info("Library: index", index.stats)
    end
    return index
end

function Library:getBooks()
    return self:ensureIndex().books
end

--- Collections as groups: { kind="collections", name=, books= }.
function Library:getCollections()
    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or not ReadCollection.coll then return {} end
    if ReadCollection._read then pcall(ReadCollection._read, ReadCollection) end
    local index = self:ensureIndex()
    local names = {}
    for name in pairs(ReadCollection.coll) do table.insert(names, name) end
    local settings = ReadCollection.coll_settings or {}
    table.sort(names, function(a, b)
        local oa = settings[a] and settings[a].order or math.huge
        local ob = settings[b] and settings[b].order or math.huge
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    local groups = {}
    for _i, name in ipairs(names) do
        local items = ReadCollection.getOrderedCollection and ReadCollection:getOrderedCollection(name) or {}
        local books = {}
        for _, item in ipairs(items) do
            local book = item.file and index:recordFor(item.file)
            if book then table.insert(books, book) end
        end
        local title = name
        if name == ReadCollection.default_collection_name then
            local fmc = self.ui.collections
            title = fmc and fmc.getCollectionTitle and fmc:getCollectionTitle(name) or _("Favorites")
        end
        table.insert(groups, { kind = "collections", name = title, books = books })
    end
    return groups
end

----------------------------------------------------------------------------
-- Showing the Library
----------------------------------------------------------------------------

function Library:newView()
    local LibraryView = require("libraryview")
    local prefs = Core.viewPrefs(self.settings, "books")
    return LibraryView:new{
        plugin = self,
        cols = self.settings.columns,
        view_mode = Core.viewMode(self.settings.view),
        filter = prefs and prefs.filter or "all",
        show_continue = self.settings.show_continue ~= false,
        top_row = Core.topRow(self.settings.top_row),
        sort = self.settings.sort,
        debounce_s = (self.settings.debounce_ms or 150) / 1000,
        barely_threshold = Core.barelyThreshold(self.settings.barely_threshold),
        rounded_keyboard = Core.roundedKeyboard(self.settings),
        use_koreader_keyboard = Core.useKoreaderKeyboard(self.settings),
        show_clock = Core.showClock(self.settings),
        show_battery = Core.showBattery(self.settings),
        fuzzy_search = Core.fuzzySearch(self.settings),
        search_suggestions = self.settings.search_suggestions ~= false,
        timing = self:timer(),
    }
end

--- The "Timing log" (librarytiming.lua): one per run, remade when it is
-- turned on or off. Lines go to library_timing.log in KOReader's folder
-- (on a Kindle, koreader/library_timing.log on the USB drive).
function Library:timingLogPath()
    local dir = DataStorage:getDataDir()
    return (type(dir) == "string" and dir or ".") .. "/library_timing.log"
end

function Library:timer()
    local on = self.settings.timing_log == true
    if shared.timer and shared.timer.enabled == on then return shared.timer end
    local time = require("ui/time")
    local path = self:timingLogPath()
    shared.timer = Timing.new{
        enabled = on,
        clock = function() return time.to_s(time.now()) end,
        write = function(line)
            logger.info("Library timing:", line)
            local f = io.open(path, "a")
            if f then f:write(line, "\n"); f:close() end
        end,
    }
    return shared.timer
end

----------------------------------------------------------------------------
-- Per-shelf memory: layout, sort and filter (see Core.viewPrefs)
----------------------------------------------------------------------------

--- What `key` should show, or nil when "Remember layout for each shelf" is off.
function Library:viewPrefs(key)
    return Core.viewPrefs(self.settings, key)
end

--- A layout, sort or filter was changed at `key`. With the memory off, the
-- layout and sort are global (as before) and the filter is not kept.
function Library:rememberViewPref(key, field, value)
    local changed
    if Core.rememberViews(self.settings) then
        changed = Core.rememberViewPref(self.settings, key, field, value)
    elseif field ~= "filter" and self.settings[field] ~= value then
        self.settings[field] = value
        changed = true
    end
    if changed then self:saveSettings() end
end

function Library:resetViewPrefs(key)
    Core.resetViewPrefs(self.settings, key)
    self:saveSettings()
end

----------------------------------------------------------------------------
-- Series navigation and resume
----------------------------------------------------------------------------

--- The open book's record and its series, in reading order.
function Library:currentSeries()
    local doc = self.ui.document
    if not doc or not doc.file then return nil end
    local index = self:ensureIndex()
    local current = index.by_path[doc.file] or index:recordFor(doc.file)
    if not current or not current.series then return nil, nil, current end
    local books = Core.seriesBooks(index.books, current.series, collate)
    local found = false
    for _, b in ipairs(books) do if b.path == current.path then found = true; break end end
    if not found then -- opened from outside the Library folder
        table.insert(books, current)
        books = Core.seriesOrder(books, collate)
    end
    return books, current.series, current
end

--- The book Next (dir = 1) or Previous (dir = -1) in series would open.
function Library:seriesTarget(dir)
    local books, _series, current = self:currentSeries()
    if not books then return nil, current end
    return Core.seriesNeighbour(books, current, dir,
        { skip_finished = self.settings.series_skip_finished ~= false }), current
end

--- "3 · Title" for menus and messages.
function Library:seriesLabel(book)
    local n = Core.seriesNumber(book.series_index)
    return (n and (n .. " · ") or "") .. (book.title or book.name)
end

function Library:openInSeries(dir)
    if not self.ui.document then
        UIManager:show(InfoMessage:new{ text = _("Open a book first."), timeout = 2 })
        return true
    end
    local target, current = self:seriesTarget(dir)
    if not target then
        local text
        if not (current and current.series) then
            text = _("This book is not part of a series.")
        elseif dir > 0 then
            text = T(_("“%1” is the last book of %2."), current.title or current.name, current.series)
        else
            text = T(_("“%1” is the first book of %2."), current.title or current.name, current.series)
        end
        UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
        return true
    end
    logger.info("Library: series", dir > 0 and "next" or "previous", "->", target.path)
    filemanagerutil.openFile(self.ui, target.path)
    return true
end

function Library:onLibraryNextInSeries() return self:openInSeries(1) end
function Library:onLibraryPrevInSeries() return self:openInSeries(-1) end

--- Open the most recently read book that is not finished, at its saved position.
function Library:onLibraryResume()
    local book = Core.resumeBook(self:getBooks())
    if not book then
        UIManager:show(InfoMessage:new{ text = _("No book in progress."), timeout = 2 })
        return true
    end
    if self.ui.document and self.ui.document.file == book.path then return true end
    self:openBook(book.path, shared.view)
    return true
end

function Library:onShowLibrary(focus_search)
    if shared.view then
        local shelf = shared.open_shelf
        shared.open_shelf = nil
        if shelf and shared.view.openNamedShelf then
            shared.view:openNamedShelf(shelf.kind, shelf.name)
        elseif focus_search then
            shared.view:focusSearch()
        end
        return true
    end
    if self.ui.document then return self:leaveBook(focus_search) end
    local timer = self:timer()
    timer:start("open", true)
    local index = self:getIndex()
    local first = index.needs_build
    local function show()
        local view = self:newView()
        shared.view = view
        UIManager:show(view)
        if focus_search then UIManager:nextTick(function() view:focusSearch() end) end
    end
    if index.needs_build then
        local msg = InfoMessage:new{ text = _("Loading library…") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        self:ensureIndex()
        UIManager:close(msg)
    else
        -- Cheap refresh of reading state and history order.
        self:refreshReadingState()
    end
    timer:arm("open", first and "first" or nil)
    local shelf = shared.open_shelf
    shared.open_shelf = nil
    -- back from a book: where the Library was (a shelf or search asked for wins)
    local spot = self:takeReturnSpot()
    show()
    if shelf and shared.view and shared.view.openNamedShelf then
        shared.view:openNamedShelf(shelf.kind, shelf.name)
    elseif spot and not focus_search and shared.view and shared.view.restoreReturn then
        shared.view:restoreReturn(spot)
    end
    return true
end

--- From inside a book: close it the way KOReader's file browser button does
-- (progress, settings and history saved), then open the Library over the
-- file browser. The file browser's copy of the plugin picks up `after_book`.
function Library:leaveBook(focus_search)
    local ui = self.ui
    local file = ui.document.file
    shared.after_book = focus_search and "search" or "show"
    ui:onClose()
    ui:showFileManager(file)
    if shared.after_book then
        -- the file browser was already there, so no new plugin copy ran init
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        local lib = FileManager and FileManager.instance and FileManager.instance.library
        shared.after_book = nil
        if lib then UIManager:nextTick(function() lib:onShowLibrary(focus_search) end) end
    end
    return true
end

function Library:onSearchLibrary()
    return self:onShowLibrary(true)
end

function Library:onRescanLibrary()
    self:ensureIndex(true)
    local index = shared.index
    UIManager:show(InfoMessage:new{
        text = T(_("Library rescanned: %1 books."), #index.books),
        timeout = 2,
    })
    if shared.view then shared.view:refreshData() end
    return true
end

function Library:onViewClosed(view)
    if shared.view == view then shared.view = nil end
end

----------------------------------------------------------------------------
-- Controls panel (librarycontrols.lua, loaded on first use)
----------------------------------------------------------------------------

function Library:controlsEnabled()
    return self.settings.controls_panel ~= false and Device:isTouchDevice()
end

function Library:openControls()
    if shared.controls or not self:controlsEnabled() then return false end
    local Controls = require("librarycontrols")
    local panel = Controls:new{ plugin = self }
    shared.controls = panel
    UIManager:show(panel, "ui")
    return true
end

function Library:onControlsClosed(panel)
    if shared.controls == panel then shared.controls = nil end
end

--- Send a KOReader event (night mode, rotation) to the file browser or reader.
function Library:sendUIEvent(ev)
    if self.ui and self.ui.handleEvent then
        self.ui:handleEvent(ev)
    else
        UIManager:broadcastEvent(ev)
    end
end

--- The Library plugin of whatever is on screen now (the file browser is
-- rebuilt when it rotates).
local function currentLibrary(fallback)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and ui.library or fallback
end

--- Rotate 90° clockwise and bring the Library back where it was: it is laid
-- out for one screen size, so it is rebuilt.
function Library:rotateLibrary()
    if self.ui and self.ui.document then
        -- in a book (Controls opened from the simple reader menu): just turn
        -- the page; the Library is not on screen
        self:sendUIEvent(Event:new("IterateRotation"))
        return
    end
    local view = shared.view
    local state = view and view:placeState()
    if view then UIManager:close(view) end
    self:sendUIEvent(Event:new("IterateRotation"))
    UIManager:nextTick(function()
        local lib = currentLibrary(self)
        lib:onShowLibrary()
        if state and shared.view then shared.view:restorePlace(state) end
    end)
end

function Library:controlsMenu()
    return {
        text = _("Controls panel (swipe down from top-right corner)"),
        help_text = _("In the Library, swipe down from the top-right corner for brightness, warmth, Wi-Fi, night mode, the cover sleep screen, rotation and sleep. Swipe up or tap outside the panel to close it. Controls your device does not have are left out."),
        enabled_func = function() return Device:isTouchDevice() end,
        checked_func = function() return self.settings.controls_panel ~= false end,
        callback = function()
            self.settings.controls_panel = self.settings.controls_panel == false
            self:saveSettings()
        end,
    }
end

--- Re-read sidecars that changed and history order (cheap, mtime-based).
function Library:refreshReadingState()
    local index = shared.index
    if not index or index.needs_build then return end
    -- A rebuild with a warm cache only stats files and reads changed sidecars.
    local ok, err = pcall(index.build, index, false)
    if not ok then logger.warn("Library: refresh failed:", err) end
end

--- This KOReader run, so a saved return spot is never used after a restart.
local has_ffi, ffi = pcall(require, "ffi")
local function runId()
    if shared.run_id then return shared.run_id end
    local ok, pid = pcall(function()
        if not has_ffi then error("no ffi") end
        pcall(ffi.cdef, "int getpid(void);")
        return tonumber(ffi.C.getpid())
    end)
    shared.run_id = ok and pid or tostring(shared)
    return shared.run_id
end
Library.runId = runId

--- Remember where the Library was, to come back there after the book.
-- Kept in memory and in the settings (the file browser and this plugin
-- are re-created when a book closes).
function Library:saveReturnSpot(view, path)
    if not (view and view.returnState) then return end
    local spot = Core.returnSpot(view:returnState(path), runId())
    shared.return_spot = spot
    self.settings.return_spot = spot
    self:saveSettings()
end

--- The spot to come back to, once. Nil after a fresh start.
function Library:takeReturnSpot()
    local spot = shared.return_spot
    if not Core.returnSpotUsable(spot, runId()) then spot = self.settings.return_spot end
    shared.return_spot = nil
    if self.settings.return_spot ~= nil then
        self.settings.return_spot = nil
        self:saveSettings()
    end
    if Core.returnSpotUsable(spot, runId()) then return spot end
    return nil
end

function Library:openBook(path, view)
    shared.reopen = true
    self:saveReturnSpot(view, path)
    filemanagerutil.openFile(self.ui, path, function()
        if view then UIManager:close(view) end
    end)
end

--- The dialog a long-press used to open: reading status, Show folder,
-- Book information and Open. The details card keeps it on More.
function Library:showBookDialog(book, view)
    local BookList = require("ui/widget/booklist")
    local file = book.path
    local dialog
    local function close() UIManager:close(dialog) end
    local function after_status_change()
        close()
        if BookList.resetBookInfoCache then BookList.resetBookInfoCache(file) end
        if shared.index then shared.index:refreshBook(file) end
        if view then view:refreshData() end
    end
    local been_opened = BookList.hasBookBeenOpened(file)
    local doc_settings_or_file = been_opened and BookList.getDocSettings(file) or file
    local bim = self:getBIM()
    local props = bim and bim.getDocProps and bim:getDocProps(file) or nil
    local buttons = {
        filemanagerutil.genStatusButtonsRow(doc_settings_or_file, after_status_change),
        {},
        {
            filemanagerutil.genShowFolderButton(file, function()
                close()
                if view then UIManager:close(view) end
            end),
            filemanagerutil.genBookInformationButton(doc_settings_or_file, props, close),
        },
        {
            {
                text = _("Open"),
                callback = function()
                    close()
                    self:openBook(file, view)
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = book.title .. (book.authors and book.authors[1] and ("\n" .. book.authors[1]) or ""),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Plain blurb for the details card. Calibre, the sidecar and book info come
-- first; the file itself is opened only when those have nothing. Not called
-- while the grid is built.
function Library:fileDescription(path)
    local doc = self.ui and self.ui.document
    if doc and doc.file == path then
        -- The book is already open: read its props, don't open it a second time.
        if doc.getProps then
            local ok, props = pcall(doc.getProps, doc)
            if ok and type(props) == "table" then return props.description end
        end
        return nil
    end
    if not DocumentRegistry.openDocument then return nil end
    local ok, opened = pcall(DocumentRegistry.openDocument, DocumentRegistry, path)
    if not ok or not opened then return nil end
    local props
    pcall(function() props = opened:getProps() end)
    pcall(function() opened:close() end)
    if type(props) == "table" then return props.description end
    return nil
end

function Library:loadDescription(book)
    if not book or type(book.path) ~= "string" then return nil end
    local candidates = {}
    local index = shared.index
    if index and index.descriptionCandidates then
        local ok, list = pcall(index.descriptionCandidates, index, book.path)
        if ok and type(list) == "table" then candidates = list end
    end
    local file_text
    if not Core.firstDescription(candidates) then
        local ok, raw = pcall(self.fileDescription, self, book.path)
        if ok then file_text = raw end
    end
    return Core.descriptionFrom(candidates, file_text)
end

function Library:collectionNames(path)
    local ok, groups = pcall(self.getCollections, self)
    if not ok or type(groups) ~= "table" then return {} end
    return Core.collectionNames(path, groups)
end

--- The open book, from the index when we have it.
function Library:currentBook()
    local doc = self.ui and self.ui.document
    if not doc or type(doc.file) ~= "string" then return nil end
    local index = shared.index
    if not index then
        local ok, idx = pcall(self.ensureIndex, self)
        if ok then index = idx end
    end
    if index then
        local book = index.by_path and index.by_path[doc.file]
        if not book and index.recordFor then
            local ok, rec = pcall(index.recordFor, index, doc.file)
            if ok then book = rec end
        end
        if book then return book end
    end
    local name = doc.file:match("[^/]+$") or doc.file
    return { path = doc.file, name = name, title = Core.stem(name), status = "reading" }
end

--- Write status the way the file browser's status buttons do, then refresh.
function Library:setReadingStatus(book, status, view)
    if not book or type(book.path) ~= "string" then return end
    local file = book.path
    local BookList = require("ui/widget/booklist")
    local handle = file
    local summary = { status = status }
    if BookList.hasBookBeenOpened and BookList.hasBookBeenOpened(file) and BookList.getDocSettings then
        handle = BookList.getDocSettings(file)
        if handle.readSetting then
            local existing = handle:readSetting("summary")
            if type(existing) == "table" then
                existing.status = status
                summary = existing
            end
        end
    end
    filemanagerutil.saveSummary(handle, summary)
    if BookList.setBookInfoCacheProperty then
        BookList.setBookInfoCacheProperty(file, "status", status)
    end
    if BookList.resetBookInfoCache then BookList.resetBookInfoCache(file) end
    book.status = status
    if shared.index and shared.index.refreshBook then
        pcall(shared.index.refreshBook, shared.index, file)
    end
    if view and view.refreshData then view:refreshData() end
end

--- Open a Genres, Collections, Series or Authors shelf. From inside a book
-- this closes it and opens the Library on that shelf.
function Library:openShelf(kind, name, view)
    if view and view.openNamedShelf then
        view:openNamedShelf(kind, name)
        return
    end
    if shared.view and shared.view.openNamedShelf then
        shared.view:openNamedShelf(kind, name)
        return
    end
    shared.open_shelf = { kind = kind, name = name }
    self:onShowLibrary()
end

--- The read-only details card. `view` is the Library when opened from a
-- long-press; from the reader menu it is nil and Continue only closes.
function Library:showBookDetails(book, view, opts)
    if not book or type(book.path) ~= "string" then return end
    opts = opts or {}
    local already_open = opts.already_open and true or false
    if not already_open and not view and self.ui and self.ui.document
            and self.ui.document.file == book.path then
        already_open = true
    end
    local time_left = Core.knownTimeLeft(book)
    if shared.index and shared.index.knownTimeLeft then
        local ok, t = pcall(shared.index.knownTimeLeft, shared.index, book.path, book)
        if ok and t then time_left = t end
    end
    local info = {
        title = book.title or book.name or "",
        authors = Core.authorNames(book),
        series = book.series,
        series_line = Core.seriesLine(book),
        genres = Core.splitKeywords(book.keywords),
        collections = {},
        time_left = time_left,
        description = self:loadDescription(book),
    }
    -- A name whose shelf would hold only this book is plain text, not a link.
    local all = (view and view.all_books) or (shared.index and shared.index.books)
    local function low(x) return util.stringLower and util.stringLower(x) or x:lower() end
    info.author_links = Core.authorLinks(info.authors, all, self.collate, low)
    info.series_link = Core.seriesLink(info.series, all, self.collate, low)
    info.genre_links = Core.genreLinks(info.genres, all, self.collate, low)
    local ok_groups, colls = pcall(self.getCollections, self)
    if ok_groups and type(colls) == "table" then
        info.collections = Core.collectionNames(book.path, colls)
        info.collection_links = Core.shelfLinks(info.collections, colls, low)
    end
    local Details = require("librarydetails")
    local Tiles = require("librarytile")
    local Covers = require("librarycovers")
    local card
    card = Details:new{
        book = book,
        info = info,
        already_open = already_open,
        covers = (view and view.covers) or { store = Covers.getStore(), bim = self:getBIM() },
        cover_cache = (view and view.cover_cache) or Tiles.newCoverCache(4),
        on_continue = function()
            UIManager:close(card)
            if Core.detailsPrimaryDismisses(already_open) then return end
            UIManager:nextTick(function() self:openBook(book.path, view) end)
        end,
        on_status = function()
            local action = Core.detailsStatusAction(book)
            self:setReadingStatus(book, action == "mark_unread" and "new" or "complete", view)
            if card.setStatusLabel then card:setStatusLabel() end
            if card.setProgress then card:setProgress() end
        end,
        on_close = function()
            UIManager:close(card)
        end,
        on_more = function()
            UIManager:close(card)
            UIManager:nextTick(function() self:showBookDialog(book, view) end)
        end,
        on_shelf = function(kind, name)
            UIManager:close(card)
            UIManager:nextTick(function() self:openShelf(kind, name, view) end)
        end,
    }
    UIManager:show(card)
    return card
end

--- The sort picker from the Library's footer label ("202 books · Last read ▾").
function Library:showSortPicker(view)
    local dialog
    local buttons = {}
    for _, mode in ipairs(Core.SORT_MENU) do
        table.insert(buttons, { {
            text = (view.sort == mode and "\u{2713} " or "") .. SORT_NAMES[mode],
            callback = function()
                UIManager:close(dialog)
                if view.sort ~= mode then view:resort(mode) end -- remembered for this tab or shelf
            end,
        } })
    end
    dialog = ButtonDialog:new{ title = _("Sort by"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
    return dialog
end

--- Go to page: a number box opened from the footer's "63 / 72".
function Library:showPageJump(view)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    local function go()
        local n = tonumber(dialog:getInputText())
        -- Empty or not a number: leave the box open. Out of range is clamped
        -- by goToPage. Cancel is the way out without moving.
        if not n or n ~= n then return end
        UIManager:close(dialog)
        view:goToPage(math.floor(n))
    end
    dialog = InputDialog:new{
        title = _("Go to page"),
        input = "",
        input_hint = T(_("1 – %1"), view.pages),
        input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Go"), is_enter_default = true, callback = go },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return dialog
end

--- The ☰ menu inside the Library view.
function Library:showLibraryMenu(view)
    local dialog
    local function close() UIManager:close(dialog) end
    local sort_row, col_row = {}, {}
    for _, mode in ipairs(Core.SORT_MENU) do
        table.insert(sort_row, {
            text = (view.sort == mode and "✓ " or "") .. SORT_NAMES[mode],
            callback = function()
                close()
                view:resort(mode) -- remembered for this shelf (or the default, on the Books tab)
            end,
        })
    end
    -- View: Small, Medium, Large covers (columns, for every shelf), List, Compact.
    -- (two rows: the cover sizes, then the text views)
    local view_row, text_row = {}, {}
    local pick = Core.viewPick(view.view_mode, self.settings.columns)
    for _i, p in ipairs(Core.VIEW_PICKER) do
        table.insert(p.columns and view_row or text_row, {
            text = (pick == p.id and "✓ " or "") .. VIEW_NAMES[p.id],
            callback = function()
                close()
                if p.columns and self.settings.columns ~= p.columns then
                    self.settings.columns = p.columns
                    self:saveSettings()
                    view:setColumns(p.columns)
                end
                view:setViewMode(p.view)
            end,
        })
    end
    table.insert(col_row, {
        text = (self.settings.show_continue ~= false and "✓ " or "")
            .. (Core.topRow(self.settings.top_row) == "recent" and _("Show Recently opened") or _("Show Continue reading")),
        callback = function()
            close()
            self.settings.show_continue = self.settings.show_continue == false
            self:saveSettings()
            view:setShowContinue(self.settings.show_continue)
        end,
    })
    local barely_row = {}
    local th = Core.barelyThreshold(self.settings.barely_threshold)
    for _i, t in ipairs(Core.BARELY_THRESHOLDS) do
        table.insert(barely_row, {
            text = (th == t and "✓ " or "") .. T(_("Barely started < %1 %"), math.floor(t * 100 + 0.5)),
            callback = function()
                close()
                self.settings.barely_threshold = t
                self:saveSettings()
                view:setBarelyThreshold(t)
            end,
        })
    end
    local buttons = { sort_row, view_row, text_row, col_row, barely_row }
    -- Each shelf remembers its own layout, sort and filter: offer to forget them.
    local remember = Core.rememberViews(self.settings)
    if remember then
        local place = view:placeName()
        local on_books = view:viewKey() == "books"
        table.insert(buttons, {
            {
                text = on_books and _("\u{21BA} Reset default layout (covers, Last read, All)")
                    or T(_("\u{21BA} Reset “%1” to default"), place),
                enabled = view:hasRemembered(),
                callback = function()
                    close()
                    view:resetRemembered()
                end,
            },
        })
    end
    local title = _("Library")
    if remember and view:viewKey() ~= "books" then
        title = T(_("Library · %1"), view:placeName())
            .. (view:hasRemembered() and ("\n" .. _("Layout, sort and filter remembered here")) or "")
    end
    table.insert(buttons, {
        {
            text = (self.settings.start_with_library and "✓ " or "") .. _("Start with Library"),
            callback = function()
                close()
                self.settings.start_with_library = not self.settings.start_with_library
                self:saveSettings()
            end,
        },
        {
            text = _("Rescan"),
            callback = function()
                close()
                self:onRescanLibrary()
            end,
        },
    })
    table.insert(buttons, {
        {
            text = (Core.showClock(self.settings) and "✓ " or "") .. _("Show clock"),
            callback = function()
                close()
                self.settings.show_clock = not Core.showClock(self.settings)
                self:saveSettings()
                if view.setShowClock then view:setShowClock(Core.showClock(self.settings)) end
            end,
        },
        {
            text = (Core.showBattery(self.settings) and "✓ " or "") .. _("Show battery"),
            callback = function()
                close()
                self.settings.show_battery = not Core.showBattery(self.settings)
                self:saveSettings()
                if view.setShowBattery then view:setShowBattery(Core.showBattery(self.settings)) end
            end,
        },
    })
    table.insert(buttons, {
        {
            text = (Core.useKoreaderKeyboard(self.settings) and "✓ " or "") .. _("Use KOReader's keyboard"),
            callback = function()
                close()
                self.settings.use_koreader_keyboard = not Core.useKoreaderKeyboard(self.settings)
                self:saveSettings()
                if view.setUseKoreaderKeyboard then
                    view:setUseKoreaderKeyboard(Core.useKoreaderKeyboard(self.settings))
                end
            end,
        },
    })
    -- Last item: leave the Library for the file browser (there is no X).
    table.insert(buttons, {
        {
            text = "\u{2715} " .. _("Close Library"),
            callback = function()
                close()
                UIManager:close(view)
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

----------------------------------------------------------------------------
-- Main menu (file browser and reader)
----------------------------------------------------------------------------

--- Next / Previous in series entries for the reader's Library menu.
function Library:seriesMenuItems()
    local function item(dir)
        return {
            text_func = function()
                local ok, target = pcall(self.seriesTarget, self, dir)
                local name = dir > 0 and _("Next in series") or _("Previous in series")
                if ok and target then return name .. ": " .. self:seriesLabel(target) end
                return name
            end,
            enabled_func = function()
                local ok, target = pcall(self.seriesTarget, self, dir)
                return ok and target ~= nil
            end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:openInSeries(dir)
            end,
            separator = dir < 0,
        }
    end
    return item(1), item(-1)
end

function Library:barelyMenu()
    local items = {}
    for _i, t in ipairs(Core.BARELY_THRESHOLDS) do
        table.insert(items, {
            text = T(_("Below %1 %"), math.floor(t * 100 + 0.5)),
            radio = true,
            checked_func = function() return Core.barelyThreshold(self.settings.barely_threshold) == t end,
            callback = function()
                self.settings.barely_threshold = t
                self:saveSettings()
                if shared.view then shared.view:setBarelyThreshold(t) end
            end,
        })
    end
    return {
        text_func = function()
            return T(_("Barely started: below %1 %"),
                math.floor(Core.barelyThreshold(self.settings.barely_threshold) * 100 + 0.5))
        end,
        help_text = _("A book you opened but did not start (still on the cover, title page or contents) counts as Unread. Barely started means past the contents but not yet through the first chapter; Reading means at least a chapter in. The Library learns the chapters the next time you open a book. Until then, and for books without a table of contents, Barely started means read less than this much (the first 2 % or 3 pages still count as Unread)."),
        sub_item_table = items,
    }
end

--- ☰ → Library → Top row: Continue reading (books in progress, the default)
-- or Recently opened (every book opened, newest first, whatever its status).
local TOP_ROW_NAMES = { continue = _("Continue reading"), recent = _("Recently opened") }

function Library:setTopRow(mode)
    Core.setTopRow(self.settings, mode, function() self:saveSettings() end)
    if shared.view then shared.view:setTopRow(self.settings.top_row) end
end

function Library:topRowMenu()
    local items = {}
    for _i, mode in ipairs(Core.TOP_ROWS) do
        table.insert(items, {
            text = TOP_ROW_NAMES[mode],
            radio = true,
            checked_func = function() return Core.topRow(self.settings.top_row) == mode end,
            callback = function() self:setTopRow(mode) end,
        })
    end
    return {
        text_func = function()
            return T(_("Top row: %1"), TOP_ROW_NAMES[Core.topRow(self.settings.top_row)])
        end,
        help_text = _("The row of large covers at the top of the Books tab. Continue reading shows the books you are reading. Recently opened shows every book you have opened, newest first, including finished and on-hold ones. The Resume button in the footer always opens the most recent book you are still reading."),
        sub_item_table = items,
    }
end

--- Put (or take) our tab into the reader's top menu bar, just before the
-- file browser tab. reader_menu_order is a cached module table, so this is
-- idempotent: drop any earlier copy first.
local READER_TAB_ID = "library_tab"
local function placeReaderTab(enabled)
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" then return end
    local buttons = order["KOMenu:menu_buttons"]
    if type(buttons) ~= "table" then return end
    Core.placeMenuButton(buttons, READER_TAB_ID, "filemanager", enabled)
    -- a top-level entry with no items: tapping it runs the callback
    order[READER_TAB_ID] = enabled and {} or nil
end

local READER_ITEM_ID = "library_open"

-- Put a "Library" item at the top of the reader's ☰ tab, above History.
local function placeReaderItem()
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if not ok or type(order) ~= "table" or type(order.main) ~= "table" then return end
    Core.placeFirst(order.main, READER_ITEM_ID)
end

function Library:addReaderItem(menu_items)
    placeReaderItem()
    menu_items[READER_ITEM_ID] = {
        text = _("Library"),
        help_text = _("Close this book and open the Library. Your page and settings are saved first."),
        callback = function()
            if self.ui.menu then self.ui.menu:onTapCloseMenu() end
            UIManager:nextTick(function() self:onShowLibrary() end)
        end,
    }
end

--- "Book details" directly under the reader's Library item. Same card as a
-- long-press. Continue closes it and returns to the open page.
local READER_DETAILS_ID = "library_details"
function Library:addBookDetailsItem(menu_items)
    local ok, order = pcall(require, "ui/elements/reader_menu_order")
    if ok and type(order) == "table" and type(order.main) == "table" then
        Core.placeAfter(order.main, READER_DETAILS_ID, READER_ITEM_ID)
    end
    menu_items[READER_DETAILS_ID] = {
        text = _("Book details"),
        help_text = _("Title, author, description and progress for this book. Continue returns to the page."),
        callback = function()
            if self.ui.menu then self.ui.menu:onTapCloseMenu() end
            UIManager:nextTick(function()
                local book = self:currentBook()
                if book then self:showBookDetails(book, nil, { already_open = true }) end
            end)
        end,
    }
end

function Library:addReaderTab(menu_items)
    local enabled = self.settings.reader_tab ~= false
    placeReaderTab(enabled)
    if not enabled then return end
    menu_items[READER_TAB_ID] = {
        icon = "book.opened",
        text = _("Library"), -- only shown if a custom menu order leaves the tab out
        remember = false,
        callback = function()
            if self.ui.menu then self.ui.menu:onTapCloseMenu() end
            -- let the menu close before the Library opens over the book
            UIManager:nextTick(function() self:onShowLibrary() end)
        end,
    }
end

--- ☰ → Library → Remember layout for each shelf, and a way to forget them all.
function Library:rememberViewsMenu()
    return {
        text = _("Remember layout for each shelf"),
        help_text = _("Each collection, author, series and tab remembers its own layout (grid or list), sort and status filter, and opens the way you left it. The Books tab sets the default for places you have not changed. To reset the place you are in, use the Library's ☰ menu. Long-press this item to forget every shelf at once."),
        checked_func = function() return Core.rememberViews(self.settings) end,
        callback = function()
            self.settings.remember_views = not Core.rememberViews(self.settings)
            self:saveSettings()
            if shared.view then
                shared.view:applyRemembered()
                shared.view:refreshBody(true)
            end
        end,
        hold_callback = function(touchmenu_instance)
            local n = Core.countViewMemory(self.settings)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = T(_("Forget the layout, sort and filter remembered for %1 shelves? The Books tab's default stays."), n),
                ok_text = _("Forget"),
                ok_callback = function()
                    Core.resetAllViewPrefs(self.settings)
                    self:saveSettings()
                    if shared.view then
                        shared.view:applyRemembered()
                        shared.view:refreshBody(true)
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

--- G_reader_settings, as the small interface Core's sleep screen helpers use.
local function readerSettings()
    return {
        read = function(k) return G_reader_settings:readSetting(k) end,
        save = function(k, v) G_reader_settings:saveSetting(k, v) end,
        del = function(k) G_reader_settings:delSetting(k) end,
    }
end

function Library:sleepCoverIsOn()
    return Core.sleepCoverOn(readerSettings())
end

--- Turn "Sleep screen: cover of last book" on or off (menu and Controls panel).
function Library:toggleSleepCover()
    local gs = readerSettings()
    if Core.sleepCoverOn(gs) then
        Core.sleepCoverDisable(gs, self.settings.sleep_cover_prev)
        self.settings.sleep_cover_prev = nil
    else
        self.settings.sleep_cover_prev = Core.sleepCoverEnable(gs)
    end
    self:saveSettings()
    logger.info("Library: sleep screen", G_reader_settings:readSetting("screensaver_type"),
        "hide in file browser:", G_reader_settings:readSetting("screensaver_hide_cover_in_filemanager"))
end

--- ☰ → Library → Sleep screen: cover of last book. A shortcut to KOReader's
-- own "Show book cover on sleep screen", which also covers the file browser
-- and the Library; turning it off restores the previous sleep screen.
function Library:sleepCoverMenu()
    return {
        text = _("Sleep screen: cover of last book"),
        help_text = _("When the device sleeps, show the cover of the book you read last, also when you are in the Library or the file browser. This turns on KOReader's own \"Show book cover on sleep screen\" (Settings → Screen → Sleep screen). If the book has no cover, KOReader shows its usual sleep screen image. Turning this off brings back the sleep screen you had before."),
        checked_func = function() return self:sleepCoverIsOn() end,
        callback = function() self:toggleSleepCover() end,
    }
end

function Library:addToMainMenu(menu_items)
    menu_items.library = {
        text = _("Library"),
        sorting_hint = "main",
        sub_item_table = {
            {
                text = _("Open Library"),
                callback = function() self:onShowLibrary() end,
            },
            {
                text = _("Rescan library"),
                keep_menu_open = true,
                callback = function() self:onRescanLibrary() end,
                separator = true,
            },
            {
                text = _("Open Library at startup"),
                help_text = _("Show the Library instead of the file browser when KOReader starts. Close the Library (X) to get to the file browser."),
                checked_func = function() return self.settings.start_with_library end,
                callback = function()
                    self.settings.start_with_library = not self.settings.start_with_library
                    self:saveSettings()
                end,
            },
            {
                text = _("Return to Library after closing a book"),
                enabled_func = function() return self.settings.start_with_library end,
                checked_func = function() return self.settings.return_to_library end,
                callback = function()
                    self.settings.return_to_library = not self.settings.return_to_library
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Library folder: %1"), BD.dirpath(filemanagerutil.abbreviate(self:getRoot())))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    filemanagerutil.showChooseDialog(_("Library folder:"), function(path)
                        self.settings.root = path
                        self:saveSettings()
                        shared.index = nil
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end, self:getRoot(), filemanagerutil.getHomeFolder())
                end,
            },
            {
                text = _("Clear cover cache"),
                help_text = _("Delete the Library's cover thumbnails. They are made again, in the background, the next time the Library is open."),
                keep_menu_open = true,
                callback = function() self:clearCoverCache() end,
            },
            {
                text = _("Include hidden folders"),
                checked_func = function() return self.settings.show_hidden end,
                callback = function()
                    self.settings.show_hidden = not self.settings.show_hidden
                    self:saveSettings()
                    shared.index = nil
                end,
                separator = true,
            },
            self:barelyMenu(),
            self:topRowMenu(),
            self:sleepCoverMenu(),
            {
                text = _("Library tab in the reader menu"),
                help_text = _("Show a Library tab (book icon) in the top menu bar while reading, next to the file browser tab."),
                checked_func = function() return self.settings.reader_tab ~= false end,
                callback = function()
                    self.settings.reader_tab = self.settings.reader_tab == false
                    self:saveSettings()
                    -- the reader rebuilds its menu tabs the next time the menu opens
                    if self.ui.document and self.ui.menu then self.ui.menu.tab_item_table = nil end
                end,
            },
            {
                text = _("Rounded keyboard in search"),
                help_text = _("Give the Library's search bar a softer on-screen keyboard: rounded keys with gaps between them on a light background, like the Kindle or a phone. Only the Library's search uses it; every other keyboard in KOReader stays as it is. This does nothing while Use KOReader's keyboard is on."),
                checked_func = function() return Core.roundedKeyboard(self.settings) end,
                callback = function()
                    self.settings.rounded_keyboard = not Core.roundedKeyboard(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setRoundedKeyboard(self.settings.rounded_keyboard) end
                end,
            },
            {
                text = _("Use KOReader's keyboard"),
                help_text = _("Search opens KOReader's own text box and keyboard instead of the Library's. Leave this off to keep the Library keyboard."),
                checked_func = function() return Core.useKoreaderKeyboard(self.settings) end,
                callback = function()
                    self.settings.use_koreader_keyboard = not Core.useKoreaderKeyboard(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setUseKoreaderKeyboard(self.settings.use_koreader_keyboard) end
                end,
            },
            {
                text = _("Show clock"),
                help_text = _("Show the time beside the search bar. It updates when the Library repaints, and once a minute while it is on screen."),
                checked_func = function() return Core.showClock(self.settings) end,
                callback = function()
                    self.settings.show_clock = not Core.showClock(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setShowClock(self.settings.show_clock) end
                end,
            },
            {
                text = _("Show battery"),
                help_text = _("Show the battery percentage beside the search bar. It updates with the clock, not on its own timer."),
                checked_func = function() return Core.showBattery(self.settings) end,
                callback = function()
                    self.settings.show_battery = not Core.showBattery(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setShowBattery(self.settings.show_battery) end
                end,
            },
            {
                text = _("Word suggestions"),
                help_text = _("While you type in the search bar, a row of words from your library (titles, authors, series) appears above the keyboard. Tap one to finish the word."),
                checked_func = function() return self.settings.search_suggestions ~= false end,
                callback = function()
                    self.settings.search_suggestions = self.settings.search_suggestions == false
                    self:saveSettings()
                    if shared.view then shared.view:setSearchSuggestions(self.settings.search_suggestions) end
                end,
            },
            {
                text = _("Typo-tolerant search"),
                help_text = _("Search also finds close matches: accents and punctuation are ignored (bronte finds Brontë) and small typos are forgiven (harry poter finds Harry Potter). Exact matches stay at the top."),
                checked_func = function() return Core.fuzzySearch(self.settings) end,
                callback = function()
                    self.settings.fuzzy_search = not Core.fuzzySearch(self.settings)
                    self:saveSettings()
                    if shared.view then shared.view:setFuzzySearch(self.settings.fuzzy_search) end
                end,
            },
            self:rememberViewsMenu(),
            self:controlsMenu(),
            {
                text = _("Timing log (for testing)"),
                help_text = T(_("Write how long the Library takes to open, turn a page, switch a filter and show search results to %1, one line each. Off by default; nothing is timed while it is off."), self:timingLogPath()),
                checked_func = function() return self.settings.timing_log == true end,
                callback = function()
                    self.settings.timing_log = self.settings.timing_log ~= true or nil
                    self:saveSettings()
                    if shared.view then shared.view.timing = self:timer() end
                end,
            },
            self:simpleReaderMenuItem(),
            self:bezelLiftMenuItem(),
            {
                text = _("Next in series skips finished books"),
                help_text = _("Next in series opens the next book you have not finished. Turn this off to always open the very next book."),
                checked_func = function() return self.settings.series_skip_finished ~= false end,
                callback = function()
                    self.settings.series_skip_finished = self.settings.series_skip_finished == false
                    self:saveSettings()
                end,
            },
        },
    }
    if self.ui.document then
        self:addReaderItem(menu_items)
        self:addBookDetailsItem(menu_items)
        self:addReaderTab(menu_items)
        -- inside a book: Next / Previous in series right under Open Library
        local next_item, prev_item = self:seriesMenuItems()
        table.insert(menu_items.library.sub_item_table, 2, next_item)
        table.insert(menu_items.library.sub_item_table, 3, prev_item)
    end
end

----------------------------------------------------------------------------
-- Simple reader menu (libraryreaderpanel.lua, loaded on first use)
----------------------------------------------------------------------------

--- Tapping the top of a page opens our small menu instead of KOReader's full
-- one. KOReader's top tap zones ("readermenu_tap", "readermenu_ext_tap") call
-- `ReaderMenu:onTapShowMenu(ges)` through a method lookup, so we shadow that
-- one method on this book's ReaderMenu instance. Nothing else changes: zone
-- order and sizes, corner taps and Gesture manager actions, the swipe down
-- from the top, the Menu key and the "Show menu" action all keep KOReader's
-- behaviour, and the hook goes away with the book. With the setting off (or
-- KOReader's "Activate menu" set to swipe only) the tap goes straight through.
function Library:hookReaderMenuTap()
    local menu = self.ui and self.ui.menu
    if not menu or rawget(menu, "_library_tap_hook") then return end
    local original = menu.onTapShowMenu
    if type(original) ~= "function" then return end
    local plugin = self
    menu._library_tap_hook = original
    menu.onTapShowMenu = function(m, ges)
        local RM = require("libraryreadermenu")
        if RM.shouldIntercept(plugin.settings.simple_reader_menu, m.activation_menu)
                and plugin:showSimpleMenu(function() return original(m, ges) end) then
            return true
        end
        return original(m, ges)
    end
end

--- Title of the open book, without building the index on a tap.
function Library:openBookTitle()
    local ui = self.ui
    local doc = ui and ui.document
    if not doc then return "" end
    local props = ui.doc_props
    if type(props) == "table" then
        local t = props.display_title or props.title
        if type(t) == "string" and t ~= "" then return t end
    end
    local index = shared.index
    local book = index and index.by_path and index.by_path[doc.file]
    if book and book.title then return book.title end
    local name = type(doc.file) == "string" and (doc.file:match("[^/]+$") or doc.file) or ""
    return Core.stem(name)
end

function Library:openBookProgress()
    local ui = self.ui
    local ok, page = pcall(function() return ui:getCurrentPage() end)
    local ok2, total = pcall(function() return ui.document:getPageCount() end)
    page = ok and tonumber(page) or nil
    total = ok2 and tonumber(total) or nil
    local pct = (page and total and total > 0) and page / total or nil
    local RM = require("libraryreadermenu")
    return RM.progressText(page, total, pct, { page_of = _("Page %d of %d") })
end

function Library:isPageBookmarked()
    local bm = self.ui and self.ui.bookmark
    if not bm or not bm.isPageBookmarked then return false end
    local ok, on = pcall(bm.isPageBookmarked, bm)
    return ok and on or false
end

--- The panel's buttons, in panel order, leaving out what this reader lacks.
function Library:simpleMenuActions()
    local ui = self.ui
    local RM = require("libraryreadermenu")
    local function send(name, ...)
        local args = { ... }
        return function() ui:handleEvent(Event:new(name, unpack(args))) end
    end
    local defs = {
        library = { label = _("Library"), icon = "book.opened",
            run = function() self:onShowLibrary() end },
        toc = { label = _("Contents"), icon = "appbar.navigation", run = send("ShowToc") },
        ["goto"] = { label = _("Go to page"), icon = "appbar.pageview", run = send("ShowGotoDialog") },
        search = { label = _("Search"), icon = "appbar.search", run = send("ShowFulltextSearchInput") },
        -- KOReader's own bottom panel: font, size, margins, spacing
        font = { label = _("Font & size"), glyph = "Aa", bold_glyph = true, run = send("ShowConfigMenu") },
        -- one tap: darker, bolder, roomier text; tap again to undo (libraryreadability.lua)
        readability = { label = _("Readability"), label_on = _("Undo"), glyph = "A+", bold_glyph = true,
            on = function() return self:readabilityIsOn() end,
            run = function() self:toggleReadability() end },
        light = { label = _("Light"), glyph = "\u{EC98}",
            run = function()
                if not self:openControls() then
                    -- Controls panel turned off: KOReader's light dialog
                    ui:handleEvent(Event:new("ShowFlDialog"))
                end
            end },
        bookmark = { label = _("Bookmark"), label_on = _("Bookmarked"), icon = "bookmark",
            on = function() return self:isPageBookmarked() end, run = send("ToggleBookmark") },
        details = { label = _("Book details"), icon = "info",
            run = function()
                local book = self:currentBook()
                if book then self:showBookDetails(book, nil, { already_open = true }) end
            end },
    }
    local ids = RM.items({
        toc = ui.toc ~= nil,
        search = ui.search ~= nil,
        config = ui.config ~= nil,
        readability = self:readabilityAvailable(),
        light = Device:hasFrontlight() and true or false,
        bookmark = ui.bookmark ~= nil,
    })
    local out = {}
    for _, id in ipairs(ids) do
        local a = defs[id]; a.id = id
        out[#out + 1] = a
    end
    return out
end

--- Open the simple reader menu. `on_more` opens KOReader's full menu the way
-- the top tap always did. Returns true when the panel is (already) open.
function Library:showSimpleMenu(on_more)
    if shared.reader_panel then return true end
    if not (self.ui and self.ui.document) then return false end
    local ok, Panel = pcall(require, "libraryreaderpanel")
    if not ok then
        logger.warn("Library: simple reader menu unavailable", Panel)
        return false
    end
    local panel = Panel:new{
        title = self:openBookTitle(),
        subtitle = self:openBookProgress(),
        actions = self:simpleMenuActions(),
        on_more = on_more,
        on_exit = function() self:confirmExit() end,
        on_close = function(p) if shared.reader_panel == p then shared.reader_panel = nil end end,
    }
    shared.reader_panel = panel
    panel:show()
    return true
end

--- Exit KOReader, after a quick "are you sure". Same path as KOReader's own
-- ☰ → Exit: the "Exit" event (DeviceListener → menu:exitOrRestart), which
-- saves and closes the book or file browser. Our own windows are closed
-- first so nothing is left on screen to keep KOReader running.
function Library:confirmExit()
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Exit KOReader?"),
        ok_text = _("Exit"),
        ok_callback = function() self:exitKOReader() end,
    })
end

function Library:exitKOReader()
    if shared.controls then UIManager:close(shared.controls); shared.controls = nil end
    if shared.reader_panel then UIManager:close(shared.reader_panel); shared.reader_panel = nil end
    local view = shared.view
    if view then
        UIManager:close(view)
        shared.view = nil
    end
    self:sendUIEvent(Event:new("Exit"))
end

function Library:simpleReaderMenuItem()
    return {
        text = _("Simple reader menu"),
        help_text = _("Tapping the top of the page while reading opens a small menu: Library, Contents, Go to page, Search, Font & size, Readability, Light, Bookmark and Book details. More… in that menu opens KOReader's full reader menu. Turn this off to get KOReader's full menu straight away. Swiping down from the top always opens the full menu."),
        checked_func = function() return self.settings.simple_reader_menu ~= false end,
        callback = function()
            self.settings.simple_reader_menu = self.settings.simple_reader_menu == false
            self:saveSettings()
        end,
    }
end

----------------------------------------------------------------------------
-- Readability (simple reader menu), see libraryreadability.lua
----------------------------------------------------------------------------

--- Only for reflowable books (EPUB, FB2, HTML…): their font, spacing and
-- margins are KOReader's "configurable" options. PDFs and comics have none.
function Library:readabilityAvailable()
    local ui = self.ui
    local doc = ui and ui.document
    return (doc and ui.rolling and ui.font and ui.typeset and type(doc.configurable) == "table") and true or false
end

function Library:readabilityState()
    local ds = self.ui and self.ui.doc_settings
    return ds and ds:readSetting("library_readability")
end

function Library:readabilityIsOn()
    return require("libraryreadability").isOn(self:readabilityState())
end

--- The book's current values, read from KOReader.
function Library:readabilitySnapshot()
    local ui = self.ui
    local c = ui.document.configurable
    local s = {
        font_gamma = c.font_gamma,
        font_base_weight = c.font_base_weight,
        line_spacing = c.line_spacing,
        t_page_margin = c.t_page_margin,
        b_page_margin = c.b_page_margin,
        sync_t_b_page_margins = c.sync_t_b_page_margins,
    }
    if type(c.h_page_margins) == "table" then s.h_page_margins = { c.h_page_margins[1], c.h_page_margins[2] } end
    if ui.typography and ui.typography.hyphenation ~= nil then s.hyphenation = ui.typography.hyphenation and true or false end
    if type(UIManager.getRefreshRate) == "function" then
        local ok, rate = pcall(UIManager.getRefreshRate, UIManager)
        if ok and tonumber(rate) then s.full_refresh_count = tonumber(rate) end
    end
    return s
end

--- Set values the way KOReader's own bottom menu does: its events (which
-- also update the book's saved options), wrapped in BatchedUpdate so the
-- book is laid out again once, not once per setting.
function Library:applyReadabilityValues(ch)
    local ui = self.ui
    local c = ui.document.configurable
    local function send(name, ...) ui:handleEvent(Event:new(name, ...)) end
    send("BatchedUpdate")
    if ch.font_gamma ~= nil then send("SetFontGamma", ch.font_gamma) end
    if ch.font_base_weight ~= nil then send("SetFontBaseWeight", ch.font_base_weight) end
    if ch.line_spacing ~= nil then send("SetLineSpace", ch.line_spacing) end
    if ch.h_page_margins ~= nil or ch.t_page_margin ~= nil or ch.b_page_margin ~= nil then
        local h = ch.h_page_margins or c.h_page_margins or { 10, 10 }
        local t = ch.t_page_margin ~= nil and ch.t_page_margin or c.t_page_margin
        local b = ch.b_page_margin ~= nil and ch.b_page_margin or c.b_page_margin
        -- the bottom menu stores these itself; events alone do not
        c.h_page_margins = { h[1], h[2] }
        c.t_page_margin, c.b_page_margin = t, b
        send("SetPageHorizMargins", { h[1], h[2] })
        send("SetPageTopAndBottomMargin", { t, b })
    end
    if ch.sync_t_b_page_margins ~= nil then
        c.sync_t_b_page_margins = ch.sync_t_b_page_margins
        if ui.typeset then ui.typeset.sync_t_b_page_margins = ch.sync_t_b_page_margins == 1 end
    end
    if ch.hyphenation ~= nil and ui.typography then
        -- no event for this one: same two calls as KOReader's Hyphenation menu
        ui.typography.hyphenation = ch.hyphenation
        pcall(ui.document.setTextHyphenation, ui.document, ch.hyphenation)
        send("UpdatePos")
    end
    send("BatchedUpdateDone")
    if ch.full_refresh_count ~= nil and type(UIManager.setRefreshRate) == "function" then
        UIManager:setRefreshRate(ch.full_refresh_count)
    end
end

--- One tap: apply the preset (remembering this book's values), or undo it.
function Library:toggleReadability()
    if not self:readabilityAvailable() then return end
    local R = require("libraryreadability")
    local ds = self.ui.doc_settings
    local cur = self:readabilitySnapshot()
    local state = self:readabilityState()
    local msg
    if R.isOn(state) then
        local ch = R.restore(state, cur)
        ds:delSetting("library_readability")
        self:applyReadabilityValues(ch)
        msg = _("Readability off: this book's own settings are back.")
    else
        local ch, new_state = R.apply(cur)
        if not ch then
            msg = _("This book already reads that way.")
        else
            ds:saveSetting("library_readability", new_state)
            self:applyReadabilityValues(ch)
            msg = _("Readability on: darker, bolder text with more space. Tap Readability again to undo.")
        end
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
end

----------------------------------------------------------------------------
-- Status bar above the bezel (Kindle Colorsoft), see librarybezel.lua
----------------------------------------------------------------------------

function Library:readerFooter()
    local view = self.ui and self.ui.view
    local footer = view and view.footer
    if footer and type(footer.settings) == "table" then return footer end
end

--- Set KOReader's status bar bottom margin the same way its own
-- "Bottom margin" spinner does, so the change is a normal KOReader setting.
function Library:setFooterBottomMargin(footer, value)
    footer.settings.container_bottom_padding = value
    footer.bottom_padding = Device.screen:scaleBySize(value)
    if type(footer.refreshFooter) == "function" then
        pcall(footer.refreshFooter, footer, true, true)
    end
end

function Library:liftFooterAboveBezel()
    local footer = self:readerFooter()
    if not footer then return end
    local Bezel = require("librarybezel")
    local current = footer.settings.container_bottom_padding
    local value = Bezel.plan{
        model = Device.model,
        enabled = self.settings.bezel_lift,
        current = current,
        prev = self.settings.bezel_prev,
    }
    if not value then return end
    self.settings.bezel_prev = tonumber(current) or Bezel.DEFAULT
    self:saveSettings()
    self:setFooterBottomMargin(footer, value)
end

function Library:onReaderReady()
    self:liftFooterAboveBezel()
end

function Library:bezelLiftMenuItem()
    local Bezel = require("librarybezel")
    return {
        text = _("Keep status bar above the bezel"),
        help_text = _("On the Kindle Colorsoft the screen runs a few pixels under the frame, so the status bar at the bottom of the page is partly hidden. This raises KOReader's status bar bottom margin a little, once, if you have not changed it yourself. Turning it off puts the old margin back. You can also set it by hand in the reader's settings: Status bar > Configure items > Bottom margin."),
        enabled_func = function() return Bezel.affected(Device.model) end,
        checked_func = function() return self.settings.bezel_lift ~= false end,
        callback = function()
            local turning_on = self.settings.bezel_lift == false
            self.settings.bezel_lift = turning_on
            local footer = self:readerFooter()
            if turning_on then
                self:saveSettings()
                self:liftFooterAboveBezel()
                return
            end
            local current = footer and footer.settings.container_bottom_padding
            if not footer then
                local stored = G_reader_settings:readSetting("footer")
                current = type(stored) == "table" and stored.container_bottom_padding or nil
            end
            local back = Bezel.restore(current, self.settings.bezel_prev)
            self.settings.bezel_prev = nil
            self:saveSettings()
            if back then
                if footer then
                    self:setFooterBottomMargin(footer, back)
                else
                    G_reader_settings:readSetting("footer").container_bottom_padding = back
                end
            end
        end,
    }
end

----------------------------------------------------------------------------
-- Keep the index fresh
----------------------------------------------------------------------------

--- While a book is open: save where its text starts and where its first
-- chapter ends (from the table of contents) in the book's sidecar, so the
-- Library can tell Unread / Barely started / Reading without opening books.
-- Worked out once per book layout. Runs on CloseDocument (the sidecar is
-- written right after it) and on SaveSettings while the book is still open
-- (suspend, autosave).
function Library:saveChapterMarks()
    local doc, toc, ds = self.ui.document, self.ui.toc, self.ui.doc_settings
    if not (doc and toc and ds and toc.fillToc) then return end
    local ok, pages = pcall(doc.getPageCount, doc)
    if not ok or not pages then return end
    local key = tostring(doc.file) .. ":" .. tostring(pages)
    if self._marks_for == key then return end
    local ok2, marks = pcall(function()
        toc:fillToc()
        return Core.tocMarks(toc.toc, pages)
    end)
    if not ok2 then logger.warn("Library: chapter marks failed:", marks); return end
    self._marks_for = key
    if Core.sameMarks(ds:readSetting("library_marks"), marks) then return end
    if marks then ds:saveSetting("library_marks", marks) else ds:delSetting("library_marks") end
end

function Library:onSaveSettings() self:saveChapterMarks() end

function Library:onCloseDocument()
    self:saveChapterMarks()
    if self.ui.document and shared.index then
        shared.index:refreshBook(self.ui.document.file)
    end
end

--- A custom cover was set or removed in Book information: drop our thumbnail.
function Library:onInvalidateMetadataCache(file)
    if not file then return end
    local Covers = require("librarycovers")
    Covers.getStore():forget(file)
    if shared.view then
        shared.view.cover_cache:clear()
        shared.view:refreshBody()
    end
end

function Library:clearCoverCache()
    local Covers = require("librarycovers")
    local store = Covers.getStore()
    Covers.kill()
    local n, bytes = store:usage()
    store:clear()
    if shared.view then
        shared.view.cover_cache:clear()
        shared.view:refreshBody(true)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Removed %1 cover thumbnails (%2)."), n, Core.formatSize(bytes)),
        timeout = 2,
    })
end

function Library:onBookMetadataChanged()
    -- Edited title/author: re-read all metadata next time.
    if shared.index then
        shared.index.needs_build = true
        shared.index.force_next = true
    end
end

return Library
