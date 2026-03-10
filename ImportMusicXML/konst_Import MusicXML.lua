-- @description Import uncompressed MusicXML (.xml) files and create tracks/MIDI for each staff with tablature or drum notes. Supports three insertion modes: create new tracks, insert on existing tracks, or match tracks by name. Includes custom drum channel mapping and robust repeats.
-- @author kkonstantin2000
-- @version 1.3
-- @provides
--   konst_Import MusicXML.lua
-- @changelog
--   v1.3 - Added Settings panel with per-articulation controls:
--            symbol text, event type (Text/Marker/Cue), Replace Fret checkbox, underscore prefix toggle, enable/disable
--          - Fret Number global setting: event type selector and enable/disable checkbox
--          - Duration Lines toggle: consecutive Marker/Cue span articulations emit "----" / "-|" instead of repeating the label
--          - Highlight Used toggle: optionally scan the MusicXML to highlight which articulations appear in the file
--          - All settings persisted via ExtState (Save/Restore Defaults buttons)
--          - Fixed vibrato, bends, let ring parsing
--          - Bend variants (bend, bend release, pre-bend, 1/2 bend, full bend, etc.) treated as standard articulation rows
--          - Fixed harmonics: natural uses <fret> format, artificial uses "fret <fret+12>" format; vibrato and other suffix articulations now combine with the base symbol (e.g. "1 <13>~")
--   v1.2 - Added track list with checkboxes to select specific tracks for import
--        - Case‑insensitive track name matching
--        - UI: integrated file selection directly into the "No file selected" area (removed separate button)
--        - Persistent storage of last imported file path
--        - Improved text selection: text elements can now be selected with left‑click dragging (standard mouse behavior)
--        - Added undo point after import for safer CTRL+Z
--   v1.1 - Added three track insertion modes: new tracks, existing tracks, and tracks by name matching
--   v1.0 - Initial release

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
local chord_offset_ticks = 1

-- Case-insensitive track name matching for "Insert items on tracks by name" mode
-- Set to true to match track names regardless of case (e.g., "guitar" matches "Guitar" or "GUITAR")
local CASE_INSENSITIVE = true

-- Maximum window dimensions (pixels). Window will not grow beyond these limits.
local MAX_WINDOW_WIDTH = 800
local MAX_WINDOW_HEIGHT = 900

