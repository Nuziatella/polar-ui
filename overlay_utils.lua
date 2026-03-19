local M = {}

M.ClampNumber = function(v, lo, hi, default)
    local n = tonumber(v)
    if n == nil then
        return default
    end
    if lo ~= nil and n < lo then
        return lo
    end
    if hi ~= nil and n > hi then
        return hi
    end
    return n
end

M.Percent01 = function(pct, default)
    local n = tonumber(pct)
    if n == nil then
        local d = tonumber(default)
        if d == nil then
            d = 100
        end
        if d < 0 then
            d = 0
        elseif d > 100 then
            d = 100
        end
        return d / 100
    end
    if n < 0 then
        n = 0
    elseif n > 100 then
        n = 100
    end
    return n / 100
end

M.SafeShow = function(wnd, show)
    if wnd == nil or wnd.Show == nil then
        return
    end
    pcall(function()
        wnd:Show(show and true or false)
    end)
end

M.SafeClickable = function(wnd, clickable)
    if wnd == nil or wnd.Clickable == nil then
        return
    end
    pcall(function()
        wnd:Clickable(clickable and true or false)
    end)
end

M.SafeSetAlpha = function(wnd, a01)
    if wnd == nil or wnd.SetAlpha == nil then
        return
    end
    pcall(function()
        wnd:SetAlpha(M.ClampNumber(a01, 0, 1, 1))
    end)
end

M.SafeSetBg = function(frame, enabled, alpha01)
    if frame == nil or frame.bg == nil then
        return
    end
    local bg = frame.bg
    pcall(function()
        if bg.Show ~= nil then
            bg:Show(enabled and true or false)
        end
    end)
    pcall(function()
        if bg.SetColor ~= nil then
            bg:SetColor(1, 1, 1, M.ClampNumber(alpha01, 0, 1, 0.8))
        end
    end)
end

return M
