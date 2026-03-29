local api = require("api")

local UI = nil
local SettingsPage = nil
local Compat = nil
local Runtime = nil
do
    local ok, mod = pcall(require, "polar-ui/ui")
    if ok then
        UI = mod
    else
        ok, mod = pcall(require, "polar-ui.ui")
        if ok then
            UI = mod
        end

    end
end

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

do
    local ok, mod = pcall(require, "polar-ui/runtime")
    if ok then
        Runtime = mod
    else
        ok, mod = pcall(require, "polar-ui.runtime")
        if ok then
            Runtime = mod
        end
    end
end

local TryMigrateCooldownTrackerFromCbt = nil
local SaveSettingsFile = nil

do
    local ok, mod = pcall(require, "polar-ui/settings_page")
    if ok then
        SettingsPage = mod
    else
        ok, mod = pcall(require, "polar-ui.settings_page")
        if ok then
            SettingsPage = mod
        end
    end
end

local PolarUiAddon = {
    name = "Polar UI",
    author = "Nuzi",
    version = "0.9.3",
    desc = "Interface overhaul"
}

local SETTINGS_FILE_PATH = "polar-ui/settings.txt"
local SETTINGS_BACKUP_FILE_PATH = "polar-ui/settings_backup.txt"
local SETTINGS_BACKUP_INDEX_FILE_PATH = "polar-ui/backups/index.txt"
local SETTINGS_BACKUP_INDEX_FALLBACK_FILE_PATH = "polar-ui/settings_backup_index.txt"
local SETTINGS_BACKUP_DIR = "polar-ui/backups"

local ADDONS_BASE_PATH = nil
pcall(function()
    if type(api) == "table" and type(api.baseDir) == "string" and api.baseDir ~= "" then
        ADDONS_BASE_PATH = string.gsub(api.baseDir, "\\", "/")
        return
    end
    if type(debug) == "table" and type(debug.getinfo) == "function" then
        local info = debug.getinfo(1, "S")
        local src = type(info) == "table" and tostring(info.source or "") or ""
        if string.sub(src, 1, 1) == "@" then
            src = string.sub(src, 2)
        end
        src = string.gsub(src, "\\", "/")
        local dir = string.match(src, "^(.*)/[^/]+$")
        if dir ~= nil then
            local base = string.match(dir, "^(.*)/[^/]+$")
            if base ~= nil and base ~= "" then
                ADDONS_BASE_PATH = base
            end
        end
    end
end)

local function ReadRawFileFallback(path)
    if ADDONS_BASE_PATH == nil or type(io) ~= "table" or type(io.open) ~= "function" then
        return nil, false, false
    end
    local full = tostring(ADDONS_BASE_PATH) .. "/" .. tostring(path)
    full = string.gsub(full, "/+", "/")
    local file = nil
    local ok = pcall(function()
        file = io.open(full, "rb")
    end)
    if not ok or file == nil then
        return nil, false, true
    end
    local contents = nil
    pcall(function()
        contents = file:read("*a")
    end)
    pcall(function()
        file:close()
    end)
    if type(contents) ~= "string" then
        return nil, true, true
    end
    if contents == "" then
        return nil, true, true
    end
    return contents, true, true
end

