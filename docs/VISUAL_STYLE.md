# tty.build visual style

tty.build uses a deliberately monochrome visual system. The application shell,
brand mark, controls, widgets, Live Activity, Dynamic Island, Watch app, and
menu-bar app use only black, white, and neutral opacity levels by default.

## Semantic palette

Apple-platform surfaces must use `TTYBuildTheme` rather than raw decorative
colors:

- `canvas`: black backgrounds.
- `content`: primary white content and the global control tint.
- `secondaryContent` / `tertiaryContent`: hierarchy without hue.
- `surface`, `separator`, and `selection`: white at low opacity.
- `warning`: system orange, only for offline or stale data.
- `critical`: system red, only for invalid input, errors, destructive actions,
  or a terminal that has exited.

Normal, connected, and active states do not use green. Buttons and links do not
use the system blue accent. State must remain understandable from copy, icons,
shape, and opacity without relying on color alone.

## Necessary exceptions

Terminal ANSI output and user-selected Ghostty themes are content controlled by
the remote program or the user; they are not application chrome and may use
color. Theme/background swatches may preview those choices. Monochrome
pairing-code panels retain maximum contrast for readability.

When adding a surface, prefer semantic roles from `TTYBuildTheme`. A new hue needs
an information-bearing purpose and must not duplicate meaning already conveyed
by text or shape.

## Widget simplicity

Every Widget and Live Activity has one primary job: show the current running TTY
count. The monospaced number is the dominant element; a terminal symbol appears
only where a compact surface needs source identity. Successful state,
online-computer counts, separators, and routine update timestamps are not shown.
A surface may add at most one secondary line or symbol, and only when the
snapshot is stale or a computer is offline. Capacity gauges are not used because
the TTY count has no meaningful fixed maximum.
