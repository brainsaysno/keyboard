# brainsaysno/keyboard

This is my [ZMK](https://zmk.dev/) config for my wireless, low profile [Corne](https://github.com/foostan/crkbd) build using nice!nano v2s and nice!view displays. It's part of my first pocketable build. Should be fairly straightforward to adapt to other setups. I also modeled and 3D printed a case for it.

![keyboard-build-setup](https://github.com/user-attachments/assets/021763f0-819f-497b-8a1f-c22a8b14172a)

## Layout

3x6 Corne split.

- **Base:** QWERTY-ish
- **Lower:** Numbers, arrow keys (in vim's hjkl), and mouse emulation (right below it)
- **Raise:** Symbols as well as media, bluetooth and brightness controls

## Cool Tweaks

- **Ctrl/Esc combo:** Hold for ctrl, tap for escape. This is my most used keymap by far, and it's nice to have it in the firmware so it works in iOS as well
- **Mouse emulation:** Move cursor and right/left click from the lower layer
- **Globe key:** For dictation with Wispr Flow
- **Media and brightness controls:** On the raise layer
- **Bluetooth profiles:** Quick switching across 5 devices
- **Cool art:** By [Hammerbeam](https://x.com/hammerbeam_tea), plugin by [@GPeye](https://github.com/GPeye/hammerbeam-slideshow). Keeping as a placeholder until I have some time to learn how to configure the display.

## Usage

There's a GitHub Action that handles the build, which is probably the easiest way to get started. Flash it and you're good to go.

Feel free to use or adapt any of this for your own build.
