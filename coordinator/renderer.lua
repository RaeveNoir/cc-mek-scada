local log  = require("scada-common.log")
local util = require("scada-common.util")

local core = require("graphics.core")

local main_view = require("coordinator.ui.layout.main_view")
local unit_view = require("coordinator.ui.layout.unit_view")
local style     = require("coordinator.ui.style")

local renderer = {}

-- render engine
local engine = {
    monitors = nil,
    dmesg_window = nil
}

-- UI layouts
local ui = {
    main_layout = nil,
    unit_layouts = {}
}

-- reset a display to the "default", but set text scale to 0.5
---@param monitor table monitor
---@param recolor? boolean override default color palette
local function _reset_display(monitor, recolor)
    monitor.setTextScale(0.5)
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    monitor.setCursorPos(1, 1)

    if recolor then
        -- set overridden colors
        for i = 1, #style.colors do
            monitor.setPaletteColor(style.colors[i].c, style.colors[i].hex)
        end
    else
        -- reset all colors
        for _, val in colors do
            -- colors api has constants and functions, just get color constants
            if type(val) == "number" then
                monitor.setPaletteColor(val, term.nativePaletteColor(val))
            end
        end
    end
end

-- link to the monitor peripherals
---@param monitors monitors_struct
function renderer.set_displays(monitors)
    engine.monitors = monitors
end

-- reset all displays in use by the renderer
---@param recolor? boolean true to use color palette from style
function renderer.reset(recolor)
    -- reset primary monitor
    _reset_display(engine.monitors.primary, recolor)

    -- reset unit displays
    for _, monitor in pairs(engine.monitors.unit_displays) do
        _reset_display(monitor, recolor)
    end
end

-- initialize the dmesg output window
function renderer.init_dmesg()
    local disp_x, disp_y = engine.monitors.primary.getSize()
    engine.dmesg_window = window.create(engine.monitors.primary, 1, 1, disp_x, disp_y)

    log.direct_dmesg(engine.dmesg_window)
end

-- start the coordinator GUI
function renderer.start_ui()
    -- hide dmesg
    engine.dmesg_window.setVisible(false)

    -- show main view on main monitor
    ui.main_layout = main_view(engine.monitors.primary)

    -- show unit views on unit displays
    for id, monitor in pairs(engine.monitors.unit_displays) do
        table.insert(ui.unit_layouts, unit_view(monitor, id))
    end
end

-- close out the UI
---@param recolor? boolean true to restore to color palette from style
function renderer.close_ui(recolor)
    -- clear root UI elements
    ui.main_layout = nil
    ui.unit_layouts = {}

    -- reset displays
    renderer.reset(recolor)

    -- re-draw dmesg
    engine.dmesg_window.setVisible(true)
    engine.dmesg_window.redraw()
end

return renderer