local DEFAULT_SETTINGS = {
    enabled = true,
    drag_requires_shift = true,
    update_interval_ms = 100,
    frame_scale = 1,
    alignment_grid_enabled = false,
    dailyage = {
        enabled = false,
        hidden = {}
    },
    cooldown_tracker = {
        enabled = false,
        update_interval_ms = 50,
        migrated_from_cbt = false,
        units = {
            player = {
                enabled = false,
                pos_x = 330,
                pos_y = 100,
                icon_size = 40,
                icon_spacing = 5,
                max_icons = 10,
                lock_position = false,
                show_timer = true,
                timer_font_size = 16,
                timer_color = { 1, 1, 1, 1 },
                show_label = false,
                label_font_size = 14,
                label_color = { 1, 1, 1, 1 },
                tracked_buffs = {}
            },
            target = {
                enabled = false,
                pos_x = 330,
                pos_y = 170,
                icon_size = 40,
                icon_spacing = 5,
                max_icons = 10,
                lock_position = false,
                show_timer = true,
                timer_font_size = 16,
                timer_color = { 1, 1, 1, 1 },
                show_label = false,
                label_font_size = 14,
                label_color = { 1, 1, 1, 1 },
                cache_timeout_s = 300,
                tracked_buffs = {}
            },
            playerpet = {
                enabled = false,
                pos_x = 330,
                pos_y = 30,
                icon_size = 40,
                icon_spacing = 5,
                max_icons = 10,
                lock_position = false,
                show_timer = true,
                timer_font_size = 16,
                timer_color = { 1, 1, 1, 1 },
                show_label = false,
                label_font_size = 14,
                label_color = { 1, 1, 1, 1 },
                tracked_buffs = {}
            },
            watchtarget = {
                enabled = false,
                pos_x = 330,
                pos_y = 240,
                icon_size = 40,
                icon_spacing = 5,
                max_icons = 10,
                lock_position = false,
                show_timer = true,
                timer_font_size = 16,
                timer_color = { 1, 1, 1, 1 },
                show_label = false,
                label_font_size = 14,
                label_color = { 1, 1, 1, 1 },
                tracked_buffs = {}
            },
            target_of_target = {
                enabled = false,
                pos_x = 330,
                pos_y = 310,
                icon_size = 40,
                icon_spacing = 5,
                max_icons = 10,
                lock_position = false,
                show_timer = true,
                timer_font_size = 16,
                timer_color = { 1, 1, 1, 1 },
                show_label = false,
                label_font_size = 14,
                label_color = { 1, 1, 1, 1 },
                tracked_buffs = {}
            }
        }
    },
    nameplates = {
        enabled = false,
        guild_only = false,
        guild_colors = {},
        show_raid_party = true,
        show_watchtarget = true,
        show_mount = true,
        show_target = true,
        show_player = false,
        show_guild = true,
        click_through_shift = true,
        click_through_ctrl = true,
        alpha_pct = 100,
        width = 100,
        hp_height = 28,
        mp_height = 4,
        max_distance = 130,
        x_offset = 0,
        y_offset = 22,
        anchor_to_nametag = true,
        bg_enabled = true,
        bg_alpha_pct = 80,
        name_font_size = 14,
        guild_font_size = 11
    },
    style = {
        large_hpmp = true,
        hp_font_size = 16,
        mp_font_size = 11,
        overlay_font_size = 12,
        overlay_alpha = 1,
        overlay_shadow = true,
        gs_font_size = 12,
        class_font_size = 12,
        role_font_size = 12,
        target_guild_font_size = 12,
        target_guild_offset_x = 10,
        target_guild_offset_y = -54,
        name_font_size = 14,
        name_shadow = true,
        name_visible = true,
        name_offset_x = 0,
        name_offset_y = 0,
        level_visible = true,
        level_font_size = 12,
        level_offset_x = 0,
        level_offset_y = 0,
        value_shadow = true,
        hp_value_offset_x = 0,
        hp_value_offset_y = 0,
        mp_value_offset_x = 0,
        mp_value_offset_y = 0,
        value_format = "stock",
        short_numbers = false,
        bar_colors_enabled = false,
        hp_bar_height = 18,
        mp_bar_height = 18,
        bar_gap = 0,
        hp_bar_color = { 223, 69, 69, 255 },
        mp_bar_color = { 86, 198, 239, 255 },
        hp_fill_color = { 223, 69, 69, 255 },
        hp_after_color = { 223, 69, 69, 255 },
        mp_fill_color = { 86, 198, 239, 255 },
        mp_after_color = { 86, 198, 239, 255 },
        hp_texture_mode = "stock",
        buff_windows = {
            enabled = false,
            player = {
                buff = {
                    anchor = "TOPLEFT",
                    x = 0,
                    y = -42
                },
                debuff = {
                    anchor = "TOPLEFT",
                    x = 0,
                    y = -66
                }
            },
            target = {
                buff = {
                    anchor = "TOPLEFT",
                    x = 0,
                    y = -42
                },
                debuff = {
                    anchor = "TOPLEFT",
                    x = 0,
                    y = -66
                }
            }
        },
        aura = {
            enabled = false,
            icon_size = 24,
            icon_x_gap = 2,
            icon_y_gap = 2,
            buffs_per_row = 10,
            sort_vertical = false
        },
        frames = {
            player = {},
            target = {},
            watchtarget = {},
            target_of_target = {}
        }
    },
    player = {
        x = 10,
        y = 300
    },
    target = {
        x = 10,
        y = 380
    },
    frame_width = 320,
    frame_height = 64,
    bar_height = 18,
    font_size_value = 12,
    show_distance = true,
    frame_alpha = 1,
    role = {
        tanks = {
            "Abolisher",
            "Skullknight"
        },
        healers = {
            "Cleric",
            "Hierophant"
        }
    }
}

local settings = nil

local lastSettingsLoadSource = ""
local lastSettingsLoadError = ""

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

local function CopyDefaultValue(value)
    if type(value) == "table" then
        return DeepCopyTable(value)
    end
    return value
end

