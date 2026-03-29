local api = require("api")

local Runtime = {}

local function trim(value)
    return (tostring(value or ""):gsub("^%s*(.-)%s*$", "%1"))
end

function Runtime.GetUnitId(unit)
    if api == nil or api.Unit == nil or api.Unit.GetUnitId == nil then
        return nil
    end
    local ok, value = pcall(function()
        return api.Unit:GetUnitId(unit)
    end)
    if ok then
        return value
    end
    return nil
end

function Runtime.GetUnitName(unit)
    if api ~= nil and api.Unit ~= nil and api.Unit.GetUnitName ~= nil then
        local ok, value = pcall(function()
            return api.Unit:GetUnitName(unit)
        end)
        value = trim(value)
        if ok and value ~= "" then
            return value
        end
    end

    local unitId = Runtime.GetUnitId(unit)
    if unitId ~= nil and api ~= nil and api.Unit ~= nil and api.Unit.GetUnitNameById ~= nil then
        local ok, value = pcall(function()
            return api.Unit:GetUnitNameById(unitId)
        end)
        value = trim(value)
        if ok and value ~= "" then
            return value
        end
    end

    if api ~= nil and api.Unit ~= nil and api.Unit.UnitInfo ~= nil then
        local ok, info = pcall(function()
            return api.Unit:UnitInfo(unit)
        end)
        if ok and type(info) == "table" then
            local value = trim(info.name)
            if value ~= "" then
                return value
            end
        end
    end

    return ""
end

function Runtime.GetUnitNameById(unitId)
    if unitId == nil or api == nil or api.Unit == nil or api.Unit.GetUnitNameById == nil then
        return ""
    end
    local ok, value = pcall(function()
        return api.Unit:GetUnitNameById(unitId)
    end)
    value = trim(value)
    if ok and value ~= "" then
        return value
    end
    return ""
end

function Runtime.GetPlayerName()
    return Runtime.GetUnitName("player")
end

function Runtime.GetStockContent(contentId)
    if contentId == nil or ADDON == nil or ADDON.GetContent == nil then
        return nil
    end
    local ok, value = pcall(function()
        return ADDON:GetContent(contentId)
    end)
    if ok then
        return value
    end
    return nil
end

return Runtime
