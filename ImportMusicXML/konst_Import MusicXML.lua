-- @description Import uncompressed MusicXML (.xml) files and create tracks/MIDI for each staff with tablature or drum notes. Supports three insertion modes: create new tracks, insert on existing tracks, or match tracks by name. Includes custom drum channel mapping and robust repeats.
-- @author kkonstantin2000
-- @version 1.4
-- @provides
--   konst_Import MusicXML.lua
-- @changelog
--   v1.4 - MusicXML Export: full export of selected MIDI items to MusicXML with staff grouping, measures, notes, and articulations
--        - Import/Export Key Signatures: bidirectional key signature support via REAPER KSIG notation events
--        - Key Signature UI: interactive root and scale buttons in EXPORT settings to set key signature on selected items
--        - Import MIDI Program Banks: preserves bank/program data from MusicXML (Bank Select MSB/LSB + Program Change)
--        - Open After Export: option to auto-open specified application after export
--        - Open Folder After Export: option to reveal the exported file in Windows Explorer
--        - Drag & Drop: MusicXML files can be dropped directly from file explorer onto the script window
--        - Clickable Articulation Labels: click articulation names in settings to insert text events on selected MIDI notes; Alt+Click to remove
--        - Settings Sections: organized settings panel into GENERAL, EXPORT, IMPORT, and ARTICULATION sections
--        - Auto-Focus: optional automatic window focus on mouse hover
--        - Stay on Top: keep the script window above other windows
--        - Docker: dock the script window to Bottom, Left, Top, or Right
--        - Font Selection: choose from a list of fonts for the UI
--        - Default Path / Last Path: file browser opens to a configured default path or the last used directory
--        - Show in Menu (M checkbox): per-setting toggle to show or hide import checkboxes in the main menu
--        - Window Position Memory: remember and restore the last script window position, or open at mouse cursor
--        - Custom context menu: dark-themed scrollable popup menus replacing REAPER's default light menus
--        - Custom Message Box: non-blocking in-GUI message dialogs with dark theme and text wrapping
--        - Unified Scrollbar: proportional scrollbar with mouse wheel and drag support for settings and track lists
--        - Added confirmation label for saving settings export


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
local fret_number_enabled = false
local fret_number_type = 1
local FRET_NUMBER_TYPE_DEFAULT = 1
-- Duration line (span) feature: draw "----" / "-|" for consecutive span arts
local span_line_enabled = false
-- Highlight articulations used in file (requires XML scan on track selection change)
local highlight_scan_enabled = true
-- Export project regions as rehearsal marks (segments) in MusicXML
local export_regions_enabled = true
-- Include MIDI program/bank in import and export
local midi_program_banks_enabled = true
-- Open exported file with external program
local export_open_with_enabled = false
local export_open_with_path = ""
-- Open containing folder after export
local export_open_folder_enabled = false
-- Key signature for export
local export_key_sig_enabled = true

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

-- Forward declarations for variables/functions defined later, needed by early functions
local path_mode
local auto_focus_enabled
local font_list
local current_font_index
local docker_enabled
local docker_position
local docker_positions
local docker_dock_values
local articulations_in_file
local window_position_mode
local save_window_position_mode
local stay_on_top_enabled

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
    -- Export regions toggle
    local expreg_en = export_regions_enabled and "1" or "0"
    table.insert(parts, "__expreg__|" .. expreg_en .. "||||")
    -- MIDI program banks toggle
    local mpb_en = midi_program_banks_enabled and "1" or "0"
    table.insert(parts, "__midibank__|" .. mpb_en .. "||||")
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
        elseif name == "__expreg__" then
            -- Export regions toggle
            if fields[2] then export_regions_enabled = (fields[2] == "1") end
        elseif name == "__midibank__" then
            -- MIDI program banks toggle
            if fields[2] then midi_program_banks_enabled = (fields[2] == "1") end
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
    fret_number_enabled = false
    fret_number_type = FRET_NUMBER_TYPE_DEFAULT
    span_line_enabled = false
    highlight_scan_enabled = true
    export_regions_enabled = true
    midi_program_banks_enabled = true
    export_open_with_enabled = false
    export_open_with_path = ""
    export_open_folder_enabled = false
    export_key_sig_enabled = true
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

-- Show-in-menu flags for all non-import settings rows
-- Keys: "hlscan","expreg","midibank","docker","winpos_last","winpos_mouse","defpath","lastpath","fret","span", and each articulation name
local settings_menu_flags = {}
-- Initialize defaults (all hidden in main menu)
for _, name in ipairs(articulation_names_ordered) do settings_menu_flags[name] = false end
settings_menu_flags.hlscan = false
settings_menu_flags.expreg = false
settings_menu_flags.midibank = false
settings_menu_flags.openwith = false
settings_menu_flags.openfolder = false
settings_menu_flags.keysig = false
settings_menu_flags.docker = false
settings_menu_flags.winpos_last = false
settings_menu_flags.winpos_mouse = false
settings_menu_flags.defpath = false
settings_menu_flags.lastpath = false
settings_menu_flags.fret = false
settings_menu_flags.span = false

