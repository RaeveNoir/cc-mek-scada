--
-- Nuclear Generation Facility SCADA Coordinator
--

require("/initenv").init_env()

local comms       = require("scada-common.comms")
local crash       = require("scada-common.crash")
local log         = require("scada-common.log")
local network     = require("scada-common.network")
local ppm         = require("scada-common.ppm")
local tcd         = require("scada-common.tcd")
local util        = require("scada-common.util")

local core        = require("graphics.core")

local configure   = require("coordinator.configure")
local coordinator = require("coordinator.coordinator")
local iocontrol   = require("coordinator.iocontrol")
local renderer    = require("coordinator.renderer")
local sounder     = require("coordinator.sounder")

local apisessions = require("coordinator.session.apisessions")

local COORDINATOR_VERSION = "v1.3.5"

local CHUNK_LOAD_DELAY_S = 30.0

local println = util.println
local println_ts = util.println_ts

local log_graphics = coordinator.log_graphics
local log_sys = coordinator.log_sys
local log_boot = coordinator.log_boot
local log_comms = coordinator.log_comms
local log_crypto = coordinator.log_crypto

----------------------------------------
-- get configuration
----------------------------------------

-- mount connected devices (required for monitor setup)
ppm.mount_all()

local wait_on_load = true
local loaded, monitors = coordinator.load_config()

-- if the computer just started, its chunk may have just loaded (...or the user rebooted)
-- if monitor config failed, maybe an adjacent chunk containing all or part of a monitor has not loaded yet, so keep trying
while wait_on_load and loaded == 2 and os.clock() < CHUNK_LOAD_DELAY_S do
    term.clear()
    term.setCursorPos(1, 1)
    println("There was a monitor configuration problem at boot.\n")
    println("Startup will keep trying every 2s in case of chunk load delays.\n")
    println(util.sprintf("The configurator will be started in %ds if all attempts fail.\n", math.max(0, CHUNK_LOAD_DELAY_S - os.clock())))
    println("(click to skip to the configurator)")

    local timer_id = util.start_timer(2)

    while true do
        local event, param1 = util.pull_event()
        if event == "timer" and param1 == timer_id then
            -- remount and re-attempt
            ppm.mount_all()
            loaded, monitors = coordinator.load_config()
            break
        elseif event == "mouse_click" or event == "terminate" then
            wait_on_load = false
            break
        end
    end
end

if loaded ~= 0 then
    -- try to reconfigure (user action)
    local success, error = configure.configure(loaded, monitors)
    if success then
        loaded, monitors = coordinator.load_config()
        if loaded ~= 0 then
            println(util.trinary(loaded == 2, "monitor configuration invalid", "failed to load a valid configuration") .. ", please reconfigure")
            return
        end
    else
        println("configuration error: " .. error)
        return
    end
end

-- passed checks, good now
---@cast monitors monitors_struct

local config = coordinator.config

----------------------------------------
-- log init
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("BOOTING coordinator.startup " .. COORDINATOR_VERSION)
log.info("========================================")
println(">> SCADA Coordinator " .. COORDINATOR_VERSION .. " <<")

crash.set_env("coordinator", COORDINATOR_VERSION)
crash.dbg_log_env()

----------------------------------------
-- main application
----------------------------------------