local function MergeInto(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return
    end

    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            MergeInto(dst[k], v)
        elseif v ~= nil then
            dst[k] = v
        end
    end
end

local function EnsureCooldownTrackerDefaults(s)
    if type(s) ~= "table" then
        return
    end

    if type(s.cooldown_tracker) ~= "table" then
        s.cooldown_tracker = {}
    end
    if type(s.cooldown_tracker.units) ~= "table" then
        s.cooldown_tracker.units = {}
    end

    for k, v in pairs(DEFAULT_SETTINGS.cooldown_tracker) do
        if s.cooldown_tracker[k] == nil then
            s.cooldown_tracker[k] = CopyDefaultValue(v)
        end
    end

    local function ensureUnit(key)
        if type(s.cooldown_tracker.units[key]) ~= "table" then
            s.cooldown_tracker.units[key] = {}
        end
        for k, v in pairs(DEFAULT_SETTINGS.cooldown_tracker.units[key]) do
            if s.cooldown_tracker.units[key][k] == nil then
                s.cooldown_tracker.units[key][k] = CopyDefaultValue(v)
            end
        end
        if type(s.cooldown_tracker.units[key].tracked_buffs) ~= "table" then
            s.cooldown_tracker.units[key].tracked_buffs = {}
        end
    end

    ensureUnit("player")
    ensureUnit("target")
    ensureUnit("playerpet")
    ensureUnit("watchtarget")
    ensureUnit("target_of_target")
end

local function EnsureDailyAgeDefaults(s)
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

local function ReadSettingsFromFile(path)
    local source = ""
    local err = ""

    if api.File == nil or api.File.Read == nil then
        return nil, "file:unavailable", ""
    end

    local ok, res = pcall(function()
        return api.File:Read(path)
    end)
    if not ok then
        source = "file:read_error"
        err = tostring(res)
        return nil, source, err
    end

    if res == nil then
        local raw, exists, probed = ReadRawFileFallback(path)
        if type(raw) == "string" then
            return nil, "file:legacy_text", "legacy text settings are no longer executed; resave via api.File:Write"
        elseif probed and exists then
            return nil, "file:unreadable", ""
        elseif probed then
            return nil, "file:missing", ""
        else
            return nil, "file:nil", ""
        end
    end
    if type(res) == "table" then
        return res, "file:table", ""
    end
    if type(res) ~= "string" then
        return nil, "file:unknown_type", ""
    end
    return nil, "file:string", "string settings are unsupported; expected api.File:Read to deserialize a table"
end

local function EnsureSettingsDefaultsAndMigrations(s)
    local forceWrite = false
    local legacyRootKeys = {
        "font_size_name",
        "show_mana"
    }

    local function NormalizeGuildKey(raw)
        local k = tostring(raw or "")
        k = string.match(k, "^%s*(.-)%s*$") or k
        k = string.lower(k)
        k = string.gsub(k, "%s+", "_")
        k = string.gsub(k, "[^%w_]", "")
        if k ~= "" and string.match(k, "^%d") ~= nil then
            k = "_" .. k
        end
        return k
    end

    for k, v in pairs(DEFAULT_SETTINGS) do
        if s[k] == nil then
            s[k] = CopyDefaultValue(v)
        end
    end

    for _, key in ipairs(legacyRootKeys) do
        if s[key] ~= nil then
            s[key] = nil
            forceWrite = true
        end
    end

    if type(s.player) ~= "table" then
        s.player = DeepCopyTable(DEFAULT_SETTINGS.player)
    end
    if type(s.target) ~= "table" then
        s.target = DeepCopyTable(DEFAULT_SETTINGS.target)
    end
    if type(s.nameplates) ~= "table" then
        s.nameplates = DeepCopyTable(DEFAULT_SETTINGS.nameplates)
    end
    if type(s.style) ~= "table" then
        s.style = DeepCopyTable(DEFAULT_SETTINGS.style)
    end

    EnsureCooldownTrackerDefaults(s)
    if type(TryMigrateCooldownTrackerFromCbt) == "function" and TryMigrateCooldownTrackerFromCbt(s) then
        EnsureCooldownTrackerDefaults(s)
        forceWrite = true
    end

    EnsureDailyAgeDefaults(s)

    for k, v in pairs(DEFAULT_SETTINGS.nameplates) do
        if s.nameplates[k] == nil then
            s.nameplates[k] = CopyDefaultValue(v)
        end
    end

    if type(s.nameplates.guild_colors) ~= "table" then
        s.nameplates.guild_colors = {}
    end

    do
        local gc = s.nameplates.guild_colors
        local migrated = false
        local moves = {}
        for k, v in pairs(gc) do
            local kstr = tostring(k or "")
            local norm = NormalizeGuildKey(kstr)
            if norm ~= "" and norm ~= kstr then
                table.insert(moves, { from = k, to = norm, val = v })
            end
        end
        for _, m in ipairs(moves) do
            if gc[m.to] == nil then
                gc[m.to] = m.val
                migrated = true
            end
            gc[m.from] = nil
        end
        if migrated then
            forceWrite = true
        end
    end

    if s.raidframes ~= nil then
        s.raidframes = nil
        forceWrite = true
    end

    for k, v in pairs(DEFAULT_SETTINGS.style) do
        if s.style[k] == nil then
            s.style[k] = CopyDefaultValue(v)
        end
    end

    if type(s.style.buff_windows) ~= "table" then
        s.style.buff_windows = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows)
    end
    if type(s.style.aura) ~= "table" then
        s.style.aura = DeepCopyTable(DEFAULT_SETTINGS.style.aura)
    end
    for k, v in pairs(DEFAULT_SETTINGS.style.buff_windows) do
        if s.style.buff_windows[k] == nil then
            s.style.buff_windows[k] = CopyDefaultValue(v)
        end
    end
    for k, v in pairs(DEFAULT_SETTINGS.style.aura) do
        if s.style.aura[k] == nil then
            s.style.aura[k] = CopyDefaultValue(v)
        end
    end
    if type(s.style.buff_windows.player) ~= "table" then
        s.style.buff_windows.player = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows.player)
    end
    if type(s.style.buff_windows.target) ~= "table" then
        s.style.buff_windows.target = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows.target)
    end
    if type(s.style.buff_windows.player.buff) ~= "table" then
        s.style.buff_windows.player.buff = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows.player.buff)
    end
    if type(s.style.buff_windows.player.debuff) ~= "table" then
        s.style.buff_windows.player.debuff = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows.player.debuff)
    end
    if type(s.style.buff_windows.target.buff) ~= "table" then
        s.style.buff_windows.target.buff = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows.target.buff)
    end
    if type(s.style.buff_windows.target.debuff) ~= "table" then
        s.style.buff_windows.target.debuff = DeepCopyTable(DEFAULT_SETTINGS.style.buff_windows.target.debuff)
    end

    if type(s.style.frames) ~= "table" then
        s.style.frames = DeepCopyTable(DEFAULT_SETTINGS.style.frames)
    end
    if type(s.style.frames.player) ~= "table" then
        s.style.frames.player = DeepCopyTable(DEFAULT_SETTINGS.style.frames.player)
    end
    if type(s.style.frames.target) ~= "table" then
        s.style.frames.target = DeepCopyTable(DEFAULT_SETTINGS.style.frames.target)
    end
    if type(s.style.frames.watchtarget) ~= "table" then
        s.style.frames.watchtarget = DeepCopyTable(DEFAULT_SETTINGS.style.frames.watchtarget)
    end
    if type(s.style.frames.target_of_target) ~= "table" then
        s.style.frames.target_of_target = DeepCopyTable(DEFAULT_SETTINGS.style.frames.target_of_target)
    end
    for k, v in pairs(DEFAULT_SETTINGS.style.buff_windows.player.buff) do
        if s.style.buff_windows.player.buff[k] == nil then
            s.style.buff_windows.player.buff[k] = CopyDefaultValue(v)
        end
    end
    for k, v in pairs(DEFAULT_SETTINGS.style.buff_windows.player.debuff) do
        if s.style.buff_windows.player.debuff[k] == nil then
            s.style.buff_windows.player.debuff[k] = CopyDefaultValue(v)
        end
    end
    for k, v in pairs(DEFAULT_SETTINGS.style.buff_windows.target.buff) do
        if s.style.buff_windows.target.buff[k] == nil then
            s.style.buff_windows.target.buff[k] = CopyDefaultValue(v)
        end
    end
    for k, v in pairs(DEFAULT_SETTINGS.style.buff_windows.target.debuff) do
        if s.style.buff_windows.target.debuff[k] == nil then
            s.style.buff_windows.target.debuff[k] = CopyDefaultValue(v)
        end
    end
    s.style.minimal = nil
    if type(s.role) ~= "table" then
        s.role = DeepCopyTable(DEFAULT_SETTINGS.role)
    end

    api.SaveSettings()
    return forceWrite
