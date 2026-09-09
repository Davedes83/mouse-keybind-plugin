[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/O3N726LJT4)
# Mouse & Keybind Plugin

<img width="799" height="446" alt="Mouse   Keybind Settings" src="https://github.com/user-attachments/assets/3ab1498b-56fb-4fcc-b5c4-7d53f245fcf4" />



Your mouse feel and your keybindings, tuned from one icon in the bar. No digging through separate settings panels, no guessing why a shortcut silently does nothing.

Plugin ID: `davedes.mouse-keybind-settings`

## Features

🖱️ Mouse & Pointer

Dial in exactly how your cursor should feel:

* Cursor speed with flat 1:1 precision or dynamic acceleration
* Natural scroll + sensitivity
* Left-handed mode
* Focus-follows-cursor & auto-refocus
* Full button remapping, including synthetic press simulation (ydotool)
* Interactive test canvas — feel your changes before you commit

⌨️ Keybinds

See what's actually running on your system, fix problems in one click:

* Live summary of active, modified, and conflicting bindings
* Conflict detection with 1-click rebind
* Smart suggestions for free keys
* Full Keybind Manager one click away — search, edit, create, reset, enable/disable
* Safe Lua sync, so your config never gets messy
  
Why bother?

Because "just tweaking cursor speed real quick" shouldn't turn into a five-minute detour, and keybind conflicts shouldn't be something you discover by accident. One icon, both problems solved.

## Installation

Clone the repository into your user plugins directory and enable it:

```bash
git clone https://github.com/Davedes83/mouse-keybind-plugin \
  ~/.config/omarchy/plugins/davedes.mouse-keybind-settings
omarchy plugin add ~/.config/omarchy/plugins/davedes.mouse-keybind-settings --enable
```

Or install it directly from the repo URL:

```bash
omarchy plugin clone Davedes83/mouse-keybind-plugin --enable
```

Afterwards restart the shell to load the widget:

```bash
omarchy restart shell
```

### Optional: synthetic button simulation (ydotool)

The **button simulation** feature (test canvas / synthetic click) is **optional** and
requires a separate, manual setup. It is not part of the base plugin installation and
all mouse/keybind settings work without it. Missing `ydotool` disables only the
simulate action — the plugin reports `ydotool not installed` and does nothing else.

Set it up only if you want the synthetic-click helper:

```bash
# 1. Install the package (requires sudo, only needed if you want simulation)
sudo pacman -S ydotool

# 2. Activate the per-user service
systemctl --user enable --now ydotool.service
```

Afterwards, the toolbar **Test Canvas** and the `simulate-button` CLI command emit
synthetic clicks. If the socket is unavailable the plugin reports `ydotoold
unavailable` — restart the service to re-enable it.

## Usage

Left-click the toolbar icon to open the settings popup. Switch between the **Mouse Settings** and **Keybinds** tabs. Right-click the toolbar icon to quickly toggle between Precision (1:1) and Dynamic acceleration.

### CLI

Replace `$HOME` with your home directory; the plugin lives by default at
`~/.config/omarchy/plugins/davedes.mouse-keybind-settings/`.

```bash
P="$HOME/.config/omarchy/plugins/davedes.mouse-keybind-settings"

# Mouse
python3 "$P/mouse_ctl.py" status
python3 "$P/mouse_ctl.py" toggle-accel
python3 "$P/mouse_ctl.py" toggle-natural-scroll
python3 "$P/mouse_ctl.py" apply --json-data '{...}'
python3 "$P/mouse_ctl.py" simulate-button --button side_back

# Keybinds
"$P/bin/omarchy-keybinds" list
"$P/bin/omarchy-keybinds" set "SUPER + SHIFT + B" "My Browser" "omarchy-launch-browser"
"$P/bin/omarchy-keybinds" reset "SUPER + SHIFT + B"
"$P/bin/omarchy-keybinds" disable "SUPER + W"
```

### IPC

```bash
omarchy-shell davedes.mouse-keybind-settings toggle
omarchy-shell davedes.mouse-keybind-settings toggleAccel
omarchy-shell shell summon davedes.mouse-keybind-settings '{}'
```

## License

MIT

## Buy Me A Coffee

Enjoying the plugin? You can support my work by buying me a coffee!:

- &#9749; [Buy me a coffee on PayPal](https://www.paypal.com/paypalme/DavidDesousa13) (@DavidDesousa13)

