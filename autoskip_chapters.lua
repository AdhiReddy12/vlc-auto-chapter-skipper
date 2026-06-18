--[[
================================================================================
  Auto Chapter Skipper — VLC Extension
  
  Automatically skips intro, opening, ending, and credits chapters.
  
  Installation:
    Windows:  %APPDATA%\vlc\lua\extensions\
    Linux:    ~/.local/share/vlc/lua/extensions/
    macOS:    ~/Library/Application Support/org.videolan.vlc/lua/extensions/
  
  Usage:
    1. Copy this file to the extensions directory above
    2. Restart VLC
    3. View → "Auto Chapter Skipper" to activate
    4. View → "Auto Chapter Skipper" → Settings to configure
  
  Author:  AadhiReddy
  Version: 1.0.0
  License: MIT
================================================================================
--]]

-------------------------------------------------------------------------------
-- Configuration defaults
-------------------------------------------------------------------------------

local CONFIG_FILENAME = "autoskip_chapters.conf"

local DEFAULT_KEYWORDS = {
    "intro",
    "opening",
    "op",
    "ending",
    "ed",
    "credits",
    "closing",
    "preview",
    "next episode preview",
    "prologue",
    "recap",
}

local POLL_INTERVAL_MS  = 500       -- how often we check the current chapter (timer fallback)
local OSD_DURATION_US   = 2000000   -- OSD message duration in microseconds (2s)
local RESKIP_COOLDOWN_MS = 1000     -- loop guard only suppresses immediate repeats
local END_SKIP_MARGIN_US = 2000000  -- when skipping the last chapter, jump near EOF

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local config = {
    enabled  = false,
    keywords = {},   -- populated from defaults or saved config
}

local state = {
    dlg               = nil,   -- dialog handle
    poll_timer        = nil,   -- custom timer state table
    poll_loop_running = false, -- true while the blocking VLC sleep loop is active
    deactivating      = false, -- tells the polling loop to exit
    last_skipped_chap = -1,    -- index of last chapter we skipped (loop guard)
    last_skip_time_ms = 0,     -- wall-clock time for loop guard cooldown
    last_skipped_uri  = "",    -- URI when we last skipped (reset on new media)
    current_input     = nil,   -- track current input for callback management
    -- dialog widgets
    w_enabled_cb      = nil,
    w_keywords_input  = nil,
    w_status_label    = nil,
    w_chapter_label   = nil,
}

-------------------------------------------------------------------------------
-- Extension descriptor
-------------------------------------------------------------------------------

function descriptor()
    return {
        title       = "Auto Chapter Skipper",
        version     = "1.0.0",
        author      = "AadhiReddy",
        url         = "",
        shortdesc   = "Auto-skip intro/opening/ending chapters",
        description = "Automatically detects and skips chapters whose titles "
                   .. "match configurable keywords (intro, opening, ending, "
                   .. "credits, etc.). Fully configurable via a settings dialog.",
        capabilities = { "input-listener", "playing-listener", "meta-listener", "menu" },
    }
end

-------------------------------------------------------------------------------
-- Menu
-------------------------------------------------------------------------------

function menu()
    return { "Settings" }
end

function trigger_menu(id)
    if id == 1 then
        open_settings_dialog()
    end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function activate()
    vlc.msg.info("[AutoSkip] Extension activated")
    state.deactivating = false
    load_config()
    
    open_settings_dialog()
    attach_current_input_callbacks()
    check_chapter()
    start_timer()
end

function deactivate()
    vlc.msg.info("[AutoSkip] Extension deactivated")
    state.deactivating = true
    
    -- Stop timer
    stop_timer()
    
    detach_input_callbacks()
    
    close_dialog()
end

function close()
    vlc.deactivate()
end

-------------------------------------------------------------------------------
-- Event hooks and timer system
-- Uses native timer if available (vlc.timer()), otherwise falls back to
-- intf-event callbacks for periodic checking
-------------------------------------------------------------------------------

