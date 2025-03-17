---@alias Index { row: number, col: number, space: SpaceIdx }
---@alias SpaceIdx number a Mission Control space index
---@alias Mapping { [string]: (table | string)[]}
---@alias Window hs.window
---@alias WindowId integer
---@alias WindowFilter hs.window.filter
---@alias WindowList table<SpaceIdx, table<number, table<number, Window>>>

local Rect <const> = hs.geometry.rect
local Screen <const> = hs.screen
local Timer <const> = hs.timer
local Watcher <const> = hs.uielement.watcher
local Window <const> = hs.window
local WindowFilter <const> = hs.window.filter
local partial <const> = hs.fnutils.partial

local Swipe = dofile(hs.spoons.resourcePath("swipe.lua"))
-- local Scroll = require("PaperWM.spoon.scroll")
-- Scroll:start()

-- constants
---@enum Direction
local Direction <const> = {
    LEFT = -1,
    RIGHT = 1,
    UP = -2,
    DOWN = 2,
    WIDTH = 3,
    HEIGHT = 4,
    ASCENDING = 5,
    DESCENDING = 6,
}
-- hs.settings key for persisting is_floating, stored as an array of window id
local IsFloatingKey <const> = "PaperWM_is_floating"

---@class PaperWM
---@field Yabai Yabai
---@field window_list WindowList 3D array of tiles in order of [space][x][y]
---@field index_table table<integer, Index> dictionary of {space, x, y} with window id for keys
---@field ui_watchers table<integer, hs.uielement.watcher> dictionary of uielement watchers with window id for keys
---@field is_floating table<integer, boolean> dictionary of boolean with window id for keys
---@field is_maximized table<integer, boolean> dictionary of boolean with window id for keys
---@field window_filter WindowFilter  filter for windows to manage
---@field app_switcher hs.window.switcher
---@field last_focus integer|nil
---@field mouseUpWatcher hs.eventtap|nil
---@field screen_watcher hs.screen.watcher
---@field swipe_gain number increase this number to make windows move futher when swiping
---@field swipe_fingers integer number of fingers to detect a horizontal swipe, set to 0 to disable
---@field logger hs.logger
---@field screen_margin integer size of the on-screen margin to place off-screen windows
---@field window_gap integer gap between windows
---@field window_ratios number[]
---@field prev_focused_window Window|nil
local PaperWM = {
    name = "YabaiPaperWM",
    version = "0.1",
    author = "sebb3, on the shoulders of mogenson",
    homepage = "https://github.com/sebb3/YabaiPaperWM.spoon",
    license = "MIT - https://opensource.org/licenses/MIT",
    default_hotkeys = {
        stop_events = { { "alt", "cmd", "shift" }, "q" },
        refresh_windows = { { "alt", "cmd", "shift" }, "r" },
        toggle_floating = { { "alt", "cmd", "shift" }, "escape" },
        focus_left = { { "alt", "cmd" }, "left" },
        focus_right = { { "alt", "cmd" }, "right" },
        focus_up = { { "alt", "cmd" }, "up" },
        focus_down = { { "alt", "cmd" }, "down" },
        swap_left = { { "alt", "cmd", "shift" }, "left" },
        swap_right = { { "alt", "cmd", "shift" }, "right" },
        swap_up = { { "alt", "cmd", "shift" }, "up" },
        swap_down = { { "alt", "cmd", "shift" }, "down" },
        center_window = { { "alt", "cmd" }, "c" },
        full_width = { { "alt", "cmd" }, "f" },
        cycle_width = { { "alt", "cmd" }, "r" },
        cycle_height = { { "alt", "cmd", "shift" }, "r" },
        reverse_cycle_width = { { "ctrl", "alt", "cmd" }, "r" },
        reverse_cycle_height = { { "ctrl", "alt", "cmd", "shift" }, "r" },
        slurp_in = { { "alt", "cmd" }, "i" },
        barf_out = { { "alt", "cmd" }, "o" },
        switch_space_l = { { "alt", "cmd" }, "," },
        switch_space_r = { { "alt", "cmd" }, "." },
        switch_space_1 = { { "alt", "cmd" }, "1" },
        switch_space_2 = { { "alt", "cmd" }, "2" },
        switch_space_3 = { { "alt", "cmd" }, "3" },
        switch_space_4 = { { "alt", "cmd" }, "4" },
        move_window_1 = { { "alt", "cmd", "shift" }, "1" },
        move_window_2 = { { "alt", "cmd", "shift" }, "2" },
        move_window_3 = { { "alt", "cmd", "shift" }, "3" },
        move_window_4 = { { "alt", "cmd", "shift" }, "4" },
    },
    window_list = {},
    index_table = {},
    ui_watchers = {},
    is_floating = {},
    x_positions = {},
    window_gap = 8,
    window_ratios = { 0.23607, 0.38195, 0.61804 },
    screen_margin = 1,
    swipe_fingers = 0,
    swipe_gain = 1,
    logger = hs.logger.new("PaperWM"),
}

PaperWM.__index = PaperWM

-- Lifecycle functions
--
function PaperWM:init()
    self.window_filter = WindowFilter.new():setOverrideFilter({
        visible = true,
        fullscreen = false,
        hasTitlebar = true,
        allowRoles = "AXStandardWindow",
    })
    self.same_app_filter = WindowFilter.new({}):setFilters({
        default = {
            activeApplication = true,
        },
    })
    self.on_screen_filter = WindowFilter.copy(self.window_filter)
        :setRegions(hs.fnutils.map(hs.screen.allScreens(), function(screen)
            return screen:fullFrame()
        end))
    self.app_switcher = hs.window.switcher.new(PaperWM.same_app_filter)
    self.window_list = setmetatable(self.window_list, {
        ---@param list WindowList
        __tostring = function(list)
            local result = ""
            for i, v in pairs(list) do
                result = result .. string.format("Space %s: \n", i)

                for x, ys in pairs(v) do
                    result = result .. string.format("x %d:\n", x)
                    for y, w in pairs(ys) do
                        result = result .. string.format("y %d:\n", y)
                        result = result .. string.format("window: %s\n", w:title())
                    end
                end
            end
            return result
        end,
    })
    self.screen_watcher = Screen.watcher.new(function()
        self:refreshWindows()
    end)
