local api = require("api")

local quests = nil

do
    local ok, mod = pcall(require, "polar-ui/dailyage_quests")
    if ok then
        quests = mod
    else
        ok, mod = pcall(require, "polar-ui.dailyage_quests")
        if ok then
            quests = mod
        end
    end
end

local DailyAge = {
    wnd = nil,
    overlay_btn = nil,
    quest_window = nil,
    quest_list = nil,
    quest_search = nil,
    _last_enabled = nil,
    _clock_ms = 0,
}

local function tolower_safe(s)
    return string.lower(tostring(s or ""))
end

local function ensureSettings(settings)
    if type(settings) ~= "table" then
        return nil
    end
    if type(settings.dailyage) ~= "table" then
        settings.dailyage = {}
    end
    if settings.dailyage.enabled == nil then
        settings.dailyage.enabled = false
    end
    if type(settings.dailyage.hidden) ~= "table" then
        settings.dailyage.hidden = {}
    end
    return settings.dailyage
end

local function normalizeHiddenTable(hidden)
    if type(hidden) ~= "table" then
        return {}
    end
    local out = {}
    for k, v in pairs(hidden) do
        local id = nil
        if type(k) == "number" then
            id = math.floor(k + 0.5)
        else
            id = tonumber(k)
            if id ~= nil then
                id = math.floor(id + 0.5)
            end
        end
        if id ~= nil then
            out[id] = v and true or false
        end
    end
    return out
end

local function hiddenSignature(hidden)
    local norm = normalizeHiddenTable(hidden)
    local ids = {}
    for id, v in pairs(norm) do
        if v then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function safeGetQuestTitle(id)
    if api == nil or api.Quest == nil then
        return tostring(id)
    end
    local ok, title = pcall(function()
        return api.Quest:GetQuestContextMainTitle(id)
    end)
    if ok and type(title) == "string" and title ~= "" then
        return title
    end
    return tostring(id)
end

local function isQuestCompleted(id)
    if api == nil or api.Quest == nil or api.Quest.IsCompleted == nil then
        return false
    end
    local ok, done = pcall(function()
        return api.Quest:IsCompleted(id)
    end)
    if ok then
        return done and true or false
    end
    return false
end

local function isAnyQuestIdCompleted(ids)
    if type(ids) ~= "table" then
        return false
    end
    for _, qid in ipairs(ids) do
        if isQuestCompleted(qid) then
            return true
        end
    end
    return false
end

local function getScrollListCtrl()
    if W_CTRL == nil or W_CTRL.CreatePageScrollListCtrl == nil then
        return nil
    end
    local ok, ctrl = pcall(function()
        return W_CTRL.CreatePageScrollListCtrl("polarUiDailyAgeQuestScrollList", DailyAge.quest_window)
    end)
    if ok then
        return ctrl
    end
    return nil
end

local function refreshQuestList(settings, searchText)
    if DailyAge.quest_list == nil then
        return
    end

    local cfg = ensureSettings(settings)
    if cfg == nil then
        return
    end

    local hidden = normalizeHiddenTable(cfg.hidden)
    DailyAge.quest_list:DeleteAllDatas()

    local count = 1
    local search = tolower_safe(searchText)
    local haveSearch = search ~= "" and #search > 2

    local function maybeInsert(ids, displayId)
        local id_num = tonumber(displayId)
        if id_num == nil then
            return
        end
        id_num = math.floor(id_num + 0.5)
        if hidden[id_num] then
            return
        end

        local title = safeGetQuestTitle(id_num)
        if haveSearch and string.find(tolower_safe(title), search, 1, true) == nil then
            return
        end

        local data = {
            id = id_num,
            questId = id_num,
            questTitle = title,
            isCompleted = isAnyQuestIdCompleted(ids),
            isViewData = true,
            isAbstention = false,
        }
        DailyAge.quest_list:InsertData(count, 1, data, false)
        count = count + 1
    end

    if type(quests) == "table" then
        for _, questIds in ipairs(quests) do
            if type(questIds) == "table" and questIds[1] ~= nil then
                maybeInsert(questIds, questIds[1])
            end
        end
    end

    maybeInsert({ 9000011 }, 9000011)

    local dsDone = isQuestCompleted(9000009) or isQuestCompleted(9000008) or isQuestCompleted(9000007)
    local dsData = {
        id = 9000009,
        questId = 9000009,
        questTitle = safeGetQuestTitle(9000009),
        isCompleted = dsDone,
        isViewData = true,
        isAbstention = false,
    }

    if not (hidden[tostring(dsData.id)] and true or false) then
        if not haveSearch or string.find(tolower_safe(dsData.questTitle), search, 1, true) ~= nil then
            DailyAge.quest_list:InsertData(count, 1, dsData, false)
        end
    end
