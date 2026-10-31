--[[--
Dev-only probe. Runs inside KOReader, drives Library GUI, and writes PNGs.

Environment:
  GUIPROBE_OUT     directory for PNGs and probe.log (required)
  GUIPROBE_SCRIPT  scenario name: smoke, footer (default smoke)
  GUIPROBE_TAG     optional filename prefix

Scenarios
  smoke   one shot of the library, to prove the harness
  footer  page label "3 / 12", the Go to page dialog, and (when the next
          arrow has a long-press) the last page after that long-press
]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local Screen = Device.screen

local OUT = os.getenv("GUIPROBE_OUT")
local TAG = os.getenv("GUIPROBE_TAG") or ""
local SCRIPT = os.getenv("GUIPROBE_SCRIPT") or "smoke"

local Probe = WidgetContainer:extend{ name = "guiprobe" }
local steps = {}
local state = { ok = true }

local function P(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    logger.info("GUIPROBE", line)
    if OUT and OUT ~= "" then
        local f = io.open(OUT .. "/probe.log", "a")
        if f then f:write(line, "\n"); f:close() end
    end
end

local function q(delay, fn)
    steps[#steps + 1] = { d = delay, f = fn }
end

local function FM()
    local fm = require("apps/filemanager/filemanager")
    return fm and fm.instance
end

local function lib()
    local fm = FM()
    return fm and fm.library
end

local function V()
    local l = lib()
    return l and l.shared and l.shared.view
end

local function shot(name)
    UIManager:forceRePaint()
    local path = OUT .. "/" .. TAG .. name .. ".png"
    Screen:shot(path)
    P("SHOT", name .. ".png", Screen:getWidth() .. "x" .. Screen:getHeight())
end

local function walk(widget, fn, seen)
    if type(widget) ~= "table" or seen[widget] then return end
    seen[widget] = true
    fn(widget)
    for i = 1, #widget do walk(widget[i], fn, seen) end
end

local function findText(widget, pattern)
    local found
    walk(widget, function(w)
        if found or type(w.text) ~= "string" then return end
        if not pattern or w.text:match(pattern) then found = w.text end
    end, {})
    return found
end

local function findIcon(icon)
    local view = V()
    if not view then return nil end
    local found
    walk(view, function(w)
        if not found and w.icon == icon and w.dimen then found = w end
    end, {})
    return found
end

local function stackLine()
    local parts = {}
    for i, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        local label = w.name or w.title or (type(w.text) == "string" and w.text:sub(1, 40)) or "?"
        parts[#parts + 1] = i .. ":" .. tostring(label)
    end
    return table.concat(parts, " | ")
end

local function ges(kind, x, y)
    local Event = require("ui/event")
    UIManager:sendEvent(Event:new("Gesture", {
        ges = kind,
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
        time = time.now(),
    }))
end

local function center(d)
    return d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2)
end

-- KOReader's own one-time notices (cover cache, importers) sit above the
-- library. Close them so the shot is the library, not the notice.
local function dismissNotices()
    local view = V()
    local closing = {}
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w == view or w.title == "Go to page" then break end
        closing[#closing + 1] = w
    end
    for _, w in ipairs(closing) do
        local label = w.title or w.text or w.name or "?"
        if type(label) ~= "string" then label = tostring(label) end
        P("dismiss", label:gsub("%s+", " "):sub(1, 90))
        UIManager:close(w)
    end
end

local function pageDialog()
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w.title == "Go to page" then return w end
    end
end

-- Twelve pages of whatever fits on this screen, so the footer reads "3 / 12".
local function trimToTwelve(view)
    local per = view.layout and view.layout.per_page or 0
    if per < 1 then
        P("FAIL no per_page")
        return false
    end
    local need = per * 12
    local have = #(view.sorted or {})
    if have < need then
        P("FAIL not enough books", "have", have, "need", need, "per_page", per)
        return false
    end
    local slice = {}
    for i = 1, need do slice[i] = view.sorted[i] end
    view.sorted = slice
    view.page = 1
    view:refreshBody(true)
    P("trimmed", "per_page", per, "pages", view.pages, "items", view.current and #view.current.items)
    return view.pages == 12
end

local function prepareFooter()
    local view = V()
    view.show_continue = false
    if view.closeKeyboard then view:closeKeyboard() end
    view:refreshBody(true)
    if trimToTwelve(view) then return true end
    -- List view caps the rows, so a page holds fewer books than the cover grid.
    view:reloadData()
    view:setViewMode("list")
    view.show_continue = false
    view:refreshBody(true)
    return trimToTwelve(view)
end

local function run()
    local step = table.remove(steps, 1)
    if not step then
        P(state.ok and "DONE ok" or "DONE fail")
        P("stack", stackLine())
        UIManager:scheduleIn(0.4, function() UIManager:quit() end)
        return
    end
    UIManager:scheduleIn(step.d, function()
        local ok, err = xpcall(step.f, debug.traceback)
        if not ok then
            state.ok = false
            P("STEP ERROR", err)
        end
        run()
    end)
end

local function whenLibrary(fn)
    local tries = 0
    local function poll()
        tries = tries + 1
        local view = V()
        if view and view.pages and view.sorted and #view.sorted > 0 then
            P("library", "books", #view.sorted, "pages", view.pages,
                "screen", Screen:getWidth() .. "x" .. Screen:getHeight(),
                "dpi", Screen:getDPI(), "tries", tries)
            fn()
            return
        end
        if tries >= 45 then
            state.ok = false
            P("FAIL library did not open", "tries", tries, "stack", stackLine())
            return
        end
        table.insert(steps, 1, { d = 1, f = poll })
    end
    q(1, poll)
end

local scenarios = {}

scenarios.smoke = function()
    whenLibrary(function()
        q(0.8, function()
            dismissNotices()
            local view = V()
            local label = view.page_label and findText(view.page_label, "%d") or findText(view, "%d+ / %d+")
            P("smoke", "page", view.page, "pages", view.pages, "label", tostring(label), "stack", stackLine())
            shot("smoke-library")
        end)
    end)
end

scenarios.footer = function()
    whenLibrary(function()
        q(0.5, function()
            if not prepareFooter() then
                state.ok = false
                P("FAIL could not build a 12 page list")
                return
            end
            V():goToPage(3)
        end)
        q(0.8, function()
            dismissNotices()
            local view = V()
            local label = view.page_label and findText(view.page_label) or ""
            P("LABEL", label, "page", view.page, "pages", view.pages)
            if label ~= "3 / 12" or view.page ~= 3 or view.pages ~= 12 then
                state.ok = false
                P("FAIL label", label)
            end
            shot("footer-page-label")
        end)
        q(0.4, function()
            local view = V()
            UIManager:forceRePaint()
            local area = view.page_label
            if area and area.dimen then
                local x, y = center(area.dimen)
                P("tap page label", x, y, area.dimen.w, area.dimen.h)
                ges("tap", x, y)
            end
            if not pageDialog() and view.showPageJump then
                P("dialog via showPageJump")
                view:showPageJump()
            end
        end)
        q(1.5, function()
            dismissNotices()
            local dialog = pageDialog()
            P("dialog", dialog and tostring(dialog.title) or "missing", "stack", stackLine())
            if not dialog then state.ok = false end
            shot("footer-go-to-page")
            if dialog then UIManager:close(dialog) end
        end)
        q(0.6, function()
            local view = V()
            UIManager:forceRePaint()
            local arrow = findIcon("chevron.right")
            if not arrow then
                state.ok = false
                P("LONGPRESS failed", "next arrow not found")
                return
            end
            if not arrow.hold_callback then
                P("LONGPRESS unavailable", "next arrow has no hold_callback",
                    "page", view.page, "pages", view.pages)
                return
            end
            local before = view.page
            local x, y = center(arrow.dimen)
            P("hold next", x, y, "dimen", arrow.dimen.x, arrow.dimen.y, arrow.dimen.w, arrow.dimen.h)
            ges("hold", x, y)
            if view.page == before then
                local Event = require("ui/event")
                arrow:handleEvent(Event:new("Gesture", {
                    ges = "hold",
                    pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
                    time = time.now(),
                }))
                P("hold delivered to the arrow button")
            end
            if view.page == view.pages and view.page ~= before then
                P("LONGPRESS ok", "from", before, "to", view.page, "of", view.pages)
            else
                state.ok = false
                P("LONGPRESS failed", "page", view.page, "pages", view.pages, "before", before)
            end
        end)
        q(0.8, function()
            if not state.ok then return end
            dismissNotices()
            local view = V()
            -- Only when the long-press actually moved off page 3.
            local jumped = view.page == view.pages and view.pages == 12 and view.page ~= 3
            if not jumped then return end
            local label = view.page_label and findText(view.page_label) or ""
            P("AFTER JUMP", label, "page", view.page, "pages", view.pages)
            shot("footer-jump-last")
        end)
    end)
end

function Probe:init()
    if _G.__guiprobe_started then return end
    _G.__guiprobe_started = true
    if not OUT or OUT == "" then
        logger.info("GUIPROBE", "GUIPROBE_OUT is unset; idle")
        return
    end
    -- Desktop KOReader reports no battery. A fixed percentage keeps the header
    -- in the same place as on a Kindle. Test-only; nothing here is in the plugin.
    pcall(function()
        Device.hasBattery = function() return true end
        local power = Device:getPowerDevice()
        if power then power.getCapacity = function() return 78 end end
    end)
    local scenario = scenarios[SCRIPT]
    if not scenario then
        P("FAIL unknown scenario", SCRIPT)
        UIManager:scheduleIn(0.5, function() UIManager:quit() end)
        return
    end
    P("scenario", SCRIPT, "out", OUT)
    UIManager:scheduleIn(0.5, function()
        scenario()
        run()
    end)
end

return Probe
