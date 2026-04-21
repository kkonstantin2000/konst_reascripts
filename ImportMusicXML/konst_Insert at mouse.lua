-- @description Insert or remove stretch marker / take marker / tempo marker at mouse cursor
-- @author kkonstantin2000
-- @version 1.0.0
-- @provides
--   konst_Insert at mouse.lua
-- @changelog
--   v1.0.0 - Initial release
-- @about
--   Context-aware insert/remove toggle at the mouse cursor.
--   - Audio item: insert or remove a stretch marker
--   - MIDI item: insert or remove a rated take marker (1.00x)
--   - Ruler / empty area: insert or remove a tempo+time-signature marker
--
--   Settings are read from REAPER ExtState section "konst_InsertAtMouse".
--   You can configure them in konst_Import MusicXML (Settings > Insert at Mouse).

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings (read from ExtState, written by konst_Import MusicXML)
-- ─────────────────────────────────────────────────────────────────────────────
local EXT = "konst_InsertAtMouse"

local function get_bool(key, default)
    local v = reaper.GetExtState(EXT, key)
    if v == "" then return default end
    return v == "1"
end

local enable_stretch   = get_bool("enable_stretch",  true)   -- audio items: stretch marker toggle
local enable_take_tm   = get_bool("enable_take_tm",  true)   -- MIDI items: 1.00x take marker toggle
local enable_tempo     = get_bool("enable_tempo",    true)   -- ruler/empty: tempo marker toggle
local take_tm_label    = reaper.GetExtState(EXT, "take_tm_label")
if take_tm_label == "" then take_tm_label = "1.00x" end

local snap_area_ms     = 24   -- detection radius in ms for removing stretch markers

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────
local function is_mouse_over_ruler()
    local _, segment = reaper.BR_GetMouseCursorContext()
    return segment == "ruler" or segment == "timeline"
end

local function get_closest_tempo_left(pos)
    local n = reaper.CountTempoTimeSigMarkers(0)
    local best_t, best_bpm, best_note, best_size = -1, 120, 4, 4
    for i = 0, n - 1 do
        local ok, t, _, _, bpm, note, size = reaper.GetTempoTimeSigMarker(0, i)
        if ok and t <= pos and (best_t == -1 or t > best_t) then
            best_t = t; best_bpm = bpm; best_note = note; best_size = size
        end
    end
    return best_bpm, best_note, best_size
end

local function find_tempo_marker_at(pos, radius)
    local n = reaper.CountTempoTimeSigMarkers(0)
    for i = 0, n - 1 do
        local ok, t = reaper.GetTempoTimeSigMarker(0, i)
        if ok and math.abs(t - pos) <= radius then return i, t end
    end
    return nil
end

local function toggle_tempo_marker(mouse_pos)
    local radius = 0.030  -- 30 ms radius for detecting existing marker
    local mi = find_tempo_marker_at(mouse_pos, radius)
    if mi then
        reaper.DeleteTempoTimeSigMarker(0, mi)
    else
        local bpm, note, size = get_closest_tempo_left(mouse_pos)
        reaper.SetTempoTimeSigMarker(0, -1, mouse_pos, -1, -1, bpm, note, size, false)
    end
    reaper.UpdateTimeline()
    reaper.TrackList_AdjustWindows(false)
end

local function find_stretch_marker_at(take, mouse_pos, area_ms)
    local item  = reaper.GetMediaItemTake_Item(take)
    local ipos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local n     = reaper.GetTakeNumStretchMarkers(take)
    local area_s = area_ms / 1000
    for i = 0, n - 1 do
        local _, spos = reaper.GetTakeStretchMarker(take, i)
        if math.abs((ipos + spos) - mouse_pos) <= area_s then return i end
    end
    return nil
end

local function toggle_stretch_marker(take, mouse_pos)
    local existing = find_stretch_marker_at(take, mouse_pos, snap_area_ms)
    if existing then
        reaper.DeleteTakeStretchMarkers(take, existing)
    else
        local ipos = reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_POSITION")
        reaper.SetTakeStretchMarker(take, -1, mouse_pos - ipos)
    end
    reaper.UpdateTimeline()
    reaper.TrackList_AdjustWindows(false)
end

-- Pattern matching rated take marker labels (e.g. "1.00x", "0.85x", "-1.20x")
local RATED_PATTERN = "^%-?%d+%.%d+x$"

local function find_take_tm_at(take, mouse_pos, radius)
    local item   = reaper.GetMediaItemTake_Item(take)
    local ipos   = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local tso    = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local n      = reaper.GetNumTakeMarkers(take)
    for mi = 0, n - 1 do
        local srcpos, name = reaper.GetTakeMarker(take, mi)
        if name and name:match(RATED_PATTERN) then
            local proj_t = ipos - tso + srcpos
            if math.abs(proj_t - mouse_pos) <= radius then return mi end
        end
    end
    return nil
end

local function toggle_take_tm(take, mouse_pos)
    local radius = 0.030  -- 30 ms
    local existing = find_take_tm_at(take, mouse_pos, radius)
    if existing then
        reaper.SetTakeMarker(take, existing, "", -1, 0)  -- set empty name = delete in REAPER 6.x+
        -- Fallback: REAPER doesn't have DeleteTakeMarker before 6.76, use name=""
        -- GetNumTakeMarkers will still count it; workaround: overwrite with empty srcpos flag
        -- Actually the correct approach is just SetTakeMarker with name "" which hides it,
        -- but REAPER >=6.76 added reaper.DeleteTakeMarker. Use it if available.
        if reaper.DeleteTakeMarker then
            reaper.SetTakeMarker(take, existing, take_tm_label, -1, 0)  -- undo the empty-name set
            reaper.DeleteTakeMarker(take, existing)
        end
    else
        local item  = reaper.GetMediaItemTake_Item(take)
        local ipos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local tso   = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
        local srcpos = mouse_pos - ipos + tso
        if srcpos >= 0 then
            reaper.SetTakeMarker(take, -1, take_tm_label, srcpos, 0)
        end
    end
    reaper.UpdateItemInProject(reaper.GetMediaItemTake_Item(take))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main
-- ─────────────────────────────────────────────────────────────────────────────
local function main()
    reaper.BR_GetMouseCursorContext()
    local mouse_pos = reaper.BR_GetMouseCursorContext_Position()
    local item      = reaper.BR_GetMouseCursorContext_Item()

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    if is_mouse_over_ruler() then
        if enable_tempo then
            toggle_tempo_marker(mouse_pos)
        end
    elseif item then
        local take = reaper.GetActiveTake(item)
        if take then
            if reaper.TakeIsMIDI(take) then
                if enable_take_tm then
                    toggle_take_tm(take, mouse_pos)
                end
            else
                if enable_stretch then
                    toggle_stretch_marker(take, mouse_pos)
                end
            end
        end
    else
        -- Mouse over empty arrange area: insert tempo marker
        if enable_tempo then
            toggle_tempo_marker(mouse_pos)
        end
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateTimeline()
    reaper.TrackList_AdjustWindows(false)
    reaper.Undo_EndBlock("Insert/Remove at mouse", -1)
end

main()
