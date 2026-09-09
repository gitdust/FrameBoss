# FrameBoss

A lightweight, standalone **boss unit frame** addon for World of Warcraft (Retail). It replaces the default boss frames with up to five clean frames (`boss1`–`boss5`) that appear only during boss encounters and hide automatically when the boss units are gone.

## Features

- **Boss fights only** — driven by `INSTANCE_ENCOUNTER_ENGAGE_UNIT`; frames show on pull and vanish when the encounter ends
- **Compact layout** — a 56×56 portrait, a large 32px health bar with 2-decimal percentage text (`Offline` / `Dead` states included), and a 24px power bar that colors itself by power type and auto-hides for bosses without power
- **Smart auras**, rendered through Blizzard's native AuraContainer so they keep working with the "secret" encounter values introduced in 12.x:
  - **Stealable** (Spellsteal) and **offensively dispellable** (Enrage) boss buffs — enlarged 20×20 icons with type-colored glowing borders
  - Ordinary boss buffs — smaller 16×16 icons
  - Only **your own debuffs** (including your pet/vehicle) — 16×16 icons with cooldown sweeps and stack counts
- **Bilingual UI** — English (default) and Simplified Chinese, selected automatically from your client locale
- **Settings panel** (`/fb`) — overall scale, power bar toggle, health bar color, edit mode (unlock and drag), reset position, and AceDB profiles
- **Test mode** — `/fb test` previews all five frames anywhere in the world, making positioning easy
- **Standalone and lightweight** — built on native Blizzard APIs with Ace3 embedded; no ElvUI, WeakAuras, or all-in-one pack required

## Commands

| Command | Action |
|---|---|
| `/fb` or `/frameboss` | Open the settings panel |
| `/fb test` or `/fb edit` | Toggle edit mode (unlock drag + show test frames) |

## Installation

1. Copy the `FrameBoss` folder into `World of Warcraft\_retail_\Interface\AddOns\`
   - Everything needed is already inside the folder, including the embedded Ace3 libraries — no separate library download
2. In-game, run `/fb test` to preview and position the frames, then take them into a dungeon or raid to try them live

## Why FrameBoss?

I'm a standalone-addon player — I build my UI from individual addons and have never used an all-in-one compilation pack. I couldn't find an in-combat boss frame addon I actually enjoyed using, so I wrote FrameBoss myself, with the help of AI. It does exactly what I want and nothing more.
