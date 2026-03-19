local api = require("api")

local SETTINGS_FILE_PATH = "polar-ui/settings.txt"
local Nameplates = nil
do
    local ok, mod = pcall(require, "polar-ui/nameplates")
    if ok then
        Nameplates = mod
    else
        ok, mod = pcall(require, "polar-ui.nameplates")
        if ok then
            Nameplates = mod
        end
    end
end

local function AnchorTopLeft(wnd, x, y)
    if wnd == nil or wnd.AddAnchor == nil then
        return false
    end

    local anchored = false
    local ok = pcall(function()
        wnd:AddAnchor("TOPLEFT", "UIParent", x, y)
    end)
    anchored = ok and true or false
    if anchored then
        return true
    end

    ok = pcall(function()
        wnd:AddAnchor("TOPLEFT", "UIParent", "TOPLEFT", x, y)
    end)
    anchored = ok and true or false
    if anchored then
        return true
    end

    ok = pcall(function()
        wnd:AddAnchor("TOPLEFT", x, y)
    end)
    anchored = ok and true or false
    return anchored
end

local DailyAge = nil
do
    local ok, mod = pcall(require, "polar-ui/dailyage")
    if ok then
        DailyAge = mod
    else
        ok, mod = pcall(require, "polar-ui.dailyage")
        if ok then
            DailyAge = mod
        end
    end
end

local CooldownTracker = nil
do
    local ok, mod = pcall(require, "polar-ui/cooldown_tracker")
    if ok then
        CooldownTracker = mod
    else
        ok, mod = pcall(require, "polar-ui.cooldown_tracker")
        if ok then
            CooldownTracker = mod
        end
    end
end

local UI = {
    settings = nil,
    enabled = true,
    accum_ms = 0,
    plates_accum_ms = 0,
    stock_refreshed = false,
    last_large_hpmp = nil,
    last_aura_enabled = nil,
    last_aura_cfg = nil,
    stock_distance_forced_hidden = false,
    created = {},
    player = {
        wnd = nil
    },
    watchtarget = {
        wnd = nil
    },
    target_of_target = {
        wnd = nil
    },
    target = {
        wnd = nil,
        role = nil,
        class_name = nil,
        gearscore = nil,
        guild = nil,
        pdef = nil,
        mdef = nil
    },
    alignment_grid = {
        wnd = nil,
        v_lines = {},
        h_lines = {},
        last_w = nil,
        last_h = nil
    }
}

local function ClampNumber(v, minV, maxV, fallback)
    local n = tonumber(v)
    if n == nil then
        return fallback
    end
    if n < minV then
        return minV
    end
    if n > maxV then
        return maxV
    end
    return n
end

local function DeepCopyTable(obj, visited)
    if type(obj) ~= "table" then
        return obj
    end
    visited = visited or {}
    if visited[obj] ~= nil then
        return visited[obj]
    end
    local out = {}
    visited[obj] = out
    for k, v in pairs(obj) do
        out[DeepCopyTable(k, visited)] = DeepCopyTable(v, visited)
    end
    return out
end

local function MergeStyleTables(base, override)
    local out = {}
    if type(base) == "table" then
        for k, v in pairs(base) do
            if k ~= "frames" and k ~= "buff_windows" and k ~= "aura" then
                out[k] = DeepCopyTable(v)
            end
        end
        if type(base.buff_windows) == "table" then
            out.buff_windows = DeepCopyTable(base.buff_windows)
        end
        if type(base.aura) == "table" then
            out.aura = DeepCopyTable(base.aura)
        end
    end

    if type(override) == "table" then
        for k, v in pairs(override) do
            if k ~= "frames" and k ~= "buff_windows" and k ~= "aura" then
                out[k] = DeepCopyTable(v)
            end
        end
    end
    return out
end

local function GetOrCreatePosTable(settings, key)
    if type(settings) ~= "table" then
        return nil
    end
    if type(settings[key]) ~= "table" then
        settings[key] = {}
    end
    return settings[key]
end

local function SafeGetOffset(wnd)
    if wnd == nil or wnd.GetOffset == nil then
        return nil, nil
    end
    local ok, x, y = pcall(function()
        return wnd:GetOffset()
    end)
    if not ok then
        return nil, nil
    end
    x = tonumber(x)
    y = tonumber(y)
    if x == nil or y == nil then
        return nil, nil
    end
    return x, y
end

local function SaveSettingsToFile(settings)
    if type(settings) ~= "table" then
        return
    end

    pcall(function()
        if type(settings.nameplates) ~= "table" or type(settings.nameplates.guild_colors) ~= "table" then
            return
        end
        local gc = settings.nameplates.guild_colors
        local moves = {}
        for k, v in pairs(gc) do
            local key = tostring(k or "")
            key = string.match(key, "^%s*(.-)%s*$") or key
            local norm = string.lower(key)
            norm = string.gsub(norm, "%s+", "_")
            norm = string.gsub(norm, "[^%w_]", "")
            if norm ~= "" and string.match(norm, "^%d") ~= nil then
                norm = "_" .. norm
            end
            if norm ~= "" and norm ~= key then
                table.insert(moves, { from = k, to = norm, val = v })
            end
        end
        for _, m in ipairs(moves) do
            if gc[m.to] == nil then
                gc[m.to] = m.val
            end
            gc[m.from] = nil
        end
    end)

    api.SaveSettings()
    if api.File ~= nil and api.File.Write ~= nil then
        pcall(function()
            api.File:Write(SETTINGS_FILE_PATH, settings)
        end)
    end
end

local function ApplyUnitFramePosition(wnd, settings, key, defaultX, defaultY)
    if wnd == nil or type(settings) ~= "table" then
        return
    end

    local pos = GetOrCreatePosTable(settings, key)
    if pos == nil then
        return
    end

    local x = tonumber(pos.x)
    local y = tonumber(pos.y)
    if x == nil or y == nil then
        local curX, curY = SafeGetOffset(wnd)
        if curX ~= nil and curY ~= nil then
            pos.x = curX
            pos.y = curY
            SaveSettingsToFile(settings)
            return
        end
        pos.x = ClampNumber(defaultX, -5000, 5000, 10)
        pos.y = ClampNumber(defaultY, -5000, 5000, 300)
        SaveSettingsToFile(settings)
        x = tonumber(pos.x)
        y = tonumber(pos.y)
    end

    x = ClampNumber(x, -5000, 5000, 10)
    y = ClampNumber(y, -5000, 5000, 300)

    if math.abs(x) > 3000 or math.abs(y) > 3000 then
        pos.x = ClampNumber(defaultX, -5000, 5000, 10)
        pos.y = ClampNumber(defaultY, -5000, 5000, 300)
        SaveSettingsToFile(settings)
        x = tonumber(pos.x)
        y = tonumber(pos.y)
    end

    if wnd.__polar_dragging then
        return
    end

    local curX, curY = SafeGetOffset(wnd)
    local drifted = false
    if curX ~= nil and curY ~= nil then
        drifted = (math.abs(curX - x) > 0.5) or (math.abs(curY - y) > 0.5)
    else
        drifted = true
    end

    if wnd.__polar_last_pos_x ~= x or wnd.__polar_last_pos_y ~= y or drifted then
        pcall(function()
            if wnd.RemoveAllAnchors ~= nil then
                wnd:RemoveAllAnchors()
            end
            AnchorTopLeft(wnd, x, y)
        end)
        wnd.__polar_last_pos_x = x
        wnd.__polar_last_pos_y = y
    end
end

local function SetFramePositionHook(frame, settings, key, defaultX, defaultY)
    if frame == nil or type(settings) ~= "table" then
        return
    end

    frame.__polar_pos_cfg = {
        settings = settings,
        key = key,
        default_x = defaultX,
        default_y = defaultY
    }

    if frame.__polar_pos_hooked then
        return
    end
    frame.__polar_pos_hooked = true

    local function wrap(methodName)
        if type(frame[methodName]) ~= "function" then
            return
        end
        local origKey = "__polar_orig_" .. methodName
        if type(frame[origKey]) == "function" then
            return
        end

        frame[origKey] = frame[methodName]
        frame[methodName] = function(self, ...)
            local out = nil
            local orig = self[origKey]
            if type(orig) == "function" then
                out = orig(self, ...)
            end

            local cfg = self.__polar_pos_cfg
            if type(cfg) == "table" and not self.__polar_dragging then
                ApplyUnitFramePosition(self, cfg.settings, cfg.key, cfg.default_x, cfg.default_y)
            end
            return out
        end
    end

    pcall(function()
        wrap("ApplyLastWindowOffset")
        wrap("ApplyLastWindowBound")
        wrap("ApplyLastWindowExtent")
        wrap("MakeOriginWindowPos")
        wrap("OnMovedPosition")
    end)
end

local function HookUnitFrameDrag(wnd, settings, key)
    if wnd == nil or type(settings) ~= "table" then
        return
    end
    local hookTarget = wnd
    if wnd.eventWindow ~= nil then
        hookTarget = wnd.eventWindow
    end

    local hookTargets = { hookTarget }
    if hookTarget ~= wnd then
        table.insert(hookTargets, wnd)
    end

    if not wnd.__polar_drag_hooked then
        wnd.__polar_drag_hooked = true

        local origStart = nil
        local origStop = nil
        if type(hookTarget.OnDragStart) == "function" then
            origStart = hookTarget.OnDragStart
        end
        if type(hookTarget.OnDragStop) == "function" then
            origStop = hookTarget.OnDragStop
        end

        wnd.__polar_drag_start = function(self, ...)
            if settings.drag_requires_shift then
                if api.Input ~= nil and api.Input.IsShiftKeyDown ~= nil and not api.Input:IsShiftKeyDown() then
                    return
                end
            end
            wnd.__polar_dragging = true
            local args = { ... }
            local unpackFn = nil
            if table ~= nil and type(table.unpack) == "function" then
                unpackFn = table.unpack
            elseif type(unpack) == "function" then
                unpackFn = unpack
            end
            if origStart ~= nil then
                pcall(function()
                    if unpackFn ~= nil then
                        origStart(self, unpackFn(args))
                    else
                        origStart(self)
                    end
                end)
            elseif wnd.StartMoving ~= nil then
                pcall(function()
                    wnd:StartMoving()
                end)
            elseif self.StartMoving ~= nil then
                pcall(function()
                    self:StartMoving()
                end)
            end
        end

        wnd.__polar_drag_stop = function(self, ...)
            local args = { ... }
            local unpackFn = nil
            if table ~= nil and type(table.unpack) == "function" then
                unpackFn = table.unpack
            elseif type(unpack) == "function" then
                unpackFn = unpack
            end

            local beforeX, beforeY = SafeGetOffset(wnd)
            if origStop ~= nil then
                pcall(function()
                    if unpackFn ~= nil then
                        origStop(self, unpackFn(args))
                    else
                        origStop(self)
                    end
                end)
            elseif wnd.StopMovingOrSizing ~= nil then
                pcall(function()
                    wnd:StopMovingOrSizing()
                end)
            elseif self.StopMovingOrSizing ~= nil then
                pcall(function()
                    self:StopMovingOrSizing()
                end)
            end

            wnd.__polar_dragging = nil

            local afterX, afterY = SafeGetOffset(wnd)
            local saveX, saveY = afterX, afterY
            if saveX == nil or saveY == nil then
                saveX, saveY = beforeX, beforeY
            end

            if saveX == nil or saveY == nil then
                return
            end

            local pos = GetOrCreatePosTable(settings, key)
            if pos == nil then
                return
            end
            pos.x = saveX
            pos.y = saveY
            SaveSettingsToFile(settings)

            wnd.__polar_last_pos_x = saveX
            wnd.__polar_last_pos_y = saveY
        end
    end

    pcall(function()
        for _, t in ipairs(hookTargets) do
            if t ~= nil and t.SetHandler ~= nil then
                t:SetHandler("OnDragStart", wnd.__polar_drag_start)
                t:SetHandler("OnDragStop", wnd.__polar_drag_stop)
                t:SetHandler("OnMouseDown", function(self, btn)
                    if btn == nil or btn == "LeftButton" then
                        wnd.__polar_drag_start(self)
                    end
                end)
                t:SetHandler("OnMouseUp", function(self, btn)
                    if btn == nil or btn == "LeftButton" then
                        wnd.__polar_drag_stop(self)
                    end
                end)
            end
            if t ~= nil and t.RegisterForDrag ~= nil then
                t:RegisterForDrag("LeftButton")
            end
            if t ~= nil and t.EnableDrag ~= nil then
                t:EnableDrag(true)
            end
        end
    end)
