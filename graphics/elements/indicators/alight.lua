-- Tri-State Alarm Indicator Light Graphics Element

local util    = require("scada-common.util")

local element = require("graphics.element")
local flasher = require("graphics.flasher")

---@class alarm_indicator_light
---@field label string indicator label
---@field c1 color color for off state
---@field c2 color color for alarm state
---@field c3 color color for ring-back state
---@field min_label_width? integer label length if omitted
---@field flash? boolean whether to flash on alarm state rather than stay on
---@field period? PERIOD flash period
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer 1 if omitted
---@field fg_bg? cpair foreground/background colors
---@field hidden? boolean true to hide on initial draw

-- new alarm indicator light
---@nodiscard
---@param args alarm_indicator_light
---@return graphics_element element, element_id id
local function alarm_indicator_light(args)
    assert(type(args.label) == "string", "graphics.elements.indicators.alight: label is a required field")
    assert(type(args.c1) == "number", "graphics.elements.indicators.alight: c1 is a required field")
    assert(type(args.c2) == "number", "graphics.elements.indicators.alight: c2 is a required field")
    assert(type(args.c3) == "number", "graphics.elements.indicators.alight: c3 is a required field")

    if args.flash then
        assert(util.is_int(args.period), "graphics.elements.indicators.alight: period is a required field if flash is enabled")
    end

    -- single line
    args.height = 1

    -- determine width
    args.width = math.max(args.min_label_width or 1, string.len(args.label)) + 2

    -- flasher state
    local flash_on = true

    -- blit translations
    local c1 = colors.toBlit(args.c1)
    local c2 = colors.toBlit(args.c2)
    local c3 = colors.toBlit(args.c3)

    -- create new graphics element base object
    local e = element.new(args)

    -- called by flasher when enabled
    local function flash_callback()
        e.window.setCursorPos(1, 1)

        if flash_on then
            if e.value == 2 then
                e.window.blit(" \x95", "0" .. c2, c2 .. e.fg_bg.blit_bkg)
            end
        else
            if e.value == 3 then
                e.window.blit(" \x95", "0" .. c3, c3 .. e.fg_bg.blit_bkg)
            else
                e.window.blit(" \x95", "0" .. c1, c1 .. e.fg_bg.blit_bkg)
            end
        end

        flash_on = not flash_on
    end

    -- on state change
    ---@param new_state integer indicator state
    function e.on_update(new_state)
        local was_off = e.value ~= 2

        e.value = new_state
        e.window.setCursorPos(1, 1)

        if args.flash then
            if was_off and (new_state == 2) then
                flash_on = true
                flasher.start(flash_callback, args.period)
            elseif new_state ~= 2 then
                flash_on = false
                flasher.stop(flash_callback)

                if new_state == 3 then
                    e.window.blit(" \x95", "0" .. c3, c3 .. e.fg_bg.blit_bkg)
                else
                    e.window.blit(" \x95", "0" .. c1, c1 .. e.fg_bg.blit_bkg)
                end
            end
        elseif new_state == 2 then
            e.window.blit(" \x95", "0" .. c2, c2 .. e.fg_bg.blit_bkg)
        elseif new_state == 3 then
            e.window.blit(" \x95", "0" .. c3, c3 .. e.fg_bg.blit_bkg)
        else
            e.window.blit(" \x95", "0" .. c1, c1 .. e.fg_bg.blit_bkg)
        end
    end

    -- set indicator state
    ---@param val integer indicator state
    function e.set_value(val) e.on_update(val) end

    -- write label and initial indicator light
    e.on_update(1)
    e.window.write(args.label)

    return e.complete()
end

return alarm_indicator_light
