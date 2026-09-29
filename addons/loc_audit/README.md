# Loc Audit Lite

**Free version of [Loc Audit](https://theidlehands.itch.io/loc-audit) for Godot 4.4 – 4.7.**

Takes stock of your translation CSV against your code and scenes: untranslated keys, unused keys, keys used but never defined, and strings never wrapped in `tr()`.

## Getting started

1. Copy `addons/loc_audit/` into your project.
2. **Project → Project Settings → Plugins**, enable **Loc Audit Lite**.
3. The dock appears bottom-right. Enter your translation CSV and press **Missing / unused keys**.

The `demo/` folder is a small project with one of every fault planted in it.

## The full version adds

- **Check overflow**: lays every scene out in every locale and reports the layouts a long translation pushes wider or clips. The part a character count cannot find
- **CSV to PO and PO to CSV** for handing work to translators and merging it back

→ **[Loc Audit on itch.io](https://theidlehands.itch.io/loc-audit)**

The full version installs into the same `addons/loc_audit/` folder, so it replaces
this one in place.

## What it will not tell you

A clean report is a measurement against the checks above, not a guarantee.
The full version's page lists every limit in detail.

## Licence

The Lite version is MIT licensed (see `LICENSE`). The full version is sold
separately under its own licence.
