# Gloam
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078d4?logo=windows)
![Language](https://img.shields.io/badge/language-AutoHotkey%20v2-334455?logo=autohotkey)
[![Release](https://img.shields.io/github/v/release/geethut-stack/Gloam)](https://github.com/geethut-stack/Gloam/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/geethut-stack/Gloam/total)](https://github.com/geethut-stack/Gloam/releases)
[![License: MIT](https://img.shields.io/github/license/geethut-stack/Gloam)](LICENSE)
> The free, open-source, all-in-one monitor control and eye protection tool for Windows: brightness, dimmer and blue-light filter in one tiny tray app.

Gloam is a free and open-source Windows tray utility, written in [AutoHotkey v2](https://www.autohotkey.com/), that puts everything you need to control your screens and protect your eyes in one place:

- **Hardware brightness** over DDC/CI: changes the monitor's real backlight, just like the buttons on the monitor.
- **Software dimmer** and **blue-light filter** via the GPU gamma ramp: no overlay window, so screenshots, fullscreen apps and games are unaffected.
- **Scenes** (Reading / Office / Movie / Night) and an **automatic day/night schedule** that fades smoothly between two scenes.

Left-click the tray icon (or press `Win+Alt+B`) to open a compact dark control panel in the bottom-right corner of the screen.
<img width="302" height="347" alt="image" src="https://github.com/user-attachments/assets/055d61f0-6b0e-4f4d-aa3c-43b7e2671ce3" />

## Features

- Hardware brightness slider and quick presets (25 / 50 / 75 / 100 %) for the primary monitor
- Software dimmer (1-100 %) and blue-light filter (0-100 %)
- Per-monitor dimmer settings, or apply to **All Monitors** at once
- Four built-in scenes, all editable at the top of the script
- Auto schedule with a gradual fade (default: 07:00 day, 20:00 night, 60 min transition)
- Optional "wider dimming range" to dim down to 1 % instead of Windows' default 50 % floor
- Settings remembered between runs
- Handles monitors being plugged in/out, and re-applies the gamma ramp if sleep, unlock or another app resets it
- Original gamma is restored when the script exits

## Requirements

- Windows 10 or 11
- [AutoHotkey v2.0](https://www.autohotkey.com/) (the script uses `#Requires AutoHotkey v2.0`)
- For hardware brightness: a monitor with **DDC/CI** enabled (see [Troubleshooting](#troubleshooting)). The dimmer and blue-light filter work without it.

## Installation

1. Install AutoHotkey v2.
2. Download `Gloam.ahk` from this repository [Releases](../../releases).
3. Double-click it. A tray icon appears and the script is running.

To start it with Windows, put a shortcut to the script in your Startup folder (`Win+R`, type `shell:startup`, press Enter).

## Usage

### Hotkeys

| Hotkey | Action |
| --- | --- |
| `Win+Alt+B` | Show / hide the control panel |
| `Win+Alt+Up` / `Win+Alt+Down` | Hardware brightness +10 % / -10 % (primary monitor) |
| `Win+Alt+Right` / `Win+Alt+Left` | Software dimmer +5 % / -5 % (selected monitor(s)) |
| `Win+Alt+X` | Turn the dimmer on / off |
| `Win+Alt+F1` | Scene: **Reading** |
| `Win+Alt+F2` | Scene: **Office** |
| `Win+Alt+F3` | Scene: **Movie** |
| `Win+Alt+F4` | Scene: **Night** |

### Control panel

- **Monitor selector**: choose which monitor the dimmer and blue-light sliders affect, or "All Monitors".
- **Brightness (monitor)**: hardware brightness via DDC/CI, with 25 / 50 / 75 / 100 % preset buttons.
- **Dimmer**: software dimming through the gamma ramp.
- **Blue light filter**: reduces the green and blue channels for a warmer picture.
- **Scene buttons**: Reading, Office, Movie, Night.

The panel closes when it loses focus, when you press `Esc`, or when you click the red ✕.

### Tray menu

- **Brightness Control**: open the panel (this is also the single-click action)
- **Dimmer enabled**: toggle the dimmer
- **Auto schedule (day/night)**: fade automatically between the day and night scenes
- **Wider dimming range (admin + restart)**: see below
- **Exit**: restores the original gamma and quits

## Scenes

Each scene is `[dimmer %, blue-light filter %]`:

| Scene | Dimmer | Blue-light filter |
| --- | --- | --- |
| Reading | 75 % | 35 % |
| Office | 90 % | 10 % |
| Movie | 60 % | 25 % |
| Night | 30 % | 60 % |

Scenes apply to the monitor(s) currently selected in the panel. Note that the Night scene's 30 % dimmer needs the wider dimming range (see below); otherwise it is clamped to 50 %.

## Auto schedule

When enabled from the tray menu, the script blends from `DAY_SCENE` to `NIGHT_SCENE` and back over the configured transition time, checking every 30 seconds. Defaults:

| Setting | Default |
| --- | --- |
| Day starts | 07:00 |
| Night starts | 20:00 |
| Fade length | 60 minutes |
| Day scene | Office |
| Night scene | Night |

Manual tweaks stick between fades: the schedule only overwrites your values while the fade is actually moving.

## Wider dimming range

By default Windows rejects gamma ramps darker than about 50 %, so the dimmer cannot go below that. The tray option **Wider dimming range (admin + restart)** sets the registry value

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ICM
    GdiIcmGammaRange = 256 (DWORD)
```

which unlocks dimming down to 1 %. It needs administrator rights (the script asks via UAC) and a Windows restart, after which you start the script again. Choosing the option again removes the value and returns to the default range.

## Configuration

Edit the settings block at the top of `Gloam.ahk`:

```ahk
STEP        := 10                  ; hardware hotkey step (%)
DIM_STEP    := 5                   ; dimmer hotkey step (%)
PRESETS     := [25, 50, 75, 100]   ; hardware preset buttons (%)
THROTTLE_MS := 40                  ; min delay between DDC/CI writes while dragging

SCENES := Map("Reading", [75, 35]
            , "Office",  [90, 10]
            , "Movie",   [60, 25]
            , "Night",   [30, 60])

DAY_START   := 7  * 60             ; minutes after midnight
NIGHT_START := 20 * 60
TRANSITION  := 60                  ; length of the fade, in minutes
DAY_SCENE   := "Office"
NIGHT_SCENE := "Night"
```

Your dimmer values, blue-light values and auto-schedule state are saved to an `.ini` file next to the script (same name, `.ini` extension) when the panel closes and when the script exits.

## How it works

- **Hardware brightness** uses the Windows `dxva2` monitor configuration API (`SetMonitorBrightness`, with a fallback to VCP feature `0x10`) to talk to the monitor over DDC/CI. Writes are throttled so dragging the slider doesn't flood the display bus.
- **Software dimming** scales the red, green and blue channels of each display's gamma ramp with `SetDeviceGammaRamp`. The blue-light filter lowers green by up to 28 % and blue by up to 62 %. If Windows rejects a ramp as too dark, the script backs off step by step until one is accepted.
- The gamma ramp is re-applied every 5 seconds, because sleep, unlock and some other apps can reset it.

## Limitations

- Hardware brightness controls the **primary monitor** only. The dimmer and blue-light filter work on every monitor.
- Other programs that also change the gamma ramp (colour calibration tools, other blue-light or night-mode utilities) will compete with this script, so run only one at a time.
- Because the dimmer works through the gamma ramp, it reduces the output levels of your display; it does not change backlight strength.
- Windows only.

## Troubleshooting

**"Failed to initialize monitor" / hardware slider shows N/A**

1. Enable **DDC/CI** in the monitor's on-screen display (OSD) menu.
2. Unplug and replug the monitor's cable.
3. Update your graphics drivers.

Some connections (certain docks, adapters and KVM switches) and most built-in laptop panels don't support DDC/CI. In that case the dimmer and blue-light filter still work.

**The dimmer won't go below 50 %**: enable the wider dimming range described above.

**Colours look wrong after the script crashed**: restart the script and exit it from the tray menu, which restores the default gamma ramp. Signing out or restarting Windows also resets it.

## License

Gloam is free and open source. 