end

TryMigrateCooldownTrackerFromCbt = function(s)
    if type(s) ~= "table" or type(s.cooldown_tracker) ~= "table" then
        return false
    end
    if s.cooldown_tracker.migrated_from_cbt then
        return false
    end

    local cbt = api.GetSettings("CooldawnBuffTracker")
    if type(cbt) ~= "table" then
        s.cooldown_tracker.migrated_from_cbt = true
        return true
    end

    local function migrateUnit(srcKey, dstKey)
        if type(cbt[srcKey]) ~= "table" then
            return
        end
        local src = cbt[srcKey]
        local dst = s.cooldown_tracker.units[dstKey]
        if type(dst) ~= "table" then
            return
        end

        if src.enabled ~= nil then
            dst.enabled = src.enabled and true or false
        end
        if src.posX ~= nil then
            dst.pos_x = tonumber(src.posX) or dst.pos_x
        end
        if src.posY ~= nil then
            dst.pos_y = tonumber(src.posY) or dst.pos_y
        end
        if src.iconSize ~= nil then
            dst.icon_size = tonumber(src.iconSize) or dst.icon_size
        end
        if src.iconSpacing ~= nil then
            dst.icon_spacing = tonumber(src.iconSpacing) or dst.icon_spacing
        end
        if src.lockPositioning ~= nil then
            dst.lock_position = src.lockPositioning and true or false
        end

        if src.showTimer ~= nil then
            dst.show_timer = src.showTimer and true or false
        end
        if src.timerFontSize ~= nil then
            dst.timer_font_size = tonumber(src.timerFontSize) or dst.timer_font_size
        end
        if type(src.timerTextColor) == "table" then
            dst.timer_color = {
                tonumber(src.timerTextColor.r) or 1,
                tonumber(src.timerTextColor.g) or 1,
                tonumber(src.timerTextColor.b) or 1,
                tonumber(src.timerTextColor.a) or 1
            }
        end

        if src.showLabel ~= nil then
            dst.show_label = src.showLabel and true or false
        end
        if src.labelFontSize ~= nil then
            dst.label_font_size = tonumber(src.labelFontSize) or dst.label_font_size
        end
        if type(src.labelTextColor) == "table" then
            dst.label_color = {
                tonumber(src.labelTextColor.r) or 1,
                tonumber(src.labelTextColor.g) or 1,
                tonumber(src.labelTextColor.b) or 1,
                tonumber(src.labelTextColor.a) or 1
            }
        end

        if type(src.trackedBuffs) == "table" then
            dst.tracked_buffs = {}
            for _, v in ipairs(src.trackedBuffs) do
                table.insert(dst.tracked_buffs, v)
            end
        end

        if srcKey == "target" and src.cacheTimeout ~= nil then
            dst.cache_timeout_s = tonumber(src.cacheTimeout) or dst.cache_timeout_s
        end
    end

    EnsureCooldownTrackerDefaults(s)
    migrateUnit("player", "player")
    migrateUnit("target", "target")
    migrateUnit("playerpet", "playerpet")

    if cbt.enabled ~= nil then
        s.cooldown_tracker.enabled = cbt.enabled and true or false
    end

    s.cooldown_tracker.migrated_from_cbt = true
    return true
