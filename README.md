<div id="top"></div>

<div align="center">

[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]

</div>

<br />
<div align="center">
  <a href="https://github.com/brainsaysno/keyboard">
    <img width="30%" alt="Keyboard build" src="https://github.com/user-attachments/assets/021763f0-819f-497b-8a1f-c22a8b14172a"/>
  </a>
  <br/>
  <i> zmk config for my wireless, low profile corne build with nice!nano v2s and nice!view displays </i>
  <br/>
  <br/>

<h1 align="center">keyboard</h1>
  <p align="center">
    <a href="https://github.com/brainsaysno/keyboard"><strong>Explore docs »</strong></a>
    <br />
    <br />
    <a href="https://github.com/brainsaysno/keyboard/issues/new?labels=enhancement">Suggest a feature</a>
    ·
    <a href="https://github.com/brainsaysno/keyboard/issues/new?labels=bug">Report a bug</a>
  </p>
</div>

<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About the Project</a>
      <ul>
        <li><a href="#cool-tweaks">Cool Tweaks</a></li>
      </ul>
    </li>
    <li><a href="#layout">Layout</a></li>
    <li><a href="#usage">Usage</a></li>
  </ol>
</details>

## About the Project

My [zmk](https://zmk.dev/) config for my wireless, low profile [corne](https://github.com/foostan/crkbd) build using nice!nano v2s and nice!view displays. It's part of my first pocketable build. Should be fairly straightforward to adapt to other setups. I also modeled and 3D printed a case for it.

### Cool Tweaks

- **Ctrl/Esc combo:** Hold for ctrl, tap for escape. This is my most used keymap by far, and it's nice to have it in the firmware so it works in iOS as well
- **Mouse emulation:** Move cursor and right/left click from lower layer; Shift with mouse up/down scrolls
- **Clipboard history:** Lower+C sends F18, bound in Raycast to Clipboard History
- **Globe key:** For dictation with Wispr Flow
- **Media and brightness controls:** On raise layer
- **Bluetooth profiles:** Quick switching across 5 devices
- **Cool art:** By [Hammerbeam](https://x.com/hammerbeam_tea), plugin by [@GPeye](https://github.com/GPeye/hammerbeam-slideshow). Keeping as a placeholder until I have some time to learn how to configure the display

## Layout

3x6 Corne split.

- **Base:** QWERTY-ish
- **Lower:** Numbers, arrow keys (vim hjkl), mouse movement/scrolling, clipboard history, direct Bluetooth profile selection
- **Raise:** Symbols, media, AirPods hotkeys, brightness controls
- **Adjust:** Bluetooth setup. Hold both Lower and Raise to activate it; release either to leave it.

### Audio and AirPods keys

Hold the right-thumb Raise key and press the physical key listed below:

| Key | Action | Keycode |
| --- | --- | --- |
| Z | Output mute | `C_MUTE` |
| X | AirPods ANC hotkey | `F19` |
| C | AirPods Transparency hotkey | `F20` |
| V | Brightness down | `C_BRI_DN` |
| B | Brightness up | `C_BRI_UP` |

The existing media controls on Raise+A/S/D/F/G are unchanged.

The firmware only sends `F19` and `F20`; Raycast hotkeys turn them into listening-mode changes. See [Mac setup](#mac-setup).

### Bluetooth setup

Hold both layer thumb keys to access Adjust:

- A/S/D/F/G select Bluetooth profiles 1 through 5, matching the existing Lower shortcuts.
- Z selects the previous profile; C selects the next profile.
- X clears the selected keyboard profile's pairing. Use it only when re-pairing, not to disconnect a device.

Other Adjust keys are disabled to prevent media or typing actions from falling through. Lower+A/S/D/F/G remain available for quick device switching without holding both thumbs.

### Clipboard history and scrolling

| Binding | Action |
| --- | --- |
| Lower+C | Send `F18` for Raycast Clipboard History |
| Lower+M | Move mouse down |
| Lower+comma | Move mouse up |
| Lower+Shift+M | Scroll down |
| Lower+Shift+comma | Scroll up |

Hold Shift before pressing the mouse key. To switch between moving and scrolling, release the mouse key, change Shift, and press it again. Left/right mouse movement and the H/J/K/L arrow keys are unchanged, including Shift+arrows for selecting text. Scroll direction follows the host's mouse scrolling settings.

The local `zmk,behavior-shift-scroll` behavior sends a keyboard modifier report before scrolling. Stock ZMK v0.3 mod-morph masks modifiers internally but does not itself send that report, and a mouse behavior does not send one either. The helper suppresses Shift during scrolling and restores it when the last scrolling key is released, preventing the host from interpreting vertical wheel events as Shift-scroll.

### Mac setup

Raycast hotkeys handle the F-keys, so Karabiner-Elements is not needed. Karabiner leaves the Corne alone by default because it is both a keyboard and a pointing device.

1. Build the AirPods helper and link its Raycast script commands into a Raycast script directory (here `~/.config/raycast/scripts`):

   ```sh
   swiftc -O macos/airpods-mode.swift -o ~/.local/bin/airpods-mode
   ln -s "$PWD"/macos/raycast/*.sh ~/.config/raycast/scripts/
   ```

2. In Raycast Settings → Extensions, record these hotkeys by pressing the Corne keys:

   | Raycast command | Corne keys | Key sent |
   | --- | --- | --- |
   | Clipboard History | Lower+C | `F18` |
   | AirPods Noise Cancellation | Raise+X | `F19` |
   | AirPods Transparency | Raise+C | `F20` |

3. Turn off macOS mouse-wheel acceleration, which otherwise makes a held scroll key start slowly and then race. This applies to every mouse:

   ```sh
   defaults write -g com.apple.scrollwheel.scaling -float -1
   ```

macOS has no public API for AirPods listening modes, so `airpods-mode` clicks the mode in the menu bar's Sound menu through the Accessibility API, and the menu flashes briefly. It needs Raycast to have Accessibility permission and Sound set to always show in the menu bar (System Settings → Control Center). Ctrl+F2 (Move focus to the menu bar) must stay enabled: an auto-hidden menu bar ignores clicks until it has focus.

### Local validation

Run `python3 -m unittest discover -s tests -v` to check the keymap and the Shift-scroll helper's modifier and release behavior with a host C compiler. This is not a replacement for a full ZMK firmware build or on-device testing.

## Usage

There's a github action which handles the build. Flash it and you're good to go.

Feel free to use or adapt any of this for your own build.

[contributors-shield]: https://img.shields.io/github/contributors/brainsaysno/keyboard.svg?style=for-the-badge
[contributors-url]: https://github.com/brainsaysno/keyboard/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/brainsaysno/keyboard.svg?style=for-the-badge
[forks-url]: https://github.com/brainsaysno/keyboard/network/members
[stars-shield]: https://img.shields.io/github/stars/brainsaysno/keyboard.svg?style=for-the-badge
[stars-url]: https://github.com/brainsaysno/keyboard/stargazers
[issues-shield]: https://img.shields.io/github/issues/brainsaysno/keyboard.svg?style=for-the-badge
[issues-url]: https://github.com/brainsaysno/keyboard/issues