end

---start automatic window tiling
---@return PaperWM
function PaperWM:start()
    -- check for some settings
    if not self:screensHaveSeparateSpaces() then
        self.logger.e("please check 'Displays have separate Spaces' in System Preferences -> Mission Control")
    end

    -- clear state
    for i, _ in pairs(self.window_list) do
        self.window_list[i] = {}
    end
    self.index_table = {}
    self.ui_watchers = {}
    self.is_floating = {}
    self.x_positions = {}

    self.Yabai = spoon.Yabai
    assert(self.Yabai, "Yabai spoon not found")
    -- restore saved is_floating state, filtering for valid windows
    for _, id in ipairs(self:loadFloatingList()) do
        local window = Window.get(id)
        if window and self.window_filter:isWindowAllowed(window) then
            self.is_floating[id] = true
        end
    end

    self:persistFloatingList()

    -- populate window list, index table, ui_watchers, and set initial layout
    self:refreshWindows()

    -- listen for window events
    self.window_filter:subscribe({
        WindowFilter.windowFocused,
        WindowFilter.windowVisible,
        WindowFilter.windowNotVisible,
        WindowFilter.windowFullscreened,
        WindowFilter.windowUnfullscreened,
        WindowFilter.windowDestroyed,
    }, function(window, _, event)
        self:windowEventHandler(window, event)
    end)

    hs.urlevent.bind("windowMoved", function(eventName, params)
        local window = Window.get(tonumber(params.id))
        hs.printf("Event: %s, Params: %s", eventName, hs.inspect(params))
        if window then
            self:windowEventHandler(window, "YabaiMoved")
        end
    end)

    -- watch for external monitor plug / unplug
    self.screen_watcher:start()

    -- recognize horizontal touchpad swipe gestures
    if self.swipe_fingers > 1 then
        Swipe:start(self.swipe_fingers, self:swipeHandler())
    end

    return self
end

---stop automatic window tiling
---@return PaperWM
function PaperWM:stop()
    -- stop events
    self.window_filter:unsubscribeAll()
    self.on_screen_filter:unsubscribeAll()
    self.same_app_filter:unsubscribeAll()
    self.app_switcher = nil
    self.screen_watcher:stop()
    hs.fnutils.each(self.ui_watchers, function(watcher)
        watcher:stop()
    end)

    -- fit all windows within the bounds of the screen
    for _, window in ipairs(self.window_filter:getWindows()) do
        window:setFrameInScreenBounds()
    end

    -- stop listening for touchpad swipes
    Swipe:stop()

    return self
end

---bind userdefined hotkeys to PaperWM actions
---use PaperWM.default_hotkeys for suggested defaults
---@param mapping Mapping table of actions and hotkeys
function PaperWM:bindHotkeys(mapping)
    local spec = self.actions
    hs.spoons.bindHotkeysToSpec(spec, mapping)
end

-- end lifecycle functions

-- #region WindowList
---get a column of windows for a space from the window_list
---@param space SpaceIdx
---@param col number
---@return Window[]
---@private
function PaperWM:getColumn(space, col)
    return (self.window_list[space] or {})[col]
end

---get a window in a row, in a column, in a space from the window_list
---@param space SpaceIdx
---@param col integer
---@param row integer
---@return Window
---@private
function PaperWM:getWindow(space, col, row)
    return (self:getColumn(space, col) or {})[row]
end

---update the column number in window_list to be ascending from provided column up
---@param space SpaceIdx
---@param column number
---@private
function PaperWM:updateIndexTable(space, column)
    local columns = self.window_list[space] or {}
    for col = column, #columns do
        for row, window in ipairs(self:getColumn(space, col)) do
            self.index_table[window:id()] = { space = space, col = col, row = row }
        end
    end
end

---return the first window that's completely on the screen
---@param space SpaceIdx space to lookup windows
---@param screen_frame hs.geometry the coordinates of the screen
---@param direction Direction|nil either LEFT or RIGHT
---@return Window|nil
---@private
function PaperWM:getFirstVisibleWindow(space, screen_frame, direction)
    direction = direction or Direction.LEFT
    local distance = math.huge
    local closest = nil
    for _, windows in ipairs(self.window_list[space] or {}) do
        local window = windows[1] -- take first window in column
        local d = (function()
            local windowFrame = window:frame()
            if direction == Direction.LEFT then
                return windowFrame.x - screen_frame.x
            elseif direction == Direction.RIGHT then
                return screen_frame.x2 - windowFrame.x2
            end
        end)() or math.huge
        if d >= 0 and d < distance then
            distance = d
            closest = window
        end
    end
    return closest
end

---get the tileable bounds for a screen
---@param screen hs.screen
---@private
function PaperWM:getCanvas(screen)
    local screen_frame = screen:frame()
    return Rect(
        screen_frame.x + self.window_gap,
        screen_frame.y + 40,
        screen_frame.w - (2 * self.window_gap),
        screen_frame.h - 80
    )
end

---update the virtual x position for a table of windows on the specified space
---@param space SpaceIdx
---@param windows Window[]
---@private
function PaperWM:updateVirtualPositions(space, windows, x)
    if self.swipe_fingers == 0 then
        return
    end
    if not self.x_positions[space] then
        self.x_positions[space] = {}
    end
    for _, window in ipairs(windows) do
        self.x_positions[space][window] = x
    end
end

---save the is_floating list to settings
function PaperWM:persistFloatingList()
    local persisted = {}
    for k, _ in pairs(self.is_floating) do
        table.insert(persisted, k)
    end
    hs.settings.set(IsFloatingKey, persisted)
end

function PaperWM:loadFloatingList()
    return hs.settings.get(IsFloatingKey) or {}
end

