![Codex Travel Mode](image.png)

# Codex Travel Mode

Codex Travel Mode is a macOS menu-bar app for keeping Codex work alive while
moving a MacBook. It keeps the current Wi-Fi network when connected, uses the
iPhone hotspot only as a fallback when Wi-Fi disconnects, and can optionally
enable a privileged lid-closed sleep override for the active travel session.

The app auto-detects the Wi-Fi device, lists saved or currently visible hotspot
networks, and lets you save the selected fallback hotspot plus password. The
main widget shows the selected fallback hotspot and whether Codex is currently
running.

## Run

```bash
swift run codex-travel-mode
```

## Build

```bash
swift build -c release
```

## Safety

The lid-closed override always runs while Travel Mode is active. It uses
`pmset -a disablesleep` through a macOS administrator prompt and restores normal
sleep behavior when Travel Mode stops.

Use this tool at your own risk. The lid-closed override uses Apple's own `pmset` tooling, and thermal risk should be low during short, supervised periods. Never put your MacBook in a bag or another enclosed space while Travel Mode is active. Keep it ventilated, monitor its temperature, and stop Travel Mode if it becomes unusually hot. I cannot guarantee the safety of your Mac or data.