local EXTSTATE_MENU_FLAGS_KEY = "settings_menu_flags"
local function save_settings_menu_flags()
    local parts = {}
    for k, v in pairs(settings_menu_flags) do
        if v then table.insert(parts, k .. "=1") end
    end
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_MENU_FLAGS_KEY, table.concat(parts, ";"), true)
end
local function load_settings_menu_flags()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_MENU_FLAGS_KEY)
    if not saved or saved == "" then return end
    for entry in saved:gmatch("[^;]+") do
        local k, v = entry:match("^(.+)=(%d)$")
        if k and v then settings_menu_flags[k] = (v == "1") end
    end
end
load_settings_menu_flags()

-- Build list of extra settings visible in main menu (controlled by M checkboxes)
local function get_visible_extra_settings()
    local items = {}
    -- GENERAL settings
    if settings_menu_flags.autofocus then table.insert(items, {key="autofocus", label="Auto-Focus"}) end
    if settings_menu_flags.stayontop then table.insert(items, {key="stayontop", label="Stay on Top"}) end
    if settings_menu_flags.font then table.insert(items, {key="font", label="Font"}) end
    if settings_menu_flags.docker then table.insert(items, {key="docker", label="Docker"}) end
    if settings_menu_flags.winpos_last then table.insert(items, {key="winpos_last", label="Last Position"}) end
    if settings_menu_flags.winpos_mouse then table.insert(items, {key="winpos_mouse", label="At Mouse"}) end
    if settings_menu_flags.defpath then table.insert(items, {key="defpath", label="Default Path"}) end
    if settings_menu_flags.lastpath then table.insert(items, {key="lastpath", label="Last Opened"}) end
    -- EXPORT settings
    if settings_menu_flags.expreg then table.insert(items, {key="expreg", label="Export Regions"}) end
    if settings_menu_flags.midibank then table.insert(items, {key="midibank", label="MIDI Program Banks"}) end
    if settings_menu_flags.openwith then table.insert(items, {key="openwith", label="Open After Export"}) end
    if settings_menu_flags.openfolder then table.insert(items, {key="openfolder", label="Open Folder"}) end
    if settings_menu_flags.keysig then table.insert(items, {key="keysig", label="Key Signature"}) end
    -- ARTICULATION settings
    if settings_menu_flags.hlscan then table.insert(items, {key="hlscan", label="Highlight Used"}) end
    if settings_menu_flags.fret then table.insert(items, {key="fret", label="Fret Number"}) end
    if settings_menu_flags.span then table.insert(items, {key="span", label="Duration Lines"}) end
    for i, name in ipairs(articulation_names_ordered) do
        if settings_menu_flags[name] then table.insert(items, {key=name, label=name, is_art=true, art_index=i}) end
    end
    return items
end

local function get_extra_setting_checked(key)
    if key == "autofocus" then return auto_focus_enabled
    elseif key == "stayontop" then return stay_on_top_enabled
    elseif key == "font" then return true
    elseif key == "hlscan" then return highlight_scan_enabled
    elseif key == "expreg" then return export_regions_enabled
    elseif key == "midibank" then return midi_program_banks_enabled
    elseif key == "openwith" then return export_open_with_enabled
    elseif key == "openfolder" then return export_open_folder_enabled
    elseif key == "keysig" then return export_key_sig_enabled
    elseif key == "docker" then return docker_enabled
    elseif key == "winpos_last" then return window_position_mode == "last"
    elseif key == "winpos_mouse" then return window_position_mode == "mouse"
    elseif key == "defpath" then return path_mode == "default"
    elseif key == "lastpath" then return path_mode == "last"
    elseif key == "fret" then return fret_number_enabled
    elseif key == "span" then return span_line_enabled
    else return articulation_enabled[key] or false
    end
end

local function toggle_extra_setting(key)
    if key == "autofocus" then auto_focus_enabled = not auto_focus_enabled
    elseif key == "stayontop" then stay_on_top_enabled = not stay_on_top_enabled; apply_stay_on_top(); save_stay_on_top_setting()
    elseif key == "font" then -- no toggle; font is always active
    elseif key == "hlscan" then
        highlight_scan_enabled = not highlight_scan_enabled
        if not highlight_scan_enabled then articulations_in_file = {} end
    elseif key == "expreg" then export_regions_enabled = not export_regions_enabled
    elseif key == "midibank" then midi_program_banks_enabled = not midi_program_banks_enabled
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
    elseif key == "defpath" then path_mode = "default"; save_path_mode("default")
    elseif key == "lastpath" then path_mode = "last"; save_path_mode("last")
    elseif key == "fret" then fret_number_enabled = not fret_number_enabled
    elseif key == "span" then span_line_enabled = not span_line_enabled
    elseif articulation_enabled[key] ~= nil then articulation_enabled[key] = not articulation_enabled[key]
    end
