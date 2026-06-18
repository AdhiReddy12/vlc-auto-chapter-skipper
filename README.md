# ⏭ Auto Chapter Skipper — VLC Extension

Automatically skips intro, opening, ending, and credits chapters in VLC media player.

![VLC Extension](https://img.shields.io/badge/VLC-Extension-orange?style=flat-square&logo=vlcmediaplayer)
![Lua](https://img.shields.io/badge/Lua-5.1+-blue?style=flat-square&logo=lua)
![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)

## ✨ Features

- **Auto-skip chapters** matching configurable keywords (intro, opening, ending, credits, etc.)
- **Case-insensitive substring matching** — "Opening Theme" matches the keyword "opening"
- **OSD notifications** — shows what was skipped and what's playing now
- **Settings dialog** — customize keywords, enable/disable, view chapter list
- **Persistent config** — settings survive VLC restarts
- **Loop prevention** — won't get stuck re-skipping the same chapter

## 📦 Installation

### Automatic (Windows)

Run the included install script:

```powershell
.\install.ps1
```

### Manual

1. **Install the GUI Extension:** Copy `autoskip_chapters.lua` to your VLC extensions directory.
2. **Install the Background Watcher:** Copy `autoskip_bg.lua` to your VLC intf directory.

| OS      | Extensions Path | Intf Path |
|---------|-----------------|-----------|
| Windows | `%APPDATA%\vlc\lua\extensions\` | `%APPDATA%\vlc\lua\intf\` |
| Linux   | `~/.local/share/vlc/lua/extensions/` | `~/.local/share/vlc/lua/intf/` |
| macOS   | `~/Library/Application Support/org.videolan.vlc/lua/extensions/` | `~/Library/Application Support/org.videolan.vlc/lua/intf/` |

> **Note:** Create the `extensions` and `intf` folders if they don't exist.

3. **Enable Background Watcher in VLC:**
   - Open your VLC configuration file (`vlcrc`), usually located one level above the `lua` folder.
   - Find the line `extraintf=` and append `luaintf` (e.g. `extraintf=luaintf`).
   - Find the line `lua-intf=` and set it to `autoskip_bg` (e.g. `lua-intf=autoskip_bg`).

## 🚀 Usage

1. **Restart VLC** after installing
2. Go to **View** → **Auto Chapter Skipper** to activate the extension
3. Play any media with named chapters (MKV, DVD, etc.)
4. Chapters matching skip keywords are automatically skipped!

### Settings

Go to **View** → **Auto Chapter Skipper** → **Settings** to:

- ✅ Enable/disable auto-skip
- 📝 Edit skip keywords (comma-separated)
- 📋 View all chapters in the current media
- 🔄 Reset to default keywords

## 🏷️ Default Skip Keywords

The extension ships with these default keywords (case-insensitive substring match):

| Keyword              | Typical Use                    |
|----------------------|--------------------------------|
| `intro`              | Show intros                    |
| `opening` / `op`     | Anime/TV opening themes        |
| `ending` / `ed`      | Anime/TV ending themes         |
| `credits`            | End credits                    |
| `closing`            | Closing sequences              |
| `preview`            | Next episode previews          |
| `next episode preview` | Extended preview segments    |
| `prologue`           | Pre-story segments             |
| `recap`              | "Previously on..." segments    |

### Custom Keywords

Add your own keywords in the Settings dialog. Examples:

```
intro, opening, op, ending, ed, credits, previously on, cold open
```

## 🔧 How It Works

```
┌──────────────────────────┐      ┌──────────────────────────┐
│   Extension (Settings)   │      │ Background Watcher (intf)│
│                          │      │                          │
│  • Manages Config File   │      │  ┌────────────────────┐  │
│  • Provides Settings GUI │      │  │ Poll Current Chapter│  │
│                          │      │  └─────────┬──────────┘  │
└────────────┬─────────────┘      │            │             │
             │                    │      Match found?        │
             ▼                    │      ╱          ╲        │
  ┌──────────────────────┐        │    Yes           No      │
  │ autoskip_chapters.conf│       │    ╱               ╲     │
  └──────────────────────┘        │ ┌──────▼──────┐ (wait for│
             ▲                    │ │ Skip to next│ next poll│
             │                    │ │   chapter   │   500ms) │
             │                    │ └──────┬──────┘          │
             │                    │        │                 │
             │                    │ ┌──────▼──────┐          │
             │                    │ │  Show OSD   │          │
             │                    │ │ notification│          │
             │                    │ └─────────────┘          │
             │                    └──────────────────────────┘
```

**Dual-script architecture:** 
1. **GUI Extension** (`autoskip_chapters.lua`): Provides the settings menu and saves your configuration to a file.
2. **Background Watcher** (`autoskip_bg.lua`): Runs continuously in the background using VLC's `luaintf` module. It polls playback state every 500ms to detect chapter changes even when you seek manually.

## ⚠️ Requirements

- **VLC 3.0+** (tested with VLC 3.x and 4.x)
- Media files with **named chapters** (MKV, MP4 with chapters, DVD, Blu-ray rips)

> **Note:** The extension only works with media that has embedded chapter markers with titles. Files without chapters are unaffected.

## ⚖️ Terms and Conditions (Disclaimer)

By using this extension, you agree that you use it at your own risk. The creator is not responsible for any failures, issues, or data loss that may occur. This software is provided "as is", without warranty of any kind.

## 📄 License

MIT License — free to use, modify, and distribute.