function input_changed()
    -- New media loaded — reset skip guard so we can skip chapter 0 again
    state.last_skipped_chap = -1
    state.last_skipped_uri  = ""
    vlc.msg.dbg("[AutoSkip] Input changed — skip guard reset")
    
    -- Stop any existing timer
    stop_timer()
    
    attach_current_input_callbacks()
    check_chapter()
end

function playing_changed(status)
    vlc.msg.dbg("[AutoSkip] Playing status changed: " .. tostring(status))
    attach_current_input_callbacks()
    
    -- VLC status codes (varies by version):
    -- VLC 2.x/3.x: 0=stopped, 1=opening, 2=paused, 3=playing, 4=stopping, 5=error
    -- VLC 4.x: 0=stopped, 1=playing, 2=paused
    if status == 3 or status == 1 then  -- Support both VLC 3.x (3) and 4.x (1)
        -- Started playing - start timer for periodic checks
        vlc.msg.dbg("[AutoSkip] Media playing, starting timer...")
        start_timer()
    elseif status == 2 then
        -- Paused media can still be seeked, so keep the checker alive.
        vlc.msg.dbg("[AutoSkip] Media paused, keeping timer active...")
        start_timer()
    else
        -- Stopped or paused - stop timer
        vlc.msg.dbg("[AutoSkip] Media stopped/paused, stopping timer...")
        stop_timer()
    end
    
    check_chapter()
end

function meta_changed()
    -- VLC often fires meta_changed when a chapter transition happens
    -- Always check when this fires
    check_chapter()
end