---add a new window to be tracked and automatically tiled
---@param add_window Window new window to be added
---@return SpaceIdx|nil space that contains new window
function PaperWM:addWindow(add_window)
    -- A window with no tabs will have a tabCount of 0
    -- A new tab for a window will have tabCount equal to the total number of tabs
    -- All existing tabs in a window will have their tabCount reset to 0
    -- We can't query whether an exiting hs.window is a tab or not after creation
    local apple <const> = "com.apple"
    if add_window:tabCount() > 0 and add_window:application():bundleID():sub(1, #apple) == apple then
        -- It's mostly built-in Apple apps like Finder and Terminal whose tabs
        -- show up as separate windows. Third party apps like Microsoft Office
        -- use tabs that are all contained within one window and tile fine.
        hs.notify.show(
            "PaperWM",
            "Windows with tabs are not supported!",
            "See https://github.com/mogenson/PaperWM.spoon/issues/39"
        )
        return
    end

    -- check if window is already in window list
    if self.index_table[add_window:id()] then
        return
    end

    coroutine.wrap(function()
        local space = add_window:space()
        if not self.window_list[space] then
            self.window_list[space] = {}
        end

        -- find where to insert window
        local add_column = 1

        -- when addWindow() is called from a window created event:
        -- focused_window from previous window focused event will not be add_window
        -- hs.window.focusedWindow() will return add_window
        -- new window focused event for add_window has not happened yet
        if
            self.prev_focused_window
            and ((self.index_table[self.prev_focused_window:id()] or {}).space == space)
            and (self.prev_focused_window:id() ~= add_window:id())
        then
            add_column = self.index_table[self.prev_focused_window:id()].col + 1 -- insert to the right
        else
            local x = add_window:frame().center.x
            for col, windows in ipairs(self.window_list[space]) do
                if x < windows[1]:frame().center.x then
                    add_column = col
                    break
                end
            end
        end

        -- add window
        table.insert(self.window_list[space], add_column, { add_window })

        -- update index table
        self:updateIndexTable(space, add_column)

        -- subscribe to window moved events
        self.ui_watchers[add_window:id()] = add_window
            :newWatcher(function()
                -- coroutine.wrap(function()
                --     if self.mouseUpWatcher and self.mouseUpWatcher:isEnabled() then
                --         return
                --     end
                --     if window:isDragging() then
                --         self:watchForDragRelease(window, event)
                --         return
                --     end
                --     self:windowEventHandler(window, event)
                -- end)()
            end)
            :start({ Watcher.windowMoved, Watcher.windowResized })

        return space
    end)()
end

---remove a window from being tracked and automatically tiled
---@param remove_window Window window to be removed
---@param skip_new_window_focus boolean|nil don't focus a nearby window if true
---@return SpaceIdx|nil space that contained removed window
function PaperWM:removeWindow(remove_window, skip_new_window_focus)
    -- get index of window
    local remove_index = self.index_table[remove_window:id()]
    if not remove_index then
        self.logger.e("remove index not found")
        return
    end
    if not skip_new_window_focus then -- find nearby window to focus
        if self.last_focus == remove_window:id() then
            for _, direction in ipairs({
                Direction.DOWN,
                Direction.UP,
                Direction.LEFT,
                Direction.RIGHT,
            }) do
                if self:focusWindow(direction, remove_index) then
                    break
                end
            end
        end
    end

    -- remove window
    table.remove(self.window_list[remove_index.space][remove_index.col], remove_index.row)
    if #self.window_list[remove_index.space][remove_index.col] == 0 then
        table.remove(self.window_list[remove_index.space], remove_index.col)
    end

    -- remove watcher
    self.ui_watchers[remove_window:id()]:stop()
    self.ui_watchers[remove_window:id()] = nil;

    -- clear window position
    (self.x_positions[remove_index.space] or {})[remove_window] = nil

    -- update index table
    self.index_table[remove_window:id()] = nil
    self:updateIndexTable(remove_index.space, remove_index.col)

    -- remove if space is empty
    if #self.window_list[remove_index.space] == 0 then
        self.window_list[remove_index.space] = nil
        self.x_positions[remove_index.space] = nil
    end

    return remove_index.space -- return space for removed window
end

--#endregion WindowList

--#region Events
function PaperWM:watchForDragRelease(window, event)
    self.mouseUpWatcher = hs.eventtap
        .new({ hs.eventtap.event.types.leftMouseUp }, function()
            if self.mouseUpWatcher then
                self.mouseUpWatcher:stop()
                self.mouseUpWatcher = nil
            end

            self:windowEventHandler(window, event)
        end)
        :start()
end

---callback for window events
---@param window Window
---@param event string name of the event
function PaperWM:windowEventHandler(window, event)
    self.logger.df("Event: %s, dragging: %s", event, hs.inspect(hs.eventtap.checkMouseButtons()))
    if event == "YabaiMoved" and hs.eventtap.checkMouseButtons()[1] == true then
        return
    end
    if not coroutine.isyieldable() then
        coroutine.wrap(partial(self.windowEventHandler, self, window, event))()
        return
    end

    self.logger.df("%s for [%s] id: %d. isDragging: %s", event, window, window:id(), window:isDragging())

    local space = nil

    if event == "windowFocused" then
        self.prev_focused_window = window -- for addWindow()
    elseif event == "windowVisible" or event == "windowUnfullscreened" then
        self:addWindow(window)
    elseif event == "windowDestroyed" then
        if self.is_floating[window:id()] then
            self.is_floating[window:id()] = nil
            self:persistFloatingList()
        end
    elseif event == "windowNotVisible" then
        space = self:removeWindow(window)
    elseif event == "windowFullscreened" then
        space = self:removeWindow(window, true) -- don't focus new window if fullscreened
    elseif event == "AXWindowMoved" or event == "AXWindowResized" then
    end
    space = space or window:space()
    self:tileSpace(space)
end

---generate callback fucntion for touchpad swipe gesture event
---@param self PaperWM
function PaperWM:swipeHandler()
    -- saved upvalues between callback function calls
    local space, screen_frame = nil, nil

    ---callback for touchpad swipe gesture event
    ---@param id number unique id across callbacks for the same swipe
    ---@param eventType number one of Swipe.BEGIN, Swipe.MOVED, Swipe.END
    ---@param dx number change in horizonal position since last callback: between 0 and 1
    ---@param dy number change in vertical position since last callback: between 0 and 1
    return function(id, eventType, dx, dy)
        if eventType == Swipe.BEGIN then
            self.logger.df("new swipe: %d", id)

            -- use focused window for space to scroll windows
            local focused_window = Window.focusedWindow()
            if not focused_window then
                self.logger.d("focused window not found")
                return
            end

            -- get focused window index
            local focused_index = self.index_table[focused_window:id()]
            if not focused_index then
                self.logger.e("focused index not found")
                return
            end

            local screen = self.Yabai:getScreenForSpace(focused_index.space)
            if not screen then
                self.logger.e("no screen for space")
                return
            end

            -- cache upvalues
            screen_frame = screen:frame()
            space = focused_index.space

            -- stop all window moved watchers
            for window, _ in pairs(self.x_positions[space] or {}) do
                if not window then
                    break
                end
                local watcher = self.ui_watchers[window:id()]
                if watcher then
                    watcher:stop()
                end
            end
        elseif eventType == Swipe.END then
            self.logger.df("swipe end: %d", id)

            if not space or not screen_frame then
                return -- no cached upvalues
            end

            -- restart all window moved watchers
            for window, _ in pairs(self.x_positions[space] or {}) do
                if not window then
                    break
                end
                local watcher = self.ui_watchers[window:id()]
                if watcher then
                    watcher:start({ Watcher.windowMoved, Watcher.windowResized })
                end
            end

            -- ensure a focused window is on screen
            local focused_window = Window.focusedWindow()
            if focused_window then
                local frame = focused_window:frame()
                local visible_window = (function()
                    if frame.x < screen_frame.x then
                        return self:getFirstVisibleWindow(space, screen_frame, Direction.LEFT)
                    elseif frame.x2 > screen_frame.x2 then
                        return self:getFirstVisibleWindow(space, screen_frame, Direction.RIGHT)
                    end
                end)()
                if visible_window then
                    visible_window:focus()
                else
                    self:tileSpace(space)
                end
            else
                self.logger.e("no focused window at end of swipe")
            end

            -- clear cached upvalues
            space, screen_frame = nil, nil
        elseif eventType == Swipe.MOVED then
            if not space or not screen_frame then
                return -- no cached upvalues
            end

            if math.abs(dy) >= math.abs(dx) then
                return -- only handle horizontal swipes
            end

            dx = math.floor(self.swipe_gain * dx * screen_frame.w)

            local left_margin = screen_frame.x + self.screen_margin
            local right_margin = screen_frame.x2 - self.screen_margin

            for window, x in pairs(self.x_positions[space] or {}) do
                if not window then
                    break
                end
                x = x + dx
                local frame = window:frame()
                if dx > 0 then -- scroll right
                    frame.x = math.min(x, right_margin)
                else -- scroll left
                    frame.x = math.max(x, left_margin - frame.w)
                end
                window:setTopLeft(frame.x, frame.y) -- avoid the animationDuration
                self.x_positions[space][window] = x -- update virtual position
            end
        end
    end
end

function PaperWM:windowMoved(id, grabbed)
    hs.printf("Window moved: %s, grabbed: %s", id, grabbed)
    local window = Window.get(id)
    if window then
        self:windowEventHandler(window, "YabaiMoved")
    end
end

--#endregion

function PaperWM:screensHaveSeparateSpaces()
    return hs.spaces.screensHaveSeparateSpaces()
end

--#region Tiling

---tile a column of window by moving and resizing
---@param windows Window[] column of windows
---@param bounds hs.geometry bounds to constrain column of tiled windows
---@param h number|nil set windows to specified height
---@param w number|nil set windows to specified width
---@param id number|nil id of window to set specific height
---@param h4id number|nil specific height for provided window id
---@return number width of tiled column
function PaperWM:tileColumn(windows, bounds, h, w, id, h4id)
    local last_window, frame
    for _, window in ipairs(windows) do
        frame = window:frame()
        w = w or frame.w -- take given width or width of first window
        if bounds.x then -- set either left or right x coord
            frame.x = bounds.x
        elseif bounds.x2 then
            frame.x = bounds.x2 - w
        end
        if h then -- set height if given
            if id and h4id and window:id() == id then
                frame.h = h4id -- use this height for window with id
            else
                frame.h = h -- use this height for all other windows
            end
        end
        frame.y = bounds.y
        frame.w = w
        frame.y2 = math.min(frame.y2, bounds.y2) -- don't overflow bottom of bounds
        self:moveWindow(window, frame)
        bounds.y = math.min(frame.y2 + self.window_gap, bounds.y2)
        last_window = window
    end
    -- expand last window height to bottom
    if frame.y2 ~= bounds.y2 then
        frame.y2 = bounds.y2
        self:moveWindow(last_window, frame)
    end
    return w -- return width of column
end

---tile all column in a space by moving and resizing windows
---@param space SpaceIdx
function PaperWM:tileSpace(space)
    assert(space)

    if not coroutine.isyieldable() then
        coroutine.wrap(partial(self.tileSpace, self, space))()
        return
    end

    -- find screen for space
    local screen = self.Yabai:getScreenForSpace(space)
    assert(screen)

    -- if focused window is in space, tile from that
    local focused_window = Window.focusedWindow()
    local anchor_window = (function()
        if focused_window and not self.is_floating[focused_window:id()] and focused_window:space() == space then
            return focused_window
        else
            return self:getFirstVisibleWindow(space, screen:frame())
        end
    end)()

    if not anchor_window then
        self.logger.e("no anchor window in space")
        return
    end

    local anchor_index = self.index_table[anchor_window:id()]
    if not anchor_index then
        self.logger.e("anchor index not found")
        return -- bail
    end

    -- get some global coordinates
    local screen_frame <const> = screen:frame()
    local left_margin <const> = screen_frame.x + self.screen_margin
    local right_margin <const> = screen_frame.x2 - self.screen_margin
    local canvas <const> = self:getCanvas(screen)

    -- make sure anchor window is on screen
    local anchor_frame = anchor_window:frame()
    anchor_frame.x = math.max(anchor_frame.x, canvas.x)
    anchor_frame.w = math.min(anchor_frame.w, canvas.w)
    anchor_frame.h = math.min(anchor_frame.h, canvas.h)
    if anchor_frame.x2 > canvas.x2 then
        anchor_frame.x = canvas.x2 - anchor_frame.w
    end

    -- adjust anchor window column
    local column = self:getColumn(space, anchor_index.col)
    if not column then
        self.logger.e("no anchor window column")
        return
    end

    -- TODO: need a minimum window height
    if #column == 1 then
        anchor_frame.y, anchor_frame.h = canvas.y, canvas.h
        self:moveWindow(anchor_window, anchor_frame)
    else
        local n = #column - 1 -- number of other windows in column
        local h = math.max(0, canvas.h - anchor_frame.h - (n * self.window_gap)) // n
        local bounds = {
            x = anchor_frame.x,
            x2 = nil,
            y = canvas.y,
            y2 = canvas.y2,
        }
        self:tileColumn(column, bounds, h, anchor_frame.w, anchor_window:id(), anchor_frame.h)
    end
    self:updateVirtualPositions(space, column, anchor_frame.x)

    -- tile windows from anchor right
    local x = anchor_frame.x2 + self.window_gap
    for col = anchor_index.col + 1, #(self.window_list[space] or {}) do
        local bounds = {
            x = math.min(x, right_margin),
            x2 = nil,
            y = canvas.y,
            y2 = canvas.y2,
        }
        local column = self:getColumn(space, col)
        local width = self:tileColumn(column, bounds)
        self:updateVirtualPositions(space, column, x)
        x = x + width + self.window_gap
    end

    -- tile windows from anchor left
    local x = anchor_frame.x
    local x2 = math.max(anchor_frame.x - self.window_gap, left_margin)
    for col = anchor_index.col - 1, 1, -1 do
        local bounds = { x = nil, x2 = x2, y = canvas.y, y2 = canvas.y2 }
        local column = self:getColumn(space, col)
        local width = self:tileColumn(column, bounds)
        x = x - width - self.window_gap
        self:updateVirtualPositions(space, column, x)
        x2 = math.max(x2 - width - self.window_gap, left_margin)
    end
end

---get all windows across all spaces and retile them
function PaperWM:refreshWindows()
    if not coroutine.isyieldable() then
        coroutine.wrap(partial(self.refreshWindows, self))()
        return
    end

    self.logger.d("Refreshing windows")

    -- get all windows across spaces
    local all_windows = self.window_filter:getWindows()
    table.sort(all_windows, function(a, b)
        return a:frame().x > b:frame().x
    end)

    local retile_spaces = {} -- spaces that need to be retiled
    for _, window in ipairs(all_windows) do
        local index = self.index_table[window:id()]
        if self.is_floating[window:id()] then
            -- ignore floating windows
        elseif not index then
            -- add window
            local space = self:addWindow(window)
            if space then
                retile_spaces[space] = true
            end
        elseif index.space ~= window:space() then
            -- move to window list in new space
            self:removeWindow(window)
            local space = self:addWindow(window)
            if space then
                retile_spaces[space] = true
            end
        end
    end

    -- retile spaces
    for space, _ in pairs(retile_spaces) do
        self:tileSpace(space)
    end
end

--#endregion

---move focus to a new window next to the currently focused window
---@param direction Direction use either Direction UP, DOWN, LEFT, or RIGHT
---@param focused_index Index index of focused window within the window_list
function PaperWM:focusWindow(direction, focused_index)
    if not focused_index then
        -- get current focused window
        local focused_window = Window.focusedWindow()
        if not focused_window then
            self.logger.d("focused window not found")
            return
        end

        -- get focused window index
        focused_index = self.index_table[focused_window:id()]
    end

    if not focused_index then
        self.logger.e("focused index not found")
        return
    end

    -- get new focused window
    local new_focused_window = nil
    if direction == Direction.LEFT or direction == Direction.RIGHT then
        -- walk down column, looking for match in neighbor column
        for row = focused_index.row, 1, -1 do
            new_focused_window = self:getWindow(focused_index.space, focused_index.col + direction, row)
            if new_focused_window then
                break
            end
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        new_focused_window =
            self:getWindow(focused_index.space, focused_index.col, focused_index.row + (direction // 2))

        if not new_focused_window then
            local candidateWindows = {}
            if direction == Direction.DOWN then
                candidateWindows = self.on_screen_filter:windowsToSouth()
            end
            if direction == Direction.UP then
                candidateWindows = self.on_screen_filter:windowsToNorth()
            end
            if candidateWindows then
                new_focused_window = candidateWindows[1]
            end
        end
    end

    if not new_focused_window then
        self.logger.d("new focused window not found")
        return
    end

    -- focus new window, windowFocused event will be emited immediately
    new_focused_window:focus()

    -- try to prevent MacOS from stealing focus away to another window
    self.Yabai:focusWindow(new_focused_window:id())
    return new_focused_window
end

---swap the focused window with a window next to it
---if swapping horizontally and the adjacent window is in a column, swap the
---entire column. if swapping vertically and the focused window is in a column,
---swap positions within the column
---@param direction Direction use Direction LEFT, RIGHT, UP, or DOWN
function PaperWM:swapWindows(direction)
    -- use focused window as source window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return
    end

    -- get focused window index
    local focused_index = self.index_table[focused_window:id()]
    if not focused_index then
        self.logger.e("focused index not found")
        return
    end

    if direction == Direction.LEFT or direction == Direction.RIGHT then
        -- get target windows
        local target_index = { col = focused_index.col + direction }
        local target_column = self:getColumn(focused_index.space, target_index.col)
        if not target_column then
            self.logger.d("target column not found")
            return
        end

        -- swap place in window list
        local focused_column = self:getColumn(focused_index.space, focused_index.col)
        self.window_list[focused_index.space][target_index.col] = focused_column
        self.window_list[focused_index.space][focused_index.col] = target_column

        -- update index table
        for row, window in ipairs(target_column) do
            self.index_table[window:id()] = {
                space = focused_index.space,
                col = focused_index.col,
                row = row,
            }
        end
        for row, window in ipairs(focused_column) do
            self.index_table[window:id()] = {
                space = focused_index.space,
                col = target_index.col,
                row = row,
            }
        end

        -- swap frames
        local focused_frame = focused_window:frame()
        local target_frame = target_column[1]:frame()
        if direction == Direction.LEFT then
            focused_frame.x = target_frame.x
            target_frame.x = focused_frame.x2 + self.window_gap
        else -- Direction.RIGHT
            target_frame.x = focused_frame.x
            focused_frame.x = target_frame.x2 + self.window_gap
        end
        for _, window in ipairs(target_column) do
            local frame = window:frame()
            frame.x = target_frame.x
            self:moveWindow(window, frame)
        end
        for _, window in ipairs(focused_column) do
            local frame = window:frame()
            frame.x = focused_frame.x
            self:moveWindow(window, frame)
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        -- get target window
        local target_index = {
            space = focused_index.space,
            col = focused_index.col,
            row = focused_index.row + (direction // 2),
        }
        local target_window = self:getWindow(target_index.space, target_index.col, target_index.row)
        if not target_window then
            self.logger.d("target window not found")
            return
        end

        -- swap places in window list
        self.window_list[target_index.space][target_index.col][target_index.row] = focused_window
        self.window_list[focused_index.space][focused_index.col][focused_index.row] = target_window

        -- update index table
        self.index_table[target_window:id()] = focused_index
        self.index_table[focused_window:id()] = target_index

        -- swap frames
        local focused_frame = focused_window:frame()
        local target_frame = target_window:frame()
        if direction == Direction.UP then
            focused_frame.y = target_frame.y
            target_frame.y = focused_frame.y2 + self.window_gap
        else -- Direction.DOWN
            target_frame.y = focused_frame.y
            focused_frame.y = target_frame.y2 + self.window_gap
        end
        self:moveWindow(focused_window, focused_frame)
        self:moveWindow(target_window, target_frame)
    end

    -- update layout
    self:tileSpace(focused_index.space)
end

---move the focused window to the center of the screen, horizontally
---don't resize the window or change it's vertical position
function PaperWM:centerWindow()
    if not coroutine.isyieldable() then
        coroutine.wrap(partial(self.centerWindow, self))()
        return
    end
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return
    end

    -- get global coordinates
    local focused_frame = focused_window:frame()
    local screen_frame = focused_window:screen():frame()

    -- center window
    focused_frame.x = screen_frame.x + (screen_frame.w // 2) - (focused_frame.w // 2)
    self:moveWindow(focused_window, focused_frame)

    -- update layout
    local space = focused_window:space()
    self:tileSpace(space)
end

---set the focused window to the width of the screen and cache the original width
---restore the original window size if called again, don't change the height
function PaperWM:toggleWindowFullWidth()
    local width_cache = {}
    return function()
        -- get current focused window
        local focused_window = Window.focusedWindow()
        if not focused_window then
            self.logger.d("focused window not found")
            return
        end

        local canvas = self:getCanvas(focused_window:screen())
        local focused_frame = focused_window:frame()
        local id = focused_window:id()

        local width = width_cache[id]
        if width then
            -- restore window width
            focused_frame.x = canvas.x + ((canvas.w - width) / 2)
            focused_frame.w = width
            width_cache[id] = nil
        else
            -- set window to fullscreen width
            width_cache[id] = focused_frame.w
            focused_frame.x, focused_frame.w = canvas.x, canvas.w
        end

        -- update layout
        self:moveWindow(focused_window, focused_frame)
        local space = focused_window:space()
        self:tileSpace(space)
    end
end

---resize the width or height of the window, keeping the other dimension the
---same. cycles through the ratios specified in PaperWM.window_ratios
---@param direction Direction use Direction.WIDTH or Direction.HEIGHT
---@param cycle_direction Direction use Direction.ASCENDING or DESCENDING
function PaperWM:cycleWindowSize(direction, cycle_direction)
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return
    end

    local function findNewSize(area_size, frame_size, cycle_direction)
        local sizes = {}
        local new_size = nil
        if cycle_direction == Direction.ASCENDING then
            for index, ratio in ipairs(self.window_ratios) do
                sizes[index] = ratio * (area_size + self.window_gap) - self.window_gap
            end

            -- find new size
            new_size = sizes[1]
            for _, size in ipairs(sizes) do
                if size > frame_size + 10 then
                    new_size = size
                    break
                end
            end
        elseif cycle_direction == Direction.DESCENDING then
            for index, ratio in ipairs(self.window_ratios) do
                sizes[index] = ratio * (area_size + self.window_gap) - self.window_gap
            end

            -- find new size, starting from the end
            new_size = sizes[#sizes] -- Start with the largest size
            for i = #sizes, 1, -1 do
                if sizes[i] < frame_size - 10 then
                    new_size = sizes[i]
                    break
                end
            end
        else
            self.logger.e("cycle_direction must be either Direction.ASCENDING or Direction.DESCENDING")
        end

        return new_size
    end

    local canvas = self:getCanvas(focused_window:screen())
    local focused_frame = focused_window:frame()

    if direction == Direction.WIDTH then
        local new_width = findNewSize(canvas.w, focused_frame.w, cycle_direction)
        focused_frame.x = focused_frame.x + ((focused_frame.w - new_width) // 2)
        focused_frame.w = new_width
    elseif direction == Direction.HEIGHT then
        local new_height = findNewSize(canvas.h, focused_frame.h, cycle_direction)
        focused_frame.y = math.max(canvas.y, focused_frame.y + ((focused_frame.h - new_height) // 2))
        focused_frame.h = new_height
        focused_frame.y = focused_frame.y - math.max(0, focused_frame.y2 - canvas.y2)
    else
        self.logger.e("direction must be either Direction.WIDTH or Direction.HEIGHT")
        return
    end

    -- apply new size
    self:moveWindow(focused_window, focused_frame)

    -- update layout
    local space = focused_window:space()
    self:tileSpace(space)
end

---take the current focused window and move it into the bottom of
---the column to the left
function PaperWM:slurpWindow()
    -- TODO paperwm behavior:
    -- add top window from column to the right to bottom of current column
    -- if no colum to the right and current window is only window in current column,
    -- add current window to bottom of column to the left

    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return
    end

    -- get window index
    local focused_index = self.index_table[focused_window:id()]
    if not focused_index then
        self.logger.e("focused index not found")
        return
    end

    -- get column to left
    local column = self:getColumn(focused_index.space, focused_index.col - 1)
    if not column then
        self.logger.d("column not found")
        return
    end

    -- remove window
    table.remove(self.window_list[focused_index.space][focused_index.col], focused_index.row)
    if #self.window_list[focused_index.space][focused_index.col] == 0 then
        table.remove(self.window_list[focused_index.space], focused_index.col)
    end

    -- append to end of column
    table.insert(column, focused_window)

    -- update index table
    local num_windows = #column
    self.index_table[focused_window:id()] = {
        space = focused_index.space,
        col = focused_index.col - 1,
        row = num_windows,
    }
    self:updateIndexTable(focused_index.space, focused_index.col)

    -- adjust window frames
    local canvas = self:getCanvas(focused_window:screen())
    local bounds = {
        x = column[1]:frame().x,
        x2 = nil,
        y = canvas.y,
        y2 = canvas.y2,
    }
    local h = math.max(0, canvas.h - ((num_windows - 1) * self.window_gap)) // num_windows
    self:tileColumn(column, bounds, h)

    -- update layout
    self:tileSpace(focused_index.space)
end

---remove focused window from it's current column and place into
---a new column to the right
function PaperWM:barfWindow()
    -- TODO paperwm behavior:
    -- remove bottom window of current column
    -- place window into a new column to the right--

    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return
    end

    -- get window index
    local focused_index = self.index_table[focused_window:id()]
    if not focused_index then
        self.logger.e("focused index not found")
        return
    end

    -- get column
    local column = self:getColumn(focused_index.space, focused_index.col)
    if #column == 1 then
        self.logger.d("only window in column")
        return
    end

    -- remove window and insert in new column
    table.remove(column, focused_index.row)
    table.insert(self.window_list[focused_index.space], focused_index.col + 1, { focused_window })

    -- update index table
    self:updateIndexTable(focused_index.space, focused_index.col)

    -- adjust window frames
    local num_windows = #column
    local canvas = self:getCanvas(focused_window:screen())
    local focused_frame = focused_window:frame()
    local bounds = { x = focused_frame.x, x2 = nil, y = canvas.y, y2 = canvas.y2 }
    local h = math.max(0, canvas.h - ((num_windows - 1) * self.window_gap)) // num_windows
    focused_frame.y = canvas.y
    focused_frame.x = focused_frame.x2 + self.window_gap
    focused_frame.h = canvas.h
    self:moveWindow(focused_window, focused_frame)
    self:tileColumn(column, bounds, h)

    -- update layout
    self:tileSpace(focused_index.space)
end

---switch to a Mission Control space
---@param index SpaceIdx incremental id for space
function PaperWM:switchToSpace(index)
    assert(index)
    if not coroutine.isyieldable() then
        coroutine.wrap(partial(self.switchToSpace, self, index))()
        return
    end

    local screen = self.Yabai:getScreenForSpace(index)
    local window = self:getFirstVisibleWindow(index, screen:frame())
    self.Yabai:focusSpace(index)
    if window then
        window:focus()
    end
end

---switch to a Mission Control space to the left or right of current space
---@param direction Direction use Direction.LEFT or Direction.RIGHT
function PaperWM:incrementSpace(direction)
    if direction ~= Direction.LEFT and direction ~= Direction.RIGHT then
        self.logger.d("move is invalid, left and right only")
        return
    end

    self.Yabai:focusSpace(direction == Direction.RIGHT and "next" or "prev")
end

function PaperWM:moveWindowToAdjacentSpace(direction)
    if direction ~= Direction.LEFT and direction ~= Direction.RIGHT then
        self.logger.d("move is invalid, left and right only")
        return
    end

    self.Yabai:moveToSpace(direction == Direction.RIGHT and "next" or "prev", Window.focusedWindow():id())
end

---move focused window to a Mission Control space
---@param index number space index
function PaperWM:moveWindowToSpace(index)
    local focused_window = Window.focusedWindow()
    if not focused_window then
        self.logger.d("focused window not found")
        return
    end

    local focused_index = self.index_table[focused_window:id()]
    if not focused_index then
        self.logger.e("focused index not found")
        return
    end
    coroutine.wrap(partial(self.Yabai.moveToSpace, self.Yabai, index, focused_window:id()))()

    -- cache a copy of focused_window, don't switch focus when removing window
    local old_space = self:removeWindow(focused_window, true)
    if not old_space then
        self.logger.e("can't remove focused window")
        return
    end

    self:addWindow(focused_window)
    self:tileSpace(old_space)
    self:tileSpace(index)
end

---move and resize a window to the coordinates specified by the frame
---disable watchers while window is moving and re-enable after
---@param window Window window to move
---@param frame hs.geometry coordinates to set window size and location
function PaperWM:moveWindow(window, frame)
    -- greater than 0.017 hs.window animation step time
    local padding <const> = 0.02

    local watcher = self.ui_watchers[window:id()]
    if not watcher then
        self.logger.e("window does not have ui watcher")
        return
    end

    if frame == window:frame() then
        self.logger.v("no change in window frame")
        return
    end

    watcher:stop()
    window:setFrame(frame)
    Timer.doAfter(Window.animationDuration + padding, function()
        watcher:start({ Watcher.windowMoved, Watcher.windowResized })
    end)
end

---add or remove focused window from the floating layer and retile the space
function PaperWM:toggleFloating(window, value)
    local _window = window or Window.focusedWindow()
    if not _window then
        self.logger.d("focused window not found")
        return
    end
    hs.printf("toggleFloating-- window: %s. value: %s", _window:title(), value)
    local id = _window:id()
    local _value
    hs.printf("toggleFloating: value = %s", value)
    if value == true then
        _value = true
    elseif value == false then
        _value = nil
    else
        _value = not self.is_floating[id] or nil
    end

    self.is_floating[id] = _value
    self:persistFloatingList()

    local space = (function()
        if self.is_floating[id] then
            if not window then
                return self:removeWindow(_window, true)
            end
        else
            return self:addWindow(window)
        end
    end)()
    if space then
        self:tileSpace(space)
    end
end

function PaperWM:nextAppWindow()
    self.app_switcher:next()
end

_G.wezTermWnd = WindowFilter.new({
    ["WezTerm"] = { allowRoles = "*" },
})

function PaperWM:dialogWindow(w)
    local frame = hs.geometry.rect(hs.screen.primaryScreen():frame())
    frame.w = frame.w / 2
    frame.h = frame.h / 2
    frame.x = frame.x + frame.w / 2
    frame.y = frame.y + frame.h / 2
    w:setFrame(frame)
end

function PaperWM:toggleConsole()
    hs.toggleConsole()
    local w = hs.console:hswindow()
    -- self:toggleFloating(w, true)
    -- self:dialogWindow(w)

    if not w then
        return
    end
    local ax = hs.axuielement.windowElement(w)
    local inputs = {}
    if not ax then
        return
    end

    ax:allDescendantElements(function(_, els)
        inputs = hs.fnutils.filter(els, function(el)
            return el:role() == "AXTextField"
        end)
    end)
    if inputs and #inputs > 0 then
        inputs[1]:focus()
    end
end

---supported window movement actions
PaperWM.actions = {
    stop_events = partial(PaperWM.stop, PaperWM),
    refresh_windows = partial(PaperWM.refreshWindows, PaperWM),
    toggle_floating = partial(PaperWM.toggleFloating, PaperWM),
    focus_left = partial(PaperWM.focusWindow, PaperWM, Direction.LEFT),
    focus_right = partial(PaperWM.focusWindow, PaperWM, Direction.RIGHT),
    focus_up = partial(PaperWM.focusWindow, PaperWM, Direction.UP),
    focus_down = partial(PaperWM.focusWindow, PaperWM, Direction.DOWN),
    swap_left = partial(PaperWM.swapWindows, PaperWM, Direction.LEFT),
    swap_right = partial(PaperWM.swapWindows, PaperWM, Direction.RIGHT),
    swap_up = partial(PaperWM.swapWindows, PaperWM, Direction.UP),
    swap_down = partial(PaperWM.swapWindows, PaperWM, Direction.DOWN),
    center_window = partial(PaperWM.centerWindow, PaperWM),
    full_width = partial(PaperWM:toggleWindowFullWidth(), PaperWM),
    cycle_width = partial(PaperWM.cycleWindowSize, PaperWM, Direction.WIDTH, Direction.ASCENDING),
    cycle_height = partial(PaperWM.cycleWindowSize, PaperWM, Direction.HEIGHT, Direction.ASCENDING),
    reverse_cycle_width = partial(PaperWM.cycleWindowSize, PaperWM, Direction.WIDTH, Direction.DESCENDING),
    reverse_cycle_height = partial(PaperWM.cycleWindowSize, PaperWM, Direction.HEIGHT, Direction.DESCENDING),
    slurp_in = partial(PaperWM.slurpWindow, PaperWM),
    barf_out = partial(PaperWM.barfWindow, PaperWM),
    switch_space_l = partial(PaperWM.incrementSpace, PaperWM, Direction.LEFT),
    switch_space_r = partial(PaperWM.incrementSpace, PaperWM, Direction.RIGHT),
    switch_space_1 = partial(PaperWM.switchToSpace, PaperWM, 1),
    switch_space_2 = partial(PaperWM.switchToSpace, PaperWM, 2),
    switch_space_3 = partial(PaperWM.switchToSpace, PaperWM, 3),
    switch_space_4 = partial(PaperWM.switchToSpace, PaperWM, 4),
    switch_space_5 = partial(PaperWM.switchToSpace, PaperWM, 5),
    switch_space_6 = partial(PaperWM.switchToSpace, PaperWM, 6),
    switch_space_7 = partial(PaperWM.switchToSpace, PaperWM, 7),
    switch_space_8 = partial(PaperWM.switchToSpace, PaperWM, 8),
    switch_space_9 = partial(PaperWM.switchToSpace, PaperWM, 9),
    move_window_l = partial(PaperWM.moveWindowToSpace, PaperWM, "prev"),
    move_window_r = partial(PaperWM.moveWindowToSpace, PaperWM, "next"),
    move_window_1 = partial(PaperWM.moveWindowToSpace, PaperWM, 1),
    move_window_2 = partial(PaperWM.moveWindowToSpace, PaperWM, 2),
    move_window_3 = partial(PaperWM.moveWindowToSpace, PaperWM, 3),
    move_window_4 = partial(PaperWM.moveWindowToSpace, PaperWM, 4),
    move_window_5 = partial(PaperWM.moveWindowToSpace, PaperWM, 5),
    move_window_6 = partial(PaperWM.moveWindowToSpace, PaperWM, 6),
    move_window_7 = partial(PaperWM.moveWindowToSpace, PaperWM, 7),
    move_window_8 = partial(PaperWM.moveWindowToSpace, PaperWM, 8),
    move_window_9 = partial(PaperWM.moveWindowToSpace, PaperWM, 9),
    next_app_window = partial(PaperWM.nextAppWindow, PaperWM),
    toggle_console = partial(PaperWM.toggleConsole, PaperWM),
}

return PaperWM
