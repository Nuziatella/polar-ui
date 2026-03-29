local api = require("api")

local Compat = {
    state = nil
}

local function hasFunction(tbl, key)
    return type(tbl) == "table" and type(tbl[key]) == "function"
end

local function append(list, value)
    list[#list + 1] = value
end

local function buildRuntimeLines(caps)
    local anchorText = caps.nametag_anchor and "Name tag" or (caps.screen_position and "Screen position" or "Unavailable")
    local sliderText = caps.slider_factory and "Available" or "Unavailable"
    local checkText = caps.checkbutton_factory and "Available" or "Fallback"
    return {
        string.format("Nameplates: %s", caps.nameplates_supported and "Supported" or "Blocked"),
        string.format("Anchoring: %s | Sliders: %s", anchorText, sliderText),
        string.format("Check buttons: %s | Targeting: passthrough only", checkText)
    }
end

function Compat.Probe(force)
    if Compat.state ~= nil and not force then
        return Compat.state
    end

    local caps = {
        create_window = hasFunction(api.Interface, "CreateWindow"),
        create_empty_window = hasFunction(api.Interface, "CreateEmptyWindow"),
        create_widget = hasFunction(api.Interface, "CreateWidget"),
        free_widget = hasFunction(api.Interface, "Free"),
        save_settings = type(api.SaveSettings) == "function",
        stock_content = ADDON ~= nil and type(ADDON.GetContent) == "function",
        target_unitframe = ADDON ~= nil and type(ADDON.GetContent) == "function" and UIC ~= nil and UIC.TARGET_UNITFRAME ~= nil,
        player_unitframe = ADDON ~= nil and type(ADDON.GetContent) == "function" and UIC ~= nil and UIC.PLAYER_UNITFRAME ~= nil,
        watchtarget_unitframe = ADDON ~= nil and type(ADDON.GetContent) == "function" and UIC ~= nil and UIC.WATCH_TARGET_FRAME ~= nil,
        targetoftarget_unitframe = ADDON ~= nil and type(ADDON.GetContent) == "function" and UIC ~= nil and UIC.TARGET_OF_TARGET_FRAME ~= nil,
        statusbar_factory = type(W_BAR) == "table" and type(W_BAR.CreateStatusBarOfRaidFrame) == "function",
        slider_factory = type(api._Library) == "table"
            and type(api._Library.UI) == "table"
            and type(api._Library.UI.CreateSlider) == "function",
        checkbutton_factory = type(api._Library) == "table"
            and type(api._Library.UI) == "table"
            and type(api._Library.UI.CreateCheckButton) == "function",
        nametag_anchor = hasFunction(api.Unit, "GetUnitScreenNameTagOffset"),
        screen_position = hasFunction(api.Unit, "GetUnitScreenPosition"),
        unit_id = hasFunction(api.Unit, "GetUnitId"),
        unit_info = hasFunction(api.Unit, "GetUnitInfoById") or hasFunction(api.Unit, "UnitInfo")
    }

    local blockers = {}
    local warnings = {}

    if not caps.create_widget then
        append(blockers, "CreateWidget unavailable")
    end
    if not caps.create_empty_window then
        append(blockers, "CreateEmptyWindow unavailable")
    end
    if not caps.statusbar_factory then
        append(blockers, "W_BAR.CreateStatusBarOfRaidFrame unavailable")
    end
    if not caps.screen_position and not caps.nametag_anchor then
        append(blockers, "No unit screen-position API available")
    end

    if not caps.slider_factory then
        append(warnings, "Slider helper unavailable; settings page uses limited controls.")
    end
    if not caps.checkbutton_factory then
        append(warnings, "Checkbutton helper unavailable; checkbox controls use fallback widgets.")
    end
    if not caps.target_unitframe then
        append(warnings, "Stock target frame content unavailable.")
    end
    if not caps.nametag_anchor and caps.screen_position then
        append(warnings, "Name-tag anchoring unavailable; using screen-position fallback.")
    end

    caps.nameplates_supported = #blockers == 0
    caps.targeting_mode = "passthrough"

    Compat.state = {
        caps = caps,
        blockers = blockers,
        warnings = warnings,
        runtime_lines = buildRuntimeLines(caps)
    }
    return Compat.state
end

function Compat.Get()
    return Compat.Probe(false)
end

function Compat.GetCaps()
    return Compat.Get().caps
end

function Compat.NameplatesSupported()
    return Compat.Get().caps.nameplates_supported and true or false
end

function Compat.GetRuntimeLines()
    return Compat.Get().runtime_lines
end

function Compat.GetStatusText()
    local state = Compat.Get()
    if #state.blockers > 0 then
        return "Runtime blocked: " .. table.concat(state.blockers, "; ")
    end
    if #state.warnings > 0 then
        return "Runtime warnings: " .. table.concat(state.warnings, " ")
    end
    return "Runtime OK"
end

return Compat