end

local function EnsureSettings()
    local runtime = api.GetSettings("polar-ui")
    if type(runtime) ~= "table" then
        runtime = {}
    end

    local fileSettings = nil
    local fileMissing = false
    local fileUnreadable = false
    lastSettingsLoadSource = ""
    lastSettingsLoadError = ""
    do
        local parsed, source, err = ReadSettingsFromFile(SETTINGS_FILE_PATH)
        lastSettingsLoadSource = source
        lastSettingsLoadError = err
        if parsed == nil then
            if source == "file:missing" then
                fileMissing = true
            elseif source == "file:unreadable" then
                fileUnreadable = true
                api.Log:Err("[Polar-UI] Failed to deserialize " .. SETTINGS_FILE_PATH .. " (file exists but was not readable)")
            elseif source == "file:read_error" then
                api.Log:Err("[Polar-UI] Failed to read " .. SETTINGS_FILE_PATH .. ": " .. tostring(err))
            elseif source == "file:nil" then
                api.Log:Err(
                    "[Polar-UI] Failed to read "
                        .. SETTINGS_FILE_PATH
                        .. " (api.File:Read returned nil and raw fallback unavailable)"
                )
            elseif source == "file:legacy_text" or source == "file:string" then
                api.Log:Err(
                    "[Polar-UI] Failed to load "
                        .. SETTINGS_FILE_PATH
                        .. " because it was a raw string file; Polar UI now expects api.File:Read to deserialize a table"
                )
            elseif source == "file:raw" then
                api.Log:Err(
                    "[Polar-UI] Failed to parse "
                        .. SETTINGS_FILE_PATH
                        .. " (error="
                        .. tostring(err)
                        .. ")"
                )
            end
        else
            fileSettings = parsed
        end
    end

    settings = runtime
    if type(fileSettings) == "table" then
        MergeInto(settings, fileSettings)
    end

    local forceWrite = EnsureSettingsDefaultsAndMigrations(settings)

    local shouldWrite = false
    if fileMissing then
        shouldWrite = true
    elseif not fileUnreadable and type(fileSettings) == "table" and forceWrite then
        shouldWrite = true
    end

    if shouldWrite and api.File ~= nil and api.File.Write ~= nil then
        pcall(function()
            api.File:Write(SETTINGS_FILE_PATH, settings)
        end)
    end
