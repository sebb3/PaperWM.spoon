local Scroll          = {}
Scroll.__index        = Scroll

local hScroll <const> = hs.eventtap.event.types.scrollWheel

function Scroll:start()
    self.watcher = hs.eventtap.new({ hScroll },
        ---@param event hs.eventtap.event
        function(event)
            local type = event:getType(true)
            hs.printf("event: %s", type)
        end)

    self.watcher:start()
end

function Scroll:stop()
    if self.watcher then
        self.watcher:stop()
        self.watcher = nil
    end
end

return Scroll
