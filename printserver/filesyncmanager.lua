--- Server lifecycle management for the FileSync plugin.
--- Handles starting/stopping the HTTP server, WiFi/IP detection, battery checks,
--- QR code display, standby prevention, and Kindle firewall rules.
---
--- Key dependencies: device (KOReader), UIManager (KOReader), printserver/httpserver,

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local QRWidget = require("ui/widget/qrwidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local Utils = require("printserver/utils")
local logger = require("logger")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local FileSyncManager = {
    _running = false,
    _server = nil,
    _port = nil,
    _ip = nil,
    _was_running_before_suspend = false,
    _standby_prevented = false,
    _qr_widget = nil,
}

function FileSyncManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Port used by a fresh install. Port 631 is the default port for Ipp.
local DEFAULT_PORT = 631
-- Port used when binding a privileged port (<1024) fails.
local FALLBACK_PORT = 8080

function FileSyncManager:getPort()
    if self._port then return self._port end
    self._port = G_reader_settings:readSetting("koprinter_port", DEFAULT_PORT)
    return self._port
end

function FileSyncManager:_buildURL(host)
    local url = "http://" .. host .. ":" .. self._port
    return url
end

--- Build the URL users type or scan, based on the device IP.
function FileSyncManager:getServerURL()
    return self:_buildURL(self._ip)
end

function FileSyncManager:setPort(port)
    self._port = port
    G_reader_settings:saveSetting("koprinter_port", port)
    G_reader_settings:flush()
end

--- Settings this plugin persists in G_reader_settings. Kept in one place so
--- deleteSettings() cannot drift from the readers/writers above.
local SETTINGS_KEYS = {
    "koprinter_port",
}

--- Whether the "needs root access" notice should be shown for `port`.
---
--- Binding a privileged port fails on every start on Android and desktop, so
--- an unconditional notice reappears each time the server comes up. Show it
--- once per configured port instead: enough to explain the ":8080" in the
--- URL, without nagging devices that can never bind a low port. Choosing a
--- different port arms the notice again, since that is a new setting whose
--- outcome the user has not been told about yet. Only the last port is
--- remembered, so switching back to an earlier one reports again.
---
--- @return boolean: true when the notice has not yet been shown for this port
function FileSyncManager:shouldNotifyPortFallback(port)
    if G_reader_settings:readSetting(PORT_FALLBACK_NOTICE_KEY) == port then
        return false
    end
    G_reader_settings:saveSetting(PORT_FALLBACK_NOTICE_KEY, port)
    G_reader_settings:flush()
    return true
end

--- Remove every setting this plugin owns, restoring first-run defaults.
--- Called by KOReader's plugin manager through FileSync:deletePluginSettings().
function FileSyncManager:deleteSettings()
    for _i, key in ipairs(SETTINGS_KEYS) do
        G_reader_settings:delSetting(key)
    end
    G_reader_settings:flush()
    -- Drop the cached values so a still-loaded instance re-reads the defaults.
    self._port = nil
end

function FileSyncManager:configurePort()
    local InputDialog = require("ui/widget/inputdialog")
    local port_dialog
    port_dialog = InputDialog:new{
        title = _("Server port"),
        input = tostring(self:getPort()),
        input_type = "number",
        input_hint = "631",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(port_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_port = tonumber(port_dialog:getInputText())
                        if new_port and new_port >= 1 and new_port <= 65535 then
                            self:setPort(new_port)
                            UIManager:close(port_dialog)
                            local msg
                            if new_port < 1024 then
                                -- Privileged ports only bind when KOReader runs
                                -- as root (Kobo/Kindle). Elsewhere the server
                                -- falls back to FALLBACK_PORT at start time.
                                msg = T(_("Port set to %1. Ports below 1024 need root access (available on Kobo/Kindle); if unavailable the server falls back to port %2. Restart the server for changes to take effect."), new_port, FALLBACK_PORT)
                            else
                                msg = T(_("Port set to %1. Restart the server for changes to take effect."), new_port)
                            end
                            UIManager:show(InfoMessage:new{
                                text = msg,
                                timeout = 5,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid port. Please enter a number between 1 and 65535."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(port_dialog)
    port_dialog:onShowKeyboard()
end

function FileSyncManager:getLocalIP()
    -- Try multiple methods to get the local IP address
    -- Method 1: Use KOReader's NetworkMgr if available
    if NetworkMgr and NetworkMgr.getLocalIpAddress then
        local ip = NetworkMgr:getLocalIpAddress()
        if ip and ip ~= "0.0.0.0" and ip ~= "127.0.0.1" then
            return ip
        end
    end

    -- Method 2: Parse ifconfig output
    local fd = io.popen("ifconfig 2>/dev/null || ip addr show 2>/dev/null")
    if fd then
        local output = fd:read("*all")
        fd:close()
        if output then
            -- Match inet addresses, skip loopback
            for ip in output:gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
                if ip ~= "127.0.0.1" then
                    return ip
                end
            end
        end
    end

    -- Method 3: UDP socket trick (doesn't actually send data)
    local socket = require("socket")
    local s = socket.udp()
    if s then
        s:setpeername("8.8.8.8", 631)
        local ip = s:getsockname()
        s:close()
        if ip and ip ~= "0.0.0.0" then
            return ip
        end
    end

    return nil
end

function FileSyncManager:getRootDir()
    -- Determine the books/library directory based on device
    if Device:isKindle() then
        return "/mnt/us"
    elseif Device:isKobo() then
        return "/mnt/onboard"
    elseif Device:isPocketBook() then
        return "/mnt/ext1"
    elseif Device:isAndroid() then
        return require("android").getExternalStoragePath()
    else
        -- Fallback: use KOReader's home directory
        local DataStorage = require("datastorage")
        return DataStorage:getDataDir()
    end
end

--- Check whether the FileSync server is currently running.
--- @return boolean
function FileSyncManager:isRunning()
    return self._running
end

--- Start the FileSync server: check WiFi, resolve IP, create HttpServer, and show QR code.
--- @param silent boolean|nil: when true, suppress UI messages and QR code display
function FileSyncManager:start(silent)
    if self._running then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("FileSync server is already running."),
                timeout = 2,
            })
        end
        return
    end

    -- Continuation: runs once WiFi is confirmed up (or immediately, if it
    -- already was). Kept local to start() so it can close over `silent`.
    local function continueStart()
        -- Re-entrancy guard: an auto-start could have fired between the
        -- WiFi prompt and the connectivity callback.
        if self._running then return end

        -- Get the local IP. NetworkMgr:runWhenConnected only guarantees
        -- isConnected (IP + gateway), so the IP lookup may still fail on
        -- some devices; keep the existing retry/fallback chain.
        local ip = self:getLocalIP()
        if not ip then
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = _("Could not determine device IP address. Make sure WiFi is connected."),
                    timeout = 3,
                })
            end
            return
        end

        local port = self:getPort()
        local HttpServer = require("printserver/httpserver")
        local IppHandler = require("printserver/handler")
        local function tryStart(p)
            return pcall(function()
                self._server = HttpServer:new({port = p})
                self._server.ipp_handler = IppHandler.new({ port = self._server.port, printer_name = "Kindle PDF" }) -- TODO parameterize printer_name
                self._server:start()
            end)
        end

        local ok, err = tryStart(port)

        -- Privileged ports (<1024) only bind when KOReader runs as root, which
        -- is the case on Kobo/Kindle but not on Android or desktop. If binding
        -- such a port fails, fall back to FALLBACK_PORT so the server still
        -- comes up instead of failing outright.
        if not ok and port < 1024 then
            logger.warn("FileSync: Could not bind privileged port", port,
                "- falling back to", FALLBACK_PORT)
            local fb_ok, fb_err = tryStart(FALLBACK_PORT)
            if fb_ok then
                ok = true
                if not silent and self:shouldNotifyPortFallback(port) then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Port %1 needs root access and isn't available on this device. Using port %2 instead."), port, FALLBACK_PORT),
                        timeout = 5,
                    })
                end
                port = FALLBACK_PORT
            else
                err = fb_err
            end
        end

        if not ok then
            logger.err("FileSync: Failed to start server:", err)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = T(_("Failed to start server: %1"), tostring(err)),
                    timeout = 5,
                })
            end
            return
        end

        -- Add Kindle firewall rules
        if Device:isKindle() then
            self:openKindleFirewall(port)
        end

        self._running = true
        self._ip = ip
        self._port = port
        self:preventStandby()
        logger.info("FileSync: Server started on", ip .. ":" .. port)
    end

    -- WiFi gate. In silent mode (auto-start on resume) we never want to
    -- pop KOReader's "Turn on Wi-Fi?" prompt, so just bail if WiFi is off.
    -- In interactive mode, defer to NetworkMgr: if already connected,
    -- runWhenConnected fires the callback inline; otherwise it shows the
    -- standard prompt and schedules the callback after IP is assigned.
    -- If the user cancels the prompt, the callback simply never fires
    -- and no error is shown -- which is what we want.
    if not NetworkMgr:isConnected() then
        if silent then
            return
        end
        NetworkMgr:runWhenConnected(continueStart)
        return
    end

    continueStart()
