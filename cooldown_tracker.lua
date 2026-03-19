local api = require("api")

local SETTINGS_FILE_PATH = "polar-ui/settings.txt"

local CooldownTracker = {
    settings = nil,
    accum_ms = 0,
    unit_state = {},
    target_cache = {},
    last_target_id = nil,
    last_target_lost_ms = nil,
    cached_target_display = {}
}

local function ClampNumber(v, min_v, max_v, fallback)
    local n = tonumber(v)
    if n == nil then
        return fallback
    end
    if n < min_v then
        return min_v
    end
    if n > max_v then
        return max_v
    end
    return n
end

local function ExtractTimeLeftMs(effect)
    if type(effect) ~= "table" then
        return nil
    end

    local function normalize(raw)
        local n = tonumber(raw)
        if n == nil then
            return nil
        end
        if n <= 0 then
            return nil
        end
        if n <= 300 then
            return n * 1000
        end
        return n
    end

    local candidates = {
        effect.timeLeft,
        effect.timeleft,
        effect.time_left,
        effect.leftTime,
        effect.left_time,
        effect.remainTime,
        effect.remain_time,
        effect.remaining,
        effect.remaining_ms,
    }

    for _, v in ipairs(candidates) do
        local ms = normalize(v)
        if ms ~= nil then
            return ms
        end
    end
    return nil
end

local function CopyBuffInfo(info)
    if type(info) ~= "table" then
        return nil
    end
    return {
        id = info.id,
        name = info.name,
        icon = info.icon,
        cooldown = info.cooldown,
        time_of_action = info.time_of_action,
        remaining_ms = info.remaining_ms,
        last_seen_ms = info.last_seen_ms,
        missing = info.missing,
        fixed_ms = info.fixed_ms,
        status = info.status
    }
end

local function SaveTargetCacheEntry(target_id, now_ms, state)
    if target_id == nil or type(state) ~= "table" then
        return
    end

    if type(CooldownTracker.target_cache) ~= "table" then
        CooldownTracker.target_cache = {}
    end

    local entry = CooldownTracker.target_cache[target_id]
    if type(entry) ~= "table" then
        entry = {}
        CooldownTracker.target_cache[target_id] = entry
    end

    entry.last_seen_ms = now_ms
    entry.buffs = {}
    if type(state.buffs) == "table" then
        for id, info in pairs(state.buffs) do
            entry.buffs[id] = CopyBuffInfo(info)
        end
    end
end

local function LoadTargetCacheEntry(target_id, state)
    if target_id == nil or type(state) ~= "table" then
        return false
    end
    local entry = type(CooldownTracker.target_cache) == "table" and CooldownTracker.target_cache[target_id] or nil
    if type(entry) ~= "table" or type(entry.buffs) ~= "table" then
        return false
    end
    state.buffs = {}
    for id, info in pairs(entry.buffs) do
        state.buffs[id] = CopyBuffInfo(info)
    end
    return true
end

local function Persist(settings)
    if type(settings) ~= "table" then
        return
    end
    api.SaveSettings()
    if api.File ~= nil and api.File.Write ~= nil then
        pcall(function()
            api.File:Write(SETTINGS_FILE_PATH, settings)
        end)
    end
end

local function FormatBuffId(buff_id)
    if type(buff_id) == "number" then
        return string.format("%.0f", buff_id)
    end
    return tostring(buff_id)
end

local function GetOrCreate(tbl, key)
    if type(tbl) ~= "table" then
        return nil
    end
    if type(tbl[key]) ~= "table" then
        tbl[key] = {}
    end
    return tbl[key]
end

local function EnsureUnitDefaults(cfg)
    if type(cfg) ~= "table" then
        return
    end

    if cfg.enabled == nil then
        cfg.enabled = false
    end
    if cfg.pos_x == nil then
        cfg.pos_x = 330
    end
    if cfg.pos_y == nil then
        cfg.pos_y = 30
    end
    if cfg.icon_size == nil then
        cfg.icon_size = 40
    end
    if cfg.icon_spacing == nil then
        cfg.icon_spacing = 5
    end
    if cfg.max_icons == nil then
        cfg.max_icons = 10
    end
    if cfg.lock_position == nil then
        cfg.lock_position = false
    end

    if cfg.show_timer == nil then
        cfg.show_timer = true
    end
    if cfg.timer_font_size == nil then
        cfg.timer_font_size = 16
    end
    if type(cfg.timer_color) ~= "table" then
        cfg.timer_color = { 1, 1, 1, 1 }
    end

    if cfg.show_label == nil then
        cfg.show_label = false
    end
    if cfg.label_font_size == nil then
        cfg.label_font_size = 14
    end
    if type(cfg.label_color) ~= "table" then
        cfg.label_color = { 1, 1, 1, 1 }
    end

    if type(cfg.tracked_buffs) ~= "table" then
        cfg.tracked_buffs = {}
    end

    if cfg.cache_timeout_s == nil then
        cfg.cache_timeout_s = 300
    end
