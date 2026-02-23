## 🎸 Import MusicXML

This script imports an uncompressed MusicXML file (e.g., from Guitar Pro) into REAPER, preserving string/fret positions via MIDI channels and text events. It's designed to work seamlessly with **ReaTab Hero**, eliminating the need to manually reassign strings and frets after exporting MIDI.

### Features

- Parses `<string>` and `<fret>` elements and maps string numbers to MIDI channels (string 1 → channel 7, etc.)
- Converts fret numbers and articulations (slides, hammer-ons, harmonics, mutes, etc.) into text or marker events
- Handles drum parts with configurable per‑family channel mapping
- Expands repeats (forward/backward) and respects chord offsets
- Optionally imports tempo and time signature markers
- Creates separate MIDI tracks for each staff

### Installation

#### Via ReaPack (recommended)

1. In REAPER, open **Extensions → ReaPack → Manage Repositories**
2. Click **Add** and enter: `https://github.com/kkonstantin2000/konst_reascripts/raw/master/index.xml`
3. Click **OK**, then **Synchronize**
4. Find the script in the Action List: `Script: Import MusicXML.lua`

#### Manual

- Download `ImportMusicXML.lua` from the `ImportMusicXML` folder and place it in your REAPER Scripts directory.

### Usage

1. Run the script from the Action List.
2. Select an uncompressed `.xml` file (MusicXML).
3. Choose whether to import tempo/time signature markers.
4. New tracks will be created with MIDI items containing notes and text events.

For best results with ReaTab Hero, make sure the target track has the proper string tuning set (the script can now store tuning as track ExtState – see below).

### Feedback & Contributions

Found a bug? Have a feature request? Please open an issue on GitHub or post in the [REAPER forum thread](https://forum.cockos.com/showthread.php?t=307042).

### Credits

- Thanks to **ExtremRaym** for ReaTab Hero and for encouraging this project.
- Inspired by the REAPER scripting community.
