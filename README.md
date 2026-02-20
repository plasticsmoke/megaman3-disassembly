# Mega Man 3 (NES) Disassembly — Annotated Fork

Fork of [refreshing-lemonade/megaman3-disassembly](https://github.com/refreshing-lemonade/megaman3-disassembly) with detailed annotations, verified labels, and cross-references to the Mega Man 4 engine.

## What This Fork Adds

- **Mesen-verified player state labels**: All 22 player states identified by setting write breakpoints on $0030. 19 confirmed, 3 unconfirmed.
- **Structured bank headers**: bank1E_1F.asm and bank1C_1D.asm have comprehensive headers documenting entity memory layout, dispatch mechanisms, and key routines.
- **MM4 engine cross-references**: Since MM3 and MM4 share the same core engine, matching routine addresses are noted (e.g., `process_sprites` at $1C800C maps to MM4's $3A8014). See also [plasticsmoke/megaman4-disassembly](https://github.com/plasticsmoke/megaman4-disassembly).
- **Entity system documentation**: Slot layout, field map ($0300-$05FF), dispatch routing for routine indices $00-$FF across banks.
- **Named routines**: Robot master AI labels, Doc Robot routines, weapon systems, core sprite processing, and collision detection.
- **Combined bank files**: Adjacent bank pairs (1A+1B, 1C+1D) merged into single files for easier navigation.

## Original README

Disassembly is 100% finished, including code and data. Assembles to 100% clean ROM under xkas-plus (build included in repo).

Version:
NTSC-U (United States)

Assembling instructions:
`./xkas -o mm3.nes assemble.asm`

This game uses the MMC3 mapper chip, and contains 32 PRG banks and 16 CHR banks of $2000 bytes each.

The disassembly is complete and assembles to clean but not all code is documented yet. Feel free to contribute documentation via pull request or just message and ask me to add you as a contributor if you want to help out more seriously.
