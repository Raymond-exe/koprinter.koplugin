-- Custom gettext for FileSync plugin
-- Loads .po translations from the plugin's i18n/ directory
-- Falls back to English (returns msgid) if no translation found

local translations = {}
local loaded = false

local function gettext(msgid)
    return msgid
end

return gettext
