local api = require("api")
local Compat = nil
do
    local ok, mod = pcall(require, "polar-ui/compat")
    if ok then
        Compat = mod
    else
        ok, mod = pcall(require, "polar-ui.compat")
        if ok then
            Compat = mod
        end
    end
end

local SettingsPage = {
    settings = nil,
    on_save = nil,
    on_apply = nil,
    actions = nil,
    window = nil,
    scroll_frame = nil,
    content = nil,
    controls = {},
    pages = {},
    page_heights = {},
    active_page = nil,
    nav = {},
    toggle_button = nil,
    toggle_button_dragging = false,
    style_target = "all",
    _refreshing_style_target = false,
    cooldown_unit_key = "player",
    cooldown_buff_page = 1,
    cooldown_scan_results = {}
}

local STYLE_TARGET_KEYS = {
    "all",
    "player",
    "target",
    "watchtarget",
    "target_of_target"
}

local COOLDOWN_UNIT_KEYS = {
    "player",
    "target",
    "playerpet",
    "watchtarget",
    "target_of_target"
}

local COOLDOWN_UNIT_LABELS = {
    "Player",
    "Target",
    "Mount/Pet",
    "Watchtarget",
    "Target of Target"
}

local COOLDOWN_BUFFS_PER_PAGE = 6
local COOLDOWN_SCAN_ROWS = 10

local function ClampInt(v, min_v, max_v, fallback)
    local n = tonumber(v)
    if n == nil then
        return fallback
    end
    n = math.floor(n + 0.5)
    if n < min_v then
        return min_v
    end
    if n > max_v then
        return max_v
    end
    return n
end

local function FormatBuffId(buff_id)
    if type(buff_id) == "number" then
        return string.format("%.0f", buff_id)
    end
    return tostring(buff_id)
end

local function ScanTargetEffects()
    local results = {}
    SettingsPage.cooldown_scan_results = results

    if api == nil or api.Unit == nil then
        return
    end

    local buff_helper = nil
    pcall(function()
        buff_helper = require("CooldawnBuffTracker/buff_helper")
    end)

    local function getName(id, raw)
        local id_str = tostring(id or "")
        local id_num = tonumber(id_str)

        if type(raw) == "table" and raw.name ~= nil then
            local n = tostring(raw.name)
            if n ~= "" and n ~= id_str then
                return n
            end
        end

        if api ~= nil and api.Ability ~= nil and id_num ~= nil then
            local ok, tooltip = pcall(function()
                if type(api.Ability.GetBuffTooltip) == "function" then
                    return api.Ability:GetBuffTooltip(id_num, 1)
                end
                return nil
            end)
            if ok and type(tooltip) == "table" and tooltip.name ~= nil then
                local n = tostring(tooltip.name)
                if n ~= "" and n ~= id_str then
                    return n
                end
            end
        end

        if type(buff_helper) == "table" and type(buff_helper.GetBuffName) == "function" then
            local ok, n = pcall(function()
                return buff_helper.GetBuffName(id_num or id_str)
            end)
            if ok and n ~= nil then
                n = tostring(n)
                if n ~= "" and n ~= id_str then
                    return n
                end
            end
        end

        if id_str ~= "" then
            return "Buff #" .. id_str
        end
        return ""
    end

    local function push(kind, eff)
        if type(eff) ~= "table" or eff.buff_id == nil then
            return
        end
        local id = FormatBuffId(eff.buff_id)
        if id == "" then
            return
        end
        table.insert(results, {
            kind = kind,
            id = id,
            name = getName(id, eff)
        })
    end

    local ok = pcall(function()
        local bc = api.Unit:UnitBuffCount("target") or 0
        for i = 1, bc do
            push("buff", api.Unit:UnitBuff("target", i))
        end
        local dc = api.Unit:UnitDeBuffCount("target") or 0
        for i = 1, dc do
            push("debuff", api.Unit:UnitDeBuff("target", i))
        end
    end)
    if not ok then
        SettingsPage.cooldown_scan_results = {}
    end
end

local function EnsureDailyAgeTables(s)
    if type(s) ~= "table" then
        return
    end
    if type(s.dailyage) ~= "table" then
        s.dailyage = {}
    end
    if s.dailyage.enabled == nil then
        s.dailyage.enabled = false
    end
    if type(s.dailyage.hidden) ~= "table" then
        s.dailyage.hidden = {}
    end
end

local function GetCooldownUnitKeyFromIndex(idx)
    idx = tonumber(idx) or 1
    if idx < 1 then
        idx = 1
    end
    if idx > #COOLDOWN_UNIT_KEYS then
        idx = #COOLDOWN_UNIT_KEYS
    end
    return COOLDOWN_UNIT_KEYS[idx]
end

local function GetCooldownUnitIndexFromKey(key)
    for i, k in ipairs(COOLDOWN_UNIT_KEYS) do
        if k == key then
            return i
        end
    end
    return 1
end

local function EnsureCooldownTrackerTables(s)
    if type(s) ~= "table" then
        return
    end
    if type(s.cooldown_tracker) ~= "table" then
        s.cooldown_tracker = {}
    end
    if s.cooldown_tracker.enabled == nil then
        s.cooldown_tracker.enabled = false
    end
    if s.cooldown_tracker.update_interval_ms == nil then
        s.cooldown_tracker.update_interval_ms = 50
    end
    if type(s.cooldown_tracker.units) ~= "table" then
        s.cooldown_tracker.units = {}
    end
    for _, key in ipairs(COOLDOWN_UNIT_KEYS) do
        if type(s.cooldown_tracker.units[key]) ~= "table" then
            s.cooldown_tracker.units[key] = {}
        end
        if type(s.cooldown_tracker.units[key].tracked_buffs) ~= "table" then
            s.cooldown_tracker.units[key].tracked_buffs = {}
        end
    end
end

local function SetWidgetEnabled(widget, enabled)
    if widget == nil then
        return
    end
    pcall(function()
        if widget.Enable ~= nil then
            widget:Enable(enabled and true or false)
        elseif widget.SetEnabled ~= nil then
            widget:SetEnabled(enabled and true or false)
        end
    end)
end