end

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
-- Helper: read active tuning from Fretboard script ExtState
-- Returns array of MIDI note numbers (low to high), or nil
-- ============================================================================
-- Compact tuning data mirroring konst_Fretboard INSTRUMENTS table (midi arrays,
-- ordered high-to-low as stored in Fretboard).
local fretboard_tunings = {
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

local function getTuningFromFretboard()
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
local function getActiveTuning()
    return getTuningFromFretboard() or getDefaultGuitarTuning()
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
  if options.import_midi_banks and part_list then
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
        end
      end
    end
  end

  -- 7. Data structures for note import
  local all_parts_data = {}          -- part_id -> { staff_notes, staff_texts, total_seconds }
  local markers = {}                  -- time (sec) -> { tempo, beats, beat_type }
  local sections = {}                 -- { { name, start_time, end_time }, ... }
  local part_key_sig = {}             -- part_id -> { fifths, mode } from first <key> element

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
                        start_ticks = base_start + (count - 1) * (needs_chord_offset and chord_offset_ticks or 0)
                      else
                        staff_last_start[staff_num] = cur_pos_ticks
                        staff_chord_count[staff_num] = 1
                        start_ticks = cur_pos_ticks
                      end

                      -- Store note (merge with previous if tie stop)
                      if not staff_notes[staff_num] then staff_notes[staff_num] = {} end
                      local note_channel = channel - 1
                      -- For bass tracks, shift channel down by 1
                      if is_bass then
                        note_channel = note_channel - 1
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

    local part_bank_inserted = false
    local part_ksig_inserted = false
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
local default_import_dir = ""  -- Default directory for file explorer when no last path exists
path_mode = "last"  -- "default" = use default_import_dir, "last" = use last_import_dir
local track_checkboxes = {}  -- Dynamic list: { {name="...", checked=true, part_id="..."}, ... }
local import_all_checked = true  -- "Import All" master checkbox state
local track_scroll_offset = 0  -- Scroll offset (in rows) for the track list
local scrollbar_dragging = false  -- Whether we're dragging the scrollbar
local settings_mode = false  -- Whether the settings view is active
local settings_scroll_offset = 0  -- Scroll offset for settings view (pixels)
local settings_sb_dragging = false  -- Whether we're dragging the settings scrollbar thumb
local settings_sb_drag_start_y = 0  -- Mouse Y when drag started
local settings_sb_drag_start_offset = 0  -- settings_scroll_offset when drag started
auto_focus_enabled = true  -- Whether to auto-focus window on mouse hover
stay_on_top_enabled = false  -- Whether to keep the window always on top
font_list = {"Outfit", "Arial", "Segoe UI", "Tahoma", "Verdana", "Consolas", "Courier New", "Times New Roman", "Georgia", "Trebuchet MS", "Calibri", "Helvetica"}
current_font_index = 1  -- Index into font_list (default: Outfit)
docker_enabled = false  -- Whether to dock on startup
docker_position = 1  -- 1=Bottom, 2=Left, 3=Top, 4=Right
docker_positions = {"Bottom", "Left", "Top", "Right"}
docker_dock_values = {769, 257, 513, 1}  -- gfx.dock values for each position
local settings_btn_hovered = false  -- Hover state for settings button in main view
local export_btn_hovered = false  -- Hover state for export button in main view
local export_confirmed_until = 0   -- os.clock() time until which "Exported!" label is shown
local pre_settings_width = nil  -- Window width before entering settings mode
local pre_settings_height = nil -- Window height before entering settings mode
articulations_in_file = {}  -- Set of articulation names found in the selected file's checked tracks

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

-- Checkbox items (add your items here)
local checkboxes_list = {
    {name = "Import tempo and time signature", checked = true, show_in_menu = true},
    {name = "Import segments as regions", checked = true, show_in_menu = true},
    {name = "Import MIDI program banks", checked = true, show_in_menu = true},
    {name = "Import key signatures", checked = true, show_in_menu = true},
    {name = "Insert items on new tracks", checked = false, show_in_menu = true},
    {name = "Insert items on existing tracks", checked = false, show_in_menu = true},
    {name = "Insert items on tracks by name", checked = true, show_in_menu = true},
}

-- Save/Load import checkbox settings (checked state + show_in_menu flags)
local EXTSTATE_IMPORT_KEY = "import_settings"
local function save_import_settings()
    local parts = {}
    for _, cb in ipairs(checkboxes_list) do
        table.insert(parts, (cb.checked and "1" or "0") .. "," .. (cb.show_in_menu and "1" or "0"))
    end
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_IMPORT_KEY, table.concat(parts, ";"), true)
end
local function load_import_settings()
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
local EXTSTATE_WINPOS_KEY = "window_position"
local EXTSTATE_WINPOS_MODE_KEY = "window_position_mode"
window_position_mode = "mouse"  -- "last" or "mouse"
local function save_window_position()
    local dock, wx, wy = gfx.dock(-1, 0, 0, 0, 0)
    if dock == 0 then  -- only save when not docked
        reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_KEY, tostring(math.floor(wx)) .. "," .. tostring(math.floor(wy)), true)
    end
end
local function load_window_position()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_KEY)
    if not saved or saved == "" then return nil, nil end
    local sx, sy = saved:match("(%-?%d+),(%-?%d+)")
    if sx and sy then return tonumber(sx), tonumber(sy) end
    return nil, nil