end

local function GetStockContent(contentId)
    if ADDON == nil or ADDON.GetContent == nil then
        return nil
    end
    local ok, res = pcall(function()
        return ADDON:GetContent(contentId)
    end)
    if ok then
        return res
    end
    return nil
end

local function SetStockDistanceLabelVisible(visible)
    if UI.target.wnd == nil or UI.target.wnd.distanceLabel == nil then
        return
    end
    pcall(function()
        local w = UI.target.wnd.distanceLabel
        if w.SetAlpha ~= nil then
            w:SetAlpha(visible and 1 or 0)
        end
        if w.Show ~= nil then
            w:Show(visible and true or false)
        end
    end)
end

local function ColorFrom255(v)
    local n = tonumber(v)
    if n == nil then
        return 1
    end
    if n < 0 then
        n = 0
    elseif n > 255 then
        n = 255
    end
    return n / 255
end

local BAR_STYLE_STATE = {
    orig_statusbar = {}
}

BAR_STYLE_STATE.orig_statusbar.__captured = false

local function ApplyBarStyle(frame, style)
    if frame == nil or type(style) ~= "table" then
        return
    end

    local statusbar_style = nil
    pcall(function()
        if type(_G) == "table" and _G.STATUSBAR_STYLE ~= nil then
            statusbar_style = _G.STATUSBAR_STYLE
        elseif STATUSBAR_STYLE ~= nil then
            statusbar_style = STATUSBAR_STYLE
        end
    end)

    local function to01(c)
        if type(c) == "table" then
            local r = ColorFrom255(c[1])
            local g = ColorFrom255(c[2])
            local b = ColorFrom255(c[3])
            local a = ColorFrom255(c[4] or 255)
            return { r, g, b, a }
        end
        return { 1, 1, 1, 1 }
    end

    local function getColor01(key, fallbackKey)
        if type(style[key]) == "table" then
            return to01(style[key])
        end
        if type(style[fallbackKey]) == "table" then
            return to01(style[fallbackKey])
        end
        return { 1, 1, 1, 1 }
    end

    local hpFill01 = getColor01("hp_fill_color", "hp_bar_color")
    local mpFill01 = getColor01("mp_fill_color", "mp_bar_color")
    local hpAfter01 = getColor01("hp_after_color", "hp_bar_color")
    local mpAfter01 = getColor01("mp_after_color", "mp_bar_color")

    local LARGE_BAR_COORDS = { 0, 120, 300, 19 }
    local SMALL_BAR_COORDS = { 301, 120, 150, 19 }

    local function setStatusBarStyle(key, coords, afterUp, afterDown)
        if statusbar_style == nil or type(statusbar_style) ~= "table" then
            return
        end
        if statusbar_style[key] == nil or type(statusbar_style[key]) ~= "table" then
            statusbar_style[key] = {}
        end
        statusbar_style[key].coords = coords
        statusbar_style[key].afterImage_color_up = afterUp
        statusbar_style[key].afterImage_color_down = afterDown
    end

    -- BetterBars-style: the stock UI pulls these tables when rendering.
    local keys = {
        "L_HP_FRIENDLY",
        "S_HP_FRIENDLY",
        "L_HP_HOSTILE",
        "S_HP_HOSTILE",
        "L_HP_NEUTRAL",
        "S_HP_NEUTRAL",
        "L_MP",
        "S_MP"
    }

    if statusbar_style ~= nil and type(statusbar_style) == "table" and not BAR_STYLE_STATE.orig_statusbar.__captured then
        for _, k in ipairs(keys) do
            local t = statusbar_style[k]
            if type(t) == "table" then
                BAR_STYLE_STATE.orig_statusbar[k] = {
                    coords = t.coords,
                    afterImage_color_up = t.afterImage_color_up,
                    afterImage_color_down = t.afterImage_color_down
                }
            else
                BAR_STYLE_STATE.orig_statusbar[k] = {
                    coords = nil,
                    afterImage_color_up = nil,
                    afterImage_color_down = nil
                }
            end
        end
        BAR_STYLE_STATE.orig_statusbar.__captured = true
    end

    local colorsEnabled = (style.bar_colors_enabled and true or false)
    local mode = tostring(style.hp_texture_mode or "stock")
    if tostring(frame.__polar_unit) == "watchtarget" then
        mode = "stock"
    end

    local function coordsFor(key, betterCoords)
        local keepOrig = (mode == "stock")
        if type(key) == "string" and string.sub(key, 1, 2) == "S_" then
            keepOrig = true
        end
        if keepOrig and BAR_STYLE_STATE.orig_statusbar.__captured then
            local o = BAR_STYLE_STATE.orig_statusbar[key]
            if type(o) == "table" and type(o.coords) == "table" then
                return o.coords
            end
        end
        return betterCoords
    end
    if statusbar_style ~= nil and type(statusbar_style) == "table" and BAR_STYLE_STATE.orig_statusbar.__captured then
        local function afterColorsFor(key, custom01)
            if colorsEnabled then
                return custom01, custom01
            end
            local orig = BAR_STYLE_STATE.orig_statusbar[key]
            if type(orig) == "table" then
                return orig.afterImage_color_up, orig.afterImage_color_down
            end
            return custom01, custom01
        end

        local hpUp, hpDown = afterColorsFor("L_HP_FRIENDLY", hpAfter01)
        setStatusBarStyle("L_HP_FRIENDLY", coordsFor("L_HP_FRIENDLY", LARGE_BAR_COORDS), hpUp, hpDown)
        hpUp, hpDown = afterColorsFor("S_HP_FRIENDLY", hpAfter01)
        setStatusBarStyle("S_HP_FRIENDLY", coordsFor("S_HP_FRIENDLY", SMALL_BAR_COORDS), hpUp, hpDown)
        hpUp, hpDown = afterColorsFor("L_HP_HOSTILE", hpAfter01)
        setStatusBarStyle("L_HP_HOSTILE", coordsFor("L_HP_HOSTILE", LARGE_BAR_COORDS), hpUp, hpDown)
        hpUp, hpDown = afterColorsFor("S_HP_HOSTILE", hpAfter01)
        setStatusBarStyle("S_HP_HOSTILE", coordsFor("S_HP_HOSTILE", SMALL_BAR_COORDS), hpUp, hpDown)
        hpUp, hpDown = afterColorsFor("L_HP_NEUTRAL", hpAfter01)
        setStatusBarStyle("L_HP_NEUTRAL", coordsFor("L_HP_NEUTRAL", LARGE_BAR_COORDS), hpUp, hpDown)
        hpUp, hpDown = afterColorsFor("S_HP_NEUTRAL", hpAfter01)
        setStatusBarStyle("S_HP_NEUTRAL", coordsFor("S_HP_NEUTRAL", SMALL_BAR_COORDS), hpUp, hpDown)

        local mpUp, mpDown = afterColorsFor("L_MP", mpAfter01)
        setStatusBarStyle("L_MP", coordsFor("L_MP", LARGE_BAR_COORDS), mpUp, mpDown)
        mpUp, mpDown = afterColorsFor("S_MP", mpAfter01)
        setStatusBarStyle("S_MP", coordsFor("S_MP", SMALL_BAR_COORDS), mpUp, mpDown)
    end

    if frame.__polar_last_hp_texture_mode ~= mode then
        frame.__polar_last_hp_texture_mode = mode
        if mode == "pc" then
            pcall(function()
                frame:ChangeHpBarTexture_forPc()
            end)
        elseif mode == "npc" then
            pcall(function()
                frame:ChangeHpBarTexture_forNpc()
            end)
        end

    end

    local function isHostileUnit(unit)
        if api == nil or api.Unit == nil then
            return false
        end
        if type(unit) ~= "string" or unit == "" then
            return false
        end
        local tid = api.Unit:GetUnitId(unit)
        if tid == nil then
            return false
        end
        local info = nil
        pcall(function()
            info = api.Unit:GetUnitInfoById(tid)
        end)
        if type(info) == "table" and tostring(info.faction) == "hostile" then
            return true
        end
        return false
    end

    local function usesSmallHpMp()
        return frame.__polar_small_hpmp and true or false
    end

    pcall(function()
        if frame.hpBar ~= nil then
            if statusbar_style ~= nil and type(statusbar_style) == "table" then
                local unit = frame.__polar_unit
                local hostile = isHostileUnit(unit)
                local styleKey = nil
                if usesSmallHpMp() then
                    styleKey = hostile and "S_HP_HOSTILE" or "S_HP_FRIENDLY"
                else
                    styleKey = hostile and "L_HP_HOSTILE" or "L_HP_FRIENDLY"
                end
                frame.hpBar:ApplyBarTexture(statusbar_style[styleKey])
            else
                frame.hpBar:ApplyBarTexture()
            end
        end
    end)
    pcall(function()
        if frame.mpBar ~= nil then
            if statusbar_style ~= nil and type(statusbar_style) == "table" then
                local mpKey = usesSmallHpMp() and "S_MP" or "L_MP"
                frame.mpBar:ApplyBarTexture(statusbar_style[mpKey])
            else
                frame.mpBar:ApplyBarTexture()
            end
        end
    end)

    if colorsEnabled then
        local function setFill(statusBar, c01)
            if statusBar == nil or type(c01) ~= "table" then
                return
            end
            pcall(function()
                statusBar:SetBarColor(c01[1], c01[2], c01[3], c01[4])
            end)
            pcall(function()
                statusBar:SetBarColor({ c01[1], c01[2], c01[3], c01[4] })
            end)
            pcall(function()
                statusBar:SetColor(c01[1], c01[2], c01[3], c01[4])
            end)
        end

        pcall(function()
            if frame.hpBar ~= nil and frame.hpBar.statusBar ~= nil then
                setFill(frame.hpBar.statusBar, hpFill01)
            end
        end)
        pcall(function()
            if frame.mpBar ~= nil and frame.mpBar.statusBar ~= nil then
                setFill(frame.mpBar.statusBar, mpFill01)
            end
        end)

        local function setAnyColor(widget, rgba)
            if widget == nil or type(rgba) ~= "table" then
                return
            end
            local r = ColorFrom255(rgba[1])
            local g = ColorFrom255(rgba[2])
            local b = ColorFrom255(rgba[3])
            local a = ColorFrom255(rgba[4] or 255)
            pcall(function()
                widget:SetBarColor({ r, g, b, a })
            end)
            pcall(function()
                widget:SetColor(r, g, b, a)
            end)
        end

        local function setBarFillColor(bar, rgba)
            if bar == nil then
                return
            end

            pcall(function()
                if bar.statusBar ~= nil then
                    setAnyColor(bar.statusBar, rgba)
                end
            end)

            pcall(function()
                setAnyColor(bar, rgba)
            end)
        end

        local function setBarAfterColor(bar, rgba)
            if bar == nil then
                return
            end

            local function afterColorValues(texInfo)
                local existing = nil
                if texInfo ~= nil and type(texInfo.afterImage_color_up) == "table" then
                    existing = texInfo.afterImage_color_up
                elseif texInfo ~= nil and type(texInfo.afterImage_color_down) == "table" then
                    existing = texInfo.afterImage_color_down
                end

                if type(existing) == "table" and type(existing[1]) == "number" and existing[1] > 1 then
                    return { tonumber(rgba[1]) or 0, tonumber(rgba[2]) or 0, tonumber(rgba[3]) or 0, tonumber(rgba[4] or 255) or 255 }
                end
                return { ColorFrom255(rgba[1]), ColorFrom255(rgba[2]), ColorFrom255(rgba[3]), ColorFrom255(rgba[4] or 255) }
            end

            pcall(function()
                if bar.statusBarAfterImage ~= nil then
                    setAnyColor(bar.statusBarAfterImage, rgba)
                end
            end)

            pcall(function()
                if bar.textureInfo ~= nil and type(bar.textureInfo) == "table" then
                    local c = afterColorValues(bar.textureInfo)
                    if type(bar.textureInfo.afterImage_color_up) == "table" then
                        bar.textureInfo.afterImage_color_up = c
                    end
                    if type(bar.textureInfo.afterImage_color_down) == "table" then
                        bar.textureInfo.afterImage_color_down = c
                    end
                end
            end)

            pcall(function()
                bar:ChangeAfterImageColor()
            end)
        end

        local function resolveColor(key, fallbackKey)
            if type(style[key]) == "table" then
                return style[key]
            end
            if type(style[fallbackKey]) == "table" then
                return style[fallbackKey]
            end
            return nil
        end

        local hpFill = resolveColor("hp_fill_color", "hp_bar_color")
        local hpAfter = resolveColor("hp_after_color", "hp_bar_color")
        local mpFill = resolveColor("mp_fill_color", "mp_bar_color")
        local mpAfter = resolveColor("mp_after_color", "mp_bar_color")

        pcall(function()
            if frame.hpBar ~= nil then
                if hpFill ~= nil then
                    setBarFillColor(frame.hpBar, hpFill)
                end
                if hpAfter ~= nil then
                    setBarAfterColor(frame.hpBar, hpAfter)
                end
            end
        end)
        pcall(function()
            if frame.mpBar ~= nil then
                if mpFill ~= nil then
                    setBarFillColor(frame.mpBar, mpFill)
                end
                if mpAfter ~= nil then
                    setBarAfterColor(frame.mpBar, mpAfter)
                end
            end
        end)
    end