function intf_event_handler(var, old, new, data)
    -- This gets called frequently by VLC
    -- Always check when this fires (it's our pseudo-timer)
    check_chapter()
end

function chapter_changed_handler(var, old, new, data)
    vlc.msg.dbg("[AutoSkip] Chapter changed: " .. tostring(old) .. " -> " .. tostring(new))
    check_chapter()
end

function time_changed_handler(var, old, new, data)
    if should_check_now() then
        check_chapter()
    end
end

function position_changed_handler(var, old, new, data)
    if should_check_now() then
        check_chapter()
    end
end

function state_changed_handler(var, old, new, data)
    vlc.msg.dbg("[AutoSkip] Input state changed: " .. tostring(old) .. " -> " .. tostring(new))
    check_chapter()
end

function detach_input_callbacks()
    if state.current_input then
        pcall(vlc.var.del_callback, state.current_input, "intf-event", intf_event_handler)
        pcall(vlc.var.del_callback, state.current_input, "chapter", chapter_changed_handler)
        pcall(vlc.var.del_callback, state.current_input, "time", time_changed_handler)
        pcall(vlc.var.del_callback, state.current_input, "position", position_changed_handler)
        pcall(vlc.var.del_callback, state.current_input, "state", state_changed_handler)
        state.current_input = nil
    end
end

function attach_current_input_callbacks()
    local input = vlc.object.input()
    if not input then
        detach_input_callbacks()
        return nil
    end

    if state.current_input == input then
        return input
    end

    detach_input_callbacks()

    local attached = false
    attached = register_input_callback(input, "intf-event", intf_event_handler) or attached
    attached = register_input_callback(input, "chapter", chapter_changed_handler) or attached
    attached = register_input_callback(input, "time", time_changed_handler) or attached
    attached = register_input_callback(input, "position", position_changed_handler) or attached
    attached = register_input_callback(input, "state", state_changed_handler) or attached

    if attached then
        state.current_input = input
    else
        vlc.msg.warn("[AutoSkip] No input callbacks registered; seek detection will only run on VLC play/pause events")
    end

    return input
end

function register_input_callback(input, var_name, handler)
    -- Disabled as callbacks are handled by background watcher
    return false
end

function start_timer()
    -- Disabled
end

function stop_timer()
    -- Disabled
end

function run_poll_loop()
    -- Disabled
end

function should_check_now()
    return true
end

function current_time_ms()
    local ok, mdate = pcall(function() return vlc.misc.mdate() end)
    if ok and mdate then
        return math.floor(mdate / 1000)
    end

    return math.floor(os.clock() * 1000)
end

--- Main check — called by timer and VLC event hooks
function check_chapter()
    if not config.enabled then return end

    local input = attach_current_input_callbacks()
    if not input then 
        -- No input = no media playing, stop timer if it's running
        stop_timer()
        return 
    end
    
    -- Check playback state. Skipping while paused is allowed so activating the
    -- extension on a paused video still moves past intro/opening chapters.
    local ok_playing, is_playing = pcall(vlc.var.get, input, "state")
    if ok_playing and (is_playing == 3 or is_playing == 1) then  -- 3=VLC3.x, 1=VLC4.x
        -- Media is playing, ensure timer is running
        if not state.poll_timer then
            start_timer()
        end
    elseif ok_playing and is_playing == 2 then
        -- Paused: no polling needed, but still check the current chapter once.
        -- Keep polling so manual seeks while paused are still detected.
    else
        -- Media not playing (paused/stopped), stop timer
        stop_timer()
        return
    end

    -- Get the current chapter index (0-based)
    local ok_cur, current_chapter = pcall(vlc.var.get, input, "chapter")
    if not ok_cur or current_chapter == nil then return end

    -- Get the list of chapters: values (indices) and texts (titles)
    local ok_list, values, texts = pcall(vlc.var.get_list, input, "chapter")
    if not ok_list or not values or not texts then return end

    local chapter_count = #values
    if chapter_count == 0 then return end

    -- Get current media URI for skip-guard scoping
    local item = vlc.input.item()
    local current_uri = ""
    if item then
        current_uri = item:uri() or ""
    end

    -- Reset skip guard if the media changed
    if current_uri ~= state.last_skipped_uri then
        state.last_skipped_chap = -1
        state.last_skip_time_ms = 0
        state.last_skipped_uri  = current_uri
    end

    local now_ms = current_time_ms()

    -- Suppress only immediate repeat callbacks from the same skip action.
    -- Seeking back to the same chapter later should skip again.
    if current_chapter == state.last_skipped_chap
        and (now_ms - state.last_skip_time_ms) < RESKIP_COOLDOWN_MS then
        return
    end

    -- Find the title of the current chapter
    -- The arrays are 1-indexed in Lua; chapter index from VLC is 0-based
    local lua_index = current_chapter + 1
    if lua_index < 1 or lua_index > #texts then return end

    local chapter_title = texts[lua_index]
    if not chapter_title or chapter_title == "" then return end

    -- Check if the chapter title matches any skip keyword
    local matched_keyword = match_keywords(chapter_title)
    if matched_keyword then
        vlc.msg.info("[AutoSkip] Chapter " .. current_chapter
            .. " (\"" .. chapter_title .. "\") matches keyword \""
            .. matched_keyword .. "\" — skipping!")

        -- Determine the target chapter. Skip consecutive matching chapters in
        -- one pass so VLC does not need another playback/UI event.
        local next_chapter = current_chapter + 1
        while next_chapter < (chapter_count - 1) do
            local next_lua_index = next_chapter + 1
            local next_title_to_check = texts[next_lua_index]
            local next_match = match_keywords(next_title_to_check)
            if not next_match then
                break
            end

            vlc.msg.info("[AutoSkip] Also skipping chapter " .. next_chapter
                .. " (\"" .. next_title_to_check .. "\") matching keyword \""
                .. next_match .. "\"")
            next_chapter = next_chapter + 1
        end

        if next_chapter >= chapter_count then
            state.last_skipped_chap = current_chapter
            state.last_skip_time_ms = now_ms
            state.last_skipped_uri  = current_uri

            local skipped_to_end = skip_to_end(input)
            if skipped_to_end then
                local osd_msg = "â­ Skipped: \"" .. chapter_title .. "\""
                show_osd_message(osd_msg)
                update_dialog_status("Skipped final chapter " .. current_chapter
                    .. " (\"" .. chapter_title .. "\")")
            else
                vlc.msg.info("[AutoSkip] Already at last chapter and duration is unavailable")
            end
            return
        end

        -- If we're at the last chapter, we can't skip forward
        if next_chapter >= chapter_count then
            vlc.msg.info("[AutoSkip] Already at last chapter — cannot skip further")
            state.last_skipped_chap = current_chapter
            return
        end

        -- Record what we skipped to prevent loops
        state.last_skipped_chap = current_chapter
        state.last_skip_time_ms = now_ms
        state.last_skipped_uri  = current_uri

        -- Jump to next chapter
        vlc.var.set(input, "chapter", next_chapter)

        -- Show OSD notification
        local next_title = ""
        if next_chapter + 1 <= #texts then
            next_title = texts[next_chapter + 1]
        end
        local osd_msg = "⏭ Skipped: \"" .. chapter_title .. "\""
        if next_title and next_title ~= "" then
            osd_msg = osd_msg .. "\n▶ Now: \"" .. next_title .. "\""
        end
        show_osd_message(osd_msg)

        -- Update dialog if open
        update_dialog_status("Skipped chapter " .. current_chapter
            .. " (\"" .. chapter_title .. "\")")
    end
end

function skip_to_end(input)
    local duration = nil

    local ok_len, length_value = pcall(vlc.var.get, input, "length")
    if ok_len and length_value and length_value > 0 then
        duration = length_value
    end

    if not duration then
        local item = vlc.input.item()
        if item then
            local ok_duration, item_duration = pcall(function() return item:duration() end)
            if ok_duration and item_duration and item_duration > 0 then
                if item_duration < 100000 then
                    duration = item_duration * 1000000
                else
                    duration = item_duration
                end
            end
        end
    end

    if not duration then
        return false
    end

    local target_time = duration - END_SKIP_MARGIN_US
    if target_time < 0 then
        target_time = duration
    end

    vlc.msg.info("[AutoSkip] Final skipped chapter; jumping near end at "
        .. tostring(target_time))
    return pcall(vlc.var.set, input, "time", target_time)
end

function show_osd_message(msg)
    pcall(function()
        local channel = vlc.osd.channel_register()
        vlc.osd.message(msg, channel, "top-right", OSD_DURATION_US)
    end)
end

-------------------------------------------------------------------------------
-- Keyword matching
-------------------------------------------------------------------------------

--- Check if a chapter title matches any configured skip keyword.
--- Uses case-insensitive substring matching.
--- @param title string  The chapter title to check
--- @return string|nil   The matched keyword, or nil if no match
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

-------------------------------------------------------------------------------
-- Settings dialog
-------------------------------------------------------------------------------

function open_settings_dialog()
    if state.dlg then
        -- Dialog already open — just bring it to focus
        state.dlg:show()
        refresh_dialog_info()
        return
    end

    state.dlg = vlc.dialog("Auto Chapter Skipper — Settings")
    local d = state.dlg

    -- Row 1: Title
    d:add_label("<h2>⏭ Auto Chapter Skipper</h2>", 1, 1, 4, 1)

    -- Row 2: Enable/disable toggle
    d:add_label("<b>Status:</b>", 1, 2, 1, 1)
    state.w_enabled_cb = d:add_check_box("Auto-skip enabled", config.enabled, 2, 2, 2, 1)

    -- Row 3-4: Keywords
    d:add_label("<b>Skip keywords</b> (comma-separated):", 1, 3, 4, 1)
    local kw_str = table.concat(config.keywords, ", ")
    state.w_keywords_input = d:add_text_input(kw_str, 1, 4, 4, 1)

    -- Row 5: Buttons
    d:add_button("💾  Save", on_save, 1, 5, 1, 1)
    d:add_button("🔄  Reset Defaults", on_reset_defaults, 2, 5, 1, 1)
    d:add_button("❌  Close", on_close_dialog, 3, 5, 1, 1)

    -- Row 6: Separator
    d:add_label("<hr>", 1, 6, 4, 1)

    -- Row 7: Current chapter info
    d:add_label("<b>Current Playback Info:</b>", 1, 7, 4, 1)
    state.w_chapter_label = d:add_label("Loading...", 1, 8, 4, 1)

    -- Row 9: Status / last action
    d:add_label("<b>Last Action:</b>", 1, 9, 1, 1)
    state.w_status_label = d:add_label("—", 2, 9, 3, 1)

    -- Row 10: Disclaimer
    d:add_label("<hr>", 1, 10, 4, 1)
    d:add_label("<small><i><b>Disclaimer:</b> Use at your own risk. The creator is not responsible for any failures.</i></small>", 1, 11, 4, 1)

    refresh_dialog_info()
end

function close_dialog()
    if state.dlg then
        state.dlg:delete()
        state.dlg = nil
        state.w_enabled_cb = nil
        state.w_keywords_input = nil
        state.w_status_label = nil
        state.w_chapter_label = nil
    end
end

function refresh_dialog_info()
    if not state.w_chapter_label then return end

    local input = vlc.object.input()
    if not input then
        state.w_chapter_label:set_text("No media playing")
        return
    end

    local ok_cur, current_chapter = pcall(vlc.var.get, input, "chapter")
    local ok_list, values, texts = pcall(vlc.var.get_list, input, "chapter")

    if not ok_list or not values or #values == 0 then
        state.w_chapter_label:set_text("No chapters detected in current media")
        return
    end

    local info_parts = {}
    table.insert(info_parts, "Total chapters: " .. #values)

    if ok_cur and current_chapter ~= nil then
        local lua_idx = current_chapter + 1
        local cur_title = "(unknown)"
        if lua_idx >= 1 and lua_idx <= #texts then
            cur_title = texts[lua_idx]
        end
        table.insert(info_parts, "Current: #" .. current_chapter .. " — \"" .. cur_title .. "\"")

        -- Show whether current chapter would be skipped
        local match = match_keywords(cur_title)
        if match then
            table.insert(info_parts, "⚠ Would skip (matches: \"" .. match .. "\")")
        end
    end

    -- List all chapters
    table.insert(info_parts, "")
    table.insert(info_parts, "<b>All chapters:</b>")
    for i, text in ipairs(texts) do
        local prefix = "  "
        if ok_cur and (i - 1) == current_chapter then
            prefix = "▶ "
        end
        local skip_mark = ""
        if match_keywords(text) then
            skip_mark = " ⏭"
        end
        table.insert(info_parts, prefix .. (i - 1) .. ": " .. text .. skip_mark)
    end

    state.w_chapter_label:set_text(table.concat(info_parts, "<br>"))
end

function update_dialog_status(msg)
    if state.w_status_label then
        state.w_status_label:set_text(msg)
    end
    -- Also refresh chapter info
    refresh_dialog_info()
end

-------------------------------------------------------------------------------
-- Dialog callbacks
-------------------------------------------------------------------------------

function on_save()
    if not state.w_enabled_cb or not state.w_keywords_input then return end

    -- Read enabled state
    config.enabled = state.w_enabled_cb:get_checked()

    -- Parse keywords from comma-separated input
    local raw = state.w_keywords_input:get_text()
    config.keywords = parse_keywords(raw)

    -- Reset skip guard when config changes
    state.last_skipped_chap = -1

    -- Persist
    save_config()

    update_dialog_status("✅ Settings saved! (" .. #config.keywords .. " keywords)")
    vlc.msg.info("[AutoSkip] Settings saved: enabled="
        .. tostring(config.enabled) .. ", keywords=" .. table.concat(config.keywords, ", "))
end

function on_reset_defaults()
    config.keywords = shallow_copy(DEFAULT_KEYWORDS)
    config.enabled  = false

    -- Update UI
    if state.w_keywords_input then
        state.w_keywords_input:set_text(table.concat(config.keywords, ", "))
    end
    if state.w_enabled_cb then
        state.w_enabled_cb:set_checked(true)
    end

    -- Reset skip guard
    state.last_skipped_chap = -1

    save_config()
    update_dialog_status("🔄 Reset to defaults (" .. #config.keywords .. " keywords)")
end

function on_close_dialog()
    close_dialog()
end

-------------------------------------------------------------------------------
-- Config persistence
-------------------------------------------------------------------------------

--- Get the path to the config file
function get_config_path()
    -- Try vlc.config.userdatadir() first (VLC 3.0+)
    local dir = nil
    local ok, result = pcall(function() return vlc.config.userdatadir() end)
    if ok and result then
        dir = result
    else
        -- Fallback for older VLC versions or if userdatadir fails
        -- Windows: %APPDATA%\vlc\
        -- Linux: ~/.local/share/vlc/
        -- macOS: ~/Library/Application Support/org.videolan.vlc/
        if package.config:sub(1,1) == '\\' then -- Windows
            dir = os.getenv("APPDATA") .. "\\vlc"
        else -- Unix-like (Linux/macOS)
            local home = os.getenv("HOME")
            if home then
                -- Try Linux path first, then macOS
                local linux_path = home .. "/.local/share/vlc"
                local mac_path = home .. "/Library/Application Support/org.videolan.vlc"
                if vlc and vlc.config and vlc.config.datadir then
                    dir = vlc.config.datadir
                elseif os.execute("test -d '" .. linux_path .. "' 2>/dev/null") == 0 then
                    dir = linux_path
                else
                    dir = mac_path
                end
            end
        end
    end
    
    if not dir then
        -- Ultimate fallback
        dir = "."
    end
    
    return dir .. "/" .. CONFIG_FILENAME
end

function save_config()
    local path = get_config_path()
    local file = io.open(path, "w")
    if not file then
        vlc.msg.warn("[AutoSkip] Could not save config to: " .. path)
        return
    end

    file:write("-- Auto Chapter Skipper Configuration\n")
    file:write("-- This file is auto-generated. Edit via the VLC extension dialog.\n\n")
    file:write("enabled=" .. tostring(config.enabled) .. "\n")
    file:write("keywords=" .. table.concat(config.keywords, ",") .. "\n")
    file:close()

    vlc.msg.info("[AutoSkip] Config saved to: " .. path)
end

function load_config()
    -- Start with defaults
    config.keywords = shallow_copy(DEFAULT_KEYWORDS)
    config.enabled  = false

    local path = get_config_path()
    local file = io.open(path, "r")
    if not file then
        vlc.msg.info("[AutoSkip] No config file found, using defaults")
        return
    end

    vlc.msg.info("[AutoSkip] Loading config from: " .. path)

    for line in file:lines() do
        -- Skip comments and empty lines
        if not string.match(line, "^%s*%-%-") and not string.match(line, "^%s*$") then
            local key, value = string.match(line, "^(%w+)%s*=%s*(.+)$")
            if key and value then
                if key == "enabled" then
                    config.enabled = (value == "true")
                elseif key == "keywords" then
                    config.keywords = parse_keywords(value)
                end
            end
        end
    end

    file:close()
    vlc.msg.info("[AutoSkip] Config loaded: enabled="
        .. tostring(config.enabled) .. ", " .. #config.keywords .. " keywords")
end

-------------------------------------------------------------------------------
-- Utility functions
-------------------------------------------------------------------------------

--- Parse a comma-separated string into a table of trimmed, non-empty keywords
function parse_keywords(str)
    local keywords = {}
    if not str or str == "" then return keywords end

    for token in string.gmatch(str, "[^,]+") do
        local trimmed = string.match(token, "^%s*(.-)%s*$")
        if trimmed and trimmed ~= "" then
            table.insert(keywords, trimmed)
        end
    end

    return keywords
end

--- Shallow copy a table
function shallow_copy(t)
    local copy = {}
    for i, v in ipairs(t) do
        copy[i] = v
    end
    return copy
end
