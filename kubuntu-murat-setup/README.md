# kubuntu-murat-setup

## macOS-like Magic Keyboard (Kubuntu / Plasma 6 / Wayland)

Your machine: Ubuntu 26.04, Plasma 6.6 on Wayland, Apple Magic Keyboard A1644 (`05ac:0267`).

### Research

There is no good KDE-only checkbox for this. Mapping Super→Ctrl in System Settings makes `Cmd+C` copy, but then **physical Ctrl+C in a terminal becomes copy instead of SIGINT**, and `Cmd+arrows` / `Option+arrows` / `Cmd+Backspace` still do the wrong thing. Plasma shortcuts only cover KDE/Qt apps, not Chrome/Firefox/GTK.

| Tool | Verdict on this machine |
| --- | --- |
| **[Kinto](https://github.com/rbreaves/kinto)** | Built for this, but **X11-only** (xkeysnail). Skip on Wayland. |
| **[Toshy](https://github.com/RedBearAK/toshy)** | Best *full* Mac recreation (per-app maps, terminal-aware Cmd+C, Option special chars, KDE Wayland support). Heavy: Python venv, KWin script, many deps. Use this if the script below is not enough. |
| **[keyd](https://github.com/rvaiya/keyd)** | In Ubuntu 26.04 (`apt install keyd`). Evdev-level, works on Wayland, easy to undo. Official `macos.conf` is for **PC** keyboards (Alt as Cmd). This repo ships an **Apple** variant (Command is already Super). |
| `hid_apple swap_opt_cmd` | Only swaps Option/Command. Does not give macOS shortcuts. |
| input-remapper / xremap | Possible, not packaged as cleanly, harder to undo as one unit. |

This repo uses **keyd** plus `hid_apple fnmode=1` (media keys by default, Fn for F1–F12, like macOS). Physical Control is never remapped.

### Apply / undo

```bash
./macos-keyboard.sh apply     # needs sudo; installs keyd if missing
./macos-keyboard.sh revert    # keyboard back to stock Linux
./macos-keyboard.sh status
```

If a bad map bricks input: hold **Backspace + Escape + Enter** (keyd panic combo), then `./macos-keyboard.sh revert`.

Ubuntu renamed the binary to `keyd.rvaiya` (name clash with another package). The systemd unit is still `keyd.service`.

### Behaviour

| You press | Result |
| --- | --- |
| Cmd+C / V / X | Copy / paste / cut (Ctrl+Insert / Shift+Insert / Shift+Delete — **safe in terminals**) |
| Cmd+A S Z F T W N | Select-all, save, undo, find, new tab, close, new window |
| Cmd+Left / Right | Start / end of line |
| Cmd+Up / Down | Start / end of document |
| Option+Left / Right | Word jump |
| Cmd+Backspace | Delete to start of line |
| Option+Backspace | Delete previous word |
| Cmd+Delete | Delete to end of line |
| Option+Delete | Delete next word |
| Cmd+Tab / Cmd+\` | App switcher / windows of this app |
| Cmd+Space | KRunner |
| Cmd+Q | Close window |
| Cmd+T in Konsole | New tab (Konsole default is Ctrl+Shift+T; overlay also keeps that) |
| Cmd+Shift+3 / 4 | Screenshot / region (Spectacle) |
| **Ctrl+C** (physical Control) | Unchanged — SIGINT in a terminal |

KDE Meta shortcuts that would steal Cmd (Overview on Meta+W, clipboard on Meta+V, tiling on Meta+arrows) never see Command, because keyd consumes it first.

### Limits vs Toshy

- No per-app maps: in a terminal, **Cmd+W is Ctrl+W** (delete word in readline) rather than “close tab”.
- No macOS Option-key special characters (Option+2 = ™, dead keys, …).
- Cmd+Left in a browser with no text focus will not go Back (it sends Home). Use Cmd+[ / Cmd+] for back/forward.

Edit `macos-keyboard/keyd/macos-magic-keyboard.conf`, then `./macos-keyboard.sh reload`.

## 3-finger swipe back / forward

Plasma hardcodes 3-finger left/right to virtual desktops. There is no System Settings remap. This installs [InputActions](https://github.com/taj-ny/InputActions) as a KWin effect and maps the gesture to Alt+Left / Alt+Right.

```bash
./three-finger-nav.sh apply      # needs sudo for apt + plugin install
./three-finger-nav.sh revert     # stock Plasma gestures
./three-finger-nav.sh status
./three-finger-nav.sh rebuild    # after a Plasma / KWin upgrade
```

| Gesture | Result |
| --- | --- |
| 3-finger swipe left | Back |
| 3-finger swipe right | Forward |

Edit `three-finger-nav/config.yaml`, then `./three-finger-nav.sh reload`.
