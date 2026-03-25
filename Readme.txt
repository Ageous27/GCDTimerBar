GCDTimerBar (Turtle WoW 1.12)

Simple global cooldown bar addon for Turtle WoW.

Dependencies:
- Required: none
- Optional: Nampower + SuperWoW
  - If present, the addon reads Nampower queue settings and uses the real spell queue window
    to draw the press-early overlay.
  - If not present, the addon falls back to adaptive latency+jitter estimation.

Features:
- Horizontal bar that drains from right to left during GCD.
- Purple press-early overlay (left edge) for queue timing.
- /gcd opens options.
- Lock/Unlock bar movement.
- Click-through when locked.
- Width and height sliders.
- Opacity slider.
- Color picker.
- Optional hide out of combat.
- Preview simulation while options window is open.

Files:
- GCDTimerBar.toc
- GCDTimerBar.lua

Install:
1) Copy the GCDTimerBar folder into Interface\AddOns\
2) Reload UI or restart the game.

Command:
- /gcd