end

local function SaveSettingsBackupFile()
    if api.File == nil or api.File.Write == nil or type(settings) ~= "table" then
        return false, "api.File:Write unavailable"
    end
    EnsureSettingsDefaultsAndMigrations(settings)

    local ts = nil
    pcall(function()
        if api.Time ~= nil and api.Time.GetLocalTime ~= nil then
            ts = api.Time:GetLocalTime()
        end
    end)
    if ts == nil then
        ts = tostring(math.random(1000000000, 9999999999))
    end
    ts = tostring(ts)

    local backupPath = string.format("%s/settings_%s.txt", SETTINGS_BACKUP_DIR, ts)
    local ok, err = pcall(function()
        api.File:Write(backupPath, settings)
    end)
    if not ok then
        backupPath = string.format("polar-ui/settings_backup_%s.txt", ts)
        ok, err = pcall(function()
            api.File:Write(backupPath, settings)
        end)
        if not ok then
            return false, tostring(err)
        end
    end

    local idx = nil
    pcall(function()
        idx = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FILE_PATH)
    end)
    if type(idx) ~= "table" then
        pcall(function()
            idx = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FALLBACK_FILE_PATH)
        end)
    end
    if type(idx) ~= "table" then
        idx = { version = 1, backups = {} }
    end
    if type(idx.backups) ~= "table" then
        idx.backups = {}
    end

    table.insert(idx.backups, 1, { path = backupPath, timestamp = ts })
    while #idx.backups > 50 do
        table.remove(idx.backups)
    end

    pcall(function()
        api.File:Write(SETTINGS_BACKUP_INDEX_FILE_PATH, idx)
    end)
    pcall(function()
        local parsed2, source2 = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FILE_PATH)
        if parsed2 == nil and tostring(source2) ~= "file:table" then
            api.File:Write(SETTINGS_BACKUP_INDEX_FALLBACK_FILE_PATH, idx)
        end
    end)

    pcall(function()
        local legacyParsed, legacySource = ReadSettingsFromFile(SETTINGS_BACKUP_FILE_PATH)
        if legacyParsed == nil and tostring(legacySource) == "file:missing" then
            api.File:Write(SETTINGS_BACKUP_FILE_PATH, settings)
        end
    end)

    api.Log:Info("[Polar-UI] Backup saved: " .. tostring(backupPath))
    return true, backupPath
end

local function ResolveBackupPathFromArg(arg)
    local idx = nil
    pcall(function()
        idx = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FILE_PATH)
    end)
    if type(idx) ~= "table" then
        pcall(function()
            idx = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FALLBACK_FILE_PATH)
        end)
    end
    if type(idx) ~= "table" or type(idx.backups) ~= "table" then
        idx = nil
    end

    local raw = tostring(arg or "")
    raw = string.match(raw, "^%s*(.-)%s*$") or raw

    if raw == "" then
        if idx ~= nil and idx.backups[1] ~= nil and type(idx.backups[1].path) == "string" then
            return idx.backups[1].path
        end
        return SETTINGS_BACKUP_FILE_PATH
    end

    local n = tonumber(raw)
    if n ~= nil and idx ~= nil and idx.backups[n] ~= nil and type(idx.backups[n].path) == "string" then
        return idx.backups[n].path
    end

    if string.find(raw, "polar%-ui/", 1, true) == 1 then
        return raw
    end

    if idx ~= nil then
        for _, e in ipairs(idx.backups) do
            if type(e) == "table" and tostring(e.path) == raw then
                return raw
            end
        end
    end

    return nil
end

local function LogBackupList(maxN)
    local limit = tonumber(maxN) or 10
    if limit < 1 then
        limit = 1
    end
    if limit > 50 then
        limit = 50
    end

    local idx = nil
    pcall(function()
        idx = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FILE_PATH)
    end)
    if type(idx) ~= "table" then
        pcall(function()
            idx = ReadSettingsFromFile(SETTINGS_BACKUP_INDEX_FALLBACK_FILE_PATH)
        end)
    end
    if type(idx) ~= "table" or type(idx.backups) ~= "table" or #idx.backups == 0 then
        api.Log:Info("[Polar-UI] No backups found.")
        return
    end

    api.Log:Info("[Polar-UI] Backups:")
    local n = 0
    for i, e in ipairs(idx.backups) do
        if n >= limit then
            break
        end
        if type(e) == "table" and type(e.path) == "string" then
            api.Log:Info(string.format("[Polar-UI]  %d) %s", i, e.path))
            n = n + 1
        end
    end
