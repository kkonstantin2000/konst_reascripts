-- @description Import and export MusicXML (.xml) 
-- @author kkonstantin2000
-- @version 1.5.0
-- @provides
--   konst_Import MusicXML.lua
-- @changelog
--   v1.5.0
--   Settings UI:
--   - Reorganized all settings into 9 foldable sections: GENERAL, EXPORT, IMPORT, TRANSIENTS, TEMPO MAP, MIDI TOOLS, INSERT AT MOUSE, ARTICULATION, ARTICULATION GRID.
--   - Added comprehensive hover tooltips for all UI elements in both main and settings views.
--   - Fixed hover tips toggle: disabling "Hover Tips" now correctly hides tooltips in both views.
--
--   Import workflow:
--   - Added drag-and-drop track import: drag a track label from the GUI list directly into REAPER's arrange view to import and position it.
--   - Added double-click on track label to import that single track at the edit cursor.
--   - Added import position options "Region Onset" and "START Marker" (total now 6, was 4).
--   - Added import timebase options "Align to project tempo map" and "Align to detected tempo map" (total now 6, was 4).
--   - Added import progress bar overlay with animated progress, status text, and per-step completion log.
--   - Added import undo history: saves pre-import state and allows undoing the last import.
--
--   Auto-load:
--   - Added auto-loading MusicXML by region name: automatically selects the file matching the active region as the edit cursor moves.
--   - Fixed: manual Import button now always respects import_position_index, even when the cursor is inside an auto-loaded region.
--
--   Audio alignment (Settings > Transients / Tempo Map):
--   - Added "Align to audio stem" import timebase: aligns the imported score to a drum/percussion audio stem via an external Python script.
--   - Added "Align notes to transients" option: creates a nudged MIDI take with each note snapped to its nearest audio transient.
--   - Added native audio transient detection with dual envelope follower and peak refinement.
--   - Added tempo smoothing and iterative BPM correction passes for stable tempo maps.
--   - Added "Tempo map every beat" option: generates per-beat tempo markers snapped to audio transients.
--   - Added stretch markers on drum audio items during stem alignment.
--   - Added START marker detection to anchor alignment to a specific project position.
--   - Added measure boundary collection during XML parsing for alignment use.
--   - Added "Detect Tempo" button (Settings > Transients): generates tempo markers from the transients of a selected audio item.
--   - Added standalone "Remap" button (Settings > Tempo Map): re-positions MIDI notes to match the current project tempo map without re-importing.
--   - Added standalone "Nudge" button (Settings > Tempo Map): snaps notes of a selected MIDI item to the nearest stretch markers of a selected audio item (new take).
--   - Added "Delete Tempo Markers" button (Settings > Tempo Map): deletes all tempo markers within the active range (razor edit → time selection → selected items bounding box).
--   - Added "Remove Stretch Markers" button (Settings > Tempo Map): removes stretch markers from selected audio items within the active range.
--
--   MIDI Tools (Settings > MIDI Tools):
--   - Added MIDI Stretch Markers mode: take markers on MIDI items act as pseudo-stretch markers — drag to warp surrounding notes in real time.
--   - Added "Shift TM" slider: shifts the MIDI take tempo map offset (±2 beats).
--   - Added "Warp TM" slider: stretches the MIDI take tempo map rate (±2 beats range), with rate display.
--   - Added TM Grid Snap toggle: snaps both sliders to the project grid.
--   - Added "Snap TM to Note" button: snaps the take marker to the nearest MIDI note.
--   - Added Auto-snap TM checkbox: automatically snaps the take marker on every frame.
--   - Added "Reset TM" button: resets Shift TM and Warp TM to defaults.
--
--   Insert at Mouse (Settings > Insert at Mouse + companion script):
--   - Added companion script konst_Insert at mouse.lua: context-sensitive insertion on ruler (tempo marker), MIDI item (take marker), or audio item (stretch marker).
--   - Added Insert at Mouse settings section to control which insertion types are enabled.
--
--   Bug fixes:
--   - Fixed ticks_to_project_time: now uses TimeMap_timeToQN / TimeMap_QNToTime for correct accumulated beat calculation (was using TimeMap2_timeToBeats which returns beat-within-measure).
--   - Fixed stale autoload_region_start_pos causing manual Import to override the chosen import position when the cursor was inside a matching region.

--[[
  Select an uncompressed MusicXML (.xml) file. This script creates new tracks and MIDI items for each staff that contains tablature or drum notes.
  Drum parts use a configurable channel mapping so instruments like kick, snare, etc. can be assigned to separate MIDI channels.

  This version supports expansion of repeats (forward/backward), with a robust XML parser that handles CDATA sections and processing instructions.

  Mute handling:
    - straight mute: type 1 text event, symbol "x", replaces fret, no underscore
    - palm mute:    type 6 marker, symbol "P.M___", does not replace fret, no underscore

  Slide handling (modified):
    - Slides (slide, slide-up, slide-down) are detected as start/stop pairs.
    - Single text event is placed at the second note for paired slides.
    - If no partner, the slide is placed as before.
]]

-- ============================================================================
-- USER‑CONFIGURABLE SETTINGS
-- ============================================================================

-- Offset (in ticks) applied to successive notes of a chord.
-- The first note keeps its original position, the second is moved forward by
-- this amount, the third by 2×, etc. Set to 0 to disable.
chord_offset_ticks = 1

-- Script directory (for finding companion Python scripts)
script_dir = ({reaper.get_action_context()})[2]:match("(.+[\\/])") or ""

-- Case-insensitive track name matching for "Insert items on tracks by name" mode
-- Set to true to match track names regardless of case (e.g., "guitar" matches "Guitar" or "GUITAR")
CASE_INSENSITIVE = true

-- Maximum window dimensions (pixels). Window will not grow beyond these limits.
MAX_WINDOW_WIDTH = 800
MAX_WINDOW_HEIGHT = 900

-- ============================================================================
-- DRUM NAME TO TEXT MAPPING
-- ============================================================================
-- Map the exact instrument names (as they appear in <instrument-name>) to the
-- short text you want to appear in the MIDI item (prefixed with an underscore).
-- If a name is not found, a fallback (first word, lowercased) is used.
drum_text_map = {
    -- Kick & bass drums
    ["Kick (hit)"]            = "kick",
    ["Surdo (hit)"]           = "surdo",
    ["Surdo (mute)"]          = "surdo_m",
    ["Grancassa (hit)"]       = "grancassa",

    -- Snares & similar
    ["Snare (hit)"]           = "snare",
    ["Snare (side stick)"]    = "stick",
    ["Snare (rim shot)"]      = "rim",
    ["Hand Clap (hit)"]       = "clap",

    -- Hi‑hats
    ["Hi-Hat (closed)"]       = "hh",
    ["Hi-Hat (half)"]         = "hhalf",
    ["Hi-Hat (open)"]         = "hho",
    ["Pedal Hi-Hat (hit)"]    = "hhped",

    -- Toms
    ["High Floor Tom (hit)"]  = "hftom",
    ["High Tom (hit)"]        = "htom",
    ["Mid Tom (hit)"]         = "mtom",
    ["Low Tom (hit)"]         = "ltom",
    ["Very Low Tom (hit)"]    = "vltom",
    ["Low Floor Tom (hit)"]   = "lftom",

    -- Cymbals
    ["Ride (edge)"]           = "ride",
    ["Ride (middle)"]         = "ride",
    ["Ride (bell)"]           = "ridebell",
    ["Ride (choke)"]          = "ridechoke",
    ["Crash high (hit)"]      = "crash",
    ["Crash high (choke)"]    = "crashchoke",
    ["Crash medium (hit)"]    = "crash",
    ["Crash medium (choke)"]  = "crashchoke",
    ["Splash (hit)"]          = "splash",
    ["Splash (choke)"]        = "splashchoke",
    ["China (hit)"]           = "china",
    ["China (choke)"]         = "chinachoke",
    ["Cymbal (hit)"]          = "cymbal",

    -- Aux percussion
    ["Cowbell low (hit)"]     = "cowb_l",
    ["Cowbell low (tip)"]     = "cowb_l_tip",
    ["Cowbell medium (hit)"]  = "cowb_m",
    ["Cowbell medium (tip)"]  = "cowb_m_tip",
    ["Cowbell high (hit)"]    = "cowb_h",
    ["Cowbell high (tip)"]    = "cowb_h_tip",
    ["Woodblock low (hit)"]   = "wood_l",
    ["Woodblock high (hit)"]  = "wood_h",
    ["Bongo high (hit)"]      = "bongo_h",
    ["Bongo high (mute)"]     = "bongo_h_m",
    ["Bongo high (slap)"]     = "bongo_h_slap",
    ["Bongo low (hit)"]       = "bongo_l",
    ["Bongo low (mute)"]      = "bongo_l_m",
    ["Bongo low (slap)"]      = "bongo_l_slap",
    ["Timbale low (hit)"]     = "timb_l",
    ["Timbale high (hit)"]    = "timb_h",
    ["Agogo low (hit)"]       = "agogo_l",
    ["Agogo high (hit)"]      = "agogo_h",
    ["Conga low (hit)"]       = "conga_l",
    ["Conga low (slap)"]      = "conga_l_slap",
    ["Conga low (mute)"]      = "conga_l_m",
    ["Conga high (hit)"]      = "conga_h",
    ["Conga high (slap)"]     = "conga_h_slap",
    ["Conga high (mute)"]     = "conga_h_m",
    ["Whistle low (hit)"]     = "whistle_l",
    ["Whistle high (hit)"]    = "whistle_h",
    ["Guiro (hit)"]           = "guiro",
    ["Guiro (scrap-return)"]  = "guiro_scrap",
    ["Tambourine (hit)"]      = "tamb",
    ["Tambourine (return)"]   = "tamb_ret",
    ["Tambourine (roll)"]     = "tamb_roll",
    ["Tambourine (hand)"]     = "tamb_hand",
    ["Cuica (open)"]          = "cuica_o",
    ["Cuica (mute)"]          = "cuica_m",
    ["Vibraslap (hit)"]       = "vibraslap",
    ["Triangle (hit)"]        = "tri",
    ["Triangle (mute)"]       = "tri_m",
    ["Piatti (hit)"]          = "piatti",
    ["Piatti (hand)"]         = "piatti_hand",
    ["Cabasa (hit)"]          = "cabasa",
    ["Cabasa (return)"]       = "cabasa_ret",
    ["Castanets (hit)"]       = "cast",
    ["Claves (hit)"]          = "claves",
    ["Left Maraca (hit)"]     = "maraca_l",
    ["Left Maraca (return)"]  = "maraca_l_ret",
    ["Right Maraca (hit)"]    = "maraca_r",
    ["Right Maraca (return)"] = "maraca_r_ret",
    ["Shaker (hit)"]          = "shaker",
    ["Shaker (return)"]       = "shaker_ret",
    ["Bell Tree (hit)"]       = "belltree",
    ["Bell Tree (return)"]    = "belltree_ret",
    ["Jingle Bell (hit)"]     = "jingle",
    ["Tinkle Bell (hit)"]     = "tinkle",
    ["Golpe (thumb)"]         = "golpe_t",
    ["Golpe (finger)"]        = "golpe_f",
}

-- ============================================================================
-- DRUM CHANNEL MAPPING
-- ============================================================================
-- Map the exact instrument names to a MIDI channel (1‑6).
-- All instruments are grouped into six channels by family.
-- If an instrument is not listed here, the script falls back to the
-- <midi-channel> value from the MusicXML (usually channel 10), but with this
-- comprehensive mapping that fallback should never be needed.
-- ============================================================================
-- DRUM CHANNEL MAPPING
-- ============================================================================
-- Map the exact instrument names to a MIDI channel (1‑9).
-- Instruments are grouped into nine channels by family for better separation.
-- If an instrument is not listed here, the script falls back to the
-- <midi-channel> value from the MusicXML (usually channel 10), but with this
-- comprehensive mapping that fallback should never be needed.
drum_channel_map = {
    -- Channel 1: Bass drums
    ["Kick (hit)"]            = 1,
    ["Surdo (hit)"]           = 1,
    ["Surdo (mute)"]          = 1,
    ["Grancassa (hit)"]       = 1,

    -- Channel 2: Snares & similar
    ["Snare (hit)"]           = 2,
    ["Snare (side stick)"]    = 2,
    ["Snare (rim shot)"]      = 2,
    ["Hand Clap (hit)"]       = 2,

    -- Channel 3: Hi‑hats
    ["Hi-Hat (closed)"]       = 3,
    ["Hi-Hat (half)"]         = 3,
    ["Hi-Hat (open)"]         = 3,
    ["Pedal Hi-Hat (hit)"]    = 3,

    -- Channel 4: Toms
    ["High Floor Tom (hit)"]  = 4,
    ["High Tom (hit)"]        = 4,
    ["Mid Tom (hit)"]         = 4,
    ["Low Tom (hit)"]         = 4,
    ["Very Low Tom (hit)"]    = 4,
    ["Low Floor Tom (hit)"]   = 4,

    -- Channel 5: Ride cymbals
    ["Ride (edge)"]           = 5,
    ["Ride (middle)"]         = 5,
    ["Ride (bell)"]           = 5,
    ["Ride (choke)"]          = 5,

    -- Channel 6: Crash, splash & china cymbals
    ["Crash high (hit)"]      = 6,
    ["Crash high (choke)"]    = 6,
    ["Crash medium (hit)"]    = 6,
    ["Crash medium (choke)"]  = 6,
    ["Splash (hit)"]          = 6,
    ["Splash (choke)"]        = 6,
    ["China (hit)"]           = 6,
    ["China (choke)"]         = 6,
    ["Cymbal (hit)"]          = 6,

    -- Channel 7: Pitched percussion (cowbells, woodblocks, agogo, claves, etc.)
    ["Cowbell low (hit)"]     = 7,
    ["Cowbell low (tip)"]     = 7,
    ["Cowbell medium (hit)"]  = 7,
    ["Cowbell medium (tip)"]  = 7,
    ["Cowbell high (hit)"]    = 7,
    ["Cowbell high (tip)"]    = 7,
    ["Woodblock low (hit)"]   = 7,
    ["Woodblock high (hit)"]  = 7,
    ["Agogo low (hit)"]       = 7,
    ["Agogo high (hit)"]      = 7,
    ["Claves (hit)"]          = 7,
    ["Castanets (hit)"]       = 7,
    ["Bell Tree (hit)"]       = 7,
    ["Bell Tree (return)"]    = 7,
    ["Jingle Bell (hit)"]     = 7,
    ["Tinkle Bell (hit)"]     = 7,

    -- Channel 8: Hand drums (bongos, congas, timbales)
    ["Bongo high (hit)"]      = 8,
    ["Bongo high (mute)"]     = 8,
    ["Bongo high (slap)"]     = 8,
    ["Bongo low (hit)"]       = 8,
    ["Bongo low (mute)"]      = 8,
    ["Bongo low (slap)"]      = 8,
    ["Conga low (hit)"]       = 8,
    ["Conga low (slap)"]      = 8,
    ["Conga low (mute)"]      = 8,
    ["Conga high (hit)"]      = 8,
    ["Conga high (slap)"]     = 8,
    ["Conga high (mute)"]     = 8,
    ["Timbale low (hit)"]     = 8,
    ["Timbale high (hit)"]    = 8,

    -- Channel 9: Shakers, rattles & other effects
    ["Whistle low (hit)"]     = 9,
    ["Whistle high (hit)"]    = 9,
    ["Guiro (hit)"]           = 9,
    ["Guiro (scrap-return)"]  = 9,
    ["Tambourine (hit)"]      = 9,
    ["Tambourine (return)"]   = 9,
    ["Tambourine (roll)"]     = 9,
    ["Tambourine (hand)"]     = 9,
    ["Cuica (open)"]          = 9,
    ["Cuica (mute)"]          = 9,
    ["Vibraslap (hit)"]       = 9,
    ["Triangle (hit)"]        = 9,
    ["Triangle (mute)"]       = 9,
    ["Piatti (hit)"]          = 9,
    ["Piatti (hand)"]         = 9,
    ["Cabasa (hit)"]          = 9,
    ["Cabasa (return)"]       = 9,
    ["Left Maraca (hit)"]     = 9,
    ["Left Maraca (return)"]  = 9,
    ["Right Maraca (hit)"]    = 9,
    ["Right Maraca (return)"] = 9,
    ["Shaker (hit)"]          = 9,
    ["Shaker (return)"]       = 9,
    ["Golpe (thumb)"]         = 9,
    ["Golpe (finger)"]        = 9,
}

-- ============================================================================
-- DRUM PITCH MAPPING (General MIDI Percussion Key Map)
-- ============================================================================
-- Maps drum instrument names to their General MIDI pitch values
-- Organized by channel for proper ReaTabHero configuration
drum_pitch_map = {
    -- Channel 1: Bass drums
    ["Kick (hit)"]            = 36,  -- C1 Bass Drum 1
    ["Surdo (hit)"]           = 36,
    ["Surdo (mute)"]          = 36,
    ["Grancassa (hit)"]       = 35,  -- B0 Acoustic Bass Drum

    -- Channel 2: Snares & similar
    ["Snare (hit)"]           = 38,  -- D1 Acoustic Snare
    ["Snare (side stick)"]    = 37,  -- C#1 Side Stick
    ["Snare (rim shot)"]      = 37,
    ["Hand Clap (hit)"]       = 39,  -- Eb1 Hand Clap
    ["Electric Snare"]        = 40,  -- E1 Electric Snare

    -- Channel 3: Hi‑hats
    ["Hi-Hat (closed)"]       = 42,  -- F#1 Closed Hi Hat
    ["Hi-Hat (half)"]         = 44,  -- Ab1 Pedal Hi-Hat
    ["Hi-Hat (open)"]         = 46,  -- Bb1 Open Hi-Hat
    ["Pedal Hi-Hat (hit)"]    = 44,

    -- Channel 4: Toms
    ["High Floor Tom (hit)"]  = 43,  -- G1 High Floor Tom
    ["High Tom (hit)"]        = 50,  -- D2 High Tom
    ["Mid Tom (hit)"]         = 48,  -- C2 Hi Mid Tom
    ["Low Tom (hit)"]         = 45,  -- A1 Low Tom
    ["Very Low Tom (hit)"]    = 41,  -- F1 Low Floor Tom
    ["Low Floor Tom (hit)"]   = 41,

    -- Channel 5: Ride cymbals
    ["Ride (edge)"]           = 51,  -- Eb2 Ride Cymbal 1
    ["Ride (middle)"]         = 51,
    ["Ride (bell)"]           = 53,  -- F2 Ride Bell
    ["Ride (choke)"]          = 51,

    -- Channel 6: Crash, splash & china cymbals
    ["Crash high (hit)"]      = 49,  -- C#2 Crash Cymbal 1
    ["Crash high (choke)"]    = 49,
    ["Crash medium (hit)"]    = 57,  -- A2 Crash Cymbal 2
    ["Crash medium (choke)"]  = 57,
    ["Splash (hit)"]          = 55,  -- G2 Splash Cymbal
    ["Splash (choke)"]        = 55,
    ["China (hit)"]           = 52,  -- E2 Chinese Cymbal
    ["China (choke)"]         = 52,
    ["Cymbal (hit)"]          = 49,

    -- Channel 7: Pitched percussion (cowbells, woodblocks, agogo, claves, etc.)
    ["Cowbell low (hit)"]     = 56,  -- Ab2 Cowbell
    ["Cowbell low (tip)"]     = 56,
    ["Cowbell medium (hit)"]  = 56,
    ["Cowbell medium (tip)"]  = 56,
    ["Cowbell high (hit)"]    = 56,
    ["Cowbell high (tip)"]    = 56,
    ["Woodblock low (hit)"]   = 77,  -- F4 Low Wood Block
    ["Woodblock high (hit)"]  = 76,  -- E4 Hi Wood Block
    ["Agogo low (hit)"]       = 68,  -- Ab3 Low Agogo
    ["Agogo high (hit)"]      = 67,  -- G3 High Agogo
    ["Claves (hit)"]          = 75,  -- Eb4 Claves

    -- Channel 8: Hand drums (bongos, congas, timbales)
    ["Bongo high (hit)"]      = 60,  -- C3 Hi Bongo
    ["Bongo high (mute)"]     = 60,
    ["Bongo high (slap)"]     = 60,
    ["Bongo low (hit)"]       = 61,  -- C#3 Low Bongo
    ["Bongo low (mute)"]      = 61,
    ["Bongo low (slap)"]      = 61,
    ["Conga low (hit)"]       = 64,  -- E3 Low Conga
    ["Conga low (slap)"]      = 64,
    ["Conga low (mute)"]      = 62,  -- D3 Mute Hi Conga
    ["Conga high (hit)"]      = 63,  -- Eb3 Open Hi Conga
    ["Conga high (slap)"]     = 63,
    ["Conga high (mute)"]     = 62,
    ["Timbale low (hit)"]     = 66,  -- F#3 Low Timbale
    ["Timbale high (hit)"]    = 65,  -- F3 High Timbale

    -- Channel 9: Shakers, rattles & other effects
    ["Whistle low (hit)"]     = 71,  -- B3 Short Whistle
    ["Whistle high (hit)"]    = 72,  -- C4 Long Whistle
    ["Guiro (hit)"]           = 73,  -- C#4 Short Guiro
    ["Guiro (scrap-return)"]  = 74,  -- D4 Long Guiro
    ["Tambourine (hit)"]      = 54,  -- F#2 Tambourine
    ["Tambourine (return)"]   = 54,
    ["Tambourine (roll)"]     = 54,
    ["Tambourine (hand)"]     = 54,
    ["Cuica (open)"]          = 79,  -- G4 Open Cuica
    ["Cuica (mute)"]          = 78,  -- F#4 Mute Cuica
    ["Vibraslap (hit)"]       = 58,  -- Bb2 Vibraslap
    ["Triangle (hit)"]        = 81,  -- A4 Open Triangle
    ["Triangle (mute)"]       = 80,  -- Ab4 Mute Triangle
    ["Piatti (hit)"]          = 49,
    ["Piatti (hand)"]         = 49,
    ["Cabasa (hit)"]          = 69,  -- A3 Cabasa
    ["Cabasa (return)"]       = 69,
    ["Left Maraca (hit)"]     = 70,  -- Bb3 Maracas
    ["Left Maraca (return)"]  = 70,
    ["Right Maraca (hit)"]    = 70,
    ["Right Maraca (return)"] = 70,
    ["Shaker (hit)"]          = 70,
    ["Shaker (return)"]       = 70,
    ["Golpe (thumb)"]         = 56,
    ["Golpe (finger)"]        = 56,
}

-- ============================================================================
-- GM PRESETS TABLE (for bank/program assignment)
-- ============================================================================
gm_presets = {
    {name = ">Keys", program = 0},
    {name = "Acoustic Grand Piano", program = 0},
    {name = "Bright Acoustic Piano", program = 1},
    {name = "Electric Grand Piano", program = 2},
    {name = "Honky-tonk Piano", program = 3},
    {name = "Electric Piano 1", program = 4},
    {name = "Electric Piano 2", program = 5},
    {name = "Harpsichord", program = 6},
    {name = "<Clavinet", program = 7},
    {name = ">Chromatic Percussion", program = 0},
    {name = "Celesta", program = 8},
    {name = "Glockenspiel", program = 9},
    {name = "Music Box", program = 10},
    {name = "Vibraphone", program = 11},
    {name = "Marimba", program = 12},
    {name = "Xylophone", program = 13},
    {name = "Tubular Bells", program = 14},
    {name = "<Dulcimer", program = 15},
    {name = ">Organ", program = 0},
    {name = "Drawbar Organ", program = 16},
    {name = "Percussive Organ", program = 17},
    {name = "Rock Organ", program = 18},
    {name = "Church Organ", program = 19},
    {name = "Reed Organ", program = 20},
    {name = "Accordion", program = 21},
    {name = "Harmonica", program = 22},
    {name = "<Tango Accordion", program = 23},
    {name = ">Guitar", program = 0},
    {name = "Acoustic Guitar (nylon)", program = 24},
    {name = "Acoustic Guitar (steel)", program = 25},
    {name = "Electric Guitar (jazz)", program = 26},
    {name = "Electric Guitar (clean)", program = 27},
    {name = "Electric Guitar (muted)", program = 28},
    {name = "Overdriven Guitar", program = 29},
    {name = "Distortion Guitar", program = 30},
    {name = "<Guitar Harmonics", program = 31},
    {name = ">Bass", program = 0},
    {name = "Acoustic Bass", program = 32},
    {name = "Electric Bass (finger)", program = 33},
    {name = "Electric Bass (pick)", program = 34},
    {name = "Fretless Bass", program = 35},
    {name = "Slap Bass 1", program = 36},
    {name = "Slap Bass 2", program = 37},
    {name = "Synth Bass 1", program = 38},
    {name = "<Synth Bass 2", program = 39},
    {name = ">Strings", program = 0},
    {name = "Violin", program = 40},
    {name = "Viola", program = 41},
    {name = "Cello", program = 42},
    {name = "Contrabass", program = 43},
    {name = "Tremolo Strings", program = 44},
    {name = "Pizzicato Strings", program = 45},
    {name = "Orchestral Harp", program = 46},
    {name = "<Timpani", program = 47},
    {name = ">Ensembles", program = 0},
    {name = "String Ensemble 1", program = 48},
    {name = "String Ensemble 2", program = 49},
    {name = "Synth Strings 1", program = 50},
    {name = "Synth Strings 2", program = 51},
    {name = "Choir Aahs", program = 52},
    {name = "Voice Oohs", program = 53},
    {name = "Synth Voice", program = 54},
    {name = "<Orchestra Hit", program = 55},
    {name = ">Brass", program = 0},
    {name = "Trumpet", program = 56},
    {name = "Trombone", program = 57},
    {name = "Tuba", program = 58},
    {name = "Muted Trumpet", program = 59},
    {name = "French Horn", program = 60},
    {name = "Brass Section", program = 61},
    {name = "Synth Brass 1", program = 62},
    {name = "<Synth Brass 2", program = 63},
    {name = ">Reed Instruments", program = 0},
    {name = "Soprano Sax", program = 64},
    {name = "Alto Sax", program = 65},
    {name = "Tenor Sax", program = 66},
    {name = "Baritone Sax", program = 67},
    {name = "Oboe", program = 68},
    {name = "English Horn", program = 69},
    {name = "Bassoon", program = 70},
    {name = "<Clarinet", program = 71},
    {name = ">Pipes", program = 0},
    {name = "Piccolo", program = 72},
    {name = "Flute", program = 73},
    {name = "Recorder", program = 74},
    {name = "Pan Flute", program = 75},
    {name = "Blown Bottle", program = 76},
    {name = "Shakuhachi", program = 77},
    {name = "Whistle", program = 78},
    {name = "<Ocarina", program = 79},
    {name = ">Synth Leads", program = 0},
    {name = "Lead 1 (square)", program = 80},
    {name = "Lead 2 (sawtooth)", program = 81},
    {name = "Lead 3 (calliope)", program = 82},
    {name = "Lead 4 (chiff)", program = 83},
    {name = "Lead 5 (charang)", program = 84},
    {name = "Lead 6 (voice)", program = 85},
    {name = "Lead 7 (fifths)", program = 86},
    {name = "<Lead 8 (bass + lead)", program = 87},
    {name = ">Synth Pads", program = 0},
    {name = "Synth Pad 1 (New Age)", program = 88},
    {name = "Synth Pad 2 (warm)", program = 89},
    {name = "Synth Pad 3 (polysynth)", program = 90},
    {name = "Synth Pad 4 (choir)", program = 91},
    {name = "Synth Pad 5 (bowed)", program = 92},
    {name = "Synth Pad 6 (metallic)", program = 93},
    {name = "Synth Pad 7 (halo)", program = 94},
    {name = "<Synth Pad 8 (sweep)", program = 95},
    {name = ">Synth Effects", program = 0},
    {name = "Synth Effects 1 (rain)", program = 96},
    {name = "Synth Effects 2 (soundtrack)", program = 97},
    {name = "Synth Effects 3 (crystal)", program = 98},
    {name = "Synth Effects 4 (atmosphere)", program = 99},
    {name = "Synth Effects 5 (brightness)", program = 100},
    {name = "Synth Effects 6 (goblins)", program = 101},
    {name = "Synth Effects 7 (echoes)", program = 102},
    {name = "<Synth Effects 8 (sci-fi)", program = 103},
    {name = ">Ethnic", program = 0},
    {name = "Sitar", program = 104},
    {name = "Banjo", program = 105},
    {name = "Shamisen", program = 106},
    {name = "Koto", program = 107},
    {name = "Kalimba", program = 108},
    {name = "Bagpipe", program = 109},
    {name = "Fiddle", program = 110},
    {name = "<Shanai", program = 111},
    {name = ">Percussion", program = 0},
    {name = "Tinkle Bell", program = 112},
    {name = "Agogo", program = 113},
    {name = "Steel Drums", program = 114},
    {name = "Woodblock", program = 115},
    {name = "Taiko Drum", program = 116},
    {name = "Melodic Tom", program = 117},
    {name = "Synth Drum", program = 118},
    {name = "<Reverse Cymbal", program = 119},
    {name = ">Sound Effects", program = 0},
    {name = "Guitar Fret Noise", program = 120},
    {name = "Breath Noise", program = 121},
    {name = "Seashore", program = 122},
    {name = "Bird Tweet", program = 123},
    {name = "Telephone Ring", program = 124},
    {name = "Helicopter", program = 125},
    {name = "Applause", program = 126},
    {name = "<Gunshot", program = 127},
    {name = "Drums", program = 128},
}

-- Build program-to-name lookup (excluding submenu headers and Drums)
gm_program_to_name = {}
for _, p in ipairs(gm_presets) do
    if p.name:sub(1,1) ~= ">" and p.name ~= "Drums" then
        local clean = p.name:gsub("^<", "")
        gm_program_to_name[p.program] = clean
    end
end

-- ============================================================================
-- REGION COLORS AND MAPPING
-- ============================================================================
local c = {
    rosewood = reaper.ColorToNative(152,0,46)|0x1000000,
    red = reaper.ColorToNative(149,63,64)|0x1000000,
    orange = reaper.ColorToNative(153,84,62)|0x1000000,
    gold = reaper.ColorToNative(153,130,60)|0x1000000,
    green = reaper.ColorToNative(97,138,88)|0x1000000,
    teal = reaper.ColorToNative(78,149,134)|0x1000000,
    cyan = reaper.ColorToNative(61,153,153)|0x1000000,
    royalblue = reaper.ColorToNative(76,78,151)|0x1000000,
    grey = reaper.ColorToNative(89,89,98)|0x1000000
}

region_color_map = {
    ["intro"] = c.grey,
    ["verse"] = c.gold,
    ["pre-chorus"] = c.orange,
    ["chorus"] = c.cyan,
    ["bridge"] = c.grey,
    ["solo"] = c.rosewood,
    ["riff"] = c.red,
    ["outro"] = c.grey
}

-- ============================================================================
-- USER‑CONFIGURABLE ARTICULATION MAP
-- ============================================================================
-- Keys are MusicXML element names (e.g., "accent", "staccato", "harmonic").
-- Each entry contains:
--   type          : 1 = Text, 6 = Marker, 7 = Cue point (or function returning these)
--   symbol        : text to insert. For harmonics, use "%d" as a placeholder
--                   for the fret number. (or function)
--   replaces_fret : (optional) if true, this articulation replaces the base
--                   fret text (the symbol will be prefixed with "_").
--                   Otherwise a separate text event with the symbol is added.
--   no_prefix     : (optional) if true, the underscore prefix is NOT added.
-- ============================================================================
articulation_map = {
    -- Articulations (usually under <articulations>)
    accent        = { type = 6, symbol = ">", no_prefix = true },
    staccato      = { type = 7, symbol = ".", no_prefix = true },
    tenuto        = { type = 7, symbol = "-", no_prefix = true },
    -- ["strong-accent"] = { type = 1, symbol = "^" },   -- upbow accent
    staccatissimo = { type = 7, symbol = "'", no_prefix = true },
    spiccato      = { type = 7, symbol = "!", no_prefix = true },
    scoop         = { type = 1, symbol = "/%d", replaces_fret = true },
    falloff       = { type = 1, symbol = "%d\\", replaces_fret = true },      -- downward slide
    doit          = { type = 1, symbol = "/%d", replaces_fret = true },       -- upward slide
    breathmark    = { type = 1, symbol = "," },

    -- Technical indications (under <technical>)
    ["palm mute"]      = { type = 6, symbol = "P.M---", no_prefix = true },
    ["straight mute"]  = { type = 1, symbol = "x", replaces_fret = true, no_prefix = false },
    ["letring"]        = { type = 6, symbol = "let ring---",  no_prefix = true },

    ["hammer-on"] = { type = 6, symbol = "H", no_prefix = true },
    ["pull-off"]  = { type = 6, symbol = "P", no_prefix = true },
    ["tap"]       = { type = 6, symbol = "T", no_prefix = true },
    ["fingering"] = { type = 1, symbol = "%d" },      -- finger number
    ["harmonic"]  = { type = 1, symbol = "<%d>", replaces_fret = true },
    ["natural-harmonic"]   = { type = 1, symbol = "<%d>",    replaces_fret = true },
    ["artificial-harmonic"]= { type = 1, symbol = "%d <%h>", replaces_fret = true },
    ["vibrato"]   = { type = 1, symbol = "~", replaces_fret = false, is_suffix = true },
    -- Slide entries are kept here for symbol lookup, but they are handled separately in the main loop.
    ["slide"]     = { type = 1, symbol = "/%d", replaces_fret = true },
    ["slide-up"]  = { type = 1, symbol = "/%d", replaces_fret = true },
    ["slide-down"]= { type = 1, symbol = "%d\\", replaces_fret = true },
    ["bend"]         = { type = 1, symbol = "%d˄",  replaces_fret = true },
    ["bend release"] = { type = 1, symbol = "%d˄˅", replaces_fret = true },
    ["pre-bend"]     = { type = 1, symbol = "%d|",  replaces_fret = true },
    -- Amount label markers (type 6, one row per bend amount)
    ["1/2 bend"]     = { type = 6, symbol = "1/2",   no_prefix = true },
    ["full bend"]    = { type = 6, symbol = "full",  no_prefix = true },
    ["1 1/2 bend"]   = { type = 6, symbol = "1 1/2", no_prefix = true },
    ["2 bend"]       = { type = 6, symbol = "2",     no_prefix = true },
    ["2 1/2 bend"]   = { type = 6, symbol = "2 1/2", no_prefix = true },
    ["3 bend"]       = { type = 6, symbol = "3",     no_prefix = true },
    ["grace-note"]   = { type = 1, symbol = "gr" },

    -- Markers (type 6) – for strum directions, below the tab
    ["up-stroke"]   = { type = 6, symbol = "˄" },
    ["down-stroke"] = { type = 6, symbol = "˅" },

    -- Cues (type 7) – for sections, chords, lyrics, above the tab
    ["chord"]       = { type = 7, symbol = "%s", no_prefix = true },    -- chord name (needs separate parsing)
    ["lyric"]       = { type = 7, symbol = "%s", no_prefix = true },    -- lyric text (needs separate parsing)
}

-- Names of slide elements – these will be handled separately in the main loop.
slide_names = {
    ["slide"] = true,
    ["slide-up"] = true,
    ["slide-down"] = true
}

-- Names of bend elements – collected as a sequence rather than processed individually.
bend_names = {
    ["bend"] = true,
}

-- ============================================================================
-- ARTICULATION SETTINGS (enabled / disabled per articulation)
-- ============================================================================
-- Ordered list of articulation names for a stable display in Settings UI
articulation_names_ordered = {
    "accent", "staccato", "tenuto", "staccatissimo", "spiccato",
    "scoop", "falloff", "doit", "breathmark",
    "palm", "straight", "letring",
    "hammer-on", "pull-off", "tap", "fingering",
    "harmonic", "natural-harmonic", "artificial-harmonic",
    "vibrato",
    "slide", "slide-up", "slide-down",
    "bend", "bend release", "pre-bend",
    "1/2 bend", "full bend", "1 1/2 bend", "2 bend", "2 1/2 bend", "3 bend",
    "grace-note",
    "up-stroke", "down-stroke",
    "chord", "lyric",
}

-- Map XML element names that differ from articulation_names_ordered entries
xml_to_settings_name = {
    ["palm mute"] = "palm",
    ["straight mute"] = "straight",
}

-- Build a set of articulation_names_ordered for quick lookup
settings_name_set = {}
for _, name in ipairs(articulation_names_ordered) do
    settings_name_set[name] = true
end

-- Table: articulation_name -> true/false (enabled)
articulation_enabled = {}
-- Table: articulation_name -> custom symbol string (nil = use default)
articulation_symbol_override = {}
-- Table: articulation_name -> custom type number (nil = use default)
articulation_type_override = {}
-- Table: articulation_name -> custom replaces_fret override (nil = use default)
articulation_replaces_fret_override = {}
-- Table: articulation_name -> custom no_prefix override (nil = use default)
articulation_no_prefix_override = {}
-- Table: articulation_name -> default symbol string (from articulation_map)
articulation_default_symbol = {}
-- Table: articulation_name -> default type number (from articulation_map)
articulation_default_type = {}
-- Table: articulation_name -> default replaces_fret (from articulation_map)
articulation_default_replaces_fret = {}
-- Table: articulation_name -> default no_prefix (from articulation_map)
articulation_default_no_prefix = {}
-- Valid type values and their labels
art_type_values = {1, 6, 7}
art_type_labels = {[1] = "Text", [6] = "Marker", [7] = "Cue"}
-- Fret number global settings
fret_number_enabled = false
fret_number_type = 1
FRET_NUMBER_TYPE_DEFAULT = 1
-- Duration line (span) feature: draw "----" / "-|" for consecutive span arts
span_line_enabled = false
-- Highlight articulations used in file (requires XML scan on track selection change)
highlight_scan_enabled = true
-- Export project regions as rehearsal marks (segments) in MusicXML
export_regions_enabled = true
-- Include MIDI program/bank in import and export
midi_program_banks_enabled = true
-- Use GM preset names for imported track names instead of part-name
gm_name_tracks_enabled = false
-- Import position: 1=Start of Project, 2=Edit Cursor, 3=Closest Region Start, 4=Closest Marker, 5=Region Onset, 6=START Marker
import_position_index = 1
import_position_options = {"Start of Project", "Edit Cursor", "Closest Region Start", "Closest Marker", "Region Onset", "START Marker"}
-- Align stem selector: index into the audio items list within the current region (0 = Auto)
align_stem_index = 0
align_stem_items = {}  -- populated dynamically: {{item, take, name}, ...}
-- Onset item selector: index into audio items list for onset detection (0 = Auto)
onset_item_index = 0
onset_item_items = {}  -- populated dynamically like align_stem_items
-- Auto-load MusicXML file by matching region name at edit cursor
autoload_by_region_enabled = false
-- MIDI item timebase: 1=Default, 2=Time, 3=Beats (pos+len+rate), 4=Beats (pos only), 5=Adapt to project tempo map
import_timebase_index = 1
import_timebase_options = {"Project default", "Time", "Beats (position, length, rate)", "Beats (position only)", "Align to project tempo map", "Align to detected tempo map"}
import_timebase_values = {-1, 0, 1, 2, 0}  -- C_BEATATTACHMODE values; index 5 (Align to tempo map) uses Time (0) (-1=project default, 0=time, 1=beats pos+len+rate, 2=beats pos only; Adapt uses project default)
-- Tempo map frequency: how often to write tempo markers (fraction of a bar, or N bars)
tempo_map_freq_index = 1
tempo_map_freq_options = {"Off", "1/16", "1/8", "1/6", "1/4", "1/3", "1/2", "1", "2", "3", "4", "5", "6", "7", "8"}
-- Time signature for tempo detection (default 4/4)
tempo_timesig_index = 8  -- index into tempo_timesig_options for 4/4
tempo_timesig_options = {
    "1/2", "2/2", "3/2", "4/2",
    "1/4", "2/4", "3/4", "4/4", "5/4", "6/4", "7/4", "8/4",
    "1/8", "2/8", "3/8", "4/8", "5/8", "6/8", "7/8", "8/8", "9/8", "12/8",
}
tempo_timesig_num   = {1, 2, 3, 4,  1, 2, 3, 4, 5, 6, 7, 8,  1, 2, 3, 4, 5, 6, 7, 8, 9, 12}
tempo_timesig_denom = {2, 2, 2, 2,  4, 4, 4, 4, 4, 4, 4, 4,  8, 8, 8, 8, 8, 8, 8, 8, 8, 8}
-- Compute effective time sig and quarter-note beats per marker interval.
-- For freq >= 1 bar: uses user time sig, marker every N bars.
-- For freq < 1 bar: shrinks time sig so one marker = one bar.
-- Returns: ts_num, ts_denom, beats_per_bar (quarter-note beats), or nil,nil,nil if Off.
function get_detect_tempo_timesig()
    local freq_opt = tempo_map_freq_options[tempo_map_freq_index]
    if freq_opt == "Off" then return nil, nil, nil end
    local user_num = tempo_timesig_num[tempo_timesig_index]
    local user_denom = tempo_timesig_denom[tempo_timesig_index]
    local user_beats_qn = user_num * 4 / user_denom
    local fn, fd = freq_opt:match("^(%d+)/(%d+)$")
    if fn then
        fn = tonumber(fn)
        fd = tonumber(fd)
    else
        fn = tonumber(freq_opt)
        fd = 1
    end
    if fn >= fd then
        -- freq >= 1 bar: user time sig, marker every N bars
        return user_num, user_denom, user_beats_qn * fn / fd
    else
        -- freq < 1 bar: effective time sig = fraction of user bar
        local eff_num = user_num * fn
        local eff_denom = user_denom * fd
        local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
        local g = gcd(eff_num, eff_denom)
        eff_num = eff_num / g
        eff_denom = eff_denom / g
        return eff_num, eff_denom, eff_num * 4 / eff_denom
    end
end
-- Tempo detection method: 1=Lua, 2=Python
tempo_detect_method_index = 1
tempo_detect_method_options = {"Lua", "Python"}
-- Stretch markers on transients after tempo detection
detect_stretch_markers_enabled = false
-- First stretch marker = start of bar 1 (skip transients before it)
first_marker_is_bar1 = true
-- Detect tempo from existing stretch markers (skip transient detection)
detect_tempo_use_existing_markers = false
-- Stretch marker sliders: threshold, sensitivity, retrig, offset
sm_threshold_dB = 60     -- amplitude threshold (0–60 dB, higher = detect more). Default 60
sm_sensitivity_dB = 7    -- envelope ratio (1–20 dB, lower = more transients). Default 7
sm_retrig_ms = 60        -- min gap between transients (10–500 ms). Default 60
sm_offset_ms = 0         -- bidirectional shift of markers (-100 to +100 ms). Default 0
sm_slider_dragging = nil -- nil or "threshold"/"sensitivity"/"retrig"/"offset"
-- Cache of detected transients (per item, detected at min settings for instant post-filtering)
cached_transients_raw = nil     -- table of {src=..., proj=..., strength=env1, env2=env2}
cached_transient_item = nil     -- item pointer the cache was built for
cached_transient_params = nil   -- (unused, kept for compat)
-- Tempo detection item source: 0=Selected Item, 1+=index into detect_tempo_item_items
detect_tempo_item_index = 0
detect_tempo_item_items = {}  -- populated dynamically like align_stem_items
-- Tooltips (hover tips) enabled
tips_enabled = true
-- Import undo history (persisted to ExtState)
import_history = {}  -- array of {label, timestamp, track_guids={}, item_guids={}, region_indices={}, tempo_marker_indices={}}
EXTSTATE_IMPORT_HISTORY_KEY = "import_history"

function save_import_history()
    local entries = {}
    for _, entry in ipairs(import_history) do
        local tg = table.concat(entry.track_guids or {}, ",")
        local ig = table.concat(entry.item_guids or {}, ",")
        local ri = {}
        for _, v in ipairs(entry.region_indices or {}) do ri[#ri+1] = tostring(v) end
        local ti = {}
        for _, v in ipairs(entry.tempo_marker_indices or {}) do ti[#ti+1] = tostring(v) end
        entries[#entries+1] = (entry.label or "Import") .. "\t" ..
            tostring(entry.timestamp or 0) .. "\t" ..
            tg .. "\t" .. ig .. "\t" ..
            table.concat(ri, ",") .. "\t" .. table.concat(ti, ",")
    end
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_IMPORT_HISTORY_KEY, table.concat(entries, "\n"), true)
end

function load_import_history()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_IMPORT_HISTORY_KEY)
    if not saved or saved == "" then return end
    import_history = {}
    for line in saved:gmatch("[^\n]+") do
        local parts = {}
        for part in (line .. "\t"):gmatch("(.-)\t") do parts[#parts+1] = part end
        if #parts >= 6 then
            local entry = {
                label = parts[1],
                timestamp = tonumber(parts[2]) or 0,
                track_guids = {},
                item_guids = {},
                region_indices = {},
                tempo_marker_indices = {},
            }
            if parts[3] ~= "" then
                for g in parts[3]:gmatch("[^,]+") do entry.track_guids[#entry.track_guids+1] = g end
            end
            if parts[4] ~= "" then
                for g in parts[4]:gmatch("[^,]+") do entry.item_guids[#entry.item_guids+1] = g end
            end
            if parts[5] ~= "" then
                for v in parts[5]:gmatch("[^,]+") do entry.region_indices[#entry.region_indices+1] = tonumber(v) end
            end
            if parts[6] ~= "" then
                for v in parts[6]:gmatch("[^,]+") do entry.tempo_marker_indices[#entry.tempo_marker_indices+1] = tonumber(v) end
            end
            import_history[#import_history+1] = entry
        end
    end
end
-- load_import_history() is called after EXTSTATE_SECTION is defined below
-- Open exported file with external program
export_open_with_enabled = false
export_open_with_path = ""
-- Open containing folder after export
export_open_folder_enabled = false
-- Key signature for export
export_key_sig_enabled = true

-- Key signature lookup tables
keysig_root_names = {"C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"}
keysig_fifths_to_root_major = {[0]=0, [1]=7, [2]=2, [3]=9, [4]=4, [5]=11, [6]=6, [7]=1, [-1]=5, [-2]=10, [-3]=3, [-4]=8, [-5]=1, [-6]=6, [-7]=11}
keysig_fifths_to_root_minor = {[0]=9, [1]=4, [2]=11, [3]=6, [4]=1, [5]=8, [6]=3, [7]=10, [-1]=2, [-2]=7, [-3]=0, [-4]=5, [-5]=10, [-6]=3, [-7]=8}
keysig_root_to_fifths_major = {[0]=0, [7]=1, [2]=2, [9]=3, [4]=4, [11]=5, [6]=6, [1]=7, [5]=-1, [10]=-2, [3]=-3, [8]=-4, [1]=-5, [6]=-6}
keysig_root_to_fifths_minor = {[9]=0, [4]=1, [11]=2, [6]=3, [1]=4, [8]=5, [3]=6, [10]=7, [2]=-1, [7]=-2, [0]=-3, [5]=-4, [10]=-5, [3]=-6}
KEYSIG_MAJOR_HEX = 0xAB5
KEYSIG_MINOR_HEX = 0x5AD
keysig_scales_list = {
    {name = "Major", hex = 0xAB5},
    {name = "Natural minor", hex = 0x5AD},
}

-- Write/replace KSIG notation event at position 0 in a MIDI take
function keysig_write_event(take, root, notes_hex)
    -- Remove existing KSIG events at position 0
    local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
    if gotAllOK then
        local MIDIlen = MIDIstring:len()
        local tableEvents = {}
        local stringPos = 1
        local abs_pos = 0
        while stringPos < MIDIlen do
            local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
            abs_pos = abs_pos + offset
            local skip = false
            if abs_pos == 0 and msg:len() >= 3 and msg:byte(1) == 0xFF and msg:byte(2) == 0x0F then
                local evt_text = msg:sub(3)
                if evt_text:match("^KSIG ") then skip = true end
            end
            if not skip then
                table.insert(tableEvents, string.pack("i4Bs4", offset, flags, msg))
            end
            stringPos = newPos
        end
        reaper.MIDI_SetAllEvts(take, table.concat(tableEvents))
    end
    -- Insert new KSIG event
    local evt_str = string.format("KSIG root %d dir -1 notes 0x%03X", root, notes_hex)
    local packed = string.pack("BB", 0xFF, 0x0F) .. evt_str
    reaper.MIDI_InsertEvt(take, false, false, 0, packed)
    reaper.MIDI_Sort(take)
end

-- Forward declarations (globals) for variables defined later, needed by early functions
-- (Assigned in the GUI initialization section below)

-- Reverse mapping: settings name -> XML element name (for names that differ)
settings_to_xml_name = {}
for xml_name, settings_name in pairs(xml_to_settings_name) do
    settings_to_xml_name[settings_name] = xml_name
end

-- Initialize all to true (default) and capture defaults from articulation_map
for _, name in ipairs(articulation_names_ordered) do
    articulation_enabled[name] = true
    local entry = articulation_map[name] or articulation_map[settings_to_xml_name[name]]
    if entry then
        if type(entry.symbol) ~= "function" then
            articulation_default_symbol[name] = entry.symbol or ""
        else
            articulation_default_symbol[name] = "(dynamic)"
        end
        if type(entry.type) ~= "function" then
            articulation_default_type[name] = entry.type
        else
            articulation_default_type[name] = 1
        end
        if type(entry.replaces_fret) ~= "function" then
            articulation_default_replaces_fret[name] = entry.replaces_fret or false
        else
            articulation_default_replaces_fret[name] = false
        end
        if type(entry.no_prefix) ~= "function" then
            articulation_default_no_prefix[name] = entry.no_prefix or false
        else
            articulation_default_no_prefix[name] = false
        end
    else
        articulation_default_symbol[name] = ""
        articulation_default_type[name] = 1
        articulation_default_replaces_fret[name] = false
        articulation_default_no_prefix[name] = false
    end
end

EXTSTATE_SECTION = "konst_ImportMusicXML"
EXTSTATE_ART_KEY = "articulation_settings"
load_import_history()

-- Get the effective symbol for an articulation (override or default)
function get_art_symbol(name)
    return articulation_symbol_override[name] or articulation_default_symbol[name]
end

-- Get the effective type for an articulation (override or default)
function get_art_type(name)
    return articulation_type_override[name] or articulation_default_type[name]
end

-- Get the effective replaces_fret for an articulation (override or default)
function get_art_replaces_fret(name)
    if articulation_replaces_fret_override[name] ~= nil then
        return articulation_replaces_fret_override[name]
    end
    return articulation_default_replaces_fret[name]
end

-- Get the effective no_prefix for an articulation (override or default)
function get_art_no_prefix(name)
    if articulation_no_prefix_override[name] ~= nil then
        return articulation_no_prefix_override[name]
    end
    return articulation_default_no_prefix[name]
end

-- Serialize all articulation settings to a string
-- Format: "name|enabled|symbol|type;name2|enabled|symbol|type;..."
-- Symbol uses base64-like URL encoding to avoid delimiter collisions
function encode_sym(s)
    -- Percent-encode | ; and % characters
    return s:gsub("%%", "%%%%25"):gsub("|", "%%7C"):gsub(";", "%%3B")
end
function decode_sym(s)
    return s:gsub("%%3B", ";"):gsub("%%7C", "|"):gsub("%%25", "%%")
end

function serialize_articulation_settings()
    local parts = {}
    -- Fret number global settings as special entry
    local fret_en = fret_number_enabled and "1" or "0"
    local fret_typ = (fret_number_type ~= FRET_NUMBER_TYPE_DEFAULT) and tostring(fret_number_type) or ""
    table.insert(parts, "__fret__|" .. fret_en .. "||" .. fret_typ .. "||")
    -- Span line (duration lines) toggle
    local span_en = span_line_enabled and "1" or "0"
    table.insert(parts, "__span__|" .. span_en .. "||||")
    -- Highlight scan toggle
    local hl_en = highlight_scan_enabled and "1" or "0"
    table.insert(parts, "__hlscan__|" .. hl_en .. "||||")
    -- Export regions toggle
    local expreg_en = export_regions_enabled and "1" or "0"
    table.insert(parts, "__expreg__|" .. expreg_en .. "||||")
    -- MIDI program banks toggle
    local mpb_en = midi_program_banks_enabled and "1" or "0"
    table.insert(parts, "__midibank__|" .. mpb_en .. "||||")
    -- GM track names toggle
    local gmn_en = gm_name_tracks_enabled and "1" or "0"
    table.insert(parts, "__gmname__|" .. gmn_en .. "||||")
    -- Import position
    table.insert(parts, "__importpos__|" .. tostring(import_position_index) .. "||||")
    -- Align stem index
    table.insert(parts, "__alignstem__|" .. tostring(align_stem_index) .. "||||")
    -- Onset item index
    table.insert(parts, "__onsetitem__|" .. tostring(onset_item_index) .. "||||")
    -- Auto-load by region
    local alr_en = autoload_by_region_enabled and "1" or "0"
    table.insert(parts, "__autoloadrgn__|" .. alr_en .. "||||")
    -- Import timebase
    table.insert(parts, "__timebase__|" .. tostring(import_timebase_index) .. "||||")
    -- Tempo map frequency
    table.insert(parts, "__tempofreq__|" .. tostring(tempo_map_freq_index) .. "||||")
    -- Tempo time signature
    table.insert(parts, "__tempotimesig__|" .. tostring(tempo_timesig_index) .. "||||")
    -- Tempo detect method
    table.insert(parts, "__detectmethod__|" .. tostring(tempo_detect_method_index) .. "||||")
    -- Stretch markers on transients
    table.insert(parts, "__stretchmarkers__|" .. (detect_stretch_markers_enabled and "1" or "0") .. "||||")
    -- Use existing stretch markers for tempo detection
    table.insert(parts, "__useexistingmarkers__|" .. (detect_tempo_use_existing_markers and "1" or "0") .. "||||")
    -- Stretch marker slider parameters
    table.insert(parts, "__smthreshold__|" .. tostring(sm_threshold_dB) .. "||||")
    table.insert(parts, "__smsensitivity__|" .. tostring(sm_sensitivity_dB) .. "||||")
    table.insert(parts, "__smretrig__|" .. tostring(sm_retrig_ms) .. "||||")
    table.insert(parts, "__smoffset__|" .. tostring(sm_offset_ms) .. "||||")
    -- Detect tempo item index
    table.insert(parts, "__detectitem__|" .. tostring(detect_tempo_item_index) .. "||||")
    -- Tips enabled
    table.insert(parts, "__tips__|" .. (tips_enabled and "1" or "0") .. "||||")
    for _, name in ipairs(articulation_names_ordered) do
        local en = articulation_enabled[name] and "1" or "0"
        local sym = articulation_symbol_override[name] or ""
        local typ = articulation_type_override[name] or ""
        local rf = articulation_replaces_fret_override[name]
        local rf_str = rf == nil and "" or (rf and "1" or "0")
        local np = articulation_no_prefix_override[name]
        local np_str = np == nil and "" or (np and "1" or "0")
        table.insert(parts, name .. "|" .. en .. "|" .. encode_sym(sym) .. "|" .. tostring(typ) .. "|" .. rf_str .. "|" .. np_str)
    end
    return table.concat(parts, ";")
end

-- Deserialize string back to articulation settings tables
function deserialize_articulation_settings(str)
    if not str or str == "" then return end
    -- Support old format "name=0,name2=1,..." for backward compatibility
    if str:find("=") and not str:find("|") then
        for pair in str:gmatch("[^,]+") do
            local k, v = pair:match("^(.+)=(%d)$")
            if k and v and articulation_enabled[k] ~= nil then
                articulation_enabled[k] = (v == "1")
            end
        end
        return
    end
    -- New format "name|enabled|symbol|type|replaces_fret|no_prefix;..."
    for entry_str in str:gmatch("[^;]+") do
        local fields = {}
        for field in (entry_str .. "|"):gmatch("([^|]*)|?") do
            table.insert(fields, field)
        end
        -- Remove trailing empty from gmatch
        if fields[#fields] == "" then table.remove(fields) end
        local name = fields[1]
        if name == "__fret__" then
            -- Fret number global settings
            if fields[2] then fret_number_enabled = (fields[2] == "1") end
            if fields[4] and fields[4] ~= "" then
                local t = tonumber(fields[4])
                if t then fret_number_type = t end
            end
        elseif name == "__span__" then
            -- Span line (duration lines) toggle
            if fields[2] then span_line_enabled = (fields[2] == "1") end
        elseif name == "__hlscan__" then
            -- Highlight scan toggle
            if fields[2] then highlight_scan_enabled = (fields[2] == "1") end
        elseif name == "__expreg__" then
            -- Export regions toggle
            if fields[2] then export_regions_enabled = (fields[2] == "1") end
        elseif name == "__midibank__" then
            -- MIDI program banks toggle
            if fields[2] then midi_program_banks_enabled = (fields[2] == "1") end
        elseif name == "__gmname__" then
            -- GM track names toggle
            if fields[2] then gm_name_tracks_enabled = (fields[2] == "1") end
        elseif name == "__importpos__" then
            -- Import position
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx and idx >= 1 and idx <= #import_position_options then import_position_index = idx end
            end
        elseif name == "__alignstem__" then
            -- Align stem index
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx then align_stem_index = idx end
            end
        elseif name == "__onsetitem__" then
            -- Onset item index
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx then onset_item_index = idx end
            end
        elseif name == "__autoloadrgn__" then
            -- Auto-load by region
            if fields[2] then autoload_by_region_enabled = (fields[2] == "1") end
        elseif name == "__timebase__" then
            -- Import timebase
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx and idx >= 1 and idx <= #import_timebase_options then import_timebase_index = idx end
            end
        elseif name == "__tempofreq__" then
            -- Tempo map frequency
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx and idx >= 1 and idx <= #tempo_map_freq_options then tempo_map_freq_index = idx end
            end
        elseif name == "__tempotimesig__" then
            -- Tempo time signature
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx and idx >= 1 and idx <= #tempo_timesig_options then tempo_timesig_index = idx end
            end
        elseif name == "__detectmethod__" then
            -- Tempo detect method
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx and idx >= 1 and idx <= #tempo_detect_method_options then tempo_detect_method_index = idx end
            end
        elseif name == "__stretchmarkers__" then
            -- Stretch markers on transients
            if fields[2] then
                detect_stretch_markers_enabled = (fields[2] == "1")
            end
        elseif name == "__detectitem__" then
            if fields[2] then
                local idx = tonumber(fields[2])
                if idx then detect_tempo_item_index = idx end
            end
        elseif name == "__transientsens__" then
            -- legacy: ignore (replaced by __smthreshold__ / __smsensitivity__)
        elseif name == "__transientretrig__" then
            -- legacy: ignore (replaced by __smretrig__)
        elseif name == "__useexistingmarkers__" then
            if fields[2] then
                detect_tempo_use_existing_markers = (fields[2] ~= "0")
            end
        elseif name == "__smthreshold__" then
            if fields[2] then
                local v = tonumber(fields[2])
                if v then sm_threshold_dB = math.max(0, math.min(60, v)) end
            end
        elseif name == "__smsensitivity__" then
            if fields[2] then
                local v = tonumber(fields[2])
                if v then sm_sensitivity_dB = math.max(1, math.min(20, v)) end
            end
        elseif name == "__smretrig__" then
            if fields[2] then
                local v = tonumber(fields[2])
                if v then sm_retrig_ms = math.max(10, math.min(500, v)) end
            end
        elseif name == "__smoffset__" then
            if fields[2] then
                local v = tonumber(fields[2])
                if v then sm_offset_ms = math.max(-100, math.min(100, v)) end
            end
        elseif name == "__tips__" then
            if fields[2] then
                tips_enabled = (fields[2] ~= "0")
            end
        elseif name and articulation_enabled[name] ~= nil then
            if fields[2] then articulation_enabled[name] = (fields[2] == "1") end
            if fields[3] and fields[3] ~= "" then
                articulation_symbol_override[name] = decode_sym(fields[3])
            end
            if fields[4] and fields[4] ~= "" then
                local t = tonumber(fields[4])
                if t then articulation_type_override[name] = t end
            end
            if fields[5] and fields[5] ~= "" then
                articulation_replaces_fret_override[name] = (fields[5] == "1")
            end
            if fields[6] and fields[6] ~= "" then
                articulation_no_prefix_override[name] = (fields[6] == "1")
            end
        end
    end
end

-- Load from EXTSTATE (call at startup)
function load_articulation_settings()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_ART_KEY)
    deserialize_articulation_settings(saved)
end

-- Save to EXTSTATE (persist = true)
function save_articulation_settings()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_ART_KEY, serialize_articulation_settings(), true)
end

-- Restore defaults: re-enable everything, clear overrides
function restore_default_articulation_settings()
    fret_number_enabled = false
    fret_number_type = FRET_NUMBER_TYPE_DEFAULT
    span_line_enabled = false
    highlight_scan_enabled = true
    export_regions_enabled = true
    midi_program_banks_enabled = true
    gm_name_tracks_enabled = false
    import_position_index = 1
    align_stem_index = 0
    onset_item_index = 0
    autoload_by_region_enabled = false
    import_timebase_index = 1
    export_open_with_enabled = false
    export_open_with_path = ""
    export_open_folder_enabled = false
    export_key_sig_enabled = true
    detect_stretch_markers_enabled = false
    first_marker_is_bar1 = true
    detect_tempo_item_index = 0
    tips_enabled = true
    for _, name in ipairs(articulation_names_ordered) do
        articulation_enabled[name] = true
        articulation_symbol_override[name] = nil
        articulation_type_override[name] = nil
        articulation_replaces_fret_override[name] = nil
        articulation_no_prefix_override[name] = nil
    end
end

-- Load settings on script start
load_articulation_settings()

-- Load Insert at Mouse companion script settings
do
    local v = reaper.GetExtState("konst_InsertAtMouse", "enable_stretch")
    iam_enable_stretch = (v == "" or v == "1")
    v = reaper.GetExtState("konst_InsertAtMouse", "enable_take_tm")
    iam_enable_take_tm = (v == "" or v == "1")
    v = reaper.GetExtState("konst_InsertAtMouse", "enable_tempo")
    iam_enable_tempo   = (v == "" or v == "1")
end

-- Show-in-menu flags for all non-import settings rows
-- Keys: "hlscan","expreg","midibank","docker","winpos_last","winpos_mouse","defpath","lastpath","fret","span", and each articulation name
settings_menu_flags = {}
-- Initialize defaults (all hidden in main menu)
for _, name in ipairs(articulation_names_ordered) do settings_menu_flags[name] = false end
settings_menu_flags.hlscan = false
settings_menu_flags.expreg = false
settings_menu_flags.midibank = false
settings_menu_flags.gmname = false
settings_menu_flags.importpos = false
settings_menu_flags.alignstem = false
settings_menu_flags.onsetitem = false
settings_menu_flags.autoloadrgn = false
settings_menu_flags.timebase = false
settings_menu_flags.tempofreq = false
settings_menu_flags.tempotimesig = false
settings_menu_flags.detectmethod = false
settings_menu_flags.detectitem = false
settings_menu_flags.openwith = false
settings_menu_flags.openfolder = false
settings_menu_flags.keysig = false
settings_menu_flags.docker = false
settings_menu_flags.winpos_last = false
settings_menu_flags.winpos_mouse = false
settings_menu_flags.winsize = false
settings_menu_flags.defpath = false
settings_menu_flags.lastpath = false
settings_menu_flags.fret = false
settings_menu_flags.span = false
settings_menu_flags.smsnap = false
settings_menu_flags.temposnap = false
settings_menu_flags.midism = false

EXTSTATE_MENU_FLAGS_KEY = "settings_menu_flags"
function save_settings_menu_flags()
    local parts = {}
    for k, v in pairs(settings_menu_flags) do
        if v then table.insert(parts, k .. "=1") end
    end
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_MENU_FLAGS_KEY, table.concat(parts, ";"), true)
end
function load_settings_menu_flags()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_MENU_FLAGS_KEY)
    if not saved or saved == "" then return end
    for entry in saved:gmatch("[^;]+") do
        local k, v = entry:match("^(.+)=(%d)$")
        if k and v then settings_menu_flags[k] = (v == "1") end
    end
end
load_settings_menu_flags()

-- Foldable section state for settings view + main view
settings_fold = {general=false, export=false, import=false, transients=false, tempomap=false, miditools=false, insertmouse=false, articulation=false, artgrid=false}
main_settings_folded = false

EXTSTATE_FOLD_KEY = "settings_fold"
EXTSTATE_MAIN_FOLD_KEY = "main_settings_folded"
function save_fold_state()
    local parts = {}
    for k, v in pairs(settings_fold) do
        if v then table.insert(parts, k .. "=1") end
    end
    if main_settings_folded then table.insert(parts, "main=1") end
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_FOLD_KEY, table.concat(parts, ";"), true)
end
function load_fold_state()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_FOLD_KEY)
    if not saved or saved == "" then return end
    for entry in saved:gmatch("[^;]+") do
        local k, v = entry:match("^(.+)=(%d)$")
        if k and v and v == "1" then
            if k == "main" then
                main_settings_folded = true
            elseif settings_fold[k] ~= nil then
                settings_fold[k] = true
            end
        end
    end
end
load_fold_state()

-- Build list of extra settings visible in main menu (controlled by M checkboxes)
function get_visible_extra_settings()
    local items = {}
    -- GENERAL settings
    if settings_menu_flags.autofocus then table.insert(items, {key="autofocus", label="Auto-Focus"}) end
    if settings_menu_flags.stayontop then table.insert(items, {key="stayontop", label="Stay on Top"}) end
    if settings_menu_flags.font then table.insert(items, {key="font", label="Font"}) end
    if settings_menu_flags.docker then table.insert(items, {key="docker", label="Docker"}) end
    if settings_menu_flags.winpos_last then table.insert(items, {key="winpos_last", label="Last Position"}) end
    if settings_menu_flags.winpos_mouse then table.insert(items, {key="winpos_mouse", label="At Mouse"}) end
    if settings_menu_flags.winsize then table.insert(items, {key="winsize", label="Remember Size"}) end
    if settings_menu_flags.defpath then table.insert(items, {key="defpath", label="Default Path"}) end
    if settings_menu_flags.lastpath then table.insert(items, {key="lastpath", label="Last Opened"}) end
    -- EXPORT settings
    if settings_menu_flags.expreg then table.insert(items, {key="expreg", label="Export Regions"}) end
    if settings_menu_flags.midibank then table.insert(items, {key="midibank", label="MIDI Program Banks"}) end
    if settings_menu_flags.openwith then table.insert(items, {key="openwith", label="Open After Export"}) end
    if settings_menu_flags.openfolder then table.insert(items, {key="openfolder", label="Open Folder"}) end
    if settings_menu_flags.keysig then table.insert(items, {key="keysig", label="Key Signature"}) end
    -- IMPORT settings
    if settings_menu_flags.gmname then table.insert(items, {key="gmname", label="GM Track Names"}) end
    if settings_menu_flags.importpos then table.insert(items, {key="importpos", label="Import Position"}) end
    if settings_menu_flags.autoloadrgn then table.insert(items, {key="autoloadrgn", label="Auto-load by Region"}) end
    if settings_menu_flags.timebase then table.insert(items, {key="timebase", label="MIDI Timebase"}) end
    -- TEMPO MAP settings
    if settings_menu_flags.tempofreq then table.insert(items, {key="tempofreq", label="Tempo Map Freq"}) end
    if settings_menu_flags.tempotimesig then table.insert(items, {key="tempotimesig", label="Time Signature"}) end
    if settings_menu_flags.detectmethod then table.insert(items, {key="detectmethod", label="Detect Method"}) end
    if settings_menu_flags.detectitem then table.insert(items, {key="detectitem", label="Detect Item"}) end
    if settings_menu_flags.alignstem then table.insert(items, {key="alignstem", label="Align Stem"}) end
    if settings_menu_flags.onsetitem then table.insert(items, {key="onsetitem", label="Onset Item"}) end
    if settings_menu_flags.smsnap then table.insert(items, {key="smsnap", label="Snap SM to Grid"}) end
    if settings_menu_flags.temposnap then table.insert(items, {key="temposnap", label="Snap Tempo to SM"}) end
    if settings_menu_flags.midism then table.insert(items, {key="midism", label="MIDI SM Mode"}) end
    -- ARTICULATION settings
    if settings_menu_flags.hlscan then table.insert(items, {key="hlscan", label="Highlight Used"}) end
    if settings_menu_flags.fret then table.insert(items, {key="fret", label="Fret Number"}) end
    if settings_menu_flags.span then table.insert(items, {key="span", label="Duration Lines"}) end
    for i, name in ipairs(articulation_names_ordered) do
        if settings_menu_flags[name] then table.insert(items, {key=name, label=name, is_art=true, art_index=i}) end
    end
    return items
end

function get_extra_setting_checked(key)
    if key == "autofocus" then return auto_focus_enabled
    elseif key == "stayontop" then return stay_on_top_enabled
    elseif key == "font" then return true
    elseif key == "hlscan" then return highlight_scan_enabled
    elseif key == "expreg" then return export_regions_enabled
    elseif key == "midibank" then return midi_program_banks_enabled
    elseif key == "gmname" then return gm_name_tracks_enabled
    elseif key == "autoloadrgn" then return autoload_by_region_enabled
    elseif key == "openwith" then return export_open_with_enabled
    elseif key == "openfolder" then return export_open_folder_enabled
    elseif key == "keysig" then return export_key_sig_enabled
    elseif key == "docker" then return docker_enabled
    elseif key == "winpos_last" then return window_position_mode == "last"
    elseif key == "winpos_mouse" then return window_position_mode == "mouse"
    elseif key == "winsize" then return remember_window_size
    elseif key == "defpath" then return path_mode == "default"
    elseif key == "lastpath" then return path_mode == "last"
    elseif key == "fret" then return fret_number_enabled
    elseif key == "span" then return span_line_enabled
    elseif key == "smsnap" then return sm_snap_to_grid_enabled
    elseif key == "temposnap" then return tempo_snap_to_sm_enabled
    elseif key == "midism" then return midi_sm_enabled
    elseif key == "tempofreq" then return true
    elseif key == "tempotimesig" then return true
    elseif key == "detectmethod" then return true
    elseif key == "detectitem" then return true
    else return articulation_enabled[key] or false
    end
end

function toggle_extra_setting(key)
    if key == "autofocus" then auto_focus_enabled = not auto_focus_enabled
    elseif key == "stayontop" then stay_on_top_enabled = not stay_on_top_enabled; apply_stay_on_top(); save_stay_on_top_setting()
    elseif key == "font" then -- no toggle; font is always active
    elseif key == "hlscan" then
        highlight_scan_enabled = not highlight_scan_enabled
        if not highlight_scan_enabled then articulations_in_file = {} end
    elseif key == "expreg" then export_regions_enabled = not export_regions_enabled
    elseif key == "midibank" then midi_program_banks_enabled = not midi_program_banks_enabled
    elseif key == "gmname" then
        gm_name_tracks_enabled = not gm_name_tracks_enabled
        resize_window()
    elseif key == "autoloadrgn" then
        autoload_by_region_enabled = not autoload_by_region_enabled
    elseif key == "openwith" then export_open_with_enabled = not export_open_with_enabled
    elseif key == "openfolder" then export_open_folder_enabled = not export_open_folder_enabled
    elseif key == "keysig" then export_key_sig_enabled = not export_key_sig_enabled
    elseif key == "docker" then
        docker_enabled = not docker_enabled
        if docker_enabled then
            gfx.dock(docker_dock_values[docker_position] or 1)
        else
            gfx.dock(0)
        end
    elseif key == "winpos_last" then window_position_mode = "last"; save_window_position_mode("last")
    elseif key == "winpos_mouse" then window_position_mode = "mouse"; save_window_position_mode("mouse")
    elseif key == "winsize" then remember_window_size = not remember_window_size; save_remember_window_size_setting()
    elseif key == "defpath" then path_mode = "default"; save_path_mode("default")
    elseif key == "lastpath" then path_mode = "last"; save_path_mode("last")
    elseif key == "fret" then fret_number_enabled = not fret_number_enabled
    elseif key == "span" then span_line_enabled = not span_line_enabled
    elseif key == "smsnap" then sm_snap_to_grid_enabled = not sm_snap_to_grid_enabled
    elseif key == "temposnap" then tempo_snap_to_sm_enabled = not tempo_snap_to_sm_enabled
    elseif key == "midism" then midi_sm_enabled = not midi_sm_enabled; if not midi_sm_enabled then midi_sm_state = {} end
    elseif articulation_enabled[key] ~= nil then articulation_enabled[key] = not articulation_enabled[key]
    end
end

-- ============================================================================
-- Helper: convert drum instrument name to short text
-- ============================================================================
function drumNameToText(name)
    if drum_text_map[name] then
        return drum_text_map[name]
    end
    -- Fallback: first word, lowercased, without parentheses
    local simple = name:lower():gsub("[%(%)]", ""):gsub("%s+", " "):match("^%s*(%S+)") or name:lower()
    return simple
end

-- ============================================================================
-- Helper: get MIDI channel for a drum instrument name
-- ============================================================================
function getDrumChannel(instrument_name, default_channel)
    local chan = drum_channel_map[instrument_name]
    if chan then
        -- Convert 1‑based user channel to 0‑based for REAPER
        return chan - 1
    end
    return default_channel
end

-- ============================================================================
-- Helper: get MIDI pitch for a drum instrument name
-- ============================================================================
function getDrumPitch(instrument_name, default_pitch)
    local pitch = drum_pitch_map[instrument_name]
    if pitch then
        return pitch
    end
    return default_pitch or 60  -- Default to C3 if not found
end

-- ============================================================================
-- Helper: generate drum exstate string with 9 channels (one per string)
-- ============================================================================
function getDrumReaTabHeroState()
    -- Map channel (1-based) to default MIDI pitch for that channel
    -- This creates a 9-string setup for drums
    local channel_pitches = {
        36,  -- Channel 1: Kick (Bass Drum 1)
        38,  -- Channel 2: Snare (Acoustic Snare)
        42,  -- Channel 3: Hi-Hat Closed
        45,  -- Channel 4: Low Tom
        51,  -- Channel 5: Ride Cymbal 1
        49,  -- Channel 6: Crash Cymbal 1
        56,  -- Channel 7: Cowbell
        60,  -- Channel 8: Hi Bongo
        70,  -- Channel 9: Maracas
    }
    
    local notes_str = table.concat(channel_pitches, ",")
    return "{cases=24,strings={" .. notes_str .. "}} "
end

-- ============================================================================
-- NOTE TO MIDI SEMITONE MAPPING
-- ============================================================================
note_to_semitone = {
    ["C"] = 0,
    ["D"] = 2,
    ["E"] = 4,
    ["F"] = 5,
    ["G"] = 7,
    ["A"] = 9,
    ["B"] = 11
}

-- ============================================================================
-- Helper: parse guitar tuning from staff-tuning elements
-- ============================================================================
function parseTuning(attrs, is_drum)
    if is_drum then
        return nil  -- Drums don't have tuning
    end
    
    if not attrs then return nil end
    
    -- Find all staff-tuning elements
    local staff_tunings = findChildren(attrs, "staff-tuning")
    if not staff_tunings or #staff_tunings == 0 then
        return nil
    end
    
    -- Sort by line number to get correct string order (line 1 = lowest/thickest string)
    table.sort(staff_tunings, function(a, b)
        local line_a = tonumber(getAttribute(a, "line")) or 0
        local line_b = tonumber(getAttribute(b, "line")) or 0
        return line_a < line_b
    end)
    
    local tuning = {}
    for _, tuning_elem in ipairs(staff_tunings) do
        local step = getChildText(tuning_elem, "tuning-step")
        local alter = (tonumber(getChildText(tuning_elem, "tuning-alter")) or 0)
        local octave = (tonumber(getChildText(tuning_elem, "tuning-octave")) or 2)
        
        if step then
            local semitone_offset = note_to_semitone[step] or 0
            local midi_note = (octave + 1) * 12 + semitone_offset + alter
            table.insert(tuning, midi_note)
        end
    end
    
    return (#tuning > 0) and tuning or nil
end

-- ============================================================================
-- Helper: convert tuning array to ReaTabHero format string
-- ============================================================================
function tuningToReaTabHeroString(tuning)
    if not tuning or #tuning == 0 then return nil end
    
    local notes_str = table.concat(tuning, ",")
    -- Format: {cases=24,strings={40,45,50,55,59,64}} 
    return "{cases=24,strings={" .. notes_str .. "}} "
end

-- ============================================================================
-- Helper: get default tuning for guitar (standard DADGAD, drop D, open tunings, etc.)
-- ============================================================================
function getDefaultGuitarTuning()
    -- Standard guitar tuning: E A D G B E
    return {40, 45, 50, 55, 59, 64}
end

-- ============================================================================
-- Helper: get default tuning for bass
-- ============================================================================
function getDefaultBassTuning()
    -- Standard 4-string bass tuning: E A D G
    return {28, 33, 38, 43}
end

-- ============================================================================
-- Helper: get default tuning for 5-string bass
-- ============================================================================
function getDefault5StringBassTuning()
    -- Standard 5-string bass tuning: B E A D G
    return {23, 28, 33, 38, 43}
end

-- ============================================================================
-- Helper: read active tuning from Fretboard script ExtState
-- Returns array of MIDI note numbers (low to high), or nil
-- ============================================================================
-- Compact tuning data mirroring konst_Fretboard INSTRUMENTS table (midi arrays,
-- ordered high-to-low as stored in Fretboard).
fretboard_tunings = {
    -- Guitar 6-String
    {{ 64,59,55,50,45,40 }, { 64,59,55,50,45,38 }, { 63,58,54,49,44,37 },
     { 62,57,53,48,43,36 }, { 61,56,52,47,42,35 }, { 59,54,50,45,40,33 },
     { 62,59,55,50,43,38 }, { 62,57,54,50,45,38 }, { 64,59,56,52,47,40 },
     { 64,61,57,52,45,40 }, { 64,60,55,48,43,36 }, { 62,57,55,50,45,38 },
     { 62,59,55,50,45,38 }, { 63,58,54,49,44,39 }, { 62,57,53,48,43,38 },
     { 61,56,52,47,42,37 }, { 60,55,51,46,41,36 }, { 64,59,55,50,45,36 },
     { 62,57,53,50,45,38 }, { 64,59,55,52,45,40 }, { 62,57,55,50,43,36 }},
    -- Guitar 7-String
    {{ 64,59,55,50,45,40,35 }, { 64,59,55,50,45,40,33 }, { 64,59,55,50,45,38,31 },
     { 63,58,54,49,44,39,34 }, { 62,57,53,48,43,38,33 }},
    -- Guitar 8-String
    {{ 64,59,55,50,45,40,35,30 }, { 64,59,55,50,45,40,35,28 }, { 63,58,54,49,44,39,34,29 }},
    -- Guitar 12-String
    {{ 64,64,59,59,55,55,50,50,45,45,40,52 }, { 63,63,58,58,54,54,49,49,44,44,39,51 },
     { 62,62,57,57,54,54,50,50,45,45,38,50 }},
    -- Djent 2018
    {{ 81,76,71,67,62,57,52,47,42,37,32,27,28,23,18,13,15,16 }},
    -- Bass 4-String
    {{ 43,38,33,28 }, { 43,38,33,26 }, { 41,36,31,24 }, { 40,35,30,23 },
     { 42,37,32,27 }, { 41,36,31,26 }, { 43,38,34,31 }},
    -- Bass 5-String
    {{ 43,38,33,28,23 }, { 43,38,33,28,21 }, { 48,43,38,33,28 }, { 48,43,38,33,28 },
     { 42,37,32,27,22 }},
    -- Bass 6-String
    {{ 48,43,38,33,28,23 }, { 47,42,37,32,27,22 }},
    -- Ukulele Soprano
    {{ 67,64,60,69 }, { 67,64,60,55 }, { 69,66,62,57 }},
    -- Ukulele Concert
    {{ 67,64,60,69 }, { 67,64,60,55 }},
    -- Ukulele Tenor
    {{ 67,64,60,69 }, { 67,64,60,55 }, { 69,66,62,57 }},
    -- Ukulele Baritone
    {{ 64,59,55,50 }, { 64,59,55,38 }},
    -- Violin
    {{ 76,69,62,55 }, { 76,69,62,57 }, { 75,68,61,54 }},
    -- Viola
    {{ 69,62,55,48 }},
    -- Cello
    {{ 57,50,43,36 }, { 57,50,43,38 }},
    -- Contrabass
    {{ 43,38,33,28 }, { 45,40,35,30 }, { 43,38,33,28,23 }, { 48,43,38,33,28 }, { 40,38,33,28 }},
    -- Banjo 5-String
    {{ 62,59,55,50,67 }, { 60,60,55,50,67 }, { 62,57,54,50,69 }, { 62,55,55,50,67 }, { 62,57,55,50,67 }},
    -- Banjo 4-String Tenor
    {{ 62,55,48,41 }, { 64,59,55,50 }, { 64,57,50,43 }},
    -- Mandolin
    {{ 76,76,69,69,62,62,55,55 }, { 74,74,67,67,62,62,55,55 }, { 74,74,67,67,62,62,55,55 }},
    -- Bouzouki (Greek)
    {{ 69,69,65,65,60,60,53,53 }, { 69,69,62,62,57,57 }},
    -- Bouzouki (Irish)
    {{ 62,62,57,57,50,50,62,62 }, { 62,62,57,57,45,45,62,62 }},
    -- Lute (6-course)
    {{ 64,59,55,50,45,40 }, { 65,60,55,50,45,38 }},
    -- Sitar
    {{ 50,45,38,38,45,50,62 }},
    -- Piano (range-based, not midi tuning)
    nil,
    -- Shovel
    {{ 43,50,55 }},
}

function getTuningFromFretboard()
    local inst_idx = tonumber(reaper.GetExtState("konst_Fretboard", "instrument"))
    local tun_idx  = tonumber(reaper.GetExtState("konst_Fretboard", "tuning"))
    if not inst_idx or not tun_idx then return nil end
    local inst = fretboard_tunings[inst_idx]
    if not inst then return nil end
    local midi = inst[tun_idx]
    if not midi then return nil end
    -- Fretboard stores high-to-low; reverse to low-to-high (matching Import convention)
    local reversed = {}
    for i = #midi, 1, -1 do
        reversed[#reversed + 1] = midi[i]
    end
    return reversed
end

-- Get active tuning: Fretboard ExtState -> default guitar
function getActiveTuning()
    return getTuningFromFretboard() or getDefaultGuitarTuning()
end

-- ============================================================================
-- Helper: detect if a track name indicates it's a bass
-- ============================================================================
function isBassTrack(track_name)
    if not track_name then return false end
    local name_lower = track_name:lower()
    return name_lower:find("bass") ~= nil
end

-- ============================================================================
-- Helper: detect if a track name indicates it's a 5-string bass
-- ============================================================================
function is5StringBassTrack(track_name)
    if not track_name then return false end
    local name_lower = track_name:lower()
    return (name_lower:find("5") ~= nil or name_lower:find("five") ~= nil) and name_lower:find("bass") ~= nil
end

-- ============================================================================
-- Helper: detect if a track name indicates it's a drum track
-- ============================================================================
function isDrumTrack(track_name)
    if not track_name then return false end
    local name_lower = track_name:lower()
    return name_lower:find("drum") ~= nil or name_lower:find("percussion") ~= nil or name_lower:find("kit") ~= nil
end

-- ============================================================================
-- Detect transients on an audio item using dual envelope follower.
-- Returns sorted list of {proj = project_time, src = source_time, strength = env1}
-- Each position is refined to the actual sample peak within a short window.
-- ============================================================================
function detect_audio_transients(audio_item, audio_take, opts)
  if not audio_item or not audio_take then return {} end
  local PCM_src = reaper.GetMediaItemTake_Source(audio_take)
  local srate = reaper.GetMediaSourceSampleRate(PCM_src)
  if not srate or srate <= 0 then return {} end

  local sens_dB = (opts and opts.sensitivity_dB) or 7
  local retrig_ms = (opts and opts.retrig_ms) or 60
  local threshold_dB = (opts and opts.threshold_dB) or 60

  local da_pos  = reaper.GetMediaItemInfo_Value(audio_item, "D_POSITION")
  local da_len  = reaper.GetMediaItemInfo_Value(audio_item, "D_LENGTH")
  local da_offs = reaper.GetMediaItemTakeInfo_Value(audio_take, "D_STARTOFFS")
  local da_rate = reaper.GetMediaItemTakeInfo_Value(audio_take, "D_PLAYRATE")
  if da_rate == 0 then da_rate = 1 end

  local orig_rate = da_rate
  if da_rate ~= 1 then
    reaper.SetMediaItemTakeInfo_Value(audio_take, "D_PLAYRATE", 1)
    reaper.SetMediaItemInfo_Value(audio_item, "D_LENGTH", da_len * da_rate)
  end

  local range_start = da_offs
  local range_len = da_len * orig_rate
  local range_len_smpls = math.floor(range_len * srate)

  -- Detection parameters (use passed-in sensitivity, retrigger, and threshold)
  local Threshold   = 10 ^ (-threshold_dB / 20)
  local Sensitivity = 10 ^ (sens_dB / 20)
  local Retrig      = math.floor((retrig_ms / 1000) * srate)
  local PEAK_WINDOW = math.floor(0.005 * srate)  -- 5ms forward window for peak refinement

  local ga1 = math.exp(-1 / (srate * 0.001))
  local gr1 = math.exp(-1 / (srate * 0.010))
  local ga2 = math.exp(-1 / (srate * 0.007))
  local gr2 = math.exp(-1 / (srate * 0.015))

  local env1 = 0
  local env2 = 0
  local retrig_cnt = Retrig + 1

  local block_size = 65536
  local n_blocks = math.floor(range_len_smpls / block_size)
  local starttime = range_start
  local trigger_positions = {}  -- raw trigger source-time positions + sample index info

  -- Pass 1: detect trigger points
  local AA = reaper.CreateTakeAudioAccessor(audio_take)
  for cur_block = 0, n_blocks do
    local sz = cur_block == n_blocks
      and (range_len_smpls - block_size * n_blocks) or block_size
    if sz <= 0 then break end
    local buf = reaper.new_array(sz)
    reaper.GetAudioAccessorSamples(AA, srate, 1, starttime, sz, buf)
    for s = 1, sz do
      local inp = math.abs(buf[s])
      env1 = inp > env1 and (inp + ga1 * (env1 - inp)) or (inp + gr1 * (env1 - inp))
      env2 = inp > env2 and (inp + ga2 * (env2 - inp)) or (inp + gr2 * (env2 - inp))
      if retrig_cnt > Retrig and env1 > Threshold and env2 > 0 and env1 / env2 > Sensitivity then
        local trigger_src = starttime + (s - 1) / srate
        -- Scan forward in current buffer for peak within 5ms window
        local peak_val = inp
        local peak_offset = 0
        local scan_end = math.min(sz, s + PEAK_WINDOW)
        for ps = s + 1, scan_end do
          local pv = math.abs(buf[ps])
          if pv > peak_val then
            peak_val = pv
            peak_offset = ps - s
          end
        end
        local peak_src = trigger_src + peak_offset / srate
        trigger_positions[#trigger_positions + 1] = {
          src = peak_src,
          strength = env1,
          env2 = env2
        }
        retrig_cnt = 0
      else
        retrig_cnt = retrig_cnt + 1
      end
    end
    starttime = starttime + block_size / srate
  end
  reaper.DestroyAudioAccessor(AA)

  -- Restore playrate
  if orig_rate ~= 1 then
    reaper.SetMediaItemTakeInfo_Value(audio_take, "D_PLAYRATE", orig_rate)
    reaper.SetMediaItemInfo_Value(audio_item, "D_LENGTH", da_len)
  end

  -- Convert to project time and build result
  local proj_start = opts and opts.proj_start
  local proj_end   = opts and opts.proj_end
  local results = {}
  for _, tp in ipairs(trigger_positions) do
    local pt = da_pos + (tp.src - da_offs) / orig_rate
    if (not proj_start or pt >= proj_start) and (not proj_end or pt <= proj_end) then
      results[#results + 1] = {
        proj = pt,
        src = tp.src,
        strength = tp.strength,
        env2 = tp.env2
      }
    end
  end
  table.sort(results, function(a, b) return a.proj < b.proj end)
  return results, da_pos, da_offs, orig_rate
end

-- Helper: find drum audio item in the project
function find_drum_audio_item()
  local n_items = reaper.CountMediaItems(0)
  for ii = 0, n_items - 1 do
    local ai = reaper.GetMediaItem(0, ii)
    local at = reaper.GetActiveTake(ai)
    if at and not reaper.TakeIsMIDI(at) then
      local ai_track = reaper.GetMediaItemTrack(ai)
      local _, ai_track_name = reaper.GetSetMediaTrackInfo_String(ai_track, "P_NAME", "", false)
      if isDrumTrack(ai_track_name) then
        return ai, at
      end
    end
  end
  return nil, nil
end

-- ============================================================================
-- Pre-process Guitar Pro processing instructions (<?GP ... ?>)
-- Converts them to parseable <_gp_> elements so their content is accessible
-- in the parsed tree (e.g. <letring/> detection).
-- ============================================================================
function preprocess_gp_pis(xml)
  local pieces = {}
  local pos = 1
  local len = #xml
  while pos <= len do
    local s = xml:find("<%?GP", pos)
    if not s then
      pieces[#pieces + 1] = xml:sub(pos)
      break
    end
    pieces[#pieces + 1] = xml:sub(pos, s - 1)
    local e = xml:find("%?>", s + 4)
    if not e then
      pieces[#pieces + 1] = xml:sub(s)
      break
    end
    local content = xml:sub(s + 4, e - 1)
    pieces[#pieces + 1] = "<_gp_>"
    pieces[#pieces + 1] = content
    pieces[#pieces + 1] = "</_gp_>"
    pos = e + 2
  end
  return table.concat(pieces)
end

-- ============================================================================
-- Robust XML parser (handles CDATA, processing instructions, comments, etc.)
-- ============================================================================
function parseXML(xml)
  local root
  local stack = {}
  local i = 1
  local n = #xml

  -- Helper to skip an XML declaration (<?xml ... ?>)
  local function skipDeclaration()
    if xml:sub(i, i+4) == "<?xml" then
      local close = xml:find("?>", i)
      if close then i = close + 2 end
    end
  end

  -- Helper to skip a processing instruction (<? ... ?>)
  local function skipProcessingInstruction()
    if xml:sub(i, i+1) == "<?" then
      local close = xml:find("?>", i)
      if close then i = close + 2 end
    end
  end

  -- Helper to skip a DOCTYPE declaration
  local function skipDOCTYPE()
    if xml:sub(i, i+8) == "<!DOCTYPE" then
      local level = 1
      local pos = i + 8
      while pos <= n do
        local ch = xml:sub(pos, pos)
        if ch == '<' then
          -- possible nested? ignore
        elseif ch == '>' then
          level = level - 1
          if level == 0 then
            i = pos + 1
            break
          end
        end
        pos = pos + 1
      end
    end
  end

  -- Helper to skip a comment (<!-- ... -->)
  local function skipComment()
    if xml:sub(i, i+3) == "<!--" then
      local close = xml:find("-->", i)
      if close then i = close + 3 end
    end
  end

  -- Helper to parse a tag (either opening or self-closing)
  local function parseTag()
    local tagStart = i
    local closePos = xml:find("[>/]", i)
    if not closePos then return nil end
    local tagContent = xml:sub(i, closePos-1)
    i = closePos

    local name, attrStr = tagContent:match("^%s*([^%s]+)%s*(.*)$")
    if not name then name = tagContent:match("^%s*([^%s]+)%s*$") end
    local attrs = {}
    if attrStr and attrStr ~= "" then
      for k, v in attrStr:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do
        attrs[k] = v
      end
    end
    return name, attrs
  end

  while i <= n do
    -- Skip XML declaration, DOCTYPE, processing instructions, comments, CDATA
    skipDeclaration()
    skipDOCTYPE()
    skipProcessingInstruction()
    skipComment()

    -- Handle CDATA sections (capture text)
    if xml:sub(i, i+8) == "<![CDATA[" then
      local start = i + 9  -- after "<![CDATA["
      local close = xml:find("]]>", i)
      if close then
        local text = xml:sub(start, close-1)
        -- Add text node to current parent
        local parent = stack[#stack]
        if parent then
          table.insert(parent.children, { name = "text", text = text })
        end
        i = close + 3
        goto continue
      end
    end

    local ch = xml:sub(i, i)
    if ch == '<' then
      i = i + 1
      if xml:sub(i, i) == '/' then
        -- Closing tag
        local closePos = xml:find(">", i)
        if closePos then
          local tagName = xml:sub(i+1, closePos-1)
          i = closePos + 1
          local node = table.remove(stack)
          if #stack == 0 then
            root = node
          else
            local parent = stack[#stack]
            table.insert(parent.children, node)
          end
        end
      elseif xml:sub(i, i+3) == '!--' then
        -- Already handled by skipComment() above, but just in case
        local commentEnd = xml:find("-->", i-1)  -- i is after "<"
        if commentEnd then i = commentEnd + 3 end
      else
        -- Opening tag
        local name, attrs = parseTag()
        if name then
          local selfClose = (xml:sub(i, i) == '/')
          if selfClose then i = i + 1 end
          if xml:sub(i, i) == '>' then i = i + 1 end

          local node = { name = name, attrs = attrs or {}, children = {} }
          if not selfClose then
            table.insert(stack, node)
          else
            if #stack == 0 then
              root = node
            else
              local parent = stack[#stack]
              table.insert(parent.children, node)
            end
          end
        else
          -- Malformed tag – skip until next '>'
          local gt = xml:find(">", i)
          if gt then i = gt + 1 end
        end
      end
    else
      -- Text content
      local textStart = i
      while i <= n and xml:sub(i, i) ~= '<' do
        i = i + 1
      end
      local text = xml:sub(textStart, i-1)
      if text:match("%S") then
        local parent = stack[#stack]
        if parent then
          table.insert(parent.children, { name = "text", text = text })
        end
      end
    end
    ::continue::
  end

  return root
end

-- ============================================================================
-- Helper functions (unchanged)
-- ============================================================================
function findChild(node, name)
  if not node or not node.children then return nil end
  for _, child in ipairs(node.children) do
    if child.name == name then return child end
  end
  return nil
end

function findChildren(node, name)
  local result = {}
  if not node or not node.children then return result end
  for _, child in ipairs(node.children) do
    if child.name == name then table.insert(result, child) end
  end
  return result
end

function getNodeText(node)
  if not node or not node.children then return "" end
  local parts = {}
  for _, child in ipairs(node.children) do
    if child.name == "text" then
      table.insert(parts, child.text)
    end
  end
  return table.concat(parts)
end

function getChildText(node, childName)
  local child = findChild(node, childName)
  if child then
    return getNodeText(child)
  end
  return ""
end

function getChildValue(node, childName)
  local txt = getChildText(node, childName)
  return tonumber(txt)
end

function getAttribute(node, name)
  return node and node.attrs and node.attrs[name]
end

-- ============================================================================
-- Articulation processing (modified to skip slides)
-- ============================================================================

-- Analyse a sequence of <bend> nodes and return up to two events:
--   1. A fret-replacing shape event (bend / bend release / pre-bend articulation)
--   2. An amount label event (1/2 bend, full bend, … articulation)
-- Everything is controlled via the standard articulation settings rows.
function make_bend_events(bend_nodes, default_fret)
  if #bend_nodes == 0 then return {} end

  local n1      = bend_nodes[1]
  local a1_node = findChild(n1, "bend-alter")
  local a1      = (a1_node and tonumber(getNodeText(a1_node))) or 0
  local has_pre = findChild(n1, "pre-bend") ~= nil
  local has_release = false
  for _, bn in ipairs(bend_nodes) do
    if findChild(bn, "release") then has_release = true; break end
  end

  -- Shape articulation name
  local shape_name
  if has_release then
    shape_name = "bend release"
  elseif has_pre then
    shape_name = "pre-bend"
  else
    shape_name = "bend"
  end

  -- Amount articulation name mapped from semitone count
  local amount_name_map = {
    [1] = "1/2 bend", [2] = "full bend", [3] = "1 1/2 bend",
    [4] = "2 bend",   [5] = "2 1/2 bend", [6] = "3 bend",
  }
  local amount_name = amount_name_map[a1]

  local result = {}

  -- Shape event
  if articulation_enabled[shape_name] ~= false then
    local sym = get_art_symbol(shape_name) or ""
    sym = sym:gsub("%%d", tostring(default_fret))
    table.insert(result, {
      type          = get_art_type(shape_name),
      symbol        = sym,
      no_prefix     = get_art_no_prefix(shape_name),
      replaces_fret = get_art_replaces_fret(shape_name),
    })
  end

  -- Amount label event
  if amount_name and articulation_enabled[amount_name] ~= false then
    local sym = get_art_symbol(amount_name) or ""
    if sym ~= "" then
      table.insert(result, {
        type          = get_art_type(amount_name),
        symbol        = sym,
        no_prefix     = get_art_no_prefix(amount_name),
        replaces_fret = get_art_replaces_fret(amount_name),
      })
    end
  elseif not amount_name and a1 > 0 then
    -- Fallback for unusual semitone counts not covered by the named articulations
    local steps = a1 / 2
    local whole = math.floor(steps)
    local label = (steps - whole >= 0.4) and
        (whole == 0 and "1/2" or (tostring(whole) .. " 1/2")) or tostring(whole)
    table.insert(result, { type = 6, symbol = label, no_prefix = true, replaces_fret = false })
  end

  return result
end

function getArticulationEvents(note_node, default_fret)
  local events = {}
  if not note_node then return events end

  local notations = findChild(note_node, "notations")

  local function addEvent(entry, node, art_name)
    if not entry then return end
    -- Check if this articulation is disabled in settings
    local lookup = art_name or (node and node.name)
    if lookup and articulation_enabled[lookup] == false then return end

    local ev = {}

    -- Resolve type (could be a function), then apply override
    if articulation_type_override[lookup] then
      ev.type = articulation_type_override[lookup]
    elseif type(entry.type) == "function" then
      ev.type = entry.type(node)
    else
      ev.type = entry.type
    end

    -- Resolve symbol, then apply override
    local sym
    if articulation_symbol_override[lookup] then
      sym = articulation_symbol_override[lookup]
    elseif type(entry.symbol) == "function" then
      sym = entry.symbol(node)
    else
      sym = entry.symbol
    end

    -- Resolve replaces_fret, then apply override
    if articulation_replaces_fret_override[lookup] ~= nil then
      ev.replaces_fret = articulation_replaces_fret_override[lookup]
    elseif type(entry.replaces_fret) == "function" then
      ev.replaces_fret = entry.replaces_fret(node)
    else
      ev.replaces_fret = entry.replaces_fret
    end

    -- Resolve no_prefix, then apply override
    if articulation_no_prefix_override[lookup] ~= nil then
      ev.no_prefix = articulation_no_prefix_override[lookup]
    elseif type(entry.no_prefix) == "function" then
      ev.no_prefix = entry.no_prefix(node)
    else
      ev.no_prefix = entry.no_prefix or false
    end

    if sym and sym:find("%%d") then
      sym = sym:gsub("%%d", tostring(default_fret))
    end
    if sym and sym:find("%%h") then
      sym = sym:gsub("%%h", tostring(default_fret + 12))
    end

    ev.symbol = sym
    ev.is_suffix = entry.is_suffix or false
    ev.art_name = lookup   -- store resolved name for span tracking
    table.insert(events, ev)
  end

  if notations then
    local articulations = findChild(notations, "articulations")
    if articulations and articulations.children then
      for _, child in ipairs(articulations.children) do
        local entry = articulation_map[child.name]
        if entry then addEvent(entry, child, xml_to_settings_name[child.name]) end
      end
    end

    local technical = findChild(notations, "technical")
    if technical and technical.children then
      for _, child in ipairs(technical.children) do
        if not bend_names[child.name] then  -- bends handled as a sequence below
          if child.name == "harmonic" then
            -- Distinguish natural (<harmonic><natural/>…) from artificial (<harmonic/>)
            local art_key = findChild(child, "natural") and "natural-harmonic" or "artificial-harmonic"
            local art_entry = articulation_map[art_key]
            if art_entry then addEvent(art_entry, child, art_key) end
          else
            local entry = articulation_map[child.name]
            if entry then addEvent(entry, child, xml_to_settings_name[child.name]) end
          end
        end
      end
    end

    -- Process all <bend> children of <technical> as one or more marker events
    if technical then
      local bend_nodes = {}
      for _, child in ipairs(technical.children or {}) do
        if child.name == "bend" then table.insert(bend_nodes, child) end
      end
      for _, bev in ipairs(make_bend_events(bend_nodes, default_fret)) do
        table.insert(events, bev)
      end
    end

    -- All other children of notations (including slides) but we skip slide names here
    for _, child in ipairs(notations.children or {}) do
      if child.name ~= "articulations" and child.name ~= "technical" then
        if not slide_names[child.name] then   -- <-- skip slides
          local entry = articulation_map[child.name]
          if entry then addEvent(entry, child, xml_to_settings_name[child.name]) end
        end
      end
    end
  end

  -- Route <play>/<mute> to the appropriate static entry based on mute text
  local play = findChild(note_node, "play")
  if play and play.children then
    for _, child in ipairs(play.children) do
      if child.name == "mute" then
        local mute_text = getNodeText(child)
        if mute_text == "palm" then
          local entry = articulation_map["palm mute"]
          if entry then addEvent(entry, child, "palm") end
        elseif mute_text == "straight" then
          local entry = articulation_map["straight mute"]
          if entry then addEvent(entry, child, "straight") end
        end
      end
    end
  end

  -- Detect let ring from GP processing instructions (<?GP <root><letring/></root>?>)
  -- converted to <_gp_> elements by preprocess_gp_pis() before parsing.
  if articulation_enabled["letring"] ~= false then
    for _, child in ipairs(note_node.children or {}) do
      if child.name == "_gp_" then
        local gp_root = findChild(child, "root")
        if gp_root and findChild(gp_root, "letring") then
          local entry = articulation_map["letring"]
          if entry then addEvent(entry, nil, "letring") end
          break
        end
      end
    end
  end

  -- Detect vibrato from GP processing instructions (<?GP <root><vibrato type="..."/></root>?>)
  -- converted to <_gp_> elements by preprocess_gp_pis() before parsing.
  if articulation_enabled["vibrato"] ~= false then
    for _, child in ipairs(note_node.children or {}) do
      if child.name == "_gp_" then
        local gp_root = findChild(child, "root")
        if gp_root and findChild(gp_root, "vibrato") then
          local entry = articulation_map["vibrato"]
          if entry then addEvent(entry, nil, "vibrato") end
          break
        end
      end
    end
  end

  return events
end

-- ============================================================================
-- Helper to resolve slide info from the articulation map
-- ============================================================================
function getSlideInfo(slide_node, default_fret)
  -- Check if this slide articulation is disabled in settings
  if slide_node and articulation_enabled[slide_node.name] == false then return nil end
  local entry = articulation_map[slide_node.name]
  if not entry then return nil end
  local info = {}
  local slide_name = slide_node.name
  -- resolve type, then apply override
  if articulation_type_override[slide_name] then
    info.type = articulation_type_override[slide_name]
  elseif type(entry.type) == "function" then
    info.type = entry.type(slide_node)
  else
    info.type = entry.type
  end
  -- resolve symbol, then apply override
  if articulation_symbol_override[slide_name] then
    info.symbol = articulation_symbol_override[slide_name]
  elseif type(entry.symbol) == "function" then
    info.symbol = entry.symbol(slide_node)
  else
    info.symbol = entry.symbol
  end
  if info.symbol and info.symbol:find("%%d") then
    info.symbol = info.symbol:gsub("%%d", tostring(default_fret))
  end
  -- resolve no_prefix, then apply override
  if articulation_no_prefix_override[slide_name] ~= nil then
    info.no_prefix = articulation_no_prefix_override[slide_name]
  elseif type(entry.no_prefix) == "function" then
    info.no_prefix = entry.no_prefix(slide_node)
  else
    info.no_prefix = entry.no_prefix or false
  end
  -- resolve replaces_fret, then apply override
  if articulation_replaces_fret_override[slide_name] ~= nil then
    info.replaces_fret = articulation_replaces_fret_override[slide_name]
  elseif type(entry.replaces_fret) == "function" then
    info.replaces_fret = entry.replaces_fret(slide_node)
  else
    info.replaces_fret = entry.replaces_fret or false
  end
  return info
end

-- ============================================================================
-- Insert tempo/time signature markers into REAPER
-- ============================================================================
function insert_markers(markers, offset)
  offset = offset or 0
  -- Convert to sorted list
  local times = {}
  for t in pairs(markers) do table.insert(times, t) end
  table.sort(times)

  for _, t in ipairs(times) do
    local m = markers[t]
    reaper.SetTempoTimeSigMarker(
      0,           -- project
      -1,          -- index (-1 = add new)
      t + offset,  -- time in seconds (offset by import position)
      -1, -1,      -- measure & beat (auto)
      m.tempo or -1,
      m.beats or -1,
      m.beat_type or -1,
      false        -- linear tempo
    )
  end
  reaper.UpdateTimeline()
end

-- ============================================================================
-- Insert sections as regions
-- ============================================================================
function insert_regions(sections, max_seconds, offset)
  if not sections or #sections == 0 then return end
  offset = offset or 0
  
  -- Sort sections by start time
  table.sort(sections, function(a, b) return a.start_time < b.start_time end)
  
  -- Create regions for each section
  for i, section in ipairs(sections) do
    local start_time = section.start_time + offset
    -- End time is either the next section's start time or the end of the project
    local end_time
    if i < #sections then
      end_time = sections[i + 1].start_time + offset
    else
      -- Last section extends to the end of the project
      end_time = max_seconds + offset
    end
    
    -- Ensure end_time is at least start_time + small buffer
    if end_time <= start_time then
      end_time = start_time + 0.01
    end
    
    -- Get color from mapping, or use default grey if not found
    local section_name_lower = section.name:lower()
    local color = region_color_map[section_name_lower] or c.royalblue
    
    -- Add region marker
    reaper.AddProjectMarker2(
      0,                    -- project
      true,                 -- isrgn (true for region)
      start_time,          -- pos (offset by import position)
      end_time,            -- rgnend (offset by import position)
      section.name,        -- name
      -1,                  -- wantidx (-1 = add new)
      color                -- color
    )
  end
  
  reaper.UpdateTimeline()
end

-- ============================================================================
-- Repeat expansion
-- ============================================================================
function expand_repeats(measures)
  -- Recursively expand repeats in a list of measure nodes.
  -- Returns a linear list of measure nodes (original nodes may appear multiple times).
  local expanded = {}
  local i = 1
  local stack = {}  -- each entry: { start_idx, forward_times }

  while i <= #measures do
    local measure = measures[i]

    -- Check for backward repeat barline (at the end of this measure)
    local backward_times = nil
    for _, bar in ipairs(findChildren(measure, "barline") or {}) do
      local rep = findChild(bar, "repeat")
      if rep and getAttribute(rep, "direction") == "backward" then
        backward_times = tonumber(getAttribute(rep, "times")) or 2
        break
      end
    end

    -- Add current measure to result
    table.insert(expanded, measure)

    if backward_times then
      -- We have a backward repeat – pop stack to get the matching forward start
      if #stack == 0 then
        -- No matching forward – ignore (malformed XML)
        i = i + 1
        goto continue
      end
      local start_info = table.remove(stack)
      local start_idx = start_info.start_idx
      local forward_times = start_info.forward_times

      -- Determine how many times to play this section (prefer backward times)
      local passes = backward_times or forward_times or 2

      -- Extract the slice from start_idx to i (inclusive) in the original list
      local slice = {}
      for j = start_idx, i do
        table.insert(slice, measures[j])
      end

      -- Recursively expand the slice (in case of inner repeats)
      local expanded_slice = expand_repeats(slice)

      -- Insert (passes-1) copies of the expanded slice after the current position
      for copy = 1, passes-1 do
        for _, m in ipairs(expanded_slice) do
          table.insert(expanded, m)
        end
      end
    end

    -- Check for forward repeat barline (at the end of this measure)
    for _, bar in ipairs(findChildren(measure, "barline") or {}) do
      local rep = findChild(bar, "repeat")
      if rep and getAttribute(rep, "direction") == "forward" then
        local times = tonumber(getAttribute(rep, "times")) or 2
        -- The repeat starts at the next measure
        table.insert(stack, { start_idx = i+1, forward_times = times })
        break
      end
    end

    ::continue::
    i = i + 1
  end

  return expanded
end

-- ============================================================================
-- Export function: read selected MIDI items and generate MusicXML
-- ============================================================================
function ExportMusicXML(filepath)
  -- Semitone-to-note-name mapping for MusicXML pitch elements
  local semitone_to_step = {
    [0] = {"C", 0}, [1] = {"C", 1}, [2] = {"D", 0}, [3] = {"D", 1},
    [4] = {"E", 0}, [5] = {"F", 0}, [6] = {"F", 1}, [7] = {"G", 0},
    [8] = {"G", 1}, [9] = {"A", 0}, [10] = {"A", 1}, [11] = {"B", 0}
  }

  local function midi_to_pitch_xml(midi_note)
    local octave = math.floor(midi_note / 12) - 1
    local semitone = midi_note % 12
    local info = semitone_to_step[semitone]
    local step, alter = info[1], info[2]
    local xml = "            <pitch>\n"
    xml = xml .. "              <step>" .. step .. "</step>\n"
    if alter ~= 0 then
      xml = xml .. "              <alter>" .. alter .. "</alter>\n"
    end
    xml = xml .. "              <octave>" .. octave .. "</octave>\n"
    xml = xml .. "            </pitch>\n"
    return xml
  end

  -- Parse tuning from ReaTabHero exstate string
  local function parse_reatabhero_tuning(exstate_str)
    if not exstate_str or exstate_str == "" then return nil end
    local strings_str = exstate_str:match("strings={([^}]+)}")
    if not strings_str then return nil end
    local tuning = {}
    for num in strings_str:gmatch("(%d+)") do
      table.insert(tuning, tonumber(num))
    end
    return (#tuning > 0) and tuning or nil
  end

  -- Convert tick duration to MusicXML duration and type
  local function ticks_to_duration(tick_dur, ppq)
    -- MusicXML divisions = ppq (ticks per quarter note)
    local duration = tick_dur  -- duration in divisions
    -- Determine note type based on duration relative to quarter note
    local ratio = tick_dur / ppq
    local note_type, dots
    if ratio >= 3.5 then
      note_type = "whole"; dots = 0
    elseif ratio >= 2.5 then
      note_type = "half"; dots = 1
    elseif ratio >= 1.75 then
      note_type = "half"; dots = 0
    elseif ratio >= 1.25 then
      note_type = "quarter"; dots = 1
    elseif ratio >= 0.875 then
      note_type = "quarter"; dots = 0
    elseif ratio >= 0.625 then
      note_type = "eighth"; dots = 1
    elseif ratio >= 0.4375 then
      note_type = "eighth"; dots = 0
    elseif ratio >= 0.3125 then
      note_type = "16th"; dots = 1
    elseif ratio >= 0.21875 then
      note_type = "16th"; dots = 0
    elseif ratio >= 0.15625 then
      note_type = "32nd"; dots = 1
    elseif ratio >= 0.109375 then
      note_type = "32nd"; dots = 0
    else
      note_type = "64th"; dots = 0
    end
    return duration, note_type, dots
  end

  -- Collect selected items and group by track
  local num_selected = reaper.CountSelectedMediaItems(0)
  if num_selected == 0 then
    safe_msgbox("Please select one or more MIDI items to export.", "No Items Selected", 0)
    return false
  end

  local ppq = reaper.SNM_GetIntConfigVar("miditicksperbeat", 960)

  -- Group items by track
  local track_items = {}  -- { {track, track_name, tuning, items = { {take, item} ... }} }
  local track_order = {}  -- track pointers in order
  local track_map = {}    -- track pointer -> index in track_items

  for i = 0, num_selected - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local take = reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local track = reaper.GetMediaItemTake_Track(take)
        if not track_map[track] then
          local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
          -- Read tuning from ReaTabHero exstate
          local _, exstate = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:XR_ReaTabHero", "", false)
          local tuning = parse_reatabhero_tuning(exstate)
          if not tuning then
            -- Default tuning based on track name
            if isBassTrack(track_name) then
              if is5StringBassTrack(track_name) then
                tuning = getDefault5StringBassTuning()
              else
                tuning = getDefaultBassTuning()
              end
            else
              tuning = getDefaultGuitarTuning()
            end
          end
          table.insert(track_items, {
            track = track,
            track_name = track_name or "Track",
            tuning = tuning,
            is_bass = isBassTrack(track_name),
            is_drum = isDrumTrack(track_name),
            items = {}
          })
          track_map[track] = #track_items
          table.insert(track_order, track)
        end
        local idx = track_map[track]
        table.insert(track_items[idx].items, {take = take, item = item})
      end
    end
  end

  if #track_items == 0 then
    safe_msgbox("No MIDI items found in selection.", "Export Error", 0)
    return false
  end

  -- Collect all tempo/time signature markers
  local tempo_markers = {}  -- { {time, tempo, ts_num, ts_denom, is_tempo, is_timesig} }
  local num_tempo_markers = reaper.CountTempoTimeSigMarkers(0)
  for i = 0, num_tempo_markers - 1 do
    local _, timepos, _, _, bpm, timesig_num, timesig_denom, _ = reaper.GetTempoTimeSigMarker(0, i)
    local has_tempo = (bpm > 0)
    local has_timesig = (timesig_num > 0 and timesig_denom > 0)
    table.insert(tempo_markers, {
      time = timepos,
      tempo = has_tempo and bpm or nil,
      ts_num = has_timesig and timesig_num or nil,
      ts_denom = has_timesig and timesig_denom or nil,
      is_tempo = has_tempo,
      is_timesig = has_timesig
    })
  end

  -- Get initial tempo and time signature
  local project_tempo = reaper.Master_GetTempo()
  local ts_num, ts_denom = reaper.TimeMap_GetTimeSigAtTime(0, 0)
  if ts_num == 0 then ts_num = 4 end
  if ts_denom == 0 then ts_denom = 4 end

  -- Collect project regions for rehearsal marks (if enabled)
  local project_regions = {}  -- { {time, name} }
  if export_regions_enabled then
    local num_markers = reaper.CountProjectMarkers(0)
    for i = 0, num_markers - 1 do
      local _, isrgn, pos, _, name, _ = reaper.EnumProjectMarkers(i)
      if isrgn and name and name ~= "" then
        table.insert(project_regions, { time = pos, name = name })
      end
    end
    table.sort(project_regions, function(a, b) return a.time < b.time end)
  end

  -- Build MusicXML
  local xml = {}
  table.insert(xml, '<?xml version="1.0" encoding="UTF-8"?>')
  table.insert(xml, '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">')
  table.insert(xml, '<score-partwise version="4.0">')

  -- Part list
  table.insert(xml, '  <part-list>')
  for part_idx, tdata in ipairs(track_items) do
    local part_id = "P" .. part_idx
    table.insert(xml, '    <score-part id="' .. part_id .. '">')
    table.insert(xml, '      <part-name>' .. tdata.track_name .. '</part-name>')

    -- Read MIDI bank/program from first item (if enabled)
    if midi_program_banks_enabled and tdata.items[1] then
      local take = tdata.items[1].take
      local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
      if gotAllOK then
        local MIDIlen = MIDIstring:len()
        local stringPos = 1
        local bank_msb, bank_lsb, midi_program, midi_channel = nil, nil, nil, nil
        local abs_pos = 0

        while stringPos < MIDIlen - 12 do
          local offset, flags, msg
          offset, flags, msg, stringPos = string.unpack("i4Bs4", MIDIstring, stringPos)
          abs_pos = abs_pos + offset
          if abs_pos > 0 then break end  -- only look at position 0
          if msg:len() >= 2 then
            local status = msg:byte(1)
            local msg_type = status >> 4
            local ch = status & 0x0F
            if msg_type == 0xB and msg:len() >= 3 then
              local cc_num = msg:byte(2)
              local cc_val = msg:byte(3)
              if cc_num == 0 then bank_msb = cc_val; midi_channel = ch end
              if cc_num == 32 then bank_lsb = cc_val end
            elseif msg_type == 0xC then
              midi_program = msg:byte(2)
              midi_channel = ch
            end
          end
        end

        if midi_program then
          local bank = 1
          if bank_msb or bank_lsb then
            bank = (bank_msb or 0) * 128 + (bank_lsb or 0) + 1
          end
          table.insert(xml, '    <midi-instrument id="' .. part_id .. '">')
          table.insert(xml, '      <midi-channel>' .. ((midi_channel or 0) + 1) .. '</midi-channel>')
          table.insert(xml, '      <midi-bank>' .. bank .. '</midi-bank>')
          table.insert(xml, '      <midi-program>' .. (midi_program + 1) .. '</midi-program>')
          table.insert(xml, '    </midi-instrument>')
        end
      end
    end

    table.insert(xml, '    </score-part>')
  end
  table.insert(xml, '  </part-list>')

  -- Generate each part
  for part_idx, tdata in ipairs(track_items) do
    local part_id = "P" .. part_idx
    table.insert(xml, '  <part id="' .. part_id .. '">')

    -- Read key signature (KSIG notation event) from first item
    local export_ksig_root = nil
    local export_ksig_notes = nil
    if export_key_sig_enabled and tdata.items[1] then
      local take = tdata.items[1].take
      local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
      if gotAllOK then
        local MIDIlen = MIDIstring:len()
        local stringPos = 1
        local abs_pos = 0
        while stringPos < MIDIlen - 12 do
          local offset, flags, msg
          offset, flags, msg, stringPos = string.unpack("i4Bs4", MIDIstring, stringPos)
          abs_pos = abs_pos + offset
          if abs_pos > 0 then break end
          if msg:len() >= 3 and msg:byte(1) == 0xFF and msg:byte(2) == 0x0F then
            local evt_text = msg:sub(3)
            local r, n = evt_text:match("^KSIG root (%d+) dir %-?%d+ notes 0x(%x+)")
            if r and n then
              export_ksig_root = tonumber(r)
              export_ksig_notes = tonumber(n, 16)
              break
            end
          end
        end
      end
    end

    -- Collect all MIDI notes and text events from all items on this track
    local all_notes = {}   -- { pos, endpos, channel, pitch, vel }
    local all_texts = {}   -- { pos, type, text }

    for _, item_data in ipairs(tdata.items) do
      local take = item_data.take
      local _, note_count = reaper.MIDI_CountEvts(take)
      for ni = 0, note_count - 1 do
        local _, _, _, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, ni)
        table.insert(all_notes, {
          pos = startppq,
          endpos = endppq,
          channel = chan,
          pitch = pitch,
          vel = vel
        })
      end
      -- Read text events
      local _, _, _, text_count = reaper.MIDI_CountEvts(take)
      for ti = 0, text_count - 1 do
        local _, _, _, ppqpos, evt_type, msg = reaper.MIDI_GetTextSysexEvt(take, ti)
        if msg and msg ~= "" then
          table.insert(all_texts, {
            pos = ppqpos,
            type = evt_type,
            text = msg
          })
        end
      end
    end

    -- Sort notes by position, then channel
    table.sort(all_notes, function(a, b)
      if a.pos ~= b.pos then return a.pos < b.pos end
      return a.channel < b.channel
    end)

    -- ================================================================
    -- Match MIDI text events to articulations for MusicXML export
    -- ================================================================

    -- Map articulation name → MusicXML element specification
    local art_to_xml_export = {
      -- <notations><articulations> group
      accent        = { group = "articulations", tag = "accent" },
      staccato      = { group = "articulations", tag = "staccato" },
      tenuto        = { group = "articulations", tag = "tenuto" },
      staccatissimo = { group = "articulations", tag = "staccatissimo" },
      spiccato      = { group = "articulations", tag = "spiccato" },
      scoop         = { group = "articulations", tag = "scoop" },
      falloff       = { group = "articulations", tag = "falloff" },
      doit          = { group = "articulations", tag = "doit" },
      breathmark    = { group = "articulations", tag = "breath-mark" },
      ["up-stroke"]   = { group = "articulations", tag = "up-bow" },
      ["down-stroke"] = { group = "articulations", tag = "down-bow" },
      -- <notations><technical> group
      ["hammer-on"]           = { group = "technical", xml = '<hammer-on type="start">H</hammer-on>' },
      ["pull-off"]            = { group = "technical", xml = '<pull-off type="start">P</pull-off>' },
      tap                     = { group = "technical", xml = '<tap/>' },
      harmonic                = { group = "technical", xml = '<harmonic><natural/></harmonic>' },
      ["natural-harmonic"]    = { group = "technical", xml = '<harmonic><natural/></harmonic>' },
      ["artificial-harmonic"] = { group = "technical", xml = '<harmonic><artificial/></harmonic>' },
      vibrato                 = { group = "technical", xml = '<other-technical>vibrato</other-technical>' },
      letring                 = { group = "technical", xml = '<other-technical>let ring</other-technical>' },
      -- Bend shapes
      bend                    = { group = "bend" },
      ["bend release"]        = { group = "bend", release = true },
      ["pre-bend"]            = { group = "bend", prebend = true },
      -- Slides
      slide                   = { group = "slide", xml = '<slide type="start" line-type="solid" number="1"/>' },
      ["slide-up"]            = { group = "slide", xml = '<slide type="start" line-type="solid" number="1"/>' },
      ["slide-down"]          = { group = "slide", xml = '<slide type="start" line-type="solid" number="1"/>' },
      -- Palm / straight mute → <play><mute>
      palm                    = { group = "play", xml = '<mute>palm</mute>' },
      straight                = { group = "play", xml = '<mute>straight</mute>' },
      -- Bend amount → determines <bend-alter> value
      ["1/2 bend"]            = { group = "bend_amount", alter = 1 },
      ["full bend"]           = { group = "bend_amount", alter = 2 },
      ["1 1/2 bend"]          = { group = "bend_amount", alter = 3 },
      ["2 bend"]              = { group = "bend_amount", alter = 4 },
      ["2 1/2 bend"]          = { group = "bend_amount", alter = 5 },
      ["3 bend"]              = { group = "bend_amount", alter = 6 },
      -- Grace note (emitted as <grace/> on the note, not inside <notations>)
      ["grace-note"]          = { group = "grace" },
    }

    -- Build Lua patterns for reverse-matching text events to articulation names
    local art_patterns = {}
    for _, art_name in ipairs(articulation_names_ordered) do
      local sym = get_art_symbol(art_name)
      if sym and sym ~= "" then
        local no_prefix = get_art_no_prefix(art_name)
        local token_d = "\1"
        local token_s = "\2"
        local s = sym:gsub("%%%%", "\3")
        s = s:gsub("%%d", token_d):gsub("%%h", token_d):gsub("%%s", token_s)
        s = s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", function(c) return "%" .. c end)
        s = s:gsub(token_d, function() return "%-?%%d+" end)
        s = s:gsub(token_s, function() return ".+" end)
        s = s:gsub("\3", function() return "%%%%" end)
        local pat
        if no_prefix then
          pat = "^" .. s .. "$"
        else
          pat = "^_" .. s .. "$"
        end
        table.insert(art_patterns, { pattern = pat, name = art_name })
      end
    end

    local function match_text_art(text)
      for _, entry in ipairs(art_patterns) do
        if text:match(entry.pattern) then return entry.name end
      end
      return nil
    end

    -- Index matched articulations by tick position
    local arts_at_pos = {}
    for _, t in ipairs(all_texts) do
      local art_name = match_text_art(t.text)
      if art_name then
        if not arts_at_pos[t.pos] then arts_at_pos[t.pos] = {} end
        table.insert(arts_at_pos[t.pos], { name = art_name, text = t.text })
      end
    end

    -- Build measure boundaries with tempo/time signature changes
    -- Convert tempo marker times to tick positions (QN-based)
    local marker_ticks = {}
    for _, m in ipairs(tempo_markers) do
      local qn = reaper.TimeMap2_timeToQN(0, m.time)
      table.insert(marker_ticks, {
        tick = qn * ppq,
        tempo = m.tempo,
        ts_num = m.ts_num,
        ts_denom = m.ts_denom,
        is_tempo = m.is_tempo,
        is_timesig = m.is_timesig
      })
    end

    -- Convert project region times to tick positions
    local region_ticks = {}
    for _, r in ipairs(project_regions) do
      local qn = reaper.TimeMap2_timeToQN(0, r.time)
      table.insert(region_ticks, { tick = qn * ppq, name = r.name })
    end

    local max_tick = 0
    for _, n in ipairs(all_notes) do
      if n.endpos > max_tick then max_tick = n.endpos end
    end

    -- Build measures dynamically based on time sig changes
    local measures = {}  -- { {start, end_tick, ts_num, ts_denom, tempo_changes = {}, timesig_changed} }
    local cur_ts_num = ts_num
    local cur_ts_denom = ts_denom
    local cur_tempo = project_tempo
    local cur_tick = 0
    local measure_num = 0

    -- Precompute which markers apply at measure boundaries
    local function ticks_per_measure_for(tsn, tsd)
      return ppq * 4 * tsn / tsd
    end

    if max_tick == 0 then max_tick = ticks_per_measure_for(cur_ts_num, cur_ts_denom) end

    while cur_tick < max_tick do
      measure_num = measure_num + 1
      local meas_tpm = ticks_per_measure_for(cur_ts_num, cur_ts_denom)
      local meas_end = cur_tick + meas_tpm

      -- Collect tempo/timesig changes that fall at or near this measure start
      local tempo_changes_here = {}
      local timesig_changed = false
      local new_ts_num, new_ts_denom = cur_ts_num, cur_ts_denom
      for _, mt in ipairs(marker_ticks) do
        if math.abs(mt.tick - cur_tick) < 1 then
          if mt.is_tempo then
            table.insert(tempo_changes_here, mt.tempo)
            cur_tempo = mt.tempo
          end
          if mt.is_timesig then
            new_ts_num = mt.ts_num
            new_ts_denom = mt.ts_denom
            if new_ts_num ~= cur_ts_num or new_ts_denom ~= cur_ts_denom then
              timesig_changed = true
              cur_ts_num = new_ts_num
              cur_ts_denom = new_ts_denom
              meas_tpm = ticks_per_measure_for(cur_ts_num, cur_ts_denom)
              meas_end = cur_tick + meas_tpm
            end
          end
        end
      end

      table.insert(measures, {
        start = cur_tick,
        end_tick = meas_end,
        ts_num = cur_ts_num,
        ts_denom = cur_ts_denom,
        tempo = #tempo_changes_here > 0 and tempo_changes_here[#tempo_changes_here] or nil,
        timesig_changed = timesig_changed,
        number = measure_num
      })
      cur_tick = meas_end
    end

    if #measures == 0 then
      local meas_tpm = ticks_per_measure_for(cur_ts_num, cur_ts_denom)
      table.insert(measures, {
        start = 0,
        end_tick = meas_tpm,
        ts_num = cur_ts_num,
        ts_denom = cur_ts_denom,
        tempo = project_tempo,
        timesig_changed = false,
        number = 1
      })
    end

    -- Build tuning info
    local tuning = tdata.tuning
    local num_strings = tuning and #tuning or 6

    -- Pre-process: split notes at measure boundaries and add tie info
    local split_notes = {}  -- like all_notes but with tie_start/tie_stop flags
    for _, n in ipairs(all_notes) do
      for _, meas in ipairs(measures) do
        if n.pos < meas.end_tick and n.endpos > meas.start then
          local seg_start = math.max(n.pos, meas.start)
          local seg_end = math.min(n.endpos, meas.end_tick)
          if seg_end - seg_start > 0.5 then
            table.insert(split_notes, {
              pos = seg_start,
              endpos = seg_end,
              channel = n.channel,
              pitch = n.pitch,
              vel = n.vel,
              tie_start = (n.endpos > meas.end_tick),
              tie_stop = (n.pos < meas.start)
            })
          end
        end
      end
    end

    -- Sort split notes by position, then channel
    table.sort(split_notes, function(a, b)
      if a.pos ~= b.pos then return a.pos < b.pos end
      return a.channel < b.channel
    end)

    -- Helper: decompose a tick duration into beat-aligned segments
    local function decompose_to_beats(start_tick, total_dur, beat_ticks)
      local segments = {}
      local remaining = total_dur
      local pos = start_tick
      while remaining > 0.5 do
        local beat_offset = pos % beat_ticks
        local to_beat_end
        if beat_offset < 0.5 then
          -- On a beat boundary; use full beat
          to_beat_end = beat_ticks
        else
          -- Mid-beat; finish this beat
          to_beat_end = beat_ticks - beat_offset
        end
        local seg = math.min(remaining, to_beat_end)
        table.insert(segments, seg)
        pos = pos + seg
        remaining = remaining - seg
      end
      return segments
    end

    for _, meas in ipairs(measures) do
      local measure_start = meas.start
      local measure_end = meas.end_tick

      table.insert(xml, '    <measure number="' .. meas.number .. '">')

      -- Attributes: first measure always, or when time sig changes
      if meas.number == 1 or meas.timesig_changed then
        table.insert(xml, '      <attributes>')
        if meas.number == 1 then
          table.insert(xml, '        <divisions>' .. ppq .. '</divisions>')
          -- Key signature from KSIG notation event
          if export_ksig_root ~= nil and export_ksig_notes ~= nil then
            local fifths_map = (export_ksig_notes == KEYSIG_MINOR_HEX) and keysig_root_to_fifths_minor or keysig_root_to_fifths_major
            local fifths = fifths_map[export_ksig_root]
            if fifths then
              local mode = (export_ksig_notes == KEYSIG_MINOR_HEX) and "minor" or "major"
              table.insert(xml, '        <key>')
              table.insert(xml, '          <fifths>' .. fifths .. '</fifths>')
              table.insert(xml, '          <mode>' .. mode .. '</mode>')
              table.insert(xml, '        </key>')
            end
          end
        end
        table.insert(xml, '        <time>')
        table.insert(xml, '          <beats>' .. meas.ts_num .. '</beats>')
        table.insert(xml, '          <beat-type>' .. meas.ts_denom .. '</beat-type>')
        table.insert(xml, '        </time>')
        if meas.number == 1 then
          table.insert(xml, '        <staves>2</staves>')
          -- Staff 1: standard notation (treble clef)
          table.insert(xml, '        <clef number="1">')
          table.insert(xml, '          <sign>G</sign>')
          table.insert(xml, '          <line>2</line>')
          table.insert(xml, '        </clef>')
          -- Staff 2: tablature
          table.insert(xml, '        <clef number="2">')
          table.insert(xml, '          <sign>TAB</sign>')
          table.insert(xml, '          <line>5</line>')
          table.insert(xml, '        </clef>')
          -- Staff details for TAB staff with tuning
          if tuning and not tdata.is_drum then
            table.insert(xml, '        <staff-details number="2">')
            table.insert(xml, '          <staff-lines>' .. num_strings .. '</staff-lines>')
            for s = 1, num_strings do
              local midi_note = tuning[s]
              local octave = math.floor(midi_note / 12) - 1
              local semitone = midi_note % 12
              local info = semitone_to_step[semitone]
              local step = info[1]
              local alter = info[2]
              table.insert(xml, '          <staff-tuning line="' .. s .. '">')
              table.insert(xml, '            <tuning-step>' .. step .. '</tuning-step>')
              if alter ~= 0 then
                table.insert(xml, '            <tuning-alter>' .. alter .. '</tuning-alter>')
              end
              table.insert(xml, '            <tuning-octave>' .. octave .. '</tuning-octave>')
              table.insert(xml, '          </staff-tuning>')
            end
            table.insert(xml, '        </staff-details>')
          end
          -- Transpose for staff 1: guitar sounds one octave lower than written
          table.insert(xml, '        <transpose number="1">')
          table.insert(xml, '          <diatonic>0</diatonic>')
          table.insert(xml, '          <chromatic>0</chromatic>')
          table.insert(xml, '          <octave-change>-1</octave-change>')
          table.insert(xml, '        </transpose>')
        end
        table.insert(xml, '      </attributes>')
      end

      -- Direction with tempo (first measure or when tempo changes)
      local tempo_to_emit = nil
      if meas.number == 1 then
        tempo_to_emit = meas.tempo or project_tempo
      elseif meas.tempo then
        tempo_to_emit = meas.tempo
      end
      if tempo_to_emit then
        table.insert(xml, '      <direction placement="above">')
        table.insert(xml, '        <direction-type>')
        table.insert(xml, '          <metronome>')
        table.insert(xml, '            <beat-unit>quarter</beat-unit>')
        table.insert(xml, '            <per-minute>' .. math.floor(tempo_to_emit) .. '</per-minute>')
        table.insert(xml, '          </metronome>')
        table.insert(xml, '        </direction-type>')
        table.insert(xml, '        <sound tempo="' .. math.floor(tempo_to_emit) .. '"/>')
        table.insert(xml, '      </direction>')
      end

      -- Rehearsal marks from project regions at this measure
      for _, rt in ipairs(region_ticks) do
        if math.abs(rt.tick - measure_start) < 1 then
          table.insert(xml, '      <direction placement="above">')
          table.insert(xml, '        <direction-type>')
          table.insert(xml, '          <rehearsal>' .. rt.name .. '</rehearsal>')
          table.insert(xml, '        </direction-type>')
          table.insert(xml, '      </direction>')
        end
      end

      -- Collect notes in this measure (from split_notes)
      local measure_notes = {}
      for _, n in ipairs(split_notes) do
        if n.pos >= measure_start and n.pos < measure_end then
          table.insert(measure_notes, n)
        end
      end

      -- Group notes by position (for chord detection)
      -- Notes within chord_offset_ticks tolerance are treated as chords
      local chord_tolerance = chord_offset_ticks * 16  -- allow small offsets from import
      local pos_groups = {}
      local pos_order = {}
      for _, n in ipairs(measure_notes) do
        -- Find an existing group within tolerance
        local matched_pos = nil
        for _, existing_pos in ipairs(pos_order) do
          if math.abs(n.pos - existing_pos) <= chord_tolerance then
            matched_pos = existing_pos
            break
          end
        end
        if matched_pos then
          table.insert(pos_groups[matched_pos], n)
        else
          pos_groups[n.pos] = {n}
          table.insert(pos_order, n.pos)
        end
      end

      -- Beat length for this measure's time signature
      local beat_ticks = ppq * 4 / meas.ts_denom

      -- Helper to emit notes for a given staff
      -- staff_num: 1 = standard notation, 2 = TAB
      -- voice: 1 for staff 1, 5 for staff 2
      local function emit_notes_for_staff(staff_num, voice)
        local cur_tick_s = measure_start
        local total_duration_emitted = 0

        for _, pos in ipairs(pos_order) do
          local notes_at_pos = pos_groups[pos]

          -- Insert beat-aligned rests if there's a gap
          if pos > cur_tick_s then
            local rest_dur = pos - cur_tick_s
            local rest_segs = decompose_to_beats(cur_tick_s, rest_dur, beat_ticks)
            for _, seg_dur in ipairs(rest_segs) do
              local duration, note_type, dots = ticks_to_duration(seg_dur, ppq)
              table.insert(xml, '      <note>')
              table.insert(xml, '        <rest/>')
              table.insert(xml, '        <duration>' .. duration .. '</duration>')
              table.insert(xml, '        <voice>' .. voice .. '</voice>')
              table.insert(xml, '        <type>' .. note_type .. '</type>')
              if dots > 0 then
                table.insert(xml, '        <dot/>')
              end
              table.insert(xml, '        <staff>' .. staff_num .. '</staff>')
              table.insert(xml, '      </note>')
              total_duration_emitted = total_duration_emitted + seg_dur
            end
          end

          -- Emit notes at this position
          local max_endpos = pos
          for ni, n in ipairs(notes_at_pos) do
            local note_dur = n.endpos - n.pos
            local duration, note_type, dots = ticks_to_duration(note_dur, ppq)

            -- Determine string and fret from channel and tuning
            local string_num, fret_num
            if not tdata.is_drum and tuning then
              local channel_1based = n.channel + 1
              if tdata.is_bass then
                channel_1based = channel_1based + 1
              end
              string_num = 7 - channel_1based
              if string_num < 1 then string_num = 1 end
              if string_num > num_strings then string_num = num_strings end
              local tuning_idx = num_strings - string_num + 1
              fret_num = n.pitch - (tuning[tuning_idx] or 0)
              if fret_num < 0 then fret_num = 0 end
            end

            table.insert(xml, '      <note>')
            if ni > 1 then
              table.insert(xml, '        <chord/>')
            end

            -- Pitch: staff 1 writes one octave higher (guitar transposition convention)
            if staff_num == 1 then
              table.insert(xml, midi_to_pitch_xml(n.pitch + 12))
            else
              table.insert(xml, midi_to_pitch_xml(n.pitch))
            end

            -- Tie element (before voice)
            if n.tie_stop then
              table.insert(xml, '        <tie type="stop"/>')
            end
            if n.tie_start then
              table.insert(xml, '        <tie type="start"/>')
            end

            table.insert(xml, '        <duration>' .. duration .. '</duration>')
            table.insert(xml, '        <voice>' .. voice .. '</voice>')
            table.insert(xml, '        <type>' .. note_type .. '</type>')
            if dots > 0 then
              table.insert(xml, '        <dot/>')
            end
            table.insert(xml, '        <staff>' .. staff_num .. '</staff>')

            -- Collect articulations from text events at this chord group's positions
            -- Only for the first note in a chord group; skip tie continuations
            local note_art_list = {}
            if ni == 1 and not n.tie_stop then
              -- Check all note positions in this chord group (they may differ
              -- by chord_offset_ticks, each with its own text events)
              local seen_arts = {}
              for _, cn in ipairs(notes_at_pos) do
                local pos_arts = arts_at_pos[cn.pos] or {}
                for _, art in ipairs(pos_arts) do
                  if not seen_arts[art.name] then
                    seen_arts[art.name] = true
                    table.insert(note_art_list, art)
                  end
                end
              end
            end

            -- Categorize articulations into MusicXML groups
            local xml_art_elems = {}      -- <articulations> children
            local xml_tech_elems = {}     -- <technical> children (from articulations)
            local xml_slide_elems = {}    -- <slide> direct notation children
            local xml_play_elems = {}     -- <play> children (mutes)
            local bend_alter = 2          -- default bend-alter (full bend = 2 semitones)
            local has_bend = false
            local bend_release = false
            local bend_prebend = false

            for _, art in ipairs(note_art_list) do
              local spec = art_to_xml_export[art.name]
              if spec then
                if spec.group == "articulations" then
                  table.insert(xml_art_elems, '<' .. spec.tag .. '/>')
                elseif spec.group == "technical" then
                  table.insert(xml_tech_elems, spec.xml)
                elseif spec.group == "slide" then
                  table.insert(xml_slide_elems, spec.xml)
                elseif spec.group == "play" then
                  table.insert(xml_play_elems, spec.xml)
                elseif spec.group == "bend" then
                  has_bend = true
                  if spec.release then bend_release = true end
                  if spec.prebend then bend_prebend = true end
                elseif spec.group == "bend_amount" then
                  bend_alter = spec.alter
                end
              end
            end

            -- Build bend XML if needed
            if has_bend then
              local bend_xml = '<bend><bend-alter>' .. bend_alter .. '</bend-alter>'
              if bend_prebend then bend_xml = bend_xml .. '<pre-bend/>' end
              if bend_release then bend_xml = bend_xml .. '<release/>' end
              bend_xml = bend_xml .. '</bend>'
              table.insert(xml_tech_elems, bend_xml)
            end

            -- Notations (articulations + technical + slides + ties)
            local has_tab_technical = (staff_num == 2 and string_num and fret_num)
            local has_art_technical = (#xml_tech_elems > 0)
            local has_tied = (n.tie_start or n.tie_stop)
            local has_notations = has_tab_technical or has_art_technical
                                  or #xml_art_elems > 0 or #xml_slide_elems > 0 or has_tied
            if has_notations then
              table.insert(xml, '        <notations>')
              -- Articulations group
              if #xml_art_elems > 0 then
                table.insert(xml, '          <articulations>')
                for _, elem in ipairs(xml_art_elems) do
                  table.insert(xml, '            ' .. elem)
                end
                table.insert(xml, '          </articulations>')
              end
              -- Technical group (tab string/fret + articulation technicals)
              if has_tab_technical or has_art_technical then
                table.insert(xml, '          <technical>')
                if has_tab_technical then
                  table.insert(xml, '            <string>' .. string_num .. '</string>')
                  table.insert(xml, '            <fret>' .. fret_num .. '</fret>')
                end
                for _, elem in ipairs(xml_tech_elems) do
                  table.insert(xml, '            ' .. elem)
                end
                table.insert(xml, '          </technical>')
              end
              -- Slides (direct children of <notations>)
              for _, elem in ipairs(xml_slide_elems) do
                table.insert(xml, '          ' .. elem)
              end
              -- Ties
              if n.tie_stop then
                table.insert(xml, '          <tied type="stop"/>')
              end
              if n.tie_start then
                table.insert(xml, '          <tied type="start"/>')
              end
              table.insert(xml, '        </notations>')
            end

            -- Play element for mutes (outside <notations>, inside <note>)
            if #xml_play_elems > 0 then
              table.insert(xml, '        <play>')
              for _, elem in ipairs(xml_play_elems) do
                table.insert(xml, '          ' .. elem)
              end
              table.insert(xml, '        </play>')
            end

            table.insert(xml, '      </note>')

            if ni == 1 then
              total_duration_emitted = total_duration_emitted + duration
            end
            if n.endpos > max_endpos then max_endpos = n.endpos end
          end

          cur_tick_s = max_endpos
        end

        -- Fill remaining measure with beat-aligned rests
        if cur_tick_s < measure_end then
          local rest_dur = measure_end - cur_tick_s
          local rest_segs = decompose_to_beats(cur_tick_s, rest_dur, beat_ticks)
          for _, seg_dur in ipairs(rest_segs) do
            local duration, note_type, dots = ticks_to_duration(seg_dur, ppq)
            table.insert(xml, '      <note>')
            table.insert(xml, '        <rest/>')
            table.insert(xml, '        <duration>' .. duration .. '</duration>')
            table.insert(xml, '        <voice>' .. voice .. '</voice>')
            table.insert(xml, '        <type>' .. note_type .. '</type>')
            if dots > 0 then
              table.insert(xml, '        <dot/>')
            end
            table.insert(xml, '        <staff>' .. staff_num .. '</staff>')
            table.insert(xml, '      </note>')
            total_duration_emitted = total_duration_emitted + seg_dur
          end
        end

        return total_duration_emitted
      end

      -- Emit staff 1 (standard notation, voice 1)
      local staff1_duration = emit_notes_for_staff(1, 1)

      -- Backup to re-align for staff 2
      if staff1_duration > 0 then
        table.insert(xml, '      <backup>')
        table.insert(xml, '        <duration>' .. staff1_duration .. '</duration>')
        table.insert(xml, '      </backup>')
      end

      -- Emit staff 2 (TAB, voice 5)
      emit_notes_for_staff(2, 5)

      table.insert(xml, '    </measure>')
    end

    table.insert(xml, '  </part>')
  end

  table.insert(xml, '</score-partwise>')

  -- Write to file
  local xml_str = table.concat(xml, "\n") .. "\n"
  local f = io.open(filepath, "w")
  if not f then
    safe_msgbox("Could not write to file:\n" .. filepath, "Export Error", 0)
    return false
  end
  f:write(xml_str)
  f:close()

  -- reaper.ShowMessageBox("Exported " .. #track_items .. " part(s) to:\n" .. filepath, "Export Complete", 0)
  return true
end

-- ============================================================================
-- Find an audio stem item in the project by region name + stem keyword
-- Returns: source_path or nil
-- ============================================================================
function find_audio_stem_for_region(region_name)
  if not region_name or region_name == "" then return nil, 0 end
  local region_lower = region_name:lower()
  local stem_keywords = {"drum", "drums", "percussion", "perc"}

  local n_items = reaper.CountMediaItems(0)
  for i = 0, n_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      local name_lower = take_name:lower()
      -- Check if item name contains the region name AND a drum keyword
      if name_lower:find(region_lower, 1, true) then
        for _, kw in ipairs(stem_keywords) do
          if name_lower:find(kw, 1, true) then
            local source = reaper.GetMediaItemTake_Source(take)
            if source then
              local path = reaper.GetMediaSourceFileName(source)
              if path and path ~= "" then
                local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local take_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
                return path, item_pos - take_offs
              end
            end
          end
        end
      end
    end
  end

  -- Fallback: try any audio item containing the region name
  for i = 0, n_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      if take_name:lower():find(region_lower, 1, true) then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          local path = reaper.GetMediaSourceFileName(source)
          if path and path ~= "" then
            local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local take_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
            return path, item_pos - take_offs
          end
        end
      end
    end
  end

  return nil, 0
end

-- ============================================================================
-- Get all audio items within a region (by region start/end)
-- Returns: list of {item, take, name} sorted by track index then position
-- ============================================================================
function get_audio_items_in_region(rgn_start, rgn_end)
  if not rgn_start or not rgn_end then return {} end
  local results = {}
  local n_items = reaper.CountMediaItems(0)
  for i = 0, n_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      -- Item overlaps with region
      if pos < rgn_end and pos + len > rgn_start then
        local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if take_name == "" then
          local track = reaper.GetMediaItemTrack(item)
          if track then
            _, take_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
          end
        end
        local track = reaper.GetMediaItemTrack(item)
        local track_idx = track and reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
        results[#results + 1] = {item = item, take = take, name = take_name or "", pos = pos, track_idx = track_idx}
      end
    end
  end
  table.sort(results, function(a, b)
    if a.track_idx ~= b.track_idx then return a.track_idx < b.track_idx end
    return a.pos < b.pos
  end)
  return results
end

-- ============================================================================
-- Refresh the align stem items list based on current region context
-- ============================================================================
function refresh_align_stem_items()
  local cursor = reaper.GetCursorPosition()
  local _, num_m, num_r = reaper.CountProjectMarkers(0)
  local rgn_start, rgn_end = nil, nil
  -- Try cursor inside a region first
  for i = 0, num_m + num_r - 1 do
    local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
    if is_rgn and cursor >= pos and cursor < rgnend then
      rgn_start, rgn_end = pos, rgnend
      break
    end
  end
  -- Fallback: closest region to cursor
  if not rgn_start then
    local best_dist = math.huge
    for i = 0, num_m + num_r - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn then
        local d = math.abs(pos - cursor)
        if d < best_dist then best_dist = d; rgn_start = pos; rgn_end = rgnend end
      end
    end
  end
  if autoload_region_start_pos then
    rgn_start = autoload_region_start_pos
    -- Find region end for autoloaded region
    for i = 0, num_m + num_r - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn and math.abs(pos - rgn_start) < 0.01 then
        rgn_end = rgnend
        break
      end
    end
  end
  align_stem_items = get_audio_items_in_region(rgn_start, rgn_end)
  -- Clamp index
  if align_stem_index > #align_stem_items then align_stem_index = 0 end
end

-- ============================================================================
-- Get the currently selected align stem item (or nil for Auto)
-- Returns: item, take, name  or nil,nil,nil
-- ============================================================================
function get_selected_align_stem()
  if align_stem_index <= 0 or align_stem_index > #align_stem_items then
    return nil, nil, nil
  end
  local entry = align_stem_items[align_stem_index]
  return entry.item, entry.take, entry.name
end

-- ============================================================================
-- Refresh the onset item list based on current region context
-- ============================================================================
function refresh_onset_item_items()
  local cursor = reaper.GetCursorPosition()
  local _, num_m, num_r = reaper.CountProjectMarkers(0)
  local rgn_start, rgn_end = nil, nil
  -- Try cursor inside a region first
  for i = 0, num_m + num_r - 1 do
    local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
    if is_rgn and cursor >= pos and cursor < rgnend then
      rgn_start, rgn_end = pos, rgnend
      break
    end
  end
  -- Fallback: closest region to cursor
  if not rgn_start then
    local best_dist = math.huge
    for i = 0, num_m + num_r - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn then
        local d = math.abs(pos - cursor)
        if d < best_dist then best_dist = d; rgn_start = pos; rgn_end = rgnend end
      end
    end
  end
  if autoload_region_start_pos then
    rgn_start = autoload_region_start_pos
    for i = 0, num_m + num_r - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn and math.abs(pos - rgn_start) < 0.01 then
        rgn_end = rgnend
        break
      end
    end
  end
  onset_item_items = get_audio_items_in_region(rgn_start, rgn_end)
  if onset_item_index > #onset_item_items then onset_item_index = 0 end
end

-- ============================================================================
-- Get the currently selected onset item (or nil for Auto)
-- Returns: item, take, name  or nil,nil,nil
-- ============================================================================
function get_selected_onset_item()
  if onset_item_index <= 0 or onset_item_index > #onset_item_items then
    return nil, nil, nil
  end
  local entry = onset_item_items[onset_item_index]
  return entry.item, entry.take, entry.name
end

-- ============================================================================
-- Get audio items overlapping the edit cursor (fallback when no region exists)
-- ============================================================================
function get_audio_items_at_cursor()
  local cursor = reaper.GetCursorPosition()
  local results = {}
  local n_items = reaper.CountMediaItems(0)
  for i = 0, n_items - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if cursor >= pos and cursor < pos + len then
        local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        if take_name == "" then
          local track = reaper.GetMediaItemTrack(item)
          if track then _, take_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false) end
        end
        local track = reaper.GetMediaItemTrack(item)
        local track_idx = track and reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") or 0
        results[#results + 1] = {item = item, take = take, name = take_name or "", pos = pos, track_idx = track_idx}
      end
    end
  end
  table.sort(results, function(a, b)
    if a.track_idx ~= b.track_idx then return a.track_idx < b.track_idx end
    return a.pos < b.pos
  end)
  return results
end

-- ============================================================================
-- Refresh detect tempo item list (region items + fallback to edit cursor)
-- ============================================================================
function refresh_detect_tempo_items()
  local cursor = reaper.GetCursorPosition()
  local _, num_m, num_r = reaper.CountProjectMarkers(0)
  local rgn_start, rgn_end = nil, nil
  for i = 0, num_m + num_r - 1 do
    local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
    if is_rgn and cursor >= pos and cursor < rgnend then
      rgn_start, rgn_end = pos, rgnend
      break
    end
  end
  if not rgn_start then
    local best_dist = math.huge
    for i = 0, num_m + num_r - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn then
        local d = math.abs(pos - cursor)
        if d < best_dist then best_dist = d; rgn_start = pos; rgn_end = rgnend end
      end
    end
  end
  if autoload_region_start_pos then
    rgn_start = autoload_region_start_pos
    for i = 0, num_m + num_r - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn and math.abs(pos - rgn_start) < 0.01 then
        rgn_end = rgnend
        break
      end
    end
  end
  if rgn_start and rgn_end then
    detect_tempo_item_items = get_audio_items_in_region(rgn_start, rgn_end)
  else
    detect_tempo_item_items = get_audio_items_at_cursor()
  end
  if detect_tempo_item_index > #detect_tempo_item_items then detect_tempo_item_index = 0 end
end

-- ============================================================================
-- Get the item/take for tempo detection based on detect_tempo_item_index
-- 0 = Selected Item (current selection in arrange), 1+ = specific from list
-- ============================================================================
function get_detect_tempo_item()
  if detect_tempo_item_index <= 0 then
    -- "Selected Item" mode
    local item = reaper.GetSelectedMediaItem(0, 0)
    if item then
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then return item, take end
    end
    -- Fallback: try to find audio item under razor edit
    for ti = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, ti)
      local _, razor_str = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
      if razor_str and razor_str ~= "" then
        for rstart, rend in razor_str:gmatch("([%d%.]+) ([%d%.]+)") do
          local rs, re = tonumber(rstart), tonumber(rend)
          if rs and re and re - rs > 0.001 then
            for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
              local ri = reaper.GetTrackMediaItem(track, ii)
              local ri_pos = reaper.GetMediaItemInfo_Value(ri, "D_POSITION")
              local ri_len = reaper.GetMediaItemInfo_Value(ri, "D_LENGTH")
              if ri_pos < re and ri_pos + ri_len > rs then
                local rt = reaper.GetActiveTake(ri)
                if rt and not reaper.TakeIsMIDI(rt) then return ri, rt end
              end
            end
          end
        end
      end
    end
    return nil, nil
  end
  if detect_tempo_item_index > #detect_tempo_item_items then
    refresh_detect_tempo_items()
  end
  if detect_tempo_item_index <= 0 or detect_tempo_item_index > #detect_tempo_item_items then
    return nil, nil
  end
  local entry = detect_tempo_item_items[detect_tempo_item_index]
  return entry.item, entry.take
end

-- ============================================================================
-- Get detection bounds from time selection or razor edit for stretch marker slider
-- ============================================================================
function get_slider_detect_bounds(item)
    local detect_start, detect_end
    local sel_start, sel_end = reaper.GetSet_LoopTimeRange(0, false, 0, 0, false)
    if sel_end - sel_start > 0.001 then
        detect_start = sel_start
        detect_end = sel_end
    else
        local item_track = reaper.GetMediaItemTrack(item)
        if item_track then
            local _, razor_str = reaper.GetSetMediaTrackInfo_String(item_track, "P_RAZOREDITS", "", false)
            if razor_str and razor_str ~= "" then
                for rstart, rend in razor_str:gmatch("([%d%.]+) ([%d%.]+)") do
                    local rs, re = tonumber(rstart), tonumber(rend)
                    if rs and re and re - rs > 0.001 then
                        detect_start = rs
                        detect_end = re
                        break
                    end
                end
            end
        end
    end
    return detect_start, detect_end
end

-- ============================================================================
-- Get the active edit range as (start, end) in project time.
-- Priority: razor edit on any track → time selection → selected items bounds.
-- Returns nil, nil if nothing is available.
-- ============================================================================
function get_edit_range()
    -- 1. Razor edits: find the union of all razor edit areas across all tracks
    local razor_start, razor_end
    for ti = 0, reaper.CountTracks(0) - 1 do
        local track = reaper.GetTrack(0, ti)
        local _, razor_str = reaper.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
        if razor_str and razor_str ~= "" then
            for rstart, rend in razor_str:gmatch("([%d%.%-]+) ([%d%.%-]+)") do
                local rs, re = tonumber(rstart), tonumber(rend)
                if rs and re and re - rs > 0.001 then
                    if not razor_start or rs < razor_start then razor_start = rs end
                    if not razor_end   or re > razor_end   then razor_end   = re end
                end
            end
        end
    end
    if razor_start then return razor_start, razor_end end

    -- 2. Time selection
    local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if sel_end - sel_start > 0.001 then
        return sel_start, sel_end
    end

    -- 3. Selected items bounding box
    local n = reaper.CountSelectedMediaItems(0)
    if n > 0 then
        local rng_start, rng_end
        for i = 0, n - 1 do
            local item = reaper.GetSelectedMediaItem(0, i)
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            if not rng_start or pos < rng_start then rng_start = pos end
            if not rng_end   or pos + len > rng_end then rng_end = pos + len end
        end
        return rng_start, rng_end
    end

    return nil, nil
end

-- ============================================================================
-- Delete all tempo/time-sig markers within the given project-time range.
-- Never removes the very first marker if it is the only one (REAPER requires
-- at least one tempo marker). Returns the count of deleted markers.
-- ============================================================================
function delete_tempo_markers_in_range(range_start, range_end)
    local n = reaper.CountTempoTimeSigMarkers(0)
    if n == 0 then return 0 end
    -- Collect indices to delete (iterate backwards to avoid index shifting)
    local to_delete = {}
    for i = 0, n - 1 do
        local rv, t = reaper.GetTempoTimeSigMarker(0, i)
        if rv and t >= range_start - 0.0001 and t <= range_end + 0.0001 then
            table.insert(to_delete, i)
        end
    end
    -- If we would delete ALL markers, keep the first one
    if #to_delete == n and n > 0 then
        table.remove(to_delete, 1)
    end
    -- Delete in reverse order so indices stay valid
    for i = #to_delete, 1, -1 do
        reaper.DeleteTempoTimeSigMarker(0, to_delete[i])
    end
    return #to_delete
end

-- ============================================================================
-- Remove stretch markers on all selected audio items within the given range.
-- If range_start/range_end are nil, removes ALL stretch markers from selected items.
-- Returns total count of removed markers.
-- ============================================================================
function remove_stretch_markers_in_range(range_start, range_end, items_list)
    local total_removed = 0
    local n_items = items_list and #items_list or reaper.CountSelectedMediaItems(0)
    reaper.PreventUIRefresh(1)
    for i = 0, n_items - 1 do
        local item = items_list and items_list[i + 1] or reaper.GetSelectedMediaItem(0, i)
        local take = reaper.GetActiveTake(item)
        if take and not reaper.TakeIsMIDI(take) then
            local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local item_rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
            if item_rate == 0 then item_rate = 1 end
            local item_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
            local sm_count = reaper.GetTakeNumStretchMarkers(take)
            -- Collect indices to remove (backwards)
            local to_remove = {}
            for si = 0, sm_count - 1 do
                local _, src_pos = reaper.GetTakeStretchMarker(take, si)
                -- Convert source position to project time
                local proj_pos = item_pos + (src_pos - item_offs) / item_rate
                local in_range = (not range_start) or
                                 (proj_pos >= range_start - 0.0001 and proj_pos <= range_end + 0.0001)
                if in_range then
                    table.insert(to_remove, si)
                end
            end
            for ri = #to_remove, 1, -1 do
                reaper.DeleteTakeStretchMarkers(take, to_remove[ri])
                total_removed = total_removed + 1
            end
        end
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateTimeline()
    return total_removed
end

-- ============================================================================
-- Ensure transient cache is valid for the given item + detection parameters.
-- Cache key is item only — detection runs at minimum settings (threshold=60,
-- sensitivity=1, retrig=10) to capture ALL possible candidates with their
-- envelope values. Slider changes post-filter the cached candidates instantly.
-- ============================================================================
function ensure_transient_cache(item, take)
    if cached_transients_raw and cached_transient_item == item then
        return  -- cache is valid for this item
    end
    -- Detect at minimum settings to get the superset of all possible transients
    local opts = {
        threshold_dB = 60,    -- lowest amplitude gate → most candidates
        sensitivity_dB = 1,   -- lowest ratio gate → most candidates
        retrig_ms = 10,       -- shortest gap → most candidates
    }
    local transients = detect_audio_transients(item, take, opts)
    if not transients then transients = {} end
    cached_transients_raw = transients
    cached_transient_item = item
    cached_transient_params = nil  -- no longer used
end

-- ============================================================================
-- Post-filter cached transient candidates for given slider values.
-- This is O(N) over the candidate list (typically hundreds) → instant.
-- Applies threshold, sensitivity, and retrig filters in a single pass.
-- Returns a filtered list of {src, proj, strength, env2}.
-- ============================================================================
function filter_transients(candidates, threshold_dB, sensitivity_dB, retrig_ms)
    if not candidates then return {} end
    local Threshold   = 10 ^ (-threshold_dB / 20)
    local Sensitivity = 10 ^ (sensitivity_dB / 20)
    local retrig_sec  = retrig_ms / 1000.0
    local result = {}
    local last_proj = -1e30
    for _, t in ipairs(candidates) do
        if t.strength > Threshold
           and t.env2 and t.env2 > 0
           and t.strength / t.env2 > Sensitivity
           and (t.proj - last_proj) > retrig_sec then
            result[#result + 1] = t
            last_proj = t.proj
        end
    end
    return result
end

-- ============================================================================
-- Apply stretch markers from cached transients onto the item.
-- Post-filters the cached superset using current slider values (instant).
-- Then filters by current time selection / razor edit bounds.
-- Applies offset (sm_offset_ms) to source positions.
-- Removes all existing stretch markers first, then places filtered ones.
-- ============================================================================
function apply_cached_stretch_markers(item, take)
    -- Ensure cache is populated (runs detection once per item, then instant)
    ensure_transient_cache(item, take)
    if not cached_transients_raw then return end
    -- Post-filter cached candidates using current slider values (microseconds)
    local filtered = filter_transients(cached_transients_raw, sm_threshold_dB, sm_sensitivity_dB, sm_retrig_ms)
    local ds, de = get_slider_detect_bounds(item)
    local da_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local da_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local da_rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if da_rate == 0 then da_rate = 1 end
    local offset_sec = sm_offset_ms / 1000.0
    reaper.PreventUIRefresh(1)
    -- Remove stretch markers in range only (preserve those outside range when range is set)
    local sm_count = reaper.GetTakeNumStretchMarkers(take)
    for i = sm_count - 1, 0, -1 do
        if ds or de then
            local _, sm_pos = reaper.GetTakeStretchMarker(take, i)
            local sm_proj = da_pos + sm_pos
            if (not ds or sm_proj >= ds - 0.001) and (not de or sm_proj <= de + 0.001) then
                reaper.DeleteTakeStretchMarkers(take, i)
            end
        else
            reaper.DeleteTakeStretchMarkers(take, i)
        end
    end
    -- Filter by bounds and apply offset
    local to_place = {}
    for _, tr in ipairs(filtered) do
        -- Filter by project-time bounds if set
        if (not ds or tr.proj >= ds) and (not de or tr.proj <= de) then
            local shifted_src = tr.src + offset_sec * da_rate
            if shifted_src >= da_offs then
                to_place[#to_place + 1] = shifted_src
            end
        end
    end
    table.sort(to_place)
    -- Insert stretch markers
    for _, src_pos in ipairs(to_place) do
        reaper.SetTakeStretchMarker(take, -1, src_pos)
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateTimeline()
end

-- ============================================================================
-- Detect song start in an audio item (first sustained signal above silence)
-- Returns: project_time of detected onset, or nil
-- ============================================================================
function detect_song_start(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end

  local PCM_src = reaper.GetMediaItemTake_Source(take)
  local srate = reaper.GetMediaSourceSampleRate(PCM_src)
  if not srate or srate <= 0 then return nil end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local take_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local play_rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  if play_rate == 0 then play_rate = 1 end

  local orig_rate = play_rate
  if play_rate ~= 1 then
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_len * play_rate)
  end

  local SILENCE_THRESHOLD_DB = -40
  local RMS_BLOCK_MS = 10
  local LOOKBACK_MS = 5
  local MIN_CONSECUTIVE_BLOCKS = 2
  local SILENCE_THRESHOLD = 10 ^ (SILENCE_THRESHOLD_DB / 20)

  local block_samples = math.floor(RMS_BLOCK_MS / 1000 * srate)
  local source_len = item_len * orig_rate
  local total_blocks = math.floor(source_len * srate / block_samples)

  local AA = reaper.CreateTakeAudioAccessor(take)
  local first_loud_block = nil
  local consecutive = 0

  for bi = 0, total_blocks - 1 do
    local block_start = take_offs + bi * block_samples / srate
    local buf = reaper.new_array(block_samples)
    reaper.GetAudioAccessorSamples(AA, srate, 1, block_start, block_samples, buf)

    local sum_sq = 0
    for s = 1, block_samples do
      local v = buf[s]; sum_sq = sum_sq + v * v
    end
    local rms = math.sqrt(sum_sq / block_samples)

    if rms > SILENCE_THRESHOLD then
      if consecutive == 0 then first_loud_block = bi end
      consecutive = consecutive + 1
      if consecutive >= MIN_CONSECUTIVE_BLOCKS then
        local lookback_samples = math.floor(LOOKBACK_MS / 1000 * srate)
        local onset_sample = first_loud_block * block_samples
        onset_sample = math.max(0, onset_sample - lookback_samples)

        local scan_start = take_offs + onset_sample / srate
        local scan_len = math.min(block_samples * 3, lookback_samples + block_samples * 2)
        local scan_buf = reaper.new_array(scan_len)
        reaper.GetAudioAccessorSamples(AA, srate, 1, scan_start, scan_len, scan_buf)

        local onset_offset = 0
        for s = 1, scan_len do
          if math.abs(scan_buf[s]) > SILENCE_THRESHOLD * 0.5 then
            onset_offset = s - 1
            break
          end
        end

        reaper.DestroyAudioAccessor(AA)
        if orig_rate ~= 1 then
          reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", orig_rate)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_len)
        end

        local source_time = take_offs + onset_sample / srate + onset_offset / srate
        local project_time = item_pos + (source_time - take_offs) / orig_rate
        return project_time
      end
    else
      consecutive = 0
      first_loud_block = nil
    end
  end

  reaper.DestroyAudioAccessor(AA)
  if orig_rate ~= 1 then
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", orig_rate)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_len)
  end
  return nil
end

-- ============================================================================
-- Run audio-to-score alignment via Python
-- Returns: aligned_boundaries table or nil on failure
-- ============================================================================
function run_audio_alignment(audio_path, score_onsets, measure_boundaries_data, start_time)
  local align_script = script_dir .. "konst_align_score_to_audio.py"

  -- Check Python script exists
  local pf = io.open(align_script, "r")
  if not pf then
    import_log("Alignment script not found: " .. align_script)
    return nil
  end
  pf:close()

  -- Determine Python executable
  local py_exe = reaper.GetExtState("konst_ImportMusicXML", "python_exe")
  if py_exe == "" then py_exe = "python" end

  -- Write input JSON
  local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or reaper.GetResourcePath()
  local ts = tostring(os.time())
  local input_path  = temp_dir .. "\\konst_align_input_" .. ts .. ".json"
  local output_path = temp_dir .. "\\konst_align_output_" .. ts .. ".json"

  -- Build JSON input manually (avoid requiring dkjson at top level)
  local onset_parts = {}
  for _, t in ipairs(score_onsets) do
    onset_parts[#onset_parts + 1] = tostring(t)
  end

  local mb_parts = {}
  for _, mb in ipairs(measure_boundaries_data) do
    mb_parts[#mb_parts + 1] = string.format(
      '{"measure":%d,"score_time":%s,"beats":%d,"beat_type":%d}',
      mb.measure, tostring(mb.score_time), mb.beats, mb.beat_type)
  end

  local start_time_json = ""
  if start_time then
    start_time_json = string.format(',"start_time":%s', tostring(start_time))
  end

  local json_str = string.format(
    '{"audio_path":"%s","score_onsets":[%s],"measure_boundaries":[%s]%s}',
    audio_path:gsub("\\", "\\\\"):gsub('"', '\\"'),
    table.concat(onset_parts, ","),
    table.concat(mb_parts, ","),
    start_time_json)

  local f = io.open(input_path, "w")
  if not f then
    import_log("Could not write alignment input file")
    return nil
  end
  f:write(json_str)
  f:close()

  -- Run Python synchronously (ExecProcess with timeout)
  local cmd = string.format('"%s" "%s" "%s" "%s"',
    py_exe, align_script, input_path, output_path)
  import_log("Running audio alignment...")

  local ret = reaper.ExecProcess(cmd, 120000)  -- 120s timeout

  -- Clean up input
  os.remove(input_path)

  -- Check for error file
  local errf = io.open(output_path .. ".err", "r")
  if errf then
    local err_msg = errf:read("*a")
    errf:close()
    os.remove(output_path .. ".err")
    import_log("Alignment error: " .. err_msg)
    return nil
  end

  -- Read output
  local of = io.open(output_path, "r")
  if not of then
    import_log("Alignment produced no output")
    return nil
  end
  local result_str = of:read("*a")
  of:close()
  os.remove(output_path)

  -- Parse JSON result (simple parser for our known structure)
  local aligned_boundaries = {}
  for entry in result_str:gmatch('{[^{}]+}') do
    -- Skip the outer wrapper, only parse boundary entries
    local measure = tonumber(entry:match('"measure"%s*:%s*(%d+)'))
    local real_time = tonumber(entry:match('"real_time"%s*:%s*([%d%.%-e]+)'))
    local tempo = tonumber(entry:match('"tempo"%s*:%s*([%d%.%-e]+)'))
    local beats = tonumber(entry:match('"beats"%s*:%s*(%d+)'))
    local beat_type = tonumber(entry:match('"beat_type"%s*:%s*(%d+)'))
    if measure and real_time then
      table.insert(aligned_boundaries, {
        measure = measure,
        real_time = real_time,
        tempo = tempo or 120,
        beats = beats or 4,
        beat_type = beat_type or 4
      })
    end
  end

  -- Parse confidence
  local confidence = tonumber(result_str:match('"confidence"%s*:%s*([%d%.]+)')) or 0

  -- Parse per-note corrections (st = score_time, tt = target_time from item start)
  local note_corrections = {}
  for entry in result_str:gmatch('{[^{}]+}') do
    local st = tonumber(entry:match('"st"%s*:%s*([%d%.%-e]+)'))
    local tt = tonumber(entry:match('"tt"%s*:%s*([%d%.%-e]+)'))
    if st and tt and not entry:match('"measure"') then
      local key = string.format("%.4f", st)
      note_corrections[key] = tt
    end
  end

  -- Parse onset_times array (flat array of audio-relative onset positions)
  local onset_times = {}
  local onset_arr_str = result_str:match('"onset_times"%s*:%s*(%[[^%]]*%])')
  if onset_arr_str then
    for val in onset_arr_str:gmatch('([%d%.%-e]+)') do
      local t = tonumber(val)
      if t then table.insert(onset_times, t) end
    end
    table.sort(onset_times)
  end

  if #aligned_boundaries > 0 then
    local n_corr = 0
    for _ in pairs(note_corrections) do n_corr = n_corr + 1 end
    import_log(string.format(
      "Alignment: %d bars, %d note corrections, confidence %.0f%%",
      #aligned_boundaries, n_corr, confidence * 100))
    return aligned_boundaries, note_corrections, onset_times
  end

  import_log("Alignment returned no boundaries")
  return nil, nil, nil
end

-- ============================================================================
-- Convert beat-based ticks to seconds using a tempo map
-- tempo_map: sorted list of {ticks, tempo} pairs
-- ============================================================================
function ticks_to_seconds(pos, map, ppq_val)
  local sec = 0
  local prev_ticks = 0
  local prev_tempo = 120
  for _, entry in ipairs(map) do
    if entry.ticks > pos then break end
    sec = sec + (entry.ticks - prev_ticks) / ppq_val * 60 / prev_tempo
    prev_ticks = entry.ticks
    prev_tempo = entry.tempo
  end
  sec = sec + (pos - prev_ticks) / ppq_val * 60 / prev_tempo
  return sec
end

-- ============================================================================
-- Convert XML ticks to project time using the project's existing tempo map.
-- tick_pos: position in XML ticks (ppq_val ticks per quarter note)
-- ppq_val: ticks per quarter note from the XML
-- import_start_time: project time where import begins
-- Returns: absolute project time
-- The XML tick position is converted to beat offset (quarter notes),
-- then mapped to the project's tempo map starting from import_start_time.
-- ============================================================================
function ticks_to_project_time(tick_pos, ppq_val, import_start_time)
  local qn_offset = tick_pos / ppq_val  -- quarter notes from start of piece
  -- Get the ABSOLUTE QN position of the import start (TimeMap2_timeToBeats returns
  -- beat-within-measure as first value; TimeMap_timeToQN returns accumulated QN from project start)
  local start_qn = reaper.TimeMap_timeToQN(import_start_time)
  -- Map to project time at (start_qn + qn_offset) quarter notes from project start
  return reaper.TimeMap_QNToTime(start_qn + qn_offset)
end

-- ============================================================================
-- Remap data: serialize/deserialize tick-based note & text data on MIDI takes
-- Stored via P_EXT keys so it persists in the RPP project file.
-- ============================================================================

-- Serialize notes array to a compact string: "pos,endpos,ch,pitch,vel;..."
function serialize_remap_notes(notes)
  local parts = {}
  for _, n in ipairs(notes) do
    parts[#parts + 1] = string.format("%d,%d,%d,%d,%d", n.pos, n.endpos, n.channel, n.pitch, n.vel)
  end
  return table.concat(parts, ";")
end

-- Deserialize notes string back to array of {pos, endpos, channel, pitch, vel}
function deserialize_remap_notes(str)
  if not str or str == "" then return nil end
  local notes = {}
  for entry in str:gmatch("[^;]+") do
    local p, e, ch, pi, v = entry:match("^(%d+),(%d+),(%d+),(%d+),(%d+)$")
    if p then
      notes[#notes + 1] = {
        pos = tonumber(p), endpos = tonumber(e),
        channel = tonumber(ch), pitch = tonumber(pi), vel = tonumber(v)
      }
    end
  end
  return #notes > 0 and notes or nil
end

-- Serialize text events array to a compact string: "pos,type,text;..."
-- Text is base64-encoded to avoid delimiter collisions.
function serialize_remap_texts(texts)
  if not texts or #texts == 0 then return "" end
  local parts = {}
  for _, t in ipairs(texts) do
    -- Simple base64 encode for the text field
    local b64 = remap_base64_encode(t.text or "")
    parts[#parts + 1] = string.format("%d,%d,%s", t.pos, t.type or 1, b64)
  end
  return table.concat(parts, ";")
end

-- Deserialize text events string back to array of {pos, type, text}
function deserialize_remap_texts(str)
  if not str or str == "" then return nil end
  local texts = {}
  for entry in str:gmatch("[^;]+") do
    local p, tp, b64 = entry:match("^(%d+),(%d+),(.+)$")
    if p and b64 then
      texts[#texts + 1] = {
        pos = tonumber(p), type = tonumber(tp),
        text = remap_base64_decode(b64)
      }
    end
  end
  return #texts > 0 and texts or nil
end

-- Minimal base64 encode/decode for text event storage
do
  local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  function remap_base64_encode(data)
    local out = {}
    local pad = 0
    for i = 1, #data, 3 do
      local a, b, c = data:byte(i, i + 2)
      b = b or 0; c = c or 0
      if i + 1 > #data then pad = pad + 1 end
      if i + 2 > #data then pad = pad + 1 end
      local n = a * 65536 + b * 256 + c
      out[#out + 1] = b64chars:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
      out[#out + 1] = b64chars:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
      out[#out + 1] = pad < 2 and b64chars:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "="
      out[#out + 1] = pad < 1 and b64chars:sub(n % 64 + 1, n % 64 + 1) or "="
    end
    return table.concat(out)
  end
  local b64lookup = {}
  for i = 1, 64 do b64lookup[b64chars:byte(i)] = i - 1 end
  function remap_base64_decode(data)
    data = data:gsub("=", "")
    local out = {}
    for i = 1, #data, 4 do
      local a = b64lookup[data:byte(i)] or 0
      local b = b64lookup[data:byte(i + 1)] or 0
      local c = b64lookup[data:byte(i + 2)] or 0
      local d = b64lookup[data:byte(i + 3)] or 0
      local n = a * 262144 + b * 4096 + c * 64 + d
      out[#out + 1] = string.char(math.floor(n / 65536) % 256)
      if i + 2 <= #data then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
      if i + 3 <= #data then out[#out + 1] = string.char(n % 256) end
    end
    return table.concat(out)
  end
end

-- Store remap data on a take after note insertion
function store_remap_data(take, notes, texts, ppq_val)
  if not take then return end
  local notes_str = serialize_remap_notes(notes)
  if notes_str and notes_str ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_NOTES", notes_str, true)
  end
  local texts_str = serialize_remap_texts(texts)
  if texts_str and texts_str ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_TEXTS", texts_str, true)
  end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_PPQ", tostring(ppq_val), true)
end

-- ============================================================================
-- Remap: re-position MIDI notes on selected items using the current tempo map.
-- Scans all takes on selected items for stored remap data (P_EXT:XMLREMAP_*).
-- Clears existing MIDI events and re-inserts them from stored tick data.
-- Returns: number of takes remapped, or 0 if none found.
-- ============================================================================
function remap_midi_to_tempo_map()
  local num_items = reaper.CountSelectedMediaItems(0)
  if num_items == 0 then return 0 end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local remapped_count = 0

  for i = 0, num_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local num_takes = reaper.GetMediaItemNumTakes(item)

      -- Collect max end-time across all takes for item length adjustment
      local max_end_time = item_pos

      for t = 0, num_takes - 1 do
        local take = reaper.GetMediaItemTake(item, t)
        if take and reaper.TakeIsMIDI(take) then
          -- Read stored remap data
          local ok_n, notes_str = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_NOTES", "", false)
          local ok_p, ppq_str = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_PPQ", "", false)

          if ok_n and notes_str ~= "" and ok_p and ppq_str ~= "" then
            local notes = deserialize_remap_notes(notes_str)
            local ppq_val = tonumber(ppq_str)

            if notes and ppq_val and ppq_val > 0 then
              -- Read text events if stored
              local ok_t, texts_str = reaper.GetSetMediaItemTakeInfo_String(take, "P_EXT:XMLREMAP_TEXTS", "", false)
              local texts = (ok_t and texts_str ~= "") and deserialize_remap_texts(texts_str) or nil

              -- Clear all existing MIDI events
              reaper.MIDI_DisableSort(take)
              local _, note_count, cc_count, text_count = reaper.MIDI_CountEvts(take)
              for ni = note_count - 1, 0, -1 do
                reaper.MIDI_DeleteNote(take, ni)
              end
              for ti = text_count - 1, 0, -1 do
                reaper.MIDI_DeleteTextSysexEvt(take, ti)
              end

              -- Re-insert notes using current project tempo map
              for _, n in ipairs(notes) do
                local start_proj = ticks_to_project_time(n.pos, ppq_val, item_pos)
                local end_proj = ticks_to_project_time(n.endpos, ppq_val, item_pos)
                local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, start_proj)
                local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(take, end_proj)
                if ppq_end <= ppq_start then ppq_end = ppq_start + 1 end
                reaper.MIDI_InsertNote(take, false, false, ppq_start, ppq_end, n.channel, n.pitch, n.vel, true)
                if end_proj > max_end_time then max_end_time = end_proj end
              end

              -- Re-insert text events
              if texts then
                for _, tx in ipairs(texts) do
                  local t_proj = ticks_to_project_time(tx.pos, ppq_val, item_pos)
                  local ppq_pos = reaper.MIDI_GetPPQPosFromProjTime(take, t_proj)
                  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq_pos, tx.type, tx.text)
                end
              end

              reaper.MIDI_Sort(take)
              remapped_count = remapped_count + 1
            end
          end
        end
      end

      -- Adjust item length to fit all remapped notes
      if max_end_time > item_pos then
        local new_length = max_end_time - item_pos + 0.01  -- small padding
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Remap MIDI to project tempo map", -1)
  return remapped_count
end

-- ============================================================================
-- Nudge notes to transients: create a new take on a MIDI item where each note
-- is snapped to the nearest stretch marker position from an audio item.
-- Requires exactly 2 selected items: one MIDI, one audio with stretch markers.
-- Returns: nudge_count (notes moved), or nil + error string on failure.
-- ============================================================================
function nudge_notes_to_transients()
  local num_items = reaper.CountSelectedMediaItems(0)
  if num_items < 2 then
    return nil, "Select exactly 2 items: one MIDI item and one audio item with stretch markers."
  end

  -- Identify the MIDI item and audio item among selected items
  local midi_item, midi_take, audio_item, audio_take
  for i = 0, num_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    if item then
      local take = reaper.GetActiveTake(item)
      if take then
        if reaper.TakeIsMIDI(take) then
          if not midi_item then
            midi_item = item
            midi_take = take
          end
        else
          if not audio_item then
            audio_item = item
            audio_take = take
          end
        end
      end
    end
  end

  if not midi_item or not midi_take then
    return nil, "No MIDI item found among selected items."
  end
  if not audio_item or not audio_take then
    return nil, "No audio item with stretch markers found among selected items."
  end

  -- Read stretch marker positions as project times
  local sm_count = reaper.GetTakeNumStretchMarkers(audio_take)
  if sm_count == 0 then
    return nil, "Audio item has no stretch markers. Add stretch markers first."
  end

  local audio_pos = reaper.GetMediaItemInfo_Value(audio_item, "D_POSITION")
  local audio_offset = reaper.GetMediaItemTakeInfo_Value(audio_take, "D_STARTOFFS")
  local audio_rate = reaper.GetMediaItemTakeInfo_Value(audio_take, "D_PLAYRATE")
  if audio_rate == 0 then audio_rate = 1 end

  local sm_positions = {}
  for si = 0, sm_count - 1 do
    local _, pos_in_source = reaper.GetTakeStretchMarker(audio_take, si)
    -- Convert source position to project time
    local proj_time = audio_pos + (pos_in_source - audio_offset) / audio_rate
    sm_positions[#sm_positions + 1] = proj_time
  end
  table.sort(sm_positions)

  -- Read all notes from the MIDI take
  local _, note_count = reaper.MIDI_CountEvts(midi_take)
  if note_count == 0 then
    return nil, "MIDI item has no notes."
  end

  local src_notes = {}
  for i = 0, note_count - 1 do
    local ret, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(midi_take, i)
    if ret then
      src_notes[#src_notes + 1] = {
        proj_time = reaper.MIDI_GetProjTimeFromPPQPos(midi_take, startppq),
        sp = startppq, ep = endppq,
        sel = sel, muted = muted,
        chan = chan, pitch = pitch, vel = vel,
      }
    end
  end

  -- Read text/sysex events from original take to copy them to nudge take
  local _, _, _, text_count = reaper.MIDI_CountEvts(midi_take)
  local src_texts = {}
  for i = 0, text_count - 1 do
    local ret, sel, muted, ppqpos, evt_type, msg = reaper.MIDI_GetTextSysexEvt(midi_take, i)
    if ret then
      src_texts[#src_texts + 1] = {ppqpos = ppqpos, sel = sel, muted = muted, evt_type = evt_type, msg = msg}
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Create a new take on the MIDI item (shares the same source)
  local nudge_take = reaper.AddTakeToMediaItem(midi_item)
  if not nudge_take then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Nudge notes to transients (failed)", -1)
    return nil, "Failed to create new take."
  end

  -- Copy source from original take
  local old_src = reaper.GetMediaItemTake_Source(nudge_take)
  local src = reaper.GetMediaItemTake_Source(midi_take)
  reaper.SetMediaItemTake_Source(nudge_take, src)
  if old_src then reaper.PCM_Source_Destroy(old_src) end

  -- Name the new take
  local _, orig_name = reaper.GetSetMediaItemTakeInfo_String(midi_take, "P_NAME", "", false)
  local nudge_name = (orig_name ~= "" and orig_name or "MIDI") .. " (nudged)"
  reaper.GetSetMediaItemTakeInfo_String(nudge_take, "P_NAME", nudge_name, true)

  -- Insert nudged notes
  reaper.MIDI_DisableSort(nudge_take)
  local nudge_count = 0

  -- Snap each note to nearest stretch marker and preserve original PPQ duration
  local nudged_notes = {}
  for _, tn in ipairs(src_notes) do
    -- Binary search for closest stretch marker
    local lo, hi = 1, #sm_positions
    while lo < hi do
      local mid = math.floor((lo + hi) / 2)
      if sm_positions[mid] < tn.proj_time then lo = mid + 1 else hi = mid end
    end
    local best_d = math.huge
    local best_proj = tn.proj_time
    for ci = lo - 1, lo + 1 do
      if ci >= 1 and ci <= #sm_positions then
        local d = math.abs(sm_positions[ci] - tn.proj_time)
        if d < best_d then
          best_d = d
          best_proj = sm_positions[ci]
        end
      end
    end
    if best_proj ~= tn.proj_time then nudge_count = nudge_count + 1 end

    local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, best_proj)
    local orig_dur = tn.ep - tn.sp
    local ppq_end = ppq_start + (orig_dur > 0 and orig_dur or 10)
    nudged_notes[#nudged_notes + 1] = {
      sel=tn.sel, muted=tn.muted, chan=tn.chan, pitch=tn.pitch, vel=tn.vel,
      sp=ppq_start, ep=ppq_end
    }
  end

  -- Prevent overlap: for same channel+pitch, trim note end to next note's start
  table.sort(nudged_notes, function(a, b)
    if a.chan ~= b.chan then return a.chan < b.chan end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return a.sp < b.sp
  end)
  for i = 1, #nudged_notes - 1 do
    local na = nudged_notes[i]
    local nb = nudged_notes[i + 1]
    if na.chan == nb.chan and na.pitch == nb.pitch and na.ep > nb.sp then
      na.ep = nb.sp
      if na.ep <= na.sp then na.ep = na.sp + 1 end
    end
  end

  -- Insert nudged notes
  for _, nn in ipairs(nudged_notes) do
    reaper.MIDI_InsertNote(nudge_take, nn.sel, nn.muted,
      nn.sp, nn.ep, nn.chan, nn.pitch, nn.vel, true)
  end

  -- Copy text/sysex events to nudge take at original positions
  for _, tx in ipairs(src_texts) do
    reaper.MIDI_InsertTextSysexEvt(nudge_take, tx.sel, tx.muted, tx.ppqpos, tx.evt_type, tx.msg)
  end

  reaper.MIDI_Sort(nudge_take)

  -- Copy remap P_EXT data to the nudge take if present on original
  local ok_n, notes_str = reaper.GetSetMediaItemTakeInfo_String(midi_take, "P_EXT:XMLREMAP_NOTES", "", false)
  if ok_n and notes_str ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(nudge_take, "P_EXT:XMLREMAP_NOTES", notes_str, true)
  end
  local ok_t, texts_str = reaper.GetSetMediaItemTakeInfo_String(midi_take, "P_EXT:XMLREMAP_TEXTS", "", false)
  if ok_t and texts_str ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(nudge_take, "P_EXT:XMLREMAP_TEXTS", texts_str, true)
  end
  local ok_p, ppq_str = reaper.GetSetMediaItemTakeInfo_String(midi_take, "P_EXT:XMLREMAP_PPQ", "", false)
  if ok_p and ppq_str ~= "" then
    reaper.GetSetMediaItemTakeInfo_String(nudge_take, "P_EXT:XMLREMAP_PPQ", ppq_str, true)
  end

  -- Make the nudge take active
  reaper.SetActiveTake(nudge_take)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Nudge notes to transients", -1)
  return nudge_count
end
function capture_pre_import_state()
    local state = {}
    state.track_count = reaper.CountTracks(0)
    state.track_guids = {}
    for i = 0, state.track_count - 1 do
        local track = reaper.GetTrack(0, i)
        state.track_guids[reaper.GetTrackGUID(track)] = true
    end
    state.item_count = reaper.CountMediaItems(0)
    state.item_guids = {}
    for i = 0, state.item_count - 1 do
        local item = reaper.GetMediaItem(0, i)
        state.item_guids[reaper.BR_GetMediaItemGUID(item)] = true
    end
    state.region_count = 0
    state.region_indices = {}
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local _, isrgn, _, _, _, idx = reaper.EnumProjectMarkers(i)
        if isrgn then
            state.region_count = state.region_count + 1
            state.region_indices[idx] = true
        end
    end
    state.tempo_count = reaper.CountTempoTimeSigMarkers(0)
    return state
end

function capture_post_import_history(pre_state, filepath)
    local entry = {
        label = filepath and filepath:match("[^\\/]+$") or "Import",
        timestamp = os.time(),
        track_guids = {},
        item_guids = {},
        region_indices = {},
        tempo_marker_indices = {},
    }
    -- Find new tracks
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        local guid = reaper.GetTrackGUID(track)
        if not pre_state.track_guids[guid] then
            table.insert(entry.track_guids, guid)
        end
    end
    -- Find new items
    local item_count = reaper.CountMediaItems(0)
    for i = 0, item_count - 1 do
        local item = reaper.GetMediaItem(0, i)
        local guid = reaper.BR_GetMediaItemGUID(item)
        if not pre_state.item_guids[guid] then
            table.insert(entry.item_guids, guid)
        end
    end
    -- Find new regions
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local _, isrgn, _, _, _, idx = reaper.EnumProjectMarkers(i)
        if isrgn and not pre_state.region_indices[idx] then
            table.insert(entry.region_indices, idx)
        end
    end
    -- Find new tempo markers
    local tempo_count = reaper.CountTempoTimeSigMarkers(0)
    for i = pre_state.tempo_count, tempo_count - 1 do
        table.insert(entry.tempo_marker_indices, i)
    end
    -- Only add if something was created
    if #entry.track_guids > 0 or #entry.item_guids > 0 or #entry.region_indices > 0 or #entry.tempo_marker_indices > 0 then
        table.insert(import_history, entry)
        save_import_history()
    end
end

-- ============================================================================
-- ============================================================================
-- Find nearest stretch marker to the REAPER edit cursor (across all audio items).
-- Returns item, take, idx (0-based), src (take-time), proj_pos.
-- Returns nil,nil,-1,0,0 if none found.
-- ============================================================================
function find_sm_near_cursor()
    local cur = reaper.GetCursorPosition()
    local best_item, best_take, best_idx, best_src, best_proj, best_srcpos = nil, nil, -1, 0, 0, 0
    local best_dist = math.huge
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local it = reaper.GetMediaItem(0, i)
        local tk = reaper.GetActiveTake(it)
        if tk and not reaper.TakeIsMIDI(tk) then
            local ip = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            for si = 0, reaper.GetTakeNumStretchMarkers(tk) - 1 do
                local _, sm_pos, sm_srcpos = reaper.GetTakeStretchMarker(tk, si)
                local proj = ip + sm_pos
                local d = math.abs(proj - cur)
                if d < best_dist then
                    best_dist = d
                    best_item = it; best_take = tk; best_idx = si
                    best_src = sm_pos
                    best_srcpos = (sm_srcpos and sm_srcpos >= 0) and sm_srcpos or sm_pos
                    best_proj = proj
                end
            end
        end
    end
    return best_item, best_take, best_idx, best_src, best_proj, best_srcpos
end

-- ============================================================================
-- Find nearest tempo marker to the REAPER edit cursor.
-- Returns idx (0-based), proj_time, bpm, tsn, tsd, linear.
-- Returns -1 if not found.
-- ============================================================================
function find_tempo_near_cursor()
    local cur = reaper.GetCursorPosition()
    local best_idx, best_t, best_bpm = -1, 0, 120
    local best_tsn, best_tsd, best_lin = 4, 4, false
    local best_dist = math.huge
    for mi = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
        local rv, t, _, _, bpm, tsn, tsd, lin = reaper.GetTempoTimeSigMarker(0, mi)
        if rv then
            local d = math.abs(t - cur)
            if d < best_dist then
                best_dist = d
                best_idx = mi; best_t = t; best_bpm = bpm
                best_tsn = tsn; best_tsd = tsd; best_lin = lin
            end
        end
    end
    return best_idx, best_t, best_bpm, best_tsn, best_tsd, best_lin
end

-- ============================================================================
-- Snap nearest stretch marker to edit cursor to the REAPER project grid.
-- ============================================================================
function snap_sm_to_grid()
    local item, take, idx, src = find_sm_near_cursor()
    if not item or idx < 0 then
        safe_msgbox("No stretch markers found near the edit cursor.", "No SM", 0)
        return
    end
    local ip = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local proj = ip + src
    local snapped = reaper.SnapToGrid(0, proj)
    if math.abs(snapped - proj) < 0.0001 then return end
    local new_src = src + (snapped - proj)
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    reaper.DeleteTakeStretchMarkers(take, idx)
    reaper.SetTakeStretchMarker(take, idx, new_src)
    reaper.UpdateTimeline()
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Snap stretch marker to grid", -1)
end

-- ============================================================================
-- Snap nearest tempo marker to edit cursor to the nearest stretch marker position.
-- ============================================================================
function snap_tempo_to_sm()
    local tidx, t_time, bpm, tsn, tsd, lin = find_tempo_near_cursor()
    if tidx < 0 then
        safe_msgbox("No tempo markers found near the edit cursor.", "No Tempo", 0)
        return
    end
    local best_proj, best_dist = nil, math.huge
    for i = 0, reaper.CountMediaItems(0) - 1 do
        local it = reaper.GetMediaItem(0, i)
        local tk = reaper.GetActiveTake(it)
        if tk and not reaper.TakeIsMIDI(tk) then
            local ip = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
            for si = 0, reaper.GetTakeNumStretchMarkers(tk) - 1 do
                local _, src = reaper.GetTakeStretchMarker(tk, si)
                local proj = ip + src
                local d = math.abs(proj - t_time)
                if d < best_dist then best_dist = d; best_proj = proj end
            end
        end
    end
    if not best_proj then
        safe_msgbox("No stretch markers found in project.", "No SM", 0)
        return
    end
    if math.abs(best_proj - t_time) < 0.0001 then return end
    reaper.Undo_BeginBlock()
    reaper.DeleteTempoTimeSigMarker(0, tidx)
    reaper.SetTempoTimeSigMarker(0, -1, best_proj, -1, -1, bpm, tsn, tsd, lin)
    reaper.UpdateTimeline()
    reaper.Undo_EndBlock("Snap tempo marker to stretch marker", -1)
end

-- ============================================================================
-- MIDI Stretch Markers mode
-- Take markers on MIDI items act as pseudo-stretch markers.  When a take
-- marker is moved the MIDI notes in the affected region are scaled
-- proportionally and the marker name is updated to show the segment rate
-- (e.g. "1.00x", "0.83x").
-- ============================================================================

-- Convert a take-marker srcpos (seconds from source start) to PPQ.
-- For MIDI items D_STARTOFFS is typically 0; we use it defensively.
local function midi_sm_srcpos_to_ppq(take, item_pos, take_startoffs, srcpos)
    return reaper.MIDI_GetPPQPosFromProjTime(take, item_pos - take_startoffs + srcpos)
end

-- Initialize (or re-initialize) the cache entry for a MIDI take.
-- Called the first time we see the take, or when the marker count changes.
function midi_sm_init_take(take_key, item, take)
    local item_pos      = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local take_startoffs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local n = reaper.GetNumTakeMarkers(take)
    local markers = {}
    for mi = 0, n - 1 do
        local srcpos, name = reaper.GetTakeMarker(take, mi)
        -- Only track markers that already carry a rated label (e.g. "1.00x").
        -- Unrated markers are cached with rated=false so we can track their position
        -- without ever triggering a stretch on them.
        local rated = (name and name:match(MIDI_TM_LABEL_PATTERN)) and true or false
        markers[mi + 1] = {orig_s = srcpos, last_s = srcpos, rated = rated}
    end
    -- Compute orig_ppq for each marker (PPQ position at its original source offset)
    for mi_b = 1, #markers do
        markers[mi_b].orig_ppq = midi_sm_srcpos_to_ppq(take, item_pos, take_startoffs, markers[mi_b].orig_s)
    end
    -- Snapshot all notes as pristine baseline for non-accumulating piecewise warp
    local note_backup = {}
    local n_nb = select(1, reaper.MIDI_CountEvts(take))
    for ni_b = 0, n_nb - 1 do
        local r_b, s_b, m_b, sp_b, ep_b, ch_b, pt_b, v_b = reaper.MIDI_GetNote(take, ni_b)
        if r_b then note_backup[#note_backup + 1] = {ni=ni_b, sel=s_b, muted=m_b, sp=sp_b, ep=ep_b, chan=ch_b, pitch=pt_b, vel=v_b} end
    end
    midi_sm_state[take_key] = {
        item          = item,
        take          = take,
        item_pos      = item_pos,
        take_startoffs = take_startoffs,
        markers       = markers,
        note_backup   = note_backup,
        needs_reindex = false,  -- set true after MIDI_Sort (indices become stale)
        tm_drag       = {},     -- per-marker drag state {stable, undo_open}
    }
end

-- Warp notes from pristine note_backup using piecewise-linear mapping.
-- Uses MIDI_SetNote in-place (no visual flicker) when ni indices are valid.
-- Falls back to delete+reinsert only when note count has changed since backup.
-- Caller must call MIDI_Sort(take) only after drag ENDS — NOT every frame.
function midi_sm_apply_piecewise_warp(take_key)
    local cached = midi_sm_state[take_key]
    if not cached or not cached.note_backup or #cached.note_backup == 0 then return end
    local take        = cached.take
    local ip          = cached.item_pos
    local ts          = cached.take_startoffs
    local markers     = cached.markers
    local n_m         = #markers
    local note_backup = cached.note_backup
    -- Segment boundaries
    local orig_ppqs = {}; local curr_ppqs = {}
    orig_ppqs[0] = 0;  curr_ppqs[0] = 0
    for mi = 1, n_m do
        local m = markers[mi]
        orig_ppqs[mi] = m.orig_ppq or reaper.MIDI_GetPPQPosFromProjTime(take, ip - ts + m.orig_s)
        curr_ppqs[mi] = reaper.MIDI_GetPPQPosFromProjTime(take, ip - ts + m.last_s)
    end
    -- Warp: piecewise linear with exact pinning at marker boundaries
    local function warp(x)
        for si = 1, n_m do
            if math.abs(x - orig_ppqs[si]) < 0.5 then return curr_ppqs[si] end
        end
        local prev_o, prev_c = 0, 0
        for si = 1, n_m do
            if x < orig_ppqs[si] then
                local span = orig_ppqs[si] - prev_o
                return span > 0.5 and (prev_c + (x - prev_o) / span * (curr_ppqs[si] - prev_c)) or prev_c
            end
            prev_o = orig_ppqs[si]; prev_c = curr_ppqs[si]
        end
        return x + (curr_ppqs[n_m] - orig_ppqs[n_m])
    end
    -- Rebuild ni mapping when indices are stale (after MIDI_Sort or drag start)
    if cached.needs_reindex then
        local n_curr = select(1, reaper.MIDI_CountEvts(take))
        if n_curr == #note_backup then
            local cn = {}
            for ni = 0, n_curr - 1 do
                local r, _, _, sp = reaper.MIDI_GetNote(take, ni)
                if r then cn[#cn + 1] = {ni = ni, sp = sp} end
            end
            table.sort(cn, function(a, b) return a.sp < b.sp end)
            local sbi = {}
            for i = 1, #note_backup do sbi[i] = i end
            table.sort(sbi, function(a, b) return note_backup[a].sp < note_backup[b].sp end)
            for rank, bi in ipairs(sbi) do
                note_backup[bi].ni = cn[rank] and cn[rank].ni or -1
            end
            cached._count_mismatch = false
        else
            cached._count_mismatch = true  -- note count changed: use fallback
        end
        cached.needs_reindex = false
    end
    reaper.PreventUIRefresh(1)
    if cached._count_mismatch then
        -- Fallback: delete+reinsert (slower, causes one-frame flicker, handles note count change)
        local nn = select(1, reaper.MIDI_CountEvts(take))
        for ni = nn - 1, 0, -1 do reaper.MIDI_DeleteNote(take, ni) end
        for _, nb in ipairs(note_backup) do
            local new_sp = math.floor(warp(nb.sp) + 0.5)
            local new_ep = math.max(new_sp + 1, math.floor(warp(nb.ep) + 0.5))
            reaper.MIDI_InsertNote(take, nb.sel, nb.muted, new_sp, new_ep, nb.chan, nb.pitch, nb.vel, true)
        end
    else
        -- Fast path: update notes in-place (no visual flicker, stable indices during drag)
        reaper.MIDI_DisableSort(take)
        for _, nb in ipairs(note_backup) do
            if nb.ni and nb.ni >= 0 then
                local new_sp = math.floor(warp(nb.sp) + 0.5)
                local new_ep = math.max(new_sp + 1, math.floor(warp(nb.ep) + 0.5))
                reaper.MIDI_SetNote(take, nb.ni, nb.sel, nb.muted, new_sp, new_ep, nb.chan, nb.pitch, nb.vel, false)
            end
        end
    end
    reaper.PreventUIRefresh(-1)
end

-- Apply note stretching when the marker at changed_mi (0-based) moves
-- from old_srcpos to new_srcpos.
function midi_sm_apply_stretch(take_key, changed_mi, old_srcpos, new_srcpos)
    local cached = midi_sm_state[take_key]
    if not cached then return end
    local take        = cached.take
    local item        = cached.item
    local item_pos    = cached.item_pos
    local take_so     = cached.take_startoffs
    local markers     = cached.markers
    local n_m         = #markers

    -- Neighbour source positions (use last_s which is current at call time)
    local prev_srcpos = (changed_mi > 0) and markers[changed_mi].last_s or 0
    local next_idx    = changed_mi + 2  -- 1-based index of next marker
    local next_srcpos = (next_idx <= n_m) and markers[next_idx].last_s or nil

    -- Convert everything to PPQ
    local prev_ppq = midi_sm_srcpos_to_ppq(take, item_pos, take_so, prev_srcpos)
    local old_ppq  = midi_sm_srcpos_to_ppq(take, item_pos, take_so, old_srcpos)
    local new_ppq  = midi_sm_srcpos_to_ppq(take, item_pos, take_so, new_srcpos)
    local next_ppq = next_srcpos and midi_sm_srcpos_to_ppq(take, item_pos, take_so, next_srcpos) or 1e9

    -- Guard degenerate regions (marker would collapse to a point)
    local left_span_old  = old_ppq  - prev_ppq
    local right_span_old = next_ppq - old_ppq
    if left_span_old < 0.5 and right_span_old < 0.5 then return end

    local n_notes = select(1, reaper.MIDI_CountEvts(take))
    if n_notes == 0 then return end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Rescale all notes in the two affected sub-regions
    for ni = 0, n_notes - 1 do
        local ret, sel, muted, sp, ep, chan, pitch, vel = reaper.MIDI_GetNote(take, ni)
        if ret then
            local new_sp = sp
            local new_ep = ep

            -- Left region: [prev_ppq, old_ppq)
            if left_span_old > 0.5 then
                local new_left = new_ppq - prev_ppq
                if sp >= prev_ppq and sp < old_ppq then
                    new_sp = prev_ppq + (sp - prev_ppq) / left_span_old * new_left
                end
                if ep > prev_ppq and ep <= old_ppq then
                    new_ep = prev_ppq + (ep - prev_ppq) / left_span_old * new_left
                end
            end

            -- Right region: [old_ppq, next_ppq)
            if right_span_old > 0.5 then
                local new_right = next_ppq - new_ppq
                if sp >= old_ppq and sp < next_ppq then
                    new_sp = new_ppq + (sp - old_ppq) / right_span_old * new_right
                end
                if ep > old_ppq and ep <= next_ppq then
                    new_ep = new_ppq + (ep - old_ppq) / right_span_old * new_right
                end
            end

            new_sp = math.floor(new_sp + 0.5)
            new_ep = math.max(new_sp + 1, math.floor(new_ep + 0.5))

            if new_sp ~= sp or new_ep ~= ep then
                reaper.MIDI_SetNote(take, ni, sel, muted, new_sp, new_ep, chan, pitch, vel, false)
            end
        end
    end

    -- Update marker name: rate shown = (original span) / (current span) for left segment
    local left_orig  = markers[changed_mi + 1].orig_s - ((changed_mi > 0) and markers[changed_mi].orig_s or 0)
    local left_curr  = new_srcpos - prev_srcpos
    local rate_left  = (left_curr > 1e-7) and (left_orig / left_curr) or 0
    local _, _, color_c = reaper.GetTakeMarker(take, changed_mi)
    reaper.SetTakeMarker(take, changed_mi, string.format("%.2fx", rate_left), new_srcpos, color_c)

    -- Update next marker's name too (its left segment changed)
    if next_idx <= n_m then
        local right_orig = markers[next_idx].orig_s - markers[changed_mi + 1].orig_s
        local right_curr = (next_srcpos or new_srcpos) - new_srcpos
        local rate_right = (right_curr > 1e-7) and (right_orig / right_curr) or 0
        local next_curr_s, _, color_n = reaper.GetTakeMarker(take, next_idx - 1)
        reaper.SetTakeMarker(take, next_idx - 1, string.format("%.2fx", rate_right), next_curr_s, color_n)
    end

    reaper.MIDI_Sort(take)
    reaper.UpdateItemInProject(item)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("MIDI SM: stretch notes", -1)
end

-- Called every frame when midi_sm_enabled.  Detects moved take markers on
-- MIDI items and rebuilds note positions via non-accumulating piecewise warp.
function check_midi_sm_changes()
    local n_items = reaper.CountMediaItems(0)
    for ii = 0, n_items - 1 do
        local item = reaper.GetMediaItem(0, ii)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
            local n_m = reaper.GetNumTakeMarkers(take)
            if n_m > 0 then
                local tk_key = tostring(take)
                local cached = midi_sm_state[tk_key]

                -- Init or re-init if marker count changed
                if not cached or #cached.markers ~= n_m then
                    midi_sm_init_take(tk_key, item, take)
                    cached = midi_sm_state[tk_key]
                end
                if not cached.tm_drag then cached.tm_drag = {} end

                -- Detect moved markers (process at most one rated marker per frame)
                for mi = 0, n_m - 1 do
                    local curr_s, curr_name = reaper.GetTakeMarker(take, mi)
                    local cm = cached.markers[mi + 1]
                    if cm then
                        cm.rated = (curr_name and curr_name:match(MIDI_TM_LABEL_PATTERN)) and true or false
                        local drag = cached.tm_drag[mi]
                        if cm.rated and math.abs(curr_s - cm.last_s) > 1e-5 then
                            -- Open undo block on first movement of this drag
                            if not drag then
                                drag = {stable=0, undo_open=false}
                                cached.tm_drag[mi] = drag
                                cached.needs_reindex = true  -- reindex at drag start
                                reaper.Undo_BeginBlock()
                                drag.undo_open = true
                            end
                            drag.stable = 0
                            -- Update last_s BEFORE warp so warp reads current position
                            cm.last_s = curr_s
                            -- Rebuild all notes from pristine backup via piecewise warp
                            reaper.PreventUIRefresh(1)
                            midi_sm_apply_piecewise_warp(tk_key)
                            -- Update rate label for moved marker
                            local prev_s_a = (mi > 0) and cached.markers[mi].last_s or 0
                            local left_orig_a = cached.markers[mi+1].orig_s - ((mi > 0) and cached.markers[mi].orig_s or 0)
                            local left_curr_a = curr_s - prev_s_a
                            local rate_left_a = (left_curr_a > 1e-7) and (left_orig_a / left_curr_a) or 0
                            local _, _, color_a = reaper.GetTakeMarker(take, mi)
                            reaper.SetTakeMarker(take, mi, string.format("%.2fx", rate_left_a), curr_s, color_a)
                            -- Update next marker rate label
                            local nxt_idx_a = mi + 2
                            if nxt_idx_a <= n_m then
                                local right_orig_a = cached.markers[nxt_idx_a].orig_s - cached.markers[mi+1].orig_s
                                local next_s_a = cached.markers[nxt_idx_a].last_s
                                local right_curr_a = next_s_a - curr_s
                                local rate_right_a = (right_curr_a > 1e-7) and (right_orig_a / right_curr_a) or 0
                                local ncs_a, _, color_na = reaper.GetTakeMarker(take, nxt_idx_a - 1)
                                reaper.SetTakeMarker(take, nxt_idx_a - 1, string.format("%.2fx", rate_right_a), ncs_a, color_na)
                            end
                            -- MIDI_Sort deferred until drag settles (keeps indices stable during drag)
                            reaper.UpdateItemInProject(item)
                            reaper.PreventUIRefresh(-1)
                            break  -- one change per frame
                        else
                            if not cm.rated then
                                cm.last_s = curr_s  -- track unrated markers silently
                            end
                            -- Decay stable counter; close undo block when drag settles
                            if drag then
                                drag.stable = drag.stable + 1
                                if drag.stable > 3 then
                                    -- Sort once when drag settles, mark indices stale
                                    reaper.MIDI_Sort(take)
                                    reaper.UpdateItemInProject(item)
                                    cached.needs_reindex = true
                                    if drag.undo_open then
                                        reaper.Undo_EndBlock("MIDI SM: stretch notes", -1)
                                        drag.undo_open = false
                                    end
                                    cached.tm_drag[mi] = nil
                                end
                            end
                        end
                    end
                end
            else
                -- No markers on this take; clear stale cache
                midi_sm_state[tostring(take)] = nil
            end
        end
    end
end

-- ============================================================================
-- MIDI TM helpers: find nearest rated take marker, insert take marker, inner stretch
-- ============================================================================

-- Pattern that identifies a "rated" take marker label (e.g. "1.00x", "0.83x")
MIDI_TM_LABEL_PATTERN = "^%-?%d+%.%d+x$"

-- Find the rated take marker (label matches MIDI_TM_LABEL_PATTERN) on any MIDI item
-- that is closest to the edit cursor.
-- Returns: item, take, mi (0-based), srcpos  — or nil if none found.
function find_midi_tm_near_cursor()
    local cursor = reaper.GetCursorPosition()
    local best_item, best_take, best_mi, best_srcpos = nil, nil, -1, 0
    local best_dist = math.huge
    local n_items = reaper.CountMediaItems(0)
    for ii = 0, n_items - 1 do
        local item = reaper.GetMediaItem(0, ii)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
            local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local take_so  = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
            local n_m = reaper.GetNumTakeMarkers(take)
            for mi = 0, n_m - 1 do
                local srcpos, name = reaper.GetTakeMarker(take, mi)
                if name and name:match(MIDI_TM_LABEL_PATTERN) then
                    local proj_t = item_pos - take_so + srcpos
                    local dist = math.abs(proj_t - cursor)
                    if dist < best_dist then
                        best_dist = dist
                        best_item = item; best_take = take
                        best_mi = mi; best_srcpos = srcpos
                    end
                end
            end
        end
    end
    return best_item, best_take, best_mi, best_srcpos
end

-- Insert a "1.00x" take marker at the edit cursor on the selected MIDI item.
function insert_midi_tm_at_cursor()
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if not sel_item then
        safe_msgbox("Select a MIDI item first.", "No Selection", 0)
        return
    end
    local take = reaper.GetActiveTake(sel_item)
    if not take or not reaper.TakeIsMIDI(take) then
        safe_msgbox("Selected item is not a MIDI item.", "Not MIDI", 0)
        return
    end
    local cursor  = reaper.GetCursorPosition()
    local item_pos = reaper.GetMediaItemInfo_Value(sel_item, "D_POSITION")
    local take_so  = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local srcpos   = cursor - item_pos + take_so
    if srcpos < 0 then
        safe_msgbox("Edit cursor is before the MIDI item start.", "Out of Range", 0)
        return
    end
    reaper.Undo_BeginBlock()
    reaper.SetTakeMarker(take, -1, "1.00x", srcpos, 0)
    -- Re-init cache so check_midi_sm_changes picks it up cleanly
    midi_sm_init_take(tostring(take), sel_item, take)
    reaper.UpdateItemInProject(sel_item)
    reaper.Undo_EndBlock("Insert MIDI take marker", -1)
end

-- Snap the rated take marker nearest the edit cursor to the closest note start or end.
function snap_midi_tm_to_note()
    local bi, bt, bmi, bs = find_midi_tm_near_cursor()
    if not bi or bmi < 0 then
        safe_msgbox("No rated take markers (e.g. 1.00x) found near the edit cursor.", "No TM", 0)
        return false
    end
    local item_pos = reaper.GetMediaItemInfo_Value(bi, "D_POSITION")
    local take_so  = reaper.GetMediaItemTakeInfo_Value(bt, "D_STARTOFFS")
    local n_notes  = select(1, reaper.MIDI_CountEvts(bt))
    if n_notes == 0 then
        safe_msgbox("No notes in the MIDI item.", "No Notes", 0)
        return false
    end
    local best_dist = math.huge
    local best_srcpos = bs
    for ni = 0, n_notes - 1 do
        local r, _, _, sp, ep = reaper.MIDI_GetNote(bt, ni)
        if r then
            local sp_s = reaper.MIDI_GetProjTimeFromPPQPos(bt, sp) - item_pos + take_so
            local ep_s = reaper.MIDI_GetProjTimeFromPPQPos(bt, ep) - item_pos + take_so
            if math.abs(sp_s - bs) < best_dist then best_dist = math.abs(sp_s - bs); best_srcpos = sp_s end
            if math.abs(ep_s - bs) < best_dist then best_dist = math.abs(ep_s - bs); best_srcpos = ep_s end
        end
    end
    if math.abs(best_srcpos - bs) < 1e-6 then return true end  -- already at note boundary
    reaper.Undo_BeginBlock()
    local _, cur_lbl, color_c = reaper.GetTakeMarker(bt, bmi)
    reaper.SetTakeMarker(bt, bmi, cur_lbl or "1.00x", best_srcpos, color_c)
    local tk_key = tostring(bt)
    if midi_sm_state[tk_key] and midi_sm_state[tk_key].markers[bmi + 1] then
        midi_sm_state[tk_key].markers[bmi + 1].last_s = best_srcpos
    end
    reaper.UpdateItemInProject(bi)
    reaper.Undo_EndBlock("Snap MIDI TM to note boundary", -1)
    return true
end

-- Silent version used during auto-snap drag: snaps TM in-place without msgboxes.
-- take = take pointer, mi = marker index (0-based), srcpos = current src position.
-- Returns the snapped srcpos (unchanged if no notes or already on boundary).
function snap_tm_to_closest_note_silent(take, mi, srcpos)
    local n_notes = select(1, reaper.MIDI_CountEvts(take))
    if n_notes == 0 then return srcpos end
    local item_pos = reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), "D_POSITION")
    local take_so  = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local best_dist = math.huge
    local best_srcpos = srcpos
    for ni = 0, n_notes - 1 do
        local r, _, _, sp, ep = reaper.MIDI_GetNote(take, ni)
        if r then
            local sp_s = reaper.MIDI_GetProjTimeFromPPQPos(take, sp) - item_pos + take_so
            local ep_s = reaper.MIDI_GetProjTimeFromPPQPos(take, ep) - item_pos + take_so
            if math.abs(sp_s - srcpos) < best_dist then best_dist = math.abs(sp_s - srcpos); best_srcpos = sp_s end
            if math.abs(ep_s - srcpos) < best_dist then best_dist = math.abs(ep_s - srcpos); best_srcpos = ep_s end
        end
    end
    return best_srcpos
end

-- Restore all notes in a take to their pre-warp positions (note_backup), reset all
-- marker last_s to orig_s, and restore each marker label to "1.00x".
function reset_midi_tm(take_key)
    local cached = midi_sm_state[take_key]
    if not cached or not cached.note_backup or #cached.note_backup == 0 then
        safe_msgbox("No MIDI SM state found. Enable MIDI SM and move a marker first.", "Nothing to Reset", 0)
        return false
    end
    local take    = cached.take
    local item    = cached.item
    local markers = cached.markers
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    -- Restore all notes from backup at original (unwarped) positions
    local nn = select(1, reaper.MIDI_CountEvts(take))
    for ni = nn - 1, 0, -1 do reaper.MIDI_DeleteNote(take, ni) end
    for _, nb in ipairs(cached.note_backup) do
        reaper.MIDI_InsertNote(take, nb.sel, nb.muted, nb.sp, nb.ep, nb.chan, nb.pitch, nb.vel, true)
    end
    reaper.MIDI_Sort(take)
    -- Reset all markers to orig_s with 1.00x label
    for mi_1, m in ipairs(markers) do
        local mi = mi_1 - 1
        local _, _, color_r = reaper.GetTakeMarker(take, mi)
        reaper.SetTakeMarker(take, mi, "1.00x", m.orig_s, color_r)
        m.last_s = m.orig_s
    end
    -- Clear any in-flight drag state
    cached.tm_drag = {}
    cached.needs_reindex = true
    reaper.UpdateItemInProject(item)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Reset MIDI TM to original state", -1)
    return true
end
-- Used by the stretch slider drag loop (caller owns the undo block).
function midi_sm_apply_stretch_inner(take_key, changed_mi, old_srcpos, new_srcpos)
    local cached = midi_sm_state[take_key]
    if not cached then return end
    local take    = cached.take
    local item    = cached.item
    local item_pos = cached.item_pos
    local take_so  = cached.take_startoffs
    local markers  = cached.markers
    local n_m      = #markers

    local prev_srcpos = (changed_mi > 0) and markers[changed_mi].last_s or 0
    local next_idx    = changed_mi + 2
    local next_srcpos = (next_idx <= n_m) and markers[next_idx].last_s or nil

    local prev_ppq = midi_sm_srcpos_to_ppq(take, item_pos, take_so, prev_srcpos)
    local old_ppq  = midi_sm_srcpos_to_ppq(take, item_pos, take_so, old_srcpos)
    local new_ppq  = midi_sm_srcpos_to_ppq(take, item_pos, take_so, new_srcpos)
    local next_ppq = next_srcpos and midi_sm_srcpos_to_ppq(take, item_pos, take_so, next_srcpos) or 1e9

    local left_span_old  = old_ppq  - prev_ppq
    local right_span_old = next_ppq - old_ppq
    if left_span_old < 0.5 and right_span_old < 0.5 then return end

    local n_notes = select(1, reaper.MIDI_CountEvts(take))
    if n_notes == 0 then return end

    reaper.PreventUIRefresh(1)
    for ni = 0, n_notes - 1 do
        local ret, sel, muted, sp, ep, chan, pitch, vel = reaper.MIDI_GetNote(take, ni)
        if ret then
            local new_sp = sp
            local new_ep = ep
            if left_span_old > 0.5 then
                local new_left = new_ppq - prev_ppq
                if sp >= prev_ppq and sp < old_ppq then
                    new_sp = prev_ppq + (sp - prev_ppq) / left_span_old * new_left
                end
                if ep > prev_ppq and ep <= old_ppq then
                    new_ep = prev_ppq + (ep - prev_ppq) / left_span_old * new_left
                end
            end
            if right_span_old > 0.5 then
                local new_right = next_ppq - new_ppq
                if sp >= old_ppq and sp < next_ppq then
                    new_sp = new_ppq + (sp - old_ppq) / right_span_old * new_right
                end
                if ep > old_ppq and ep <= next_ppq then
                    new_ep = new_ppq + (ep - old_ppq) / right_span_old * new_right
                end
            end
            new_sp = math.floor(new_sp + 0.5)
            new_ep = math.max(new_sp + 1, math.floor(new_ep + 0.5))
            if new_sp ~= sp or new_ep ~= ep then
                reaper.MIDI_SetNote(take, ni, sel, muted, new_sp, new_ep, chan, pitch, vel, false)
            end
        end
    end
    -- Update marker label with rate
    local left_orig = markers[changed_mi + 1].orig_s - ((changed_mi > 0) and markers[changed_mi].orig_s or 0)
    local left_curr = new_srcpos - prev_srcpos
    local rate_left = (left_curr > 1e-7) and (left_orig / left_curr) or 0
    local _, _, color_c = reaper.GetTakeMarker(take, changed_mi)
    reaper.SetTakeMarker(take, changed_mi, string.format("%.2fx", rate_left), new_srcpos, color_c)
    if next_idx <= n_m then
        local right_orig = markers[next_idx].orig_s - markers[changed_mi + 1].orig_s
        local right_curr = (next_srcpos or new_srcpos) - new_srcpos
        local rate_right = (right_curr > 1e-7) and (right_orig / right_curr) or 0
        local next_curr_s, _, color_n = reaper.GetTakeMarker(take, next_idx - 1)
        reaper.SetTakeMarker(take, next_idx - 1, string.format("%.2fx", rate_right), next_curr_s, color_n)
    end
    reaper.MIDI_Sort(take)
    reaper.UpdateItemInProject(item)
    reaper.PreventUIRefresh(-1)
end

-- Apply proportional stretch to a pre-cached set of notes from their ORIGINAL positions.
-- Does NOT call MIDI_Sort — caller must sort after drag ends.
-- note_cache: array of {ni, sel, muted, sp, ep, chan, pitch, vel} (original PPQ positions)
-- prev_ppq / orig_ppq / next_ppq: fixed region boundaries captured at drag start
-- new_ppq: current position of the moving marker
function midi_tm_apply_stretch_absolute(take, note_cache, prev_ppq, orig_ppq, new_ppq, next_ppq)
    if #note_cache == 0 then return end
    local left_span_orig  = orig_ppq - prev_ppq
    local right_span_orig = next_ppq - orig_ppq
    local left_span_new   = new_ppq  - prev_ppq
    local right_span_new  = next_ppq - new_ppq
    if left_span_orig < 0.5 and right_span_orig < 0.5 then return end
    reaper.PreventUIRefresh(1)
    for _, nc in ipairs(note_cache) do
        local new_sp = nc.sp
        local new_ep = nc.ep
        local sp_left  = nc.sp >= prev_ppq and nc.sp < orig_ppq
        local sp_right = nc.sp >= orig_ppq and nc.sp < next_ppq
        local ep_left  = nc.ep > prev_ppq  and nc.ep <= orig_ppq
        local ep_right = nc.ep > orig_ppq  and nc.ep <= next_ppq
        -- Scale start position
        if sp_left and left_span_orig > 0.5 then
            new_sp = left_span_new > 0.5
                and (prev_ppq + (nc.sp - prev_ppq) / left_span_orig * left_span_new)
                or  prev_ppq
        elseif sp_right and right_span_orig > 0.5 then
            new_sp = right_span_new > 0.5
                and (new_ppq + (nc.sp - orig_ppq) / right_span_orig * right_span_new)
                or  new_ppq
        end
        -- Scale end position (may be in a different region than start)
        if sp_left then
            if ep_left and left_span_orig > 0.5 then
                -- Both endpoints in left region
                new_ep = left_span_new > 0.5
                    and (prev_ppq + (nc.ep - prev_ppq) / left_span_orig * left_span_new)
                    or  prev_ppq + 1
            elseif ep_right and right_span_orig > 0.5 then
                -- Note spans marker boundary: ep scaled by right formula
                new_ep = right_span_new > 0.5
                    and (new_ppq + (nc.ep - orig_ppq) / right_span_orig * right_span_new)
                    or  new_ppq + 1
            end
            -- if ep > next_ppq: leave unchanged (note ends outside both regions)
        elseif sp_right and ep_right and right_span_orig > 0.5 then
            -- Both endpoints in right region
            new_ep = right_span_new > 0.5
                and (new_ppq + (nc.ep - orig_ppq) / right_span_orig * right_span_new)
                or  new_ppq + 1
        end
        new_sp = math.floor(new_sp + 0.5)
        new_ep = math.max(new_sp + 1, math.floor(new_ep + 0.5))
        reaper.MIDI_SetNote(take, nc.ni, nc.sel, nc.muted, new_sp, new_ep, nc.chan, nc.pitch, nc.vel, false)
    end
    reaper.PreventUIRefresh(-1)
end


-- Same range logic and settings as detect_tempo_from_item().
-- ============================================================================
function detect_transients_manual()
    local item, take = get_detect_tempo_item()
    if not item then
        safe_msgbox("No audio item found.\nSelect an item or set a razor edit.", "No Item", 0)
        return
    end
    if not take or reaper.TakeIsMIDI(take) then
        safe_msgbox("Selected item must be an audio item (not MIDI).", "Invalid Item", 0)
        return
    end
    local detect_start, detect_end = get_slider_detect_bounds(item)
    local detect_opts = {
        sensitivity_dB = sm_sensitivity_dB,
        retrig_ms      = sm_retrig_ms,
        threshold_dB   = sm_threshold_dB,
        proj_start     = detect_start,
        proj_end       = detect_end,
    }
    local transients = detect_audio_transients(item, take, detect_opts)
    if not transients or #transients == 0 then
        safe_msgbox("No transients detected in the selected range.", "No Transients", 0)
        return
    end
    local item_pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local take_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local play_rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if play_rate == 0 then play_rate = 1 end
    for _, tr in ipairs(transients) do
        if not tr.src then
            tr.src = take_offs + (tr.proj - item_pos) * play_rate
        end
    end
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    -- Remove existing SMs in the target range only (preserve those outside range)
    local sm_count_before = reaper.GetTakeNumStretchMarkers(take)
    for i = sm_count_before - 1, 0, -1 do
        local _, sm_pos = reaper.GetTakeStretchMarker(take, i)
        local sm_proj = item_pos + sm_pos
        local in_range = (not detect_start or sm_proj >= detect_start - 0.001) and
                         (not detect_end   or sm_proj <= detect_end   + 0.001)
        if in_range then
            reaper.DeleteTakeStretchMarkers(take, i)
        end
    end
    local count = 0
    for _, tr in ipairs(transients) do
        if tr.src then
            reaper.SetTakeStretchMarker(take, -1, tr.src)
            count = count + 1
        end
    end
    reaper.PreventUIRefresh(-1)
    reaper.UpdateTimeline()
    reaper.Undo_EndBlock("Detect transients → stretch markers (" .. count .. ")", -1)
    detect_transients_confirmed_until = os.clock() + 1.5
end

-- Detect tempo from selected audio item and create tempo markers
-- Uses tempo_map_freq_index for marker spacing and tempo_detect_method_index for algorithm
-- ============================================================================
function detect_tempo_from_item()
    -- Get item based on detect_tempo_item_index setting
    local item, take = get_detect_tempo_item()
    if not item then
        safe_msgbox("No audio item found.\nSelect an item or choose one in Detect Item setting.", "No Item", 0)
        return
    end
    if not take or reaper.TakeIsMIDI(take) then
        safe_msgbox("Selected item must be an audio item (not MIDI).", "Invalid Item", 0)
        return
    end

    -- Check frequency setting
    local eff_ts_num, eff_ts_denom, eff_beats_qn = get_detect_tempo_timesig()
    if not eff_ts_num then
        safe_msgbox("Tempo map frequency is set to Off.\nPlease select a frequency first.", "Frequency Off", 0)
        return
    end

    -- Determine detection range: razor edit > time selection > item bounds
    local detect_start, detect_end = get_slider_detect_bounds(item)

    -- Build opts for transient detection (use slider values)
    local detect_opts = {
        sensitivity_dB = sm_sensitivity_dB,
        retrig_ms = sm_retrig_ms,
        threshold_dB = sm_threshold_dB,
        proj_start = detect_start,
        proj_end = detect_end,
    }

    -- Detect transients or use existing stretch markers
    local transients
    local use_existing = detect_tempo_use_existing_markers

    if use_existing then
        -- Build transient list from existing stretch markers on the item
        local item_pos_e = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local sm_count_e = reaper.GetTakeNumStretchMarkers(take)
        if sm_count_e < 2 then
            safe_msgbox("Not enough stretch markers on the item.\nPlace at least 2 stretch markers first.", "No Markers", 0)
            return
        end
        transients = {}
        for si = 0, sm_count_e - 1 do
            local _, pos_e = reaper.GetTakeStretchMarker(take, si)
            local proj_t = item_pos_e + pos_e
            if (not detect_start or proj_t >= detect_start) and
               (not detect_end or proj_t <= detect_end) then
                transients[#transients+1] = {proj = proj_t, src = pos_e, strength = 1}
            end
        end
        if #transients < 2 then
            safe_msgbox("Not enough stretch markers in the selected range.", "Insufficient Markers", 0)
            return
        end
    elseif tempo_detect_method_index == 2 then
        -- Python detection: run external script
        local PCM_src = reaper.GetMediaItemTake_Source(take)
        local audio_path = reaper.GetMediaSourceFileName(PCM_src)
        if not audio_path or audio_path == "" then
            safe_msgbox("Could not get audio file path.", "Error", 0)
            return
        end
        local py_script = script_dir .. "konst_detect_onsets.py"
        local pf = io.open(py_script, "r")
        if not pf then
            safe_msgbox("Python onset detection script not found:\n" .. py_script .. "\n\nFalling back to Lua detection.", "Script Not Found", 0)
            transients = detect_audio_transients(item, take, detect_opts)
        else
            pf:close()
            local py_exe = reaper.GetExtState("konst_ImportMusicXML", "python_exe")
            if py_exe == "" then py_exe = "python" end
            local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or reaper.GetResourcePath()
            local output_path = temp_dir .. "\\konst_onsets_" .. tostring(os.time()) .. ".txt"
            local cmd = string.format('"%s" "%s" "%s" "%s"', py_exe, py_script, audio_path, output_path)
            reaper.ExecProcess(cmd, 60000)
            local of = io.open(output_path, "r")
            if of then
                local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                transients = {}
                for line in of:lines() do
                    local t = tonumber(line)
                    if t then transients[#transients+1] = {proj = item_pos + t, src = t} end
                end
                of:close()
                os.remove(output_path)
                -- Filter by detection range if set
                if detect_start or detect_end then
                    local filtered = {}
                    for _, tr in ipairs(transients) do
                        if (not detect_start or tr.proj >= detect_start) and
                           (not detect_end or tr.proj <= detect_end) then
                            filtered[#filtered+1] = tr
                        end
                    end
                    transients = filtered
                end
            else
                safe_msgbox("Python onset detection produced no output.\nFalling back to Lua detection.", "Python Error", 0)
                transients = detect_audio_transients(item, take, detect_opts)
            end
        end
    else
        -- Lua detection (same function used during MusicXML import)
        transients = detect_audio_transients(item, take, detect_opts)
    end

    if not transients or #transients == 0 then
        safe_msgbox("No transients detected in the selected audio item.", "No Transients", 0)
        return
    end

    -- Ensure all transients have .proj
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local take_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local play_rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if play_rate == 0 then play_rate = 1 end
    for _, tr in ipairs(transients) do
        if not tr.proj then
            tr.proj = item_pos + (tr.src - take_offs) / play_rate
        end
    end

    -- ========================================================================
    -- Estimate BPM using folded inter-onset intervals.
    -- For each consecutive transient gap, compute the implied BPM, then fold
    -- it into the 60-200 range by halving/doubling. This is octave-robust:
    -- hi-hat 16ths at 480 BPM fold to 120, kick gaps at 60 BPM stay at 60.
    -- The median of all folded BPMs is the estimate.
    -- ========================================================================
    local gap_bpms = {}
    for i = 1, #transients - 1 do
        local g = transients[i+1].proj - transients[i].proj
        if g > 0.04 then  -- ignore gaps < 40ms (noise / retriggering)
            local bpm = 60 / g
            while bpm > 200 do bpm = bpm / 2 end
            while bpm < 60 do bpm = bpm * 2 end
            gap_bpms[#gap_bpms+1] = bpm
        end
    end
    if #gap_bpms == 0 then
        safe_msgbox("Could not estimate tempo from transients.", "Detection Failed", 0)
        return
    end
    table.sort(gap_bpms)
    local est_bpm = gap_bpms[math.ceil(#gap_bpms / 2)]
    est_bpm = math.floor(est_bpm * 10 + 0.5) / 10  -- round to 1 decimal

    -- ========================================================================
    -- Preview: show popup menu with detected BPM, half, double, custom entry
    -- ========================================================================
    local half_bpm = math.floor(est_bpm / 2 * 10 + 0.5) / 10
    local double_bpm = math.floor(est_bpm * 2 * 10 + 0.5) / 10
    local menu_str = string.format(
        "Write at %.1f BPM|Half (%.1f BPM)|Double (%.1f BPM)|Enter custom BPM...",
        est_bpm, half_bpm, double_bpm)
    gfx.x = gfx.mouse_x
    gfx.y = gfx.mouse_y
    local choice = gfx.showmenu(menu_str)

    local final_bpm = nil
    if choice == 1 then
        final_bpm = est_bpm
    elseif choice == 2 then
        final_bpm = half_bpm
    elseif choice == 3 then
        final_bpm = double_bpm
    elseif choice == 4 then
        local retval, input = reaper.GetUserInputs(
            "Custom BPM", 1, "BPM (10-999):,extrawidth=80",
            string.format("%.1f", est_bpm))
        if retval then
            local v = tonumber(input)
            if v and v >= 10 and v <= 999 then
                final_bpm = v
            else
                safe_msgbox("Invalid BPM value.", "Error", 0)
                return
            end
        end
    end
    if not final_bpm then return end  -- cancelled

    -- ========================================================================
    -- Grid-fit tempo detection (same approach as konst_Detect tempo.lua).
    -- Uses stretch markers as transient positions. If the first stretch marker
    -- exists, it defines bar 1 position; otherwise uses item start.
    -- For each bar, try tempos in a range around the baseline and pick the one
    -- whose subdivision grid best aligns with the transient/stretch markers.
    -- ========================================================================
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    -- Step 1: Insert stretch markers on transients if enabled, then collect
    -- all stretch marker positions as the timing reference.
    local stretch_markers_created = 0
    if detect_stretch_markers_enabled and not use_existing then
        for _, tr in ipairs(transients) do
            if tr.src then
                reaper.SetTakeStretchMarker(take, -1, tr.src)
                stretch_markers_created = stretch_markers_created + 1
            end
        end
        reaper.UpdateTimeline()
    end

    -- Collect stretch marker project-time positions (these are our "clicks")
    -- Filter to the detect range so old markers outside the range are excluded.
    local marker_times = {}
    local sm_count = reaper.GetTakeNumStretchMarkers(take)
    for si = 0, sm_count - 1 do
        local _, pos = reaper.GetTakeStretchMarker(take, si)
        local proj_t = item_pos + pos
        if proj_t >= item_pos and proj_t <= item_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH") then
            if (not detect_start or proj_t >= detect_start - 0.001) and
               (not detect_end   or proj_t <= detect_end   + 0.001) then
                marker_times[#marker_times+1] = proj_t
            end
        end
    end
    table.sort(marker_times)

    -- If no stretch markers in range, fall back to transient .proj times
    if #marker_times < 2 then
        marker_times = {}
        for _, tr in ipairs(transients) do
            marker_times[#marker_times+1] = tr.proj
        end
        table.sort(marker_times)
    end

    if #marker_times < 2 then
        reaper.PreventUIRefresh(-1)
        reaper.Undo_EndBlock("Detect Tempo (aborted)", -1)
        safe_msgbox("Not enough markers/transients to build tempo map.", "Insufficient Data", 0)
        return
    end

    -- Step 2: Determine bar start position.
    -- When a range is set, start the tempo map at detect_start so bars don't
    -- begin before the selection. Otherwise, start at the first marker.
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local end_proj = detect_end or (item_pos + item_len)
    local first_beat = detect_start or marker_times[1]
    local beats_per_bar = eff_beats_qn  -- from get_detect_tempo_timesig()
    local subdivisions_per_beat = 2  -- score 8th-note subdivisions

    -- Step 3: Build tempo map bar-by-bar using grid-fit scoring.
    -- For each bar, sweep tempos in [baseline*0.7 .. baseline*1.3] at 0.5 BPM
    -- increments. Score = how well stretch markers align to the subdivision grid.
    -- The tempo with the highest score wins.
    local min_tempo = math.max(20, final_bpm * 0.7)
    local max_tempo = math.min(300, final_bpm * 1.3)
    local step = 0.5
    local tolerance_factor = 0.25
    local markers_created = 0
    local bar_start = first_beat
    local bar_tempo = final_bpm

    while bar_start < end_proj do
        -- Score each candidate tempo for this bar
        local best_tempo = bar_tempo
        local best_score = -math.huge

        for tempo = min_tempo, max_tempo, step do
            local beat_duration = 60 / tempo
            local grid_step = beat_duration / subdivisions_per_beat
            local bar_duration = beat_duration * beats_per_bar
            local bar_end = bar_start + bar_duration
            local margin = grid_step * tolerance_factor

            local score = 0
            local markers_in_bar = 0
            for _, mt in ipairs(marker_times) do
                if mt > bar_start + 0.0001 and mt <= bar_end then
                    markers_in_bar = markers_in_bar + 1
                    local offset = mt - bar_start
                    local grid_index = math.floor(offset / grid_step + 0.5)
                    local grid_pos = bar_start + grid_index * grid_step
                    local dist = math.abs(mt - grid_pos)
                    if dist <= margin then
                        score = score + (1 - dist / margin)
                    else
                        score = score - 0.05
                    end
                end
            end

            -- Lookahead bonus: does bar_end align with a marker?
            local next_window = math.max(0.05, (60 / tempo) * 0.4)
            local nearest_dist = next_window * 2
            for _, mt in ipairs(marker_times) do
                if mt > bar_start + 0.0001 then
                    local d = math.abs(mt - bar_end)
                    if d < nearest_dist then nearest_dist = d end
                end
            end
            if nearest_dist <= next_window then
                score = score + (1 - nearest_dist / next_window) * 0.8
            end

            -- Closeness-to-baseline bonus
            local closeness = 1 - math.abs(tempo - final_bpm) / math.max(1, max_tempo - min_tempo)
            if closeness < 0 then closeness = 0 end
            score = score + 0.1 * closeness

            if markers_in_bar > 0 then score = score / markers_in_bar end

            if score > best_score then
                best_score = score
                best_tempo = tempo
            end
        end

        -- Use baseline if no markers scored positively
        if best_score <= 0 then best_tempo = final_bpm end

        -- Write tempo marker at bar_start (always include time signature)
        reaper.SetTempoTimeSigMarker(0, -1, bar_start, -1, -1,
            best_tempo, eff_ts_num, eff_ts_denom, false)
        markers_created = markers_created + 1

        -- Advance to next bar
        local bar_duration = (60 / best_tempo) * beats_per_bar
        bar_tempo = best_tempo
        bar_start = bar_start + bar_duration
    end

    -- Step 4: Refinement pass — adjust each tempo marker's BPM so the next
    -- bar start aligns exactly with the nearest stretch marker.
    reaper.UpdateTimeline()
    local n_tempo = reaper.CountTempoTimeSigMarkers(0)
    -- Find our first marker index
    local first_idx = nil
    for mi = 0, n_tempo - 1 do
        local rv, t = reaper.GetTempoTimeSigMarker(0, mi)
        if rv and math.abs(t - first_beat) < 0.002 then
            first_idx = mi
            break
        end
    end
    if first_idx and markers_created > 1 then
        for mi = first_idx, first_idx + markers_created - 2 do
            if mi + 1 >= n_tempo then break end
            local rv_c, t_curr, _, _, bpm_curr, tsn_c, tsd_c, lin_c =
                reaper.GetTempoTimeSigMarker(0, mi)
            local rv_n, t_next = reaper.GetTempoTimeSigMarker(0, mi + 1)
            if not (rv_c and rv_n) then break end

            local bar_dur_curr = (60 / bpm_curr) * beats_per_bar
            local search_radius = bar_dur_curr * 0.5

            -- Find nearest stretch marker to t_next
            local best_s = nil
            local best_dist = math.huge
            for _, mt in ipairs(marker_times) do
                if mt > t_curr + 0.001 then
                    local d = math.abs(mt - t_next)
                    if d < best_dist and d < search_radius then
                        best_dist = d
                        best_s = mt
                    end
                end
            end
            if best_s then
                local gap = best_s - t_curr
                if gap > 0.005 then
                    local new_bpm = beats_per_bar * 60 / gap
                    if new_bpm >= min_tempo and new_bpm <= max_tempo then
                        reaper.SetTempoTimeSigMarker(0, mi, t_curr, -1, -1, new_bpm,
                            tsn_c > 0 and tsn_c or 0, tsd_c > 0 and tsd_c or 0, lin_c)
                        -- Move next marker to align
                        local rv_n2, _, mq_n, mqn_n, bpm_n, tsn_n, tsd_n, lin_n =
                            reaper.GetTempoTimeSigMarker(0, mi + 1)
                        if rv_n2 then
                            reaper.SetTempoTimeSigMarker(0, mi + 1, best_s, -1, -1, bpm_n,
                                tsn_n, tsd_n, lin_n)
                        end
                        reaper.UpdateTimeline()
                    end
                end
            end
        end
    end

    reaper.UpdateTimeline()
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Detect Tempo (" .. markers_created .. " markers, baseline "
        .. string.format("%.1f", final_bpm) .. " BPM)", -1)

    local msg = string.format("%d tempo markers (baseline %.1f BPM).",
        markers_created, final_bpm)
    if stretch_markers_created > 0 then
        msg = msg .. "\n" .. stretch_markers_created .. " stretch markers inserted."
    end
    safe_msgbox(msg, "Tempo Detection Complete", 0)
end

-- ============================================================================
-- Import function with GUI-provided options
-- ============================================================================
function ImportMusicXMLWithOptions(filepath, options)
  -- Begin undo block for all import operations
  reaper.Undo_BeginBlock()
  
  -- Validate filepath
  if not filepath or filepath == "" then
    safe_msgbox("No file path provided.", "Error", 0)
    reaper.Undo_EndBlock("Import MusicXML", -1)
    return
  end

  -- 1. Read the file content
  local f = io.open(filepath, "r")
  if not f then
    safe_msgbox("Could not open file.", "Error", 0)
    reaper.Undo_EndBlock("Import MusicXML", -1)
    return
  end
  local content = f:read("*all")
  f:close()

  -- 2. Parse XML (preprocess Guitar Pro PIs so letring etc. are accessible)
  content = preprocess_gp_pis(content)
  local root = parseXML(content)
  if not root then
    safe_msgbox("Failed to parse XML.", "Error", 0)
    reaper.Undo_EndBlock("Import MusicXML", -1)
    return
  end

  -- 3. Use options from GUI (or defaults if not provided)
  local import_markers = (options and options.import_markers) or false
  local import_regions = (options and options.import_regions) or false
  local import_key_sigs = (options and options.import_key_sigs) or false
  local insert_on_new_tracks = (options and options.insert_on_new_tracks) or false
  local insert_on_existing_tracks = (options and options.insert_on_existing_tracks) or false
  local insert_on_tracks_by_name = (options and options.insert_on_tracks_by_name) or true
  local align_to_audio = (options and options.align_to_audio) or false
  local align_notes_to_transients = (options and options.align_notes_to_transients) or false
  local tempo_per_beat = false  -- legacy, replaced by tempo_map_freq
  local tempo_map_freq = (options and options.tempo_map_freq) or 1  -- index into tempo_map_freq_options
  local tempo_map_freq_enabled = (tempo_map_freq_options[tempo_map_freq] ~= "Off")  -- true if any tempo map mode
  local selected_tracks = options and options.selected_tracks  -- nil means import all

  -- Build a lookup set of selected track names for quick filtering
  local selected_tracks_set = nil
  if selected_tracks then
    selected_tracks_set = {}
    for _, name in ipairs(selected_tracks) do
      selected_tracks_set[name] = true
    end
  end

  -- 5. Get project's ticks per quarter note (PPQ)
  local ppq = reaper.SNM_GetIntConfigVar("miditicksperbeat", 960)

  -- 6. Read the part-list to map part IDs to track names AND build drum instrument mapping
  local part_names = {}
  local parts_order = {}  -- Preserve the order of parts from MusicXML
  local drum_instrument_map = {}  -- part_id -> { [instrument_id] = { midi_note, channel, name } }

  local part_list = findChild(root, "part-list")
  if part_list then
    for _, score_part in ipairs(findChildren(part_list, "score-part")) do
      local id = getAttribute(score_part, "id")
      local name = getChildText(score_part, "part-name")
      if id and name then
        part_names[id] = name
        table.insert(parts_order, id)  -- Track the order
      end

      -- Build drum instrument map for this part
      local instr_map = {}
      local score_instruments = findChildren(score_part, "score-instrument")
      for _, si in ipairs(score_instruments) do
        local instr_id = getAttribute(si, "id")
        local instr_name = getChildText(si, "instrument-name")
        -- find matching midi-instrument (inside the same score-part)
        local midi_instr = nil
        for _, mi in ipairs(findChildren(score_part, "midi-instrument")) do
          if getAttribute(mi, "id") == instr_id then
            midi_instr = mi
            break
          end
        end
        if midi_instr then
          local midi_channel = tonumber(getChildText(midi_instr, "midi-channel")) or 10
          local midi_unpitched = tonumber(getChildText(midi_instr, "midi-unpitched"))
          if midi_unpitched then
            instr_map[instr_id] = {
              midi_note = midi_unpitched,
              channel = midi_channel - 1,  -- 0‑based for REAPER (will be overridden by drum_channel_map)
              name = instr_name
            }
          end
        end
      end
      drum_instrument_map[id] = instr_map
    end
  end

  -- 6b. Extract MIDI bank/program per part (first midi-instrument with bank/program)
  local part_midi_program = {}  -- part_id -> { channel, bank, program }
  if (options.import_midi_banks or gm_name_tracks_enabled) and part_list then
    for _, score_part in ipairs(findChildren(part_list, "score-part")) do
      local id = getAttribute(score_part, "id")
      for _, mi in ipairs(findChildren(score_part, "midi-instrument")) do
        local midi_channel = tonumber(getChildText(mi, "midi-channel"))
        local midi_bank = tonumber(getChildText(mi, "midi-bank"))
        local midi_program = tonumber(getChildText(mi, "midi-program"))
        if midi_program then
          part_midi_program[id] = {
            channel = (midi_channel or 1) - 1,  -- 0-based
            bank = midi_bank or 1,
            program = midi_program - 1  -- MusicXML is 1-based, MIDI is 0-based
          }
          break  -- take first midi-instrument with program info
        elseif midi_channel == 10 and not part_midi_program[id] then
          -- Drum parts often have channel 10 but no program
          part_midi_program[id] = {
            channel = 9,  -- 0-based
            bank = midi_bank or 1,
            program = -1
          }
        end
      end
    end
  end

  -- 7. Data structures for note import
  local all_parts_data = {}          -- part_id -> { staff_notes, staff_texts, total_seconds }
  local markers = {}                  -- time (sec) -> { tempo, beats, beat_type }
  local sections = {}                 -- { { name, start_time, end_time }, ... }
  local part_key_sig = {}             -- part_id -> { fifths, mode } from first <key> element
  local tempo_map = {{ticks = 0, tempo = 120}}  -- beat position -> tempo, for PPQ->seconds conversion
  local measure_boundaries = {}       -- for audio alignment: {measure, ticks, score_time, beats, beat_type}
  local current_beats = 4             -- current time signature numerator
  local current_beat_type = 4         -- current time signature denominator

  -- 8. Process each <part> element
  local parts = findChildren(root, "part")
  local total_parts = #parts
  for part_idx, part_node in ipairs(parts) do
    if import_progress.active then
      update_import_progress(0.05 + 0.45 * ((part_idx - 1) / total_parts),
        string.format("Parsing part %d/%d...", part_idx, total_parts))
    end
    local part_id = getAttribute(part_node, "id")
    local base_track_name = part_names[part_id] or ("Part " .. part_id)
    local is_bass = isBassTrack(base_track_name)
    local drum_map = drum_instrument_map[part_id] or {}

    -- Get all measures of this part
    local original_measures = findChildren(part_node, "measure")
    -- Expand repeats
    local expanded_measures = expand_repeats(original_measures)
    
    -- Only parse sections from the first part to avoid duplicates (and if import_regions is enabled)
    local parse_sections = (part_idx == 1 and import_regions)

    -- Per‑staff data for this part
    local staff_notes = {}
    local staff_texts = {}
    local staff_tunings = {}      -- staff_num -> tuning array (MIDI notes)

    -- Per‑staff chord tracking
    local staff_last_start = {}
    local staff_chord_count = {}

    -- Per‑staff pending slides (for start/stop pairing)
    local staff_pending_slides = {}

    -- Per‑staff span state for duration line feature
    -- [staff_num][art_name] = { last_idx, last_pos, count }
    local staff_span_state = {}

    -- Per‑staff grace note chord tracking (separate from regular chord
    -- tracking so that grace notes never interfere with surrounding chords).
    local staff_grace_start = {}       -- last start position for grace chord
    local staff_grace_chord_count = {} -- chord member counter for grace chords
    local staff_grace_running_offset = {} -- cumulative on-beat grace time per staff (applied to note positions, never touches cur_pos_ticks)

    -- Note type name → duration in ticks (relative to ppq)
    local note_type_ticks = {
      whole   = 4 * ppq,
      half    = 2 * ppq,
      quarter = ppq,
      eighth  = ppq / 2,
      ["16th"]  = ppq / 4,
      ["32nd"]  = ppq / 8,
      ["64th"]  = ppq / 16,
      ["128th"] = ppq / 32,
    }

    -- Time tracking for this part
    local cur_pos_ticks = 0
    local cur_seconds = 0
    local current_tempo = 120               -- default BPM
    local divisions = nil
    
    -- Flag to track if we've parsed tuning yet (only do it once, from first measure)
    local tuning_parsed = false

    -- Helper to convert ticks to seconds and advance time
    local function advance(ticks)
      if ticks and ticks > 0 then
        local sec = (ticks / ppq) * (60 / current_tempo)
        cur_seconds = cur_seconds + sec
      end
    end

    -- 9. Parse all measures of the expanded list
    for measure_idx, measure_node in ipairs(expanded_measures) do
      -- Look for <attributes> (may contain divisions and time signature)
      local attrs = findChild(measure_node, "attributes")
      if attrs then
        local d = getChildValue(attrs, "divisions")
        if d then divisions = d end

        -- Parse tuning from first measure only
        if not tuning_parsed then
          tuning_parsed = true
          -- Try to parse tuning from staff-details in this measure
          local staff_details_list = findChildren(attrs, "staff-details")
          for _, staff_details in ipairs(staff_details_list) do
            local staff_num = tonumber(getAttribute(staff_details, "number")) or 1
            -- Check if this is a drum part
            local is_drum = (next(drum_map) ~= nil)
            local tuning = parseTuning(staff_details, is_drum)
            if tuning then
              staff_tunings[staff_num] = tuning
            end
          end
        end

        -- Time signature change?
        local time_node = findChild(attrs, "time")
        if time_node and part_idx == 1 then
          local beats = tonumber(getChildText(time_node, "beats"))
          local beat_type = tonumber(getChildText(time_node, "beat-type"))
          if beats and beat_type then
            current_beats = beats
            current_beat_type = beat_type
            if import_markers then
              if not markers[cur_seconds] then markers[cur_seconds] = {} end
              markers[cur_seconds].beats = beats
              markers[cur_seconds].beat_type = beat_type
            end
          end
        end

        -- Key signature (first occurrence per part only)
        if import_key_sigs and not part_key_sig[part_id] then
          local key_node = findChild(attrs, "key")
          if key_node then
            local fifths = tonumber(getChildText(key_node, "fifths"))
            local mode_text = getChildText(key_node, "mode"):match("^%s*(.-)%s*$") or ""
            local mode = (mode_text ~= "" and mode_text) or "major"
            if fifths then
              part_key_sig[part_id] = { fifths = fifths, mode = mode }
            end
          end
        end
      end

      -- Collect measure boundary for audio alignment (first part only, after attributes parsed)
      if part_idx == 1 then
        table.insert(measure_boundaries, {
          measure = measure_idx,
          ticks = cur_pos_ticks,
          score_time = cur_seconds,
          beats = current_beats,
          beat_type = current_beat_type
        })
      end

      -- Process all elements in measure
      local measure_children = measure_node.children or {}
      for _, elem in ipairs(measure_children) do
        if elem.name == "note" then
          local rest = findChild(elem, "rest")
          local grace_node = findChild(elem, "grace")
          local dur_node = findChild(elem, "duration")

          -- ==================== GRACE NOTE ====================
          if grace_node and not rest and divisions then
            local chord = findChild(elem, "chord")
            local staff_elem = findChild(elem, "staff")
            local staff_num = 1
            if staff_elem then
              staff_num = tonumber(getNodeText(staff_elem)) or 1
            end

            -- Compute grace note duration from <type>
            local type_node = findChild(elem, "type")
            local type_text = type_node and getNodeText(type_node) or "32nd"
            local grace_ticks = note_type_ticks[type_text] or (ppq / 8)
            -- Account for dots
            local dot_count = #findChildren(elem, "dot")
            if dot_count > 0 then
              local add = grace_ticks
              for _ = 1, dot_count do
                add = add / 2
                grace_ticks = grace_ticks + add
              end
            end

            local slash = getAttribute(grace_node, "slash")
            local on_beat = (slash ~= "yes")  -- default / slash="no" → on beat

            -- Process pitch
            local pitch_node = findChild(elem, "pitch")
            if pitch_node then
              local step = getChildText(pitch_node, "step")
              local alter = getChildValue(pitch_node, "alter") or 0
              local octave = getChildValue(pitch_node, "octave") or 4
              local offset = ({ C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 })[step]
              if offset then
                local pitch = (octave + 1) * 12 + offset + alter

                -- Extract string and fret (direct children, then GP PI fallback)
                local string_num, fret_num
                local notations = findChild(elem, "notations")
                if notations then
                  local technical = findChild(notations, "technical")
                  if technical then
                    local str_node = findChild(technical, "string")
                    local fret_node = findChild(technical, "fret")
                    if str_node and fret_node then
                      string_num = tonumber(getNodeText(str_node))
                      fret_num = tonumber(getNodeText(fret_node))
                    end
                    -- Fallback: extract from GP processing instruction (<_gp_><root>)
                    if not (string_num and fret_num) then
                      for _, gp_child in ipairs(technical.children or {}) do
                        if gp_child.name == "_gp_" then
                          local gp_root = findChild(gp_child, "root")
                          if gp_root then
                            local gp_str = findChild(gp_root, "string")
                            local gp_fret = findChild(gp_root, "fret")
                            if gp_str and gp_fret then
                              string_num = tonumber(getNodeText(gp_str))
                              fret_num = tonumber(getNodeText(gp_fret))
                            end
                          end
                          break
                        end
                      end
                    end
                  end
                end

                if string_num and fret_num then
                  local channel = 7 - string_num
                  if channel < 1 or channel > 16 then channel = 1 end
                  local note_channel = channel - 1
                  if is_bass then note_channel = note_channel - 1 end
                  local velocity = 100

                  -- Grace note positioning uses its OWN chord tracking
                  -- (staff_grace_start / staff_grace_chord_count) so regular
                  -- chord tracking (staff_last_start / staff_chord_count) is
                  -- never touched.
                  local grace_off = staff_grace_running_offset[staff_num] or 0
                  local start_ticks
                  if on_beat then
                    -- On-beat: starts at the current beat position (with running offset)
                    if chord then
                      local base = staff_grace_start[staff_num] or (cur_pos_ticks + grace_off)
                      local cnt = (staff_grace_chord_count[staff_num] or 1)
                      start_ticks = base + (cnt - 1) * chord_offset_ticks
                      staff_grace_chord_count[staff_num] = cnt + 1
                    else
                      start_ticks = cur_pos_ticks + grace_off
                      staff_grace_start[staff_num] = start_ticks
                      staff_grace_chord_count[staff_num] = 1
                      -- Accumulate running offset so all subsequent notes shift by this grace's duration
                      staff_grace_running_offset[staff_num] = grace_off + grace_ticks
                    end
                  else
                    -- Before-beat: placed just before current position (with running offset)
                    if chord then
                      local base = staff_grace_start[staff_num] or (cur_pos_ticks + grace_off - grace_ticks)
                      local cnt = (staff_grace_chord_count[staff_num] or 1)
                      start_ticks = base + (cnt - 1) * chord_offset_ticks
                      staff_grace_chord_count[staff_num] = cnt + 1
                    else
                      start_ticks = cur_pos_ticks + grace_off - grace_ticks
                      if start_ticks < 0 then start_ticks = 0 end
                      staff_grace_start[staff_num] = start_ticks
                      staff_grace_chord_count[staff_num] = 1
                    end
                  end

                  -- Insert MIDI note for the grace note
                  if not staff_notes[staff_num] then staff_notes[staff_num] = {} end

                  -- Trim any previous note on same channel+pitch that
                  -- overlaps (e.g. chord-offset causes 1-tick overlap).
                  for ni = #staff_notes[staff_num], 1, -1 do
                    local prev = staff_notes[staff_num][ni]
                    if prev.pitch == pitch and prev.channel == note_channel
                        and prev.endpos > start_ticks and prev.pos < start_ticks then
                      prev.endpos = start_ticks
                      break
                    end
                  end

                  table.insert(staff_notes[staff_num], {
                    pos     = start_ticks,
                    endpos  = start_ticks + grace_ticks,
                    channel = note_channel,
                    pitch   = pitch,
                    vel     = velocity
                  })

                  -- Articulation events (text events for the grace note)
                  local articulation_events = getArticulationEvents(elem, fret_num)

                  -- Write "gr" text event if grace-note articulation is enabled
                  local grace_entry = articulation_map["grace-note"]
                  if grace_entry and articulation_enabled["grace-note"] ~= false then
                    if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                    table.insert(staff_texts[staff_num], {
                      pos  = start_ticks,
                      text = "_" .. (grace_entry.symbol or "gr"),
                      type = grace_entry.type or 1
                    })
                  end

                  -- Fret-replacing text
                  local main_ev = nil
                  local suffix_chars = ""
                  for _, ev in ipairs(articulation_events) do
                    if ev.replaces_fret then
                      if ev.is_suffix then
                        suffix_chars = suffix_chars .. (ev.symbol or "")
                      elseif not main_ev then
                        main_ev = ev
                      end
                    end
                  end
                  local fret_replaced = false
                  if main_ev ~= nil or suffix_chars ~= "" then
                    fret_replaced = true
                    if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                    local base_sym, ev_type, no_pfx
                    if main_ev then
                      base_sym = main_ev.symbol; ev_type = main_ev.type; no_pfx = main_ev.no_prefix
                    else
                      base_sym = tostring(fret_num); ev_type = 1; no_pfx = false
                    end
                    local text = base_sym .. suffix_chars
                    if not no_pfx then text = "_" .. text end
                    table.insert(staff_texts[staff_num], { pos = start_ticks, text = text, type = ev_type })
                  end
                  if not fret_replaced and fret_number_enabled then
                    if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                    table.insert(staff_texts[staff_num], { pos = start_ticks, text = "_" .. fret_num, type = fret_number_type })
                  end

                  -- Non-replacing articulations
                  for _, ev in ipairs(articulation_events) do
                    if not ev.replaces_fret then
                      if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                      local text = ev.symbol
                      if not ev.no_prefix then text = "_" .. text end
                      table.insert(staff_texts[staff_num], { pos = start_ticks, text = text, type = ev.type })
                    end
                  end

                  -- Slide handling for grace notes
                  if notations then
                    for _, child in ipairs(notations.children or {}) do
                      if slide_names[child.name] then
                        local info = getSlideInfo(child, fret_num)
                        if info then
                          local slide_type = child.attrs and child.attrs.type
                          if slide_type == "start" then
                            if not staff_pending_slides[staff_num] then staff_pending_slides[staff_num] = {} end
                            staff_pending_slides[staff_num][string_num] = {
                              start_pos = start_ticks, symbol = info.symbol,
                              no_prefix = info.no_prefix, type = info.type
                            }
                          elseif slide_type == "stop" then
                            if staff_pending_slides[staff_num] and staff_pending_slides[staff_num][string_num] then
                              local pending = staff_pending_slides[staff_num][string_num]
                              if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                              local text = info.symbol
                              if not info.no_prefix then text = "_" .. text end
                              table.insert(staff_texts[staff_num], { pos = start_ticks, text = text, type = pending.type })
                              staff_pending_slides[staff_num][string_num] = nil
                            end
                          end
                        end
                      end
                    end
                  end
                end  -- string_num and fret_num
              end  -- offset
            end  -- pitch_node
            -- Grace notes have no <duration>, so do NOT advance time

          elseif dur_node and divisions then
            local duration = tonumber(getNodeText(dur_node))
            if duration then
              local tick_duration = (duration / divisions) * ppq
              local chord = findChild(elem, "chord")

              -- Staff number (default 1)
              local staff_elem = findChild(elem, "staff")
              local staff_num = 1
              if staff_elem then
                staff_num = tonumber(getNodeText(staff_elem)) or 1
              end

              if rest then
                -- Rest: advance time, reset chord tracking
                staff_last_start[staff_num] = nil
                staff_chord_count[staff_num] = nil
                advance(tick_duration)
                cur_pos_ticks = cur_pos_ticks + tick_duration
              else
                -- Determine if this is a drum note by checking the instrument ID
                local instrument_node = findChild(elem, "instrument")
                local instrument_id = instrument_node and getAttribute(instrument_node, "id")
                local drum_info = instrument_id and drum_map[instrument_id]

                if drum_info then
                  -- ==================== DRUM NOTE ====================
                  -- Use mapped MIDI pitch from drum_pitch_map, fallback to XML midi_note
                  local midi_note = getDrumPitch(drum_info.name, drum_info.midi_note)
                  -- Override channel using drum_channel_map if available
                  local channel = getDrumChannel(drum_info.name, drum_info.channel)
                  local drum_name = drum_info.name
                  local drum_text = "_" .. drumNameToText(drum_name)

                  -- Determine start position with possible chord offset
                  -- Apply per-staff grace running offset for correct beat alignment
                  local drum_grace_off = staff_grace_running_offset[staff_num] or 0
                  local start_ticks
                  if chord then
                    local base_start = staff_last_start[staff_num]
                    if not base_start then
                      base_start = cur_pos_ticks + drum_grace_off
                      staff_last_start[staff_num] = base_start
                      staff_chord_count[staff_num] = 1
                    end
                    local count = staff_chord_count[staff_num] or 0
                    count = count + 1
                    staff_chord_count[staff_num] = count
                    start_ticks = base_start + (count - 1) * chord_offset_ticks
                  else
                    staff_last_start[staff_num] = cur_pos_ticks + drum_grace_off
                    staff_chord_count[staff_num] = 1
                    start_ticks = cur_pos_ticks + drum_grace_off
                  end

                  -- Store note (merge with previous if tie stop)
                  if not staff_notes[staff_num] then staff_notes[staff_num] = {} end
                  local is_tie_stop = false
                  local tie_nodes = findChildren(elem, "tie")
                  for _, tie_node in ipairs(tie_nodes) do
                    if getAttribute(tie_node, "type") == "stop" then
                      is_tie_stop = true
                      break
                    end
                  end
                  if is_tie_stop then
                    -- Extend the previous note with same pitch and channel
                    local merged = false
                    for ni = #staff_notes[staff_num], 1, -1 do
                      local prev = staff_notes[staff_num][ni]
                      if prev.pitch == midi_note and prev.channel == channel then
                        prev.endpos = start_ticks + tick_duration
                        merged = true
                        break
                      end
                    end
                    if not merged then
                      table.insert(staff_notes[staff_num], {
                        pos    = start_ticks,
                        endpos = start_ticks + tick_duration,
                        channel = channel,
                        pitch  = midi_note,
                        vel    = 100
                      })
                    end
                  else
                    table.insert(staff_notes[staff_num], {
                      pos    = start_ticks,
                      endpos = start_ticks + tick_duration,
                      channel = channel,
                      pitch  = midi_note,
                      vel    = 100
                    })
                  end

                  -- Process articulations (pass a dummy fret 0)
                  local articulation_events = getArticulationEvents(elem, 0)

                  -- Check if any articulation replaces the base drum text
                  local base_replaced = false
                  for _, ev in ipairs(articulation_events) do
                    if ev.replaces_fret then
                      base_replaced = true
                      if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                      local text = ev.symbol
                      if not ev.no_prefix then text = "_" .. text end
                      table.insert(staff_texts[staff_num], {
                        pos = start_ticks,
                        text = text,
                        type = ev.type
                      })
                      break
                    end
                  end

                  -- Add base drum text if not replaced
                  if not base_replaced then
                    if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                    table.insert(staff_texts[staff_num], {
                      pos = start_ticks,
                      text = drum_text,
                      type = 1
                    })
                  end

                  -- Add other (non‑replacing) articulations
                  for _, ev in ipairs(articulation_events) do
                    if not ev.replaces_fret then
                      if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                      local text = ev.symbol
                      if not ev.no_prefix then text = "_" .. text end
                      table.insert(staff_texts[staff_num], {
                        pos = start_ticks,
                        text = text,
                        type = ev.type
                      })
                    end
                  end

                  -- (Slides are skipped for drum notes)

                  if not chord then
                    advance(tick_duration)
                    cur_pos_ticks = cur_pos_ticks + tick_duration
                  end

                else
                  -- ==================== REGULAR (PITCHED) NOTE ====================
                  local pitch_node = findChild(elem, "pitch")
                  if pitch_node then
                    local step = getChildText(pitch_node, "step")
                    local alter = getChildValue(pitch_node, "alter") or 0
                    local octave = getChildValue(pitch_node, "octave") or 4
                    local offset = ({ C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11 })[step]
                    if offset then
                      local pitch = (octave + 1) * 12 + offset + alter

                      -- Extract string and fret
                      local string_num, fret_num
                      local notations = findChild(elem, "notations")
                      if notations then
                        local technical = findChild(notations, "technical")
                        if technical then
                          local str_node = findChild(technical, "string")
                          local fret_node = findChild(technical, "fret")
                          if str_node and fret_node then
                            string_num = tonumber(getNodeText(str_node))
                            fret_num = tonumber(getNodeText(fret_node))
                          end
                          -- Fallback: extract from GP processing instruction (<_gp_><root>)
                          if not (string_num and fret_num) then
                            for _, gp_child in ipairs(technical.children or {}) do
                              if gp_child.name == "_gp_" then
                                local gp_root = findChild(gp_child, "root")
                                if gp_root then
                                  local gp_str = findChild(gp_root, "string")
                                  local gp_fret = findChild(gp_root, "fret")
                                  if gp_str and gp_fret then
                                    string_num = tonumber(getNodeText(gp_str))
                                    fret_num = tonumber(getNodeText(gp_fret))
                                  end
                                end
                                break
                              end
                            end
                          end
                        end
                      end

                      -- Skip notes without tab info
                      if not (string_num and fret_num) then
                        if not chord then
                          advance(tick_duration)
                          cur_pos_ticks = cur_pos_ticks + tick_duration
                        end
                        goto continue
                      end

                      -- Map string number (1‑6) to MIDI channel
                      local channel = 7 - string_num
                      if channel < 1 or channel > 16 then channel = 1 end
                      local velocity = 100

                      -- Pre-compute articulations to decide if chord offset is needed
                      local articulation_events = getArticulationEvents(elem, fret_num)
                      local has_slides = false
                      if notations then
                        for _, child in ipairs(notations.children or {}) do
                          if slide_names[child.name] then
                            has_slides = true
                            break
                          end
                        end
                      end
                      local needs_chord_offset = fret_number_enabled or #articulation_events > 0 or has_slides

                      -- Determine start position with possible chord offset
                      -- Apply per-staff grace running offset for correct beat alignment
                      local pitched_grace_off = staff_grace_running_offset[staff_num] or 0
                      local start_ticks
                      if chord then
                        local base_start = staff_last_start[staff_num]
                        if not base_start then
                          base_start = cur_pos_ticks + pitched_grace_off
                          staff_last_start[staff_num] = base_start
                          staff_chord_count[staff_num] = 1
                        end
                        local count = staff_chord_count[staff_num] or 0
                        count = count + 1
                        staff_chord_count[staff_num] = count
                        start_ticks = base_start + (count - 1) * (needs_chord_offset and chord_offset_ticks or 0)
                      else
                        start_ticks = cur_pos_ticks + pitched_grace_off
                        staff_last_start[staff_num] = start_ticks
                        staff_chord_count[staff_num] = 1
                      end

                      -- Store note (merge with previous if tie stop)
                      if not staff_notes[staff_num] then staff_notes[staff_num] = {} end
                      local note_channel = channel - 1
                      -- For bass tracks, shift channel down by 1
                      if is_bass then
                        note_channel = note_channel - 1
                      end

                      -- Trim any previous note on the same channel+pitch that
                      -- would overlap this note (e.g. chord-offset causes a
                      -- 1-tick overlap when the same open string repeats).
                      -- Without this, REAPER silently drops the new note.
                      for ni = #staff_notes[staff_num], 1, -1 do
                        local prev = staff_notes[staff_num][ni]
                        if prev.pitch == pitch and prev.channel == note_channel
                            and prev.endpos > start_ticks and prev.pos < start_ticks then
                          prev.endpos = start_ticks
                          break
                        end
                      end

                      local is_tie_stop = false
                      local tie_nodes = findChildren(elem, "tie")
                      for _, tie_node in ipairs(tie_nodes) do
                        if getAttribute(tie_node, "type") == "stop" then
                          is_tie_stop = true
                          break
                        end
                      end
                      if is_tie_stop then
                        -- Extend the previous note with same pitch and channel
                        local merged = false
                        for ni = #staff_notes[staff_num], 1, -1 do
                          local prev = staff_notes[staff_num][ni]
                          if prev.pitch == pitch and prev.channel == note_channel then
                            prev.endpos = start_ticks + tick_duration
                            merged = true
                            break
                          end
                        end
                        if not merged then
                          table.insert(staff_notes[staff_num], {
                            pos    = start_ticks,
                            endpos = start_ticks + tick_duration,
                            channel = note_channel,
                            pitch  = pitch,
                            vel    = velocity
                          })
                        end
                      else
                        table.insert(staff_notes[staff_num], {
                          pos    = start_ticks,
                          endpos = start_ticks + tick_duration,
                          channel = note_channel,
                          pitch  = pitch,
                          vel    = velocity
                        })
                      end

                      -- --- Process non‑slide articulations ---

                      -- Combine replaces_fret events: first non-suffix is the "main" symbol;
                      -- suffix events (e.g. vibrato "~") are appended to it.
                      -- If only suffix events exist, fret_num is used as the base.
                      local main_ev = nil
                      local suffix_chars = ""
                      local suffix_type = 1
                      for _, ev in ipairs(articulation_events) do
                        if ev.replaces_fret then
                          if ev.is_suffix then
                            suffix_chars = suffix_chars .. (ev.symbol or "")
                            suffix_type = ev.type
                          elseif not main_ev then
                            main_ev = ev
                          end
                        end
                      end

                      local fret_replaced = false
                      if main_ev ~= nil or suffix_chars ~= "" then
                        fret_replaced = true
                        if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                        local base_sym, ev_type, no_pfx
                        if main_ev then
                          base_sym = main_ev.symbol
                          ev_type  = main_ev.type
                          no_pfx   = main_ev.no_prefix
                        else
                          -- Only suffix(es), no main: prepend fret_num as base
                          base_sym = tostring(fret_num)
                          ev_type  = suffix_type
                          no_pfx   = false
                        end
                        local text = base_sym .. suffix_chars
                        if not no_pfx then text = "_" .. text end
                        table.insert(staff_texts[staff_num], {
                          pos = start_ticks,
                          text = text,
                          type = ev_type
                        })
                      end

                      -- Pre-check: if a slide-stop/standalone with replaces_fret exists, suppress separate fret event
                      if not fret_replaced and notations then
                        for _, child in ipairs(notations.children or {}) do
                          if slide_names[child.name] then
                            local stype = child.attrs and child.attrs.type
                            if stype ~= "start" then
                              local slide_entry = articulation_map[child.name]
                              local slide_rf = (articulation_replaces_fret_override[child.name] ~= nil)
                                  and articulation_replaces_fret_override[child.name]
                                  or (slide_entry and slide_entry.replaces_fret)
                              if slide_rf then
                                fret_replaced = true
                                break
                              end
                            end
                          end
                        end
                      end

                      if not fret_replaced then
                        if fret_number_enabled then
                          if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                          table.insert(staff_texts[staff_num], {
                            pos = start_ticks,
                            text = "_" .. fret_num,
                            type = fret_number_type
                          })
                        end
                      end

                      local seen_span_arts = {}
                      for _, ev in ipairs(articulation_events) do
                        if not ev.replaces_fret then
                          if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                          local is_span_art = span_line_enabled
                              and (ev.type == 6 or ev.type == 7)
                              and ev.art_name ~= nil
                          if is_span_art then
                            local aname = ev.art_name
                            seen_span_arts[aname] = true
                            if not chord then
                              -- Only advance spans on non-chord (new time position) notes
                              if not staff_span_state[staff_num] then
                                staff_span_state[staff_num] = {}
                              end
                              local span = staff_span_state[staff_num][aname]
                              if not span then
                                -- First occurrence: emit normal label
                                local text = ev.symbol
                                if not ev.no_prefix then text = "_" .. text end
                                table.insert(staff_texts[staff_num], {
                                  pos = start_ticks, text = text, type = ev.type
                                })
                                staff_span_state[staff_num][aname] = {
                                  last_idx = #staff_texts[staff_num],
                                  last_pos = start_ticks,
                                  count = 1
                                }
                              else
                                -- Continuation: upgrade previous "-|" to "----" if needed
                                if span.count >= 2 then
                                  staff_texts[staff_num][span.last_idx].text = "----"
                                end
                                -- Emit closing mark for now (upgraded to "----" if more follow)
                                table.insert(staff_texts[staff_num], {
                                  pos = start_ticks, text = "-|", type = ev.type
                                })
                                span.last_idx = #staff_texts[staff_num]
                                span.last_pos = start_ticks
                                span.count = span.count + 1
                              end
                            end
                            -- chord notes: just mark seen, no text emitted
                          else
                            -- Normal (non-span or span feature disabled) emission
                            local text = ev.symbol
                            if not ev.no_prefix then text = "_" .. text end
                            table.insert(staff_texts[staff_num], {
                              pos = start_ticks,
                              text = text,
                              type = ev.type
                            })
                          end
                        end
                      end

                      -- Close spans that were not present on this non-chord note
                      if not chord and staff_span_state[staff_num] then
                        for aname_k, _ in pairs(staff_span_state[staff_num]) do
                          if not seen_span_arts[aname_k] then
                            staff_span_state[staff_num][aname_k] = nil
                          end
                        end
                      end

                      -- --- Slide handling (start/stop pairing) ---
                      if notations then
                        for _, child in ipairs(notations.children or {}) do
                          if slide_names[child.name] then
                            local info = getSlideInfo(child, fret_num)
                            if info then
                              local slide_type = child.attrs and child.attrs.type
                              if slide_type == "start" then
                                -- store pending slide for this string
                                if not staff_pending_slides[staff_num] then
                                  staff_pending_slides[staff_num] = {}
                                end
                                staff_pending_slides[staff_num][string_num] = {
                                  start_pos = start_ticks,
                                  symbol = info.symbol,
                                  no_prefix = info.no_prefix,
                                  type = info.type
                                }
                              elseif slide_type == "stop" then
                                -- look for matching start on the same string
                                if staff_pending_slides[staff_num] and staff_pending_slides[staff_num][string_num] then
                                  local pending = staff_pending_slides[staff_num][string_num]
                                  -- Place slide event at the start of the second note (stop position).
                                  -- Use info.symbol (resolved at stop/destination note) so the fret
                                  -- number embedded via %d reflects the destination note's fret.
                                  if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                                  local text = info.symbol
                                  if not info.no_prefix then text = "_" .. text end
                                  table.insert(staff_texts[staff_num], {
                                    pos = start_ticks,   -- at second note's start
                                    text = text,
                                    type = pending.type
                                  })
                                  -- remove the pending start
                                  staff_pending_slides[staff_num][string_num] = nil
                                else
                                  -- no matching start -> treat as standalone at current note
                                  if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                                  local text = info.symbol
                                  if not info.no_prefix then text = "_" .. text end
                                  table.insert(staff_texts[staff_num], {
                                    pos = start_ticks,
                                    text = text,
                                    type = info.type
                                  })
                                end
                              else
                                -- no type, or type="continue" etc. -> treat as standalone at current note
                                if not staff_texts[staff_num] then staff_texts[staff_num] = {} end
                                local text = info.symbol
                                if not info.no_prefix then text = "_" .. text end
                                table.insert(staff_texts[staff_num], {
                                  pos = start_ticks,
                                  text = text,
                                  type = info.type
                                })
                              end
                            end
                          end
                        end
                      end

                      if not chord then
                        advance(tick_duration)
                        cur_pos_ticks = cur_pos_ticks + tick_duration
                      end

                      ::continue::
                    end
                  end
                end
              end
            end
          end

        elseif elem.name == "backup" then
          local dur_node = findChild(elem, "duration")
          if dur_node and divisions then
            local duration = tonumber(getNodeText(dur_node))
            if duration then
              local tick_duration = (duration / divisions) * ppq
              -- Backup moves backwards in time, so we subtract seconds too
              local sec = (tick_duration / ppq) * (60 / current_tempo)
              cur_seconds = cur_seconds - sec
              cur_pos_ticks = cur_pos_ticks - tick_duration
              if cur_pos_ticks < 0 then cur_pos_ticks = 0 end
              if cur_seconds < 0 then cur_seconds = 0 end
            end
          end

        elseif elem.name == "forward" then
          local dur_node = findChild(elem, "duration")
          if dur_node and divisions then
            local duration = tonumber(getNodeText(dur_node))
            if duration then
              local tick_duration = (duration / divisions) * ppq
              advance(tick_duration)
              cur_pos_ticks = cur_pos_ticks + tick_duration
            end
          end

        elseif elem.name == "direction" then
          -- Extract tempo from <sound> for ALL parts (needed for correct advance() timing)
          local sound = findChild(elem, "sound")
          if sound then
            local tempo_attr = getAttribute(sound, "tempo")
            if tempo_attr then
              local new_tempo = tonumber(tempo_attr)
              if new_tempo then
                -- Record marker only for first part to avoid duplicates
                if import_markers and part_idx == 1 then
                  if not markers[cur_seconds] then markers[cur_seconds] = {} end
                  markers[cur_seconds].tempo = new_tempo
                end
                -- Always update current tempo for correct advance() calculations
                current_tempo = new_tempo
                -- Record tempo change by tick position (first part only) for PPQ->seconds conversion
                if part_idx == 1 then
                  table.insert(tempo_map, {ticks = cur_pos_ticks, tempo = new_tempo})
                end
              end
            end
          end
          
          -- Check for section/rehearsal marker (only from first part to avoid duplicates)
          if parse_sections then
            local direction_type = findChild(elem, "direction-type")
            if direction_type then
              local rehearsal = findChild(direction_type, "rehearsal")
              if rehearsal then
                local section_name = getNodeText(rehearsal)
                if section_name and section_name ~= "" then
                  -- Check if we already have a section at this time (avoid duplicates)
                  local is_duplicate = false
                  for _, sec in ipairs(sections) do
                    if sec.name == section_name and math.abs(sec.start_time - cur_seconds) < 0.01 then
                      is_duplicate = true
                      break
                    end
                  end
                  
                  if not is_duplicate then
                    table.insert(sections, {
                      name = section_name,
                      start_time = cur_seconds,
                      end_time = cur_seconds,
                      ticks = cur_pos_ticks
                    })
                  end
                end
              end
            end
          end

        elseif elem.name == "sound" then
          -- Handle <sound> as direct child of <measure> (some exporters place it here)
          local tempo_attr = getAttribute(elem, "tempo")
          if tempo_attr then
            local new_tempo = tonumber(tempo_attr)
            if new_tempo then
              if import_markers and part_idx == 1 then
                if not markers[cur_seconds] then markers[cur_seconds] = {} end
                markers[cur_seconds].tempo = new_tempo
              end
              current_tempo = new_tempo
              if part_idx == 1 then
                table.insert(tempo_map, {ticks = cur_pos_ticks, tempo = new_tempo})
              end
            end
          end
        end
      end
    end

    -- Store this part's data
    all_parts_data[part_id] = {
      staff_notes = staff_notes,
      staff_texts = staff_texts,
      staff_tunings = staff_tunings,
      total_seconds = cur_seconds,
      total_ticks = cur_pos_ticks
    }
  end

  if import_progress.active then
    update_import_progress(0.50, "Processing alignment...")
  end

  -- 11. Determine overall max length across all parts (needed for region boundaries)
  local max_seconds = 0
  local max_ticks = 0
  for _, data in pairs(all_parts_data) do
    if data.total_seconds > max_seconds then
      max_seconds = data.total_seconds
    end
    if data.total_ticks and data.total_ticks > max_ticks then
      max_ticks = data.total_ticks
    end
  end
  if max_seconds < 0.001 then max_seconds = 1.0 end

  -- 9b. Determine import position offset (used for markers, regions, and MIDI items)
  -- When auto-loaded by region, always use that region's start position
  local item_position = 0
  if autoload_region_start_pos then
    item_position = autoload_region_start_pos
  elseif import_position_index == 2 then
    -- Edit Cursor
    item_position = reaper.GetCursorPosition()
  elseif import_position_index == 3 then
    -- Closest Region Start
    local cursor = reaper.GetCursorPosition()
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local best_dist = math.huge
    for i = 0, num_markers + num_regions - 1 do
      local _, is_rgn, pos = reaper.EnumProjectMarkers(i)
      if is_rgn then
        local d = math.abs(pos - cursor)
        if d < best_dist then best_dist = d; item_position = pos end
      end
    end
  elseif import_position_index == 4 then
    -- Closest Marker
    local cursor = reaper.GetCursorPosition()
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local best_dist = math.huge
    for i = 0, num_markers + num_regions - 1 do
      local _, is_rgn, pos = reaper.EnumProjectMarkers(i)
      if not is_rgn then
        local d = math.abs(pos - cursor)
        if d < best_dist then best_dist = d; item_position = pos end
      end
    end
  elseif import_position_index == 6 then
    -- START Marker: find any project marker whose name contains "START" (case-insensitive)
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
      local rv, is_rgn, pos, _, name = reaper.EnumProjectMarkers(i)
      if rv and not is_rgn and name and name:upper():find("START", 1, true) then
        item_position = pos
        break
      end
    end
  end

  -- 9b-onset. Region Onset: detect onset on selected onset item and use as import position
  if import_position_index == 5 and not autoload_region_start_pos then
    -- Find closest region
    local cursor = reaper.GetCursorPosition()
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    local best_dist = math.huge
    local rgn_start, rgn_end
    for i = 0, num_markers + num_regions - 1 do
      local _, is_rgn, pos, rgnend = reaper.EnumProjectMarkers(i)
      if is_rgn then
        local d = math.abs(pos - cursor)
        if d < best_dist then best_dist = d; rgn_start = pos; rgn_end = rgnend end
      end
    end
    if rgn_start then
      -- Get the item to detect onset on (from Onset Item selector)
      local onset_item = nil
      if onset_item_index > 0 then
        refresh_onset_item_items()
        local si = onset_item_items[onset_item_index]
        if si then onset_item = si.item end
      end
      if not onset_item then
        -- Auto: find first audio item in region
        local items = get_audio_items_in_region(rgn_start, rgn_end)
        if #items > 0 then onset_item = items[1].item end
      end
      if onset_item then
        local onset_pos = detect_song_start(onset_item)
        if onset_pos then
          item_position = onset_pos
          -- Create START marker at onset
          reaper.AddProjectMarker(0, false, onset_pos, 0, "START", -1)
        else
          item_position = rgn_start
        end
      else
        item_position = rgn_start
      end
    end
  end

  -- 9c. Audio-to-score alignment (if enabled)
  -- Per-note correction data (populated during alignment, used during insertion)
  local note_corrections_table = nil
  local tick_to_score_time = nil
  local audio_onset_times = nil  -- onset positions (relative to item start) for stretch markers
  local audio_stem_file_start = 0  -- project time where audio file time 0 maps to
  local drum_transients = nil  -- native transient detections {proj, src, strength}
  local drum_aud_item = nil    -- drum audio item reference for stretch markers
  local beat_desired_offsets = nil  -- absolute project times for per-beat tempo correction
  local beat_snap_details = nil   -- per-beat snap diagnostics for debug output
  local bar_desired_offsets = nil  -- absolute project times for per-bar tempo correction
  if align_to_audio and #measure_boundaries > 1 then
    -- Find the audio stem to align to
    local region_name = nil
    if autoload_region_start_pos then
      region_name = autoload_last_region_name
    else
      region_name, _ = get_region_at_cursor()
    end

    local audio_path = nil
    local audio_file_start = 0  -- project time where file time 0 maps to

    -- Check explicit stem selection first
    if align_stem_index > 0 then
      refresh_align_stem_items()
      local si = align_stem_items[align_stem_index]
      if si and si.item and si.take then
        local src = reaper.GetMediaItemTake_Source(si.take)
        if src then
          audio_path = reaper.GetMediaSourceFileName(src)
          if audio_path == "" then audio_path = nil end
          if audio_path then
            local ip = reaper.GetMediaItemInfo_Value(si.item, "D_POSITION")
            local to = reaper.GetMediaItemTakeInfo_Value(si.take, "D_STARTOFFS")
            audio_file_start = ip - to
            drum_aud_item = si.item
          end
        end
      end
    end

    if not audio_path and region_name then
      audio_path, audio_file_start = find_audio_stem_for_region(region_name)
    end

    if not audio_path then
      -- Fallback: try selected audio item
      local sel_item = reaper.GetSelectedMediaItem(0, 0)
      if sel_item then
        local sel_take = reaper.GetActiveTake(sel_item)
        if sel_take and not reaper.TakeIsMIDI(sel_take) then
          local src = reaper.GetMediaItemTake_Source(sel_take)
          if src then
            audio_path = reaper.GetMediaSourceFileName(src)
            if audio_path == "" then audio_path = nil end
            if audio_path then
              local ip = reaper.GetMediaItemInfo_Value(sel_item, "D_POSITION")
              local to = reaper.GetMediaItemTakeInfo_Value(sel_take, "D_STARTOFFS")
              audio_file_start = ip - to
            end
          end
        end
      end
    end

    if audio_path then
      import_log("Aligning to audio: " .. audio_path)

      -- Look for a "START" marker — search ALL project markers
      local start_marker_pos = nil  -- project position of START marker
      local start_marker_time = nil -- audio-file-relative time for Python
      local _, nm, nr = reaper.CountProjectMarkers(0)
      for i = 0, nm + nr - 1 do
        local rv, is_rgn, pos, _, name, _ = reaper.EnumProjectMarkers(i)
        if not is_rgn and name and name:upper():find("START", 1, true) then
          -- If we have a region context, only accept markers within it
          local in_range = true
          if autoload_region_start_pos then
            local rgn_s = autoload_region_start_pos
            -- Find region end
            for j = 0, nm + nr - 1 do
              local _, jr, jp, je = reaper.EnumProjectMarkers(j)
              if jr and math.abs(jp - rgn_s) < 0.01 then
                if pos < jp - 0.01 or pos > je + 0.01 then
                  in_range = false
                end
                break
              end
            end
          end
          if in_range then
            start_marker_pos = pos
            start_marker_time = pos - audio_file_start
            import_log(string.format(
              "Found START marker at %.3fs", pos))
            break
          end
        end
      end
      if not start_marker_pos then
        import_log("No START marker found. Using auto-detect.")
      end

      -- Collect all note onset times (score seconds) and build tick→score_time map
      local score_onsets = {}
      local onset_set = {}  -- dedup
      tick_to_score_time = {}  -- tick pos → original score time (for per-note corrections)
      for _, data in pairs(all_parts_data) do
        for _, notes in pairs(data.staff_notes) do
          for _, n in ipairs(notes) do
            local t = ticks_to_seconds(n.pos, tempo_map, ppq)
            tick_to_score_time[n.pos] = t
            local key = string.format("%.4f", t)
            if not onset_set[key] then
              onset_set[key] = true
              score_onsets[#score_onsets + 1] = t
            end
          end
        end
      end
      table.sort(score_onsets)

      -- Run alignment
      local aligned, note_corr, audio_onsets = run_audio_alignment(audio_path, score_onsets, measure_boundaries, start_marker_time)

      -- Store note corrections for per-note nudging during insertion
      if note_corr and align_notes_to_transients then
        note_corrections_table = note_corr
      end

      -- Store audio onset times for stretch markers on drum stems
      audio_onset_times = audio_onsets
      audio_stem_file_start = audio_file_start

      -- Detect native transients on drum audio for tempo snapping + later reuse
      local drum_aud_take
      drum_aud_item, drum_aud_take = find_drum_audio_item()
      if drum_aud_item and drum_aud_take then
        drum_transients = detect_audio_transients(drum_aud_item, drum_aud_take)
        import_log(string.format(
          "Detected %d transients on drum stem",
          #drum_transients))
      end

      if aligned and #aligned > 0 then
        -- Snap bar positions to drum transients using BPM-closest logic.
        -- For each bar, pick the transient that keeps tempo closest to the
        -- expected baseline from the score, avoiding ghost note snaps.
        -- Work in project time to avoid coordinate system mismatches.
        if drum_transients and #drum_transients > 0 then
          local snapped = 0
          local first_tr_proj = drum_transients[1].proj

          -- Store score-intended tempo per bar BEFORE snapping changes it.
          -- Used later to detect and reject wild tempo artifacts from bad transients.
          for _, ab in ipairs(aligned) do
            ab.score_tempo = ab.tempo
          end

          for i, ab in ipairs(aligned) do
            local bar_proj = audio_file_start + ab.real_time  -- project time

            -- Skip bars before drums come in
            if bar_proj < first_tr_proj - 0.1 then
              goto continue_bar_snap
            end

            -- Expected tempo from score for this bar
            local expected_bpm = ab.tempo

            -- Previous bar's snapped position
            local prev_proj = nil
            if i > 1 then prev_proj = audio_file_start + aligned[i-1].real_time end

            -- Binary search for closest transient by project time
            local lo, hi = 1, #drum_transients
            while lo < hi do
              local mid = math.floor((lo + hi) / 2)
              if drum_transients[mid].proj < bar_proj then lo = mid + 1 else hi = mid end
            end

            -- Search ±3 candidates, pick one whose resulting BPM is closest to expected
            local best_bpm_err = math.huge
            local best_proj = bar_proj
            local search_lo = math.max(1, lo - 3)
            local search_hi = math.min(#drum_transients, lo + 3)
            local found = false
            for ci = search_lo, search_hi do
              local cand = drum_transients[ci].proj
              if prev_proj then
                local gap = cand - prev_proj
                if gap > 0.05 then
                  -- Bar duration in quarter notes
                  local mb_beats = 4  -- default 4/4
                  for _, m in ipairs(measure_boundaries) do
                    if m.measure == ab.measure then
                      mb_beats = m.beats * 4.0 / m.beat_type
                      break
                    end
                  end
                  local cand_bpm = mb_beats * 60.0 / gap
                  local bpm_err = math.abs(cand_bpm - expected_bpm)
                  if bpm_err < best_bpm_err then
                    best_bpm_err = bpm_err
                    best_proj = cand
                    found = true
                  end
                end
              else
                -- First bar: use nearest
                local d = math.abs(cand - bar_proj)
                if d < best_bpm_err then
                  best_bpm_err = d
                  best_proj = cand
                  found = true
                end
              end
            end
            if found then
              ab.real_time = best_proj - audio_file_start
              snapped = snapped + 1
            end

            ::continue_bar_snap::
          end

          -- Enforce strict monotonicity after snapping
          for i = 2, #aligned do
            if aligned[i].real_time <= aligned[i-1].real_time + 0.05 then
              aligned[i].real_time = aligned[i-1].real_time +
                (measure_boundaries[i].score_time - measure_boundaries[i-1].score_time) /
                (aligned[i-1].tempo / 60.0)
            end
          end

          -- Recalculate per-bar tempos from snapped positions.
          -- If a recalculated tempo deviates >15% from the score's baseline
          -- (e.g., drum fill caused wrong transient snap → 33 BPM instead of 99),
          -- reject it and use the score tempo instead.
          local MAX_TEMPO_DEVIATION = 0.15  -- 15% threshold
          local smoothed_count = 0
          for i = 1, #aligned do
            local mb = nil
            for _, m in ipairs(measure_boundaries) do
              if m.measure == aligned[i].measure then mb = m; break end
            end
            if mb and i < #aligned then
              local bar_dur = aligned[i+1].real_time - aligned[i].real_time
              local qn = mb.beats * 4.0 / mb.beat_type
              if bar_dur > 0.05 then
                local new_tempo = math.max(30, math.min(300, qn * 60.0 / bar_dur))
                local base = aligned[i].score_tempo or new_tempo
                local deviation = math.abs(new_tempo - base) / base
                if deviation > MAX_TEMPO_DEVIATION then
                  -- Wild tempo — use score baseline instead
                  aligned[i].tempo = base
                  smoothed_count = smoothed_count + 1
                else
                  aligned[i].tempo = new_tempo
                end
              end
            elseif i == #aligned and i > 1 then
              aligned[i].tempo = aligned[i-1].tempo
            end
          end
          if smoothed_count > 0 then
            import_log(string.format(
              "Smoothed %d/%d bar tempos",
              smoothed_count, #aligned))
          end

          import_log(string.format(
            "Snapped %d/%d bar positions to transients", snapped, #aligned))
        end

        if tempo_map_freq_enabled and drum_transients and #drum_transients > 0 then
          -- Per-beat tempo map: each beat's position = nearest drum transient.
          -- Work entirely in PROJECT TIME to avoid coordinate mismatches.
          -- The drum transients ARE the ground truth — tempo markers go there.

          -- Step 1: Build estimated beat positions in PROJECT time
          local beat_entries = {}  -- {tick, proj_time, beat_type, snapped_sm}
          for i = 1, #aligned do
            local ab = aligned[i]
            local mb = nil
            for _, m in ipairs(measure_boundaries) do
              if m.measure == ab.measure then mb = m; break end
            end
            if mb then
              local bar_start_tick = mb.ticks
              local num_beats = ab.beats
              local beat_type = ab.beat_type
              local ticks_per_beat = ppq * 4 / beat_type

              if i < #aligned then
                local bar_dur = aligned[i+1].real_time - ab.real_time
                local beat_dur = bar_dur / num_beats
                for k = 0, num_beats - 1 do
                  local rt = ab.real_time + k * beat_dur
                  beat_entries[#beat_entries+1] = {
                    tick = bar_start_tick + k * ticks_per_beat,
                    proj_time = audio_file_start + rt,  -- absolute project time
                    beat_type = beat_type,
                    snapped_sm = nil,  -- will hold transient index if snapped
                  }
                end
              else
                beat_entries[#beat_entries+1] = {
                  tick = bar_start_tick,
                  proj_time = audio_file_start + ab.real_time,
                  beat_type = beat_type,
                  snapped_sm = nil,
                }
              end
            end
          end

          -- Step 2: For each beat, snap to the transient whose resulting BPM
          -- is closest to the expected tempo from the score (baseline).
          -- Beats before the first transient keep their interpolated positions
          -- so they use pure baseline tempo (drums haven't started yet).
          local snapped_beats = 0
          local first_tr_proj = drum_transients[1].proj

          for bi, be in ipairs(beat_entries) do
            be.orig_proj = be.proj_time

            -- Skip beats before drums come in — keep baseline position
            if be.proj_time < first_tr_proj - 0.1 then
              goto continue_beat_snap
            end

            -- Expected BPM from score = 60 / (original gap to next beat)
            local expected_bpm = 98  -- fallback
            if bi < #beat_entries then
              -- Use .proj_time for look-ahead (orig_proj not yet set on next entry)
              local gap = beat_entries[bi+1].proj_time - be.orig_proj
              if gap > 0.01 then expected_bpm = 60 / gap end
            elseif bi > 1 then
              local gap = be.orig_proj - beat_entries[bi-1].orig_proj
              if gap > 0.01 then expected_bpm = 60 / gap end
            end

            -- Previous beat's snapped position (needed to compute resulting BPM)
            local prev_proj = nil
            if bi > 1 then prev_proj = beat_entries[bi-1].proj_time end

            -- Binary search for closest transient
            local lo, hi = 1, #drum_transients
            while lo < hi do
              local mid = math.floor((lo + hi) / 2)
              if drum_transients[mid].proj < be.proj_time then lo = mid + 1 else hi = mid end
            end

            -- Search candidates in neighborhood: pick the one whose BPM
            -- (relative to previous beat) is closest to expected_bpm.
            local best_bpm_err = math.huge
            local best_proj = be.proj_time
            local best_idx = nil
            local search_lo = math.max(1, lo - 3)
            local search_hi = math.min(#drum_transients, lo + 3)
            for ci = search_lo, search_hi do
              local cand = drum_transients[ci].proj
              if prev_proj then
                local gap = cand - prev_proj
                if gap > 0.01 then
                  local cand_bpm = 60 / gap
                  local bpm_err = math.abs(cand_bpm - expected_bpm)
                  if bpm_err < best_bpm_err then
                    best_bpm_err = bpm_err
                    best_proj = cand
                    best_idx = ci
                  end
                end
              else
                -- First snapped beat: just use nearest
                local d = math.abs(cand - be.proj_time)
                if d < best_bpm_err then
                  best_bpm_err = d
                  best_proj = cand
                  best_idx = ci
                end
              end
            end
            if best_idx then
              be.proj_time = best_proj
              be.snapped_sm = best_idx
              snapped_beats = snapped_beats + 1
            end

            ::continue_beat_snap::
          end

          -- Step 3: Enforce strict monotonicity.
          -- If collision, use baseline tempo gap instead of tiny 15ms gap
          -- (which caused 300 BPM spam).
          for i = 2, #beat_entries do
            if beat_entries[i].proj_time <= beat_entries[i-1].proj_time + 0.01 then
              -- Revert to interpolated position
              beat_entries[i].proj_time = beat_entries[i].orig_proj
              beat_entries[i].snapped_sm = nil
              -- If still colliding, space by expected beat duration (baseline tempo)
              if beat_entries[i].proj_time <= beat_entries[i-1].proj_time + 0.01 then
                local baseline_gap = beat_entries[i].orig_proj - beat_entries[i-1].orig_proj
                if baseline_gap < 0.1 then baseline_gap = 0.6 end  -- ~100 BPM fallback
                beat_entries[i].proj_time = beat_entries[i-1].proj_time + baseline_gap
              end
            end
          end

          -- Step 4: Compute the effective item_position so marker_sec offsets
          -- produce exact transient positions when insert_markers adds it back.
          -- item_position will be start_marker_pos (if START marker exists)
          -- or audio_file_start + aligned[1].real_time.
          local eff_item_pos = start_marker_pos or (audio_file_start + aligned[1].real_time)

          -- Step 5: Compute per-beat tempos and build tempo_map + markers.
          -- 1/4 time signature: BPM = 60 / gap_to_next_beat.
          -- If a beat's tempo deviates >15% from the score's expected BPM,
          -- use the expected BPM instead (avoids drum fill artifacts).
          -- marker_sec = proj_time - eff_item_pos, so that
          -- insert_markers places at marker_sec + item_position = proj_time exactly.
          local MAX_BEAT_DEVIATION = 0.15  -- 15% threshold
          local smoothed_beats = 0
          tempo_map = {}
          markers = {}
          for i, be in ipairs(beat_entries) do
            -- Compute expected BPM from score (unsnapped positions)
            local expected_bpm = 98  -- global fallback
            if be.orig_proj then
              if i < #beat_entries and beat_entries[i+1].orig_proj then
                local gap = beat_entries[i+1].orig_proj - be.orig_proj
                if gap > 0.01 then expected_bpm = 60 / gap end
              elseif i > 1 and beat_entries[i-1].orig_proj then
                local gap = be.orig_proj - beat_entries[i-1].orig_proj
                if gap > 0.01 then expected_bpm = 60 / gap end
              end
            end

            local beat_tempo = expected_bpm  -- default to score tempo
            if i < #beat_entries then
              local bd = beat_entries[i+1].proj_time - be.proj_time
              if bd > 0.01 then
                local raw_tempo = math.max(30, math.min(300, 60 / bd))
                local deviation = math.abs(raw_tempo - expected_bpm) / expected_bpm
                if deviation > MAX_BEAT_DEVIATION then
                  beat_tempo = expected_bpm
                  smoothed_beats = smoothed_beats + 1
                else
                  beat_tempo = raw_tempo
                end
              end
            elseif i > 1 then
              local bd = be.proj_time - beat_entries[i-1].proj_time
              if bd > 0.01 then
                local raw_tempo = math.max(30, math.min(300, 60 / bd))
                local deviation = math.abs(raw_tempo - expected_bpm) / expected_bpm
                if deviation > MAX_BEAT_DEVIATION then
                  beat_tempo = expected_bpm
                  smoothed_beats = smoothed_beats + 1
                else
                  beat_tempo = raw_tempo
                end
              end
            end
            table.insert(tempo_map, {ticks = be.tick, tempo = beat_tempo})
            local marker_sec = be.proj_time - eff_item_pos
            if not markers[marker_sec] then markers[marker_sec] = {} end
            markers[marker_sec].tempo = beat_tempo
            local eff_n, eff_d = get_detect_tempo_timesig()
            markers[marker_sec].beats = eff_n or 1
            markers[marker_sec].beat_type = eff_d or 4
          end
          table.sort(tempo_map, function(a, b) return a.ticks < b.ticks end)

          import_log(string.format(
            "Per-beat tempo map: %d beats, %d snapped, %d smoothed",
            #beat_entries, snapped_beats, smoothed_beats))

          -- Store desired ABSOLUTE project times for the correction pass.
          -- No offset arithmetic — just the exact project time each marker must be at.
          beat_desired_offsets = {}
          for _, be in ipairs(beat_entries) do
            beat_desired_offsets[#beat_desired_offsets + 1] = be.proj_time
          end

          -- Store snap details for debug output
          beat_snap_details = {}
          for bi, be in ipairs(beat_entries) do
            beat_snap_details[bi] = {
              orig_proj = be.orig_proj,
              final_proj = be.proj_time,
              snapped_sm = be.snapped_sm,
            }
          end
        else
          -- Per-bar tempo map (default)
          -- Rebuild tempo_map from aligned boundaries (every bar)
          tempo_map = {}
          for i, ab in ipairs(aligned) do
            for _, mb in ipairs(measure_boundaries) do
              if mb.measure == ab.measure then
                table.insert(tempo_map, {ticks = mb.ticks, tempo = ab.tempo})
                break
              end
            end
          end
          if #tempo_map == 0 and #aligned > 0 then
            table.insert(tempo_map, {ticks = 0, tempo = aligned[1].tempo})
          end
          table.sort(tempo_map, function(a, b) return a.ticks < b.ticks end)

          -- Rebuild markers — every bar gets a tempo marker for tight alignment.
          -- Use eff_item_pos pattern (same as per-beat) so that
          -- marker_sec + item_position = proj_time exactly.
          local bar_eff_item_pos = start_marker_pos or (audio_file_start + aligned[1].real_time)
          markers = {}
          bar_desired_offsets = {}
          for i, ab in ipairs(aligned) do
            local bar_proj = audio_file_start + ab.real_time  -- absolute project time
            local marker_sec = bar_proj - bar_eff_item_pos
            if not markers[marker_sec] then markers[marker_sec] = {} end
            markers[marker_sec].tempo = ab.tempo
            markers[marker_sec].beats = ab.beats
            markers[marker_sec].beat_type = ab.beat_type
            bar_desired_offsets[#bar_desired_offsets + 1] = bar_proj
          end
        end

        -- Recompute max_seconds with aligned tempo map
        max_seconds = 0
        for _, data in pairs(all_parts_data) do
          for _, notes in pairs(data.staff_notes) do
            for _, n in ipairs(notes) do
              local end_sec = ticks_to_seconds(n.endpos, tempo_map, ppq)
              if end_sec > max_seconds then max_seconds = end_sec end
            end
          end
        end
        if max_seconds < 0.001 then max_seconds = 1.0 end

        -- Recompute section times with aligned tempo map
        for _, sec in ipairs(sections) do
          if sec.ticks then
            sec.start_time = ticks_to_seconds(sec.ticks, tempo_map, ppq)
            sec.end_time = sec.start_time
          end
        end

        -- Position: use START marker directly, or fall back to audio offset
        if start_marker_pos then
          item_position = start_marker_pos
        else
          item_position = audio_file_start + aligned[1].real_time
        end

        import_log(string.format(
          "Aligned %d bars, position=%.3fs", #aligned, item_position))
      else
        import_log("Alignment failed, importing without alignment.")
      end
    else
      import_log("No audio stem found for alignment.")
    end
  end

  if import_progress.active then
    update_import_progress(0.65, "Inserting tempo markers...")
  end

  -- 10. Insert tempo/time signature markers if requested
  if import_markers and next(markers) then
    insert_markers(markers, item_position)

    -- Correction pass for per-bar mode: adjust each tempo marker's BPM
    -- so the NEXT marker lands exactly at the desired bar position.
    if not tempo_map_freq_enabled and bar_desired_offsets and #bar_desired_offsets > 1 then
      local n_tempo = reaper.CountTempoTimeSigMarkers(0)
      local desired = bar_desired_offsets
      local first_idx = nil
      for mi = 0, n_tempo - 1 do
        local rv, t = reaper.GetTempoTimeSigMarker(0, mi)
        if rv and math.abs(t - desired[1]) < 0.002 then
          first_idx = mi
          break
        end
      end
      if first_idx then
        local corrections = 0
        for k = 2, #desired do
          local mi = first_idx + k - 1
          if mi >= n_tempo then break end
          local prev_mi = mi - 1
          local rv_p, t_prev, _, _, bpm_prev, tsn_p, tsd_p, lin_p = reaper.GetTempoTimeSigMarker(0, prev_mi)
          local rv_k, t_cur = reaper.GetTempoTimeSigMarker(0, mi)
          if rv_p and rv_k then
            local target = desired[k]
            local err = t_cur - target
            if math.abs(err) > 0.0001 then
              -- Find the measure_boundary for this bar to get quarter-note count
              local ab = aligned and aligned[k]
              local mb_beats = 4  -- default 4/4
              if ab then
                for _, m in ipairs(measure_boundaries) do
                  if m.measure == ab.measure then
                    mb_beats = m.beats * 4.0 / m.beat_type
                    break
                  end
                end
              end
              local gap = target - t_prev
              if gap > 0.005 then
                local new_bpm = mb_beats * 60.0 / gap
                new_bpm = math.max(30, math.min(300, new_bpm))
                reaper.SetTempoTimeSigMarker(0, prev_mi, t_prev, -1, -1, new_bpm,
                  tsn_p > 0 and tsn_p or 0, tsd_p > 0 and tsd_p or 0, lin_p)
                reaper.UpdateTimeline()
                corrections = corrections + 1
              end
            end
          end
        end
        reaper.UpdateTimeline()
        import_log(string.format(
          "Per-bar tempo correction: adjusted %d/%d markers",
          corrections, #desired - 1))
      end
    end

    -- Correction pass for per-beat mode: adjust each tempo marker's BPM
    -- so the NEXT marker lands exactly at the desired transient position.
    -- This is equivalent to REAPER's "move tempo marker, adjusting previous tempo".
    -- Done sequentially because adjusting marker N shifts all markers after it.
    if tempo_map_freq_enabled and beat_desired_offsets and #beat_desired_offsets > 1 then
      local n_tempo = reaper.CountTempoTimeSigMarkers(0)
      -- beat_desired_offsets are ABSOLUTE project times (no offset needed)
      local desired = beat_desired_offsets
      -- We need to match our beat entries to the REAPER markers.
      -- Our markers start at desired[1]; find which REAPER marker index that is.
      local first_idx = nil
      for mi = 0, n_tempo - 1 do
        local rv, t = reaper.GetTempoTimeSigMarker(0, mi)
        if rv and math.abs(t - desired[1]) < 0.002 then
          first_idx = mi
          break
        end
      end
      if first_idx then
        local corrections = 0
        for k = 2, #desired do
          local mi = first_idx + k - 1  -- REAPER marker index for beat k
          if mi >= n_tempo then break end
          local prev_mi = mi - 1
          -- Read current position of the previous marker (which we may have just adjusted)
          local rv_p, t_prev, _, _, bpm_prev, tsn_p, tsd_p, lin_p = reaper.GetTempoTimeSigMarker(0, prev_mi)
          -- Read current position of marker k
          local rv_k, t_cur = reaper.GetTempoTimeSigMarker(0, mi)
          if rv_p and rv_k then
            local target = desired[k]
            local err = t_cur - target
            if math.abs(err) > 0.0001 then  -- more than 0.1ms off
              -- Adjust previous marker's BPM: BPM = 60 / (target - t_prev)
              local gap = target - t_prev
              if gap > 0.005 then
                local new_bpm = 60.0 / gap
                new_bpm = math.max(30, math.min(300, new_bpm))
                reaper.SetTempoTimeSigMarker(0, prev_mi, t_prev, -1, -1, new_bpm,
                  tsn_p > 0 and tsn_p or 1, tsd_p > 0 and tsd_p or 4, lin_p)
                reaper.UpdateTimeline()
                corrections = corrections + 1
              end
            end
          end
        end
        reaper.UpdateTimeline()
        import_log(string.format(
          "Tempo correction: adjusted %d/%d markers",
          corrections, #desired - 1))

        -- Debug: write detailed comparison to file
        local debug_path = reaper.GetResourcePath() .. "/Scripts/konst-reascripts/beat_debug.txt"
        local dbg = io.open(debug_path, "w")
        if dbg then
          local function fmt_time(s)
            if s < 0 then return "N/A             " end
            local m = math.floor(s / 60)
            local sec = s - m * 60
            return string.format("%d:%06.3f", m, sec)
          end

          dbg:write("=== BEAT POSITION DEBUG ===\n")
          dbg:write(string.format("item_position = %.6f  audio_file_start = %.6f\n\n",
            item_position, audio_file_start or 0))

          -- Snap diagnostics: show what each beat snapped to
          dbg:write("=== BEAT SNAP DETAILS ===\n")
          dbg:write(string.format("%-6s  %-16s  %-16s  %-10s  %-6s  %s\n",
            "Beat", "Estimated (proj)", "Snapped (proj)", "Shift(ms)", "SM#", "SM strength"))
          dbg:write(string.rep("-", 90) .. "\n")
          if beat_snap_details then
            for bi = 1, #beat_snap_details do
              local sd = beat_snap_details[bi]
              local shift_ms = (sd.final_proj - sd.orig_proj) * 1000
              local sm_str = sd.snapped_sm and string.format("%-6d", sd.snapped_sm) or "  --  "
              local strength_str = ""
              if sd.snapped_sm and drum_transients and drum_transients[sd.snapped_sm] then
                strength_str = string.format("%.6f", drum_transients[sd.snapped_sm].strength)
              end
              dbg:write(string.format("%-6d  %-16s  %-16s  %+8.1f    %s  %s\n",
                bi, fmt_time(sd.orig_proj), fmt_time(sd.final_proj),
                shift_ms, sm_str, strength_str))
            end
          end

          dbg:write(string.format("\n%-6s  %-16s  %-16s  %-12s  %-16s  %s\n",
            "Beat", "Tempo mkr (proj)", "Stretch mkr", "TM-SM (ms)", "Desired", "BPM"))
          dbg:write(string.rep("-", 95) .. "\n")

          local n_tempo_after = reaper.CountTempoTimeSigMarkers(0)
          for k = 1, #desired do
            local mi = first_idx + k - 1
            local t_actual = -1
            local bpm_val = 0
            if mi < n_tempo_after then
              local rv, t, _, _, bpm = reaper.GetTempoTimeSigMarker(0, mi)
              if rv then t_actual = t; bpm_val = bpm end
            end
            -- Compare tempo marker to the stretch marker it should align with
            local sm_proj = -1
            local sm_diff_ms = 0
            if beat_snap_details and beat_snap_details[k] and beat_snap_details[k].snapped_sm then
              local si = beat_snap_details[k].snapped_sm
              if drum_transients and drum_transients[si] then
                sm_proj = drum_transients[si].proj
                if t_actual >= 0 then
                  sm_diff_ms = (t_actual - sm_proj) * 1000
                end
              end
            end
            local sm_str = sm_proj >= 0 and fmt_time(sm_proj) or "  --  "
            local diff_str = sm_proj >= 0 and string.format("%+8.3f", sm_diff_ms) or "    --  "
            dbg:write(string.format("%-6d  %-16s  %-16s  %-12s  %-16s  %.2f\n",
              k, fmt_time(t_actual), sm_str, diff_str, fmt_time(desired[k]), bpm_val))
          end

          dbg:write(string.format("\n=== STRETCH MARKERS (transients) — %d total ===\n",
            drum_transients and #drum_transients or 0))
          if drum_transients then
            for i = 1, #drum_transients do
              local tr = drum_transients[i]
              dbg:write(string.format("  SM %3d: proj=%s  src=%.6f  strength=%.6f\n",
                i, fmt_time(tr.proj), tr.src, tr.strength or 0))
            end
          end

          dbg:write("\n=== END DEBUG ===\n")
          dbg:close()
          import_log("Debug written to: " .. debug_path)
        end
      else
        import_log("Tempo correction: could not find first beat marker")
      end
    end
  end

  -- 10a. Rebuild tempo_map from REAPER's actual corrected tempo markers.
  -- The correction pass adjusts BPM values so tempo markers land at exact
  -- transient positions. Our internal tempo_map still has the smoothed values
  -- from before correction. If we use the stale tempo_map in ticks_to_seconds(),
  -- the resulting seconds won't match REAPER's internal timeline, causing notes
  -- to be off-tempo. Rebuilding ensures ticks_to_seconds() agrees with REAPER.
  if import_markers and (beat_desired_offsets or bar_desired_offsets) then
    local n_tempo = reaper.CountTempoTimeSigMarkers(0)
    if n_tempo > 0 then
      -- Read all REAPER tempo markers and rebuild tempo_map
      -- We need to convert project-time markers back to tick-based entries.
      -- Since our tempo_map is keyed by ticks, we rebuild it by reading each
      -- REAPER marker and computing its tick position via MIDI_GetPPQPosFromProjTime.
      -- But we don't have a take yet... Instead, recompute tempo_map entries
      -- by matching our existing tick positions to the corrected BPM values.
      local corrected_map = {}
      for mi = 0, n_tempo - 1 do
        local rv, t_pos, _, _, bpm, tsn, tsd, lin = reaper.GetTempoTimeSigMarker(0, mi)
        if rv and bpm > 0 then
          -- Find the matching tick position from our existing tempo_map
          local best_tick = nil
          local best_dist = math.huge
          for _, entry in ipairs(tempo_map) do
            -- Convert this entry's tick to project time using our old map
            -- to find which tempo_map entry corresponds to this REAPER marker
            local entry_sec = ticks_to_seconds(entry.ticks, tempo_map, ppq)
            local entry_proj = item_position + entry_sec
            local dist = math.abs(entry_proj - t_pos)
            if dist < best_dist then
              best_dist = dist
              best_tick = entry.ticks
            end
          end
          if best_tick and best_dist < 1.0 then
            corrected_map[#corrected_map + 1] = {ticks = best_tick, tempo = bpm}
          end
        end
      end
      if #corrected_map > 0 then
        table.sort(corrected_map, function(a, b) return a.ticks < b.ticks end)
        tempo_map = corrected_map
        import_log(string.format(
          "Rebuilt tempo_map from %d corrected markers", #corrected_map))
      end
    end
  end
  if import_regions and next(sections) then
    insert_regions(sections, max_seconds, item_position)
  end

  -- 10b. Write stretch markers on detect item during import (if option enabled)
  if detect_stretch_markers_enabled and align_to_audio and drum_aud_item and drum_transients and #drum_transients > 0 then
    local sm_take = reaper.GetActiveTake(drum_aud_item)
    if sm_take and not reaper.TakeIsMIDI(sm_take) then
      for _, tr in ipairs(drum_transients) do
        if tr.src then
          reaper.SetTakeStretchMarker(sm_take, -1, tr.src)
        end
      end
      reaper.UpdateTimeline()
      import_log(string.format("Wrote %d stretch markers on detect item", #drum_transients))
    end
  end

  if import_progress.active then
    update_import_progress(0.75, "Creating tracks and inserting MIDI...")
  end

  -- 12. Create tracks for each part/staff that has notes (in MusicXML order)
  local initial_track_count = reaper.CountTracks(0)
  local tracks_created = 0
  local track_insert_idx = 0
  local total_parts_to_insert = 0
  for _, pid in ipairs(parts_order) do
    if all_parts_data[pid] then total_parts_to_insert = total_parts_to_insert + 1 end
  end
  local next_existing_track_idx = 0  -- Track index for "insert on existing tracks" mode
  
  -- Determine insertion mode
  local mode = "new_tracks"  -- default
  if insert_on_existing_tracks then
    mode = "existing_tracks"
  elseif insert_on_tracks_by_name then
    mode = "tracks_by_name"
  end
  
  for _, part_id in ipairs(parts_order) do
    local data = all_parts_data[part_id]
    if data then
    track_insert_idx = track_insert_idx + 1
    if import_progress.active then
      update_import_progress(0.75 + 0.20 * (track_insert_idx / total_parts_to_insert),
        string.format("Inserting track %d/%d...", track_insert_idx, total_parts_to_insert))
    end
    local base_track_name = part_names[part_id] or ("Part " .. part_id)
    if gm_name_tracks_enabled then
      local mp = part_midi_program[part_id]
      -- Check channel 10 (drums) first, then GM program lookup
      if mp and mp.channel == 9 then
        base_track_name = "Drums"
      elseif mp and gm_program_to_name[mp.program] then
        base_track_name = gm_program_to_name[mp.program]
      elseif isDrumTrack(base_track_name) then
        -- Fallback: part name contains "drum"/"percussion"/"kit"
        base_track_name = "Drums"
      end
    end

    -- Skip this part if it wasn't selected in the GUI track list
    if selected_tracks_set and not selected_tracks_set[base_track_name] then
      goto continue_part
    end

    local staff_notes = data.staff_notes
    local staff_texts = data.staff_texts
    local staff_tunings = data.staff_tunings or {}

    local max_staff = 0
    for staff in pairs(staff_notes) do
      if staff > max_staff then max_staff = staff end
    end

    -- When a TAB staff (with tuning info) has notes, skip non-TAB staves
    -- to avoid duplicating the same guitar notes as two tracks.
    local has_tab_staff = false
    for s = 1, max_staff do
      if staff_tunings[s] and staff_notes[s] and #staff_notes[s] > 0 then
        has_tab_staff = true
        break
      end
    end

    local part_bank_inserted = false
    local part_ksig_inserted = false
    for staff = 1, max_staff do
      -- Skip non-TAB staves when a TAB staff with notes exists
      if has_tab_staff and not staff_tunings[staff] then
        goto continue_staff
      end
      local notes = staff_notes[staff]
      if notes and #notes > 0 then
        local track = nil
        local track_name = base_track_name
        if max_staff > 1 then
          track_name = track_name
        end
        
        -- Determine which track to insert on based on mode
        if mode == "new_tracks" then
          -- Create a new track
          local insert_index = initial_track_count + tracks_created
          reaper.InsertTrackAtIndex(insert_index, true)
          track = reaper.GetTrack(0, insert_index)
          tracks_created = tracks_created + 1
          reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
          
        elseif mode == "existing_tracks" then
          -- Try to use existing tracks, starting from the first (or selected) track
          local total_tracks = reaper.CountTracks(0)
          
          if next_existing_track_idx < total_tracks then
            -- Use existing track
            track = reaper.GetTrack(0, next_existing_track_idx)
            next_existing_track_idx = next_existing_track_idx + 1
          else
            -- No more existing tracks, create a new one
            local insert_index = next_existing_track_idx
            reaper.InsertTrackAtIndex(insert_index, true)
            track = reaper.GetTrack(0, insert_index)
            next_existing_track_idx = next_existing_track_idx + 1
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
          end
          
        elseif mode == "tracks_by_name" then
          -- Try to find a track with matching name
          local total_tracks = reaper.CountTracks(0)
          track = nil
          
          for i = 0, total_tracks - 1 do
            local existing_track = reaper.GetTrack(0, i)
            if existing_track then
              local _, existing_name = reaper.GetSetMediaTrackInfo_String(existing_track, "P_NAME", "", false)
              -- Compare names with case sensitivity option
              local names_match = false
              if CASE_INSENSITIVE then
                names_match = (existing_name:lower() == track_name:lower())
              else
                names_match = (existing_name == track_name)
              end
              
              if names_match then
                track = existing_track
                break
              end
            end
          end
          
          -- If no matching track found, create a new one
          if not track then
            reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
            track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
            reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
          end
        end
        
        -- Set ReaTabHero configuration (drum exstate or guitar/bass tuning)
        local tuning = staff_tunings[staff]
        
        -- Check if this is a drum track
        if isDrumTrack(track_name) then
          -- For drum tracks, apply the drum 9-channel exstate
          local drum_exstate = getDrumReaTabHeroState()
          if drum_exstate then
            reaper.GetSetMediaTrackInfo_String(track, "P_EXT:XR_ReaTabHero", drum_exstate, true)
          end
        else
          -- For fretted instruments, apply tuning
          -- If no tuning was parsed from XML, apply default tuning based on track type
          if not tuning then
            if isBassTrack(track_name) then
              -- Apply bass tuning
              if is5StringBassTrack(track_name) then
                tuning = getDefault5StringBassTuning()
              else
                tuning = getDefaultBassTuning()
              end
            else
              -- Apply default guitar tuning
              tuning = getDefaultGuitarTuning()
            end
          end
          
          if tuning then
            local reatabhero_str = tuningToReaTabHeroString(tuning)
            if reatabhero_str then
              reaper.GetSetMediaTrackInfo_String(track, "P_EXT:XR_ReaTabHero", reatabhero_str, true)
            end
          end
        end

        -- Determine if we're in "Adapt to project tempo map" mode (index 5)
        local adapt_to_tempo_map = (import_timebase_index == 5)

        -- Compute item length: for adapt mode, use project tempo map duration
        local item_length = max_seconds
        if adapt_to_tempo_map and max_ticks > 0 then
          local end_proj = ticks_to_project_time(max_ticks, ppq, item_position)
          item_length = end_proj - item_position
          if item_length < 0.001 then item_length = max_seconds end
        end

        -- Create MIDI item, using pre-computed item_position
        local item = reaper.CreateNewMIDIItemInProj(track, item_position, item_position + item_length, false)
        if not item then
          item = reaper.AddMediaItemToTrack(track)
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", item_position)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", item_length)
        end

        -- Apply MIDI timebase setting
        local tb_mode = import_timebase_values[import_timebase_index]
        if tb_mode and tb_mode >= 0 then
          reaper.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", tb_mode)
        end

        local take = reaper.GetActiveTake(item)
        if not take then
          take = reaper.AddTakeToMediaItem(item)
        end

        -- Check if this is a drum track for per-note transient alignment
        local is_drum = isDrumTrack(track_name)
        local has_corrections = is_drum and note_corrections_table and tick_to_score_time

        -- Create nudge take for drum tracks BEFORE inserting notes
        local nudge_take = nil
        if has_corrections then
          nudge_take = reaper.AddTakeToMediaItem(item)
          if nudge_take then
            local old_src = reaper.GetMediaItemTake_Source(nudge_take)
            local src = reaper.GetMediaItemTake_Source(take)
            reaper.SetMediaItemTake_Source(nudge_take, src)
            if old_src then reaper.PCM_Source_Destroy(old_src) end
            reaper.GetSetMediaItemTakeInfo_String(nudge_take, "P_NAME", track_name .. " (nudged)", true)
          end
        end

        -- Take 1: tempo-map only (all tracks get this)
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME",
          has_corrections and (track_name .. " (tempo map)") or track_name, true)
        if adapt_to_tempo_map then
          -- Adapt mode: convert XML ticks → beat offset → project time via project tempo map
          for _, n in ipairs(notes) do
            local start_proj = ticks_to_project_time(n.pos, ppq, item_position)
            local end_proj = ticks_to_project_time(n.endpos, ppq, item_position)
            local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, start_proj)
            local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(take, end_proj)
            reaper.MIDI_InsertNote(take, false, false, ppq_start, ppq_end, n.channel, n.pitch, n.vel, false)
          end
        else
          -- Standard mode: convert XML ticks → seconds (using XML tempo) → project time
          for _, n in ipairs(notes) do
            local start_sec = ticks_to_seconds(n.pos, tempo_map, ppq)
            local end_sec = ticks_to_seconds(n.endpos, tempo_map, ppq)
            local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, item_position + start_sec)
            local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(take, item_position + end_sec)
            reaper.MIDI_InsertNote(take, false, false, ppq_start, ppq_end, n.channel, n.pitch, n.vel, false)
          end
        end

        -- Nudge take (drums only): read notes from Take 1, nudge to transients.
        -- Take 1 has all notes correctly placed by the tempo map.
        -- The nudge take snaps each onset to the nearest stretch marker
        -- so within-bar beats align to the original drum recording.
        if nudge_take then
          -- Write stretch markers on drum audio item
          local sm_positions_project = {}
          if drum_aud_item and drum_transients and #drum_transients > 0 then
            local drum_audio_take = reaper.GetActiveTake(drum_aud_item)
            if drum_audio_take then
              local existing = reaper.GetTakeNumStretchMarkers(drum_audio_take)
              for si = existing - 1, 0, -1 do
                reaper.DeleteTakeStretchMarkers(drum_audio_take, si)
              end
              for _, tr in ipairs(drum_transients) do
                reaper.SetTakeStretchMarker(drum_audio_take, -1, tr.src)
                sm_positions_project[#sm_positions_project + 1] = tr.proj
              end
              reaper.UpdateItemInProject(drum_aud_item)
              import_log(string.format(
                "Wrote %d stretch markers on drum audio", #sm_positions_project))
            end
          end

          -- Read all notes from Take 1
          local DRUM_NOTE_LEN = 0.010  -- 10ms fixed note length
          local _, take1_count = reaper.MIDI_CountEvts(take)
          local take1_notes = {}
          for i = 0, take1_count - 1 do
            local ret, sel, muted, startppq, endppq, chan, pitch, vel =
              reaper.MIDI_GetNote(take, i)
            if ret then
              take1_notes[#take1_notes + 1] = {
                proj_time = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq),
                startppq = startppq,
                sel = sel, muted = muted,
                chan = chan, pitch = pitch, vel = vel,
              }
            end
          end

          if #sm_positions_project > 0 and #take1_notes > 0 then
            -- Insert nudged notes with short duration
            reaper.MIDI_DisableSort(nudge_take)
            local nudge_count = 0
            for _, tn in ipairs(take1_notes) do
              -- Binary search for closest transient
              local lo, hi = 1, #sm_positions_project
              while lo < hi do
                local mid = math.floor((lo + hi) / 2)
                if sm_positions_project[mid] < tn.proj_time then lo = mid + 1 else hi = mid end
              end
              local best_d = math.huge
              local best_proj = tn.proj_time
              for ci = lo - 1, lo + 1 do
                if ci >= 1 and ci <= #sm_positions_project then
                  local d = math.abs(sm_positions_project[ci] - tn.proj_time)
                  if d < best_d then
                    best_d = d
                    best_proj = sm_positions_project[ci]
                  end
                end
              end
              if best_proj ~= tn.proj_time then nudge_count = nudge_count + 1 end

              local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, best_proj)
              local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, best_proj + DRUM_NOTE_LEN)
              if ppq_end <= ppq_start then ppq_end = ppq_start + 10 end
              reaper.MIDI_InsertNote(nudge_take, tn.sel, tn.muted,
                ppq_start, ppq_end, tn.chan, tn.pitch, tn.vel, true)
            end
            reaper.MIDI_Sort(nudge_take)

            -- Verify note count; re-insert any missing notes at original positions
            local _, nudge_count_check = reaper.MIDI_CountEvts(nudge_take)
            if nudge_count_check < #take1_notes then
              local missing = #take1_notes - nudge_count_check
              import_log(string.format(
                "Drum '%s': %d notes re-inserted at original positions",
                track_name, missing))
              -- Build set of (ppq_start, pitch) present in nudge take
              local present = {}
              for i = 0, nudge_count_check - 1 do
                local ret2, _, _, sppq, _, _, p = reaper.MIDI_GetNote(nudge_take, i)
                if ret2 then
                  present[string.format("%d_%d", math.floor(sppq + 0.5), p)] = true
                end
              end
              -- Re-insert missing notes from Take 1 at their original (un-nudged) positions
              reaper.MIDI_DisableSort(nudge_take)
              for _, tn in ipairs(take1_notes) do
                local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, tn.proj_time)
                local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, tn.proj_time + DRUM_NOTE_LEN)
                if ppq_end <= ppq_start then ppq_end = ppq_start + 10 end
                local key = string.format("%d_%d", math.floor(ppq_start + 0.5), tn.pitch)
                -- Check if any note with this pitch is near this position
                local found = false
                for delta = -5, 5 do
                  if present[string.format("%d_%d", math.floor(ppq_start + 0.5) + delta, tn.pitch)] then
                    found = true
                    break
                  end
                end
                if not found then
                  reaper.MIDI_InsertNote(nudge_take, tn.sel, tn.muted,
                    ppq_start, ppq_end, tn.chan, tn.pitch, tn.vel, true)
                end
              end
              reaper.MIDI_Sort(nudge_take)
            end

            local _, final_count = reaper.MIDI_CountEvts(nudge_take)
            reaper.SetActiveTake(nudge_take)
            import_log(string.format(
              "Drum '%s': %d/%d notes nudged to transients",
              track_name, nudge_count, #take1_notes))
          else
            -- No transients: copy Take 1 notes with short duration
            for _, tn in ipairs(take1_notes) do
              local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, tn.proj_time)
              local ppq_end = reaper.MIDI_GetPPQPosFromProjTime(nudge_take, tn.proj_time + DRUM_NOTE_LEN)
              if ppq_end <= ppq_start then ppq_end = ppq_start + 10 end
              reaper.MIDI_InsertNote(nudge_take, false, false,
                ppq_start, ppq_end, tn.chan, tn.pitch, tn.vel, true)
            end
            reaper.MIDI_Sort(nudge_take)
            reaper.SetActiveTake(nudge_take)
            import_log(string.format(
              "Drum '%s': no transients, copied %d notes",
              track_name, #take1_notes))
          end
        end

        -- Insert text events (convert beat-ticks to time-accurate REAPER PPQ)
        if staff_texts[staff] then
          for _, t in ipairs(staff_texts[staff]) do
            local t_proj
            if adapt_to_tempo_map then
              t_proj = ticks_to_project_time(t.pos, ppq, item_position)
            else
              t_proj = item_position + ticks_to_seconds(t.pos, tempo_map, ppq)
            end
            local ppq_pos = reaper.MIDI_GetPPQPosFromProjTime(take, t_proj)
            reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq_pos, t.type, t.text)
          end
        end

        -- Store tick-based remap data on the take for future tempo remap
        store_remap_data(take, notes, staff_texts[staff], ppq)

        -- Insert MIDI bank/program change from MusicXML (once per part, on first staff with notes)
        local mp = part_midi_program[part_id]
        if options.import_midi_banks and mp and not part_bank_inserted then
          part_bank_inserted = true
          local ch = mp.channel
          -- Bank Select MSB (CC 0)
          reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 0, math.floor((mp.bank - 1) / 128))
          -- Bank Select LSB (CC 32)
          reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 32, (mp.bank - 1) % 128)
          -- Program Change
          reaper.MIDI_InsertCC(take, false, false, 0, 0xC0, ch, mp.program, 0)
        end

        -- Insert key signature notation event (once per part, on first staff with notes)
        local ks = part_key_sig[part_id]
        if import_key_sigs and ks and not part_ksig_inserted then
          part_ksig_inserted = true
          local root_map = (ks.mode == "minor") and keysig_fifths_to_root_minor or keysig_fifths_to_root_major
          local root = root_map[ks.fifths]
          if root then
            local notes_hex = (ks.mode == "minor") and KEYSIG_MINOR_HEX or KEYSIG_MAJOR_HEX
            local evt_str = string.format("KSIG root %d dir -1 notes 0x%03X", root, notes_hex)
            local packed = string.pack("BB", 0xFF, 0x0F) .. evt_str
            reaper.MIDI_InsertEvt(take, false, false, 0, packed)
          end
        end

        reaper.MIDI_Sort(take)
      end
      ::continue_staff::
    end
    ::continue_part::
    end
  end

  reaper.UpdateArrange()
  
  if import_progress.active then
    import_log(string.format("Imported %d tracks from %s",
      tracks_created, (filepath:match("[^\\/]+$") or filepath)))
    update_import_progress(0.95, "Finalizing...")
  end

  -- End undo block
  reaper.Undo_EndBlock("Import MusicXML", -1)
end

-- Main() will be called by GUI when user clicks Import
-- (commented out to allow GUI interaction first)
-- Main()

-- Chord Toolbar with Checkboxes (borderless GUI) - Modular Version

-- Script title global
SCRIPT_TITLE = "Import MusicXML"

-- GUI configuration
gui = {
    width = 600,
    height = 250,
    settings = {
        docker_id = 0,                  -- no docking, borderless only
        font_size = 24,
        Borderless_Window = true        -- use JS_Window_SetStyle for borderless
    },
    colors = {
        BG              = {0.1, 0.1, 0.1, 1.0},
        BORDER          = {0.25, 0.25, 0.25, 1},
        HEADER_BG       = {0.15, 0.15, 0.15, 1},
        CHECKBOX_BG     = {0.2, 0.2, 0.2, 1},
        CHECKBOX_BG_HOVER = {0.17, 0.45, 0.39, 1},
        CHECKBOX_BORDER = {0.3, 0.3, 0.3, 1},
        CHECKBOX_INNER_BORDER = {0.3, 0.3, 0.3, 1},
        TEXT            = {1, 1, 1, 1},
        CHECKMARK       = {1, 1, 1, 1},
        FILE_INFO_BG     = {0.17, 0.17, 0.17, 1},
        CLOSE_BTN       = {0.2, 0.2, 0.2, 1},
        CLOSE_BTN_HOVER = {0.58, 0.25, 0.25, 1},
        IMPORT_BTN      = {0.2, 0.2, 0.2, 1},
        IMPORT_BTN_HOVER = {0.17, 0.45, 0.39, 1},
        BTN             = {0.2, 0.2, 0.2, 1},
        BTN_HOVER       = {0.17, 0.45, 0.39, 1},
    }
}

-- Global variables to store selected file info
selected_file_path = nil
selected_file_name = nil
selected_file_track_count = nil
last_import_dir = nil  -- Store the last imported file directory
default_import_dir = ""  -- Default directory for file explorer when no last path exists
path_mode = "last"  -- "default" = use default_import_dir, "last" = use last_import_dir
track_checkboxes = {}  -- Dynamic list: { {name="...", checked=true, part_id="..."}, ... }
import_all_checked = true  -- "Import All" master checkbox state
track_scroll_offset = 0  -- Scroll offset (in rows) for the track list
main_scroll_offset = 0     -- Scroll offset (in rows) for main settings area
scrollbar_dragging = false  -- Whether we're dragging the scrollbar
settings_mode = false  -- Whether the settings view is active
settings_scroll_offset = 0  -- Scroll offset for settings view (pixels)
settings_sb_dragging = false  -- Whether we're dragging the settings scrollbar thumb
settings_sb_drag_start_y = 0  -- Mouse Y when drag started
settings_sb_drag_start_offset = 0  -- settings_scroll_offset when drag started
auto_focus_enabled = true  -- Whether to auto-focus window on mouse hover
stay_on_top_enabled = false  -- Whether to keep the window always on top
font_list = {"Outfit", "Arial", "Segoe UI", "Tahoma", "Verdana", "Consolas", "Courier New", "Times New Roman", "Georgia", "Trebuchet MS", "Calibri", "Helvetica"}
current_font_index = 1  -- Index into font_list (default: Outfit)
docker_enabled = false  -- Whether to dock on startup
docker_position = 1  -- 1=Bottom, 2=Left, 3=Top, 4=Right
remember_window_size = false  -- Whether to save/restore window size across launches
docker_positions = {"Bottom", "Left", "Top", "Right"}
docker_dock_values = {769, 257, 513, 1}  -- gfx.dock values for each position
settings_btn_hovered = false  -- Hover state for settings button in main view
export_btn_hovered = false  -- Hover state for export button in main view
undo_btn_hovered = false  -- Hover state for undo button in main view
remap_btn_hovered = false  -- Hover state for remap button in main view
remap_confirmed_until = 0  -- os.clock() time until which "Remapped!" label is shown
nudge_btn_hovered = false  -- Hover state for nudge button in main view
nudge_confirmed_until = 0  -- os.clock() time until which "Nudged!" label is shown
export_confirmed_until = 0   -- os.clock() time until which "Exported!" label is shown
del_tempo_btn_hovered = false  -- Hover state for Delete Tempo Markers button
del_tempo_confirmed_until = 0  -- os.clock() time until which "Deleted!" label is shown
del_sm_btn_hovered = false  -- Hover state for Remove Stretch Markers button
del_sm_confirmed_until = 0  -- os.clock() time until which "Removed!" label is shown
detect_transients_confirmed_until = 0  -- "Detected!" label timer for Detect Transients button

-- Nudge SM slider state (moves nearest stretch marker to edit cursor)
sm_nudge_value = 0           -- current nudge delta in ms (±500)
sm_nudge_slider_dragging = false
sm_nudge_drag_start_x = 0
sm_nudge_drag_start_val = 0
sm_nudge_item = nil          -- item locked at drag start
sm_nudge_take = nil
sm_nudge_idx = -1            -- SM index at drag start (0-based)
sm_nudge_orig_src = 0        -- original take-time position (fixed during offset drag)
sm_nudge_orig_srcpos = 0     -- original source media position (varies during offset drag)
sm_nudge_undo_open = false

-- Nudge Tempo slider state (moves nearest tempo marker to edit cursor)
tempo_nudge_value = 0        -- current nudge delta in ms (±500)
tempo_nudge_slider_dragging = false
tempo_nudge_drag_start_x = 0
tempo_nudge_drag_start_val = 0
tempo_nudge_idx = -1         -- tempo marker index at drag start (0-based)
tempo_nudge_orig_t = 0       -- original project time at drag start
tempo_nudge_orig_bpm = 120
tempo_nudge_orig_tsn = 4
tempo_nudge_orig_tsd = 4
tempo_nudge_orig_lin = false
tempo_nudge_undo_open = false
tempo_nudge_prev_idx = -1        -- index of the tempo marker immediately before the nudged one
tempo_nudge_prev_t = 0           -- original time of that previous marker
tempo_nudge_prev_bpm = 120       -- original BPM of that previous marker
tempo_nudge_prev_tsn = 4
tempo_nudge_prev_tsd = 4
tempo_nudge_prev_lin = false

-- Snap toggle states for nudge sliders
sm_snap_to_grid_enabled = false    -- when ON, SM nudge slider snaps SM to grid
tempo_snap_to_sm_enabled = false   -- when ON, tempo nudge slider snaps incrementally to stretch markers
midi_sm_enabled = false            -- when ON, take markers on MIDI items act as pseudo-stretch markers
midi_sm_state  = {}                -- [tostring(take)] = {item, take, item_pos, markers=[{orig_s, last_s},...]}

-- MIDI Take Marker move slider (moves nearest rated take marker, no note stretch)
midi_tm_move_value = 0
midi_tm_move_dragging = false
midi_tm_move_drag_start_x = 0
midi_tm_move_drag_start_val = 0
midi_tm_move_item = nil
midi_tm_move_take = nil
midi_tm_move_mi = -1
midi_tm_move_orig_s = 0
midi_tm_move_undo_open = false

-- MIDI Take Marker stretch slider (moves nearest rated take marker AND stretches notes)
midi_tm_stretch_value = 0
midi_tm_stretch_dragging = false
midi_tm_stretch_drag_start_x = 0
midi_tm_stretch_drag_start_val = 0
midi_tm_stretch_item = nil
midi_tm_stretch_take = nil
midi_tm_stretch_mi = -1
midi_tm_stretch_orig_s = 0
midi_tm_stretch_last_s = 0      -- last applied srcpos (kept for compatibility, not used in absolute mode)
midi_tm_stretch_undo_open = false
-- Absolute-stretch cache: populated at drag start, cleared on release
midi_tm_stretch_note_cache = {}  -- kept for compatibility (no longer used in warp)
midi_tm_stretch_prev_ppq  = 0
midi_tm_stretch_next_ppq  = 0
midi_tm_stretch_orig_ppq  = 0

-- MIDI TM snap + beat-based slider globals
midi_tm_snap_enabled = false            -- when true, sliders snap to project grid
midi_tm_autosnap_note_enabled = false   -- when true, auto-snap TM to closest note edge after every move
midi_tm_snap_to_note_confirmed_until = 0 -- timer for "Snapped!" button confirmation
midi_tm_move_beat_dur    = 0.5          -- beat duration at drag start (±2 beats range)
midi_tm_stretch_beat_dur = 0.5          -- beat duration for Warp TM slider
midi_tm_stretch_display_str = "1.00x"   -- rate label shown on Warp TM slider
midi_tm_reset_confirmed_until = 0       -- timer for "Reset!" button confirmation

-- Insert at Mouse script settings (written to ExtState "konst_InsertAtMouse")
iam_enable_stretch  = true   -- toggle stretch markers on audio items
iam_enable_take_tm  = true   -- toggle 1.00x take markers on MIDI items
iam_enable_tempo    = true   -- toggle tempo markers on ruler / empty arrange

pre_settings_width = nil  -- Window width before entering settings mode
pre_settings_height = nil -- Window height before entering settings mode
articulations_in_file = {}  -- Set of articulation names found in the selected file's checked tracks

-- Text selection state
text_sel = {
    active = false,        -- whether a selection drag is in progress
    element_id = nil,      -- id of the selected text element
    start_char = 0,        -- character index where selection started
    end_char = 0,          -- current character index of selection end
    display_text = "",     -- displayed text of the element
    full_text = "",        -- original (non-truncated) text for clipboard
    text_x = 0,            -- x position of the text element
}
text_elements_frame = {} -- rebuilt each frame for hit testing
file_info_click_pending = false  -- track file info click for drag detection
file_info_click_x = 0  -- mouse x when file info was clicked
file_info_click_y = 0  -- mouse y when file info was clicked
text_sel_mouse_start_x = 0  -- mouse x at selection start
text_sel_mouse_start_y = 0  -- mouse y at selection start
DRAG_THRESHOLD = 3  -- minimum pixels to distinguish drag from click
pending_tooltip = nil  -- tooltip text to draw at end of frame (set during draw functions)

-- ============================================================================
-- IMPORT PROGRESS BAR
-- ============================================================================
import_progress = {
    active = false,       -- whether import is in progress
    pct = 0,              -- 0.0 to 1.0
    status = "",          -- current status text
    start_time = 0,       -- reaper.time_precise() at start
    end_time = 0,         -- reaper.time_precise() when done
    log = {},             -- log messages collected during import
    done = false,         -- import finished, showing results
}

function draw_import_progress()
    if not import_progress.active then return end
    -- Full-window dim
    gfx.set(0, 0, 0, 0.7)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    local pad = 16
    local card_w = math.max(300, math.floor(gfx.w * 0.7))

    -- Compute card height based on state
    local card_h
    if import_progress.done then
        local log_lines = math.min(#import_progress.log, 8)
        local extra = (#import_progress.log > 8) and 1 or 0
        -- title + spacing + log lines + overflow + spacing + button row
        card_h = pad + gfx.texth + 10 + (log_lines + extra) * gfx.texth + 12 + 26 + pad
        card_h = math.max(card_h, 120)
    else
        card_h = 140
    end

    local card_x = math.floor((gfx.w - card_w) / 2)
    local card_y = math.floor((gfx.h - card_h) / 2)

    -- Card background
    gfx.set(0.13, 0.13, 0.13, 1)
    gfx.rect(card_x, card_y, card_w, card_h, 1)
    gfx.set(0.35, 0.35, 0.40, 1)
    gfx.rect(card_x, card_y, card_w, card_h, 0)

    local inner_w = card_w - pad * 2

    -- Title
    gfx.set(0.17, 0.45, 0.39, 1)
    local title = import_progress.done and "Import Complete" or "Importing MusicXML..."
    local tw = gfx.measurestr(title)
    gfx.x = card_x + math.floor((card_w - tw) / 2)
    gfx.y = card_y + pad
    gfx.drawstr(title)

    if import_progress.done then
        -- Show log messages
        gfx.set(0.85, 0.85, 0.85, 1)
        local log_y = card_y + pad + gfx.texth + 10
        local max_lines = 8
        for i = 1, math.min(#import_progress.log, max_lines) do
            local msg = import_progress.log[i]
            local disp = msg
            local msg_w = gfx.measurestr(msg)
            if msg_w > inner_w then
                while gfx.measurestr(disp .. "...") > inner_w and #disp > 1 do
                    disp = disp:sub(1, -2)
                end
                disp = disp .. "..."
            end
            gfx.x = card_x + pad
            gfx.y = log_y + (i - 1) * gfx.texth
            gfx.drawstr(disp)
        end
        if #import_progress.log > max_lines then
            gfx.set(0.5, 0.5, 0.5, 1)
            gfx.x = card_x + pad
            gfx.y = log_y + max_lines * gfx.texth
            gfx.drawstr(string.format("(+%d more)", #import_progress.log - max_lines))
        end

        -- Elapsed time (frozen at completion)
        local elapsed = import_progress.end_time - import_progress.start_time
        gfx.set(0.5, 0.5, 0.5, 1)
        local time_str = string.format("Completed in %.1fs", elapsed)
        local time_w = gfx.measurestr(time_str)
        gfx.x = card_x + card_w - pad - time_w
        gfx.y = card_y + card_h - pad - gfx.texth
        gfx.drawstr(time_str)

        -- OK button
        local btn_w = 80
        local btn_h = 26
        local btn_x = card_x + pad
        local btn_y = card_y + card_h - pad - btn_h
        local mx, my = gfx.mouse_x, gfx.mouse_y
        local hov = mx >= btn_x and mx < btn_x + btn_w and my >= btn_y and my < btn_y + btn_h
        gfx.set(table.unpack(hov and {0.17, 0.45, 0.39, 1} or {0.2, 0.2, 0.2, 1}))
        gfx.rect(btn_x, btn_y, btn_w, btn_h, 1)
        gfx.set(0.35, 0.35, 0.40, 1)
        gfx.rect(btn_x, btn_y, btn_w, btn_h, 0)
        gfx.set(1, 1, 1, 1)
        local ok_w = gfx.measurestr("OK")
        gfx.x = btn_x + math.floor((btn_w - ok_w) / 2)
        gfx.y = btn_y + math.floor((btn_h - gfx.texth) / 2)
        gfx.drawstr("OK")
    else
        -- Progress bar
        local bar_w = inner_w
        local bar_h = 22
        local bar_x = card_x + pad
        local bar_y = card_y + pad + gfx.texth + 14

        -- Track
        gfx.set(0.2, 0.2, 0.22, 1)
        gfx.rect(bar_x, bar_y, bar_w, bar_h, 1)
        -- Fill
        gfx.set(0.17, 0.55, 0.46, 1)
        gfx.rect(bar_x, bar_y, math.floor(bar_w * import_progress.pct), bar_h, 1)
        -- Border
        gfx.set(0.35, 0.35, 0.40, 1)
        gfx.rect(bar_x, bar_y, bar_w, bar_h, 0)

        -- Percentage centered on bar
        gfx.set(1, 1, 1, 1)
        local pct_str = string.format("%d%%", math.floor(import_progress.pct * 100))
        local pw = gfx.measurestr(pct_str)
        gfx.x = bar_x + math.floor((bar_w - pw) / 2)
        gfx.y = bar_y + math.floor((bar_h - gfx.texth) / 2)
        gfx.drawstr(pct_str)

        -- Status text
        gfx.set(0.85, 0.85, 0.85, 1)
        local sw = gfx.measurestr(import_progress.status)
        gfx.x = bar_x + math.floor((bar_w - sw) / 2)
        gfx.y = bar_y + bar_h + 8
        gfx.drawstr(import_progress.status)

        -- Elapsed / ETA
        local elapsed = reaper.time_precise() - import_progress.start_time
        local eta = import_progress.pct > 0 and (elapsed / import_progress.pct * (1 - import_progress.pct)) or 0
        gfx.set(0.5, 0.5, 0.5, 1)
        local time_str = string.format("Elapsed: %.1fs   Remaining: ~%.1fs", elapsed, eta)
        local tw2 = gfx.measurestr(time_str)
        gfx.x = bar_x + math.floor((bar_w - tw2) / 2)
        gfx.y = bar_y + bar_h + 8 + gfx.texth + 4
        gfx.drawstr(time_str)
    end
end

function update_import_progress(pct, status)
    import_progress.pct = pct
    if status then import_progress.status = status end
    -- Clear entire window then draw overlay so it renders during sync import
    gfx.set(0.118, 0.118, 0.118, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    draw_import_progress()
    gfx.update()
end

function import_log(msg)
    table.insert(import_progress.log, msg)
end

-- ============================================================================
-- PATH PERSISTENCE FUNCTIONS
-- ============================================================================
function save_last_import_path(filepath)
    if filepath and filepath ~= "" then
        -- Extract directory and normalize separators
        local dir = filepath:gsub("\\", "/")  -- Convert all backslashes to forward slashes
        dir = dir:match("^(.+)/") or ""  -- Extract everything before the last slash
        if dir ~= "" then
            -- Append trailing slash for consistent behavior with GetUserFileNameForRead
            if not dir:match("/$") then
                dir = dir .. "/"
            end
            reaper.SetExtState("konst_ImportMusicXML", "last_import_dir", dir, true)
        end
    end
end

function load_last_import_path()
    local saved_dir = reaper.GetExtState("konst_ImportMusicXML", "last_import_dir")
    if saved_dir and saved_dir ~= "" then
        return saved_dir
    end
    return ""
end

function save_default_import_dir(dir)
    if dir then
        reaper.SetExtState("konst_ImportMusicXML", "default_import_dir", dir, true)
    end
end

function load_default_import_dir()
    local saved = reaper.GetExtState("konst_ImportMusicXML", "default_import_dir")
    if saved and saved ~= "" then
        return saved
    end
    return ""
end

function save_path_mode(mode)
    if mode then
        reaper.SetExtState("konst_ImportMusicXML", "path_mode", mode, true)
    end
end

function load_path_mode()
    local saved = reaper.GetExtState("konst_ImportMusicXML", "path_mode")
    if saved == "default" or saved == "last" then
        return saved
    end
    return "last"
end

-- ============================================================================
-- AUTO-LOAD BY REGION
-- ============================================================================
-- Track the last auto-loaded region name so we don't re-trigger on the same region
autoload_last_region_name = nil
-- When auto-load triggers, store the matched region's start position for import
autoload_region_start_pos = nil

-- Normalize a string for fuzzy matching: lowercase, strip non-alphanumeric, collapse spaces
function normalize_for_match(s)
    if not s then return "" end
    s = s:lower()
    -- Replace dashes, underscores, dots with spaces
    s = s:gsub("[%-%_%.]", " ")
    -- Remove non-alphanumeric except spaces
    s = s:gsub("[^%w%s]", "")
    -- Collapse whitespace
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or ""
    return s
end

-- Find region at the edit cursor position. Returns region name and start position, or nil.
function get_region_at_cursor()
    local cursor = reaper.GetCursorPosition()
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    for i = 0, num_markers + num_regions - 1 do
        local _, is_rgn, pos, rgnend, name = reaper.EnumProjectMarkers(i)
        if is_rgn and cursor >= pos and cursor < rgnend then
            return name, pos
        end
    end
    return nil, nil
end

-- Search the import directory for an XML file whose name contains the region name.
-- Returns the full path of the best match, or nil.
function find_xml_for_region(region_name)
    if not region_name or region_name == "" then return nil end
    local dir = ""
    if path_mode == "default" and default_import_dir ~= "" then
        dir = default_import_dir
    elseif last_import_dir and last_import_dir ~= "" then
        dir = last_import_dir
    else
        dir = load_last_import_path()
    end
    if dir == "" then return nil end

    -- Normalize region name for matching
    local norm_region = normalize_for_match(region_name)
    if norm_region == "" then return nil end

    -- List XML files in the directory
    local i = 0
    local best_path = nil
    local best_len = math.huge
    while true do
        local filename = reaper.EnumerateFiles(dir, i)
        if not filename then break end
        i = i + 1
        if filename:lower():match("%.xml$") then
            -- Normalize the filename (without extension) for comparison
            local basename = filename:match("^(.+)%.[^%.]+$") or filename
            local norm_file = normalize_for_match(basename)
            -- Check if the normalized file name contains the normalized region name
            if norm_file:find(norm_region, 1, true) then
                -- Prefer shorter filenames (closer match) 
                if #filename < best_len then
                    best_len = #filename
                    -- Build full path
                    local sep = dir:match("[/\\]$") and "" or "/"
                    best_path = dir .. sep .. filename
                end
            end
        end
    end
    return best_path
end

-- Attempt auto-load if conditions are met. Called from main_loop.
-- Returns true if a file was auto-loaded.
function try_autoload_by_region()
    if not autoload_by_region_enabled then return false end

    local region_name, region_pos = get_region_at_cursor()
    if not region_name or region_name == "" then
        autoload_last_region_name = nil
        autoload_region_start_pos = nil
        return false
    end

    -- Don't re-trigger if we already loaded for this region
    if region_name == autoload_last_region_name then return false end

    local filepath = find_xml_for_region(region_name)
    if not filepath then return false end

    -- Store the matched region's start position so import uses it directly
    autoload_region_start_pos = region_pos

    -- Auto-load the file (same logic as drag-and-drop / file dialog)
    selected_file_path = filepath
    selected_file_name = get_filename_from_path(filepath)
    save_last_import_path(filepath)
    last_import_dir = load_last_import_path()
    local f = io.open(filepath, "r")
    if f then
        local content = f:read("*all")
        f:close()
        local track_names = get_tracks_from_xml(content)
        selected_file_track_count = #track_names
        track_checkboxes = {}
        for _, t in ipairs(track_names) do
            table.insert(track_checkboxes, {name = t.name, gm_name = t.gm_name, checked = true})
        end
        import_all_checked = true
    else
        selected_file_track_count = 0
        track_checkboxes = {}
    end
    resize_window()
    if highlight_scan_enabled then scan_articulations_in_xml() end
    autoload_last_region_name = region_name
    return true
end

-- Checkbox items (add your items here)
checkboxes_list = {
    {name = "Import tempo and time signature", checked = true, show_in_menu = true, tip = "Import tempo markers and time signatures\nfrom the MusicXML file into the project."},
    {name = "Import segments as regions", checked = true, show_in_menu = true, tip = "Import rehearsal marks (segments) from the\nMusicXML file as REAPER project regions."},
    {name = "Import MIDI program banks", checked = true, show_in_menu = true, tip = "Import MIDI bank/program change info\nfrom the MusicXML file into MIDI items."},
    {name = "Import key signatures", checked = true, show_in_menu = true, tip = "Import key signatures from the MusicXML file.\nAlso writes a KSIG notation event."},
    {name = "Insert items on new tracks", checked = false, show_in_menu = true, tip = "Create new tracks for each imported\npart, even if matching tracks exist."},
    {name = "Insert items on existing tracks", checked = false, show_in_menu = true, tip = "Place imported MIDI items on existing\ntracks that match the part name."},
    {name = "Insert items on tracks by name", checked = true, show_in_menu = true, tip = "Match imported parts to existing tracks\nby comparing part names to track names."},
    {name = "Align drum MIDI to transients", checked = false, show_in_menu = false, tip = "Nudge individual drum notes to the nearest\naudio transient during import."},
}

-- Save/Load import checkbox settings (checked state + show_in_menu flags)
EXTSTATE_IMPORT_KEY = "import_settings"
function save_import_settings()
    local parts = {}
    for _, cb in ipairs(checkboxes_list) do
        table.insert(parts, (cb.checked and "1" or "0") .. "," .. (cb.show_in_menu and "1" or "0"))
    end
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_IMPORT_KEY, table.concat(parts, ";"), true)
end
function load_import_settings()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_IMPORT_KEY)
    if not saved or saved == "" then return end
    -- Count saved entries; if mismatch with current list, discard stale settings
    local count = 0
    for _ in saved:gmatch("[^;]+") do count = count + 1 end
    if count ~= #checkboxes_list then
        save_import_settings()
        return
    end
    local idx = 1
    for entry in saved:gmatch("[^;]+") do
        if idx <= #checkboxes_list then
            local checked, menu = entry:match("([01]),([01])")
            if checked then checkboxes_list[idx].checked = (checked == "1") end
            if menu then checkboxes_list[idx].show_in_menu = (menu == "1") end
        end
        idx = idx + 1
    end
end
load_import_settings()

-- Save/Load window position
EXTSTATE_WINPOS_KEY = "window_position"
EXTSTATE_WINPOS_MODE_KEY = "window_position_mode"
window_position_mode = "mouse"  -- "last" or "mouse"
function save_window_position()
    local dock, wx, wy = gfx.dock(-1, 0, 0, 0, 0)
    if dock == 0 then  -- only save when not docked
        reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_KEY, tostring(math.floor(wx)) .. "," .. tostring(math.floor(wy)), true)
    end
end
function load_window_position()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_KEY)
    if not saved or saved == "" then return nil, nil end
    local sx, sy = saved:match("(%-?%d+),(%-?%d+)")
    if sx and sy then return tonumber(sx), tonumber(sy) end
    return nil, nil
end
function save_window_position_mode(mode)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_MODE_KEY, mode, true)
end
function load_window_position_mode()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_MODE_KEY)
    if saved == "last" or saved == "mouse" then return saved end
    return "mouse"
end
window_position_mode = load_window_position_mode()

-- Save/Load remember window size setting
EXTSTATE_WINSIZE_KEY = "remember_window_size"
EXTSTATE_WINSIZE_MAIN_KEY = "window_size_main"
EXTSTATE_WINSIZE_SETTINGS_KEY = "window_size_settings"
function save_remember_window_size_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_WINSIZE_KEY, remember_window_size and "1" or "0", true)
end
function load_remember_window_size_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_WINSIZE_KEY)
    if val == "1" then remember_window_size = true end
end
function save_window_size(tab)
    if remember_window_size then
        local dock = gfx.dock(-1, 0, 0, 0, 0)
        if dock == 0 then
            local key = (tab == "settings") and EXTSTATE_WINSIZE_SETTINGS_KEY or EXTSTATE_WINSIZE_MAIN_KEY
            reaper.SetExtState(EXTSTATE_SECTION, key, tostring(math.floor(gfx.w)) .. "," .. tostring(math.floor(gfx.h)), true)
        end
    end
end
function load_window_size(tab)
    local key = (tab == "settings") and EXTSTATE_WINSIZE_SETTINGS_KEY or EXTSTATE_WINSIZE_MAIN_KEY
    local saved = reaper.GetExtState(EXTSTATE_SECTION, key)
    if not saved or saved == "" then return nil, nil end
    local sw, sh = saved:match("(%d+),(%d+)")
    if sw and sh then return tonumber(sw), tonumber(sh) end
    return nil, nil
end
load_remember_window_size_setting()

-- Save/Load auto-focus setting
EXTSTATE_AUTOFOCUS_KEY = "auto_focus"
function save_auto_focus_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_AUTOFOCUS_KEY, auto_focus_enabled and "1" or "0", true)
end
function load_auto_focus_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_AUTOFOCUS_KEY)
    if val == "0" then auto_focus_enabled = false end
end
load_auto_focus_setting()

-- Save/Load/Apply stay-on-top setting
EXTSTATE_STAYONTOP_KEY = "stay_on_top"
function apply_stay_on_top()
    if window_script then
        if stay_on_top_enabled then
            reaper.JS_Window_SetZOrder(window_script, "TOPMOST")
        else
            reaper.JS_Window_SetZOrder(window_script, "NOTOPMOST")
        end
    end
end
function save_stay_on_top_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_STAYONTOP_KEY, stay_on_top_enabled and "1" or "0", true)
end
function load_stay_on_top_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_STAYONTOP_KEY)
    if val == "1" then stay_on_top_enabled = true end
end
load_stay_on_top_setting()

-- Save/Load export open-with setting
EXTSTATE_OPENWITH_KEY = "export_open_with"
EXTSTATE_OPENWITH_PATH_KEY = "export_open_with_path"
function save_open_with_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_KEY, export_open_with_enabled and "1" or "0", true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_PATH_KEY, export_open_with_path, true)
end
function load_open_with_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_KEY)
    if val == "1" then export_open_with_enabled = true end
    local path = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_PATH_KEY)
    if path and path ~= "" then export_open_with_path = path end
end
load_open_with_setting()

-- Save/Load export open-folder setting
EXTSTATE_OPENFOLDER_KEY = "export_open_folder"
function save_open_folder_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_OPENFOLDER_KEY, export_open_folder_enabled and "1" or "0", true)
end
function load_open_folder_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_OPENFOLDER_KEY)
    if val == "1" then export_open_folder_enabled = true end
end
load_open_folder_setting()

-- Save/Load export key signature setting
EXTSTATE_KEYSIG_KEY = "export_key_sig"
function save_key_sig_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEYSIG_KEY, export_key_sig_enabled and "1" or "0", true)
end
function load_key_sig_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEYSIG_KEY)
    if val == "0" then export_key_sig_enabled = false end
end
load_key_sig_setting()

-- Custom GUI message box state (replaces reaper.ShowMessageBox to avoid z-order issues)
gui_msgbox = {
    active = false,
    title = "",
    message = "",
    ok_hovered = false,
    skip_frame = false,
}

function safe_msgbox(msg, title, typ)
    gui_msgbox.active = true
    gui_msgbox.title = title or ""
    gui_msgbox.message = msg or ""
    gui_msgbox.ok_hovered = false
    gui_msgbox.skip_frame = true  -- ignore input on the frame that opened the msgbox
end

function draw_and_handle_gui_msgbox(mouse_x, mouse_y, mouse_clicked, char_input)
    if not gui_msgbox.active then return false end

    -- Semi-transparent backdrop
    gfx.set(0, 0, 0, 0.55)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)

    -- Box dimensions
    local pad = 20
    local btn_w, btn_h = 80, 30
    local min_box_w = 280
    local max_box_w = math.floor(gfx.w * 0.85)

    -- Measure title
    local title_w = gfx.measurestr(gui_msgbox.title)

    -- Word-wrap message to fit within max_box_w
    local msg_max_w = max_box_w - pad * 2
    local lines = {}
    for raw_line in (gui_msgbox.message .. "\n"):gmatch("([^\n]*)\n") do
        if raw_line == "" then
            table.insert(lines, "")
        else
            local cur = ""
            for word in raw_line:gmatch("%S+") do
                local test = cur == "" and word or (cur .. " " .. word)
                if gfx.measurestr(test) > msg_max_w and cur ~= "" then
                    table.insert(lines, cur)
                    cur = word
                else
                    cur = test
                end
            end
            if cur ~= "" then table.insert(lines, cur) end
        end
    end

    -- Compute box size
    local line_h = math.floor(gfx.texth * 1.3)
    local msg_block_h = #lines * line_h
    local content_h = gfx.texth + 8 + msg_block_h + 16 + btn_h  -- title + gap + message + gap + button
    local box_h = pad * 2 + content_h

    local widest_line = 0
    for _, l in ipairs(lines) do
        local lw = gfx.measurestr(l)
        if lw > widest_line then widest_line = lw end
    end
    local box_w = math.max(min_box_w, math.min(max_box_w, math.max(title_w, widest_line) + pad * 2))

    local bx = math.floor((gfx.w - box_w) / 2)
    local by = math.floor((gfx.h - box_h) / 2)

    -- Box background
    gfx.set(0.13, 0.13, 0.13, 1)
    gfx.rect(bx, by, box_w, box_h, 1)
    -- Box border
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.rect(bx, by, box_w, box_h, 0)

    -- Title
    local cy = by + pad
    gfx.set(0.17, 0.45, 0.39, 1)
    gfx.x = bx + pad
    gfx.y = cy
    gfx.drawstr(gui_msgbox.title)
    cy = cy + gfx.texth + 8

    -- Message lines
    gfx.set(1, 1, 1, 1)
    for _, l in ipairs(lines) do
        gfx.x = bx + pad
        gfx.y = cy
        gfx.drawstr(l)
        cy = cy + line_h
    end
    cy = cy + 16

    -- OK button
    local ok_x = bx + math.floor((box_w - btn_w) / 2)
    local ok_y = cy
    gui_msgbox.ok_hovered = (mouse_x >= ok_x and mouse_x < ok_x + btn_w and
                             mouse_y >= ok_y and mouse_y < ok_y + btn_h)
    if gui_msgbox.ok_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(ok_x, ok_y, btn_w, btn_h, 1)
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.rect(ok_x, ok_y, btn_w, btn_h, 0)
    gfx.set(1, 1, 1, 1)
    local ok_tw = gfx.measurestr("OK")
    gfx.x = ok_x + math.floor((btn_w - ok_tw) / 2)
    gfx.y = ok_y + math.floor((btn_h - gfx.texth) / 2)
    gfx.drawstr("OK")

    -- Skip input handling on the frame that opened the msgbox
    -- (the click that triggered it would otherwise dismiss it immediately)
    if gui_msgbox.skip_frame then
        gui_msgbox.skip_frame = false
        return true
    end

    -- Handle dismiss: click OK, Enter, Escape, or click outside box
    if mouse_clicked then
        if gui_msgbox.ok_hovered then
            gui_msgbox.active = false
        elseif mouse_x < bx or mouse_x >= bx + box_w or mouse_y < by or mouse_y >= by + box_h then
            gui_msgbox.active = false
        end
    end
    if char_input then
        if char_input == 13 or char_input == 27 then  -- Enter or Escape
            gui_msgbox.active = false
        end
    end

    return true  -- signal that msgbox consumed input this frame
end

-- Save/Load font setting
EXTSTATE_FONT_KEY = "font_name"
function save_font_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_FONT_KEY, font_list[current_font_index], true)
end
function load_font_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_FONT_KEY)
    if val and val ~= "" then
        for i, name in ipairs(font_list) do
            if name == val then current_font_index = i; return end
        end
    end
end
load_font_setting()

-- Save/Load docker settings
EXTSTATE_DOCKER_KEY = "docker_settings"
function save_docker_settings()
    local val = (docker_enabled and "1" or "0") .. "," .. tostring(docker_position)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_DOCKER_KEY, val, true)
end
function load_docker_settings()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_DOCKER_KEY)
    if not saved or saved == "" then return end
    local en, pos = saved:match("([01]),(%d+)")
    if en then docker_enabled = (en == "1") end
    if pos then docker_position = math.max(1, math.min(4, tonumber(pos))) end
end
load_docker_settings()

-- Dimensions
header_height = 50  -- header area height
file_info_height = 60  -- file info section height
checkbox_size = gui.settings.font_size
checkbox_row_height = gui.settings.font_size*2  -- add some vertical spacing between rows
horizontal_margin = 32  -- left/right margin
vertical_margin = 20  -- top/bottom margin
button_height_area = 50  -- space for import button

-- Calculate max label width for aligned checkboxes
gfx.setfont(1, font_list[current_font_index] .. "|Arial|Helvetica", gui.settings.font_size)
max_label_width = 0
for i, cb in ipairs(checkboxes_list) do
    local label_width = gfx.measurestr(cb.name)
    if label_width > max_label_width then
        max_label_width = label_width
    end
end

-- Column widths for settings layout
SYM_BOX_WIDTH = 100      -- symbol text input box width
TYPE_BTN_WIDTH = 80      -- type selector button width
REPL_COL_WIDTH = 100     -- replace fret column width (wide enough for header label)
COL_SPACING = 8          -- spacing between columns

-- Calculate window dimensions dynamically (vertical layout)
local min_btn_area_width = 110 * 4 + 10 * 3 + horizontal_margin * 2  -- 4 buttons + margins
local initial_extras = get_visible_extra_settings()
local initial_has_art = false
for _, item in ipairs(initial_extras) do
    if item.is_art then initial_has_art = true; break end
end
local initial_min_art_w = 0
if initial_has_art then
    initial_min_art_w = horizontal_margin + 80 + COL_SPACING + SYM_BOX_WIDTH + COL_SPACING + TYPE_BTN_WIDTH + COL_SPACING + REPL_COL_WIDTH + COL_SPACING + checkbox_size + COL_SPACING + checkbox_size + horizontal_margin
end
gui.width = math.max(horizontal_margin + max_label_width + 5 + checkbox_size + horizontal_margin, min_btn_area_width, initial_min_art_w)
local initial_visible_import = 0
for _, cb in ipairs(checkboxes_list) do
    if cb.show_in_menu ~= false then initial_visible_import = initial_visible_import + 1 end
end
local initial_visible_extra = #initial_extras
gui.height = header_height + vertical_margin + ((initial_visible_import + initial_visible_extra) * checkbox_row_height) + vertical_margin + file_info_height + vertical_margin + button_height_area

-- Global state
last_mouse_cap = 0
import_btn_hovered = false
cancel_btn_hovered = false
remap_btn_hovered = false
nudge_btn_hovered = false
is_dragging = false
drag_offset_x = 0
drag_offset_y = 0
window_script = nil

-- Track drag-to-arrange state
track_drag = {
    active = false,         -- whether a track drag is in progress
    track_index = nil,       -- index into track_checkboxes being dragged
    start_x = 0,             -- mouse x at drag start
    start_y = 0,             -- mouse y at drag start
    confirmed = false,       -- true once mouse moved past threshold
    last_click_index = nil,  -- track index of last label click (for double-click)
    last_click_time = 0,     -- os.clock() of last label click
}

-- Reset track drag state
function reset_track_drag()
    track_drag.active = false
    track_drag.track_index = nil
    track_drag.confirmed = false
end

-- Resize handle state (bundled to reduce top-level local count)
RS = { active = false, sx = 0, sy = 0, sw = 0, sh = 0, HANDLE = 14, MIN_W = 300, MIN_H = 200 }

-- Initialize window
local mouse_x, mouse_y = reaper.GetMousePosition()
init_x = nil
init_y = nil
launch_from_fretboard = false

-- Check if Fretboard sent a launch hint (format: "right_x,top_y,fb_width,fb_height")
local hint = reaper.GetExtState("konst_window_manager", "launch_hint")
if hint and hint ~= "" then
    local hx, hy, hw, hh = hint:match("(%-?%d+),(%-?%d+),(%-?%d+),(%-?%d+)")
    if hx then
        init_x = tonumber(hx)
        init_y = tonumber(hy)
        gui.height = math.max(tonumber(hh), RS.MIN_H)
        launch_from_fretboard = true
        -- Consume the hint so it doesn't affect future standalone launches
        reaper.DeleteExtState("konst_window_manager", "launch_hint", false)
    end
end

if not launch_from_fretboard then
    -- Restore saved window size if enabled
    if remember_window_size then
        local saved_w, saved_h = load_window_size("main")
        if saved_w and saved_h then
            gui.width = math.max(RS.MIN_W, math.min(saved_w, MAX_WINDOW_WIDTH))
            gui.height = math.max(RS.MIN_H, math.min(saved_h, MAX_WINDOW_HEIGHT))
        end
    end
    if window_position_mode == "last" then
        local saved_wx, saved_wy = load_window_position()
        init_x = saved_wx or (mouse_x - gui.width/2)
        init_y = saved_wy or (mouse_y - gui.height/2)
    else
        init_x = mouse_x - gui.width/2
        init_y = mouse_y - gui.height/2
    end
end

local startup_dock = gui.settings.docker_id
if docker_enabled then startup_dock = docker_dock_values[docker_position] or 1 end
gfx.init(SCRIPT_TITLE, gui.width, gui.height, startup_dock, init_x, init_y)

-- Find the script window handle (needed for position save/restore and borderless)
window_script = reaper.JS_Window_Find(SCRIPT_TITLE, true)

-- Apply borderless window style if configured
if gui.settings.Borderless_Window and window_script then
    reaper.JS_Window_SetStyle(window_script, "POPUP")
    reaper.JS_Window_AttachResizeGrip(window_script)
    -- Re-enable drag-and-drop after POPUP style strips WS_EX_ACCEPTFILES (0x10)
    local cur_exstyle = reaper.JS_Window_GetLong(window_script, "EXSTYLE")
    if cur_exstyle then
        reaper.JS_Window_SetLong(window_script, "EXSTYLE", cur_exstyle | 0x10)
    end
end

-- Apply stay-on-top if enabled
if stay_on_top_enabled then apply_stay_on_top() end

-- Set font
gfx.setfont(1, font_list[current_font_index], gui.settings.font_size)
gfx.clear = 2829099   -- dark gray

-- Load last import directory and default dir at startup
last_import_dir = load_last_import_path()
default_import_dir = load_default_import_dir()
path_mode = load_path_mode()


-- Helper function to extract track names and count from XML content
function get_tracks_from_xml(xml_content)
    local tracks = {}
    -- Extract part-name and optional GM program name from each score-part block
    for score_part_block in xml_content:gmatch("<score%-part[^>]*>(.-)</score%-part>") do
        local part_name = score_part_block:match("<part%-name>([^<]*)</part%-name>")
        if part_name and part_name ~= "" then
            local gm_name = nil
            local midi_channel = score_part_block:match("<midi%-channel>(%d+)</midi%-channel>")
            local midi_program = score_part_block:match("<midi%-program>(%d+)</midi%-program>")
            local has_unpitched = score_part_block:find("<midi%-unpitched>") ~= nil
            if (midi_channel and tonumber(midi_channel) == 10) or has_unpitched then
                gm_name = "Drums"
            elseif midi_program then
                local prog = tonumber(midi_program) - 1
                gm_name = gm_program_to_name[prog]
            end
            table.insert(tracks, {name = part_name, gm_name = gm_name})
        end
    end
    return tracks 
end

-- Get the display name for a track checkbox entry
function get_track_display_name(tcb)
    if gm_name_tracks_enabled and tcb.gm_name then return tcb.gm_name end
    return tcb.name
end

-- Scan a MusicXML file for articulations present in checked tracks
function scan_articulations_in_xml()
    articulations_in_file = {}
    if not selected_file_path then return end

    local f = io.open(selected_file_path, "r")
    if not f then return end
    local xml_content = f:read("*all")
    f:close()

    xml_content = preprocess_gp_pis(xml_content)
    local root = parseXML(xml_content)
    if not root then return end

    -- Build set of checked track names (using display names)
    local checked_names = {}
    for _, tcb in ipairs(track_checkboxes) do
        if tcb.checked then
            checked_names[get_track_display_name(tcb)] = true
        end
    end

    -- Map part IDs to names from <part-list>
    local part_names = {}
    local part_midi_prog = {}  -- part_id -> 0-based program number
    local part_list = findChild(root, "part-list")
    if part_list then
        for _, score_part in ipairs(findChildren(part_list, "score-part")) do
            local id = getAttribute(score_part, "id")
            local name = getChildText(score_part, "part-name")
            if id and name then
                part_names[id] = name
            end
            if id and gm_name_tracks_enabled then
                for _, mi in ipairs(findChildren(score_part, "midi-instrument")) do
                    local mp = tonumber(getChildText(mi, "midi-program"))
                    if mp then
                        part_midi_prog[id] = mp - 1
                        break
                    end
                end
            end
        end
    end

    local found = {}

    -- Helper: register a found articulation by its XML element name
    local function mark_found(xml_name)
        local settings_name = xml_to_settings_name[xml_name] or xml_name
        if settings_name_set[settings_name] then
            found[settings_name] = true
        end
    end

    -- Scan each <part>
    local parts = findChildren(root, "part")
    for _, part_node in ipairs(parts) do
        local part_id = getAttribute(part_node, "id")
        local base_track_name = part_names[part_id] or ("Part " .. (part_id or "?"))
        if gm_name_tracks_enabled and part_midi_prog[part_id] and gm_program_to_name[part_midi_prog[part_id]] then
            base_track_name = gm_program_to_name[part_midi_prog[part_id]]
        end

        -- Skip parts not checked for import
        if not checked_names[base_track_name] then goto continue_scan_part end

        local measures = findChildren(part_node, "measure")
        for _, measure_node in ipairs(measures) do
            for _, elem in ipairs(measure_node.children or {}) do
                -- Check for <harmony> at measure level → "chord"
                if elem.name == "harmony" then
                    found["chord"] = true
                end

                if elem.name == "note" then
                    -- Check for <grace> child → "grace-note"
                    if findChild(elem, "grace") then
                        found["grace-note"] = true
                    end

                    -- Check for <lyric> child → "lyric"
                    if findChild(elem, "lyric") then
                        found["lyric"] = true
                    end

                    -- Check <notations> subtree
                    local notations = findChild(elem, "notations")
                    if notations then
                        local articulations = findChild(notations, "articulations")
                        if articulations and articulations.children then
                            for _, child in ipairs(articulations.children) do
                                mark_found(child.name)
                            end
                        end

                        local technical = findChild(notations, "technical")
                        if technical and technical.children then
                            for _, child in ipairs(technical.children) do
                                if child.name == "harmonic" then
                                    -- Distinguish natural from artificial
                                    if findChild(child, "natural") then
                                        found["natural-harmonic"] = true
                                    else
                                        found["artificial-harmonic"] = true
                                    end
                                else
                                    mark_found(child.name)
                                end
                            end
                        end

                        -- Other notations children (including slides)
                        for _, child in ipairs(notations.children or {}) do
                            if child.name ~= "articulations" and child.name ~= "technical" then
                                mark_found(child.name)
                            end
                        end
                    end

                    -- Check <play>/<mute>
                    local play = findChild(elem, "play")
                    if play and play.children then
                        for _, child in ipairs(play.children) do
                            if child.name == "mute" then
                                local mute_text = getNodeText(child)
                                if mute_text == "palm" then
                                    found["palm"] = true
                                elseif mute_text == "straight" then
                                    found["straight"] = true
                                end
                            end
                        end
                    end

                    -- Check for let ring from GP PI (<_gp_> elements)
                    for _, child in ipairs(elem.children or {}) do
                        if child.name == "_gp_" then
                            local gp_root = findChild(child, "root")
                            if gp_root and findChild(gp_root, "letring") then
                                found["letring"] = true
                            end
                        end
                    end
                end
            end
        end

        ::continue_scan_part::
    end

    articulations_in_file = found
end

-- ============================================================================
-- Scan MIDI text events in selected items / active editor for articulations
-- ============================================================================
-- Build a list of { pattern, art_name } for reverse-matching text events
midi_art_patterns = nil  -- lazily built

function build_midi_art_patterns()
    if midi_art_patterns then return end
    midi_art_patterns = {}
    for _, art_name in ipairs(articulation_names_ordered) do
        local sym = get_art_symbol(art_name)
        if sym and sym ~= "" then
            local no_prefix = get_art_no_prefix(art_name)
            -- Escape Lua pattern specials, but keep %d / %s placeholders
            -- Strategy: replace %d and %s with unique tokens, escape rest, then restore
            local token_d = "\1"
            local token_s = "\2"
            local s = sym:gsub("%%%%", "\3")  -- protect literal %%
            s = s:gsub("%%d", token_d):gsub("%%h", token_d):gsub("%%s", token_s)
            -- Escape Lua pattern special characters
            s = s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", function(c) return "%" .. c end)
            -- Restore placeholders as pattern matchers (use function to avoid %-escaping in replacement)
            s = s:gsub(token_d, function() return "%-?%%d+" end)
            s = s:gsub(token_s, function() return ".+" end)
            s = s:gsub("\3", function() return "%%%%" end)
            -- Build full pattern with optional _ prefix
            local pat
            if no_prefix then
                pat = "^" .. s .. "$"
            else
                pat = "^_" .. s .. "$"
            end
            table.insert(midi_art_patterns, { pattern = pat, name = art_name })
        end
    end
end

function match_text_to_articulation(text)
    build_midi_art_patterns()
    for _, entry in ipairs(midi_art_patterns) do
        if text:match(entry.pattern) then
            return entry.name
        end
    end
    return nil
end

-- Gather MIDI takes using the same fallback chain as the articulation write handler
function gather_midi_takes_for_scan()
    local takes = {}
    local seen = {}
    local function add_take(take)
        local ptr = tostring(take)
        if not seen[ptr] then
            seen[ptr] = true
            table.insert(takes, take)
        end
    end

    -- 1. Selected items
    local num_items = reaper.CountSelectedMediaItems(0)
    if num_items > 0 then
        for mi = 0, num_items - 1 do
            local item = reaper.GetSelectedMediaItem(0, mi)
            local take = item and reaper.GetActiveTake(item)
            if take and reaper.TakeIsMIDI(take) then add_take(take) end
        end
    end
    -- 2. Active MIDI editor
    if #takes == 0 then
        local me = reaper.MIDIEditor_GetActive()
        if me then
            local take = reaper.MIDIEditor_GetTake(me)
            if take and reaper.TakeIsMIDI(take) then add_take(take) end
        end
    end
    -- 3. Any items with selected notes
    if #takes == 0 then
        local total_items = reaper.CountMediaItems(0)
        for mi = 0, total_items - 1 do
            local item = reaper.GetMediaItem(0, mi)
            local take = item and reaper.GetActiveTake(item)
            if take and reaper.TakeIsMIDI(take) then
                local _, note_count = reaper.MIDI_CountEvts(take)
                for ni = 0, note_count - 1 do
                    local _, sel = reaper.MIDI_GetNote(take, ni)
                    if sel then add_take(take); break end
                end
            end
        end
    end
    return takes
end

function scan_articulations_in_midi()
    -- Rebuild patterns in case symbol overrides changed
    midi_art_patterns = nil
    local found = {}
    local takes = gather_midi_takes_for_scan()
    for _, take in ipairs(takes) do
        local _, _, _, text_count = reaper.MIDI_CountEvts(take)

        -- Collect PPQ positions of selected notes for filtering
        local _, note_count = reaper.MIDI_CountEvts(take)
        local has_selected = false
        local sel_ppqs = {}
        for ni = 0, note_count - 1 do
            local _, sel, _, startppq = reaper.MIDI_GetNote(take, ni)
            if sel then
                sel_ppqs[startppq] = true
                has_selected = true
            end
        end

        for ti = 0, text_count - 1 do
            local _, _, _, ppqpos, evt_type, msg = reaper.MIDI_GetTextSysexEvt(take, ti)
            if msg and #msg > 0 then
                -- If notes are selected, only match text events at selected note positions
                -- If no notes selected (item-level selection), match all text events
                if not has_selected or sel_ppqs[ppqpos] then
                    local art = match_text_to_articulation(msg)
                    if art then found[art] = true end
                end
            end
        end
    end
    -- Merge with existing file-based scan results (don't overwrite XML scan)
    for art_name, _ in pairs(found) do
        articulations_in_file[art_name] = true
    end
end

-- Track last known selection state so we only re-scan when selection changes
last_midi_scan_sel_hash = ""

function compute_selection_hash()
    local parts = {}
    -- Selected items
    local num_items = reaper.CountSelectedMediaItems(0)
    for mi = 0, num_items - 1 do
        local item = reaper.GetSelectedMediaItem(0, mi)
        if item then
            parts[#parts + 1] = tostring(item)
        end
    end
    -- Active MIDI editor take
    local me = reaper.MIDIEditor_GetActive()
    if me then
        local take = reaper.MIDIEditor_GetTake(me)
        if take then
            parts[#parts + 1] = "ME:" .. tostring(take)
            -- Include selected note count as a cheap proxy for note selection changes
            local _, note_count = reaper.MIDI_CountEvts(take)
            local sel_count = 0
            for ni = 0, note_count - 1 do
                local _, sel = reaper.MIDI_GetNote(take, ni)
                if sel then sel_count = sel_count + 1 end
            end
            parts[#parts + 1] = "N:" .. sel_count
        end
    end
    return table.concat(parts, "|")
end

-- Find character index (0 to #text) in text closest to pixel position px
function char_index_at_x(text, base_x, px)
    if not text or #text == 0 then return 0 end
    if px <= base_x then return 0 end
    local total_w = gfx.measurestr(text)
    if px >= base_x + total_w then return #text end
    for i = 1, #text do
        local w = gfx.measurestr(text:sub(1, i))
        if base_x + w >= px then
            local prev_w = (i > 1) and gfx.measurestr(text:sub(1, i - 1)) or 0
            if (px - base_x - prev_w) < (base_x + w - px) then
                return i - 1
            else
                return i
            end
        end
    end
    return #text
end

-- Register a text element for hit testing this frame
function register_text_element(id, display_text, full_text, x, y, w, h)
    table.insert(text_elements_frame, {
        id = id, display_text = display_text, full_text = full_text,
        x = x, y = y, w = w, h = h
    })
end

-- Draw text with selection highlight and register for hit testing
function draw_selectable_text(id, display_text, full_text, x, y, color)
    local w = gfx.measurestr(display_text)
    local h = gfx.texth
    register_text_element(id, display_text, full_text, x, y, w, h)
    -- Draw selection highlight if this element has a selection
    if text_sel.element_id == id and text_sel.start_char ~= text_sel.end_char then
        local s = math.min(text_sel.start_char, text_sel.end_char)
        local e = math.max(text_sel.start_char, text_sel.end_char)
        s = math.max(0, math.min(s, #display_text))
        e = math.max(0, math.min(e, #display_text))
        local pre_w = (s > 0) and gfx.measurestr(display_text:sub(1, s)) or 0
        local sel_w = gfx.measurestr(display_text:sub(1, e)) - pre_w
        gfx.set(0.17, 0.45, 0.39, 0.7)
        gfx.rect(x + pre_w, y, sel_w, h, 1)
    end
    -- Draw the text
    gfx.set(table.unpack(color))
    gfx.x = x
    gfx.y = y
    gfx.drawstr(display_text)
end

-- Copy selected text to clipboard
function copy_selected_text()
    if text_sel.element_id and text_sel.start_char ~= text_sel.end_char then
        local s = math.min(text_sel.start_char, text_sel.end_char)
        local e = math.max(text_sel.start_char, text_sel.end_char)
        local text = text_sel.display_text
        s = math.max(0, math.min(s, #text))
        e = math.max(0, math.min(e, #text))
        local selected = text:sub(s + 1, e)
        if selected ~= "" and reaper.CF_SetClipboard then
            reaper.CF_SetClipboard(selected)
        end
    end
end

-- Find text element at a given pixel position
function find_text_element_at(mx, my)
    for _, elem in ipairs(text_elements_frame) do
        if mx >= elem.x and mx <= elem.x + elem.w and
           my >= elem.y and my <= elem.y + elem.h then
            return elem
        end
    end
    return nil
end

-- Truncate text to fit within max_pixel_width, appending "..." if needed
function truncate_text(text, max_pixel_width)
    if not text or max_pixel_width <= 0 then return "" end
    local w = gfx.measurestr(text)
    if w <= max_pixel_width then return text end
    local ellipsis = "..."
    local ew = gfx.measurestr(ellipsis)
    -- Binary search for the longest prefix that fits
    local lo, hi = 0, #text
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        local sub = text:sub(1, mid)
        if gfx.measurestr(sub) + ew <= max_pixel_width then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return text:sub(1, lo) .. ellipsis
end

-- Recalculate and resize the GUI window based on current content
function resize_window()
    -- Recalculate max_label_width including track names and filename
    max_label_width = 0
    for _, cb in ipairs(checkboxes_list) do
        local w = gfx.measurestr(cb.name)
        if w > max_label_width then max_label_width = w end
    end
    local import_all_w = gfx.measurestr("Import All")
    if import_all_w > max_label_width then max_label_width = import_all_w end
    for _, tcb in ipairs(track_checkboxes) do
        local w = gfx.measurestr(get_track_display_name(tcb))
        if w > max_label_width then max_label_width = w end
    end
    -- Account for file info text width
    local min_btn_width = 110 * 4 + 10 * 3 + horizontal_margin * 2  -- 4 buttons + margins
    -- Check if any articulation rows are visible in main view (need wider layout)
    local has_art_rows = false
    local extras_list = get_visible_extra_settings()
    for _, item in ipairs(extras_list) do
        if item.is_art then has_art_rows = true; break end
    end
    local min_art_width = 0
    if has_art_rows then
        min_art_width = horizontal_margin + 80 + COL_SPACING + SYM_BOX_WIDTH + COL_SPACING + TYPE_BTN_WIDTH + COL_SPACING + REPL_COL_WIDTH + COL_SPACING + checkbox_size + COL_SPACING + checkbox_size + horizontal_margin
    end
    if selected_file_name then
        local info_text = selected_file_name .. " [" .. (selected_file_track_count or 0) .. " tracks]"
        local fw = gfx.measurestr(info_text)
        -- File info needs some margin on both sides
        local needed_for_file = fw + horizontal_margin * 2
        local needed_for_labels = horizontal_margin + max_label_width + 5 + checkbox_size + horizontal_margin
        local new_width = math.max(needed_for_file, needed_for_labels, min_btn_width, min_art_width)
        if new_width > gui.width then
            gui.width = math.min(new_width, MAX_WINDOW_WIDTH)
        end
    else
        local new_width = math.max(horizontal_margin + max_label_width + 5 + checkbox_size + horizontal_margin, min_btn_width, min_art_width)
        if new_width > gui.width then
            gui.width = math.min(new_width, MAX_WINDOW_WIDTH)
        end
    end

    -- Clamp max_label_width so checkboxes + labels fit within gui.width
    local available_label_width = gui.width - horizontal_margin - 5 - checkbox_size - horizontal_margin
    if max_label_width > available_label_width then
        max_label_width = available_label_width
    end

    local track_section_height = 0
    if #track_checkboxes > 0 then
        -- "Import All" row + one row per track + spacing
        track_section_height = vertical_margin + (1 + #track_checkboxes) * checkbox_row_height
    end
    local visible_import_rows = 0
    for _, cb in ipairs(checkboxes_list) do
        if cb.show_in_menu ~= false then visible_import_rows = visible_import_rows + 1 end
    end
    local visible_extra_rows = #get_visible_extra_settings()
    gui.height = header_height + vertical_margin
                 + ((visible_import_rows + visible_extra_rows) * checkbox_row_height)
                 + vertical_margin + file_info_height
                 + track_section_height
                 + vertical_margin + button_height_area
    -- Clamp height and reset scroll offset
    if gui.height > MAX_WINDOW_HEIGHT then
        gui.height = MAX_WINDOW_HEIGHT
    end
    track_scroll_offset = 0
    -- Resize the gfx window using JS_Window for reliable borderless resize
    if window_script then
        reaper.JS_Window_Resize(window_script, gui.width, gui.height)
    else
        local _, x, y = gfx.dock(-1, 0, 0, 0, 0)
        gfx.init(SCRIPT_TITLE, gui.width, gui.height, gui.settings.docker_id, x, y)
    end
end

-- Helper function to extract filename from path
function get_filename_from_path(filepath)
    -- Extract just the filename from full path
    local filename = filepath:match("([^\\]+)$") or filepath
    return filename
end

-- Draw a header box with centered title text
function draw_header(title, height, colors)
    -- Fill background
    gfx.set(table.unpack(colors.HEADER_BG))
    gfx.rect(0, 0, gfx.w, height, 1)
    
    -- Draw border
    gfx.set(table.unpack(colors.BORDER))
    gfx.rect(0, 0, gfx.w, height, 0)
    
    -- Draw centered text
    gfx.set(table.unpack(colors.TEXT))
    local title_width = gfx.measurestr(title)
    gfx.x = (gfx.w - title_width) / 2
    gfx.y = (height - gfx.texth) / 2
    gfx.drawstr(title)
end

-- Draw a single checkbox with label (truncates label if max_text_w provided)
function draw_checkbox(checkbox_x, checkbox_y, size, label_x, label_text, is_checked, colors, max_text_w, text_id)
    -- Draw text label first (possibly truncated)
    local display_text = label_text
    local was_truncated = false
    if max_text_w then
        display_text = truncate_text(label_text, max_text_w)
        was_truncated = (display_text ~= label_text)
    end
    local text_y = checkbox_y + (size - gfx.texth) / 2
    if text_id then
        draw_selectable_text(text_id, display_text, label_text, label_x, text_y, colors.TEXT)
    else
        gfx.set(table.unpack(colors.TEXT))
        gfx.x = label_x
        gfx.y = text_y
        gfx.drawstr(display_text)
    end

    -- Tooltip for truncated labels
    if was_truncated and label_text ~= "" then
        local mx, my = gfx.mouse_x, gfx.mouse_y
        local text_w = gfx.measurestr(display_text)
        if mx >= label_x and mx < label_x + text_w and my >= checkbox_y and my < checkbox_y + size then
            pending_tooltip = label_text
        end
    end

    -- Checkbox background - highlight only when checked
    if is_checked then
        gfx.set(table.unpack(colors.CHECKBOX_BG_HOVER))
    else
        gfx.set(table.unpack(colors.CHECKBOX_BG))
    end
    gfx.rect(checkbox_x, checkbox_y, size, size, 1)

    -- Outer border
    gfx.set(table.unpack(colors.CHECKBOX_BORDER))
    gfx.rect(checkbox_x, checkbox_y, size, size, 0)

    -- Inner border (inset effect)
    gfx.set(table.unpack(colors.CHECKBOX_INNER_BORDER))
    gfx.rect(checkbox_x + 1, checkbox_y + 1, size - 2, size - 2, 0)

    -- Checkmark if checked
    if is_checked then
        gfx.set(table.unpack(colors.CHECKMARK))
        gfx.x = checkbox_x + (size - gfx.measurestr("✓")) / 2
        gfx.y = checkbox_y + (size - gfx.texth) / 2
        gfx.drawstr("✓")
    end
end

-- Draw file info section with filename and track count
function draw_file_info(y_offset, height, filename, track_count, colors, is_hovered, is_drag_over)
    -- Fill background - highlight when hovered or drag-over
    if is_drag_over then
        gfx.set(table.unpack(colors.CHECKBOX_BG_HOVER))
    elseif is_hovered then
        gfx.set(table.unpack(colors.CHECKBOX_BG_HOVER))
    else
        gfx.set(table.unpack(colors.FILE_INFO_BG))
    end
    gfx.rect(0, y_offset, gfx.w, height, 1)
    
    -- Draw border
    gfx.set(table.unpack(colors.BORDER))
    gfx.rect(0, y_offset, gfx.w, height, 0)
    
    -- Draw filename and track count (centered, truncated if needed)
    gfx.set(table.unpack(colors.TEXT))
    local text_y = y_offset + (height - gfx.texth) / 2
    local max_text_w = gfx.w - horizontal_margin * 2
    
    if is_drag_over then
        local drop_text = "Drop MusicXML file here"
        local text_width = gfx.measurestr(drop_text)
        gfx.x = (gfx.w - text_width) / 2
        gfx.y = text_y
        gfx.drawstr(drop_text)
    elseif filename then
        local full_info_text = filename .. " [" .. (track_count or 0) .. " tracks]"
        local info_text = truncate_text(full_info_text, max_text_w)
        local text_width = gfx.measurestr(info_text)
        local text_x = (gfx.w - text_width) / 2
        draw_selectable_text("file_info", info_text, full_info_text, text_x, text_y, colors.TEXT)
    else
        local no_file_text = "Click to select a file"
        local text_width = gfx.measurestr(no_file_text)
        gfx.x = (gfx.w - text_width) / 2
        gfx.y = text_y
        gfx.drawstr(no_file_text)
    end
end

-- Draw a button with text
function draw_button(x, y, width, height, label, is_hovered, bg_color_key, border_color, text_color)
    -- Button background
    local hover_key = bg_color_key .. "_HOVER"
    local bg_color = is_hovered and gui.colors[hover_key] or gui.colors[bg_color_key]
    gfx.set(table.unpack(bg_color))
    gfx.rect(x, y, width, height, 1)
    
    -- Border
    gfx.set(table.unpack(border_color))
    gfx.rect(x, y, width, height, 0)
    
    -- Truncate label if it doesn't fit
    local full_label = label
    local display_label = label
    local text_width = gfx.measurestr(label)
    if text_width > width - 8 then
        display_label = truncate_text(label, width - 8)
        text_width = gfx.measurestr(display_label)
    end
    
    -- Text
    gfx.set(table.unpack(text_color))
    gfx.x = x + (width - text_width) / 2
    gfx.y = y + (height - gfx.texth) / 2
    gfx.drawstr(display_label)
    
    -- Tooltip for truncated label
    if display_label ~= full_label and is_hovered then
        pending_tooltip = full_label
    end
end

-- Draw resize handle (bottom-right corner grip) and handle drag logic
function draw_and_handle_resize(mouse_x, mouse_y, mouse_clicked, mouse_released, mouse_down, screen_x, screen_y)
    local w, h = gfx.w, gfx.h
    local sz = RS.HANDLE
    local rx, ry = w - sz, h - sz
    local hovered = mouse_x >= rx and mouse_y >= ry

    -- Start resize
    if mouse_clicked and hovered and not is_dragging then
        RS.active = true
        RS.sx = screen_x
        RS.sy = screen_y
        RS.sw = w
        RS.sh = h
    end

    -- During resize
    if RS.active and mouse_down then
        local new_w = math.max(RS.MIN_W, RS.sw + (screen_x - RS.sx))
        local new_h = math.max(RS.MIN_H, RS.sh + (screen_y - RS.sy))
        gui.width = new_w
        gui.height = new_h
        if window_script then
            reaper.JS_Window_Resize(window_script, new_w, new_h)
        end
    end

    -- End resize
    if mouse_released and RS.active then
        RS.active = false
    end

    -- Draw the grip lines (three diagonal lines)
    local alpha = (hovered or RS.active) and 0.6 or 0.3
    gfx.set(0.7, 0.7, 0.7, alpha)
    for i = 0, 2 do
        local offset = 4 + i * 4
        gfx.line(w - offset, h - 1, w - 1, h - offset)
    end

    return hovered or RS.active
end

-- Forward declarations for main view editing state (globals, used in draw_checkboxes_list)
main_sym_edit_active = nil
main_sym_edit_index = nil
main_sym_edit_text = nil
main_sym_edit_cursor = nil
main_defpath_edit_active = nil
main_defpath_edit_text = nil
main_defpath_edit_cursor = nil
main_defpath_edit_sel = nil

-- Draw all checkboxes from list (filtered by show_in_menu) plus extra settings
function draw_checkboxes_list(checkboxes, header_h, h_margin, v_margin, checkbox_h, cb_size, max_width, colors, scroll_offset, max_vis_rows)
    scroll_offset = scroll_offset or 0
    local visible_idx = 0
    -- Draw "SETTINGS" fold header as the first row
    do
        local scrolled = visible_idx - scroll_offset
        local hdr_visible = not max_vis_rows or (scrolled >= 0 and scrolled < max_vis_rows)
        if hdr_visible then
            local hdr_y = header_h + v_margin + scrolled * checkbox_h
            local hdr_h = cb_size
            local tri_size = math.floor(gfx.texth * 0.4)
            local tri_cy = hdr_y + math.floor(hdr_h / 2)
            local hdr_hovered = (gfx.mouse_x >= h_margin and gfx.mouse_x < gfx.w - h_margin and
                                 gfx.mouse_y >= hdr_y and gfx.mouse_y < hdr_y + hdr_h)
            if hdr_hovered then
                gfx.set(0.17, 0.45, 0.39, 1)
            else
                gfx.set(0.45, 0.45, 0.45, 1)
            end
            -- Triangle
            if main_settings_folded then
                local tx = h_margin
                local ty = tri_cy - tri_size
                for row = 0, tri_size * 2 do
                    local w = math.floor(tri_size * (1 - math.abs(row - tri_size) / tri_size))
                    if w > 0 then gfx.line(tx, ty + row, tx + w, ty + row) end
                end
            else
                local tx = h_margin
                local ty = tri_cy - math.floor(tri_size * 0.5)
                for row = 0, tri_size do
                    local half_w = tri_size - row
                    if half_w >= 0 then
                        local cx = tx + tri_size
                        gfx.line(cx - half_w, ty + row, cx + half_w, ty + row)
                    end
                end
            end
            -- Label
            local label_x = h_margin + tri_size * 2 + 6
            local text_y = hdr_y + (hdr_h - gfx.texth) / 2
            gfx.x = label_x
            gfx.y = text_y
            gfx.drawstr("SETTINGS")
            local lw = gfx.measurestr("SETTINGS")
            local line_y = hdr_y + math.floor(hdr_h / 2)
            gfx.set(0.3, 0.3, 0.3, 1)
            gfx.line(label_x + lw + 8, line_y, gfx.w - h_margin, line_y)
        end
        visible_idx = visible_idx + 1
    end
    if not main_settings_folded then
    for i, cb in ipairs(checkboxes) do
        if cb.show_in_menu ~= false then
            local scrolled = visible_idx - scroll_offset
            if not max_vis_rows or (scrolled >= 0 and scrolled < max_vis_rows) then
                local label_x = h_margin
                local cb_y = header_h + v_margin + scrolled * checkbox_h
                local cb_x = gfx.w - h_margin - cb_size
                
                draw_checkbox(cb_x, cb_y, cb_size, label_x, cb.name, cb.checked, colors, nil, "option_" .. i)
                -- Tooltip for import checkbox row
                if cb.tip and not pending_tooltip then
                    if gfx.mouse_x >= h_margin and gfx.mouse_x < gfx.w - h_margin
                       and gfx.mouse_y >= cb_y and gfx.mouse_y < cb_y + cb_size then
                        pending_tooltip = cb.tip
                    end
                end
            end
            visible_idx = visible_idx + 1
        end
    end
    -- Draw extra settings (from M flags)
    local extras = get_visible_extra_settings()
    for j, item in ipairs(extras) do
        local scrolled = visible_idx - scroll_offset
        local main_row_visible = not max_vis_rows or (scrolled >= 0 and scrolled < max_vis_rows)
        local cb_y = header_h + v_margin + scrolled * checkbox_h
        if main_row_visible and item.is_art then
            -- Full-featured articulation row
            local art_name = item.key
            local art_i = item.art_index
            -- Column positions (no M column in main view, rightmost = enabled cb)
            local m_cb_x = gfx.w - h_margin - cb_size
            local m_prefix_cb_x = m_cb_x - COL_SPACING - cb_size
            local m_repl_col_x = m_prefix_cb_x - COL_SPACING - REPL_COL_WIDTH
            local m_repl_cb_x = m_repl_col_x + math.floor((REPL_COL_WIDTH - cb_size) / 2)
            local m_type_btn_x = m_repl_col_x - COL_SPACING - TYPE_BTN_WIDTH
            local m_sym_box_x = m_type_btn_x - COL_SPACING - SYM_BOX_WIDTH
            local m_name_max_w = m_sym_box_x - h_margin - COL_SPACING
            local text_y = cb_y + (cb_size - gfx.texth) / 2

            -- Highlight row if this articulation is present in the file
            if articulations_in_file[art_name] then
                gfx.set(0.18, 0.25, 0.22, 1)
                gfx.rect(h_margin - 4, cb_y, gfx.w - 2 * h_margin + 8, cb_size, 1)
            end

            -- 1) Name label (clickable to insert/remove text event)
            local display_name = truncate_text(art_name, m_name_max_w)
            local mouse_x, mouse_y_pos = gfx.mouse_x, gfx.mouse_y
            local name_hovered = (mouse_x >= h_margin and mouse_x < m_sym_box_x - COL_SPACING and
                                  mouse_y_pos >= cb_y and mouse_y_pos < cb_y + cb_size)
            if name_hovered then
                if (gfx.mouse_cap & 16) ~= 0 then
                    gfx.set(0.85, 0.25, 0.25, 1)
                else
                    gfx.set(0.17, 0.45, 0.39, 1)
                end
            else
                gfx.set(table.unpack(colors.TEXT))
            end
            gfx.x = h_margin
            gfx.y = text_y
            gfx.drawstr(display_name)

            -- 2) Symbol box
            local is_editing = (main_sym_edit_active and main_sym_edit_index == art_i)
            local sym_display = is_editing and main_sym_edit_text or get_art_symbol(art_name)
            local sym_is_override = (articulation_symbol_override[art_name] ~= nil)
            if is_editing then
                gfx.set(0.25, 0.25, 0.25, 1)
            else
                gfx.set(0.17, 0.17, 0.17, 1)
            end
            gfx.rect(m_sym_box_x, cb_y, SYM_BOX_WIDTH, cb_size, 1)
            if is_editing then
                gfx.set(0.17, 0.45, 0.39, 1)
            elseif sym_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(colors.CHECKBOX_BORDER))
            end
            gfx.rect(m_sym_box_x, cb_y, SYM_BOX_WIDTH, cb_size, 0)
            local sym_text_x = m_sym_box_x + 4
            local sym_max_w = SYM_BOX_WIDTH - 8
            local sym_truncated = truncate_text(sym_display, sym_max_w)
            if sym_is_override then
                gfx.set(1.0, 0.85, 0.5, 1)
            else
                gfx.set(table.unpack(colors.TEXT))
            end
            gfx.x = sym_text_x
            gfx.y = text_y
            gfx.drawstr(sym_truncated)
            if is_editing then
                local cursor_text = main_sym_edit_text:sub(1, main_sym_edit_cursor)
                local cursor_px = gfx.measurestr(cursor_text)
                if math.floor(os.clock() * 2) % 2 == 0 then
                    gfx.set(1, 1, 1, 0.9)
                    gfx.line(sym_text_x + cursor_px, cb_y + 2, sym_text_x + cursor_px, cb_y + cb_size - 2)
                end
            end

            -- 3) Type selector button
            local current_type = get_art_type(art_name)
            local type_label = art_type_labels[current_type] or ("T" .. tostring(current_type))
            local type_is_override = (articulation_type_override[art_name] ~= nil)
            local type_hovered = (mouse_x > m_type_btn_x and mouse_x < m_type_btn_x + TYPE_BTN_WIDTH and
                                  mouse_y_pos > cb_y and mouse_y_pos < cb_y + cb_size)
            if type_hovered then
                gfx.set(0.17, 0.45, 0.39, 1)
            else
                gfx.set(0.2, 0.2, 0.2, 1)
            end
            gfx.rect(m_type_btn_x, cb_y, TYPE_BTN_WIDTH, cb_size, 1)
            if type_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(colors.CHECKBOX_BORDER))
            end
            gfx.rect(m_type_btn_x, cb_y, TYPE_BTN_WIDTH, cb_size, 0)
            if type_is_override then
                gfx.set(1.0, 0.85, 0.5, 1)
            else
                gfx.set(table.unpack(colors.TEXT))
            end
            local lbl_w = gfx.measurestr(type_label)
            gfx.x = m_type_btn_x + (TYPE_BTN_WIDTH - lbl_w) / 2
            gfx.y = text_y
            gfx.drawstr(type_label)

            -- 4) Replace fret checkbox
            local rf_checked = get_art_replaces_fret(art_name)
            local rf_is_override = (articulation_replaces_fret_override[art_name] ~= nil)
            if rf_checked then
                gfx.set(table.unpack(colors.CHECKBOX_BG_HOVER))
            else
                gfx.set(table.unpack(colors.CHECKBOX_BG))
            end
            gfx.rect(m_repl_cb_x, cb_y, cb_size, cb_size, 1)
            if rf_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(colors.CHECKBOX_BORDER))
            end
            gfx.rect(m_repl_cb_x, cb_y, cb_size, cb_size, 0)
            gfx.set(table.unpack(colors.CHECKBOX_INNER_BORDER))
            gfx.rect(m_repl_cb_x + 1, cb_y + 1, cb_size - 2, cb_size - 2, 0)
            if rf_checked then
                if rf_is_override then
                    gfx.set(1.0, 0.85, 0.5, 1)
                else
                    gfx.set(table.unpack(colors.CHECKMARK))
                end
                gfx.x = m_repl_cb_x + (cb_size - gfx.measurestr("✓")) / 2
                gfx.y = cb_y + (cb_size - gfx.texth) / 2
                gfx.drawstr("✓")
            end

            -- 5) Prefix checkbox
            local pfx_checked = not get_art_no_prefix(art_name)
            local pfx_is_override = (articulation_no_prefix_override[art_name] ~= nil)
            if pfx_checked then
                gfx.set(table.unpack(colors.CHECKBOX_BG_HOVER))
            else
                gfx.set(table.unpack(colors.CHECKBOX_BG))
            end
            gfx.rect(m_prefix_cb_x, cb_y, cb_size, cb_size, 1)
            if pfx_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(colors.CHECKBOX_BORDER))
            end
            gfx.rect(m_prefix_cb_x, cb_y, cb_size, cb_size, 0)
            gfx.set(table.unpack(colors.CHECKBOX_INNER_BORDER))
            gfx.rect(m_prefix_cb_x + 1, cb_y + 1, cb_size - 2, cb_size - 2, 0)
            if pfx_checked then
                if pfx_is_override then
                    gfx.set(1.0, 0.85, 0.5, 1)
                else
                    gfx.set(table.unpack(colors.CHECKMARK))
                end
                gfx.x = m_prefix_cb_x + (cb_size - gfx.measurestr("✓")) / 2
                gfx.y = cb_y + (cb_size - gfx.texth) / 2
                gfx.drawstr("✓")
            end

            -- 6) Enabled checkbox
            draw_checkbox(m_cb_x, cb_y, cb_size, m_cb_x, "", articulation_enabled[art_name], colors, 0, nil)
        elseif main_row_visible then
            -- Non-articulation extra settings with enhanced controls
            local label_x = h_margin
            local cb_x_pos = gfx.w - h_margin - cb_size
            local text_y = cb_y + (cb_size - gfx.texth) / 2
            local ikey = item.key

            if ikey == "docker" or ikey == "font" or ikey == "midibank" or ikey == "importpos" or ikey == "timebase" or ikey == "alignstem" or ikey == "onsetitem" or ikey == "tempofreq" or ikey == "detectmethod" or ikey == "detectitem" then
                -- Label
                gfx.set(table.unpack(colors.TEXT))
                gfx.x = label_x
                gfx.y = text_y
                gfx.drawstr(item.label)
                -- Scrollable button
                local lbl_w = gfx.measurestr(item.label .. "  ")
                local btn_x = label_x + lbl_w
                local btn_w
                if ikey == "font" or ikey == "importpos" or ikey == "timebase" or ikey == "alignstem" or ikey == "onsetitem" or ikey == "tempofreq" or ikey == "detectmethod" or ikey == "detectitem" then
                    btn_w = gfx.w - h_margin - btn_x
                else
                    btn_w = cb_x_pos - COL_SPACING - btn_x
                end
                if btn_w < 20 then btn_w = 20 end
                -- Determine button label
                local btn_label
                if ikey == "docker" then
                    btn_label = docker_positions[docker_position] or "Bottom"
                elseif ikey == "font" then
                    btn_label = font_list[current_font_index] or "Outfit"
                elseif ikey == "importpos" then
                    btn_label = import_position_options[import_position_index] or "Start of Project"
                elseif ikey == "timebase" then
                    btn_label = import_timebase_options[import_timebase_index] or "Project default"
                elseif ikey == "alignstem" then
                    if align_stem_index == 0 then
                        btn_label = "Auto"
                    elseif align_stem_items[align_stem_index] then
                        btn_label = align_stem_items[align_stem_index].name
                    else
                        btn_label = "Auto"
                    end
                elseif ikey == "onsetitem" then
                    if onset_item_index == 0 then
                        btn_label = "Auto"
                    elseif onset_item_items[onset_item_index] then
                        btn_label = onset_item_items[onset_item_index].name
                    else
                        btn_label = "Auto"
                    end
                elseif ikey == "tempofreq" then
                    btn_label = tempo_map_freq_options[tempo_map_freq_index] or "Off"
                elseif ikey == "detectmethod" then
                    btn_label = tempo_detect_method_options[tempo_detect_method_index] or "Lua"
                elseif ikey == "detectitem" then
                    if detect_tempo_item_index <= 0 then
                        btn_label = "Selected Item"
                    elseif detect_tempo_item_items[detect_tempo_item_index] then
                        btn_label = detect_tempo_item_items[detect_tempo_item_index].name
                    else
                        btn_label = "Selected Item"
                    end
                elseif ikey == "midibank" then
                    btn_label = "—"
                    local num_sel = reaper.CountSelectedMediaItems(0)
                    if num_sel > 0 then
                        local sel_item = reaper.GetSelectedMediaItem(0, 0)
                        local take = sel_item and reaper.GetActiveTake(sel_item)
                        if take and reaper.TakeIsMIDI(take) then
                            local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                            if gotAllOK then
                                local MIDIlen = MIDIstring:len()
                                local stringPos = 1
                                local abs_pos = 0
                                while stringPos < MIDIlen do
                                    local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                                    abs_pos = abs_pos + offset
                                    if abs_pos == 0 and msg:len() >= 2 then
                                        local status = msg:byte(1)
                                        if (status >> 4) == 0xC then
                                            btn_label = gm_program_to_name[msg:byte(2)] or ("Program " .. tostring(msg:byte(2)))
                                        end
                                    end
                                    if abs_pos > 0 then break end
                                    stringPos = newPos
                                end
                            end
                        end
                    end
                end
                -- Draw button
                local mx, my = gfx.mouse_x, gfx.mouse_y
                local btn_hov = (mx >= btn_x and mx < btn_x + btn_w and my >= cb_y and my < cb_y + cb_size)
                if btn_hov then
                    gfx.set(0.17, 0.45, 0.39, 1)
                else
                    gfx.set(0.2, 0.2, 0.2, 1)
                end
                gfx.rect(btn_x, cb_y, btn_w, cb_size, 1)
                gfx.set(table.unpack(colors.CHECKBOX_BORDER))
                gfx.rect(btn_x, cb_y, btn_w, cb_size, 0)
                gfx.set(table.unpack(colors.TEXT))
                -- Truncate label to fit
                local disp = btn_label
                local disp_w = gfx.measurestr(disp)
                if disp_w > btn_w - 4 then
                    while #disp > 1 and gfx.measurestr(disp .. "..") > btn_w - 4 do
                        disp = disp:sub(1, -2)
                    end
                    disp = disp .. ".."
                    disp_w = gfx.measurestr(disp)
                end
                gfx.x = btn_x + (btn_w - disp_w) / 2
                gfx.y = text_y
                gfx.drawstr(disp)
                -- Draw checkbox (for docker/midibank, not for font/importpos)
                if ikey ~= "font" and ikey ~= "importpos" and ikey ~= "timebase" and ikey ~= "alignstem" and ikey ~= "onsetitem" and ikey ~= "tempofreq" and ikey ~= "detectmethod" then
                    local checked = get_extra_setting_checked(ikey)
                    draw_checkbox(cb_x_pos, cb_y, cb_size, cb_x_pos, "", checked, colors, 0, nil)
                end
            elseif ikey == "defpath" then
                -- Label
                gfx.set(table.unpack(colors.TEXT))
                gfx.x = label_x
                gfx.y = text_y
                gfx.drawstr(item.label)
                -- Text input box
                local lbl_w = gfx.measurestr(item.label .. "  ")
                local box_x = label_x + lbl_w
                local box_w = cb_x_pos - COL_SPACING - box_x
                if box_w < 20 then box_w = 20 end
                local box_pad = 4
                if main_defpath_edit_active then
                    gfx.set(0.25, 0.25, 0.25, 1)
                else
                    gfx.set(0.17, 0.17, 0.17, 1)
                end
                gfx.rect(box_x, cb_y, box_w, cb_size, 1)
                if main_defpath_edit_active then
                    gfx.set(0.17, 0.45, 0.39, 1)
                else
                    gfx.set(table.unpack(colors.CHECKBOX_BORDER))
                end
                gfx.rect(box_x, cb_y, box_w, cb_size, 0)
                -- Text content
                local display_text = main_defpath_edit_active and main_defpath_edit_text or default_import_dir
                local inner_w = box_w - box_pad * 2
                -- Calculate scroll offset so cursor is always visible
                local scroll_px = 0
                if main_defpath_edit_active then
                    local cursor_px = gfx.measurestr(main_defpath_edit_text:sub(1, main_defpath_edit_cursor))
                    if cursor_px > inner_w then
                        scroll_px = cursor_px - inner_w + 10
                    end
                end
                -- Draw selection highlight
                if main_defpath_edit_active and main_defpath_edit_sel >= 0 and main_defpath_edit_sel ~= main_defpath_edit_cursor then
                    local s = math.min(main_defpath_edit_cursor, main_defpath_edit_sel)
                    local e = math.max(main_defpath_edit_cursor, main_defpath_edit_sel)
                    local sel_x1 = gfx.measurestr(main_defpath_edit_text:sub(1, s)) - scroll_px
                    local sel_x2 = gfx.measurestr(main_defpath_edit_text:sub(1, e)) - scroll_px
                    sel_x1 = math.max(0, math.min(sel_x1, inner_w))
                    sel_x2 = math.max(0, math.min(sel_x2, inner_w))
                    gfx.set(0.17, 0.45, 0.39, 0.5)
                    gfx.rect(box_x + box_pad + sel_x1, cb_y + 2,
                             sel_x2 - sel_x1, cb_size - 4, 1)
                end
                if display_text == "" and not main_defpath_edit_active then
                    gfx.set(0.4, 0.4, 0.4, 1)
                    gfx.x = box_x + box_pad
                    gfx.y = text_y
                    gfx.drawstr(truncate_text("(paste or type path)", inner_w))
                else
                    gfx.set(table.unpack(colors.TEXT))
                    gfx.x = box_x + box_pad
                    gfx.y = text_y
                    if scroll_px > 0 then
                        local start_char = 0
                        for ci = 1, #display_text do
                            if gfx.measurestr(display_text:sub(1, ci)) > scroll_px then
                                start_char = ci - 1; break
                            end
                        end
                        gfx.drawstr(truncate_text(display_text:sub(start_char + 1), inner_w))
                    else
                        gfx.drawstr(truncate_text(display_text, inner_w))
                    end
                end
                -- Cursor
                if main_defpath_edit_active and math.floor(os.clock() * 2) % 2 == 0 then
                    local cursor_px = gfx.measurestr(main_defpath_edit_text:sub(1, main_defpath_edit_cursor))
                    local scroll_px = 0
                    if cursor_px > inner_w then scroll_px = cursor_px - inner_w + 10 end
                    gfx.set(1, 1, 1, 0.9)
                    local cx = box_x + box_pad + cursor_px - scroll_px
                    gfx.line(cx, cb_y + 2, cx, cb_y + cb_size - 2)
                end
                -- Radio checkbox
                local checked = get_extra_setting_checked(ikey)
                draw_checkbox(cb_x_pos, cb_y, cb_size, cb_x_pos, "", checked, colors, 0, nil)
            else
                -- Default simple checkbox for all other extras
                local checked = get_extra_setting_checked(ikey)
                draw_checkbox(cb_x_pos, cb_y, cb_size, label_x, item.label, checked, colors, nil, "extra_" .. ikey)
            end
        end
        visible_idx = visible_idx + 1
    end
    end -- end if not main_settings_folded
end

-- ============================================================================
-- SETTINGS VIEW (articulation checkboxes, symbol input, type selector)
-- ============================================================================
settings_save_hovered = false
settings_restore_hovered = false
settings_close_hovered = false
settings_import_hovered = false
settings_save_confirmed_until = 0  -- os.clock() time until which "Saved!" label is shown

-- Text input state for symbol editing
sym_edit_active = false   -- whether a symbol input is being edited
sym_edit_index = nil      -- index into articulation_names_ordered
sym_edit_text = ""        -- current text being edited
sym_edit_cursor = 0       -- cursor position in text

-- Text input state for default path editing
defpath_edit_active = false
defpath_edit_text = ""
defpath_edit_cursor = 0
defpath_edit_sel = -1      -- selection anchor (-1 = no selection)

-- Text input state for "Open with" path editing
openwith_edit_active = false
openwith_edit_text = ""
openwith_edit_cursor = 0
openwith_edit_sel = -1

-- Text input state for symbol editing in main view (separate from settings view)
main_sym_edit_active = false
main_sym_edit_index = nil      -- index into articulation_names_ordered
main_sym_edit_text = ""
main_sym_edit_cursor = 0

-- Text input state for default path editing in main view
main_defpath_edit_active = false
main_defpath_edit_text = ""
main_defpath_edit_cursor = 0
main_defpath_edit_sel = -1

-- ============================================================================
-- CUSTOM DARK MENU
-- ============================================================================
dark_menu = {
    active = false,         -- whether the menu is currently shown
    items = {},             -- all parsed items (flat)
    parent_items = {},      -- items shown in parent menu (headers if has_groups, all otherwise)
    x = 0, y = 0,          -- menu position (top-left of popup)
    width = 0,              -- computed menu width
    hovered_index = nil,    -- which parent item the mouse is over
    scroll_offset = 0,      -- scroll offset for long menus
    callback = nil,         -- function(choice_index) called when an item is selected (1-based, flat index)
    max_visible = 0,        -- max visible items
    has_groups = false,     -- true if menu has submenu groups
    opened_this_frame = false, -- true on the frame the menu was opened (skip click handling)
    submenu = {             -- child submenu state
        active = false,
        header_label = nil, -- which header owns this submenu
        header_index = 0,   -- index in parent_items
        items = {},         -- child items
        x = 0, y = 0,
        width = 0,
        hovered_index = nil,
        scroll_offset = 0,
        max_visible = 0,
    },
}
DARK_MENU_ITEM_SPACING = 4    -- vertical spacing between menu items (tweak this to adjust density)
DARK_MENU_ITEM_HEIGHT = 22 + DARK_MENU_ITEM_SPACING
DARK_MENU_PADDING = 6
DARK_MENU_MAX_VISIBLE = 20

-- Parse a gfx.showmenu-format string into dark_menu.items
function dark_menu_parse(menu_str)
    local items = {}
    local parts = {}
    local i = 1
    while i <= #menu_str do
        local sep = menu_str:find("|", i, true)
        if sep then
            table.insert(parts, menu_str:sub(i, sep - 1))
            i = sep + 1
        else
            table.insert(parts, menu_str:sub(i))
            break
        end
    end
    local current_group = nil
    for idx, part in ipairs(parts) do
        local label = part
        local checked = false
        local is_header = false
        local is_last_in_group = false
        if label:sub(1,1) == "!" then
            checked = true
            label = label:sub(2)
        end
        if label:sub(1,1) == ">" then
            is_header = true
            label = label:sub(2)
            current_group = label
        end
        if label:sub(1,1) == "<" then
            is_last_in_group = true
            label = label:sub(2)
        end
        table.insert(items, {
            label = label,
            checked = checked,
            is_header = is_header,
            group = current_group,
            flat_index = idx,
        })
        if is_last_in_group then
            current_group = nil
        end
    end
    return items
end

-- Get children of a header group
function dark_menu_get_children(header_label)
    local children = {}
    for _, item in ipairs(dark_menu.items) do
        if not item.is_header and item.group == header_label then
            table.insert(children, item)
        end
    end
    return children
end

-- Close only the submenu
function dark_menu_close_submenu()
    local s = dark_menu.submenu
    s.active = false
    s.header_label = nil
    s.header_index = 0
    s.items = {}
    s.hovered_index = nil
end

-- Open a submenu for a given parent header index
function dark_menu_open_submenu(header_idx)
    local m = dark_menu
    local header = m.parent_items[header_idx]
    local children = dark_menu_get_children(header.label)
    if #children == 0 then return end

    -- Position: to the right of parent, aligned with header row
    local vis_idx = header_idx - m.scroll_offset - 1
    local sub_y = m.y + 1 + vis_idx * DARK_MENU_ITEM_HEIGHT
    local sub_x = m.x + m.width - 1

    -- Measure submenu width
    local max_w = 100
    for _, item in ipairs(children) do
        local w = gfx.measurestr(item.label) + 16 + DARK_MENU_PADDING * 2 + 8
        if w > max_w then max_w = w end
    end

    local sub_visible = math.min(#children, DARK_MENU_MAX_VISIBLE)
    local sub_h = sub_visible * DARK_MENU_ITEM_HEIGHT + 2

    -- Prefer right side; only flip to left if truly no room on right
    if sub_x + max_w > gfx.w - 4 then
        -- Try shifting parent left to make room on the right
        local needed = sub_x + max_w - (gfx.w - 4)
        if m.x - needed >= 4 then
            -- Shift parent menu left
            m.x = m.x - needed
            sub_x = m.x + m.width - 1
        else
            -- No room even after shifting, flip to left
            sub_x = m.x - max_w + 1
        end
    end
    if sub_y + sub_h > gfx.h - 4 then sub_y = gfx.h - 4 - sub_h end
    if sub_y < 4 then sub_y = 4 end
    if sub_x < 4 then sub_x = 4 end

    m.submenu.active = true
    m.submenu.header_label = header.label
    m.submenu.header_index = header_idx
    m.submenu.items = children
    m.submenu.x = sub_x
    m.submenu.y = sub_y
    m.submenu.width = max_w
    m.submenu.hovered_index = nil
    m.submenu.scroll_offset = 0
    m.submenu.max_visible = sub_visible
end

-- Open the dark menu at position (x, y) with the given menu_str and callback
function open_dark_menu(menu_str, x, y, callback)
    local items = dark_menu_parse(menu_str)
    local has_groups = false
    for _, item in ipairs(items) do
        if item.is_header then has_groups = true; break end
    end
    dark_menu.items = items
    dark_menu.has_groups = has_groups

    -- Build parent items: headers only if has groups, all items otherwise
    local parent_items = {}
    if has_groups then
        for _, item in ipairs(items) do
            if item.is_header then table.insert(parent_items, item) end
        end
    else
        for _, item in ipairs(items) do
            table.insert(parent_items, item)
        end
    end
    dark_menu.parent_items = parent_items

    -- Measure parent menu width
    local max_w = 120
    for _, item in ipairs(parent_items) do
        local arrow_space = has_groups and 16 or 0
        local check_space = 16
        local w = gfx.measurestr(item.label) + check_space + arrow_space + DARK_MENU_PADDING * 2 + 8
        if w > max_w then max_w = w end
    end
    local visible = math.min(#parent_items, DARK_MENU_MAX_VISIBLE)
    local menu_h = visible * DARK_MENU_ITEM_HEIGHT + 2
    -- Clamp position (reserve space for submenu on right if grouped)
    local reserve_w = 0
    if has_groups then
        -- Estimate max submenu width to reserve space on the right
        for _, item in ipairs(items) do
            if not item.is_header then
                local w = gfx.measurestr(item.label) + 16 + DARK_MENU_PADDING * 2 + 8
                if w > reserve_w then reserve_w = w end
            end
        end
        if reserve_w < 100 then reserve_w = 100 end
    end
    if x + max_w + reserve_w > gfx.w - 4 then x = gfx.w - 4 - max_w - reserve_w end
    if y + menu_h > gfx.h - 4 then y = gfx.h - 4 - menu_h end
    if x < 4 then x = 4 end
    if y < 4 then y = 4 end
    dark_menu.active = true
    dark_menu.x = x
    dark_menu.y = y
    dark_menu.width = max_w
    dark_menu.max_visible = visible
    dark_menu.hovered_index = nil
    dark_menu.scroll_offset = 0
    dark_menu.callback = callback
    dark_menu.opened_this_frame = true
    dark_menu_close_submenu()
end

-- Close the dark menu completely
function close_dark_menu()
    dark_menu.active = false
    dark_menu.items = {}
    dark_menu.parent_items = {}
    dark_menu.callback = nil
    dark_menu.opened_this_frame = false
    dark_menu_close_submenu()
end

-- Open a right-click dock/undock context menu on the header
function open_header_dock_menu(mx, my)
    local cur_dock = gfx.dock(-1)
    local is_docked = (cur_dock & 1) ~= 0
    local menu_str
    if is_docked then
        menu_str = "Undock"
    else
        menu_str = "Dock to Bottom|Dock to Left|Dock to Top|Dock to Right"
    end
    open_dark_menu(menu_str, mx, my, function(idx)
        if is_docked then
            -- Undock
            gfx.dock(0)
            docker_enabled = false
            if gui.settings.Borderless_Window and window_script then
                reaper.JS_Window_SetStyle(window_script, "POPUP")
                reaper.JS_Window_AttachResizeGrip(window_script)
                local cur_exstyle = reaper.JS_Window_GetLong(window_script, "EXSTYLE")
                if cur_exstyle then
                    reaper.JS_Window_SetLong(window_script, "EXSTYLE", cur_exstyle | 0x10)
                end
            end
        else
            -- Dock: idx 1=Bottom,2=Left,3=Top,4=Right
            local dock_vals = {769, 257, 513, 1}
            local val = dock_vals[idx]
            if val then
                docker_enabled = true
                docker_position = idx
                gfx.dock(val)
            end
        end
    end)
end

-- Helper: draw a single menu panel (background, border, items, scroll arrows)
function dark_menu_draw_panel(px, py, pw, p_items, p_visible, p_scroll, p_hovered, is_parent)
    local item_h = DARK_MENU_ITEM_HEIGHT
    local total = #p_items
    local menu_h = p_visible * item_h + 2
    local max_scroll = math.max(0, total - p_visible)

    -- Shadow
    gfx.set(0, 0, 0, 0.4)
    gfx.rect(px + 2, py + 2, pw, menu_h, 1)
    -- Background
    gfx.set(0.18, 0.18, 0.18, 0.98)
    gfx.rect(px, py, pw, menu_h, 1)
    -- Border
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.rect(px, py, pw, menu_h, 0)

    -- Items
    for vi = 0, p_visible - 1 do
        local idx = vi + p_scroll + 1
        if idx > total then break end
        local item = p_items[idx]
        local iy = py + 1 + vi * item_h

        -- Hover highlight
        if idx == p_hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
            gfx.rect(px + 1, iy, pw - 2, item_h, 1)
        end

        -- Highlight active submenu header in parent
        if is_parent and dark_menu.has_groups and dark_menu.submenu.active
           and item.label == dark_menu.submenu.header_label and idx ~= p_hovered then
            gfx.set(0.15, 0.35, 0.3, 1)
            gfx.rect(px + 1, iy, pw - 2, item_h, 1)
        end

        -- Text color
        gfx.set(0.9, 0.9, 0.9, 1)
        if item.is_header then gfx.set(1, 1, 1, 1) end

        -- Checkmark
        local check_w = 16
        if item.checked then
            gfx.x = px + DARK_MENU_PADDING
            gfx.y = iy + (item_h - gfx.texth) / 2
            gfx.drawstr("\xE2\x9C\x93")
        end

        -- Label
        gfx.x = px + DARK_MENU_PADDING + check_w
        gfx.y = iy + (item_h - gfx.texth) / 2
        gfx.drawstr(item.label)

        -- Submenu arrow for parent headers
        if is_parent and dark_menu.has_groups and item.is_header then
            local arrow = "\xE2\x96\xB8"
            local aw = gfx.measurestr(arrow)
            gfx.x = px + pw - aw - DARK_MENU_PADDING
            gfx.y = iy + (item_h - gfx.texth) / 2
            gfx.set(0.6, 0.6, 0.6, 1)
            gfx.drawstr(arrow)
        end
    end

    -- Scroll indicators
    if p_scroll > 0 then
        gfx.set(0.7, 0.7, 0.7, 1)
        local arrow = "\xE2\x96\xB2"
        local aw = gfx.measurestr(arrow)
        gfx.x = px + pw - aw - 6
        gfx.y = py + 2
        gfx.drawstr(arrow)
    end
    if p_scroll < max_scroll then
        gfx.set(0.7, 0.7, 0.7, 1)
        local arrow = "\xE2\x96\xBC"
        local aw = gfx.measurestr(arrow)
        gfx.x = px + pw - aw - 6
        gfx.y = py + menu_h - gfx.texth - 2
        gfx.drawstr(arrow)
    end
end

-- Draw the dark menu and handle input. Returns true if menu consumed the input.
function draw_and_handle_dark_menu(mouse_x, mouse_y, mouse_clicked, mouse_released, char_input)
    if not dark_menu.active then return false end

    local m = dark_menu
    local s = m.submenu
    local item_h = DARK_MENU_ITEM_HEIGHT
    local p_total = #m.parent_items
    local p_visible = m.max_visible
    local p_menu_h = p_visible * item_h + 2
    local p_max_scroll = math.max(0, p_total - p_visible)

    -- Submenu dimensions
    local s_total = s.active and #s.items or 0
    local s_visible = s.active and s.max_visible or 0
    local s_menu_h = s_visible * item_h + 2
    local s_max_scroll = math.max(0, s_total - s_visible)

    -- Escape key: close submenu first, then parent
    if char_input and char_input == 27 then
        if s.active then
            dark_menu_close_submenu()
        else
            close_dark_menu()
        end
        return true
    end

    -- Check if mouse is inside parent panel
    local in_parent = mouse_x >= m.x and mouse_x < m.x + m.width and
                      mouse_y >= m.y and mouse_y < m.y + p_menu_h
    -- Check if mouse is inside submenu panel
    local in_sub = s.active and mouse_x >= s.x and mouse_x < s.x + s.width and
                   mouse_y >= s.y and mouse_y < s.y + s_menu_h

    -- Mousewheel
    if gfx.mouse_wheel ~= 0 then
        if in_sub then
            local delta = -math.floor(gfx.mouse_wheel / 120)
            s.scroll_offset = s.scroll_offset + delta
            if s.scroll_offset < 0 then s.scroll_offset = 0 end
            if s.scroll_offset > s_max_scroll then s.scroll_offset = s_max_scroll end
            gfx.mouse_wheel = 0
        elseif in_parent then
            local delta = -math.floor(gfx.mouse_wheel / 120)
            m.scroll_offset = m.scroll_offset + delta
            if m.scroll_offset < 0 then m.scroll_offset = 0 end
            if m.scroll_offset > p_max_scroll then m.scroll_offset = p_max_scroll end
            gfx.mouse_wheel = 0
        end
    end

    -- Determine hovered item in parent
    m.hovered_index = nil
    if in_parent and not in_sub then
        local rel_y = mouse_y - (m.y + 1)
        local vis_idx = math.floor(rel_y / item_h)
        local abs_idx = vis_idx + m.scroll_offset + 1
        if abs_idx >= 1 and abs_idx <= p_total then
            m.hovered_index = abs_idx
        end
    end

    -- Determine hovered item in submenu
    if s.active then
        s.hovered_index = nil
        if in_sub then
            local rel_y = mouse_y - (s.y + 1)
            local vis_idx = math.floor(rel_y / item_h)
            local abs_idx = vis_idx + s.scroll_offset + 1
            if abs_idx >= 1 and abs_idx <= s_total then
                s.hovered_index = abs_idx
            end
        end
    end

    -- Hover-to-switch: when hovering a different header while submenu is open
    if m.has_groups and s.active and m.hovered_index then
        local hi = m.parent_items[m.hovered_index]
        if hi and hi.is_header and hi.label ~= s.header_label then
            dark_menu_open_submenu(m.hovered_index)
            -- Refresh submenu locals
            s = m.submenu
            s_total = #s.items
            s_visible = s.max_visible
            s_menu_h = s_visible * item_h + 2
            s_max_scroll = math.max(0, s_total - s_visible)
            in_sub = mouse_x >= s.x and mouse_x < s.x + s.width and
                     mouse_y >= s.y and mouse_y < s.y + s_menu_h
        end
    end

    -- Handle click (skip on the frame the menu was opened)
    if m.opened_this_frame then
        m.opened_this_frame = false
    elseif mouse_clicked then
        if in_sub and s.hovered_index then
            -- Click on submenu item -> select it
            local si = s.items[s.hovered_index]
            local choice = si.flat_index
            local cb = m.callback
            close_dark_menu()
            if cb then cb(choice) end
            return true
        elseif in_parent and m.hovered_index then
            local pi = m.parent_items[m.hovered_index]
            if m.has_groups and pi.is_header then
                -- Click on header -> open/toggle its submenu
                if s.active and s.header_label == pi.label then
                    dark_menu_close_submenu()
                else
                    dark_menu_open_submenu(m.hovered_index)
                end
            else
                -- Click on flat item (no groups) -> select it
                local choice = pi.flat_index
                local cb = m.callback
                close_dark_menu()
                if cb then cb(choice) end
                return true
            end
        elseif not in_parent and not in_sub then
            -- Clicked outside both panels
            close_dark_menu()
            return true
        end
    end

    -- Draw parent panel
    dark_menu_draw_panel(m.x, m.y, m.width, m.parent_items, p_visible, m.scroll_offset, m.hovered_index, true)

    -- Draw submenu panel (on top)
    if s.active then
        dark_menu_draw_panel(s.x, s.y, s.width, s.items, s.max_visible, s.scroll_offset, s.hovered_index, false)
    end

    return true  -- menu is active, consumed frame
end

-- Tooltip definitions for column headers and special elements
settings_tooltips = {
    Sym   = "Symbol text written as event.\nClick to edit, Enter to confirm.",
    Type  = "Event type: Text (note-level),\nMarker (below tab), Cue (above tab).\nMousewheel to cycle.",
    RF    = "Replace Fret: when checked,\nthis articulation replaces the\nfret number instead of adding\na separate event.",
    Prefix = "Underscore Prefix: when checked,\nthe symbol is prefixed with '_'\nfor note-level text events.",
    On    = "Enable/Disable: when unchecked,\nthis articulation will be skipped\nduring import.",
    M     = "Show in Main Menu: when checked,\nthis setting will appear as a\ncheckbox in the main window.",
    Fret  = "Fret Number: the base fret number\nwritten as a text event. Disable to\nskip fret numbers entirely.",
    FretType = "Event type for fret numbers.\nMousewheel to cycle.",
}

-- Tooltip state
settings_tooltip_text = nil  -- current tooltip to show
settings_tooltip_x = 0
settings_tooltip_y = 0

-- Draw a tooltip box near the given position
function draw_tooltip(text, mx, my)
    if not text then return end
    local pad = 6
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        table.insert(lines, line)
    end
    local max_w = 0
    for _, line in ipairs(lines) do
        local lw = gfx.measurestr(line)
        if lw > max_w then max_w = lw end
    end
    local box_w = max_w + pad * 2
    local box_h = #lines * gfx.texth + pad * 2
    -- Position: below and to the right of mouse, clamped to window
    local tx = mx + 12
    local ty = my + 16
    if tx + box_w > gfx.w - 4 then tx = gfx.w - 4 - box_w end
    if ty + box_h > gfx.h - 4 then ty = my - box_h - 4 end
    if tx < 4 then tx = 4 end
    if ty < 4 then ty = 4 end
    -- Background
    gfx.set(0.12, 0.12, 0.14, 0.95)
    gfx.rect(tx, ty, box_w, box_h, 1)
    -- Border
    gfx.set(0.35, 0.35, 0.4, 1)
    gfx.rect(tx, ty, box_w, box_h, 0)
    -- Text
    gfx.set(0.85, 0.85, 0.85, 1)
    for i, line in ipairs(lines) do
        gfx.x = tx + pad
        gfx.y = ty + pad + (i - 1) * gfx.texth
        gfx.drawstr(line)
    end
end

function draw_settings_view(mouse_x, mouse_y, mouse_clicked, mouse_released, screen_x, screen_y, mouse_down, char_input)
    -- Periodic MIDI articulation scan (only when highlight is enabled)
    if highlight_scan_enabled then
        local hash = compute_selection_hash()
        if hash ~= last_midi_scan_sel_hash then
            last_midi_scan_sel_hash = hash
            -- Reset to XML-only scan results first, then overlay MIDI scan
            scan_articulations_in_xml()
            scan_articulations_in_midi()
        end
    end

    -- Clear text elements for this frame
    text_elements_frame = {}

    -- Header drag handling
    local header_hovered = (mouse_y > 0 and mouse_y < header_height)
    local rmb_clicked = (gfx.mouse_cap & 2 ~= 0) and (last_mouse_cap & 2 == 0)
    if rmb_clicked and header_hovered then
        open_header_dock_menu(mouse_x, mouse_y)
    end
    if mouse_clicked and header_hovered and not RS.active then
        is_dragging = true
        drag_offset_x = mouse_x
        drag_offset_y = mouse_y
    end
    if is_dragging and window_script then
        local new_x = math.floor(screen_x - drag_offset_x)
        local new_y = math.floor(screen_y - drag_offset_y)
        reaper.JS_Window_Move(window_script, new_x, new_y)
    end
    if mouse_released then
        is_dragging = false
        settings_sb_dragging = false
    end

    -- Button area
    local btn_height = 30
    local btn_spacing = 10
    local btn_width = math.min(130, math.max(40, math.floor((gfx.w - horizontal_margin * 2 - btn_spacing * 3) / 4)))
    local total_btn_width = btn_width * 4 + btn_spacing * 3
    local btn_y = gfx.h - btn_height - 10
    local btn_start_x = math.floor((gfx.w - total_btn_width) / 2)

    local import_btn_x = btn_start_x
    local save_btn_x = import_btn_x + btn_width + btn_spacing
    local restore_btn_x = save_btn_x + btn_width + btn_spacing
    local close_btn_x = restore_btn_x + btn_width + btn_spacing

    -- Content area (visible region between header and buttons)
    local content_top = header_height + vertical_margin
    local content_bottom = btn_y - 10
    local visible_h = content_bottom - content_top

    -- Section header height
    local section_hdr_h = math.floor(checkbox_row_height * 0.7)

    -- Layout: compute virtual positions (before scroll)
    local vy = content_top

    -- Helper: advance vy or return offscreen if folded
    local function next_row(folded)
        if folded then return -9999 end
        local y = vy; vy = vy + checkbox_row_height; return y
    end

    -- GENERAL section
    local general_hdr_y = vy; vy = vy + section_hdr_h
    local gf = settings_fold.general
    local autofocus_row_y = next_row(gf)
    local stayontop_row_y = next_row(gf)
    local font_row_y = next_row(gf)
    local docker_row_y = next_row(gf)
    local winpos_last_row_y = next_row(gf)
    local winpos_mouse_row_y = next_row(gf)
    local winsize_row_y = next_row(gf)
    local defpath_row_y = next_row(gf)
    local lastpath_row_y = next_row(gf)
    local tips_row_y = next_row(gf)

    -- EXPORT section
    local export_hdr_y = vy; vy = vy + section_hdr_h
    local ef = settings_fold.export
    local expreg_row_y = next_row(ef)
    local midibank_row_y = next_row(ef)
    local keysig_row_y = next_row(ef)
    local openwith_row_y = next_row(ef)
    local openfolder_row_y = next_row(ef)

    -- IMPORT section
    local import_hdr_y = vy; vy = vy + section_hdr_h
    local imf = settings_fold.import
    local import_row_y = {}
    for i = 1, #checkboxes_list do
        import_row_y[i] = next_row(imf)
    end
    local gmname_row_y = next_row(imf)
    local autoloadrgn_row_y = next_row(imf)
    local timebase_row_y = next_row(imf)
    local alignstem_row_y = next_row(imf)
    local importpos_row_y = next_row(imf)
    local onsetitem_row_y = next_row(imf)
    local imdup = {}
    imdup.tempofreq    = next_row(imf)
    imdup.tempotimesig = next_row(imf)
    imdup.detectmethod = next_row(imf)

    -- TRANSIENTS section
    local transients_hdr_y = vy; vy = vy + section_hdr_h
    local trf = settings_fold.transients
    local stretchmarkers_row_y = next_row(trf)
    local threshold_row_y = next_row(trf)
    local sensitivity_row_y = next_row(trf)
    local retrig_row_y = next_row(trf)
    local offset_row_y = next_row(trf)
    local del_sm_row_y = next_row(trf)
    local sm_nudge_row_y = next_row(trf)
    local sm_snap_row_y = next_row(trf)
    -- Big Detect Transients button (file_info_height tall), last in section
    local detect_transients_row_y
    if trf then detect_transients_row_y = -9999 else detect_transients_row_y = vy; vy = vy + file_info_height end

    -- TEMPO MAP section
    local tempomap_hdr_y = vy; vy = vy + section_hdr_h
    local tmf = settings_fold.tempomap
    local tempofreq_row_y = next_row(tmf)
    local tempotimesig_row_y = next_row(tmf)
    local detectmethod_row_y = next_row(tmf)
    local detectitem_row_y = next_row(tmf)
    local useexisting_row_y = next_row(tmf)
    local remap_row_y = next_row(tmf)
    local del_tempo_row_y = next_row(tmf)
    local tempo_nudge_row_y = next_row(tmf)
    local tempo_snap_row_y = next_row(tmf)
    -- Big Detect Tempo button (file_info_height tall), last in section
    local detecttempo_row_y
    if tmf then detecttempo_row_y = -9999 else detecttempo_row_y = vy; vy = vy + file_info_height end

    -- MIDI TOOLS section
    local miditools_hdr_y = vy; vy = vy + section_hdr_h
    local mtf = settings_fold.miditools
    local midi_sm_row_y       = next_row(mtf)
    local midi_tm_insert_row_y = next_row(mtf)   -- Insert TM at cursor button
    local midi_tm_move_row_y   = next_row(mtf)   -- Move take marker slider
    local midi_tm_stretch_row_y = next_row(mtf)  -- Move + stretch notes slider
    local midi_tm_snap_row_y      = next_row(mtf)  -- TM Grid Snap toggle
    local midi_tm_snap_note_row_y = next_row(mtf)  -- Snap TM to Note button
    local midi_tm_autosnap_row_y  = next_row(mtf)  -- Auto-snap TM to note edge checkbox
    local midi_tm_reset_row_y     = next_row(mtf)  -- Reset TM button
    local nudge_row_y = next_row(mtf)            -- Nudge to Transients button

    -- INSERT AT MOUSE section
    local iam_hdr_y = vy; vy = vy + section_hdr_h
    local iamf = settings_fold.insertmouse
    local iam_stretch_row_y  = next_row(iamf)
    local iam_take_tm_row_y  = next_row(iamf)
    local iam_tempo_row_y    = next_row(iamf)

    -- ARTICULATION section
    local art_hdr_y = vy; vy = vy + section_hdr_h
    local af = settings_fold.articulation
    local hlscan_row_y = next_row(af)
    local fret_row_y = next_row(af)
    local span_row_y = next_row(af)
    local separator_y = af and -9999 or vy
    local col_header_h = math.floor(gfx.texth) + 4
    local col_header_y = af and -9999 or (separator_y + 4)
    if not af then vy = separator_y + 2 + col_header_h + 2 end
    local list_top = af and -9999 or vy
    local total_items = #articulation_names_ordered
    if not af then vy = vy + total_items * checkbox_row_height end

    -- ARTICULATION GRID section (Guitar Pro style)
    local artgrid_hdr_y = vy; vy = vy + section_hdr_h
    local artgrid_top
    do -- compute artgrid content height inline to save outer locals
        local gap, cols = 2, 8
        local bsz = math.max(16, math.floor((gfx.w - 2 * horizontal_margin - (cols - 1) * gap) / cols))
        local s1h = 5 * (bsz + gap) - gap
        local s2h = 7 * (bsz + gap) - gap
        artgrid_top = settings_fold.artgrid and -9999 or vy
        if not settings_fold.artgrid then vy = vy + s1h + 6 + s2h + 8 end
    end

    -- Scroll
    local total_content_h = vy - content_top
    local max_scroll = math.max(0, total_content_h - visible_h)
    if settings_scroll_offset > max_scroll then settings_scroll_offset = max_scroll end
    if settings_scroll_offset < 0 then settings_scroll_offset = 0 end

    -- Scrollbar geometry (needed for both input and drawing)
    local scrollbar_width = 8
    local scrollbar_x = gfx.w - scrollbar_width - 4
    local scrollbar_track_height = visible_h
    local sb_thumb_height = math.max(20, math.floor(scrollbar_track_height * visible_h / math.max(1, total_content_h)))
    local sb_current_max = math.max(1, max_scroll)
    local sb_thumb_y = content_top + math.floor((scrollbar_track_height - sb_thumb_height) * settings_scroll_offset / sb_current_max)

    -- Scrollbar drag: start
    if mouse_clicked and max_scroll > 0 and not dark_menu.active and not gui_msgbox.active then
        if mouse_x >= scrollbar_x and mouse_x <= scrollbar_x + scrollbar_width and
           mouse_y >= sb_thumb_y and mouse_y <= sb_thumb_y + sb_thumb_height then
            settings_sb_dragging = true
            settings_sb_drag_start_y = mouse_y
            settings_sb_drag_start_offset = settings_scroll_offset
        end
    end

    -- Scrollbar drag: update
    if settings_sb_dragging and mouse_down and max_scroll > 0 then
        local drag_delta = mouse_y - settings_sb_drag_start_y
        local track_usable = scrollbar_track_height - sb_thumb_height
        if track_usable > 0 then
            settings_scroll_offset = settings_sb_drag_start_offset + math.floor(drag_delta * max_scroll / track_usable)
            if settings_scroll_offset < 0 then settings_scroll_offset = 0 end
            if settings_scroll_offset > max_scroll then settings_scroll_offset = max_scroll end
        end
    end

    local scroll_y = settings_scroll_offset

    -- Apply scroll offset to all positions
    general_hdr_y = general_hdr_y - scroll_y
    autofocus_row_y = autofocus_row_y - scroll_y
    stayontop_row_y = stayontop_row_y - scroll_y
    font_row_y = font_row_y - scroll_y
    docker_row_y = docker_row_y - scroll_y
    winpos_last_row_y = winpos_last_row_y - scroll_y
    winpos_mouse_row_y = winpos_mouse_row_y - scroll_y
    winsize_row_y = winsize_row_y - scroll_y
    defpath_row_y = defpath_row_y - scroll_y
    lastpath_row_y = lastpath_row_y - scroll_y
    tips_row_y = tips_row_y - scroll_y
    export_hdr_y = export_hdr_y - scroll_y
    expreg_row_y = expreg_row_y - scroll_y
    midibank_row_y = midibank_row_y - scroll_y
    keysig_row_y = keysig_row_y - scroll_y
    openwith_row_y = openwith_row_y - scroll_y
    openfolder_row_y = openfolder_row_y - scroll_y
    import_hdr_y = import_hdr_y - scroll_y
    for i = 1, #checkboxes_list do
        import_row_y[i] = import_row_y[i] - scroll_y
    end
    gmname_row_y = gmname_row_y - scroll_y
    importpos_row_y = importpos_row_y - scroll_y
    autoloadrgn_row_y = autoloadrgn_row_y - scroll_y
    timebase_row_y = timebase_row_y - scroll_y
    transients_hdr_y = transients_hdr_y - scroll_y
    stretchmarkers_row_y = stretchmarkers_row_y - scroll_y
    threshold_row_y = threshold_row_y - scroll_y
    sensitivity_row_y = sensitivity_row_y - scroll_y
    retrig_row_y = retrig_row_y - scroll_y
    offset_row_y = offset_row_y - scroll_y
    del_sm_row_y = del_sm_row_y - scroll_y
    sm_nudge_row_y = sm_nudge_row_y - scroll_y
    sm_snap_row_y = sm_snap_row_y - scroll_y
    detect_transients_row_y = detect_transients_row_y - scroll_y
    tempomap_hdr_y = tempomap_hdr_y - scroll_y
    tempofreq_row_y = tempofreq_row_y - scroll_y
    tempotimesig_row_y = tempotimesig_row_y - scroll_y
    detectmethod_row_y = detectmethod_row_y - scroll_y
    detectitem_row_y = detectitem_row_y - scroll_y
    useexisting_row_y = useexisting_row_y - scroll_y
    alignstem_row_y = alignstem_row_y - scroll_y
    onsetitem_row_y = onsetitem_row_y - scroll_y
    imdup.tempofreq    = imdup.tempofreq    - scroll_y
    imdup.tempotimesig = imdup.tempotimesig - scroll_y
    imdup.detectmethod = imdup.detectmethod - scroll_y
    remap_row_y = remap_row_y - scroll_y
    del_tempo_row_y = del_tempo_row_y - scroll_y
    tempo_nudge_row_y = tempo_nudge_row_y - scroll_y
    tempo_snap_row_y = tempo_snap_row_y - scroll_y
    detecttempo_row_y = detecttempo_row_y - scroll_y
    miditools_hdr_y = miditools_hdr_y - scroll_y
    midi_sm_row_y = midi_sm_row_y - scroll_y
    midi_tm_insert_row_y  = midi_tm_insert_row_y  - scroll_y
    midi_tm_move_row_y    = midi_tm_move_row_y    - scroll_y
    midi_tm_stretch_row_y = midi_tm_stretch_row_y - scroll_y
    midi_tm_snap_row_y      = midi_tm_snap_row_y      - scroll_y
    midi_tm_snap_note_row_y = midi_tm_snap_note_row_y - scroll_y
    midi_tm_autosnap_row_y  = midi_tm_autosnap_row_y  - scroll_y
    midi_tm_reset_row_y     = midi_tm_reset_row_y     - scroll_y
    nudge_row_y = nudge_row_y - scroll_y
    iam_hdr_y = iam_hdr_y - scroll_y
    iam_stretch_row_y  = iam_stretch_row_y  - scroll_y
    iam_take_tm_row_y  = iam_take_tm_row_y  - scroll_y
    iam_tempo_row_y    = iam_tempo_row_y    - scroll_y
    art_hdr_y = art_hdr_y - scroll_y
    hlscan_row_y = hlscan_row_y - scroll_y
    fret_row_y = fret_row_y - scroll_y
    span_row_y = span_row_y - scroll_y
    separator_y = separator_y - scroll_y
    col_header_y = col_header_y - scroll_y
    list_top = list_top - scroll_y
    artgrid_hdr_y = artgrid_hdr_y - scroll_y
    artgrid_top = artgrid_top - scroll_y

    -- Visibility helper
    local function is_row_visible(y) return y + checkbox_row_height > content_top and y < content_bottom end

    -- Right-side element positions:
    -- [name_label] ... [sym_box] [type_btn] [repl_fret_cb] [prefix_cb] [enabled_cb] [menu_cb]
    local menu_cb_x = gfx.w - horizontal_margin - checkbox_size
    local cb_x = menu_cb_x - COL_SPACING - checkbox_size
    local prefix_cb_x = cb_x - COL_SPACING - checkbox_size
    local repl_col_x = prefix_cb_x - COL_SPACING - REPL_COL_WIDTH
    local repl_cb_x = repl_col_x + math.floor((REPL_COL_WIDTH - checkbox_size) / 2)
    local type_btn_x = repl_col_x - COL_SPACING - TYPE_BTN_WIDTH
    local sym_box_x = type_btn_x - COL_SPACING - SYM_BOX_WIDTH
    local name_max_w = sym_box_x - horizontal_margin - COL_SPACING

    -- Button left edge for non-articulation rows (font/docker/midibank)
    -- Uses art column alignment when wide enough, falls back to label-based position
    local _sett_label_floor = horizontal_margin + math.max(
        gfx.measurestr("MIDI Program Banks  "),
        gfx.measurestr("Key Signature  "),
        gfx.measurestr("Font  "),
        gfx.measurestr("Docker  ")) + 4
    local sett_simple_btn_x = math.max(sym_box_x, _sett_label_floor)

    do -- scope: click + keyboard + mousewheel handlers (free locals before drawing)
    -- Handle stretch marker slider drag (continues while mouse is held down)
    -- All sliders apply instantly: detection is cached at minimum settings,
    -- post-filtering is O(N) over candidates (microseconds).
    if sm_slider_dragging then
        if mouse_down then
            local slider_x = sett_simple_btn_x
            local slider_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            local frac = (mouse_x - slider_x) / slider_w
            frac = math.max(0, math.min(1, frac))
            local val_changed = false
            if sm_slider_dragging == "threshold" then
                local new_val = math.max(0, math.min(60, math.floor(frac * 60 + 0.5)))
                if new_val ~= sm_threshold_dB then sm_threshold_dB = new_val; val_changed = true end
            elseif sm_slider_dragging == "sensitivity" then
                local new_val = math.max(1, math.min(20, math.floor(frac * 19 + 0.5) + 1))
                if new_val ~= sm_sensitivity_dB then sm_sensitivity_dB = new_val; val_changed = true end
            elseif sm_slider_dragging == "retrig" then
                local new_val = math.max(10, math.min(500, math.floor(frac * 490 + 0.5) + 10))
                if new_val ~= sm_retrig_ms then sm_retrig_ms = new_val; val_changed = true end
            elseif sm_slider_dragging == "offset" then
                local new_val = math.max(-100, math.min(100, math.floor((frac * 200 - 100) + 0.5)))
                if new_val ~= sm_offset_ms then sm_offset_ms = new_val; val_changed = true end
            end
            if val_changed then
                local sm_item, sm_take = get_detect_tempo_item()
                if sm_item and sm_take then
                    apply_cached_stretch_markers(sm_item, sm_take)
                end
            end
        else
            -- Mouse released: save settings
            sm_slider_dragging = nil
            save_articulation_settings()
        end
    end

    -- Handle SM nudge slider drag (moves nearest stretch marker to edit cursor)
    if sm_nudge_slider_dragging then
        if mouse_down then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            local dx = mouse_x - sm_nudge_drag_start_x
            local new_val = math.max(-500, math.min(500, math.floor(sm_nudge_drag_start_val + dx / sl_w * 1000 + 0.5)))
            if new_val ~= sm_nudge_value then
                sm_nudge_value = new_val
                if sm_nudge_idx >= 0 and sm_nudge_take then
                    -- Slide behavior: move both timeline pos and srcpos by the same delta
                    -- so the marker moves on the timeline without changing the playback rate.
                    local delta_s = sm_nudge_value / 1000
                    local new_pos    = sm_nudge_orig_src    + delta_s
                    local new_srcpos = sm_nudge_orig_srcpos + delta_s
                    reaper.PreventUIRefresh(1)
                    reaper.DeleteTakeStretchMarkers(sm_nudge_take, sm_nudge_idx)
                    local new_idx = reaper.SetTakeStretchMarker(sm_nudge_take, sm_nudge_idx, new_pos, new_srcpos)
                    if new_idx >= 0 then sm_nudge_idx = new_idx end
                    reaper.UpdateTimeline()
                    reaper.PreventUIRefresh(-1)
                end
            end
        else
            -- Release: commit undo block and reset
            sm_nudge_slider_dragging = false
            if sm_nudge_undo_open then
                reaper.Undo_EndBlock("Nudge stretch marker", -1)
                sm_nudge_undo_open = false
            end
            sm_nudge_value = 0
            sm_nudge_item = nil; sm_nudge_take = nil; sm_nudge_idx = -1
        end
    end

    -- Handle Tempo nudge slider drag (moves nearest tempo marker to edit cursor)
    if tempo_nudge_slider_dragging then
        if mouse_down then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            local dx = mouse_x - tempo_nudge_drag_start_x
            local new_val = math.max(-500, math.min(500, math.floor(tempo_nudge_drag_start_val + dx / sl_w * 1000 + 0.5)))
            if new_val ~= tempo_nudge_value then
                tempo_nudge_value = new_val
                if tempo_nudge_idx >= 0 then
                    local new_t
                    if tempo_snap_to_sm_enabled then
                        -- Snap-incremental mode: snap to nearest stretch marker
                        local sm_positions = {}
                        for ii = 0, reaper.CountMediaItems(0) - 1 do
                            local it = reaper.GetMediaItem(0, ii)
                            local tk = reaper.GetActiveTake(it)
                            if tk and not reaper.TakeIsMIDI(tk) then
                                local ip = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                                for si = 0, reaper.GetTakeNumStretchMarkers(tk) - 1 do
                                    local _, smp = reaper.GetTakeStretchMarker(tk, si)
                                    sm_positions[#sm_positions + 1] = ip + smp
                                end
                            end
                        end
                        local target_t = tempo_nudge_orig_t + new_val / 1000
                        local nearest_t = tempo_nudge_orig_t
                        local nearest_dist = math.huge
                        for _, sp in ipairs(sm_positions) do
                            local d = math.abs(sp - target_t)
                            if d < nearest_dist then nearest_dist = d; nearest_t = sp end
                        end
                        new_t = nearest_t
                    else
                        new_t = tempo_nudge_orig_t + tempo_nudge_value / 1000
                    end
                    reaper.PreventUIRefresh(1)
                    -- Adjust the previous tempo marker's BPM to preserve beat count
                    -- in the region [prev_t .. new_t], so the musical grid stays aligned.
                    if tempo_nudge_prev_idx >= 0 and new_t > tempo_nudge_prev_t + 0.0001 then
                        local span_orig = tempo_nudge_orig_t - tempo_nudge_prev_t
                        local span_new  = new_t - tempo_nudge_prev_t
                        local adj_bpm = tempo_nudge_prev_bpm * span_orig / span_new
                        reaper.DeleteTempoTimeSigMarker(0, tempo_nudge_prev_idx)
                        reaper.SetTempoTimeSigMarker(0, -1, tempo_nudge_prev_t, -1, -1,
                            adj_bpm, tempo_nudge_prev_tsn, tempo_nudge_prev_tsd, tempo_nudge_prev_lin)
                    end
                    -- Rebuild index map since DeleteTempoTimeSigMarker may shift indices
                    -- Re-find the nudged marker and previous marker by their original times
                    reaper.DeleteTempoTimeSigMarker(0,
                        (function()
                            for mi = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
                                local rv2, t2 = reaper.GetTempoTimeSigMarker(0, mi)
                                if rv2 and math.abs(t2 - tempo_nudge_orig_t) < 0.001 then return mi end
                            end
                            return tempo_nudge_idx
                        end)()
                    )
                    reaper.SetTempoTimeSigMarker(0, -1, new_t, -1, -1,
                        tempo_nudge_orig_bpm, tempo_nudge_orig_tsn, tempo_nudge_orig_tsd, tempo_nudge_orig_lin)
                    -- Re-find updated indices
                    for mi = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
                        local rv2, t2 = reaper.GetTempoTimeSigMarker(0, mi)
                        if rv2 and math.abs(t2 - new_t) < 0.001 then tempo_nudge_idx = mi end
                        if rv2 and tempo_nudge_prev_idx >= 0 and math.abs(t2 - tempo_nudge_prev_t) < 0.001 then
                            tempo_nudge_prev_idx = mi
                        end
                    end
                    reaper.UpdateTimeline()
                    reaper.PreventUIRefresh(-1)
                end
            end
        else
            tempo_nudge_slider_dragging = false
            if tempo_nudge_undo_open then
                reaper.Undo_EndBlock("Nudge tempo marker", -1)
                tempo_nudge_undo_open = false
            end
            tempo_nudge_value = 0
            tempo_nudge_idx = -1
            tempo_nudge_prev_idx = -1
        end
    end

    -- Handle MIDI TM Move slider drag (moves nearest rated take marker, no note change)
    if midi_tm_move_dragging then
        if mouse_down then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            local dx = mouse_x - midi_tm_move_drag_start_x
            local new_val = math.max(-500, math.min(500, math.floor(midi_tm_move_drag_start_val + dx / sl_w * 1000 + 0.5)))
            if new_val ~= midi_tm_move_value then
                midi_tm_move_value = new_val
                if midi_tm_move_mi >= 0 and midi_tm_move_take then
                    local new_srcpos = midi_tm_move_orig_s + midi_tm_move_value / 500 * 2 * midi_tm_move_beat_dur
                    -- Snap to grid if TM snap is enabled
                    if midi_tm_snap_enabled then
                        local ip_snap = reaper.GetMediaItemInfo_Value(midi_tm_move_item, "D_POSITION")
                        local ts_snap = reaper.GetMediaItemTakeInfo_Value(midi_tm_move_take, "D_STARTOFFS")
                        local proj_snap = reaper.SnapToGrid(0, ip_snap - ts_snap + new_srcpos)
                        new_srcpos = proj_snap - ip_snap + ts_snap
                    end
                    local _, _, color_c = reaper.GetTakeMarker(midi_tm_move_take, midi_tm_move_mi)
                    local cur_lbl = select(2, reaper.GetTakeMarker(midi_tm_move_take, midi_tm_move_mi))
                    -- Auto-snap to closest note edge if enabled
                    if midi_tm_autosnap_note_enabled then
                        new_srcpos = snap_tm_to_closest_note_silent(midi_tm_move_take, midi_tm_move_mi, new_srcpos)
                    end
                    reaper.SetTakeMarker(midi_tm_move_take, midi_tm_move_mi, cur_lbl or "1.00x", new_srcpos, color_c)
                    -- Keep cache in sync so check_midi_sm_changes doesn't fire on this move
                    local tk_key = tostring(midi_tm_move_take)
                    if midi_sm_state[tk_key] and midi_sm_state[tk_key].markers[midi_tm_move_mi + 1] then
                        midi_sm_state[tk_key].markers[midi_tm_move_mi + 1].last_s = new_srcpos
                    end
                    reaper.UpdateItemInProject(midi_tm_move_item)
                end
            end
        else
            midi_tm_move_dragging = false
            if midi_tm_move_undo_open then
                reaper.Undo_EndBlock("MIDI TM: move take marker", -1)
                midi_tm_move_undo_open = false
            end
            midi_tm_move_value = 0
            midi_tm_move_item = nil; midi_tm_move_take = nil; midi_tm_move_mi = -1
        end
    end

    -- Handle MIDI TM Stretch slider drag (moves take marker AND stretches notes)
    if midi_tm_stretch_dragging then
        if mouse_down then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            local dx = mouse_x - midi_tm_stretch_drag_start_x
            local new_val = math.max(-500, math.min(500, math.floor(midi_tm_stretch_drag_start_val + dx / sl_w * 1000 + 0.5)))
            if new_val ~= midi_tm_stretch_value then
                midi_tm_stretch_value = new_val
                if midi_tm_stretch_mi >= 0 and midi_tm_stretch_take then
                    local new_srcpos = midi_tm_stretch_orig_s + midi_tm_stretch_value / 500 * 2 * midi_tm_stretch_beat_dur
                    -- Compute item/take offsets (also used for snap)
                    local item_pos_d = reaper.GetMediaItemInfo_Value(midi_tm_stretch_item, "D_POSITION")
                    local take_so_d  = reaper.GetMediaItemTakeInfo_Value(midi_tm_stretch_take, "D_STARTOFFS")
                    -- Snap to grid if TM snap is enabled
                    if midi_tm_snap_enabled then
                        local proj_snap = reaper.SnapToGrid(0, item_pos_d - take_so_d + new_srcpos)
                        new_srcpos = proj_snap - item_pos_d + take_so_d
                    end
                    -- Auto-snap to closest note edge if enabled
                    if midi_tm_autosnap_note_enabled then
                        new_srcpos = snap_tm_to_closest_note_silent(midi_tm_stretch_take, midi_tm_stretch_mi, new_srcpos)
                    end
                    -- Piecewise warp from pristine backup (non-accumulating, no drift)
                    local tk_key_s = tostring(midi_tm_stretch_take)
                    local cached_s = midi_sm_state[tk_key_s]
                    -- Sync last_s so warp uses current position AND check_midi_sm_changes won't re-trigger
                    if cached_s and cached_s.markers[midi_tm_stretch_mi + 1] then
                        cached_s.markers[midi_tm_stretch_mi + 1].last_s = new_srcpos
                    end
                    reaper.PreventUIRefresh(1)
                    midi_sm_apply_piecewise_warp(tk_key_s)
                    -- Move the actual take marker (keep original label during drag, update rate on release)
                    local _, cur_lbl_s, color_cs = reaper.GetTakeMarker(midi_tm_stretch_take, midi_tm_stretch_mi)
                    reaper.SetTakeMarker(midi_tm_stretch_take, midi_tm_stretch_mi, cur_lbl_s or "1.00x", new_srcpos, color_cs)
                    -- Update rate display string for Warp TM slider
                    if cached_s then
                        local mkrs_d = cached_s.markers
                        local lo_d = mkrs_d[midi_tm_stretch_mi + 1].orig_s - ((midi_tm_stretch_mi > 0) and mkrs_d[midi_tm_stretch_mi].orig_s or 0)
                        local lc_d = new_srcpos - ((midi_tm_stretch_mi > 0) and mkrs_d[midi_tm_stretch_mi].last_s or 0)
                        midi_tm_stretch_display_str = (lc_d > 1e-7) and string.format("%.2fx", lo_d / lc_d) or "---"
                    end
                    reaper.PreventUIRefresh(-1)
                    reaper.UpdateItemInProject(midi_tm_stretch_item)
                    -- MIDI_Sort deferred to drag release for performance
                end
            end
        else
            -- Drag released: sort MIDI once, update rate labels, close undo
            if midi_tm_stretch_mi >= 0 and midi_tm_stretch_take then
                local new_srcpos = midi_tm_stretch_orig_s + midi_tm_stretch_value / 500 * 2 * midi_tm_stretch_beat_dur
                local tk_key = tostring(midi_tm_stretch_take)
                local mkrs = midi_sm_state[tk_key] and midi_sm_state[tk_key].markers
                if mkrs then
                    -- Update rate label for the moved marker (left span rate)
                    local prev_s  = (midi_tm_stretch_mi > 0) and mkrs[midi_tm_stretch_mi].last_s or 0
                    local left_orig = mkrs[midi_tm_stretch_mi + 1].orig_s - ((midi_tm_stretch_mi > 0) and mkrs[midi_tm_stretch_mi].orig_s or 0)
                    local left_curr = new_srcpos - prev_s
                    local rate_left = (left_curr > 1e-7) and (left_orig / left_curr) or 0
                    local _, _, color_c = reaper.GetTakeMarker(midi_tm_stretch_take, midi_tm_stretch_mi)
                    reaper.SetTakeMarker(midi_tm_stretch_take, midi_tm_stretch_mi, string.format("%.2fx", rate_left), new_srcpos, color_c)
                    -- Update rate label for the next marker (right span rate)
                    local next_idx = midi_tm_stretch_mi + 2
                    if next_idx <= #mkrs then
                        local right_orig = mkrs[next_idx].orig_s - mkrs[midi_tm_stretch_mi + 1].orig_s
                        local next_s     = mkrs[next_idx].last_s
                        local right_curr = next_s - new_srcpos
                        local rate_right = (right_curr > 1e-7) and (right_orig / right_curr) or 0
                        local next_curr_s, _, color_n = reaper.GetTakeMarker(midi_tm_stretch_take, next_idx - 1)
                        reaper.SetTakeMarker(midi_tm_stretch_take, next_idx - 1, string.format("%.2fx", rate_right), next_curr_s, color_n)
                    end
                end
                reaper.MIDI_Sort(midi_tm_stretch_take)
                reaper.UpdateItemInProject(midi_tm_stretch_item)
                -- Mark indices stale after MIDI_Sort
                local tk_key_ri = tostring(midi_tm_stretch_take)
                if midi_sm_state[tk_key_ri] then midi_sm_state[tk_key_ri].needs_reindex = true end
            end
            midi_tm_stretch_dragging = false
            if midi_tm_stretch_undo_open then
                reaper.Undo_EndBlock("MIDI TM: stretch notes", -1)
                midi_tm_stretch_undo_open = false
            end
            midi_tm_stretch_value = 0
            midi_tm_stretch_display_str = "1.00x"
            midi_tm_stretch_item = nil; midi_tm_stretch_take = nil; midi_tm_stretch_mi = -1
            midi_tm_stretch_note_cache = {}
        end
    end

    -- Handle clicks (skip when dark menu or gui msgbox is active)
    if mouse_clicked and not dark_menu.active and not gui_msgbox.active then
        -- Save button
        if settings_save_hovered then
            -- Commit any active edit first
            if sym_edit_active and sym_edit_index then
                local art_name = articulation_names_ordered[sym_edit_index]
                if sym_edit_text ~= articulation_default_symbol[art_name] then
                    articulation_symbol_override[art_name] = sym_edit_text
                else
                    articulation_symbol_override[art_name] = nil
                end
            end
            sym_edit_active = false
            sym_edit_index = nil
            -- Commit default path edit
            if defpath_edit_active then
                default_import_dir = defpath_edit_text
                save_default_import_dir(defpath_edit_text)
                defpath_edit_active = false
                defpath_edit_sel = -1
            end
            -- Commit Open With path edit
            if openwith_edit_active then
                export_open_with_path = openwith_edit_text
                openwith_edit_active = false
                openwith_edit_sel = -1
            end
            save_path_mode(path_mode)
            save_articulation_settings()
            save_import_settings()
            save_docker_settings()
            save_auto_focus_setting()
            save_stay_on_top_setting()
            save_font_setting()
            save_open_with_setting()
            save_open_folder_setting()
            save_key_sig_setting()
            save_settings_menu_flags()
            settings_save_confirmed_until = os.clock() + 1.5  -- show "Saved!" for 1.5 seconds
        end
        -- Restore defaults button
        if settings_restore_hovered then
            sym_edit_active = false
            sym_edit_index = nil
            restore_default_articulation_settings()
            -- Reset import checkboxes to defaults
            checkboxes_list[1].checked = true
            checkboxes_list[2].checked = true
            checkboxes_list[3].checked = true
            checkboxes_list[4].checked = true
            checkboxes_list[5].checked = false
            checkboxes_list[6].checked = false
            checkboxes_list[7].checked = true
            for _, cb in ipairs(checkboxes_list) do cb.show_in_menu = true end
            -- Reset settings menu flags
            for k in pairs(settings_menu_flags) do settings_menu_flags[k] = false end
            -- Clear default path
            default_import_dir = ""
            save_default_import_dir("")
            defpath_edit_active = false
            defpath_edit_sel = -1
            -- Clear Open With path
            openwith_edit_active = false
            openwith_edit_sel = -1
            -- Reset path mode to last
            path_mode = "last"
            save_path_mode("last")
            -- Reset docker and auto-focus
            auto_focus_enabled = true
            stay_on_top_enabled = true
            apply_stay_on_top()
            docker_enabled = false
            docker_position = 1
            remember_window_size = false
            save_remember_window_size_setting()
            current_font_index = 1
            gfx.setfont(1, font_list[1], gui.settings.font_size)
            import_position_index = 1
            settings_save_confirmed_until = 0  -- clear any "Saved!" label
        end
        -- Close settings button
        if settings_close_hovered then
            -- Commit any active edit
            if sym_edit_active and sym_edit_index then
                local art_name = articulation_names_ordered[sym_edit_index]
                if sym_edit_text ~= articulation_default_symbol[art_name] then
                    articulation_symbol_override[art_name] = sym_edit_text
                else
                    articulation_symbol_override[art_name] = nil
                end
            end
            sym_edit_active = false
            sym_edit_index = nil
            -- Commit default path edit on close
            if defpath_edit_active then
                default_import_dir = defpath_edit_text
                save_default_import_dir(defpath_edit_text)
                defpath_edit_active = false
                defpath_edit_sel = -1
            end
            -- Commit Open With path edit on close
            if openwith_edit_active then
                export_open_with_path = openwith_edit_text
                save_open_with_setting()
                openwith_edit_active = false
                openwith_edit_sel = -1
            end
            settings_mode = false
            close_dark_menu()
            -- Save settings tab size and restore main tab size
            save_window_size("settings")
            if remember_window_size then
                local sw, sh = load_window_size("main")
                if sw and sh then
                    gui.width = math.max(RS.MIN_W, math.min(sw, MAX_WINDOW_WIDTH))
                    gui.height = math.max(RS.MIN_H, math.min(sh, MAX_WINDOW_HEIGHT))
                else
                    gui.width = pre_settings_width or gui.width
                    gui.height = pre_settings_height or gui.height
                end
            else
                gui.width = pre_settings_width or gui.width
                gui.height = pre_settings_height or gui.height
            end
            resize_window()
            pre_settings_width = nil
            pre_settings_height = nil
            return
        end

        -- Import button (in settings view)
        if settings_import_hovered then
            if selected_file_path then
                -- Commit any active edit first
                if sym_edit_active and sym_edit_index then
                    local art_name = articulation_names_ordered[sym_edit_index]
                    if sym_edit_text ~= articulation_default_symbol[art_name] then
                        articulation_symbol_override[art_name] = sym_edit_text
                    else
                        articulation_symbol_override[art_name] = nil
                    end
                end
                sym_edit_active = false
                sym_edit_index = nil
                -- Commit default path edit on import
                if defpath_edit_active then
                    default_import_dir = defpath_edit_text
                    save_default_import_dir(defpath_edit_text)
                    defpath_edit_active = false
                    defpath_edit_sel = -1
                end
                -- Commit Open With path edit on import
                if openwith_edit_active then
                    export_open_with_path = openwith_edit_text
                    save_open_with_setting()
                    openwith_edit_active = false
                    openwith_edit_sel = -1
                end
                -- Build list of selected track names
                local selected_tracks = {}
                for _, tcb in ipairs(track_checkboxes) do
                    if tcb.checked then
                        table.insert(selected_tracks, get_track_display_name(tcb))
                    end
                end
                local options = {
                    import_markers = checkboxes_list[1].checked,
                    import_regions = checkboxes_list[2].checked,
                    import_midi_banks = checkboxes_list[3].checked,
                    import_key_sigs = checkboxes_list[4].checked,
                    insert_on_new_tracks = checkboxes_list[5].checked,
                    insert_on_existing_tracks = checkboxes_list[6].checked,
                    insert_on_tracks_by_name = checkboxes_list[7].checked,
                    align_to_audio = (import_timebase_index == 6),
                    align_notes_to_transients = checkboxes_list[8].checked,
                    tempo_map_freq = tempo_map_freq_index,
                    selected_tracks = selected_tracks
                }
                import_progress.active = true
                import_progress.pct = 0
                import_progress.status = "Starting..."
                import_progress.start_time = reaper.time_precise()
                import_progress.log = {}
                import_progress.done = false
                update_import_progress(0, "Parsing MusicXML...")
                local pre_import_state = capture_pre_import_state()
                autoload_region_start_pos = nil  -- manual import: honour import_position_index, not autoload override
                ImportMusicXMLWithOptions(selected_file_path, options)
                capture_post_import_history(pre_import_state, selected_file_path)
                import_progress.done = true
                import_progress.end_time = reaper.time_precise()
                import_progress.pct = 1
                update_import_progress(1, "Done")
            else
                safe_msgbox("Please select a MusicXML file first.", "No File Selected", 0)
            end
        end

        -- Content area click guard (only handle scrollable row clicks within visible area)
        local mouse_in_content = mouse_y >= content_top and mouse_y < content_bottom

        -- Section header fold toggles
        if mouse_in_content then
            local function hdr_clicked(hdr_y)
                return mouse_y >= hdr_y and mouse_y < hdr_y + section_hdr_h
            end
            if hdr_clicked(general_hdr_y) then
                settings_fold.general = not settings_fold.general; save_fold_state()
            elseif hdr_clicked(export_hdr_y) then
                settings_fold.export = not settings_fold.export; save_fold_state()
            elseif hdr_clicked(import_hdr_y) then
                settings_fold.import = not settings_fold.import; save_fold_state()
            elseif hdr_clicked(transients_hdr_y) then
                settings_fold.transients = not settings_fold.transients; save_fold_state()
            elseif hdr_clicked(tempomap_hdr_y) then
                settings_fold.tempomap = not settings_fold.tempomap; save_fold_state()
            elseif hdr_clicked(miditools_hdr_y) then
                settings_fold.miditools = not settings_fold.miditools; save_fold_state()
            elseif hdr_clicked(iam_hdr_y) then
                settings_fold.insertmouse = not settings_fold.insertmouse; save_fold_state()
            elseif hdr_clicked(art_hdr_y) then
                settings_fold.articulation = not settings_fold.articulation; save_fold_state()
            elseif hdr_clicked(artgrid_hdr_y) then
                settings_fold.artgrid = not settings_fold.artgrid; save_fold_state()
            end
        end

        -- Check click on fret number row
        if mouse_in_content and mouse_y > fret_row_y and mouse_y < fret_row_y + checkbox_size then
            -- M checkbox
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.fret = not settings_menu_flags.fret
            -- Fret number enabled checkbox
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                fret_number_enabled = not fret_number_enabled
            -- Fret number type button click -> dropdown menu
            elseif mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH then
                local menu_str = ""
                for j, v in ipairs(art_type_values) do
                    if j > 1 then menu_str = menu_str .. "|" end
                    if v == fret_number_type then menu_str = menu_str .. "!" end
                    menu_str = menu_str .. art_type_labels[v]
                end
                open_dark_menu(menu_str, type_btn_x, fret_row_y + checkbox_size, function(choice)
                    if choice > 0 then
                        fret_number_type = art_type_values[choice]
                    end
                end)
            end
        end

        -- Check click on span line (duration lines) row
        if mouse_in_content and mouse_y > span_row_y and mouse_y < span_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.span = not settings_menu_flags.span
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                span_line_enabled = not span_line_enabled
            end
        end

        -- Check click on highlight scan row
        if mouse_in_content and mouse_y > hlscan_row_y and mouse_y < hlscan_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.hlscan = not settings_menu_flags.hlscan
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                highlight_scan_enabled = not highlight_scan_enabled
                if not highlight_scan_enabled then
                    articulations_in_file = {}
                else
                    scan_articulations_in_xml()
                end
            end
        end

        -- Check click on export regions row
        if mouse_in_content and mouse_y > expreg_row_y and mouse_y < expreg_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.expreg = not settings_menu_flags.expreg
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                export_regions_enabled = not export_regions_enabled
            end
        end

        -- Check click on auto-focus row
        if mouse_in_content and mouse_y > autofocus_row_y and mouse_y < autofocus_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.autofocus = not settings_menu_flags.autofocus
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                auto_focus_enabled = not auto_focus_enabled
            end
        end

        -- Check click on stay-on-top row
        if mouse_in_content and mouse_y > stayontop_row_y and mouse_y < stayontop_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.stayontop = not settings_menu_flags.stayontop
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                stay_on_top_enabled = not stay_on_top_enabled
                apply_stay_on_top()
            end
        end

        -- Check click on font row
        if mouse_in_content and mouse_y > font_row_y and mouse_y < font_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.font = not settings_menu_flags.font
            else
                local font_btn_x_c = sett_simple_btn_x
                local font_btn_w_c = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= font_btn_x_c and mouse_x < font_btn_x_c + font_btn_w_c then
                    local menu_str = ""
                    for j, v in ipairs(font_list) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == current_font_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. v
                    end
                    open_dark_menu(menu_str, font_btn_x_c, font_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            current_font_index = choice
                            gfx.setfont(1, font_list[current_font_index], gui.settings.font_size)
                        end
                    end)
                end
            end
        end

        -- Check click on docker row
        if mouse_in_content and mouse_y > docker_row_y and mouse_y < docker_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.docker = not settings_menu_flags.docker
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                docker_enabled = not docker_enabled
                if docker_enabled then
                    gfx.dock(docker_dock_values[docker_position] or 1)
                else
                    gfx.dock(0)
                    -- Re-apply borderless style after undocking
                    if gui.settings.Borderless_Window then
                        window_script = reaper.JS_Window_Find(SCRIPT_TITLE, true)
                        if window_script then
                            reaper.JS_Window_SetStyle(window_script, "POPUP")
                            reaper.JS_Window_AttachResizeGrip(window_script)
                            local cur_exstyle = reaper.JS_Window_GetLong(window_script, "EXSTYLE")
                            if cur_exstyle then
                                reaper.JS_Window_SetLong(window_script, "EXSTYLE", cur_exstyle | 0x10)
                            end
                        end
                    end
                    -- Re-apply stay-on-top after undocking
                    if stay_on_top_enabled then apply_stay_on_top() end
                end
            else
                local docker_btn_x = sett_simple_btn_x
                local docker_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= docker_btn_x and mouse_x < docker_btn_x + docker_btn_w then
                    local menu_str = ""
                    for j, v in ipairs(docker_positions) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == docker_position then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. v
                    end
                    open_dark_menu(menu_str, docker_btn_x, docker_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            docker_position = choice
                            if docker_enabled then
                                gfx.dock(docker_dock_values[docker_position] or 1)
                            end
                        end
                    end)
                end
            end
        end

        -- Check click on window position radio rows
        if mouse_in_content and mouse_y > winpos_last_row_y and mouse_y < winpos_last_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.winpos_last = not settings_menu_flags.winpos_last
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                window_position_mode = "last"
                save_window_position_mode("last")
            end
        end
        if mouse_in_content and mouse_y > winpos_mouse_row_y and mouse_y < winpos_mouse_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.winpos_mouse = not settings_menu_flags.winpos_mouse
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                window_position_mode = "mouse"
                save_window_position_mode("mouse")
            end
        end

        -- Check click on remember window size row
        if mouse_in_content and mouse_y > winsize_row_y and mouse_y < winsize_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.winsize = not settings_menu_flags.winsize
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                remember_window_size = not remember_window_size
                save_remember_window_size_setting()
            end
        end

        -- Check click on MIDI program banks row
        if mouse_in_content and mouse_y > midibank_row_y and mouse_y < midibank_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.midibank = not settings_menu_flags.midibank
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                midi_program_banks_enabled = not midi_program_banks_enabled
            else
                local midibank_btn_x = sett_simple_btn_x
                local midibank_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= midibank_btn_x and mouse_x < midibank_btn_x + midibank_btn_w then
                    -- Build GM presets menu string
                    local menu_str = ""
                    for i, p in ipairs(gm_presets) do
                        if i > 1 then menu_str = menu_str .. "|" end
                        menu_str = menu_str .. p.name
                    end
                    open_dark_menu(menu_str, mouse_x, mouse_y, function(choice)
                        if choice > 0 then
                            -- Find the actual preset (skip submenu headers)
                            local actual_items = {}
                            for _, p in ipairs(gm_presets) do
                                if p.name:sub(1,1) ~= ">" and p.name:sub(1,1) ~= "<" then
                                    table.insert(actual_items, p)
                                else
                                    local clean = p.name:gsub("^[<>]", "")
                                    table.insert(actual_items, {name = clean, program = p.program})
                                end
                            end
                            local selected_preset = actual_items[choice]
                            if selected_preset then
                                local num_items = reaper.CountSelectedMediaItems(0)
                                if num_items > 0 then
                                    reaper.Undo_BeginBlock()
                                    for i = 0, num_items - 1 do
                                        local item = reaper.GetSelectedMediaItem(0, i)
                                        local take = reaper.GetActiveTake(item)
                                        if take and reaper.TakeIsMIDI(take) then
                                            local _, cc_count = reaper.MIDI_CountEvts(take)
                                            for ci = cc_count - 1, 0, -1 do
                                                local _, _, _, ppqpos, _, _, cc_num = reaper.MIDI_GetCC(take, ci)
                                                if ppqpos == 0 and (cc_num == 0 or cc_num == 32) then
                                                    reaper.MIDI_DeleteCC(take, ci)
                                                end
                                            end
                                            local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                                            if gotAllOK then
                                                local MIDIlen = MIDIstring:len()
                                                local tableEvents = {}
                                                local stringPos = 1
                                                local abs_pos = 0
                                                while stringPos < MIDIlen do
                                                    local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                                                    abs_pos = abs_pos + offset
                                                    local dominated = false
                                                    if abs_pos == 0 and msg:len() >= 1 then
                                                        local status = msg:byte(1)
                                                        if (status >> 4) == 0xC then dominated = true end
                                                    end
                                                    if not dominated then
                                                        table.insert(tableEvents, string.pack("i4Bs4", offset, flags, msg))
                                                    end
                                                    stringPos = newPos
                                                end
                                                reaper.MIDI_SetAllEvts(take, table.concat(tableEvents))
                                            end
                                            local ch = 0
                                            reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 0, 0)
                                            reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 32, 0)
                                            reaper.MIDI_InsertCC(take, false, false, 0, 0xC0, ch, selected_preset.program, 0)
                                            reaper.MIDI_Sort(take)
                                        end
                                    end
                                    reaper.Undo_EndBlock("Assign GM Program: " .. selected_preset.name, -1)
                                else
                                    safe_msgbox("No MIDI items selected.", "Assign Bank", 0)
                                end
                            end
                        end
                    end)
                end
            end
        end

        -- Check click on Key Signature row
        if mouse_in_content and mouse_y > keysig_row_y and mouse_y < keysig_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.keysig = not settings_menu_flags.keysig
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                export_key_sig_enabled = not export_key_sig_enabled
            else
                local keysig_label_w = gfx.measurestr("Key Signature  ")
                local keysig_root_btn_x = horizontal_margin + keysig_label_w
                local keysig_total_btn_w = cb_x - COL_SPACING - keysig_root_btn_x
                local keysig_gap = 4
                local keysig_root_btn_w = math.floor(keysig_total_btn_w * 0.25)
                local keysig_scale_btn_x = keysig_root_btn_x + keysig_root_btn_w + keysig_gap
                local keysig_scale_btn_w = keysig_total_btn_w - keysig_root_btn_w - keysig_gap
                -- Read current KSIG to pre-select in menu
                local cur_root, cur_notes = nil, nil
                local num_sel_ks = reaper.CountSelectedMediaItems(0)
                if num_sel_ks > 0 then
                    local item = reaper.GetSelectedMediaItem(0, 0)
                    local take = item and reaper.GetActiveTake(item)
                    if take and reaper.TakeIsMIDI(take) then
                        local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                        if gotAllOK then
                            local MIDIlen = MIDIstring:len()
                            local stringPos = 1
                            local abs_pos = 0
                            while stringPos < MIDIlen do
                                local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                                abs_pos = abs_pos + offset
                                if abs_pos == 0 and msg:len() >= 3 and msg:byte(1) == 0xFF and msg:byte(2) == 0x0F then
                                    local evt_text = msg:sub(3)
                                    local r, n = evt_text:match("^KSIG root (%d+) dir %-?%d+ notes 0x(%x+)")
                                    if r and n then cur_root = tonumber(r); cur_notes = tonumber(n, 16) end
                                end
                                if abs_pos > 0 then break end
                                stringPos = newPos
                            end
                        end
                    end
                end
                -- Root button clicked
                if mouse_x >= keysig_root_btn_x and mouse_x < keysig_root_btn_x + keysig_root_btn_w then
                    local menu_str = ""
                    for i, name in ipairs(keysig_root_names) do
                        if i > 1 then menu_str = menu_str .. "|" end
                        if cur_root and cur_root == i - 1 then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. name
                    end
                    open_dark_menu(menu_str, keysig_root_btn_x, keysig_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            local new_root = choice - 1
                            local new_notes = cur_notes or KEYSIG_MAJOR_HEX
                            local num_items = reaper.CountSelectedMediaItems(0)
                            if num_items > 0 then
                                reaper.Undo_BeginBlock()
                                for i = 0, num_items - 1 do
                                    local item = reaper.GetSelectedMediaItem(0, i)
                                    local take = reaper.GetActiveTake(item)
                                    if take and reaper.TakeIsMIDI(take) then
                                        keysig_write_event(take, new_root, new_notes)
                                    end
                                end
                                reaper.Undo_EndBlock("Set Key Signature Root: " .. keysig_root_names[choice], -1)
                            end
                        end
                    end)
                -- Scale button clicked
                elseif mouse_x >= keysig_scale_btn_x and mouse_x < keysig_scale_btn_x + keysig_scale_btn_w then
                    local menu_str = ""
                    for i, sc in ipairs(keysig_scales_list) do
                        if i > 1 then menu_str = menu_str .. "|" end
                        if cur_notes and cur_notes == sc.hex then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. sc.name
                    end
                    open_dark_menu(menu_str, keysig_scale_btn_x, keysig_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            local new_notes = keysig_scales_list[choice].hex
                            local new_root = cur_root or 0
                            local num_items = reaper.CountSelectedMediaItems(0)
                            if num_items > 0 then
                                reaper.Undo_BeginBlock()
                                for i = 0, num_items - 1 do
                                    local item = reaper.GetSelectedMediaItem(0, i)
                                    local take = reaper.GetActiveTake(item)
                                    if take and reaper.TakeIsMIDI(take) then
                                        keysig_write_event(take, new_root, new_notes)
                                    end
                                end
                                reaper.Undo_EndBlock("Set Key Signature Scale: " .. keysig_scales_list[choice].name, -1)
                            end
                        end
                    end)
                end
            end
        end

        -- Check click on Open With row
        if mouse_in_content and mouse_y > openwith_row_y and mouse_y < openwith_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.openwith = not settings_menu_flags.openwith
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                export_open_with_enabled = not export_open_with_enabled
            end
        end

        -- Check click on Open Folder row
        if mouse_in_content and mouse_y > openfolder_row_y and mouse_y < openfolder_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.openfolder = not settings_menu_flags.openfolder
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                export_open_folder_enabled = not export_open_folder_enabled
            end
        end

        -- Variables for "click outside" handlers (declared before guard so they're always in scope)
        local clicked_defpath_box = false
        local clicked_openwith_box = false
        local clicked_sym_box = false

        -- Check clicks on import checkbox rows
        if mouse_in_content then
        for i = 1, #checkboxes_list do
            if mouse_y > import_row_y[i] and mouse_y < import_row_y[i] + checkbox_size then
                -- Show-in-menu toggle (rightmost position)
                if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                    checkboxes_list[i].show_in_menu = not checkboxes_list[i].show_in_menu
                    break
                end
                -- Value checkbox
                if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                    -- Handle mutually exclusive checkboxes for insertion modes (indices 5, 6, 7)
                    if i >= 5 and i <= 7 then
                        for j = 5, 7 do
                            checkboxes_list[j].checked = false
                        end
                        checkboxes_list[i].checked = true
                    else
                        checkboxes_list[i].checked = not checkboxes_list[i].checked
                    end
                    break
                end
            end
        end

        -- Check click on GM Track Names row
        if mouse_y > gmname_row_y and mouse_y < gmname_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.gmname = not settings_menu_flags.gmname
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                gm_name_tracks_enabled = not gm_name_tracks_enabled
                resize_window()
            end
        end

        -- Check click on Import Position row
        if mouse_y > importpos_row_y and mouse_y < importpos_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.importpos = not settings_menu_flags.importpos
            else
                local importpos_btn_x = sett_simple_btn_x
                local importpos_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= importpos_btn_x and mouse_x < importpos_btn_x + importpos_btn_w then
                    local menu_str = ""
                    for j, v in ipairs(import_position_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == import_position_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. v
                    end
                    open_dark_menu(menu_str, importpos_btn_x, importpos_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            import_position_index = choice
                        end
                    end)
                end
            end
        end

        -- Check click on Auto-load by Region row
        if mouse_y > autoloadrgn_row_y and mouse_y < autoloadrgn_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.autoloadrgn = not settings_menu_flags.autoloadrgn
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                autoload_by_region_enabled = not autoload_by_region_enabled
            end
        end

        -- Check click on MIDI Timebase row
        if mouse_y > timebase_row_y and mouse_y < timebase_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.timebase = not settings_menu_flags.timebase
            else
                local timebase_btn_x = sett_simple_btn_x
                local timebase_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= timebase_btn_x and mouse_x < timebase_btn_x + timebase_btn_w then
                    local menu_str = ""
                    for j, v in ipairs(import_timebase_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == import_timebase_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. v
                    end
                    open_dark_menu(menu_str, timebase_btn_x, timebase_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            import_timebase_index = choice
                        end
                    end)
                end
            end
        end

        -- Check clicks on import section duplicate rows (shared settings)
        if mouse_y > imdup.tempofreq and mouse_y < imdup.tempofreq + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.tempofreq = not settings_menu_flags.tempofreq
            else
                local btn_x = sett_simple_btn_x
                local btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= btn_x and mouse_x < btn_x + btn_w then
                    local menu_str = ""
                    for j, opt in ipairs(tempo_map_freq_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == tempo_map_freq_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. opt
                    end
                    open_dark_menu(menu_str, btn_x, imdup.tempofreq + checkbox_size, function(choice)
                        if choice > 0 then tempo_map_freq_index = choice end
                    end)
                end
            end
        end
        if mouse_y > imdup.tempotimesig and mouse_y < imdup.tempotimesig + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.tempotimesig = not settings_menu_flags.tempotimesig
            else
                local btn_x = sett_simple_btn_x
                local btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= btn_x and mouse_x < btn_x + btn_w then
                    local menu_str = ""
                    for j, opt in ipairs(tempo_timesig_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == tempo_timesig_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. opt
                    end
                    open_dark_menu(menu_str, btn_x, imdup.tempotimesig + checkbox_size, function(choice)
                        if choice > 0 then tempo_timesig_index = choice end
                    end)
                end
            end
        end
        if mouse_y > imdup.detectmethod and mouse_y < imdup.detectmethod + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.detectmethod = not settings_menu_flags.detectmethod
            else
                local btn_x = sett_simple_btn_x
                local btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= btn_x and mouse_x < btn_x + btn_w then
                    local menu_str = ""
                    for j, opt in ipairs(tempo_detect_method_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == tempo_detect_method_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. opt
                    end
                    open_dark_menu(menu_str, btn_x, imdup.detectmethod + checkbox_size, function(choice)
                        if choice > 0 then tempo_detect_method_index = choice end
                    end)
                end
            end
        end
        -- Check click on Tempo Map Freq row
        if mouse_y > tempofreq_row_y and mouse_y < tempofreq_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.tempofreq = not settings_menu_flags.tempofreq
            else
                local tempofreq_btn_x = sett_simple_btn_x
                local tempofreq_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= tempofreq_btn_x and mouse_x < tempofreq_btn_x + tempofreq_btn_w then
                    local menu_str = ""
                    for j, opt in ipairs(tempo_map_freq_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == tempo_map_freq_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. opt
                    end
                    open_dark_menu(menu_str, tempofreq_btn_x, tempofreq_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            tempo_map_freq_index = choice
                        end
                    end)
                end
            end
        end

        -- Check click on Time Signature row
        if mouse_y > tempotimesig_row_y and mouse_y < tempotimesig_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.tempotimesig = not settings_menu_flags.tempotimesig
            else
                local timesig_btn_x = sett_simple_btn_x
                local timesig_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= timesig_btn_x and mouse_x < timesig_btn_x + timesig_btn_w then
                    local menu_str = ""
                    for j, opt in ipairs(tempo_timesig_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == tempo_timesig_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. opt
                    end
                    open_dark_menu(menu_str, timesig_btn_x, tempotimesig_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            tempo_timesig_index = choice
                        end
                    end)
                end
            end
        end

        -- Check click on Detect Method row
        if mouse_y > detectmethod_row_y and mouse_y < detectmethod_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.detectmethod = not settings_menu_flags.detectmethod
            else
                local detectmethod_btn_x = sett_simple_btn_x
                local detectmethod_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= detectmethod_btn_x and mouse_x < detectmethod_btn_x + detectmethod_btn_w then
                    local menu_str = ""
                    for j, opt in ipairs(tempo_detect_method_options) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if j == tempo_detect_method_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. opt
                    end
                    open_dark_menu(menu_str, detectmethod_btn_x, detectmethod_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            tempo_detect_method_index = choice
                        end
                    end)
                end
            end
        end

        -- Check click on Detect Item row
        if mouse_y > detectitem_row_y and mouse_y < detectitem_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.detectitem = not settings_menu_flags.detectitem
            else
                local detectitem_btn_x = sett_simple_btn_x
                local detectitem_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= detectitem_btn_x and mouse_x < detectitem_btn_x + detectitem_btn_w then
                    refresh_detect_tempo_items()
                    local menu_str = "Selected Item"
                    if detect_tempo_item_index == 0 then menu_str = "!Selected Item" end
                    for j, si in ipairs(detect_tempo_item_items) do
                        menu_str = menu_str .. "|"
                        if j == detect_tempo_item_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. si.name
                    end
                    open_dark_menu(menu_str, detectitem_btn_x, detectitem_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            detect_tempo_item_index = choice - 1  -- 0=Selected Item, 1+=specific items
                        end
                    end)
                end
            end
        end

        -- Check click on Detect Tempo button row (full-width big button, last in Tempo Map)
        if mouse_y > detecttempo_row_y and mouse_y < detecttempo_row_y + file_info_height then
            detect_tempo_from_item()
        end

        -- Check click on Stretch Markers checkbox row
        if mouse_y > stretchmarkers_row_y and mouse_y < stretchmarkers_row_y + checkbox_size then
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                detect_stretch_markers_enabled = not detect_stretch_markers_enabled
                save_articulation_settings()
            end
        end

        -- Check click on slider rows (Threshold, Sensitivity, Retrig, Offset)
        -- Sets value, applies instantly (post-filter is microseconds), and starts drag.
        local slider_rows = {
            {y = threshold_row_y, name = "threshold"},
            {y = sensitivity_row_y, name = "sensitivity"},
            {y = retrig_row_y, name = "retrig"},
            {y = offset_row_y, name = "offset"},
        }
        for _, sr in ipairs(slider_rows) do
            if mouse_y > sr.y and mouse_y < sr.y + checkbox_size then
                local slider_x = sett_simple_btn_x
                local slider_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= slider_x and mouse_x < slider_x + slider_w then
                    local frac = (mouse_x - slider_x) / slider_w
                    frac = math.max(0, math.min(1, frac))
                    if sr.name == "threshold" then
                        sm_threshold_dB = math.max(0, math.min(60, math.floor(frac * 60 + 0.5)))
                    elseif sr.name == "sensitivity" then
                        sm_sensitivity_dB = math.max(1, math.min(20, math.floor(frac * 19 + 0.5) + 1))
                    elseif sr.name == "retrig" then
                        sm_retrig_ms = math.max(10, math.min(500, math.floor(frac * 490 + 0.5) + 10))
                    elseif sr.name == "offset" then
                        sm_offset_ms = math.max(-100, math.min(100, math.floor((frac * 200 - 100) + 0.5)))
                    end
                    local sm_item, sm_take = get_detect_tempo_item()
                    if sm_item and sm_take then
                        apply_cached_stretch_markers(sm_item, sm_take)
                    end
                    sm_slider_dragging = sr.name
                end
            end
        end

        -- Check click on Use Existing Markers checkbox row
        if mouse_y > useexisting_row_y and mouse_y < useexisting_row_y + checkbox_size then
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                detect_tempo_use_existing_markers = not detect_tempo_use_existing_markers
                save_articulation_settings()
            end
        end

        -- Check click on Align Stem row
        if mouse_y > alignstem_row_y and mouse_y < alignstem_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.alignstem = not settings_menu_flags.alignstem
            else
                local alignstem_btn_x = sett_simple_btn_x
                local alignstem_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= alignstem_btn_x and mouse_x < alignstem_btn_x + alignstem_btn_w then
                    refresh_align_stem_items()
                    local menu_str = "Auto"
                    if align_stem_index == 0 then menu_str = "!Auto" end
                    for j, si in ipairs(align_stem_items) do
                        menu_str = menu_str .. "|"
                        if j == align_stem_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. si.name
                    end
                    open_dark_menu(menu_str, alignstem_btn_x, alignstem_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            align_stem_index = choice - 1  -- 0=Auto, 1+=specific items
                        end
                    end)
                end
            end
        end

        -- Check click on Onset Item row
        if mouse_y > onsetitem_row_y and mouse_y < onsetitem_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.onsetitem = not settings_menu_flags.onsetitem
            else
                local onsetitem_btn_x = sett_simple_btn_x
                local onsetitem_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
                if mouse_x >= onsetitem_btn_x and mouse_x < onsetitem_btn_x + onsetitem_btn_w then
                    refresh_onset_item_items()
                    local menu_str = "Auto"
                    if onset_item_index == 0 then menu_str = "!Auto" end
                    for j, si in ipairs(onset_item_items) do
                        menu_str = menu_str .. "|"
                        if j == onset_item_index then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. si.name
                    end
                    open_dark_menu(menu_str, onsetitem_btn_x, onsetitem_row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            onset_item_index = choice - 1
                        end
                    end)
                end
            end
        end

        -- Check click on Remap button row
        if mouse_y > remap_row_y and mouse_y < remap_row_y + checkbox_size then
            local remap_sett_btn_x = sett_simple_btn_x
            local remap_sett_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= remap_sett_btn_x and mouse_x < remap_sett_btn_x + remap_sett_btn_w then
                local num_items = reaper.CountSelectedMediaItems(0)
                if num_items > 0 then
                    local count = remap_midi_to_tempo_map()
                    if count > 0 then
                        remap_confirmed_until = os.clock() + 1.5
                    else
                        safe_msgbox("No remap data found on selected items.\nOnly items imported with this script contain remap data.", "No Remap Data", 0)
                    end
                else
                    safe_msgbox("Please select MIDI items to remap.", "No Items Selected", 0)
                end
            end
        end

        -- Check click on Delete Tempo Markers button row
        if mouse_y > del_tempo_row_y and mouse_y < del_tempo_row_y + checkbox_size then
            local del_tempo_btn_x = sett_simple_btn_x
            local del_tempo_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= del_tempo_btn_x and mouse_x < del_tempo_btn_x + del_tempo_btn_w then
                local rng_start, rng_end = get_edit_range()
                if rng_start then
                    reaper.Undo_BeginBlock()
                    local count = delete_tempo_markers_in_range(rng_start, rng_end)
                    reaper.Undo_EndBlock("Delete tempo markers in range", -1)
                    reaper.UpdateTimeline()
                    if count > 0 then
                        del_tempo_confirmed_until = os.clock() + 1.5
                    else
                        safe_msgbox("No tempo markers found in the active range.", "Nothing to Delete", 0)
                    end
                else
                    safe_msgbox("No active range found.\nMake a time selection, razor edit,\nor select items to define the range.", "No Range", 0)
                end
            end
        end

        -- Check click on Remove Stretch Markers button row
        if mouse_y > del_sm_row_y and mouse_y < del_sm_row_y + checkbox_size then
            local del_sm_btn_x = sett_simple_btn_x
            local del_sm_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= del_sm_btn_x and mouse_x < del_sm_btn_x + del_sm_btn_w then
                local rng_start, rng_end = get_edit_range()
                local n_selected = reaper.CountSelectedMediaItems(0)
                if n_selected == 0 and not rng_start then
                    safe_msgbox("Please select audio items, or set a razor edit / time selection.", "No Selection", 0)
                else
                    local items_list = nil
                    if n_selected == 0 then
                        -- Auto-collect audio items overlapping the range
                        items_list = {}
                        for ii = 0, reaper.CountMediaItems(0) - 1 do
                            local it = reaper.GetMediaItem(0, ii)
                            local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
                            local ilen = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
                            if ipos < rng_end + 0.001 and ipos + ilen > rng_start - 0.001 then
                                local tk = reaper.GetActiveTake(it)
                                if tk and not reaper.TakeIsMIDI(tk) then
                                    items_list[#items_list + 1] = it
                                end
                            end
                        end
                        if #items_list == 0 then
                            safe_msgbox("No audio items found in the active range.", "Nothing to Remove", 0)
                            goto continue_del_sm
                        end
                    end
                    reaper.Undo_BeginBlock()
                    local count = remove_stretch_markers_in_range(rng_start, rng_end, items_list)
                    reaper.Undo_EndBlock("Remove stretch markers in range", -1)
                    if count > 0 then
                        del_sm_confirmed_until = os.clock() + 1.5
                    else
                        safe_msgbox("No stretch markers found in the active range.", "Nothing to Remove", 0)
                    end
                    ::continue_del_sm::
                end
            end
        end

        -- Check click on Nudge SM slider row
        if not sm_nudge_slider_dragging and mouse_y > sm_nudge_row_y and mouse_y < sm_nudge_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                -- Start nudge drag: lock nearest SM to cursor
                local item_n, take_n, idx_n, src_n, proj_n, srcpos_n = find_sm_near_cursor()
                if item_n and idx_n >= 0 then
                    sm_nudge_slider_dragging = true
                    sm_nudge_drag_start_x = mouse_x
                    sm_nudge_drag_start_val = sm_nudge_value
                    sm_nudge_item = item_n; sm_nudge_take = take_n
                    sm_nudge_idx = idx_n
                    sm_nudge_orig_src = src_n        -- take-time pos (fixed)
                    sm_nudge_orig_srcpos = srcpos_n  -- source media pos (varies)
                    reaper.Undo_BeginBlock()
                    sm_nudge_undo_open = true
                else
                    safe_msgbox("No stretch markers found near the edit cursor.", "No SM", 0)
                end
            end
        end

        -- Check click on Snap SM to Grid checkbox row
        if mouse_y > sm_snap_row_y and mouse_y < sm_snap_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.smsnap = not settings_menu_flags.smsnap
                save_settings_menu_flags()
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                sm_snap_to_grid_enabled = not sm_snap_to_grid_enabled
            end
        end

        -- Check click on Detect Transients button row (full-width big button, last in Transients)
        if mouse_y > detect_transients_row_y and mouse_y < detect_transients_row_y + file_info_height then
            detect_transients_manual()
        end

        -- Check click on Nudge Tempo slider row
        if not tempo_nudge_slider_dragging and mouse_y > tempo_nudge_row_y and mouse_y < tempo_nudge_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                -- Start nudge drag: lock nearest tempo marker to cursor
                local tidx, t_t, t_bpm, t_tsn, t_tsd, t_lin = find_tempo_near_cursor()
                if tidx >= 0 then
                    tempo_nudge_slider_dragging = true
                    tempo_nudge_drag_start_x = mouse_x
                    tempo_nudge_drag_start_val = tempo_nudge_value
                    tempo_nudge_idx = tidx; tempo_nudge_orig_t = t_t
                    tempo_nudge_orig_bpm = t_bpm; tempo_nudge_orig_tsn = t_tsn
                    tempo_nudge_orig_tsd = t_tsd; tempo_nudge_orig_lin = t_lin
                    -- Find the tempo marker immediately before this one
                    -- (needed to adjust its BPM to preserve beat count during nudge)
                    tempo_nudge_prev_idx = -1
                    tempo_nudge_prev_t = 0; tempo_nudge_prev_bpm = 120
                    tempo_nudge_prev_tsn = 4; tempo_nudge_prev_tsd = 4
                    tempo_nudge_prev_lin = false
                    for mi = tidx - 1, 0, -1 do
                        local rv_p, t_p, _, _, bpm_p, tsn_p, tsd_p, lin_p = reaper.GetTempoTimeSigMarker(0, mi)
                        if rv_p and t_p < t_t - 0.0001 then
                            tempo_nudge_prev_idx = mi
                            tempo_nudge_prev_t   = t_p
                            tempo_nudge_prev_bpm = bpm_p
                            tempo_nudge_prev_tsn = tsn_p
                            tempo_nudge_prev_tsd = tsd_p
                            tempo_nudge_prev_lin = lin_p
                            break
                        end
                    end
                    reaper.Undo_BeginBlock()
                    tempo_nudge_undo_open = true
                else
                    safe_msgbox("No tempo markers found near the edit cursor.", "No Tempo", 0)
                end
            end
        end

        -- Check click on Snap Tempo to SM checkbox row
        if mouse_y > tempo_snap_row_y and mouse_y < tempo_snap_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.temposnap = not settings_menu_flags.temposnap
                save_settings_menu_flags()
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                tempo_snap_to_sm_enabled = not tempo_snap_to_sm_enabled
            end
        end

        -- Check click on MIDI SM Mode checkbox row
        if mouse_y > midi_sm_row_y and mouse_y < midi_sm_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.midism = not settings_menu_flags.midism
                save_settings_menu_flags()
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                midi_sm_enabled = not midi_sm_enabled
                if not midi_sm_enabled then midi_sm_state = {} end
            end
        end

        -- Check click on Insert TM at cursor button
        if mouse_y > midi_tm_insert_row_y and mouse_y < midi_tm_insert_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                insert_midi_tm_at_cursor()
            end
        end

        -- Check click on MIDI TM Move slider row
        if not midi_tm_move_dragging and mouse_y > midi_tm_move_row_y and mouse_y < midi_tm_move_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                local bi, bt, bmi, bs = find_midi_tm_near_cursor()
                if bi and bmi >= 0 then
                    midi_tm_move_dragging = true
                    midi_tm_move_drag_start_x = mouse_x
                    midi_tm_move_drag_start_val = midi_tm_move_value
                    midi_tm_move_item = bi; midi_tm_move_take = bt
                    midi_tm_move_mi = bmi; midi_tm_move_orig_s = bs
                    -- Compute beat duration at cursor for beat-based slider range (±2 beats)
                    local cur_qn_mv = reaper.TimeMap2_timeToQN(0, reaper.GetCursorPosition())
                    midi_tm_move_beat_dur = math.max(0.05, math.min(4.0,
                        reaper.TimeMap2_QNToTime(0, cur_qn_mv + 1) - reaper.TimeMap2_QNToTime(0, cur_qn_mv)))
                    reaper.Undo_BeginBlock()
                    midi_tm_move_undo_open = true
                else
                    safe_msgbox("No rated take markers (e.g. 1.00x) found near the edit cursor.\nUse the 'Insert TM at cursor' button to add one.", "No TM", 0)
                end
            end
        end

        -- Check click on MIDI TM Stretch slider row
        if not midi_tm_stretch_dragging and mouse_y > midi_tm_stretch_row_y and mouse_y < midi_tm_stretch_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                local bi, bt, bmi, bs = find_midi_tm_near_cursor()
                if bi and bmi >= 0 then
                    local tk_key = tostring(bt)
                    if not midi_sm_state[tk_key] then
                        midi_sm_init_take(tk_key, bi, bt)
                    end
                    midi_tm_stretch_dragging = true
                    midi_tm_stretch_drag_start_x = mouse_x
                    midi_tm_stretch_drag_start_val = midi_tm_stretch_value
                    midi_tm_stretch_item = bi; midi_tm_stretch_take = bt
                    midi_tm_stretch_mi = bmi; midi_tm_stretch_orig_s = bs
                    midi_tm_stretch_last_s = bs
                    -- Compute beat duration at cursor for beat-based slider range (±2 beats)
                    local cur_qn_st = reaper.TimeMap2_timeToQN(0, reaper.GetCursorPosition())
                    midi_tm_stretch_beat_dur = math.max(0.05, math.min(4.0,
                        reaper.TimeMap2_QNToTime(0, cur_qn_st + 1) - reaper.TimeMap2_QNToTime(0, cur_qn_st)))
                    midi_tm_stretch_display_str = "1.00x"
                    -- Mark needs_reindex so warp rebuilds ni mapping at first drag call
                    local tk_key = tostring(bt)
                    if midi_sm_state[tk_key] then midi_sm_state[tk_key].needs_reindex = true end
                    -- Note backup lives in midi_sm_state[tk_key].note_backup;
                    -- piecewise warp is used during drag (no per-drag note cache needed)
                    reaper.Undo_BeginBlock()
                    midi_tm_stretch_undo_open = true
                else
                    safe_msgbox("No rated take markers (e.g. 1.00x) found near the edit cursor.\nUse the 'Insert TM at cursor' button to add one.", "No TM", 0)
                end
            end
        end

        -- Check click on TM Grid Snap toggle (MIDI TOOLS)
        if mouse_y > midi_tm_snap_row_y and mouse_y < midi_tm_snap_row_y + checkbox_size then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                midi_tm_snap_enabled = not midi_tm_snap_enabled
            end
        end
        -- Check click on Snap TM to Note button (MIDI TOOLS)
        if mouse_y > midi_tm_snap_note_row_y and mouse_y < midi_tm_snap_note_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                if snap_midi_tm_to_note() then
                    midi_tm_snap_to_note_confirmed_until = os.clock() + 1.5
                end
            end
        end
        -- Check click on Auto-snap TM to note toggle (MIDI TOOLS)
        if mouse_y > midi_tm_autosnap_row_y and mouse_y < midi_tm_autosnap_row_y + checkbox_size then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                midi_tm_autosnap_note_enabled = not midi_tm_autosnap_note_enabled
            end
        end
        -- Check click on Reset TM button (MIDI TOOLS)
        if mouse_y > midi_tm_reset_row_y and mouse_y < midi_tm_reset_row_y + checkbox_size then
            local sl_x = sett_simple_btn_x
            local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
            if mouse_x >= sl_x and mouse_x < sl_x + sl_w then
                -- Find active take and reset
                local sel_item = reaper.GetSelectedMediaItem(0, 0)
                local reset_take = sel_item and reaper.GetActiveTake(sel_item)
                local reset_key = reset_take and tostring(reset_take)
                if reset_key and midi_sm_state[reset_key] then
                    if reset_midi_tm(reset_key) then
                        midi_tm_reset_confirmed_until = os.clock() + 1.5
                    end
                else
                    safe_msgbox("Select the MIDI item with active MIDI SM state.", "No SM State", 0)
                end
            end
        end
        -- Check click on Nudge to Transients button row (MIDI TOOLS)
        if mouse_y > nudge_row_y and mouse_y < nudge_row_y + checkbox_size then
            local nudge_sett_btn_x = sett_simple_btn_x
            local nudge_sett_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= nudge_sett_btn_x and mouse_x < nudge_sett_btn_x + nudge_sett_btn_w then
                local num_items = reaper.CountSelectedMediaItems(0)
                if num_items >= 2 then
                    local count, err = nudge_notes_to_transients()
                    if count then
                        nudge_confirmed_until = os.clock() + 1.5
                    else
                        safe_msgbox(err or "Nudge failed.", "Nudge Error", 0)
                    end
                else
                    safe_msgbox("Select 2 items: one MIDI item and one audio item with stretch markers.", "Need 2 Items", 0)
                end
            end
        end

        -- Check clicks on INSERT AT MOUSE section checkboxes
        if mouse_y > iam_stretch_row_y and mouse_y < iam_stretch_row_y + checkbox_size then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                iam_enable_stretch = not iam_enable_stretch
                reaper.SetExtState("konst_InsertAtMouse", "enable_stretch", iam_enable_stretch and "1" or "0", true)
            end
        end
        if mouse_y > iam_take_tm_row_y and mouse_y < iam_take_tm_row_y + checkbox_size then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                iam_enable_take_tm = not iam_enable_take_tm
                reaper.SetExtState("konst_InsertAtMouse", "enable_take_tm", iam_enable_take_tm and "1" or "0", true)
            end
        end
        if mouse_y > iam_tempo_row_y and mouse_y < iam_tempo_row_y + checkbox_size then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                iam_enable_tempo = not iam_enable_tempo
                reaper.SetExtState("konst_InsertAtMouse", "enable_tempo", iam_enable_tempo and "1" or "0", true)
            end
        end

        -- Check click on default path radio checkbox
        if mouse_y > defpath_row_y and mouse_y < defpath_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.defpath = not settings_menu_flags.defpath
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                path_mode = "default"
                save_path_mode("default")
            end
        end
        -- Check click on last opened path radio checkbox
        if mouse_y > lastpath_row_y and mouse_y < lastpath_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.lastpath = not settings_menu_flags.lastpath
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                path_mode = "last"
                save_path_mode("last")
            end
        end
        -- Check click on Tips checkbox row
        if mouse_y > tips_row_y and mouse_y < tips_row_y + checkbox_size then
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                tips_enabled = not tips_enabled
                save_articulation_settings()
            end
        end
        -- Check click on default path text box
        local defpath_label_w = gfx.measurestr("Default Path" .. "  ")
        local defpath_box_x = horizontal_margin + defpath_label_w
        local defpath_box_w = gfx.w - defpath_box_x - horizontal_margin - checkbox_size - COL_SPACING - checkbox_size - COL_SPACING
        if mouse_y > defpath_row_y and mouse_y < defpath_row_y + checkbox_size and
           mouse_x > defpath_box_x and mouse_x < defpath_box_x + defpath_box_w then
            if not defpath_edit_active then
                defpath_edit_active = true
                defpath_edit_text = default_import_dir
                defpath_edit_cursor = #defpath_edit_text
                defpath_edit_sel = -1
            end
            clicked_defpath_box = true
        end

        -- Check click on Open With text box
        local openwith_label_w = gfx.measurestr("Open After Export" .. "  ")
        local openwith_box_x = horizontal_margin + openwith_label_w
        local openwith_box_w = gfx.w - openwith_box_x - horizontal_margin - checkbox_size - COL_SPACING - checkbox_size - COL_SPACING
        if mouse_y > openwith_row_y and mouse_y < openwith_row_y + checkbox_size and
           mouse_x > openwith_box_x and mouse_x < openwith_box_x + openwith_box_w then
            if not openwith_edit_active then
                openwith_edit_active = true
                openwith_edit_text = export_open_with_path
                openwith_edit_cursor = #openwith_edit_text
                openwith_edit_sel = -1
            end
            clicked_openwith_box = true
        end

        -- Check clicks on articulation rows
        for i, art_name in ipairs(articulation_names_ordered) do
            local row_y = list_top + (i - 1) * checkbox_row_height
            if is_row_visible(row_y) then

                -- M checkbox click (show in main menu)
                if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    settings_menu_flags[art_name] = not settings_menu_flags[art_name]
                    break
                end

                -- Enabled checkbox click
                if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    articulation_enabled[art_name] = not articulation_enabled[art_name]
                    break
                end

                -- Prefix checkbox click (checked = uses prefix = no_prefix false)
                if mouse_x > prefix_cb_x and mouse_x < prefix_cb_x + checkbox_size and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    local current_no_prefix = get_art_no_prefix(art_name)
                    local new_val = not current_no_prefix
                    if new_val ~= articulation_default_no_prefix[art_name] then
                        articulation_no_prefix_override[art_name] = new_val
                    else
                        articulation_no_prefix_override[art_name] = nil
                    end
                    break
                end

                -- Replace fret checkbox click
                if mouse_x > repl_cb_x and mouse_x < repl_cb_x + checkbox_size and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    local current_rf = get_art_replaces_fret(art_name)
                    local new_val = not current_rf
                    if new_val ~= articulation_default_replaces_fret[art_name] then
                        articulation_replaces_fret_override[art_name] = new_val
                    else
                        articulation_replaces_fret_override[art_name] = nil
                    end
                    break
                end

                -- Type button click -> dropdown menu
                if mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    local current_type = get_art_type(art_name)
                    local menu_str = ""
                    for j, v in ipairs(art_type_values) do
                        if j > 1 then menu_str = menu_str .. "|" end
                        if v == current_type then menu_str = menu_str .. "!" end
                        menu_str = menu_str .. art_type_labels[v]
                    end
                    local captured_art_name = art_name
                    open_dark_menu(menu_str, type_btn_x, row_y + checkbox_size, function(choice)
                        if choice > 0 then
                            local new_type = art_type_values[choice]
                            if new_type ~= articulation_default_type[captured_art_name] then
                                articulation_type_override[captured_art_name] = new_type
                            else
                                articulation_type_override[captured_art_name] = nil
                            end
                        end
                    end)
                    break
                end

                -- Symbol box click - activate text editing
                if mouse_x > sym_box_x and mouse_x < sym_box_x + SYM_BOX_WIDTH and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    -- Commit previous edit if different index
                    if sym_edit_active and sym_edit_index and sym_edit_index ~= i then
                        local prev_name = articulation_names_ordered[sym_edit_index]
                        if sym_edit_text ~= articulation_default_symbol[prev_name] then
                            articulation_symbol_override[prev_name] = sym_edit_text
                        else
                            articulation_symbol_override[prev_name] = nil
                        end
                    end
                    sym_edit_active = true
                    sym_edit_index = i
                    sym_edit_text = get_art_symbol(art_name)
                    sym_edit_cursor = #sym_edit_text
                    clicked_sym_box = true
                    break
                end

                -- Articulation name click - write text event for selected MIDI notes
                -- Alt+Click: remove articulation from selected notes instead
                if mouse_x > horizontal_margin and mouse_x < sym_box_x - COL_SPACING and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    local is_alt = (gfx.mouse_cap & 16) ~= 0
                    -- Gather takes: from selected items, or from active MIDI editor
                    local takes = {}
                    local num_items = reaper.CountSelectedMediaItems(0)
                    if num_items > 0 then
                        for mi = 0, num_items - 1 do
                            local item = reaper.GetSelectedMediaItem(0, mi)
                            local take = item and reaper.GetActiveTake(item)
                            if take and reaper.TakeIsMIDI(take) then
                                table.insert(takes, take)
                            end
                        end
                    end
                    -- Fallback: try active MIDI editor
                    if #takes == 0 then
                        local me = reaper.MIDIEditor_GetActive()
                        if me then
                            local take = reaper.MIDIEditor_GetTake(me)
                            if take and reaper.TakeIsMIDI(take) then
                                table.insert(takes, take)
                            end
                        end
                    end
                    -- Fallback: scan all items for any with selected MIDI notes
                    if #takes == 0 then
                        local total_items = reaper.CountMediaItems(0)
                        for mi = 0, total_items - 1 do
                            local item = reaper.GetMediaItem(0, mi)
                            local take = item and reaper.GetActiveTake(item)
                            if take and reaper.TakeIsMIDI(take) then
                                local _, note_count = reaper.MIDI_CountEvts(take)
                                for ni = 0, note_count - 1 do
                                    local _, sel = reaper.MIDI_GetNote(take, ni)
                                    if sel then
                                        table.insert(takes, take)
                                        break
                                    end
                                end
                            end
                        end
                    end
                    if is_alt then
                        -- ALT+CLICK: Remove matching articulation text events from selected notes
                        if #takes > 0 then
                            reaper.Undo_BeginBlock()
                            local total_removed = 0
                            for _, take in ipairs(takes) do
                                -- Collect selected note PPQs
                                local _, note_count = reaper.MIDI_CountEvts(take)
                                local sel_ppqs = {}
                                local has_selected = false
                                for ni = 0, note_count - 1 do
                                    local _, sel, _, startppq = reaper.MIDI_GetNote(take, ni)
                                    if sel then
                                        sel_ppqs[startppq] = true
                                        has_selected = true
                                    end
                                end
                                -- Scan text events in reverse to safely delete
                                local _, _, _, text_count = reaper.MIDI_CountEvts(take)
                                for ti = text_count - 1, 0, -1 do
                                    local _, _, _, ppqpos, _, msg = reaper.MIDI_GetTextSysexEvt(take, ti)
                                    if msg and #msg > 0 and (not has_selected or sel_ppqs[ppqpos]) then
                                        local matched = match_text_to_articulation(msg)
                                        if matched == art_name then
                                            reaper.MIDI_DeleteTextSysexEvt(take, ti)
                                            total_removed = total_removed + 1
                                        end
                                    end
                                end
                                reaper.MIDI_Sort(take)
                            end
                            reaper.Undo_EndBlock("Remove articulation: " .. art_name, -1)
                            -- Force re-scan
                            last_midi_scan_sel_hash = ""
                        end
                    else
                        -- NORMAL CLICK: Write articulation
                        -- Handle %s: prompt for text before writing
                        local sym_template = get_art_symbol(art_name)
                        local user_text = nil
                        if sym_template and sym_template:find("%%s") then
                            -- Schedule a deferred move so the dialog appears near the mouse
                            local dlg_title = "Enter " .. art_name .. " text"
                            local mx, my = reaper.GetMousePosition()
                            local dlg_retries = 0
                            local dlg_moved = false
                            local function move_dlg()
                                if dlg_moved then return end
                                dlg_retries = dlg_retries + 1
                                if dlg_retries > 50 then return end
                                -- Try finding the dialog by exact title first
                                local hwnd = reaper.JS_Window_Find(dlg_title, true)
                                if not hwnd then
                                    -- Fallback: check if foreground window title matches
                                    local fg = reaper.JS_Window_GetForeground()
                                    if fg then
                                        local t = reaper.JS_Window_GetTitle(fg)
                                        if t == dlg_title then hwnd = fg end
                                    end
                                end
                                if hwnd then
                                    reaper.JS_Window_Move(hwnd, mx - 100, my - 40)
                                    dlg_moved = true
                                    return
                                end
                                reaper.defer(move_dlg)
                            end
                            reaper.defer(move_dlg)
                            local retval, input = reaper.GetUserInputs(
                                dlg_title, 1,
                                art_name .. ":,extrawidth=200", "")
                            if not retval or input == "" then
                                break  -- user cancelled
                            end
                            user_text = input
                        end
                        if #takes > 0 then
                            reaper.Undo_BeginBlock()
                            local tuning = getActiveTuning()
                            local num_strings = #tuning
                            local total_written = 0
                            for _, take in ipairs(takes) do
                                local _, note_count = reaper.MIDI_CountEvts(take)
                                for ni = 0, note_count - 1 do
                                    local _, sel, _, startppq, _, chan, pitch = reaper.MIDI_GetNote(take, ni)
                                    if sel then
                                        local sym = get_art_symbol(art_name)
                                        local art_type = get_art_type(art_name)
                                        local no_prefix = get_art_no_prefix(art_name)
                                        -- Substitute %d with fret number from tuning + channel
                                        if sym:find("%%d") or sym:find("%%h") then
                                            local channel_1based = chan + 1
                                            local string_num = (num_strings + 1) - channel_1based
                                            if string_num < 1 then string_num = 1 end
                                            if string_num > num_strings then string_num = num_strings end
                                            local tuning_idx = num_strings - string_num + 1
                                            local fret = pitch - (tuning[tuning_idx] or 0)
                                            if fret < 0 then fret = 0 end
                                            sym = sym:gsub("%%d", tostring(fret))
                                            sym = sym:gsub("%%h", tostring(fret + 12))
                                        end
                                        -- Substitute %s with user-entered text
                                        if user_text and sym:find("%%s") then
                                            sym = sym:gsub("%%s", user_text)
                                        end
                                        local text = sym
                                        if not no_prefix then text = "_" .. text end
                                        reaper.MIDI_InsertTextSysexEvt(take, false, false, startppq, art_type, text)
                                        total_written = total_written + 1
                                    end
                                end
                                reaper.MIDI_Sort(take)
                            end
                            reaper.Undo_EndBlock("Write articulation: " .. art_name, -1)
                            -- Force re-scan
                            last_midi_scan_sel_hash = ""
                        end
                    end
                    break
                end
            end
        end
        end  -- if mouse_in_content

        -- Click outside any symbol box: commit and deactivate
        if not clicked_sym_box and sym_edit_active then
            local art_name = articulation_names_ordered[sym_edit_index]
            if sym_edit_text ~= articulation_default_symbol[art_name] then
                articulation_symbol_override[art_name] = sym_edit_text
            else
                articulation_symbol_override[art_name] = nil
            end
            sym_edit_active = false
            sym_edit_index = nil
        end

        -- Click outside default path box: commit and deactivate
        if not clicked_defpath_box and defpath_edit_active then
            default_import_dir = defpath_edit_text
            save_default_import_dir(defpath_edit_text)
            defpath_edit_active = false
            defpath_edit_sel = -1
        end

        -- Click outside Open With box: commit and deactivate
        if not clicked_openwith_box and openwith_edit_active then
            export_open_with_path = openwith_edit_text
            save_open_with_setting()
            openwith_edit_active = false
            openwith_edit_sel = -1
        end
    end

    -- Handle keyboard input for symbol editing
    if sym_edit_active and char_input and not gui_msgbox.active then
        if char_input == 8 then  -- Backspace
            if sym_edit_cursor > 0 then
                sym_edit_text = sym_edit_text:sub(1, sym_edit_cursor - 1) .. sym_edit_text:sub(sym_edit_cursor + 1)
                sym_edit_cursor = sym_edit_cursor - 1
            end
        elseif char_input == 6579564 then  -- Delete key
            if sym_edit_cursor < #sym_edit_text then
                sym_edit_text = sym_edit_text:sub(1, sym_edit_cursor) .. sym_edit_text:sub(sym_edit_cursor + 2)
            end
        elseif char_input == 1818584692 then  -- Left arrow
            if sym_edit_cursor > 0 then sym_edit_cursor = sym_edit_cursor - 1 end
        elseif char_input == 1919379572 then  -- Right arrow
            if sym_edit_cursor < #sym_edit_text then sym_edit_cursor = sym_edit_cursor + 1 end
        elseif char_input == 1752132965 then  -- Home
            sym_edit_cursor = 0
        elseif char_input == 6647396 then  -- End
            sym_edit_cursor = #sym_edit_text
        elseif char_input == 13 then  -- Enter: commit
            local art_name = articulation_names_ordered[sym_edit_index]
            if sym_edit_text ~= articulation_default_symbol[art_name] then
                articulation_symbol_override[art_name] = sym_edit_text
            else
                articulation_symbol_override[art_name] = nil
            end
            sym_edit_active = false
            sym_edit_index = nil
        elseif char_input == 27 then  -- Escape: cancel
            sym_edit_active = false
            sym_edit_index = nil
        elseif char_input >= 32 and char_input < 127 then  -- Printable ASCII
            local ch = string.char(char_input)
            sym_edit_text = sym_edit_text:sub(1, sym_edit_cursor) .. ch .. sym_edit_text:sub(sym_edit_cursor + 1)
            sym_edit_cursor = sym_edit_cursor + 1
        end
    end

    -- Handle keyboard input for default path editing
    if defpath_edit_active and char_input and not gui_msgbox.active then
        -- Helper: delete selected text and return updated text & cursor
        local function defpath_delete_selection()
            if defpath_edit_sel >= 0 and defpath_edit_sel ~= defpath_edit_cursor then
                local s = math.min(defpath_edit_cursor, defpath_edit_sel)
                local e = math.max(defpath_edit_cursor, defpath_edit_sel)
                defpath_edit_text = defpath_edit_text:sub(1, s) .. defpath_edit_text:sub(e + 1)
                defpath_edit_cursor = s
                defpath_edit_sel = -1
                return true
            end
            return false
        end

        if char_input == 1 then  -- Ctrl+A: select all
            defpath_edit_sel = 0
            defpath_edit_cursor = #defpath_edit_text
        elseif char_input == 3 then  -- Ctrl+C: copy
            if defpath_edit_sel >= 0 and defpath_edit_sel ~= defpath_edit_cursor then
                local s = math.min(defpath_edit_cursor, defpath_edit_sel)
                local e = math.max(defpath_edit_cursor, defpath_edit_sel)
                local selected = defpath_edit_text:sub(s + 1, e)
                if selected ~= "" and reaper.CF_SetClipboard then
                    reaper.CF_SetClipboard(selected)
                end
            end
        elseif char_input == 22 then  -- Ctrl+V: paste
            defpath_delete_selection()
            if reaper.CF_GetClipboard then
                local clip = reaper.CF_GetClipboard("")
                if clip and clip ~= "" then
                    -- Strip newlines from pasted text
                    clip = clip:gsub("[\r\n]+", "")
                    defpath_edit_text = defpath_edit_text:sub(1, defpath_edit_cursor) .. clip .. defpath_edit_text:sub(defpath_edit_cursor + 1)
                    defpath_edit_cursor = defpath_edit_cursor + #clip
                end
            end
            defpath_edit_sel = -1
        elseif char_input == 24 then  -- Ctrl+X: cut
            if defpath_edit_sel >= 0 and defpath_edit_sel ~= defpath_edit_cursor then
                local s = math.min(defpath_edit_cursor, defpath_edit_sel)
                local e = math.max(defpath_edit_cursor, defpath_edit_sel)
                local selected = defpath_edit_text:sub(s + 1, e)
                if selected ~= "" and reaper.CF_SetClipboard then
                    reaper.CF_SetClipboard(selected)
                end
                defpath_delete_selection()
            end
        elseif char_input == 8 then  -- Backspace
            if not defpath_delete_selection() then
                if defpath_edit_cursor > 0 then
                    defpath_edit_text = defpath_edit_text:sub(1, defpath_edit_cursor - 1) .. defpath_edit_text:sub(defpath_edit_cursor + 1)
                    defpath_edit_cursor = defpath_edit_cursor - 1
                end
            end
            defpath_edit_sel = -1
        elseif char_input == 6579564 then  -- Delete
            if not defpath_delete_selection() then
                if defpath_edit_cursor < #defpath_edit_text then
                    defpath_edit_text = defpath_edit_text:sub(1, defpath_edit_cursor) .. defpath_edit_text:sub(defpath_edit_cursor + 2)
                end
            end
            defpath_edit_sel = -1
        elseif char_input == 1818584692 then  -- Left arrow
            if defpath_edit_cursor > 0 then defpath_edit_cursor = defpath_edit_cursor - 1 end
            defpath_edit_sel = -1
        elseif char_input == 1919379572 then  -- Right arrow
            if defpath_edit_cursor < #defpath_edit_text then defpath_edit_cursor = defpath_edit_cursor + 1 end
            defpath_edit_sel = -1
        elseif char_input == 1752132965 then  -- Home
            defpath_edit_cursor = 0
            defpath_edit_sel = -1
        elseif char_input == 6647396 then  -- End
            defpath_edit_cursor = #defpath_edit_text
            defpath_edit_sel = -1
        elseif char_input == 13 then  -- Enter: commit
            default_import_dir = defpath_edit_text
            save_default_import_dir(defpath_edit_text)
            defpath_edit_active = false
            defpath_edit_sel = -1
        elseif char_input == 27 then  -- Escape: cancel
            defpath_edit_active = false
            defpath_edit_sel = -1
        elseif char_input >= 32 and char_input < 127 then  -- Printable ASCII
            defpath_delete_selection()
            local ch = string.char(char_input)
            defpath_edit_text = defpath_edit_text:sub(1, defpath_edit_cursor) .. ch .. defpath_edit_text:sub(defpath_edit_cursor + 1)
            defpath_edit_cursor = defpath_edit_cursor + 1
            defpath_edit_sel = -1
        end
    end

    -- Handle keyboard input for Open With path editing
    if openwith_edit_active and char_input and not gui_msgbox.active then
        local function openwith_delete_selection()
            if openwith_edit_sel >= 0 and openwith_edit_sel ~= openwith_edit_cursor then
                local s = math.min(openwith_edit_cursor, openwith_edit_sel)
                local e = math.max(openwith_edit_cursor, openwith_edit_sel)
                openwith_edit_text = openwith_edit_text:sub(1, s) .. openwith_edit_text:sub(e + 1)
                openwith_edit_cursor = s
                openwith_edit_sel = -1
                return true
            end
            return false
        end

        if char_input == 1 then  -- Ctrl+A: select all
            openwith_edit_sel = 0
            openwith_edit_cursor = #openwith_edit_text
        elseif char_input == 3 then  -- Ctrl+C: copy
            if openwith_edit_sel >= 0 and openwith_edit_sel ~= openwith_edit_cursor then
                local s = math.min(openwith_edit_cursor, openwith_edit_sel)
                local e = math.max(openwith_edit_cursor, openwith_edit_sel)
                local selected = openwith_edit_text:sub(s + 1, e)
                if selected ~= "" and reaper.CF_SetClipboard then
                    reaper.CF_SetClipboard(selected)
                end
            end
        elseif char_input == 22 then  -- Ctrl+V: paste
            openwith_delete_selection()
            if reaper.CF_GetClipboard then
                local clip = reaper.CF_GetClipboard("")
                if clip and clip ~= "" then
                    clip = clip:gsub("[\r\n]+", "")
                    openwith_edit_text = openwith_edit_text:sub(1, openwith_edit_cursor) .. clip .. openwith_edit_text:sub(openwith_edit_cursor + 1)
                    openwith_edit_cursor = openwith_edit_cursor + #clip
                end
            end
            openwith_edit_sel = -1
        elseif char_input == 24 then  -- Ctrl+X: cut
            if openwith_edit_sel >= 0 and openwith_edit_sel ~= openwith_edit_cursor then
                local s = math.min(openwith_edit_cursor, openwith_edit_sel)
                local e = math.max(openwith_edit_cursor, openwith_edit_sel)
                local selected = openwith_edit_text:sub(s + 1, e)
                if selected ~= "" and reaper.CF_SetClipboard then
                    reaper.CF_SetClipboard(selected)
                end
                openwith_delete_selection()
            end
        elseif char_input == 8 then  -- Backspace
            if not openwith_delete_selection() then
                if openwith_edit_cursor > 0 then
                    openwith_edit_text = openwith_edit_text:sub(1, openwith_edit_cursor - 1) .. openwith_edit_text:sub(openwith_edit_cursor + 1)
                    openwith_edit_cursor = openwith_edit_cursor - 1
                end
            end
            openwith_edit_sel = -1
        elseif char_input == 6579564 then  -- Delete
            if not openwith_delete_selection() then
                if openwith_edit_cursor < #openwith_edit_text then
                    openwith_edit_text = openwith_edit_text:sub(1, openwith_edit_cursor) .. openwith_edit_text:sub(openwith_edit_cursor + 2)
                end
            end
            openwith_edit_sel = -1
        elseif char_input == 1818584692 then  -- Left arrow
            if openwith_edit_cursor > 0 then openwith_edit_cursor = openwith_edit_cursor - 1 end
            openwith_edit_sel = -1
        elseif char_input == 1919379572 then  -- Right arrow
            if openwith_edit_cursor < #openwith_edit_text then openwith_edit_cursor = openwith_edit_cursor + 1 end
            openwith_edit_sel = -1
        elseif char_input == 1752132965 then  -- Home
            openwith_edit_cursor = 0
            openwith_edit_sel = -1
        elseif char_input == 6647396 then  -- End
            openwith_edit_cursor = #openwith_edit_text
            openwith_edit_sel = -1
        elseif char_input == 13 then  -- Enter: commit
            export_open_with_path = openwith_edit_text
            save_open_with_setting()
            openwith_edit_active = false
            openwith_edit_sel = -1
        elseif char_input == 27 then  -- Escape: cancel
            openwith_edit_active = false
            openwith_edit_sel = -1
        elseif char_input >= 32 and char_input < 127 then  -- Printable ASCII
            openwith_delete_selection()
            local ch = string.char(char_input)
            openwith_edit_text = openwith_edit_text:sub(1, openwith_edit_cursor) .. ch .. openwith_edit_text:sub(openwith_edit_cursor + 1)
            openwith_edit_cursor = openwith_edit_cursor + 1
            openwith_edit_sel = -1
        end
    end

    -- Handle mousewheel: scroll list OR cycle type on type buttons (skip when menu/msgbox is active)
    if gfx.mouse_wheel ~= 0 and not dark_menu.active and not gui_msgbox.active then
        local wheel_handled = false
        -- Check if mouse is over fret number type button
        if mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH and
           mouse_y > fret_row_y and mouse_y < fret_row_y + checkbox_size then
            local current_idx = 1
            for j, v in ipairs(art_type_values) do
                if v == fret_number_type then current_idx = j; break end
            end
            local delta = gfx.mouse_wheel > 0 and -1 or 1
            current_idx = current_idx + delta
            if current_idx < 1 then current_idx = #art_type_values end
            if current_idx > #art_type_values then current_idx = 1 end
            fret_number_type = art_type_values[current_idx]
            wheel_handled = true
        end
        -- Check if mouse is over font scrollable button
        if not wheel_handled then
            local font_btn_x_w = sett_simple_btn_x
            local font_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > font_btn_x_w and mouse_x < font_btn_x_w + font_btn_w_w and
               mouse_y > font_row_y and mouse_y < font_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                current_font_index = current_font_index + delta
                if current_font_index < 1 then current_font_index = #font_list end
                if current_font_index > #font_list then current_font_index = 1 end
                gfx.setfont(1, font_list[current_font_index], gui.settings.font_size)
                wheel_handled = true
            end
        end
        -- Check if mouse is over docker position button
        if not wheel_handled then
            local docker_btn_x_w = sett_simple_btn_x
            local docker_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > docker_btn_x_w and mouse_x < docker_btn_x_w + docker_btn_w_w and
               mouse_y > docker_row_y and mouse_y < docker_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                docker_position = docker_position + delta
                if docker_position < 1 then docker_position = #docker_positions end
                if docker_position > #docker_positions then docker_position = 1 end
                if docker_enabled then
                    gfx.dock(docker_dock_values[docker_position] or 1)
                end
                wheel_handled = true
            end
        end
        -- Check if mouse is over import position button
        if not wheel_handled then
            local importpos_btn_x_w = sett_simple_btn_x
            local importpos_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > importpos_btn_x_w and mouse_x < importpos_btn_x_w + importpos_btn_w_w and
               mouse_y > importpos_row_y and mouse_y < importpos_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                import_position_index = import_position_index + delta
                if import_position_index < 1 then import_position_index = #import_position_options end
                if import_position_index > #import_position_options then import_position_index = 1 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over MIDI timebase button
        if not wheel_handled then
            local timebase_btn_x_w = sett_simple_btn_x
            local timebase_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > timebase_btn_x_w and mouse_x < timebase_btn_x_w + timebase_btn_w_w and
               mouse_y > timebase_row_y and mouse_y < timebase_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                import_timebase_index = import_timebase_index + delta
                if import_timebase_index < 1 then import_timebase_index = #import_timebase_options end
                if import_timebase_index > #import_timebase_options then import_timebase_index = 1 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over import duplicate dropdown rows
        if not wheel_handled then
            local btn_x_w = sett_simple_btn_x
            local btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > btn_x_w and mouse_x < btn_x_w + btn_w_w then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                if mouse_y > imdup.tempofreq and mouse_y < imdup.tempofreq + checkbox_size then
                    tempo_map_freq_index = tempo_map_freq_index + delta
                    if tempo_map_freq_index < 1 then tempo_map_freq_index = #tempo_map_freq_options end
                    if tempo_map_freq_index > #tempo_map_freq_options then tempo_map_freq_index = 1 end
                    wheel_handled = true
                elseif mouse_y > imdup.tempotimesig and mouse_y < imdup.tempotimesig + checkbox_size then
                    tempo_timesig_index = tempo_timesig_index + delta
                    if tempo_timesig_index < 1 then tempo_timesig_index = #tempo_timesig_options end
                    if tempo_timesig_index > #tempo_timesig_options then tempo_timesig_index = 1 end
                    wheel_handled = true
                elseif mouse_y > imdup.detectmethod and mouse_y < imdup.detectmethod + checkbox_size then
                    tempo_detect_method_index = tempo_detect_method_index + delta
                    if tempo_detect_method_index < 1 then tempo_detect_method_index = #tempo_detect_method_options end
                    if tempo_detect_method_index > #tempo_detect_method_options then tempo_detect_method_index = 1 end
                    wheel_handled = true
                end
            end
        end
        -- Check if mouse is over Tempo Map Freq button
        if not wheel_handled then
            local tempofreq_btn_x_w = sett_simple_btn_x
            local tempofreq_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > tempofreq_btn_x_w and mouse_x < tempofreq_btn_x_w + tempofreq_btn_w_w and
               mouse_y > tempofreq_row_y and mouse_y < tempofreq_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                tempo_map_freq_index = tempo_map_freq_index + delta
                if tempo_map_freq_index < 1 then tempo_map_freq_index = #tempo_map_freq_options end
                if tempo_map_freq_index > #tempo_map_freq_options then tempo_map_freq_index = 1 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over Time Signature button
        if not wheel_handled then
            local timesig_btn_x_w = sett_simple_btn_x
            local timesig_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > timesig_btn_x_w and mouse_x < timesig_btn_x_w + timesig_btn_w_w and
               mouse_y > tempotimesig_row_y and mouse_y < tempotimesig_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                tempo_timesig_index = tempo_timesig_index + delta
                if tempo_timesig_index < 1 then tempo_timesig_index = #tempo_timesig_options end
                if tempo_timesig_index > #tempo_timesig_options then tempo_timesig_index = 1 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over Detect Method button
        if not wheel_handled then
            local detectmethod_btn_x_w = sett_simple_btn_x
            local detectmethod_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > detectmethod_btn_x_w and mouse_x < detectmethod_btn_x_w + detectmethod_btn_w_w and
               mouse_y > detectmethod_row_y and mouse_y < detectmethod_row_y + checkbox_size then
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                tempo_detect_method_index = tempo_detect_method_index + delta
                if tempo_detect_method_index < 1 then tempo_detect_method_index = #tempo_detect_method_options end
                if tempo_detect_method_index > #tempo_detect_method_options then tempo_detect_method_index = 1 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over Detect Item button
        if not wheel_handled then
            local detectitem_btn_x_w = sett_simple_btn_x
            local detectitem_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > detectitem_btn_x_w and mouse_x < detectitem_btn_x_w + detectitem_btn_w_w and
               mouse_y > detectitem_row_y and mouse_y < detectitem_row_y + checkbox_size then
                refresh_detect_tempo_items()
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                detect_tempo_item_index = detect_tempo_item_index + delta
                if detect_tempo_item_index < 0 then detect_tempo_item_index = #detect_tempo_item_items end
                if detect_tempo_item_index > #detect_tempo_item_items then detect_tempo_item_index = 0 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over any stretch marker slider (Threshold, Sensitivity, Retrig, Offset)
        if not wheel_handled then
            local slider_x_w = sett_simple_btn_x
            local slider_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            local sm_wheel_rows = {
                {y = threshold_row_y, name = "threshold"},
                {y = sensitivity_row_y, name = "sensitivity"},
                {y = retrig_row_y, name = "retrig"},
                {y = offset_row_y, name = "offset"},
            }
            for _, wr in ipairs(sm_wheel_rows) do
                if mouse_x > slider_x_w and mouse_x < slider_x_w + slider_w_w and
                   mouse_y > wr.y and mouse_y < wr.y + checkbox_size then
                    local delta = gfx.mouse_wheel > 0 and 1 or -1
                    local changed = false
                    if wr.name == "threshold" then
                        sm_threshold_dB = math.max(0, math.min(60, sm_threshold_dB + delta))
                        changed = true
                    elseif wr.name == "sensitivity" then
                        sm_sensitivity_dB = math.max(1, math.min(20, sm_sensitivity_dB + delta))
                        changed = true
                    elseif wr.name == "retrig" then
                        sm_retrig_ms = math.max(10, math.min(500, sm_retrig_ms + delta * 5))
                        changed = true
                    elseif wr.name == "offset" then
                        sm_offset_ms = math.max(-100, math.min(100, sm_offset_ms + delta))
                        changed = true
                    end
                    if changed then
                        local sm_item, sm_take = get_detect_tempo_item()
                        if sm_item and sm_take then
                            apply_cached_stretch_markers(sm_item, sm_take)
                        end
                        save_articulation_settings()
                    end
                    wheel_handled = true
                    break
                end
            end
        end
        -- Check if mouse is over Detect Tempo Item button
        if not wheel_handled then
            local alignstem_btn_x_w = sett_simple_btn_x
            local alignstem_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > alignstem_btn_x_w and mouse_x < alignstem_btn_x_w + alignstem_btn_w_w and
               mouse_y > alignstem_row_y and mouse_y < alignstem_row_y + checkbox_size then
                refresh_align_stem_items()
                local max_idx = #align_stem_items
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                align_stem_index = align_stem_index + delta
                if align_stem_index < 0 then align_stem_index = max_idx end
                if align_stem_index > max_idx then align_stem_index = 0 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over Onset Item button
        if not wheel_handled then
            local onsetitem_btn_x_w = sett_simple_btn_x
            local onsetitem_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x > onsetitem_btn_x_w and mouse_x < onsetitem_btn_x_w + onsetitem_btn_w_w and
               mouse_y > onsetitem_row_y and mouse_y < onsetitem_row_y + checkbox_size then
                refresh_onset_item_items()
                local max_idx = #onset_item_items
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                onset_item_index = onset_item_index + delta
                if onset_item_index < 0 then onset_item_index = max_idx end
                if onset_item_index > max_idx then onset_item_index = 0 end
                wheel_handled = true
            end
        end
        -- Check if mouse is over MIDI bank scrollable button
        local midibank_btn_x_w = sett_simple_btn_x
        local midibank_btn_w_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
        if not wheel_handled and mouse_x > midibank_btn_x_w and mouse_x < midibank_btn_x_w + midibank_btn_w_w and
           mouse_y > midibank_row_y and mouse_y < midibank_row_y + checkbox_size then
            -- Build flat list of valid GM programs (skip submenu headers)
            local flat_programs = {}
            for _, p in ipairs(gm_presets) do
                if p.name:sub(1,1) ~= ">" then
                    local clean_name = p.name:gsub("^<", "")
                    table.insert(flat_programs, {name = clean_name, program = p.program})
                end
            end
            -- Read current program from selected item
            local current_program = nil
            local num_sel_items = reaper.CountSelectedMediaItems(0)
            if num_sel_items > 0 then
                local item = reaper.GetSelectedMediaItem(0, 0)
                local take = item and reaper.GetActiveTake(item)
                if take and reaper.TakeIsMIDI(take) then
                    local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                    if gotAllOK then
                        local MIDIlen = MIDIstring:len()
                        local stringPos = 1
                        local abs_pos = 0
                        while stringPos < MIDIlen do
                            local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                            abs_pos = abs_pos + offset
                            if abs_pos == 0 and msg:len() >= 2 then
                                local status = msg:byte(1)
                                if (status >> 4) == 0xC then
                                    current_program = msg:byte(2)
                                end
                            end
                            if abs_pos > 0 then break end
                            stringPos = newPos
                        end
                    end
                end
            end
            -- Find current index in flat list
            local current_idx = 1
            if current_program then
                for j, fp in ipairs(flat_programs) do
                    if fp.program == current_program then current_idx = j; break end
                end
            end
            local delta = gfx.mouse_wheel > 0 and -1 or 1
            current_idx = current_idx + delta
            if current_idx < 1 then current_idx = #flat_programs end
            if current_idx > #flat_programs then current_idx = 1 end
            local new_preset = flat_programs[current_idx]
            if new_preset and num_sel_items > 0 then
                reaper.Undo_BeginBlock()
                for i = 0, num_sel_items - 1 do
                    local item = reaper.GetSelectedMediaItem(0, i)
                    local take = reaper.GetActiveTake(item)
                    if take and reaper.TakeIsMIDI(take) then
                        local _, cc_count = reaper.MIDI_CountEvts(take)
                        for ci = cc_count - 1, 0, -1 do
                            local _, _, _, ppqpos, _, _, cc_num = reaper.MIDI_GetCC(take, ci)
                            if ppqpos == 0 and (cc_num == 0 or cc_num == 32) then
                                reaper.MIDI_DeleteCC(take, ci)
                            end
                        end
                        local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                        if gotAllOK then
                            local MIDIlen = MIDIstring:len()
                            local tableEvents = {}
                            local stringPos = 1
                            local abs_pos = 0
                            while stringPos < MIDIlen do
                                local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                                abs_pos = abs_pos + offset
                                local dominated = false
                                if abs_pos == 0 and msg:len() >= 1 then
                                    local status = msg:byte(1)
                                    if (status >> 4) == 0xC then dominated = true end
                                end
                                if not dominated then
                                    table.insert(tableEvents, string.pack("i4Bs4", offset, flags, msg))
                                end
                                stringPos = newPos
                            end
                            reaper.MIDI_SetAllEvts(take, table.concat(tableEvents))
                        end
                        local ch = 0
                        reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 0, 0)
                        reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 32, 0)
                        reaper.MIDI_InsertCC(take, false, false, 0, 0xC0, ch, new_preset.program, 0)
                        reaper.MIDI_Sort(take)
                    end
                end
                reaper.Undo_EndBlock("Assign GM Program: " .. new_preset.name, -1)
            end
            wheel_handled = true
        end
        -- Check if mouse is over Key Signature buttons
        if not wheel_handled then
            local keysig_label_w = gfx.measurestr("Key Signature  ")
            local keysig_root_btn_x = horizontal_margin + keysig_label_w
            local keysig_total_btn_w = cb_x - COL_SPACING - keysig_root_btn_x
            local keysig_gap = 4
            local keysig_root_btn_w = math.floor(keysig_total_btn_w * 0.25)
            local keysig_scale_btn_x = keysig_root_btn_x + keysig_root_btn_w + keysig_gap
            local keysig_scale_btn_w = keysig_total_btn_w - keysig_root_btn_w - keysig_gap
            local on_root_btn = (mouse_x >= keysig_root_btn_x and mouse_x < keysig_root_btn_x + keysig_root_btn_w and
                                 mouse_y >= keysig_row_y and mouse_y < keysig_row_y + checkbox_size)
            local on_scale_btn = (mouse_x >= keysig_scale_btn_x and mouse_x < keysig_scale_btn_x + keysig_scale_btn_w and
                                  mouse_y >= keysig_row_y and mouse_y < keysig_row_y + checkbox_size)
            if on_root_btn or on_scale_btn then
                -- Read current KSIG
                local cur_root, cur_notes = 0, KEYSIG_MAJOR_HEX
                local num_sel_ks = reaper.CountSelectedMediaItems(0)
                if num_sel_ks > 0 then
                    local item = reaper.GetSelectedMediaItem(0, 0)
                    local take = item and reaper.GetActiveTake(item)
                    if take and reaper.TakeIsMIDI(take) then
                        local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                        if gotAllOK then
                            local MIDIlen = MIDIstring:len()
                            local stringPos = 1
                            local abs_pos = 0
                            while stringPos < MIDIlen do
                                local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                                abs_pos = abs_pos + offset
                                if abs_pos == 0 and msg:len() >= 3 and msg:byte(1) == 0xFF and msg:byte(2) == 0x0F then
                                    local evt_text = msg:sub(3)
                                    local r, n = evt_text:match("^KSIG root (%d+) dir %-?%d+ notes 0x(%x+)")
                                    if r and n then cur_root = tonumber(r); cur_notes = tonumber(n, 16) end
                                end
                                if abs_pos > 0 then break end
                                stringPos = newPos
                            end
                        end
                    end
                end
                local delta = gfx.mouse_wheel > 0 and -1 or 1
                if on_root_btn then
                    local new_root = (cur_root + delta) % 12
                    if num_sel_ks > 0 then
                        reaper.Undo_BeginBlock()
                        for i = 0, num_sel_ks - 1 do
                            local item = reaper.GetSelectedMediaItem(0, i)
                            local take = reaper.GetActiveTake(item)
                            if take and reaper.TakeIsMIDI(take) then
                                keysig_write_event(take, new_root, cur_notes)
                            end
                        end
                        reaper.Undo_EndBlock("Set Key Signature Root: " .. keysig_root_names[new_root + 1], -1)
                    end
                else
                    -- Cycle scale
                    local cur_idx = 1
                    for j, sc in ipairs(keysig_scales_list) do
                        if sc.hex == cur_notes then cur_idx = j; break end
                    end
                    cur_idx = cur_idx + delta
                    if cur_idx < 1 then cur_idx = #keysig_scales_list end
                    if cur_idx > #keysig_scales_list then cur_idx = 1 end
                    local new_notes = keysig_scales_list[cur_idx].hex
                    if num_sel_ks > 0 then
                        reaper.Undo_BeginBlock()
                        for i = 0, num_sel_ks - 1 do
                            local item = reaper.GetSelectedMediaItem(0, i)
                            local take = reaper.GetActiveTake(item)
                            if take and reaper.TakeIsMIDI(take) then
                                keysig_write_event(take, cur_root, new_notes)
                            end
                        end
                        reaper.Undo_EndBlock("Set Key Signature Scale: " .. keysig_scales_list[cur_idx].name, -1)
                    end
                end
                wheel_handled = true
            end
        end
        -- Check if mouse is over an articulation type button
        if not wheel_handled then
        for i, art_name in ipairs(articulation_names_ordered) do
            local row_y = list_top + (i - 1) * checkbox_row_height
            if is_row_visible(row_y) then
                if mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH and
                   mouse_y > row_y and mouse_y < row_y + checkbox_size then
                    -- Cycle through type values
                    local current_type = get_art_type(art_name)
                    local current_idx = 1
                    for j, v in ipairs(art_type_values) do
                        if v == current_type then current_idx = j; break end
                    end
                    local delta = gfx.mouse_wheel > 0 and -1 or 1
                    current_idx = current_idx + delta
                    if current_idx < 1 then current_idx = #art_type_values end
                    if current_idx > #art_type_values then current_idx = 1 end
                    local new_type = art_type_values[current_idx]
                    if new_type ~= articulation_default_type[art_name] then
                        articulation_type_override[art_name] = new_type
                    else
                        articulation_type_override[art_name] = nil
                    end
                    wheel_handled = true
                    break
                end
            end
        end
        end  -- if not wheel_handled (articulation type buttons)
        if not wheel_handled then
            if mouse_y >= content_top and mouse_y <= content_bottom then
                local scroll_delta = -math.floor(gfx.mouse_wheel / 120) * checkbox_row_height
                settings_scroll_offset = settings_scroll_offset + scroll_delta
                if settings_scroll_offset < 0 then settings_scroll_offset = 0 end
                if settings_scroll_offset > max_scroll then settings_scroll_offset = max_scroll end
            end
        end
        gfx.mouse_wheel = 0
    end
    end -- end scope: click + keyboard + mousewheel handlers

    -- Hover states
    settings_import_hovered = (mouse_x > import_btn_x and mouse_x < import_btn_x + btn_width and
                               mouse_y > btn_y and mouse_y < btn_y + btn_height)
    settings_save_hovered = (mouse_x > save_btn_x and mouse_x < save_btn_x + btn_width and
                             mouse_y > btn_y and mouse_y < btn_y + btn_height)
    settings_restore_hovered = (mouse_x > restore_btn_x and mouse_x < restore_btn_x + btn_width and
                                mouse_y > btn_y and mouse_y < btn_y + btn_height)
    settings_close_hovered = (mouse_x > close_btn_x and mouse_x < close_btn_x + btn_width and
                              mouse_y > btn_y and mouse_y < btn_y + btn_height)

    -- Determine tooltip for current mouse position
    settings_tooltip_text = nil
    pending_tooltip = nil
    -- Settings button tooltips
    if settings_import_hovered then
        settings_tooltip_text = "Import the selected MusicXML file\nusing current settings."
    elseif settings_save_hovered then
        settings_tooltip_text = "Save all current settings as defaults.\nSettings persist across sessions."
    elseif settings_restore_hovered then
        settings_tooltip_text = "Restore all settings to their\nfactory default values."
    elseif settings_close_hovered then
        settings_tooltip_text = "Close settings and return\nto the main view."
    end
    -- Column header hover area
    if mouse_y >= col_header_y and mouse_y < list_top then
        if mouse_x >= sym_box_x and mouse_x < sym_box_x + SYM_BOX_WIDTH then
            settings_tooltip_text = settings_tooltips.Sym
        elseif mouse_x >= type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH then
            settings_tooltip_text = settings_tooltips.Type
        elseif mouse_x >= repl_col_x and mouse_x < repl_col_x + REPL_COL_WIDTH then
            settings_tooltip_text = settings_tooltips.RF
        elseif mouse_x >= prefix_cb_x and mouse_x < prefix_cb_x + checkbox_size then
            settings_tooltip_text = settings_tooltips.Prefix
        elseif mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = settings_tooltips.On
        elseif mouse_x >= menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
            settings_tooltip_text = settings_tooltips.M
        end
    end
    -- Highlight scan row hover
    if mouse_y >= hlscan_row_y and mouse_y < fret_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Highlight Used: scan the selected MusicXML file\nto highlight articulations that are actually used.\nDisable to avoid slowdowns on large files."
        end
    end
    -- Export regions row hover
    if mouse_y >= expreg_row_y and mouse_y < midibank_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Export Regions: include project regions\nas rehearsal marks (segments) in MusicXML export."
        end
    end
    -- MIDI program banks row hover
    if mouse_y >= midibank_row_y and mouse_y < keysig_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "MIDI Program Banks: import/export\nMIDI bank and program change info\nfrom/to MusicXML files."
        else
            local midibank_btn_x_t = sett_simple_btn_x
            local midibank_btn_w_t = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= midibank_btn_x_t and mouse_x < midibank_btn_x_t + midibank_btn_w_t then
                settings_tooltip_text = "Current MIDI bank of selected item.\nClick to assign GM program.\nMousewheel to cycle."
            end
        end
    end
    -- Key Signature row hover
    if mouse_y >= keysig_row_y and mouse_y < openwith_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Key Signature: import/export key\nsignature from/to MusicXML files.\nAlso writes KSIG notation event."
        else
            local ks_label_w = gfx.measurestr("Key Signature  ")
            local ks_root_btn_x = horizontal_margin + ks_label_w
            local ks_total_btn_w = cb_x - COL_SPACING - ks_root_btn_x
            local ks_root_btn_w = math.floor(ks_total_btn_w * 0.25)
            local ks_scale_btn_x = ks_root_btn_x + ks_root_btn_w + 4
            local ks_scale_btn_w = ks_total_btn_w - ks_root_btn_w - 4
            if mouse_x >= ks_root_btn_x and mouse_x < ks_root_btn_x + ks_root_btn_w then
                settings_tooltip_text = "Root note of key signature.\nClick to select, mousewheel to cycle."
            elseif mouse_x >= ks_scale_btn_x and mouse_x < ks_scale_btn_x + ks_scale_btn_w then
                settings_tooltip_text = "Scale/mode of key signature.\nClick to select, mousewheel to cycle."
            end
        end
    end
    -- Open With row hover
    if mouse_y >= openwith_row_y and mouse_y < openfolder_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Open After Export: open the exported file\nwith the specified external program."
        end
    end
    -- Open Folder row hover
    if mouse_y >= openfolder_row_y and mouse_y < import_hdr_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Open Folder: after export, open the\ncontaining folder in file explorer."
        end
    end
    -- Auto-focus row hover
    if mouse_y >= autofocus_row_y and mouse_y < stayontop_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Auto-Focus: automatically focus the window\nwhen the mouse hovers over it, and return\nfocus to REAPER when the mouse leaves."
        end
    end
    -- Stay-on-top row hover
    if mouse_y >= stayontop_row_y and mouse_y < font_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Stay on Top: keep the script window\nalways on top of other windows."
        end
    end
    -- Font row hover
    if mouse_y >= font_row_y and mouse_y < docker_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x then
            settings_tooltip_text = "Font: select the display font\nfor the script window."
        else
            local font_btn_x_t = sett_simple_btn_x
            local font_btn_w_t = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= font_btn_x_t and mouse_x < font_btn_x_t + font_btn_w_t then
                settings_tooltip_text = "Font: click or mousewheel to change."
            end
        end
    end
    -- Docker row hover
    if mouse_y >= docker_row_y and mouse_y < winpos_last_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Docker: dock the script window\non startup at the selected position."
        else
            local docker_btn_x_t = sett_simple_btn_x
            local docker_btn_w_t = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
            if mouse_x >= docker_btn_x_t and mouse_x < docker_btn_x_t + docker_btn_w_t then
                settings_tooltip_text = "Dock position: click or mousewheel to change.\nBottom, Left, Top, Right."
            end
        end
    end
    -- Window position rows hover
    if mouse_y >= winpos_last_row_y and mouse_y < winpos_mouse_row_y then
        settings_tooltip_text = "Open window at the last saved\nscreen position on next launch."
    end
    if mouse_y >= winpos_mouse_row_y and mouse_y < winsize_row_y then
        settings_tooltip_text = "Open window centered under\nthe mouse cursor on next launch."
    end
    -- Remember size row hover
    if mouse_y >= winsize_row_y and mouse_y < defpath_row_y then
        settings_tooltip_text = "Remember Size: save window dimensions\nseparately for main and settings tabs."
    end
    -- Default path row hover
    if mouse_y >= defpath_row_y and mouse_y < lastpath_row_y then
        if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Use the default folder below\nwhen opening the file browser."
        elseif mouse_x >= horizontal_margin and mouse_x < gfx.w - horizontal_margin then
            settings_tooltip_text = "Default folder for the file browser.\nClick to edit. Supports Ctrl+C/V/X/A."
        end
    end
    -- Last opened path row hover
    if mouse_y >= lastpath_row_y and mouse_y < tips_row_y then
        if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Use the last imported folder\nwhen opening the file browser."
        elseif mouse_x >= horizontal_margin and mouse_x < gfx.w - horizontal_margin then
            settings_tooltip_text = "Last folder used for importing.\nUpdated automatically after each import."
        end
    end
    -- Hover Tips row hover
    if mouse_y >= tips_row_y and mouse_y < export_hdr_y then
        settings_tooltip_text = "Hover Tips: show descriptive tooltips\nwhen hovering over UI elements."
    end
    -- Import checkbox rows hover
    for i = 1, #checkboxes_list do
        local ry = import_row_y[i]
        if mouse_y >= ry and mouse_y < ry + checkbox_row_height then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                settings_tooltip_text = "Show this option in the main menu."
            elseif mouse_x >= prefix_cb_x and mouse_x < prefix_cb_x + checkbox_size then
                settings_tooltip_text = "Enable/disable this import option."
            elseif mouse_x >= horizontal_margin and mouse_x < prefix_cb_x and checkboxes_list[i].tip then
                settings_tooltip_text = checkboxes_list[i].tip
            end
        end
    end
    -- GM Track Names row hover
    if mouse_y >= gmname_row_y and mouse_y < gmname_row_y + checkbox_row_height then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "GM Track Names: use the General MIDI\npreset name (e.g. 'Electric Guitar (clean)')\nas the track name instead of the\noriginal part name from the file."
        end
    end
    -- Import Position row hover
    if mouse_y >= importpos_row_y and mouse_y < importpos_row_y + checkbox_row_height then
        if mouse_x >= horizontal_margin then
            settings_tooltip_text = "Where to place imported content\n(MIDI items, tempo markers, and regions):\n• Start of Project — position 0\n• Edit Cursor — at the current edit cursor\n• Closest Region Start — start of the nearest region\n• Closest Marker — at the nearest project marker"
        end
    end
    -- Auto-load by Region row hover
    if mouse_y >= autoloadrgn_row_y and mouse_y < autoloadrgn_row_y + checkbox_row_height then
        if mouse_x >= horizontal_margin then
            settings_tooltip_text = "Auto-load by Region: when enabled,\nautomatically loads a MusicXML file from\nthe import path if its name contains\nthe region name at the edit cursor.\nE.g. cursor at region 'Heart-Shaped Box'\nmatches 'Nirvana-Heart Shaped Box-06-22-2025.xml'"
        end
    end
    -- MIDI Timebase row hover
    if mouse_y >= timebase_row_y and mouse_y < timebase_row_y + checkbox_row_height then
        if mouse_x >= horizontal_margin then
            settings_tooltip_text = "MIDI item timebase for imported items:\n• Project default — uses the project setting\n• Time — absolute time, notes don't follow tempo\n• Beats (pos, len, rate) — fully beat-based\n• Beats (pos only) — position follows tempo"
        end
    end
    -- Fret number row hover
    if mouse_y >= fret_row_y and mouse_y < span_row_y then
        if mouse_x >= type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH then
            settings_tooltip_text = settings_tooltips.FretType
        elseif mouse_x >= horizontal_margin and mouse_x < sym_box_x then
            settings_tooltip_text = settings_tooltips.Fret
        elseif mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = settings_tooltips.Fret
        end
    end
    -- Duration Lines row hover
    if mouse_y >= span_row_y and mouse_y < separator_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x then
            settings_tooltip_text = "Duration Lines: when enabled,\nconsecutive span articulations\n(Marker/Cue type) emit '----' and '-|'\ninstead of repeating the label."
        elseif mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Duration Lines: when enabled,\nconsecutive span articulations\n(Marker/Cue type) emit '----' and '-|'\ninstead of repeating the label."
        end
    end
    -- Articulation name hover
    if mouse_y >= content_top and mouse_y < content_bottom and mouse_y >= list_top then
        local hover_idx = math.floor((mouse_y - list_top) / checkbox_row_height) + 1
        if hover_idx >= 1 and hover_idx <= total_items then
            if mouse_x >= horizontal_margin and mouse_x < sym_box_x - COL_SPACING then
                settings_tooltip_text = "Click to write this articulation\nas a text event on selected MIDI notes."
            end
        end
    end

    -- Section header helper (with fold triangle)
    local function draw_section_hdr(label, y, folded)
        local hovered = (mouse_x >= horizontal_margin and mouse_x < gfx.w - horizontal_margin and
                         mouse_y >= y and mouse_y < y + section_hdr_h)
        -- Triangle indicator
        local tri_size = math.floor(gfx.texth * 0.45)
        local tri_x = horizontal_margin
        local tri_cy = y + math.floor(section_hdr_h / 2)
        if hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
        else
            gfx.set(0.45, 0.45, 0.45, 1)
        end
        if folded then
            -- Right-pointing triangle ▶
            local tx = tri_x
            local ty = tri_cy - tri_size
            for row = 0, tri_size * 2 do
                local w = math.floor(tri_size * (1 - math.abs(row - tri_size) / tri_size))
                if w > 0 then gfx.line(tx, ty + row, tx + w, ty + row) end
            end
        else
            -- Down-pointing triangle ▼
            local tx = tri_x
            local ty = tri_cy - math.floor(tri_size * 0.5)
            for row = 0, tri_size do
                local half_w = tri_size - row
                if half_w >= 0 then
                    local cx = tx + tri_size
                    gfx.line(cx - half_w, ty + row, cx + half_w, ty + row)
                end
            end
        end
        -- Label (offset past triangle)
        local label_x = tri_x + tri_size * 2 + 6
        local text_y = y + (section_hdr_h - gfx.texth) / 2
        if hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
        else
            gfx.set(0.45, 0.45, 0.45, 1)
        end
        gfx.x = label_x
        gfx.y = text_y
        gfx.drawstr(label)
        local lw = gfx.measurestr(label)
        local line_y = y + math.floor(section_hdr_h / 2)
        gfx.set(0.3, 0.3, 0.3, 1)
        gfx.line(label_x + lw + 8, line_y, gfx.w - horizontal_margin, line_y)
    end

    -- Draw section headers
    draw_section_hdr("GENERAL", general_hdr_y, settings_fold.general)
    draw_section_hdr("EXPORT", export_hdr_y, settings_fold.export)
    draw_section_hdr("IMPORT", import_hdr_y, settings_fold.import)
    draw_section_hdr("TRANSIENTS", transients_hdr_y, settings_fold.transients)
    draw_section_hdr("TEMPO MAP", tempomap_hdr_y, settings_fold.tempomap)
    draw_section_hdr("MIDI TOOLS", miditools_hdr_y, settings_fold.miditools)
    draw_section_hdr("INSERT AT MOUSE", iam_hdr_y, settings_fold.insertmouse)
    draw_section_hdr("ARTICULATION", art_hdr_y, settings_fold.articulation)
    draw_section_hdr("ARTICULATION GRID", artgrid_hdr_y, settings_fold.artgrid)

    -- Helper to draw the M (show-in-menu) checkbox
    local function draw_menu_flag_cb(x, y, flag)
        if flag then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(x, y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(x, y, checkbox_size, checkbox_size, 0)
        gfx.set(table.unpack(gui.colors.CHECKBOX_INNER_BORDER))
        gfx.rect(x + 1, y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if flag then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            local m_lbl = "M"
            local m_w = gfx.measurestr(m_lbl)
            gfx.x = x + (checkbox_size - m_w) / 2
            gfx.y = y + (checkbox_size - gfx.texth) / 2
            gfx.drawstr(m_lbl)
        end
    end

    do -- scope: fret + span + hlscan + expreg drawing (free locals)
    -- Draw fret number row
    local fret_text_y = fret_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = fret_text_y
    gfx.drawstr("Fret Number")
    -- Fret number type button
    local fret_type_label = art_type_labels[fret_number_type] or ("T" .. tostring(fret_number_type))
    local fret_type_hovered = (mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH and
                               mouse_y > fret_row_y and mouse_y < fret_row_y + checkbox_size)
    local fret_type_is_override = (fret_number_type ~= FRET_NUMBER_TYPE_DEFAULT)
    if fret_type_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(type_btn_x, fret_row_y, TYPE_BTN_WIDTH, checkbox_size, 1)
    if fret_type_is_override then
        gfx.set(0.45, 0.35, 0.17, 1)
    else
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    end
    gfx.rect(type_btn_x, fret_row_y, TYPE_BTN_WIDTH, checkbox_size, 0)
    if fret_type_is_override then
        gfx.set(1.0, 0.85, 0.5, 1)
    else
        gfx.set(table.unpack(gui.colors.TEXT))
    end
    local fret_lbl_w = gfx.measurestr(fret_type_label)
    gfx.x = type_btn_x + (TYPE_BTN_WIDTH - fret_lbl_w) / 2
    gfx.y = fret_text_y
    gfx.drawstr(fret_type_label)
    -- Fret number enabled checkbox
    draw_checkbox(cb_x, fret_row_y, checkbox_size, cb_x, "", fret_number_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, fret_row_y, settings_menu_flags.fret)

    -- Draw span line (duration lines) row
    local span_text_y = span_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = span_text_y
    gfx.drawstr("Duration Lines")
    draw_checkbox(cb_x, span_row_y, checkbox_size, cb_x, "", span_line_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, span_row_y, settings_menu_flags.span)

    -- Draw highlight scan row
    local hlscan_text_y = hlscan_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = hlscan_text_y
    gfx.drawstr("Highlight Used")
    draw_checkbox(cb_x, hlscan_row_y, checkbox_size, cb_x, "", highlight_scan_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, hlscan_row_y, settings_menu_flags.hlscan)

    -- Draw export regions row
    local expreg_text_y = expreg_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = expreg_text_y
    gfx.drawstr("Export Regions")
    draw_checkbox(cb_x, expreg_row_y, checkbox_size, cb_x, "", export_regions_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, expreg_row_y, settings_menu_flags.expreg)
    end -- end scope: fret + span + hlscan + expreg drawing

    do -- scope: midibank + keysig drawing (free locals)
    -- Draw MIDI program banks row
    local midibank_text_y = midibank_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = midibank_text_y
    gfx.drawstr("MIDI Program Banks")
    -- MIDI bank scrollable button (like fret number type button)
    local midibank_label = "—"
    local num_sel = reaper.CountSelectedMediaItems(0)
    if num_sel > 0 then
        local item = reaper.GetSelectedMediaItem(0, 0)
        local take = item and reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
            local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
            if gotAllOK then
                local MIDIlen = MIDIstring:len()
                local stringPos = 1
                local abs_pos = 0
                local found_program = nil
                while stringPos < MIDIlen do
                    local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                    abs_pos = abs_pos + offset
                    if abs_pos == 0 and msg:len() >= 2 then
                        local status = msg:byte(1)
                        if (status >> 4) == 0xC then
                            found_program = msg:byte(2)
                        end
                    end
                    if abs_pos > 0 then break end
                    stringPos = newPos
                end
                if found_program then
                    midibank_label = gm_program_to_name[found_program] or ("Program " .. tostring(found_program))
                end
            end
        end
    end
    local midibank_btn_x = sett_simple_btn_x
    local midibank_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local midibank_btn_hovered = (mouse_x >= midibank_btn_x and mouse_x < midibank_btn_x + midibank_btn_w and
                                  mouse_y >= midibank_row_y and mouse_y < midibank_row_y + checkbox_size)
    if midibank_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(midibank_btn_x, midibank_row_y, midibank_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(midibank_btn_x, midibank_row_y, midibank_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    -- Truncate label to fit button width
    local midibank_lbl_full = midibank_label
    local midibank_lbl_w = gfx.measurestr(midibank_lbl_full)
    if midibank_lbl_w > midibank_btn_w - 4 then
        while #midibank_lbl_full > 1 and gfx.measurestr(midibank_lbl_full .. "..") > midibank_btn_w - 4 do
            midibank_lbl_full = midibank_lbl_full:sub(1, -2)
        end
        midibank_lbl_full = midibank_lbl_full .. ".."
        midibank_lbl_w = gfx.measurestr(midibank_lbl_full)
    end
    gfx.x = midibank_btn_x + (midibank_btn_w - midibank_lbl_w) / 2
    gfx.y = midibank_text_y
    gfx.drawstr(midibank_lbl_full)
    -- Enabled checkbox
    draw_checkbox(cb_x, midibank_row_y, checkbox_size, cb_x, "", midi_program_banks_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, midibank_row_y, settings_menu_flags.midibank)

    -- Draw Key Signature row (two scrollable buttons: root + scale)
    local keysig_text_y = keysig_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = keysig_text_y
    gfx.drawstr("Key Signature")
    -- Read current KSIG from selected item
    local keysig_cur_root = nil
    local keysig_cur_notes = nil
    local keysig_num_sel = reaper.CountSelectedMediaItems(0)
    if keysig_num_sel > 0 then
        local item = reaper.GetSelectedMediaItem(0, 0)
        local take = item and reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
            local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
            if gotAllOK then
                local MIDIlen = MIDIstring:len()
                local stringPos = 1
                local abs_pos = 0
                while stringPos < MIDIlen do
                    local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                    abs_pos = abs_pos + offset
                    if abs_pos == 0 and msg:len() >= 3 and msg:byte(1) == 0xFF and msg:byte(2) == 0x0F then
                        local evt_text = msg:sub(3)
                        local r, n = evt_text:match("^KSIG root (%d+) dir %-?%d+ notes 0x(%x+)")
                        if r and n then
                            keysig_cur_root = tonumber(r)
                            keysig_cur_notes = tonumber(n, 16)
                        end
                    end
                    if abs_pos > 0 then break end
                    stringPos = newPos
                end
            end
        end
    end
    -- Root button
    local keysig_root_label = keysig_cur_root and keysig_root_names[keysig_cur_root + 1] or "—"
    local keysig_label_w = gfx.measurestr("Key Signature  ")
    local keysig_root_btn_x = horizontal_margin + keysig_label_w
    local keysig_total_btn_w = cb_x - COL_SPACING - keysig_root_btn_x
    local keysig_gap = 4
    local keysig_root_btn_w = math.floor(keysig_total_btn_w * 0.25)
    local keysig_scale_btn_x = keysig_root_btn_x + keysig_root_btn_w + keysig_gap
    local keysig_scale_btn_w = keysig_total_btn_w - keysig_root_btn_w - keysig_gap
    local keysig_root_hovered = (mouse_x >= keysig_root_btn_x and mouse_x < keysig_root_btn_x + keysig_root_btn_w and
                                 mouse_y >= keysig_row_y and mouse_y < keysig_row_y + checkbox_size)
    if keysig_root_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(keysig_root_btn_x, keysig_row_y, keysig_root_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(keysig_root_btn_x, keysig_row_y, keysig_root_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local keysig_root_lbl_w = gfx.measurestr(keysig_root_label)
    gfx.x = keysig_root_btn_x + (keysig_root_btn_w - keysig_root_lbl_w) / 2
    gfx.y = keysig_text_y
    gfx.drawstr(keysig_root_label)
    -- Scale button
    local keysig_scale_label = "—"
    if keysig_cur_notes then
        for _, sc in ipairs(keysig_scales_list) do
            if sc.hex == keysig_cur_notes then keysig_scale_label = sc.name; break end
        end
    end
    local keysig_scale_hovered = (mouse_x >= keysig_scale_btn_x and mouse_x < keysig_scale_btn_x + keysig_scale_btn_w and
                                  mouse_y >= keysig_row_y and mouse_y < keysig_row_y + checkbox_size)
    if keysig_scale_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(keysig_scale_btn_x, keysig_row_y, keysig_scale_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(keysig_scale_btn_x, keysig_row_y, keysig_scale_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    -- Truncate scale label
    local keysig_scale_lbl_full = keysig_scale_label
    local keysig_scale_lbl_w = gfx.measurestr(keysig_scale_lbl_full)
    if keysig_scale_lbl_w > keysig_scale_btn_w - 4 then
        while #keysig_scale_lbl_full > 1 and gfx.measurestr(keysig_scale_lbl_full .. "..") > keysig_scale_btn_w - 4 do
            keysig_scale_lbl_full = keysig_scale_lbl_full:sub(1, -2)
        end
        keysig_scale_lbl_full = keysig_scale_lbl_full .. ".."
        keysig_scale_lbl_w = gfx.measurestr(keysig_scale_lbl_full)
    end
    gfx.x = keysig_scale_btn_x + (keysig_scale_btn_w - keysig_scale_lbl_w) / 2
    gfx.y = keysig_text_y
    gfx.drawstr(keysig_scale_lbl_full)
    -- Enabled checkbox + M flag
    draw_checkbox(cb_x, keysig_row_y, checkbox_size, cb_x, "", export_key_sig_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, keysig_row_y, settings_menu_flags.keysig)
    end -- end scope: midibank + keysig drawing

    do -- scope: openwith + openfolder drawing (free locals)
    -- Draw Open With row
    local openwith_text_y = openwith_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = openwith_text_y
    local openwith_label = "Open After Export"
    gfx.drawstr(openwith_label)
    -- Text input box for Open With path
    local openwith_label_w = gfx.measurestr(openwith_label .. "  ")
    local openwith_box_x = horizontal_margin + openwith_label_w
    local openwith_box_w = gfx.w - openwith_box_x - horizontal_margin - checkbox_size - COL_SPACING - checkbox_size - COL_SPACING
    local openwith_box_pad = 4
    if openwith_edit_active then
        gfx.set(0.25, 0.25, 0.25, 1)
    else
        gfx.set(0.17, 0.17, 0.17, 1)
    end
    gfx.rect(openwith_box_x, openwith_row_y, openwith_box_w, checkbox_size, 1)
    if openwith_edit_active then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    end
    gfx.rect(openwith_box_x, openwith_row_y, openwith_box_w, checkbox_size, 0)
    local openwith_display_text = openwith_edit_active and openwith_edit_text or export_open_with_path
    local openwith_inner_w = openwith_box_w - openwith_box_pad * 2
    local openwith_scroll_px = 0
    if openwith_edit_active then
        local cursor_px = gfx.measurestr(openwith_edit_text:sub(1, openwith_edit_cursor))
        if cursor_px > openwith_inner_w then
            openwith_scroll_px = cursor_px - openwith_inner_w + 10
        end
    end
    -- Draw selection highlight
    if openwith_edit_active and openwith_edit_sel >= 0 and openwith_edit_sel ~= openwith_edit_cursor then
        local s = math.min(openwith_edit_cursor, openwith_edit_sel)
        local e = math.max(openwith_edit_cursor, openwith_edit_sel)
        local sel_x1 = gfx.measurestr(openwith_edit_text:sub(1, s)) - openwith_scroll_px
        local sel_x2 = gfx.measurestr(openwith_edit_text:sub(1, e)) - openwith_scroll_px
        sel_x1 = math.max(0, math.min(sel_x1, openwith_inner_w))
        sel_x2 = math.max(0, math.min(sel_x2, openwith_inner_w))
        gfx.set(0.17, 0.45, 0.39, 0.5)
        gfx.rect(openwith_box_x + openwith_box_pad + sel_x1, openwith_row_y + 2,
                 sel_x2 - sel_x1, checkbox_size - 4, 1)
    end
    -- Draw text
    if openwith_display_text == "" and not openwith_edit_active then
        gfx.set(0.4, 0.4, 0.4, 1)
        gfx.x = openwith_box_x + openwith_box_pad
        gfx.y = openwith_text_y
        local placeholder = truncate_text("(path to .exe)", openwith_inner_w)
        gfx.drawstr(placeholder)
    else
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = openwith_box_x + openwith_box_pad
        gfx.y = openwith_text_y
        if openwith_scroll_px > 0 then
            local start_char = 0
            for ci = 1, #openwith_display_text do
                if gfx.measurestr(openwith_display_text:sub(1, ci)) > openwith_scroll_px then
                    start_char = ci - 1
                    break
                end
            end
            gfx.x = openwith_box_x + openwith_box_pad
            local scrolled_text = openwith_display_text:sub(start_char + 1)
            scrolled_text = truncate_text(scrolled_text, openwith_inner_w)
            gfx.drawstr(scrolled_text)
        else
            local display = truncate_text(openwith_display_text, openwith_inner_w)
            gfx.drawstr(display)
        end
    end
    -- Draw cursor
    if openwith_edit_active then
        local cursor_px = gfx.measurestr(openwith_edit_text:sub(1, openwith_edit_cursor)) - openwith_scroll_px
        cursor_px = math.max(0, math.min(cursor_px, openwith_inner_w))
        if math.floor(os.clock() * 2) % 2 == 0 then
            gfx.set(1, 1, 1, 0.9)
            gfx.line(openwith_box_x + openwith_box_pad + cursor_px, openwith_row_y + 2,
                     openwith_box_x + openwith_box_pad + cursor_px, openwith_row_y + checkbox_size - 2)
        end
    end
    draw_checkbox(cb_x, openwith_row_y, checkbox_size, cb_x, "", export_open_with_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, openwith_row_y, settings_menu_flags.openwith)

    -- Draw Open Folder row
    local openfolder_text_y = openfolder_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = openfolder_text_y
    gfx.drawstr("Open Folder")
    draw_checkbox(cb_x, openfolder_row_y, checkbox_size, cb_x, "", export_open_folder_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, openfolder_row_y, settings_menu_flags.openfolder)
    end -- end scope: openwith + openfolder drawing

    do -- scope: autofocus + stayontop + font + docker + winpos + winsize + defpath + lastpath drawing (free locals)
    -- Draw auto-focus row
    local autofocus_text_y = autofocus_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = autofocus_text_y
    gfx.drawstr("Auto-Focus")
    draw_checkbox(cb_x, autofocus_row_y, checkbox_size, cb_x, "", auto_focus_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, autofocus_row_y, settings_menu_flags.autofocus)

    -- Draw stay-on-top row
    local stayontop_text_y = stayontop_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = stayontop_text_y
    gfx.drawstr("Stay on Top")
    draw_checkbox(cb_x, stayontop_row_y, checkbox_size, cb_x, "", stay_on_top_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, stayontop_row_y, settings_menu_flags.stayontop)

    -- Draw font row
    local font_text_y = font_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = font_text_y
    gfx.drawstr("Font")
    -- Font scrollable button
    local font_btn_x = sett_simple_btn_x
    local font_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local font_label = font_list[current_font_index] or "Outfit"
    local font_btn_hovered = (mouse_x >= font_btn_x and mouse_x < font_btn_x + font_btn_w and
                              mouse_y >= font_row_y and mouse_y < font_row_y + checkbox_size)
    if font_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(font_btn_x, font_row_y, font_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(font_btn_x, font_row_y, font_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    -- Truncate label to fit
    local font_lbl_full = font_label
    local font_lbl_w = gfx.measurestr(font_lbl_full)
    if font_lbl_w > font_btn_w - 4 then
        while #font_lbl_full > 1 and gfx.measurestr(font_lbl_full .. "..") > font_btn_w - 4 do
            font_lbl_full = font_lbl_full:sub(1, -2)
        end
        font_lbl_full = font_lbl_full .. ".."
        font_lbl_w = gfx.measurestr(font_lbl_full)
    end
    gfx.x = font_btn_x + (font_btn_w - font_lbl_w) / 2
    gfx.y = font_text_y
    gfx.drawstr(font_lbl_full)
    draw_menu_flag_cb(menu_cb_x, font_row_y, settings_menu_flags.font)

    -- Draw docker row
    local docker_text_y = docker_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = docker_text_y
    gfx.drawstr("Docker")
    -- Docker position scrollable button
    local docker_btn_x = sett_simple_btn_x
    local docker_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local docker_pos_label = docker_positions[docker_position] or "Bottom"
    local docker_btn_hovered = (mouse_x >= docker_btn_x and mouse_x < docker_btn_x + docker_btn_w and
                                mouse_y >= docker_row_y and mouse_y < docker_row_y + checkbox_size)
    if docker_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(docker_btn_x, docker_row_y, docker_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(docker_btn_x, docker_row_y, docker_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    -- Truncate label to fit
    local docker_lbl_full = docker_pos_label
    local docker_lbl_w = gfx.measurestr(docker_lbl_full)
    if docker_lbl_w > docker_btn_w - 4 then
        while #docker_lbl_full > 1 and gfx.measurestr(docker_lbl_full .. "..") > docker_btn_w - 4 do
            docker_lbl_full = docker_lbl_full:sub(1, -2)
        end
        docker_lbl_full = docker_lbl_full .. ".."
        docker_lbl_w = gfx.measurestr(docker_lbl_full)
    end
    gfx.x = docker_btn_x + (docker_btn_w - docker_lbl_w) / 2
    gfx.y = docker_text_y
    gfx.drawstr(docker_lbl_full)
    -- Docker enabled checkbox
    draw_checkbox(cb_x, docker_row_y, checkbox_size, cb_x, "", docker_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, docker_row_y, settings_menu_flags.docker)

    -- Draw window position rows (radio pair)
    -- "Last Position" row
    local winpos_last_text_y = winpos_last_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = winpos_last_text_y
    gfx.drawstr("Last Position")
    -- Show live window coordinates
    local wlp_label_w = gfx.measurestr("Last Position  ")
    local _, live_wx, live_wy = gfx.dock(-1, 0, 0, 0, 0)
    gfx.set(0.5, 0.5, 0.5, 1)
    gfx.x = horizontal_margin + wlp_label_w
    gfx.y = winpos_last_text_y
    gfx.drawstr(tostring(math.floor(live_wx)) .. ", " .. tostring(math.floor(live_wy)))
    draw_checkbox(cb_x, winpos_last_row_y, checkbox_size, cb_x, "", window_position_mode == "last", gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, winpos_last_row_y, settings_menu_flags.winpos_last)

    -- "At Mouse" row
    local winpos_mouse_text_y = winpos_mouse_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = winpos_mouse_text_y
    gfx.drawstr("At Mouse")
    draw_checkbox(cb_x, winpos_mouse_row_y, checkbox_size, cb_x, "", window_position_mode == "mouse", gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, winpos_mouse_row_y, settings_menu_flags.winpos_mouse)

    -- "Remember Size" row
    local winsize_text_y = winsize_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = winsize_text_y
    gfx.drawstr("Remember Size")
    -- Show live window size
    local wrs_label_w = gfx.measurestr("Remember Size  ")
    gfx.set(0.5, 0.5, 0.5, 1)
    gfx.x = horizontal_margin + wrs_label_w
    gfx.y = winsize_text_y
    gfx.drawstr(tostring(math.floor(gfx.w)) .. " x " .. tostring(math.floor(gfx.h)))
    draw_checkbox(cb_x, winsize_row_y, checkbox_size, cb_x, "", remember_window_size, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, winsize_row_y, settings_menu_flags.winsize)

    -- Draw default path row
    local defpath_text_y = defpath_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = defpath_text_y
    local defpath_label = "Default Path"
    gfx.drawstr(defpath_label)
    -- Text input box for default path
    local defpath_label_w = gfx.measurestr(defpath_label .. "  ")
    local defpath_box_x = horizontal_margin + defpath_label_w
    local defpath_box_w = gfx.w - defpath_box_x - horizontal_margin - checkbox_size - COL_SPACING - checkbox_size - COL_SPACING
    local defpath_box_pad = 4
    -- Box background
    if defpath_edit_active then
        gfx.set(0.25, 0.25, 0.25, 1)
    else
        gfx.set(0.17, 0.17, 0.17, 1)
    end
    gfx.rect(defpath_box_x, defpath_row_y, defpath_box_w, checkbox_size, 1)
    -- Box border
    if defpath_edit_active then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    end
    gfx.rect(defpath_box_x, defpath_row_y, defpath_box_w, checkbox_size, 0)
    -- Text content
    local defpath_display_text = defpath_edit_active and defpath_edit_text or default_import_dir
    local defpath_inner_w = defpath_box_w - defpath_box_pad * 2
    -- Calculate scroll offset so cursor is always visible
    local defpath_scroll_px = 0
    if defpath_edit_active then
        local cursor_px = gfx.measurestr(defpath_edit_text:sub(1, defpath_edit_cursor))
        if cursor_px > defpath_inner_w then
            defpath_scroll_px = cursor_px - defpath_inner_w + 10
        end
    end
    -- Draw selection highlight
    if defpath_edit_active and defpath_edit_sel >= 0 and defpath_edit_sel ~= defpath_edit_cursor then
        local s = math.min(defpath_edit_cursor, defpath_edit_sel)
        local e = math.max(defpath_edit_cursor, defpath_edit_sel)
        local sel_x1 = gfx.measurestr(defpath_edit_text:sub(1, s)) - defpath_scroll_px
        local sel_x2 = gfx.measurestr(defpath_edit_text:sub(1, e)) - defpath_scroll_px
        sel_x1 = math.max(0, math.min(sel_x1, defpath_inner_w))
        sel_x2 = math.max(0, math.min(sel_x2, defpath_inner_w))
        gfx.set(0.17, 0.45, 0.39, 0.5)
        gfx.rect(defpath_box_x + defpath_box_pad + sel_x1, defpath_row_y + 2,
                 sel_x2 - sel_x1, checkbox_size - 4, 1)
    end
    -- Draw text (clipped to box)
    if defpath_display_text == "" and not defpath_edit_active then
        gfx.set(0.4, 0.4, 0.4, 1)
        gfx.x = defpath_box_x + defpath_box_pad
        gfx.y = defpath_text_y
        local placeholder = truncate_text("(paste or type path)", defpath_inner_w)
        gfx.drawstr(placeholder)
    else
        gfx.set(table.unpack(gui.colors.TEXT))
        local visible_text = truncate_text(defpath_display_text, defpath_inner_w + defpath_scroll_px)
        -- Offset by scroll
        gfx.x = defpath_box_x + defpath_box_pad
        gfx.y = defpath_text_y
        if defpath_scroll_px > 0 then
            -- Only draw the portion that's visible after scrolling
            local full_w = gfx.measurestr(visible_text)
            local clip_start = defpath_scroll_px
            -- Find first visible character
            local start_char = 0
            for ci = 1, #defpath_display_text do
                if gfx.measurestr(defpath_display_text:sub(1, ci)) > defpath_scroll_px then
                    start_char = ci - 1
                    break
                end
            end
            local offset_w = gfx.measurestr(defpath_display_text:sub(1, start_char))
            gfx.x = defpath_box_x + defpath_box_pad - (offset_w - defpath_scroll_px + gfx.measurestr(defpath_display_text:sub(1, start_char)) - offset_w)
            -- Simpler approach: just offset the x position
            gfx.x = defpath_box_x + defpath_box_pad
            local scrolled_text = defpath_display_text:sub(start_char + 1)
            scrolled_text = truncate_text(scrolled_text, defpath_inner_w)
            gfx.drawstr(scrolled_text)
        else
            local display = truncate_text(defpath_display_text, defpath_inner_w)
            gfx.drawstr(display)
        end
    end
    -- Draw cursor if editing
    if defpath_edit_active then
        local cursor_px = gfx.measurestr(defpath_edit_text:sub(1, defpath_edit_cursor)) - defpath_scroll_px
        cursor_px = math.max(0, math.min(cursor_px, defpath_inner_w))
        if math.floor(os.clock() * 2) % 2 == 0 then
            gfx.set(1, 1, 1, 0.9)
            gfx.line(defpath_box_x + defpath_box_pad + cursor_px, defpath_row_y + 2,
                     defpath_box_x + defpath_box_pad + cursor_px, defpath_row_y + checkbox_size - 2)
        end
    end
    -- Draw radio checkbox for default path
    draw_checkbox(cb_x, defpath_row_y, checkbox_size, cb_x, "", path_mode == "default", gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, defpath_row_y, settings_menu_flags.defpath)

    -- Draw last opened path row
    local lastpath_text_y = lastpath_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = lastpath_text_y
    local lastpath_label = "Last Opened"
    gfx.drawstr(lastpath_label)
    -- Display last import dir as read-only text
    local lastpath_label_w = gfx.measurestr(lastpath_label .. "  ")
    local lastpath_val_x = horizontal_margin + lastpath_label_w
    local lastpath_val_w = gfx.w - lastpath_val_x - horizontal_margin - checkbox_size - COL_SPACING - checkbox_size - COL_SPACING
    if last_import_dir and last_import_dir ~= "" then
        gfx.set(0.6, 0.6, 0.6, 1)
        gfx.x = lastpath_val_x
        gfx.y = lastpath_text_y
        local display = truncate_text(last_import_dir, lastpath_val_w)
        gfx.drawstr(display)
    else
        gfx.set(0.4, 0.4, 0.4, 1)
        gfx.x = lastpath_val_x
        gfx.y = lastpath_text_y
        local placeholder = truncate_text("(no previous import)", lastpath_val_w)
        gfx.drawstr(placeholder)
    end
    -- Draw radio checkbox for last opened path
    draw_checkbox(cb_x, lastpath_row_y, checkbox_size, cb_x, "", path_mode == "last", gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, lastpath_row_y, settings_menu_flags.lastpath)
    end -- end scope: autofocus + stayontop + font + docker + winpos + winsize + defpath + lastpath drawing

    -- Draw Tips checkbox row (General section)
    do
    local tips_text_y = tips_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = tips_text_y
    gfx.drawstr("Hover Tips")
    draw_checkbox(cb_x, tips_row_y, checkbox_size, cb_x, "", tips_enabled, gui.colors, 0, nil)
    end

    -- Draw import checkbox rows
    for i, cb in ipairs(checkboxes_list) do
        local ry = import_row_y[i]
        local text_y_i = ry + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = text_y_i
        gfx.drawstr(truncate_text(cb.name, cb_x - horizontal_margin - COL_SPACING))
        -- Value checkbox
        draw_checkbox(cb_x, ry, checkbox_size, cb_x, "", cb.checked, gui.colors, 0, nil)
        -- Show-in-menu toggle
        draw_menu_flag_cb(menu_cb_x, ry, cb.show_in_menu)
    end

    -- Draw GM Track Names row
    do
    local gmname_text_y = gmname_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = gmname_text_y
    gfx.drawstr("GM Track Names")
    draw_checkbox(cb_x, gmname_row_y, checkbox_size, cb_x, "", gm_name_tracks_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, gmname_row_y, settings_menu_flags.gmname)
    end

    do -- scope: importpos + autoloadrgn + timebase + alignstem drawing (free locals)
    -- Draw Auto-load by Region row
    local autoloadrgn_text_y = autoloadrgn_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = autoloadrgn_text_y
    gfx.drawstr("Auto-load by Region")
    draw_checkbox(cb_x, autoloadrgn_row_y, checkbox_size, cb_x, "", autoload_by_region_enabled, gui.colors, 0, nil)
    draw_menu_flag_cb(menu_cb_x, autoloadrgn_row_y, settings_menu_flags.autoloadrgn)

    -- Draw MIDI Timebase row (scrollable button, no checkbox)
    local timebase_text_y = timebase_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = timebase_text_y
    gfx.drawstr("MIDI Timebase")
    -- Scrollable button
    local timebase_btn_x = sett_simple_btn_x
    local timebase_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local timebase_label = import_timebase_options[import_timebase_index] or "Project default"
    local timebase_btn_hovered = (mouse_x >= timebase_btn_x and mouse_x < timebase_btn_x + timebase_btn_w and
                                   mouse_y >= timebase_row_y and mouse_y < timebase_row_y + checkbox_size)
    if timebase_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(timebase_btn_x, timebase_row_y, timebase_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(timebase_btn_x, timebase_row_y, timebase_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local timebase_lbl_full = timebase_label
    local timebase_lbl_w = gfx.measurestr(timebase_lbl_full)
    if timebase_lbl_w > timebase_btn_w - 4 then
        while #timebase_lbl_full > 1 and gfx.measurestr(timebase_lbl_full .. "..") > timebase_btn_w - 4 do
            timebase_lbl_full = timebase_lbl_full:sub(1, -2)
        end
        timebase_lbl_full = timebase_lbl_full .. ".."
        timebase_lbl_w = gfx.measurestr(timebase_lbl_full)
    end
    gfx.x = timebase_btn_x + (timebase_btn_w - timebase_lbl_w) / 2
    gfx.y = timebase_text_y
    gfx.drawstr(timebase_lbl_full)
    draw_menu_flag_cb(menu_cb_x, timebase_row_y, settings_menu_flags.timebase)

    -- Draw Tempo Map Frequency row (scrollable button, no checkbox)
    local tempofreq_text_y = tempofreq_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = tempofreq_text_y
    gfx.drawstr("Tempo Map Freq")
    local tempofreq_btn_x = sett_simple_btn_x
    local tempofreq_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local tempofreq_label = tempo_map_freq_options[tempo_map_freq_index] or "Off"
    local tempofreq_btn_hovered = (mouse_x >= tempofreq_btn_x and mouse_x < tempofreq_btn_x + tempofreq_btn_w and
                                   mouse_y >= tempofreq_row_y and mouse_y < tempofreq_row_y + checkbox_size)
    if tempofreq_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(tempofreq_btn_x, tempofreq_row_y, tempofreq_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(tempofreq_btn_x, tempofreq_row_y, tempofreq_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local tempofreq_lbl_w = gfx.measurestr(tempofreq_label)
    gfx.x = tempofreq_btn_x + (tempofreq_btn_w - tempofreq_lbl_w) / 2
    gfx.y = tempofreq_text_y
    gfx.drawstr(tempofreq_label)
    draw_menu_flag_cb(menu_cb_x, tempofreq_row_y, settings_menu_flags.tempofreq)
    if tempofreq_btn_hovered and tips_enabled then
        pending_tooltip = "How often to write tempo markers.\n'Off' disables tempo map writing.\nLower values = more markers, finer tempo changes."
    end

    -- Draw Time Signature row (scrollable button, no checkbox)
    local timesig_text_y = tempotimesig_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = timesig_text_y
    gfx.drawstr("Time Signature")
    local timesig_btn_x = sett_simple_btn_x
    local timesig_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local timesig_label = tempo_timesig_options[tempo_timesig_index] or "4/4"
    local timesig_btn_hovered = (mouse_x >= timesig_btn_x and mouse_x < timesig_btn_x + timesig_btn_w and
                                  mouse_y >= tempotimesig_row_y and mouse_y < tempotimesig_row_y + checkbox_size)
    if timesig_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(timesig_btn_x, tempotimesig_row_y, timesig_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(timesig_btn_x, tempotimesig_row_y, timesig_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local timesig_lbl_w = gfx.measurestr(timesig_label)
    gfx.x = timesig_btn_x + (timesig_btn_w - timesig_lbl_w) / 2
    gfx.y = timesig_text_y
    gfx.drawstr(timesig_label)
    draw_menu_flag_cb(menu_cb_x, tempotimesig_row_y, settings_menu_flags.tempotimesig)
    if timesig_btn_hovered and tips_enabled then
        local eff_n, eff_d = get_detect_tempo_timesig()
        local eff_str = eff_n and (eff_n .. "/" .. eff_d) or "N/A"
        pending_tooltip = "Base time signature for tempo detection.\nUsed directly when freq >= 1 bar.\nFor sub-bar freq, effective time sig: " .. eff_str
    end

    do -- scope: detectmethod + detecttempo + 4 sliders + useexisting + firstmarkerbar1 drawing (free locals)
    -- Draw Detect Method row (scrollable button, no checkbox)
    local detectmethod_text_y = detectmethod_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = detectmethod_text_y
    gfx.drawstr("Detect Method")
    local detectmethod_btn_x = sett_simple_btn_x
    local detectmethod_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local detectmethod_label = tempo_detect_method_options[tempo_detect_method_index] or "Lua"
    local detectmethod_btn_hovered = (mouse_x >= detectmethod_btn_x and mouse_x < detectmethod_btn_x + detectmethod_btn_w and
                                      mouse_y >= detectmethod_row_y and mouse_y < detectmethod_row_y + checkbox_size)
    if detectmethod_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(detectmethod_btn_x, detectmethod_row_y, detectmethod_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(detectmethod_btn_x, detectmethod_row_y, detectmethod_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local detectmethod_lbl_w = gfx.measurestr(detectmethod_label)
    gfx.x = detectmethod_btn_x + (detectmethod_btn_w - detectmethod_lbl_w) / 2
    gfx.y = detectmethod_text_y
    gfx.drawstr(detectmethod_label)
    draw_menu_flag_cb(menu_cb_x, detectmethod_row_y, settings_menu_flags.detectmethod)
    if detectmethod_btn_hovered and tips_enabled then
        pending_tooltip = "Algorithm for detecting audio transients.\nLua: built-in, no dependencies.\nPython: external, may be more accurate."
    end

    -- Draw Detect Item row (scrollable button)
    do
    local detectitem_text_y = detectitem_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = detectitem_text_y
    gfx.drawstr("Detect Item")
    local detectitem_btn_x = sett_simple_btn_x
    local detectitem_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local detectitem_label
    if detect_tempo_item_index <= 0 then
        detectitem_label = "Selected Item"
    elseif detect_tempo_item_index <= #detect_tempo_item_items then
        detectitem_label = detect_tempo_item_items[detect_tempo_item_index].name
    else
        detectitem_label = "Selected Item"
    end
    local detectitem_btn_hovered = (mouse_x >= detectitem_btn_x and mouse_x < detectitem_btn_x + detectitem_btn_w and
                                    mouse_y >= detectitem_row_y and mouse_y < detectitem_row_y + checkbox_size)
    if detectitem_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(detectitem_btn_x, detectitem_row_y, detectitem_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(detectitem_btn_x, detectitem_row_y, detectitem_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local detectitem_lbl_w = gfx.measurestr(detectitem_label)
    if detectitem_lbl_w > detectitem_btn_w - 8 then
        local trunc = detectitem_label
        while gfx.measurestr(trunc .. "...") > detectitem_btn_w - 8 and #trunc > 1 do
            trunc = trunc:sub(1, #trunc - 1)
        end
        detectitem_label = trunc .. "..."
        detectitem_lbl_w = gfx.measurestr(detectitem_label)
    end
    gfx.x = detectitem_btn_x + (detectitem_btn_w - detectitem_lbl_w) / 2
    gfx.y = detectitem_text_y
    gfx.drawstr(detectitem_label)
    draw_menu_flag_cb(menu_cb_x, detectitem_row_y, settings_menu_flags.detectitem)
    if detectitem_btn_hovered and tips_enabled then
        pending_tooltip = "Which audio item to use for tempo detection.\n'Selected Item' uses whatever is selected in Arrange.\nOr pick a specific item from the region/cursor."
    end
    end

    -- Draw Detect Tempo button row (full-width big button, drawn at end of Tempo Map section)

    -- Draw Stretch Markers checkbox row
    local stretchmarkers_text_y = stretchmarkers_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = stretchmarkers_text_y
    gfx.drawstr("Stretch Markers")
    -- Checkbox on the right
    local sm_cb_hovered = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                           mouse_y >= stretchmarkers_row_y and mouse_y < stretchmarkers_row_y + checkbox_size)
    if detect_stretch_markers_enabled or sm_cb_hovered then
        gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
    else
        gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
    end
    gfx.rect(cb_x, stretchmarkers_row_y, checkbox_size, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(cb_x, stretchmarkers_row_y, checkbox_size, checkbox_size, 0)
    gfx.rect(cb_x + 1, stretchmarkers_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
    if detect_stretch_markers_enabled then
        gfx.set(table.unpack(gui.colors.CHECKMARK))
        local check_str = "✓"
        local cw = gfx.measurestr(check_str)
        gfx.x = cb_x + (checkbox_size - cw) / 2
        gfx.y = stretchmarkers_row_y + (checkbox_size - gfx.texth) / 2
        gfx.drawstr(check_str)
    end
    -- Hover tooltip for entire Stretch Markers row
    local sm_row_hovered = (mouse_x >= horizontal_margin and mouse_x < cb_x + checkbox_size and
                            mouse_y >= stretchmarkers_row_y and mouse_y < stretchmarkers_row_y + checkbox_size)
    if sm_row_hovered and tips_enabled and not pending_tooltip then
        pending_tooltip = "Insert stretch markers on transients.\nFirst stretch marker defines bar 1 position.\nPlace one before detecting to set the downbeat.\n\nUse 'Remove Stretch Markers' below to clear them\nwithin a razor edit, time selection, or selected items."
    end

    -- Draw 4 stretch marker slider rows (Threshold, Sensitivity, Retrig, Offset)
    local sm_slider_defs = {
        {row_y = threshold_row_y, label = "Threshold", val = sm_threshold_dB, vmin = 0, vmax = 60, unit = " dB", drag_id = "threshold",
         tip = "Amplitude threshold for transient detection.\nHigher = detect quieter transients.\n0 = only the loudest, 60 = detect everything.\nDrag or scroll to adjust."},
        {row_y = sensitivity_row_y, label = "Sensitivity", val = sm_sensitivity_dB, vmin = 1, vmax = 20, unit = " dB", drag_id = "sensitivity",
         tip = "Envelope ratio sensitivity.\nLower = more transients detected.\nHigher = only sharp attacks.\nDrag or scroll to adjust."},
        {row_y = retrig_row_y, label = "Retrig", val = sm_retrig_ms, vmin = 10, vmax = 500, unit = " ms", drag_id = "retrig",
         tip = "Minimum time between detected transients.\nLower = allow closely spaced hits.\nHigher = skip rapid repeats.\nDrag or scroll to adjust."},
        {row_y = offset_row_y, label = "Offset", val = sm_offset_ms, vmin = -100, vmax = 100, unit = " ms", drag_id = "offset",
         tip = "Shift all placed stretch markers left/right.\nNegative = earlier, Positive = later.\nDoes not re-detect transients.\nDrag or scroll to adjust."},
    }
    for _, sd in ipairs(sm_slider_defs) do
        local sl_text_y = sd.row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = sl_text_y
        gfx.drawstr(sd.label)
        local sl_x = sett_simple_btn_x
        local sl_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
        local sl_h = checkbox_size
        local sl_track_h = 6
        local sl_track_y = sd.row_y + (sl_h - sl_track_h) / 2
        -- Track background
        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 0)
        -- Fraction (handle bidirectional offset: center = 0)
        local sl_frac
        if sd.vmin < 0 then
            sl_frac = (sd.val - sd.vmin) / (sd.vmax - sd.vmin)
        else
            sl_frac = (sd.vmax - sd.vmin) > 0 and ((sd.val - sd.vmin) / (sd.vmax - sd.vmin)) or 0
        end
        sl_frac = math.max(0, math.min(1, sl_frac))
        -- Teal fill (for offset: fill from center; for others: fill from left)
        if sd.vmin < 0 then
            local center_x = sl_x + math.floor(0.5 * sl_w)
            local thumb_pos = sl_x + math.floor(sl_frac * sl_w)
            local fill_left = math.min(center_x, thumb_pos)
            local fill_right = math.max(center_x, thumb_pos)
            if fill_right - fill_left > 0 then
                gfx.set(0.17, 0.45, 0.39, 1)
                gfx.rect(fill_left, sl_track_y, fill_right - fill_left, sl_track_h, 1)
            end
        else
            local sl_fill_w = math.floor(sl_frac * sl_w)
            if sl_fill_w > 0 then
                gfx.set(0.17, 0.45, 0.39, 1)
                gfx.rect(sl_x, sl_track_y, sl_fill_w, sl_track_h, 1)
            end
        end
        -- Thumb
        local sl_thumb_w = 10
        local sl_thumb_x = sl_x + math.floor(sl_frac * sl_w) - sl_thumb_w / 2
        if sl_thumb_x < sl_x then sl_thumb_x = sl_x end
        if sl_thumb_x + sl_thumb_w > sl_x + sl_w then sl_thumb_x = sl_x + sl_w - sl_thumb_w end
        local sl_hovered = (mouse_x >= sl_x and mouse_x < sl_x + sl_w and
                            mouse_y >= sd.row_y and mouse_y < sd.row_y + sl_h)
        if sl_hovered or sm_slider_dragging == sd.drag_id then
            gfx.set(0.65, 0.65, 0.65, 1)
        else
            gfx.set(0.4, 0.4, 0.4, 1)
        end
        gfx.rect(sl_thumb_x, sd.row_y, sl_thumb_w, sl_h, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(sl_thumb_x, sd.row_y, sl_thumb_w, sl_h, 0)
        -- Value label
        gfx.set(table.unpack(gui.colors.TEXT))
        local sl_val_str = tostring(sd.val) .. sd.unit
        local sl_val_w = gfx.measurestr(sl_val_str)
        gfx.x = sl_x + (sl_w - sl_val_w) / 2
        gfx.y = sl_text_y
        gfx.drawstr(sl_val_str)
        -- Tooltip
        if sl_hovered and tips_enabled and not pending_tooltip then
            pending_tooltip = sd.tip
        end
    end

    -- Draw Use Existing Markers checkbox row
    local uem_text_y = useexisting_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = uem_text_y
    gfx.drawstr("Use Existing Markers")
    local uem_cb_hovered = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                             mouse_y >= useexisting_row_y and mouse_y < useexisting_row_y + checkbox_size)
    if detect_tempo_use_existing_markers or uem_cb_hovered then
        gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
    else
        gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
    end
    gfx.rect(cb_x, useexisting_row_y, checkbox_size, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(cb_x, useexisting_row_y, checkbox_size, checkbox_size, 0)
    gfx.rect(cb_x + 1, useexisting_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
    if detect_tempo_use_existing_markers then
        gfx.set(table.unpack(gui.colors.CHECKMARK))
        local check_str = "✓"
        local cw = gfx.measurestr(check_str)
        gfx.x = cb_x + (checkbox_size - cw) / 2
        gfx.y = useexisting_row_y + (checkbox_size - gfx.texth) / 2
        gfx.drawstr(check_str)
    end
    if uem_cb_hovered and tips_enabled and not pending_tooltip then
        pending_tooltip = "When enabled, Detect Tempo uses the stretch markers\nalready on the item instead of detecting transients.\nPlace markers manually or with the slider above,\nthen detect tempo from them."
    end

    end -- end scope: detectmethod + detecttempo + 4 sliders + useexisting drawing

    -- Draw Detect Tempo Item row (scrollable button, no checkbox)
    local alignstem_text_y = alignstem_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = alignstem_text_y
    gfx.drawstr("Detect Tempo Item")
    -- Scrollable button
    local alignstem_btn_x = sett_simple_btn_x
    local alignstem_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local alignstem_label
    if align_stem_index == 0 then
        alignstem_label = "Auto"
    elseif align_stem_items[align_stem_index] then
        alignstem_label = align_stem_items[align_stem_index].name
    else
        alignstem_label = "Auto"
    end
    local alignstem_btn_hovered = (mouse_x >= alignstem_btn_x and mouse_x < alignstem_btn_x + alignstem_btn_w and
                                   mouse_y >= alignstem_row_y and mouse_y < alignstem_row_y + checkbox_size)
    if alignstem_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(alignstem_btn_x, alignstem_row_y, alignstem_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(alignstem_btn_x, alignstem_row_y, alignstem_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local alignstem_lbl_full = alignstem_label
    local alignstem_lbl_w = gfx.measurestr(alignstem_lbl_full)
    if alignstem_lbl_w > alignstem_btn_w - 4 then
        while #alignstem_lbl_full > 1 and gfx.measurestr(alignstem_lbl_full .. "..") > alignstem_btn_w - 4 do
            alignstem_lbl_full = alignstem_lbl_full:sub(1, -2)
        end
        alignstem_lbl_full = alignstem_lbl_full .. ".."
        alignstem_lbl_w = gfx.measurestr(alignstem_lbl_full)
    end
    gfx.x = alignstem_btn_x + (alignstem_btn_w - alignstem_lbl_w) / 2
    gfx.y = alignstem_text_y
    gfx.drawstr(alignstem_lbl_full)
    draw_menu_flag_cb(menu_cb_x, alignstem_row_y, settings_menu_flags.alignstem)
    if alignstem_btn_hovered and tips_enabled then
        pending_tooltip = "Which audio item to use for tempo detection\nwhen importing MusicXML.\n'Auto' picks the first suitable item."
    end

    -- Draw Import Position row (scrollable button, no checkbox)
    do
    local importpos_text_y = importpos_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = importpos_text_y
    gfx.drawstr("Import Position")
    local importpos_btn_x = sett_simple_btn_x
    local importpos_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local importpos_label = import_position_options[import_position_index] or "Start of Project"
    local importpos_btn_hovered = (mouse_x >= importpos_btn_x and mouse_x < importpos_btn_x + importpos_btn_w and
                                   mouse_y >= importpos_row_y and mouse_y < importpos_row_y + checkbox_size)
    if importpos_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(importpos_btn_x, importpos_row_y, importpos_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(importpos_btn_x, importpos_row_y, importpos_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local importpos_lbl_full = importpos_label
    local importpos_lbl_w = gfx.measurestr(importpos_lbl_full)
    if importpos_lbl_w > importpos_btn_w - 4 then
        while #importpos_lbl_full > 1 and gfx.measurestr(importpos_lbl_full .. "..") > importpos_btn_w - 4 do
            importpos_lbl_full = importpos_lbl_full:sub(1, -2)
        end
        importpos_lbl_full = importpos_lbl_full .. ".."
        importpos_lbl_w = gfx.measurestr(importpos_lbl_full)
    end
    gfx.x = importpos_btn_x + (importpos_btn_w - importpos_lbl_w) / 2
    gfx.y = importpos_text_y
    gfx.drawstr(importpos_lbl_full)
    draw_menu_flag_cb(menu_cb_x, importpos_row_y, settings_menu_flags.importpos)
    if importpos_btn_hovered and tips_enabled then
        pending_tooltip = "Where to place imported items in the project.\n'Region Onset': auto-detect onset of audio in closest region.\n'START Marker': use the position of a project marker named START."
    end
    end

    -- Draw Onset Item row (scrollable button, no checkbox)
    local onsetitem_text_y = onsetitem_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = onsetitem_text_y
    gfx.drawstr("Onset Item")
    -- Scrollable button
    local onsetitem_btn_x = sett_simple_btn_x
    local onsetitem_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    local onsetitem_label
    if onset_item_index == 0 then
        onsetitem_label = "Auto"
    elseif onset_item_items[onset_item_index] then
        onsetitem_label = onset_item_items[onset_item_index].name
    else
        onsetitem_label = "Auto"
    end
    local onsetitem_btn_hovered = (mouse_x >= onsetitem_btn_x and mouse_x < onsetitem_btn_x + onsetitem_btn_w and
                                   mouse_y >= onsetitem_row_y and mouse_y < onsetitem_row_y + checkbox_size)
    if onsetitem_btn_hovered then
        gfx.set(0.17, 0.45, 0.39, 1)
    else
        gfx.set(0.2, 0.2, 0.2, 1)
    end
    gfx.rect(onsetitem_btn_x, onsetitem_row_y, onsetitem_btn_w, checkbox_size, 1)
    gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
    gfx.rect(onsetitem_btn_x, onsetitem_row_y, onsetitem_btn_w, checkbox_size, 0)
    gfx.set(table.unpack(gui.colors.TEXT))
    local onsetitem_lbl_full = onsetitem_label
    local onsetitem_lbl_w = gfx.measurestr(onsetitem_lbl_full)
    if onsetitem_lbl_w > onsetitem_btn_w - 4 then
        while #onsetitem_lbl_full > 1 and gfx.measurestr(onsetitem_lbl_full .. "..") > onsetitem_btn_w - 4 do
            onsetitem_lbl_full = onsetitem_lbl_full:sub(1, -2)
        end
        onsetitem_lbl_full = onsetitem_lbl_full .. ".."
        onsetitem_lbl_w = gfx.measurestr(onsetitem_lbl_full)
    end
    gfx.x = onsetitem_btn_x + (onsetitem_btn_w - onsetitem_lbl_w) / 2
    gfx.y = onsetitem_text_y
    gfx.drawstr(onsetitem_lbl_full)
    draw_menu_flag_cb(menu_cb_x, onsetitem_row_y, settings_menu_flags.onsetitem)
    if onsetitem_btn_hovered and tips_enabled then
        pending_tooltip = "Which audio item to use for onset detection\n(finding where the song/section starts).\n'Auto' picks the first suitable item."
    end
    end -- end scope: importpos + autoloadrgn + timebase + alignstem + onsetitem drawing

    do -- scope: imdup (import section duplicate rows) drawing
    local r_btn_x = sett_simple_btn_x
    local r_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
    -- Tempo Map Freq (import duplicate)
    do
    local r = imdup.tempofreq
    if is_row_visible(r) then
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = r + (checkbox_size - gfx.texth) / 2
        gfx.drawstr("Tempo Map Freq")
        local lbl = tempo_map_freq_options[tempo_map_freq_index] or "Off"
        local hov = mouse_x >= r_btn_x and mouse_x < r_btn_x + r_btn_w and
                    mouse_y >= r and mouse_y < r + checkbox_size
        if hov then gfx.set(0.17, 0.45, 0.39, 1) else gfx.set(0.2, 0.2, 0.2, 1) end
        gfx.rect(r_btn_x, r, r_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(r_btn_x, r, r_btn_w, checkbox_size, 0)
        gfx.set(table.unpack(gui.colors.TEXT))
        local lbl_w = gfx.measurestr(lbl)
        gfx.x = r_btn_x + (r_btn_w - lbl_w) / 2; gfx.y = r + (checkbox_size - gfx.texth) / 2
        gfx.drawstr(lbl)
        draw_menu_flag_cb(menu_cb_x, r, settings_menu_flags.tempofreq)
    end
    end
    -- Time Signature (import duplicate)
    do
    local r = imdup.tempotimesig
    if is_row_visible(r) then
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = r + (checkbox_size - gfx.texth) / 2
        gfx.drawstr("Time Signature")
        local lbl = tempo_timesig_options[tempo_timesig_index] or "4/4"
        local hov = mouse_x >= r_btn_x and mouse_x < r_btn_x + r_btn_w and
                    mouse_y >= r and mouse_y < r + checkbox_size
        if hov then gfx.set(0.17, 0.45, 0.39, 1) else gfx.set(0.2, 0.2, 0.2, 1) end
        gfx.rect(r_btn_x, r, r_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(r_btn_x, r, r_btn_w, checkbox_size, 0)
        gfx.set(table.unpack(gui.colors.TEXT))
        local lbl_w = gfx.measurestr(lbl)
        gfx.x = r_btn_x + (r_btn_w - lbl_w) / 2; gfx.y = r + (checkbox_size - gfx.texth) / 2
        gfx.drawstr(lbl)
        draw_menu_flag_cb(menu_cb_x, r, settings_menu_flags.tempotimesig)
    end
    end
    -- Detect Method (import duplicate)
    do
    local r = imdup.detectmethod
    if is_row_visible(r) then
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = r + (checkbox_size - gfx.texth) / 2
        gfx.drawstr("Detect Method")
        local lbl = tempo_detect_method_options[tempo_detect_method_index] or "Lua"
        local hov = mouse_x >= r_btn_x and mouse_x < r_btn_x + r_btn_w and
                    mouse_y >= r and mouse_y < r + checkbox_size
        if hov then gfx.set(0.17, 0.45, 0.39, 1) else gfx.set(0.2, 0.2, 0.2, 1) end
        gfx.rect(r_btn_x, r, r_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(r_btn_x, r, r_btn_w, checkbox_size, 0)
        gfx.set(table.unpack(gui.colors.TEXT))
        local lbl_w = gfx.measurestr(lbl)
        gfx.x = r_btn_x + (r_btn_w - lbl_w) / 2; gfx.y = r + (checkbox_size - gfx.texth) / 2
        gfx.drawstr(lbl)
        draw_menu_flag_cb(menu_cb_x, r, settings_menu_flags.detectmethod)
    end
    end
    end -- end scope: imdup drawing

    do -- scope: remap + nudge buttons drawing
    -- Draw Remap button row
    if is_row_visible(remap_row_y) then
        local remap_text_y = remap_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = remap_text_y
        gfx.drawstr("Remap to Tempo")
        local remap_sett_btn_x = sett_simple_btn_x
        local remap_sett_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
        local remap_sett_label = "Remap"
        if os.clock() < remap_confirmed_until then remap_sett_label = "Remapped!" end
        remap_btn_hovered = (mouse_x >= remap_sett_btn_x and mouse_x < remap_sett_btn_x + remap_sett_btn_w and
                             mouse_y >= remap_row_y and mouse_y < remap_row_y + checkbox_size)
        if remap_btn_hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
        elseif os.clock() < remap_confirmed_until then
            gfx.set(0.15, 0.35, 0.2, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(remap_sett_btn_x, remap_row_y, remap_sett_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(remap_sett_btn_x, remap_row_y, remap_sett_btn_w, checkbox_size, 0)
        if os.clock() < remap_confirmed_until then
            gfx.set(0.3, 0.85, 0.5, 1)
        else
            gfx.set(table.unpack(gui.colors.TEXT))
        end
        local remap_lbl_w = gfx.measurestr(remap_sett_label)
        gfx.x = remap_sett_btn_x + (remap_sett_btn_w - remap_lbl_w) / 2
        gfx.y = remap_text_y
        gfx.drawstr(remap_sett_label)
        if remap_btn_hovered and tips_enabled then
            pending_tooltip = "Re-position MIDI notes on selected items\nto match the current project tempo map.\nOnly works on items imported with this script."
        end
    end

    -- Draw Delete Tempo Markers button row
    if is_row_visible(del_tempo_row_y) then
        local del_tempo_text_y = del_tempo_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = del_tempo_text_y
        gfx.drawstr("Delete Tempo Markers")
        local del_tempo_btn_x = sett_simple_btn_x
        local del_tempo_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
        local del_tempo_label = "Delete"
        if os.clock() < del_tempo_confirmed_until then del_tempo_label = "Deleted!" end
        del_tempo_btn_hovered = (mouse_x >= del_tempo_btn_x and mouse_x < del_tempo_btn_x + del_tempo_btn_w and
                                 mouse_y >= del_tempo_row_y and mouse_y < del_tempo_row_y + checkbox_size)
        if del_tempo_btn_hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
        elseif os.clock() < del_tempo_confirmed_until then
            gfx.set(0.15, 0.35, 0.2, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(del_tempo_btn_x, del_tempo_row_y, del_tempo_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(del_tempo_btn_x, del_tempo_row_y, del_tempo_btn_w, checkbox_size, 0)
        if os.clock() < del_tempo_confirmed_until then
            gfx.set(0.3, 0.85, 0.5, 1)
        else
            gfx.set(table.unpack(gui.colors.TEXT))
        end
        local del_tempo_lbl_w = gfx.measurestr(del_tempo_label)
        gfx.x = del_tempo_btn_x + (del_tempo_btn_w - del_tempo_lbl_w) / 2
        gfx.y = del_tempo_text_y
        gfx.drawstr(del_tempo_label)
        if del_tempo_btn_hovered and tips_enabled then
            pending_tooltip = "Delete tempo markers within the active range.\nRange priority: razor edit → time selection\n→ bounding box of selected items."
        end
    end

    -- Draw Nudge Tempo slider row (full-width, ±500 ms; snaps to SM when Snap Tempo to SM is ON)
    if is_row_visible(tempo_nudge_row_y) then
        local sl_x = sett_simple_btn_x
        local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
        local sl_text_y = tempo_nudge_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = sl_text_y
        gfx.drawstr("Nudge Tempo")
        -- Teal tint on track when snap is enabled
        if tempo_snap_to_sm_enabled then
            gfx.set(0.12, 0.28, 0.24, 1)
        else
            gfx.set(0.15, 0.15, 0.15, 1)
        end
        local sl_track_h = 6
        local sl_track_y = tempo_nudge_row_y + (checkbox_size - sl_track_h) / 2
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 0)
        local tn_frac = (tempo_nudge_value + 500) / 1000
        tn_frac = math.max(0, math.min(1, tn_frac))
        local center_tx = sl_x + math.floor(0.5 * sl_w)
        local thumb_tx = sl_x + math.floor(tn_frac * sl_w)
        local fill_tl = math.min(center_tx, thumb_tx)
        local fill_tr = math.max(center_tx, thumb_tx)
        if fill_tr - fill_tl > 0 then
            gfx.set(0.17, 0.45, 0.39, 1)
            gfx.rect(fill_tl, sl_track_y, fill_tr - fill_tl, sl_track_h, 1)
        end
        local thumb_tw = 10
        local thumb_tpx = sl_x + math.floor(tn_frac * sl_w) - thumb_tw / 2
        thumb_tpx = math.max(sl_x, math.min(sl_x + sl_w - thumb_tw, thumb_tpx))
        local tsl_hov = (mouse_x >= sl_x and mouse_x < sl_x + sl_w and mouse_y >= tempo_nudge_row_y and mouse_y < tempo_nudge_row_y + checkbox_size)
        local tthumb_bright = (tsl_hov or tempo_nudge_slider_dragging) and 0.65 or 0.4
        gfx.set(tthumb_bright, tthumb_bright, tthumb_bright, 1)
        gfx.rect(thumb_tpx, tempo_nudge_row_y, thumb_tw, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(thumb_tpx, tempo_nudge_row_y, thumb_tw, checkbox_size, 0)
        gfx.set(table.unpack(gui.colors.TEXT))
        local tnu_str = tostring(tempo_nudge_value) .. " ms"
        if tempo_snap_to_sm_enabled and tempo_nudge_slider_dragging then
            tnu_str = tostring(tempo_nudge_value) .. " ms →SM"
        end
        local tnu_w = gfx.measurestr(tnu_str)
        gfx.x = sl_x + (sl_w - tnu_w) / 2; gfx.y = sl_text_y
        gfx.drawstr(tnu_str)
        if tsl_hov and tips_enabled and not pending_tooltip then
            local tip = "Drag to move the tempo marker nearest the\nedit cursor by ±500 ms."
            if tempo_snap_to_sm_enabled then
                tip = tip .. "\nSnap mode ON: snaps to nearest stretch marker."
            end
            pending_tooltip = tip
        end
    end

    -- Draw Snap Tempo to SM checkbox row
    if is_row_visible(tempo_snap_row_y) then
        local snap_text_y = tempo_snap_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = snap_text_y
        gfx.drawstr("Snap Tempo to SM")
        -- Value checkbox
        local snap_tm_cb_hov = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                                mouse_y >= tempo_snap_row_y and mouse_y < tempo_snap_row_y + checkbox_size)
        if tempo_snap_to_sm_enabled or snap_tm_cb_hov then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(cb_x, tempo_snap_row_y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(cb_x, tempo_snap_row_y, checkbox_size, checkbox_size, 0)
        gfx.rect(cb_x + 1, tempo_snap_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if tempo_snap_to_sm_enabled then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            local cw = gfx.measurestr("✓")
            gfx.x = cb_x + (checkbox_size - cw) / 2
            gfx.y = snap_text_y
            gfx.drawstr("✓")
        end
        draw_menu_flag_cb(menu_cb_x, tempo_snap_row_y, settings_menu_flags.temposnap)
        if snap_tm_cb_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "When ON, the Nudge Tempo slider snaps\nthe tempo marker incrementally to stretch markers.\nDrag further to step to the next SM.\nM: show this toggle in the main view."
        end
    end

    -- Draw Detect Tempo big button (full-width, file_info_height, last in Tempo Map)
    if detecttempo_row_y > -9000 and detecttempo_row_y + file_info_height > content_top and detecttempo_row_y < content_bottom then
        local dtt_hov = (mouse_y >= detecttempo_row_y and mouse_y < detecttempo_row_y + file_info_height)
        if dtt_hov then gfx.set(0.17, 0.45, 0.39, 1) else gfx.set(0.2, 0.2, 0.2, 1) end
        gfx.rect(0, detecttempo_row_y, gfx.w, file_info_height, 1)
        gfx.set(table.unpack(gui.colors.BORDER))
        gfx.rect(0, detecttempo_row_y, gfx.w, file_info_height, 0)
        gfx.set(table.unpack(gui.colors.TEXT))
        local dtt_lbl_w = gfx.measurestr("Detect Tempo")
        gfx.x = (gfx.w - dtt_lbl_w) / 2
        gfx.y = detecttempo_row_y + (file_info_height - gfx.texth) / 2
        gfx.drawstr("Detect Tempo")
        if dtt_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Detect tempo from audio transients\nand write a tempo map to the project.\nUses grid-fit scoring for accuracy."
        end
    end

    -- Draw Remove Stretch Markers button row
    if is_row_visible(del_sm_row_y) then
        local del_sm_text_y = del_sm_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = del_sm_text_y
        gfx.drawstr("Remove Stretch Markers")
        local del_sm_btn_x = sett_simple_btn_x
        local del_sm_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
        local del_sm_label = "Remove"
        if os.clock() < del_sm_confirmed_until then del_sm_label = "Removed!" end
        del_sm_btn_hovered = (mouse_x >= del_sm_btn_x and mouse_x < del_sm_btn_x + del_sm_btn_w and
                              mouse_y >= del_sm_row_y and mouse_y < del_sm_row_y + checkbox_size)
        if del_sm_btn_hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
        elseif os.clock() < del_sm_confirmed_until then
            gfx.set(0.15, 0.35, 0.2, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(del_sm_btn_x, del_sm_row_y, del_sm_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(del_sm_btn_x, del_sm_row_y, del_sm_btn_w, checkbox_size, 0)
        if os.clock() < del_sm_confirmed_until then
            gfx.set(0.3, 0.85, 0.5, 1)
        else
            gfx.set(table.unpack(gui.colors.TEXT))
        end
        local del_sm_lbl_w = gfx.measurestr(del_sm_label)
        gfx.x = del_sm_btn_x + (del_sm_btn_w - del_sm_lbl_w) / 2
        gfx.y = del_sm_text_y
        gfx.drawstr(del_sm_label)
        if del_sm_btn_hovered and tips_enabled then
            pending_tooltip = "Remove stretch markers from audio items\nwithin the active range.\nRange: razor edit → time selection → selected items.\nNo item selection needed when a range is set."
        end
    end

    -- Draw Nudge SM slider row (full-width, ±500 ms offset slider, no rate change)
    if is_row_visible(sm_nudge_row_y) then
        local sl_x = sett_simple_btn_x
        local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
        local sl_text_y = sm_nudge_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = sl_text_y
        gfx.drawstr("Nudge SM")
        -- Slider track
        local sl_track_h = 6
        local sl_track_y = sm_nudge_row_y + (checkbox_size - sl_track_h) / 2
        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 0)
        -- Fill from center (bidirectional)
        local sm_nu_frac = (sm_nudge_value + 500) / 1000
        sm_nu_frac = math.max(0, math.min(1, sm_nu_frac))
        local center_x = sl_x + math.floor(0.5 * sl_w)
        local thumb_x = sl_x + math.floor(sm_nu_frac * sl_w)
        local fill_l = math.min(center_x, thumb_x)
        local fill_r = math.max(center_x, thumb_x)
        if fill_r - fill_l > 0 then
            gfx.set(0.17, 0.45, 0.39, 1)
            gfx.rect(fill_l, sl_track_y, fill_r - fill_l, sl_track_h, 1)
        end
        -- Thumb
        local thumb_w = 10
        local thumb_px = sl_x + math.floor(sm_nu_frac * sl_w) - thumb_w / 2
        thumb_px = math.max(sl_x, math.min(sl_x + sl_w - thumb_w, thumb_px))
        local sl_hov = (mouse_x >= sl_x and mouse_x < sl_x + sl_w and mouse_y >= sm_nudge_row_y and mouse_y < sm_nudge_row_y + checkbox_size)
        local sm_thumb_bright = (sl_hov or sm_nudge_slider_dragging) and 0.65 or 0.4
        gfx.set(sm_thumb_bright, sm_thumb_bright, sm_thumb_bright, 1)
        gfx.rect(thumb_px, sm_nudge_row_y, thumb_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(thumb_px, sm_nudge_row_y, thumb_w, checkbox_size, 0)
        -- Value label
        gfx.set(table.unpack(gui.colors.TEXT))
        local nu_str = tostring(sm_nudge_value) .. " ms"
        local nu_w = gfx.measurestr(nu_str)
        gfx.x = sl_x + (sl_w - nu_w) / 2; gfx.y = sl_text_y
        gfx.drawstr(nu_str)
        if sl_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Drag to slide the stretch marker nearest the edit cursor\nby ±500 ms. Both timeline and source position move\ntogether — no audio rate change."
        end
    end

    -- Draw Snap SM to Grid checkbox row
    if is_row_visible(sm_snap_row_y) then
        local snap_text_y = sm_snap_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = snap_text_y
        gfx.drawstr("Snap SM to Grid")
        -- Value checkbox
        local snap_sm_cb_hov = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                                mouse_y >= sm_snap_row_y and mouse_y < sm_snap_row_y + checkbox_size)
        if sm_snap_to_grid_enabled or snap_sm_cb_hov then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(cb_x, sm_snap_row_y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(cb_x, sm_snap_row_y, checkbox_size, checkbox_size, 0)
        gfx.rect(cb_x + 1, sm_snap_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if sm_snap_to_grid_enabled then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            local cw = gfx.measurestr("✓")
            gfx.x = cb_x + (checkbox_size - cw) / 2
            gfx.y = snap_text_y
            gfx.drawstr("✓")
        end
        draw_menu_flag_cb(menu_cb_x, sm_snap_row_y, settings_menu_flags.smsnap)
        if snap_sm_cb_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "When ON, 'Snap Grid' button snaps the nearest\nstretch marker to the project grid.\nM: show this toggle in the main view."
        end
    end

    -- Draw Detect Transients big button (full-width, file_info_height, last in Transients)
    if detect_transients_row_y > -9000 and detect_transients_row_y + file_info_height > content_top and detect_transients_row_y < content_bottom then
        local dt_hov = (mouse_y >= detect_transients_row_y and mouse_y < detect_transients_row_y + file_info_height)
        local dt_confirmed = (os.clock() < detect_transients_confirmed_until)
        if dt_confirmed then
            gfx.set(0.15, 0.35, 0.2, 1)
        elseif dt_hov then
            gfx.set(0.17, 0.45, 0.39, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(0, detect_transients_row_y, gfx.w, file_info_height, 1)
        gfx.set(table.unpack(gui.colors.BORDER))
        gfx.rect(0, detect_transients_row_y, gfx.w, file_info_height, 0)
        local dt_lbl = dt_confirmed and "Detected!" or "Detect Transients"
        if dt_confirmed then gfx.set(0.3, 0.85, 0.5, 1) else gfx.set(table.unpack(gui.colors.TEXT)) end
        local dt_lbl_w = gfx.measurestr(dt_lbl)
        gfx.x = (gfx.w - dt_lbl_w) / 2
        gfx.y = detect_transients_row_y + (file_info_height - gfx.texth) / 2
        gfx.drawstr(dt_lbl)
        if dt_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Detect audio transients and write stretch markers\nusing the current slider settings.\nRange: time selection or razor edit on item's track."
        end
    end

    -- Draw MIDI SM Mode checkbox row (MIDI TOOLS section)
    if is_row_visible(midi_sm_row_y) then
        local msm_text_y = midi_sm_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = msm_text_y
        gfx.drawstr("MIDI SM Mode")
        local msm_cb_hov = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                            mouse_y >= midi_sm_row_y and mouse_y < midi_sm_row_y + checkbox_size)
        if midi_sm_enabled or msm_cb_hov then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(cb_x, midi_sm_row_y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(cb_x, midi_sm_row_y, checkbox_size, checkbox_size, 0)
        gfx.rect(cb_x + 1, midi_sm_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if midi_sm_enabled then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            local cw = gfx.measurestr("✓")
            gfx.x = cb_x + (checkbox_size - cw) / 2
            gfx.y = msm_text_y
            gfx.drawstr("✓")
        end
        draw_menu_flag_cb(menu_cb_x, midi_sm_row_y, settings_menu_flags.midism)
        if msm_cb_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "MIDI Stretch Markers mode.\nManually add take markers to a MIDI item in REAPER.\nWhen ON, moving a take marker proportionally\nstretches or shrinks the MIDI notes in that region.\nMarker names show the segment rate (e.g. 1.00x).\nM: show this toggle in the main view."
        end
    end

    -- Draw Insert TM at cursor button row (MIDI TOOLS)
    if is_row_visible(midi_tm_insert_row_y) then
        local sl_x = sett_simple_btn_x
        local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
        local ins_hov = (mouse_x >= sl_x and mouse_x < sl_x + sl_w and
                         mouse_y >= midi_tm_insert_row_y and mouse_y < midi_tm_insert_row_y + checkbox_size)
        -- Label on left
        local ins_text_y = midi_tm_insert_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = ins_text_y
        gfx.drawstr("Insert TM at cursor")
        -- Button
        if ins_hov then gfx.set(table.unpack(gui.colors.BTN_HOVER))
        else           gfx.set(table.unpack(gui.colors.BTN)) end
        gfx.rect(sl_x, midi_tm_insert_row_y, sl_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.BORDER))
        gfx.rect(sl_x, midi_tm_insert_row_y, sl_w, checkbox_size, 0)
        gfx.set(table.unpack(gui.colors.TEXT))
        local btn_lbl = "Insert 1.00x"
        local btn_lbl_w = gfx.measurestr(btn_lbl)
        gfx.x = sl_x + (sl_w - btn_lbl_w) / 2; gfx.y = ins_text_y
        gfx.drawstr(btn_lbl)
        if ins_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Inserts a '1.00x' take marker at the edit cursor\non the currently selected MIDI item.\nOnly markers with a rate label (e.g. 1.00x) are\nrecognized by the Move and Stretch sliders."
        end
    end

    -- Draw MIDI TM Move slider row (MIDI TOOLS)
    if is_row_visible(midi_tm_move_row_y) then
        local sl_x = sett_simple_btn_x
        local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
        local sl_track_h = 4
        local sl_text_y = midi_tm_move_row_y + (checkbox_size - gfx.texth) / 2
        local sl_track_y = midi_tm_move_row_y + (checkbox_size - sl_track_h) / 2
        -- Label
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = sl_text_y
        gfx.drawstr("Shift TM")
        -- Track
        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 0)
        -- Fill from centre
        local mv_frac = (midi_tm_move_value + 500) / 1000
        mv_frac = math.max(0, math.min(1, mv_frac))
        local center_x = sl_x + math.floor(0.5 * sl_w)
        local thumb_x  = sl_x + math.floor(mv_frac * sl_w)
        local fill_l = math.min(center_x, thumb_x)
        local fill_r = math.max(center_x, thumb_x)
        if fill_r - fill_l > 0 then
            gfx.set(0.17, 0.45, 0.39, 1)
            gfx.rect(fill_l, sl_track_y, fill_r - fill_l, sl_track_h, 1)
        end
        -- Thumb
        local thumb_w = 10
        local thumb_px = sl_x + math.floor(mv_frac * sl_w) - thumb_w / 2
        thumb_px = math.max(sl_x, math.min(sl_x + sl_w - thumb_w, thumb_px))
        local mv_sl_hov = (mouse_x >= sl_x and mouse_x < sl_x + sl_w and
                           mouse_y >= midi_tm_move_row_y and mouse_y < midi_tm_move_row_y + checkbox_size)
        local mv_bright = (mv_sl_hov or midi_tm_move_dragging) and 0.65 or 0.4
        gfx.set(mv_bright, mv_bright, mv_bright, 1)
        gfx.rect(thumb_px, midi_tm_move_row_y, thumb_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(thumb_px, midi_tm_move_row_y, thumb_w, checkbox_size, 0)
        -- Value label
        gfx.set(table.unpack(gui.colors.TEXT))
        local mv_str = midi_tm_move_value == 0 and "0 qn" or string.format("%+.2f qn", midi_tm_move_value / 250)
        local mv_str_w = gfx.measurestr(mv_str)
        gfx.x = sl_x + (sl_w - mv_str_w) / 2; gfx.y = sl_text_y
        gfx.drawstr(mv_str)
        if mv_sl_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Drag to move the rated take marker (e.g. 1.00x)\nnearest the edit cursor by ±500 ms.\nNote positions are NOT changed."
        end
    end

    -- Draw MIDI TM Stretch slider row (MIDI TOOLS)
    if is_row_visible(midi_tm_stretch_row_y) then
        local sl_x = sett_simple_btn_x
        local sl_w = math.max(20, cb_x - COL_SPACING - sl_x)
        local sl_track_h = 4
        local sl_text_y = midi_tm_stretch_row_y + (checkbox_size - gfx.texth) / 2
        local sl_track_y = midi_tm_stretch_row_y + (checkbox_size - sl_track_h) / 2
        -- Label
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = sl_text_y
        gfx.drawstr("Warp TM")
        -- Track
        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(sl_x, sl_track_y, sl_w, sl_track_h, 0)
        -- Fill from centre
        local st_frac = (midi_tm_stretch_value + 500) / 1000
        st_frac = math.max(0, math.min(1, st_frac))
        local center_x = sl_x + math.floor(0.5 * sl_w)
        local thumb_x  = sl_x + math.floor(st_frac * sl_w)
        local fill_l = math.min(center_x, thumb_x)
        local fill_r = math.max(center_x, thumb_x)
        if fill_r - fill_l > 0 then
            gfx.set(0.17, 0.45, 0.39, 1)
            gfx.rect(fill_l, sl_track_y, fill_r - fill_l, sl_track_h, 1)
        end
        -- Thumb
        local thumb_w = 10
        local thumb_px = sl_x + math.floor(st_frac * sl_w) - thumb_w / 2
        thumb_px = math.max(sl_x, math.min(sl_x + sl_w - thumb_w, thumb_px))
        local st_sl_hov = (mouse_x >= sl_x and mouse_x < sl_x + sl_w and
                           mouse_y >= midi_tm_stretch_row_y and mouse_y < midi_tm_stretch_row_y + checkbox_size)
        local st_bright = (st_sl_hov or midi_tm_stretch_dragging) and 0.65 or 0.4
        gfx.set(st_bright, st_bright, st_bright, 1)
        gfx.rect(thumb_px, midi_tm_stretch_row_y, thumb_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(thumb_px, midi_tm_stretch_row_y, thumb_w, checkbox_size, 0)
        -- Value label
        gfx.set(table.unpack(gui.colors.TEXT))
        local st_str = midi_tm_stretch_display_str
        local st_str_w = gfx.measurestr(st_str)
        gfx.x = sl_x + (sl_w - st_str_w) / 2; gfx.y = sl_text_y
        gfx.drawstr(st_str)
        if st_sl_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Drag to warp the take marker nearest the edit\ncursor by up to \xC2\xB12 beats AND proportionally\nstretch/shrink the MIDI notes in adjacent regions.\nRecommended: open the inline MIDI editor\n(double-click item) to see note changes\nin real time while dragging."
        end
    end

    -- Draw TM Grid Snap checkbox row (MIDI TOOLS)
    if is_row_visible(midi_tm_snap_row_y) then
        local sn_text_y = midi_tm_snap_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = sn_text_y
        gfx.drawstr("TM Grid Snap")
        local sn_cb_hov = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                           mouse_y >= midi_tm_snap_row_y and mouse_y < midi_tm_snap_row_y + checkbox_size)
        if midi_tm_snap_enabled or sn_cb_hov then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(cb_x, midi_tm_snap_row_y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(cb_x, midi_tm_snap_row_y, checkbox_size, checkbox_size, 0)
        gfx.rect(cb_x + 1, midi_tm_snap_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if midi_tm_snap_enabled then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            local cw = gfx.measurestr("\xE2\x9C\x93")
            gfx.x = cb_x + (checkbox_size - cw) / 2; gfx.y = sn_text_y
            gfx.drawstr("\xE2\x9C\x93")
        end
        if sn_cb_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "When ON, the Shift TM and Warp TM sliders\nsnap the marker position to the project grid.\nOff by default -- turn on if you want\ngrid-locked marker positioning."
        end
    end

    -- Draw Snap TM to Note button row (MIDI TOOLS)
    if is_row_visible(midi_tm_snap_note_row_y) then
        local snn_text_y = midi_tm_snap_note_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = snn_text_y
        gfx.drawstr("Snap TM to Note")
        local snn_sl_x = sett_simple_btn_x
        local snn_sl_w = math.max(20, cb_x - COL_SPACING - snn_sl_x)
        local snn_label = os.clock() < midi_tm_snap_to_note_confirmed_until and "Snapped!" or "Snap"
        local snn_btn_hov = (mouse_x >= snn_sl_x and mouse_x < snn_sl_x + snn_sl_w and
                             mouse_y >= midi_tm_snap_note_row_y and mouse_y < midi_tm_snap_note_row_y + checkbox_size)
        if snn_btn_hov then
            gfx.set(0.17, 0.45, 0.39, 1)
        elseif os.clock() < midi_tm_snap_to_note_confirmed_until then
            gfx.set(0.15, 0.35, 0.2, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(snn_sl_x, midi_tm_snap_note_row_y, snn_sl_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(snn_sl_x, midi_tm_snap_note_row_y, snn_sl_w, checkbox_size, 0)
        if os.clock() < midi_tm_snap_to_note_confirmed_until then
            gfx.set(0.3, 0.85, 0.5, 1)
        else
            gfx.set(table.unpack(gui.colors.TEXT))
        end
        local snn_lbl_w = gfx.measurestr(snn_label)
        gfx.x = snn_sl_x + (snn_sl_w - snn_lbl_w) / 2; gfx.y = snn_text_y
        gfx.drawstr(snn_label)
        if snn_btn_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Snap the nearest rated take marker to the\nclosest note start or end in the MIDI item.\nUseful for aligning markers to note boundaries."
        end
    end

    -- Draw Auto-snap TM to note edge checkbox row (MIDI TOOLS)
    if is_row_visible(midi_tm_autosnap_row_y) then
        local as_text_y = midi_tm_autosnap_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = as_text_y
        gfx.drawstr("Auto-snap TM")
        local as_cb_hov = (mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                           mouse_y >= midi_tm_autosnap_row_y and mouse_y < midi_tm_autosnap_row_y + checkbox_size)
        if midi_tm_autosnap_note_enabled or as_cb_hov then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(cb_x, midi_tm_autosnap_row_y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(cb_x, midi_tm_autosnap_row_y, checkbox_size, checkbox_size, 0)
        gfx.rect(cb_x + 1, midi_tm_autosnap_row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if midi_tm_autosnap_note_enabled then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            local cw = gfx.measurestr("\xE2\x9C\x93")
            gfx.x = cb_x + (checkbox_size - cw) / 2; gfx.y = as_text_y
            gfx.drawstr("\xE2\x9C\x93")
        end
        if as_cb_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "When ON, every Shift TM or Warp TM drag\nautomatically snaps the marker to the\nclosest note start or end while dragging.\nUseful for snapping to notes in real time."
        end
    end

    -- Draw Reset TM button row (MIDI TOOLS)
    if is_row_visible(midi_tm_reset_row_y) then
        local rst_text_y = midi_tm_reset_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin; gfx.y = rst_text_y
        gfx.drawstr("Reset TM")
        local rst_sl_x = sett_simple_btn_x
        local rst_sl_w = math.max(20, cb_x - COL_SPACING - rst_sl_x)
        local rst_label = os.clock() < midi_tm_reset_confirmed_until and "Reset!" or "Reset"
        local rst_btn_hov = (mouse_x >= rst_sl_x and mouse_x < rst_sl_x + rst_sl_w and
                             mouse_y >= midi_tm_reset_row_y and mouse_y < midi_tm_reset_row_y + checkbox_size)
        if rst_btn_hov then
            gfx.set(0.45, 0.18, 0.18, 1)  -- dark red hover
        elseif os.clock() < midi_tm_reset_confirmed_until then
            gfx.set(0.15, 0.35, 0.2, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(rst_sl_x, midi_tm_reset_row_y, rst_sl_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(rst_sl_x, midi_tm_reset_row_y, rst_sl_w, checkbox_size, 0)
        if os.clock() < midi_tm_reset_confirmed_until then
            gfx.set(0.3, 0.85, 0.5, 1)
        else
            gfx.set(table.unpack(gui.colors.TEXT))
        end
        local rst_lbl_w = gfx.measurestr(rst_label)
        gfx.x = rst_sl_x + (rst_sl_w - rst_lbl_w) / 2; gfx.y = rst_text_y
        gfx.drawstr(rst_label)
        if rst_btn_hov and tips_enabled and not pending_tooltip then
            pending_tooltip = "Restore all notes to their original (pre-warp)\npositions and reset all take markers to 1.00x.\nRequires the selected MIDI item to have\nan active MIDI SM state."
        end
    end

    -- Draw Nudge to Transients button row (MIDI TOOLS)
    if is_row_visible(nudge_row_y) then
        local nudge_text_y = nudge_row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = nudge_text_y
        gfx.drawstr("Nudge to Transients")
        local nudge_sett_btn_x = sett_simple_btn_x
        local nudge_sett_btn_w = math.max(20, cb_x - COL_SPACING - sett_simple_btn_x)
        local nudge_sett_label = "Nudge"
        if os.clock() < nudge_confirmed_until then nudge_sett_label = "Nudged!" end
        nudge_btn_hovered = (mouse_x >= nudge_sett_btn_x and mouse_x < nudge_sett_btn_x + nudge_sett_btn_w and
                             mouse_y >= nudge_row_y and mouse_y < nudge_row_y + checkbox_size)
        if nudge_btn_hovered then
            gfx.set(0.17, 0.45, 0.39, 1)
        elseif os.clock() < nudge_confirmed_until then
            gfx.set(0.15, 0.35, 0.2, 1)
        else
            gfx.set(0.2, 0.2, 0.2, 1)
        end
        gfx.rect(nudge_sett_btn_x, nudge_row_y, nudge_sett_btn_w, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(nudge_sett_btn_x, nudge_row_y, nudge_sett_btn_w, checkbox_size, 0)
        if os.clock() < nudge_confirmed_until then
            gfx.set(0.3, 0.85, 0.5, 1)
        else
            gfx.set(table.unpack(gui.colors.TEXT))
        end
        local nudge_lbl_w = gfx.measurestr(nudge_sett_label)
        gfx.x = nudge_sett_btn_x + (nudge_sett_btn_w - nudge_lbl_w) / 2
        gfx.y = nudge_text_y
        gfx.drawstr(nudge_sett_label)
        if nudge_btn_hovered and tips_enabled then
            pending_tooltip = "Snap note starts to nearest stretch markers,\npreserving note lengths. No overlap on same pitch.\nSelect 2 items: MIDI + audio with stretch markers."
        end
    end
    end -- end scope: remap + nudge buttons drawing

    -- INSERT AT MOUSE section rows
    do
    local function draw_iam_cb(row_y, label, checked)
        if not is_row_visible(row_y) then return end
        local ty = row_y + (checkbox_size - gfx.texth) / 2
        gfx.set(table.unpack(gui.colors.TEXT))
        gfx.x = horizontal_margin
        gfx.y = ty
        gfx.drawstr(label)
        local hov = mouse_x >= cb_x and mouse_x < cb_x + checkbox_size and
                    mouse_y >= row_y and mouse_y < row_y + checkbox_size
        if checked or hov then
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
        else
            gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
        end
        gfx.rect(cb_x, row_y, checkbox_size, checkbox_size, 1)
        gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
        gfx.rect(cb_x, row_y, checkbox_size, checkbox_size, 0)
        gfx.rect(cb_x + 1, row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
        if checked then
            gfx.set(table.unpack(gui.colors.CHECKMARK))
            gfx.x = cb_x + (checkbox_size - gfx.measurestr("\xE2\x9C\x93")) / 2
            gfx.y = ty
            gfx.drawstr("\xE2\x9C\x93")
        end
    end
    draw_iam_cb(iam_stretch_row_y, "Insert: Stretch markers (audio)", iam_enable_stretch)
    draw_iam_cb(iam_take_tm_row_y, "Insert: Take markers (MIDI)",     iam_enable_take_tm)
    draw_iam_cb(iam_tempo_row_y,   "Insert: Tempo markers (ruler)",   iam_enable_tempo)
    end -- end INSERT AT MOUSE rows

    -- Separator line
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.line(horizontal_margin, separator_y, gfx.w - horizontal_margin, separator_y)

    do -- scope: column headers + articulation rows drawing (free locals)
    -- Column headers
    gfx.set(0.5, 0.5, 0.5, 1)
    local function draw_col_header(x, w, label)
        local lw = gfx.measurestr(label)
        gfx.x = x + (w - lw) / 2
        gfx.y = col_header_y
        gfx.drawstr(label)
    end
    draw_col_header(sym_box_x, SYM_BOX_WIDTH, "Symbol")
    draw_col_header(type_btn_x, TYPE_BTN_WIDTH, "Type")
    draw_col_header(repl_col_x, REPL_COL_WIDTH, "Replace Fret")
    draw_col_header(prefix_cb_x, checkbox_size, "_")
    draw_col_header(cb_x, checkbox_size, "On")
    draw_col_header(menu_cb_x, checkbox_size, "M")

    -- Draw articulation rows
    for i, art_name in ipairs(articulation_names_ordered) do
        local row_y = list_top + (i - 1) * checkbox_row_height
        if is_row_visible(row_y) then
            local text_y = row_y + (checkbox_size - gfx.texth) / 2

            -- Highlight row if this articulation is present in the file
            if articulations_in_file[art_name] then
                gfx.set(0.18, 0.25, 0.22, 1)
                gfx.rect(horizontal_margin - 4, row_y, gfx.w - 2 * horizontal_margin + 8, checkbox_size, 1)
            end

            -- 1) Draw articulation name (left side, truncated) - clickable
            local display_name = truncate_text(art_name, name_max_w)
            local name_hovered = (mouse_x >= horizontal_margin and mouse_x < sym_box_x - COL_SPACING and
                                  mouse_y >= row_y and mouse_y < row_y + checkbox_size)
            if name_hovered then
                if (gfx.mouse_cap & 16) ~= 0 then
                    gfx.set(0.85, 0.25, 0.25, 1)  -- red for Alt (remove mode)
                else
                    gfx.set(0.17, 0.45, 0.39, 1)
                end
            else
                gfx.set(table.unpack(gui.colors.TEXT))
            end
            gfx.x = horizontal_margin
            gfx.y = text_y
            gfx.drawstr(display_name)

            -- 2) Draw symbol text input box
            local is_editing = (sym_edit_active and sym_edit_index == i)
            local sym_display = is_editing and sym_edit_text or get_art_symbol(art_name)
            local sym_is_override = (articulation_symbol_override[art_name] ~= nil)

            -- Box background
            if is_editing then
                gfx.set(0.25, 0.25, 0.25, 1)
            else
                gfx.set(0.17, 0.17, 0.17, 1)
            end
            gfx.rect(sym_box_x, row_y, SYM_BOX_WIDTH, checkbox_size, 1)
            -- Box border (highlight if editing or overridden)
            if is_editing then
                gfx.set(0.17, 0.45, 0.39, 1)
            elseif sym_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
            end
            gfx.rect(sym_box_x, row_y, SYM_BOX_WIDTH, checkbox_size, 0)

            -- Symbol text (truncated to fit, with cursor if editing)
            local sym_text_x = sym_box_x + 4
            local sym_max_w = SYM_BOX_WIDTH - 8
            local sym_truncated = truncate_text(sym_display, sym_max_w)
            if sym_is_override then
                gfx.set(1.0, 0.85, 0.5, 1)  -- gold tint for overridden
            else
                gfx.set(table.unpack(gui.colors.TEXT))
            end
            gfx.x = sym_text_x
            gfx.y = text_y
            gfx.drawstr(sym_truncated)

            -- Draw cursor if editing
            if is_editing then
                local cursor_text = sym_edit_text:sub(1, sym_edit_cursor)
                local cursor_px = gfx.measurestr(cursor_text)
                -- Blink cursor (~every 30 frames)
                if math.floor(os.clock() * 2) % 2 == 0 then
                    gfx.set(1, 1, 1, 0.9)
                    gfx.line(sym_text_x + cursor_px, row_y + 2, sym_text_x + cursor_px, row_y + checkbox_size - 2)
                end
            end

            -- 3) Draw type selector button
            local current_type = get_art_type(art_name)
            local type_label = art_type_labels[current_type] or ("T" .. tostring(current_type))
            local type_is_override = (articulation_type_override[art_name] ~= nil)
            local type_hovered = (mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH and
                                  mouse_y > row_y and mouse_y < row_y + checkbox_size)
            -- Button background
            if type_hovered then
                gfx.set(0.17, 0.45, 0.39, 1)
            else
                gfx.set(0.2, 0.2, 0.2, 1)
            end
            gfx.rect(type_btn_x, row_y, TYPE_BTN_WIDTH, checkbox_size, 1)
            -- Button border (highlight if overridden)
            if type_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
            end
            gfx.rect(type_btn_x, row_y, TYPE_BTN_WIDTH, checkbox_size, 0)
            -- Button label
            if type_is_override then
                gfx.set(1.0, 0.85, 0.5, 1)
            else
                gfx.set(table.unpack(gui.colors.TEXT))
            end
            local lbl_w = gfx.measurestr(type_label)
            gfx.x = type_btn_x + (TYPE_BTN_WIDTH - lbl_w) / 2
            gfx.y = text_y
            gfx.drawstr(type_label)

            -- 4) Draw replace-fret checkbox
            local rf_checked = get_art_replaces_fret(art_name)
            local rf_is_override = (articulation_replaces_fret_override[art_name] ~= nil)
            -- Background
            if rf_checked then
                gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
            else
                gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
            end
            gfx.rect(repl_cb_x, row_y, checkbox_size, checkbox_size, 1)
            -- Border (gold if overridden)
            if rf_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
            end
            gfx.rect(repl_cb_x, row_y, checkbox_size, checkbox_size, 0)
            gfx.set(table.unpack(gui.colors.CHECKBOX_INNER_BORDER))
            gfx.rect(repl_cb_x + 1, row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
            if rf_checked then
                if rf_is_override then
                    gfx.set(1.0, 0.85, 0.5, 1)
                else
                    gfx.set(table.unpack(gui.colors.CHECKMARK))
                end
                gfx.x = repl_cb_x + (checkbox_size - gfx.measurestr("✓")) / 2
                gfx.y = row_y + (checkbox_size - gfx.texth) / 2
                gfx.drawstr("✓")
            end

            -- 5) Draw prefix checkbox (checked = uses _ prefix = no_prefix is false)
            pfx_checked = not get_art_no_prefix(art_name)
            pfx_is_override = (articulation_no_prefix_override[art_name] ~= nil)
            if pfx_checked then
                gfx.set(table.unpack(gui.colors.CHECKBOX_BG_HOVER))
            else
                gfx.set(table.unpack(gui.colors.CHECKBOX_BG))
            end
            gfx.rect(prefix_cb_x, row_y, checkbox_size, checkbox_size, 1)
            if pfx_is_override then
                gfx.set(0.45, 0.35, 0.17, 1)
            else
                gfx.set(table.unpack(gui.colors.CHECKBOX_BORDER))
            end
            gfx.rect(prefix_cb_x, row_y, checkbox_size, checkbox_size, 0)
            gfx.set(table.unpack(gui.colors.CHECKBOX_INNER_BORDER))
            gfx.rect(prefix_cb_x + 1, row_y + 1, checkbox_size - 2, checkbox_size - 2, 0)
            if pfx_checked then
                if pfx_is_override then
                    gfx.set(1.0, 0.85, 0.5, 1)
                else
                    gfx.set(table.unpack(gui.colors.CHECKMARK))
                end
                gfx.x = prefix_cb_x + (checkbox_size - gfx.measurestr("✓")) / 2
                gfx.y = row_y + (checkbox_size - gfx.texth) / 2
                gfx.drawstr("✓")
            end

            -- 6) Draw checkbox (enabled/disabled)
            draw_checkbox(cb_x, row_y, checkbox_size, cb_x, "", articulation_enabled[art_name], gui.colors, 0, nil)
            -- 7) M checkbox (show in main menu)
            draw_menu_flag_cb(menu_cb_x, row_y, settings_menu_flags[art_name])
        end
    end
    end -- end scope: column headers + articulation rows drawing

    -- Masking rectangles (cover content overflow into header and button areas)
    do
    local cr = (gfx.clear & 0xFF) / 255
    local cg = ((gfx.clear >> 8) & 0xFF) / 255
    local cb_c = ((gfx.clear >> 16) & 0xFF) / 255
    gfx.set(cr, cg, cb_c, 1)
    gfx.rect(0, 0, gfx.w, content_top, 1)
    gfx.rect(0, content_bottom, gfx.w, gfx.h - content_bottom, 1)
    end

    -- Re-draw header on top of mask
    draw_header("SETTINGS", header_height, gui.colors)

    -- Draw unified scrollbar if needed
    if max_scroll > 0 then
        -- Highlight thumb when dragging
        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(scrollbar_x, content_top, scrollbar_width, scrollbar_track_height, 1)
        if settings_sb_dragging then
            gfx.set(0.65, 0.65, 0.65, 1)
        else
            gfx.set(0.4, 0.4, 0.4, 1)
        end
        gfx.rect(scrollbar_x, sb_thumb_y, scrollbar_width, sb_thumb_height, 1)
    end

    -- Draw buttons
    draw_button(import_btn_x, btn_y, btn_width, btn_height, "Import",
                settings_import_hovered, "IMPORT_BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(save_btn_x, btn_y, btn_width, btn_height, "Save",
                settings_save_hovered, "IMPORT_BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(restore_btn_x, btn_y, btn_width, btn_height, "Restore",
                settings_restore_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(close_btn_x, btn_y, btn_width, btn_height, "Close",
                settings_close_hovered, "CLOSE_BTN", gui.colors.BORDER, gui.colors.TEXT)

    -- Draw "Saved!" confirmation label above the Save button
    if os.clock() < settings_save_confirmed_until then
        gfx.set(0.3, 0.85, 0.5, 1)  -- green
        local saved_text = "Saved!"
        local sw = gfx.measurestr(saved_text)
        gfx.x = save_btn_x + (btn_width - sw) / 2
        gfx.y = btn_y - gfx.texth - 4
        gfx.drawstr(saved_text)
    end

    -- Draw and handle dark menu (on top of everything except tooltip)
    draw_and_handle_dark_menu(mouse_x, mouse_y, mouse_clicked, mouse_released, char_input)

    -- Draw GUI message box overlay (on top of everything)
    draw_and_handle_gui_msgbox(mouse_x, mouse_y, mouse_clicked, char_input)

    -- Draw tooltip (on top of everything)
    if not dark_menu.active and not gui_msgbox.active and tips_enabled then
        if settings_tooltip_text then
            draw_tooltip(settings_tooltip_text, mouse_x, mouse_y)
        elseif pending_tooltip then
            draw_tooltip(pending_tooltip, mouse_x, mouse_y)
        end
    end
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================

function main_loop()
    local mouse_x, mouse_y = gfx.mouse_x, gfx.mouse_y
    local screen_x, screen_y = reaper.GetMousePosition()
    local mouse_down = (gfx.mouse_cap & 1 == 1)
    local mouse_clicked = mouse_down and (last_mouse_cap & 1 == 0)
    local mouse_released = (last_mouse_cap & 1 == 1) and (gfx.mouse_cap & 1 == 0)

    -- Auto-focus: bring window to front when mouse hovers over it,
    -- return focus to REAPER when mouse leaves.
    -- Only act when focus is already within REAPER (main window or this script),
    -- so external apps (Flow Launcher, Win+V clipboard, etc.) are not disrupted.
    if window_script and auto_focus_enabled then
        local mouse_inside = mouse_x >= 0 and mouse_x < gfx.w and mouse_y >= 0 and mouse_y < gfx.h
        local fg = reaper.JS_Window_GetForeground()
        local main_hwnd = reaper.GetMainHwnd()
        if mouse_inside and fg ~= window_script and fg == main_hwnd then
            reaper.JS_Window_SetForeground(window_script)
        elseif not mouse_inside and fg == window_script then
            if main_hwnd then reaper.JS_Window_SetForeground(main_hwnd) end
        end
    end

    -- Stay on top: enforce topmost z-order only when a REAPER window has focus.
    -- Remove topmost when external apps have focus, REAPER is minimized, or file dialog is open.
    if window_script and stay_on_top_enabled then
        local main_hwnd = reaper.GetMainHwnd()
        local main_style = main_hwnd and reaper.JS_Window_GetLong(main_hwnd, "STYLE")
        local is_minimized = main_style and (main_style & 0x20000000) ~= 0
        if is_minimized then
            -- REAPER minimized: remove topmost
            local exstyle = reaper.JS_Window_GetLong(window_script, "EXSTYLE")
            if exstyle and (exstyle & 0x8) ~= 0 then
                reaper.JS_Window_SetZOrder(window_script, "NOTOPMOST")
            end
        else
            -- Check if a REAPER window has focus
            local fg = reaper.JS_Window_GetForeground()
            local is_reaper = (fg == window_script or fg == main_hwnd)
            if not is_reaper and fg then
                local w = fg
                for i = 1, 20 do
                    w = reaper.JS_Window_GetParent(w)
                    if not w then break end
                    if w == main_hwnd then is_reaper = true; break end
                end
            end
            local exstyle = reaper.JS_Window_GetLong(window_script, "EXSTYLE")
            if is_reaper then
                if exstyle and (exstyle & 0x8) == 0 then
                    reaper.JS_Window_SetZOrder(window_script, "TOPMOST")
                end
            else
                if exstyle and (exstyle & 0x8) ~= 0 then
                    reaper.JS_Window_SetZOrder(window_script, "NOTOPMOST")
                end
            end
        end
    end
    
    -- Settings view branch
    if settings_mode then
        local char = gfx.getchar()
        local char_input = (char > 0) and char or nil
        draw_settings_view(mouse_x, mouse_y, mouse_clicked, mouse_released, screen_x, screen_y, mouse_down, char_input)
        -- Resize handle (drawn on top)
        draw_and_handle_resize(mouse_x, mouse_y, mouse_clicked, mouse_released, mouse_down, screen_x, screen_y)
        -- Draw import progress overlay (on top of everything)
        if import_progress.active then
            draw_import_progress()
            if import_progress.done then
                local card_w = math.max(300, math.floor(gfx.w * 0.7))
                local log_lines = math.min(#import_progress.log, 8)
                local extra = (#import_progress.log > 8) and 1 or 0
                local card_h = math.max(120, 16 + gfx.texth + 10 + (log_lines + extra) * gfx.texth + 12 + 26 + 16)
                local card_x = math.floor((gfx.w - card_w) / 2)
                local card_y = math.floor((gfx.h - card_h) / 2)
                local btn_x = card_x + 16
                local btn_y = card_y + card_h - 16 - 26
                local hov = mouse_x >= btn_x and mouse_x < btn_x + 80 and mouse_y >= btn_y and mouse_y < btn_y + 26
                if (mouse_clicked and hov) or char_input == 13 or char_input == 27 then
                    import_progress.active = false
                    save_window_position()
                    save_window_size("settings")
                    gfx.quit()
                    return
                end
            end
        end
        gfx.update()
        last_mouse_cap = gfx.mouse_cap
        if char >= 0 then
            reaper.defer(main_loop)
        else
            save_window_position()
            save_window_size("settings")
            gfx.quit()
        end
        return
    end

    -- Handle dropped files (drag-and-drop from Explorer / Flow Launcher / etc.)
    local char = gfx.getchar()
    local char_input = (char > 0) and char or nil

    -- Auto-load by region: check if cursor moved to a new region
    try_autoload_by_region()

    -- MIDI Stretch Markers: detect moved take markers and stretch notes
    if midi_sm_enabled then check_midi_sm_changes() end

    local retval, drop_file = gfx.getdropfile(0)
    if retval > 0 and drop_file and drop_file ~= "" then
        gfx.getdropfile(-1)  -- clear the drop list
        if drop_file:lower():match("%.xml$") then
            autoload_region_start_pos = nil  -- manual selection clears auto-load override
            autoload_last_region_name = nil
            selected_file_path = drop_file
            selected_file_name = get_filename_from_path(drop_file)
            save_last_import_path(drop_file)
            last_import_dir = load_last_import_path()
            local f = io.open(drop_file, "r")
            if f then
                local content = f:read("*all")
                f:close()
                local track_names = get_tracks_from_xml(content)
                selected_file_track_count = #track_names
                track_checkboxes = {}
                for _, t in ipairs(track_names) do
                    table.insert(track_checkboxes, {name = t.name, gm_name = t.gm_name, checked = true})
                end
                import_all_checked = true
            else
                selected_file_track_count = 0
                track_checkboxes = {}
            end
            resize_window()
            if highlight_scan_enabled then scan_articulations_in_xml() end
        end
    end

    -- Text selection handling (uses previous frame's text_elements_frame)
    if mouse_clicked then
        local elem = find_text_element_at(mouse_x, mouse_y)
        if elem then
            text_sel.active = true
            text_sel.element_id = elem.id
            text_sel.display_text = elem.display_text
            text_sel.full_text = elem.full_text
            text_sel.text_x = elem.x
            text_sel.start_char = char_index_at_x(elem.display_text, elem.x, mouse_x)
            text_sel.end_char = text_sel.start_char
            text_sel_mouse_start_x = mouse_x
            text_sel_mouse_start_y = mouse_y
        else
            -- Clear selection when clicking outside text
            text_sel.active = false
            text_sel.element_id = nil
            text_sel.start_char = 0
            text_sel.end_char = 0
        end
    elseif mouse_down and text_sel.active then
        -- Continue dragging - update end position
        text_sel.end_char = char_index_at_x(text_sel.display_text, text_sel.text_x, mouse_x)
    elseif mouse_released and text_sel.active then
        text_sel.active = false  -- stop tracking active drag, but keep selection visible
    end
    
    -- Clear text elements for this frame (will be rebuilt during drawing)
    text_elements_frame = {}
    
    -- Check if mouse is over header area
    local header_hovered = (mouse_y > 0 and mouse_y < header_height)
    local rmb_clicked = (gfx.mouse_cap & 2 ~= 0) and (last_mouse_cap & 2 == 0)
    if rmb_clicked and header_hovered then
        open_header_dock_menu(mouse_x, mouse_y)
    end
    
    -- Handle drag start
    if mouse_clicked and header_hovered and not RS.active then
        is_dragging = true
        drag_offset_x = mouse_x
        drag_offset_y = mouse_y
    end
    
    -- Handle dragging - keep the relative click point under the cursor
    if is_dragging and window_script then
        local new_x = math.floor(screen_x - drag_offset_x)
        local new_y = math.floor(screen_y - drag_offset_y)
        reaper.JS_Window_Move(window_script, new_x, new_y)
    end

    -- Track drag-to-arrange: confirm drag after threshold, import and hand off to arrange
    if track_drag.active and mouse_down then
        local dx = math.abs(mouse_x - track_drag.start_x)
        local dy = math.abs(mouse_y - track_drag.start_y)
        if not track_drag.confirmed and (dx > DRAG_THRESHOLD or dy > DRAG_THRESHOLD) then
            is_dragging = false
            -- Import the track immediately and hand off drag to REAPER arrange view
            do
                local tcb = track_checkboxes[track_drag.track_index]
                if tcb and selected_file_path then
                    local track_name = get_track_display_name(tcb)
                    local saved_autoload = autoload_region_start_pos
                    local import_pos = reaper.GetCursorPosition()
                    autoload_region_start_pos = import_pos
                    -- Count items on all tracks before import so we can find the new one
                    local items_before = reaper.CountMediaItems(0)
                    local options = {
                        import_markers = false,
                        import_regions = false,
                        import_midi_banks = checkboxes_list[3].checked,
                        import_key_sigs = false,
                        insert_on_new_tracks = false,
                        insert_on_existing_tracks = false,
                        insert_on_tracks_by_name = true,
                        selected_tracks = { track_name }
                    }
                    local pre_import_state = capture_pre_import_state()
                    ImportMusicXMLWithOptions(selected_file_path, options)
                    capture_post_import_history(pre_import_state, selected_file_path)
                    autoload_region_start_pos = saved_autoload
                    -- Find newly created item(s) by comparing item count
                    local items_after = reaper.CountMediaItems(0)
                    local new_item = nil
                    if items_after > items_before then
                        -- Deselect all items, then select only the new one(s)
                        for i = 0, items_after - 1 do
                            reaper.SetMediaItemSelected(reaper.GetMediaItem(0, i), false)
                        end
                        -- The new items are at the end of the item list
                        for i = items_before, items_after - 1 do
                            local item = reaper.GetMediaItem(0, i)
                            if item then
                                reaper.SetMediaItemSelected(item, true)
                                if not new_item then new_item = item end
                            end
                        end
                        reaper.UpdateArrange()
                    end
                    -- Move mouse to the new item's center and hand off drag
                    if new_item then
                        local item_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION")
                        local item_len = reaper.GetMediaItemInfo_Value(new_item, "D_LENGTH")
                        local item_track = reaper.GetMediaItem_Track(new_item)
                        local main_hwnd = reaper.GetMainHwnd()
                        local arrange_hwnd = reaper.JS_Window_FindChildByID(main_hwnd, 1000)
                        if arrange_hwnd then
                            local start_time, end_time = reaper.GetSet_ArrangeView2(0, false, 0, 0)
                            local _, arr_l, arr_t, arr_r = reaper.JS_Window_GetClientRect(arrange_hwnd)
                            local arr_w = arr_r - arr_l
                            local zoom = arr_w / (end_time - start_time)
                            local item_cx = math.floor((item_pos + item_len / 2 - start_time) * zoom)
                            local track_y = reaper.GetMediaTrackInfo_Value(item_track, "I_TCPY")
                            local track_h = reaper.GetMediaTrackInfo_Value(item_track, "I_TCPH")
                            local item_cy = math.floor(track_y + track_h / 2)
                            -- Move mouse to item center in arrange view
                            reaper.JS_Mouse_SetPosition(arr_l + item_cx, arr_t + item_cy)
                            -- Hand off drag to REAPER: simulate mouse-down on item
                            reaper.JS_WindowMessage_Post(arrange_hwnd, "WM_LBUTTONDOWN", 1, 0, item_cx, item_cy)
                        end
                    end
                end
            end
            reset_track_drag()
        end
    end

    -- Handle drag end
    if mouse_released then
        is_dragging = false

        -- Track drag: reset if released without confirming (click without movement)
        if track_drag.active then
            reset_track_drag()
        end
        
        -- File info click: open dialog only if no significant drag occurred
        if file_info_click_pending then
            local dx = math.abs(mouse_x - file_info_click_x)
            local dy = math.abs(mouse_y - file_info_click_y)
            if dx <= DRAG_THRESHOLD and dy <= DRAG_THRESHOLD then
                -- It was a click, not a drag - open file dialog
                local start_dir
                if path_mode == "default" and default_import_dir ~= "" then
                    start_dir = default_import_dir
                elseif last_import_dir ~= "" then
                    start_dir = last_import_dir
                else
                    start_dir = default_import_dir
                end
                -- Ensure trailing separator so the dialog opens the folder, not its parent
                if start_dir ~= "" and not start_dir:match("[/\\]$") then
                    start_dir = start_dir .. "/"
                end
                -- Temporarily remove topmost before file dialog
                if stay_on_top_enabled and window_script then
                    reaper.JS_Window_SetZOrder(window_script, "NOTOPMOST")
                end
                local retval, filepath = reaper.GetUserFileNameForRead(start_dir, "Select MusicXML file", "*.xml")
                -- Re-apply topmost after file dialog closes
                if stay_on_top_enabled and window_script then
                    reaper.JS_Window_SetZOrder(window_script, "TOPMOST")
                end
                if retval then
                    autoload_region_start_pos = nil  -- manual selection clears auto-load override
                    autoload_last_region_name = nil
                    selected_file_path = filepath
                    selected_file_name = get_filename_from_path(filepath)
                    save_last_import_path(filepath)
                    last_import_dir = load_last_import_path()
                    
                    local f = io.open(filepath, "r")
                    if f then
                        local content = f:read("*all")
                        f:close()
                        local track_names = get_tracks_from_xml(content)
                        selected_file_track_count = #track_names
                        track_checkboxes = {}
                        for _, t in ipairs(track_names) do
                            table.insert(track_checkboxes, {name = t.name, gm_name = t.gm_name, checked = true})
                        end
                        import_all_checked = true
                    else
                        selected_file_track_count = 0
                        track_checkboxes = {}
                    end
                    resize_window()
                    if highlight_scan_enabled then scan_articulations_in_xml() end
                end
                -- Clear any selection started during click
                text_sel.element_id = nil
                text_sel.start_char = 0
                text_sel.end_char = 0
            end
            file_info_click_pending = false
        end
    end

    -- Button area - bottom with five buttons side by side
    local btn_height = 30
    local btn_spacing = 10
    local btn_width = math.min(110, math.max(40, math.floor((gfx.w - horizontal_margin * 2 - btn_spacing * 4) / 5)))
    local total_btn_width = btn_width * 5 + btn_spacing * 4
    local btn_y = gfx.h - btn_height - 10
    local btn_start_x = math.floor((gfx.w - total_btn_width) / 2)
    
    -- Import button
    local import_btn_x = btn_start_x
    local import_btn_y = btn_y
    
    -- Export button
    local export_btn_x = import_btn_x + btn_width + btn_spacing
    local export_btn_y = btn_y
    
    -- Undo button
    local undo_btn_x = export_btn_x + btn_width + btn_spacing
    local undo_btn_y = btn_y
    
    -- Settings button
    local settings_btn_x = undo_btn_x + btn_width + btn_spacing
    local settings_btn_y = btn_y
    
    -- Cancel button
    local cancel_btn_x = settings_btn_x + btn_width + btn_spacing
    local cancel_btn_y = btn_y
    
    -- File info area for clicking to select file
    local visible_checkboxes = 1  -- SETTINGS fold header row (always visible)
    if not main_settings_folded then
        for _, cb in ipairs(checkboxes_list) do
            if cb.show_in_menu ~= false then visible_checkboxes = visible_checkboxes + 1 end
        end
        visible_checkboxes = visible_checkboxes + #get_visible_extra_settings()
    end
    
    -- Compute main settings scroll state
    local settings_area_top = header_height + vertical_margin
    local fixed_bottom_h = vertical_margin + file_info_height + vertical_margin + button_height_area
    local settings_avail_h = gfx.h - settings_area_top - fixed_bottom_h
    local max_vis_settings = math.max(1, math.floor(settings_avail_h / checkbox_row_height))
    local main_needs_scroll = visible_checkboxes > max_vis_settings
    local main_display_rows = main_needs_scroll and max_vis_settings or visible_checkboxes
    local max_main_scroll = math.max(0, visible_checkboxes - max_vis_settings)
    if main_scroll_offset > max_main_scroll then main_scroll_offset = max_main_scroll end
    if main_scroll_offset < 0 then main_scroll_offset = 0 end
    
    local file_info_y_top = settings_area_top + main_display_rows * checkbox_row_height + vertical_margin
    local file_info_y
    if main_needs_scroll and #track_checkboxes == 0 then
        -- Anchor from bottom to eliminate visual gap from floor() remainder
        local file_info_y_bottom = btn_y - vertical_margin - file_info_height
        file_info_y = math.max(file_info_y_top, file_info_y_bottom)
    else
        file_info_y = file_info_y_top
    end
    local file_info_hovered = (mouse_x > 0 and mouse_x < gfx.w and
                               mouse_y > file_info_y and mouse_y < file_info_y + file_info_height)
    -- File info tooltip
    if file_info_hovered and not pending_tooltip then
        if selected_file_path then
            pending_tooltip = "Click to browse for a different MusicXML file.\nOr drag and drop a file here."
        else
            pending_tooltip = "Click to browse for a MusicXML file.\nOr drag and drop a file here."
        end
    end

    -- Detect external drag-over: mouse is inside the window with left button held
    -- externally (Explorer drag) but gfx.mouse_cap doesn't see it
    local is_external_drag = false
    if window_script and gfx.mouse_cap == 0 then
        local os_mouse_state = reaper.JS_Mouse_GetState(1)  -- 1 = left button
        if os_mouse_state == 1 then
            is_external_drag = true
        end
    end
    local is_drag_over_file_info = is_external_drag and file_info_hovered

    -- Handle clicks
    if mouse_clicked and not dark_menu.active and not gui_msgbox.active and not import_progress.active then
        -- Cancel button
        if cancel_btn_hovered then
            reset_track_drag()
            save_window_position()
            save_window_size(settings_mode and "settings" or "main")
            gfx.quit()
            return
        end

        -- File info area - defer to mouse release so drag = text selection, click = file dialog
        if file_info_hovered then
            file_info_click_pending = true
            file_info_click_x = mouse_x
            file_info_click_y = mouse_y
        end

        -- Import button
        if import_btn_hovered then
            if selected_file_path then
                -- Build list of selected track names
                local selected_tracks = {}
                for _, tcb in ipairs(track_checkboxes) do
                    if tcb.checked then
                        table.insert(selected_tracks, get_track_display_name(tcb))
                    end
                end
                -- Collect checkbox states into options table
                local options = {
                    import_markers = checkboxes_list[1].checked,
                    import_regions = checkboxes_list[2].checked,
                    import_midi_banks = checkboxes_list[3].checked,
                    import_key_sigs = checkboxes_list[4].checked,
                    insert_on_new_tracks = checkboxes_list[5].checked,
                    insert_on_existing_tracks = checkboxes_list[6].checked,
                    insert_on_tracks_by_name = checkboxes_list[7].checked,
                    align_to_audio = (import_timebase_index == 6),
                    align_notes_to_transients = checkboxes_list[8].checked,
                    tempo_map_freq = tempo_map_freq_index,
                    selected_tracks = selected_tracks
                }
                -- Execute import with selected options
                import_progress.active = true
                import_progress.pct = 0
                import_progress.status = "Starting..."
                import_progress.start_time = reaper.time_precise()
                import_progress.log = {}
                import_progress.done = false
                update_import_progress(0, "Parsing MusicXML...")
                local pre_import_state = capture_pre_import_state()
                autoload_region_start_pos = nil  -- manual import: honour import_position_index, not autoload override
                ImportMusicXMLWithOptions(selected_file_path, options)
                capture_post_import_history(pre_import_state, selected_file_path)
                import_progress.done = true
                import_progress.end_time = reaper.time_precise()
                import_progress.pct = 1
                update_import_progress(1, "Done")
            else
                safe_msgbox("Please select a MusicXML file first.", "No File Selected", 0)
            end
        end

        -- Export button
        if export_btn_hovered then
            local num_items = reaper.CountSelectedMediaItems(0)
            if num_items > 0 then
                local start_dir = ""
                if path_mode == "default" and default_import_dir ~= "" then
                    start_dir = default_import_dir
                elseif last_import_dir ~= "" then
                    start_dir = last_import_dir
                end
                if stay_on_top_enabled and window_script then
                    reaper.JS_Window_SetZOrder(window_script, "NOTOPMOST")
                end
                local retval, save_path = reaper.JS_Dialog_BrowseForSaveFile("Export MusicXML", start_dir, "", "MusicXML (*.xml)\0*.xml\0\0")
                if stay_on_top_enabled and window_script then
                    reaper.JS_Window_SetZOrder(window_script, "TOPMOST")
                end
                if retval == 1 and save_path and save_path ~= "" then
                    if not save_path:lower():match("%.xml$") then
                        save_path = save_path .. ".xml"
                    end
                    ExportMusicXML(save_path)
                    export_confirmed_until = os.clock() + 1.5
                    -- Post-export: open with external program
                    if export_open_with_enabled and export_open_with_path ~= "" then
                        reaper.ExecProcess('"' .. export_open_with_path .. '" "' .. save_path .. '"', -1)
                    end
                    -- Post-export: open containing folder
                    if export_open_folder_enabled then
                        reaper.ExecProcess('explorer /select,"' .. save_path .. '"', -1)
                    end
                end
            else
                safe_msgbox("Please select one or more MIDI items to export.", "No Items Selected", 0)
            end
        end

        -- Undo button
        if undo_btn_hovered then
            if #import_history == 0 then
                safe_msgbox("No import history to undo.", "Nothing to Undo", 0)
            else
                -- Build menu of import history entries
                local menu_str = ""
                for i = #import_history, 1, -1 do
                    local entry = import_history[i]
                    if i < #import_history then menu_str = menu_str .. "|" end
                    local label = entry.label or ("Import #" .. i)
                    menu_str = menu_str .. label
                end
                open_dark_menu(menu_str, undo_btn_x, undo_btn_y, function(choice)
                    if choice > 0 then
                        local actual_idx = #import_history - choice + 1
                        local entry = import_history[actual_idx]
                        if entry then
                            reaper.Undo_BeginBlock()
                            reaper.PreventUIRefresh(1)
                            -- Delete created items
                            if entry.item_guids then
                                for _, guid in ipairs(entry.item_guids) do
                                    local item = reaper.BR_GetMediaItemByGUID(0, guid)
                                    if item then
                                        local track = reaper.GetMediaItemTrack(item)
                                        reaper.DeleteTrackMediaItem(track, item)
                                    end
                                end
                            end
                            -- Delete created tracks (in reverse to preserve indices)
                            if entry.track_guids then
                                for i = #entry.track_guids, 1, -1 do
                                    local track = reaper.BR_GetMediaTrackByGUID(0, entry.track_guids[i])
                                    if track then
                                        reaper.DeleteTrack(track)
                                    end
                                end
                            end
                            -- Delete created regions
                            if entry.region_indices then
                                for i = #entry.region_indices, 1, -1 do
                                    reaper.DeleteProjectMarker(0, entry.region_indices[i], true)
                                end
                            end
                            -- Delete tempo markers
                            if entry.tempo_marker_indices then
                                for i = #entry.tempo_marker_indices, 1, -1 do
                                    reaper.DeleteTempoTimeSigMarker(0, entry.tempo_marker_indices[i])
                                end
                            end
                            reaper.UpdateTimeline()
                            reaper.PreventUIRefresh(-1)
                            reaper.Undo_EndBlock("Undo MusicXML Import: " .. (entry.label or ""), -1)
                            table.remove(import_history, actual_idx)
                            save_import_history()
                        end
                    end
                end)
            end
        end

        -- Settings button
        if settings_btn_hovered then
            settings_mode = true
            settings_scroll_offset = 0
            sym_edit_active = false
            sym_edit_index = nil
            -- Commit any main view symbol edit
            if main_sym_edit_active and main_sym_edit_index then
                local art_name = articulation_names_ordered[main_sym_edit_index]
                if main_sym_edit_text ~= articulation_default_symbol[art_name] then
                    articulation_symbol_override[art_name] = main_sym_edit_text
                else
                    articulation_symbol_override[art_name] = nil
                end
            end
            main_sym_edit_active = false
            main_sym_edit_index = nil
            -- Commit any main view default path edit
            if main_defpath_edit_active then
                default_import_dir = main_defpath_edit_text
                save_default_import_dir(main_defpath_edit_text)
                main_defpath_edit_active = false
            end
            -- Save current size and resize for settings view
            save_window_size("main")
            pre_settings_width = gui.width
            pre_settings_height = gui.height
            -- Try to restore saved settings tab size
            local restored_settings = false
            if remember_window_size then
                local sw, sh = load_window_size("settings")
                if sw and sh then
                    gui.width = math.max(RS.MIN_W, math.min(sw, MAX_WINDOW_WIDTH))
                    gui.height = math.max(RS.MIN_H, math.min(sh, MAX_WINDOW_HEIGHT))
                    if window_script then
                        reaper.JS_Window_Resize(window_script, gui.width, gui.height)
                    else
                        local _, wx, wy = gfx.dock(-1, 0, 0, 0, 0)
                        gfx.init(SCRIPT_TITLE, gui.width, gui.height, gui.settings.docker_id, wx, wy)
                    end
                    restored_settings = true
                end
            end
            if not restored_settings then
            local min_settings_w = horizontal_margin + 150 + COL_SPACING + SYM_BOX_WIDTH + COL_SPACING + TYPE_BTN_WIDTH + COL_SPACING + REPL_COL_WIDTH + COL_SPACING + checkbox_size + COL_SPACING + checkbox_size + COL_SPACING + checkbox_size + horizontal_margin
            local settings_w = math.max(min_settings_w, 660)
            local settings_h = math.min(MAX_WINDOW_HEIGHT, 900)
            local need_resize = false
            if gfx.w < settings_w then gui.width = settings_w; need_resize = true end
            if gfx.h < settings_h then gui.height = settings_h; need_resize = true end
            if need_resize then
                if window_script then
                    reaper.JS_Window_Resize(window_script, gui.width, gui.height)
                else
                    local _, wx, wy = gfx.dock(-1, 0, 0, 0, 0)
                    gfx.init(SCRIPT_TITLE, gui.width, gui.height, gui.settings.docker_id, wx, wy)
                end
            end
            end
        end

        -- Fold header click (row 0)
        local vis_idx = 0
        local main_click_handled = false
        local extras = get_visible_extra_settings()
        local main_clicked_sym_box = false
        local main_clicked_defpath_box = false
        do
            local hdr_scrolled = vis_idx - main_scroll_offset
            local hdr_y = header_height + vertical_margin + hdr_scrolled * checkbox_row_height
            if hdr_scrolled >= 0 and (not main_needs_scroll or hdr_scrolled < main_display_rows) and
               mouse_y >= hdr_y and mouse_y < hdr_y + checkbox_row_height and
               mouse_x >= horizontal_margin and mouse_x < gfx.w - horizontal_margin then
                main_settings_folded = not main_settings_folded
                save_fold_state()
                main_click_handled = true
            end
            vis_idx = vis_idx + 1
        end

        -- Checkboxes (vertical layout - aligned, filtered by show_in_menu)
        if not main_settings_folded and not main_click_handled then
        for i, cb in ipairs(checkboxes_list) do
            if cb.show_in_menu ~= false then
                local scrolled_i = vis_idx - main_scroll_offset
                local cb_x = gfx.w - horizontal_margin - checkbox_size
                local cb_y = header_height + vertical_margin + scrolled_i * checkbox_row_height
                if scrolled_i >= 0 and (not main_needs_scroll or scrolled_i < main_display_rows) and
                   mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
                   mouse_y > cb_y and mouse_y < cb_y + checkbox_size then
                    -- Handle mutually exclusive checkboxes for insertion modes (indices 5, 6, 7)
                    if i >= 5 and i <= 7 then
                        -- Uncheck other insertion mode options
                        for j = 5, 7 do
                            checkboxes_list[j].checked = false
                        end
                        -- Check the clicked one
                        checkboxes_list[i].checked = true
                    else
                        -- Regular toggle for other options
                        checkboxes_list[i].checked = not checkboxes_list[i].checked
                    end
                    main_click_handled = true
                    break
                end
                vis_idx = vis_idx + 1
            end
        end
        end -- end if not folded and not clicked

        -- Extra settings (from M flags) - full-featured for articulations
        if not main_settings_folded and not main_click_handled then
        for j, item in ipairs(extras) do
            local scrolled_j = vis_idx - main_scroll_offset
            local cb_y = header_height + vertical_margin + scrolled_j * checkbox_row_height
            local row_vis = scrolled_j >= 0 and (not main_needs_scroll or scrolled_j < main_display_rows)
            if row_vis and item.is_art then
                local art_name = item.key
                local art_i = item.art_index
                -- Column positions matching draw code
                local m_cb_x = gfx.w - horizontal_margin - checkbox_size
                local m_prefix_cb_x = m_cb_x - COL_SPACING - checkbox_size
                local m_repl_col_x = m_prefix_cb_x - COL_SPACING - REPL_COL_WIDTH
                local m_repl_cb_x = m_repl_col_x + math.floor((REPL_COL_WIDTH - checkbox_size) / 2)
                local m_type_btn_x = m_repl_col_x - COL_SPACING - TYPE_BTN_WIDTH
                local m_sym_box_x = m_type_btn_x - COL_SPACING - SYM_BOX_WIDTH
                local m_name_max_w = m_sym_box_x - horizontal_margin - COL_SPACING

                if mouse_y > cb_y and mouse_y < cb_y + checkbox_size then
                    -- Enabled checkbox
                    if mouse_x > m_cb_x and mouse_x < m_cb_x + checkbox_size then
                        articulation_enabled[art_name] = not articulation_enabled[art_name]
                        break
                    end
                    -- Prefix checkbox
                    if mouse_x > m_prefix_cb_x and mouse_x < m_prefix_cb_x + checkbox_size then
                        local current_no_prefix = get_art_no_prefix(art_name)
                        local new_val = not current_no_prefix
                        if new_val ~= articulation_default_no_prefix[art_name] then
                            articulation_no_prefix_override[art_name] = new_val
                        else
                            articulation_no_prefix_override[art_name] = nil
                        end
                        break
                    end
                    -- Replace fret checkbox
                    if mouse_x > m_repl_cb_x and mouse_x < m_repl_cb_x + checkbox_size then
                        local current_rf = get_art_replaces_fret(art_name)
                        local new_val = not current_rf
                        if new_val ~= articulation_default_replaces_fret[art_name] then
                            articulation_replaces_fret_override[art_name] = new_val
                        else
                            articulation_replaces_fret_override[art_name] = nil
                        end
                        break
                    end
                    -- Type button -> dropdown
                    if mouse_x > m_type_btn_x and mouse_x < m_type_btn_x + TYPE_BTN_WIDTH then
                        local current_type = get_art_type(art_name)
                        local menu_str = ""
                        for jj, v in ipairs(art_type_values) do
                            if jj > 1 then menu_str = menu_str .. "|" end
                            if v == current_type then menu_str = menu_str .. "!" end
                            menu_str = menu_str .. art_type_labels[v]
                        end
                        local captured_art_name = art_name
                        open_dark_menu(menu_str, m_type_btn_x, cb_y + checkbox_size, function(choice)
                            if choice > 0 then
                                local new_type = art_type_values[choice]
                                if new_type ~= articulation_default_type[captured_art_name] then
                                    articulation_type_override[captured_art_name] = new_type
                                else
                                    articulation_type_override[captured_art_name] = nil
                                end
                            end
                        end)
                        break
                    end
                    -- Symbol box -> text editing
                    if mouse_x > m_sym_box_x and mouse_x < m_sym_box_x + SYM_BOX_WIDTH then
                        if main_sym_edit_active and main_sym_edit_index and main_sym_edit_index ~= art_i then
                            local prev_name = articulation_names_ordered[main_sym_edit_index]
                            if main_sym_edit_text ~= articulation_default_symbol[prev_name] then
                                articulation_symbol_override[prev_name] = main_sym_edit_text
                            else
                                articulation_symbol_override[prev_name] = nil
                            end
                        end
                        main_sym_edit_active = true
                        main_sym_edit_index = art_i
                        main_sym_edit_text = get_art_symbol(art_name)
                        main_sym_edit_cursor = #main_sym_edit_text
                        main_clicked_sym_box = true
                        break
                    end
                    -- Name click -> write/remove text event
                    if mouse_x > horizontal_margin and mouse_x < m_sym_box_x - COL_SPACING then
                        local is_alt = (gfx.mouse_cap & 16) ~= 0
                        local takes = {}
                        local num_items = reaper.CountSelectedMediaItems(0)
                        if num_items > 0 then
                            for mi = 0, num_items - 1 do
                                local sel_item = reaper.GetSelectedMediaItem(0, mi)
                                local take = sel_item and reaper.GetActiveTake(sel_item)
                                if take and reaper.TakeIsMIDI(take) then
                                    table.insert(takes, take)
                                end
                            end
                        end
                        if #takes == 0 then
                            local me = reaper.MIDIEditor_GetActive()
                            if me then
                                local take = reaper.MIDIEditor_GetTake(me)
                                if take and reaper.TakeIsMIDI(take) then
                                    table.insert(takes, take)
                                end
                            end
                        end
                        if #takes == 0 then
                            local total_items = reaper.CountMediaItems(0)
                            for mi = 0, total_items - 1 do
                                local any_item = reaper.GetMediaItem(0, mi)
                                local take = any_item and reaper.GetActiveTake(any_item)
                                if take and reaper.TakeIsMIDI(take) then
                                    local _, note_count = reaper.MIDI_CountEvts(take)
                                    for ni = 0, note_count - 1 do
                                        local _, sel = reaper.MIDI_GetNote(take, ni)
                                        if sel then
                                            table.insert(takes, take)
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        if is_alt then
                            if #takes > 0 then
                                reaper.Undo_BeginBlock()
                                local total_removed = 0
                                for _, take in ipairs(takes) do
                                    local _, note_count = reaper.MIDI_CountEvts(take)
                                    local sel_ppqs = {}
                                    local has_selected = false
                                    for ni = 0, note_count - 1 do
                                        local _, sel, _, startppq = reaper.MIDI_GetNote(take, ni)
                                        if sel then
                                            sel_ppqs[startppq] = true
                                            has_selected = true
                                        end
                                    end
                                    local _, _, _, text_count = reaper.MIDI_CountEvts(take)
                                    for ti = text_count - 1, 0, -1 do
                                        local _, _, _, ppqpos, _, msg = reaper.MIDI_GetTextSysexEvt(take, ti)
                                        if msg and #msg > 0 and (not has_selected or sel_ppqs[ppqpos]) then
                                            local matched = match_text_to_articulation(msg)
                                            if matched == art_name then
                                                reaper.MIDI_DeleteTextSysexEvt(take, ti)
                                                total_removed = total_removed + 1
                                            end
                                        end
                                    end
                                    reaper.MIDI_Sort(take)
                                end
                                reaper.Undo_EndBlock("Remove articulation: " .. art_name, -1)
                                last_midi_scan_sel_hash = ""
                            end
                        else
                            local sym_template = get_art_symbol(art_name)
                            local user_text = nil
                            if sym_template and sym_template:find("%%s") then
                                local dlg_title = "Enter " .. art_name .. " text"
                                local mx, my = reaper.GetMousePosition()
                                local dlg_retries = 0
                                local dlg_moved = false
                                local function move_dlg()
                                    if dlg_moved then return end
                                    dlg_retries = dlg_retries + 1
                                    if dlg_retries > 50 then return end
                                    local hwnd = reaper.JS_Window_Find(dlg_title, true)
                                    if not hwnd then
                                        local fg = reaper.JS_Window_GetForeground()
                                        if fg then
                                            local t = reaper.JS_Window_GetTitle(fg)
                                            if t == dlg_title then hwnd = fg end
                                        end
                                    end
                                    if hwnd then
                                        reaper.JS_Window_Move(hwnd, mx - 100, my - 40)
                                        dlg_moved = true
                                        return
                                    end
                                    reaper.defer(move_dlg)
                                end
                                reaper.defer(move_dlg)
                                local retval, input = reaper.GetUserInputs(
                                    dlg_title, 1,
                                    art_name .. ":,extrawidth=200", "")
                                if not retval or input == "" then
                                    break
                                end
                                user_text = input
                            end
                            if #takes > 0 then
                                reaper.Undo_BeginBlock()
                                local tuning = getActiveTuning()
                                local num_strings = #tuning
                                local total_written = 0
                                for _, take in ipairs(takes) do
                                    local _, note_count = reaper.MIDI_CountEvts(take)
                                    for ni = 0, note_count - 1 do
                                        local _, sel, _, startppq, _, chan, pitch = reaper.MIDI_GetNote(take, ni)
                                        if sel then
                                            local sym = get_art_symbol(art_name)
                                            local art_type = get_art_type(art_name)
                                            local no_prefix = get_art_no_prefix(art_name)
                                            if sym:find("%%d") or sym:find("%%h") then
                                                local channel_1based = chan + 1
                                                local string_num = (num_strings + 1) - channel_1based
                                                if string_num < 1 then string_num = 1 end
                                                if string_num > num_strings then string_num = num_strings end
                                                local tuning_idx = num_strings - string_num + 1
                                                local fret = pitch - (tuning[tuning_idx] or 0)
                                                if fret < 0 then fret = 0 end
                                                sym = sym:gsub("%%d", tostring(fret))
                                                sym = sym:gsub("%%h", tostring(fret + 12))
                                            end
                                            if user_text and sym:find("%%s") then
                                                sym = sym:gsub("%%s", user_text)
                                            end
                                            local text = sym
                                            if not no_prefix then text = "_" .. text end
                                            reaper.MIDI_InsertTextSysexEvt(take, false, false, startppq, art_type, text)
                                            total_written = total_written + 1
                                        end
                                    end
                                    reaper.MIDI_Sort(take)
                                end
                                reaper.Undo_EndBlock("Write articulation: " .. art_name, -1)
                                last_midi_scan_sel_hash = ""
                            end
                        end
                        break
                    end
                end
            elseif row_vis then
                -- Non-articulation extras with enhanced controls
                local mk = item.key
                local cb_x = gfx.w - horizontal_margin - checkbox_size

                if mk == "docker" or mk == "font" or mk == "midibank" or mk == "importpos" or mk == "timebase" or mk == "alignstem" or mk == "onsetitem" or mk == "tempofreq" or mk == "detectmethod" or mk == "detectitem" then
                    -- Calculate button bounds (same as drawing)
                    local lbl_w = gfx.measurestr(item.label .. "  ")
                    local btn_x = horizontal_margin + lbl_w
                    local btn_w
                    if mk == "font" or mk == "importpos" or mk == "timebase" or mk == "alignstem" or mk == "onsetitem" or mk == "tempofreq" or mk == "detectmethod" or mk == "detectitem" then
                        btn_w = gfx.w - horizontal_margin - btn_x
                    else
                        btn_w = cb_x - COL_SPACING - btn_x
                    end
                    if btn_w < 20 then btn_w = 20 end
                    -- Check checkbox click (docker/midibank only)
                    if mk ~= "font" and mk ~= "importpos" and mk ~= "timebase" and mk ~= "alignstem" and mk ~= "onsetitem" and mk ~= "tempofreq" and mk ~= "detectmethod" and mk ~= "detectitem" and mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
                       mouse_y > cb_y and mouse_y < cb_y + checkbox_size then
                        toggle_extra_setting(mk)
                        break
                    end
                    -- Check button click
                    if mouse_x >= btn_x and mouse_x < btn_x + btn_w and
                       mouse_y >= cb_y and mouse_y < cb_y + checkbox_size then
                        if mk == "docker" then
                            local menu_str = ""
                            for j, v in ipairs(docker_positions) do
                                if j > 1 then menu_str = menu_str .. "|" end
                                if j == docker_position then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. v
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    docker_position = choice
                                    if docker_enabled then
                                        gfx.dock(docker_dock_values[docker_position] or 1)
                                    end
                                end
                            end)
                        elseif mk == "font" then
                            local menu_str = ""
                            for j, v in ipairs(font_list) do
                                if j > 1 then menu_str = menu_str .. "|" end
                                if j == current_font_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. v
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    current_font_index = choice
                                    gfx.setfont(1, font_list[current_font_index], gui.settings.font_size)
                                end
                            end)
                        elseif mk == "importpos" then
                            local menu_str = ""
                            for j, v in ipairs(import_position_options) do
                                if j > 1 then menu_str = menu_str .. "|" end
                                if j == import_position_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. v
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    import_position_index = choice
                                end
                            end)
                        elseif mk == "timebase" then
                            local menu_str = ""
                            for j, v in ipairs(import_timebase_options) do
                                if j > 1 then menu_str = menu_str .. "|" end
                                if j == import_timebase_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. v
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    import_timebase_index = choice
                                end
                            end)
                        elseif mk == "alignstem" then
                            refresh_align_stem_items()
                            local menu_str = "Auto"
                            if align_stem_index == 0 then menu_str = "!Auto" end
                            for j, si in ipairs(align_stem_items) do
                                menu_str = menu_str .. "|"
                                if j == align_stem_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. si.name
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    align_stem_index = choice - 1
                                end
                            end)
                        elseif mk == "onsetitem" then
                            refresh_onset_item_items()
                            local menu_str = "Auto"
                            if onset_item_index == 0 then menu_str = "!Auto" end
                            for j, si in ipairs(onset_item_items) do
                                menu_str = menu_str .. "|"
                                if j == onset_item_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. si.name
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    onset_item_index = choice - 1
                                end
                            end)
                        elseif mk == "tempofreq" then
                            local menu_str = ""
                            for j, v in ipairs(tempo_map_freq_options) do
                                if j > 1 then menu_str = menu_str .. "|" end
                                if j == tempo_map_freq_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. v
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    tempo_map_freq_index = choice
                                end
                            end)
                        elseif mk == "detectmethod" then
                            local menu_str = ""
                            for j, v in ipairs(tempo_detect_method_options) do
                                if j > 1 then menu_str = menu_str .. "|" end
                                if j == tempo_detect_method_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. v
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    tempo_detect_method_index = choice
                                end
                            end)
                        elseif mk == "detectitem" then
                            refresh_detect_tempo_items()
                            local menu_str = "Selected Item"
                            if detect_tempo_item_index == 0 then menu_str = "!Selected Item" end
                            for j, si in ipairs(detect_tempo_item_items) do
                                menu_str = menu_str .. "|"
                                if j == detect_tempo_item_index then menu_str = menu_str .. "!" end
                                menu_str = menu_str .. si.name
                            end
                            open_dark_menu(menu_str, btn_x, cb_y + checkbox_size, function(choice)
                                if choice > 0 then
                                    detect_tempo_item_index = choice - 1
                                end
                            end)
                        elseif mk == "midibank" then
                            local menu_str = ""
                            for mi, p in ipairs(gm_presets) do
                                if mi > 1 then menu_str = menu_str .. "|" end
                                menu_str = menu_str .. p.name
                            end
                            open_dark_menu(menu_str, mouse_x, mouse_y, function(choice)
                                if choice > 0 then
                                    local actual_items = {}
                                    for _, p in ipairs(gm_presets) do
                                        if p.name:sub(1,1) ~= ">" and p.name:sub(1,1) ~= "<" then
                                            table.insert(actual_items, p)
                                        else
                                            local clean = p.name:gsub("^[<>]", "")
                                            table.insert(actual_items, {name = clean, program = p.program})
                                        end
                                    end
                                    local selected_preset = actual_items[choice]
                                    if selected_preset then
                                        local num_items = reaper.CountSelectedMediaItems(0)
                                        if num_items > 0 then
                                            reaper.Undo_BeginBlock()
                                            for ii = 0, num_items - 1 do
                                                local sel_item = reaper.GetSelectedMediaItem(0, ii)
                                                local take = reaper.GetActiveTake(sel_item)
                                                if take and reaper.TakeIsMIDI(take) then
                                                    local _, cc_count = reaper.MIDI_CountEvts(take)
                                                    for ci = cc_count - 1, 0, -1 do
                                                        local _, _, _, ppqpos, _, _, cc_num = reaper.MIDI_GetCC(take, ci)
                                                        if ppqpos == 0 and (cc_num == 0 or cc_num == 32) then
                                                            reaper.MIDI_DeleteCC(take, ci)
                                                        end
                                                    end
                                                    local gotAllOK, MIDIstring = reaper.MIDI_GetAllEvts(take, "")
                                                    if gotAllOK then
                                                        local MIDIlen = MIDIstring:len()
                                                        local tableEvents = {}
                                                        local stringPos = 1
                                                        local abs_pos = 0
                                                        while stringPos < MIDIlen do
                                                            local offset, flags, msg, newPos = string.unpack("i4Bs4", MIDIstring, stringPos)
                                                            abs_pos = abs_pos + offset
                                                            local dominated = false
                                                            if abs_pos == 0 and msg:len() >= 1 then
                                                                local status = msg:byte(1)
                                                                if (status >> 4) == 0xC then dominated = true end
                                                            end
                                                            if not dominated then
                                                                table.insert(tableEvents, string.pack("i4Bs4", offset, flags, msg))
                                                            end
                                                            stringPos = newPos
                                                        end
                                                        reaper.MIDI_SetAllEvts(take, table.concat(tableEvents))
                                                    end
                                                    local ch = 0
                                                    reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 0, 0)
                                                    reaper.MIDI_InsertCC(take, false, false, 0, 0xB0, ch, 32, 0)
                                                    reaper.MIDI_InsertCC(take, false, false, 0, 0xC0, ch, selected_preset.program, 0)
                                                    reaper.MIDI_Sort(take)
                                                end
                                            end
                                            reaper.Undo_EndBlock("Set MIDI Program", -1)
                                        end
                                    end
                                end
                            end)
                        end
                        break
                    end
                elseif mk == "defpath" then
                    -- Check checkbox click
                    if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
                       mouse_y > cb_y and mouse_y < cb_y + checkbox_size then
                        toggle_extra_setting(mk)
                        break
                    end
                    -- Check text box click
                    local lbl_w = gfx.measurestr(item.label .. "  ")
                    local box_x = horizontal_margin + lbl_w
                    local box_w = cb_x - COL_SPACING - box_x
                    if box_w < 20 then box_w = 20 end
                    if mouse_x >= box_x and mouse_x < box_x + box_w and
                       mouse_y >= cb_y and mouse_y < cb_y + checkbox_size then
                        main_defpath_edit_active = true
                        main_defpath_edit_text = default_import_dir
                        main_defpath_edit_cursor = #default_import_dir
                        main_defpath_edit_sel = -1
                        main_clicked_defpath_box = true
                        break
                    end
                else
                    -- Default simple checkbox
                    if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
                       mouse_y > cb_y and mouse_y < cb_y + checkbox_size then
                        toggle_extra_setting(mk)
                        break
                    end
                end
            end
            vis_idx = vis_idx + 1
        end
        end -- end if not main_settings_folded

        -- Commit main view symbol edit when clicking outside
        if not main_clicked_sym_box and main_sym_edit_active then
            local art_name = articulation_names_ordered[main_sym_edit_index]
            if main_sym_edit_text ~= articulation_default_symbol[art_name] then
                articulation_symbol_override[art_name] = main_sym_edit_text
            else
                articulation_symbol_override[art_name] = nil
            end
            main_sym_edit_active = false
            main_sym_edit_index = nil
        end

        -- Commit main view default path edit when clicking outside
        if not main_clicked_defpath_box and main_defpath_edit_active then
            default_import_dir = main_defpath_edit_text
            save_default_import_dir(main_defpath_edit_text)
            main_defpath_edit_active = false
        end

        -- Track checkboxes (only visible when file is loaded)
        if #track_checkboxes > 0 then
            local track_section_y = file_info_y + file_info_height + vertical_margin
            local cb_x = gfx.w - horizontal_margin - checkbox_size

            -- "Import All" checkbox
            local all_y = track_section_y
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
               mouse_y > all_y and mouse_y < all_y + checkbox_size then
                import_all_checked = not import_all_checked
                for _, tcb in ipairs(track_checkboxes) do
                    tcb.checked = import_all_checked
                end
                if highlight_scan_enabled then scan_articulations_in_xml() end
            else
                -- Individual track checkboxes (account for scroll offset)
                local tracks_area_top = track_section_y + checkbox_row_height
                local tracks_area_bottom = btn_y - 10
                local tracks_area_height = tracks_area_bottom - tracks_area_top
                local max_visible_tracks = math.floor(tracks_area_height / checkbox_row_height)
                
                for i, tcb in ipairs(track_checkboxes) do
                    local scrolled_i = i - track_scroll_offset
                    if scrolled_i >= 1 and scrolled_i <= max_visible_tracks then
                        local tcb_y = tracks_area_top + (scrolled_i - 1) * checkbox_row_height
                        if mouse_y > tcb_y and mouse_y < tcb_y + checkbox_size then
                            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                                -- Checkbox area: toggle
                                tcb.checked = not tcb.checked
                                local all_checked = true
                                for _, t in ipairs(track_checkboxes) do
                                    if not t.checked then all_checked = false; break end
                                end
                                import_all_checked = all_checked
                                if highlight_scan_enabled then scan_articulations_in_xml() end
                                break
                            elseif mouse_x >= horizontal_margin and mouse_x < cb_x and selected_file_path then
                                -- Label area: check for double-click → import at edit cursor
                                local now = os.clock()
                                if track_drag.last_click_index == i and (now - track_drag.last_click_time) < 0.4 then
                                    -- Double-click: import this track at edit cursor
                                    track_drag.last_click_index = nil
                                    track_drag.last_click_time = 0
                                    local track_name = get_track_display_name(tcb)
                                    local saved_autoload = autoload_region_start_pos
                                    autoload_region_start_pos = reaper.GetCursorPosition()
                                    local options = {
                                        import_markers = false,
                                        import_regions = false,
                                        import_midi_banks = checkboxes_list[3].checked,
                                        import_key_sigs = false,
                                        insert_on_new_tracks = false,
                                        insert_on_existing_tracks = false,
                                        insert_on_tracks_by_name = true,
                                        selected_tracks = { track_name }
                                    }
                                    local pre_import_state = capture_pre_import_state()
                                    ImportMusicXMLWithOptions(selected_file_path, options)
                                    capture_post_import_history(pre_import_state, selected_file_path)
                                    autoload_region_start_pos = saved_autoload
                                    break
                                else
                                    -- First click: record for double-click and start drag
                                    track_drag.last_click_index = i
                                    track_drag.last_click_time = now
                                    track_drag.active = true
                                    track_drag.track_index = i
                                    track_drag.start_x = mouse_x
                                    track_drag.start_y = mouse_y
                                    track_drag.confirmed = false
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Handle mousewheel for settings area scroll + type buttons on art rows
    if gfx.mouse_wheel ~= 0 and not dark_menu.active and not gui_msgbox.active then
        -- Main settings area scroll
        local settings_area_bottom = settings_area_top + main_display_rows * checkbox_row_height
        if main_needs_scroll and mouse_y >= settings_area_top and mouse_y < settings_area_bottom then
            local mw_handled_scroll = false
            -- Check art row type buttons first (they consume mousewheel too)
            local mw_extras = get_visible_extra_settings()
            local mw_vis_idx = 1 -- row 0 is fold header
            for _, cb in ipairs(checkboxes_list) do
                if cb.show_in_menu ~= false then mw_vis_idx = mw_vis_idx + 1 end
            end
            if not main_settings_folded then
            for _, mw_item in ipairs(mw_extras) do
                local mw_scrolled = mw_vis_idx - main_scroll_offset
                local mw_cb_y = header_height + vertical_margin + mw_scrolled * checkbox_row_height
                if mw_scrolled >= 0 and mw_scrolled < main_display_rows and mw_item.is_art then
                    local m_cb_x = gfx.w - horizontal_margin - checkbox_size
                    local m_prefix_cb_x = m_cb_x - COL_SPACING - checkbox_size
                    local m_repl_col_x = m_prefix_cb_x - COL_SPACING - REPL_COL_WIDTH
                    local m_type_btn_x = m_repl_col_x - COL_SPACING - TYPE_BTN_WIDTH
                    if mouse_x > m_type_btn_x and mouse_x < m_type_btn_x + TYPE_BTN_WIDTH and
                       mouse_y > mw_cb_y and mouse_y < mw_cb_y + checkbox_size then
                        mw_handled_scroll = true
                    end
                end
                if mw_scrolled >= 0 and mw_scrolled < main_display_rows and
                   (mw_item.key == "docker" or mw_item.key == "font" or mw_item.key == "importpos" or mw_item.key == "timebase" or mw_item.key == "alignstem" or mw_item.key == "onsetitem" or mw_item.key == "tempofreq" or mw_item.key == "detectmethod" or mw_item.key == "detectitem") then
                    local lbl_w = gfx.measurestr(mw_item.label .. "  ")
                    local btn_x = horizontal_margin + lbl_w
                    local m_cb_x = gfx.w - horizontal_margin - checkbox_size
                    local btn_w = (mw_item.key == "font" or mw_item.key == "importpos" or mw_item.key == "timebase" or mw_item.key == "alignstem" or mw_item.key == "onsetitem" or mw_item.key == "tempofreq" or mw_item.key == "detectmethod" or mw_item.key == "detectitem") and (gfx.w - horizontal_margin - btn_x) or (m_cb_x - COL_SPACING - btn_x)
                    if btn_w < 20 then btn_w = 20 end
                    if mouse_x >= btn_x and mouse_x < btn_x + btn_w and
                       mouse_y >= mw_cb_y and mouse_y < mw_cb_y + checkbox_size then
                        mw_handled_scroll = true
                    end
                end
                mw_vis_idx = mw_vis_idx + 1
            end
            end -- end if not main_settings_folded
            if not mw_handled_scroll then
                local scroll_delta = -math.floor(gfx.mouse_wheel / 120)
                main_scroll_offset = main_scroll_offset + scroll_delta
                if main_scroll_offset < 0 then main_scroll_offset = 0 end
                if main_scroll_offset > max_main_scroll then main_scroll_offset = max_main_scroll end
                gfx.mouse_wheel = 0
            end
        end
    end

    -- Handle mousewheel for type buttons on art rows in main view
    if gfx.mouse_wheel ~= 0 and not dark_menu.active and not gui_msgbox.active then
        local mw_extras = get_visible_extra_settings()
        local mw_vis_idx = 1 -- row 0 is fold header
        for _, cb in ipairs(checkboxes_list) do
            if cb.show_in_menu ~= false then mw_vis_idx = mw_vis_idx + 1 end
        end
        local mw_handled = false
        if not main_settings_folded then
        for _, mw_item in ipairs(mw_extras) do
            local mw_scrolled = mw_vis_idx - main_scroll_offset
            local mw_cb_y = header_height + vertical_margin + mw_scrolled * checkbox_row_height
            if mw_scrolled >= 0 and (not main_needs_scroll or mw_scrolled < main_display_rows) and mw_item.is_art then
                local m_cb_x = gfx.w - horizontal_margin - checkbox_size
                local m_prefix_cb_x = m_cb_x - COL_SPACING - checkbox_size
                local m_repl_col_x = m_prefix_cb_x - COL_SPACING - REPL_COL_WIDTH
                local m_type_btn_x = m_repl_col_x - COL_SPACING - TYPE_BTN_WIDTH
                if mouse_x > m_type_btn_x and mouse_x < m_type_btn_x + TYPE_BTN_WIDTH and
                   mouse_y > mw_cb_y and mouse_y < mw_cb_y + checkbox_size then
                    local current_type = get_art_type(mw_item.key)
                    local current_idx = 1
                    for j, v in ipairs(art_type_values) do
                        if v == current_type then current_idx = j; break end
                    end
                    local delta = gfx.mouse_wheel > 0 and -1 or 1
                    current_idx = current_idx + delta
                    if current_idx < 1 then current_idx = #art_type_values end
                    if current_idx > #art_type_values then current_idx = 1 end
                    local new_type = art_type_values[current_idx]
                    if new_type ~= articulation_default_type[mw_item.key] then
                        articulation_type_override[mw_item.key] = new_type
                    else
                        articulation_type_override[mw_item.key] = nil
                    end
                    mw_handled = true
                    break
                end
            elseif mw_scrolled >= 0 and (not main_needs_scroll or mw_scrolled < main_display_rows) and
                   (mw_item.key == "docker" or mw_item.key == "font" or mw_item.key == "importpos" or mw_item.key == "timebase" or mw_item.key == "alignstem" or mw_item.key == "onsetitem" or mw_item.key == "tempofreq" or mw_item.key == "detectmethod" or mw_item.key == "detectitem") then
                local lbl_w = gfx.measurestr(mw_item.label .. "  ")
                local btn_x = horizontal_margin + lbl_w
                local m_cb_x = gfx.w - horizontal_margin - checkbox_size
                local btn_w
                if mw_item.key == "font" or mw_item.key == "importpos" or mw_item.key == "timebase" or mw_item.key == "alignstem" or mw_item.key == "onsetitem" or mw_item.key == "tempofreq" or mw_item.key == "detectmethod" or mw_item.key == "detectitem" then
                    btn_w = gfx.w - horizontal_margin - btn_x
                else
                    btn_w = m_cb_x - COL_SPACING - btn_x
                end
                if btn_w < 20 then btn_w = 20 end
                if mouse_x >= btn_x and mouse_x < btn_x + btn_w and
                   mouse_y >= mw_cb_y and mouse_y < mw_cb_y + checkbox_size then
                    local delta = gfx.mouse_wheel > 0 and -1 or 1
                    if mw_item.key == "docker" then
                        docker_position = docker_position + delta
                        if docker_position < 1 then docker_position = #docker_positions end
                        if docker_position > #docker_positions then docker_position = 1 end
                        if docker_enabled then
                            gfx.dock(docker_dock_values[docker_position] or 1)
                        end
                    elseif mw_item.key == "importpos" then
                        import_position_index = import_position_index + delta
                        if import_position_index < 1 then import_position_index = #import_position_options end
                        if import_position_index > #import_position_options then import_position_index = 1 end
                    elseif mw_item.key == "timebase" then
                        import_timebase_index = import_timebase_index + delta
                        if import_timebase_index < 1 then import_timebase_index = #import_timebase_options end
                        if import_timebase_index > #import_timebase_options then import_timebase_index = 1 end
                    elseif mw_item.key == "alignstem" then
                        refresh_align_stem_items()
                        local max_idx = #align_stem_items
                        align_stem_index = align_stem_index + delta
                        if align_stem_index < 0 then align_stem_index = max_idx end
                        if align_stem_index > max_idx then align_stem_index = 0 end
                    elseif mw_item.key == "onsetitem" then
                        refresh_onset_item_items()
                        local max_idx = #onset_item_items
                        onset_item_index = onset_item_index + delta
                        if onset_item_index < 0 then onset_item_index = max_idx end
                        if onset_item_index > max_idx then onset_item_index = 0 end
                    elseif mw_item.key == "tempofreq" then
                        tempo_map_freq_index = tempo_map_freq_index + delta
                        if tempo_map_freq_index < 1 then tempo_map_freq_index = #tempo_map_freq_options end
                        if tempo_map_freq_index > #tempo_map_freq_options then tempo_map_freq_index = 1 end
                    elseif mw_item.key == "detectmethod" then
                        tempo_detect_method_index = tempo_detect_method_index + delta
                        if tempo_detect_method_index < 1 then tempo_detect_method_index = #tempo_detect_method_options end
                        if tempo_detect_method_index > #tempo_detect_method_options then tempo_detect_method_index = 1 end
                    elseif mw_item.key == "detectitem" then
                        refresh_detect_tempo_items()
                        detect_tempo_item_index = detect_tempo_item_index + delta
                        if detect_tempo_item_index < 0 then detect_tempo_item_index = #detect_tempo_item_items end
                        if detect_tempo_item_index > #detect_tempo_item_items then detect_tempo_item_index = 0 end
                    else
                        current_font_index = current_font_index + delta
                        if current_font_index < 1 then current_font_index = #font_list end
                        if current_font_index > #font_list then current_font_index = 1 end
                        gfx.setfont(1, font_list[current_font_index], gui.settings.font_size)
                    end
                    mw_handled = true
                    break
                end
            end
            mw_vis_idx = mw_vis_idx + 1
        end
        end -- end if not main_settings_folded

        if mw_handled then gfx.mouse_wheel = 0 end
    end

    -- Handle mousewheel scrolling for track list
    if #track_checkboxes > 0 and gfx.mouse_wheel ~= 0 then
        local track_section_y = file_info_y + file_info_height + vertical_margin
        local tracks_area_top = track_section_y + checkbox_row_height
        local tracks_area_bottom = btn_y - 10
        -- Only scroll when mouse is over the track list area
        if mouse_y >= tracks_area_top and mouse_y <= tracks_area_bottom then
            local scroll_delta = -math.floor(gfx.mouse_wheel / 120)
            track_scroll_offset = track_scroll_offset + scroll_delta
            local tracks_area_height = tracks_area_bottom - tracks_area_top
            local max_visible_tracks = math.floor(tracks_area_height / checkbox_row_height)
            local max_scroll = math.max(0, #track_checkboxes - max_visible_tracks)
            if track_scroll_offset < 0 then track_scroll_offset = 0 end
            if track_scroll_offset > max_scroll then track_scroll_offset = max_scroll end
        end
        gfx.mouse_wheel = 0
    end

    -- Hover states for buttons
    import_btn_hovered = (mouse_x > import_btn_x and mouse_x < import_btn_x + btn_width and
                          mouse_y > import_btn_y and mouse_y < import_btn_y + btn_height)
    export_btn_hovered = (mouse_x > export_btn_x and mouse_x < export_btn_x + btn_width and
                          mouse_y > export_btn_y and mouse_y < export_btn_y + btn_height)
    undo_btn_hovered = (mouse_x > undo_btn_x and mouse_x < undo_btn_x + btn_width and
                        mouse_y > undo_btn_y and mouse_y < undo_btn_y + btn_height)
    settings_btn_hovered = (mouse_x > settings_btn_x and mouse_x < settings_btn_x + btn_width and
                            mouse_y > settings_btn_y and mouse_y < settings_btn_y + btn_height)
    cancel_btn_hovered = (mouse_x > cancel_btn_x and mouse_x < cancel_btn_x + btn_width and
                          mouse_y > cancel_btn_y and mouse_y < cancel_btn_y + btn_height)
    
    -- Button tooltips
    if import_btn_hovered then
        pending_tooltip = "Import the selected MusicXML file\ninto the project using current settings."
    elseif export_btn_hovered then
        pending_tooltip = "Export selected MIDI items to\na MusicXML file."
    elseif undo_btn_hovered then
        pending_tooltip = "Undo the last import operation\n(removes imported items, tempo, and regions)."
    elseif settings_btn_hovered then
        pending_tooltip = "Open settings to configure import/export\noptions, articulations, and preferences."
    elseif cancel_btn_hovered then
        pending_tooltip = "Close the script window."
    end
    
    -- Periodic MIDI articulation scan (when art rows visible in main view)
    local main_extras = get_visible_extra_settings()
    local main_has_art_rows = false
    for _, ei in ipairs(main_extras) do
        if ei.is_art then main_has_art_rows = true; break end
    end
    if main_has_art_rows and highlight_scan_enabled then
        local hash = compute_selection_hash()
        if hash ~= last_midi_scan_sel_hash then
            last_midi_scan_sel_hash = hash
            scan_articulations_in_xml()
            scan_articulations_in_midi()
        end
    end

    -- Draw all UI elements using modular functions
    pending_tooltip = nil  -- clear tooltip each frame
    draw_header("IMPORT MUSICXML", header_height, gui.colors)
    draw_checkboxes_list(checkboxes_list, header_height, horizontal_margin, vertical_margin, 
                        checkbox_row_height, checkbox_size, max_label_width, gui.colors,
                        main_scroll_offset, main_needs_scroll and main_display_rows or nil)
    
    -- Draw main settings scrollbar if needed
    if main_needs_scroll then
        local sb_width = 8
        local sb_x = gfx.w - sb_width - 4
        local sb_top = settings_area_top
        local sb_track_h = main_display_rows * checkbox_row_height
        local thumb_h = math.max(20, math.floor(sb_track_h * main_display_rows / visible_checkboxes))
        local thumb_y = sb_top + math.floor((sb_track_h - thumb_h) * main_scroll_offset / max_main_scroll)
        -- Track
        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(sb_x, sb_top, sb_width, sb_track_h, 1)
        -- Thumb
        gfx.set(0.4, 0.4, 0.4, 1)
        gfx.rect(sb_x, thumb_y, sb_width, thumb_h, 1)
    end
    
    -- Cover area below settings rows (above file info) to hide partially-drawn scrolled content
    if main_needs_scroll then
        local clear_r = (gfx.clear & 0xFF) / 255
        local clear_g = ((gfx.clear >> 8) & 0xFF) / 255
        local clear_b = ((gfx.clear >> 16) & 0xFF) / 255
        gfx.set(clear_r, clear_g, clear_b, 1)
        local cover_y = settings_area_top + main_display_rows * checkbox_row_height
        local cover_h = file_info_y - cover_y
        if cover_h > 0 then
            gfx.rect(0, cover_y, gfx.w, cover_h, 1)
        end
    end
    
    draw_file_info(file_info_y, file_info_height, selected_file_name, selected_file_track_count, gui.colors, file_info_hovered, is_drag_over_file_info)
    
    -- Draw track checkboxes section (after file info)
    if #track_checkboxes > 0 then
        local track_section_y = file_info_y + file_info_height + vertical_margin
        local cb_x = gfx.w - horizontal_margin - checkbox_size
        
        -- Draw "Import All" checkbox (always visible, not scrolled)
        local trunc_w = cb_x - horizontal_margin - 5
        draw_checkbox(cb_x, track_section_y, checkbox_size, horizontal_margin,
                      "Import All", import_all_checked, gui.colors, trunc_w, "import_all")
        
        -- Draw separator line after "Import All"
        local line_y = track_section_y + checkbox_size + math.floor((checkbox_row_height - checkbox_size) / 2)
        gfx.set(table.unpack(gui.colors.BORDER))
        gfx.line(horizontal_margin, line_y, gfx.w - horizontal_margin, line_y)
        
        -- Calculate visible area for track list (between separator and buttons)
        local tracks_area_top = track_section_y + checkbox_row_height
        local tracks_area_bottom = btn_y - 10
        local tracks_area_height = tracks_area_bottom - tracks_area_top
        local max_visible_tracks = math.floor(tracks_area_height / checkbox_row_height)
        local total_tracks = #track_checkboxes
        local max_scroll = math.max(0, total_tracks - max_visible_tracks)
        
        -- Clamp scroll offset
        if track_scroll_offset > max_scroll then track_scroll_offset = max_scroll end
        if track_scroll_offset < 0 then track_scroll_offset = 0 end
        
        -- Draw visible track checkboxes with clipping
        for i, tcb in ipairs(track_checkboxes) do
            local scrolled_i = i - track_scroll_offset
            if scrolled_i >= 1 and scrolled_i <= max_visible_tracks then
                local tcb_y = tracks_area_top + (scrolled_i - 1) * checkbox_row_height
                -- Hover highlight on label area (draggable indicator)
                if not track_drag.active and selected_file_path
                       and mouse_x >= horizontal_margin and mouse_x < cb_x
                       and mouse_y >= tcb_y and mouse_y < tcb_y + checkbox_size then
                    gfx.set(0.17, 0.45, 0.39, 0.12)
                    gfx.rect(horizontal_margin, tcb_y, cb_x - horizontal_margin, checkbox_size, 1)
                    if not pending_tooltip then
                        pending_tooltip = "Drag to arrange view or double-click to import at edit cursor"
                    end
                end
                draw_checkbox(cb_x, tcb_y, checkbox_size, horizontal_margin,
                              get_track_display_name(tcb), tcb.checked, gui.colors, trunc_w, "track_" .. i)
            end
        end
        
        -- Draw scrollbar if needed
        if total_tracks > max_visible_tracks then
            local scrollbar_width = 8
            local scrollbar_x = gfx.w - scrollbar_width - 4
            local scrollbar_track_height = tracks_area_height
            local thumb_height = math.max(20, math.floor(scrollbar_track_height * max_visible_tracks / total_tracks))
            local thumb_y = tracks_area_top + math.floor((scrollbar_track_height - thumb_height) * track_scroll_offset / max_scroll)
            
            -- Scrollbar track
            gfx.set(0.15, 0.15, 0.15, 1)
            gfx.rect(scrollbar_x, tracks_area_top, scrollbar_width, scrollbar_track_height, 1)
            -- Scrollbar thumb
            gfx.set(0.4, 0.4, 0.4, 1)
            gfx.rect(scrollbar_x, thumb_y, scrollbar_width, thumb_height, 1)
        end
    end

    -- Draw buttons (Import, Export, Undo, Settings, and Cancel)
    draw_button(import_btn_x, import_btn_y, btn_width, btn_height, "Import",
                import_btn_hovered, "IMPORT_BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(export_btn_x, export_btn_y, btn_width, btn_height, "Export",
                export_btn_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(undo_btn_x, undo_btn_y, btn_width, btn_height, "Undo",
                undo_btn_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(settings_btn_x, settings_btn_y, btn_width, btn_height, "Settings",
                settings_btn_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(cancel_btn_x, cancel_btn_y, btn_width, btn_height, "Cancel",
                cancel_btn_hovered, "CLOSE_BTN", gui.colors.BORDER, gui.colors.TEXT)

    -- Draw "Exported!" confirmation label above the Export button
    if os.clock() < export_confirmed_until then
        gfx.set(0.3, 0.85, 0.5, 1)  -- green
        local exported_text = "Exported!"
        local ew = gfx.measurestr(exported_text)
        gfx.x = export_btn_x + (btn_width - ew) / 2
        gfx.y = export_btn_y - gfx.texth - 4
        gfx.drawstr(exported_text)
    end

    -- Handle keyboard input for main view symbol editing
    if main_sym_edit_active and char_input and not gui_msgbox.active then
        if char_input == 8 then  -- Backspace
            if main_sym_edit_cursor > 0 then
                main_sym_edit_text = main_sym_edit_text:sub(1, main_sym_edit_cursor - 1) .. main_sym_edit_text:sub(main_sym_edit_cursor + 1)
                main_sym_edit_cursor = main_sym_edit_cursor - 1
            end
        elseif char_input == 6579564 then  -- Delete key
            if main_sym_edit_cursor < #main_sym_edit_text then
                main_sym_edit_text = main_sym_edit_text:sub(1, main_sym_edit_cursor) .. main_sym_edit_text:sub(main_sym_edit_cursor + 2)
            end
        elseif char_input == 1818584692 then  -- Left arrow
            if main_sym_edit_cursor > 0 then main_sym_edit_cursor = main_sym_edit_cursor - 1 end
        elseif char_input == 1919379572 then  -- Right arrow
            if main_sym_edit_cursor < #main_sym_edit_text then main_sym_edit_cursor = main_sym_edit_cursor + 1 end
        elseif char_input == 1752132965 then  -- Home
            main_sym_edit_cursor = 0
        elseif char_input == 6647396 then  -- End
            main_sym_edit_cursor = #main_sym_edit_text
        elseif char_input == 13 then  -- Enter: commit
            local art_name = articulation_names_ordered[main_sym_edit_index]
            if main_sym_edit_text ~= articulation_default_symbol[art_name] then
                articulation_symbol_override[art_name] = main_sym_edit_text
            else
                articulation_symbol_override[art_name] = nil
            end
            main_sym_edit_active = false
            main_sym_edit_index = nil
        elseif char_input == 27 then  -- Escape: cancel
            main_sym_edit_active = false
            main_sym_edit_index = nil
        elseif char_input >= 32 and char_input < 127 then  -- Printable ASCII
            local ch = string.char(char_input)
            main_sym_edit_text = main_sym_edit_text:sub(1, main_sym_edit_cursor) .. ch .. main_sym_edit_text:sub(main_sym_edit_cursor + 1)
            main_sym_edit_cursor = main_sym_edit_cursor + 1
        end
    end

    -- Handle keyboard input for main view default path editing
    if main_defpath_edit_active and char_input and not gui_msgbox.active then
        local function main_defpath_delete_selection()
            if main_defpath_edit_sel >= 0 and main_defpath_edit_sel ~= main_defpath_edit_cursor then
                local s = math.min(main_defpath_edit_cursor, main_defpath_edit_sel)
                local e = math.max(main_defpath_edit_cursor, main_defpath_edit_sel)
                main_defpath_edit_text = main_defpath_edit_text:sub(1, s) .. main_defpath_edit_text:sub(e + 1)
                main_defpath_edit_cursor = s
                main_defpath_edit_sel = -1
                return true
            end
            return false
        end

        if char_input == 1 then  -- Ctrl+A: select all
            main_defpath_edit_sel = 0
            main_defpath_edit_cursor = #main_defpath_edit_text
        elseif char_input == 3 then  -- Ctrl+C: copy
            if main_defpath_edit_sel >= 0 and main_defpath_edit_sel ~= main_defpath_edit_cursor then
                local s = math.min(main_defpath_edit_cursor, main_defpath_edit_sel)
                local e = math.max(main_defpath_edit_cursor, main_defpath_edit_sel)
                local selected = main_defpath_edit_text:sub(s + 1, e)
                if selected ~= "" and reaper.CF_SetClipboard then
                    reaper.CF_SetClipboard(selected)
                end
            end
        elseif char_input == 22 then  -- Ctrl+V: paste
            main_defpath_delete_selection()
            if reaper.CF_GetClipboard then
                local clip = reaper.CF_GetClipboard("")
                if clip and clip ~= "" then
                    clip = clip:gsub("[\r\n]+", "")
                    main_defpath_edit_text = main_defpath_edit_text:sub(1, main_defpath_edit_cursor) .. clip .. main_defpath_edit_text:sub(main_defpath_edit_cursor + 1)
                    main_defpath_edit_cursor = main_defpath_edit_cursor + #clip
                end
            end
            main_defpath_edit_sel = -1
        elseif char_input == 24 then  -- Ctrl+X: cut
            if main_defpath_edit_sel >= 0 and main_defpath_edit_sel ~= main_defpath_edit_cursor then
                local s = math.min(main_defpath_edit_cursor, main_defpath_edit_sel)
                local e = math.max(main_defpath_edit_cursor, main_defpath_edit_sel)
                local selected = main_defpath_edit_text:sub(s + 1, e)
                if selected ~= "" and reaper.CF_SetClipboard then
                    reaper.CF_SetClipboard(selected)
                end
                main_defpath_delete_selection()
            end
        elseif char_input == 8 then  -- Backspace
            if not main_defpath_delete_selection() then
                if main_defpath_edit_cursor > 0 then
                    main_defpath_edit_text = main_defpath_edit_text:sub(1, main_defpath_edit_cursor - 1) .. main_defpath_edit_text:sub(main_defpath_edit_cursor + 1)
                    main_defpath_edit_cursor = main_defpath_edit_cursor - 1
                end
            end
            main_defpath_edit_sel = -1
        elseif char_input == 6579564 then  -- Delete key
            if not main_defpath_delete_selection() then
                if main_defpath_edit_cursor < #main_defpath_edit_text then
                    main_defpath_edit_text = main_defpath_edit_text:sub(1, main_defpath_edit_cursor) .. main_defpath_edit_text:sub(main_defpath_edit_cursor + 2)
                end
            end
            main_defpath_edit_sel = -1
        elseif char_input == 1818584692 then  -- Left arrow
            if main_defpath_edit_cursor > 0 then main_defpath_edit_cursor = main_defpath_edit_cursor - 1 end
            main_defpath_edit_sel = -1
        elseif char_input == 1919379572 then  -- Right arrow
            if main_defpath_edit_cursor < #main_defpath_edit_text then main_defpath_edit_cursor = main_defpath_edit_cursor + 1 end
            main_defpath_edit_sel = -1
        elseif char_input == 1752132965 then  -- Home
            main_defpath_edit_cursor = 0
            main_defpath_edit_sel = -1
        elseif char_input == 6647396 then  -- End
            main_defpath_edit_cursor = #main_defpath_edit_text
            main_defpath_edit_sel = -1
        elseif char_input == 13 then  -- Enter: commit
            default_import_dir = main_defpath_edit_text
            save_default_import_dir(main_defpath_edit_text)
            main_defpath_edit_active = false
            main_defpath_edit_sel = -1
        elseif char_input == 27 then  -- Escape: cancel
            main_defpath_edit_active = false
            main_defpath_edit_sel = -1
        elseif char_input >= 32 and char_input < 127 then  -- Printable ASCII
            main_defpath_delete_selection()
            local ch = string.char(char_input)
            main_defpath_edit_text = main_defpath_edit_text:sub(1, main_defpath_edit_cursor) .. ch .. main_defpath_edit_text:sub(main_defpath_edit_cursor + 1)
            main_defpath_edit_cursor = main_defpath_edit_cursor + 1
            main_defpath_edit_sel = -1
        end
    end

    -- Draw and handle dark menu (on top of everything)
    draw_and_handle_dark_menu(mouse_x, mouse_y, mouse_clicked, mouse_released, char_input)

    -- Draw GUI message box overlay (on top of everything)
    draw_and_handle_gui_msgbox(mouse_x, mouse_y, mouse_clicked, char_input)

    -- Resize handle (drawn on top)
    draw_and_handle_resize(mouse_x, mouse_y, mouse_clicked, mouse_released, mouse_down, screen_x, screen_y)

    -- Draw tooltip (on top of everything, before update)
    if pending_tooltip and tips_enabled and not dark_menu.active and not gui_msgbox.active then
        draw_tooltip(pending_tooltip, mouse_x, mouse_y)
    end

    -- Draw import progress overlay (on top of everything)
    if import_progress.active then
        draw_import_progress()
        -- Handle dismiss
        if import_progress.done then
            local card_w = math.max(300, math.floor(gfx.w * 0.7))
            local log_lines = math.min(#import_progress.log, 8)
            local extra = (#import_progress.log > 8) and 1 or 0
            local card_h = math.max(120, 16 + gfx.texth + 10 + (log_lines + extra) * gfx.texth + 12 + 26 + 16)
            local card_x = math.floor((gfx.w - card_w) / 2)
            local card_y = math.floor((gfx.h - card_h) / 2)
            local btn_x = card_x + 16
            local btn_y = card_y + card_h - 16 - 26
            local hov = mouse_x >= btn_x and mouse_x < btn_x + 80 and mouse_y >= btn_y and mouse_y < btn_y + 26
            if (mouse_clicked and hov) or char_input == 13 or char_input == 27 then
                import_progress.active = false
                save_window_position()
                save_window_size(settings_mode and "settings" or "main")
                gfx.quit()
                return
            end
        end
    end

    gfx.update()
    last_mouse_cap = gfx.mouse_cap

    -- Continue or quit
    -- Handle Ctrl+C for copying selected text
    if char == 3 and not main_sym_edit_active and not main_defpath_edit_active then
        copy_selected_text()
    end
    if char >= 0 then
        reaper.defer(main_loop)
    else
        reset_track_drag()
        save_window_position()
        save_window_size("main")
        gfx.quit()
    end
end

-- Start the main loop
main_loop()