end

local function EnsureDefaults(settings)
    if type(settings) ~= "table" then
        return
    end
    if type(settings.cooldown_tracker) ~= "table" then
        settings.cooldown_tracker = {}
    end

    local ct = settings.cooldown_tracker
    if ct.enabled == nil then
        ct.enabled = false
    end
    if ct.update_interval_ms == nil then
        ct.update_interval_ms = 50
    end
    if type(ct.units) ~= "table" then
        ct.units = {}
    end

    local units = ct.units
    EnsureUnitDefaults(GetOrCreate(units, "player"))
    EnsureUnitDefaults(GetOrCreate(units, "target"))
    EnsureUnitDefaults(GetOrCreate(units, "playerpet"))
    EnsureUnitDefaults(GetOrCreate(units, "watchtarget"))
    EnsureUnitDefaults(GetOrCreate(units, "target_of_target"))
end

local function GetUnitTokens(unit_key)
    if unit_key == "player" then
        return { "player" }
    end
    if unit_key == "target" then
        return { "target" }
    end
    if unit_key == "playerpet" then
        return { "playerpet", "playerpet1" }
    end
    if unit_key == "watchtarget" then
        return { "watchtarget" }
    end
    if unit_key == "target_of_target" then
        return { "targetoftarget", "target_of_target", "targettarget" }
    end
    return { tostring(unit_key) }
end

local function CallUnitMethod(method_name, ...)
    if api.Unit == nil then
        return nil
    end

    local fn = api.Unit[method_name]
    if type(fn) ~= "function" then
        return nil
    end

    local args = { ... }
    local ok, res = pcall(function()
        return fn(api.Unit, table.unpack(args))
    end)
    if not ok then
        return nil
    end
    return res
end

local function SafeBuffCount(unit_key)
    for _, tok in ipairs(GetUnitTokens(unit_key)) do
        local res = CallUnitMethod("UnitBuffCount", tok)
        if type(res) == "number" then
            return tok, res
        end
    end
    return nil, 0
end

local function SafeDebuffCount(unit_key)
    for _, tok in ipairs(GetUnitTokens(unit_key)) do
        local res = CallUnitMethod("UnitDeBuffCount", tok)
        if type(res) == "number" then
            return tok, res
        end
    end
    return nil, 0
end

local function SafeBuff(unit_token, idx)
    return CallUnitMethod("UnitBuff", unit_token, idx)
end

local function SafeDebuff(unit_token, idx)
    return CallUnitMethod("UnitDeBuff", unit_token, idx)
end

local function NowMs()
    local ms = 0
    pcall(function()
        if api.Time ~= nil and api.Time.GetUiMsec ~= nil then
            ms = api.Time:GetUiMsec() or 0
        end
    end)
    return tonumber(ms) or 0
end

local function NormalizeColorComponent(v)
    v = tonumber(v)
    if v == nil then
        return 1
    end
    if v > 1 then
        return v / 255
    end
    if v < 0 then
        return 0
    end
    return v
end

local function NormalizeAlphaComponent(v)
    v = tonumber(v)
    if v == nil then
        return 1
    end
    if v > 1 and v <= 100 then
        return v / 100
    end
    if v > 1 then
        return v / 255
    end
    if v < 0 then
        return 0
    end
    return v
end

local function NormalizeRgba(color)
    if type(color) ~= "table" then
        return 1, 1, 1, 1
    end
    return NormalizeColorComponent(color[1]),
        NormalizeColorComponent(color[2]),
        NormalizeColorComponent(color[3]),
        NormalizeAlphaComponent(color[4])
end