end

--- Stop the FileSync server: close QR screen, stop HttpServer, remove firewall rules.
--- @param silent boolean|nil: when true, suppress UI messages and skip the file list refresh
function FileSyncManager:stop(silent)
    if not self._running then
        return
    end

    -- Close QR screen if open
    self:closeQRScreen()

    if self._server then
        pcall(function()
            self._server:stop()
        end)
        self._server = nil
    end

    -- Remove Kindle firewall rules
    if Device:isKindle() then
        self:closeKindleFirewall(self:getPort())
    end

    self._running = false
    self:allowStandby()
    logger.info("FileSync: Server stopped")

    if not silent then
        -- Pick up whatever was uploaded while the server was running, then say
        -- so. KOReader is deliberately *not* restarted here: a restart costs
        -- the user half a minute of blank screen, and refreshing the file list
        -- is all it ever bought us.
        Utils.refreshFileList()
        UIManager:show(InfoMessage:new{
            text = _("FileSync server stopped."),
            timeout = 2,
        })
    end
end

function FileSyncManager:preventStandby()
    if self._standby_prevented then return end

    -- 1. Prevent standby (light sleep / screen off)
    UIManager:preventStandby()
    logger.info("FileSync: Standby prevented")

    -- 2. Pause auto-suspend via the officially supported PluginShare flag.
    --    KOReader's autosuspend plugin checks this flag on every schedule
    --    cycle and resets the suspend countdown while it is truthy.
    local PluginShare = require("pluginshare")
    PluginShare.pause_auto_suspend = true
    logger.info("FileSync: Auto-suspend paused via PluginShare")

    self._standby_prevented = true
