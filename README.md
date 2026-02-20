# Mega Man 3 (NES) Disassembly — Annotated Fork

Fork of [refreshing-lemonade/megaman3-disassembly](https://github.com/refreshing-lemonade/megaman3-disassembly) with detailed annotations, verified labels, and cross-references to the Mega Man 4 engine.

## What This Fork Adds

- **Mesen-verified player state labels**: All 22 player states identified by setting write breakpoints on $0030. 20 confirmed, 2 unconfirmed.
- **Tile collision system**: All 7 collision types mapped ($00 air, $10 solid, $20 ladder, $30 damage, $40 ladder top, $50 spikes, $70 disappearing block). `check_tile_collision` routine labeled with full documentation of the `$BF00` attribute table lookup, ground detection, ladder entry, and hazard priority system.
- **Level data format**: Complete per-stage bank layout documented — screen pointer tables ($AA60), screen layout data ($AA82, 20 bytes/screen with 16 metatile column IDs + 4 connection bytes), metatile column definitions ($AF00, 64 bytes/column), CHR tile definitions ($B700, 4 bytes/metatile = 2x2 pattern), and collision attribute table ($BF00). `load_stage` routine and `stage_to_bank` mapping table labeled.
- **Enemy spawn system**: Per-stage placement tables ($AB00 screen, $AC00 X, $AD00 Y, $AE00 global enemy ID) feeding into bank $00's global enemy data tables (flags, AI routine, shape, HP). `spawn_enemy` routine in bank1A_1B fully annotated.
- **Stage select screen**: Complete stage select system decoded in bank18 — portrait frame rendering (`write_portrait_frames`/`write_portrait_faces`), cursor bolt sprites (4 corners, tiles $E4/$E5, red/orange palette $37, flash every 8 frames), Mega Man eye sprites (6 per direction, H-flip for symmetry), stage lookup table ($9CE1 with Robot Master/Doc Robot/Wily tiers), and all data tables with pixel positions annotated. Full visual composition documented: background tiles + nametable writes + OAM sprites.
- **Stage progression system**: `stage_select_progression` routine in bank03 annotated — $61 boss-defeated bitmask accumulation, Robot Master → Doc Robot tier transition ($61=$FF → $60=$09), Doc Robot → Wily transition ($60=$12).
- **Mesen-verified zero-page variables**: Weapon IDs ($A0), energy addresses ($A2-$AD), lives ($AE), E-tanks ($AF), stage index ($22), gravity ($99=$55), stage select cursor ($12/$13), boss-defeated bitmask ($61), and more.
- **Cross-bank state transition annotations**: Every `STA $30` write across all banks annotated with state name and trigger context — including boss defeat tracking (Rush Jet/Rush Marine awards), Doc Flash Time Stopper, Hard Man stun/launch, fortress boss sequences.
- **Structured bank headers**: bank1E_1F.asm has comprehensive reference sections for physics, tile collision types, level data format, entity memory layout, weapon IDs, stage mapping, and player states.
- **MM4 engine cross-references**: Since MM3 and MM4 share the same core engine, matching routine addresses are noted (e.g., `process_sprites` at $1C800C maps to MM4's $3A8014). See also [plasticsmoke/megaman4-disassembly](https://github.com/plasticsmoke/megaman4-disassembly).
- **Entity system documentation**: Slot layout, field map ($0300-$05FF), dispatch routing for routine indices $00-$FF across banks. Entity-to-player distance (`entity_x_dist_to_player`/`entity_y_dist_to_player`), 16-direction angle calculation (`calc_direction_to_player`), smooth direction tracking (`track_direction_to_player`), and proportional homing velocity (`calc_homing_velocity`) — all fully annotated.
- **Math utilities**: 8-bit and 16-bit restoring division routines (`divide_8bit`, `divide_16bit`) annotated with algorithm explanation (shift-and-subtract, fixed-point results).
- **Entity helper functions**: `init_child_entity` (85+ callers, spawns sub-entity inheriting parent's flip), `set_sprite_hflip` (35+ callers, converts facing direction to NES horizontal flip bit), `face_player` (aims entity toward player).
- **Movement with collision**: `move_right_collide`, `move_left_collide`, `move_down_collide`, `move_up_collide` (20+ callers each), `move_vertical_gravity` (20+ callers) — full movement+tile collision pipeline with platform interaction for player slot.
- **Named routines**: Robot master AI labels, Doc Robot routines, weapon systems, core sprite processing, collision detection, metatile lookup, and stage loading.
- **Combined bank files**: Adjacent bank pairs (1A+1B, 1C+1D) merged into single files for easier navigation.

## Original README

Disassembly is 100% finished, including code and data. Assembles to 100% clean ROM under xkas-plus (build included in repo).

Version:
NTSC-U (United States)

Assembling instructions:
`./xkas -o mm3.nes assemble.asm`

This game uses the MMC3 mapper chip, and contains 32 PRG banks and 16 CHR banks of $2000 bytes each.

The disassembly is complete and assembles to clean but not all code is documented yet. Feel free to contribute documentation via pull request or just message and ask me to add you as a contributor if you want to help out more seriously.