-- ============================================================================
-- DRUM NAME TO TEXT MAPPING
-- ============================================================================
-- Map the exact instrument names (as they appear in <instrument-name>) to the
-- short text you want to appear in the MIDI item (prefixed with an underscore).
-- If a name is not found, a fallback (first word, lowercased) is used.
local drum_text_map = {
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
local drum_channel_map = {
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
local drum_pitch_map = {
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

local region_color_map = {
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
local articulation_map = {
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
    ["straight mute"]  = { type = 1, symbol = "x", replaces_fret = true, no_prefix = true },
    ["letring"]        = { type = 6, symbol = "let ring---",  no_prefix = true },

    ["hammer-on"] = { type = 6, symbol = "H", no_prefix = true },
    ["pull-off"]  = { type = 6, symbol = "P", no_prefix = true },
    ["tap"]       = { type = 6, symbol = "T", no_prefix = true },
    ["fingering"] = { type = 1, symbol = "%d" },      -- finger number
    ["harmonic"]  = { type = 1, symbol = "<%d>", replaces_fret = true },
    ["natural-harmonic"]   = { type = 1, symbol = "<%d>",    replaces_fret = true },
    ["artificial-harmonic"]= { type = 1, symbol = "%d <%h>", replaces_fret = true },
    ["vibrato"]   = { type = 1, symbol = "~", replaces_fret = true, is_suffix = true },
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
    ["chord"]       = { type = 7, symbol = "%s" },    -- chord name (needs separate parsing)
    ["lyric"]       = { type = 7, symbol = "%s" },    -- lyric text (needs separate parsing)
}

-- Names of slide elements – these will be handled separately in the main loop.
local slide_names = {
    ["slide"] = true,
    ["slide-up"] = true,
    ["slide-down"] = true
}

-- Names of bend elements – collected as a sequence rather than processed individually.
local bend_names = {
    ["bend"] = true,
}

-- ============================================================================
-- ARTICULATION SETTINGS (enabled / disabled per articulation)
-- ============================================================================
-- Ordered list of articulation names for a stable display in Settings UI
local articulation_names_ordered = {
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
local xml_to_settings_name = {
    ["palm mute"] = "palm",
    ["straight mute"] = "straight",
}

-- Build a set of articulation_names_ordered for quick lookup
local settings_name_set = {}
for _, name in ipairs(articulation_names_ordered) do
    settings_name_set[name] = true
end

-- Table: articulation_name -> true/false (enabled)
local articulation_enabled = {}
-- Table: articulation_name -> custom symbol string (nil = use default)
local articulation_symbol_override = {}
-- Table: articulation_name -> custom type number (nil = use default)
local articulation_type_override = {}
-- Table: articulation_name -> custom replaces_fret override (nil = use default)
local articulation_replaces_fret_override = {}
-- Table: articulation_name -> custom no_prefix override (nil = use default)
local articulation_no_prefix_override = {}
-- Table: articulation_name -> default symbol string (from articulation_map)
local articulation_default_symbol = {}
-- Table: articulation_name -> default type number (from articulation_map)
local articulation_default_type = {}
-- Table: articulation_name -> default replaces_fret (from articulation_map)
local articulation_default_replaces_fret = {}
-- Table: articulation_name -> default no_prefix (from articulation_map)
local articulation_default_no_prefix = {}
-- Valid type values and their labels
local art_type_values = {1, 6, 7}
local art_type_labels = {[1] = "Text", [6] = "Marker", [7] = "Cue"}
-- Fret number global settings
local fret_number_enabled = true
local fret_number_type = 1
local FRET_NUMBER_TYPE_DEFAULT = 1
-- Duration line (span) feature: draw "----" / "-|" for consecutive span arts
local span_line_enabled = false
-- Highlight articulations used in file (requires XML scan on track selection change)
local highlight_scan_enabled = true

-- Reverse mapping: settings name -> XML element name (for names that differ)
local settings_to_xml_name = {}
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

local EXTSTATE_SECTION = "konst_ImportMusicXML"
local EXTSTATE_ART_KEY = "articulation_settings"

-- Get the effective symbol for an articulation (override or default)
local function get_art_symbol(name)
    return articulation_symbol_override[name] or articulation_default_symbol[name]
end

-- Get the effective type for an articulation (override or default)
local function get_art_type(name)
    return articulation_type_override[name] or articulation_default_type[name]
end

-- Get the effective replaces_fret for an articulation (override or default)
local function get_art_replaces_fret(name)
    if articulation_replaces_fret_override[name] ~= nil then
        return articulation_replaces_fret_override[name]
    end
    return articulation_default_replaces_fret[name]
end

-- Get the effective no_prefix for an articulation (override or default)
local function get_art_no_prefix(name)
    if articulation_no_prefix_override[name] ~= nil then
        return articulation_no_prefix_override[name]
    end
    return articulation_default_no_prefix[name]
end

-- Serialize all articulation settings to a string
-- Format: "name|enabled|symbol|type;name2|enabled|symbol|type;..."
-- Symbol uses base64-like URL encoding to avoid delimiter collisions
local function encode_sym(s)
    -- Percent-encode | ; and % characters
    return s:gsub("%%", "%%%%25"):gsub("|", "%%7C"):gsub(";", "%%3B")
end
local function decode_sym(s)
    return s:gsub("%%3B", ";"):gsub("%%7C", "|"):gsub("%%25", "%%")
end

local function serialize_articulation_settings()
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
local function deserialize_articulation_settings(str)
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
local function load_articulation_settings()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_ART_KEY)
    deserialize_articulation_settings(saved)
end

-- Save to EXTSTATE (persist = true)
local function save_articulation_settings()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_ART_KEY, serialize_articulation_settings(), true)
end

-- Restore defaults: re-enable everything, clear overrides
local function restore_default_articulation_settings()
    fret_number_enabled = true
    fret_number_type = FRET_NUMBER_TYPE_DEFAULT
    span_line_enabled = false
    highlight_scan_enabled = true
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

-- ============================================================================
-- Helper: convert drum instrument name to short text
-- ============================================================================
local function drumNameToText(name)
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
local function getDrumChannel(instrument_name, default_channel)
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
local function getDrumPitch(instrument_name, default_pitch)
    local pitch = drum_pitch_map[instrument_name]
    if pitch then
        return pitch
    end
    return default_pitch or 60  -- Default to C3 if not found
end

-- ============================================================================
-- Helper: generate drum exstate string with 9 channels (one per string)
-- ============================================================================
local function getDrumReaTabHeroState()
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
local note_to_semitone = {
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
local function parseTuning(attrs, is_drum)
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
local function tuningToReaTabHeroString(tuning)
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
local function getDefaultBassTuning()
    -- Standard 4-string bass tuning: E A D G
    return {28, 33, 38, 43}
end

-- ============================================================================
-- Helper: get default tuning for 5-string bass
-- ============================================================================
local function getDefault5StringBassTuning()
    -- Standard 5-string bass tuning: B E A D G
    return {23, 28, 33, 38, 43}
end

-- ============================================================================
-- Helper: detect if a track name indicates it's a bass
-- ============================================================================
local function isBassTrack(track_name)
    if not track_name then return false end
    local name_lower = track_name:lower()
    return name_lower:find("bass") ~= nil
end

-- ============================================================================
-- Helper: detect if a track name indicates it's a 5-string bass
-- ============================================================================
local function is5StringBassTrack(track_name)
    if not track_name then return false end
    local name_lower = track_name:lower()
    return (name_lower:find("5") ~= nil or name_lower:find("five") ~= nil) and name_lower:find("bass") ~= nil
end

-- ============================================================================
-- Helper: detect if a track name indicates it's a drum track
-- ============================================================================
local function isDrumTrack(track_name)
    if not track_name then return false end
    local name_lower = track_name:lower()
    return name_lower:find("drum") ~= nil or name_lower:find("percussion") ~= nil or name_lower:find("kit") ~= nil
end

-- ============================================================================
-- Pre-process Guitar Pro processing instructions (<?GP ... ?>)
-- Converts them to parseable <_gp_> elements so their content is accessible
-- in the parsed tree (e.g. <letring/> detection).
-- ============================================================================
local function preprocess_gp_pis(xml)
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
local function make_bend_events(bend_nodes, default_fret)
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

local function getArticulationEvents(note_node, default_fret)
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
local function getSlideInfo(slide_node, default_fret)
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
local function insert_markers(markers)
  -- Convert to sorted list
  local times = {}
  for t in pairs(markers) do table.insert(times, t) end
  table.sort(times)

  for _, t in ipairs(times) do
    local m = markers[t]
    reaper.SetTempoTimeSigMarker(
      0,           -- project
      -1,          -- index (-1 = add new)
      t,           -- time in seconds
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
local function insert_regions(sections, max_seconds)
  if not sections or #sections == 0 then return end
  
  -- Sort sections by start time
  table.sort(sections, function(a, b) return a.start_time < b.start_time end)
  
  -- Create regions for each section
  for i, section in ipairs(sections) do
    local start_time = section.start_time
    -- End time is either the next section's start time or the end of the project
    local end_time
    if i < #sections then
      end_time = sections[i + 1].start_time
    else
      -- Last section extends to the end of the project
      end_time = max_seconds
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
      start_time,          -- pos
      end_time,            -- rgnend
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
local function expand_repeats(measures)
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
-- Import function with GUI-provided options
-- ============================================================================
function ImportMusicXMLWithOptions(filepath, options)
  -- Begin undo block for all import operations
  reaper.Undo_BeginBlock()
  
  -- Validate filepath
  if not filepath or filepath == "" then
    reaper.ShowMessageBox("No file path provided.", "Error", 0)
    reaper.Undo_EndBlock("Import MusicXML", -1)
    return
  end

  -- 1. Read the file content
  local f = io.open(filepath, "r")
  if not f then
    reaper.ShowMessageBox("Could not open file.", "Error", 0)
    reaper.Undo_EndBlock("Import MusicXML", -1)
    return
  end
  local content = f:read("*all")
  f:close()

  -- 2. Parse XML (preprocess Guitar Pro PIs so letring etc. are accessible)
  content = preprocess_gp_pis(content)
  local root = parseXML(content)
  if not root then
    reaper.ShowMessageBox("Failed to parse XML.", "Error", 0)
    reaper.Undo_EndBlock("Import MusicXML", -1)
    return
  end

  -- 3. Use options from GUI (or defaults if not provided)
  local import_markers = (options and options.import_markers) or false
  local import_regions = (options and options.import_regions) or false
  local insert_on_new_tracks = (options and options.insert_on_new_tracks) or false
  local insert_on_existing_tracks = (options and options.insert_on_existing_tracks) or false
  local insert_on_tracks_by_name = (options and options.insert_on_tracks_by_name) or true
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

  -- 7. Data structures for note import
  local all_parts_data = {}          -- part_id -> { staff_notes, staff_texts, total_seconds }
  local markers = {}                  -- time (sec) -> { tempo, beats, beat_type }
  local sections = {}                 -- { { name, start_time, end_time }, ... }

  -- 8. Process each <part> element
  local parts = findChildren(root, "part")
  for part_idx, part_node in ipairs(parts) do
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
        if time_node and import_markers and part_idx == 1 then
          local beats = tonumber(getChildText(time_node, "beats"))
          local beat_type = tonumber(getChildText(time_node, "beat-type"))
          if beats and beat_type then
            if not markers[cur_seconds] then markers[cur_seconds] = {} end
            markers[cur_seconds].beats = beats
            markers[cur_seconds].beat_type = beat_type
          end
        end
      end

      -- Process all elements in measure
      local measure_children = measure_node.children or {}
      for _, elem in ipairs(measure_children) do
        if elem.name == "note" then
          local rest = findChild(elem, "rest")
          local dur_node = findChild(elem, "duration")
          if dur_node and divisions then
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
                  local start_ticks
                  if chord then
                    local base_start = staff_last_start[staff_num]
                    if not base_start then
                      base_start = cur_pos_ticks
                      staff_last_start[staff_num] = base_start
                      staff_chord_count[staff_num] = 1
                    end
                    local count = staff_chord_count[staff_num] or 0
                    count = count + 1
                    staff_chord_count[staff_num] = count
                    start_ticks = base_start + (count - 1) * chord_offset_ticks
                  else
                    staff_last_start[staff_num] = cur_pos_ticks
                    staff_chord_count[staff_num] = 1
                    start_ticks = cur_pos_ticks
                  end

                  -- Store note
                  if not staff_notes[staff_num] then staff_notes[staff_num] = {} end
                  table.insert(staff_notes[staff_num], {
                    pos    = start_ticks,
                    endpos = start_ticks + tick_duration,
                    channel = channel,
                    pitch  = midi_note,
                    vel    = 100
                  })

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

                      -- Determine start position with possible chord offset
                      local start_ticks
                      if chord then
                        local base_start = staff_last_start[staff_num]
                        if not base_start then
                          base_start = cur_pos_ticks
                          staff_last_start[staff_num] = base_start
                          staff_chord_count[staff_num] = 1
                        end
                        local count = staff_chord_count[staff_num] or 0
                        count = count + 1
                        staff_chord_count[staff_num] = count
                        start_ticks = base_start + (count - 1) * chord_offset_ticks
                      else
                        staff_last_start[staff_num] = cur_pos_ticks
                        staff_chord_count[staff_num] = 1
                        start_ticks = cur_pos_ticks
                      end

                      -- Store note
                      if not staff_notes[staff_num] then staff_notes[staff_num] = {} end
                      local note_channel = channel - 1
                      -- For bass tracks, shift channel down by 1
                      if is_bass then
                        note_channel = note_channel - 1
                      end
                      table.insert(staff_notes[staff_num], {
                        pos    = start_ticks,
                        endpos = start_ticks + tick_duration,
                        channel = note_channel,
                        pitch  = pitch,
                        vel    = velocity
                      })

                      -- --- Process non‑slide articulations ---
                      local articulation_events = getArticulationEvents(elem, fret_num)

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
          -- Tempo change? (only from first part to avoid duplicates)
          if import_markers and part_idx == 1 then
            local sound = findChild(elem, "sound")
            if sound then
              local tempo_attr = getAttribute(sound, "tempo")
              if tempo_attr then
                local new_tempo = tonumber(tempo_attr)
                if new_tempo then
                  if not markers[cur_seconds] then markers[cur_seconds] = {} end
                  markers[cur_seconds].tempo = new_tempo
                  -- Update current tempo for subsequent time calculations
                  current_tempo = new_tempo
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
                      end_time = cur_seconds
                    })
                  end
                end
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
      total_seconds = cur_seconds
    }
  end

  -- 11. Determine overall max length across all parts (needed for region boundaries)
  local max_seconds = 0
  for _, data in pairs(all_parts_data) do
    if data.total_seconds > max_seconds then
      max_seconds = data.total_seconds
    end
  end
  if max_seconds < 0.001 then max_seconds = 1.0 end

  -- 10. Insert tempo/time signature markers if requested
  if import_markers and next(markers) then
    insert_markers(markers)
  end

  -- 10b. Insert sections as regions if requested
  if import_regions and next(sections) then
    insert_regions(sections, max_seconds)
  end

  -- 12. Create tracks for each part/staff that has notes (in MusicXML order)
  local initial_track_count = reaper.CountTracks(0)
  local tracks_created = 0
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
    local base_track_name = part_names[part_id] or ("Part " .. part_id)

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

    for staff = 1, max_staff do
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

        -- Determine item position (always at 0 in new implementation)
        local item_position = 0

        -- Create MIDI item (length = max_seconds)
        local item = reaper.CreateNewMIDIItemInProj(track, item_position, item_position + max_seconds, false)
        if not item then
          item = reaper.AddMediaItemToTrack(track)
          reaper.SetMediaItemInfo_Value(item, "D_POSITION", item_position)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", max_seconds)
        end

        local take = reaper.GetActiveTake(item)
        if not take then
          take = reaper.AddTakeToMediaItem(item)
        end

        -- Name the take after the track
        reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", track_name, true)

        -- Insert notes
        for _, n in ipairs(notes) do
          reaper.MIDI_InsertNote(take, false, false, n.pos, n.endpos, n.channel, n.pitch, n.vel, false)
        end

        -- Insert text events
        if staff_texts[staff] then
          for _, t in ipairs(staff_texts[staff]) do
            reaper.MIDI_InsertTextSysexEvt(take, false, false, t.pos, t.type, t.text)
          end
        end

        reaper.MIDI_Sort(take)
      end
    end
    ::continue_part::
    end
  end

  reaper.UpdateArrange()
  
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
local selected_file_path = nil
local selected_file_name = nil
local selected_file_track_count = nil
local last_import_dir = nil  -- Store the last imported file directory
local track_checkboxes = {}  -- Dynamic list: { {name="...", checked=true, part_id="..."}, ... }
local import_all_checked = true  -- "Import All" master checkbox state
local track_scroll_offset = 0  -- Scroll offset (in rows) for the track list
local scrollbar_dragging = false  -- Whether we're dragging the scrollbar
local settings_mode = false  -- Whether the settings view is active
local settings_scroll_offset = 0  -- Scroll offset for settings articulation list
local settings_btn_hovered = false  -- Hover state for settings button in main view
local pre_settings_width = nil  -- Window width before entering settings mode
local pre_settings_height = nil -- Window height before entering settings mode
local articulations_in_file = {}  -- Set of articulation names found in the selected file's checked tracks

-- Text selection state
local text_sel = {
    active = false,        -- whether a selection drag is in progress
    element_id = nil,      -- id of the selected text element
    start_char = 0,        -- character index where selection started
    end_char = 0,          -- current character index of selection end
    display_text = "",     -- displayed text of the element
    full_text = "",        -- original (non-truncated) text for clipboard
    text_x = 0,            -- x position of the text element
}
local text_elements_frame = {} -- rebuilt each frame for hit testing
local file_info_click_pending = false  -- track file info click for drag detection
local file_info_click_x = 0  -- mouse x when file info was clicked
local file_info_click_y = 0  -- mouse y when file info was clicked
local text_sel_mouse_start_x = 0  -- mouse x at selection start
local text_sel_mouse_start_y = 0  -- mouse y at selection start
local DRAG_THRESHOLD = 3  -- minimum pixels to distinguish drag from click

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

-- Checkbox items (add your items here)
local checkboxes_list = {
    {name = "Import tempo and time signature", checked = true},
    {name = "Import segments as regions", checked = true},
    {name = "Insert items on new tracks", checked = false},
    {name = "Insert items on existing tracks", checked = false},
    {name = "Insert items on tracks by name", checked = true},
}

-- Dimensions
local header_height = 50  -- header area height
local file_info_height = 60  -- file info section height
local checkbox_size = gui.settings.font_size
local checkbox_row_height = gui.settings.font_size*2  -- add some vertical spacing between rows
local horizontal_margin = 32  -- left/right margin
local vertical_margin = 20  -- top/bottom margin
local button_height_area = 50  -- space for import button

-- Calculate max label width for aligned checkboxes
gfx.setfont(1, "Outfit|Arial|Helvetica", gui.settings.font_size)
local max_label_width = 0
for i, cb in ipairs(checkboxes_list) do
    local label_width = gfx.measurestr(cb.name)
    if label_width > max_label_width then
        max_label_width = label_width
    end
end

-- Calculate window dimensions dynamically (vertical layout)
local min_btn_area_width = 110 * 3 + 10 * 2 + horizontal_margin * 2  -- 3 buttons + margins
gui.width = math.max(horizontal_margin + max_label_width + 5 + checkbox_size + horizontal_margin, min_btn_area_width)
gui.height = header_height + vertical_margin + (#checkboxes_list * checkbox_row_height) + vertical_margin + file_info_height + vertical_margin + button_height_area

-- Global state
local last_mouse_cap = 0
local import_btn_hovered = false
local cancel_btn_hovered = false
local is_dragging = false
local drag_offset_x = 0
local drag_offset_y = 0
local window_script = nil

-- Initialize window
local mouse_x, mouse_y = reaper.GetMousePosition()
gfx.init(SCRIPT_TITLE, gui.width, gui.height, gui.settings.docker_id, mouse_x - gui.width/2, mouse_y - gui.height/2)

-- Apply borderless window style if configured
if gui.settings.Borderless_Window then
    window_script = reaper.JS_Window_Find(SCRIPT_TITLE, true)
    if window_script then
        reaper.JS_Window_SetStyle(window_script, "POPUP")
        reaper.JS_Window_AttachResizeGrip(window_script)
    end
end

-- Set font
gfx.setfont(1, "Outfit", gui.settings.font_size)
gfx.clear = 2829099   -- dark gray

-- Load last import directory at startup
last_import_dir = load_last_import_path()


-- Helper function to extract track names and count from XML content
function get_tracks_from_xml(xml_content)
    local tracks = {}
    -- Extract part-name from each score-part block
    for score_part_block in xml_content:gmatch("<score%-part[^>]*>(.-)</score%-part>") do
        local part_name = score_part_block:match("<part%-name>([^<]*)</part%-name>")
        if part_name and part_name ~= "" then
            table.insert(tracks, part_name)
        end
    end
    return tracks 
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

    -- Build set of checked track names
    local checked_names = {}
    for _, tcb in ipairs(track_checkboxes) do
        if tcb.checked then
            checked_names[tcb.name] = true
        end
    end

    -- Map part IDs to names from <part-list>
    local part_names = {}
    local part_list = findChild(root, "part-list")
    if part_list then
        for _, score_part in ipairs(findChildren(part_list, "score-part")) do
            local id = getAttribute(score_part, "id")
            local name = getChildText(score_part, "part-name")
            if id and name then
                part_names[id] = name
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
        local w = gfx.measurestr(tcb.name)
        if w > max_label_width then max_label_width = w end
    end
    -- Account for file info text width
    local min_btn_width = 110 * 3 + 10 * 2 + horizontal_margin * 2  -- 3 buttons + margins
    if selected_file_name then
        local info_text = selected_file_name .. " [" .. (selected_file_track_count or 0) .. " tracks]"
        local fw = gfx.measurestr(info_text)
        -- File info needs some margin on both sides
        local needed_for_file = fw + horizontal_margin * 2
        local needed_for_labels = horizontal_margin + max_label_width + 5 + checkbox_size + horizontal_margin
        local new_width = math.max(needed_for_file, needed_for_labels, min_btn_width)
        if new_width > gui.width then
            gui.width = math.min(new_width, MAX_WINDOW_WIDTH)
        end
    else
        local new_width = math.max(horizontal_margin + max_label_width + 5 + checkbox_size + horizontal_margin, min_btn_width)
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
    gui.height = header_height + vertical_margin
                 + (#checkboxes_list * checkbox_row_height)
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
    if max_text_w then
        display_text = truncate_text(label_text, max_text_w)
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
function draw_file_info(y_offset, height, filename, track_count, colors, is_hovered)
    -- Fill background - highlight when hovered
    if is_hovered then
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
    
    if filename then
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
    
    -- Text
    gfx.set(table.unpack(text_color))
    local text_width = gfx.measurestr(label)
    gfx.x = x + (width - text_width) / 2
    gfx.y = y + (height - gfx.texth) / 2
    gfx.drawstr(label)
end

-- Draw all checkboxes from list
function draw_checkboxes_list(checkboxes, header_h, h_margin, v_margin, checkbox_h, cb_size, max_width, colors)
    for i, cb in ipairs(checkboxes) do
        local label_x = h_margin
        local cb_y = header_h + v_margin + (i - 1) * checkbox_h
        local cb_x = gfx.w - h_margin - cb_size
        
        draw_checkbox(cb_x, cb_y, cb_size, label_x, cb.name, cb.checked, colors, nil, "option_" .. i)
    end
end

-- ============================================================================
-- SETTINGS VIEW (articulation checkboxes, symbol input, type selector)
-- ============================================================================
local settings_save_hovered = false
local settings_restore_hovered = false
local settings_close_hovered = false

-- Text input state for symbol editing
local sym_edit_active = false   -- whether a symbol input is being edited
local sym_edit_index = nil      -- index into articulation_names_ordered
local sym_edit_text = ""        -- current text being edited
local sym_edit_cursor = 0       -- cursor position in text

-- Column widths for settings layout
local SYM_BOX_WIDTH = 100      -- symbol text input box width
local TYPE_BTN_WIDTH = 80      -- type selector button width
local REPL_COL_WIDTH = 100     -- replace fret column width (wide enough for header label)
local COL_SPACING = 8          -- spacing between columns

-- Tooltip definitions for column headers and special elements
local settings_tooltips = {
    Sym   = "Symbol text written as event.\nClick to edit, Enter to confirm.",
    Type  = "Event type: Text (note-level),\nMarker (below tab), Cue (above tab).\nMousewheel to cycle.",
    RF    = "Replace Fret: when checked,\nthis articulation replaces the\nfret number instead of adding\na separate event.",
    Prefix = "Underscore Prefix: when checked,\nthe symbol is prefixed with '_'\nfor note-level text events.",
    On    = "Enable/Disable: when unchecked,\nthis articulation will be skipped\nduring import.",
    Fret  = "Fret Number: the base fret number\nwritten as a text event. Disable to\nskip fret numbers entirely.",
    FretType = "Event type for fret numbers.\nMousewheel to cycle.",
}

-- Tooltip state
local settings_tooltip_text = nil  -- current tooltip to show
local settings_tooltip_x = 0
local settings_tooltip_y = 0

-- Draw a tooltip box near the given position
local function draw_tooltip(text, mx, my)
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
    -- Clear text elements for this frame
    text_elements_frame = {}

    -- Header drag handling
    local header_hovered = (mouse_y > 0 and mouse_y < header_height)
    if mouse_clicked and header_hovered then
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
    end

    -- Button area
    local btn_width = 130
    local btn_height = 30
    local btn_spacing = 10
    local total_btn_width = btn_width * 3 + btn_spacing * 2
    local btn_y = gfx.h - btn_height - 10
    local btn_start_x = (gfx.w - total_btn_width) / 2

    local save_btn_x = btn_start_x
    local restore_btn_x = save_btn_x + btn_width + btn_spacing
    local close_btn_x = restore_btn_x + btn_width + btn_spacing

    -- Fret number row, span line row, and highlight scan row (above scrollable list)
    local fret_row_y = header_height + vertical_margin
    local span_row_y = fret_row_y + checkbox_row_height
    local hlscan_row_y = span_row_y + checkbox_row_height
    local separator_y = hlscan_row_y + checkbox_row_height
    local col_header_h = math.floor(gfx.texth) + 4
    local col_header_y = separator_y + 4
    local list_top = separator_y + 2 + col_header_h + 2
    local list_bottom = btn_y - 10
    local list_height = list_bottom - list_top
    local max_visible = math.floor(list_height / checkbox_row_height)
    local total_items = #articulation_names_ordered
    local max_scroll = math.max(0, total_items - max_visible)

    -- Right-side element positions:
    -- [name_label] ... [sym_box] [type_btn] [repl_fret_cb] [prefix_cb] [enabled_cb]
    local cb_x = gfx.w - horizontal_margin - checkbox_size
    local prefix_cb_x = cb_x - COL_SPACING - checkbox_size
    local repl_col_x = prefix_cb_x - COL_SPACING - REPL_COL_WIDTH
    local repl_cb_x = repl_col_x + math.floor((REPL_COL_WIDTH - checkbox_size) / 2)
    local type_btn_x = repl_col_x - COL_SPACING - TYPE_BTN_WIDTH
    local sym_box_x = type_btn_x - COL_SPACING - SYM_BOX_WIDTH
    local name_max_w = sym_box_x - horizontal_margin - COL_SPACING

    -- Handle clicks
    if mouse_clicked then
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
            save_articulation_settings()
        end
        -- Restore defaults button
        if settings_restore_hovered then
            sym_edit_active = false
            sym_edit_index = nil
            restore_default_articulation_settings()
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
            settings_mode = false
            -- Restore pre-settings window size
            local need_resize = false
            if pre_settings_width and pre_settings_width ~= gui.width then
                gui.width = pre_settings_width
                need_resize = true
            end
            if pre_settings_height and pre_settings_height ~= gui.height then
                gui.height = pre_settings_height
                need_resize = true
            end
            if need_resize then
                if window_script then
                    reaper.JS_Window_Resize(window_script, gui.width, gui.height)
                else
                    local _, wx, wy = gfx.dock(-1, 0, 0, 0, 0)
                    gfx.init(SCRIPT_TITLE, gui.width, gui.height, gui.settings.docker_id, wx, wy)
                end
            end
            pre_settings_width = nil
            pre_settings_height = nil
            return
        end

        -- Check click on fret number row
        if mouse_y > fret_row_y and mouse_y < fret_row_y + checkbox_size then
            -- Fret number enabled checkbox
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                fret_number_enabled = not fret_number_enabled
            -- Fret number type button click -> dropdown menu
            elseif mouse_x > type_btn_x and mouse_x < type_btn_x + TYPE_BTN_WIDTH then
                local menu_str = ""
                for j, v in ipairs(art_type_values) do
                    if j > 1 then menu_str = menu_str .. "|" end
                    if v == fret_number_type then menu_str = menu_str .. "!" end
                    menu_str = menu_str .. art_type_labels[v]
                end
                gfx.x = type_btn_x
                gfx.y = fret_row_y + checkbox_size
                local choice = gfx.showmenu(menu_str)
                if choice > 0 then
                    fret_number_type = art_type_values[choice]
                end
            end
        end

        -- Check click on span line (duration lines) row
        if mouse_y > span_row_y and mouse_y < span_row_y + checkbox_size then
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                span_line_enabled = not span_line_enabled
            end
        end

        -- Check click on highlight scan row
        if mouse_y > hlscan_row_y and mouse_y < hlscan_row_y + checkbox_size then
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                highlight_scan_enabled = not highlight_scan_enabled
                if not highlight_scan_enabled then
                    articulations_in_file = {}
                else
                    scan_articulations_in_xml()
                end
            end
        end

        -- Check clicks on articulation rows
        local clicked_sym_box = false
        for i, art_name in ipairs(articulation_names_ordered) do
            local scrolled_i = i - settings_scroll_offset
            if scrolled_i >= 1 and scrolled_i <= max_visible then
                local row_y = list_top + (scrolled_i - 1) * checkbox_row_height

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
                    gfx.x = type_btn_x
                    gfx.y = row_y + checkbox_size
                    local choice = gfx.showmenu(menu_str)
                    if choice > 0 then
                        local new_type = art_type_values[choice]
                        if new_type ~= articulation_default_type[art_name] then
                            articulation_type_override[art_name] = new_type
                        else
                            articulation_type_override[art_name] = nil
                        end
                    end
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
            end
        end

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
    end

    -- Handle keyboard input for symbol editing
    if sym_edit_active and char_input then
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

    -- Handle mousewheel: scroll list OR cycle type on type buttons
    if gfx.mouse_wheel ~= 0 then
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
        -- Check if mouse is over an articulation type button
        if not wheel_handled then
        for i, art_name in ipairs(articulation_names_ordered) do
            local scrolled_i = i - settings_scroll_offset
            if scrolled_i >= 1 and scrolled_i <= max_visible then
                local row_y = list_top + (scrolled_i - 1) * checkbox_row_height
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
            if mouse_y >= list_top and mouse_y <= list_bottom then
                local scroll_delta = -math.floor(gfx.mouse_wheel / 120)
                settings_scroll_offset = settings_scroll_offset + scroll_delta
                if settings_scroll_offset < 0 then settings_scroll_offset = 0 end
                if settings_scroll_offset > max_scroll then settings_scroll_offset = max_scroll end
            end
        end
        gfx.mouse_wheel = 0
    end

    -- Hover states
    settings_save_hovered = (mouse_x > save_btn_x and mouse_x < save_btn_x + btn_width and
                             mouse_y > btn_y and mouse_y < btn_y + btn_height)
    settings_restore_hovered = (mouse_x > restore_btn_x and mouse_x < restore_btn_x + btn_width and
                                mouse_y > btn_y and mouse_y < btn_y + btn_height)
    settings_close_hovered = (mouse_x > close_btn_x and mouse_x < close_btn_x + btn_width and
                              mouse_y > btn_y and mouse_y < btn_y + btn_height)

    -- Determine tooltip for current mouse position
    settings_tooltip_text = nil
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
    if mouse_y >= span_row_y and mouse_y < hlscan_row_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x then
            settings_tooltip_text = "Duration Lines: when enabled,\nconsecutive span articulations\n(Marker/Cue type) emit '----' and '-|'\ninstead of repeating the label."
        elseif mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Duration Lines: when enabled,\nconsecutive span articulations\n(Marker/Cue type) emit '----' and '-|'\ninstead of repeating the label."
        end
    end
    -- Highlight scan row hover
    if mouse_y >= hlscan_row_y and mouse_y < separator_y then
        if mouse_x >= horizontal_margin and mouse_x < sym_box_x or
           mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Highlight Used: scan the selected MusicXML file\nto highlight articulations that are actually used.\nDisable to avoid slowdowns on large files."
        end
    end

    -- Draw header
    draw_header("ARTICULATION SETTINGS", header_height, gui.colors)

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

    -- Draw span line (duration lines) row
    local span_text_y = span_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = span_text_y
    gfx.drawstr("Duration Lines")
    draw_checkbox(cb_x, span_row_y, checkbox_size, cb_x, "", span_line_enabled, gui.colors, 0, nil)

    -- Draw highlight scan row
    local hlscan_text_y = hlscan_row_y + (checkbox_size - gfx.texth) / 2
    gfx.set(table.unpack(gui.colors.TEXT))
    gfx.x = horizontal_margin
    gfx.y = hlscan_text_y
    gfx.drawstr("Highlight Used")
    draw_checkbox(cb_x, hlscan_row_y, checkbox_size, cb_x, "", highlight_scan_enabled, gui.colors, 0, nil)

    -- Separator line
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.line(horizontal_margin, separator_y, gfx.w - horizontal_margin, separator_y)

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

    -- Draw articulation rows
    for i, art_name in ipairs(articulation_names_ordered) do
        local scrolled_i = i - settings_scroll_offset
        if scrolled_i >= 1 and scrolled_i <= max_visible then
            local row_y = list_top + (scrolled_i - 1) * checkbox_row_height
            local text_y = row_y + (checkbox_size - gfx.texth) / 2

            -- Highlight row if this articulation is present in the file
            if articulations_in_file[art_name] then
                gfx.set(0.18, 0.25, 0.22, 1)
                gfx.rect(horizontal_margin - 4, row_y, gfx.w - 2 * horizontal_margin + 8, checkbox_size, 1)
            end

            -- 1) Draw articulation name (left side, truncated)
            local display_name = truncate_text(art_name, name_max_w)
            gfx.set(table.unpack(gui.colors.TEXT))
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
            local pfx_checked = not get_art_no_prefix(art_name)
            local pfx_is_override = (articulation_no_prefix_override[art_name] ~= nil)
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
        end
    end

    -- Draw scrollbar if needed
    if total_items > max_visible then
        local scrollbar_width = 8
        local scrollbar_x = gfx.w - scrollbar_width - 4
        local scrollbar_track_height = list_height
        local thumb_height = math.max(20, math.floor(scrollbar_track_height * max_visible / total_items))
        local current_max_scroll = math.max(1, max_scroll)
        local thumb_y = list_top + math.floor((scrollbar_track_height - thumb_height) * settings_scroll_offset / current_max_scroll)

        gfx.set(0.15, 0.15, 0.15, 1)
        gfx.rect(scrollbar_x, list_top, scrollbar_width, scrollbar_track_height, 1)
        gfx.set(0.4, 0.4, 0.4, 1)
        gfx.rect(scrollbar_x, thumb_y, scrollbar_width, thumb_height, 1)
    end

    -- Draw buttons
    draw_button(save_btn_x, btn_y, btn_width, btn_height, "Save",
                settings_save_hovered, "IMPORT_BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(restore_btn_x, btn_y, btn_width, btn_height, "Restore",
                settings_restore_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(close_btn_x, btn_y, btn_width, btn_height, "Close",
                settings_close_hovered, "CLOSE_BTN", gui.colors.BORDER, gui.colors.TEXT)

    -- Draw tooltip (on top of everything)
    draw_tooltip(settings_tooltip_text, mouse_x, mouse_y)
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
    
    -- Settings view branch
    if settings_mode then
        local char = gfx.getchar()
        local char_input = (char > 0) and char or nil
        draw_settings_view(mouse_x, mouse_y, mouse_clicked, mouse_released, screen_x, screen_y, mouse_down, char_input)
        gfx.update()
        last_mouse_cap = gfx.mouse_cap
        if char >= 0 then
            reaper.defer(main_loop)
        else
            gfx.quit()
        end
        return
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
    
    -- Handle drag start
    if mouse_clicked and header_hovered then
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
    
    -- Handle drag end
    if mouse_released then
        is_dragging = false
        
        -- File info click: open dialog only if no significant drag occurred
        if file_info_click_pending then
            local dx = math.abs(mouse_x - file_info_click_x)
            local dy = math.abs(mouse_y - file_info_click_y)
            if dx <= DRAG_THRESHOLD and dy <= DRAG_THRESHOLD then
                -- It was a click, not a drag - open file dialog
                local retval, filepath = reaper.GetUserFileNameForRead(last_import_dir, "Select MusicXML file", "*.xml")
                if retval then
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
                        for _, name in ipairs(track_names) do
                            table.insert(track_checkboxes, {name = name, checked = true})
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

    -- Button area - bottom with three buttons side by side
    local btn_width = 110
    local btn_height = 30
    local btn_spacing = 10
    local total_btn_width = btn_width * 3 + btn_spacing * 2
    local btn_y = gfx.h - btn_height - 10
    local btn_start_x = (gfx.w - total_btn_width) / 2
    
    -- Import button (left)
    local import_btn_x = btn_start_x
    local import_btn_y = btn_y
    
    -- Settings button (center)
    local settings_btn_x = import_btn_x + btn_width + btn_spacing
    local settings_btn_y = btn_y
    
    -- Cancel button (right)
    local cancel_btn_x = settings_btn_x + btn_width + btn_spacing
    local cancel_btn_y = btn_y
    
    -- File info area for clicking to select file
    local file_info_y = header_height + vertical_margin + (#checkboxes_list * checkbox_row_height) + vertical_margin
    local file_info_hovered = (mouse_x > 0 and mouse_x < gfx.w and
                               mouse_y > file_info_y and mouse_y < file_info_y + file_info_height)

    -- Handle clicks
    if mouse_clicked then
        -- Cancel button
        if cancel_btn_hovered then
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
                        table.insert(selected_tracks, tcb.name)
                    end
                end
                -- Collect checkbox states into options table
                local options = {
                    import_markers = checkboxes_list[1].checked,
                    import_regions = checkboxes_list[2].checked,
                    insert_on_new_tracks = checkboxes_list[3].checked,
                    insert_on_existing_tracks = checkboxes_list[4].checked,
                    insert_on_tracks_by_name = checkboxes_list[5].checked,
                    selected_tracks = selected_tracks
                }
                -- Execute import with selected options
                ImportMusicXMLWithOptions(selected_file_path, options)
                gfx.quit()
            else
                reaper.ShowMessageBox("Please select a MusicXML file first.", "No File Selected", 0)
            end
        end

        -- Settings button
        if settings_btn_hovered then
            settings_mode = true
            settings_scroll_offset = 0
            sym_edit_active = false
            sym_edit_index = nil
            -- Save current size and resize for settings view
            pre_settings_width = gui.width
            pre_settings_height = gui.height
            local min_settings_w = horizontal_margin + 150 + COL_SPACING + SYM_BOX_WIDTH + COL_SPACING + TYPE_BTN_WIDTH + COL_SPACING + REPL_COL_WIDTH + COL_SPACING + checkbox_size + COL_SPACING + checkbox_size + horizontal_margin
            local settings_w = math.max(min_settings_w, 660)
            local settings_h = math.min(MAX_WINDOW_HEIGHT, 700)
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

        -- Checkboxes (vertical layout - aligned)
        for i, cb in ipairs(checkboxes_list) do
            local cb_x = gfx.w - horizontal_margin - checkbox_size
            local cb_y = header_height + vertical_margin + (i - 1) * checkbox_row_height
            if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
               mouse_y > cb_y and mouse_y < cb_y + checkbox_size then
                -- Handle mutually exclusive checkboxes for insertion modes (indices 3, 4, 5)
                if i >= 3 and i <= 5 then
                    -- Uncheck other insertion mode options
                    for j = 3, 5 do
                        checkboxes_list[j].checked = false
                    end
                    -- Check the clicked one
                    checkboxes_list[i].checked = true
                else
                    -- Regular toggle for other options
                    checkboxes_list[i].checked = not checkboxes_list[i].checked
                end
                break
            end
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
                        if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
                           mouse_y > tcb_y and mouse_y < tcb_y + checkbox_size then
                            tcb.checked = not tcb.checked
                            -- Update "Import All" state based on individual checkboxes
                            local all_checked = true
                            for _, t in ipairs(track_checkboxes) do
                                if not t.checked then all_checked = false; break end
                            end
                            import_all_checked = all_checked
                            if highlight_scan_enabled then scan_articulations_in_xml() end
                            break
                        end
                    end
                end
            end
        end
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
    settings_btn_hovered = (mouse_x > settings_btn_x and mouse_x < settings_btn_x + btn_width and
                            mouse_y > settings_btn_y and mouse_y < settings_btn_y + btn_height)
    cancel_btn_hovered = (mouse_x > cancel_btn_x and mouse_x < cancel_btn_x + btn_width and
                          mouse_y > cancel_btn_y and mouse_y < cancel_btn_y + btn_height)
    
    -- Draw all UI elements using modular functions
    draw_header("IMPORT MUSICXML", header_height, gui.colors)
    draw_checkboxes_list(checkboxes_list, header_height, horizontal_margin, vertical_margin, 
                        checkbox_row_height, checkbox_size, max_label_width, gui.colors)
    draw_file_info(file_info_y, file_info_height, selected_file_name, selected_file_track_count, gui.colors, file_info_hovered)
    
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
                draw_checkbox(cb_x, tcb_y, checkbox_size, horizontal_margin,
                              tcb.name, tcb.checked, gui.colors, trunc_w, "track_" .. i)
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
    
    -- Draw buttons (Import, Settings, and Cancel)
    draw_button(import_btn_x, import_btn_y, btn_width, btn_height, "Import",
                import_btn_hovered, "IMPORT_BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(settings_btn_x, settings_btn_y, btn_width, btn_height, "Settings",
                settings_btn_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(cancel_btn_x, cancel_btn_y, btn_width, btn_height, "Cancel",
                cancel_btn_hovered, "CLOSE_BTN", gui.colors.BORDER, gui.colors.TEXT)

    gfx.update()
    last_mouse_cap = gfx.mouse_cap

    -- Continue or quit
    local char = gfx.getchar()
    -- Handle Ctrl+C for copying selected text
    if char == 3 then
        copy_selected_text()
    end
    if char >= 0 then
        reaper.defer(main_loop)
    else
        gfx.quit()
    end
end

-- Start the main loop
main_loop()