local function RefreshCooldownScanRows()
    if SettingsPage.controls == nil then
        return
    end
    local rows = SettingsPage.controls.ct_scan_rows
    if type(rows) ~= "table" then
        return
    end

    local results = SettingsPage.cooldown_scan_results
    if type(results) ~= "table" then
        results = {}
        SettingsPage.cooldown_scan_results = results
    end

    if SettingsPage.controls.ct_scan_status ~= nil and SettingsPage.controls.ct_scan_status.SetText ~= nil then
        SettingsPage.controls.ct_scan_status:SetText(string.format("Found %d effect(s) on target", #results))
    end

    for i, row in ipairs(rows) do
        local entry = results[i]
        local show = type(entry) == "table"
        if type(row) == "table" then
            if row.label ~= nil and row.label.SetText ~= nil then
                if show then
                    local kind = tostring(entry.kind or "buff")
                    local prefix = (kind == "debuff") and "[D]" or "[B]"
                    local id = tostring(entry.id or "")
                    local name = tostring(entry.name or "")
                    local text = string.format("%s %s %s", prefix, id, name)
                    row.label:SetText(text)
                else
                    row.label:SetText("")
                end
            end
            if row.label ~= nil and row.label.Show ~= nil then
                row.label:Show(show)
            end
            if row.add ~= nil and row.add.Show ~= nil then
                row.add:Show(show)
            end
            if row.add ~= nil then
                row.add.__polar_scan_index = i
            end
        end
    end
end

local function GetEditText(field)
    if field == nil or field.GetText == nil then
        return ""
    end
    local ok, res = pcall(function()
        return field:GetText()
    end)
    if ok and res ~= nil then
        return tostring(res)
    end
    return ""
end

local function ParseEditNumber(field)
    local txt = GetEditText(field)
    txt = tostring(txt or "")
    txt = txt:gsub("%s+", "")
    local n = tonumber(txt)
    return n
end

local function RefreshCooldownBuffRows(unit_cfg)
    if SettingsPage.controls == nil then
        return
    end
    local rows = SettingsPage.controls.ct_buff_rows
    if type(rows) ~= "table" then
        return
    end

    local buffs = type(unit_cfg) == "table" and unit_cfg.tracked_buffs or nil
    if type(buffs) ~= "table" then
        buffs = {}
    end

    local total = #buffs
    local pages = math.max(1, math.ceil(total / COOLDOWN_BUFFS_PER_PAGE))
    if SettingsPage.cooldown_buff_page < 1 then
        SettingsPage.cooldown_buff_page = 1
    elseif SettingsPage.cooldown_buff_page > pages then
        SettingsPage.cooldown_buff_page = pages
    end

    local start_idx = ((SettingsPage.cooldown_buff_page - 1) * COOLDOWN_BUFFS_PER_PAGE) + 1
    for i = 1, COOLDOWN_BUFFS_PER_PAGE do
        local idx = start_idx + (i - 1)
        local row = rows[i]
        if type(row) == "table" then
            local id = buffs[idx]
            local show = id ~= nil
            if row.label ~= nil and row.label.SetText ~= nil then
                row.label:SetText(show and tostring(id) or "")
            end
            if row.label ~= nil and row.label.Show ~= nil then
                row.label:Show(show)
            end
            if row.remove ~= nil and row.remove.Show ~= nil then
                row.remove:Show(show)
            end
            if row.remove ~= nil then
                row.remove.__polar_buff_index = idx
            end
        end
    end

    if SettingsPage.controls.ct_page_label ~= nil and SettingsPage.controls.ct_page_label.SetText ~= nil then
        SettingsPage.controls.ct_page_label:SetText(string.format("%d / %d", SettingsPage.cooldown_buff_page, pages))
    end
    if SettingsPage.controls.ct_prev_page ~= nil and SettingsPage.controls.ct_prev_page.SetEnable ~= nil then
        SettingsPage.controls.ct_prev_page:SetEnable(SettingsPage.cooldown_buff_page > 1)
    end
    if SettingsPage.controls.ct_next_page ~= nil and SettingsPage.controls.ct_next_page.SetEnable ~= nil then
        SettingsPage.controls.ct_next_page:SetEnable(SettingsPage.cooldown_buff_page < pages)
    end
end

local function GetComboBoxIndexRaw(ctrl)
    if ctrl == nil then
        return nil
    end
    local idx = nil
    if ctrl.GetSelectedIndex ~= nil then
        idx = ctrl:GetSelectedIndex()
    elseif ctrl.GetSelIndex ~= nil then
        idx = ctrl:GetSelIndex()
    end
    return tonumber(idx)
end

local function SetComboBoxIndex1Based(ctrl, idx1)
    if ctrl == nil or idx1 == nil then
        return
    end

    local function updateBaseFromRaw(raw)
        raw = tonumber(raw)
        if raw == nil then
            return
        end
        if raw == idx1 then
            ctrl.__polar_index_base = 1
        elseif raw == (idx1 - 1) then
            ctrl.__polar_index_base = 0
        end
    end

    if ctrl.Select ~= nil then
        local selVal = idx1
        if ctrl.GetSelectedIndex ~= nil then
            ctrl.__polar_index_base = 1
            selVal = idx1
        elseif ctrl.GetSelIndex ~= nil then
            ctrl.__polar_index_base = 0
            selVal = idx1 - 1
        end

        ctrl:Select(selVal)
        updateBaseFromRaw(GetComboBoxIndexRaw(ctrl))
        return
    end

    local function trySetter(setter, val)
        local ok = pcall(function()
            setter(ctrl, val)
        end)
        if not ok then
            return nil
        end
        return GetComboBoxIndexRaw(ctrl)
    end

    if ctrl.SetSelectedIndex ~= nil then
        ctrl.__polar_index_base = nil
        local raw = trySetter(ctrl.SetSelectedIndex, idx1)
        updateBaseFromRaw(raw)
        if ctrl.__polar_index_base == nil then
            raw = trySetter(ctrl.SetSelectedIndex, idx1 - 1)
            updateBaseFromRaw(raw)
        end
        return
    end

    if ctrl.SetSelIndex ~= nil then
        ctrl.__polar_index_base = 0
        local raw = trySetter(ctrl.SetSelIndex, idx1 - 1)
        updateBaseFromRaw(raw)
    end
end

local function GetComboBoxIndex1Based(ctrl, maxCount)
    local raw = GetComboBoxIndexRaw(ctrl)
    if raw == nil then
        return nil
    end

    local base = ctrl.__polar_index_base
    if base == nil then
        if raw == 0 then
            base = 0
        elseif raw == maxCount then
            base = 1
        elseif raw == (maxCount - 1) then
            base = 0
        else
            base = 1
        end
        ctrl.__polar_index_base = base
    end

    if base == 0 then
        return raw + 1
    end
    return raw
end

local function EnsureStyleFrames(settings)
    if type(settings) ~= "table" then
        return
    end
    if type(settings.style) ~= "table" then
        settings.style = {}
    end
    if type(settings.style.frames) ~= "table" then
        settings.style.frames = {}
    end
    if type(settings.style.frames.player) ~= "table" then
        settings.style.frames.player = {}
    end
    if type(settings.style.frames.target) ~= "table" then
        settings.style.frames.target = {}
    end
    if type(settings.style.frames.watchtarget) ~= "table" then
        settings.style.frames.watchtarget = {}
    end
    if type(settings.style.frames.target_of_target) ~= "table" then
        settings.style.frames.target_of_target = {}
    end
end

local function GetStyleTargetKeyFromIndex(idx)
    idx = tonumber(idx) or 1
    if idx < 1 then
        idx = 1
    end
    if idx > #STYLE_TARGET_KEYS then
        idx = #STYLE_TARGET_KEYS
    end
    return STYLE_TARGET_KEYS[idx]
end

local function GetStyleTargetIndexFromKey(key)
    key = tostring(key or "all")
    for i, k in ipairs(STYLE_TARGET_KEYS) do
        if k == key then
            return i
        end
    end
    return 1
end

local function GetStyleTargetDisplayName(key)
    key = tostring(key or "all")
    if key == "player" then
        return "Player"
    elseif key == "target" then
        return "Target"
    elseif key == "watchtarget" then
        return "Watchtarget"
    elseif key == "target_of_target" then
        return "Target of Target"
    end
    return "All frames"
end

local function GetStyleTargetKeyFromLabel(text)
    local value = string.lower(tostring(text or ""))
    if value == "player" then
        return "player"
    elseif value == "target" then
        return "target"
    elseif value == "watchtarget" then
        return "watchtarget"
    elseif value == "target of target" then
        return "target_of_target"
    elseif value == "all frames" then
        return "all"
    end
    return nil
end

local function GetComboBoxText(ctrl)
    if ctrl == nil then
        return nil
    end

    local getters = {
        "GetSelectedText",
        "GetText",
        "GetSelectedValue",
        "GetSelectedItemText"
    }

    for _, name in ipairs(getters) do
        local fn = ctrl[name]
        if type(fn) == "function" then
            local ok, res = pcall(function()
                return fn(ctrl)
            end)
            if ok and type(res) == "string" and res ~= "" then
                return res
            end
        end
    end

    return nil
end

local function GetStyleTargetKeyFromControl(ctrl, eventArg1, eventArg2)
    local directTextKeys = {
        GetStyleTargetKeyFromLabel(eventArg2),
        GetStyleTargetKeyFromLabel(eventArg1),
        GetStyleTargetKeyFromLabel(GetComboBoxText(ctrl))
    }
    for _, key in ipairs(directTextKeys) do
        if key ~= nil then
            return key
        end
    end

    local items = type(ctrl) == "table" and ctrl.__polar_items or nil
    local numericArgs = { tonumber(eventArg2), tonumber(eventArg1) }
    if type(items) == "table" then
        for _, rawArg in ipairs(numericArgs) do
            if type(rawArg) == "number" then
                local idx = math.floor(rawArg + 0.5)
                local key = GetStyleTargetKeyFromLabel(items[idx]) or GetStyleTargetKeyFromLabel(items[idx + 1])
                if key ~= nil then
                    return key
                end
            end
        end
    end

    local textKey = GetStyleTargetKeyFromLabel(GetComboBoxText(ctrl))
    if textKey ~= nil then
        return textKey
    end

    local raw = GetComboBoxIndexRaw(ctrl)
    if type(items) == "table" and type(raw) == "number" then
        local idx = math.floor(raw + 0.5)
        local key = GetStyleTargetKeyFromLabel(items[idx]) or GetStyleTargetKeyFromLabel(items[idx + 1])
        if key ~= nil then
            return key
        end
    end

    local idx = GetComboBoxIndex1Based(ctrl, #STYLE_TARGET_KEYS)
    if idx ~= nil then
        return GetStyleTargetKeyFromIndex(idx)
    end
    return "all"
end

local function UpdateStyleTargetHints()
    local targetLabel = GetStyleTargetDisplayName(SettingsPage.style_target)
    local summary = ""
    if SettingsPage.style_target == "all" then
        summary = "Editing shared defaults for all overlay frames."
    else
        summary = string.format("Editing only %s overrides. Unchanged values still inherit from All frames.", targetLabel)
    end

    local hintKeys = {
        "style_target_text_hint",
        "style_target_bars_hint"
    }

    for _, key in ipairs(hintKeys) do
        local label = SettingsPage.controls[key]
        if label ~= nil and label.SetText ~= nil then
            label:SetText(summary)
        end
    end
end

local function EffectiveStyle(base, override)
    local out = {}
    if type(base) == "table" then
        for k, v in pairs(base) do
            if k ~= "frames" then
                out[k] = v
            end
        end
    end
    if type(override) == "table" then
        for k, v in pairs(override) do
            if k ~= "frames" and k ~= "large_hpmp" and k ~= "buff_windows" and k ~= "aura" then
                out[k] = v
            end
        end
    end
    return out
end

local function GetStyleTables(settings)
    EnsureStyleFrames(settings)
    local base = settings.style

    local target = tostring(SettingsPage.style_target or "all")
    if target == "all" then
        return base, base
    end

    local override = (type(base.frames) == "table") and base.frames[target] or nil
    if type(override) ~= "table" then
        override = {}
    end
    return EffectiveStyle(base, override), override
end

local function DeepCopySimple(obj, visited)
    visited = visited or {}
    local t = type(obj)
    if t ~= "table" then
        return obj
    end
    if visited[obj] ~= nil then
        return visited[obj]
    end
    local out = {}
    visited[obj] = out
    for k, v in pairs(obj) do
        out[DeepCopySimple(k, visited)] = DeepCopySimple(v, visited)
    end
    return out
end

local function CopyTableInto(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end
    for k, _ in pairs(dst) do
        dst[k] = nil
    end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = DeepCopySimple(v)
        else
            dst[k] = v
        end
    end
end

local function CopyStatusbarCoords(dstKey, srcKey)
    if STATUSBAR_STYLE == nil or type(STATUSBAR_STYLE) ~= "table" then
        return
    end
    if type(dstKey) ~= "string" or type(srcKey) ~= "string" then
        return
    end
    local dst = STATUSBAR_STYLE[dstKey]
    local src = STATUSBAR_STYLE[srcKey]
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end
    if type(src.coords) ~= "table" then
        return
    end
    dst.coords = DeepCopySimple(src.coords)
end

local function CreatePage(id, parent)
    local page = api.Interface:CreateWidget("emptywidget", id, parent)
    pcall(function()
        if page.AddAnchor ~= nil then
            page:AddAnchor("TOPLEFT", parent, 0, 0)
            page:AddAnchor("RIGHT", parent, 0, 0)
        end
    end)
    pcall(function()
        if page.Show ~= nil then
            page:Show(false)
        end
    end)
    return page
end

local function SetActivePage(pageId)
    if SettingsPage.pages == nil or SettingsPage.pages[pageId] == nil then
        return
    end

    for id, page in pairs(SettingsPage.pages) do
        if page ~= nil and page.Show ~= nil then
            page:Show(id == pageId)
        end
    end
    SettingsPage.active_page = pageId

    if pageId == "dailyage" and type(SettingsPage.RefreshDailyAgeList) == "function" then
        pcall(function()
            SettingsPage.RefreshDailyAgeList()
        end)
    end

    local function syncStyleTargetCombo(ctrl)
        if ctrl == nil then
            return
        end
        SettingsPage._refreshing_style_target = true
        local targetIdx = GetStyleTargetIndexFromKey(SettingsPage.style_target)
        ctrl.__polar_index_base = nil
        SetComboBoxIndex1Based(ctrl, targetIdx)
        SettingsPage._refreshing_style_target = false
    end

    if pageId == "text" then
        syncStyleTargetCombo(SettingsPage.controls.style_target_text)
    elseif pageId == "bars" then
        syncStyleTargetCombo(SettingsPage.controls.style_target_bars)
    end

    UpdateStyleTargetHints()

    local page = SettingsPage.pages[pageId]

    local totalHeight = tonumber(SettingsPage.page_heights[pageId]) or 0
    pcall(function()
        if SettingsPage.scroll_frame ~= nil and SettingsPage.scroll_frame.ResetScroll ~= nil then
            SettingsPage.scroll_frame:ResetScroll(totalHeight)
        end
    end)

    pcall(function()
        if SettingsPage.scroll_frame ~= nil and SettingsPage.scroll_frame.scroll ~= nil and SettingsPage.scroll_frame.scroll.vs ~= nil then
            local vs = SettingsPage.scroll_frame.scroll.vs
            if vs.SetValue ~= nil then
                vs:SetValue(0, false)
            end
        end
    end)

    pcall(function()
        if page ~= nil and page.ChangeChildAnchorByScrollValue ~= nil then
            page:ChangeChildAnchorByScrollValue("vert", 0)
        end
    end)
end

local function MakeCloseHandler()
    return function()
        if SettingsPage.window ~= nil then
            SettingsPage.window:Show(false)
        end
    end
end

local function RestoreSettingsButtonPos(widget)
    if widget == nil then
        return
    end
    if SettingsPage.settings == nil or type(SettingsPage.settings) ~= "table" then
        return
    end

    local pos = SettingsPage.settings.settings_button
    local x = 10
    local y = 200
    if type(pos) == "table" then
        x = tonumber(pos.x) or x
        y = tonumber(pos.y) or y
    end

    pcall(function()
        if widget.RemoveAllAnchors ~= nil then
            widget:RemoveAllAnchors()
        end
        if widget.AddAnchor ~= nil then
            widget:AddAnchor("TOPLEFT", "UIParent", x, y)
        end
    end)
end

local function SaveSettingsButtonPos(widget)
    if widget == nil or widget.GetOffset == nil then
        return
    end
    if SettingsPage.settings == nil or type(SettingsPage.settings) ~= "table" then
        return
    end

    local ok, x, y = pcall(function()
        return widget:GetOffset()
    end)
    if not ok then
        return
    end

    x = tonumber(x)
    y = tonumber(y)
    if x == nil or y == nil then
        return
    end

    if type(SettingsPage.settings.settings_button) ~= "table" then
        SettingsPage.settings.settings_button = {}
    end
    SettingsPage.settings.settings_button.x = x
    SettingsPage.settings.settings_button.y = y

    if type(SettingsPage.on_save) == "function" then
        pcall(function()
            SettingsPage.on_save()
        end)
    end
end

local function EnsureSettingsButton()
    if SettingsPage.toggle_button ~= nil then
        return
    end

    local btn = nil
    pcall(function()
        btn = api.Interface:CreateWidget("button", "polarUiSettingsToggleBtn", api.rootWindow)
    end)
    if btn == nil then
        return
    end

    SettingsPage.toggle_button = btn
    SettingsPage.toggle_button_dragging = false

    pcall(function()
        if btn.SetText ~= nil then
            btn:SetText("PUI")
        end
        if api.Interface ~= nil and api.Interface.ApplyButtonSkin ~= nil and BUTTON_BASIC ~= nil then
            api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
        end
        if btn.SetExtent ~= nil then
            btn:SetExtent(40, 26)
        end
        if btn.Show ~= nil then
            btn:Show(true)
        end
    end)

    RestoreSettingsButtonPos(btn)

    if btn.SetHandler ~= nil then
        btn:SetHandler("OnDragStart", function(self)
            SettingsPage.toggle_button_dragging = true
            if self.StartMoving ~= nil then
                self:StartMoving()
            end
        end)
        btn:SetHandler("OnDragStop", function(self)
            if self.StopMovingOrSizing ~= nil then
                self:StopMovingOrSizing()
            end
            if api.Cursor ~= nil and api.Cursor.ClearCursor ~= nil then
                pcall(function()
                    api.Cursor:ClearCursor()
                end)
            end
            SaveSettingsButtonPos(self)
        end)
        btn:SetHandler("OnClick", function()
            if SettingsPage.toggle_button_dragging then
                SettingsPage.toggle_button_dragging = false
                return
            end
            if SettingsPage.toggle ~= nil then
                SettingsPage.toggle()
            end
        end)
    end

    pcall(function()
        if btn.RegisterForDrag ~= nil then
            btn:RegisterForDrag("LeftButton")
        end
        if btn.EnableDrag ~= nil then
            btn:EnableDrag(true)
        end
    end)
end

local function StyleLabel(label, fontSize)
    if label == nil or label.style == nil then
        return
    end
    pcall(function()
        local r, g, b = 1, 1, 1
        if FONT_COLOR ~= nil and FONT_COLOR.TITLE ~= nil then
            r = FONT_COLOR.TITLE[1] or 1
            g = FONT_COLOR.TITLE[2] or 1
            b = FONT_COLOR.TITLE[3] or 1
        end
        label.style:SetAlign(ALIGN.LEFT)
        label.style:SetFontSize(fontSize)
        label.style:SetColor(r, g, b, 1)
    end)
end

local function CreateLabel(id, parent, text, x, y, fontSize)
    local label = api.Interface:CreateWidget("label", id, parent)
    pcall(function()
        label:AddAnchor("TOPLEFT", x, y)
    end)
    label:SetExtent(360, 20)
    label:SetText(text)
    StyleLabel(label, fontSize)
    return label
end

local function CreateHintLabel(id, parent, text, x, y, width)
    local label = api.Interface:CreateWidget("label", id, parent)
    pcall(function()
        label:AddAnchor("TOPLEFT", x, y)
    end)
    label:SetExtent(width or 520, 18)
    label:SetText(text)
    pcall(function()
        if label.style ~= nil then
            label.style:SetFontSize(12)
            label.style:SetAlign(ALIGN.LEFT)
            label.style:SetColor(0.75, 0.75, 0.75, 1)
        end
    end)
    return label
end

local function ApplyCheckButtonSkin(checkbox)
    if checkbox == nil or checkbox.CreateImageDrawable == nil then
        return
    end

    pcall(function()
        local function makeBg(coordsX, coordsY)
            local bg = checkbox:CreateImageDrawable("ui/button/check_button.dds", "background")
            bg:SetExtent(18, 17)
            bg:AddAnchor("CENTER", checkbox, 0, 0)
            bg:SetCoords(coordsX, coordsY, 18, 17)
            return bg
        end

        if checkbox.SetNormalBackground ~= nil then
            checkbox:SetNormalBackground(makeBg(0, 0))
        end
        if checkbox.SetHighlightBackground ~= nil then
            checkbox:SetHighlightBackground(makeBg(0, 0))
        end
        if checkbox.SetPushedBackground ~= nil then
            checkbox:SetPushedBackground(makeBg(0, 0))
        end
        if checkbox.SetDisabledBackground ~= nil then
            checkbox:SetDisabledBackground(makeBg(0, 17))
        end
        if checkbox.SetCheckedBackground ~= nil then
            checkbox:SetCheckedBackground(makeBg(18, 0))
        end
        if checkbox.SetDisabledCheckedBackground ~= nil then
            checkbox:SetDisabledCheckedBackground(makeBg(18, 17))
        end
    end)
end

local function CreateCheckbox(id, parent, text, x, y)
    local checkbox = nil

    if api._Library ~= nil and api._Library.UI ~= nil and api._Library.UI.CreateCheckButton ~= nil then
        local ok, res = pcall(function()
            return api._Library.UI.CreateCheckButton(id, parent, text)
        end)
        if ok then
            checkbox = res
        end
        if checkbox ~= nil and checkbox.AddAnchor ~= nil then
            local ok = pcall(function()
                checkbox:AddAnchor("TOPLEFT", parent, x, y)
            end)
            if not ok then
                pcall(function()
                    checkbox:AddAnchor("TOPLEFT", x, y)
                end)
            end
        end
        if checkbox ~= nil and checkbox.SetButtonStyle ~= nil then
            checkbox:SetButtonStyle("default")
        end
        return checkbox
    end

    checkbox = api.Interface:CreateWidget("checkbutton", id, parent)
    checkbox:SetExtent(18, 17)
    pcall(function()
        checkbox:AddAnchor("TOPLEFT", parent, x, y)
    end)
    ApplyCheckButtonSkin(checkbox)

    local label = api.Interface:CreateWidget("label", id .. "Label", parent)
    pcall(function()
        label:AddAnchor("LEFT", checkbox, "RIGHT", 6, 0)
    end)
    label:SetExtent(320, 18)
    label:SetText(text)
    pcall(function()
        if label.style ~= nil then
            label.style:SetFontSize(13)
            label.style:SetAlign(ALIGN.LEFT)
            label.style:SetColor(1, 1, 1, 1)
        end
        if label.Clickable ~= nil then
            label:Clickable(true)
        end
    end)

    if label.SetHandler ~= nil then
        label:SetHandler("OnClick", function()
            if checkbox ~= nil and checkbox.SetChecked ~= nil and checkbox.GetChecked ~= nil then
                checkbox:SetChecked(not checkbox:GetChecked())
            end
        end)
    end

    return checkbox
end

local function CreateButton(id, parent, text, x, y)
    local button = api.Interface:CreateWidget("button", id, parent)
    button:AddAnchor("TOPLEFT", x, y)
    button:SetExtent(90, 26)
    button:SetText(text)
    api.Interface:ApplyButtonSkin(button, BUTTON_BASIC.DEFAULT)
    return button
end

local function CreateEdit(id, parent, text, x, y, width, height)
    local field = nil
    pcall(function()
        if W_CTRL ~= nil and W_CTRL.CreateEdit ~= nil then
            field = W_CTRL.CreateEdit(id, parent)
        elseif api.Interface ~= nil and api.Interface.CreateWidget ~= nil then
            field = api.Interface:CreateWidget("edit", id, parent)
        end
    end)
    if field == nil then
        return nil
    end
    pcall(function()
        field:SetExtent(width, height)
        if field.AddAnchor ~= nil then
            local ok = pcall(function()
                field:AddAnchor("TOPLEFT", parent, x, y)
            end)
            if not ok then
                field:AddAnchor("TOPLEFT", x, y)
            end
        end
        if field.SetText ~= nil then
            field:SetText(tostring(text or ""))
        end
        if field.style ~= nil then
            field.style:SetColor(0, 0, 0, 1)
            field.style:SetAlign(ALIGN.LEFT)
        end
    end)
    return field
end

local function GetSliderValue(slider)
    if slider == nil then
        return 0
    end
    local ok, res = pcall(function()
        if slider.GetValue ~= nil then
            return slider:GetValue()
        end
        return nil
    end)
    if ok and type(res) == "number" then
        return res
    end
    return 0
end

local function SetSliderValue(slider, value)
    if slider == nil then
        return
    end
    pcall(function()
        if slider.SetValue ~= nil then
            slider:SetValue(value, false)
        elseif slider.SetInitialValue ~= nil then
            slider:SetInitialValue(value)
        end
    end)
end

local function CreateSlider(id, parent, text, x, y, minVal, maxVal, step)
    local label = api.Interface:CreateWidget("label", id .. "Label", parent)
    pcall(function()
        label:AddAnchor("TOPLEFT", x, y)
    end)
    label:SetExtent(170, 18)
    label:SetText(text)
    pcall(function()
        if label.style ~= nil then
            label.style:SetFontSize(13)
            label.style:SetAlign(ALIGN.LEFT)
            label.style:SetColor(1, 1, 1, 1)
        end
    end)

    local slider = nil
    if api._Library ~= nil and api._Library.UI ~= nil and api._Library.UI.CreateSlider ~= nil then
        local ok, res = pcall(function()
            return api._Library.UI.CreateSlider(id, parent)
        end)
        if ok then
            slider = res
        end
    end

    if slider ~= nil then
        pcall(function()
            slider:SetExtent(250, 26)
            slider:AddAnchor("TOPLEFT", x + 175, y - 4)
            slider:SetMinMaxValues(minVal, maxVal)
            if slider.SetStep ~= nil then
                slider:SetStep(step)
            else
                slider:SetValueStep(step)
            end
        end)
    end

    local valueLabel = api.Interface:CreateWidget("label", id .. "Value", parent)
    pcall(function()
        valueLabel:AddAnchor("TOPLEFT", x + 430, y)
    end)
    valueLabel:SetExtent(60, 18)
    valueLabel:SetText("0")
    pcall(function()
        if valueLabel.style ~= nil then
            valueLabel.style:SetFontSize(13)
            valueLabel.style:SetAlign(ALIGN.LEFT)
            valueLabel.style:SetColor(1, 1, 1, 1)
        end
    end)

    return slider, valueLabel
end

local function CreateComboBox(parent, values, x, y, width, height)
    local dropdown = nil
    pcall(function()
        if W_CTRL ~= nil and W_CTRL.CreateComboBox ~= nil then
            dropdown = W_CTRL.CreateComboBox(parent)
        elseif api.Interface ~= nil and api.Interface.CreateComboBox ~= nil then
            dropdown = api.Interface:CreateComboBox(parent)
        end
    end)
    if dropdown == nil then
        return nil
    end
    dropdown.__polar_items = values
    pcall(function()
        local anchored = false
        if dropdown.AddAnchor ~= nil then
            local okAnchor = pcall(function()
                dropdown:AddAnchor("TOPLEFT", parent, x, y)
            end)
            anchored = okAnchor and true or false
            if not anchored then
                pcall(function()
                    dropdown:AddAnchor("TOPLEFT", x, y)
                end)
            end
        end

        if dropdown.SetExtent ~= nil then
            dropdown:SetExtent(width or 220, height or 24)
        end

        if dropdown.AddItem ~= nil and type(values) == "table" then
            for _, v in ipairs(values) do
                dropdown:AddItem(tostring(v))
            end
        else
            dropdown.dropdownItem = values
        end

        if dropdown.Show ~= nil then
            dropdown:Show(true)
        end
    end)
    return dropdown
end

local function RefreshControls()
    local s = SettingsPage.settings
    if s == nil then
        return
    end
    if SettingsPage.controls.enabled ~= nil then
        SettingsPage.controls.enabled:SetChecked(s.enabled and true or false)
    end

    UpdateStyleTargetHints()

    local displayStyle, _ = GetStyleTables(s)

    local function refreshAlpha(slider, valueLabel, value)
        local pct = math.floor(((tonumber(value) or 1) * 100) + 0.5)
        if pct < 0 then
            pct = 0
        elseif pct > 100 then
            pct = 100
        end
        if slider ~= nil then
            SetSliderValue(slider, pct)
        end
        if valueLabel ~= nil and valueLabel.SetText ~= nil then
            valueLabel:SetText(tostring(pct))
        end
    end

    local function refreshSlider(slider, valueLabel, value)
        if slider ~= nil then
            SetSliderValue(slider, value)
        end
        if valueLabel ~= nil and valueLabel.SetText ~= nil then
            valueLabel:SetText(tostring(math.floor((tonumber(value) or 0) + 0.5)))
        end
    end

    if type(s.style) == "table" and SettingsPage.controls.large_hpmp ~= nil then
        SettingsPage.controls.large_hpmp:SetChecked(s.style.large_hpmp ~= false)
    end

    if SettingsPage.controls.show_distance ~= nil then
        SettingsPage.controls.show_distance:SetChecked(s.show_distance ~= false)
    end

    if SettingsPage.controls.alignment_grid_enabled ~= nil then
        SettingsPage.controls.alignment_grid_enabled:SetChecked(s.alignment_grid_enabled and true or false)
    end

    EnsureDailyAgeTables(s)
    if SettingsPage.controls.dailyage_enabled ~= nil then
        SettingsPage.controls.dailyage_enabled:SetChecked(s.dailyage.enabled and true or false)
    end

    if SettingsPage.controls.frame_alpha ~= nil then
        local fa = nil
        if type(displayStyle) == "table" then
            fa = tonumber(displayStyle.frame_alpha)
        end
        if fa == nil then
            fa = tonumber(s.frame_alpha)
        end
        refreshAlpha(SettingsPage.controls.frame_alpha, SettingsPage.controls.frame_alpha_val, fa)
    end

    if type(displayStyle) == "table" and SettingsPage.controls.overlay_alpha ~= nil then
        refreshAlpha(SettingsPage.controls.overlay_alpha, SettingsPage.controls.overlay_alpha_val, displayStyle.overlay_alpha)
    end

    if SettingsPage.controls.frame_width ~= nil then
        local fw = nil
        if type(displayStyle) == "table" then
            fw = tonumber(displayStyle.frame_width)
        end
        if fw == nil then
            fw = tonumber(s.frame_width)
        end
        refreshSlider(SettingsPage.controls.frame_width, SettingsPage.controls.frame_width_val, fw or 320)
    end
    if SettingsPage.controls.frame_height ~= nil then
        refreshSlider(SettingsPage.controls.frame_height, SettingsPage.controls.frame_height_val, tonumber(s.frame_height) or 64)
    end
    if SettingsPage.controls.frame_scale ~= nil then
        local fs = nil
        if type(displayStyle) == "table" then
            fs = tonumber(displayStyle.frame_scale)
        end
        if fs == nil then
            fs = tonumber(s.frame_scale)
        end
        local pct = math.floor(((tonumber(fs) or 1) * 100) + 0.5)
        if pct < 50 then
            pct = 50
        elseif pct > 150 then
            pct = 150
        end
        refreshSlider(SettingsPage.controls.frame_scale, SettingsPage.controls.frame_scale_val, pct)
    end
    if SettingsPage.controls.bar_height ~= nil then
        local bh = nil
        if type(displayStyle) == "table" then
            bh = tonumber(displayStyle.bar_height)
        end
        if bh == nil then
            bh = tonumber(s.bar_height)
        end
        refreshSlider(SettingsPage.controls.bar_height, SettingsPage.controls.bar_height_val, bh or 18)
    end
    if SettingsPage.controls.hp_bar_height ~= nil then
        local hpBh = nil
        if type(displayStyle) == "table" then
            hpBh = tonumber(displayStyle.hp_bar_height) or tonumber(displayStyle.bar_height)
        end
        if hpBh == nil then
            hpBh = tonumber(s.bar_height)
        end
        refreshSlider(SettingsPage.controls.hp_bar_height, SettingsPage.controls.hp_bar_height_val, hpBh or 18)
    end
    if SettingsPage.controls.mp_bar_height ~= nil then
        local mpBh = nil
        if type(displayStyle) == "table" then
            mpBh = tonumber(displayStyle.mp_bar_height) or tonumber(displayStyle.bar_height)
        end
        if mpBh == nil then
            mpBh = tonumber(s.bar_height)
        end
        refreshSlider(SettingsPage.controls.mp_bar_height, SettingsPage.controls.mp_bar_height_val, mpBh or 18)
    end
    if SettingsPage.controls.bar_gap ~= nil then
        local gap = 0
        if type(displayStyle) == "table" and displayStyle.bar_gap ~= nil then
            gap = tonumber(displayStyle.bar_gap) or 0
        end
        refreshSlider(SettingsPage.controls.bar_gap, SettingsPage.controls.bar_gap_val, gap)
    end

    if type(s.nameplates) == "table" then
        if SettingsPage.controls.plates_enabled ~= nil then
            SettingsPage.controls.plates_enabled:SetChecked(s.nameplates.enabled and true or false)
        end
        if SettingsPage.controls.plates_guild_only ~= nil then
            SettingsPage.controls.plates_guild_only:SetChecked(s.nameplates.guild_only and true or false)
        end
        if SettingsPage.controls.plates_show_target ~= nil then
            SettingsPage.controls.plates_show_target:SetChecked(s.nameplates.show_target ~= false)
        end
        if SettingsPage.controls.plates_show_player ~= nil then
            SettingsPage.controls.plates_show_player:SetChecked(s.nameplates.show_player and true or false)
        end
        if SettingsPage.controls.plates_show_raid_party ~= nil then
            SettingsPage.controls.plates_show_raid_party:SetChecked(s.nameplates.show_raid_party ~= false)
        end
        if SettingsPage.controls.plates_show_watchtarget ~= nil then
            SettingsPage.controls.plates_show_watchtarget:SetChecked(s.nameplates.show_watchtarget ~= false)
        end
        if SettingsPage.controls.plates_show_mount ~= nil then
            SettingsPage.controls.plates_show_mount:SetChecked(s.nameplates.show_mount ~= false)
        end
        if SettingsPage.controls.plates_show_guild ~= nil then
            SettingsPage.controls.plates_show_guild:SetChecked(s.nameplates.show_guild ~= false)
        end
        if SettingsPage.controls.plates_click_shift ~= nil then
            SettingsPage.controls.plates_click_shift:SetChecked(true)
            SetWidgetEnabled(SettingsPage.controls.plates_click_shift, false)
        end
        if SettingsPage.controls.plates_click_ctrl ~= nil then
            SettingsPage.controls.plates_click_ctrl:SetChecked(true)
            SetWidgetEnabled(SettingsPage.controls.plates_click_ctrl, false)
        end
        if SettingsPage.controls.plates_runtime_status ~= nil and SettingsPage.controls.plates_runtime_status.SetText ~= nil then
            local runtimeText = Compat ~= nil and Compat.GetStatusText() or "Runtime OK"
            SettingsPage.controls.plates_runtime_status:SetText(runtimeText)
        end
        if SettingsPage.controls.plates_alpha ~= nil then
            refreshSlider(SettingsPage.controls.plates_alpha, SettingsPage.controls.plates_alpha_val, tonumber(s.nameplates.alpha_pct) or 100)
        end
        if SettingsPage.controls.plates_width ~= nil then
            refreshSlider(SettingsPage.controls.plates_width, SettingsPage.controls.plates_width_val, tonumber(s.nameplates.width) or 100)
        end
        if SettingsPage.controls.plates_hp_h ~= nil then
            refreshSlider(SettingsPage.controls.plates_hp_h, SettingsPage.controls.plates_hp_h_val, tonumber(s.nameplates.hp_height) or 28)
        end
        if SettingsPage.controls.plates_mp_h ~= nil then
            refreshSlider(SettingsPage.controls.plates_mp_h, SettingsPage.controls.plates_mp_h_val, tonumber(s.nameplates.mp_height) or 4)
        end
        if SettingsPage.controls.plates_x_offset ~= nil then
            refreshSlider(SettingsPage.controls.plates_x_offset, SettingsPage.controls.plates_x_offset_val, tonumber(s.nameplates.x_offset) or 0)
        end
        if SettingsPage.controls.plates_max_dist ~= nil then
            refreshSlider(SettingsPage.controls.plates_max_dist, SettingsPage.controls.plates_max_dist_val, tonumber(s.nameplates.max_distance) or 130)
        end
        if SettingsPage.controls.plates_y_offset ~= nil then
            refreshSlider(SettingsPage.controls.plates_y_offset, SettingsPage.controls.plates_y_offset_val, tonumber(s.nameplates.y_offset) or 22)
        end
        if SettingsPage.controls.plates_anchor_tag ~= nil then
            SettingsPage.controls.plates_anchor_tag:SetChecked(s.nameplates.anchor_to_nametag ~= false)
        end
        if SettingsPage.controls.plates_bg_enabled ~= nil then
            SettingsPage.controls.plates_bg_enabled:SetChecked(s.nameplates.bg_enabled ~= false)
        end
        if SettingsPage.controls.plates_bg_alpha ~= nil then
            refreshSlider(SettingsPage.controls.plates_bg_alpha, SettingsPage.controls.plates_bg_alpha_val, tonumber(s.nameplates.bg_alpha_pct) or 80)
        end
        if SettingsPage.controls.plates_name_fs ~= nil then
            refreshSlider(SettingsPage.controls.plates_name_fs, SettingsPage.controls.plates_name_fs_val, tonumber(s.nameplates.name_font_size) or 14)
        end
        if SettingsPage.controls.plates_guild_fs ~= nil then
            refreshSlider(SettingsPage.controls.plates_guild_fs, SettingsPage.controls.plates_guild_fs_val, tonumber(s.nameplates.guild_font_size) or 11)
        end

        if SettingsPage.controls.plates_guild_color_r ~= nil then
            refreshSlider(SettingsPage.controls.plates_guild_color_r, SettingsPage.controls.plates_guild_color_r_val, 255)
        end
        if SettingsPage.controls.plates_guild_color_g ~= nil then
            refreshSlider(SettingsPage.controls.plates_guild_color_g, SettingsPage.controls.plates_guild_color_g_val, 255)
        end
        if SettingsPage.controls.plates_guild_color_b ~= nil then
            refreshSlider(SettingsPage.controls.plates_guild_color_b, SettingsPage.controls.plates_guild_color_b_val, 255)
        end

        if type(s.nameplates.guild_colors) ~= "table" then
            s.nameplates.guild_colors = {}
        end

        if type(SettingsPage.controls.plates_guild_color_rows) == "table" then
            local keys = {}
            for k, _ in pairs(s.nameplates.guild_colors) do
                table.insert(keys, tostring(k))
            end
            table.sort(keys)

            for i, row in ipairs(SettingsPage.controls.plates_guild_color_rows) do
                local key = keys[i]
                local show = key ~= nil and key ~= ""

                if type(row) == "table" then
                    if row.label ~= nil and row.label.SetText ~= nil then
                        if show then
                            local rgba = s.nameplates.guild_colors[key]
                            local r01 = type(rgba) == "table" and tonumber(rgba[1]) or 1
                            local g01 = type(rgba) == "table" and tonumber(rgba[2]) or 1
                            local b01 = type(rgba) == "table" and tonumber(rgba[3]) or 1
                            local r = math.floor((r01 * 255) + 0.5)
                            local g = math.floor((g01 * 255) + 0.5)
                            local b = math.floor((b01 * 255) + 0.5)
                            row.label:SetText(string.format("%s  (%d, %d, %d)", tostring(key), r, g, b))
                        else
                            row.label:SetText("")
                        end
                    end

                    if row.label ~= nil and row.label.Show ~= nil then
                        row.label:Show(show)
                    end

                    if row.remove ~= nil then
                        row.remove.__polar_guild_key = key
                        if row.remove.Show ~= nil then
                            row.remove:Show(show)
                        end
                    end
                end
            end
        end
    end

    if type(displayStyle) == "table" then
        if SettingsPage.controls.name_visible ~= nil then
            SettingsPage.controls.name_visible:SetChecked(displayStyle.name_visible ~= false)
        end
        if SettingsPage.controls.name_offset_x ~= nil then
            refreshSlider(SettingsPage.controls.name_offset_x, SettingsPage.controls.name_offset_x_val, tonumber(displayStyle.name_offset_x) or 0)
        end
        if SettingsPage.controls.name_offset_y ~= nil then
            refreshSlider(SettingsPage.controls.name_offset_y, SettingsPage.controls.name_offset_y_val, tonumber(displayStyle.name_offset_y) or 0)
        end

        if SettingsPage.controls.level_visible ~= nil then
            SettingsPage.controls.level_visible:SetChecked(displayStyle.level_visible ~= false)
        end
        if SettingsPage.controls.level_font_size ~= nil then
            refreshSlider(SettingsPage.controls.level_font_size, SettingsPage.controls.level_font_size_val, tonumber(displayStyle.level_font_size) or 12)
        end
        if SettingsPage.controls.level_offset_x ~= nil then
            refreshSlider(SettingsPage.controls.level_offset_x, SettingsPage.controls.level_offset_x_val, tonumber(displayStyle.level_offset_x) or 0)
        end
        if SettingsPage.controls.level_offset_y ~= nil then
            refreshSlider(SettingsPage.controls.level_offset_y, SettingsPage.controls.level_offset_y_val, tonumber(displayStyle.level_offset_y) or 0)
        end

        if SettingsPage.controls.name_font_size ~= nil then
            refreshSlider(SettingsPage.controls.name_font_size, SettingsPage.controls.name_font_size_val, tonumber(displayStyle.name_font_size) or 14)
        end
        if SettingsPage.controls.hp_font_size ~= nil then
            refreshSlider(SettingsPage.controls.hp_font_size, SettingsPage.controls.hp_font_size_val, tonumber(displayStyle.hp_font_size) or 16)
        end
        if SettingsPage.controls.mp_font_size ~= nil then
            refreshSlider(SettingsPage.controls.mp_font_size, SettingsPage.controls.mp_font_size_val, tonumber(displayStyle.mp_font_size) or 11)
        end
        if SettingsPage.controls.overlay_font_size ~= nil then
            refreshSlider(SettingsPage.controls.overlay_font_size, SettingsPage.controls.overlay_font_size_val, tonumber(displayStyle.overlay_font_size) or 12)
        end

        if SettingsPage.controls.gs_font_size ~= nil then
            refreshSlider(SettingsPage.controls.gs_font_size, SettingsPage.controls.gs_font_size_val, tonumber(displayStyle.gs_font_size) or (tonumber(displayStyle.overlay_font_size) or 12))
        end
        if SettingsPage.controls.class_font_size ~= nil then
            refreshSlider(SettingsPage.controls.class_font_size, SettingsPage.controls.class_font_size_val, tonumber(displayStyle.class_font_size) or (tonumber(displayStyle.overlay_font_size) or 12))
        end
        if SettingsPage.controls.role_font_size ~= nil then
            refreshSlider(SettingsPage.controls.role_font_size, SettingsPage.controls.role_font_size_val, tonumber(displayStyle.role_font_size) or (tonumber(displayStyle.overlay_font_size) or 12))
        end

        if SettingsPage.controls.target_guild_font_size ~= nil then
            refreshSlider(
                SettingsPage.controls.target_guild_font_size,
                SettingsPage.controls.target_guild_font_size_val,
                tonumber(displayStyle.target_guild_font_size) or (tonumber(displayStyle.overlay_font_size) or 12)
            )
        end

        if SettingsPage.controls.name_shadow ~= nil then
            SettingsPage.controls.name_shadow:SetChecked(displayStyle.name_shadow and true or false)
        end
        if SettingsPage.controls.value_shadow ~= nil then
            SettingsPage.controls.value_shadow:SetChecked(displayStyle.value_shadow ~= false)
        end
        if SettingsPage.controls.overlay_shadow ~= nil then
            SettingsPage.controls.overlay_shadow:SetChecked(displayStyle.overlay_shadow ~= false)
        end

        if SettingsPage.controls.hp_value_offset_x ~= nil then
            refreshSlider(SettingsPage.controls.hp_value_offset_x, SettingsPage.controls.hp_value_offset_x_val, tonumber(displayStyle.hp_value_offset_x) or 0)
        end
        if SettingsPage.controls.hp_value_offset_y ~= nil then
            refreshSlider(SettingsPage.controls.hp_value_offset_y, SettingsPage.controls.hp_value_offset_y_val, tonumber(displayStyle.hp_value_offset_y) or 0)
        end
        if SettingsPage.controls.mp_value_offset_x ~= nil then
            refreshSlider(SettingsPage.controls.mp_value_offset_x, SettingsPage.controls.mp_value_offset_x_val, tonumber(displayStyle.mp_value_offset_x) or 0)
        end
        if SettingsPage.controls.mp_value_offset_y ~= nil then
            refreshSlider(SettingsPage.controls.mp_value_offset_y, SettingsPage.controls.mp_value_offset_y_val, tonumber(displayStyle.mp_value_offset_y) or 0)
        end

        if SettingsPage.controls.target_guild_offset_x ~= nil then
            refreshSlider(
                SettingsPage.controls.target_guild_offset_x,
                SettingsPage.controls.target_guild_offset_x_val,
                tonumber(displayStyle.target_guild_offset_x) or 10
            )
        end
        if SettingsPage.controls.target_guild_offset_y ~= nil then
            refreshSlider(
                SettingsPage.controls.target_guild_offset_y,
                SettingsPage.controls.target_guild_offset_y_val,
                tonumber(displayStyle.target_guild_offset_y) or -54
            )
        end

        if SettingsPage.controls.bar_colors_enabled ~= nil then
            SettingsPage.controls.bar_colors_enabled:SetChecked(displayStyle.bar_colors_enabled and true or false)
        end

        local hpFill = type(displayStyle.hp_fill_color) == "table" and displayStyle.hp_fill_color or (type(displayStyle.hp_bar_color) == "table" and displayStyle.hp_bar_color or {})
        local hpAfter = type(displayStyle.hp_after_color) == "table" and displayStyle.hp_after_color or (type(displayStyle.hp_bar_color) == "table" and displayStyle.hp_bar_color or {})
        local mpFill = type(displayStyle.mp_fill_color) == "table" and displayStyle.mp_fill_color or (type(displayStyle.mp_bar_color) == "table" and displayStyle.mp_bar_color or {})
        local mpAfter = type(displayStyle.mp_after_color) == "table" and displayStyle.mp_after_color or (type(displayStyle.mp_bar_color) == "table" and displayStyle.mp_bar_color or {})

        if SettingsPage.controls.hp_r ~= nil then
            refreshSlider(SettingsPage.controls.hp_r, SettingsPage.controls.hp_r_val, tonumber(hpFill[1]) or 223)
        end
        if SettingsPage.controls.hp_g ~= nil then
            refreshSlider(SettingsPage.controls.hp_g, SettingsPage.controls.hp_g_val, tonumber(hpFill[2]) or 69)
        end
        if SettingsPage.controls.hp_b ~= nil then
            refreshSlider(SettingsPage.controls.hp_b, SettingsPage.controls.hp_b_val, tonumber(hpFill[3]) or 69)
        end
        if SettingsPage.controls.hp_a ~= nil then
            refreshSlider(SettingsPage.controls.hp_a, SettingsPage.controls.hp_a_val, tonumber(hpFill[4]) or 255)
        end

        if SettingsPage.controls.hp_after_r ~= nil then
            refreshSlider(SettingsPage.controls.hp_after_r, SettingsPage.controls.hp_after_r_val, tonumber(hpAfter[1]) or 223)
        end
        if SettingsPage.controls.hp_after_g ~= nil then
            refreshSlider(SettingsPage.controls.hp_after_g, SettingsPage.controls.hp_after_g_val, tonumber(hpAfter[2]) or 69)
        end
        if SettingsPage.controls.hp_after_b ~= nil then
            refreshSlider(SettingsPage.controls.hp_after_b, SettingsPage.controls.hp_after_b_val, tonumber(hpAfter[3]) or 69)
        end
        if SettingsPage.controls.hp_after_a ~= nil then
            refreshSlider(SettingsPage.controls.hp_after_a, SettingsPage.controls.hp_after_a_val, tonumber(hpAfter[4]) or 255)
        end

        if SettingsPage.controls.mp_r ~= nil then
            refreshSlider(SettingsPage.controls.mp_r, SettingsPage.controls.mp_r_val, tonumber(mpFill[1]) or 86)
        end
        if SettingsPage.controls.mp_g ~= nil then
            refreshSlider(SettingsPage.controls.mp_g, SettingsPage.controls.mp_g_val, tonumber(mpFill[2]) or 198)
        end
        if SettingsPage.controls.mp_b ~= nil then
            refreshSlider(SettingsPage.controls.mp_b, SettingsPage.controls.mp_b_val, tonumber(mpFill[3]) or 239)
        end
        if SettingsPage.controls.mp_a ~= nil then
            refreshSlider(SettingsPage.controls.mp_a, SettingsPage.controls.mp_a_val, tonumber(mpFill[4]) or 255)
        end

        if SettingsPage.controls.mp_after_r ~= nil then
            refreshSlider(SettingsPage.controls.mp_after_r, SettingsPage.controls.mp_after_r_val, tonumber(mpAfter[1]) or 86)
        end
        if SettingsPage.controls.mp_after_g ~= nil then
            refreshSlider(SettingsPage.controls.mp_after_g, SettingsPage.controls.mp_after_g_val, tonumber(mpAfter[2]) or 198)
        end
        if SettingsPage.controls.mp_after_b ~= nil then
            refreshSlider(SettingsPage.controls.mp_after_b, SettingsPage.controls.mp_after_b_val, tonumber(mpAfter[3]) or 239)
        end
        if SettingsPage.controls.mp_after_a ~= nil then
            refreshSlider(SettingsPage.controls.mp_after_a, SettingsPage.controls.mp_after_a_val, tonumber(mpAfter[4]) or 255)
        end

        local tex = tostring(displayStyle.hp_texture_mode or "stock")
        if SettingsPage.controls.hp_tex_stock ~= nil then
            SettingsPage.controls.hp_tex_stock:SetChecked(tex == "stock")
        end
        if SettingsPage.controls.hp_tex_pc ~= nil then
            SettingsPage.controls.hp_tex_pc:SetChecked(tex == "pc")
        end
        if SettingsPage.controls.hp_tex_npc ~= nil then
            SettingsPage.controls.hp_tex_npc:SetChecked(tex == "npc")
        end
    end

    if type(displayStyle) == "table" then
        local fmt = tostring(displayStyle.value_format or "stock")
        if SettingsPage.controls.value_fmt_curmax ~= nil then
            SettingsPage.controls.value_fmt_curmax:SetChecked(fmt == "curmax" or fmt == "curmax_percent")
        end
        if SettingsPage.controls.value_fmt_percent ~= nil then
            SettingsPage.controls.value_fmt_percent:SetChecked(fmt == "percent" or fmt == "curmax_percent")
        end
        if SettingsPage.controls.short_numbers ~= nil then
            SettingsPage.controls.short_numbers:SetChecked(displayStyle.short_numbers and true or false)
        end
    end

    if type(s.style) == "table" and type(s.style.buff_windows) == "table" and SettingsPage.controls.move_buffs ~= nil then
        SettingsPage.controls.move_buffs:SetChecked(s.style.buff_windows.enabled and true or false)
    elseif SettingsPage.controls.move_buffs ~= nil then
        SettingsPage.controls.move_buffs:SetChecked(false)
    end

    local bw = (type(s.style) == "table" and type(s.style.buff_windows) == "table") and s.style.buff_windows or nil
    local aura = (type(s.style) == "table" and type(s.style.aura) == "table") and s.style.aura or nil

    if bw ~= nil then
        refreshSlider(SettingsPage.controls.p_buff_x, SettingsPage.controls.p_buff_x_val, bw.player.buff.x or 0)
        refreshSlider(SettingsPage.controls.p_buff_y, SettingsPage.controls.p_buff_y_val, bw.player.buff.y or 0)
        refreshSlider(SettingsPage.controls.p_debuff_x, SettingsPage.controls.p_debuff_x_val, bw.player.debuff.x or 0)
        refreshSlider(SettingsPage.controls.p_debuff_y, SettingsPage.controls.p_debuff_y_val, bw.player.debuff.y or 0)

        refreshSlider(SettingsPage.controls.t_buff_x, SettingsPage.controls.t_buff_x_val, bw.target.buff.x or 0)
        refreshSlider(SettingsPage.controls.t_buff_y, SettingsPage.controls.t_buff_y_val, bw.target.buff.y or 0)
        refreshSlider(SettingsPage.controls.t_debuff_x, SettingsPage.controls.t_debuff_x_val, bw.target.debuff.x or 0)
        refreshSlider(SettingsPage.controls.t_debuff_y, SettingsPage.controls.t_debuff_y_val, bw.target.debuff.y or 0)
    end

    if aura ~= nil then
        if SettingsPage.controls.aura_enabled ~= nil then
            SettingsPage.controls.aura_enabled:SetChecked(aura.enabled and true or false)
        end
        refreshSlider(SettingsPage.controls.aura_icon_size, SettingsPage.controls.aura_icon_size_val, aura.icon_size or 24)
        refreshSlider(SettingsPage.controls.aura_x_gap, SettingsPage.controls.aura_x_gap_val, aura.icon_x_gap or 2)
        refreshSlider(SettingsPage.controls.aura_y_gap, SettingsPage.controls.aura_y_gap_val, aura.icon_y_gap or 2)
        refreshSlider(SettingsPage.controls.aura_per_row, SettingsPage.controls.aura_per_row_val, aura.buffs_per_row or 10)
        if SettingsPage.controls.aura_sort_vertical ~= nil then
            SettingsPage.controls.aura_sort_vertical:SetChecked(aura.sort_vertical and true or false)
        end
    end

    EnsureCooldownTrackerTables(s)
    if SettingsPage.controls.ct_enabled ~= nil then
        SettingsPage.controls.ct_enabled:SetChecked(s.cooldown_tracker.enabled and true or false)
    end
    if SettingsPage.controls.ct_update_interval ~= nil then
        refreshSlider(
            SettingsPage.controls.ct_update_interval,
            SettingsPage.controls.ct_update_interval_val,
            tonumber(s.cooldown_tracker.update_interval_ms) or 50
        )
    end

    local unit_key = tostring(SettingsPage.cooldown_unit_key or "player")
    if SettingsPage.controls.ct_unit ~= nil then
        SetComboBoxIndex1Based(SettingsPage.controls.ct_unit, GetCooldownUnitIndexFromKey(unit_key))
    end

    local unit_cfg = s.cooldown_tracker.units[unit_key]
    if type(unit_cfg) == "table" then
        if SettingsPage.controls.ct_unit_enabled ~= nil then
            SettingsPage.controls.ct_unit_enabled:SetChecked(unit_cfg.enabled and true or false)
        end
        if SettingsPage.controls.ct_lock_position ~= nil then
            SettingsPage.controls.ct_lock_position:SetChecked(unit_cfg.lock_position and true or false)
        end
        if SettingsPage.controls.ct_show_timer ~= nil then
            SettingsPage.controls.ct_show_timer:SetChecked(unit_cfg.show_timer ~= false)
        end
        if SettingsPage.controls.ct_show_label ~= nil then
            SettingsPage.controls.ct_show_label:SetChecked(unit_cfg.show_label and true or false)
        end

        if SettingsPage.controls.ct_pos_x ~= nil and SettingsPage.controls.ct_pos_x.SetText ~= nil then
            SettingsPage.controls.ct_pos_x:SetText(tostring(tonumber(unit_cfg.pos_x) or 0))
        end
        if SettingsPage.controls.ct_pos_y ~= nil and SettingsPage.controls.ct_pos_y.SetText ~= nil then
            SettingsPage.controls.ct_pos_y:SetText(tostring(tonumber(unit_cfg.pos_y) or 0))
        end

        refreshSlider(SettingsPage.controls.ct_icon_size, SettingsPage.controls.ct_icon_size_val, tonumber(unit_cfg.icon_size) or 40)
        refreshSlider(SettingsPage.controls.ct_icon_spacing, SettingsPage.controls.ct_icon_spacing_val, tonumber(unit_cfg.icon_spacing) or 5)
        refreshSlider(SettingsPage.controls.ct_max_icons, SettingsPage.controls.ct_max_icons_val, tonumber(unit_cfg.max_icons) or 10)
        refreshSlider(SettingsPage.controls.ct_timer_fs, SettingsPage.controls.ct_timer_fs_val, tonumber(unit_cfg.timer_font_size) or 16)
        refreshSlider(SettingsPage.controls.ct_label_fs, SettingsPage.controls.ct_label_fs_val, tonumber(unit_cfg.label_font_size) or 14)

        do
            local cache_val = 300
            if unit_key == "target" then
                cache_val = tonumber(unit_cfg.cache_timeout_s) or 300
            end
            refreshSlider(
                SettingsPage.controls.ct_cache_timeout,
                SettingsPage.controls.ct_cache_timeout_val,
                cache_val
            )
            if SettingsPage.controls.ct_cache_timeout ~= nil and SettingsPage.controls.ct_cache_timeout.SetEnable ~= nil then
                SettingsPage.controls.ct_cache_timeout:SetEnable(unit_key == "target")
            end
        end

        local tc = type(unit_cfg.timer_color) == "table" and unit_cfg.timer_color or { 1, 1, 1, 1 }
        refreshSlider(SettingsPage.controls.ct_timer_r, SettingsPage.controls.ct_timer_r_val, ClampInt((tc[1] or 1) * 255, 0, 255, 255))
        refreshSlider(SettingsPage.controls.ct_timer_g, SettingsPage.controls.ct_timer_g_val, ClampInt((tc[2] or 1) * 255, 0, 255, 255))
        refreshSlider(SettingsPage.controls.ct_timer_b, SettingsPage.controls.ct_timer_b_val, ClampInt((tc[3] or 1) * 255, 0, 255, 255))

        local lc = type(unit_cfg.label_color) == "table" and unit_cfg.label_color or { 1, 1, 1, 1 }
        refreshSlider(SettingsPage.controls.ct_label_r, SettingsPage.controls.ct_label_r_val, ClampInt((lc[1] or 1) * 255, 0, 255, 255))
        refreshSlider(SettingsPage.controls.ct_label_g, SettingsPage.controls.ct_label_g_val, ClampInt((lc[2] or 1) * 255, 0, 255, 255))
        refreshSlider(SettingsPage.controls.ct_label_b, SettingsPage.controls.ct_label_b_val, ClampInt((lc[3] or 1) * 255, 0, 255, 255))

        RefreshCooldownBuffRows(unit_cfg)
    end

    RefreshCooldownScanRows()
end

local function ApplyControlsToSettings()
    local s = SettingsPage.settings
    if s == nil then
        return
    end
    s.enabled = (SettingsPage.controls.enabled ~= nil and SettingsPage.controls.enabled:GetChecked()) and true or false

    if SettingsPage.controls.alignment_grid_enabled ~= nil then
        s.alignment_grid_enabled = SettingsPage.controls.alignment_grid_enabled:GetChecked() and true or false
    end

    EnsureDailyAgeTables(s)
    if SettingsPage.controls.dailyage_enabled ~= nil then
        s.dailyage.enabled = SettingsPage.controls.dailyage_enabled:GetChecked() and true or false
    end

    EnsureStyleFrames(s)
    if type(s.style) ~= "table" then
        s.style = {}
    end
    local _, editStyle = GetStyleTables(s)
    if SettingsPage.style_target == "all" then
        editStyle = s.style
    end
    if type(editStyle) ~= "table" then
        editStyle = s.style
    end
    if type(editStyle) ~= "table" then
        editStyle = {}
        s.style = editStyle
    end

    if type(s.nameplates) ~= "table" then
        s.nameplates = {}
    end

    if SettingsPage.controls.plates_enabled ~= nil then
        s.nameplates.enabled = SettingsPage.controls.plates_enabled:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_guild_only ~= nil then
        s.nameplates.guild_only = SettingsPage.controls.plates_guild_only:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_show_target ~= nil then
        s.nameplates.show_target = SettingsPage.controls.plates_show_target:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_show_player ~= nil then
        s.nameplates.show_player = SettingsPage.controls.plates_show_player:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_show_raid_party ~= nil then
        s.nameplates.show_raid_party = SettingsPage.controls.plates_show_raid_party:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_show_watchtarget ~= nil then
        s.nameplates.show_watchtarget = SettingsPage.controls.plates_show_watchtarget:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_show_mount ~= nil then
        s.nameplates.show_mount = SettingsPage.controls.plates_show_mount:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_show_guild ~= nil then
        s.nameplates.show_guild = SettingsPage.controls.plates_show_guild:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_click_shift ~= nil then
        s.nameplates.click_through_shift = true
    end
    if SettingsPage.controls.plates_click_ctrl ~= nil then
        s.nameplates.click_through_ctrl = true
    end
    if SettingsPage.controls.plates_alpha ~= nil then
        s.nameplates.alpha_pct = GetSliderValue(SettingsPage.controls.plates_alpha)
    end
    if SettingsPage.controls.plates_width ~= nil then
        s.nameplates.width = GetSliderValue(SettingsPage.controls.plates_width)
    end
    if SettingsPage.controls.plates_hp_h ~= nil then
        s.nameplates.hp_height = GetSliderValue(SettingsPage.controls.plates_hp_h)
    end
    if SettingsPage.controls.plates_mp_h ~= nil then
        s.nameplates.mp_height = GetSliderValue(SettingsPage.controls.plates_mp_h)
    end
    if SettingsPage.controls.plates_x_offset ~= nil then
        s.nameplates.x_offset = GetSliderValue(SettingsPage.controls.plates_x_offset)
    end
    if SettingsPage.controls.plates_max_dist ~= nil then
        s.nameplates.max_distance = GetSliderValue(SettingsPage.controls.plates_max_dist)
    end
    if SettingsPage.controls.plates_y_offset ~= nil then
        s.nameplates.y_offset = GetSliderValue(SettingsPage.controls.plates_y_offset)
    end
    if SettingsPage.controls.plates_anchor_tag ~= nil then
        s.nameplates.anchor_to_nametag = SettingsPage.controls.plates_anchor_tag:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_bg_enabled ~= nil then
        s.nameplates.bg_enabled = SettingsPage.controls.plates_bg_enabled:GetChecked() and true or false
    end
    if SettingsPage.controls.plates_bg_alpha ~= nil then
        s.nameplates.bg_alpha_pct = GetSliderValue(SettingsPage.controls.plates_bg_alpha)
    end
    if SettingsPage.controls.plates_name_fs ~= nil then
        s.nameplates.name_font_size = GetSliderValue(SettingsPage.controls.plates_name_fs)
    end
    if SettingsPage.controls.plates_guild_fs ~= nil then
        s.nameplates.guild_font_size = GetSliderValue(SettingsPage.controls.plates_guild_fs)
    end

    if SettingsPage.controls.large_hpmp ~= nil then
        s.style.large_hpmp = SettingsPage.controls.large_hpmp:GetChecked() and true or false
    end

    if SettingsPage.controls.show_distance ~= nil then
        s.show_distance = SettingsPage.controls.show_distance:GetChecked() and true or false
    end

    if SettingsPage.controls.frame_alpha ~= nil then
        editStyle.frame_alpha = GetSliderValue(SettingsPage.controls.frame_alpha) / 100
    end

    if SettingsPage.controls.frame_width ~= nil then
        editStyle.frame_width = GetSliderValue(SettingsPage.controls.frame_width)
    end

    if SettingsPage.controls.frame_height ~= nil then
        s.frame_height = GetSliderValue(SettingsPage.controls.frame_height)
    end

    if SettingsPage.controls.frame_scale ~= nil then
        editStyle.frame_scale = GetSliderValue(SettingsPage.controls.frame_scale) / 100
    end

    if SettingsPage.controls.bar_height ~= nil then
        editStyle.bar_height = GetSliderValue(SettingsPage.controls.bar_height)
    end
    if SettingsPage.controls.hp_bar_height ~= nil then
        editStyle.hp_bar_height = GetSliderValue(SettingsPage.controls.hp_bar_height)
    end
    if SettingsPage.controls.mp_bar_height ~= nil then
        editStyle.mp_bar_height = GetSliderValue(SettingsPage.controls.mp_bar_height)
    end
    if SettingsPage.controls.bar_gap ~= nil then
        editStyle.bar_gap = GetSliderValue(SettingsPage.controls.bar_gap)
    end

    if SettingsPage.controls.name_visible ~= nil then
        editStyle.name_visible = SettingsPage.controls.name_visible:GetChecked() and true or false
    end
    if SettingsPage.controls.name_offset_x ~= nil then
        editStyle.name_offset_x = GetSliderValue(SettingsPage.controls.name_offset_x)
    end
    if SettingsPage.controls.name_offset_y ~= nil then
        editStyle.name_offset_y = GetSliderValue(SettingsPage.controls.name_offset_y)
    end

    if SettingsPage.controls.level_visible ~= nil then
        editStyle.level_visible = SettingsPage.controls.level_visible:GetChecked() and true or false
    end
    if SettingsPage.controls.level_font_size ~= nil then
        editStyle.level_font_size = GetSliderValue(SettingsPage.controls.level_font_size)
    end
    if SettingsPage.controls.level_offset_x ~= nil then
        editStyle.level_offset_x = GetSliderValue(SettingsPage.controls.level_offset_x)
    end
    if SettingsPage.controls.level_offset_y ~= nil then
        editStyle.level_offset_y = GetSliderValue(SettingsPage.controls.level_offset_y)
    end

    if SettingsPage.controls.name_font_size ~= nil then
        editStyle.name_font_size = GetSliderValue(SettingsPage.controls.name_font_size)
    end
    if SettingsPage.controls.hp_font_size ~= nil then
        editStyle.hp_font_size = GetSliderValue(SettingsPage.controls.hp_font_size)
    end
    if SettingsPage.controls.mp_font_size ~= nil then
        editStyle.mp_font_size = GetSliderValue(SettingsPage.controls.mp_font_size)
    end
    if SettingsPage.controls.overlay_font_size ~= nil then
        editStyle.overlay_font_size = GetSliderValue(SettingsPage.controls.overlay_font_size)
    end

    if SettingsPage.controls.gs_font_size ~= nil then
        editStyle.gs_font_size = GetSliderValue(SettingsPage.controls.gs_font_size)
    end
    if SettingsPage.controls.class_font_size ~= nil then
        editStyle.class_font_size = GetSliderValue(SettingsPage.controls.class_font_size)
    end
    if SettingsPage.controls.role_font_size ~= nil then
        editStyle.role_font_size = GetSliderValue(SettingsPage.controls.role_font_size)
    end

    if SettingsPage.controls.target_guild_font_size ~= nil then
        editStyle.target_guild_font_size = GetSliderValue(SettingsPage.controls.target_guild_font_size)
    end

    if SettingsPage.controls.name_shadow ~= nil then
        editStyle.name_shadow = SettingsPage.controls.name_shadow:GetChecked() and true or false
    end
    if SettingsPage.controls.value_shadow ~= nil then
        editStyle.value_shadow = SettingsPage.controls.value_shadow:GetChecked() and true or false
    end
    if SettingsPage.controls.overlay_shadow ~= nil then
        editStyle.overlay_shadow = SettingsPage.controls.overlay_shadow:GetChecked() and true or false
    end

    if SettingsPage.controls.hp_value_offset_x ~= nil then
        editStyle.hp_value_offset_x = GetSliderValue(SettingsPage.controls.hp_value_offset_x)
    end
    if SettingsPage.controls.hp_value_offset_y ~= nil then
        editStyle.hp_value_offset_y = GetSliderValue(SettingsPage.controls.hp_value_offset_y)
    end
    if SettingsPage.controls.mp_value_offset_x ~= nil then
        editStyle.mp_value_offset_x = GetSliderValue(SettingsPage.controls.mp_value_offset_x)
    end
    if SettingsPage.controls.mp_value_offset_y ~= nil then
        editStyle.mp_value_offset_y = GetSliderValue(SettingsPage.controls.mp_value_offset_y)
    end

    if SettingsPage.controls.target_guild_offset_x ~= nil then
        editStyle.target_guild_offset_x = GetSliderValue(SettingsPage.controls.target_guild_offset_x)
    end
    if SettingsPage.controls.target_guild_offset_y ~= nil then
        editStyle.target_guild_offset_y = GetSliderValue(SettingsPage.controls.target_guild_offset_y)
    end

    if SettingsPage.controls.bar_colors_enabled ~= nil then
        editStyle.bar_colors_enabled = SettingsPage.controls.bar_colors_enabled:GetChecked() and true or false
    end

    local function colorTable(r, g, b, a)
        return { r, g, b, a or 255 }
    end
    local function sliderOr(slider, fallback)
        if slider ~= nil then
            return GetSliderValue(slider)
        end
        return fallback
    end
    if SettingsPage.controls.hp_r ~= nil and SettingsPage.controls.hp_g ~= nil and SettingsPage.controls.hp_b ~= nil then
        local fill = colorTable(
            GetSliderValue(SettingsPage.controls.hp_r),
            GetSliderValue(SettingsPage.controls.hp_g),
            GetSliderValue(SettingsPage.controls.hp_b),
            sliderOr(SettingsPage.controls.hp_a, 255)
        )
        editStyle.hp_fill_color = fill
        editStyle.hp_bar_color = fill
    end
    if SettingsPage.controls.hp_after_r ~= nil and SettingsPage.controls.hp_after_g ~= nil and SettingsPage.controls.hp_after_b ~= nil then
        editStyle.hp_after_color = colorTable(
            GetSliderValue(SettingsPage.controls.hp_after_r),
            GetSliderValue(SettingsPage.controls.hp_after_g),
            GetSliderValue(SettingsPage.controls.hp_after_b),
            sliderOr(SettingsPage.controls.hp_after_a, 255)
        )
    end

    if SettingsPage.controls.mp_r ~= nil and SettingsPage.controls.mp_g ~= nil and SettingsPage.controls.mp_b ~= nil then
        local fill = colorTable(
            GetSliderValue(SettingsPage.controls.mp_r),
            GetSliderValue(SettingsPage.controls.mp_g),
            GetSliderValue(SettingsPage.controls.mp_b),
            sliderOr(SettingsPage.controls.mp_a, 255)
        )
        editStyle.mp_fill_color = fill
        editStyle.mp_bar_color = fill
    end
    if SettingsPage.controls.mp_after_r ~= nil and SettingsPage.controls.mp_after_g ~= nil and SettingsPage.controls.mp_after_b ~= nil then
        editStyle.mp_after_color = colorTable(
            GetSliderValue(SettingsPage.controls.mp_after_r),
            GetSliderValue(SettingsPage.controls.mp_after_g),
            GetSliderValue(SettingsPage.controls.mp_after_b),
            sliderOr(SettingsPage.controls.mp_after_a, 255)
        )
    end

    if SettingsPage.controls.hp_tex_stock ~= nil and SettingsPage.controls.hp_tex_pc ~= nil and SettingsPage.controls.hp_tex_npc ~= nil then
        if SettingsPage.controls.hp_tex_pc:GetChecked() then
            editStyle.hp_texture_mode = "pc"
        elseif SettingsPage.controls.hp_tex_npc:GetChecked() then
            editStyle.hp_texture_mode = "npc"
        else
            editStyle.hp_texture_mode = "stock"
        end
    end

    if type(s.style.buff_windows) ~= "table" then
        s.style.buff_windows = {}
    end

    if type(s.style.aura) ~= "table" then
        s.style.aura = {}
    end
    if type(s.style.buff_windows.player) ~= "table" then
        s.style.buff_windows.player = {}
    end
    if type(s.style.buff_windows.target) ~= "table" then
        s.style.buff_windows.target = {}
    end
    if type(s.style.buff_windows.player.buff) ~= "table" then
        s.style.buff_windows.player.buff = {}
    end
    if type(s.style.buff_windows.player.debuff) ~= "table" then
        s.style.buff_windows.player.debuff = {}
    end
    if type(s.style.buff_windows.target.buff) ~= "table" then
        s.style.buff_windows.target.buff = {}
    end
    if type(s.style.buff_windows.target.debuff) ~= "table" then
        s.style.buff_windows.target.debuff = {}
    end
    if SettingsPage.controls.move_buffs ~= nil then
        s.style.buff_windows.enabled = SettingsPage.controls.move_buffs:GetChecked() and true or false
    end

    if SettingsPage.controls.p_buff_x ~= nil then
        s.style.buff_windows.player.buff.x = GetSliderValue(SettingsPage.controls.p_buff_x)
    end
    if SettingsPage.controls.p_buff_y ~= nil then
        s.style.buff_windows.player.buff.y = GetSliderValue(SettingsPage.controls.p_buff_y)
    end
    if SettingsPage.controls.p_debuff_x ~= nil then
        s.style.buff_windows.player.debuff.x = GetSliderValue(SettingsPage.controls.p_debuff_x)
    end
    if SettingsPage.controls.p_debuff_y ~= nil then
        s.style.buff_windows.player.debuff.y = GetSliderValue(SettingsPage.controls.p_debuff_y)
    end

    if SettingsPage.controls.t_buff_x ~= nil then
        s.style.buff_windows.target.buff.x = GetSliderValue(SettingsPage.controls.t_buff_x)
    end
    if SettingsPage.controls.t_buff_y ~= nil then
        s.style.buff_windows.target.buff.y = GetSliderValue(SettingsPage.controls.t_buff_y)
    end
    if SettingsPage.controls.t_debuff_x ~= nil then
        s.style.buff_windows.target.debuff.x = GetSliderValue(SettingsPage.controls.t_debuff_x)
    end
    if SettingsPage.controls.t_debuff_y ~= nil then
        s.style.buff_windows.target.debuff.y = GetSliderValue(SettingsPage.controls.t_debuff_y)
    end

    if SettingsPage.controls.overlay_alpha ~= nil then
        editStyle.overlay_alpha = GetSliderValue(SettingsPage.controls.overlay_alpha) / 100
    end

    if SettingsPage.controls.aura_enabled ~= nil then
        s.style.aura.enabled = SettingsPage.controls.aura_enabled:GetChecked() and true or false
    end
    if SettingsPage.controls.aura_icon_size ~= nil then
        s.style.aura.icon_size = GetSliderValue(SettingsPage.controls.aura_icon_size)
    end
    if SettingsPage.controls.aura_x_gap ~= nil then
        s.style.aura.icon_x_gap = GetSliderValue(SettingsPage.controls.aura_x_gap)
    end
    if SettingsPage.controls.aura_y_gap ~= nil then
        s.style.aura.icon_y_gap = GetSliderValue(SettingsPage.controls.aura_y_gap)
    end
    if SettingsPage.controls.aura_per_row ~= nil then
        s.style.aura.buffs_per_row = GetSliderValue(SettingsPage.controls.aura_per_row)
    end
    if SettingsPage.controls.aura_sort_vertical ~= nil then
        s.style.aura.sort_vertical = SettingsPage.controls.aura_sort_vertical:GetChecked() and true or false
    end

    if SettingsPage.controls.value_fmt_curmax ~= nil and SettingsPage.controls.value_fmt_percent ~= nil then
        local wantCurMax = SettingsPage.controls.value_fmt_curmax:GetChecked() and true or false
        local wantPercent = SettingsPage.controls.value_fmt_percent:GetChecked() and true or false
        if wantCurMax and wantPercent then
            editStyle.value_format = "curmax_percent"
        elseif wantPercent then
            editStyle.value_format = "percent"
        elseif wantCurMax then
            editStyle.value_format = "curmax"
        else
            editStyle.value_format = "stock"
        end
    end

    if SettingsPage.controls.short_numbers ~= nil then
        editStyle.short_numbers = SettingsPage.controls.short_numbers:GetChecked() and true or false
    end

    EnsureCooldownTrackerTables(s)
    if SettingsPage.controls.ct_enabled ~= nil then
        s.cooldown_tracker.enabled = SettingsPage.controls.ct_enabled:GetChecked() and true or false
    end
    if SettingsPage.controls.ct_update_interval ~= nil then
        s.cooldown_tracker.update_interval_ms = ClampInt(GetSliderValue(SettingsPage.controls.ct_update_interval), 10, 1000, 50)
    end

    local unit_key = tostring(SettingsPage.cooldown_unit_key or "player")
    local unit_cfg = s.cooldown_tracker.units[unit_key]
    if type(unit_cfg) == "table" then
        if SettingsPage.controls.ct_unit_enabled ~= nil then
            unit_cfg.enabled = SettingsPage.controls.ct_unit_enabled:GetChecked() and true or false
        end
        if SettingsPage.controls.ct_lock_position ~= nil then
            unit_cfg.lock_position = SettingsPage.controls.ct_lock_position:GetChecked() and true or false
        end
        if SettingsPage.controls.ct_show_timer ~= nil then
            unit_cfg.show_timer = SettingsPage.controls.ct_show_timer:GetChecked() and true or false
        end
        if SettingsPage.controls.ct_show_label ~= nil then
            unit_cfg.show_label = SettingsPage.controls.ct_show_label:GetChecked() and true or false
        end

        local pos_x = ParseEditNumber(SettingsPage.controls.ct_pos_x)
        local pos_y = ParseEditNumber(SettingsPage.controls.ct_pos_y)
        if pos_x ~= nil then
            unit_cfg.pos_x = math.floor(pos_x + 0.5)
        end
        if pos_y ~= nil then
            unit_cfg.pos_y = math.floor(pos_y + 0.5)
        end

        if SettingsPage.controls.ct_icon_size ~= nil then
            unit_cfg.icon_size = ClampInt(GetSliderValue(SettingsPage.controls.ct_icon_size), 10, 200, 40)
        end
        if SettingsPage.controls.ct_icon_spacing ~= nil then
            unit_cfg.icon_spacing = ClampInt(GetSliderValue(SettingsPage.controls.ct_icon_spacing), 0, 50, 5)
        end
        if SettingsPage.controls.ct_max_icons ~= nil then
            unit_cfg.max_icons = ClampInt(GetSliderValue(SettingsPage.controls.ct_max_icons), 1, 50, 10)
        end
        if SettingsPage.controls.ct_timer_fs ~= nil then
            unit_cfg.timer_font_size = ClampInt(GetSliderValue(SettingsPage.controls.ct_timer_fs), 6, 64, 16)
        end
        if SettingsPage.controls.ct_label_fs ~= nil then
            unit_cfg.label_font_size = ClampInt(GetSliderValue(SettingsPage.controls.ct_label_fs), 6, 64, 14)
        end

        if unit_key == "target" and SettingsPage.controls.ct_cache_timeout ~= nil then
            unit_cfg.cache_timeout_s = ClampInt(GetSliderValue(SettingsPage.controls.ct_cache_timeout), 0, 3600, 300)
        end

        if SettingsPage.controls.ct_timer_r ~= nil and SettingsPage.controls.ct_timer_g ~= nil and SettingsPage.controls.ct_timer_b ~= nil then
            unit_cfg.timer_color = {
                ClampInt(GetSliderValue(SettingsPage.controls.ct_timer_r), 0, 255, 255) / 255,
                ClampInt(GetSliderValue(SettingsPage.controls.ct_timer_g), 0, 255, 255) / 255,
                ClampInt(GetSliderValue(SettingsPage.controls.ct_timer_b), 0, 255, 255) / 255,
                1
            }
        end
        if SettingsPage.controls.ct_label_r ~= nil and SettingsPage.controls.ct_label_g ~= nil and SettingsPage.controls.ct_label_b ~= nil then
            unit_cfg.label_color = {
                ClampInt(GetSliderValue(SettingsPage.controls.ct_label_r), 0, 255, 255) / 255,
                ClampInt(GetSliderValue(SettingsPage.controls.ct_label_g), 0, 255, 255) / 255,
                ClampInt(GetSliderValue(SettingsPage.controls.ct_label_b), 0, 255, 255) / 255,
                1
            }
        end
    end
end

local function EnsureWindow()
    if SettingsPage.window ~= nil then
        return
    end

    SettingsPage.window = api.Interface:CreateWindow("PolarUiSettings", "Polar UI Settings", 640, 760)
    SettingsPage.window:AddAnchor("CENTER", "UIParent", 0, 0)

    local closeHandler = MakeCloseHandler()
    SettingsPage.window:SetHandler("OnCloseByEsc", closeHandler)
    function SettingsPage.window:OnClose()
        closeHandler()
    end

    SettingsPage.scroll_frame = nil
    SettingsPage.content = SettingsPage.window

    if SettingsPage.window.CreateChildWidget ~= nil then
        local ok, res = pcall(function()
            return SettingsPage.window:CreateChildWidget("emptywidget", "polarUiScrollFrame", 0, true)
        end)
        if ok then
            SettingsPage.scroll_frame = res
        end
    end

    if SettingsPage.scroll_frame ~= nil then
        pcall(function()
            SettingsPage.scroll_frame:Show(true)
            SettingsPage.scroll_frame:AddAnchor("TOPLEFT", SettingsPage.window, 0, 95)
            SettingsPage.scroll_frame:AddAnchor("BOTTOMRIGHT", SettingsPage.window, -8, -50)
            SettingsPage.scroll_frame:SetExtent(620, 605)
        end)

        if SettingsPage.scroll_frame.CreateChildWidget ~= nil then
            local ok, res = pcall(function()
                return SettingsPage.scroll_frame:CreateChildWidget("emptywidget", "content", 0, true)
            end)
            if ok then
                SettingsPage.content = res
            end
        end

        if SettingsPage.content ~= nil then
            pcall(function()
                SettingsPage.content:Show(true)
            end)
            pcall(function()
                if SettingsPage.content.EnableScroll ~= nil then
                    SettingsPage.content:EnableScroll(true)
                end
            end)
        end
    end

    local scroll = nil
    if SettingsPage.scroll_frame ~= nil and W_CTRL ~= nil and W_CTRL.CreateScroll ~= nil then
        local ok, res = pcall(function()
            return W_CTRL.CreateScroll("polarUiScroll", SettingsPage.scroll_frame)
        end)
        if ok then
            scroll = res
        end
    end

    if scroll ~= nil and SettingsPage.scroll_frame ~= nil then
        scroll:AddAnchor("TOPRIGHT", SettingsPage.scroll_frame, 0, 0)
        scroll:AddAnchor("BOTTOMRIGHT", SettingsPage.scroll_frame, 0, 0)
        if scroll.AlwaysScrollShow ~= nil then
            scroll:AlwaysScrollShow()
        end
    end

    pcall(function()
        if SettingsPage.scroll_frame ~= nil and SettingsPage.content ~= nil and SettingsPage.content.AddAnchor ~= nil then
            SettingsPage.content:AddAnchor("TOPLEFT", SettingsPage.scroll_frame, 0, 0)
            SettingsPage.content:AddAnchor("BOTTOM", SettingsPage.scroll_frame, 0, 0)
            if scroll ~= nil then
                SettingsPage.content:AddAnchor("RIGHT", scroll, "LEFT", -5, 0)
            else
                SettingsPage.content:AddAnchor("RIGHT", SettingsPage.scroll_frame, 0, 0)
            end
        end
    end)

    if scroll ~= nil and SettingsPage.scroll_frame ~= nil and scroll.vs ~= nil and scroll.vs.SetHandler ~= nil then
        scroll.vs:SetHandler("OnSliderChanged", function(a, b)
            pcall(function()
                local value = b
                if type(value) ~= "number" then
                    value = a
                end
                if type(value) ~= "number" then
                    return
                end
                local page = SettingsPage.active_page ~= nil and SettingsPage.pages[SettingsPage.active_page] or nil
                if page ~= nil and page.ChangeChildAnchorByScrollValue ~= nil then
                    page:ChangeChildAnchorByScrollValue("vert", value)
                end
            end)
        end)
    end

    if SettingsPage.scroll_frame ~= nil then
        SettingsPage.scroll_frame.content = SettingsPage.content
        SettingsPage.scroll_frame.scroll = scroll
        function SettingsPage.scroll_frame:ResetScroll(totalHeight)
            if self.scroll == nil or self.scroll.vs == nil or self.scroll.vs.SetMinMaxValues == nil then
                return
            end
            local height = 0
            pcall(function()
                if self.GetHeight ~= nil then
                    height = self:GetHeight()
                end
            end)
            local total = tonumber(totalHeight) or 0
            local maxScroll = total
            if height > 0 then
                maxScroll = total - height
            end
            if maxScroll < 0 then
                maxScroll = 0
            end

            self.scroll.vs:SetMinMaxValues(0, maxScroll)
            if maxScroll <= 0 then
                if self.scroll.SetEnable ~= nil then
                    self.scroll:SetEnable(false)
                end
            else
                if self.scroll.SetEnable ~= nil then
                    self.scroll:SetEnable(true)
                end
            end
        end
    end

    local navY = 35
    SettingsPage.nav.general = CreateButton("polarUiNavGeneral", SettingsPage.window, "General", 15, navY)
    SettingsPage.nav.text = CreateButton("polarUiNavText", SettingsPage.window, "Text", 105, navY)
    SettingsPage.nav.bars = CreateButton("polarUiNavBars", SettingsPage.window, "Bars", 195, navY)
    SettingsPage.nav.auras = CreateButton("polarUiNavAuras", SettingsPage.window, "Auras", 285, navY)
    SettingsPage.nav.plates = CreateButton("polarUiNavPlates", SettingsPage.window, "Plates", 375, navY)
    SettingsPage.nav.cooldown = CreateButton("polarUiNavCooldown", SettingsPage.window, "Cooldowns", 465, navY)
    SettingsPage.nav.dailyage = CreateButton("polarUiNavDailyAge", SettingsPage.window, "Dailies", 15, navY + 30)

    if SettingsPage.nav.general ~= nil and SettingsPage.nav.general.SetHandler ~= nil then
        SettingsPage.nav.general:SetHandler("OnClick", function()
            SetActivePage("general")
        end)
    end
    if SettingsPage.nav.text ~= nil and SettingsPage.nav.text.SetHandler ~= nil then
        SettingsPage.nav.text:SetHandler("OnClick", function()
            SetActivePage("text")
        end)
    end
    if SettingsPage.nav.bars ~= nil and SettingsPage.nav.bars.SetHandler ~= nil then
        SettingsPage.nav.bars:SetHandler("OnClick", function()
            SetActivePage("bars")
        end)
    end
    if SettingsPage.nav.auras ~= nil and SettingsPage.nav.auras.SetHandler ~= nil then
        SettingsPage.nav.auras:SetHandler("OnClick", function()
            SetActivePage("auras")
        end)
    end

    if SettingsPage.nav.plates ~= nil and SettingsPage.nav.plates.SetHandler ~= nil then
        SettingsPage.nav.plates:SetHandler("OnClick", function()
            SetActivePage("plates")
        end)
    end

    if SettingsPage.nav.cooldown ~= nil and SettingsPage.nav.cooldown.SetHandler ~= nil then
        SettingsPage.nav.cooldown:SetHandler("OnClick", function()
            SetActivePage("cooldown")
        end)
    end

    if SettingsPage.nav.dailyage ~= nil and SettingsPage.nav.dailyage.SetHandler ~= nil then
        SettingsPage.nav.dailyage:SetHandler("OnClick", function()
            SetActivePage("dailyage")
        end)
    end

    SettingsPage.pages = {}
    SettingsPage.page_heights = {}

    SettingsPage.pages.general = CreatePage("polarUiPageGeneral", SettingsPage.content)
    SettingsPage.pages.text = CreatePage("polarUiPageText", SettingsPage.content)
    SettingsPage.pages.bars = CreatePage("polarUiPageBars", SettingsPage.content)
    SettingsPage.pages.auras = CreatePage("polarUiPageAuras", SettingsPage.content)
    SettingsPage.pages.plates = CreatePage("polarUiPagePlates", SettingsPage.content)
    SettingsPage.pages.cooldown = CreatePage("polarUiPageCooldown", SettingsPage.content)
    SettingsPage.pages.dailyage = CreatePage("polarUiPageDailyAge", SettingsPage.content)

    local gap = 24

    do
        local page = SettingsPage.pages.general
        local y = 35
        CreateLabel("polarUiGeneralPageTitle", page, "General", 15, y, 18)
        y = y + 30

        SettingsPage.controls.enabled = CreateCheckbox("polarUiEnabled", page, "Enable Polar UI overlays", 15, y)
        y = y + gap

        SettingsPage.controls.large_hpmp = CreateCheckbox("polarUiLargeHpMp", page, "Large HP/MP text", 15, y)
        y = y + gap

        SettingsPage.controls.show_distance = CreateCheckbox("polarUiShowDistance", page, "Show target distance", 15, y)
        y = y + gap

        SettingsPage.controls.alignment_grid_enabled = CreateCheckbox(
            "polarUiAlignmentGridEnabled",
            page,
            "Show alignment grid (30px)",
            15,
            y
        )
        y = y + gap

        SettingsPage.page_heights.general = y + 40
    end

    do
        local quests = nil
        pcall(function()
            quests = require("polar-ui/dailyage_quests")
        end)
        if type(quests) ~= "table" then
            pcall(function()
                quests = require("polar-ui.dailyage_quests")
            end)
        end

        local function safeGetQuestTitle(id)
            local id_num = tonumber(id)
            if id_num == nil then
                return tostring(id)
            end
            local title = nil
            pcall(function()
                if api ~= nil and api.Quest ~= nil and api.Quest.GetQuestContextMainTitle ~= nil then
                    title = api.Quest:GetQuestContextMainTitle(id_num)
                end
            end)
            if type(title) == "string" and title ~= "" then
                return title
            end
            return tostring(id_num)
        end

        local function isQuestCompleted(id)
            local id_num = tonumber(id)
            if id_num == nil then
                return false
            end
            if api == nil or api.Quest == nil or api.Quest.IsCompleted == nil then
                return false
            end
            local ok, done = pcall(function()
                return api.Quest:IsCompleted(id_num)
            end)
            if ok then
                return done and true or false
            end
            return false
        end

        local function buildQuestEntries()
            local out = {}
            if type(quests) == "table" then
                for _, ids in ipairs(quests) do
                    if type(ids) == "table" and ids[1] ~= nil then
                        local id_num = tonumber(ids[1])
                        if id_num ~= nil then
                            table.insert(out, { id = id_num, title = safeGetQuestTitle(id_num) })
                        end
                    end
                end
            end
            table.insert(out, { id = 9000009, title = safeGetQuestTitle(9000009) })
            table.insert(out, { id = 9000011, title = safeGetQuestTitle(9000011) })
            return out
        end

        local function getDailyAgeSearchText()
            return tostring(SettingsPage.dailyage_search_text or "")
        end

        local function setDailyAgeSearchText(v)
            SettingsPage.dailyage_search_text = tostring(v or "")
        end

        local renderDailyAgeManagerRows = nil

        local function refreshDailyAgeList()
            if SettingsPage.settings == nil then
                return
            end
            EnsureDailyAgeTables(SettingsPage.settings)
            local hidden = SettingsPage.settings.dailyage.hidden
            if type(hidden) ~= "table" then
                hidden = {}
                SettingsPage.settings.dailyage.hidden = hidden
            end

            for k, v in pairs(hidden) do
                if type(k) == "string" then
                    local nk = tonumber(k)
                    if nk ~= nil then
                        hidden[nk] = v
                        hidden[k] = nil
                    end
                end
            end

            if SettingsPage.dailyage_entries == nil then
                SettingsPage.dailyage_entries = buildQuestEntries()
            end

            local search = string.lower(getDailyAgeSearchText())
            local haveSearch = search ~= "" and #search > 2

            local items = {}
            for _, e in ipairs(SettingsPage.dailyage_entries) do
                local id_key = tostring(e.id)
                local isHidden = (hidden[e.id] or hidden[id_key]) and true or false
                local completed = isQuestCompleted(e.id)

                local show = true
                if haveSearch then
                    local t = string.lower(tostring(e.title or ""))
                    if string.find(t, search, 1, true) == nil then
                        show = false
                    end
                end

                if show then
                    items[#items + 1] = {
                        id = e.id,
                        title = tostring(e.title or ""),
                        hidden = isHidden,
                        completed = completed,
                    }
                end
            end

            if type(renderDailyAgeManagerRows) == "function" then
                pcall(function()
                    renderDailyAgeManagerRows(items)
                end)
            end

            if SettingsPage.controls.dailyage_status ~= nil and SettingsPage.controls.dailyage_status.SetText ~= nil then
                local totalCount = 0
                if type(SettingsPage.dailyage_entries) == "table" then
                    totalCount = #SettingsPage.dailyage_entries
                end
                local hiddenCount = 0
                for _, v in pairs(hidden) do
                    if v then
                        hiddenCount = hiddenCount + 1
                    end
                end
                local shownCount = totalCount - hiddenCount
                if shownCount < 0 then
                    shownCount = 0
                end
                SettingsPage.controls.dailyage_status:SetText(
                    string.format("Shown: %d / %d  (Hidden: %d)", shownCount, totalCount, hiddenCount)
                )
            end

            if SettingsPage.controls.dailyage_mgr_status ~= nil and SettingsPage.controls.dailyage_mgr_status.SetText ~= nil then
                local totalCount = 0
                if type(SettingsPage.dailyage_entries) == "table" then
                    totalCount = #SettingsPage.dailyage_entries
                end
                local hiddenCount = 0
                for _, v in pairs(hidden) do
                    if v then
                        hiddenCount = hiddenCount + 1
                    end
                end
                local shownCount = totalCount - hiddenCount
                if shownCount < 0 then
                    shownCount = 0
                end
                SettingsPage.controls.dailyage_mgr_status:SetText(
                    string.format("Shown: %d / %d  (Hidden: %d)", shownCount, totalCount, hiddenCount)
                )
            end
        end

        local function setDailyAgeShown(id, shown)
            if SettingsPage.settings == nil then
                return
            end
            EnsureDailyAgeTables(SettingsPage.settings)
            local key = tonumber(id)
            if key == nil then
                return
            end
            local hidden = SettingsPage.settings.dailyage.hidden
            if type(hidden) ~= "table" then
                hidden = {}
                SettingsPage.settings.dailyage.hidden = hidden
            end

            if shown then
                hidden[key] = nil
            else
                hidden[key] = true
            end
            refreshDailyAgeList()
            if type(SettingsPage.on_save) == "function" then
                pcall(function()
                    SettingsPage.on_save()
                end)
            end
            if type(SettingsPage.on_apply) == "function" then
                pcall(function()
                    SettingsPage.on_apply()
                end)
            end
        end

        local function EnsureDailyAgeManagerWindow()
            if SettingsPage.controls.dailyage_mgr_window ~= nil then
                return SettingsPage.controls.dailyage_mgr_window
            end

            if api == nil or api.Interface == nil or api.Interface.CreateWindow == nil then
                return nil
            end

            local ok, wnd = pcall(function()
                return api.Interface:CreateWindow("polarUiDailyAgeManagerWindow", "Dailies", 560, 720)
            end)
            if not ok then
                return nil
            end

            SettingsPage.controls.dailyage_mgr_window = wnd

            local function closeHandler()
                if wnd ~= nil and wnd.Show ~= nil then
                    wnd:Show(false)
                end
            end

            pcall(function()
                if wnd.AddAnchor ~= nil then
                    wnd:AddAnchor("CENTER", "UIParent", 0, 0)
                end
                if wnd.Show ~= nil then
                    wnd:Show(false)
                end
                if wnd.SetHandler ~= nil then
                    wnd:SetHandler("OnCloseByEsc", closeHandler)
                end
                function wnd:OnClose()
                    closeHandler()
                end
            end)

            local y = 18
            local showAllBtn = CreateButton("polarUiDailyAgeMgrShowAll", wnd, "Show all", 15, y)
            if showAllBtn ~= nil and showAllBtn.SetHandler ~= nil then
                showAllBtn:SetHandler("OnClick", function()
                    if SettingsPage.settings == nil then
                        return
                    end
                    EnsureDailyAgeTables(SettingsPage.settings)
                    SettingsPage.settings.dailyage.hidden = {}
                    refreshDailyAgeList()
                    if type(SettingsPage.on_save) == "function" then
                        pcall(function()
                            SettingsPage.on_save()
                        end)
                    end
                    if type(SettingsPage.on_apply) == "function" then
                        pcall(function()
                            SettingsPage.on_apply()
                        end)
                    end
                end)
            end

            SettingsPage.controls.dailyage_mgr_status = api.Interface:CreateWidget("label", "polarUiDailyAgeMgrStatus", wnd)
            pcall(function()
                SettingsPage.controls.dailyage_mgr_status:AddAnchor("TOPLEFT", wnd, 130, y + 6)
                SettingsPage.controls.dailyage_mgr_status:SetExtent(400, 18)
                SettingsPage.controls.dailyage_mgr_status:SetText("")
                if SettingsPage.controls.dailyage_mgr_status.style ~= nil then
                    SettingsPage.controls.dailyage_mgr_status.style:SetFontSize(13)
                    SettingsPage.controls.dailyage_mgr_status.style:SetAlign(ALIGN.LEFT)
                end
            end)

            y = y + 38

            local searchEdit = CreateEdit("polarUiDailyAgeMgrSearch", wnd, "", 15, y, 250, 24)
            SettingsPage.controls.dailyage_mgr_search = searchEdit
            if searchEdit ~= nil and searchEdit.SetHandler ~= nil then
                searchEdit:SetHandler("OnTextChanged", function()
                    local txt = GetEditText(searchEdit)
                    setDailyAgeSearchText(txt)
                    if #txt > 2 or #txt == 0 then
                        refreshDailyAgeList()
                    end
                end)
            end
            CreateLabel("polarUiDailyAgeMgrSearchLabel", wnd, "Filter", 275, y + 2, 13)
            y = y + 34

            local scrollFrame = nil
            if wnd.CreateChildWidget ~= nil then
                local ok2, res = pcall(function()
                    return wnd:CreateChildWidget("emptywidget", "polarUiDailyAgeMgrScrollFrame", 0, true)
                end)
                if ok2 then
                    scrollFrame = res
                end
            end
            SettingsPage.controls.dailyage_mgr_scroll_frame = scrollFrame

            local content = nil
            if scrollFrame ~= nil then
                pcall(function()
                    scrollFrame:Show(true)
                    scrollFrame:AddAnchor("TOPLEFT", wnd, 15, y)
                    scrollFrame:AddAnchor("BOTTOMRIGHT", wnd, -15, -15)
                end)
                if scrollFrame.CreateChildWidget ~= nil then
                    local ok3, res2 = pcall(function()
                        return scrollFrame:CreateChildWidget("emptywidget", "content", 0, true)
                    end)
                    if ok3 then
                        content = res2
                    end
                end
            end
            SettingsPage.controls.dailyage_mgr_content = content

            local scroll = nil
            if scrollFrame ~= nil and W_CTRL ~= nil and W_CTRL.CreateScroll ~= nil then
                local ok4, res3 = pcall(function()
                    return W_CTRL.CreateScroll("polarUiDailyAgeMgrScroll", scrollFrame)
                end)
                if ok4 then
                    scroll = res3
                end
            end
            SettingsPage.controls.dailyage_mgr_scroll = scroll

            if scroll ~= nil and scrollFrame ~= nil then
                pcall(function()
                    scroll:AddAnchor("TOPRIGHT", scrollFrame, 0, 0)
                    scroll:AddAnchor("BOTTOMRIGHT", scrollFrame, 0, 0)
                    if scroll.AlwaysScrollShow ~= nil then
                        scroll:AlwaysScrollShow()
                    end
                end)
            end

            if scrollFrame ~= nil and content ~= nil then
                pcall(function()
                    content:Show(true)
                    if content.EnableScroll ~= nil then
                        content:EnableScroll(true)
                    end
                    if content.EnablePick ~= nil then
                        content:EnablePick(false)
                    end
                    if content.Clickable ~= nil then
                        content:Clickable(false)
                    end
                    if content.eventWindow ~= nil and content.eventWindow.EnablePick ~= nil then
                        content.eventWindow:EnablePick(false)
                    end
                end)
                pcall(function()
                    if content.AddAnchor ~= nil then
                        content:AddAnchor("TOPLEFT", scrollFrame, 0, 0)
                        content:AddAnchor("BOTTOM", scrollFrame, 0, 0)
                        if scroll ~= nil then
                            content:AddAnchor("RIGHT", scroll, "LEFT", -5, 0)
                        else
                            content:AddAnchor("RIGHT", scrollFrame, 0, 0)
                        end
                    end
                end)
            end

            if scroll ~= nil and scrollFrame ~= nil and scroll.vs ~= nil and scroll.vs.SetHandler ~= nil then
                scroll.vs:SetHandler("OnSliderChanged", function(a, b)
                    pcall(function()
                        local value = b
                        if type(value) ~= "number" then
                            value = a
                        end
                        if type(value) ~= "number" then
                            return
                        end
                        if content ~= nil and content.ChangeChildAnchorByScrollValue ~= nil then
                            content:ChangeChildAnchorByScrollValue("vert", value)
                        end
                    end)
                end)
            end

            if scrollFrame ~= nil then
                pcall(function()
                    if scrollFrame.EnablePick ~= nil then
                        scrollFrame:EnablePick(false)
                    end
                    if scrollFrame.Clickable ~= nil then
                        scrollFrame:Clickable(false)
                    end
                    if scrollFrame.eventWindow ~= nil and scrollFrame.eventWindow.EnablePick ~= nil then
                        scrollFrame.eventWindow:EnablePick(false)
                    end
                end)
                scrollFrame.content = content
                scrollFrame.scroll = scroll
                function scrollFrame:ResetScroll(totalHeight)
                    if self.scroll == nil or self.scroll.vs == nil or self.scroll.vs.SetMinMaxValues == nil then
                        return
                    end
                    local height = 0
                    pcall(function()
                        if self.GetHeight ~= nil then
                            height = self:GetHeight()
                        end
                    end)
                    local total = tonumber(totalHeight) or 0
                    local maxScroll = total
                    if height > 0 then
                        maxScroll = total - height
                    end
                    if maxScroll < 0 then
                        maxScroll = 0
                    end
                    self.scroll.vs:SetMinMaxValues(0, maxScroll)
                    if self.scroll.SetEnable ~= nil then
                        self.scroll:SetEnable(maxScroll > 0)
                    end
                end
            end

            return wnd
        end

        renderDailyAgeManagerRows = function(items)
            local wnd = SettingsPage.controls.dailyage_mgr_window
            local content = SettingsPage.controls.dailyage_mgr_content
            if wnd == nil or content == nil then
                return
            end

            if type(SettingsPage.controls.dailyage_mgr_rows) ~= "table" then
                SettingsPage.controls.dailyage_mgr_rows = {}
            end
            local rows = SettingsPage.controls.dailyage_mgr_rows

            local rowH = 24
            local y = 0

            local function ensureRow(i)
                if rows[i] ~= nil then
                    return rows[i]
                end
                local row = {}

                local cb = api.Interface:CreateWidget("checkbutton", "polarUiDailyAgeMgrRowCb" .. tostring(i), content)
                cb:SetExtent(18, 17)
                ApplyCheckButtonSkin(cb)
                pcall(function()
                    if cb.Clickable ~= nil then
                        cb:Clickable(true)
                    end
                    if cb.EnablePick ~= nil then
                        cb:EnablePick(true)
                    end
                    if cb.eventWindow ~= nil and cb.eventWindow.EnablePick ~= nil then
                        cb.eventWindow:EnablePick(true)
                    end
                    if cb.SetButtonStyle ~= nil then
                        cb:SetButtonStyle("default")
                    end
                end)

                local label = api.Interface:CreateWidget("label", "polarUiDailyAgeMgrRowLbl" .. tostring(i), content)
                label:SetExtent(480, 18)
                pcall(function()
                    if label.style ~= nil then
                        label.style:SetFontSize(13)
                        label.style:SetAlign(ALIGN.LEFT)
                        label.style:SetColor(1, 1, 1, 1)
                    end
                    if label.Clickable ~= nil then
                        label:Clickable(true)
                    end
                    if label.EnablePick ~= nil then
                        label:EnablePick(true)
                    end
                    if label.eventWindow ~= nil and label.eventWindow.EnablePick ~= nil then
                        label.eventWindow:EnablePick(true)
                    end
                end)

                local function applyState()
                    if row.__polar_populating then
                        return
                    end
                    if row.quest_id ~= nil and cb.GetChecked ~= nil then
                        setDailyAgeShown(row.quest_id, cb:GetChecked() and true or false)
                    end
                end

                if cb.SetHandler ~= nil then
                    cb:SetHandler("OnClick", function()
                        if cb.SetChecked ~= nil and cb.GetChecked ~= nil then
                            row.__polar_populating = true
                            cb:SetChecked(not cb:GetChecked())
                            row.__polar_populating = nil
                        end
                        applyState()
                    end)
                end

                if label.SetHandler ~= nil then
                    label:SetHandler("OnClick", function()
                        if cb.SetChecked ~= nil and cb.GetChecked ~= nil then
                            row.__polar_populating = true
                            cb:SetChecked(not cb:GetChecked())
                            row.__polar_populating = nil
                        end
                        applyState()
                    end)
                end

                row.checkbox = cb
                row.label = label
                rows[i] = row
                return row
            end

            local count = 0
            if type(items) == "table" then
                count = #items
            end

            for i = 1, count do
                local item = items[i]
                local row = ensureRow(i)
                row.quest_id = tonumber(item.id)
                local text = string.format("%s %s", tostring(item.id), tostring(item.title or ""))

                row.__polar_populating = true
                if row.checkbox ~= nil and row.checkbox.SetChecked ~= nil then
                    row.checkbox:SetChecked(item.hidden and false or true)
                end
                row.__polar_populating = nil

                if row.label ~= nil and row.label.SetText ~= nil then
                    row.label:SetText(text)
                end

                pcall(function()
                    if row.label ~= nil and FONT_COLOR ~= nil and ApplyTextColor ~= nil then
                        if item.completed then
                            ApplyTextColor(row.label, FONT_COLOR.GREEN)
                        else
                            ApplyTextColor(row.label, FONT_COLOR.RED)
                        end
                    end
                end)

                pcall(function()
                    if row.checkbox.RemoveAllAnchors ~= nil then
                        row.checkbox:RemoveAllAnchors()
                    end
                    row.checkbox:AddAnchor("TOPLEFT", content, 0, y)
                    if row.label.RemoveAllAnchors ~= nil then
                        row.label:RemoveAllAnchors()
                    end
                    row.label:AddAnchor("LEFT", row.checkbox, "RIGHT", 8, 0)
                end)

                pcall(function()
                    if row.checkbox.Show ~= nil then
                        row.checkbox:Show(true)
                    end
                    if row.label.Show ~= nil then
                        row.label:Show(true)
                    end
                end)

                y = y + rowH
            end

            for i = count + 1, #rows do
                local row = rows[i]
                if type(row) == "table" then
                    pcall(function()
                        if row.checkbox ~= nil and row.checkbox.Show ~= nil then
                            row.checkbox:Show(false)
                        end
                        if row.label ~= nil and row.label.Show ~= nil then
                            row.label:Show(false)
                        end
                    end)
                    row.quest_id = nil
                end
            end

            local scrollFrame = SettingsPage.controls.dailyage_mgr_scroll_frame
            if scrollFrame ~= nil and scrollFrame.ResetScroll ~= nil then
                scrollFrame:ResetScroll(y + 5)
            end
        end

        local page = SettingsPage.pages.dailyage
        local y = 35
        CreateLabel("polarUiDailyAgePageTitle", page, "Dailies", 15, y, 18)
        y = y + 30

        SettingsPage.controls.dailyage_enabled = CreateCheckbox("polarUiDailyAgeEnabled", page, "Enable Dailies", 15, y)
        y = y + gap

        SettingsPage.controls.dailyage_clear_hidden = CreateButton("polarUiDailyAgeClearHidden", page, "Show all", 15, y - 4)
        if SettingsPage.controls.dailyage_clear_hidden ~= nil and SettingsPage.controls.dailyage_clear_hidden.SetHandler ~= nil then
            SettingsPage.controls.dailyage_clear_hidden:SetHandler("OnClick", function()
                if SettingsPage.settings == nil then
                    return
                end
                EnsureDailyAgeTables(SettingsPage.settings)
                SettingsPage.settings.dailyage.hidden = {}
                refreshDailyAgeList()
                if type(SettingsPage.on_save) == "function" then
                    pcall(function()
                        SettingsPage.on_save()
                    end)
                end
                if type(SettingsPage.on_apply) == "function" then
                    pcall(function()
                        SettingsPage.on_apply()
                    end)
                end
            end)
        end

        SettingsPage.controls.dailyage_status = api.Interface:CreateWidget("label", "polarUiDailyAgeStatus", page)
        SettingsPage.controls.dailyage_status:AddAnchor("TOPLEFT", page, 210, y)
        SettingsPage.controls.dailyage_status:SetExtent(300, 18)
        SettingsPage.controls.dailyage_status:SetText("Shown: 0")
        pcall(function()
            if SettingsPage.controls.dailyage_status.style ~= nil then
                SettingsPage.controls.dailyage_status.style:SetFontSize(13)
                SettingsPage.controls.dailyage_status.style:SetAlign(ALIGN.LEFT)
            end
        end)

        SettingsPage.controls.dailyage_manage = CreateButton("polarUiDailyAgeManage", page, "Manage dailies...", 15, y + 26)
        if SettingsPage.controls.dailyage_manage ~= nil and SettingsPage.controls.dailyage_manage.SetHandler ~= nil then
            SettingsPage.controls.dailyage_manage:SetHandler("OnClick", function()
                local wnd = EnsureDailyAgeManagerWindow()
                if wnd ~= nil and wnd.Show ~= nil then
                    pcall(function()
                        wnd:Show(true)
                    end)
                end
                refreshDailyAgeList()
            end)
        end

        y = y + 70
        SettingsPage.page_heights.dailyage = y + 40

        SettingsPage.dailyage_entries = nil
        SettingsPage.dailyage_search_text = ""
        SettingsPage.RefreshDailyAgeList = refreshDailyAgeList
        refreshDailyAgeList()
    end

    do
        local page = SettingsPage.pages.text
        local y = 35
        CreateLabel("polarUiTextPageTitle", page, "Text", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiTextStyleTargetLabel", page, "Edit style for", 15, y, 15)
        SettingsPage.controls.style_target_text = CreateComboBox(
            page,
            { "All frames", "Player", "Target", "Watchtarget", "Target of Target" },
            175,
            y - 4,
            220,
            24
        )
        y = y + 34

        SettingsPage.controls.style_target_text_hint = CreateHintLabel(
            "polarUiTextStyleTargetHint",
            page,
            "Editing shared defaults for all overlay frames.",
            15,
            y
        )
        y = y + 24

        CreateLabel("polarUiFontSizesTitle", page, "Font Sizes", 15, y, 18)
        y = y + 30

        SettingsPage.controls.name_font_size, SettingsPage.controls.name_font_size_val = CreateSlider(
            "polarUiNameFontSize",
            page,
            "Name font size",
            15,
            y,
            8,
            30,
            1
        )
        y = y + 24

        SettingsPage.controls.hp_font_size, SettingsPage.controls.hp_font_size_val = CreateSlider(
            "polarUiHpFontSize",
            page,
            "HP font size",
            15,
            y,
            8,
            40,
            1
        )
        y = y + 24

        SettingsPage.controls.mp_font_size, SettingsPage.controls.mp_font_size_val = CreateSlider(
            "polarUiMpFontSize",
            page,
            "MP font size",
            15,
            y,
            8,
            40,
            1
        )
        y = y + 24

        SettingsPage.controls.overlay_font_size, SettingsPage.controls.overlay_font_size_val = CreateSlider(
            "polarUiOverlayFontSize",
            page,
            "Target overlay font size",
            15,
            y,
            8,
            30,
            1
        )
        y = y + 24

        SettingsPage.controls.gs_font_size, SettingsPage.controls.gs_font_size_val = CreateSlider(
            "polarUiGsFontSize",
            page,
            "Gearscore font size",
            15,
            y,
            8,
            30,
            1
        )
        y = y + 24

        SettingsPage.controls.class_font_size, SettingsPage.controls.class_font_size_val = CreateSlider(
            "polarUiClassFontSize",
            page,
            "Class font size",
            15,
            y,
            8,
            30,
            1
        )
        y = y + 24

        SettingsPage.controls.role_font_size, SettingsPage.controls.role_font_size_val = CreateSlider(
            "polarUiRoleFontSize",
            page,
            "Role font size",
            15,
            y,
            8,
            30,
            1
        )
        y = y + 24

        SettingsPage.controls.target_guild_font_size, SettingsPage.controls.target_guild_font_size_val = CreateSlider(
            "polarUiTargetGuildFontSize",
            page,
            "Target guild font size",
            15,
            y,
            8,
            30,
            1
        )
        y = y + gap

        CreateLabel("polarUiShadowsTitle", page, "Shadows", 15, y, 18)
        y = y + 30

        SettingsPage.controls.name_shadow = CreateCheckbox("polarUiNameShadow", page, "Name text shadow", 15, y)
        y = y + gap

        SettingsPage.controls.value_shadow = CreateCheckbox("polarUiValueShadow", page, "HP/MP value shadow", 15, y)
        y = y + gap

        SettingsPage.controls.overlay_shadow = CreateCheckbox("polarUiOverlayShadow", page, "Target overlay shadow", 15, y)
        y = y + gap + 10

        CreateLabel("polarUiValueOffsetsTitle", page, "HP/MP Value Offsets", 15, y, 18)
        y = y + 30

        SettingsPage.controls.hp_value_offset_x, SettingsPage.controls.hp_value_offset_x_val = CreateSlider(
            "polarUiHpValueOffsetX",
            page,
            "HP value offset X",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + 24

        SettingsPage.controls.hp_value_offset_y, SettingsPage.controls.hp_value_offset_y_val = CreateSlider(
            "polarUiHpValueOffsetY",
            page,
            "HP value offset Y",
            15,
            y,
            -120,
            120,
            1
        )
        y = y + 24

        SettingsPage.controls.mp_value_offset_x, SettingsPage.controls.mp_value_offset_x_val = CreateSlider(
            "polarUiMpValueOffsetX",
            page,
            "MP value offset X",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + 24

        SettingsPage.controls.mp_value_offset_y, SettingsPage.controls.mp_value_offset_y_val = CreateSlider(
            "polarUiMpValueOffsetY",
            page,
            "MP value offset Y",
            15,
            y,
            -120,
            120,
            1
        )
        y = y + 24

        SettingsPage.controls.target_guild_offset_x, SettingsPage.controls.target_guild_offset_x_val = CreateSlider(
            "polarUiTargetGuildOffsetX",
            page,
            "Target guild offset X",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + 24

        SettingsPage.controls.target_guild_offset_y, SettingsPage.controls.target_guild_offset_y_val = CreateSlider(
            "polarUiTargetGuildOffsetY",
            page,
            "Target guild offset Y",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + gap + 10

        CreateLabel("polarUiTextLayoutTitle", page, "Text Layout", 15, y, 18)
        y = y + 30

        SettingsPage.controls.name_visible = CreateCheckbox("polarUiNameVisible", page, "Show name text", 15, y)
        y = y + gap

        SettingsPage.controls.name_offset_x, SettingsPage.controls.name_offset_x_val = CreateSlider(
            "polarUiNameOffsetX",
            page,
            "Name offset X",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + 24

        SettingsPage.controls.name_offset_y, SettingsPage.controls.name_offset_y_val = CreateSlider(
            "polarUiNameOffsetY",
            page,
            "Name offset Y",
            15,
            y,
            -120,
            120,
            1
        )
        y = y + 24

        SettingsPage.controls.level_visible = CreateCheckbox("polarUiLevelVisible", page, "Show level text", 15, y)
        y = y + gap

        SettingsPage.controls.level_font_size, SettingsPage.controls.level_font_size_val = CreateSlider(
            "polarUiLevelFontSize",
            page,
            "Level font size",
            15,
            y,
            8,
            24,
            1
        )
        y = y + 24

        SettingsPage.controls.level_offset_x, SettingsPage.controls.level_offset_x_val = CreateSlider(
            "polarUiLevelOffsetX",
            page,
            "Level offset X",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + 24

        SettingsPage.controls.level_offset_y, SettingsPage.controls.level_offset_y_val = CreateSlider(
            "polarUiLevelOffsetY",
            page,
            "Level offset Y",
            15,
            y,
            -120,
            120,
            1
        )
        y = y + 34

        SettingsPage.page_heights.text = y + 40
    end

    do
        local page = SettingsPage.pages.bars
        local y = 35
        CreateLabel("polarUiBarsPageTitle", page, "Bars", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiBarsStyleTargetLabel", page, "Edit style for", 15, y, 15)
        SettingsPage.controls.style_target_bars = CreateComboBox(
            page,
            { "All frames", "Player", "Target", "Watchtarget", "Target of Target" },
            175,
            y - 4,
            220,
            24
        )
        y = y + 34

        SettingsPage.controls.style_target_bars_hint = CreateHintLabel(
            "polarUiBarsStyleTargetHint",
            page,
            "Editing shared defaults for all overlay frames.",
            15,
            y
        )
        y = y + 24

        CreateLabel("polarUiFrameTitleBars", page, "Frame Styling", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiFrameOpacityTitle", page, "Opacity", 15, y, 15)
        y = y + 22

        SettingsPage.controls.frame_alpha, SettingsPage.controls.frame_alpha_val = CreateSlider(
            "polarUiFrameAlpha",
            page,
            "Frame alpha (0-100)",
            15,
            y,
            0,
            100,
            1
        )
        y = y + 24

        SettingsPage.controls.overlay_alpha, SettingsPage.controls.overlay_alpha_val = CreateSlider(
            "polarUiOverlayAlpha",
            page,
            "Overlay alpha (0-100)",
            15,
            y,
            0,
            100,
            1
        )
        y = y + gap

        CreateLabel("polarUiFrameSizeTitle", page, "Dimensions", 15, y, 15)
        y = y + 22

        SettingsPage.controls.frame_width, SettingsPage.controls.frame_width_val = CreateSlider(
            "polarUiFrameWidth",
            page,
            "Frame width",
            15,
            y,
            200,
            600,
            1
        )
        y = y + 24

        SettingsPage.controls.frame_height, SettingsPage.controls.frame_height_val = CreateSlider(
            "polarUiFrameHeight",
            page,
            "Frame height (global)",
            15,
            y,
            40,
            120,
            1
        )
        y = y + 24

        SettingsPage.controls.frame_scale, SettingsPage.controls.frame_scale_val = CreateSlider(
            "polarUiFrameScale",
            page,
            "Frame scale (50-150)",
            15,
            y,
            50,
            150,
            1
        )
        y = y + 24

        CreateLabel("polarUiBarLayoutTitle", page, "Bar Layout", 15, y, 15)
        y = y + 22

        SettingsPage.controls.bar_height, SettingsPage.controls.bar_height_val = CreateSlider(
            "polarUiBarHeight",
            page,
            "Shared bar height",
            15,
            y,
            10,
            40,
            1
        )
        y = y + 24

        SettingsPage.controls.hp_bar_height, SettingsPage.controls.hp_bar_height_val = CreateSlider(
            "polarUiHpBarHeight",
            page,
            "HP bar height",
            15,
            y,
            10,
            40,
            1
        )
        y = y + 24

        SettingsPage.controls.mp_bar_height, SettingsPage.controls.mp_bar_height_val = CreateSlider(
            "polarUiMpBarHeight",
            page,
            "MP bar height",
            15,
            y,
            6,
            40,
            1
        )
        y = y + 24

        SettingsPage.controls.bar_gap, SettingsPage.controls.bar_gap_val = CreateSlider(
            "polarUiBarGap",
            page,
            "Bar gap",
            15,
            y,
            0,
            20,
            1
        )
        y = y + gap + 10

        CreateLabel("polarUiBarStyleTitle", page, "Bar Style", 15, y, 18)
        y = y + 30

        SettingsPage.controls.bar_colors_enabled = CreateCheckbox("polarUiBarColorsEnabled", page, "Override HP/MP bar colors", 15, y)
        y = y + gap

        CreateLabel("polarUiHpColorLabel", page, "HP Color (RGB)", 15, y, 15)
        y = y + 22

        SettingsPage.controls.hp_r, SettingsPage.controls.hp_r_val = CreateSlider("polarUiHpR", page, "HP R", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.hp_g, SettingsPage.controls.hp_g_val = CreateSlider("polarUiHpG", page, "HP G", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.hp_b, SettingsPage.controls.hp_b_val = CreateSlider("polarUiHpB", page, "HP B", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.hp_a, SettingsPage.controls.hp_a_val = CreateSlider("polarUiHpA", page, "HP Fill alpha", 15, y, 0, 255, 1)
        y = y + 30

        CreateLabel("polarUiHpAfterColorLabel", page, "HP Afterimage Color (RGB)", 15, y, 15)
        y = y + 22

        SettingsPage.controls.hp_after_r, SettingsPage.controls.hp_after_r_val = CreateSlider("polarUiHpAfterR", page, "HP After R", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.hp_after_g, SettingsPage.controls.hp_after_g_val = CreateSlider("polarUiHpAfterG", page, "HP After G", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.hp_after_b, SettingsPage.controls.hp_after_b_val = CreateSlider("polarUiHpAfterB", page, "HP After B", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.hp_after_a, SettingsPage.controls.hp_after_a_val = CreateSlider("polarUiHpAfterA", page, "HP After alpha", 15, y, 0, 255, 1)
        y = y + 30

        CreateLabel("polarUiMpColorLabel", page, "MP Color (RGB)", 15, y, 15)
        y = y + 22

        SettingsPage.controls.mp_r, SettingsPage.controls.mp_r_val = CreateSlider("polarUiMpR", page, "MP R", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.mp_g, SettingsPage.controls.mp_g_val = CreateSlider("polarUiMpG", page, "MP G", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.mp_b, SettingsPage.controls.mp_b_val = CreateSlider("polarUiMpB", page, "MP B", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.mp_a, SettingsPage.controls.mp_a_val = CreateSlider("polarUiMpA", page, "MP Fill alpha", 15, y, 0, 255, 1)
        y = y + 30

        CreateLabel("polarUiMpAfterColorLabel", page, "MP Afterimage Color (RGB)", 15, y, 15)
        y = y + 22

        SettingsPage.controls.mp_after_r, SettingsPage.controls.mp_after_r_val = CreateSlider("polarUiMpAfterR", page, "MP After R", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.mp_after_g, SettingsPage.controls.mp_after_g_val = CreateSlider("polarUiMpAfterG", page, "MP After G", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.mp_after_b, SettingsPage.controls.mp_after_b_val = CreateSlider("polarUiMpAfterB", page, "MP After B", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.mp_after_a, SettingsPage.controls.mp_after_a_val = CreateSlider("polarUiMpAfterA", page, "MP After alpha", 15, y, 0, 255, 1)
        y = y + gap

        CreateLabel("polarUiHpTextureLabel", page, "HP Texture Mode", 15, y, 15)
        y = y + 22

        SettingsPage.controls.hp_tex_stock = CreateCheckbox("polarUiHpTexStock", page, "Stock", 15, y)
        y = y + gap
        SettingsPage.controls.hp_tex_pc = CreateCheckbox("polarUiHpTexPc", page, "PC", 15, y)
        y = y + gap
        SettingsPage.controls.hp_tex_npc = CreateCheckbox("polarUiHpTexNpc", page, "NPC", 15, y)
        y = y + gap + 10

        CreateLabel("polarUiValueTextTitle", page, "HP/MP Value Text", 15, y, 18)
        y = y + 30

        SettingsPage.controls.value_fmt_curmax = CreateCheckbox(
            "polarUiValueFmtCurMax",
            page,
            "Format HP/MP as cur/max",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.value_fmt_percent = CreateCheckbox(
            "polarUiValueFmtPercent",
            page,
            "Format HP/MP as percent",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.short_numbers = CreateCheckbox(
            "polarUiShortNumbers",
            page,
            "Short numbers (12.3k/4.5m)",
            15,
            y
        )
        y = y + 34

        SettingsPage.page_heights.bars = y + 40
    end

    do
        local page = SettingsPage.pages.auras
        local y = 35
        CreateLabel("polarUiAurasPageTitle", page, "Auras", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiAuraTitle", page, "Aura Layout (Buff/Debuff Icon Size)", 15, y, 18)
        y = y + 30

        SettingsPage.controls.aura_enabled = CreateCheckbox(
            "polarUiAuraEnabled",
            page,
            "Override aura icon layout",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.aura_icon_size, SettingsPage.controls.aura_icon_size_val = CreateSlider(
            "polarUiAuraIconSize",
            page,
            "Icon size",
            15,
            y,
            12,
            48,
            1
        )
        y = y + 24

        SettingsPage.controls.aura_x_gap, SettingsPage.controls.aura_x_gap_val = CreateSlider(
            "polarUiAuraXGap",
            page,
            "Icon X gap",
            15,
            y,
            0,
            10,
            1
        )
        y = y + 24

        SettingsPage.controls.aura_y_gap, SettingsPage.controls.aura_y_gap_val = CreateSlider(
            "polarUiAuraYGap",
            page,
            "Icon Y gap",
            15,
            y,
            0,
            10,
            1
        )
        y = y + 24

        SettingsPage.controls.aura_per_row, SettingsPage.controls.aura_per_row_val = CreateSlider(
            "polarUiAuraPerRow",
            page,
            "Icons per row",
            15,
            y,
            1,
            30,
            1
        )
        y = y + 24

        SettingsPage.controls.aura_sort_vertical = CreateCheckbox(
            "polarUiAuraSortVertical",
            page,
            "Sort vertical",
            15,
            y
        )
        y = y + gap + 10

        SettingsPage.controls.move_buffs = CreateCheckbox("polarUiMoveBuffs", page, "Move buff/debuff strips (uses settings.txt offsets)", 15, y)
        y = y + gap

        CreateLabel("polarUiBuffPlacementTitle", page, "Buff/Debuff Placement (Offsets)", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiBuffPlacementPlayer", page, "Player", 15, y, 15)
        y = y + 22

        SettingsPage.controls.p_buff_x, SettingsPage.controls.p_buff_x_val = CreateSlider("polarUiPBX", page, "Buff X", 15, y, -200, 200, 1)
        y = y + 24
        SettingsPage.controls.p_buff_y, SettingsPage.controls.p_buff_y_val = CreateSlider("polarUiPBY", page, "Buff Y", 15, y, -200, 200, 1)
        y = y + 24
        SettingsPage.controls.p_debuff_x, SettingsPage.controls.p_debuff_x_val = CreateSlider("polarUiPDBX", page, "Debuff X", 15, y, -200, 200, 1)
        y = y + 24
        SettingsPage.controls.p_debuff_y, SettingsPage.controls.p_debuff_y_val = CreateSlider("polarUiPDBY", page, "Debuff Y", 15, y, -200, 200, 1)
        y = y + 30

        CreateLabel("polarUiBuffPlacementTarget", page, "Target", 15, y, 15)
        y = y + 22

        SettingsPage.controls.t_buff_x, SettingsPage.controls.t_buff_x_val = CreateSlider("polarUiTBX", page, "Buff X", 15, y, -200, 200, 1)
        y = y + 24
        SettingsPage.controls.t_buff_y, SettingsPage.controls.t_buff_y_val = CreateSlider("polarUiTBY", page, "Buff Y", 15, y, -200, 200, 1)
        y = y + 24
        SettingsPage.controls.t_debuff_x, SettingsPage.controls.t_debuff_x_val = CreateSlider("polarUiTDBX", page, "Debuff X", 15, y, -200, 200, 1)
        y = y + 24
        SettingsPage.controls.t_debuff_y, SettingsPage.controls.t_debuff_y_val = CreateSlider("polarUiTDBY", page, "Debuff Y", 15, y, -200, 200, 1)
        y = y + 34

        SettingsPage.page_heights.auras = y + 40
    end

    do
        local page = SettingsPage.pages.plates
        local y = 35
        CreateLabel("polarUiPlatesPageTitle", page, "Plates", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiPlatesHeader", page, "Overhead Raid/Party Plates", 15, y, 18)
        y = y + 30

        SettingsPage.controls.plates_enabled = CreateCheckbox("polarUiPlatesEnabled", page, "Enable overhead plates", 15, y)
        y = y + gap

        SettingsPage.controls.plates_guild_only = CreateCheckbox(
            "polarUiPlatesGuildOnly",
            page,
            "Guild-only overlay (keep stock nameplates)",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.plates_show_target = CreateCheckbox("polarUiPlatesShowTarget", page, "Show target (always)", 15, y)
        y = y + gap

        SettingsPage.controls.plates_show_player = CreateCheckbox("polarUiPlatesShowPlayer", page, "Show player (always)", 15, y)
        y = y + gap

        SettingsPage.controls.plates_show_raid_party = CreateCheckbox("polarUiPlatesShowRaid", page, "Show raid/party (team1..team50)", 15, y)
        y = y + gap

        SettingsPage.controls.plates_show_watchtarget = CreateCheckbox("polarUiPlatesShowWatch", page, "Show watchtarget", 15, y)
        y = y + gap

        SettingsPage.controls.plates_show_mount = CreateCheckbox("polarUiPlatesShowMount", page, "Show mount/pet (playerpet1)", 15, y)
        y = y + gap

        SettingsPage.controls.plates_show_guild = CreateCheckbox("polarUiPlatesShowGuild", page, "Show guild/expedition", 15, y)
        y = y + gap + 10

        CreateLabel("polarUiPlatesClickHeader", page, "Click Behavior", 15, y, 18)
        y = y + 30

        SettingsPage.controls.plates_click_shift = CreateCheckbox("polarUiPlatesClickShift", page, "Shift: click through plates", 15, y)
        y = y + gap

        SettingsPage.controls.plates_click_ctrl = CreateCheckbox("polarUiPlatesClickCtrl", page, "Ctrl: click through plates", 15, y)
        y = y + gap + 10

        SettingsPage.controls.plates_runtime_note = CreateLabel(
            "polarUiPlatesRuntimeNote",
            page,
            "Current client uses passthrough targeting. Keep stock nameplates roughly aligned behind the addon plates.",
            15,
            y,
            13
        )
        if SettingsPage.controls.plates_runtime_note ~= nil then
            SettingsPage.controls.plates_runtime_note:SetExtent(470, 36)
        end
        y = y + 38

        SettingsPage.controls.plates_runtime_status = CreateLabel(
            "polarUiPlatesRuntimeStatus",
            page,
            "",
            15,
            y,
            12
        )
        if SettingsPage.controls.plates_runtime_status ~= nil then
            SettingsPage.controls.plates_runtime_status:SetExtent(470, 32)
        end
        y = y + 34

        CreateLabel("polarUiPlatesLayoutHeader", page, "Layout", 15, y, 18)
        y = y + 30

        SettingsPage.controls.plates_alpha, SettingsPage.controls.plates_alpha_val = CreateSlider(
            "polarUiPlatesAlpha",
            page,
            "Transparency (0-100)",
            15,
            y,
            0,
            100,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_width, SettingsPage.controls.plates_width_val = CreateSlider(
            "polarUiPlatesWidth",
            page,
            "Width",
            15,
            y,
            50,
            250,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_hp_h, SettingsPage.controls.plates_hp_h_val = CreateSlider(
            "polarUiPlatesHpHeight",
            page,
            "HP height",
            15,
            y,
            5,
            60,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_mp_h, SettingsPage.controls.plates_mp_h_val = CreateSlider(
            "polarUiPlatesMpHeight",
            page,
            "MP height (0 hides)",
            15,
            y,
            0,
            40,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_x_offset, SettingsPage.controls.plates_x_offset_val = CreateSlider(
            "polarUiPlatesXOffset",
            page,
            "X offset",
            15,
            y,
            -200,
            200,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_max_dist, SettingsPage.controls.plates_max_dist_val = CreateSlider(
            "polarUiPlatesMaxDistance",
            page,
            "Max distance",
            15,
            y,
            1,
            300,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_y_offset, SettingsPage.controls.plates_y_offset_val = CreateSlider(
            "polarUiPlatesYOffset",
            page,
            "Y offset",
            15,
            y,
            -100,
            100,
            1
        )
        y = y + gap

        SettingsPage.controls.plates_anchor_tag = CreateCheckbox(
            "polarUiPlatesAnchorToTag",
            page,
            "Anchor to stock name tag",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.plates_bg_enabled = CreateCheckbox(
            "polarUiPlatesBgEnabled",
            page,
            "Show background",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.plates_bg_alpha, SettingsPage.controls.plates_bg_alpha_val = CreateSlider(
            "polarUiPlatesBgAlpha",
            page,
            "Background alpha (0-100)",
            15,
            y,
            0,
            100,
            1
        )
        y = y + gap + 10

        CreateLabel("polarUiPlatesTextHeader", page, "Text", 15, y, 18)
        y = y + 30

        SettingsPage.controls.plates_name_fs, SettingsPage.controls.plates_name_fs_val = CreateSlider(
            "polarUiPlatesNameFontSize",
            page,
            "Name font size",
            15,
            y,
            6,
            32,
            1
        )
        y = y + 24

        SettingsPage.controls.plates_guild_fs, SettingsPage.controls.plates_guild_fs_val = CreateSlider(
            "polarUiPlatesGuildFontSize",
            page,
            "Guild font size",
            15,
            y,
            6,
            32,
            1
        )
        y = y + 34

        CreateLabel("polarUiPlatesGuildColorsHeader", page, "Guild Colors", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiPlatesGuildColorNameLbl", page, "Guild", 15, y, 15)
        SettingsPage.controls.plates_guild_color_name = CreateEdit("polarUiPlatesGuildColorName", page, "", 70, y - 4, 180, 22)
        SettingsPage.controls.plates_guild_color_add = CreateButton("polarUiPlatesGuildColorAdd", page, "Add", 265, y - 6)
        SettingsPage.controls.plates_guild_color_add_target = CreateButton("polarUiPlatesGuildColorAddTarget", page, "Use Target", 340, y - 6)
        if SettingsPage.controls.plates_guild_color_add ~= nil then
            SettingsPage.controls.plates_guild_color_add:SetExtent(70, 22)
        end
        if SettingsPage.controls.plates_guild_color_add_target ~= nil then
            SettingsPage.controls.plates_guild_color_add_target:SetExtent(95, 22)
        end
        y = y + 28

        SettingsPage.controls.plates_guild_color_r, SettingsPage.controls.plates_guild_color_r_val = CreateSlider(
            "polarUiPlatesGuildColorR",
            page,
            "R (0-255)",
            15,
            y,
            0,
            255,
            1
        )
        y = y + 24
        SettingsPage.controls.plates_guild_color_g, SettingsPage.controls.plates_guild_color_g_val = CreateSlider(
            "polarUiPlatesGuildColorG",
            page,
            "G (0-255)",
            15,
            y,
            0,
            255,
            1
        )
        y = y + 24
        SettingsPage.controls.plates_guild_color_b, SettingsPage.controls.plates_guild_color_b_val = CreateSlider(
            "polarUiPlatesGuildColorB",
            page,
            "B (0-255)",
            15,
            y,
            0,
            255,
            1
        )
        y = y + 30

        SettingsPage.controls.plates_guild_color_rows = {}
        for i = 1, 8 do
            local row_y = y
            local label = CreateLabel("polarUiPlatesGuildColorRow" .. tostring(i), page, "", 30, row_y, 14)
            if label ~= nil then
                label:SetExtent(280, 18)
            end
            local rm = CreateButton("polarUiPlatesGuildColorRemove" .. tostring(i), page, "Remove", 320, row_y - 6)
            if rm ~= nil then
                rm:SetExtent(80, 22)
            end
            SettingsPage.controls.plates_guild_color_rows[i] = { label = label, remove = rm }
            y = y + 26
        end
        SettingsPage.page_heights.plates = y + 40
    end

    do
        local page = SettingsPage.pages.cooldown
        local y = 35
        CreateLabel("polarUiCooldownPageTitle", page, "Cooldown Tracker", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_enabled = CreateCheckbox(
            "polarUiCooldownEnabled",
            page,
            "Enable cooldown tracker",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.ct_update_interval, SettingsPage.controls.ct_update_interval_val = CreateSlider(
            "polarUiCooldownUpdateInterval",
            page,
            "Update interval (ms)",
            15,
            y,
            10,
            500,
            1
        )
        y = y + gap + 10

        CreateLabel("polarUiCooldownUnitLabel", page, "Unit", 15, y, 15)
        SettingsPage.controls.ct_unit = CreateComboBox(page, COOLDOWN_UNIT_LABELS, 110, y - 4, 220, 24)
        y = y + 34

        SettingsPage.controls.ct_unit_enabled = CreateCheckbox(
            "polarUiCooldownUnitEnabled",
            page,
            "Enable for selected unit",
            15,
            y
        )
        y = y + gap

        SettingsPage.controls.ct_lock_position = CreateCheckbox(
            "polarUiCooldownLockPosition",
            page,
            "Lock position (disable dragging)",
            15,
            y
        )
        y = y + gap + 10

        CreateLabel("polarUiCooldownPositionTitle", page, "Position", 15, y, 18)
        y = y + 30

        CreateLabel("polarUiCooldownPosXLabel", page, "X", 15, y, 15)
        SettingsPage.controls.ct_pos_x = CreateEdit("polarUiCooldownPosX", page, "0", 35, y - 4, 90, 22)
        if SettingsPage.controls.ct_pos_x ~= nil and SettingsPage.controls.ct_pos_x.SetDigit ~= nil then
            pcall(function()
                SettingsPage.controls.ct_pos_x:SetDigit(true)
            end)
        end

        CreateLabel("polarUiCooldownPosYLabel", page, "Y", 145, y, 15)
        SettingsPage.controls.ct_pos_y = CreateEdit("polarUiCooldownPosY", page, "0", 165, y - 4, 90, 22)
        if SettingsPage.controls.ct_pos_y ~= nil and SettingsPage.controls.ct_pos_y.SetDigit ~= nil then
            pcall(function()
                SettingsPage.controls.ct_pos_y:SetDigit(true)
            end)
        end
        y = y + gap + 10

        CreateLabel("polarUiCooldownIconsTitle", page, "Icons", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_icon_size, SettingsPage.controls.ct_icon_size_val = CreateSlider(
            "polarUiCooldownIconSize",
            page,
            "Icon size",
            15,
            y,
            12,
            80,
            1
        )
        y = y + 24

        SettingsPage.controls.ct_icon_spacing, SettingsPage.controls.ct_icon_spacing_val = CreateSlider(
            "polarUiCooldownIconSpacing",
            page,
            "Icon spacing",
            15,
            y,
            0,
            20,
            1
        )
        y = y + 24

        SettingsPage.controls.ct_max_icons, SettingsPage.controls.ct_max_icons_val = CreateSlider(
            "polarUiCooldownMaxIcons",
            page,
            "Max icons",
            15,
            y,
            1,
            20,
            1
        )
        y = y + gap + 10

        CreateLabel("polarUiCooldownTimerTitle", page, "Timer Text", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_show_timer = CreateCheckbox("polarUiCooldownShowTimer", page, "Show timer", 15, y)
        y = y + gap

        SettingsPage.controls.ct_timer_fs, SettingsPage.controls.ct_timer_fs_val = CreateSlider(
            "polarUiCooldownTimerFontSize",
            page,
            "Timer font size",
            15,
            y,
            6,
            40,
            1
        )
        y = y + 24

        CreateLabel("polarUiCooldownTimerColorTitle", page, "Timer color (RGB)", 15, y, 15)
        y = y + 22
        SettingsPage.controls.ct_timer_r, SettingsPage.controls.ct_timer_r_val = CreateSlider("polarUiCooldownTimerR", page, "R", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.ct_timer_g, SettingsPage.controls.ct_timer_g_val = CreateSlider("polarUiCooldownTimerG", page, "G", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.ct_timer_b, SettingsPage.controls.ct_timer_b_val = CreateSlider("polarUiCooldownTimerB", page, "B", 15, y, 0, 255, 1)
        y = y + gap + 10

        CreateLabel("polarUiCooldownLabelTitle", page, "Label Text", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_show_label = CreateCheckbox("polarUiCooldownShowLabel", page, "Show label", 15, y)
        y = y + gap

        SettingsPage.controls.ct_label_fs, SettingsPage.controls.ct_label_fs_val = CreateSlider(
            "polarUiCooldownLabelFontSize",
            page,
            "Label font size",
            15,
            y,
            6,
            40,
            1
        )
        y = y + 24

        CreateLabel("polarUiCooldownLabelColorTitle", page, "Label color (RGB)", 15, y, 15)
        y = y + 22
        SettingsPage.controls.ct_label_r, SettingsPage.controls.ct_label_r_val = CreateSlider("polarUiCooldownLabelR", page, "R", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.ct_label_g, SettingsPage.controls.ct_label_g_val = CreateSlider("polarUiCooldownLabelG", page, "G", 15, y, 0, 255, 1)
        y = y + 24
        SettingsPage.controls.ct_label_b, SettingsPage.controls.ct_label_b_val = CreateSlider("polarUiCooldownLabelB", page, "B", 15, y, 0, 255, 1)
        y = y + gap + 10

        CreateLabel("polarUiCooldownTargetCacheTitle", page, "Target Cache", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_cache_timeout, SettingsPage.controls.ct_cache_timeout_val = CreateSlider(
            "polarUiCooldownCacheTimeout",
            page,
            "Cache timeout (sec) (target only)",
            15,
            y,
            0,
            600,
            1
        )
        y = y + gap + 10

        CreateLabel("polarUiCooldownTrackedBuffsTitle", page, "Tracked Buff IDs", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_new_buff_id = CreateEdit("polarUiCooldownNewBuffId", page, "", 15, y - 4, 120, 22)
        if SettingsPage.controls.ct_new_buff_id ~= nil and SettingsPage.controls.ct_new_buff_id.SetDigit ~= nil then
            pcall(function()
                SettingsPage.controls.ct_new_buff_id:SetDigit(true)
            end)
        end
        SettingsPage.controls.ct_add_buff = CreateButton("polarUiCooldownAddBuff", page, "Add", 145, y - 6)
        y = y + 34

        SettingsPage.controls.ct_prev_page = CreateButton("polarUiCooldownPrevPage", page, "Prev", 15, y)
        SettingsPage.controls.ct_next_page = CreateButton("polarUiCooldownNextPage", page, "Next", 110, y)
        SettingsPage.controls.ct_page_label = CreateLabel("polarUiCooldownPageLabel", page, "1 / 1", 215, y + 6, 14)
        y = y + 34

        SettingsPage.controls.ct_buff_rows = {}
        for i = 1, COOLDOWN_BUFFS_PER_PAGE do
            local row_y = y + ((i - 1) * 26)
            local label = CreateLabel("polarUiCooldownBuffRowLabel" .. tostring(i), page, "", 15, row_y + 6, 14)
            if label ~= nil then
                label:SetExtent(180, 18)
            end
            local rm = CreateButton("polarUiCooldownBuffRowRemove" .. tostring(i), page, "Remove", 205, row_y)
            if rm ~= nil then
                rm:SetExtent(90, 22)
            end
            SettingsPage.controls.ct_buff_rows[i] = { label = label, remove = rm }
        end
        y = y + (COOLDOWN_BUFFS_PER_PAGE * 26) + 20

        CreateLabel("polarUiCooldownScanTitle", page, "Scan Target Buffs/Debuffs", 15, y, 18)
        y = y + 30

        SettingsPage.controls.ct_scan_btn = CreateButton("polarUiCooldownScanBtn", page, "Scan", 15, y - 6)
        SettingsPage.controls.ct_scan_status = CreateLabel("polarUiCooldownScanStatus", page, "", 110, y, 14)
        if SettingsPage.controls.ct_scan_status ~= nil then
            SettingsPage.controls.ct_scan_status:SetExtent(320, 18)
        end
        y = y + 34

        SettingsPage.controls.ct_scan_rows = {}
        for i = 1, COOLDOWN_SCAN_ROWS do
            local row_y = y + ((i - 1) * 26)
            local label = CreateLabel("polarUiCooldownScanRowLabel" .. tostring(i), page, "", 15, row_y + 6, 14)
            if label ~= nil then
                label:SetExtent(310, 18)
            end
            local add = CreateButton("polarUiCooldownScanRowAdd" .. tostring(i), page, "Add", 335, row_y)
            if add ~= nil then
                add:SetExtent(60, 22)
            end
            SettingsPage.controls.ct_scan_rows[i] = { label = label, add = add }
        end
        y = y + (COOLDOWN_SCAN_ROWS * 26) + 20

        SettingsPage.page_heights.cooldown = y + 40
    end

    local applyBtn = CreateButton("polarUiApplySettings", SettingsPage.window, "Apply", 15, 370)
    local closeBtn = CreateButton("polarUiCloseSettings", SettingsPage.window, "Close", 110, 370)
    local backupBtn = CreateButton("polarUiBackupSettings", SettingsPage.window, "Backup", 205, 370)
    local importBtn = CreateButton("polarUiImportSettings", SettingsPage.window, "Import", 300, 370)
    local backupStatus = CreateLabel("polarUiBackupStatus", SettingsPage.window, "", 395, 370 + 6, 14)
    if backupStatus ~= nil then
        backupStatus:SetExtent(230, 18)
    end

    pcall(function()
        applyBtn:RemoveAllAnchors()
        closeBtn:RemoveAllAnchors()
        if backupBtn ~= nil then
            backupBtn:RemoveAllAnchors()
        end
        if importBtn ~= nil then
            importBtn:RemoveAllAnchors()
        end
        if backupStatus ~= nil then
            backupStatus:RemoveAllAnchors()
        end
        applyBtn:AddAnchor("BOTTOMLEFT", SettingsPage.window, 15, -15)
        closeBtn:AddAnchor("BOTTOMLEFT", SettingsPage.window, 110, -15)
        if backupBtn ~= nil then
            backupBtn:AddAnchor("BOTTOMLEFT", SettingsPage.window, 205, -15)
        end
        if importBtn ~= nil then
            importBtn:AddAnchor("BOTTOMLEFT", SettingsPage.window, 300, -15)
        end
        if backupStatus ~= nil then
            backupStatus:AddAnchor("BOTTOMLEFT", SettingsPage.window, 395, -11)
        end
    end)

    SetActivePage("general")

    local function syncStyleTargetFromActivePage()
        local ctrl = nil
        if SettingsPage.active_page == "text" then
            ctrl = SettingsPage.controls.style_target_text
        elseif SettingsPage.active_page == "bars" then
            ctrl = SettingsPage.controls.style_target_bars
        else
            return
        end
        SettingsPage.style_target = GetStyleTargetKeyFromControl(ctrl)
        UpdateStyleTargetHints()
    end

    local function sliderChanged()
        if SettingsPage.settings == nil then
            return
        end
        syncStyleTargetFromActivePage()
        ApplyControlsToSettings()
        if type(SettingsPage.on_apply) == "function" then
            pcall(function()
                SettingsPage.on_apply()
            end)
        end
    end

    local sliderList = {
        { SettingsPage.controls.frame_alpha, SettingsPage.controls.frame_alpha_val },
        { SettingsPage.controls.overlay_alpha, SettingsPage.controls.overlay_alpha_val },
        { SettingsPage.controls.frame_width, SettingsPage.controls.frame_width_val },
        { SettingsPage.controls.frame_height, SettingsPage.controls.frame_height_val },
        { SettingsPage.controls.frame_scale, SettingsPage.controls.frame_scale_val },
        { SettingsPage.controls.bar_height, SettingsPage.controls.bar_height_val },
        { SettingsPage.controls.hp_bar_height, SettingsPage.controls.hp_bar_height_val },
        { SettingsPage.controls.mp_bar_height, SettingsPage.controls.mp_bar_height_val },
        { SettingsPage.controls.bar_gap, SettingsPage.controls.bar_gap_val },
        { SettingsPage.controls.name_font_size, SettingsPage.controls.name_font_size_val },
        { SettingsPage.controls.hp_font_size, SettingsPage.controls.hp_font_size_val },
        { SettingsPage.controls.mp_font_size, SettingsPage.controls.mp_font_size_val },
        { SettingsPage.controls.overlay_font_size, SettingsPage.controls.overlay_font_size_val },
        { SettingsPage.controls.gs_font_size, SettingsPage.controls.gs_font_size_val },
        { SettingsPage.controls.class_font_size, SettingsPage.controls.class_font_size_val },
        { SettingsPage.controls.role_font_size, SettingsPage.controls.role_font_size_val },
        { SettingsPage.controls.target_guild_font_size, SettingsPage.controls.target_guild_font_size_val },
        { SettingsPage.controls.hp_value_offset_x, SettingsPage.controls.hp_value_offset_x_val },
        { SettingsPage.controls.hp_value_offset_y, SettingsPage.controls.hp_value_offset_y_val },
        { SettingsPage.controls.mp_value_offset_x, SettingsPage.controls.mp_value_offset_x_val },
        { SettingsPage.controls.mp_value_offset_y, SettingsPage.controls.mp_value_offset_y_val },
        { SettingsPage.controls.target_guild_offset_x, SettingsPage.controls.target_guild_offset_x_val },
        { SettingsPage.controls.target_guild_offset_y, SettingsPage.controls.target_guild_offset_y_val },
        { SettingsPage.controls.name_offset_x, SettingsPage.controls.name_offset_x_val },
        { SettingsPage.controls.name_offset_y, SettingsPage.controls.name_offset_y_val },
        { SettingsPage.controls.level_font_size, SettingsPage.controls.level_font_size_val },
        { SettingsPage.controls.level_offset_x, SettingsPage.controls.level_offset_x_val },
        { SettingsPage.controls.level_offset_y, SettingsPage.controls.level_offset_y_val },
        { SettingsPage.controls.hp_r, SettingsPage.controls.hp_r_val },
        { SettingsPage.controls.hp_g, SettingsPage.controls.hp_g_val },
        { SettingsPage.controls.hp_b, SettingsPage.controls.hp_b_val },
        { SettingsPage.controls.hp_a, SettingsPage.controls.hp_a_val },
        { SettingsPage.controls.hp_after_r, SettingsPage.controls.hp_after_r_val },
        { SettingsPage.controls.hp_after_g, SettingsPage.controls.hp_after_g_val },
        { SettingsPage.controls.hp_after_b, SettingsPage.controls.hp_after_b_val },
        { SettingsPage.controls.hp_after_a, SettingsPage.controls.hp_after_a_val },
        { SettingsPage.controls.mp_r, SettingsPage.controls.mp_r_val },
        { SettingsPage.controls.mp_g, SettingsPage.controls.mp_g_val },
        { SettingsPage.controls.mp_b, SettingsPage.controls.mp_b_val },
        { SettingsPage.controls.mp_a, SettingsPage.controls.mp_a_val },
        { SettingsPage.controls.mp_after_r, SettingsPage.controls.mp_after_r_val },
        { SettingsPage.controls.mp_after_g, SettingsPage.controls.mp_after_g_val },
        { SettingsPage.controls.mp_after_b, SettingsPage.controls.mp_after_b_val },
        { SettingsPage.controls.mp_after_a, SettingsPage.controls.mp_after_a_val },
        { SettingsPage.controls.p_buff_x, SettingsPage.controls.p_buff_x_val },
        { SettingsPage.controls.p_buff_y, SettingsPage.controls.p_buff_y_val },
        { SettingsPage.controls.p_debuff_x, SettingsPage.controls.p_debuff_x_val },
        { SettingsPage.controls.p_debuff_y, SettingsPage.controls.p_debuff_y_val },
        { SettingsPage.controls.t_buff_x, SettingsPage.controls.t_buff_x_val },
        { SettingsPage.controls.t_buff_y, SettingsPage.controls.t_buff_y_val },
        { SettingsPage.controls.t_debuff_x, SettingsPage.controls.t_debuff_x_val },
        { SettingsPage.controls.t_debuff_y, SettingsPage.controls.t_debuff_y_val },
        { SettingsPage.controls.aura_icon_size, SettingsPage.controls.aura_icon_size_val },
        { SettingsPage.controls.aura_x_gap, SettingsPage.controls.aura_x_gap_val },
        { SettingsPage.controls.aura_y_gap, SettingsPage.controls.aura_y_gap_val },
        { SettingsPage.controls.aura_per_row, SettingsPage.controls.aura_per_row_val },
        { SettingsPage.controls.plates_alpha, SettingsPage.controls.plates_alpha_val },
        { SettingsPage.controls.plates_width, SettingsPage.controls.plates_width_val },
        { SettingsPage.controls.plates_hp_h, SettingsPage.controls.plates_hp_h_val },
        { SettingsPage.controls.plates_mp_h, SettingsPage.controls.plates_mp_h_val },
        { SettingsPage.controls.plates_x_offset, SettingsPage.controls.plates_x_offset_val },
        { SettingsPage.controls.plates_max_dist, SettingsPage.controls.plates_max_dist_val },
        { SettingsPage.controls.plates_y_offset, SettingsPage.controls.plates_y_offset_val },
        { SettingsPage.controls.plates_bg_alpha, SettingsPage.controls.plates_bg_alpha_val },
        { SettingsPage.controls.plates_name_fs, SettingsPage.controls.plates_name_fs_val },
        { SettingsPage.controls.plates_guild_fs, SettingsPage.controls.plates_guild_fs_val },
        { SettingsPage.controls.ct_update_interval, SettingsPage.controls.ct_update_interval_val },
        { SettingsPage.controls.ct_icon_size, SettingsPage.controls.ct_icon_size_val },
        { SettingsPage.controls.ct_icon_spacing, SettingsPage.controls.ct_icon_spacing_val },
        { SettingsPage.controls.ct_max_icons, SettingsPage.controls.ct_max_icons_val },
        { SettingsPage.controls.ct_timer_fs, SettingsPage.controls.ct_timer_fs_val },
        { SettingsPage.controls.ct_label_fs, SettingsPage.controls.ct_label_fs_val },
        { SettingsPage.controls.ct_timer_r, SettingsPage.controls.ct_timer_r_val },
        { SettingsPage.controls.ct_timer_g, SettingsPage.controls.ct_timer_g_val },
        { SettingsPage.controls.ct_timer_b, SettingsPage.controls.ct_timer_b_val },
        { SettingsPage.controls.ct_label_r, SettingsPage.controls.ct_label_r_val },
        { SettingsPage.controls.ct_label_g, SettingsPage.controls.ct_label_g_val },
        { SettingsPage.controls.ct_label_b, SettingsPage.controls.ct_label_b_val },
        { SettingsPage.controls.ct_cache_timeout, SettingsPage.controls.ct_cache_timeout_val }
    }

    for _, pair in ipairs(sliderList) do
        local slider = pair[1]
        local valLabel = pair[2]
        if slider ~= nil and slider.SetHandler ~= nil then
            slider:SetHandler("OnSliderChanged", function(_, value)
                if valLabel ~= nil and valLabel.SetText ~= nil and type(value) == "number" then
                    valLabel:SetText(tostring(math.floor(value + 0.5)))
                end
                sliderChanged()
            end)
        end
    end

    local function bindValueLabelOnly(slider, valLabel)
        if slider ~= nil and slider.SetHandler ~= nil then
            slider:SetHandler("OnSliderChanged", function(_, value)
                if valLabel ~= nil and valLabel.SetText ~= nil and type(value) == "number" then
                    valLabel:SetText(tostring(math.floor(value + 0.5)))
                end
            end)
        end
    end

    bindValueLabelOnly(SettingsPage.controls.plates_guild_color_r, SettingsPage.controls.plates_guild_color_r_val)
    bindValueLabelOnly(SettingsPage.controls.plates_guild_color_g, SettingsPage.controls.plates_guild_color_g_val)
    bindValueLabelOnly(SettingsPage.controls.plates_guild_color_b, SettingsPage.controls.plates_guild_color_b_val)

    local checkboxList = {
        SettingsPage.controls.aura_enabled,
        SettingsPage.controls.aura_sort_vertical,
        SettingsPage.controls.name_visible,
        SettingsPage.controls.level_visible,
        SettingsPage.controls.large_hpmp,
        SettingsPage.controls.show_distance,
        SettingsPage.controls.alignment_grid_enabled,
        SettingsPage.controls.bar_colors_enabled,
        SettingsPage.controls.overlay_shadow,
        SettingsPage.controls.name_shadow,
        SettingsPage.controls.value_shadow,
        SettingsPage.controls.buff_windows_enabled,
        SettingsPage.controls.plates_enabled,
        SettingsPage.controls.plates_guild_only,
        SettingsPage.controls.plates_show_target,
        SettingsPage.controls.plates_show_player,
        SettingsPage.controls.plates_show_raid_party,
        SettingsPage.controls.plates_show_watchtarget,
        SettingsPage.controls.plates_show_mount,
        SettingsPage.controls.plates_show_guild,
        SettingsPage.controls.plates_click_shift,
        SettingsPage.controls.plates_click_ctrl,
        SettingsPage.controls.plates_anchor_tag,
        SettingsPage.controls.plates_bg_enabled,
        SettingsPage.controls.ct_enabled,
        SettingsPage.controls.ct_unit_enabled,
        SettingsPage.controls.ct_lock_position,
        SettingsPage.controls.ct_show_timer,
        SettingsPage.controls.ct_show_label
    }

    if SettingsPage.controls.ct_unit ~= nil and SettingsPage.controls.ct_unit.SetHandler ~= nil then
        SettingsPage.controls.ct_unit:SetHandler("OnSelChanged", function()
            local idx = GetComboBoxIndex1Based(SettingsPage.controls.ct_unit, #COOLDOWN_UNIT_KEYS)
            if idx == nil then
                return
            end
            SettingsPage.cooldown_unit_key = GetCooldownUnitKeyFromIndex(idx)
            SettingsPage.cooldown_buff_page = 1
            RefreshControls()
        end)
    end

    if SettingsPage.controls.plates_guild_color_add_target ~= nil and SettingsPage.controls.plates_guild_color_add_target.SetHandler ~= nil then
        SettingsPage.controls.plates_guild_color_add_target:SetHandler("OnClick", function()
            if SettingsPage.settings == nil then
                return
            end

            local guild = ""
            pcall(function()
                if api.Unit ~= nil and api.Unit.GetUnitId ~= nil and api.Unit.GetUnitInfoById ~= nil then
                    local id = api.Unit:GetUnitId("target")
                    if id ~= nil then
                        local info = api.Unit:GetUnitInfoById(id)
                        if type(info) == "table" and info.expeditionName ~= nil then
                            guild = tostring(info.expeditionName or "")
                        end
                    end
                end
            end)
            guild = tostring(guild or "")
            guild = string.match(guild, "^%s*(.-)%s*$") or guild
            if guild == "" then
                return
            end

            if type(SettingsPage.settings.nameplates) ~= "table" then
                SettingsPage.settings.nameplates = {}
            end
            if type(SettingsPage.settings.nameplates.guild_colors) ~= "table" then
                SettingsPage.settings.nameplates.guild_colors = {}
            end

            local r = GetSliderValue(SettingsPage.controls.plates_guild_color_r)
            local g = GetSliderValue(SettingsPage.controls.plates_guild_color_g)
            local b = GetSliderValue(SettingsPage.controls.plates_guild_color_b)
            local key = string.lower(guild)
            key = string.gsub(key, "%s+", "_")
            key = string.gsub(key, "[^%w_]", "")
            if key ~= "" and string.match(key, "^%d") ~= nil then
                key = "_" .. key
            end
            SettingsPage.settings.nameplates.guild_colors[key] = { (r or 255) / 255, (g or 255) / 255, (b or 255) / 255, 1 }

            pcall(function()
                if SettingsPage.controls.plates_guild_color_name ~= nil and SettingsPage.controls.plates_guild_color_name.SetText ~= nil then
                    SettingsPage.controls.plates_guild_color_name:SetText(guild)
                end
            end)

            if type(SettingsPage.on_apply) == "function" then
                pcall(function()
                    SettingsPage.on_apply()
                end)
            end
            if type(SettingsPage.on_save) == "function" then
                pcall(function()
                    SettingsPage.on_save()
                end)
            end
            RefreshControls()
        end)
    end

    if SettingsPage.controls.plates_guild_color_add ~= nil and SettingsPage.controls.plates_guild_color_add.SetHandler ~= nil then
        SettingsPage.controls.plates_guild_color_add:SetHandler("OnClick", function()
            if SettingsPage.settings == nil then
                return
            end
            if type(SettingsPage.settings.nameplates) ~= "table" then
                SettingsPage.settings.nameplates = {}
            end
            if type(SettingsPage.settings.nameplates.guild_colors) ~= "table" then
                SettingsPage.settings.nameplates.guild_colors = {}
            end

            local guild = GetEditText(SettingsPage.controls.plates_guild_color_name)
            guild = tostring(guild or "")
            guild = string.match(guild, "^%s*(.-)%s*$") or guild
            if guild == "" then
                return
            end

            local r = GetSliderValue(SettingsPage.controls.plates_guild_color_r)
            local g = GetSliderValue(SettingsPage.controls.plates_guild_color_g)
            local b = GetSliderValue(SettingsPage.controls.plates_guild_color_b)
            local key = string.lower(guild)
            key = string.gsub(key, "%s+", "_")
            key = string.gsub(key, "[^%w_]", "")
            if key ~= "" and string.match(key, "^%d") ~= nil then
                key = "_" .. key
            end
            SettingsPage.settings.nameplates.guild_colors[key] = { (r or 255) / 255, (g or 255) / 255, (b or 255) / 255, 1 }

            if type(SettingsPage.on_apply) == "function" then
                pcall(function()
                    SettingsPage.on_apply()
                end)
            end
            if type(SettingsPage.on_save) == "function" then
                pcall(function()
                    SettingsPage.on_save()
                end)
            end
            RefreshControls()
        end)
    end

    if type(SettingsPage.controls.plates_guild_color_rows) == "table" then
        for _, row in ipairs(SettingsPage.controls.plates_guild_color_rows) do
            if type(row) == "table" and row.remove ~= nil and row.remove.SetHandler ~= nil then
                local btn = row.remove
                btn:SetHandler("OnClick", function()
                    if SettingsPage.settings == nil or type(SettingsPage.settings.nameplates) ~= "table" then
                        return
                    end
                    if type(SettingsPage.settings.nameplates.guild_colors) ~= "table" then
                        return
                    end
                    local key = tostring(btn.__polar_guild_key or "")
                    if key == "" then
                        return
                    end
                    SettingsPage.settings.nameplates.guild_colors[key] = nil
                    if type(SettingsPage.on_apply) == "function" then
                        pcall(function()
                            SettingsPage.on_apply()
                        end)
                    end
                    if type(SettingsPage.on_save) == "function" then
                        pcall(function()
                            SettingsPage.on_save()
                        end)
                    end
                    RefreshControls()
                end)
            end
        end
    end

    if SettingsPage.controls.ct_scan_btn ~= nil and SettingsPage.controls.ct_scan_btn.SetHandler ~= nil then
        SettingsPage.controls.ct_scan_btn:SetHandler("OnClick", function()
            ScanTargetEffects()
            RefreshControls()
        end)
    end

    if type(SettingsPage.controls.ct_scan_rows) == "table" then
        for _, row in ipairs(SettingsPage.controls.ct_scan_rows) do
            if type(row) == "table" and row.add ~= nil and row.add.SetHandler ~= nil then
                local btn = row.add
                row.add:SetHandler("OnClick", function()
                    if SettingsPage.settings == nil then
                        return
                    end
                    local idx = tonumber(btn ~= nil and btn.__polar_scan_index or nil)
                    local entry = (type(SettingsPage.cooldown_scan_results) == "table") and SettingsPage.cooldown_scan_results[idx] or nil
                    if type(entry) ~= "table" then
                        return
                    end

                    EnsureCooldownTrackerTables(SettingsPage.settings)
                    local unit_key = tostring(SettingsPage.cooldown_unit_key or "player")
                    local unit_cfg = SettingsPage.settings.cooldown_tracker.units[unit_key]
                    if type(unit_cfg) ~= "table" or type(unit_cfg.tracked_buffs) ~= "table" then
                        return
                    end

                    local id = tostring(entry.id or "")
                    if id == "" then
                        return
                    end

                    local exists = false
                    for _, v in ipairs(unit_cfg.tracked_buffs) do
                        if tostring(v) == id then
                            exists = true
                            break
                        end
                    end
                    if not exists then
                        table.insert(unit_cfg.tracked_buffs, id)
                    end

                    if type(SettingsPage.on_apply) == "function" then
                        pcall(function()
                            SettingsPage.on_apply()
                        end)
                    end
                    RefreshControls()
                end)
            end
        end
    end

    if SettingsPage.controls.ct_add_buff ~= nil and SettingsPage.controls.ct_add_buff.SetHandler ~= nil then
        SettingsPage.controls.ct_add_buff:SetHandler("OnClick", function()
            if SettingsPage.settings == nil then
                return
            end
            EnsureCooldownTrackerTables(SettingsPage.settings)
            local unit_key = tostring(SettingsPage.cooldown_unit_key or "player")
            local unit_cfg = SettingsPage.settings.cooldown_tracker.units[unit_key]
            if type(unit_cfg) ~= "table" then
                return
            end
            local txt = GetEditText(SettingsPage.controls.ct_new_buff_id)
            txt = tostring(txt or "")
            txt = txt:gsub("%s+", "")
            if txt == "" then
                return
            end

            local exists = false
            for _, v in ipairs(unit_cfg.tracked_buffs) do
                if tostring(v) == txt then
                    exists = true
                    break
                end
            end
            if not exists then
                table.insert(unit_cfg.tracked_buffs, txt)
            end
            if SettingsPage.controls.ct_new_buff_id ~= nil and SettingsPage.controls.ct_new_buff_id.SetText ~= nil then
                SettingsPage.controls.ct_new_buff_id:SetText("")
            end
            if type(SettingsPage.on_apply) == "function" then
                pcall(function()
                    SettingsPage.on_apply()
                end)
            end
            RefreshControls()
        end)
    end

    if SettingsPage.controls.ct_prev_page ~= nil and SettingsPage.controls.ct_prev_page.SetHandler ~= nil then
        SettingsPage.controls.ct_prev_page:SetHandler("OnClick", function()
            SettingsPage.cooldown_buff_page = (tonumber(SettingsPage.cooldown_buff_page) or 1) - 1
            RefreshControls()
        end)
    end

    if SettingsPage.controls.ct_next_page ~= nil and SettingsPage.controls.ct_next_page.SetHandler ~= nil then
        SettingsPage.controls.ct_next_page:SetHandler("OnClick", function()
            SettingsPage.cooldown_buff_page = (tonumber(SettingsPage.cooldown_buff_page) or 1) + 1
            RefreshControls()
        end)
    end

    if type(SettingsPage.controls.ct_buff_rows) == "table" then
        for _, row in ipairs(SettingsPage.controls.ct_buff_rows) do
            if type(row) == "table" and row.remove ~= nil and row.remove.SetHandler ~= nil then
                local btn = row.remove
                row.remove:SetHandler("OnClick", function()
                    if SettingsPage.settings == nil then
                        return
                    end
                    EnsureCooldownTrackerTables(SettingsPage.settings)
                    local unit_key = tostring(SettingsPage.cooldown_unit_key or "player")
                    local unit_cfg = SettingsPage.settings.cooldown_tracker.units[unit_key]
                    if type(unit_cfg) ~= "table" or type(unit_cfg.tracked_buffs) ~= "table" then
                        return
                    end
                    local idx = tonumber(btn ~= nil and btn.__polar_buff_index or nil)
                    if idx == nil or idx < 1 or idx > #unit_cfg.tracked_buffs then
                        return
                    end
                    table.remove(unit_cfg.tracked_buffs, idx)
                    if type(SettingsPage.on_apply) == "function" then
                        pcall(function()
                            SettingsPage.on_apply()
                        end)
                    end
                    RefreshControls()
                end)
            end
        end
    end

    local function styleTargetChanged(ctrl, a, b)
        if SettingsPage._refreshing_style_target then
            return
        end
        if ctrl == SettingsPage.controls.style_target_text and SettingsPage.active_page ~= "text" then
            return
        end
        if ctrl == SettingsPage.controls.style_target_bars and SettingsPage.active_page ~= "bars" then
            return
        end
        if ctrl == nil then
            return
        end
        SettingsPage.style_target = GetStyleTargetKeyFromControl(ctrl, a, b)
        UpdateStyleTargetHints()
        RefreshControls()
    end

    if SettingsPage.controls.style_target_text ~= nil and SettingsPage.controls.style_target_text.SetHandler ~= nil then
        SettingsPage.controls.style_target_text:SetHandler("OnSelChanged", function(a, b)
            styleTargetChanged(SettingsPage.controls.style_target_text, a, b)
        end)
    end
    if SettingsPage.controls.style_target_bars ~= nil and SettingsPage.controls.style_target_bars.SetHandler ~= nil then
        SettingsPage.controls.style_target_bars:SetHandler("OnSelChanged", function(a, b)
            styleTargetChanged(SettingsPage.controls.style_target_bars, a, b)
        end)
    end

    for _, cb in ipairs(checkboxList) do
        if cb ~= nil and cb.SetHandler ~= nil then
            cb:SetHandler("OnClick", function()
                sliderChanged()
            end)
        end
    end

    applyBtn:SetHandler("OnClick", function()
        if SettingsPage.settings == nil then
            return
        end
        syncStyleTargetFromActivePage()
        ApplyControlsToSettings()
        if type(SettingsPage.on_save) == "function" then
            pcall(function()
                SettingsPage.on_save()
            end)
        end
        if type(SettingsPage.on_apply) == "function" then
            pcall(function()
                SettingsPage.on_apply()
            end)
        end
        RefreshControls()
    end)

    closeBtn:SetHandler("OnClick", function()
        closeHandler()
    end)

    if backupBtn ~= nil and backupBtn.SetHandler ~= nil then
        backupBtn:SetHandler("OnClick", function()
            if backupStatus ~= nil and backupStatus.SetText ~= nil then
                backupStatus:SetText("")
            end
            if type(SettingsPage.actions) ~= "table" or type(SettingsPage.actions.backup_settings) ~= "function" then
                if backupStatus ~= nil and backupStatus.SetText ~= nil then
                    backupStatus:SetText("Backup not available")
                end
                return
            end
            local ok, res1, res2 = pcall(function()
                return SettingsPage.actions.backup_settings()
            end)
            local success = ok and (res1 == true)
            local err = ""
            if ok then
                err = tostring(res2 or "")
            else
                err = tostring(res1)
            end
            if backupStatus ~= nil and backupStatus.SetText ~= nil then
                if success then
                    backupStatus:SetText("Backup saved")
                else
                    backupStatus:SetText("Backup failed: " .. err)
                end
            end
        end)
    end

    if importBtn ~= nil and importBtn.SetHandler ~= nil then
        importBtn:SetHandler("OnClick", function()
            if backupStatus ~= nil and backupStatus.SetText ~= nil then
                backupStatus:SetText("")
            end
            if type(SettingsPage.actions) ~= "table" or type(SettingsPage.actions.import_settings) ~= "function" then
                if backupStatus ~= nil and backupStatus.SetText ~= nil then
                    backupStatus:SetText("Import not available")
                end
                return
            end
            local ok, res1, res2 = pcall(function()
                return SettingsPage.actions.import_settings()
            end)
            local success = ok and (res1 == true)
            local err = ""
            if ok then
                err = tostring(res2 or "")
            else
                err = tostring(res1)
            end
            if backupStatus ~= nil and backupStatus.SetText ~= nil then
                if success then
                    backupStatus:SetText("Imported")
                else
                    backupStatus:SetText("Import failed: " .. err)
                end
            end
            RefreshControls()
        end)
    end

    RefreshControls()
end

function SettingsPage.init(settings, onSave, onApply, actions)
    SettingsPage.settings = settings
    SettingsPage.on_save = onSave
    SettingsPage.on_apply = onApply
    SettingsPage.actions = actions
    EnsureWindow()
    EnsureSettingsButton()
end

function SettingsPage.open()
    if SettingsPage.settings == nil then
        return
    end
    EnsureWindow()
    RefreshControls()
    SettingsPage.window:Show(true)
end

function SettingsPage.toggle()
    if SettingsPage.window == nil then
        SettingsPage.open()
        return
    end
    local want = true
    if SettingsPage.window.IsVisible ~= nil then
        local ok, res = pcall(function()
            return SettingsPage.window:IsVisible()
        end)
        if ok then
            want = not res
        end
    end
    if want then
        SettingsPage.open()
    else
        SettingsPage.window:Show(false)
    end
end

function SettingsPage.Unload()
    if SettingsPage.window ~= nil then
        pcall(function()
            SettingsPage.window:Show(false)
        end)
        pcall(function()
            if api ~= nil and api.Interface ~= nil and api.Interface.Free ~= nil then
                api.Interface:Free(SettingsPage.window)
            end
        end)
        SettingsPage.window = nil
    end
    if SettingsPage.toggle_button ~= nil and SettingsPage.toggle_button.Show ~= nil then
        pcall(function()
            SettingsPage.toggle_button:Show(false)
        end)
    end
    if SettingsPage.toggle_button ~= nil then
        pcall(function()
            if api ~= nil and api.Interface ~= nil and api.Interface.Free ~= nil then
                api.Interface:Free(SettingsPage.toggle_button)
            end
        end)
    end
    SettingsPage.toggle_button = nil
    SettingsPage.toggle_button_dragging = false
    SettingsPage.scroll_frame = nil
    SettingsPage.content = nil
    SettingsPage.pages = {}
    SettingsPage.page_heights = {}
    SettingsPage.nav = {}
    SettingsPage.controls = {}
end

return SettingsPage