end

local function ApplyTextLayout(frame, style)
    if frame == nil or type(style) ~= "table" then
        return
    end

    local nameVisible = (style.name_visible ~= false)
    local nameX = tonumber(style.name_offset_x) or 0
    local nameY = tonumber(style.name_offset_y) or 0

    local levelVisible = (style.level_visible ~= false)
    local levelX = tonumber(style.level_offset_x) or 0
    local levelY = tonumber(style.level_offset_y) or 0
    local levelSize = tonumber(style.level_font_size)

    pcall(function()
        if frame.name ~= nil and frame.name.Show ~= nil then
            frame.name:Show(nameVisible)
        end
    end)

    local function safeAnchor(widget, point, rel, relPoint, x, y)
        if widget == nil or widget.AddAnchor == nil then
            return false
        end
        local ok = pcall(function()
            widget:AddAnchor(point, rel, relPoint, x, y)
        end)
        if ok then
            return true
        end
        return pcall(function()
            widget:AddAnchor(point, rel, x, y)
        end)
    end

    if nameVisible and (nameX ~= 0 or nameY ~= 0) and frame.name ~= nil and frame.hpBar ~= nil then
        pcall(function()
            if frame.name.RemoveAllAnchors ~= nil then
                frame.name:RemoveAllAnchors()
            end
            if safeAnchor(frame.name, "BOTTOMLEFT", frame.hpBar, "TOPLEFT", nameX, nameY) then
                frame.__polar_name_moved = true
            end
        end)
    elseif frame.__polar_name_moved then
        frame.__polar_name_moved = nil
        pcall(function()
            if frame.UpdateNameStyle ~= nil then
                frame:UpdateNameStyle()
            end
        end)
    end

    local levelLabel = (frame.level ~= nil and frame.level.label ~= nil) and frame.level.label or nil
    pcall(function()
        if levelLabel ~= nil and levelLabel.Show ~= nil then
            levelLabel:Show(levelVisible)
        end
    end)
    pcall(function()
        if levelLabel ~= nil and levelLabel.style ~= nil and levelSize ~= nil then
            levelLabel.style:SetFontSize(levelSize)
        end
    end)

    if levelVisible and (levelX ~= 0 or levelY ~= 0) and levelLabel ~= nil then
        pcall(function()
            if levelLabel.RemoveAllAnchors ~= nil then
                levelLabel:RemoveAllAnchors()
            end
            local anchored = false
            if frame.name ~= nil and nameVisible then
                anchored = safeAnchor(levelLabel, "RIGHT", frame.name, "LEFT", levelX, levelY)
            elseif frame.hpBar ~= nil then
                anchored = safeAnchor(levelLabel, "BOTTOMLEFT", frame.hpBar, "TOPLEFT", levelX, levelY)
            end
            if anchored then
                frame.__polar_level_moved = true
            end
        end)
    elseif frame.__polar_level_moved then
        frame.__polar_level_moved = nil
        pcall(function()
            if frame.UpdateLevel ~= nil then
                frame:UpdateLevel()
            end
        end)
    end
end

local function ApplyStockDistanceSetting()
    if UI.target.wnd == nil or UI.target.wnd.distanceLabel == nil then
        return
    end

    local forceHide = false
    if UI.enabled and UI.settings ~= nil and UI.settings.show_distance == false then
        forceHide = true
    end

    if forceHide then
        SetStockDistanceLabelVisible(false)
        UI.stock_distance_forced_hidden = true
        return
    end

    if UI.stock_distance_forced_hidden then
        UI.stock_distance_forced_hidden = false
        SetStockDistanceLabelVisible(true)
        pcall(function()
            if UI.target.wnd ~= nil and UI.target.wnd.UpdateAll ~= nil then
                UI.target.wnd:UpdateAll()
            end
        end)
    end
end

local function HideLegacyPolarDistanceOverlay(frame)
    if frame == nil then
        return
    end
    local w = frame.polarUiTargetDist
    if w == nil then
        return
    end
    pcall(function()
        if w.SetAlpha ~= nil then
            w:SetAlpha(0)
        end
        if w.Show ~= nil then
            w:Show(false)
        end
        if w.SetText ~= nil then
            w:SetText("")
        end
    end)
end

local function SetNotClickable(widget)
    if widget ~= nil and widget.Clickable ~= nil then
        widget:Clickable(false)
    end
end

local function SafeGetExtent(wnd)
    if wnd == nil then
        return nil, nil
    end

    local ok, w, h = pcall(function()
        if wnd.GetEffectiveExtent ~= nil then
            return wnd:GetEffectiveExtent()
        end
        if wnd.GetExtent ~= nil then
            return wnd:GetExtent()
        end
        if wnd.GetWidth ~= nil and wnd.GetHeight ~= nil then
            return wnd:GetWidth(), wnd:GetHeight()
        end
        return nil, nil
    end)
    if not ok then
        return nil, nil
    end
    return tonumber(w), tonumber(h)
end

local function EnsureAlignmentGridWindow()
    if UI.alignment_grid.wnd ~= nil then
        return UI.alignment_grid.wnd
    end
    if api.Interface == nil or api.Interface.CreateEmptyWindow == nil then
        return nil
    end

    local wnd = nil
    pcall(function()
        wnd = api.Interface:CreateEmptyWindow("polarUiAlignmentGrid")
    end)
    if wnd == nil then
        return nil
    end

    UI.alignment_grid.wnd = wnd
    SetNotClickable(wnd)
    pcall(function()
        if wnd.SetUILayer ~= nil then
            wnd:SetUILayer("hud")
        end
    end)
    pcall(function()
        if wnd.SetZOrder ~= nil then
            wnd:SetZOrder(9999)
        end
    end)
    pcall(function()
        if wnd.RemoveAllAnchors ~= nil then
            wnd:RemoveAllAnchors()
        end
        if wnd.AddAnchor ~= nil then
            wnd:AddAnchor("TOPLEFT", "UIParent", 0, 0)
            wnd:AddAnchor("BOTTOMRIGHT", "UIParent", 0, 0)
        end
    end)
    pcall(function()
        if wnd.Show ~= nil then
            wnd:Show(false)
        end
    end)

    return wnd
end

local function EnsureAlignmentGridLines(w, h)
    local wnd = UI.alignment_grid.wnd
    if wnd == nil then
        return
    end

    local step = 30
    local alpha = 0.18
    local line_w = 1
    local line_h = 1

    local max_v = math.floor((w or 0) / step)
    local max_h = math.floor((h or 0) / step)
    if max_v < 1 then
        max_v = math.floor(2042 / step)
    end
    if max_h < 1 then
        max_h = math.floor(1124 / step)
    end

    for i = 0, max_v do
        local d = UI.alignment_grid.v_lines[i]
        if d == nil and wnd.CreateColorDrawable ~= nil then
            pcall(function()
                d = wnd:CreateColorDrawable(1, 1, 1, alpha, "overlay")
            end)
            UI.alignment_grid.v_lines[i] = d
        end
        if d ~= nil then
            pcall(function()
                if d.RemoveAllAnchors ~= nil then
                    d:RemoveAllAnchors()
                end
                if d.AddAnchor ~= nil then
                    local x = i * step
                    d:AddAnchor("TOPLEFT", wnd, x, 0)
                    d:AddAnchor("BOTTOMLEFT", wnd, x, 0)
                end
                if d.SetWidth ~= nil then
                    d:SetWidth(line_w)
                end
                if d.Show ~= nil then
                    d:Show(true)
                end
            end)
        end
    end

    for i, d in pairs(UI.alignment_grid.v_lines) do
        if type(i) == "number" and i > max_v and d ~= nil and d.Show ~= nil then
            pcall(function()
                d:Show(false)
            end)
        end
    end

    for i = 0, max_h do
        local d = UI.alignment_grid.h_lines[i]
        if d == nil and wnd.CreateColorDrawable ~= nil then
            pcall(function()
                d = wnd:CreateColorDrawable(1, 1, 1, alpha, "overlay")
            end)
            UI.alignment_grid.h_lines[i] = d
        end
        if d ~= nil then
            pcall(function()
                if d.RemoveAllAnchors ~= nil then
                    d:RemoveAllAnchors()
                end
                if d.AddAnchor ~= nil then
                    local y = i * step
                    d:AddAnchor("TOPLEFT", wnd, 0, y)
                    d:AddAnchor("TOPRIGHT", wnd, 0, y)
                end
                if d.SetHeight ~= nil then
                    d:SetHeight(line_h)
                end
                if d.Show ~= nil then
                    d:Show(true)
                end
            end)
        end
    end

    for i, d in pairs(UI.alignment_grid.h_lines) do
        if type(i) == "number" and i > max_h and d ~= nil and d.Show ~= nil then
            pcall(function()
                d:Show(false)
            end)
        end
    end
end