end

local function ensureUi(settings)
    local cfg = ensureSettings(settings)
    if cfg == nil then
        return
    end

    if DailyAge.wnd == nil then
        if api.Interface == nil or api.Interface.CreateEmptyWindow == nil then
            return
        end
        local ok, wnd = pcall(function()
            return api.Interface:CreateEmptyWindow("polarUiDailyAgeRoot")
        end)
        if ok then
            DailyAge.wnd = wnd
        end

        if DailyAge.wnd ~= nil and DailyAge.wnd.Show ~= nil then
            pcall(function()
                DailyAge.wnd:Show(true)
            end)
        end
    end

    if DailyAge.wnd == nil then
        return
    end

    if DailyAge.overlay_btn == nil and DailyAge.wnd.CreateChildWidget ~= nil then
        local btn = DailyAge.wnd:CreateChildWidget("button", "polarUiDailyAgeOverlayBtn", 0, true)
        btn:SetExtent(40, 26)
        btn:SetText("D")
        pcall(function()
            if api.Interface ~= nil and api.Interface.ApplyButtonSkin ~= nil and BUTTON_BASIC ~= nil then
                api.Interface:ApplyButtonSkin(btn, BUTTON_BASIC.DEFAULT)
            end
        end)
        pcall(function()
            if btn.style ~= nil and btn.style.SetFontSize ~= nil then
                btn.style:SetFontSize(13)
            end
        end)
        pcall(function()
            if btn.SetTextColor ~= nil and FONT_COLOR ~= nil and FONT_COLOR.WHITE ~= nil then
                btn:SetTextColor(FONT_COLOR.WHITE[1], FONT_COLOR.WHITE[2], FONT_COLOR.WHITE[3], FONT_COLOR.WHITE[4])
            end
            if btn.SetHighlightTextColor ~= nil and FONT_COLOR ~= nil and FONT_COLOR.WHITE ~= nil then
                btn:SetHighlightTextColor(FONT_COLOR.WHITE[1], FONT_COLOR.WHITE[2], FONT_COLOR.WHITE[3], FONT_COLOR.WHITE[4])
            end
            if btn.SetPushedTextColor ~= nil and FONT_COLOR ~= nil and FONT_COLOR.WHITE ~= nil then
                btn:SetPushedTextColor(FONT_COLOR.WHITE[1], FONT_COLOR.WHITE[2], FONT_COLOR.WHITE[3], FONT_COLOR.WHITE[4])
            end
            if btn.SetDisabledTextColor ~= nil and FONT_COLOR ~= nil and FONT_COLOR.WHITE ~= nil then
                btn:SetDisabledTextColor(FONT_COLOR.WHITE[1], FONT_COLOR.WHITE[2], FONT_COLOR.WHITE[3], FONT_COLOR.WHITE[4])
            end
        end)
        pcall(function()
            if btn.RemoveAllAnchors ~= nil then
                btn:RemoveAllAnchors()
            end
        end)

        pcall(function()
            if btn.AddAnchor ~= nil then
                local ok = pcall(function()
                    btn:AddAnchor("TOP", "UIParent", 0, 10)
                end)
                if not ok then
                    pcall(function()
                        btn:AddAnchor("TOP", 0, 10)
                    end)
                end
            end
        end)
        pcall(function()
            if btn.Show ~= nil then
                btn:Show(true)
            end
        end)

        btn:SetHandler("OnClick", function()
            if DailyAge.quest_window == nil then
                return
            end
            local visible = false
            pcall(function()
                visible = DailyAge.quest_window:IsVisible() and true or false
            end)
            pcall(function()
                DailyAge.quest_window:Show(not visible)
            end)
        end)

        DailyAge.overlay_btn = btn
    end

    if DailyAge.quest_window == nil then
        if api.Interface == nil or api.Interface.CreateWindow == nil then
            return
        end

        local ok, w = pcall(function()
            return api.Interface:CreateWindow("polarUiDailyAgeQuestListWindow", "Dailies")
        end)
        if ok then
            DailyAge.quest_window = w
        end

        if DailyAge.quest_window ~= nil then
            pcall(function()
                DailyAge.quest_window:AddAnchor("CENTER", "UIParent", 0, 0)
                DailyAge.quest_window:SetExtent(430, 600)
                DailyAge.quest_window:Show(false)
            end)

            local function DataSetFunc(subItem, data, setValue)
                if not setValue or type(data) ~= "table" then
                    return
                end
                subItem.questId = data.id
                subItem.questTitle = data.questTitle
                subItem.isCompleted = data.isCompleted
                subItem.textbox:SetText(data.questTitle)

                if subItem.isCompleted then
                    ApplyTextColor(subItem.textbox, FONT_COLOR.GREEN)
                else
                    ApplyTextColor(subItem.textbox, FONT_COLOR.RED)
                end
            end

            local function LayoutSetFunc(_, _, _, subItem)
                subItem:SetExtent(300, 25)
                local textbox = subItem:CreateChildWidget("textbox", "textbox", 0, true)
                textbox:AddAnchor("TOPLEFT", subItem, 15, 0)
                textbox:AddAnchor("BOTTOMRIGHT", subItem, 0, 0)
                textbox.style:SetAlign(ALIGN.LEFT)
                ApplyTextColor(textbox, FONT_COLOR.GREEN)
                subItem.textbox = textbox
            end

            DailyAge.quest_list = getScrollListCtrl()
            if DailyAge.quest_list ~= nil then
                local list = DailyAge.quest_list
                pcall(function()
                    if list.AddAnchor ~= nil then
                        list:AddAnchor("TOPLEFT", DailyAge.quest_window, -10, 40)
                        list:AddAnchor("BOTTOMRIGHT", DailyAge.quest_window, -10, -10)
                    end
                end)
                pcall(function()
                    if list.scroll ~= nil and list.scroll.AddAnchor ~= nil then
                        list.scroll:AddAnchor("TOPRIGHT", list, 0, 0)
                        list.scroll:AddAnchor("BOTTOMRIGHT", list, 0, 0)
                    end
                end)
                pcall(function()
                    if list.pageControl ~= nil and list.pageControl.Show ~= nil then
                        list.pageControl:Show(false)
                    end
                end)
                pcall(function()
                    if list.InsertColumn ~= nil then
                        list:InsertColumn("", 300, 0, DataSetFunc, nil, nil, LayoutSetFunc)
                    end
                    if list.InsertRows ~= nil then
                        list:InsertRows(25, true)
                    end
                    if list.SetColumnHeight ~= nil then
                        list:SetColumnHeight(40)
                    end
                end)
            end

            if W_CTRL ~= nil and W_CTRL.CreateEdit ~= nil then
                local edit = W_CTRL.CreateEdit("polarUiDailyAgeQuestSearch", DailyAge.quest_window)
                edit:SetExtent(280, 24)
                if DailyAge.quest_list ~= nil then
                    edit:AddAnchor("TOPLEFT", DailyAge.quest_list, 140, 10)
                else
                    edit:AddAnchor("TOPLEFT", DailyAge.quest_window, 140, 10)
                end
                edit.style:SetFontSize(FONT_SIZE.XLARGE)

                local label = edit:CreateChildWidget("label", "polarUiDailyAgeQuestSearchLabel", 0, true)
                label:SetText("Quest Name:")
                label.style:SetAlign(ALIGN.RIGHT)
                label.style:SetFontSize(FONT_SIZE.XLARGE)
                ApplyTextColor(label, FONT_COLOR.DEFAULT)
                label:AddAnchor("TOPRIGHT", edit, "LEFT", 0, 0)

                edit:SetHandler("OnTextChanged", function()
                    local text = edit:GetText()
                    refreshQuestList(settings, text)
                end)
                DailyAge.quest_search = edit
            end

            refreshQuestList(settings, "")
        end
    end

    local show = cfg.enabled and true or false
    if DailyAge.overlay_btn ~= nil and DailyAge.overlay_btn.Show ~= nil then
        pcall(function()
            DailyAge.overlay_btn:Show(show)
        end)
    end
    if not show and DailyAge.quest_window ~= nil then
        pcall(function()
            DailyAge.quest_window:Show(false)
        end)
    end