local function main()
    ----------------------------------------
    -- system startup
    ----------------------------------------

    -- log mounts now since mounting was done before logging was ready
    ppm.log_mounts()

    -- report versions/init fp PSIL
    iocontrol.init_fp(COORDINATOR_VERSION, comms.version)

    -- init renderer
    renderer.configure(config)
    renderer.set_displays(monitors)
    renderer.init_displays()
    renderer.init_dmesg()

    -- lets get started!
    log.info("monitors ready, dmesg output incoming...")

    log_graphics("displays connected and reset")
    log_sys("system start on " .. os.date("%c"))
    log_boot("starting " .. COORDINATOR_VERSION)

    ----------------------------------------
    -- setup alarm sounder subsystem
    ----------------------------------------

    local speaker = ppm.get_device("speaker")
    if speaker == nil then
        log_boot("annunciator alarm speaker not found")
        println("startup> speaker not found")
        log.fatal("no annunciator alarm speaker found")
        return
    else
        local sounder_start = util.time_ms()
        log_boot("annunciator alarm speaker connected")
        sounder.init(speaker, config.SpeakerVolume)
        log_boot("tone generation took " .. (util.time_ms() - sounder_start) .. "ms")
        log_sys("annunciator alarm configured")
        iocontrol.fp_has_speaker(true)
    end

    ----------------------------------------
    -- setup communications
    ----------------------------------------

    -- message authentication init
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        local init_time = network.init_mac(config.AuthKey)
        log_crypto("HMAC init took " .. init_time .. "ms")
    end

    -- get the communications modem
    local modem = ppm.get_wireless_modem()
    if modem == nil then
        log_comms("wireless modem not found")
        println("startup> wireless modem not found")
        log.fatal("no wireless modem on startup")
        return
    else
        log_comms("wireless modem connected")
        iocontrol.fp_has_modem(true)
    end

    -- create connection watchdog
    local conn_watchdog = util.new_watchdog(config.SVR_Timeout)
    conn_watchdog.cancel()
    log.debug("startup> conn watchdog created")

    -- create network interface then setup comms
    local nic = network.nic(modem)
    local coord_comms = coordinator.comms(COORDINATOR_VERSION, nic, conn_watchdog)
    log.debug("startup> comms init")
    log_comms("comms initialized")

    -- base loop clock (2Hz, 10 ticks)
    local MAIN_CLOCK = 0.5
    local loop_clock = util.new_clock(MAIN_CLOCK)

    ----------------------------------------
    -- start front panel & UI start function
    ----------------------------------------

    log_graphics("starting front panel UI...")

    local fp_ok, fp_message = renderer.try_start_fp()
    if not fp_ok then
        log_graphics(util.c("front panel UI error: ", fp_message))
        println_ts("front panel UI creation failed")
        log.fatal(util.c("front panel GUI render failed with error ", fp_message))
        return
    else log_graphics("front panel ready") end

    -- start up the main UI
    ---@return boolean ui_ok started ok
    local function start_main_ui()
        log_graphics("starting main UI...")

        local draw_start = util.time_ms()

        local ui_ok, ui_message = renderer.try_start_ui()
        if not ui_ok then
            log_graphics(util.c("main UI error: ", ui_message))
            log.fatal(util.c("main GUI render failed with error ", ui_message))
        else
            log_graphics("main UI draw took " .. (util.time_ms() - draw_start) .. "ms")
        end

        return ui_ok
    end

    ----------------------------------------
    -- main event loop
    ----------------------------------------

    local link_failed = false
    local ui_ok = true
    local date_format = util.trinary(config.Time24Hour, "%X \x04 %A, %B %d %Y", "%r \x04 %A, %B %d %Y")

    -- start clock
    loop_clock.start()

    log_sys("system started successfully")

    -- main event loop
    while true do
        local event, param1, param2, param3, param4, param5 = util.pull_event()

        -- handle event
        if event == "peripheral_detach" then
            local type, device = ppm.handle_unmount(param1)

            if type ~= nil and device ~= nil then
                if type == "modem" then
                    -- we only really care if this is our wireless modem
                    -- if it is another modem, handle other peripheral losses separately
                    if nic.is_modem(device) then
                        nic.disconnect()
                        log_sys("comms modem disconnected")

                        local other_modem = ppm.get_wireless_modem()
                        if other_modem then
                            log_sys("found another wireless modem, using it for comms")
                            nic.connect(other_modem)
                        else
                            -- close out main UI
                            renderer.close_ui()

                            -- alert user to status
                            log_sys("awaiting comms modem reconnect...")

                            iocontrol.fp_has_modem(false)
                        end
                    else
                        log_sys("non-comms modem disconnected")
                    end
                elseif type == "monitor" then
                    if renderer.handle_disconnect(device) then
                        log_sys("lost a configured monitor")
                    else
                        log_sys("lost an unused monitor")
                    end
                elseif type == "speaker" then
                    log_sys("lost alarm sounder speaker")
                    iocontrol.fp_has_speaker(false)
                end
            end
        elseif event == "peripheral" then
            local type, device = ppm.mount(param1)

            if type ~= nil and device ~= nil then
                if type == "modem" then
                    if device.isWireless() and not nic.is_connected() then
                        -- reconnected modem
                        log_sys("comms modem reconnected")
                        nic.connect(device)
                        iocontrol.fp_has_modem(true)
                    elseif device.isWireless() then
                        log.info("unused wireless modem reconnected")
                    else
                        log_sys("wired modem reconnected")
                    end
                elseif type == "monitor" then
                    if renderer.handle_reconnect(param1, device) then
                        log_sys(util.c("configured monitor ", param1, " reconnected"))
                    else
                        log_sys(util.c("unused monitor ", param1, " connected"))
                    end
                elseif type == "speaker" then
                    log_sys("alarm sounder speaker reconnected")
                    sounder.reconnect(device)
                    iocontrol.fp_has_speaker(true)
                end
            end
        elseif event == "monitor_resize" then
            local is_used, is_ok = renderer.handle_resize(param1)
            if is_used then
                log_sys(util.c("configured monitor ", param1, " resized, ", util.trinary(is_ok, "display still fits", "display no longer fits")))
            end
        elseif event == "timer" then
            if loop_clock.is_clock(param1) then
                -- main loop tick

                -- toggle heartbeat
                iocontrol.heartbeat()

                -- maintain connection
                if nic.is_connected() then
                    local ok, start_ui = coord_comms.try_connect()
                    if not ok then
                        link_failed = true
                        log_sys("supervisor connection failed, shutting down...")
                        log.fatal("failed to connect to supervisor")
                        break
                    elseif start_ui then
                        log_sys("supervisor connected, proceeding to main UI start")
                        ui_ok = start_main_ui()
                        if not ui_ok then break end
                    end
                end

                -- iterate sessions
                apisessions.iterate_all()

                -- free any closed sessions
                apisessions.free_all_closed()

                -- update date and time string for main display
                if coord_comms.is_linked() then
                    iocontrol.get_db().facility.ps.publish("date_time", os.date(date_format))
                end

                loop_clock.start()
            elseif conn_watchdog.is_timer(param1) then
                -- supervisor watchdog timeout
                log_comms("supervisor server timeout")

                -- close connection, main UI, and stop sounder
                coord_comms.close()
                renderer.close_ui()
                sounder.stop()
            else
                -- a non-clock/main watchdog timer event

                -- check API watchdogs
                apisessions.check_all_watchdogs(param1)

                -- notify timer callback dispatcher
                tcd.handle(param1)
            end
        elseif event == "modem_message" then
            -- got a packet
            local packet = coord_comms.parse_packet(param1, param2, param3, param4, param5)

            -- handle then check if it was a disconnect
            if coord_comms.handle_packet(packet) then
                log_comms("supervisor closed connection")

                -- close connection, main UI, and stop sounder
                coord_comms.close()
                renderer.close_ui()
                sounder.stop()
            end
        elseif event == "monitor_touch" or event == "mouse_click" or event == "mouse_up" or
               event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
            -- handle a mouse event
            renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
        elseif event == "speaker_audio_empty" then
            -- handle speaker buffer emptied
            sounder.continue()
        end

        -- check for termination request
        if event == "terminate" or ppm.should_terminate() then
            -- handle supervisor connection
            coord_comms.try_connect(true)

            if coord_comms.is_linked() then
                log_comms("terminate requested, closing supervisor connection...")
            else link_failed = true end

            coord_comms.close()
            log_comms("supervisor connection closed")

            -- handle API sessions
            log_comms("closing api sessions...")
            apisessions.close_all()
            log_comms("api sessions closed")
            break
        end
    end

    renderer.close_ui()
    renderer.close_fp()
    sounder.stop()
    log_sys("system shutdown")

    if link_failed then println_ts("failed to connect to supervisor") end
    if not ui_ok then println_ts("main UI creation failed") end

    -- close on error exit (such as UI error)
    if coord_comms.is_linked() then coord_comms.close() end

    println_ts("exited")
    log.info("exited")
end

if not xpcall(main, crash.handler) then
    pcall(renderer.close_ui)
    pcall(renderer.close_fp)
    pcall(sounder.stop)
    crash.exit()
else
    log.close()
end