end
function save_window_position_mode(mode)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_MODE_KEY, mode, true)
end
local function load_window_position_mode()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_WINPOS_MODE_KEY)
    if saved == "last" or saved == "mouse" then return saved end
    return "mouse"
end
window_position_mode = load_window_position_mode()

-- Save/Load auto-focus setting
local EXTSTATE_AUTOFOCUS_KEY = "auto_focus"
local function save_auto_focus_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_AUTOFOCUS_KEY, auto_focus_enabled and "1" or "0", true)
end
local function load_auto_focus_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_AUTOFOCUS_KEY)
    if val == "0" then auto_focus_enabled = false end
end
load_auto_focus_setting()

-- Save/Load/Apply stay-on-top setting
local EXTSTATE_STAYONTOP_KEY = "stay_on_top"
local function apply_stay_on_top()
    if window_script then
        if stay_on_top_enabled then
            reaper.JS_Window_SetZOrder(window_script, "TOPMOST")
        else
            reaper.JS_Window_SetZOrder(window_script, "NOTOPMOST")
        end
    end
end
local function save_stay_on_top_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_STAYONTOP_KEY, stay_on_top_enabled and "1" or "0", true)
end
local function load_stay_on_top_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_STAYONTOP_KEY)
    if val == "1" then stay_on_top_enabled = true end
end
load_stay_on_top_setting()

-- Save/Load export open-with setting
local EXTSTATE_OPENWITH_KEY = "export_open_with"
local EXTSTATE_OPENWITH_PATH_KEY = "export_open_with_path"
local function save_open_with_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_KEY, export_open_with_enabled and "1" or "0", true)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_PATH_KEY, export_open_with_path, true)
end
local function load_open_with_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_KEY)
    if val == "1" then export_open_with_enabled = true end
    local path = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_OPENWITH_PATH_KEY)
    if path and path ~= "" then export_open_with_path = path end
end
load_open_with_setting()

-- Save/Load export open-folder setting
local EXTSTATE_OPENFOLDER_KEY = "export_open_folder"
local function save_open_folder_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_OPENFOLDER_KEY, export_open_folder_enabled and "1" or "0", true)
end
local function load_open_folder_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_OPENFOLDER_KEY)
    if val == "1" then export_open_folder_enabled = true end
end
load_open_folder_setting()

-- Save/Load export key signature setting
local EXTSTATE_KEYSIG_KEY = "export_key_sig"
function save_key_sig_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_KEYSIG_KEY, export_key_sig_enabled and "1" or "0", true)
end
local function load_key_sig_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_KEYSIG_KEY)
    if val == "0" then export_key_sig_enabled = false end
end
load_key_sig_setting()

-- Custom GUI message box state (replaces reaper.ShowMessageBox to avoid z-order issues)
local gui_msgbox = {
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
local EXTSTATE_FONT_KEY = "font_name"
local function save_font_setting()
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_FONT_KEY, font_list[current_font_index], true)
end
local function load_font_setting()
    local val = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_FONT_KEY)
    if val and val ~= "" then
        for i, name in ipairs(font_list) do
            if name == val then current_font_index = i; return end
        end
    end
end
load_font_setting()

-- Save/Load docker settings
local EXTSTATE_DOCKER_KEY = "docker_settings"
local function save_docker_settings()
    local val = (docker_enabled and "1" or "0") .. "," .. tostring(docker_position)
    reaper.SetExtState(EXTSTATE_SECTION, EXTSTATE_DOCKER_KEY, val, true)
end
local function load_docker_settings()
    local saved = reaper.GetExtState(EXTSTATE_SECTION, EXTSTATE_DOCKER_KEY)
    if not saved or saved == "" then return end
    local en, pos = saved:match("([01]),(%d+)")
    if en then docker_enabled = (en == "1") end
    if pos then docker_position = math.max(1, math.min(4, tonumber(pos))) end
end
load_docker_settings()

-- Dimensions
local header_height = 50  -- header area height
local file_info_height = 60  -- file info section height
local checkbox_size = gui.settings.font_size
local checkbox_row_height = gui.settings.font_size*2  -- add some vertical spacing between rows
local horizontal_margin = 32  -- left/right margin
local vertical_margin = 20  -- top/bottom margin
local button_height_area = 50  -- space for import button

-- Calculate max label width for aligned checkboxes
gfx.setfont(1, font_list[current_font_index] .. "|Arial|Helvetica", gui.settings.font_size)
local max_label_width = 0
for i, cb in ipairs(checkboxes_list) do
    local label_width = gfx.measurestr(cb.name)
    if label_width > max_label_width then
        max_label_width = label_width
    end
end

-- Column widths for settings layout
local SYM_BOX_WIDTH = 100      -- symbol text input box width
local TYPE_BTN_WIDTH = 80      -- type selector button width
local REPL_COL_WIDTH = 100     -- replace fret column width (wide enough for header label)
local COL_SPACING = 8          -- spacing between columns

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
local last_mouse_cap = 0
local import_btn_hovered = false
local cancel_btn_hovered = false
local is_dragging = false
local drag_offset_x = 0
local drag_offset_y = 0
local window_script = nil

