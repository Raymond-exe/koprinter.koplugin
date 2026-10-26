local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Determine plugin directory from this file's path
local _plugin_dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."
local plugin_meta = dofile(_plugin_dir .. "/_meta.lua")

local KOPrinter = WidgetContainer:extend{
    name = "koprinter",
    is_doc_only = false,
}

function KOPrinter:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_koprinter_server", {
        category = "none",
        event = "TogglePrintServer",
        title = _("Toggle KOPrint server"),
        general = true,
    })
end

function KOPrinter:init()
    self:onDispatcherRegisterActions()
    require("printserver/simpleui"):register()
    self.ui.menu:registerToMainMenu(self)
end

function KOPrinter:addToMainMenu(menu_items)
    menu_items.koprinter = {
        text = _("KOPrinter"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    if FileSyncManager:isRunning() then
                        return _("Stop print server")
                    else
                        return _("Start print server")
                    end
                end,
                callback = function()
                    self:onTogglePrintServer()
                end,
                keep_menu_open = false,
            },
            {
                text = _("Configure server port"),
                callback = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    FileSyncManager:configurePort()
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    local T = require("ffi/util").template
                    return T(_("Hostname: %1"), FileSyncManager:getHostname() .. ".local")
                end,
                help_text = _("Name under which the server is reachable on the local network (e.g. http://koprinter.local). Works out of the box on macOS, iOS and Windows; Linux needs avahi; most Android browsers cannot resolve .local names, so use the IP address or QR code there."),
                callback = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    FileSyncManager:configureHostname()
                end,
                keep_menu_open = true,
            },
            {
                text = _("Safe mode"),
                help_text = _([[When enabled, the web interface only lists document and image formats KOReader can open, and hides sidecar metadata folders and hidden files.

Disable it to browse every file on the device, including hidden files and folders.]]),
                checked_func = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    return FileSyncManager:getSafeMode()
                end,
                callback = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    FileSyncManager:setSafeMode(not FileSyncManager:getSafeMode())
                end,
                keep_menu_open = true,
            },
            {
                text = _("Show QR code"),
                enabled_func = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    return FileSyncManager:isRunning()
                end,
                callback = function()
                    local FileSyncManager = require("printserver/filesyncmanager")
                    FileSyncManager:showQRCode()
                end,
                keep_menu_open = false,
            },
            {
                text = _("About"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    local InfoMessage = require("ui/widget/infomessage")
                    local T = require("ffi/util").template
                    UIManager:show(InfoMessage:new{
                        text = T(_("KOPrinter v%1\n\nPrint Server plugin for KOReader.\n\nForked from abrahamnm/filesync.koplugin"), plugin_meta.version),
                    })
                end,
                keep_menu_open = true,
            },
        },
    }
end

function KOPrinter:onTogglePrintServer()
    local FileSyncManager = require("printserver/filesyncmanager")
    if FileSyncManager:isRunning() then
        -- A non-silent stop refreshes the file list and reports back itself.
        FileSyncManager:stop()
    else
        FileSyncManager:checkBatteryAndStart()
    end
end

function KOPrinter:onSuspend()
    local FileSyncManager = require("printserver/filesyncmanager")
    if FileSyncManager:isRunning() then
        FileSyncManager._was_running_before_suspend = true
        FileSyncManager:stop(true) -- silent stop
    end
end

function KOPrinter:onResume()
    local FileSyncManager = require("printserver/filesyncmanager")
    if FileSyncManager._was_running_before_suspend then
        FileSyncManager._was_running_before_suspend = false
        FileSyncManager:start(true) -- silent start (no QR code)
    end
end

function KOPrinter:onEnterStandby()
    self:onSuspend()
end

function KOPrinter:onLeaveStandby()
    self:onResume()
end

--- Called by KOReader's plugin manager (v2026.07+) when the user picks
--- "Delete plugin settings". Its presence is what makes those menu entries
--- appear: settings live as flat keys in G_reader_settings, so neither
--- settings_file nor settings_key applies here.
function KOPrinter:deletePluginSettings()
    local FileSyncManager = require("printserver/filesyncmanager")
    FileSyncManager:deleteSettings()
end

--- Called by KOReader's plugin manager before the plugin directory is removed.
--- Shuts the HTTP server down (and drops the Kindle firewall rules) so nothing
--- outlives the deletion; the caller restarts KOReader afterwards.
function KOPrinter:stopPlugin(force)
    local FileSyncManager = require("printserver/filesyncmanager")
    if not FileSyncManager:isRunning() then
        return true
    end
    local ok, err = pcall(function()
        FileSyncManager:stop(true) -- silent: no UI, the caller restarts KOReader
    end)
    if not ok and force then
        return true
    end
    return ok, err
end

function KOPrinter:onExit()
    local FileSyncManager = require("printserver/filesyncmanager")
    if FileSyncManager:isRunning() then
        FileSyncManager:stop(true)
    end
end

return KOPrinter