end

function FileSyncManager:allowStandby()
    if not self._standby_prevented then return end

    -- 1. Resume auto-suspend
    local PluginShare = require("pluginshare")
    PluginShare.pause_auto_suspend = nil
    logger.info("FileSync: Auto-suspend resumed via PluginShare")

    -- 2. Allow standby again
    UIManager:allowStandby()
    logger.info("FileSync: Standby allowed")

    self._standby_prevented = false
end

function FileSyncManager:checkBatteryAndStart()
    local ok_power, power_device = pcall(function() return Device:getPowerDevice() end)
    local capacity = 100
    local is_charging = false
    if ok_power and power_device then
        local ok_cap, cap = pcall(function() return power_device:getCapacity() end)
        if ok_cap and cap then capacity = cap end
        local ok_chg, chg = pcall(function() return power_device:isCharging() end)
        if ok_chg then is_charging = chg end
    end

    if capacity < 15 and not is_charging then
        UIManager:show(ConfirmBox:new{
            title = _("Low Battery"),
            text = T(_("Battery level is at %1%. Running the server may drain the battery quickly."), capacity),
            ok_text = _("Start Anyway"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:start()
            end,
        })
    else
        self:start()
    end
end

function FileSyncManager:closeQRScreen()
    if self._qr_widget then
        UIManager:close(self._qr_widget, "full")
        self._qr_widget = nil
    end
end

--- Stop the server from the QR screen.
--- Shared by the "Stop Server" button and the confirmation dialog.
--- stop() closes the QR screen, refreshes the file list and reports back, so
--- there is nothing left to do here.
function FileSyncManager:stopFromQRScreen()
    self:stop()
end

--- Ask the user what to do when leaving the QR screen while the server runs.
--- Shared by the close button and the Back key.
function FileSyncManager:confirmLeaveQRScreen()
    UIManager:show(ConfirmBox:new{
        title = _("Print server is running"),
        text = _("The server will keep running in the background and prevent the device from sleeping. What would you like to do?"),
        ok_text = _("Stop server"),
        cancel_text = _("Keep running"),
        ok_callback = function()
            self:stopFromQRScreen()
        end,
        cancel_callback = function()
            self:closeQRScreen()
        end,
    })
end

--- Only these protocols may reach the shell command below.
local FIREWALL_PROTOCOLS = { tcp = true, udp = true }

--- Add an iptables rule allowing incoming traffic on a port.
--- @param port number
function FileSyncManager:openKindleFirewall(port)
    port = tonumber(port)
    os.execute(string.format("iptables -A INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    logger.info("FileSync: Kindle firewall rule added for tcp port", port)
end

--- Remove the iptables rule added by openKindleFirewall.
--- @param port number
function FileSyncManager:closeKindleFirewall(port)
    port = tonumber(port)
    os.execute(string.format("iptables -D INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null", port))
    logger.info("FileSync: Kindle firewall rule removed for tcp port", port)
end

return FileSyncManager