end

local function ImportSettingsBackupFile(arg)
    if type(settings) ~= "table" then
        return false, "settings not initialized"
    end

    local backupPath = ResolveBackupPathFromArg(arg)
    if backupPath == nil then
        return false, "no backups found (use Backup first or run !pui backups)"
    end

    local parsed, source, err = ReadSettingsFromFile(backupPath)
    if type(parsed) ~= "table" then
        if err == "" then
            err = "no backup found"
        end
        return false, tostring(source) .. ":" .. tostring(err)
    end

    for k in pairs(settings) do
        settings[k] = nil
    end
    MergeInto(settings, parsed)
    EnsureSettingsDefaultsAndMigrations(settings)

    pcall(function()
        local px = type(parsed.player) == "table" and parsed.player.x or nil
        local py = type(parsed.player) == "table" and parsed.player.y or nil
        local tx = type(parsed.target) == "table" and parsed.target.x or nil
        local ty = type(parsed.target) == "table" and parsed.target.y or nil
        local gcCount = 0
        if type(parsed.nameplates) == "table" and type(parsed.nameplates.guild_colors) == "table" then
            for _ in pairs(parsed.nameplates.guild_colors) do
                gcCount = gcCount + 1
            end
        end
        api.Log:Info(
            string.format(
                "[Polar-UI] Imported backup (%s): player=(%s,%s) target=(%s,%s) guild_colors=%s",
                tostring(backupPath),
                tostring(px),
                tostring(py),
                tostring(tx),
                tostring(ty),
                tostring(gcCount)
            )
        )
    end)
    if type(SaveSettingsFile) == "function" then
        SaveSettingsFile()
    end

    if UI ~= nil and UI.Init ~= nil then
        pcall(function()
            UI.Init(settings)
        end)
    end

    if SettingsPage ~= nil and SettingsPage.open ~= nil then
        pcall(function()
            SettingsPage.open()
        end)
    end

    return true, ""
end

SaveSettingsFile = function()
    api.SaveSettings()
    if api.File ~= nil and api.File.Write ~= nil and type(settings) == "table" then
        EnsureSettingsDefaultsAndMigrations(settings)
        pcall(function()
            api.File:Write(SETTINGS_FILE_PATH, settings)
        end)
    end
end

local function OnUpdate(dt)
    if UI == nil or UI.OnUpdate == nil then
        return
    end

    local ok, err = pcall(function()
        UI.OnUpdate(dt)
    end)
    if not ok then
        api.Log:Err("[Polar-UI] UI.OnUpdate failed: " .. tostring(err))
    end
end

local function ReinitializeModules()
    if type(settings) ~= "table" then
        return
    end

    if UI ~= nil and UI.UnLoad ~= nil then
        pcall(function()
            UI.UnLoad()
        end)
    end

    if SettingsPage ~= nil and SettingsPage.Unload ~= nil then
        pcall(function()
            SettingsPage.Unload()
        end)
    end

    if SettingsPage ~= nil and SettingsPage.init ~= nil then
        pcall(function()
            SettingsPage.init(settings, SaveSettingsFile, function()
                if UI ~= nil and UI.Init ~= nil then
                    UI.Init(settings)
                end
            end, {
                backup_settings = SaveSettingsBackupFile,
                import_settings = ImportSettingsBackupFile
            })
        end)
    end

    if UI ~= nil and UI.Init ~= nil then
        local ok, err = pcall(function()
            UI.Init(settings)
        end)
        if not ok then
            api.Log:Err("[Polar-UI] UI.Init failed: " .. tostring(err))
        end
    end
end

local HandleChatCommand

local function LogRuntimeSummary()
    if Compat == nil or api == nil or api.Log == nil or api.Log.Info == nil then
        return
    end
    local runtime = Compat.Get()
    local caps = runtime.caps or {}
    api.Log:Info(string.format(
        "[Polar-UI] Runtime nameplates=%s sliders=%s anchor=%s targeting=%s",
        caps.nameplates_supported and "yes" or "no",
        caps.slider_factory and "yes" or "no",
        caps.nametag_anchor and "nametag" or (caps.screen_position and "screen" or "none"),
        tostring(caps.targeting_mode or "unknown")
    ))
    for _, warning in ipairs(runtime.warnings or {}) do
        api.Log:Info("[Polar-UI] " .. tostring(warning))
    end
    for _, blocker in ipairs(runtime.blockers or {}) do
        if api.Log.Err ~= nil then
            api.Log:Err("[Polar-UI] " .. tostring(blocker))
        end
    end