-- Initialize window
local mouse_x, mouse_y = reaper.GetMousePosition()
local init_x, init_y
if window_position_mode == "last" then
    local saved_wx, saved_wy = load_window_position()
    init_x = saved_wx or (mouse_x - gui.width/2)
    init_y = saved_wy or (mouse_y - gui.height/2)
else
    init_x = mouse_x - gui.width/2
    init_y = mouse_y - gui.height/2
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

-- ============================================================================
-- Scan MIDI text events in selected items / active editor for articulations
-- ============================================================================
-- Build a list of { pattern, art_name } for reverse-matching text events
local midi_art_patterns  -- lazily built

local function build_midi_art_patterns()
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

local function match_text_to_articulation(text)
    build_midi_art_patterns()
    for _, entry in ipairs(midi_art_patterns) do
        if text:match(entry.pattern) then
            return entry.name
        end
    end
    return nil
end

-- Gather MIDI takes using the same fallback chain as the articulation write handler
local function gather_midi_takes_for_scan()
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
local last_midi_scan_sel_hash = ""

local function compute_selection_hash()
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
        local w = gfx.measurestr(tcb.name)
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
    
    -- Text
    gfx.set(table.unpack(text_color))
    local text_width = gfx.measurestr(label)
    gfx.x = x + (width - text_width) / 2
    gfx.y = y + (height - gfx.texth) / 2
    gfx.drawstr(label)
end

-- Forward declarations for main view editing state (used in draw_checkboxes_list, defined later)
local main_sym_edit_active
local main_sym_edit_index
local main_sym_edit_text
local main_sym_edit_cursor
local main_defpath_edit_active
local main_defpath_edit_text
local main_defpath_edit_cursor
local main_defpath_edit_sel

