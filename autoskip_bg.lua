--[[
================================================================================
  Auto Chapter Skipper — Background Watcher (luaintf)
  
  This script runs in the background of VLC to continuously poll for chapter
  changes on seek. This is required because VLC Lua Extensions cannot detect
  seeks reliably without add_callback or mwait, which are disabled in extensions.
================================================================================
--]]

local CONFIG_FILENAME = "autoskip_chapters.conf"
local POLL_INTERVAL_US = 500000      -- 500ms
local CONFIG_POLL_INTERVAL_US = 2000000 -- 2s
local RESKIP_COOLDOWN_MS = 1000
local END_SKIP_MARGIN_US = 2000000

local config = {
    enabled = true,
    keywords = {
        "intro", "opening", "op", "ending", "ed", "credits", "closing", 
        "preview", "next episode preview", "prologue", "recap"
    }
}

local state = {
    last_skipped_chap = -1,
    last_skip_time_ms = 0,
    last_skipped_uri  = "",
    last_config_load  = 0
}

function get_config_path()
    local dir = nil
    local ok, result = pcall(function() return vlc.config.userdatadir() end)
    if ok and result then dir = result else
        if package.config:sub(1,1) == '\\' then
            dir = os.getenv("APPDATA") .. "\\vlc"
        else
            local home = os.getenv("HOME")
            if home then dir = home .. "/.local/share/vlc" end
        end
    end
    if not dir then dir = "." end
    return dir .. "/" .. CONFIG_FILENAME
end

function load_config()
    local path = get_config_path()
    local file = io.open(path, "r")
    if not file then return end

    local content = file:read("*all")
    file:close()

    for line in string.gmatch(content, "[^\r\n]+") do
        if not string.match(line, "^%s*%-%-") then
            local key, value = string.match(line, "^([^=]+)=(.*)$")
            if key and value then
                if key == "enabled" then
                    config.enabled = (value == "true")
                elseif key == "keywords" then
                    config.keywords = {}
                    for kw in string.gmatch(value, "([^,]+)") do
                        local trimmed = string.match(kw, "^%s*(.-)%s*$")
                        if trimmed and trimmed ~= "" then
                            table.insert(config.keywords, trimmed)
                        end
                    end
                end
            end
        end
    end
end

function match_keywords(title)
    if not title then return nil end
    local lower_title = string.lower(title)
    for _, keyword in ipairs(config.keywords) do
        local lower_kw = string.lower(keyword)
        if lower_kw ~= "" and string.find(lower_title, lower_kw, 1, true) then
            return keyword
        end
    end
    return nil
end

function current_time_ms()
    local ok, mdate = pcall(function() return vlc.misc.mdate() end)
    if ok and mdate then
        return math.floor(mdate / 1000)
    end
    return 0
end

function skip_to_end(input)
    local duration = nil
    local ok_len, length_value = pcall(vlc.var.get, input, "length")
    if ok_len and length_value and length_value > 0 then
        duration = length_value
    end

    if not duration then return false end

    local target_time = duration - END_SKIP_MARGIN_US
    if target_time < 0 then target_time = duration end

    vlc.msg.info("[AutoSkip BG] Final skipped chapter; jumping near end")
    return pcall(vlc.var.set, input, "time", target_time)
end

function show_osd_message(msg)
    pcall(function()
        local channel = vlc.osd.channel_register()
        vlc.osd.message(msg, channel, "top-right", 2000000)
    end)
end

function check_chapter()
    if not config.enabled then return end

    local input = vlc.object.input()
    if not input then return end

    -- Only check if playing or paused
    local ok_playing, is_playing = pcall(vlc.var.get, input, "state")
    if not ok_playing or (is_playing ~= 3 and is_playing ~= 1 and is_playing ~= 2) then return end

    local ok_cur, current_chapter = pcall(vlc.var.get, input, "chapter")
    if not ok_cur or current_chapter == nil then return end

    local ok_list, values, texts = pcall(vlc.var.get_list, input, "chapter")
    if not ok_list or not values or not texts or #values == 0 then return end

    -- Reset skip guard if the media changed
    local ok_uri, current_uri = pcall(vlc.var.get, input, "uri")
    if not ok_uri then current_uri = "" end

    if current_uri ~= state.last_skipped_uri then
        state.last_skipped_chap = -1
        state.last_skip_time_ms = 0
        state.last_skipped_uri  = current_uri
    end

    local now_ms = current_time_ms()
    if current_chapter == state.last_skipped_chap and (now_ms - state.last_skip_time_ms) < RESKIP_COOLDOWN_MS then
        return
    end

    local lua_index = current_chapter + 1
    if lua_index < 1 or lua_index > #texts then return end

    local chapter_title = texts[lua_index]
    if not chapter_title or chapter_title == "" then return end

    local matched_keyword = match_keywords(chapter_title)
    if matched_keyword then
        vlc.msg.info("[AutoSkip BG] Chapter " .. current_chapter .. " matches keyword " .. matched_keyword .. " - skipping!")

        local chapter_count = #values
        local next_chapter = current_chapter + 1
        while next_chapter < (chapter_count - 1) do
            local next_match = match_keywords(texts[next_chapter + 1])
            if not next_match then break end
            next_chapter = next_chapter + 1
        end

        state.last_skipped_chap = current_chapter
        state.last_skip_time_ms = now_ms
        state.last_skipped_uri  = current_uri

        if next_chapter >= chapter_count then
            if skip_to_end(input) then
                show_osd_message("⏭ Skipped: \"" .. chapter_title .. "\"")
            end
            return
        end

        pcall(vlc.var.set, input, "chapter", next_chapter)

        local next_title = ""
        if next_chapter + 1 <= #texts then next_title = texts[next_chapter + 1] end
        local osd_msg = "⏭ Skipped: \"" .. chapter_title .. "\""
        if next_title ~= "" then osd_msg = osd_msg .. "\n▶ Now: \"" .. next_title .. "\"" end
        show_osd_message(osd_msg)
    end
end

-- Main loop
vlc.msg.info("[AutoSkip BG] Background watcher started")
load_config()
state.last_config_load = current_time_ms()

while true do
    -- Periodic config reload
    local now_ms = current_time_ms()
    if (now_ms - state.last_config_load) * 1000 > CONFIG_POLL_INTERVAL_US then
        load_config()
        state.last_config_load = now_ms
    end

    check_chapter()

    -- Sleep
    local ok_sleep = pcall(function() vlc.misc.mwait(vlc.misc.mdate() + POLL_INTERVAL_US) end)
    if not ok_sleep then
        -- Should not happen in intf script, but fallback if it does
        break
    end
end