end

local function OnCommunityChatMessage(...)
    HandleChatCommand(...)
end

local function OnUiReloaded()
    if Compat ~= nil then
        Compat.Probe(true)
        LogRuntimeSummary()
    end
    ReinitializeModules()
end

HandleChatCommand = function(arg1, arg2, arg3, arg4, arg5)
    local message = ""
    local senderName = ""
    local senderUnit = ""

    if type(arg5) == "string" then
        message = arg5
    elseif type(arg3) == "string" then
        message = arg3
    elseif type(arg1) == "string" then
        message = arg1
    end

    if type(arg4) == "string" then
        senderName = arg4
    elseif type(arg2) == "string" then
        senderName = arg2
    end
    if type(arg1) == "string" then
        senderUnit = arg1
    end

    message = tostring(message or "")
    message = string.match(message, "^%s*(.-)%s*$") or message

    if message == "" then
        return
    end

    senderName = tostring(senderName or "")
    senderUnit = tostring(senderUnit or "")

    local isLocalCommand = false
    if senderUnit == "player" then
        isLocalCommand = true
    else
        local myName = Runtime ~= nil and Runtime.GetPlayerName() or ""
        if myName ~= "" and senderName == myName then
            isLocalCommand = true
        end
    end

    local cmd, rest = string.match(message, "^(%S+)%s*(.-)$")
    cmd = tostring(cmd or "")
    rest = tostring(rest or "")
    local sub = string.match(rest, "^(%S+)")
    sub = tostring(sub or "")

    if cmd == "!pui" and not isLocalCommand then
        return
    end

    if cmd == "!pui" and rest == "" then
        if type(settings) ~= "table" then
            return
        end
        settings.enabled = not settings.enabled
        SaveSettingsFile()
        if UI ~= nil and UI.SetEnabled ~= nil then
            UI.SetEnabled(settings.enabled)
        end
        return
    end

    if cmd == "!pui" and sub == "settings" then
        if SettingsPage ~= nil and SettingsPage.toggle ~= nil then
            pcall(function()
                SettingsPage.toggle()
            end)
        end
        return
    end

    if cmd == "!pui" and sub == "backup" then
        local ok, res = SaveSettingsBackupFile()
        if ok then
            api.Log:Info("[Polar-UI] Backup saved: " .. tostring(res))
        else
            api.Log:Err("[Polar-UI] Backup failed: " .. tostring(res))
        end
        return
    end

    if cmd == "!pui" and sub == "backups" then
        local _, argN = string.match(rest, "^(%S+)%s*(.-)$")
        argN = tostring(argN or "")
        LogBackupList(tonumber(argN))
        api.Log:Info("[Polar-UI] Usage: !pui import <n>")
        return
    end

    if cmd == "!pui" and sub == "import" then
        local _, argN = string.match(rest, "^(%S+)%s*(.-)$")
        argN = tostring(argN or "")
        local ok, err = ImportSettingsBackupFile(argN)
        if ok then
            api.Log:Info("[Polar-UI] Imported backup")
        else
            api.Log:Err("[Polar-UI] Import failed: " .. tostring(err))
        end
        return
    end

end

local function OnLoad()
    EnsureSettings()
    if Compat ~= nil then
        Compat.Probe(true)
        LogRuntimeSummary()
    end
    ReinitializeModules()

    api.On("UPDATE", OnUpdate)
    api.On("CHAT_MESSAGE", HandleChatCommand)
    pcall(function()
        api.On("COMMUNITY_CHAT_MESSAGE", OnCommunityChatMessage)
    end)
    api.On("UI_RELOADED", OnUiReloaded)

    api.Log:Info("[Polar-UI] Loaded. !pui toggles overlays; !pui settings opens the settings window.")
end

local function OnUnload()
    api.On("UPDATE", function() end)
    api.On("CHAT_MESSAGE", function() end)
    pcall(function()
        api.On("COMMUNITY_CHAT_MESSAGE", function() end)
    end)
    api.On("UI_RELOADED", function() end)

    if UI ~= nil and UI.UnLoad ~= nil then
        pcall(function()
            UI.UnLoad()
        end)
    end

    if SettingsPage ~= nil and SettingsPage.Unload ~= nil then
        pcall(function()
            SettingsPage.Unload()
        end)
    end
end

PolarUiAddon.OnLoad = OnLoad
PolarUiAddon.OnUnload = OnUnload

return PolarUiAddon