local function FormatTimerSeconds(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then
        return ""
    end

    seconds = math.floor(seconds * 10 + 0.5) / 10
    if seconds > 3600 then
        return string.format(
            "%d:%02d:%02d",
            math.floor(seconds / 3600),
            math.floor((seconds % 3600) / 60),
            math.floor(seconds % 60)
        )
    end
    if seconds > 60 then
        return string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
    end
    if seconds >= 10 then
        return string.format("%d", math.floor(seconds))
    end
    return string.format("%.1f", seconds)
end

local function NormalizeTimeLeftMs(raw)
    local n = tonumber(raw)
    if n == nil then
        return nil
    end
    if n <= 0 then
        return nil
    end

    -- AA APIs differ between returning seconds vs milliseconds.
    -- Heuristic: if the value is small (<= 300) treat it as seconds.
    if n <= 300 then
        return n * 1000
    end
    return n
end

local function GetBuffHelper()
    local ok, mod = pcall(require, "CooldawnBuffTracker/buff_helper")
    if ok and type(mod) == "table" then
        return mod
    end
    ok, mod = pcall(require, "CooldawnBuffTracker.buff_helper")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

local function SafeBuffTooltip(buff_id_num)
    if buff_id_num == nil or api == nil or api.Ability == nil then
        return nil
    end
    if type(api.Ability.GetBuffTooltip) ~= "function" then
        return nil
    end

    local ok, tooltip = pcall(function()
        if api.Ability.GetBuffTooltip == nil then
            return nil
        end
        if type(api.Ability.GetBuffTooltip) == "function" then
            return api.Ability:GetBuffTooltip(buff_id_num, 1)
        end
        return nil
    end)
    if ok and type(tooltip) == "table" then
        return tooltip
    end

    ok, tooltip = pcall(function()
        return api.Ability.GetBuffTooltip(buff_id_num)
    end)
    if ok and type(tooltip) == "table" then
        return tooltip
    end
    return nil
end

local function ResolveBuffNameAndIcon(buff_id, buff_helper)
    local id_str = tostring(buff_id or "")
    local id_num = tonumber(id_str)

    local name = "Buff #" .. id_str
    local icon = nil

    local tooltip = SafeBuffTooltip(id_num)
    if type(tooltip) == "table" then
        if tooltip.name ~= nil then
            local n = tostring(tooltip.name)
            if n ~= "" and n ~= id_str then
                name = n
            end
        end
        if tooltip.path ~= nil then
            local p = tostring(tooltip.path)
            if p ~= "" then
                icon = p
            end
        end
    end

    if type(buff_helper) == "table" then
        if (name == "" or name == ("Buff #" .. id_str) or name == id_str) and type(buff_helper.GetBuffName) == "function" then
            local ok, n = pcall(function()
                return buff_helper.GetBuffName(id_num or id_str)
            end)
            if ok and n ~= nil then
                n = tostring(n)
                if n ~= "" and n ~= id_str then
                    name = n
                end
            end
        end

        if icon == nil and type(buff_helper.GetBuffIcon) == "function" then
            local ok, p = pcall(function()
                return buff_helper.GetBuffIcon(id_str)
            end)
            if ok and p ~= nil then
                p = tostring(p)
                if p ~= "" then
                    icon = p
                end
            end
        end
    end

    return name, icon
end

local function EnsureBuffInfoResolved(info, buff_helper)
    if type(info) ~= "table" then
        return
    end
    local id_str = tostring(info.id or info.buff_id or "")
    if id_str == "" then
        return
    end

    local want_name = (info.name == nil) or (tostring(info.name) == "") or (tostring(info.name) == ("Buff #" .. id_str)) or (tostring(info.name) == id_str)
    local want_icon = (info.icon == nil) or (tostring(info.icon) == "")
    if not want_name and not want_icon then
        return
    end

    local name, icon = ResolveBuffNameAndIcon(id_str, buff_helper)
    if want_name and type(name) == "string" and name ~= "" and name ~= ("Buff #" .. id_str) and name ~= id_str then
        info.name = name
    end
    if want_icon and type(icon) == "string" and icon ~= "" then
        info.icon = icon
    end
end

local function GetOrCreateBuffInfo(state, buff_id, buff_helper)
    if type(state.buffs) ~= "table" then
        state.buffs = {}
    end

    if type(state.buffs[buff_id]) == "table" then
        return state.buffs[buff_id]
    end

    local name, icon = ResolveBuffNameAndIcon(buff_id, buff_helper)
    local cooldown = 30
    local time_of_action = 3

    if buff_helper ~= nil then
        pcall(function()
            if buff_helper.GetBuffName ~= nil then
                local id_num = tonumber(tostring(buff_id))
                name = buff_helper.GetBuffName(id_num or tostring(buff_id)) or name
            end
        end)
        pcall(function()
            if buff_helper.GetBuffIcon ~= nil then
                icon = icon or buff_helper.GetBuffIcon(tostring(buff_id))
            end
        end)
        pcall(function()
            if buff_helper.GetBuffCooldown ~= nil then
                cooldown = tonumber(buff_helper.GetBuffCooldown(tonumber(tostring(buff_id)) or tostring(buff_id))) or cooldown
            end
        end)
        pcall(function()
            if buff_helper.GetBuffTimeOfAction ~= nil then
                time_of_action = tonumber(buff_helper.GetBuffTimeOfAction(tonumber(tostring(buff_id)) or tostring(buff_id))) or time_of_action
            end
        end)
    end

    state.buffs[buff_id] = {
        id = buff_id,
        name = name,
        icon = icon,
        cooldown = cooldown,
        time_of_action = time_of_action,
        fixed_ms = nil,
        status = "ready"
    }

    return state.buffs[buff_id]
end

local function ComputeStatus(buff, now_ms)
    if buff == nil or buff.fixed_ms == nil then
        return "ready"
    end

    local fixed_ms = tonumber(buff.fixed_ms) or 0
    local active_ms = (tonumber(buff.time_of_action) or 0) * 1000
    local cd_ms = (tonumber(buff.cooldown) or 0) * 1000

    local active_end = fixed_ms + active_ms
    local ready_at = fixed_ms + cd_ms

    now_ms = tonumber(now_ms) or 0
    if now_ms < active_end - 50 then
        return "active"
    end
    if now_ms < ready_at - 50 then
        return "cooldown"
    end
    return "ready"
end

local function SetBuffActive(buff, now_ms, remaining_ms)
    if buff == nil then
        return
    end

    now_ms = tonumber(now_ms) or 0
    remaining_ms = tonumber(remaining_ms)

    if remaining_ms ~= nil and remaining_ms > 0 then
        local toa_ms = (tonumber(buff.time_of_action) or 0) * 1000
        buff.fixed_ms = now_ms - (toa_ms - remaining_ms)
    else
        buff.fixed_ms = now_ms
    end
    buff.status = "active"
    buff.missing = false
end

local function EnsureCanvas(state, unit_key, unit_cfg, settings)
    if state.canvas ~= nil then
        return
    end

    local canvas = nil
    pcall(function()
        canvas = api.Interface:CreateEmptyWindow("PolarCooldownTracker_" .. unit_key)
    end)

    if canvas == nil then
        return
    end

    canvas:SetExtent(1, 1)
    canvas:Clickable(true)
    if canvas.SetZOrder ~= nil then
        canvas:SetZOrder(110)
    end

    local bg = nil
    pcall(function()
        bg = canvas:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
        if bg ~= nil then
            bg:SetTextureInfo("bg_quest")
            bg:SetColor(0, 0, 0, 0.4)
            bg:AddAnchor("TOPLEFT", canvas, 0, 0)
            bg:AddAnchor("BOTTOMRIGHT", canvas, 0, 0)
        end
    end)
    canvas.bg = bg

    canvas.buff_icons = {}
    canvas.isDragging = false

    canvas.OnDragStart = function(self)
        if unit_cfg.lock_position then
            return
        end
        self.isDragging = true
        if self.bg ~= nil and self.bg.SetColor ~= nil then
            self.bg:SetColor(0, 0, 0, 0.6)
        end
        pcall(function()
            self:StartMoving()
        end)
        pcall(function()
            if api.Cursor ~= nil then
                api.Cursor:ClearCursor()
                api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
            end
        end)
    end

    canvas.OnDragStop = function(self)
        if unit_cfg.lock_position then
            return
        end

        pcall(function()
            self:StopMovingOrSizing()
        end)
        if self.bg ~= nil and self.bg.SetColor ~= nil then
            self.bg:SetColor(0, 0, 0, 0.4)
        end

        local ok, x, y = pcall(function()
            return self:GetOffset()
        end)
        if ok and type(x) == "number" and type(y) == "number" then
            unit_cfg.pos_x = x
            unit_cfg.pos_y = y
            Persist(settings)
        end

        self.isDragging = false
        pcall(function()
            if api.Cursor ~= nil then
                api.Cursor:ClearCursor()
            end
        end)
    end

    pcall(function()
        canvas:SetHandler("OnDragStart", canvas.OnDragStart)
        canvas:SetHandler("OnDragStop", canvas.OnDragStop)
        if canvas.RegisterForDrag ~= nil then
            canvas:RegisterForDrag("LeftButton")
        end
        if canvas.EnableDrag ~= nil then
            canvas:EnableDrag(not unit_cfg.lock_position)
        end
    end)

    state.canvas = canvas
end

local function EnsureIcons(state, unit_cfg, icon_count)
    if state.canvas == nil then
        return
    end

    local want = ClampNumber(icon_count, 1, 30, 10)
    local cur = #state.canvas.buff_icons

    local function createIcon(index)
        local icon = nil
        pcall(function()
            icon = CreateItemIconButton("polarCtIcon_" .. tostring(index), state.canvas)
        end)
        if icon == nil then
            return nil
        end

        pcall(function()
            if F_SLOT ~= nil and F_SLOT.ApplySlotSkin ~= nil and icon.back ~= nil and SLOT_STYLE ~= nil then
                local style = SLOT_STYLE.DEFAULT or SLOT_STYLE.BUFF or SLOT_STYLE.ITEM
                if style ~= nil then
                    F_SLOT.ApplySlotSkin(icon, icon.back, style)
                end
            end
        end)

        icon.statusOverlay = icon:CreateColorDrawable(0, 0, 0, 0, "overlay")
        icon.statusOverlay:AddAnchor("TOPLEFT", icon, 0, 0)
        icon.statusOverlay:AddAnchor("BOTTOMRIGHT", icon, 0, 0)

        local nameLabel = nil
        pcall(function()
            nameLabel = api.Interface:CreateWidget("label", "polarCtName_" .. tostring(index), icon)
        end)
        if nameLabel == nil and icon.CreateChildWidget ~= nil then
            pcall(function()
                nameLabel = icon:CreateChildWidget("label", "polarCtName_" .. tostring(index), 0, true)
            end)
        end
        if nameLabel ~= nil then
            pcall(function()
                nameLabel:SetExtent(unit_cfg.icon_size * 2, unit_cfg.icon_size / 2)
                nameLabel:AddAnchor("CENTER", icon, 0, -30)
                if nameLabel.style ~= nil then
                    nameLabel.style:SetFontSize(unit_cfg.label_font_size)
                    nameLabel.style:SetAlign(ALIGN.CENTER)
                    nameLabel.style:SetShadow(true)
                end
            end)
        end

        local timerLabel = nil
        pcall(function()
            timerLabel = api.Interface:CreateWidget("label", "polarCtTimer_" .. tostring(index), icon)
        end)
        if timerLabel == nil and icon.CreateChildWidget ~= nil then
            pcall(function()
                timerLabel = icon:CreateChildWidget("label", "polarCtTimer_" .. tostring(index), 0, true)
            end)
        end
        if timerLabel ~= nil then
            pcall(function()
                timerLabel:SetExtent(unit_cfg.icon_size, unit_cfg.icon_size / 2)
                timerLabel:AddAnchor("CENTER", icon, 0, 0)
                if timerLabel.style ~= nil then
                    timerLabel.style:SetFontSize(unit_cfg.timer_font_size)
                    timerLabel.style:SetAlign(ALIGN.CENTER)
                    timerLabel.style:SetShadow(true)
                end
            end)
        end

        local missingLabel = nil
        pcall(function()
            missingLabel = api.Interface:CreateWidget("label", "polarCtMissing_" .. tostring(index), icon)
        end)
        if missingLabel == nil and icon.CreateChildWidget ~= nil then
            pcall(function()
                missingLabel = icon:CreateChildWidget("label", "polarCtMissing_" .. tostring(index), 0, true)
            end)
        end
        if missingLabel ~= nil then
            pcall(function()
                missingLabel:SetExtent(unit_cfg.icon_size * 2, unit_cfg.icon_size / 2)
                missingLabel:AddAnchor("CENTER", icon, 0, -(unit_cfg.icon_size * 0.85))
                missingLabel:SetText("MISSING")
                if missingLabel.style ~= nil then
                    missingLabel.style:SetFontSize(math.max(10, math.floor((tonumber(unit_cfg.label_font_size) or 14) * 0.85)))
                    missingLabel.style:SetAlign(ALIGN.CENTER)
                    missingLabel.style:SetShadow(true)
                end
            end)
        end

        icon.nameLabel = nameLabel
        icon.timerLabel = timerLabel
        icon.missingLabel = missingLabel

        icon:Show(false)
        if nameLabel ~= nil then
            nameLabel:Show(false)
        end
        if timerLabel ~= nil then
            timerLabel:Show(false)
        end
        if missingLabel ~= nil then
            missingLabel:Show(false)
        end

        return icon
    end

    while cur < want do
        cur = cur + 1
        state.canvas.buff_icons[cur] = createIcon(cur)
    end

    while cur > want do
        local icon = state.canvas.buff_icons[cur]
        if icon ~= nil and icon.Show ~= nil then
            icon:Show(false)
        end
        state.canvas.buff_icons[cur] = nil
        cur = cur - 1
    end
end

local function ApplyCanvasLayout(state, unit_cfg, shown_count)
    if state.canvas == nil then
        return
    end

    local icon_size = ClampNumber(unit_cfg.icon_size, 12, 64, 40)
    local spacing = ClampNumber(unit_cfg.icon_spacing, 0, 40, 5)

    local count = ClampNumber(shown_count, 0, 30, 0)
    if count < 1 then
        state.canvas:Show(false)
        return
    end

    local total_width = count * icon_size + (count - 1) * spacing
    total_width = math.max(total_width, icon_size * 2)

    pcall(function()
        state.canvas:SetWidth(total_width)
        state.canvas:SetHeight(icon_size * 1.2)
    end)

    if state.canvas.isDragging ~= true then
        pcall(function()
            state.canvas:RemoveAllAnchors()
            state.canvas:AddAnchor("TOPLEFT", "UIParent", unit_cfg.pos_x, unit_cfg.pos_y)
            if state.canvas.EnableDrag ~= nil then
                state.canvas:EnableDrag(not unit_cfg.lock_position)
            end
        end)
    end

    state.canvas:Show(true)
end

local function UpdateIcons(state, unit_cfg, active_list, now_ms)
    if state.canvas == nil then
        return
    end

    local icon_size = ClampNumber(unit_cfg.icon_size, 12, 64, 40)
    local spacing = ClampNumber(unit_cfg.icon_spacing, 0, 40, 5)

    local timer_r, timer_g, timer_b, timer_a = NormalizeRgba(unit_cfg.timer_color)
    local label_r, label_g, label_b, label_a = NormalizeRgba(unit_cfg.label_color)

    for i, entry in ipairs(active_list) do
        local icon = state.canvas.buff_icons[i]
        if icon ~= nil then
            pcall(function()
                icon:RemoveAllAnchors()
                icon:SetExtent(icon_size, icon_size)
                icon:AddAnchor("LEFT", state.canvas, (i - 1) * (icon_size + spacing), 0)
            end)

            if icon.missingLabel ~= nil then
                pcall(function()
                    icon.missingLabel:RemoveAllAnchors()
                    icon.missingLabel:SetExtent(icon_size * 2, icon_size / 2)
                    icon.missingLabel:AddAnchor("CENTER", icon, 0, -(icon_size * 0.85))
                end)
            end

            if entry.icon ~= nil then
                local iconPath = tostring(entry.icon)
                if iconPath ~= "" then
                    local set = false
                    if F_SLOT ~= nil and F_SLOT.SetIconBackGround ~= nil then
                        local ok = pcall(function()
                            F_SLOT.SetIconBackGround(icon, iconPath)
                        end)
                        set = ok and true or false
                    end
                    if not set and icon.SetItemIcon ~= nil then
                        pcall(function()
                            icon:SetItemIcon(iconPath)
                        end)
                    end
                end
            end

            local status = entry.status
            local overlay_rgba = { 1, 1, 1, 0 }
            if status == "active" then
                overlay_rgba = { 0.2, 1, 0.2, 0.25 }
            elseif status == "cooldown" then
                overlay_rgba = { 1, 0.2, 0.2, 0.25 }
            end

            if icon.statusOverlay ~= nil and icon.statusOverlay.SetColor ~= nil then
                pcall(function()
                    icon.statusOverlay:SetColor(overlay_rgba[1], overlay_rgba[2], overlay_rgba[3], overlay_rgba[4])
                end)
            end

            if icon.nameLabel ~= nil then
                local show_label = unit_cfg.show_label and true or false
                local text = show_label and tostring(entry.name or "") or ""
                pcall(function()
                    icon.nameLabel.style:SetFontSize(unit_cfg.label_font_size)
                    icon.nameLabel.style:SetColor(label_r, label_g, label_b, label_a)
                    icon.nameLabel:SetText(text)
                    icon.nameLabel:Show(show_label and text ~= "")
                end)
            end

            if icon.missingLabel ~= nil then
                local show_missing = status == "missing"
                local phase = (tonumber(now_ms) or 0) / 200
                local flash = (math.sin(phase * 6.28318) + 1) / 2
                local a = 0.25 + (0.75 * flash)
                pcall(function()
                    if icon.missingLabel.style ~= nil then
                        icon.missingLabel.style:SetColor(1, 0.2, 0.2, a)
                    end
                    icon.missingLabel:Show(show_missing)
                end)
            end

            if icon.timerLabel ~= nil then
                local show_timer = unit_cfg.show_timer and true or false
                local remaining_s = nil
                if entry.remaining_ms ~= nil and entry.last_seen_ms ~= nil and entry.status ~= "missing" then
                    local rem_ms = tonumber(entry.remaining_ms) or 0
                    local seen_ms = tonumber(entry.last_seen_ms) or now_ms
                    rem_ms = rem_ms - (now_ms - seen_ms)
                    if rem_ms > 0 then
                        remaining_s = rem_ms / 1000
                    end
                elseif entry.fixed_ms ~= nil then
                    local fixed_ms = tonumber(entry.fixed_ms) or 0
                    local active_ms = (tonumber(entry.time_of_action) or 0) * 1000
                    local cd_ms = (tonumber(entry.cooldown) or 0) * 1000
                    if entry.status == "active" then
                        remaining_s = (fixed_ms + active_ms - now_ms) / 1000
                    elseif entry.status == "cooldown" then
                        remaining_s = (fixed_ms + cd_ms - now_ms) / 1000
                    end
                end
                local timer_text = ""
                if show_timer and remaining_s ~= nil and remaining_s > 0 then
                    timer_text = FormatTimerSeconds(remaining_s)
                end
                pcall(function()
                    if icon.timerLabel.style ~= nil then
                        icon.timerLabel.style:SetFontSize(unit_cfg.timer_font_size)
                        icon.timerLabel.style:SetColor(timer_r, timer_g, timer_b, timer_a)
                    end
                    icon.timerLabel:SetText(timer_text)
                    icon.timerLabel:Show(show_timer and timer_text ~= "")
                end)
            end

            icon:Show(true)
        end
    end

    for j = #active_list + 1, #state.canvas.buff_icons do
        local icon = state.canvas.buff_icons[j]
        if icon ~= nil then
            icon:Show(false)
            if icon.nameLabel ~= nil then
                icon.nameLabel:Show(false)
            end
            if icon.timerLabel ~= nil then
                icon.timerLabel:Show(false)
            end
            if icon.missingLabel ~= nil then
                icon.missingLabel:Show(false)
            end
        end
    end

    ApplyCanvasLayout(state, unit_cfg, #active_list)
end

local function BuildTrackedSet(unit_cfg)
    local out = {}
    if type(unit_cfg.tracked_buffs) ~= "table" then
        return out
    end

    for _, v in ipairs(unit_cfg.tracked_buffs) do
        local id = FormatBuffId(v)
        if id ~= "" then
            out[id] = true
        end
    end
    return out
end

local function UpdateUnitState(settings, unit_key, unit_cfg)
    local state = CooldownTracker.unit_state[unit_key]
    if type(state) ~= "table" then
        state = { buffs = {}, canvas = nil }
        CooldownTracker.unit_state[unit_key] = state
    end

    if not settings.cooldown_tracker.enabled or not unit_cfg.enabled then
        if state.canvas ~= nil then
            state.canvas:Show(false)
        end
        return
    end

    local tracked_set = BuildTrackedSet(unit_cfg)
    local tracked_count = 0
    for _ in pairs(tracked_set) do
        tracked_count = tracked_count + 1
    end

    if tracked_count < 1 then
        if state.canvas ~= nil then
            state.canvas:Show(false)
        end
        return
    end

    EnsureCanvas(state, unit_key, unit_cfg, settings)
    EnsureIcons(state, unit_cfg, ClampNumber(unit_cfg.max_icons, 1, 30, 10))

    local now_ms = NowMs()

    if unit_key == "target" then
        local target_id = nil
        pcall(function()
            if api.Unit ~= nil and api.Unit.GetUnitId ~= nil then
                target_id = api.Unit:GetUnitId("target")
            end
        end)

        if target_id == nil then
            if state.target_id ~= nil and state.target_lost_ms == nil then
                state.target_lost_ms = now_ms
            end

            local timeout_s = tonumber(unit_cfg.cache_timeout_s) or 300
            if state.target_lost_ms ~= nil and (now_ms - state.target_lost_ms) > (timeout_s * 1000) then
                state.target_id = nil
                state.target_lost_ms = nil
                state.buffs = {}
                if state.canvas ~= nil then
                    state.canvas:Show(false)
                end
                return
            end

            for _, info in pairs(state.buffs) do
                info.status = ComputeStatus(info, now_ms)
            end

            local ordered = {}
            if type(unit_cfg.tracked_buffs) == "table" then
                for _, v in ipairs(unit_cfg.tracked_buffs) do
                    local id = FormatBuffId(v)
                    local info = state.buffs[id]
                    if type(info) == "table" and info.fixed_ms ~= nil then
                        table.insert(ordered, info)
                    end
                end
            end

            local max_icons = ClampNumber(unit_cfg.max_icons, 1, 30, 10)
            if #ordered > max_icons then
                local trimmed = {}
                for i = 1, max_icons do
                    trimmed[i] = ordered[i]
                end
                ordered = trimmed
            end

            UpdateIcons(state, unit_cfg, ordered, now_ms)
            return
        end

        if state.target_id ~= target_id then
            if state.target_id ~= nil then
                SaveTargetCacheEntry(state.target_id, now_ms, state)
            end
            state.target_id = target_id
            state.target_lost_ms = nil

            if not LoadTargetCacheEntry(target_id, state) then
                state.buffs = {}
            end
        end
    end
    local buff_helper = GetBuffHelper()

    local active_map = {}
    local current_map = {}

    local unit_token, buff_count = SafeBuffCount(unit_key)
    for i = 1, buff_count do
        local buff = SafeBuff(unit_token, i)
        if type(buff) == "table" and buff.buff_id ~= nil then
            local id = FormatBuffId(buff.buff_id)
            current_map[id] = true
            if tracked_set[id] then
                active_map[id] = true
                local info = GetOrCreateBuffInfo(state, id, buff_helper)
                EnsureBuffInfoResolved(info, buff_helper)
                local remaining = ExtractTimeLeftMs(buff)
                if info.status ~= "active" or (unit_key == "target" and remaining ~= nil and remaining > 500) then
                    SetBuffActive(info, now_ms, remaining)
                end
                if remaining ~= nil then
                    info.remaining_ms = remaining
                    info.last_seen_ms = now_ms
                else
                    info.remaining_ms = nil
                    info.last_seen_ms = nil
                end
            end
        end
    end

    do
        local deb_token, deb_count = SafeDebuffCount(unit_key)
        for i = 1, deb_count do
            local deb = SafeDebuff(deb_token, i)
            if type(deb) == "table" and deb.buff_id ~= nil then
                local id = FormatBuffId(deb.buff_id)
                current_map[id] = true
                if tracked_set[id] then
                    active_map[id] = true
                    local info = GetOrCreateBuffInfo(state, id, buff_helper)
                    EnsureBuffInfoResolved(info, buff_helper)
                    local remaining = ExtractTimeLeftMs(deb)
                    if info.status ~= "active" or (unit_key == "target" and remaining ~= nil and remaining > 500) then
                        SetBuffActive(info, now_ms, remaining)
                    end
                    if remaining ~= nil then
                        info.remaining_ms = remaining
                        info.last_seen_ms = now_ms
                    else
                        info.remaining_ms = nil
                        info.last_seen_ms = nil
                    end
                end
            end
        end
    end

    if unit_key == "player" then
        for id, _ in pairs(tracked_set) do
            local info = GetOrCreateBuffInfo(state, id, buff_helper)
            EnsureBuffInfoResolved(info, buff_helper)
            if not active_map[id] then
                info.missing = true
                info.status = "missing"
                info.remaining_ms = nil
                info.last_seen_ms = nil
            else
                info.missing = false
            end
        end
    end

    for id, info in pairs(state.buffs) do
        if info.status == "missing" then
            -- preserve missing state for player tracked buffs
        elseif current_map[id] then
            if info.status ~= "active" then
                SetBuffActive(info, now_ms, nil)
            end
        else
            local expected = ComputeStatus(info, now_ms)
            info.status = expected
        end
    end

    if unit_key == "target" and state.target_id ~= nil then
        SaveTargetCacheEntry(state.target_id, now_ms, state)
    end

    local ordered = {}
    if type(unit_cfg.tracked_buffs) == "table" then
        for _, v in ipairs(unit_cfg.tracked_buffs) do
            local id = FormatBuffId(v)
            if tracked_set[id] then
                local info = GetOrCreateBuffInfo(state, id, buff_helper)
                EnsureBuffInfoResolved(info, buff_helper)
                if info.status ~= "missing" then
                    local st = ComputeStatus(info, now_ms)
                    info.status = st
                end
                if unit_key ~= "target" or active_map[id] or (info.fixed_ms ~= nil) then
                    table.insert(ordered, info)
                end
            end
        end
    end

    local max_icons = ClampNumber(unit_cfg.max_icons, 1, 30, 10)
    if #ordered > max_icons then
        local trimmed = {}
        for i = 1, max_icons do
            trimmed[i] = ordered[i]
        end
        ordered = trimmed
    end

    UpdateIcons(state, unit_cfg, ordered, now_ms)
end

function CooldownTracker.Init(settings)
    CooldownTracker.settings = settings
    EnsureDefaults(settings)
end

function CooldownTracker.Unload()
    for _, state in pairs(CooldownTracker.unit_state) do
        if type(state) == "table" and state.canvas ~= nil then
            pcall(function()
                state.canvas:Show(false)
            end)
            pcall(function()
                if api.Interface ~= nil and api.Interface.Free ~= nil then
                    api.Interface:Free(state.canvas)
                end
            end)
        end
    end
    CooldownTracker.unit_state = {}
    CooldownTracker.target_cache = {}
    CooldownTracker.last_target_id = nil
    CooldownTracker.last_target_lost_ms = nil
    CooldownTracker.cached_target_display = {}
end

function CooldownTracker.OnUpdate(settings, elapsed_ms)
    if type(settings) ~= "table" then
        return
    end

    EnsureDefaults(settings)

    local ct = settings.cooldown_tracker
    if type(ct) ~= "table" or not ct.enabled then
        for _, state in pairs(CooldownTracker.unit_state) do
            if type(state) == "table" and state.canvas ~= nil and state.canvas.Show ~= nil then
                pcall(function()
                    state.canvas:Show(false)
                end)
            end
        end
        return
    end

    elapsed_ms = tonumber(elapsed_ms) or 0
    CooldownTracker.accum_ms = CooldownTracker.accum_ms + elapsed_ms
    local interval = tonumber(ct.update_interval_ms) or 50
    if CooldownTracker.accum_ms < interval then
        return
    end
    CooldownTracker.accum_ms = 0

    local units = ct.units
    if type(units) ~= "table" then
        return
    end

    for _, key in ipairs({ "player", "target", "playerpet", "watchtarget", "target_of_target" }) do
        local cfg = units[key]
        if type(cfg) == "table" then
            EnsureUnitDefaults(cfg)
            UpdateUnitState(settings, key, cfg)
        end
    end
end

return CooldownTracker