local function EnsureAlignmentGrid(settings)
    local enabled = (type(settings) == "table" and settings.alignment_grid_enabled) and true or false
    local wnd = EnsureAlignmentGridWindow()
    if wnd == nil then
        return
    end

    if not enabled then
        pcall(function()
            wnd:Show(false)
        end)
        return
    end

    local w, h = SafeGetExtent(wnd)
    if w == nil or h == nil or w <= 0 or h <= 0 then
        w, h = SafeGetExtent(api.rootWindow)
    end
    if w == nil or h == nil or w <= 0 or h <= 0 then
        w, h = 2042, 1124
    end

    if UI.alignment_grid.last_w ~= w or UI.alignment_grid.last_h ~= h then
        UI.alignment_grid.last_w = w
        UI.alignment_grid.last_h = h
        EnsureAlignmentGridLines(w, h)
    end

    pcall(function()
        wnd:Show(true)
    end)
end

local function ApplyFrameAlpha(frame, alpha)
    if frame == nil then
        return
    end
    local a = tonumber(alpha)
    if a == nil then
        a = 1
    end
    if a < 0 then
        a = 0
    elseif a > 1 then
        a = 1
    end
    pcall(function()
        if frame.SetAlpha ~= nil then
            frame:SetAlpha(a)
        end
    end)
end

local function ApplyOverlayAlpha(alpha)
    local a = tonumber(alpha)
    if a == nil then
        a = 1
    end
    if a < 0 then
        a = 0
    elseif a > 1 then
        a = 1
    end

    local function applyTo(w)
        if w == nil then
            return
        end
        pcall(function()
            if w.SetAlpha ~= nil then
                w:SetAlpha(a)
            end
        end)
    end

    applyTo(UI.target.role)
    applyTo(UI.target.class_name)
    applyTo(UI.target.guild)
end

local function FormatShortNumber(n)
    if type(n) ~= "number" then
        return "0"
    end
    local absN = math.abs(n)
    local sign = n < 0 and "-" or ""
    local v = absN
    local suffix = ""
    if absN >= 1000000000 then
        v = absN / 1000000000
        suffix = "b"
    elseif absN >= 1000000 then
        v = absN / 1000000
        suffix = "m"
    elseif absN >= 1000 then
        v = absN / 1000
        suffix = "k"
    else
        return sign .. tostring(math.floor(absN + 0.5))
    end

    local s = string.format("%.1f", v)
    s = s:gsub("%.0$", "")
    return sign .. s .. suffix
end