end

function DailyAge.Init(settings)
    ensureUi(settings)
end

function DailyAge.Unload()
    if DailyAge.quest_window ~= nil and DailyAge.quest_window.Show ~= nil then
        pcall(function()
            DailyAge.quest_window:Show(false)
        end)
    end
    if DailyAge.overlay_btn ~= nil and DailyAge.overlay_btn.Show ~= nil then
        pcall(function()
            DailyAge.overlay_btn:Show(false)
        end)
    end
    pcall(function()
        if api.Interface ~= nil and api.Interface.Free ~= nil and DailyAge.quest_window ~= nil then
            api.Interface:Free(DailyAge.quest_window)
        end
    end)
    pcall(function()
        if api.Interface ~= nil and api.Interface.Free ~= nil and DailyAge.wnd ~= nil then
            api.Interface:Free(DailyAge.wnd)
        end
    end)
    DailyAge.overlay_btn = nil
    DailyAge.quest_window = nil
    DailyAge.wnd = nil
end

function DailyAge.OnUpdate(settings, dt)
    local cfg = ensureSettings(settings)
    if cfg == nil or not cfg.enabled then
        return
    end

    ensureUi(settings)

    if DailyAge.quest_window == nil or DailyAge.quest_window.IsVisible == nil then
        return
    end

    local visible = false
    pcall(function()
        visible = DailyAge.quest_window:IsVisible() and true or false
    end)

    if visible then
        local searchText = ""
        if DailyAge.quest_search ~= nil and DailyAge.quest_search.GetText ~= nil then
            pcall(function()
                searchText = DailyAge.quest_search:GetText() or ""
            end)
        end

        local searchSig = string.lower(tostring(searchText or ""))
        local hiddenSig = hiddenSignature(cfg.hidden)

        if DailyAge._last_search_sig ~= searchSig or DailyAge._last_hidden_sig ~= hiddenSig then
            DailyAge._last_search_sig = searchSig
            DailyAge._last_hidden_sig = hiddenSig
            refreshQuestList(settings, searchText)
        end
        if DailyAge.quest_list ~= nil and DailyAge.quest_list.UpdateView ~= nil then
            pcall(function()
                DailyAge.quest_list:UpdateView()
            end)
        end
    else
        DailyAge._clock_ms = (DailyAge._clock_ms or 0) + (tonumber(dt) or 0)
        if DailyAge._clock_ms > 1000 then
            DailyAge._clock_ms = 0
            local text = ""
            if DailyAge.quest_search ~= nil and DailyAge.quest_search.GetText ~= nil then
                pcall(function()
                    text = DailyAge.quest_search:GetText() or ""
                end)
            end
            refreshQuestList(settings, text)
        end
    end
end

return DailyAge