-- Draw all checkboxes from list (filtered by show_in_menu) plus extra settings
function draw_checkboxes_list(checkboxes, header_h, h_margin, v_margin, checkbox_h, cb_size, max_width, colors)
    local visible_idx = 0
    for i, cb in ipairs(checkboxes) do
        if cb.show_in_menu ~= false then
            local label_x = h_margin
            local cb_y = header_h + v_margin + visible_idx * checkbox_h
            local cb_x = gfx.w - h_margin - cb_size
            
            draw_checkbox(cb_x, cb_y, cb_size, label_x, cb.name, cb.checked, colors, nil, "option_" .. i)
            visible_idx = visible_idx + 1
        end
    end
    -- Draw extra settings (from M flags)
    local extras = get_visible_extra_settings()
    for j, item in ipairs(extras) do
        local cb_y = header_h + v_margin + visible_idx * checkbox_h
        if item.is_art then
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
        else
            -- Non-articulation extra settings with enhanced controls
            local label_x = h_margin
            local cb_x_pos = gfx.w - h_margin - cb_size
            local text_y = cb_y + (cb_size - gfx.texth) / 2
            local ikey = item.key

            if ikey == "docker" or ikey == "font" or ikey == "midibank" then
                -- Label
                gfx.set(table.unpack(colors.TEXT))
                gfx.x = label_x
                gfx.y = text_y
                gfx.drawstr(item.label)
                -- Scrollable button
                local lbl_w = gfx.measurestr(item.label .. "  ")
                local btn_x = label_x + lbl_w
                local btn_w
                if ikey == "font" then
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
                -- Draw checkbox (for docker/midibank, not for font)
                if ikey ~= "font" then
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
local dark_menu = {
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
local function dark_menu_parse(menu_str)
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
local function dark_menu_get_children(header_label)
    local children = {}
    for _, item in ipairs(dark_menu.items) do
        if not item.is_header and item.group == header_label then
            table.insert(children, item)
        end
    end
    return children
end

-- Close only the submenu
local function dark_menu_close_submenu()
    local s = dark_menu.submenu
    s.active = false
    s.header_label = nil
    s.header_index = 0
    s.items = {}
    s.hovered_index = nil
end

-- Open a submenu for a given parent header index
local function dark_menu_open_submenu(header_idx)
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
local function open_dark_menu(menu_str, x, y, callback)
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
local function close_dark_menu()
    dark_menu.active = false
    dark_menu.items = {}
    dark_menu.parent_items = {}
    dark_menu.callback = nil
    dark_menu.opened_this_frame = false
    dark_menu_close_submenu()
end

-- Helper: draw a single menu panel (background, border, items, scroll arrows)
local function dark_menu_draw_panel(px, py, pw, p_items, p_visible, p_scroll, p_hovered, is_parent)
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
local function draw_and_handle_dark_menu(mouse_x, mouse_y, mouse_clicked, mouse_released, char_input)
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
        settings_sb_dragging = false
    end

    -- Button area
    local btn_width = 130
    local btn_height = 30
    local btn_spacing = 10
    local total_btn_width = btn_width * 4 + btn_spacing * 3
    local btn_y = gfx.h - btn_height - 10
    local btn_start_x = (gfx.w - total_btn_width) / 2

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

    -- GENERAL section
    local general_hdr_y = vy; vy = vy + section_hdr_h
    local autofocus_row_y = vy; vy = vy + checkbox_row_height
    local stayontop_row_y = vy; vy = vy + checkbox_row_height
    local font_row_y = vy; vy = vy + checkbox_row_height
    local docker_row_y = vy; vy = vy + checkbox_row_height
    local winpos_last_row_y = vy; vy = vy + checkbox_row_height
    local winpos_mouse_row_y = vy; vy = vy + checkbox_row_height
    local defpath_row_y = vy; vy = vy + checkbox_row_height
    local lastpath_row_y = vy; vy = vy + checkbox_row_height

    -- EXPORT section
    local export_hdr_y = vy; vy = vy + section_hdr_h
    local expreg_row_y = vy; vy = vy + checkbox_row_height
    local midibank_row_y = vy; vy = vy + checkbox_row_height
    local keysig_row_y = vy; vy = vy + checkbox_row_height
    local openwith_row_y = vy; vy = vy + checkbox_row_height
    local openfolder_row_y = vy; vy = vy + checkbox_row_height

    -- IMPORT section
    local import_hdr_y = vy; vy = vy + section_hdr_h
    local import_row_y = {}
    for i = 1, #checkboxes_list do
        import_row_y[i] = vy
        vy = vy + checkbox_row_height
    end

    -- ARTICULATION section
    local art_hdr_y = vy; vy = vy + section_hdr_h
    local hlscan_row_y = vy; vy = vy + checkbox_row_height
    local fret_row_y = vy; vy = vy + checkbox_row_height
    local span_row_y = vy; vy = vy + checkbox_row_height
    local separator_y = vy
    local col_header_h = math.floor(gfx.texth) + 4
    local col_header_y = separator_y + 4
    vy = separator_y + 2 + col_header_h + 2
    local list_top = vy
    local total_items = #articulation_names_ordered
    vy = vy + total_items * checkbox_row_height

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
    defpath_row_y = defpath_row_y - scroll_y
    lastpath_row_y = lastpath_row_y - scroll_y
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
    art_hdr_y = art_hdr_y - scroll_y
    hlscan_row_y = hlscan_row_y - scroll_y
    fret_row_y = fret_row_y - scroll_y
    span_row_y = span_row_y - scroll_y
    separator_y = separator_y - scroll_y
    col_header_y = col_header_y - scroll_y
    list_top = list_top - scroll_y

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
            current_font_index = 1
            gfx.setfont(1, font_list[1], gui.settings.font_size)
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
            -- Recalculate main view size (M flags may have changed)
            gui.width = pre_settings_width or gui.width
            gui.height = pre_settings_height or gui.height
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
                        table.insert(selected_tracks, tcb.name)
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
                    selected_tracks = selected_tracks
                }
                ImportMusicXMLWithOptions(selected_file_path, options)
                save_window_position()
                gfx.quit()
            else
                safe_msgbox("Please select a MusicXML file first.", "No File Selected", 0)
            end
        end

        -- Content area click guard (only handle scrollable row clicks within visible area)
        local mouse_in_content = mouse_y >= content_top and mouse_y < content_bottom

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
                local font_btn_x_c = sym_box_x
                local font_btn_w_c = cb_x - COL_SPACING - sym_box_x
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
                local docker_btn_x = sym_box_x
                local docker_btn_w = cb_x - COL_SPACING - sym_box_x
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

        -- Check click on MIDI program banks row
        if mouse_in_content and mouse_y > midibank_row_y and mouse_y < midibank_row_y + checkbox_size then
            if mouse_x > menu_cb_x and mouse_x < menu_cb_x + checkbox_size then
                settings_menu_flags.midibank = not settings_menu_flags.midibank
            elseif mouse_x > cb_x and mouse_x < cb_x + checkbox_size then
                midi_program_banks_enabled = not midi_program_banks_enabled
            else
                local midibank_btn_x = sym_box_x
                local midibank_btn_w = cb_x - COL_SPACING - sym_box_x
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
            local font_btn_x_w = sym_box_x
            local font_btn_w_w = cb_x - COL_SPACING - sym_box_x
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
            local docker_btn_x_w = sym_box_x
            local docker_btn_w_w = cb_x - COL_SPACING - sym_box_x
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
        -- Check if mouse is over MIDI bank scrollable button
        local midibank_btn_x_w = sym_box_x
        local midibank_btn_w_w = cb_x - COL_SPACING - sym_box_x
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
            local midibank_btn_x_t = sym_box_x
            local midibank_btn_w_t = cb_x - COL_SPACING - sym_box_x
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
            local font_btn_x_t = sym_box_x
            local font_btn_w_t = cb_x - COL_SPACING - sym_box_x
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
            local docker_btn_x_t = sym_box_x
            local docker_btn_w_t = cb_x - COL_SPACING - sym_box_x
            if mouse_x >= docker_btn_x_t and mouse_x < docker_btn_x_t + docker_btn_w_t then
                settings_tooltip_text = "Dock position: click or mousewheel to change.\nBottom, Left, Top, Right."
            end
        end
    end
    -- Window position rows hover
    if mouse_y >= winpos_last_row_y and mouse_y < winpos_mouse_row_y then
        settings_tooltip_text = "Open window at the last saved\nscreen position on next launch."
    end
    if mouse_y >= winpos_mouse_row_y and mouse_y < defpath_row_y then
        settings_tooltip_text = "Open window centered under\nthe mouse cursor on next launch."
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
    if mouse_y >= lastpath_row_y and mouse_y < export_hdr_y then
        if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
            settings_tooltip_text = "Use the last imported folder\nwhen opening the file browser."
        elseif mouse_x >= horizontal_margin and mouse_x < gfx.w - horizontal_margin then
            settings_tooltip_text = "Last folder used for importing.\nUpdated automatically after each import."
        end
    end
    -- Import checkbox rows hover
    for i = 1, #checkboxes_list do
        local ry = import_row_y[i]
        if mouse_y >= ry and mouse_y < ry + checkbox_row_height then
            if mouse_x >= cb_x and mouse_x < cb_x + checkbox_size then
                settings_tooltip_text = "Show this option in the main menu."
            elseif mouse_x >= prefix_cb_x and mouse_x < prefix_cb_x + checkbox_size then
                settings_tooltip_text = "Enable/disable this import option."
            end
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

    -- Section header helper
    local function draw_section_hdr(label, y)
        gfx.set(0.45, 0.45, 0.45, 1)
        local text_y = y + (section_hdr_h - gfx.texth) / 2
        gfx.x = horizontal_margin
        gfx.y = text_y
        gfx.drawstr(label)
        local lw = gfx.measurestr(label)
        local line_y = y + math.floor(section_hdr_h / 2)
        gfx.set(0.3, 0.3, 0.3, 1)
        gfx.line(horizontal_margin + lw + 8, line_y, gfx.w - horizontal_margin, line_y)
    end

    -- Draw section headers
    draw_section_hdr("GENERAL", general_hdr_y)
    draw_section_hdr("EXPORT", export_hdr_y)
    draw_section_hdr("IMPORT", import_hdr_y)
    draw_section_hdr("ARTICULATION", art_hdr_y)

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
    local midibank_btn_x = sym_box_x
    local midibank_btn_w = cb_x - COL_SPACING - sym_box_x
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
    local font_btn_x = sym_box_x
    local font_btn_w = cb_x - COL_SPACING - sym_box_x
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
    local docker_btn_x = sym_box_x
    local docker_btn_w = cb_x - COL_SPACING - sym_box_x
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
    local docker_lbl_w = gfx.measurestr(docker_pos_label)
    gfx.x = docker_btn_x + (docker_btn_w - docker_lbl_w) / 2
    gfx.y = docker_text_y
    gfx.drawstr(docker_pos_label)
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
            -- 7) M checkbox (show in main menu)
            draw_menu_flag_cb(menu_cb_x, row_y, settings_menu_flags[art_name])
        end
    end

    -- Masking rectangles (cover content overflow into header and button areas)
    local clear_r = (gfx.clear & 0xFF) / 255
    local clear_g = ((gfx.clear >> 8) & 0xFF) / 255
    local clear_b = ((gfx.clear >> 16) & 0xFF) / 255
    gfx.set(clear_r, clear_g, clear_b, 1)
    gfx.rect(0, 0, gfx.w, content_top, 1)
    gfx.rect(0, content_bottom, gfx.w, gfx.h - content_bottom, 1)

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
    if not dark_menu.active and not gui_msgbox.active then
        draw_tooltip(settings_tooltip_text, mouse_x, mouse_y)
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
        gfx.update()
        last_mouse_cap = gfx.mouse_cap
        if char >= 0 then
            reaper.defer(main_loop)
        else
            save_window_position()
            gfx.quit()
        end
        return
    end

    -- Handle dropped files (drag-and-drop from Explorer / Flow Launcher / etc.)
    local char = gfx.getchar()
    local char_input = (char > 0) and char or nil
    local retval, drop_file = gfx.getdropfile(0)
    if retval > 0 and drop_file and drop_file ~= "" then
        gfx.getdropfile(-1)  -- clear the drop list
        if drop_file:lower():match("%.xml$") then
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

    -- Button area - bottom with four buttons side by side
    local btn_width = 110
    local btn_height = 30
    local btn_spacing = 10
    local total_btn_width = btn_width * 4 + btn_spacing * 3
    local btn_y = gfx.h - btn_height - 10
    local btn_start_x = (gfx.w - total_btn_width) / 2
    
    -- Import button
    local import_btn_x = btn_start_x
    local import_btn_y = btn_y
    
    -- Export button
    local export_btn_x = import_btn_x + btn_width + btn_spacing
    local export_btn_y = btn_y
    
    -- Settings button
    local settings_btn_x = export_btn_x + btn_width + btn_spacing
    local settings_btn_y = btn_y
    
    -- Cancel button
    local cancel_btn_x = settings_btn_x + btn_width + btn_spacing
    local cancel_btn_y = btn_y
    
    -- File info area for clicking to select file
    local visible_checkboxes = 0
    for _, cb in ipairs(checkboxes_list) do
        if cb.show_in_menu ~= false then visible_checkboxes = visible_checkboxes + 1 end
    end
    visible_checkboxes = visible_checkboxes + #get_visible_extra_settings()
    local file_info_y = header_height + vertical_margin + (visible_checkboxes * checkbox_row_height) + vertical_margin
    local file_info_hovered = (mouse_x > 0 and mouse_x < gfx.w and
                               mouse_y > file_info_y and mouse_y < file_info_y + file_info_height)

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
    if mouse_clicked and not dark_menu.active and not gui_msgbox.active then
        -- Cancel button
        if cancel_btn_hovered then
            save_window_position()
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
                    import_midi_banks = checkboxes_list[3].checked,
                    import_key_sigs = checkboxes_list[4].checked,
                    insert_on_new_tracks = checkboxes_list[5].checked,
                    insert_on_existing_tracks = checkboxes_list[6].checked,
                    insert_on_tracks_by_name = checkboxes_list[7].checked,
                    selected_tracks = selected_tracks
                }
                -- Execute import with selected options
                ImportMusicXMLWithOptions(selected_file_path, options)
                save_window_position()
                gfx.quit()
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
            pre_settings_width = gui.width
            pre_settings_height = gui.height
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

        -- Checkboxes (vertical layout - aligned, filtered by show_in_menu)
        local vis_idx = 0
        for i, cb in ipairs(checkboxes_list) do
            if cb.show_in_menu ~= false then
                local cb_x = gfx.w - horizontal_margin - checkbox_size
                local cb_y = header_height + vertical_margin + vis_idx * checkbox_row_height
                if mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
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
                    break
                end
                vis_idx = vis_idx + 1
            end
        end

        -- Extra settings (from M flags) - full-featured for articulations
        local extras = get_visible_extra_settings()
        local main_clicked_sym_box = false
        local main_clicked_defpath_box = false
        for j, item in ipairs(extras) do
            local cb_y = header_height + vertical_margin + vis_idx * checkbox_row_height
            if item.is_art then
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
            else
                -- Non-articulation extras with enhanced controls
                local mk = item.key
                local cb_x = gfx.w - horizontal_margin - checkbox_size

                if mk == "docker" or mk == "font" or mk == "midibank" then
                    -- Calculate button bounds (same as drawing)
                    local lbl_w = gfx.measurestr(item.label .. "  ")
                    local btn_x = horizontal_margin + lbl_w
                    local btn_w
                    if mk == "font" then
                        btn_w = gfx.w - horizontal_margin - btn_x
                    else
                        btn_w = cb_x - COL_SPACING - btn_x
                    end
                    if btn_w < 20 then btn_w = 20 end
                    -- Check checkbox click (docker/midibank only)
                    if mk ~= "font" and mouse_x > cb_x and mouse_x < cb_x + checkbox_size and
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

    -- Handle mousewheel for type buttons on art rows in main view
    if gfx.mouse_wheel ~= 0 and not dark_menu.active and not gui_msgbox.active then
        local mw_extras = get_visible_extra_settings()
        local mw_vis_idx = 0
        for _, cb in ipairs(checkboxes_list) do
            if cb.show_in_menu ~= false then mw_vis_idx = mw_vis_idx + 1 end
        end
        local mw_handled = false
        for _, mw_item in ipairs(mw_extras) do
            local mw_cb_y = header_height + vertical_margin + mw_vis_idx * checkbox_row_height
            if mw_item.is_art then
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
            elseif mw_item.key == "docker" or mw_item.key == "font" then
                local lbl_w = gfx.measurestr(mw_item.label .. "  ")
                local btn_x = horizontal_margin + lbl_w
                local m_cb_x = gfx.w - horizontal_margin - checkbox_size
                local btn_w
                if mw_item.key == "font" then
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
    settings_btn_hovered = (mouse_x > settings_btn_x and mouse_x < settings_btn_x + btn_width and
                            mouse_y > settings_btn_y and mouse_y < settings_btn_y + btn_height)
    cancel_btn_hovered = (mouse_x > cancel_btn_x and mouse_x < cancel_btn_x + btn_width and
                          mouse_y > cancel_btn_y and mouse_y < cancel_btn_y + btn_height)
    
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
    draw_header("IMPORT MUSICXML", header_height, gui.colors)
    draw_checkboxes_list(checkboxes_list, header_height, horizontal_margin, vertical_margin, 
                        checkbox_row_height, checkbox_size, max_label_width, gui.colors)
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
    
    -- Draw buttons (Import, Export, Settings, and Cancel)
    draw_button(import_btn_x, import_btn_y, btn_width, btn_height, "Import",
                import_btn_hovered, "IMPORT_BTN", gui.colors.BORDER, gui.colors.TEXT)
    draw_button(export_btn_x, export_btn_y, btn_width, btn_height, "Export",
                export_btn_hovered, "BTN", gui.colors.BORDER, gui.colors.TEXT)
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
        save_window_position()
        gfx.quit()
    end
end

-- Start the main loop
main_loop()
