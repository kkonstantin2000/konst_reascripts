## 🎸 MusicXML Tools for REAPER

This script imports and exports **MusicXML** files directly inside REAPER while preserving guitar-specific information such as **string and fret positions**, articulations, and track structure.

It was originally designed to work seamlessly with **ReaTab Hero**, eliminating the need to manually reassign strings and frets after exporting MIDI from notation software like Guitar Pro. The script has since grown into a more complete **MusicXML workflow tool for REAPER**, supporting both import and export, articulation editing, and flexible project integration.

---

## Features

### MusicXML Import

- Parses `<string>` and `<fret>` elements and maps string numbers to MIDI channels (string 1 → channel 7, etc.)
    
- Preserves guitar articulation information such as slides, hammer-ons, vibrato, harmonics, bends, mutes, and more
    
- Converts articulations into **text events, markers, or cue events** (fully configurable)
    
- Handles **drum parts** with configurable per-family MIDI channel mapping
    
- Expands repeat sections (forward/backward repeats)
    
- Supports chord offsets and complex rhythmic structures
    
- Optional **tempo and time signature import**
    

### MusicXML Export

- Export selected **MIDI items back to MusicXML**
    
- Preserves:
    
    - measures
        
    - staff grouping
        
    - notes
        
    - articulations
        
- Supports **key signatures via REAPER KSIG notation events**
    
- Includes a small UI to quickly set key signatures before export
    
- Preserves **MIDI bank/program data** (Bank Select MSB/LSB + Program Change)
    

### Track & Project Integration

- Creates separate MIDI tracks for each staff
    
- Three insertion modes:
    
    - **Create new tracks** – original behavior
        
    - **Insert on existing tracks** – places MIDI items on selected tracks
        
    - **Match tracks by name** – automatically maps staves to existing tracks
        
- Stores **string tuning as track ExtState** for compatibility with ReaTab Hero
    

### Articulation Workflow

- Fully configurable articulation system
    
- Each articulation can define:
    
    - symbol text
        
    - event type (Text / Marker / Cue)
        
    - fret replacement behavior
        
    - enable/disable toggle
        
- Click articulation labels in settings to **insert articulation text events directly on selected MIDI notes**
    
- **Alt + Click** removes articulation events
    

### User Interface & Workflow

- Dedicated GUI with organized settings sections:
    
    - GENERAL
        
    - IMPORT
        
    - EXPORT
        
    - ARTICULATION
        
- Drag & drop MusicXML files directly onto the script window
    
- Custom dark-themed UI elements:
    
    - scrollable menus
        
    - message boxes
        
    - unified scrollbars
        
- Dockable window (top / bottom / left / right)
    
- Optional **stay-on-top mode**
    
- Optional **auto-focus on mouse hover**
    
- Font selection for the UI
    
- Window position memory
    
- Default / last path handling for file browsing
    
- Open exported file or folder automatically after export
    

---

## Installation

### Via ReaPack (recommended)

1. In REAPER open **Extensions → ReaPack → Import Repositories**
    
2. Paste the repository link
    

https://raw.githubusercontent.com/kkonstantin2000/konst_reascripts/master/index.xml

3. Click **OK**
    
4. Run **Extensions → ReaPack → Synchronize packages**
    
5. Install:
    

Script: konst_Import MusicXML.lua

---

### Manual Installation

Download:

konst_Import MusicXML.lua

from the repository and place it in your **REAPER Scripts** directory, then load it via the **Action List**.

---

## Usage

1. Run the script from the **Action List**
    
2. Select an uncompressed **MusicXML (.xml)** file
    
3. Choose import settings (tempo markers, articulation behavior, etc.)
    
4. Import the file
    

The script will create MIDI items containing notes, string channel information, and articulation events.

For best results with **ReaTab Hero**, ensure the target track has the correct tuning. The script can automatically store tuning data as **track ExtState**.

---

## Feedback & Contributions

If you encounter a bug or have a feature request:

- Open an issue on GitHub
    
- Or post in the REAPER forum thread
    

[https://forum.cockos.com/showthread.php?t=307042](https://forum.cockos.com/showthread.php?t=307042)

---

## Credits

Thanks to **ExtremRaym** for creating **ReaTab Hero** and for helpful feedback during development.
