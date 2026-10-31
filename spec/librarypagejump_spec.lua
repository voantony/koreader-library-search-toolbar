-- Tapping the footer's "63 / 72" opens a Go to page box. The plugin manager
-- lists it as "Library GUI"; on the device the menu and header stay "Library".
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end

local function load(file, extra)
    local old_require = require
    local real = { librarycore = true, libraryindex = true, string = true, table = true, math = true }
    _G.require = function(name)
        if extra[name] ~= nil then return extra[name] end
        if real[name] then return old_require(name) end
        if name == "gettext" then return function(s) return s end end
        if name == "ffi/util" then
            return { template = function(s, ...)
                local a = { ... }
                return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
            end }
        end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/" .. file)
    _G.require = old_require
    if not ok then error(mod, 0) end
    return mod
end

local function cls()
    local base = {}
    base.__index = base
    function base:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    function base:new(o) o = o or {}; return setmetatable(o, self) end
    return base
end

local function mainWith(shown, closed)
    return load("main.lua", {
        ["ui/uimanager"] = {
            show = function(_, w) shown[#shown + 1] = w end,
            close = function(_, w) closed[#closed + 1] = w end,
        },
        ["ui/widget/container/widgetcontainer"] = cls(),
    })
end

local function jumpDialog(typed, pages)
    local shown, closed, went = {}, {}, {}
    local Library = mainWith(shown, closed)
    local InputDialog = { new = function(_, o)
        o.getInputText = function() return typed end
        o.onShowKeyboard = function() o.keyboard = true end
        return o
    end }
    package.loaded["ui/widget/inputdialog"] = InputDialog
    local view = { pages = pages or 72 }
    function view:goToPage(n) went[#went + 1] = n end
    local self = setmetatable({ settings = {} }, { __index = Library })
    local dialog = Library.showPageJump(self, view)
    package.loaded["ui/widget/inputdialog"] = nil
    local go = dialog.buttons[1][2]
    return dialog, go, went, shown, closed
end

describe("Go to page from the footer", function()
    it("opens a number box with the page range and the keyboard up", function()
        local dialog, go, _w, shown = jumpDialog("", 72)
        eq(shown[1], dialog)
        eq(dialog.title, "Go to page")
        eq(dialog.input_type, "number")
        eq(dialog.input_hint, "1 – 72")
        eq(go.text, "Go")
        eq(dialog.keyboard, true)
    end)

    it("Go jumps to the typed page and closes", function()
        local dialog, go, went, _s, closed = jumpDialog("63")
        go.callback()
        same(went, { 63 })
        eq(closed[1], dialog)
    end)

    it("ignores text that is not a number, and an empty box", function()
        for _, typed in ipairs({ "abc", "", "   ", "nan" }) do
            local _d, go, went, _s, closed = jumpDialog(typed)
            go.callback()
            eq(#went, 0, typed)
            eq(#closed, 0, typed)
        end
    end)

    it("Cancel closes and does not jump", function()
        local dialog, _go, went, _s, closed = jumpDialog("4", 12)
        local cancel = dialog.buttons[1][1]
        eq(cancel.text, "Cancel")
        eq(cancel.id, "close")
        cancel.callback()
        eq(#went, 0)
        eq(closed[1], dialog)
    end)

    it("a typed page in range jumps, and a fraction keeps its whole pages", function()
        local dialog, go, went, _s, closed = jumpDialog("3.8", 12)
        go.callback()
        same(went, { 3 })
        eq(closed[1], dialog)
    end)

    it("out of range is clamped when Go is pressed", function()
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            util = { stringLower = function(s) return s:lower() end },
        })
        local shown, closed = {}, {}
        local Library = mainWith(shown, closed)
        local typed = "99"
        package.loaded["ui/widget/inputdialog"] = { new = function(_, o)
            o.getInputText = function() return typed end
            o.onShowKeyboard = function() o.keyboard = true end
            return o
        end }
        local v = setmetatable({ page = 3, pages = 12 }, { __index = View })
        v.refreshBody = function() end
        local self = setmetatable({ settings = {} }, { __index = Library })
        local dialog = Library.showPageJump(self, v)
        dialog.buttons[1][2].callback()
        eq(v.page, 12)
        eq(closed[1], dialog)
        typed = "0"
        v.page = 5
        dialog = Library.showPageJump(self, v)
        dialog.buttons[1][2].callback()
        eq(v.page, 1)
        eq(#closed, 2)
        typed = "-4"
        v.page = 5
        dialog = Library.showPageJump(self, v)
        dialog.buttons[1][2].callback()
        eq(v.page, 1)
        package.loaded["ui/widget/inputdialog"] = nil
    end)

    it("out-of-range pages are clamped by goToPage", function()
        local View = load("libraryview.lua", {
            ["ui/widget/container/inputcontainer"] = cls(),
            util = { stringLower = function(s) return s:lower() end },
        })
        local v = setmetatable({ page = 2, pages = 10 }, { __index = View })
        v.refreshBody = function() end
        v:goToPage(99); eq(v.page, 10)
        v:goToPage(-3); eq(v.page, 1)
    end)
end)

describe("LibraryView page label", function()
    local View = load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = cls(),
        util = { stringLower = function(s) return s:lower() end },
    })
    it("tapping it hides the search keyboard and asks the plugin for the box", function()
        local calls = {}
        local v = setmetatable({ pages = 5 }, { __index = View })
        v.keyboardGuard = function() calls[#calls + 1] = "keyboard" end
        v.plugin = { showPageJump = function(_, view) calls[#calls + 1] = "jump"; eq(view, v) end }
        v:showPageJump()
        same(calls, { "keyboard", "jump" })
    end)

    it("does nothing on a single page", function()
        local v = setmetatable({ pages = 1 }, { __index = View })
        v.keyboardGuard = function() error("should not run") end
        v.plugin = { showPageJump = function() error("should not run") end }
        v:showPageJump()
    end)
end)

-- Footer arrows: a tap moves one page, a long-press jumps to the end.
local function sized(w, h)
    return { getSize = function() return { w = w, h = h } end, free = function() end }
end

local function widget(w, h)
    return { new = function(_, o)
        o = o or {}
        o.getSize = function() return { w = o.width or w, h = o.height or h } end
        o.free = function() end
        return o
    end }
end

local buttons, groups
local function clsInit()
    local base = cls()
    function base:new(o)
        o = o or {}
        setmetatable(o, self)
        if o.init then o:init() end
        return o
    end
    return base
end

local function loadFooterView()
    buttons, groups = {}, {}
    return load("libraryview.lua", {
        ["ui/widget/container/inputcontainer"] = clsInit(),
        ["ui/widget/iconbutton"] = { new = function(_, o)
            o.image = {}
            o.getSize = function() return { w = 48, h = 48 } end
            buttons[#buttons + 1] = o
            return o
        end },
        ["ui/widget/textwidget"] = { new = function() return sized(80, 24) end },
        ["ui/widget/horizontalgroup"] = { new = function(_, o)
            o = o or {}
            o.getSize = function() return { w = 160, h = 48 } end
            o.free = function() end
            groups[#groups + 1] = o
            return o
        end },
        ["ui/widget/horizontalspan"] = widget(8, 8),
        ["ui/widget/container/framecontainer"] = widget(200, 48),
        ["ui/geometry"] = { new = function(_, o) o.x = o.x or 0; o.y = o.y or 0; return o end },
        ["ui/gesturerange"] = { new = function() return {} end },
        ["ui/widget/container/leftcontainer"] = { new = function(_, o) return o end },
        ["ui/size"] = { margin = { default = 10 }, padding = { default = 8, small = 4, large = 16 } },
        ["ui/font"] = { getFace = function() return {} end },
        ["ui/time"] = {
            now = function() return _G.__now_ms or 0 end,
            to_ms = function(t) return t end,
            to_s = function(t) return t end,
        },
        librarytile = { minTouch = function() return 48 end },
        device = { screen = {
            scaleBySize = function(_, n) return n end,
            scaleByDPI = function(_, n) return n end,
            getWidth = function() return 1264 end,
            getHeight = function() return 1680 end,
        }, hasKeys = function() return false end, isTouchDevice = function() return true end, hasDPad = function() return false end },
        util = { stringLower = function(s) return s:lower() end },
    })
end

local function arrowView(View, opts)
    opts = opts or {}
    local opened = {}
    local stepped = {}
    local v = setmetatable({
        width = 1264,
        tab = opts.tab or "books",
        sort = "recent",
        query = opts.query or "",
        page = opts.page or 1,
        pages = opts.pages or 1,
        group = opts.group,
        last_book = nil,
        plugin = {
            settings = {},
            sortName = function() return "Last read" end,
            openBook = function(_, path) opened[#opened + 1] = path end,
        },
    }, { __index = View })
    v.refreshBody = function(self) self.refreshed = (self.refreshed or 0) + 1 end
    v.keyboardGuard = function() end
    v.seriesPosition = function() return opts.series_pos, opts.series_count end
    v.stepSeries = function(self, dir)
        stepped[#stepped + 1] = dir
        return true
    end
    return v, opened, stepped
end

local function arrows()
    local prev, nxt
    for _, b in ipairs(buttons) do
        if b.icon == "chevron.left" then prev = b
        elseif b.icon == "chevron.right" then nxt = b end
    end
    return prev, nxt
end

describe("Long-press on the page arrows", function()
    local View = loadFooterView()

    local function footer(opts)
        buttons, groups = {}, {}
        local v, opened, stepped = arrowView(View, opts)
        v:buildFooter(opts.page or 1, opts.pages or 1, opts.total or 40, opts.kind or "books")
        local prev, nxt = arrows()
        return v, prev, nxt, opened, stepped
    end

    it("a tap moves one page and a long-press jumps to the last or the first", function()
        local v, prev, nxt = footer({ page = 3, pages = 10 })
        eq(prev.enabled, true)
        eq(nxt.enabled, true)
        eq(prev.image.dim, nil)
        nxt.callback()
        eq(v.page, 4)
        eq(v.refreshed, 1)
        prev.hold_callback()
        eq(v.page, 1)
        eq(v.refreshed, 2)
        nxt.hold_callback()
        eq(v.page, 10)
        eq(v.refreshed, 3)
    end)

    it("does nothing when already on the first or last page", function()
        local v, prev, nxt = footer({ page = 1, pages = 10 })
        eq(prev.enabled, false)
        eq(prev.image.dim, true)
        eq(nxt.enabled, true)
        prev.hold_callback()
        eq(v.page, 1)
        eq(v.refreshed, nil)
        nxt.callback()
        eq(v.page, 2)

        buttons = {}
        v.page, v.pages, v.refreshed = 10, 10, nil
        v:buildFooter(10, 10, 40, "books")
        prev, nxt = arrows()
        eq(nxt.enabled, false)
        eq(nxt.image.dim, true)
        nxt.hold_callback()
        eq(v.page, 10)
        eq(v.refreshed, nil)
        prev.hold_callback()
        eq(v.page, 1)
        eq(v.refreshed, 1)
    end)

    it("does nothing on a single page, in a folder and in search results", function()
        local v, prev, nxt = footer({ page = 1, pages = 1, kind = "groups", tab = "authors", total = 3 })
        eq(prev.enabled, false)
        eq(nxt.enabled, false)
        eq(v.page_label, nil, "one page: the number is not a tap target")
        prev.hold_callback(); nxt.hold_callback()
        prev.callback(); nxt.callback()
        eq(v.page, 1)
        eq(v.refreshed, nil)

        buttons, groups = {}, {}
        local folder = arrowView(View, {
            page = 2, pages = 5, kind = "books", tab = "authors",
            group = { kind = "authors", name = "Austen" }, query = "emma",
        })
        folder:buildFooter(2, 5, 22, "books")
        prev, nxt = arrows()
        eq(prev.enabled, true)
        eq(nxt.enabled, true)
        nxt.hold_callback()
        eq(folder.page, 5)
        prev.hold_callback()
        eq(folder.page, 1)
    end)

    it("inside a series, a long-press stays on this series and a tap still steps", function()
        local v, prev, nxt, _o, stepped = footer({
            page = 2, pages = 4,
            group = { kind = "series", name = "Oz", books = {} },
            series_pos = 2, series_count = 6,
        })
        -- both ends stay tappable so a tap can walk into the next series
        eq(prev.enabled, true)
        eq(nxt.enabled, true)
        nxt.hold_callback()
        eq(v.page, 4)
        eq(#stepped, 0)
        nxt.hold_callback()
        eq(v.page, 4, "already on the last page")
        eq(#stepped, 0)
        nxt.callback()
        same(stepped, { 1 })

        buttons, groups = {}, {}
        v.page, v.refreshed = 1, nil
        v:buildFooter(1, 4, 4, "books")
        prev = arrows()
        eq(prev.icon, "chevron.left")
        prev.hold_callback()
        eq(v.page, 1)
        eq(#stepped, 1, "a long-press on the first page does not open the previous series")
        prev.callback()
        same(stepped, { 1, -1 })
    end)

    it("tapping the page number opens Go to page and leaves the arrows alone", function()
        local v, prev, nxt = footer({ page = 3, pages = 12 })
        local jumps = 0
        v.plugin.showPageJump = function(_, view)
            jumps = jumps + 1
            eq(view, v)
        end
        local pager
        for _, g in ipairs(groups) do
            if g[1] == prev and g[3] == nxt then pager = g end
        end
        eq(pager[2], v.page_label, "the number sits between the arrows, not inside them")
        eq(v.page_label.dimen.w, 80, "only as wide as the number")
        eq(v.page_label.ges_events.Hold, nil, "a long-press is not the number's gesture")
        eq(v.page_label.ges_events.TapArea ~= nil, true)
        v.page_label.callback()
        eq(jumps, 1)
        eq(v.page, 3)
        eq(v.refreshed, nil)
        nxt.callback()
        eq(jumps, 1, "a tap on next still moves one page")
        eq(v.page, 4)
        prev.hold_callback()
        eq(jumps, 1, "a long-press on previous still jumps home")
        eq(v.page, 1)
        nxt.hold_callback()
        eq(jumps, 1)
        eq(v.page, 12)
    end)

    it("a jump arms the guard that ignores a tap left over from a slow swipe", function()
        local v, _p, _n, opened = footer({ page = 2, pages = 8 })
        local tile = { book = { path = "/emma" } }
        _G.__now_ms = 5000
        v:jumpToEnd(1)
        eq(v.page, 8)
        eq(v._turned_ms, 5000)
        _G.__now_ms = 5200
        v:onTileTap(tile, { pos = { x = 300, y = 400 } })
        eq(#opened, 0)
        _G.__now_ms = 5600
        v:onTileTap(tile, { pos = { x = 300, y = 400 } })
        eq(opened[1], "/emma")
    end)

    it("a long-press that does not move does not swallow the next tap on a book", function()
        local v, _p, _n, opened = footer({ page = 1, pages = 8 })
        _G.__now_ms = 5000
        v:jumpToEnd(-1)
        eq(v.page, 1)
        eq(v._turned_ms, nil)
        eq(v.refreshed, nil)
        _G.__now_ms = 5100
        v:onTouch(nil, { pos = { x = 300, y = 400 } })
        v:onTileTap({ book = { path = "/emma" } }, { pos = { x = 302, y = 401 } })
        eq(opened[1], "/emma")
    end)

    it("a short flick still turns the page instead of opening the book", function()
        local v, _p, _n, opened = footer({ page = 3, pages = 8 })
        _G.__now_ms = 8000
        v:onTouch(nil, { pos = { x = 300, y = 400 } })
        v:onTileTap({ book = { path = "/emma" } }, { pos = { x = 260, y = 405 } })
        eq(#opened, 0)
        eq(v.page, 4)
    end)
end)

describe("Plugin name", function()
    it("shows as Library GUI in plugin management", function()
        local meta = load("_meta.lua", {})
        eq(meta.fullname, "Library GUI")
        assert(meta.description:find("Library GUI", 1, true), "description names Library GUI")
    end)

    it("the main menu entry and its Open item stay plain Library", function()
        local Library = mainWith({}, {})
        local self = setmetatable({ settings = {}, ui = {} }, { __index = Library })
        self.barelyMenu = function() return {} end
        self.topRowMenu = function() return {} end
        self.sleepCoverMenu = function() return {} end
        local items = {}
        Library.addToMainMenu(self, items)
        eq(items.library.text, "Library")
        eq(items.library.sub_item_table[1].text, "Open Library")
    end)
end)