local function ParseTwoNumbers(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local cleaned = text:gsub(",", "")
    local a, b = cleaned:match("(%d+)%D+(%d+)")
    if a == nil or b == nil then
        return nil, nil
    end
    return tonumber(a), tonumber(b)
end

local function GetUnitVitals(unit)
    if api == nil or api.Unit == nil or type(unit) ~= "string" then
        return nil
    end

    local hp, hpMax, mp, mpMax = nil, nil, nil, nil
    pcall(function()
        if api.Unit.UnitHealth ~= nil then
            hp = api.Unit:UnitHealth(unit)
        end
        if api.Unit.UnitMaxHealth ~= nil then
            hpMax = api.Unit:UnitMaxHealth(unit)
        end
        if api.Unit.UnitMana ~= nil then
            mp = api.Unit:UnitMana(unit)
        end
        if api.Unit.UnitMaxMana ~= nil then
            mpMax = api.Unit:UnitMaxMana(unit)
        end
    end)

    if type(hp) ~= "number" or type(hpMax) ~= "number" or hpMax <= 0 then
        hp, hpMax = nil, nil
    end
    if type(mp) ~= "number" or type(mpMax) ~= "number" or mpMax <= 0 then
        mp, mpMax = nil, nil
    end

    if hp == nil and mp == nil then
        return nil
    end

    return {
        hp = hp,
        hp_max = hpMax,
        mp = mp,
        mp_max = mpMax
    }
end

local function ApplyValueTextFormat(frame, style)
    if frame == nil or type(style) ~= "table" then
        return
    end

    local fmt = tostring(style.value_format or "stock")
    local short = style.short_numbers and true or false

    if fmt == "stock" and not short then
        return
    end

    local unit = nil
    if type(frame.__polar_unit) == "string" then
        unit = frame.__polar_unit
    elseif type(frame.target) == "string" then
        unit = frame.target
    end

    local vitals = GetUnitVitals(unit)

    local function formatValue(cur, max)
        if type(cur) ~= "number" or type(max) ~= "number" or max <= 0 then
            return nil
        end

        local wantCurMax = (fmt == "curmax" or fmt == "curmax_percent" or short)
        local wantPercent = (fmt == "percent" or fmt == "curmax_percent")

        local curMaxText = nil
        if wantCurMax then
            local curTxt = short and FormatShortNumber(cur) or tostring(math.floor(cur + 0.5))
            local maxTxt = short and FormatShortNumber(max) or tostring(math.floor(max + 0.5))
            curMaxText = curTxt .. "/" .. maxTxt
        end

        local pctText = nil
        if wantPercent then
            local pct = math.floor((cur / max) * 100 + 0.5)
            pctText = tostring(pct) .. "%"
        end

        if curMaxText ~= nil and pctText ~= nil then
            return curMaxText .. " (" .. pctText .. ")"
        end
        if curMaxText ~= nil then
            return curMaxText
        end
        if pctText ~= nil then
            return pctText
        end

        return nil
    end

    local function applyTo(label, cur, max)
        if label == nil or label.SetText == nil then
            return
        end

        local out = formatValue(cur, max)
        if type(out) == "string" and out ~= "" then
            label:SetText(out)
        end
    end

    pcall(function()
        if frame.hpBar ~= nil then
            if vitals ~= nil and vitals.hp ~= nil and vitals.hp_max ~= nil then
                applyTo(frame.hpBar.hpLabel, vitals.hp, vitals.hp_max)
            else
                local t = (frame.hpBar.hpLabel ~= nil and frame.hpBar.hpLabel.GetText ~= nil) and frame.hpBar.hpLabel:GetText() or nil
                local cur, max = ParseTwoNumbers(t)
                applyTo(frame.hpBar.hpLabel, cur, max)
            end
        end
    end)
    pcall(function()
        if frame.mpBar ~= nil then
            if vitals ~= nil and vitals.mp ~= nil and vitals.mp_max ~= nil then
                applyTo(frame.mpBar.mpLabel, vitals.mp, vitals.mp_max)
            else
                local t = (frame.mpBar.mpLabel ~= nil and frame.mpBar.mpLabel.GetText ~= nil) and frame.mpBar.mpLabel:GetText() or nil
                local cur, max = ParseTwoNumbers(t)
                applyTo(frame.mpBar.mpLabel, cur, max)
            end
        end
    end)
end

local function ApplyFrameLayout(frame, settings)
    if frame == nil or type(settings) ~= "table" then
        return
    end

    local styleTable = nil
    if type(frame.__polar_style_override) == "table" then
        styleTable = frame.__polar_style_override
    elseif type(settings.style) == "table" then
        styleTable = settings.style
    end

    local width = nil
    local height = tonumber(settings.frame_height)
    local scale = nil

    if type(styleTable) == "table" then
        width = tonumber(styleTable.frame_width)
        scale = tonumber(styleTable.frame_scale)
    end

    if width == nil then
        width = tonumber(settings.frame_width)
    end
    if scale == nil then
        scale = tonumber(settings.frame_scale)
    end

    local barH = nil
    local hpBarH = nil
    local mpBarH = nil
    local barGap = 0
    if type(styleTable) == "table" then
        barH = tonumber(styleTable.bar_height)
        hpBarH = tonumber(styleTable.hp_bar_height)
        mpBarH = tonumber(styleTable.mp_bar_height)
        barGap = tonumber(styleTable.bar_gap) or 0
    end
    if barH == nil then
        barH = tonumber(settings.bar_height)
    end
    if hpBarH == nil then
        hpBarH = barH
    end
    if mpBarH == nil then
        mpBarH = barH
    end

    if width ~= nil and height ~= nil then
        pcall(function()
            if frame.SetExtent ~= nil then
                frame:SetExtent(width, height)
            end
        end)
    end

    if scale ~= nil then
        if scale < 0.5 then
            scale = 0.5
        elseif scale > 1.5 then
            scale = 1.5
        end
        pcall(function()
            if frame.SetScale ~= nil then
                frame:SetScale(scale)
            end
        end)
    end

    if hpBarH ~= nil or mpBarH ~= nil then
        local function clampBarHeight(value)
            value = tonumber(value)
            if value == nil then
                return nil
            end
            if value < 6 then
                return 6
            elseif value > 60 then
                return 60
            end
            return value
        end

        hpBarH = clampBarHeight(hpBarH)
        mpBarH = clampBarHeight(mpBarH)

        local function setBarHeight(bar, targetHeight)
            if bar == nil then
                return
            end
            pcall(function()
                if bar.SetHeight ~= nil then
                    bar:SetHeight(targetHeight)
                    return
                end
                if bar.SetExtent ~= nil then
                    local w = nil
                    if bar.GetWidth ~= nil then
                        w = bar:GetWidth()
                    end
                    if type(w) == "number" and w > 0 then
                        bar:SetExtent(w, targetHeight)
                    elseif type(width) == "number" and width > 0 then
                        bar:SetExtent(width, targetHeight)
                    end
                end
            end)
        end

        local function setBarExtent(bar, targetHeight)
            if bar == nil then
                return
            end
            if type(width) ~= "number" or width <= 0 then
                setBarHeight(bar, targetHeight)
                return
            end
            pcall(function()
                if bar.SetExtent ~= nil then
                    bar:SetExtent(width, targetHeight)
                elseif bar.SetWidth ~= nil then
                    bar:SetWidth(width)
                    if bar.SetHeight ~= nil then
                        bar:SetHeight(targetHeight)
                    end
                else
                    setBarHeight(bar, targetHeight)
                end
            end)
        end

        setBarExtent(frame.hpBar, hpBarH)
        setBarExtent(frame.mpBar, mpBarH)

        pcall(function()
            if frame.hpBar ~= nil and frame.mpBar ~= nil and frame.mpBar.AddAnchor ~= nil then
                if frame.mpBar.RemoveAllAnchors ~= nil then
                    frame.mpBar:RemoveAllAnchors()
                end
                local ok = pcall(function()
                    frame.mpBar:AddAnchor("TOPLEFT", frame.hpBar, "BOTTOMLEFT", 0, barGap)
                end)
                if not ok then
                    pcall(function()
                        frame.mpBar:AddAnchor("TOPLEFT", frame.hpBar, 0, hpBarH + barGap)
                    end)
                end
            end
        end)
    end

    if type(styleTable) == "table" then
        ApplyValueTextFormat(frame, styleTable)
        ApplyTextLayout(frame, styleTable)
        ApplyBarStyle(frame, styleTable)
    end
end

local function SetFrameStyleHook(frame, settings)
    if frame == nil or type(settings) ~= "table" then
        return
    end

    frame.__polar_frame_style_cfg = settings
    if frame.__polar_frame_style_hooked then
        return
    end
    frame.__polar_frame_style_hooked = true

    local function wrap(methodName)
        if type(frame[methodName]) ~= "function" then
            return
        end
        local origKey = "__polar_orig_" .. methodName
        if type(frame[origKey]) == "function" then
            return
        end

        frame[origKey] = frame[methodName]
        frame[methodName] = function(self, ...)
            local out = nil
            local orig = self[origKey]
            if type(orig) == "function" then
                out = orig(self, ...)
            end
            if type(self.__polar_frame_style_cfg) == "table" and not self.__polar_frame_style_applying then
                self.__polar_frame_style_applying = true
                ApplyFrameLayout(self, self.__polar_frame_style_cfg)
                self.__polar_frame_style_applying = nil
            end
            return out
        end
    end

    pcall(function()
        wrap("UpdateAll")
        wrap("UpdateHpMp")
        wrap("SetHp")
        wrap("SetMp")
        wrap("UpdateNameStyle")
        wrap("UpdateName")
        wrap("UpdateLevel")
        wrap("UpdateHpBarTexture_FirstHitByMe")
        wrap("ChangeHpBarTexture_forPc")
        wrap("ChangeHpBarTexture_forNpc")
        wrap("UpdateFrameStyle_ForUniType")
        wrap("ApplyFrameStyle")
    end)
end

local function ClearFrameStyleHook(frame)
    if frame == nil then
        return
    end

    frame.__polar_frame_style_cfg = nil
    if not frame.__polar_frame_style_hooked then
        return
    end
    frame.__polar_frame_style_hooked = nil

    local function restore(methodName)
        local origKey = "__polar_orig_" .. methodName
        if type(frame[origKey]) == "function" then
            frame[methodName] = frame[origKey]
        end
        frame[origKey] = nil
    end

    pcall(function()
        restore("UpdateAll")
        restore("UpdateHpMp")
        restore("SetHp")
        restore("SetMp")
        restore("UpdateNameStyle")
        restore("UpdateName")
        restore("UpdateLevel")
        restore("UpdateHpBarTexture_FirstHitByMe")
        restore("ChangeHpBarTexture_forPc")
        restore("ChangeHpBarTexture_forNpc")
        restore("UpdateFrameStyle_ForUniType")
        restore("ApplyFrameStyle")
    end)
end

local function ApplyAuraLayout(frame, aura)
    if frame == nil or type(aura) ~= "table" then
        return
    end

    local iconSize = tonumber(aura.icon_size) or 24
    local xGap = tonumber(aura.icon_x_gap) or 2
    local yGap = tonumber(aura.icon_y_gap) or 2
    local perRow = tonumber(aura.buffs_per_row) or 10
    local sortVertical = aura.sort_vertical and true or false

    local function ApplyOverrideFields(window)
        if window == nil then
            return
        end
        local o = window.__polar_aura_override
        if type(o) ~= "table" then
            return
        end
        if window.iconSize ~= nil then
            window.iconSize = o.iconSize
        end
        if window.iconXGap ~= nil then
            window.iconXGap = o.iconXGap
        end
        if window.iconYGap ~= nil then
            window.iconYGap = o.iconYGap
        end
        if window.buffCountOnSingleLine ~= nil then
            window.buffCountOnSingleLine = o.buffCountOnSingleLine
        end
        if window.iconSortVertical ~= nil then
            window.iconSortVertical = o.iconSortVertical
        end
    end

    local function ForceLayoutButtons(window)
        if window == nil then
            return
        end
        local o = window.__polar_aura_override
        if type(o) ~= "table" then
            return
        end
        local btns = window.button
        if type(btns) ~= "table" then
            return
        end

        local perLine = tonumber(o.buffCountOnSingleLine) or 10
        if perLine < 1 then
            perLine = 1
        end
        local iconSizeLocal = tonumber(o.iconSize) or 24
        local xGapLocal = tonumber(o.iconXGap) or 2
        local yGapLocal = tonumber(o.iconYGap) or 2
        local sortVerticalLocal = o.iconSortVertical and true or false

        local visible = tonumber(window.visibleBuffCount)
        if visible == nil or visible < 1 then
            visible = #btns
        end
        if visible < 1 then
            return
        end

        for i = 1, visible do
            local b = btns[i]
            if b ~= nil then
                pcall(function()
                    if b.RemoveAllAnchors ~= nil then
                        b:RemoveAllAnchors()
                    end

                    local row = 0
                    local col = 0
                    if sortVerticalLocal then
                        col = math.floor((i - 1) / perLine)
                        row = (i - 1) % perLine
                    else
                        row = math.floor((i - 1) / perLine)
                        col = (i - 1) % perLine
                    end

                    local x = col * (iconSizeLocal + xGapLocal)
                    local y = -row * (iconSizeLocal + yGapLocal)

                    if b.AddAnchor ~= nil then
                        local ok = pcall(function()
                            b:AddAnchor("TOPLEFT", window, x, y)
                        end)
                        if not ok then
                            pcall(function()
                                b:AddAnchor("TOPLEFT", window, "TOPLEFT", x, y)
                            end)
                        end
                    end

                    if b.SetExtent ~= nil then
                        b:SetExtent(iconSizeLocal, iconSizeLocal)
                    end
                end)
            end
        end
    end

    local function SetWindowAuraOverride(window)
        if window == nil then
            return
        end

        if type(window.__polar_aura_override) ~= "table" then
            window.__polar_aura_override = {}
        end
        window.__polar_aura_override.iconSize = iconSize
        window.__polar_aura_override.iconXGap = xGap
        window.__polar_aura_override.iconYGap = yGap
        window.__polar_aura_override.buffCountOnSingleLine = perRow
        window.__polar_aura_override.iconSortVertical = sortVertical

        if window.__polar_aura_hooked then
            return
        end
        window.__polar_aura_hooked = true

        pcall(function()
            if type(window.SetLayout) == "function" then
                window.__polar_orig_SetLayout = window.SetLayout
                window.SetLayout = function(self, ...)
                    ApplyOverrideFields(self)
                    local out = nil
                    if type(self.__polar_orig_SetLayout) == "function" then
                        out = self:__polar_orig_SetLayout(...)
                    end
                    ApplyOverrideFields(self)
                    ForceLayoutButtons(self)
                    return out
                end
            end
        end)

        pcall(function()
            if type(window.BuffUpdate) == "function" then
                window.__polar_orig_BuffUpdate = window.BuffUpdate
                window.BuffUpdate = function(self, ...)
                    ApplyOverrideFields(self)
                    local out = nil
                    if type(self.__polar_orig_BuffUpdate) == "function" then
                        out = self:__polar_orig_BuffUpdate(...)
                    end
                    ApplyOverrideFields(self)
                    ForceLayoutButtons(self)
                    return out
                end
            end
        end)
    end

    local function applyTo(window)
        if window == nil then
            return
        end

        SetWindowAuraOverride(window)

        local function setFields()
            if window.iconSize ~= nil then
                window.iconSize = iconSize
            end
            if window.iconXGap ~= nil then
                window.iconXGap = xGap
            end
            if window.iconYGap ~= nil then
                window.iconYGap = yGap
            end
            if window.buffCountOnSingleLine ~= nil then
                window.buffCountOnSingleLine = perRow
            end
            if window.iconSortVertical ~= nil then
                window.iconSortVertical = sortVertical
            end
        end

        pcall(function()
            setFields()
            if window.SetVisibleBuffCount ~= nil and window.visibleBuffCount ~= nil then
                window:SetVisibleBuffCount(window.visibleBuffCount)
            end
            if window.SetLayout ~= nil then
                window:SetLayout()
            end

            setFields()
            if window.BuffUpdate ~= nil then
                window:BuffUpdate()
            end

            setFields()
            ForceLayoutButtons(window)
        end)
    end

    applyTo(frame.buffWindow)
    applyTo(frame.debuffWindow)
end

local function ClearAuraOverride(frame)
    if frame == nil then
        return
    end

    local function clearWindow(window)
        if window == nil then
            return
        end
        window.__polar_aura_override = nil
        if window.__polar_aura_hooked then
            window.__polar_aura_hooked = nil
            pcall(function()
                if type(window.__polar_orig_SetLayout) == "function" then
                    window.SetLayout = window.__polar_orig_SetLayout
                end
                window.__polar_orig_SetLayout = nil
            end)
            pcall(function()
                if type(window.__polar_orig_BuffUpdate) == "function" then
                    window.BuffUpdate = window.__polar_orig_BuffUpdate
                end
                window.__polar_orig_BuffUpdate = nil
            end)
        end
    end

    clearWindow(frame.buffWindow)
    clearWindow(frame.debuffWindow)
end

local function SetAuraFrameHook(frame, aura)
    if frame == nil or type(aura) ~= "table" then
        return
    end

    frame.__polar_aura_frame_cfg = aura
    if frame.__polar_aura_frame_hooked then
        return
    end
    frame.__polar_aura_frame_hooked = true

    local function wrap(methodName)
        if type(frame[methodName]) ~= "function" then
            return
        end

        local origKey = "__polar_orig_" .. methodName
        if type(frame[origKey]) == "function" then
            return
        end

        frame[origKey] = frame[methodName]
        frame[methodName] = function(self, ...)
            local orig = self[origKey]

            if type(self.__polar_aura_frame_cfg) == "table" and not self.__polar_aura_frame_applying then
                self.__polar_aura_frame_applying = true
                ApplyAuraLayout(self, self.__polar_aura_frame_cfg)
                self.__polar_aura_frame_applying = nil
            end

            local out = nil
            if type(orig) == "function" then
                out = orig(self, ...)
            end

            if type(self.__polar_aura_frame_cfg) == "table" and not self.__polar_aura_frame_applying then
                self.__polar_aura_frame_applying = true
                ApplyAuraLayout(self, self.__polar_aura_frame_cfg)
                self.__polar_aura_frame_applying = nil
            end
            return out
        end
    end

    pcall(function()
        wrap("UpdateBuffDebuff")
        wrap("UpdateAll")
    end)
end

local function ClearAuraFrameHook(frame)
    if frame == nil then
        return
    end

    frame.__polar_aura_frame_cfg = nil
    if not frame.__polar_aura_frame_hooked then
        return
    end
    frame.__polar_aura_frame_hooked = nil

    local function restore(methodName)
        local origKey = "__polar_orig_" .. methodName
        if type(frame[origKey]) == "function" then
            frame[methodName] = frame[origKey]
        end
        frame[origKey] = nil
    end

    pcall(function()
        restore("UpdateBuffDebuff")
        restore("UpdateAll")
    end)
end

local function AuraWindowMatches(window, aura)
    if window == nil or type(aura) ~= "table" then
        return true
    end
    local iconSize = tonumber(aura.icon_size) or 24
    local xGap = tonumber(aura.icon_x_gap) or 2
    local yGap = tonumber(aura.icon_y_gap) or 2
    local perRow = tonumber(aura.buffs_per_row) or 10
    local sortVertical = aura.sort_vertical and true or false

    if window.iconSize ~= nil and window.iconSize ~= iconSize then
        return false
    end
    if window.iconXGap ~= nil and window.iconXGap ~= xGap then
        return false
    end
    if window.iconYGap ~= nil and window.iconYGap ~= yGap then
        return false
    end
    if window.buffCountOnSingleLine ~= nil and window.buffCountOnSingleLine ~= perRow then
        return false
    end
    if window.iconSortVertical ~= nil and (window.iconSortVertical and true or false) ~= sortVertical then
        return false
    end

    return true
end

local function FrameAuraNeedsApply(frame, aura)
    if frame == nil or type(aura) ~= "table" then
        return false
    end
    if not AuraWindowMatches(frame.buffWindow, aura) then
        return true
    end
    if not AuraWindowMatches(frame.debuffWindow, aura) then
        return true
    end
    return false
end

local function GetAuraCfgKey(aura)
    if type(aura) ~= "table" then
        return nil
    end
    local iconSize = tonumber(aura.icon_size) or 24
    local xGap = tonumber(aura.icon_x_gap) or 2
    local yGap = tonumber(aura.icon_y_gap) or 2
    local perRow = tonumber(aura.buffs_per_row) or 10
    local sortVertical = aura.sort_vertical and 1 or 0
    return string.format("%d:%d:%d:%d:%d", iconSize, xGap, yGap, perRow, sortVertical)
end

local function InList(list, value)
    if type(list) ~= "table" or value == nil then
        return false
    end

    local v = tostring(value):lower()
    for _, item in pairs(list) do
        if tostring(item):lower() == v then
            return true
        end
    end
    return false
end

local function GetRoleForClass(settings, className)
    if type(settings) ~= "table" or type(settings.role) ~= "table" then
        return "dps"
    end

    if InList(settings.role.tanks, className) then
        return "tank"
    end
    if InList(settings.role.healers, className) then
        return "healer"
    end
    return "dps"
end

local function ApplyBuffWindowPlacement(frame, cfg)
    if frame == nil or type(cfg) ~= "table" then
        return
    end

    local function Key(p)
        if type(p) ~= "table" then
            return ""
        end
        return string.format("%s:%d:%d", tostring(p.anchor or ""), tonumber(p.x) or 0, tonumber(p.y) or 0)
    end

    local function Place(widget, placement)
        if widget == nil or type(placement) ~= "table" then
            return
        end
        local anchor = placement.anchor
        if type(anchor) ~= "string" or anchor == "" then
            anchor = "TOPLEFT"
        end
        local x = tonumber(placement.x) or 0
        local y = tonumber(placement.y) or 0

        pcall(function()
            if widget.RemoveAllAnchors ~= nil then
                widget:RemoveAllAnchors()
            end
            if widget.AddAnchor ~= nil then
                local ok = pcall(function()
                    widget:AddAnchor(anchor, frame, x, y)
                end)
                if not ok then
                    pcall(function()
                        widget:AddAnchor(anchor, frame, anchor, x, y)
                    end)
                end
            end
        end)
    end

    Place(frame.buffWindow, cfg.buff)
    Place(frame.debuffWindow, cfg.debuff)

    local placeKey = Key(cfg.buff) .. "|" .. Key(cfg.debuff)
    if frame.__polar_last_buff_place_key ~= placeKey then
        frame.__polar_last_buff_place_key = placeKey
        pcall(function()
            if frame.UpdateBuffDebuff ~= nil then
                frame:UpdateBuffDebuff()
            end
        end)
    end
end

local function ApplyStockFrameStyle(frame, style)
    if frame == nil or type(style) ~= "table" then
        return
    end

    pcall(function()
        if frame.name ~= nil and frame.name.style ~= nil then
            local nameSize = tonumber(style.name_font_size)
            if nameSize ~= nil then
                frame.name.style:SetFontSize(nameSize)
            end
            if style.name_shadow ~= nil then
                frame.name.style:SetShadow(style.name_shadow and true or false)
            end
            ApplyTextColor(frame.name, FONT_COLOR.WHITE)
        end
    end)

    ApplyTextLayout(frame, style)
    ApplyBarStyle(frame, style)

    pcall(function()
        local function SafeAnchor(widget, target)
            if widget == nil or widget.AddAnchor == nil then
                return
            end
            local ox = 0
            local oy = 0
            if widget == frame.hpBar.hpLabel then
                ox = tonumber(style.hp_value_offset_x) or 0
                oy = tonumber(style.hp_value_offset_y) or 0
            elseif widget == frame.mpBar.mpLabel then
                ox = tonumber(style.mp_value_offset_x) or 0
                oy = tonumber(style.mp_value_offset_y) or 0
            end

            local ok = pcall(function()
                widget:AddAnchor("CENTER", target, ox, oy)
            end)
            if not ok then
                pcall(function()
                    widget:AddAnchor("CENTER", target, "CENTER", ox, oy)
                end)
            end
        end

        if frame.hpBar ~= nil and frame.hpBar.hpLabel ~= nil and frame.hpBar.hpLabel.style ~= nil then
            frame.hpBar.hpLabel.style:SetFontSize(tonumber(style.hp_font_size) or 16)
            if style.value_shadow ~= nil then
                frame.hpBar.hpLabel.style:SetShadow(style.value_shadow and true or false)
            end
            if frame.hpBar.hpLabel.RemoveAllAnchors ~= nil then
                frame.hpBar.hpLabel:RemoveAllAnchors()
            end
            SafeAnchor(frame.hpBar.hpLabel, frame.hpBar)
        end

        if frame.mpBar ~= nil and frame.mpBar.mpLabel ~= nil and frame.mpBar.mpLabel.style ~= nil then
            frame.mpBar.mpLabel.style:SetFontSize(tonumber(style.mp_font_size) or 11)
            if style.value_shadow ~= nil then
                frame.mpBar.mpLabel.style:SetShadow(style.value_shadow and true or false)
            end
            if frame.mpBar.mpLabel.RemoveAllAnchors ~= nil then
                frame.mpBar.mpLabel:RemoveAllAnchors()
            end
            SafeAnchor(frame.mpBar.mpLabel, frame.mpBar)
        end
    end)
end

local function EnsureUi(settings)
    EnsureAlignmentGrid(settings)

    UI.player.wnd = GetStockContent(UIC.PLAYER_UNITFRAME)
    UI.target.wnd = GetStockContent(UIC.TARGET_UNITFRAME)
    UI.watchtarget.wnd = GetStockContent(UIC.WATCH_TARGET_FRAME)
    UI.target_of_target.wnd = GetStockContent(UIC.TARGET_OF_TARGET_FRAME)

    if UI.player.wnd ~= nil then
        UI.player.wnd.__polar_unit = "player"
        UI.player.wnd.__polar_small_hpmp = nil
    end
    if UI.target.wnd ~= nil then
        UI.target.wnd.__polar_unit = "target"
        UI.target.wnd.__polar_small_hpmp = nil
    end
    if UI.watchtarget.wnd ~= nil then
        UI.watchtarget.wnd.__polar_unit = "watchtarget"
        UI.watchtarget.wnd.__polar_small_hpmp = true
    end
    if UI.target_of_target.wnd ~= nil then
        UI.target_of_target.wnd.__polar_unit = "targetoftarget"
        UI.target_of_target.wnd.__polar_small_hpmp = true
    end

    if UI.target.wnd ~= nil then
        HideLegacyPolarDistanceOverlay(UI.target.wnd)
    end

    local baseStyle = nil
    if type(settings) == "table" and type(settings.style) == "table" then
        baseStyle = settings.style
    else
        baseStyle = {}
    end

    local styleFrames = (type(baseStyle.frames) == "table") and baseStyle.frames or {}
    if UI.player.wnd ~= nil then
        UI.player.wnd.__polar_style_override = MergeStyleTables(baseStyle, styleFrames.player)
    end
    if UI.target.wnd ~= nil then
        UI.target.wnd.__polar_style_override = MergeStyleTables(baseStyle, styleFrames.target)
    end
    if UI.watchtarget.wnd ~= nil then
        UI.watchtarget.wnd.__polar_style_override = MergeStyleTables(baseStyle, styleFrames.watchtarget)
    end
    if UI.target_of_target.wnd ~= nil then
        UI.target_of_target.wnd.__polar_style_override = MergeStyleTables(baseStyle, styleFrames.target_of_target)
    end

    if not UI.enabled then
        ApplyStockDistanceSetting()
        return
    end

    HookUnitFrameDrag(UI.player.wnd, settings, "player")
    HookUnitFrameDrag(UI.target.wnd, settings, "target")
    HookUnitFrameDrag(UI.watchtarget.wnd, settings, "watchtarget")
    HookUnitFrameDrag(UI.target_of_target.wnd, settings, "target_of_target")

    SetFramePositionHook(UI.player.wnd, settings, "player", 10, 300)
    SetFramePositionHook(UI.target.wnd, settings, "target", 10, 380)
    SetFramePositionHook(UI.watchtarget.wnd, settings, "watchtarget", 10, 460)
    SetFramePositionHook(UI.target_of_target.wnd, settings, "target_of_target", 10, 540)

    SetFrameStyleHook(UI.player.wnd, settings)
    SetFrameStyleHook(UI.target.wnd, settings)
    SetFrameStyleHook(UI.watchtarget.wnd, settings)
    SetFrameStyleHook(UI.target_of_target.wnd, settings)
    ApplyFrameLayout(UI.player.wnd, settings)
    ApplyFrameLayout(UI.target.wnd, settings)
    ApplyFrameLayout(UI.watchtarget.wnd, settings)
    ApplyFrameLayout(UI.target_of_target.wnd, settings)

    local function getFrameAlpha(wnd)
        if wnd ~= nil and type(wnd.__polar_style_override) == "table" then
            local a = tonumber(wnd.__polar_style_override.frame_alpha)
            if a ~= nil then
                return a
            end
        end
        return tonumber(settings.frame_alpha)
    end

    ApplyFrameAlpha(UI.player.wnd, getFrameAlpha(UI.player.wnd))
    ApplyFrameAlpha(UI.target.wnd, getFrameAlpha(UI.target.wnd))
    ApplyFrameAlpha(UI.watchtarget.wnd, getFrameAlpha(UI.watchtarget.wnd))
    ApplyFrameAlpha(UI.target_of_target.wnd, getFrameAlpha(UI.target_of_target.wnd))

    local wantLargeHpMp = baseStyle.large_hpmp and true or false
    if UI.last_large_hpmp == nil then
        UI.last_large_hpmp = wantLargeHpMp
    end

    local wantStockRefresh = (not UI.stock_refreshed) or (UI.last_large_hpmp ~= wantLargeHpMp)
    if wantStockRefresh then
        UI.stock_refreshed = true
        pcall(function()
            if UI.player.wnd ~= nil and UI.player.wnd.UpdateAll ~= nil then
                UI.player.wnd:UpdateAll()
            end
        end)
        pcall(function()
            if UI.target.wnd ~= nil and UI.target.wnd.UpdateAll ~= nil then
                UI.target.wnd:UpdateAll()
            end
        end)
        pcall(function()
            if UI.watchtarget.wnd ~= nil and UI.watchtarget.wnd.UpdateAll ~= nil then
                UI.watchtarget.wnd:UpdateAll()
            end
        end)
        pcall(function()
            if UI.target_of_target.wnd ~= nil and UI.target_of_target.wnd.UpdateAll ~= nil then
                UI.target_of_target.wnd:UpdateAll()
            end
        end)
    end

    ApplyUnitFramePosition(UI.player.wnd, settings, "player", 10, 300)
    ApplyUnitFramePosition(UI.target.wnd, settings, "target", 10, 380)
    ApplyUnitFramePosition(UI.watchtarget.wnd, settings, "watchtarget", 10, 460)
    ApplyUnitFramePosition(UI.target_of_target.wnd, settings, "target_of_target", 10, 540)

    UI.last_large_hpmp = wantLargeHpMp

    if UI.player.wnd ~= nil then
        ApplyStockFrameStyle(UI.player.wnd, UI.player.wnd.__polar_style_override or baseStyle)
    end
    if UI.target.wnd ~= nil then
        ApplyStockFrameStyle(UI.target.wnd, UI.target.wnd.__polar_style_override or baseStyle)
    end
    if UI.watchtarget.wnd ~= nil then
        ApplyStockFrameStyle(UI.watchtarget.wnd, UI.watchtarget.wnd.__polar_style_override or baseStyle)
    end
    if UI.target_of_target.wnd ~= nil then
        ApplyStockFrameStyle(UI.target_of_target.wnd, UI.target_of_target.wnd.__polar_style_override or baseStyle)
    end

    if UI.player.wnd ~= nil then
        ApplyValueTextFormat(UI.player.wnd, UI.player.wnd.__polar_style_override or baseStyle)
    end
    if UI.target.wnd ~= nil then
        ApplyValueTextFormat(UI.target.wnd, UI.target.wnd.__polar_style_override or baseStyle)
    end

    ApplyStockDistanceSetting()

    if type(baseStyle.buff_windows) == "table" and baseStyle.buff_windows.enabled then
        if type(baseStyle.buff_windows.player) == "table" then
            ApplyBuffWindowPlacement(UI.player.wnd, baseStyle.buff_windows.player)
        end
        if type(baseStyle.buff_windows.target) == "table" then
            ApplyBuffWindowPlacement(UI.target.wnd, baseStyle.buff_windows.target)
        end
    end

    local auraEnabled = type(baseStyle.aura) == "table" and (baseStyle.aura.enabled and true or false) or false
    local auraCfgKey = auraEnabled and GetAuraCfgKey(baseStyle.aura) or nil
    if UI.last_aura_enabled == nil then
        UI.last_aura_enabled = auraEnabled
    end

    if auraEnabled and type(baseStyle.aura) == "table" then
        SetAuraFrameHook(UI.player.wnd, baseStyle.aura)
        SetAuraFrameHook(UI.target.wnd, baseStyle.aura)
        if auraCfgKey ~= UI.last_aura_cfg or FrameAuraNeedsApply(UI.player.wnd, baseStyle.aura) or FrameAuraNeedsApply(UI.target.wnd, baseStyle.aura) then
            ApplyAuraLayout(UI.player.wnd, baseStyle.aura)
            ApplyAuraLayout(UI.target.wnd, baseStyle.aura)
        end
    elseif UI.last_aura_enabled then
        ClearAuraFrameHook(UI.player.wnd)
        ClearAuraFrameHook(UI.target.wnd)
        ClearAuraOverride(UI.player.wnd)
        ClearAuraOverride(UI.target.wnd)
        pcall(function()
            if UI.player.wnd ~= nil and UI.player.wnd.UpdateBuffDebuff ~= nil then
                UI.player.wnd:UpdateBuffDebuff()
            end
        end)
        pcall(function()
            if UI.target.wnd ~= nil and UI.target.wnd.UpdateBuffDebuff ~= nil then
                UI.target.wnd:UpdateBuffDebuff()
            end
        end)
        pcall(function()
            if UI.player.wnd ~= nil and UI.player.wnd.UpdateAll ~= nil then
                UI.player.wnd:UpdateAll()
            end
        end)
        pcall(function()
            if UI.target.wnd ~= nil and UI.target.wnd.UpdateAll ~= nil then
                UI.target.wnd:UpdateAll()
            end
        end)
    end
    UI.last_aura_enabled = auraEnabled
    UI.last_aura_cfg = auraCfgKey

    local targetStyle = (UI.target.wnd ~= nil and type(UI.target.wnd.__polar_style_override) == "table") and UI.target.wnd.__polar_style_override or baseStyle
    local overlayFontSize = tonumber(targetStyle.overlay_font_size) or tonumber(settings.font_size_value) or 12
    local gsFontSize = tonumber(targetStyle.gs_font_size) or overlayFontSize
    local classFontSize = tonumber(targetStyle.class_font_size) or overlayFontSize
    local roleFontSize = tonumber(targetStyle.role_font_size) or overlayFontSize
    local guildFontSize = tonumber(targetStyle.target_guild_font_size) or overlayFontSize
    local overlayShadow = (targetStyle.overlay_shadow ~= false)

    if UI.target.wnd == nil then
        return
    end

    if UI.target.role == nil then
        UI.target.role = UI.target.wnd:CreateChildWidget("label", "polarUiTargetRole", 0, true)
        table.insert(UI.created, UI.target.role)
        SetNotClickable(UI.target.role)
        UI.target.role:AddAnchor("BOTTOMRIGHT", UI.target.wnd, -10, -6)
        UI.target.role.style:SetAlign(ALIGN.RIGHT)
        UI.target.role.style:SetShadow(overlayShadow)
        ApplyTextColor(UI.target.role, FONT_COLOR.WHITE)
        if UI.target.role.SetAutoResize ~= nil then
            UI.target.role:SetAutoResize(true)
        end
        UI.target.role.style:SetFontSize(roleFontSize)
    end

    if UI.target.guild == nil then
        UI.target.guild = UI.target.wnd:CreateChildWidget("label", "polarUiTargetGuild", 0, true)
        table.insert(UI.created, UI.target.guild)
        SetNotClickable(UI.target.guild)
        UI.target.guild.style:SetAlign(ALIGN.LEFT)
        UI.target.guild.style:SetShadow(overlayShadow)
        ApplyTextColor(UI.target.guild, FONT_COLOR.WHITE)
        if UI.target.guild.SetAutoResize ~= nil then
            UI.target.guild:SetAutoResize(true)
        end
        UI.target.guild.style:SetFontSize(guildFontSize)
        UI.target.guild:Show(false)
    end

    if UI.target.class_name == nil then
        UI.target.class_name = UI.target.wnd:CreateChildWidget("label", "polarUiTargetClass", 0, true)
        table.insert(UI.created, UI.target.class_name)
        SetNotClickable(UI.target.class_name)
        UI.target.class_name:AddAnchor("TOPLEFT", UI.target.wnd, 10, -18)
        UI.target.class_name.style:SetAlign(ALIGN.LEFT)
        UI.target.class_name.style:SetShadow(overlayShadow)
        ApplyTextColor(UI.target.class_name, FONT_COLOR.WHITE)
        if UI.target.class_name.SetAutoResize ~= nil then
            UI.target.class_name:SetAutoResize(true)
        end
        UI.target.class_name.style:SetFontSize(classFontSize)
    end

    if UI.target.gearscore == nil then
        UI.target.gearscore = UI.target.wnd:CreateChildWidget("label", "polarUiTargetGearscore", 0, true)
        table.insert(UI.created, UI.target.gearscore)
        SetNotClickable(UI.target.gearscore)
        UI.target.gearscore:AddAnchor("TOPLEFT", UI.target.wnd, 10, -36)
        UI.target.gearscore.style:SetAlign(ALIGN.LEFT)
        UI.target.gearscore.style:SetShadow(overlayShadow)
        ApplyTextColor(UI.target.gearscore, FONT_COLOR.WHITE)
        if UI.target.gearscore.SetAutoResize ~= nil then
            UI.target.gearscore:SetAutoResize(true)
        end
        UI.target.gearscore.style:SetFontSize(gsFontSize)
    end

    if UI.target.pdef == nil then
        UI.target.pdef = UI.target.wnd:CreateChildWidget("label", "polarUiTargetPdef", 0, true)
        table.insert(UI.created, UI.target.pdef)
        SetNotClickable(UI.target.pdef)
        UI.target.pdef.style:SetAlign(ALIGN.LEFT)
        UI.target.pdef.style:SetShadow(overlayShadow)
        ApplyTextColor(UI.target.pdef, FONT_COLOR.WHITE)
        if UI.target.pdef.SetAutoResize ~= nil then
            UI.target.pdef:SetAutoResize(true)
        end
        UI.target.pdef.style:SetFontSize(gsFontSize)
        UI.target.pdef:Show(false)
    end

    if UI.target.mdef == nil then
        UI.target.mdef = UI.target.wnd:CreateChildWidget("label", "polarUiTargetMdef", 0, true)
        table.insert(UI.created, UI.target.mdef)
        SetNotClickable(UI.target.mdef)
        UI.target.mdef.style:SetAlign(ALIGN.LEFT)
        UI.target.mdef.style:SetShadow(overlayShadow)
        ApplyTextColor(UI.target.mdef, FONT_COLOR.WHITE)
        if UI.target.mdef.SetAutoResize ~= nil then
            UI.target.mdef:SetAutoResize(true)
        end
        UI.target.mdef.style:SetFontSize(gsFontSize)
        UI.target.mdef:Show(false)
    end

    pcall(function()
        if UI.target.role ~= nil and UI.target.role.style ~= nil then
            UI.target.role.style:SetFontSize(roleFontSize)
            UI.target.role.style:SetShadow(overlayShadow)
        end
        if UI.target.guild ~= nil and UI.target.guild.style ~= nil then
            UI.target.guild.style:SetFontSize(guildFontSize)
            UI.target.guild.style:SetShadow(overlayShadow)
        end
        if UI.target.class_name ~= nil and UI.target.class_name.style ~= nil then
            UI.target.class_name.style:SetFontSize(classFontSize)
            UI.target.class_name.style:SetShadow(overlayShadow)
        end
        if UI.target.gearscore ~= nil and UI.target.gearscore.style ~= nil then
            UI.target.gearscore.style:SetFontSize(gsFontSize)
            UI.target.gearscore.style:SetShadow(overlayShadow)
        end
        if UI.target.pdef ~= nil and UI.target.pdef.style ~= nil then
            UI.target.pdef.style:SetFontSize(gsFontSize)
            UI.target.pdef.style:SetShadow(overlayShadow)
        end
        if UI.target.mdef ~= nil and UI.target.mdef.style ~= nil then
            UI.target.mdef.style:SetFontSize(gsFontSize)
            UI.target.mdef.style:SetShadow(overlayShadow)
        end
    end)

    pcall(function()
        if UI.target.class_name ~= nil and UI.target.gearscore ~= nil then
            if UI.target.guild ~= nil then
                if UI.target.guild.RemoveAllAnchors ~= nil then
                    UI.target.guild:RemoveAllAnchors()
                end
                UI.target.guild:AddAnchor(
                    "TOPLEFT",
                    UI.target.wnd,
                    tonumber(targetStyle.target_guild_offset_x) or 10,
                    tonumber(targetStyle.target_guild_offset_y) or -54
                )
            end

            if UI.target.class_name.RemoveAllAnchors ~= nil then
                UI.target.class_name:RemoveAllAnchors()
            end
            UI.target.class_name:AddAnchor("TOPLEFT", UI.target.wnd, 10, -18)

            if UI.target.gearscore.RemoveAllAnchors ~= nil then
                UI.target.gearscore:RemoveAllAnchors()
            end
            UI.target.gearscore:AddAnchor("TOPLEFT", UI.target.wnd, 10, -36)

            if UI.target.pdef ~= nil and UI.target.pdef.RemoveAllAnchors ~= nil then
                UI.target.pdef:RemoveAllAnchors()
            end
            if UI.target.pdef ~= nil then
                UI.target.pdef:AddAnchor("TOPLEFT", UI.target.class_name, "TOPRIGHT", 10, 0)
            end

            if UI.target.mdef ~= nil and UI.target.mdef.RemoveAllAnchors ~= nil then
                UI.target.mdef:RemoveAllAnchors()
            end
            if UI.target.mdef ~= nil then
                UI.target.mdef:AddAnchor("TOPLEFT", UI.target.gearscore, "TOPRIGHT", 10, 0)
            end
        end
    end)

    ApplyOverlayAlpha(targetStyle.overlay_alpha)
end

local function UpdateTargetExtras(settings)
    local targetId = api.Unit:GetUnitId("target")
    if targetId == nil then
        return
    end

    local isCharacter = true
    pcall(function()
        if api.Unit ~= nil and api.Unit.GetUnitInfoById ~= nil then
            local ti = api.Unit:GetUnitInfoById(targetId)
            if type(ti) == "table" and ti.type ~= nil then
                isCharacter = (ti.type == "character")
            end
        end
    end)

    local gs = nil
    pcall(function()
        if api.Unit ~= nil then
            gs = api.Unit:UnitGearScore("target")
        end
    end)

    if gs == nil then
        pcall(function()
            if api.Unit ~= nil then
                local info = api.Unit:UnitInfo("target")
                if type(info) == "table" then
                    gs = info.gearScore or info.gearscore or info.gear_score or info.gs
                end
            end
        end)
    end

    if gs == nil then
        pcall(function()
            if api.Unit ~= nil then
                local info = api.Unit:GetUnitInfoById(targetId)
                if type(info) == "table" then
                    gs = info.gearScore or info.gearscore or info.gear_score or info.gs
                end
            end
        end)
    end

    if UI.target.gearscore ~= nil and UI.target.gearscore.SetText ~= nil then
        local txt = nil
        if type(gs) == "number" then
            txt = tostring(math.floor(gs + 0.5))
        elseif type(gs) == "string" then
            txt = gs
        end
        if type(txt) == "string" and txt ~= "" then
            UI.target.gearscore:SetText(txt .. "gs")
        else
            UI.target.gearscore:SetText("")
        end
    end

    if UI.target.gearscore ~= nil and UI.target.gearscore.Show ~= nil then
        UI.target.gearscore:Show(gs ~= nil and tostring(gs) ~= "")
    end

    local className = ""
    pcall(function()
        if api.Ability and api.Ability.GetUnitClassName then
            className = api.Ability:GetUnitClassName("target") or ""
        end
    end)

    if UI.target.class_name ~= nil and UI.target.class_name.SetText ~= nil then
        UI.target.class_name:SetText(className)
    end

    local role = GetRoleForClass(settings, className)
    if UI.target.role ~= nil and UI.target.role.SetText ~= nil then
        if role == "tank" then
            UI.target.role:SetText("T")
        elseif role == "healer" then
            UI.target.role:SetText("H")
        else
            UI.target.role:SetText("D")
        end
    end

    pcall(function()
        if UI.target.wnd ~= nil and UI.target.wnd.UpdateTooltip ~= nil then
            UI.target.wnd:UpdateTooltip()
        end
    end)

    local unitInfo = nil
    pcall(function()
        if api.Unit ~= nil and api.Unit.UnitInfo ~= nil then
            unitInfo = api.Unit:UnitInfo("target")
        end
    end)

    local pdef = nil
    local mdef = nil
    if isCharacter and type(unitInfo) == "table" then
        pdef = unitInfo.armor
        mdef = unitInfo.magic_resist
    end

    local guild = ""
    pcall(function()
        if api.Unit ~= nil and api.Unit.GetUnitInfoById ~= nil then
            local info = api.Unit:GetUnitInfoById(targetId)
            if type(info) == "table" and info.expeditionName ~= nil then
                guild = tostring(info.expeditionName or "")
            end
        end
    end)

    if UI.target.guild ~= nil and UI.target.guild.SetText ~= nil then
        if guild ~= "" then
            UI.target.guild:SetText("<" .. guild .. ">")
        else
            UI.target.guild:SetText("")
        end
    end
    if UI.target.guild ~= nil and UI.target.guild.Show ~= nil then
        UI.target.guild:Show(guild ~= "")
    end

    if UI.target.pdef ~= nil and UI.target.pdef.SetText ~= nil then
        if type(pdef) == "number" and pdef > 0 then
            UI.target.pdef:SetText(string.format("PDEF %d", math.floor(pdef + 0.5)))
        else
            UI.target.pdef:SetText("")
        end
    end
    if UI.target.pdef ~= nil and UI.target.pdef.Show ~= nil then
        UI.target.pdef:Show(type(pdef) == "number" and pdef > 0)
    end

    if UI.target.mdef ~= nil and UI.target.mdef.SetText ~= nil then
        if type(mdef) == "number" and mdef > 0 then
            UI.target.mdef:SetText(string.format("MDEF %d", math.floor(mdef + 0.5)))
        else
            UI.target.mdef:SetText("")
        end
    end
    if UI.target.mdef ~= nil and UI.target.mdef.Show ~= nil then
        UI.target.mdef:Show(type(mdef) == "number" and mdef > 0)
    end

    -- stock distanceLabel handles distance display
end

UI.Init = function(settings)
    UI.settings = settings
    UI.enabled = settings.enabled and true or false
    UI.accum_ms = 0
    UI.stock_refreshed = false
    UI.last_large_hpmp = nil
    UI.last_aura_enabled = nil
    if CooldownTracker ~= nil and CooldownTracker.Init ~= nil then
        pcall(function()
            CooldownTracker.Init(settings)
        end)
    end
    if DailyAge ~= nil and DailyAge.Init ~= nil then
        pcall(function()
            DailyAge.Init(settings)
        end)
    end
    EnsureAlignmentGrid(settings)
    EnsureUi(settings)
    if Nameplates ~= nil and Nameplates.Init ~= nil then
        pcall(function()
            Nameplates.Init(settings)
        end)
    end
    UI.SetEnabled(UI.enabled)
end

UI.UnLoad = function()
    if Nameplates ~= nil and Nameplates.Unload ~= nil then
        pcall(function()
            Nameplates.Unload()
        end)
    end
    if CooldownTracker ~= nil and CooldownTracker.Unload ~= nil then
        pcall(function()
            CooldownTracker.Unload()
        end)
    end
    if DailyAge ~= nil and DailyAge.Unload ~= nil then
        pcall(function()
            DailyAge.Unload()
        end)
    end
    if UI.alignment_grid.wnd ~= nil then
        pcall(function()
            if UI.alignment_grid.wnd.Show ~= nil then
                UI.alignment_grid.wnd:Show(false)
            end
        end)
        pcall(function()
            if api.Interface ~= nil and api.Interface.Free ~= nil then
                api.Interface:Free(UI.alignment_grid.wnd)
            end
        end)
    end
    for _, widget in ipairs(UI.created or {}) do
        pcall(function()
            if widget ~= nil and widget.Show ~= nil then
                widget:Show(false)
            end
        end)
        pcall(function()
            if widget ~= nil and api.Interface ~= nil and api.Interface.Free ~= nil then
                api.Interface:Free(widget)
            end
        end)
    end
    UI.created = {}
    UI.alignment_grid.wnd = nil
    UI.alignment_grid.v_lines = {}
    UI.alignment_grid.h_lines = {}
    UI.alignment_grid.last_w = nil
    UI.alignment_grid.last_h = nil
    UI.player.wnd = nil
    UI.target.wnd = nil
    UI.stock_refreshed = false
    UI.last_large_hpmp = nil
    UI.last_aura_enabled = nil
    UI.stock_distance_forced_hidden = false
    UI.target.role = nil
    UI.target.guild = nil
    UI.target.class_name = nil
    UI.target.gearscore = nil
    UI.target.pdef = nil
    UI.target.mdef = nil
end

UI.SetEnabled = function(enabled)
    UI.enabled = enabled and true or false

    if Nameplates ~= nil and Nameplates.SetEnabled ~= nil then
        pcall(function()
            Nameplates.SetEnabled(UI.enabled)
        end)
    end

    if not UI.enabled then
        ClearFrameStyleHook(UI.player.wnd)
        ClearFrameStyleHook(UI.target.wnd)
        ClearAuraFrameHook(UI.player.wnd)
        ClearAuraFrameHook(UI.target.wnd)
        ClearAuraOverride(UI.player.wnd)
        ClearAuraOverride(UI.target.wnd)
        pcall(function()
            if UI.player.wnd ~= nil and UI.player.wnd.UpdateAll ~= nil then
                UI.player.wnd:UpdateAll()
            end
        end)
        pcall(function()
            if UI.target.wnd ~= nil and UI.target.wnd.UpdateAll ~= nil then
                UI.target.wnd:UpdateAll()
            end
        end)
        ApplyFrameAlpha(UI.player.wnd, 1)
        ApplyFrameAlpha(UI.target.wnd, 1)
        pcall(function()
            if UI.player.wnd ~= nil and UI.player.wnd.SetScale ~= nil then
                UI.player.wnd:SetScale(1)
            end
        end)
        pcall(function()
            if UI.target.wnd ~= nil and UI.target.wnd.SetScale ~= nil then
                UI.target.wnd:SetScale(1)
            end
        end)
        UI.stock_refreshed = false
        UI.last_large_hpmp = nil
        UI.last_aura_enabled = nil
        UI.last_aura_cfg = nil
    end

    if UI.target.role ~= nil and UI.target.role.Show ~= nil then
        UI.target.role:Show(UI.enabled)
    end
    if UI.target.class_name ~= nil and UI.target.class_name.Show ~= nil then
        UI.target.class_name:Show(UI.enabled)
    end
    if UI.target.gearscore ~= nil and UI.target.gearscore.Show ~= nil then
        if not UI.enabled then
            UI.target.gearscore:Show(false)
        else
            local tid = api.Unit:GetUnitId("target")
            UI.target.gearscore:Show(tid ~= nil)
        end
    end

    if UI.target.pdef ~= nil and UI.target.pdef.Show ~= nil then
        if not UI.enabled then
            UI.target.pdef:Show(false)
        else
            local tid = api.Unit:GetUnitId("target")
            UI.target.pdef:Show(tid ~= nil)
        end
    end

    if UI.target.mdef ~= nil and UI.target.mdef.Show ~= nil then
        if not UI.enabled then
            UI.target.mdef:Show(false)
        else
            local tid = api.Unit:GetUnitId("target")
            UI.target.mdef:Show(tid ~= nil)
        end
    end
    ApplyStockDistanceSetting()
end

UI.OnUpdate = function(dt)
    if type(dt) ~= "number" then
        return
    end

    if UI.settings == nil then
        return
    end

    EnsureUi(UI.settings)

    UI.plates_accum_ms = (tonumber(UI.plates_accum_ms) or 0) + dt
    local platesInterval = 33
    if UI.plates_accum_ms >= platesInterval then
        UI.plates_accum_ms = 0
        if Nameplates ~= nil and Nameplates.OnUpdate ~= nil then
            local ok, err = pcall(function()
                Nameplates.OnUpdate(UI.settings)
            end)
            if not ok and api.Log ~= nil and api.Log.Err ~= nil then
                api.Log:Err("[Polar-UI] Nameplates.OnUpdate failed: " .. tostring(err))
            end
        end
    end

    UI.accum_ms = UI.accum_ms + dt
    local interval = tonumber(UI.settings.update_interval_ms) or 100
    if UI.accum_ms < interval then
        return
    end

    UI.accum_ms = 0

    if CooldownTracker ~= nil and CooldownTracker.OnUpdate ~= nil then
        pcall(function()
            CooldownTracker.OnUpdate(UI.settings, interval)
        end)
    end

    if DailyAge ~= nil and DailyAge.OnUpdate ~= nil then
        pcall(function()
            DailyAge.OnUpdate(UI.settings, interval)
        end)
    end

    if UI.enabled and UI.target.wnd ~= nil and UI.target.role ~= nil then
        local tid = api.Unit:GetUnitId("target")
        if tid == nil then
            if UI.target.role ~= nil and UI.target.role.Show ~= nil then
                UI.target.role:Show(false)
            end
            if UI.target.class_name ~= nil and UI.target.class_name.Show ~= nil then
                UI.target.class_name:Show(false)
            end
            if UI.target.gearscore ~= nil and UI.target.gearscore.Show ~= nil then
                UI.target.gearscore:Show(false)
            end
        else
            if UI.target.role ~= nil and UI.target.role.Show ~= nil then
                UI.target.role:Show(true)
            end
            if UI.target.class_name ~= nil and UI.target.class_name.Show ~= nil then
                UI.target.class_name:Show(true)
            end
            UpdateTargetExtras(UI.settings)
        end
    end
end

return UI
