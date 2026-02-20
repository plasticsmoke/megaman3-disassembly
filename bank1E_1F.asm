; =============================================================================
; MEGA MAN 3 (U) — BANKS $1E-$1F — MAIN GAME LOGIC (FIXED BANK)
; =============================================================================
; This is the fixed code bank for Mega Man 3. Always mapped to $C000-$FFFF.
; Contains:
;   - NMI / interrupt handling
;   - Player state machine (22 states via player_state_ptr_lo/hi)
;   - Player movement physics (walk, jump, gravity, slide, ladder)
;   - Weapon firing and initialization
;   - Entity movement routines (shared by player and enemies)
;   - Sprite animation control
;   - Collision detection (player-entity, weapon-entity)
;   - Sound submission
;   - PRG/CHR bank switching
;
; NOTE: MM3 shares its engine with Mega Man 4 (MM4). Many routines here
; are near-identical to MM4's bank38_3F.asm (the MM4 fixed bank).
; MM4 cross-references (from plasticsmoke/megaman4-disassembly):
;   process_sprites    ($1C800C) → code_3A8014 — entity processing loop
;   check_player_hit   ($1C8097) → code_3A81CC — contact damage check
;   check_weapon_hit   ($1C8102) → code_3FF95D — weapon-entity collision
;   find_enemy_freeslot_x ($1FFC43) → code_3FFB5C — find empty entity slot (X)
;   find_enemy_freeslot_y ($1FFC53) → code_3FFB6C — find empty entity slot (Y)
;   move_sprite_right  ($1FF71D) → code_3FF22D — entity X += velocity
;   move_sprite_left   ($1FF73B) → code_3FF24B — entity X -= velocity
;   move_sprite_down   ($1FF759) → code_3FF269 — entity Y += velocity
;   move_sprite_up     ($1FF779) → code_3FF289 — entity Y -= velocity
;   reset_sprite_anim  ($1FF835) → (equivalent in bank38_3F)
;   reset_gravity      ($1FF81B) → (equivalent in bank38_3F)
;   face_player        ($1FF869) → (equivalent in bank38_3F)
;   select_PRG_banks   ($1FFF6B) → code_3FFF37 — MMC3 bank switch
;   NMI                ($1EC000) → NMI ($3EC000) — vblank interrupt
;   RESET              ($1FFE00) → RESET ($3FFE00) — power-on entry
;
; Key differences from MM4: 32 entity slots (vs 24), $20 stride (vs $18),
; direct routine-index dispatch (vs page-based AI state machine),
; 16 weapon slots (vs 8), Top Spin mechanic, no 16-bit X coordinates.
;
; =============================================================================
; KEY MEMORY MAP
; =============================================================================
;
; Zero Page:
;   $12     = stage select cursor column (0-2) / player tile X (in-game)
;   $13     = stage select cursor row offset (0/3/6)
;   $14     = controller 1 buttons (new presses this frame)
;   $15     = controller 1 buttons (new presses, alternate read)
;   $16     = controller 1 buttons (held / continuous)
;             Button bits: $80=A $40=B $20=Select $10=Start
;                          $08=Up $04=Down $02=Left $01=Right
;   $18     = palette update request flag
;   $19     = nametable update request flag
;   $1A     = nametable column update flag
;   $22     = current stage index (see STAGE MAPPING below)
;   $30     = player state (index into player_state_ptr tables, 22 states)
;   $31     = player facing direction (1=right, 2=left)
;   $32     = walking flag / sub-state (nonzero = walking or sub-state active)
;   $34     = entity_ride slot (entity slot index being ridden, state $05)
;   $35     = facing sub-state / Mag Fly direction inherit
;   $39     = invincibility/i-frames timer (nonzero = immune to damage)
;   $3A     = jump/rush counter
;   $3D     = pending hazard state ($06=damage, $0E=death from tile collision)
;   $41     = max tile type at feet (highest priority hazard)
;   $43-$44 = tile types at player feet (for ground/ladder detection)
;   $50     = scroll lock flag
;   $5A     = boss active flag (bit 7 = boss fight in progress)
;   $5B-$5C = spark freeze slots (entity X indices frozen by Spark Shock)
;   $5D     = sub-state / item interaction flag
;   $5E-$5F = scroll position values
;   $60     = stage select page offset (0=Robot Master, nonzero=Doc Robot/Wily)
;   $61     = boss-defeated bitmask (bit N = stage $0N boss beaten, $FF=all 8)
;   $68     = cutscene-complete flag (Proto Man encounter)
;   $69-$6A = scroll position (used during Gamma screen_scroll)
;   $6C     = warp destination index (teleporter tube target)
;   $78     = screen mode
;   $99     = gravity sub-pixel increment ($55 during gameplay = 0.332/frame,
;             set at start of process_sprites each frame; $40 at stage select)
;   $9E-$9F = enemy spawn tracking counters (left/right)
;
; Weapon / Inventory Block ($A0-$AF):
;   $A0     = current weapon ID (see WEAPON IDS below)
;   $A1     = weapon menu cursor position (remembers last pause screen selection)
;   $A2     = player HP        (full=$9C, empty=$80, AND #$1F for value, 28 max)
;   $A3     = Gemini Laser ammo (full=$9C, empty=$80, address = $A2 + weapon ID)
;   $A4     = Needle Cannon ammo
;   $A5     = Hard Knuckle ammo
;   $A6     = Magnet Missile ammo
;   $A7     = Top Spin ammo
;   $A8     = Search Snake ammo
;   $A9     = Rush Coil ammo
;   $AA     = Spark Shock ammo
;   $AB     = Rush Marine ammo
;   $AC     = Shadow Blade ammo
;   $AD     = Rush Jet ammo
;   $AE     = lives
;   $AF     = E-Tanks
;
;   $B0     = boss HP display position (starts $80, fills to $9C = 28 HP)
;   $B3     = boss HP fill target ($8E = 28 HP)
;   $EE     = NMI skip flag
;   $EF     = current sprite slot counter (loop variable in process_sprites)
;   $F0     = MMC3 bank select register shadow
;   $F5     = current $A000-$BFFF PRG bank number
;   $F8     = game mode / screen state
;   $F9     = camera/scroll page
;   $FA     = vertical scroll
;   $FC-$FD = camera X position (low, high)
;   $FE     = PPU mask ($2001) shadow
;   $FF     = PPU control ($2000) shadow
;
; WEAPON IDS ($A0 values):
;   $00 = Mega Buster    $04 = Magnet Missile  $08 = Spark Shock
;   $01 = Gemini Laser   $05 = Top Spin        $09 = Rush Marine
;   $02 = Needle Cannon  $06 = Search Snake    $0A = Shadow Blade
;   $03 = Hard Knuckle   $07 = Rush Coil       $0B = Rush Jet
;
; STAGE MAPPING ($22 values):
;   Robot Masters (stage select grid, $12=col 0-2, $13=row 0/3/6):
;     $00 = Needle Man   (col 2, row 0 = top-right)
;     $01 = Magnet Man   (col 1, row 2 = bottom-middle)
;     $02 = Gemini Man   (col 0, row 2 = bottom-left)
;     $03 = Hard Man     (col 0, row 1 = middle-left)
;     $04 = Top Man      (col 2, row 1 = middle-right)
;     $05 = Snake Man    (col 1, row 0 = top-middle)
;     $06 = Spark Man    (col 0, row 0 = top-left)
;     $07 = Shadow Man   (col 2, row 2 = bottom-right)
;   Doc Robot stages: $08-$0B (4 revisited stages)
;   Wily Castle: $0C+ (fortress stages)
;   Stage select grid lookup table at CPU $9CE1 (bank18.asm)
;
; PLAYER PHYSICS:
;   Normal jump velocity:    $04.E5 (~4.9 px/frame upward)
;   Super jump (Rush Coil):  $08.00 (8.0 px/frame upward)
;   Slide jump velocity:     $06.EE (~6.9 px/frame upward)
;   Resting Y velocity:      $FF.C0 (-0.25, gentle ground pin)
;   Terminal fall velocity:   $F9.00 (-7.0, clamped in gravity code)
;   Gravity per frame:        $00.55 (0.332 px/frame², set in process_sprites)
;   Velocity format: $0460.$0440 = whole.sub, higher = upward
;
; TILE COLLISION TYPES (upper nibble of $BF00,y tile attribute table):
;   $00 = air (passthrough, no collision)
;   $10 = solid ground (bit 4 = solid flag)
;   $20 = ladder (climbable when pressing Up, passthrough)
;   $30 = damage tile (lava/fire — triggers player_damage, solid)
;   $40 = ladder top (climbable, grab point from above)
;   $50 = spikes (instant kill, solid)
;   $70 = disappearing block (Gemini Man stages $02/$09 only, solid when visible)
;   Solid test: accumulate tile types in $10, then AND #$10 — nonzero = on solid ground
;   Hazard priority: $41 tracks max type, $30→damage, $50→death
;   $BF00 table is per-stage, loaded from the stage's PRG bank
;
; LEVEL DATA FORMAT (per-stage PRG bank, mapped to $A000-$BFFF):
;   Stage bank = stage_to_bank[$22] table at $C8B9 (usually bank = stage index)
;   $A000-$A4FF: enemy data tables (flags, main routine IDs, spawn data)
;   $AA00+:      screen metatile grid (column IDs, read during tile collision)
;   $AA60:       screen pointer table (2 bytes/screen: init param, layout index)
;   $AA80-$AA81: palette indices for stage
;   $AA82+:      screen layout data, 20 bytes per screen:
;                  bytes 0-15: 16 metatile column IDs (one per 16px column)
;                  bytes 16-19: screen connection data (bit 7=flag, bits 0-6=target)
;   $AB00+:      enemy placement tables (4 tables, indexed by stage enemy ID):
;                  $AB00,y = screen number, $AC00,y = X pixel, $AD00,y = Y pixel,
;                  $AE00,y = global enemy ID (→ bank $00 for AI/shape/HP)
;   $AF00+:      metatile column definitions, 64 bytes per column ID
;                  (vertical strip of metatile indices for one 16px-wide column)
;   $B700+:      metatile CHR definitions, 4 bytes per metatile index
;                  (2x2 CHR tile pattern: TL, TR, BL, BR)
;   $BF00-$BFFF: collision attribute table, 1 byte per metatile index (256 entries)
;                  upper nibble = collision type (see TILE COLLISION TYPES above)
;   Screen = 16 columns x N rows of 16x16 metatiles = 256px wide
;   load_stage routine at $1EC816 copies screen data to RAM ($0600+)
;
; Entity Arrays (indexed by X, stride $20, 32 slots $00-$1F):
;   $0300,x = entity active flag (bit 7 = active)
;   $0320,x = main routine index (AI type, dispatched in process_sprites)
;   $0340,x = X position sub-pixel
;   $0360,x = X position pixel
;   $0380,x = X position screen/page
;   $03A0,x = Y position sub-pixel
;   $03C0,x = Y position pixel
;   $03E0,x = Y position screen/page
;   $0400,x = X velocity sub-pixel
;   $0420,x = X velocity pixel (signed: positive=right, negative=left)
;   $0440,x = Y velocity sub-pixel
;   $0460,x = Y velocity pixel (signed: negative=up/gravity, positive=down)
;   $0480,x = entity shape/hitbox (bit 7 = causes player contact damage)
;   $04A0,x = facing direction (1=right, 2=left)
;   $04C0,x = stage enemy ID (spawn tracking, prevents duplicate spawns)
;   $04E0,x = health / hit points
;   $0500,x = AI timer / general purpose counter
;   $0520,x = general purpose / wildcard 1
;   $0540,x = general purpose / wildcard 2
;   $0560,x = general purpose / wildcard 3
;   $0580,x = entity flags (bit 7=active/collidable, bit 6=H-flip, bit 4=?)
;   $05A0,x = animation state (0=reset, set by reset_sprite_anim)
;   $05C0,x = current animation / OAM ID
;   $05E0,x = animation frame counter (bit 7 preserved on anim reset)
;
; Entity Slot Ranges:
;   Slot $00       = Mega Man (player)
;   Slots $01-$0F  = weapons / projectiles (15 reserved slots)
;   Slots $10-$1F  = enemies / items / bosses (searched by find_enemy_freeslot)
;
; MM3→MM4 Entity Address Cross-Reference:
;   MM3 $0300,x → MM4 $0300,x  (entity active flag)
;   MM3 $0320,x → MM4 n/a      (routine index; MM4 uses page-based dispatch)
;   MM3 $0340,x → MM4 $0318,x  (X sub-pixel)
;   MM3 $0360,x → MM4 $0330,x  (X pixel)
;   MM3 $0380,x → MM4 $0348,x  (X screen/page)
;   MM3 $03A0,x → MM4 $0360,x  (Y sub-pixel)
;   MM3 $03C0,x → MM4 $0378,x  (Y pixel)
;   MM3 $03E0,x → MM4 $0390,x  (Y screen/page)
;   MM3 $0400,x → MM4 $03A8,x  (X velocity sub-pixel)
;   MM3 $0420,x → MM4 $03C0,x  (X velocity pixel)
;   MM3 $0440,x → MM4 $03D8,x  (Y velocity sub-pixel)
;   MM3 $0460,x → MM4 $03F0,x  (Y velocity pixel)
;   MM3 $0480,x → MM4 $0408,x  (shape/hitbox)
;   MM3 $04A0,x → MM4 $0420,x  (facing/direction)
;   MM3 $04E0,x → MM4 (TBD)    (health)
;   MM3 $0500,x → MM4 $0468,x  (AI timer)
;   MM3 $0580,x → MM4 $0528,x  (entity flags)
;   MM3 $05C0,x → MM4 $0558,x  (animation/OAM ID)
;   MM3 $05E0,x → MM4 $0540,x  (animation frame counter)
;
; Sound System:
;   submit_sound_ID ($1FFA98) — submit a sound effect to the queue
;
; Palette RAM:
;   $0600-$061F = palette buffer (32 bytes, uploaded to PPU $3F00 during NMI)
;
; Controller Button Masks (for $14 / $16):
;   #$80 = A button (Jump)
;   #$40 = B button (Fire)
;   #$20 = Select
;   #$10 = Start
;   #$08 = Up
;   #$04 = Down
;   #$02 = Left
;   #$01 = Right
;
; Fixed-Point Format: 8.8 (high byte = pixels, low byte = sub-pixel / 256)
;   Example: $01.4C = 1 + 76/256 = 1.297 pixels/frame
;
; PHYSICS CONSTANTS (from reset_gravity and player movement code):
;   Gravity (player):  $FFC0 as velocity = -0.25 px/frame² (upward bias)
;   Gravity (enemies): $FFAB as velocity = -0.332 px/frame²
;   Terminal velocity: $07.00 = 7.0 px/frame downward (clamped at $0460 >= $07)
;   Walk speed:        $01.4C = 1.297 px/frame (same as MM4)
;   Slide speed:       (TODO: verify from player slide state)
;   Jump velocity:     (TODO: verify from player_on_ground.jump)
;
; PLAYER STATES (22 states, index in $30, dispatched via player_state_ptr tables):
; Verified via Mesen 0.9.9 write breakpoint on $0030 during full playthrough.
;   $00 = player_on_ground    ($CE36) — idle/walking on ground [confirmed]
;   $01 = player_airborne     ($D007) — jumping/falling, variable jump [confirmed]
;   $02 = player_slide        ($D3FD) — sliding on ground [confirmed]
;   $03 = player_ladder       ($D4EB) — on ladder (climb, fire, jump off) [confirmed]
;   $04 = player_reappear     ($D5BA) — respawn/reappear (death, unpause, stage start) [confirmed]
;   $05 = player_entity_ride  ($D613) — riding entity at slot $34 (anim $62) [unconfirmed]
;   $06 = player_damage       ($D6AB) — taking damage (contact or projectile) [confirmed]
;   $07 = player_special_death($D831) — Doc Flash Time Stopper kill [confirmed]
;   $08 = player_rush_marine  ($D858) — riding Rush Marine submarine [confirmed]
;   $09 = player_boss_wait    ($D929) — frozen during boss intro (shutters/HP bar) [confirmed]
;   $0A = player_top_spin     ($D991) — Top Spin recoil bounce (8 frames) [confirmed]
;   $0B = player_weapon_recoil($D9BE) — Hard Knuckle fire freeze (16 frames) [confirmed]
;   $0C = player_victory      ($D9D3) — boss defeated cutscene (jump, get weapon) [confirmed]
;   $0D = player_teleport     ($DBE1) — teleport away, persists through menus [confirmed]
;   $0E = player_death        ($D779) — dead, explosion on all sprites [confirmed]
;   $0F = player_stunned      ($CDCC) — frozen by external force (slam/grab/cutscene) [confirmed]
;   $10 = player_screen_scroll($DD14) — vertical scroll transition between sections [confirmed]
;   $11 = player_warp_init    ($DDAA) — teleporter tube area initialization [confirmed]
;   $12 = player_warp_anim    ($DE52) — wait for warp animation, return to $00 [confirmed]
;   $13 = player_teleport_beam($DF33) — teleport beam landing w/ gravity [unconfirmed]
;   $14 = player_auto_walk    ($DF8A) — scripted walk to X=$50 (post-Wily) [confirmed]
;   $15 = player_auto_walk_2  ($E08C) — scripted walk to X=$68 (ending cutscene) [confirmed]
;
; =============================================================================

bank $1E
org $C000

NMI:
  PHP                                       ; $1EC000 |\
  PHA                                       ; $1EC001 | |
  TXA                                       ; $1EC002 | | preserve X, Y, and
  PHA                                       ; $1EC003 | | processor flags
  TYA                                       ; $1EC004 | |
  PHA                                       ; $1EC005 |/
  LDA $2002                                 ; $1EC006 |
  LDA $FF                                   ; $1EC009 |
  AND #$7F                                  ; $1EC00B |
  STA $2000                                 ; $1EC00D |
  LDA #$00                                  ; $1EC010 |
  STA $2001                                 ; $1EC012 |
  LDA $EE                                   ; $1EC015 |
  ORA $9A                                   ; $1EC017 |
  BNE code_1EC088                           ; $1EC019 |
  LDA $FC                                   ; $1EC01B |
  STA $79                                   ; $1EC01D |
  LDA $FD                                   ; $1EC01F |
  STA $7A                                   ; $1EC021 |
  LDA $F8                                   ; $1EC023 |
  STA $78                                   ; $1EC025 |
  LDA $50                                   ; $1EC027 |
  BNE code_1EC02F                           ; $1EC029 |
  LDA $5E                                   ; $1EC02B |
  STA $7B                                   ; $1EC02D |
code_1EC02F:
  LDA #$00                                  ; $1EC02F |
  STA $2003                                 ; $1EC031 |
  LDA #$02                                  ; $1EC034 |
  STA $4014                                 ; $1EC036 |
  LDA $19                                   ; $1EC039 |
  BEQ code_1EC040                           ; $1EC03B |
  JSR code_1EC4F8                           ; $1EC03D |
code_1EC040:
  LDA $1A                                   ; $1EC040 |
  BEQ code_1EC05B                           ; $1EC042 |
  LDA $FF                                   ; $1EC044 |
  AND #$7F                                  ; $1EC046 |
  ORA #$04                                  ; $1EC048 |
  STA $2000                                 ; $1EC04A |
  LDX #$00                                  ; $1EC04D |
  STX $1A                                   ; $1EC04F |
  JSR code_1EC4FC                           ; $1EC051 |
  LDA $FF                                   ; $1EC054 |
  AND #$7F                                  ; $1EC056 |
  STA $2000                                 ; $1EC058 |
code_1EC05B:
  LDA $18                                   ; $1EC05B |
  BEQ code_1EC088                           ; $1EC05D |
  LDX #$00                                  ; $1EC05F |
  STX $18                                   ; $1EC061 |
  LDA $2002                                 ; $1EC063 |
  LDA #$3F                                  ; $1EC066 |
  STA $2006                                 ; $1EC068 |
  STX $2006                                 ; $1EC06B |
  LDY #$20                                  ; $1EC06E |
code_1EC070:
  LDA $0600,x                               ; $1EC070 |
  STA $2007                                 ; $1EC073 |
  INX                                       ; $1EC076 |
  DEY                                       ; $1EC077 |
  BNE code_1EC070                           ; $1EC078 |
  LDA #$3F                                  ; $1EC07A |
  STA $2006                                 ; $1EC07C |
  STY $2006                                 ; $1EC07F |
  STY $2006                                 ; $1EC082 |
  STY $2006                                 ; $1EC085 |
code_1EC088:
  LDA $78                                   ; $1EC088 |
  CMP #$02                                  ; $1EC08A |
  BNE code_1EC09D                           ; $1EC08C |
  LDA $2002                                 ; $1EC08E |
  LDA $5F                                   ; $1EC091 |
  STA $2005                                 ; $1EC093 |
  LDA #$00                                  ; $1EC096 |
  STA $2005                                 ; $1EC098 |
  BEQ code_1EC0AA                           ; $1EC09B |
code_1EC09D:
  LDA $2002                                 ; $1EC09D |
  LDA $79                                   ; $1EC0A0 |
  STA $2005                                 ; $1EC0A2 |
  LDA $FA                                   ; $1EC0A5 |
  STA $2005                                 ; $1EC0A7 |
code_1EC0AA:
  LDA $FE                                   ; $1EC0AA |
  STA $2001                                 ; $1EC0AC |
  LDA $7A                                   ; $1EC0AF |
  AND #$03                                  ; $1EC0B1 |
  ORA $FF                                   ; $1EC0B3 |
  STA $2000                                 ; $1EC0B5 |
  JSR select_CHR_banks                      ; $1EC0B8 |
  LDA $F0                                   ; $1EC0BB |
  STA $8000                                 ; $1EC0BD |
; --- NMI: set up MMC3 scanline IRQ for this frame ---
; $7B = scanline count for first IRQ. $9B = enable flag (0=off, 1=on).
; $78 = game mode, used to index irq_vector_table for the handler address.
; $50/$51 = secondary split: if $50 != 0 and $7B >= $51, use gameplay handler.
  LDA $7B                                   ; $1EC0C0 | scanline count for first split
  STA $C000                                 ; $1EC0C2 | set MMC3 IRQ counter value
  STA $C001                                 ; $1EC0C5 | latch counter (reload)
  LDX $9B                                   ; $1EC0C8 | IRQ enable flag
  STA $E000,x                               ; $1EC0CA | $9B=0 → $E000 (disable), $9B=1 → $E001 (enable)
  BEQ code_1EC0E7                           ; $1EC0CD | if disabled, skip vector setup
  LDX $78                                   ; $1EC0CF | X = game mode (index into vector table)
  LDA $50                                   ; $1EC0D1 | secondary split flag
  BEQ code_1EC0DD                           ; $1EC0D3 | if no secondary split, use mode index
  LDA $7B                                   ; $1EC0D5 |\ if $7B < $51, use mode index
  CMP $51                                   ; $1EC0D7 | | (first split happens before secondary)
  BCC code_1EC0DD                           ; $1EC0D9 |/
  LDX #$01                                  ; $1EC0DB | else override: use index 1 (gameplay)
code_1EC0DD:
  LDA $C4C8,x                               ; $1EC0DD | IRQ vector low byte from table
  STA $9C                                   ; $1EC0E0 |
  LDA $C4DA,x                               ; $1EC0E2 | IRQ vector high byte from table
  STA $9D                                   ; $1EC0E5 | → $9C/$9D = handler address for JMP ($009C)
code_1EC0E7:
  INC $92                                   ; $1EC0E7 |
  LDX #$FF                                  ; $1EC0E9 |
  STX $90                                   ; $1EC0EB |
  INX                                       ; $1EC0ED |
  LDY #$04                                  ; $1EC0EE |
code_1EC0F0:
  LDA $80,x                                 ; $1EC0F0 |
  CMP #$01                                  ; $1EC0F2 |
  BNE code_1EC0FE                           ; $1EC0F4 |
  DEC $81,x                                 ; $1EC0F6 |
  BNE code_1EC0FE                           ; $1EC0F8 |
  LDA #$04                                  ; $1EC0FA |
  STA $80,x                                 ; $1EC0FC |
code_1EC0FE:
  INX                                       ; $1EC0FE |
  INX                                       ; $1EC0FF |
  INX                                       ; $1EC100 |
  INX                                       ; $1EC101 |
  DEY                                       ; $1EC102 |
  BNE code_1EC0F0                           ; $1EC103 |
  TSX                                       ; $1EC105 |\
  LDA $0107,x                               ; $1EC106 | | manual stack hackery!
  STA $7D                                   ; $1EC109 | | preserve original address
  LDA $0106,x                               ; $1EC10B | | from interrupt push
  STA $7C                                   ; $1EC10E | | (word address 6th & 7th down)
  LDA #$C1                                  ; $1EC110 | | -> $7C & $7D
  STA $0107,x                               ; $1EC112 | | then change that slot to be
  LDA #$21                                  ; $1EC115 | | $C121, the address right after RTI
  STA $0106,x                               ; $1EC117 |/
  PLA                                       ; $1EC11A |\
  TAY                                       ; $1EC11B | |
  PLA                                       ; $1EC11C | | restore X, Y, and P flags
  TAX                                       ; $1EC11D | | and clear interrupt flag
  PLA                                       ; $1EC11E | |
  PLP                                       ; $1EC11F |/
  RTI                                       ; $1EC120 | FAKE RETURN
; does not actually return, stack is hardcoded to go right here
; another preserve & restore just to call play_sounds
; this is done in case NMI happened in the middle of selecting PRG banks
; because play_sounds also selects PRG banks - possible race condition
; is handled in play_sounds routine
  PHP                                       ; $1EC121 |\ leave a stack slot for word sized
  PHP                                       ; $1EC122 |/ return address for the RTS
  PHP                                       ; $1EC123 |\
  PHA                                       ; $1EC124 | |
  TXA                                       ; $1EC125 | | once again, preserve X, Y & flags
  PHA                                       ; $1EC126 | |
  TYA                                       ; $1EC127 | |
  PHA                                       ; $1EC128 |/
  TSX                                       ; $1EC129 |\
  SEC                                       ; $1EC12A | |
  LDA $7C                                   ; $1EC12B | | restore original address
  SBC #$01                                  ; $1EC12D | | from interrupt push
  STA $0105,x                               ; $1EC12F | | onto the beginning of stack
  LDA $7D                                   ; $1EC132 | | (for RTS)
  SBC #$00                                  ; $1EC134 | |
  STA $0106,x                               ; $1EC136 |/
  JSR play_sounds                           ; $1EC139 |
  PLA                                       ; $1EC13C |\
  TAY                                       ; $1EC13D | |
  PLA                                       ; $1EC13E | | once again, restore X, Y & flags
  TAX                                       ; $1EC13F | |
  PLA                                       ; $1EC140 | |
  PLP                                       ; $1EC141 |/
  RTS                                       ; $1EC142 | this is the "true" RTI

; ===========================================================================
; IRQ — MMC3 scanline IRQ entry point
; ===========================================================================
; Triggered by the MMC3 mapper when the scanline counter ($7B) reaches zero.
; Saves registers, acknowledges the IRQ, re-enables it, then dispatches
; to the handler whose address is stored at $9C/$9D (set by NMI each frame
; from the irq_vector_table indexed by game mode $78).
;
; The IRQ handlers implement mid-frame scroll splits. For example, during
; stage transitions ($78=$07), a two-IRQ chain creates a 3-strip effect:
;   1. NMI sets top strip scroll + first counter ($7B = scanline 88)
;   2. First IRQ ($C297) sets middle strip scroll, chains to second handler
;   3. Second IRQ ($C2D2) restores bottom strip scroll
; ---------------------------------------------------------------------------
IRQ:
  PHP                                       ; $1EC143 |\
  PHA                                       ; $1EC144 | | save registers
  TXA                                       ; $1EC145 | |
  PHA                                       ; $1EC146 | |
  TYA                                       ; $1EC147 | |
  PHA                                       ; $1EC148 |/
  STA $E000                                 ; $1EC149 | acknowledge MMC3 IRQ (disable)
  STA $E001                                 ; $1EC14C | re-enable MMC3 IRQ
  JMP ($009C)                               ; $1EC14F | dispatch to current handler

; ===========================================================================
; irq_gameplay_status_bar — split after HUD for gameplay area ($C152)
; ===========================================================================
; Fires after the status bar scanlines. Sets PPU scroll/nametable for the
; gameplay area below. $52 encodes the PPU coarse Y and nametable for the
; gameplay viewport. When mode $0B is active, falls through to a simpler
; reset-to-origin variant.
; ---------------------------------------------------------------------------
irq_gameplay_status_bar:
  LDA $78                                   ; $1EC152 | check game mode
  CMP #$0B                                  ; $1EC154 | mode $0B (title)?
  BEQ .reset_to_origin                      ; $1EC156 | → simplified scroll
  LDA $2002                                 ; $1EC158 | reset PPU latch
  LDA $52                                   ; $1EC15B |\ $2006 = $52:$C0
  STA $2006                                 ; $1EC15D | | (sets coarse Y, nametable, coarse X=0)
  LDA #$C0                                  ; $1EC160 | |
  STA $2006                                 ; $1EC162 |/
  LDA $52                                   ; $1EC165 |\ PPUCTRL: nametable from ($52 >> 2) & 3
  LSR                                       ; $1EC167 | | merged with base $98 (NMI on, BG $1000)
  LSR                                       ; $1EC168 | |
  AND #$03                                  ; $1EC169 | |
  ORA #$98                                  ; $1EC16B | |
  STA $2000                                 ; $1EC16D |/
  LDA #$00                                  ; $1EC170 |\ fine X = 0, fine Y = 0
  STA $2005                                 ; $1EC172 | |
  STA $2005                                 ; $1EC175 |/
  JMP irq_exit                              ; $1EC178 |

.reset_to_origin:
  LDA $2002                                 ; $1EC17B | reset PPU latch
  LDA #$20                                  ; $1EC17E |\ $2006 = $20:$00
  STA $2006                                 ; $1EC180 | | (nametable 0, origin)
  LDA #$00                                  ; $1EC183 | |
  STA $2006                                 ; $1EC185 |/
  LDA #$98                                  ; $1EC188 |\ PPUCTRL = $98 (NT 0, NMI, BG $1000)
  STA $2000                                 ; $1EC18A |/
  LDA #$00                                  ; $1EC18D |\ X = 0, Y = 0
  STA $2005                                 ; $1EC18F | |
  STA $2005                                 ; $1EC192 |/
  JMP irq_exit                              ; $1EC195 |

; ===========================================================================
; irq_gameplay_hscroll — horizontal scroll for gameplay area ($C198)
; ===========================================================================
; Sets X scroll to $79 (the gameplay horizontal scroll position).
; If secondary split is enabled ($50 != 0), chains to status bar handler
; for an additional split at scanline $51.
; ---------------------------------------------------------------------------
irq_gameplay_hscroll:
  LDA $2002                                 ; $1EC198 | reset PPU latch
  LDA $79                                   ; $1EC19B |\ X scroll = $79
  STA $2005                                 ; $1EC19D |/
  LDA #$00                                  ; $1EC1A0 |\ Y scroll = 0
  STA $2005                                 ; $1EC1A2 |/
  LDA $50                                   ; $1EC1A5 | secondary split enabled?
  BEQ irq_jmp_exit_disable                  ; $1EC1A7 | no → last split
  LDA $51                                   ; $1EC1A9 |\ counter = $51 - $9F
  SEC                                       ; $1EC1AB | | (scanlines until secondary split)
  SBC #$9F                                  ; $1EC1AC | |
  STA $C000                                 ; $1EC1AE |/
  LDA $C4C9                                 ; $1EC1B1 |\ chain to irq_gameplay_status_bar
  STA $9C                                   ; $1EC1B4 | |
  LDA $C4DB                                 ; $1EC1B6 | |
  STA $9D                                   ; $1EC1B9 |/
  JMP irq_exit                              ; $1EC1BB |

irq_jmp_exit_disable:                       ;         | shared trampoline for BEQ range
  JMP irq_exit_disable                      ; $1EC1BE |

; ===========================================================================
; irq_gameplay_ntswap — nametable swap after HUD ($C1C1)
; ===========================================================================
; Switches PPU to nametable 2 ($2800) at scroll origin (0,0).
; Used for vertical level layouts where the gameplay area uses a different
; nametable than the HUD. Chains to the next handler indexed by $78,
; unless secondary split overrides to mode $00 (no-op).
; ---------------------------------------------------------------------------
irq_gameplay_ntswap:
  LDA $2002                                 ; $1EC1C1 | reset PPU latch
  LDA #$28                                  ; $1EC1C4 |\ $2006 = $28:$00
  STA $2006                                 ; $1EC1C6 | | (nametable 2 origin)
  LDA #$00                                  ; $1EC1C9 | |
  STA $2006                                 ; $1EC1CB |/
  LDA $FF                                   ; $1EC1CE |\ PPUCTRL: set nametable bit 1
  ORA #$02                                  ; $1EC1D0 | | → nametable 2
  STA $2000                                 ; $1EC1D2 |/
  LDA #$00                                  ; $1EC1D5 |\ X = 0, Y = 0
  STA $2005                                 ; $1EC1D7 | |
  STA $2005                                 ; $1EC1DA |/
  LDA #$B0                                  ; $1EC1DD |\ counter = $B0 - $7B
  SEC                                       ; $1EC1DF | | (scanlines to next split)
  SBC $7B                                   ; $1EC1E0 | |
  STA $C000                                 ; $1EC1E2 |/
  LDX $78                                   ; $1EC1E5 | chain index = current game mode
  LDA $50                                   ; $1EC1E7 | secondary split?
  BEQ .chain                                ; $1EC1E9 | no → use mode index
  LDA $51                                   ; $1EC1EB |\ if $51 == $B0, override to mode $00
  CMP #$B0                                  ; $1EC1ED | | (disable further splits)
  BNE .chain                                ; $1EC1EF |/
  LDX #$00                                  ; $1EC1F1 | X = 0 → irq_exit_disable handler
.chain:
  LDA $C4C9,x                               ; $1EC1F3 |\ chain to handler for mode X
  STA $9C                                   ; $1EC1F6 | |
  LDA $C4DB,x                               ; $1EC1F8 | |
  STA $9D                                   ; $1EC1FB |/
  JMP irq_exit                              ; $1EC1FD |

; ===========================================================================
; irq_gameplay_vscroll — vertical scroll for gameplay area ($C200)
; ===========================================================================
; Sets PPU to $22C0 (nametable 0, bottom portion) with Y scroll = $B0 (176).
; Used for stages with vertical scrolling — positions the viewport to show
; the bottom part of the nametable. Optionally chains to status bar handler.
; ---------------------------------------------------------------------------
irq_gameplay_vscroll:
  LDA $2002                                 ; $1EC200 | reset PPU latch
  LDA #$22                                  ; $1EC203 |\ $2006 = $22:$C0
  STA $2006                                 ; $1EC205 | | (nametable 0, coarse Y ≈ 22)
  LDA #$C0                                  ; $1EC208 | |
  STA $2006                                 ; $1EC20A |/
  LDA $FF                                   ; $1EC20D |\ PPUCTRL from base value
  STA $2000                                 ; $1EC20F |/
  LDA #$00                                  ; $1EC212 |\ X scroll = 0
  STA $2005                                 ; $1EC214 |/
  LDA #$B0                                  ; $1EC217 |\ Y scroll = $B0 (176)
  STA $2005                                 ; $1EC219 |/
  LDA $50                                   ; $1EC21C | secondary split?
  BEQ irq_jmp_exit_disable                  ; $1EC21E | no → exit disabled
  LDA $51                                   ; $1EC220 |\ counter = $51 - $B0
  SEC                                       ; $1EC222 | |
  SBC #$B0                                  ; $1EC223 | |
  STA $C000                                 ; $1EC225 |/
  LDA $C4C9                                 ; $1EC228 |\ chain to irq_gameplay_status_bar
  STA $9C                                   ; $1EC22B | |
  LDA $C4DB                                 ; $1EC22D | |
  STA $9D                                   ; $1EC230 |/
  JMP irq_exit                              ; $1EC232 |

; ===========================================================================
; irq_stagesel_first — stage select X scroll (mode $05)
; ===========================================================================
; Sets scroll for the upper portion of the stage select screen using the
; standard NES mid-frame $2006/$2005 trick. X scroll comes from $79.
; Chains to irq_stagesel_second after $C0 - $7B scanlines.
; ---------------------------------------------------------------------------
irq_stagesel_first:
  LDA $2002                                 ; $1EC235 | reset PPU latch
  LDA #$20                                  ; $1EC238 |\ $2006 = $20:coarseX
  STA $2006                                 ; $1EC23A | | (nametable 0, coarse Y=0)
  LDA $79                                   ; $1EC23D | |
  LSR                                       ; $1EC23F | | coarse X = $79 >> 3
  LSR                                       ; $1EC240 | |
  LSR                                       ; $1EC241 | |
  AND #$1F                                  ; $1EC242 | | mask to 0-31
  ORA #$00                                  ; $1EC244 | | coarse Y=0 (top)
  STA $2006                                 ; $1EC246 |/
  LDA $FF                                   ; $1EC249 |\ PPUCTRL: nametable 0
  AND #$FC                                  ; $1EC24B | |
  STA $2000                                 ; $1EC24D |/
  LDA $79                                   ; $1EC250 |\ fine X scroll = $79
  STA $2005                                 ; $1EC252 |/
  LDA #$00                                  ; $1EC255 |\ Y scroll = 0
  STA $2005                                 ; $1EC257 |/
  LDA #$C0                                  ; $1EC25A |\ counter = $C0 - $7B
  SEC                                       ; $1EC25C | | (scanlines to bottom split)
  SBC $7B                                   ; $1EC25D | |
  STA $C000                                 ; $1EC25F |/
  LDA $C4CE                                 ; $1EC262 |\ chain to irq_stagesel_second ($C26F)
  STA $9C                                   ; $1EC265 | |
  LDA $C4E0                                 ; $1EC267 | |
  STA $9D                                   ; $1EC26A |/
  JMP irq_exit                              ; $1EC26C |

; ===========================================================================
; irq_stagesel_second — stage select bottom scroll (mode $06)
; ===========================================================================
; Sets scroll for the bottom portion of the stage select screen.
; Uses nametable 0 at high coarse Y ($23xx). Last split — disables IRQ.
; ---------------------------------------------------------------------------
irq_stagesel_second:
  LDA $2002                                 ; $1EC26F | reset PPU latch
  LDA #$23                                  ; $1EC272 |\ $2006 = $23:coarseX
  STA $2006                                 ; $1EC274 | | (nametable 0, high coarse Y)
  LDA $79                                   ; $1EC277 | |
  LSR                                       ; $1EC279 | | coarse X = $79 >> 3
  LSR                                       ; $1EC27A | |
  LSR                                       ; $1EC27B | |
  AND #$1F                                  ; $1EC27C | |
  ORA #$00                                  ; $1EC27E | |
  STA $2006                                 ; $1EC280 |/
  LDA $FF                                   ; $1EC283 |\ PPUCTRL: nametable 0
  AND #$FC                                  ; $1EC285 | |
  STA $2000                                 ; $1EC287 |/
  LDA $79                                   ; $1EC28A |\ fine X scroll = $79
  STA $2005                                 ; $1EC28C |/
  LDA #$C0                                  ; $1EC28F |\ Y scroll = $C0 (192)
  STA $2005                                 ; $1EC291 |/
  JMP irq_exit_disable                      ; $1EC294 | last split

; ===========================================================================
; irq_transition_first_split — middle strip scroll (mode $07, scanline 88)
; ===========================================================================
; First IRQ handler during stage transitions. Fires at scanline $7B (88).
; Sets scroll for the MIDDLE strip (blue boss intro band, y=88-151).
;
; The top strip scrolls left via $FC/$FD (main scroll). The middle strip
; must appear FIXED, so this handler NEGATES the scroll values ($79/$7A),
; canceling the horizontal movement for the middle band.
;
; After setting the middle strip scroll, it programs the next IRQ to fire
; 64 scanlines later (at scanline 152) and chains to the second split
; handler (irq_transition_second_split at $C2D2).
; ---------------------------------------------------------------------------
irq_transition_first_split:
  LDA $2002                                 ; $1EC297 | reset PPU address latch
  LDA $79                                   ; $1EC29A |\ negate $79/$7A (two's complement)
  EOR #$FF                                  ; $1EC29C | | inverted_X = -$79
  CLC                                       ; $1EC29E | |
  ADC #$01                                  ; $1EC29F |/
  STA $9C                                   ; $1EC2A1 | $9C = inverted X scroll (temp)
  LDA $7A                                   ; $1EC2A3 |\ negate high byte with carry
  EOR #$FF                                  ; $1EC2A5 | |
  ADC #$00                                  ; $1EC2A7 | |
  AND #$01                                  ; $1EC2A9 |/ keep only nametable bit
  STA $9D                                   ; $1EC2AB | $9D = inverted nametable select
  LDA $FF                                   ; $1EC2AD |\ PPUCTRL: clear NT bits, set inverted NT
  AND #$FC                                  ; $1EC2AF | |
  ORA $9D                                   ; $1EC2B1 | |
  STA $2000                                 ; $1EC2B3 |/ → middle strip uses opposite nametable
  LDA $9C                                   ; $1EC2B6 |\ set X scroll = negated value
  STA $2005                                 ; $1EC2B8 |/ (cancels horizontal movement)
  LDA #$58                                  ; $1EC2BB |\ set Y scroll = $58 (88)
  STA $2005                                 ; $1EC2BD |/ (top of middle band)
  LDA #$40                                  ; $1EC2C0 |\ set next IRQ at 64 scanlines later
  STA $C000                                 ; $1EC2C2 |/ (scanline 88+64 = 152)
  LDA $C4D0                                 ; $1EC2C5 |\ chain to second split handler
  STA $9C                                   ; $1EC2C8 | | $9C/$9D → $C2D2
  LDA $C4E2                                 ; $1EC2CA | | (irq_transition_second_split)
  STA $9D                                   ; $1EC2CD |/
  JMP irq_exit                              ; $1EC2CF | exit without disabling IRQ

; ===========================================================================
; irq_transition_second_split — bottom strip scroll (mode $07, scanline 152)
; ===========================================================================
; Second IRQ handler during stage transitions. Fires at scanline 152.
; Restores scroll for the BOTTOM strip (y=152-239), which scrolls the same
; direction as the top strip (the stage select background scrolling away).
;
; Uses the $2006/$2006/$2000/$2005/$2005 sequence — the standard NES
; mid-frame scroll trick that sets both coarse and fine scroll via PPU
; address register manipulation.
; ---------------------------------------------------------------------------
irq_transition_second_split:
  LDA $2002                                 ; $1EC2D2 | reset PPU address latch
  LDA $7A                                   ; $1EC2D5 |\ compute PPU $2006 high byte:
  AND #$01                                  ; $1EC2D7 | | nametable bit → bits 2-3
  ASL                                       ; $1EC2D9 | | ($7A & 1) << 2 | $22
  ASL                                       ; $1EC2DA | | → $22 (NT 0) or $26 (NT 1)
  ORA #$22                                  ; $1EC2DB | |
  STA $2006                                 ; $1EC2DD |/
  LDA $79                                   ; $1EC2E0 |\ compute PPU $2006 low byte:
  LSR                                       ; $1EC2E2 | | ($79 >> 3) = coarse X scroll
  LSR                                       ; $1EC2E3 | | | $60 = coarse Y=12 (scanline 96)
  LSR                                       ; $1EC2E4 | |
  AND #$1F                                  ; $1EC2E5 | |
  ORA #$60                                  ; $1EC2E7 | |
  STA $2006                                 ; $1EC2E9 |/
  LDA $7A                                   ; $1EC2EC |\ PPUCTRL: set nametable bits from $7A
  AND #$03                                  ; $1EC2EE | | merge with base value $FF
  ORA $FF                                   ; $1EC2F0 | |
  STA $2000                                 ; $1EC2F2 |/
  LDA $79                                   ; $1EC2F5 |\ fine X scroll = $79 (low 3 bits used)
  STA $2005                                 ; $1EC2F7 |/
  LDA #$98                                  ; $1EC2FA |\ Y scroll = $98 (152) — bottom strip
  STA $2005                                 ; $1EC2FC |/
  JMP irq_exit_disable                      ; $1EC2FF | last split — disable IRQ

; ===========================================================================
; irq_wave_set_strip — water wave scroll strip (mode $09)
; ===========================================================================
; Creates a water wave effect (Gemini Man stage) by alternating X scroll
; direction across strips. $73 indexes the current strip (0-2).
;   Strip 0: X = -$69 + 1,  Y = $30 (48)
;   Strip 1: X =  $69,      Y = $60 (96)
;   Strip 2: X = -$69 + 1,  Y = $90 (144)
; Chains to irq_wave_advance after 14 scanlines.
; ---------------------------------------------------------------------------
irq_wave_set_strip:
  LDA $2002                                 ; $1EC302 | reset PPU latch
  LDY $73                                   ; $1EC305 | Y = strip index (0-2)
  LDA $69                                   ; $1EC307 |\ X scroll = $69 EOR mask + offset
  EOR $C4EC,y                               ; $1EC309 | | masks: $FF/$00/$FF (negate strips 0,2)
  CLC                                       ; $1EC30C | | offsets: $01/$00/$01
  ADC $C4EF,y                               ; $1EC30D | | → alternating wave scroll
  STA $2005                                 ; $1EC310 |/
  LDA $C4F2,y                               ; $1EC313 |\ Y scroll from table: $30/$60/$90
  STA $2005                                 ; $1EC316 |/
  LDA #$0E                                  ; $1EC319 |\ next IRQ in 14 scanlines
  STA $C000                                 ; $1EC31B |/
  LDA $C4D2                                 ; $1EC31E |\ chain to irq_wave_advance ($C32B)
  STA $9C                                   ; $1EC321 | |
  LDA $C4E4                                 ; $1EC323 | |
  STA $9D                                   ; $1EC326 |/
  JMP irq_exit                              ; $1EC328 |

; ===========================================================================
; irq_wave_advance — advance wave strip counter (mode $0A)
; ===========================================================================
; Resets X scroll to 0 between wave strips, advances $73 counter.
; If all 3 strips done, optionally chains to secondary split.
; Otherwise loops back to irq_wave_set_strip after 32 scanlines.
; ---------------------------------------------------------------------------
irq_wave_advance:
  LDA $2002                                 ; $1EC32B | reset PPU latch
  LDY $73                                   ; $1EC32E | Y = strip index
  LDA #$00                                  ; $1EC330 |\ X scroll = 0 (reset between strips)
  STA $2005                                 ; $1EC332 |/
  LDA $C4F5,y                               ; $1EC335 |\ Y scroll from table: $40/$70/$A0
  STA $2005                                 ; $1EC338 |/
  INC $73                                   ; $1EC33B | advance to next strip
  LDA $73                                   ; $1EC33D |
  CMP #$03                                  ; $1EC33F | all 3 strips done?
  BEQ .all_done                             ; $1EC341 | yes → finish
  LDA #$20                                  ; $1EC343 |\ next IRQ in 32 scanlines
  STA $C000                                 ; $1EC345 |/
  LDA $C4D1                                 ; $1EC348 |\ chain back to irq_wave_set_strip ($C302)
  STA $9C                                   ; $1EC34B | |
  LDA $C4E3                                 ; $1EC34D | |
  STA $9D                                   ; $1EC350 |/
  JMP irq_exit                              ; $1EC352 |

.all_done:
  LDA #$00                                  ; $1EC355 | reset strip counter
  STA $73                                   ; $1EC357 |
  LDA $50                                   ; $1EC359 | secondary split?
  BEQ .exit_disabled                        ; $1EC35B | no → last split
  LDA $51                                   ; $1EC35D |\ counter = $51 - $A0
  SEC                                       ; $1EC35F | |
  SBC #$A0                                  ; $1EC360 | |
  STA $C000                                 ; $1EC362 |/
  LDA $C4C9                                 ; $1EC365 |\ chain to irq_gameplay_status_bar
  STA $9C                                   ; $1EC368 | |
  LDA $C4DB                                 ; $1EC36A | |
  STA $9D                                   ; $1EC36D |/
  JMP irq_exit                              ; $1EC36F |

.exit_disabled:
  JMP irq_exit_disable                      ; $1EC372 |

; ===========================================================================
; irq_title_first — title/password screen first split (mode $0B)
; ===========================================================================
; Sets scroll to $2140 (nametable 0, tile row 10) with X=0, Y=0.
; This positions the main content area of the title/password screen.
; Chains to irq_title_second after $4C (76) scanlines.
; ---------------------------------------------------------------------------
irq_title_first:
  LDA $2002                                 ; $1EC375 | reset PPU latch
  LDA #$21                                  ; $1EC378 |\ $2006 = $21:$40
  STA $2006                                 ; $1EC37A | | (nametable 0, tile row 10)
  LDA #$40                                  ; $1EC37D | |
  STA $2006                                 ; $1EC37F |/
  LDA $FF                                   ; $1EC382 |\ PPUCTRL: nametable 0
  AND #$FC                                  ; $1EC384 | |
  STA $2000                                 ; $1EC386 |/
  LDA #$00                                  ; $1EC389 |\ X = 0, Y = 0
  STA $2005                                 ; $1EC38B | |
  STA $2005                                 ; $1EC38E |/
  LDA #$4C                                  ; $1EC391 |\ next IRQ in 76 scanlines
  STA $C000                                 ; $1EC393 |/
  LDA $C4D4                                 ; $1EC396 |\ chain to irq_title_second ($C3A3)
  STA $9C                                   ; $1EC399 | |
  LDA $C4E6                                 ; $1EC39B | |
  STA $9D                                   ; $1EC39E |/
  JMP irq_exit                              ; $1EC3A0 |

; ===========================================================================
; irq_title_second — title/password screen X scroll (mode $0C)
; ===========================================================================
; Sets X scroll from $6A for the bottom portion of the title screen.
; Optionally chains to secondary split for HUD overlay.
; ---------------------------------------------------------------------------
irq_title_second:
  LDA $2002                                 ; $1EC3A3 | reset PPU latch
  LDA $6A                                   ; $1EC3A6 |\ X scroll = $6A
  STA $2005                                 ; $1EC3A8 |/
  LDA #$00                                  ; $1EC3AB |\ Y scroll = 0
  STA $2005                                 ; $1EC3AD |/
  LDA $50                                   ; $1EC3B0 | secondary split?
  BEQ .exit_disabled                        ; $1EC3B2 | no → last split
  LDA $51                                   ; $1EC3B4 |\ counter = $51 - $A0
  SEC                                       ; $1EC3B6 | |
  SBC #$A0                                  ; $1EC3B7 | |
  STA $C000                                 ; $1EC3B9 |/
  LDA $C4C9                                 ; $1EC3BC |\ chain to irq_gameplay_status_bar
  STA $9C                                   ; $1EC3BF | |
  LDA $C4DB                                 ; $1EC3C1 | |
  STA $9D                                   ; $1EC3C4 |/
  JMP irq_exit                              ; $1EC3C6 |

.exit_disabled:
  JMP irq_exit_disable                      ; $1EC3C9 |

; ===========================================================================
; irq_cutscene_scroll — cutscene full scroll setup (mode $0D)
; ===========================================================================
; Full $2006/$2005 mid-frame scroll using $6A (X), $6B (nametable), $7B (Y).
; Used for cutscene/intro sequences with arbitrary scroll positioning.
; Chains to irq_cutscene_secondary after $AE - $7B scanlines.
; ---------------------------------------------------------------------------
irq_cutscene_scroll:
  LDA $2002                                 ; $1EC3CC | reset PPU latch
  LDA $6B                                   ; $1EC3CF |\ $2006 high = ($6B << 2) | $20
  ASL                                       ; $1EC3D1 | | → $20 (NT 0) or $24 (NT 1)
  ASL                                       ; $1EC3D2 | |
  ORA #$20                                  ; $1EC3D3 | |
  STA $2006                                 ; $1EC3D5 |/
  LDA $6A                                   ; $1EC3D8 |\ $2006 low = ($6A >> 3) | $E0
  LSR                                       ; $1EC3DA | | coarse X from $6A, high coarse Y
  LSR                                       ; $1EC3DB | |
  LSR                                       ; $1EC3DC | |
  ORA #$E0                                  ; $1EC3DD | |
  STA $2006                                 ; $1EC3DF |/
  LDA $6A                                   ; $1EC3E2 |\ fine X scroll = $6A
  STA $2005                                 ; $1EC3E4 |/
  LDA $7B                                   ; $1EC3E7 |\ fine Y scroll = $7B
  STA $2005                                 ; $1EC3E9 |/
  LDA $FF                                   ; $1EC3EC |\ PPUCTRL: base | nametable bits from $6B
  ORA $6B                                   ; $1EC3EE | |
  STA $2000                                 ; $1EC3F0 |/
  LDA #$AE                                  ; $1EC3F3 |\ counter = $AE - $7B
  SEC                                       ; $1EC3F5 | | (scanlines to secondary split)
  SBC $7B                                   ; $1EC3F6 | |
  STA $C000                                 ; $1EC3F8 |/
  LDA $C4D6                                 ; $1EC3FB |\ chain to irq_cutscene_secondary ($C408)
  STA $9C                                   ; $1EC3FE | |
  LDA $C4E8                                 ; $1EC400 | |
  STA $9D                                   ; $1EC403 |/
  JMP irq_exit                              ; $1EC405 |

; ===========================================================================
; irq_cutscene_secondary — cutscene secondary split (mode $0E)
; ===========================================================================
; Handles the bottom portion of cutscene screens. If $50 != 0 and
; $51 - $B0 == 0, chains directly to status bar. Otherwise resets scroll
; to $22C0 (nametable 0 bottom) and optionally chains for another split.
; ---------------------------------------------------------------------------
irq_cutscene_secondary:
  LDA $50                                   ; $1EC408 | secondary split enabled?
  BEQ .reset_scroll                         ; $1EC40A | no → reset to origin
  LDA $51                                   ; $1EC40C |\ X = $51 - $B0
  SEC                                       ; $1EC40E | | (remaining scanlines)
  SBC #$B0                                  ; $1EC40F | |
  TAX                                       ; $1EC411 |/
  BNE .reset_scroll                         ; $1EC412 | non-zero → need scroll reset
  JMP irq_gameplay_status_bar               ; $1EC414 | zero → chain directly to status bar

.reset_scroll:
  LDA $2002                                 ; $1EC417 | reset PPU latch
  LDA #$22                                  ; $1EC41A |\ $2006 = $22:$C0
  STA $2006                                 ; $1EC41C | | (nametable 0, bottom portion)
  LDA #$C0                                  ; $1EC41F | |
  STA $2006                                 ; $1EC421 |/
  LDA $FF                                   ; $1EC424 |\ PPUCTRL: nametable 0
  AND #$FC                                  ; $1EC426 | |
  STA $2000                                 ; $1EC428 |/
  LDA #$00                                  ; $1EC42B |\ X = 0, Y = 0
  STA $2005                                 ; $1EC42D | |
  STA $2005                                 ; $1EC430 |/
  LDA $50                                   ; $1EC433 | secondary split?
  BEQ .exit_disabled                        ; $1EC435 | no → last split
  STX $C000                                 ; $1EC437 |\ counter = X (from $51 - $B0 above)
  LDA $C4C9                                 ; $1EC43A | | chain to irq_gameplay_status_bar
  STA $9C                                   ; $1EC43D | |
  LDA $C4DB                                 ; $1EC43F | |
  STA $9D                                   ; $1EC442 |/
  JMP irq_exit                              ; $1EC444 |

.exit_disabled:
  JMP irq_exit_disable                      ; $1EC447 |

; ===========================================================================
; irq_chr_split_first — scroll + chain to CHR swap (mode $0F)
; ===========================================================================
; Sets X scroll from $69, then chains to irq_chr_split_swap after 48
; scanlines. First half of a two-part mid-frame CHR bank swap effect.
; ---------------------------------------------------------------------------
irq_chr_split_first:
  LDA $2002                                 ; $1EC44A | reset PPU latch
  LDA $69                                   ; $1EC44D |\ X scroll = $69
  STA $2005                                 ; $1EC44F |/
  LDA #$00                                  ; $1EC452 |\ Y scroll = 0
  STA $2005                                 ; $1EC454 |/
  LDA #$30                                  ; $1EC457 |\ next IRQ in 48 scanlines
  STA $C000                                 ; $1EC459 |/
  LDA $C4D8                                 ; $1EC45C |\ chain to irq_chr_split_swap ($C469)
  STA $9C                                   ; $1EC45F | |
  LDA $C4EA                                 ; $1EC461 | |
  STA $9D                                   ; $1EC464 |/
  JMP irq_exit                              ; $1EC466 |

; ===========================================================================
; irq_chr_split_swap — scroll + mid-frame CHR bank swap (mode $10)
; ===========================================================================
; Sets X scroll from $6A with nametable from $6B, then performs a mid-frame
; CHR bank swap: swaps BG CHR to banks $66/$72, then sets up $78/$7A for
; the main loop to restore during NMI. $1B flag signals the swap occurred.
; ---------------------------------------------------------------------------
irq_chr_split_swap:
  LDA $2002                                 ; $1EC469 | reset PPU latch
  LDA $6A                                   ; $1EC46C |\ X scroll = $6A
  STA $2005                                 ; $1EC46E |/
  LDA #$00                                  ; $1EC471 |\ Y scroll = 0
  STA $2005                                 ; $1EC473 |/
  LDA $FF                                   ; $1EC476 |\ PPUCTRL: nametable from $6B
  AND #$FC                                  ; $1EC478 | |
  ORA $6B                                   ; $1EC47A | |
  STA $2000                                 ; $1EC47C |/
  LDA #$66                                  ; $1EC47F |\ swap BG CHR bank 0 → $66
  STA $E8                                   ; $1EC481 |/
  LDA #$72                                  ; $1EC483 |\ swap BG CHR bank 1 → $72
  STA $E9                                   ; $1EC485 |/
  JSR select_CHR_banks.reset_flag           ; $1EC487 | apply CHR bank swap
  LDA $F0                                   ; $1EC48A |\ trigger MMC3 bank latch
  STA $8000                                 ; $1EC48C |/
  LDA #$78                                  ; $1EC48F |\ set up next banks for NMI restore
  STA $E8                                   ; $1EC491 | | BG bank 0 → $78
  LDA #$7A                                  ; $1EC493 | |
  STA $E9                                   ; $1EC495 |/ BG bank 1 → $7A
  INC $1B                                   ; $1EC497 | signal main loop: CHR swap occurred
  JMP irq_exit_disable                      ; $1EC499 | last split

; ===========================================================================
; irq_chr_swap_only — CHR bank swap without scroll change (mode $11)
; ===========================================================================
; Performs a mid-frame CHR bank swap to $66/$72 without changing scroll.
; Saves and restores $E8/$E9 so the main loop's bank setup is preserved.
; Falls through to irq_exit_disable.
; ---------------------------------------------------------------------------
irq_chr_swap_only:
  LDA $E8                                   ; $1EC49C |\ save current CHR bank addresses
  PHA                                       ; $1EC49E | |
  LDA $E9                                   ; $1EC49F | |
  PHA                                       ; $1EC4A1 |/
  LDA #$66                                  ; $1EC4A2 |\ temporarily swap BG CHR bank 0 → $66
  STA $E8                                   ; $1EC4A4 |/
  LDA #$72                                  ; $1EC4A6 |\ temporarily swap BG CHR bank 1 → $72
  STA $E9                                   ; $1EC4A8 |/
  JSR select_CHR_banks.reset_flag           ; $1EC4AA | apply CHR bank swap
  LDA $F0                                   ; $1EC4AD |\ trigger MMC3 bank latch
  STA $8000                                 ; $1EC4AF |/
  PLA                                       ; $1EC4B2 |\ restore $E9
  STA $E9                                   ; $1EC4B3 |/
  PLA                                       ; $1EC4B5 |\ restore $E8
  STA $E8                                   ; $1EC4B6 |/
  INC $1B                                   ; $1EC4B8 | signal main loop: CHR swap occurred
; --- IRQ exit routines ---
; Handlers jump here when done. Two entry points:
;   irq_exit_disable ($C4BA): disables IRQ (last split of frame)
;   irq_exit ($C4BD): keeps IRQ enabled (more splits coming)
irq_exit_disable:
  STA $E000                                 ; $1EC4BA | disable MMC3 IRQ (no more splits)
irq_exit:
  PLA                                       ; $1EC4BD |\
  TAY                                       ; $1EC4BE | |
  PLA                                       ; $1EC4BF | | restore registers
  TAX                                       ; $1EC4C0 | |
  PLA                                       ; $1EC4C1 | |
  PLP                                       ; $1EC4C2 |/
  RTI                                       ; $1EC4C3 |

; ===========================================================================
; irq_vector_table — handler addresses indexed by game mode ($78)
; ===========================================================================
; NMI loads $9C/$9D from these tables: low bytes at $C4C8, high at $C4DA.
; The IRQ entry point dispatches via JMP ($009C).
;
; Index | Handler  | Purpose
; ------+----------+---------------------------------------------------
;  $00  | $C4BA    | irq_exit_disable (no-op, no splits needed)
;  $01  | $C152    | irq_gameplay_status_bar — HUD/gameplay split
;  $02  | $C198    | irq_gameplay_hscroll — horizontal scroll after HUD
;  $03  | $C1C1    | irq_gameplay_ntswap — nametable swap after HUD
;  $04  | $C200    | irq_gameplay_vscroll — vertical scroll after HUD
;  $05  | $C235    | irq_stagesel_first — stage select X scroll
;  $06  | $C26F    | irq_stagesel_second — stage select bottom (chain)
;  $07  | $C297    | irq_transition_first_split — 3-strip middle band
;  $08  | $C2D2    | irq_transition_second_split — 3-strip bottom (chain)
;  $09  | $C302    | irq_wave_set_strip — water wave strip (Gemini Man)
;  $0A  | $C32B    | irq_wave_advance — wave strip loop (chain)
;  $0B  | $C375    | irq_title_first — title/password first split
;  $0C  | $C3A3    | irq_title_second — title/password X scroll (chain)
;  $0D  | $C3CC    | irq_cutscene_scroll — full $2006/$2005 scroll
;  $0E  | $C408    | irq_cutscene_secondary — secondary split (chain)
;  $0F  | $C44A    | irq_chr_split_first — scroll + chain to CHR swap
;  $10  | $C469    | irq_chr_split_swap — scroll + mid-frame CHR swap
;  $11  | $C49C    | irq_chr_swap_only — CHR bank swap (no scroll)
; ---------------------------------------------------------------------------
; 4 unused bytes (padding/alignment)
  db $00, $00, $00, $00                     ; $1EC4C4 |
; low bytes of handler addresses ($C4C8, 18 entries)
irq_vector_lo:
  db $BA, $52, $98, $C1                     ; $1EC4C8 | modes $00-$03
  db $00, $35, $6F, $97, $D2, $02, $2B, $75 ; $1EC4CC | modes $04-$0B
  db $A3, $CC, $08, $4A, $69, $9C          ; $1EC4D4 | modes $0C-$11
; high bytes of handler addresses ($C4DA, 18 entries)
irq_vector_hi:
  db $C4, $C1                              ; $1EC4DA | modes $00-$01
  db $C1, $C1, $C2, $C2, $C2, $C2, $C2, $C3 ; $1EC4DC | modes $02-$09
  db $C3, $C3, $C3, $C3, $C4, $C4, $C4, $C4 ; $1EC4E4 | modes $0A-$11
; --- water wave scroll tables (used by irq_wave_set_strip/advance) ---
; $73 indexes strip 0-2. Strips 0,2 invert X scroll; strip 1 keeps it.
wave_eor_masks:
  db $FF, $00, $FF                          ; $1EC4EC | EOR: negate/keep/negate X scroll
wave_adc_offsets:
  db $01, $00, $01                          ; $1EC4EF | ADC: +1/0/+1 (two's complement fixup)
wave_y_scroll_set:
  db $30, $60, $90                          ; $1EC4F2 | Y scroll for set_strip: 48/96/144
wave_y_scroll_advance:
  db $40, $70, $A0                          ; $1EC4F5 | Y scroll for advance: 64/112/160

code_1EC4F8:
  LDX #$00                                  ; $1EC4F8 |
  STX $19                                   ; $1EC4FA |
code_1EC4FC:
  LDA $0780,x                               ; $1EC4FC |
  BMI code_1EC51C                           ; $1EC4FF |
  STA $2006                                 ; $1EC501 |
  LDA $0781,x                               ; $1EC504 |
  STA $2006                                 ; $1EC507 |
  LDY $0782,x                               ; $1EC50A |
code_1EC50D:
  LDA $0783,x                               ; $1EC50D |
  STA $2007                                 ; $1EC510 |
  INX                                       ; $1EC513 |
  DEY                                       ; $1EC514 |
  BPL code_1EC50D                           ; $1EC515 |
  INX                                       ; $1EC517 |
  INX                                       ; $1EC518 |
  INX                                       ; $1EC519 |
  BNE code_1EC4FC                           ; $1EC51A |
code_1EC51C:
  RTS                                       ; $1EC51C |

  LDA $FF                                   ; $1EC51D |
  AND #$11                                  ; $1EC51F |
  STA $FF                                   ; $1EC521 |
  STA $2000                                 ; $1EC523 |
  RTS                                       ; $1EC526 |

  LDA $FF                                   ; $1EC527 |
  ORA #$80                                  ; $1EC529 |
  STA $FF                                   ; $1EC52B |
  STA $2000                                 ; $1EC52D |
  RTS                                       ; $1EC530 |

code_1EC531:
  INC $EE                                   ; $1EC531 |
  LDA #$00                                  ; $1EC533 |
  STA $FE                                   ; $1EC535 |
  STA $2001                                 ; $1EC537 |
  RTS                                       ; $1EC53A |

code_1EC53B:
  DEC $EE                                   ; $1EC53B |
  LDA #$18                                  ; $1EC53D |
  STA $FE                                   ; $1EC53F |
  STA $2001                                 ; $1EC541 |
  RTS                                       ; $1EC544 |

code_1EC545:
  LDX #$01                                  ; $1EC545 |
  STX $4016                                 ; $1EC547 |
  DEX                                       ; $1EC54A |
  STX $4016                                 ; $1EC54B |
  LDX #$08                                  ; $1EC54E |
code_1EC550:
  LDA $4016                                 ; $1EC550 |
  LSR                                       ; $1EC553 |
  ROL $14                                   ; $1EC554 |
  LSR                                       ; $1EC556 |
  ROL $00                                   ; $1EC557 |
  LDA $4017                                 ; $1EC559 |
  LSR                                       ; $1EC55C |
  ROL $15                                   ; $1EC55D |
  LSR                                       ; $1EC55F |
  ROL $01                                   ; $1EC560 |
  DEX                                       ; $1EC562 |
  BNE code_1EC550                           ; $1EC563 |
  LDA $00                                   ; $1EC565 |
  ORA $14                                   ; $1EC567 |
  STA $14                                   ; $1EC569 |
  LDA $01                                   ; $1EC56B |
  ORA $15                                   ; $1EC56D |
  STA $15                                   ; $1EC56F |
  LDX #$01                                  ; $1EC571 |
code_1EC573:
  LDA $14,x                                 ; $1EC573 |
  TAY                                       ; $1EC575 |
  EOR $16,x                                 ; $1EC576 |
  AND $14,x                                 ; $1EC578 |
  STA $14,x                                 ; $1EC57A |
  STY $16,x                                 ; $1EC57C |
  DEX                                       ; $1EC57E |
  BPL code_1EC573                           ; $1EC57F |
  LDX #$03                                  ; $1EC581 |
code_1EC583:
  LDA $14,x                                 ; $1EC583 |
  AND #$0C                                  ; $1EC585 |
  CMP #$0C                                  ; $1EC587 |
  BEQ code_1EC593                           ; $1EC589 |
  LDA $14,x                                 ; $1EC58B |
  AND #$03                                  ; $1EC58D |
  CMP #$03                                  ; $1EC58F |
  BNE code_1EC599                           ; $1EC591 |
code_1EC593:
  LDA $14,x                                 ; $1EC593 |
  AND #$F0                                  ; $1EC595 |
  STA $14,x                                 ; $1EC597 |
code_1EC599:
  DEX                                       ; $1EC599 |
  BPL code_1EC583                           ; $1EC59A |
  RTS                                       ; $1EC59C |

code_1EC59D:
  STA $00                                   ; $1EC59D |
  STX $01                                   ; $1EC59F |
  STY $02                                   ; $1EC5A1 |
  LDA $2002                                 ; $1EC5A3 |
  LDA $FF                                   ; $1EC5A6 |
  AND #$FE                                  ; $1EC5A8 |
  STA $2000                                 ; $1EC5AA |
  LDA $00                                   ; $1EC5AD |
  STA $2006                                 ; $1EC5AF |
  LDY #$00                                  ; $1EC5B2 |
  STY $2006                                 ; $1EC5B4 |
  LDX #$04                                  ; $1EC5B7 |
  CMP #$20                                  ; $1EC5B9 |
  BCS code_1EC5BF                           ; $1EC5BB |
  LDX $02                                   ; $1EC5BD |
code_1EC5BF:
  LDY #$00                                  ; $1EC5BF |
  LDA $01                                   ; $1EC5C1 |
code_1EC5C3:
  STA $2007                                 ; $1EC5C3 |
  DEY                                       ; $1EC5C6 |
  BNE code_1EC5C3                           ; $1EC5C7 |
  DEX                                       ; $1EC5C9 |
  BNE code_1EC5C3                           ; $1EC5CA |
  LDY $02                                   ; $1EC5CC |
  LDA $00                                   ; $1EC5CE |
  CMP #$20                                  ; $1EC5D0 |
  BCC code_1EC5E6                           ; $1EC5D2 |
  ADC #$02                                  ; $1EC5D4 |
  STA $2006                                 ; $1EC5D6 |
  LDA #$C0                                  ; $1EC5D9 |
  STA $2006                                 ; $1EC5DB |
  LDX #$40                                  ; $1EC5DE |
code_1EC5E0:
  STY $2007                                 ; $1EC5E0 |
  DEX                                       ; $1EC5E3 |
  BNE code_1EC5E0                           ; $1EC5E4 |
code_1EC5E6:
  LDX $01                                   ; $1EC5E6 |
  RTS                                       ; $1EC5E8 |

code_1EC5E9:
  LDA $30                                   ; $1EC5E9 |
  CMP #$07                                  ; $1EC5EB |
  BNE code_1EC5F5                           ; $1EC5ED |
  LDX #$6C                                  ; $1EC5EF |
  STX $97                                   ; $1EC5F1 |
  BNE code_1EC60A                           ; $1EC5F3 |
code_1EC5F5:
  LDX $97                                   ; $1EC5F5 |
  CPX #$04                                  ; $1EC5F7 |
  BNE code_1EC600                           ; $1EC5F9 |
  LDA #$F8                                  ; $1EC5FB |
  STA $0200                                 ; $1EC5FD |
code_1EC600:
  LDA $50                                   ; $1EC600 |
  BNE code_1EC60A                           ; $1EC602 |
  LDA $72                                   ; $1EC604 |
  BEQ code_1EC60A                           ; $1EC606 |
  LDX #$30                                  ; $1EC608 |
code_1EC60A:
  LDA #$F8                                  ; $1EC60A |
code_1EC60C:
  STA $0200,x                               ; $1EC60C |
  INX                                       ; $1EC60F |
  INX                                       ; $1EC610 |
  INX                                       ; $1EC611 |
  INX                                       ; $1EC612 |
  BNE code_1EC60C                           ; $1EC613 |
  LDA $50                                   ; $1EC615 |
  BNE code_1EC627                           ; $1EC617 |
  LDA $71                                   ; $1EC619 |
  BNE code_1EC63E                           ; $1EC61B |
  LDA $72                                   ; $1EC61D |
  BNE code_1EC669                           ; $1EC61F |
  LDA $F8                                   ; $1EC621 |
  CMP #$02                                  ; $1EC623 |
  BEQ code_1EC696                           ; $1EC625 |
code_1EC627:
  RTS                                       ; $1EC627 |

code_1EC628:
  LDX #$1F                                  ; $1EC628 |
code_1EC62A:
  LDA #$00                                  ; $1EC62A |
  STA $0300,x                               ; $1EC62C |
  LDA #$FF                                  ; $1EC62F |
  STA $04C0,x                               ; $1EC631 |
  DEX                                       ; $1EC634 |
  BNE code_1EC62A                           ; $1EC635 |
  LDA #$00                                  ; $1EC637 |
  STA $71                                   ; $1EC639 |
  STA $72                                   ; $1EC63B |
  RTS                                       ; $1EC63D |

code_1EC63E:
  LDA #$00                                  ; $1EC63E |
  STA $71                                   ; $1EC640 |
  LDY #$2C                                  ; $1EC642 |
code_1EC644:
  LDA $C6D8,y                               ; $1EC644 |
  STA $0200,y                               ; $1EC647 |
  LDA $C6D9,y                               ; $1EC64A |
  STA $0201,y                               ; $1EC64D |
  LDA $C6DA,y                               ; $1EC650 |
  STA $0202,y                               ; $1EC653 |
  LDA $C6DB,y                               ; $1EC656 |
  STA $0203,y                               ; $1EC659 |
  DEY                                       ; $1EC65C |
  DEY                                       ; $1EC65D |
  DEY                                       ; $1EC65E |
  DEY                                       ; $1EC65F |
  BPL code_1EC644                           ; $1EC660 |
  STY $72                                   ; $1EC662 |
  LDA #$30                                  ; $1EC664 |
  STA $97                                   ; $1EC666 |
  RTS                                       ; $1EC668 |

code_1EC669:
  LDY #$14                                  ; $1EC669 |
code_1EC66B:
  LDA $0203,y                               ; $1EC66B |
  SEC                                       ; $1EC66E |
  SBC #$01                                  ; $1EC66F |
  STA $0203,y                               ; $1EC671 |
  DEY                                       ; $1EC674 |
  DEY                                       ; $1EC675 |
  DEY                                       ; $1EC676 |
  DEY                                       ; $1EC677 |
  BPL code_1EC66B                           ; $1EC678 |
  LDA $95                                   ; $1EC67A |
  AND #$01                                  ; $1EC67C |
  BNE code_1EC691                           ; $1EC67E |
  LDY #$14                                  ; $1EC680 |
code_1EC682:
  LDA $021B,y                               ; $1EC682 |
  SEC                                       ; $1EC685 |
  SBC #$01                                  ; $1EC686 |
  STA $021B,y                               ; $1EC688 |
  DEY                                       ; $1EC68B |
  DEY                                       ; $1EC68C |
  DEY                                       ; $1EC68D |
  DEY                                       ; $1EC68E |
  BPL code_1EC682                           ; $1EC68F |
code_1EC691:
  LDA #$30                                  ; $1EC691 |
  STA $97                                   ; $1EC693 |
  RTS                                       ; $1EC695 |

code_1EC696:
  LDA $FC                                   ; $1EC696 |
  STA $00                                   ; $1EC698 |
  LDA $F9                                   ; $1EC69A |
  LSR                                       ; $1EC69C |
  ROR $00                                   ; $1EC69D |
  LSR                                       ; $1EC69F |
  ROR $00                                   ; $1EC6A0 |
  LDA $95                                   ; $1EC6A2 |
  AND #$01                                  ; $1EC6A4 |
  ASL                                       ; $1EC6A6 |
  ASL                                       ; $1EC6A7 |
  ASL                                       ; $1EC6A8 |
  ASL                                       ; $1EC6A9 |
  ASL                                       ; $1EC6AA |
  TAY                                       ; $1EC6AB |
  LDX #$1C                                  ; $1EC6AC |
code_1EC6AE:
  LDA $C708,y                               ; $1EC6AE |
  STA $0200,x                               ; $1EC6B1 |
  LDA $C709,y                               ; $1EC6B4 |
  STA $0201,x                               ; $1EC6B7 |
  LDA $C70A,y                               ; $1EC6BA |
  STA $0202,x                               ; $1EC6BD |
  LDA $C70B,y                               ; $1EC6C0 |
  SEC                                       ; $1EC6C3 |
  SBC $00                                   ; $1EC6C4 |
  STA $0203,x                               ; $1EC6C6 |
  INY                                       ; $1EC6C9 |
  INY                                       ; $1EC6CA |
  INY                                       ; $1EC6CB |
  INY                                       ; $1EC6CC |
  DEX                                       ; $1EC6CD |
  DEX                                       ; $1EC6CE |
  DEX                                       ; $1EC6CF |
  DEX                                       ; $1EC6D0 |
  BPL code_1EC6AE                           ; $1EC6D1 |
  LDA #$20                                  ; $1EC6D3 |
  STA $97                                   ; $1EC6D5 |
  RTS                                       ; $1EC6D7 |

  db $58, $F1, $02, $28, $E0, $F1, $02, $28 ; $1EC6D8 |
  db $B8, $F1, $02, $70, $20, $F1, $02, $A0 ; $1EC6E0 |
  db $68, $F1, $02, $D0, $D8, $F1, $02, $D0 ; $1EC6E8 |
  db $90, $F2, $02, $10, $40, $F2, $02, $58 ; $1EC6F0 |
  db $D0, $F2, $02, $58, $78, $F2, $02, $80 ; $1EC6F8 |
  db $28, $F2, $02, $D8, $A8, $F2, $02, $D8 ; $1EC700 |
  db $90, $E4, $03, $18, $28, $E4, $03, $20 ; $1EC708 |
  db $68, $E4, $03, $30, $58, $E4, $03, $60 ; $1EC710 |
  db $80, $E4, $03, $70, $10, $E4, $03, $98 ; $1EC718 |
  db $58, $E4, $03, $C0, $80, $E4, $03, $D0 ; $1EC720 |
  db $18, $E4, $03, $10, $A0, $E4, $03, $48 ; $1EC728 |
  db $28, $E4, $03, $58, $40, $E4, $03, $90 ; $1EC730 |
  db $98, $E4, $03, $A0, $78, $E4, $03, $D8 ; $1EC738 |
  db $30, $E4, $03, $E0, $A0, $E4, $03, $E8 ; $1EC740 |
  db $00, $00, $00, $00                     ; $1EC748 |

code_1EC74C:
  LDA #$30                                  ; $1EC74C |
  LDX #$F0                                  ; $1EC74E |
  BNE code_1EC755                           ; $1EC750 |
code_1EC752:
  LDA #$10                                  ; $1EC752 |
  TAX                                       ; $1EC754 |
code_1EC755:
  STA $0F                                   ; $1EC755 |
  STX $0D                                   ; $1EC757 |
  LDY #$04                                  ; $1EC759 |
  STY $0E                                   ; $1EC75B |
code_1EC75D:
  LDY #$1F                                  ; $1EC75D |
code_1EC75F:
  LDA $0620,y                               ; $1EC75F |
  STA $0600,y                               ; $1EC762 |
  DEY                                       ; $1EC765 |
  BPL code_1EC75F                           ; $1EC766 |
  LDY #$1F                                  ; $1EC768 |
code_1EC76A:
  LDA $0600,y                               ; $1EC76A |
  SEC                                       ; $1EC76D |
  SBC $0F                                   ; $1EC76E |
  BPL code_1EC774                           ; $1EC770 |
  LDA #$0F                                  ; $1EC772 |
code_1EC774:
  STA $0600,y                               ; $1EC774 |
  DEY                                       ; $1EC777 |
  BPL code_1EC76A                           ; $1EC778 |
  STY $18                                   ; $1EC77A |
  LDA $0E                                   ; $1EC77C |
code_1EC77E:
  PHA                                       ; $1EC77E |
  JSR task_yield                           ; $1EC77F |
  PLA                                       ; $1EC782 |
  SEC                                       ; $1EC783 |
  SBC #$01                                  ; $1EC784 |
  BNE code_1EC77E                           ; $1EC786 |
  LDA $0F                                   ; $1EC788 |
  CLC                                       ; $1EC78A |
  ADC $0D                                   ; $1EC78B |
  STA $0F                                   ; $1EC78D |
  CMP #$50                                  ; $1EC78F |
  BEQ code_1EC797                           ; $1EC791 |
  LDA $0F                                   ; $1EC793 |
  BPL code_1EC75D                           ; $1EC795 |
code_1EC797:
  RTS                                       ; $1EC797 |

code_1EC798:
  LDA $1C                                   ; $1EC798 |
  BEQ code_1EC7DC                           ; $1EC79A |
  LDA $95                                   ; $1EC79C |
  AND #$03                                  ; $1EC79E |
  BNE code_1EC7DC                           ; $1EC7A0 |
  LDY #$1F                                  ; $1EC7A2 |
code_1EC7A4:
  LDA $0620,y                               ; $1EC7A4 |
  STA $0600,y                               ; $1EC7A7 |
  DEY                                       ; $1EC7AA |
  BPL code_1EC7A4                           ; $1EC7AB |
  LDY #$0F                                  ; $1EC7AD |
code_1EC7AF:
  LDA $0600,y                               ; $1EC7AF |
  SEC                                       ; $1EC7B2 |
  SBC $1D                                   ; $1EC7B3 |
  BPL code_1EC7B9                           ; $1EC7B5 |
  LDA #$0F                                  ; $1EC7B7 |
code_1EC7B9:
  STA $0600,y                               ; $1EC7B9 |
  DEY                                       ; $1EC7BC |
  BPL code_1EC7AF                           ; $1EC7BD |
  STY $18                                   ; $1EC7BF |
  LDA $1D                                   ; $1EC7C1 |
  CLC                                       ; $1EC7C3 |
  ADC $1E                                   ; $1EC7C4 |
  STA $1D                                   ; $1EC7C6 |
  CMP #$F0                                  ; $1EC7C8 |
  BEQ code_1EC7D4                           ; $1EC7CA |
  CMP #$50                                  ; $1EC7CC |
  BNE code_1EC7DC                           ; $1EC7CE |
  INC $71                                   ; $1EC7D0 |
  BNE code_1EC7D8                           ; $1EC7D2 |
code_1EC7D4:
  LDA #$00                                  ; $1EC7D4 |
  STA $72                                   ; $1EC7D6 |
code_1EC7D8:
  LDA #$00                                  ; $1EC7D8 |
  STA $1C                                   ; $1EC7DA |
code_1EC7DC:
  RTS                                       ; $1EC7DC |

  STX $0E                                   ; $1EC7DD |
  STY $0F                                   ; $1EC7DF |
  ASL                                       ; $1EC7E1 |
  TAY                                       ; $1EC7E2 |
  INY                                       ; $1EC7E3 |
  PLA                                       ; $1EC7E4 |
  STA $0C                                   ; $1EC7E5 |
  PLA                                       ; $1EC7E7 |
  STA $0D                                   ; $1EC7E8 |
  LDA ($0C),y                               ; $1EC7EA |
  TAX                                       ; $1EC7EC |
  INY                                       ; $1EC7ED |
  LDA ($0C),y                               ; $1EC7EE |
  STA $0D                                   ; $1EC7F0 |
  STX $0C                                   ; $1EC7F2 |
  LDX $0E                                   ; $1EC7F4 |
  LDY $0F                                   ; $1EC7F6 |
  JMP ($000C)                               ; $1EC7F8 |

code_1EC7FB:
  LDX #$00                                  ; $1EC7FB |
  LDY #$04                                  ; $1EC7FD |
  LDA $E4,x                                 ; $1EC7FF |
  AND #$02                                  ; $1EC801 |
  STA $00                                   ; $1EC803 |
  LDA $E5,x                                 ; $1EC805 |
  AND #$02                                  ; $1EC807 |
  EOR $00                                   ; $1EC809 |
  CLC                                       ; $1EC80B |
  BEQ code_1EC80F                           ; $1EC80C |
  SEC                                       ; $1EC80E |
code_1EC80F:
  ROR $E4,x                                 ; $1EC80F |
  INX                                       ; $1EC811 |
  DEY                                       ; $1EC812 |
  BNE code_1EC80F                           ; $1EC813 |
  RTS                                       ; $1EC815 |

; -----------------------------------------------
; load_stage: loads level data from stage bank into RAM
; reads screen layout, palette, and metatile column grid
; STAGE BANK DATA LAYOUT ($A000-$BFFF per stage):
;   $A000-$A4FF: global enemy data (bank $00 only: flags, AI IDs, shapes, HP)
;   $AA00+:      screen metatile grid (loaded to RAM, used by tile collision)
;   $AA60:       screen pointer table (2 bytes/screen: init param + layout index)
;   $AA80-$AA81: palette indices
;   $AA82+:      screen layout data (20 bytes/screen: 16 column IDs + 4 connection)
;   $AF00+:      metatile column definitions (64 bytes per column ID)
;   $B700+:      metatile CHR tile definitions (4 bytes per metatile: 2x2 CHR tiles)
;   $BF00-$BFFF: tile collision attribute table (256 bytes, 1 per metatile)
; -----------------------------------------------
load_stage:
  LDA $22                                   ; $1EC816 |\ switch to stage's PRG bank
  STA $F5                                   ; $1EC818 | | ($A000-$BFFF = stage data)
  JSR select_PRG_banks                      ; $1EC81A |/
  LDA $AA80                                 ; $1EC81D |\ load palette indices
  STA $E8                                   ; $1EC820 | | from stage bank
  LDA $AA81                                 ; $1EC822 | |
  STA $E9                                   ; $1EC825 |/
  LDX #$07                                  ; $1EC827 |\ copy default palette
code_1EC829:                                         ; | from $C898 (fixed bank)
  LDA $C898,x                               ; $1EC829 | | to sprite palette RAM
  STA $0610,x                               ; $1EC82C | |
  STA $0630,x                               ; $1EC82F | |
  DEX                                       ; $1EC832 | |
  BPL code_1EC829                           ; $1EC833 |/
  LDA #$00                                  ; $1EC835 |
  STA $EA                                   ; $1EC837 |
  LDA #$01                                  ; $1EC839 |
  STA $EB                                   ; $1EC83B |
code_1EC83D:
  LDA $2B                                   ; $1EC83D |
  ASL                                       ; $1EC83F |
  TAX                                       ; $1EC840 |
  LDA $AA60,x                               ; $1EC841 |  screen init param (saved for later)
  PHA                                       ; $1EC844 |
  LDA $AA61,x                               ; $1EC845 |\ screen layout index
  ASL                                       ; $1EC848 | | multiply by 20:
  ASL                                       ; $1EC849 | | *4 → $00
  STA $00                                   ; $1EC84A | | *16
  ASL                                       ; $1EC84C | | *16 + *4 = *20
  ASL                                       ; $1EC84D | | (20 bytes per screen entry:
  ADC $00                                   ; $1EC84E | |  16 column IDs + 4 connection)
  TAY                                       ; $1EC850 |/
  LDX #$00                                  ; $1EC851 |
.load_columns:
  LDA $AA82,y                               ; $1EC853 |\ copy 16 metatile column IDs
  STA $0600,x                               ; $1EC856 | | to $0600-$060F (current screen)
  STA $0620,x                               ; $1EC859 | | and $0620-$062F (mirror)
  INY                                       ; $1EC85C | |
  INX                                       ; $1EC85D | |
  CPX #$10                                  ; $1EC85E | |
  BNE .load_columns                         ; $1EC860 |/
  LDX #$00                                  ; $1EC862 |
.load_connections:
  LDA $AA82,y                               ; $1EC864 |\ 4 screen connection bytes:
  PHA                                       ; $1EC867 | | bit 7 → $0100,x (direction flag)
  AND #$80                                  ; $1EC868 | | bits 0-6 → $0108,x (target screen)
  STA $0100,x                               ; $1EC86A | |
  PLA                                       ; $1EC86D | |
  AND #$7F                                  ; $1EC86E | |
  STA $0108,x                               ; $1EC870 | |
  LDA #$00                                  ; $1EC873 | |
  STA $0104,x                               ; $1EC875 | |
  STA $010C,x                               ; $1EC878 | |
  INY                                       ; $1EC87B | |
  INX                                       ; $1EC87C | |
  CPX #$04                                  ; $1EC87D | |
  BNE .load_connections                     ; $1EC87F |/
  LDA $0600                                 ; $1EC881 |
  STA $0610                                 ; $1EC884 |
  STA $0630                                 ; $1EC887 |
  LDA #$01                                  ; $1EC88A |
  STA $F5                                   ; $1EC88C |
  JSR select_PRG_banks                      ; $1EC88E |
  PLA                                       ; $1EC891 |
  JSR $A000                                 ; $1EC892 |
  JMP update_CHR_banks                      ; $1EC895 |

  db $0F, $0F, $2C, $11, $0F, $0F, $30, $37 ; $1EC898 |

code_1EC8A0:
  TXA                                       ; $1EC8A0 |
  PHA                                       ; $1EC8A1 |
  TYA                                       ; $1EC8A2 |
  PHA                                       ; $1EC8A3 |
  LDA $F5                                   ; $1EC8A4 |
  CMP #$13                                  ; $1EC8A6 |
  BEQ code_1EC8B4                           ; $1EC8A8 |
  LDY $22                                   ; $1EC8AA |
  LDA $C8B9,y                               ; $1EC8AC |
  STA $F5                                   ; $1EC8AF |
  JSR select_PRG_banks                      ; $1EC8B1 |
code_1EC8B4:
  PLA                                       ; $1EC8B4 |
  TAY                                       ; $1EC8B5 |
  PLA                                       ; $1EC8B6 |
  TAX                                       ; $1EC8B7 |
  RTS                                       ; $1EC8B8 |

; stage_to_bank: maps stage index ($22) → PRG bank ($F5)
; $00=Needle $01=Magnet $02=Gemini $03=Hard $04=Top $05=Snake $06=Spark $07=Shadow
; $08-$0B=Doc Robot (Needle/Gemini/Spark/Shadow stages)
; $0C-$0F=Wily fortress, $10+=special/ending
  db $00, $01, $02, $03, $04, $05, $06, $07 ; $1EC8B9 |
  db $08, $09, $0A, $0B, $0C, $0D, $0D, $0F ; $1EC8C1 |
  db $0D, $11, $12, $13, $10, $1E, $0E      ; $1EC8C9 |

  LDX #$BF                                  ; $1EC8D0 |
  TXS                                       ; $1EC8D2 |
  LDA $FF                                   ; $1EC8D3 |
  STA $2000                                 ; $1EC8D5 |
  JSR task_yield                           ; $1EC8D8 |
  LDA #$88                                  ; $1EC8DB |
  STA $E4                                   ; $1EC8DD |
  CLI                                       ; $1EC8DF |
  LDA #$01                                  ; $1EC8E0 |
  STA $9B                                   ; $1EC8E2 |
  LDA #$00                                  ; $1EC8E4 |
  JSR submit_sound_ID_D9                    ; $1EC8E6 |
  LDA #$40                                  ; $1EC8E9 |
  STA $99                                   ; $1EC8EB |
  LDA #$18                                  ; $1EC8ED |
  STA $F4                                   ; $1EC8EF |
  JSR select_PRG_banks                      ; $1EC8F1 |
  JSR $9009                                 ; $1EC8F4 |
  LDA #$9C                                  ; $1EC8F7 |
  STA $A9                                   ; $1EC8F9 |
  LDA #$02                                  ; $1EC8FB |
  STA $AE                                   ; $1EC8FD |
code_1EC8FF:
  LDA #$00                                  ; $1EC8FF |
  LDY #$1F                                  ; $1EC901 |
code_1EC903:
  STA $0150,y                               ; $1EC903 |
  DEY                                       ; $1EC906 |
  BPL code_1EC903                           ; $1EC907 |
code_1EC909:
  LDA #$00                                  ; $1EC909 |
  STA $EE                                   ; $1EC90B |
  JSR code_1EC752                           ; $1EC90D |
  LDA #$04                                  ; $1EC910 |
  STA $97                                   ; $1EC912 |
  JSR code_1EC5E9                           ; $1EC914 |
  JSR task_yield                           ; $1EC917 |
  JSR code_1EC628                           ; $1EC91A |
  LDA #$01                                  ; $1EC91D |
  STA $A000                                 ; $1EC91F |
  LDA #$00                                  ; $1EC922 |
  STA $F8                                   ; $1EC924 |
  STA $0300                                 ; $1EC926 |
  STA $FD                                   ; $1EC929 |
  STA $71                                   ; $1EC92B |
  STA $72                                   ; $1EC92D |
  STA $FC                                   ; $1EC92F |
  STA $FA                                   ; $1EC931 |
  STA $F9                                   ; $1EC933 |
  STA $25                                   ; $1EC935 |
  STA $0380                                 ; $1EC937 |
  STA $03E0                                 ; $1EC93A |
  STA $B1                                   ; $1EC93D |
  STA $B2                                   ; $1EC93F |
  STA $B3                                   ; $1EC941 |
  STA $9E                                   ; $1EC943 |
  STA $9F                                   ; $1EC945 |
  STA $5A                                   ; $1EC947 |
  STA $A0                                   ; $1EC949 |
  STA $B4                                   ; $1EC94B |
  STA $A1                                   ; $1EC94D |
  STA $6F                                   ; $1EC94F |
  LDY $22                                   ; $1EC951 |
  LDA $CD0C,y                               ; $1EC953 |
  JSR submit_sound_ID_D9                    ; $1EC956 |
  LDA #$01                                  ; $1EC959 |
  STA $31                                   ; $1EC95B |
  STA $23                                   ; $1EC95D |
  STA $2E                                   ; $1EC95F |
  LDA #$FF                                  ; $1EC961 |
  STA $29                                   ; $1EC963 |
  LDA #$1F                                  ; $1EC965 |
  STA $24                                   ; $1EC967 |
code_1EC969:
  LDA #$01                                  ; $1EC969 |
  STA $10                                   ; $1EC96B |
  JSR code_1FE4F1                           ; $1EC96D |
  JSR task_yield                           ; $1EC970 |
  LDA $29                                   ; $1EC973 |
  BEQ code_1EC969                           ; $1EC975 |
  LDA $22                                   ; $1EC977 |
  STA $F5                                   ; $1EC979 |
  JSR select_PRG_banks                      ; $1EC97B |
  LDA $AA40                                 ; $1EC97E |
  PHA                                       ; $1EC981 |
  AND #$E0                                  ; $1EC982 |
  STA $2A                                   ; $1EC984 |
  LDX #$01                                  ; $1EC986 |
  LDY #$2A                                  ; $1EC988 |
  AND #$C0                                  ; $1EC98A |
  BEQ code_1EC991                           ; $1EC98C |
  DEX                                       ; $1EC98E |
  LDY #$26                                  ; $1EC98F |
code_1EC991:
  STX $A000                                 ; $1EC991 |
  STY $52                                   ; $1EC994 |
  PLA                                       ; $1EC996 |
  AND #$1F                                  ; $1EC997 |
  STA $2C                                   ; $1EC999 |
  LDA #$00                                  ; $1EC99B |
  STA $2B                                   ; $1EC99D |
  STA $2D                                   ; $1EC99F |
  JSR load_stage                           ; $1EC9A1 |
  LDA #$00                                  ; $1EC9A4 |
  STA $18                                   ; $1EC9A6 |
  JSR task_yield                           ; $1EC9A8 |
  JSR code_1EC74C                           ; $1EC9AB |
  LDA #$80                                  ; $1EC9AE |
  STA $0360                                 ; $1EC9B0 |
code_1EC9B3:
  LDA #$9C                                  ; $1EC9B3 |
  STA $A2                                   ; $1EC9B5 |
  LDA #$E8                                  ; $1EC9B7 |
  STA $51                                   ; $1EC9B9 |
  STA $5E                                   ; $1EC9BB |
  LDA $F9                                   ; $1EC9BD |
  BNE code_1EC9D3                           ; $1EC9BF |
  LDA $22                                   ; $1EC9C1 |
  CMP #$02                                  ; $1EC9C3 |
  BEQ code_1EC9CB                           ; $1EC9C5 |
  CMP #$09                                  ; $1EC9C7 |
  BNE code_1EC9D3                           ; $1EC9C9 |
code_1EC9CB:
  LDA #$9F                                  ; $1EC9CB |
  STA $5E                                   ; $1EC9CD |
  LDA #$02                                  ; $1EC9CF |
  STA $F8                                   ; $1EC9D1 |
code_1EC9D3:
  LDA #$74                                  ; $1EC9D3 |
  STA $EA                                   ; $1EC9D5 |
  LDA #$75                                  ; $1EC9D7 |
  STA $EB                                   ; $1EC9D9 |
  JSR update_CHR_banks                      ; $1EC9DB |
  LDA #$30                                  ; $1EC9DE |
  STA $0611                                 ; $1EC9E0 |
  INC $18                                   ; $1EC9E3 |
  LDA #$3C                                  ; $1EC9E5 |
code_1EC9E7:
  PHA                                       ; $1EC9E7 |
  LDA $95                                   ; $1EC9E8 |
  AND #$10                                  ; $1EC9EA |
  BEQ code_1ECA10                           ; $1EC9EC |
  LDX #$10                                  ; $1EC9EE |
code_1EC9F0:
  LDA $CCF8,x                               ; $1EC9F0 |
  STA $0200,x                               ; $1EC9F3 |
  LDA $CCF9,x                               ; $1EC9F6 |
  STA $0201,x                               ; $1EC9F9 |
  LDA $CCFA,x                               ; $1EC9FC |
  STA $0202,x                               ; $1EC9FF |
  LDA $CCFB,x                               ; $1ECA02 |
  STA $0203,x                               ; $1ECA05 |
  DEX                                       ; $1ECA08 |
  DEX                                       ; $1ECA09 |
  DEX                                       ; $1ECA0A |
  DEX                                       ; $1ECA0B |
  BPL code_1EC9F0                           ; $1ECA0C |
  LDA #$14                                  ; $1ECA0E |
code_1ECA10:
  STA $97                                   ; $1ECA10 |
  TAX                                       ; $1ECA12 |
  LDA #$F8                                  ; $1ECA13 |
code_1ECA15:
  STA $0200,x                               ; $1ECA15 |
  INX                                       ; $1ECA18 |
  INX                                       ; $1ECA19 |
  INX                                       ; $1ECA1A |
  INX                                       ; $1ECA1B |
  BNE code_1ECA15                           ; $1ECA1C |
  LDA #$00                                  ; $1ECA1E |
  STA $EE                                   ; $1ECA20 |
  JSR task_yield                           ; $1ECA22 |
  INC $EE                                   ; $1ECA25 |
  INC $95                                   ; $1ECA27 |
  PLA                                       ; $1ECA29 |
  SEC                                       ; $1ECA2A |
  SBC #$01                                  ; $1ECA2B |
  BNE code_1EC9E7                           ; $1ECA2D |
  LDA #$0F                                  ; $1ECA2F |
  STA $0611                                 ; $1ECA31 |
  INC $18                                   ; $1ECA34 |
  LDA #$00                                  ; $1ECA36 |
  STA $EA                                   ; $1ECA38 |
  LDA #$01                                  ; $1ECA3A |
  STA $EB                                   ; $1ECA3C |
  JSR update_CHR_banks                      ; $1ECA3E |
  LDA #$80                                  ; $1ECA41 |
  STA $0300                                 ; $1ECA43 |
  LDA #$00                                  ; $1ECA46 |
  STA $03C0                                 ; $1ECA48 |
  LDA #$D0                                  ; $1ECA4B |
  STA $0580                                 ; $1ECA4D |
  LDA #$4C                                  ; $1ECA50 |
  STA $0400                                 ; $1ECA52 |
  LDA #$01                                  ; $1ECA55 |
  STA $0420                                 ; $1ECA57 |
  LDA #$00                                  ; $1ECA5A |
  STA $0440                                 ; $1ECA5C |
  LDA #$F9                                  ; $1ECA5F |
  STA $0460                                 ; $1ECA61 |
  LDX #$00                                  ; $1ECA64 |
  LDA #$13                                  ; $1ECA66 |
  JSR reset_sprite_anim                     ; $1ECA68 |
  LDA #$04                                  ; $1ECA6B |
  STA $30                                   ; $1ECA6D |
  LDA #$80                                  ; $1ECA6F |
  STA $B2                                   ; $1ECA71 |
code_1ECA73:
  LDA $14                                   ; $1ECA73 |
  AND #$10                                  ; $1ECA75 |
  BEQ code_1ECAB5                           ; $1ECA77 |
  LDA $30                                   ; $1ECA79 |
  CMP #$04                                  ; $1ECA7B |
  BEQ code_1ECAB5                           ; $1ECA7D |
  CMP #$07                                  ; $1ECA7F |
  BEQ code_1ECAB5                           ; $1ECA81 |
  CMP #$09                                  ; $1ECA83 |
  BCS code_1ECAB5                           ; $1ECA85 |
  LDA $A0                                   ; $1ECA87 |
  SEC                                       ; $1ECA89 |
  SBC #$06                                  ; $1ECA8A |
  BCC code_1ECA99                           ; $1ECA8C |
  AND #$01                                  ; $1ECA8E |
  BEQ code_1ECA99                           ; $1ECA90 |
  LDA #$00                                  ; $1ECA92 |
  STA $0301                                 ; $1ECA94 |
  BEQ code_1ECAA4                           ; $1ECA97 |
code_1ECA99:
  LDA $0301                                 ; $1ECA99 |
  ORA $0302                                 ; $1ECA9C |
  ORA $0303                                 ; $1ECA9F |
  BMI code_1ECAB5                           ; $1ECAA2 |
code_1ECAA4:
  LDY $30                                   ; $1ECAA4 |
  LDA $CD1E,y                               ; $1ECAA6 |
  BMI code_1ECAB5                           ; $1ECAA9 |
  LDA #$02                                  ; $1ECAAB |
  STA $F5                                   ; $1ECAAD |
  JSR select_PRG_banks                      ; $1ECAAF |
  JSR $A003                                 ; $1ECAB2 |
code_1ECAB5:
  LDA $22                                   ; $1ECAB5 |
  STA $F5                                   ; $1ECAB7 |
  JSR select_PRG_banks                      ; $1ECAB9 |
  JSR code_1ECD34                           ; $1ECABC |
  LDA $3D                                   ; $1ECABF |
  BEQ code_1ECAD7                           ; $1ECAC1 |
  STA $30                                   ; $1ECAC3 |
  CMP #$0E                                  ; $1ECAC5 |
  BNE code_1ECAD3                           ; $1ECAC7 |
  LDA #$F2                                  ; $1ECAC9 |
  JSR submit_sound_ID                       ; $1ECACB |
  LDA #$17                                  ; $1ECACE |
  JSR submit_sound_ID                       ; $1ECAD0 |
code_1ECAD3:
  LDA #$00                                  ; $1ECAD3 |
  STA $3D                                   ; $1ECAD5 |
code_1ECAD7:
  JSR code_1FE16A                           ; $1ECAD7 |
  LDA $FC                                   ; $1ECADA |
  STA $25                                   ; $1ECADC |
  STA $00                                   ; $1ECADE |
  LDA $F8                                   ; $1ECAE0 |
  CMP #$02                                  ; $1ECAE2 |
  BNE code_1ECAF2                           ; $1ECAE4 |
  LDA $F9                                   ; $1ECAE6 |
  LSR                                       ; $1ECAE8 |
  ROR $00                                   ; $1ECAE9 |
  LSR                                       ; $1ECAEB |
  ROR $00                                   ; $1ECAEC |
  LDA $00                                   ; $1ECAEE |
  STA $5F                                   ; $1ECAF0 |
code_1ECAF2:
  LDA $0380                                 ; $1ECAF2 |
  CMP $6F                                   ; $1ECAF5 |
  BCC code_1ECAFB                           ; $1ECAF7 |
  STA $6F                                   ; $1ECAF9 |
code_1ECAFB:
  LDA $0360                                 ; $1ECAFB |
  STA $27                                   ; $1ECAFE |
  LDX #$1C                                  ; $1ECB00 |\
  STX $F4                                   ; $1ECB02 | | select banks 1C & 1D
  INX                                       ; $1ECB04 | | for $8000~$BFFF
  STX $F5                                   ; $1ECB05 | | (sprite code banks)
  JSR select_PRG_banks                      ; $1ECB07 |/
  JSR process_sprites_j                     ; $1ECB0A | process all sprites
  LDA #$1A                                  ; $1ECB0D |
  STA $F4                                   ; $1ECB0F |
  LDA $22                                   ; $1ECB11 |
  STA $F5                                   ; $1ECB13 |
  JSR select_PRG_banks                      ; $1ECB15 |
  JSR check_new_enemies                     ; $1ECB18 |
  LDA #$09                                  ; $1ECB1B |
  STA $F4                                   ; $1ECB1D |
  JSR select_PRG_banks                      ; $1ECB1F |
  JSR $8003                                 ; $1ECB22 |
  JSR $8006                                 ; $1ECB25 |
  JSR $800F                                 ; $1ECB28 |
  JSR $8009                                 ; $1ECB2B |
  JSR $800C                                 ; $1ECB2E |
  JSR $8000                                 ; $1ECB31 |
  JSR $8012                                 ; $1ECB34 |
  JSR code_1EC798                           ; $1ECB37 |
  JSR process_frame_yield_with_player                           ; $1ECB3A |
  LDA $98                                   ; $1ECB3D |
  AND #$02                                  ; $1ECB3F |
  BEQ code_1ECB49                           ; $1ECB41 |
  LDA #$01                                  ; $1ECB43 |
  ORA $17                                   ; $1ECB45 |
  STA $17                                   ; $1ECB47 |
code_1ECB49:
  JSR code_1EC7FB                           ; $1ECB49 |
  LDA $59                                   ; $1ECB4C |
  BNE code_1ECB5B                           ; $1ECB4E |
  LDA $3C                                   ; $1ECB50 |
  BNE code_1ECB78                           ; $1ECB52 |
  LDA $74                                   ; $1ECB54 |
  BNE code_1ECBCE                           ; $1ECB56 |
  JMP code_1ECA73                           ; $1ECB58 |

code_1ECB5B:
  LDA #$00                                  ; $1ECB5B |
  STA $EE                                   ; $1ECB5D |
  STA $71                                   ; $1ECB5F |
  STA $72                                   ; $1ECB61 |
  STA $F8                                   ; $1ECB63 |
  STA $5A                                   ; $1ECB65 |
  LDA #$18                                  ; $1ECB67 |
  STA $F4                                   ; $1ECB69 |
  LDA #$10                                  ; $1ECB6B |
  STA $F5                                   ; $1ECB6D |
  JSR select_PRG_banks                      ; $1ECB6F |
  JSR $9000                                 ; $1ECB72 |
  JMP code_1EC8FF                           ; $1ECB75 |

code_1ECB78:
  LDA #$00                                  ; $1ECB78 |
  STA $3C                                   ; $1ECB7A |
  STA $5A                                   ; $1ECB7C |
  LDA $AE                                   ; $1ECB7E |
  SEC                                       ; $1ECB80 |
  SBC #$01                                  ; $1ECB81 |
  BCC code_1ECBB1                           ; $1ECB83 |
  STA $AE                                   ; $1ECB85 |
  AND #$0F                                  ; $1ECB87 |
  CMP #$0F                                  ; $1ECB89 |
  BNE code_1ECB94                           ; $1ECB8B |
  LDA $AE                                   ; $1ECB8D |
  SEC                                       ; $1ECB8F |
  SBC #$06                                  ; $1ECB90 |
  STA $AE                                   ; $1ECB92 |
code_1ECB94:
  LDA #$00                                  ; $1ECB94 |
  STA $EE                                   ; $1ECB96 |
  STA $71                                   ; $1ECB98 |
  STA $72                                   ; $1ECB9A |
  STA $F8                                   ; $1ECB9C |
  LDA $60                                   ; $1ECB9E |
  CMP #$12                                  ; $1ECBA0 |
  BEQ code_1ECBA7                           ; $1ECBA2 |
  JMP handle_checkpoint                     ; $1ECBA4 |

code_1ECBA7:
  LDA #$18                                  ; $1ECBA7 |
  STA $F4                                   ; $1ECBA9 |
  JSR select_PRG_banks                      ; $1ECBAB |
  JMP $9006                                 ; $1ECBAE |

code_1ECBB1:
  LDA #$00                                  ; $1ECBB1 |
  STA $EE                                   ; $1ECBB3 |
  STA $5A                                   ; $1ECBB5 |
  STA $71                                   ; $1ECBB7 |
  STA $72                                   ; $1ECBB9 |
  STA $F8                                   ; $1ECBBB |
  LDA #$18                                  ; $1ECBBD |
  STA $F4                                   ; $1ECBBF |
  LDA #$13                                  ; $1ECBC1 |
  STA $F5                                   ; $1ECBC3 |
  JSR select_PRG_banks                      ; $1ECBC5 |
  JSR $9003                                 ; $1ECBC8 |
  JMP code_1EC8FF                           ; $1ECBCB |

code_1ECBCE:
  PHA                                       ; $1ECBCE |
  LDA #$00                                  ; $1ECBCF |
  STA $5A                                   ; $1ECBD1 |
  STA $74                                   ; $1ECBD3 |
  STA $B1                                   ; $1ECBD5 |
  STA $B2                                   ; $1ECBD7 |
  STA $B3                                   ; $1ECBD9 |
  STA $5A                                   ; $1ECBDB |
  STA $F9                                   ; $1ECBDD |
  STA $F8                                   ; $1ECBDF |
  LDA #$0B                                  ; $1ECBE1 |
  STA $F4                                   ; $1ECBE3 |
  LDA #$0E                                  ; $1ECBE5 |
  STA $F5                                   ; $1ECBE7 |
  JSR select_PRG_banks                      ; $1ECBE9 |
  PLA                                       ; $1ECBEC |
  AND #$7F                                  ; $1ECBED |
  BNE code_1ECBF7                           ; $1ECBEF |
  JSR $8000                                 ; $1ECBF1 |
  JMP code_1EC8FF                           ; $1ECBF4 |

code_1ECBF7:
  LDA $75                                   ; $1ECBF7 |
  CMP #$06                                  ; $1ECBF9 |
  BEQ code_1ECC03                           ; $1ECBFB |
  JSR $8003                                 ; $1ECBFD |
  JMP code_1EC8FF                           ; $1ECC00 |

code_1ECC03:
  LDA #$0C                                  ; $1ECC03 |
  STA $F4                                   ; $1ECC05 |
  LDA #$0E                                  ; $1ECC07 |
  STA $F5                                   ; $1ECC09 |
  JSR select_PRG_banks                      ; $1ECC0B |
  LDA #$11                                  ; $1ECC0E |
  STA $F8                                   ; $1ECC10 |
  JSR $8000                                 ; $1ECC12 |
  JMP code_1EC8FF                           ; $1ECC15 |

handle_checkpoint:
  LDA $22                                   ; $1ECC18 |\  store current level
  STA $F5                                   ; $1ECC1A | | as $A000-$BFFF bank
  JSR select_PRG_banks                      ; $1ECC1C |/  and swap banks to it
  LDY #$00                                  ; $1ECC1F | loop through checkpoint data
.loop:
  LDA $6F                                   ; $1ECC21 |\  if current checkpoint >
  CMP $AAF8,y                               ; $1ECC23 | | current screen ID
  BCC .go_back_one                          ; $1ECC26 |/  we're done & 1 too far
  INY                                       ; $1ECC28 |\
  BNE .loop                                 ; $1ECC29 |/ next checkpoint
.go_back_one:
  DEY                                       ; $1ECC2B |\  we're one checkpoint too far so
  BPL .take_checkpoint                      ; $1ECC2C | | go back one, if it's negative
  JMP code_1EC909                           ; $1ECC2E |/  we're just at the beginning

.take_checkpoint:
  TYA                                       ; $1ECC31 |
  PHA                                       ; $1ECC32 |
  JSR code_1EC752                           ; $1ECC33 |
  LDA #$04                                  ; $1ECC36 |
  STA $97                                   ; $1ECC38 |
  JSR code_1EC5E9                           ; $1ECC3A |
  JSR task_yield                           ; $1ECC3D |
  JSR code_1EC628                           ; $1ECC40 |
  LDA #$00                                  ; $1ECC43 |
  STA $F8                                   ; $1ECC45 |
  STA $FD                                   ; $1ECC47 |
  STA $71                                   ; $1ECC49 |
  STA $72                                   ; $1ECC4B |
  STA $FC                                   ; $1ECC4D |
  STA $FA                                   ; $1ECC4F |
  STA $25                                   ; $1ECC51 |
  STA $03E0                                 ; $1ECC53 |
  STA $B1                                   ; $1ECC56 |
  STA $B2                                   ; $1ECC58 |
  STA $B3                                   ; $1ECC5A |
  STA $5A                                   ; $1ECC5C |
  STA $A0                                   ; $1ECC5E |
  STA $B4                                   ; $1ECC60 |
  STA $A1                                   ; $1ECC62 |
  PLA                                       ; $1ECC64 |
  TAY                                       ; $1ECC65 |
  LDA $AAF8,y                               ; $1ECC66 |\
  STA $29                                   ; $1ECC69 | | set screen ID
  STA $F9                                   ; $1ECC6B | | from checkpoint
  STA $0380                                 ; $1ECC6D |/
  LDA $ABC0,y                               ; $1ECC70 |
  STA $9E                                   ; $1ECC73 |
  STA $9F                                   ; $1ECC75 |
  LDX $AAF0,y                               ; $1ECC77 |
  STX $2B                                   ; $1ECC7A |
  LDA $AA40,x                               ; $1ECC7C |
  PHA                                       ; $1ECC7F |
  STA $00                                   ; $1ECC80 |
  AND #$20                                  ; $1ECC82 |
  STA $2A                                   ; $1ECC84 |
  BNE code_1ECC8E                           ; $1ECC86 |
  LDA $00                                   ; $1ECC88 |
  AND #$C0                                  ; $1ECC8A |
  STA $2A                                   ; $1ECC8C |
code_1ECC8E:
  LDX #$01                                  ; $1ECC8E |
  LDY #$2A                                  ; $1ECC90 |
  AND #$20                                  ; $1ECC92 |
  BNE code_1ECC99                           ; $1ECC94 |
  DEX                                       ; $1ECC96 |
  LDY #$26                                  ; $1ECC97 |
code_1ECC99:
  STX $A000                                 ; $1ECC99 |
  STY $52                                   ; $1ECC9C |
  PLA                                       ; $1ECC9E |
  AND #$1F                                  ; $1ECC9F |
  STA $2C                                   ; $1ECCA1 |
  LDA #$00                                  ; $1ECCA3 |
  STA $2D                                   ; $1ECCA5 |
  LDY $22                                   ; $1ECCA7 |
  LDA $CD0C,y                               ; $1ECCA9 |
  JSR submit_sound_ID_D9                    ; $1ECCAC |
  LDA #$01                                  ; $1ECCAF |
  STA $31                                   ; $1ECCB1 |
  STA $23                                   ; $1ECCB3 |
  STA $2E                                   ; $1ECCB5 |
  DEC $29                                   ; $1ECCB7 |
  LDA #$1F                                  ; $1ECCB9 |
  STA $24                                   ; $1ECCBB |
  LDA #$21                                  ; $1ECCBD |
code_1ECCBF:
  PHA                                       ; $1ECCBF |
  LDA #$01                                  ; $1ECCC0 |
  STA $10                                   ; $1ECCC2 |
  JSR code_1FE4F1                           ; $1ECCC4 |
  JSR task_yield                           ; $1ECCC7 |
  PLA                                       ; $1ECCCA |
  SEC                                       ; $1ECCCB |
  SBC #$01                                  ; $1ECCCC |
  BNE code_1ECCBF                           ; $1ECCCE |
  JSR load_stage                           ; $1ECCD0 |
  LDA #$00                                  ; $1ECCD3 |
  STA $18                                   ; $1ECCD5 |
  JSR task_yield                           ; $1ECCD7 |
  JSR code_1EC74C                           ; $1ECCDA |
  LDA #$80                                  ; $1ECCDD |
  STA $0360                                 ; $1ECCDF |
  JMP code_1EC9B3                           ; $1ECCE2 |

  LDA $98                                   ; $1ECCE5 |
  AND #$03                                  ; $1ECCE7 |
  CMP #$01                                  ; $1ECCE9 |
  BNE code_1ECCF7                           ; $1ECCEB |
  LDY #$0B                                  ; $1ECCED |
  LDA #$9C                                  ; $1ECCEF |
code_1ECCF1:
  STA $00A2,y                               ; $1ECCF1 |
  DEY                                       ; $1ECCF4 |
  BPL code_1ECCF1                           ; $1ECCF5 |
code_1ECCF7:
  RTS                                       ; $1ECCF7 |

  db $80, $40, $00, $6C, $80, $41, $00, $74 ; $1ECCF8 |
  db $80, $42, $00, $7C, $80, $43, $00, $84 ; $1ECD00 |
  db $80, $44, $00, $8C, $01, $02, $03, $04 ; $1ECD08 |
  db $05, $06, $07, $08, $01, $03, $07, $08 ; $1ECD10 |
  db $09, $09, $0A, $0A, $0B, $0B, $00, $00 ; $1ECD18 |
  db $FF, $00, $FF, $00, $FF, $FF, $00, $FF ; $1ECD20 |
  db $00, $FF, $FF, $FF, $FF, $FF, $FF, $FF ; $1ECD28 |
  db $FF, $FF, $FF, $FF                     ; $1ECD30 |

code_1ECD34:
  LDA $0420                                 ; $1ECD34 |
  CMP #$02                                  ; $1ECD37 |
  BNE code_1ECD41                           ; $1ECD39 |
  LDA $30                                   ; $1ECD3B |
  CMP #$02                                  ; $1ECD3D |
  BEQ code_1ECD4B                           ; $1ECD3F |
code_1ECD41:
  LDA #$4C                                  ; $1ECD41 |
  STA $0400                                 ; $1ECD43 |
  LDA #$01                                  ; $1ECD46 |
  STA $0420                                 ; $1ECD48 |
code_1ECD4B:
  LDA #$40                                  ; $1ECD4B |
  STA $99                                   ; $1ECD4D |
  LDX #$00                                  ; $1ECD4F |
  STX $5D                                   ; $1ECD51 |
  LDA $36                                   ; $1ECD53 |
  BEQ code_1ECD5A                           ; $1ECD55 |
  JSR code_1ECDEC                           ; $1ECD57 |
code_1ECD5A:
  LDA $39                                   ; $1ECD5A |
  BEQ code_1ECD6A                           ; $1ECD5C |
  DEC $39                                   ; $1ECD5E |
  BNE code_1ECD6A                           ; $1ECD60 |
  LDA $05E0                                 ; $1ECD62 |
  AND #$7F                                  ; $1ECD65 |
  STA $05E0                                 ; $1ECD67 |
code_1ECD6A:
  LDA $16                                   ; $1ECD6A |
  AND #$40                                  ; $1ECD6C |
  BNE code_1ECD76                           ; $1ECD6E |
  LDA #$E0                                  ; $1ECD70 |
  STA $1F                                   ; $1ECD72 |
  BNE code_1ECD8B                           ; $1ECD74 |
code_1ECD76:
  LDA $1F                                   ; $1ECD76 |
  CLC                                       ; $1ECD78 |
  ADC #$20                                  ; $1ECD79 |
  STA $1F                                   ; $1ECD7B |
  BNE code_1ECD8B                           ; $1ECD7D |
  LDA $A0                                   ; $1ECD7F |
  CMP #$02                                  ; $1ECD81 |
  BNE code_1ECD8B                           ; $1ECD83 |
  LDA $14                                   ; $1ECD85 |
  ORA #$40                                  ; $1ECD87 |
  STA $14                                   ; $1ECD89 |
code_1ECD8B:
  LDY $30                                   ; $1ECD8B |\
  LDA $CD9A,y                               ; $1ECD8D | | grab player state
  STA $00                                   ; $1ECD90 | | index into state ptr tables
  LDA $CDB0,y                               ; $1ECD92 | | jump to address
  STA $01                                   ; $1ECD95 | |
  JMP ($0000)                               ; $1ECD97 |/

; =============================================================================
; PLAYER STATE POINTER TABLES — 22 states, indexed by $30
; =============================================================================
; Dispatch at code_1ECD8B: LDY $30; LDA lo,y / LDA hi,y; JMP ($0000)
;
;   $00 = player_on_ground    ($CE36) — idle/walking on ground [confirmed]
;   $01 = player_airborne     ($D007) — jumping/falling, variable jump [confirmed]
;   $02 = player_slide        ($D3FD) — sliding on ground [confirmed]
;   $03 = player_ladder       ($D4EB) — on ladder (climb, fire, jump off) [confirmed]
;   $04 = player_reappear     ($D5BA) — respawn/reappear (death, unpause, stage start) [confirmed]
;   $05 = player_entity_ride  ($D613) — riding entity at slot $34 (anim $62) [unconfirmed]
;   $06 = player_damage       ($D6AB) — taking damage (contact or projectile) [confirmed]
;   $07 = player_special_death($D831) — Doc Flash Time Stopper kill [confirmed]
;   $08 = player_rush_marine  ($D858) — riding Rush Marine submarine [confirmed]
;   $09 = player_boss_wait    ($D929) — frozen during boss intro (shutters/HP bar) [confirmed]
;   $0A = player_top_spin     ($D991) — Top Spin recoil bounce (8 frames) [confirmed]
;   $0B = player_weapon_recoil($D9BE) — Hard Knuckle fire freeze (16 frames) [confirmed]
;   $0C = player_victory      ($D9D3) — boss defeated cutscene (jump, get weapon) [confirmed]
;   $0D = player_teleport     ($DBE1) — teleport away, persists through menus [confirmed]
;   $0E = player_death        ($D779) — dead, explosion on all sprites [confirmed]
;   $0F = player_stunned      ($CDCC) — frozen by external force (slam/grab/cutscene) [confirmed]
;   $10 = player_screen_scroll($DD14) — vertical scroll transition between sections [confirmed]
;   $11 = player_warp_init    ($DDAA) — teleporter tube area initialization [confirmed]
;   $12 = player_warp_anim    ($DE52) — wait for warp animation, return to $00 [confirmed]
;   $13 = player_teleport_beam($DF33) — teleport beam landing w/ gravity [unconfirmed]
;   $14 = player_auto_walk    ($DF8A) — scripted walk to X=$50 (post-Wily) [confirmed]
;   $15 = player_auto_walk_2  ($E08C) — scripted walk to X=$68 (ending cutscene) [confirmed]
;
; MM4 comparison: 6 states (stand/walk/air/slide/hurt/ladder).
; MM3's extra states cover Rush Marine, victory, teleport, death,
; stage transitions, boss intros, weapon recoil, and scripted cutscenes.
; =============================================================================
player_state_ptr_lo:
  db player_on_ground                       ; $1ECD98 | $00 player_on_ground
  db $07                                    ; $1ECD99 | $01 player_airborne
  db $FD                                    ; $1ECD9A | $02 player_slide
  db $EB                                    ; $1ECD9B | $03 player_ladder
  db $BA                                    ; $1ECD9C | $04 player_reappear
  db $13                                    ; $1ECD9D | $05 player_entity_ride
  db $AB                                    ; $1ECD9E | $06 player_damage
  db $31                                    ; $1ECD9F | $07 player_special_death
  db $58                                    ; $1ECDA0 | $08 player_rush_marine
  db $29                                    ; $1ECDA1 | $09 player_boss_wait
  db $91                                    ; $1ECDA2 | $0A player_top_spin
  db $BE                                    ; $1ECDA3 | $0B player_weapon_recoil
  db $D3                                    ; $1ECDA4 | $0C player_victory
  db $E1                                    ; $1ECDA5 | $0D player_teleport
  db $79                                    ; $1ECDA6 | $0E player_death
  db $CC                                    ; $1ECDA7 | $0F player_stunned
  db $14                                    ; $1ECDA8 | $10 player_screen_scroll
  db $AA                                    ; $1ECDA9 | $11 player_warp_init
  db $52                                    ; $1ECDAA | $12 player_warp_anim
  db $33                                    ; $1ECDAB | $13 player_teleport_beam
  db $8A                                    ; $1ECDAC | $14 player_auto_walk
  db $8C                                    ; $1ECDAD | $15 player_auto_walk_2

player_state_ptr_hi:
  db player_on_ground>>8                    ; $1ECDAE | $00
  db $D0                                    ; $1ECDAF | $01
  db $D3                                    ; $1ECDB0 | $02
  db $D4                                    ; $1ECDB1 | $03
  db $D5                                    ; $1ECDB2 | $04
  db $D6                                    ; $1ECDB3 | $05
  db $D6                                    ; $1ECDB4 | $06
  db $D8                                    ; $1ECDB5 | $07
  db $D8                                    ; $1ECDB6 | $08
  db $D9                                    ; $1ECDB7 | $09
  db $D9                                    ; $1ECDB8 | $0A
  db $D9                                    ; $1ECDB9 | $0B
  db $D9                                    ; $1ECDBA | $0C
  db $DB                                    ; $1ECDBB | $0D
  db $D7                                    ; $1ECDBC | $0E
  db $CD                                    ; $1ECDBD | $0F
  db $DD                                    ; $1ECDBE | $10
  db $DD                                    ; $1ECDBF | $11
  db $DE                                    ; $1ECDC0 | $12
  db $DF                                    ; $1ECDC1 | $13
  db $DF                                    ; $1ECDC2 | $14
  db $E0                                    ; $1ECDC3 | $15

  db $66, $61, $E0, $CF, $CE, $CF           ; $1ECDC6 |

; player state $0F: frozen by external force (slam/grab/cutscene) [confirmed]
player_stunned:
  LDA $5A                                   ; $1ECDCC |
  BMI code_1ECDE6                           ; $1ECDCE |
  LDY #$00                                  ; $1ECDD0 |
  JSR move_vertical_gravity                           ; $1ECDD2 |
  BCC code_1ECDE5                           ; $1ECDD5 |
  LDA #$01                                  ; $1ECDD7 |
  CMP $05C0                                 ; $1ECDD9 |
  BEQ code_1ECDE5                           ; $1ECDDC |
  JSR reset_sprite_anim                     ; $1ECDDE |
  LDA #$00                                  ; $1ECDE1 |
  STA $32                                   ; $1ECDE3 |
code_1ECDE5:
  RTS                                       ; $1ECDE5 |

code_1ECDE6:
  LDA #$00                                  ; $1ECDE6 |
  STA $05E0                                 ; $1ECDE8 |
  RTS                                       ; $1ECDEB |

code_1ECDEC:
  LDA $0580                                 ; $1ECDEC |
  PHA                                       ; $1ECDEF |
  LDA $0400                                 ; $1ECDF0 |
  PHA                                       ; $1ECDF3 |
  LDA $0420                                 ; $1ECDF4 |
  PHA                                       ; $1ECDF7 |
  LDA $37                                   ; $1ECDF8 |
  STA $0400                                 ; $1ECDFA |
  LDA $38                                   ; $1ECDFD |
  STA $0420                                 ; $1ECDFF |
  LDY $30                                   ; $1ECE02 |
  CPY #$02                                  ; $1ECE04 |
  BEQ code_1ECE0A                           ; $1ECE06 |
  LDY #$00                                  ; $1ECE08 |
code_1ECE0A:
  LDA $36                                   ; $1ECE0A |
  AND #$01                                  ; $1ECE0C |
  BEQ code_1ECE16                           ; $1ECE0E |
  JSR move_right_collide                           ; $1ECE10 |
  JMP code_1ECE1A                           ; $1ECE13 |

code_1ECE16:
  INY                                       ; $1ECE16 |
  JSR move_left_collide                           ; $1ECE17 |
code_1ECE1A:
  PLA                                       ; $1ECE1A |
  STA $0420                                 ; $1ECE1B |
  PLA                                       ; $1ECE1E |
  STA $0400                                 ; $1ECE1F |
  PLA                                       ; $1ECE22 |
  AND #$40                                  ; $1ECE23 |
  STA $00                                   ; $1ECE25 |
  LDA $0580                                 ; $1ECE27 |
  AND #$BF                                  ; $1ECE2A |
  ORA $00                                   ; $1ECE2C |
  STA $0580                                 ; $1ECE2E |
  LDA #$00                                  ; $1ECE31 |
  STA $36                                   ; $1ECE33 |
code_1ECE35:
  RTS                                       ; $1ECE35 |

; player state $00 routine: on ground
player_on_ground:
  JSR player_airborne                           ; $1ECE36 |
  BCC code_1ECE35                           ; $1ECE39 |
  LDY $5D                                   ; $1ECE3B |
  CPY #$01                                  ; $1ECE3D |
  BNE .check_slide_jump                     ; $1ECE3F |
  LDA $05C0                                 ; $1ECE41 |\
  CMP #$11                                  ; $1ECE44 | | reset Mega Man's animation
  BNE .code_1ECE4D                          ; $1ECE46 | | to idle if taking damage
  LDA #$01                                  ; $1ECE48 | |
  JSR reset_sprite_anim                     ; $1ECE4A |/
.code_1ECE4D:
  LDY $05C1                                 ; $1ECE4D |\
  CPY #$D7                                  ; $1ECE50 | | is rush animating?
  BCC .check_slide_jump                     ; $1ECE52 |/
  LDA $CCEF,y                               ; $1ECE54 |
  STA $00                                   ; $1ECE57 |
  LDA $CCF2,y                               ; $1ECE59 |
  STA $01                                   ; $1ECE5C |
  JMP ($0000)                               ; $1ECE5E |

  LDA $05A1                                 ; $1ECE61 |
  BNE .check_slide_jump                     ; $1ECE64 |
  INC $3A                                   ; $1ECE66 |
  LDA #$EE                                  ; $1ECE68 |
  STA $0440                                 ; $1ECE6A |
  LDA #$06                                  ; $1ECE6D |
  STA $0460                                 ; $1ECE6F |
  INC $05A1                                 ; $1ECE72 |
  LDA #$3C                                  ; $1ECE75 |
  STA $0501                                 ; $1ECE77 |
  LDA $0581                                 ; $1ECE7A |
  AND #$FE                                  ; $1ECE7D |
  STA $0581                                 ; $1ECE7F |
  JSR decrease_ammo.check_frames            ; $1ECE82 |
  JMP player_airborne                           ; $1ECE85 |

.check_slide_jump:
  LDA $05C0                                 ; $1ECE88 |\
  CMP #$10                                  ; $1ECE8B | | player sliding?
  BNE .check_jump                           ; $1ECE8D |/
  LDA $14                                   ; $1ECE8F |\
  AND #$80                                  ; $1ECE91 | | if so,
  BEQ code_1ECE35                           ; $1ECE93 | | newpressing A
  LDA $16                                   ; $1ECE95 | | and not holding down?
  AND #$04                                  ; $1ECE97 | | return, else go on
  BEQ code_1ECE35                           ; $1ECE99 | | to ???
  JMP code_1ED38E                           ; $1ECE9B |/

.check_jump:
  LDA $14                                   ; $1ECE9E |\
  AND #$80                                  ; $1ECEA0 | | newpressing A
  BEQ code_1ECECD                           ; $1ECEA2 | | and not holding down
  LDA $16                                   ; $1ECEA4 | | means jumping
  AND #$04                                  ; $1ECEA6 | | else go on to ???
  BEQ .jump                                 ; $1ECEA8 | |
  JMP code_1ED38E                           ; $1ECEAA |/

.jump:
  LDA $17                                   ; $1ECEAD |\  check controller 2
  AND #$01                                  ; $1ECEAF | | holding Right for
  BNE .super_jump                           ; $1ECEB1 |/  super jump
  LDA #$E5                                  ; $1ECEB3 |\
  STA $0440,x                               ; $1ECEB5 | | jump speed
  LDA #$04                                  ; $1ECEB8 | | $04E5
  STA $0460,x                               ; $1ECEBA |/
  JMP player_airborne                           ; $1ECEBD |

.super_jump:
  LDA #$00                                  ; $1ECEC0 |\
  STA $0440                                 ; $1ECEC2 | | super jump speed
  LDA #$08                                  ; $1ECEC5 | | $0800
  STA $0460                                 ; $1ECEC7 |/
  JMP player_airborne                           ; $1ECECA |

code_1ECECD:
  LDA $05C0                                 ; $1ECECD |
  CMP #$04                                  ; $1ECED0 |
  BEQ code_1ECEEB                           ; $1ECED2 |
  CMP #$05                                  ; $1ECED4 |
  BEQ code_1ECEEB                           ; $1ECED6 |
  CMP #$0D                                  ; $1ECED8 |
  BEQ code_1ECEE4                           ; $1ECEDA |
  CMP #$0E                                  ; $1ECEDC |
  BEQ code_1ECEE4                           ; $1ECEDE |
  CMP #$0F                                  ; $1ECEE0 |
  BNE code_1ECF0A                           ; $1ECEE2 |
code_1ECEE4:
  LDA $05A0                                 ; $1ECEE4 |
  BNE code_1ECF0A                           ; $1ECEE7 |
  BEQ code_1ECF59                           ; $1ECEE9 |
code_1ECEEB:
  LDA $16                                   ; $1ECEEB |
  AND $31                                   ; $1ECEED |
  BEQ code_1ECEF9                           ; $1ECEEF |
  PHA                                       ; $1ECEF1 |
  JSR code_1ECF59                           ; $1ECEF2 |
  PLA                                       ; $1ECEF5 |
  JMP code_1ECF3D                           ; $1ECEF6 |

code_1ECEF9:
  LDA #$0D                                  ; $1ECEF9 |
  JSR reset_sprite_anim                     ; $1ECEFB |
  LDA $32                                   ; $1ECEFE |
  BEQ code_1ECF05                           ; $1ECF00 |
  JSR code_1ED370                           ; $1ECF02 |
code_1ECF05:
  LDA $31                                   ; $1ECF05 |
  JMP code_1ECF3D                           ; $1ECF07 |

code_1ECF0A:
  LDA $16                                   ; $1ECF0A |
  AND #$03                                  ; $1ECF0C |
  BEQ code_1ECF4B                           ; $1ECF0E |
  STA $31                                   ; $1ECF10 |
  JSR code_1ECF59                           ; $1ECF12 |
  LDA $05C0                                 ; $1ECF15 |
  CMP #$0D                                  ; $1ECF18 |
  BEQ code_1ECF24                           ; $1ECF1A |
  CMP #$0E                                  ; $1ECF1C |
  BEQ code_1ECF24                           ; $1ECF1E |
  CMP #$0F                                  ; $1ECF20 |
  BNE code_1ECEF9                           ; $1ECF22 |
code_1ECF24:
  LDA #$04                                  ; $1ECF24 |
  JSR reset_sprite_anim                     ; $1ECF26 |
  LDA $31                                   ; $1ECF29 |
  LDY $32                                   ; $1ECF2B |
  BEQ code_1ECF3D                           ; $1ECF2D |
  JSR code_1ED370                           ; $1ECF2F |
  LDY $A0                                   ; $1ECF32 |
  CMP #$04                                  ; $1ECF34 |
  BNE code_1ECF3D                           ; $1ECF36 |
  LDY #$AA                                  ; $1ECF38 |
  STA $05C0                                 ; $1ECF3A |
code_1ECF3D:
  AND #$01                                  ; $1ECF3D |
  BEQ code_1ECF46                           ; $1ECF3F |
  LDY #$00                                  ; $1ECF41 |
  JMP move_right_collide                           ; $1ECF43 |

code_1ECF46:
  LDY #$01                                  ; $1ECF46 |
  JMP move_left_collide                           ; $1ECF48 |

code_1ECF4B:
  LDA $32                                   ; $1ECF4B |
  BNE code_1ECF59                           ; $1ECF4D |
  LDA #$01                                  ; $1ECF4F |
  CMP $05C0                                 ; $1ECF51 |
  BEQ code_1ECF59                           ; $1ECF54 |
  JSR reset_sprite_anim                     ; $1ECF56 |
code_1ECF59:
  JSR code_1ED355                           ; $1ECF59 |
  LDA $14                                   ; $1ECF5C |
  AND #$40                                  ; $1ECF5E |
  BEQ code_1ECF65                           ; $1ECF60 |
  JSR weapon_fire                           ; $1ECF62 |
code_1ECF65:
  RTS                                       ; $1ECF65 |

  JSR decrease_ammo.check_frames            ; $1ECF66 |
  LDA #$82                                  ; $1ECF69 |
  CMP $0321                                 ; $1ECF6B |
  BEQ code_1ECF7B                           ; $1ECF6E |
  STA $0321                                 ; $1ECF70 |
  LDA $05E1                                 ; $1ECF73 |
  AND #$7F                                  ; $1ECF76 |
  STA $05E1                                 ; $1ECF78 |
code_1ECF7B:
  LDA $14                                   ; $1ECF7B |
  AND #$80                                  ; $1ECF7D |
  BEQ code_1ECF84                           ; $1ECF7F |
  JMP player_on_ground.jump                 ; $1ECF81 |

code_1ECF84:
  LDA $16                                   ; $1ECF84 |
  AND #$03                                  ; $1ECF86 |
  BEQ code_1ECF9B                           ; $1ECF88 |
  STA $31                                   ; $1ECF8A |
  JSR code_1ECF3D                           ; $1ECF8C |
  LDA #$01                                  ; $1ECF8F |
  JSR reset_sprite_anim                     ; $1ECF91 |
  LDA $32                                   ; $1ECF94 |
  BEQ code_1ECF9B                           ; $1ECF96 |
  JSR code_1ED370                           ; $1ECF98 |
code_1ECF9B:
  LDA $16                                   ; $1ECF9B |
  AND #$0C                                  ; $1ECF9D |
  BEQ code_1ECFD3                           ; $1ECF9F |
  PHA                                       ; $1ECFA1 |
  LDA #$80                                  ; $1ECFA2 |
  STA $0440,x                               ; $1ECFA4 |
  LDA #$01                                  ; $1ECFA7 |
  STA $0460,x                               ; $1ECFA9 |
  PLA                                       ; $1ECFAC |
  AND #$08                                  ; $1ECFAD |
  BEQ code_1ECFC2                           ; $1ECFAF |
  LDY #$01                                  ; $1ECFB1 |
  JSR move_up_collide                           ; $1ECFB3 |
  LDA #$0C                                  ; $1ECFB6 |
  CMP $03C0                                 ; $1ECFB8 |
  BCC code_1ECFC7                           ; $1ECFBB |
  STA $03C0                                 ; $1ECFBD |
  BCS code_1ECFC7                           ; $1ECFC0 |
code_1ECFC2:
  LDY #$07                                  ; $1ECFC2 |
  JSR move_down_collide                           ; $1ECFC4 |
code_1ECFC7:
  LDA $03C0                                 ; $1ECFC7 |
  CLC                                       ; $1ECFCA |
  ADC #$0E                                  ; $1ECFCB |
  STA $03C1                                 ; $1ECFCD |
  JSR reset_gravity                         ; $1ECFD0 |
code_1ECFD3:
  JSR code_1ED355                           ; $1ECFD3 |
  LDA $14                                   ; $1ECFD6 |
  AND #$40                                  ; $1ECFD8 |
  BEQ code_1ECFDF                           ; $1ECFDA |
  JSR weapon_fire                           ; $1ECFDC |
code_1ECFDF:
  RTS                                       ; $1ECFDF |

  LDA $0361                                 ; $1ECFE0 |
  STA $0360                                 ; $1ECFE3 |
  LDA $0381                                 ; $1ECFE6 |
  STA $0380                                 ; $1ECFE9 |
  LDA $03C1                                 ; $1ECFEC |
  STA $03C0                                 ; $1ECFEF |
  LDA #$00                                  ; $1ECFF2 |
  STA $0301                                 ; $1ECFF4 |
  LDA #$05                                  ; $1ECFF7 |
  STA $EB                                   ; $1ECFF9 |
  JSR update_CHR_banks                      ; $1ECFFB |
  LDA #$08                                  ; $1ECFFE |
  STA $30                                   ; $1ED000 |
  LDA #$DA                                  ; $1ED002 |
  JMP reset_sprite_anim                     ; $1ED004 |

; player state $01: jumping/falling, variable jump
player_airborne:
  LDA $0460                                 ; $1ED007 |\ player moving up?
  BMI code_1ED019                           ; $1ED00A |/
  LDA $3A                                   ; $1ED00C |
  BNE code_1ED01D                           ; $1ED00E |
  LDA $16                                   ; $1ED010 |
  AND #$80                                  ; $1ED012 |
  BNE code_1ED019                           ; $1ED014 |
  JSR reset_gravity                         ; $1ED016 |
code_1ED019:
  LDA #$00                                  ; $1ED019 |
  STA $3A                                   ; $1ED01B |
code_1ED01D:
  LDY #$06                                  ; $1ED01D |
  JSR check_tile_horiz                           ; $1ED01F |
  LDA $10                                   ; $1ED022 |
  STA $0F                                   ; $1ED024 |
  LDY #$00                                  ; $1ED026 |
  JSR move_vertical_gravity                           ; $1ED028 |
  PHP                                       ; $1ED02B |
  LDA $0F                                   ; $1ED02C |
  CMP #$80                                  ; $1ED02E |
  BNE code_1ED07E                           ; $1ED030 |
  LDA $B9                                   ; $1ED032 |
  BNE code_1ED084                           ; $1ED034 |
  LDA #$03                                  ; $1ED036 |
  STA $B9                                   ; $1ED038 |
  LDA $BA                                   ; $1ED03A |
  BNE code_1ED084                           ; $1ED03C |
  INC $BA                                   ; $1ED03E |
  LDA #$1F                                  ; $1ED040 |
  JSR submit_sound_ID                       ; $1ED042 |
  LDA #$80                                  ; $1ED045 |
  STA $0304                                 ; $1ED047 |
  LDA $0580                                 ; $1ED04A |
  STA $0584                                 ; $1ED04D |
  LDX #$04                                  ; $1ED050 |
  LDA #$68                                  ; $1ED052 |
  JSR reset_sprite_anim                     ; $1ED054 |
  LDA $0360                                 ; $1ED057 |
  STA $0364                                 ; $1ED05A |
  LDA $0380                                 ; $1ED05D |
  STA $0384                                 ; $1ED060 |
  LDA $03C0                                 ; $1ED063 |
  AND #$F0                                  ; $1ED066 |
  SEC                                       ; $1ED068 |
  SBC #$08                                  ; $1ED069 |
  STA $03C4                                 ; $1ED06B |
  LDA $03E0                                 ; $1ED06E |
  STA $03E4                                 ; $1ED071 |
  LDX #$00                                  ; $1ED074 |
  STX $0484                                 ; $1ED076 |
  STX $0324                                 ; $1ED079 |
  BEQ code_1ED084                           ; $1ED07C |
code_1ED07E:
  LDA #$00                                  ; $1ED07E |
  STA $BA                                   ; $1ED080 |
  STA $B9                                   ; $1ED082 |
code_1ED084:
  PLP                                       ; $1ED084 |
  JSR code_1ED47E                           ; $1ED085 |
  BCC code_1ED0A7                           ; $1ED088 |
  LDA $30                                   ; $1ED08A |
  BEQ code_1ED0A6                           ; $1ED08C |
  LDA #$13                                  ; $1ED08E |
  JSR submit_sound_ID                       ; $1ED090 |
  LDA #$00                                  ; $1ED093 |
  STA $30                                   ; $1ED095 |
  LDA #$0D                                  ; $1ED097 |
  JSR reset_sprite_anim                     ; $1ED099 |
  INC $05A0                                 ; $1ED09C |
  LDA $32                                   ; $1ED09F |
  BEQ code_1ED0A6                           ; $1ED0A1 |
  JSR code_1ED370                           ; $1ED0A3 |
code_1ED0A6:
  RTS                                       ; $1ED0A6 |

code_1ED0A7:
  LDA $30                                   ; $1ED0A7 |
  CMP #$03                                  ; $1ED0A9 |
  BEQ code_1ED0D8                           ; $1ED0AB |
  CMP #$01                                  ; $1ED0AD |
  BEQ code_1ED0C1                           ; $1ED0AF |
  LDA #$07                                  ; $1ED0B1 |
  JSR reset_sprite_anim                     ; $1ED0B3 |
  LDA #$01                                  ; $1ED0B6 |
  STA $30                                   ; $1ED0B8 |
  LDA $32                                   ; $1ED0BA |
  BEQ code_1ED0C1                           ; $1ED0BC |
  JSR code_1ED370                           ; $1ED0BE |
code_1ED0C1:
  LDA $16                                   ; $1ED0C1 |
  AND #$03                                  ; $1ED0C3 |
  BEQ code_1ED0CC                           ; $1ED0C5 |
  STA $31                                   ; $1ED0C7 |
  JSR code_1ECF3D                           ; $1ED0C9 |
code_1ED0CC:
  JSR code_1ED355                           ; $1ED0CC |
  LDA $14                                   ; $1ED0CF |
  AND #$40                                  ; $1ED0D1 |
  BEQ code_1ED0D8                           ; $1ED0D3 |
  JSR weapon_fire                           ; $1ED0D5 |
code_1ED0D8:
  CLC                                       ; $1ED0D8 |
  RTS                                       ; $1ED0D9 |

; player intends to fire the active weapon
; check if enough ammo and if free slot available
weapon_fire:
  LDY $A0                                   ; $1ED0DA |\
  LDA $00A2,y                               ; $1ED0DC | | ammo run out?
  AND #$1F                                  ; $1ED0DF | | return
  BEQ init_weapon.ret                       ; $1ED0E1 |/
  LDA weapon_max_shots,y                    ; $1ED0E3 |\ Y = starting loop index
  TAY                                       ; $1ED0E6 |/ to check for weapons
.loop_freeslot:
  LDA $0300,y                               ; $1ED0E7 |\
  BPL .fire                                 ; $1ED0EA | | check free slot for weapons
  DEY                                       ; $1ED0EC | | by $0300,x active table
  BNE .loop_freeslot                        ; $1ED0ED |/
  BEQ init_weapon.ret                       ; $1ED0EF | no free slots, return
.fire:
  LDY $A0                                   ; $1ED0F1 |\ decrease ammo
  JSR decrease_ammo                         ; $1ED0F3 |/
  LDA weapon_init_ptr_lo,y                  ; $1ED0F6 |\
  STA $00                                   ; $1ED0F9 | | jump to weapon init
  LDA weapon_init_ptr_hi,y                  ; $1ED0FB | | routine to spawn
  STA $01                                   ; $1ED0FE | | the shot sprite
  JMP ($0000)                               ; $1ED100 |/

; common weapon init routine: spawns the shot
init_weapon:
  LDA $32                                   ; $1ED103 |
  BNE .animate_player                       ; $1ED105 |
  JSR code_1ED370                           ; $1ED107 |
.animate_player:
  LDA $05C0                                 ; $1ED10A |\
  CMP #$05                                  ; $1ED10D | | if Mega Man OAM ID
  BEQ .code_1ED121                          ; $1ED10F | | is $05, $0E, or $0F
  CMP #$0E                                  ; $1ED111 | |
  BEQ .code_1ED121                          ; $1ED113 | |
  CMP #$0F                                  ; $1ED115 | |
  BEQ .code_1ED121                          ; $1ED117 |/
  LDA #$00                                  ; $1ED119 |\  any other ID
  STA $05A0                                 ; $1ED11B | | reset Mega Man animation
  STA $05E0                                 ; $1ED11E |/  to $00 frame & timer
.code_1ED121:
  LDA #$10                                  ; $1ED121 |
  STA $32                                   ; $1ED123 |
  LDY $A0                                   ; $1ED125 |\  use max shot value as
  LDA weapon_max_shots,y                    ; $1ED127 | | max slot to start loop
  TAY                                       ; $1ED12A |/
.loop_freeslot:
  LDA $0300,y                               ; $1ED12B |\
  BPL .spawn_shot                           ; $1ED12E | | check free slot for weapons
  DEY                                       ; $1ED130 | | by $0300,x active table
  BNE .loop_freeslot                        ; $1ED131 |/
  CLC                                       ; $1ED133 | no free slots, return carry off
.ret:
  RTS                                       ; $1ED134 |
.spawn_shot:
  LDX $A0                                   ; $1ED135 |\
  LDA weapon_fire_sound,x                   ; $1ED137 | | play weapon sound effect
  JSR submit_sound_ID                       ; $1ED13A |/
  LDX #$00                                  ; $1ED13D |
  LDA #$80                                  ; $1ED13F |\ set active
  STA $0300,y                               ; $1ED141 |/
  LDA $31                                   ; $1ED144 |
  ROR                                       ; $1ED146 |
  ROR                                       ; $1ED147 |
  ROR                                       ; $1ED148 |
  AND #$40                                  ; $1ED149 |
  ORA #$90                                  ; $1ED14B |
  STA $0580,y                               ; $1ED14D |
  LDA #$00                                  ; $1ED150 |\
  STA $0400,y                               ; $1ED152 | | default weapon X speed:
  LDA #$04                                  ; $1ED155 | | 4 pixels per frame
  STA $0420,y                               ; $1ED157 |/
  LDA $31                                   ; $1ED15A |\ set L/R facing of shot
  STA $04A0,y                               ; $1ED15C |/ = player facing
  AND #$02                                  ; $1ED15F |\
  TAX                                       ; $1ED161 | |
  LDA $0360                                 ; $1ED162 | | fetch X pixel & screen offsets
  CLC                                       ; $1ED165 | | based on player facing
  ADC weapon_x_offset,x                     ; $1ED166 | | weapon X = player X + offset
  STA $0360,y                               ; $1ED169 | |
  LDA $0380                                 ; $1ED16C | |
  ADC weapon_x_offset+1,x                   ; $1ED16F | |
  STA $0380,y                               ; $1ED172 |/
  LDA $03C0                                 ; $1ED175 |\
  STA $03C0,y                               ; $1ED178 | | weapon Y = player Y
  LDA $03E0                                 ; $1ED17B | |
  STA $03E0,y                               ; $1ED17E |/
  LDA #$00                                  ; $1ED181 |\
  STA $0480,y                               ; $1ED183 | | clear animation, hitbox,
  STA $05A0,y                               ; $1ED186 | | wildcard & X subpixel
  STA $05E0,y                               ; $1ED189 | |
  STA $0340,y                               ; $1ED18C | |
  STA $0500,y                               ; $1ED18F |/
  LDX $A0                                   ; $1ED192 |\
  LDA weapon_OAM_ID,x                       ; $1ED194 | | set OAM & main
  STA $05C0,y                               ; $1ED197 | | ID's for weapon
  LDA weapon_main_ID,x                      ; $1ED19A | |
  STA $0320,y                               ; $1ED19D |/
  INC $3B                                   ; $1ED1A0 |
  LDX #$00                                  ; $1ED1A2 |
  SEC                                       ; $1ED1A4 |
  RTS                                       ; $1ED1A5 |

init_rush:
  LDA $05C0                                 ; $1ED1A6 |
  CMP #$D7                                  ; $1ED1A9 |
  BCS code_1ED1B7                           ; $1ED1AB |
  LDA $0580                                 ; $1ED1AD |
  BPL code_1ED1FA                           ; $1ED1B0 |
  LDA $0301                                 ; $1ED1B2 |
  BPL code_1ED1BA                           ; $1ED1B5 |
code_1ED1B7:
  JMP init_weapon                           ; $1ED1B7 |

code_1ED1BA:
  LDY #$01                                  ; $1ED1BA |
  LDA #$13                                  ; $1ED1BC |
  JSR init_child_entity                           ; $1ED1BE |
  LDA #$00                                  ; $1ED1C1 |
  STA $03C1                                 ; $1ED1C3 |
  STA $03E1                                 ; $1ED1C6 |
  LDA #$11                                  ; $1ED1C9 |
  STA $0481                                 ; $1ED1CB |
  LDA $31                                   ; $1ED1CE |
  STA $04A1                                 ; $1ED1D0 |
  AND #$02                                  ; $1ED1D3 |
  TAX                                       ; $1ED1D5 |
  LDA $0360                                 ; $1ED1D6 |
  CLC                                       ; $1ED1D9 |
  ADC $D31F,x                               ; $1ED1DA |
  STA $0361                                 ; $1ED1DD |
  LDA $0380                                 ; $1ED1E0 |
  ADC $D320,x                               ; $1ED1E3 |
  STA $0381                                 ; $1ED1E6 |
  LDA #$80                                  ; $1ED1E9 |
  STA $0320,y                               ; $1ED1EB |
  LDA #$AB                                  ; $1ED1EE |
  STA $0441                                 ; $1ED1F0 |
  LDA #$FF                                  ; $1ED1F3 |
  STA $0461                                 ; $1ED1F5 |
  LDX #$00                                  ; $1ED1F8 |
code_1ED1FA:
  RTS                                       ; $1ED1FA |

init_needle_cannon:
  JSR init_weapon                           ; $1ED1FB |
  BCC code_1ED211                           ; $1ED1FE |
  LDA $3B                                   ; $1ED200 |
  AND #$01                                  ; $1ED202 |
  TAX                                       ; $1ED204 |
  LDA $03C0,y                               ; $1ED205 |
  CLC                                       ; $1ED208 |
  ADC $D33B,x                               ; $1ED209 |
  STA $03C0,y                               ; $1ED20C |
  LDX #$00                                  ; $1ED20F |
code_1ED211:
  RTS                                       ; $1ED211 |

init_gemini_laser:
  JSR init_weapon                           ; $1ED212 |
  BCC .ret                                  ; $1ED215 |
  INY                                       ; $1ED217 |\
  JSR init_weapon.spawn_shot                ; $1ED218 | | spawn 2 more shots
  INY                                       ; $1ED21B | | uses all 3 slots
  JSR init_weapon.spawn_shot                ; $1ED21C |/
  LDA #$B4                                  ; $1ED21F |\
  STA $0501                                 ; $1ED221 | | store $B4
  STA $0502                                 ; $1ED224 | | wildcard 1
  STA $0503                                 ; $1ED227 |/  all 3 slots
  LDA #$00                                  ; $1ED22A |\
  STA $0441                                 ; $1ED22C | |
  STA $0442                                 ; $1ED22F | | clear Y speeds
  STA $0443                                 ; $1ED232 | | all 3 slots
  STA $0461                                 ; $1ED235 | |
  STA $0462                                 ; $1ED238 | |
  STA $0463                                 ; $1ED23B |/
  LDA $0361                                 ; $1ED23E |\
  AND #$FC                                  ; $1ED241 | | take first slot's
  STA $0361                                 ; $1ED243 | | X, chop off low two bits
  STA $0362                                 ; $1ED246 | | store into all three X slots
  STA $0363                                 ; $1ED249 |/
.ret:
  RTS                                       ; $1ED24C |

init_hard_knuckle:
  LDA $0301                                 ; $1ED24D |
  BMI code_1ED292                           ; $1ED250 |
  LDY $30                                   ; $1ED252 |
  CPY #$04                                  ; $1ED254 |
  BCS code_1ED292                           ; $1ED256 |
  LDA $D293,y                               ; $1ED258 |
  BEQ code_1ED292                           ; $1ED25B |
  JSR init_weapon                           ; $1ED25D |
  LDY $30                                   ; $1ED260 |
  LDA $D293,y                               ; $1ED262 |
  JSR reset_sprite_anim                     ; $1ED265 |
  CPY #$03                                  ; $1ED268 |
  BNE code_1ED271                           ; $1ED26A |
  LDA #$AE                                  ; $1ED26C |
  STA $05C1                                 ; $1ED26E |
code_1ED271:
  LDA #$00                                  ; $1ED271 |
  STA $0401                                 ; $1ED273 |
  STA $0421                                 ; $1ED276 |
  STA $0461                                 ; $1ED279 |
  LDA #$80                                  ; $1ED27C |
  STA $0441                                 ; $1ED27E |
  INC $05E1                                 ; $1ED281 |
  LDA $30                                   ; $1ED284 |
  STA $0500                                 ; $1ED286 |
  LDA #$10                                  ; $1ED289 |
  STA $0520                                 ; $1ED28B |
  LDA #$0B                                  ; $1ED28E |
  STA $30                                   ; $1ED290 |
code_1ED292:
  RTS                                       ; $1ED292 |

  db $AA, $AB, $00, $AD, $01, $07, $00, $0A ; $1ED293 |
  db $FC, $FF, $04, $00                     ; $1ED29B |

init_top_spin:
  LDA $30                                   ; $1ED29F |\
  CMP #$01                                  ; $1ED2A1 | | if player not in air,
  BNE init_search_snake.ret                 ; $1ED2A3 |/  return
  LDA #$A3                                  ; $1ED2A5 |\
  CMP $05C0                                 ; $1ED2A7 | | if Mega Man already spinning,
  BEQ init_search_snake.ret                 ; $1ED2AA |/  return
  JSR reset_sprite_anim                     ; $1ED2AC | else set animation to spin
  LDA #$2C                                  ; $1ED2AF |\ and play the top spin
  JMP submit_sound_ID                       ; $1ED2B1 |/ sound

init_search_snake:
  JSR init_weapon                           ; $1ED2B4 |
  BCC .ret                                  ; $1ED2B7 |
  LDA #$44                                  ; $1ED2B9 |
  STA $0440,y                               ; $1ED2BB |
  LDA #$03                                  ; $1ED2BE |
  STA $0460,y                               ; $1ED2C0 |
  LDA #$00                                  ; $1ED2C3 |
  STA $0400,y                               ; $1ED2C5 |
  LDA #$01                                  ; $1ED2C8 |
  STA $0420,y                               ; $1ED2CA |
  LDA #$13                                  ; $1ED2CD |
  STA $0500,y                               ; $1ED2CF |
.ret:
  RTS                                       ; $1ED2D2 |

init_shadow_blade:
  JSR init_weapon                           ; $1ED2D3 |
  BCC code_1ED302                           ; $1ED2D6 |
  LDA $16                                   ; $1ED2D8 |
  AND #$0B                                  ; $1ED2DA |
  BEQ code_1ED2E1                           ; $1ED2DC |
  STA $04A0,y                               ; $1ED2DE |
code_1ED2E1:
  LDA #$00                                  ; $1ED2E1 |
  STA $0440,y                               ; $1ED2E3 |
  LDA #$04                                  ; $1ED2E6 |
  STA $0460,y                               ; $1ED2E8 |
  LDA #$14                                  ; $1ED2EB |
  STA $0500,y                               ; $1ED2ED |
  LDA $0360,x                               ; $1ED2F0 |
  STA $0360,y                               ; $1ED2F3 |
  LDA $0380,x                               ; $1ED2F6 |
  STA $0380,y                               ; $1ED2F9 |
  LDA $03C0,x                               ; $1ED2FC |
  STA $03C0,y                               ; $1ED2FF |
code_1ED302:
  RTS                                       ; $1ED302 |

; routine pointers for weapon init upon firing
weapon_init_ptr_lo:
  db init_weapon                            ; $1ED303 | Mega Buster
  db init_gemini_laser                      ; $1ED304 | Gemini Laser
  db init_needle_cannon                     ; $1ED305 | Needle Cannon
  db init_hard_knuckle                      ; $1ED306 | Hard Knuckle
  db init_weapon                            ; $1ED307 | Magnet Missile
  db init_top_spin                          ; $1ED308 | Top Spin
  db init_search_snake                      ; $1ED309 | Search Snake
  db init_rush                              ; $1ED30A | Rush Coil
  db init_weapon                            ; $1ED30B | Spark Shock
  db init_rush                              ; $1ED30C | Rush Marine
  db init_shadow_blade                      ; $1ED30D | Shadow Blade
  db init_rush                              ; $1ED30E | Rush Jet

weapon_init_ptr_hi:
  db init_weapon>>8                         ; $1ED30F | Mega Buster
  db init_gemini_laser>>8                   ; $1ED310 | Gemini Laser
  db init_needle_cannon>>8                  ; $1ED311 | Needle Cannon
  db init_hard_knuckle>>8                   ; $1ED312 | Hard Knuckle
  db init_weapon>>8                         ; $1ED313 | Magnet Missile
  db init_top_spin>>8                       ; $1ED314 | Top Spin
  db init_search_snake>>8                   ; $1ED315 | Search Snake
  db init_rush>>8                           ; $1ED316 | Rush Coil
  db init_weapon>>8                         ; $1ED317 | Spark Shock
  db init_rush>>8                           ; $1ED318 | Rush Marine
  db init_shadow_blade>>8                   ; $1ED319 | Shadow Blade
  db init_rush>>8                           ; $1ED31A | Rush Jet

; on weapon fire, weapon is placed at an offset from Mega Man
; based on left vs. right facing
; right X pixel, right X screen, left X pixel, left X screen
weapon_x_offset:
  db $0F, $00, $F0, $FF                     ; $1ED31B |

  db $17, $00, $E8, $FF                     ; $1ED31F |

weapon_OAM_ID:
  db $18                                    ; $1ED323 | Mega Buster
  db $9F                                    ; $1ED324 | Gemini Laser
  db $A2                                    ; $1ED325 | Needle Cannon
  db $AC                                    ; $1ED326 | Hard Knuckle
  db $97                                    ; $1ED327 | Magnet Missile
  db $18                                    ; $1ED328 | Top Spin
  db $A5                                    ; $1ED329 | Search Snake
  db $18                                    ; $1ED32A | Rush Coil
  db $9C                                    ; $1ED32B | Spark Shock
  db $18                                    ; $1ED32C | Rush Marine
  db $9E                                    ; $1ED32D | Shadow Blade
  db $18                                    ; $1ED32E | Rush Jet

weapon_main_ID:
  db $01                                    ; $1ED32F | Mega Buster
  db $84                                    ; $1ED330 | Gemini Laser
  db $01                                    ; $1ED331 | Needle Cannon
  db $85                                    ; $1ED332 | Hard Knuckle
  db $83                                    ; $1ED333 | Magnet Missile
  db $01                                    ; $1ED334 | Top Spin
  db $86                                    ; $1ED335 | Search Snake
  db $01                                    ; $1ED336 | Rush Coil
  db $87                                    ; $1ED337 | Spark Shock
  db $01                                    ; $1ED338 | Rush Marine
  db $88                                    ; $1ED339 | Shadow Blade
  db $01                                    ; $1ED33A | Rush Jet

  db $FE, $02                               ; $1ED33B |

; maximum # of shots on screen at once
weapon_max_shots:
  db $03                                    ; $1ED33D | Mega Buster
  db $01                                    ; $1ED33E | Gemini Laser
  db $03                                    ; $1ED33F | Needle Cannon
  db $01                                    ; $1ED340 | Hard Knuckle
  db $02                                    ; $1ED341 | Magnet Missile
  db $00                                    ; $1ED342 | Top Spin
  db $03                                    ; $1ED343 | Search Snake
  db $03                                    ; $1ED344 | Rush Coil
  db $02                                    ; $1ED345 | Spark Shock
  db $03                                    ; $1ED346 | Rush Marine
  db $01                                    ; $1ED347 | Shadow Blade
  db $03                                    ; $1ED348 | Rush Jet

; sound ID played on weapon fire
weapon_fire_sound:
  db $15                                    ; $1ED349 | Mega Buster
  db $2B                                    ; $1ED34A | Gemini Laser
  db $15                                    ; $1ED34B | Needle Cannon
  db $15                                    ; $1ED34C | Hard Knuckle
  db $2A                                    ; $1ED34D | Magnet Missile
  db $2C                                    ; $1ED34E | Top Spin
  db $15                                    ; $1ED34F | Search Snake
  db $15                                    ; $1ED350 | Rush Coil
  db $2D                                    ; $1ED351 | Spark Shock
  db $15                                    ; $1ED352 | Rush Marine
  db $2E                                    ; $1ED353 | Shadow Blade
  db $15                                    ; $1ED354 | Rush Jet

code_1ED355:
  LDA $32                                   ; $1ED355 |
  BEQ code_1ED36F                           ; $1ED357 |
  DEC $32                                   ; $1ED359 |
  BNE code_1ED36F                           ; $1ED35B |
  JSR code_1ED37F                           ; $1ED35D |
  LDY $05C0                                 ; $1ED360 |
  CPY #$04                                  ; $1ED363 |
  BEQ code_1ED36F                           ; $1ED365 |
  LDA #$00                                  ; $1ED367 |
  STA $05E0                                 ; $1ED369 |
  STA $05A0                                 ; $1ED36C |
code_1ED36F:
  RTS                                       ; $1ED36F |

code_1ED370:
  PHA                                       ; $1ED370 | preserve A
  INC $05C0                                 ; $1ED371 |
  LDA $A0                                   ; $1ED374 |
  CMP #$0A                                  ; $1ED376 |
  BNE code_1ED37D                           ; $1ED378 |
  INC $05C0                                 ; $1ED37A |
code_1ED37D:
  PLA                                       ; $1ED37D | restore A
  RTS                                       ; $1ED37E |

code_1ED37F:
  PHA                                       ; $1ED37F |
  DEC $05C0                                 ; $1ED380 |
  LDA $A0                                   ; $1ED383 |
  CMP #$0A                                  ; $1ED385 |
  BNE code_1ED38C                           ; $1ED387 |
  DEC $05C0                                 ; $1ED389 |
code_1ED38C:
  PLA                                       ; $1ED38C |
  RTS                                       ; $1ED38D |

code_1ED38E:
  LDA $16                                   ; $1ED38E |
  AND #$03                                  ; $1ED390 |
  BEQ code_1ED396                           ; $1ED392 |
  STA $31                                   ; $1ED394 |
code_1ED396:
  LDY #$04                                  ; $1ED396 |
  LDA $31                                   ; $1ED398 |
  AND #$01                                  ; $1ED39A |
  BNE code_1ED39F                           ; $1ED39C |
  INY                                       ; $1ED39E |
code_1ED39F:
  JSR check_tile_horiz                           ; $1ED39F |
  LDA $10                                   ; $1ED3A2 |\ solid ground ahead?
  AND #$10                                  ; $1ED3A4 | | if yes, wall → stop slide
  BEQ code_1ED3A9                           ; $1ED3A6 |/
  RTS                                       ; $1ED3A8 |

code_1ED3A9:
  LDA #$02                                  ; $1ED3A9 |\ no wall → continue sliding
  STA $30                                   ; $1ED3AB |/
  LDA #$14                                  ; $1ED3AD |
  STA $33                                   ; $1ED3AF |
  LDA #$10                                  ; $1ED3B1 |
  JSR reset_sprite_anim                     ; $1ED3B3 |
  LDA $03C0                                 ; $1ED3B6 |
  CLC                                       ; $1ED3B9 |
  ADC #$02                                  ; $1ED3BA |
  STA $03C0                                 ; $1ED3BC |
  LDA #$80                                  ; $1ED3BF |
  STA $0400                                 ; $1ED3C1 |
  LDA #$02                                  ; $1ED3C4 |
  STA $0420                                 ; $1ED3C6 |
  LDA #$80                                  ; $1ED3C9 |
  STA $0304                                 ; $1ED3CB |
  LDA $0580                                 ; $1ED3CE |
  STA $0584                                 ; $1ED3D1 |
  LDX #$04                                  ; $1ED3D4 |
  LDA #$17                                  ; $1ED3D6 |
  JSR reset_sprite_anim                     ; $1ED3D8 |
  LDA $0360                                 ; $1ED3DB |
  STA $0364                                 ; $1ED3DE |
  LDA $0380                                 ; $1ED3E1 |
  STA $0384                                 ; $1ED3E4 |
  LDA $03C0                                 ; $1ED3E7 |
  STA $03C4                                 ; $1ED3EA |
  LDA $03E0                                 ; $1ED3ED |
  STA $03E4                                 ; $1ED3F0 |
  LDX #$00                                  ; $1ED3F3 |
  STX $0484                                 ; $1ED3F5 |
  STX $0324                                 ; $1ED3F8 |
  BEQ code_1ED412                           ; $1ED3FB |

; player state $02: sliding on ground
player_slide:
  LDY #$02                                  ; $1ED3FD |
  JSR move_vertical_gravity                           ; $1ED3FF |
  BCC code_1ED455                           ; $1ED402 |
  LDA $16                                   ; $1ED404 |
  AND #$03                                  ; $1ED406 |
  BEQ code_1ED412                           ; $1ED408 |
  CMP $31                                   ; $1ED40A |
  BEQ code_1ED412                           ; $1ED40C |
  STA $31                                   ; $1ED40E |
  BNE code_1ED43E                           ; $1ED410 |
code_1ED412:
  LDA $31                                   ; $1ED412 |
  AND #$01                                  ; $1ED414 |
  BEQ code_1ED420                           ; $1ED416 |
  LDY #$02                                  ; $1ED418 |
  JSR move_right_collide                           ; $1ED41A |
  JMP code_1ED425                           ; $1ED41D |

code_1ED420:
  LDY #$03                                  ; $1ED420 |
  JSR move_left_collide                           ; $1ED422 |
code_1ED425:
  LDA $10                                   ; $1ED425 |\ solid ground under feet?
  AND #$10                                  ; $1ED427 | | if on ground, land
  BNE code_1ED43E                           ; $1ED429 |/
  LDA $33                                   ; $1ED42B |
  BEQ code_1ED43E                           ; $1ED42D |
  DEC $33                                   ; $1ED42F |
  LDA $33                                   ; $1ED431 |
  CMP #$0C                                  ; $1ED433 |
  BCS code_1ED43D                           ; $1ED435 |
  LDA $14                                   ; $1ED437 |
  AND #$80                                  ; $1ED439 |
  BNE code_1ED43E                           ; $1ED43B |
code_1ED43D:
  RTS                                       ; $1ED43D |

code_1ED43E:
  LDY #$01                                  ; $1ED43E |
  JSR check_tile_horiz                           ; $1ED440 |
  LDA $10                                   ; $1ED443 |\ bit 4 = solid ground under feet
  AND #$10                                  ; $1ED445 | | ($10,$30,$50,$70 all have bit 4)
  BNE code_1ED470                           ; $1ED447 |/ on ground → return
  STA $33                                   ; $1ED449 |
  STA $30                                   ; $1ED44B |
  LDA $14                                   ; $1ED44D |
  AND #$80                                  ; $1ED44F |
  BNE code_1ED471                           ; $1ED451 |
  BEQ code_1ED45D                           ; $1ED453 |
code_1ED455:
  LDA #$00                                  ; $1ED455 |
  STA $33                                   ; $1ED457 |
  LDA #$01                                  ; $1ED459 |
  BNE code_1ED45F                           ; $1ED45B |
code_1ED45D:
  LDA #$04                                  ; $1ED45D |
code_1ED45F:
  JSR reset_sprite_anim                     ; $1ED45F |
  LDA #$4C                                  ; $1ED462 |
  STA $0400                                 ; $1ED464 |
  LDA #$01                                  ; $1ED467 |
  STA $0420                                 ; $1ED469 |
  LDA #$00                                  ; $1ED46C |
  STA $30                                   ; $1ED46E |
code_1ED470:
  RTS                                       ; $1ED470 |

code_1ED471:
  LDA #$4C                                  ; $1ED471 |
  STA $0400                                 ; $1ED473 |
  LDA #$01                                  ; $1ED476 |
  STA $0420                                 ; $1ED478 |
  JMP player_on_ground.jump                 ; $1ED47B |

code_1ED47E:
  LDA $03E0                                 ; $1ED47E |
  BNE code_1ED4C7                           ; $1ED481 |
  LDA $16                                   ; $1ED483 |\ pressing Up?
  AND #$08                                  ; $1ED485 | | (Up = bit 3)
  BEQ code_1ED4C8                           ; $1ED487 |/
  PHP                                       ; $1ED489 |
.check_ladder_entry:
  LDY #$04                                  ; $1ED48A |
  JSR check_tile_collision                           ; $1ED48C |
  LDA $44                                   ; $1ED48F |\ check both foot tiles
  CMP #$20                                  ; $1ED491 | | for ladder ($20) or
  BEQ code_1ED4A3                           ; $1ED493 | | ladder top ($40)
  CMP #$40                                  ; $1ED495 | |
  BEQ code_1ED4A3                           ; $1ED497 |/
  LDA $43                                   ; $1ED499 |\ same check on other foot
  CMP #$20                                  ; $1ED49B | |
  BEQ code_1ED4A3                           ; $1ED49D | |
  CMP #$40                                  ; $1ED49F | |
  BNE code_1ED4C6                           ; $1ED4A1 |/
code_1ED4A3:
  PLP                                       ; $1ED4A3 |
  LDA $12                                   ; $1ED4A4 |
  AND #$F0                                  ; $1ED4A6 |
  ORA #$08                                  ; $1ED4A8 |
  STA $0360                                 ; $1ED4AA |
  LDA #$0A                                  ; $1ED4AD |
code_1ED4AF:
  JSR reset_sprite_anim                     ; $1ED4AF |
  LDA #$03                                  ; $1ED4B2 |
  STA $30                                   ; $1ED4B4 |
  LDA #$4C                                  ; $1ED4B6 |
  STA $0440                                 ; $1ED4B8 |
  LDA #$01                                  ; $1ED4BB |
  STA $0460                                 ; $1ED4BD |
  LDA #$00                                  ; $1ED4C0 |
  STA $32                                   ; $1ED4C2 |
  CLC                                       ; $1ED4C4 |
  RTS                                       ; $1ED4C5 |

code_1ED4C6:
  PLP                                       ; $1ED4C6 |
code_1ED4C7:
  RTS                                       ; $1ED4C7 |

code_1ED4C8:
  LDA $16                                   ; $1ED4C8 |
  AND #$04                                  ; $1ED4CA |
  BEQ code_1ED4C7                           ; $1ED4CC |
  PHP                                       ; $1ED4CE |
  LDA $43                                   ; $1ED4CF |
  CMP #$40                                  ; $1ED4D1 |
  BNE code_1ED48A                           ; $1ED4D3 |
  PLP                                       ; $1ED4D5 |
  LDA $0360                                 ; $1ED4D6 |
  AND #$F0                                  ; $1ED4D9 |
  ORA #$08                                  ; $1ED4DB |
  STA $0360                                 ; $1ED4DD |
  LDA $11                                   ; $1ED4E0 |
  AND #$F0                                  ; $1ED4E2 |
  STA $03C0                                 ; $1ED4E4 |
  LDA #$14                                  ; $1ED4E7 |
  BNE code_1ED4AF                           ; $1ED4E9 |

; player state $03: on ladder (climb, fire, jump off)
player_ladder:
  JSR code_1ED355                           ; $1ED4EB |
  LDA $14                                   ; $1ED4EE |
  AND #$40                                  ; $1ED4F0 |
  BEQ code_1ED50B                           ; $1ED4F2 |
  LDA $16                                   ; $1ED4F4 |
  AND #$03                                  ; $1ED4F6 |
  BEQ code_1ED508                           ; $1ED4F8 |
  CMP $31                                   ; $1ED4FA |
  BEQ code_1ED508                           ; $1ED4FC |
  STA $31                                   ; $1ED4FE |
  LDA $0580                                 ; $1ED500 |
  EOR #$40                                  ; $1ED503 |
  STA $0580                                 ; $1ED505 |
code_1ED508:
  JSR weapon_fire                           ; $1ED508 |
code_1ED50B:
  LDA $32                                   ; $1ED50B |
  BNE code_1ED4C7                           ; $1ED50D |
  LDA $16                                   ; $1ED50F |
  AND #$0C                                  ; $1ED511 |
  BNE code_1ED521                           ; $1ED513 |
  LDA $14                                   ; $1ED515 |
  AND #$80                                  ; $1ED517 |
  BNE code_1ED51E                           ; $1ED519 |
  JMP code_1ED5B4                           ; $1ED51B |

code_1ED51E:
  JMP code_1ED5AD                           ; $1ED51E |

code_1ED521:
  PHA                                       ; $1ED521 |
  LDA $0360                                 ; $1ED522 |
  AND #$F0                                  ; $1ED525 |
  ORA #$08                                  ; $1ED527 |
  STA $0360                                 ; $1ED529 |
  PLA                                       ; $1ED52C |
  AND #$04                                  ; $1ED52D |
  BEQ code_1ED568                           ; $1ED52F |
  LDA #$0A                                  ; $1ED531 |
  CMP $05C0                                 ; $1ED533 |
  BEQ code_1ED53B                           ; $1ED536 |
  JSR reset_sprite_anim                     ; $1ED538 |
code_1ED53B:
  LDY #$00                                  ; $1ED53B |
  JSR move_down_collide                           ; $1ED53D |
  BCS code_1ED5AD                           ; $1ED540 |
  LDA $03E0                                 ; $1ED542 |
  BEQ code_1ED54D                           ; $1ED545 |
  LDA #$00                                  ; $1ED547 |
  STA $03C0                                 ; $1ED549 |
  RTS                                       ; $1ED54C |

code_1ED54D:
  LDY #$04                                  ; $1ED54D |
  JSR check_tile_collision                           ; $1ED54F |
  LDA $44                                   ; $1ED552 |
  CMP #$20                                  ; $1ED554 |
  BEQ code_1ED5B9                           ; $1ED556 |
  CMP #$40                                  ; $1ED558 |
  BEQ code_1ED5B9                           ; $1ED55A |
  LDA $43                                   ; $1ED55C |
  CMP #$20                                  ; $1ED55E |
  BEQ code_1ED5B9                           ; $1ED560 |
  CMP #$40                                  ; $1ED562 |
  BEQ code_1ED5B9                           ; $1ED564 |
  BNE code_1ED5AD                           ; $1ED566 |
code_1ED568:
  LDY #$01                                  ; $1ED568 |
  JSR move_up_collide                           ; $1ED56A |
  BCS code_1ED5B4                           ; $1ED56D |
  LDA $03E0                                 ; $1ED56F |
  BEQ code_1ED57A                           ; $1ED572 |
  LDA #$EF                                  ; $1ED574 |
  STA $03C0                                 ; $1ED576 |
  RTS                                       ; $1ED579 |

code_1ED57A:
  LDA $03C0                                 ; $1ED57A |
  CMP #$10                                  ; $1ED57D |
  BCC code_1ED5B9                           ; $1ED57F |
  LDY #$04                                  ; $1ED581 |
  JSR check_tile_collision                           ; $1ED583 |
  LDA $44                                   ; $1ED586 |
  CMP #$20                                  ; $1ED588 |
  BEQ code_1ED5B9                           ; $1ED58A |
  CMP #$40                                  ; $1ED58C |
  BEQ code_1ED5B9                           ; $1ED58E |
  LDA $43                                   ; $1ED590 |
  CMP #$20                                  ; $1ED592 |
  BEQ code_1ED5B9                           ; $1ED594 |
  CMP #$40                                  ; $1ED596 |
  BEQ code_1ED5B9                           ; $1ED598 |
  LDA #$14                                  ; $1ED59A |
  CMP $05C0                                 ; $1ED59C |
  BEQ code_1ED5A4                           ; $1ED59F |
  JSR reset_sprite_anim                     ; $1ED5A1 |
code_1ED5A4:
  LDA $03C0                                 ; $1ED5A4 |
  AND #$0F                                  ; $1ED5A7 |
  CMP #$0C                                  ; $1ED5A9 |
  BCS code_1ED5B9                           ; $1ED5AB |
code_1ED5AD:
  LDA #$00                                  ; $1ED5AD |
  STA $30                                   ; $1ED5AF |
  JMP reset_gravity                         ; $1ED5B1 |

code_1ED5B4:
  LDA #$00                                  ; $1ED5B4 |
  STA $05E0                                 ; $1ED5B6 |
code_1ED5B9:
  RTS                                       ; $1ED5B9 |

; player state $04: respawn/reappear (death, unpause, stage start) [confirmed]
player_reappear:
  LDA $05A0                                 ; $1ED5BA |
  BNE code_1ED5EB                           ; $1ED5BD |
  LDA $22                                   ; $1ED5BF |
  CMP #$07                                  ; $1ED5C1 |
  BEQ code_1ED5D2                           ; $1ED5C3 |
  LDA $03C0                                 ; $1ED5C5 |
  CMP #$68                                  ; $1ED5C8 |
  BCS code_1ED5DF                           ; $1ED5CA |
  JSR apply_y_speed                           ; $1ED5CC |
  JMP code_1ED5E6                           ; $1ED5CF |

code_1ED5D2:
  LDA $03C0                                 ; $1ED5D2 |
  CMP #$30                                  ; $1ED5D5 |
  BCS code_1ED5DF                           ; $1ED5D7 |
  JSR apply_y_speed                           ; $1ED5D9 |
  JMP code_1ED5E6                           ; $1ED5DC |

code_1ED5DF:
  LDY #$00                                  ; $1ED5DF |
  JSR move_vertical_gravity                           ; $1ED5E1 |
  BCS code_1ED5EB                           ; $1ED5E4 |
code_1ED5E6:
  LDA #$00                                  ; $1ED5E6 |
  STA $05E0                                 ; $1ED5E8 |
code_1ED5EB:
  LDA $05E0                                 ; $1ED5EB |
  BNE code_1ED5FC                           ; $1ED5EE |
  LDA $05A0                                 ; $1ED5F0 |
  CMP #$01                                  ; $1ED5F3 |
  BNE code_1ED5FC                           ; $1ED5F5 |
  LDA #$34                                  ; $1ED5F7 |
  JSR submit_sound_ID                       ; $1ED5F9 |
code_1ED5FC:
  LDA $05A0                                 ; $1ED5FC |
  CMP #$04                                  ; $1ED5FF |
  BNE code_1ED60B                           ; $1ED601 |
  LDA #$00                                  ; $1ED603 |
  STA $30                                   ; $1ED605 |
  STA $32                                   ; $1ED607 |
  STA $39                                   ; $1ED609 |
code_1ED60B:
  RTS                                       ; $1ED60B |

code_1ED60C:
  LDA #$00                                  ; $1ED60C |
  STA $30                                   ; $1ED60E |
  JMP reset_gravity                         ; $1ED610 |

; player state $05: riding entity at slot $34 (anim $62) [unconfirmed]
player_entity_ride:
  LDY $34                                   ; $1ED613 |
  LDA $0300,y                               ; $1ED615 |
  BPL code_1ED60C                           ; $1ED618 |
  LDA $05C0,y                               ; $1ED61A |
  CMP #$62                                  ; $1ED61D |
  BNE code_1ED60C                           ; $1ED61F |
  LDA $16                                   ; $1ED621 |
  AND #$0C                                  ; $1ED623 |
  BEQ code_1ED656                           ; $1ED625 |
  STA $00                                   ; $1ED627 |
  LDA $0440                                 ; $1ED629 |
  PHA                                       ; $1ED62C |
  LDA $0460                                 ; $1ED62D |
  PHA                                       ; $1ED630 |
  LDA #$40                                  ; $1ED631 |
  STA $0440                                 ; $1ED633 |
  LDA #$00                                  ; $1ED636 |
  STA $0460                                 ; $1ED638 |
  LDA $00                                   ; $1ED63B |
  AND #$08                                  ; $1ED63D |
  BEQ code_1ED649                           ; $1ED63F |
  LDY #$01                                  ; $1ED641 |
  JSR move_up_collide                           ; $1ED643 |
  JMP code_1ED64E                           ; $1ED646 |

code_1ED649:
  LDY #$00                                  ; $1ED649 |
  JSR move_down_collide                           ; $1ED64B |
code_1ED64E:
  PLA                                       ; $1ED64E |
  STA $0460                                 ; $1ED64F |
  PLA                                       ; $1ED652 |
  STA $0440                                 ; $1ED653 |
code_1ED656:
  LDA $0440                                 ; $1ED656 |
  ORA $0460                                 ; $1ED659 |
  BNE code_1ED67E                           ; $1ED65C |
  LDA $14                                   ; $1ED65E |
  AND #$80                                  ; $1ED660 |
  BEQ code_1ED667                           ; $1ED662 |
  JMP player_on_ground.jump                 ; $1ED664 |

code_1ED667:
  LDA #$00                                  ; $1ED667 |
  STA $0400                                 ; $1ED669 |
  LDA #$01                                  ; $1ED66C |
  STA $0420                                 ; $1ED66E |
  LDA $0580                                 ; $1ED671 |
  PHA                                       ; $1ED674 |
  LDA $35                                   ; $1ED675 |
  JSR code_1ECF3D                           ; $1ED677 |
  PLA                                       ; $1ED67A |
  STA $0580                                 ; $1ED67B |
code_1ED67E:
  LDY #$01                                  ; $1ED67E |
  JSR move_up_collide                           ; $1ED680 |
  LDA $0440                                 ; $1ED683 |
  CLC                                       ; $1ED686 |
  ADC #$40                                  ; $1ED687 |
  STA $0440                                 ; $1ED689 |
  LDA $0460                                 ; $1ED68C |
  ADC #$00                                  ; $1ED68F |
  STA $0460                                 ; $1ED691 |
  CMP #$07                                  ; $1ED694 |
  BCC code_1ED69D                           ; $1ED696 |
  LDA #$00                                  ; $1ED698 |
  STA $0440                                 ; $1ED69A |
code_1ED69D:
  LDA #$4C                                  ; $1ED69D |
  STA $0400                                 ; $1ED69F |
  LDA #$01                                  ; $1ED6A2 |
  STA $0420                                 ; $1ED6A4 |
  JSR code_1ED0C1                           ; $1ED6A7 |
  RTS                                       ; $1ED6AA |

; player state $06: taking damage, init knockback
player_damage:
  LDA $05C0                                 ; $1ED6AB |
  CMP #$11                                  ; $1ED6AE |
  BEQ code_1ED701                           ; $1ED6B0 |
  CMP #$B1                                  ; $1ED6B2 |
  BEQ code_1ED701                           ; $1ED6B4 |
  LDA $05C0                                 ; $1ED6B6 |
  STA $3E                                   ; $1ED6B9 |
  CMP #$D9                                  ; $1ED6BB |
  BCS code_1ED6C3                           ; $1ED6BD |
  LDA #$11                                  ; $1ED6BF |
  BNE code_1ED6C5                           ; $1ED6C1 |
code_1ED6C3:
  LDA #$B1                                  ; $1ED6C3 |
code_1ED6C5:
  JSR reset_sprite_anim                     ; $1ED6C5 |
  LDA #$00                                  ; $1ED6C8 |
  STA $32                                   ; $1ED6CA |
  JSR reset_gravity                         ; $1ED6CC |
  LDA #$80                                  ; $1ED6CF |
  STA $0304                                 ; $1ED6D1 |
  LDA $0580                                 ; $1ED6D4 |
  STA $0584                                 ; $1ED6D7 |
  LDX #$04                                  ; $1ED6DA |
  LDA #$12                                  ; $1ED6DC |
  JSR reset_sprite_anim                     ; $1ED6DE |
  LDA $0360                                 ; $1ED6E1 |
  STA $0364                                 ; $1ED6E4 |
  LDA $0380                                 ; $1ED6E7 |
  STA $0384                                 ; $1ED6EA |
  LDA $03C0                                 ; $1ED6ED |
  STA $03C4                                 ; $1ED6F0 |
  LDA $03E0                                 ; $1ED6F3 |
  STA $03E4                                 ; $1ED6F6 |
  LDX #$00                                  ; $1ED6F9 |
  STX $0484                                 ; $1ED6FB |
  STX $0324                                 ; $1ED6FE |
code_1ED701:
  LDA $3E                                   ; $1ED701 |
  CMP #$10                                  ; $1ED703 |
  BEQ code_1ED742                           ; $1ED705 |
  CMP #$79                                  ; $1ED707 |
  BCS code_1ED742                           ; $1ED709 |
  LDY #$00                                  ; $1ED70B |
  JSR move_vertical_gravity                           ; $1ED70D |
  LDA #$80                                  ; $1ED710 |
  STA $0400                                 ; $1ED712 |
  LDA #$00                                  ; $1ED715 |
  STA $0420                                 ; $1ED717 |
  LDA $0580                                 ; $1ED71A |
  PHA                                       ; $1ED71D |
  LDA $0580                                 ; $1ED71E |
  AND #$40                                  ; $1ED721 |
  BNE code_1ED72D                           ; $1ED723 |
  LDY #$00                                  ; $1ED725 |
  JSR move_right_collide                           ; $1ED727 |
  JMP code_1ED732                           ; $1ED72A |

code_1ED72D:
  LDY #$01                                  ; $1ED72D |
  JSR move_left_collide                           ; $1ED72F |
code_1ED732:
  LDA $0360                                 ; $1ED732 |
  STA $0364                                 ; $1ED735 |
  LDA $0380                                 ; $1ED738 |
  STA $0384                                 ; $1ED73B |
  PLA                                       ; $1ED73E |
  STA $0580                                 ; $1ED73F |
code_1ED742:
  LDA $05A0                                 ; $1ED742 |
  CMP #$09                                  ; $1ED745 |
  BNE code_1ED778                           ; $1ED747 |
  LDA $3E                                   ; $1ED749 |
  PHA                                       ; $1ED74B |
  CMP #$10                                  ; $1ED74C |
  BEQ code_1ED754                           ; $1ED74E |
  CMP #$D9                                  ; $1ED750 |
  BCC code_1ED757                           ; $1ED752 |
code_1ED754:
  JSR reset_sprite_anim                     ; $1ED754 |
code_1ED757:
  PLA                                       ; $1ED757 |
  CMP #$10                                  ; $1ED758 |
  BEQ code_1ED764                           ; $1ED75A |
  CMP #$D9                                  ; $1ED75C |
  BCC code_1ED768                           ; $1ED75E |
  LDA #$08                                  ; $1ED760 |
  BNE code_1ED76A                           ; $1ED762 |
code_1ED764:
  LDA #$02                                  ; $1ED764 |
  BNE code_1ED76A                           ; $1ED766 |
code_1ED768:
  LDA #$00                                  ; $1ED768 |
code_1ED76A:
  STA $30                                   ; $1ED76A |
  LDA #$3C                                  ; $1ED76C |
  STA $39                                   ; $1ED76E |
  LDA $05E0                                 ; $1ED770 |
  ORA #$80                                  ; $1ED773 |
  STA $05E0                                 ; $1ED775 |
code_1ED778:
  RTS                                       ; $1ED778 |

; player state $0E: dead, explosion on all sprites
player_death:
  LDA #$00                                  ; $1ED779 |
  STA $3D                                   ; $1ED77B |
  LDA $05C0                                 ; $1ED77D |
  CMP #$7A                                  ; $1ED780 |
  BEQ code_1ED7E7                           ; $1ED782 |
  LDA $03E0                                 ; $1ED784 |
  BNE code_1ED7EA                           ; $1ED787 |
  LDY #$0F                                  ; $1ED789 |
code_1ED78B:
  LDA #$7A                                  ; $1ED78B |
  STA $05C0,y                               ; $1ED78D |
  LDA #$00                                  ; $1ED790 |
  STA $05E0,y                               ; $1ED792 |
  STA $05A0,y                               ; $1ED795 |
  STA $0480,y                               ; $1ED798 |
  LDA $0360                                 ; $1ED79B |
  STA $0360,y                               ; $1ED79E |
  LDA $0380                                 ; $1ED7A1 |
  STA $0380,y                               ; $1ED7A4 |
  LDA $03C0                                 ; $1ED7A7 |
  STA $03C0,y                               ; $1ED7AA |
  LDA $03E0                                 ; $1ED7AD |
  STA $03E0,y                               ; $1ED7B0 |
  LDA #$10                                  ; $1ED7B3 |
  STA $0320,y                               ; $1ED7B5 |
  LDA #$80                                  ; $1ED7B8 |
  STA $0300,y                               ; $1ED7BA |
  LDA #$90                                  ; $1ED7BD |
  STA $0580,y                               ; $1ED7BF |
  LDA $D7F1,y                               ; $1ED7C2 |
  STA $0400,y                               ; $1ED7C5 |
  LDA $D801,y                               ; $1ED7C8 |
  STA $0420,y                               ; $1ED7CB |
  LDA $D811,y                               ; $1ED7CE |
  STA $0440,y                               ; $1ED7D1 |
  LDA $D821,y                               ; $1ED7D4 |
  STA $0460,y                               ; $1ED7D7 |
  DEY                                       ; $1ED7DA |
  BPL code_1ED78B                           ; $1ED7DB |
  LDA #$00                                  ; $1ED7DD |
  STA $0440                                 ; $1ED7DF |
  LDA #$03                                  ; $1ED7E2 |
  STA $0460                                 ; $1ED7E4 |
code_1ED7E7:
  JSR move_sprite_up                        ; $1ED7E7 |
code_1ED7EA:
  INC $3F                                   ; $1ED7EA |
  BNE code_1ED7F0                           ; $1ED7EC |
  INC $3C                                   ; $1ED7EE |
code_1ED7F0:
  RTS                                       ; $1ED7F0 |

  db $00, $1F, $00, $1F, $00, $E1, $00, $E1 ; $1ED7F1 |
  db $00, $0F, $80, $0F, $00, $F1, $80, $F1 ; $1ED7F9 |
  db $00, $02, $03, $02, $00, $FD, $FD, $FD ; $1ED801 |
  db $00, $01, $01, $01, $00, $FE, $FE, $FE ; $1ED809 |
  db $00, $E1, $00, $1F, $00, $1F, $00, $E1 ; $1ED811 |
  db $80, $F1, $00, $0F, $80, $0F, $00, $F1 ; $1ED819 |
  db $FD, $FD, $00, $02, $03, $02, $00, $FD ; $1ED821 |
  db $FE, $FE, $00, $01, $01, $01, $00, $FE ; $1ED829 |

; player state $07: Doc Flash Time Stopper kill [confirmed]
player_special_death:
  LDA #$00                                  ; $1ED831 |
  STA $05E0                                 ; $1ED833 |
  DEC $0500                                 ; $1ED836 |
  BNE code_1ED857                           ; $1ED839 |
  LDA #$1E                                  ; $1ED83B |
  STA $0500                                 ; $1ED83D |
  LDY #$68                                  ; $1ED840 |
code_1ED842:
  LDA $0201,y                               ; $1ED842 |
  CLC                                       ; $1ED845 |
  ADC #$01                                  ; $1ED846 |
  CMP #$FA                                  ; $1ED848 |
  BNE code_1ED84E                           ; $1ED84A |
  LDA #$F7                                  ; $1ED84C |
code_1ED84E:
  STA $0201,y                               ; $1ED84E |
  DEY                                       ; $1ED851 |
  DEY                                       ; $1ED852 |
  DEY                                       ; $1ED853 |
  DEY                                       ; $1ED854 |
  BPL code_1ED842                           ; $1ED855 |
code_1ED857:
  RTS                                       ; $1ED857 |

; player state $08: riding Rush Marine submarine [confirmed]
player_rush_marine:
  JSR decrease_ammo.check_frames            ; $1ED858 |
  LDA $05C0                                 ; $1ED85B |
  CMP #$DA                                  ; $1ED85E |
  BNE code_1ED86E                           ; $1ED860 |
  LDA $05A0                                 ; $1ED862 |
  CMP #$03                                  ; $1ED865 |
  BNE code_1ED857                           ; $1ED867 |
  LDA #$DB                                  ; $1ED869 |
  JSR reset_sprite_anim                     ; $1ED86B |
code_1ED86E:
  LDY #$06                                  ; $1ED86E |
  JSR check_tile_horiz                           ; $1ED870 |
  LDA $10                                   ; $1ED873 |
  CMP #$80                                  ; $1ED875 |
  BEQ code_1ED886                           ; $1ED877 |
  LDA #$DB                                  ; $1ED879 |
  CMP $05C0                                 ; $1ED87B |
  BEQ code_1ED893                           ; $1ED87E |
  JSR reset_sprite_anim                     ; $1ED880 |
  JMP code_1ED893                           ; $1ED883 |

code_1ED886:
  LDA #$DC                                  ; $1ED886 |
  CMP $05C0                                 ; $1ED888 |
  BEQ code_1ED8BD                           ; $1ED88B |
  JSR reset_sprite_anim                     ; $1ED88D |
  JMP code_1ED8BD                           ; $1ED890 |

code_1ED893:
  LDY #$00                                  ; $1ED893 |
  JSR move_vertical_gravity                           ; $1ED895 |
  BCC code_1ED8AF                           ; $1ED898 |
  LDA $14                                   ; $1ED89A |
  AND #$80                                  ; $1ED89C |
  BEQ code_1ED910                           ; $1ED89E |
code_1ED8A0:
  LDA #$E5                                  ; $1ED8A0 |
  STA $0440                                 ; $1ED8A2 |
  LDA #$04                                  ; $1ED8A5 |
  STA $0460                                 ; $1ED8A7 |
  LDY #$00                                  ; $1ED8AA |
  JSR move_vertical_gravity                           ; $1ED8AC |
code_1ED8AF:
  LDA $16                                   ; $1ED8AF |
  AND #$03                                  ; $1ED8B1 |
  BEQ code_1ED910                           ; $1ED8B3 |
  STA $31                                   ; $1ED8B5 |
  JSR code_1ECF3D                           ; $1ED8B7 |
  JMP code_1ED910                           ; $1ED8BA |

code_1ED8BD:
  LDA $14                                   ; $1ED8BD |
  AND #$80                                  ; $1ED8BF |
  BEQ code_1ED8CE                           ; $1ED8C1 |
  LDY #$01                                  ; $1ED8C3 |
  JSR check_tile_horiz                           ; $1ED8C5 |
  LDA $10                                   ; $1ED8C8 |
  CMP #$80                                  ; $1ED8CA |
  BNE code_1ED8A0                           ; $1ED8CC |
code_1ED8CE:
  LDA $16                                   ; $1ED8CE |
  AND #$03                                  ; $1ED8D0 |
  BEQ code_1ED8D9                           ; $1ED8D2 |
  STA $31                                   ; $1ED8D4 |
  JSR code_1ECF3D                           ; $1ED8D6 |
code_1ED8D9:
  LDA #$80                                  ; $1ED8D9 |
  STA $0440                                 ; $1ED8DB |
  LDA #$01                                  ; $1ED8DE |
  STA $0460                                 ; $1ED8E0 |
  LDA $16                                   ; $1ED8E3 |
  AND #$0C                                  ; $1ED8E5 |
  BEQ code_1ED910                           ; $1ED8E7 |
  AND #$04                                  ; $1ED8E9 |
  BNE code_1ED90B                           ; $1ED8EB |
  LDY #$01                                  ; $1ED8ED |
  JSR move_up_collide                           ; $1ED8EF |
  LDY #$06                                  ; $1ED8F2 |
  JSR check_tile_horiz                           ; $1ED8F4 |
  LDA $10                                   ; $1ED8F7 |
  CMP #$80                                  ; $1ED8F9 |
  BEQ code_1ED908                           ; $1ED8FB |
  LDA $03C0                                 ; $1ED8FD |
  AND #$F0                                  ; $1ED900 |
  CLC                                       ; $1ED902 |
  ADC #$10                                  ; $1ED903 |
  STA $03C0                                 ; $1ED905 |
code_1ED908:
  JMP code_1ED910                           ; $1ED908 |

code_1ED90B:
  LDY #$00                                  ; $1ED90B |
  JMP move_down_collide                           ; $1ED90D |

code_1ED910:
  LDA $05C0                                 ; $1ED910 |
  PHA                                       ; $1ED913 |
  JSR code_1ED355                           ; $1ED914 |
  LDA $14                                   ; $1ED917 |
  AND #$40                                  ; $1ED919 |
  BEQ code_1ED920                           ; $1ED91B |
  JSR weapon_fire                           ; $1ED91D |
code_1ED920:
  LDA #$00                                  ; $1ED920 |
  STA $32                                   ; $1ED922 |
  PLA                                       ; $1ED924 |
  STA $05C0                                 ; $1ED925 |
  RTS                                       ; $1ED928 |

; player state $09: frozen during boss intro (shutters/HP bar) [confirmed]
player_boss_wait:
  LDY #$00                                  ; $1ED929 |
  JSR move_vertical_gravity                           ; $1ED92B |
  BCC code_1ED990                           ; $1ED92E |
  LDA #$01                                  ; $1ED930 |
  CMP $05C0                                 ; $1ED932 |
  BEQ code_1ED942                           ; $1ED935 |
  STA $05C0                                 ; $1ED937 |
  LDA #$00                                  ; $1ED93A |
  STA $05E0                                 ; $1ED93C |
  STA $05A0                                 ; $1ED93F |
code_1ED942:
  LDA $22                                   ; $1ED942 |
  CMP #$10                                  ; $1ED944 |
  BNE code_1ED973                           ; $1ED946 |
  LDY #$26                                  ; $1ED948 |
  CPY $52                                   ; $1ED94A |
  BEQ code_1ED95B                           ; $1ED94C |
  STY $52                                   ; $1ED94E |
  LDY #$00                                  ; $1ED950 |
  STY $A000                                 ; $1ED952 |
  STY $70                                   ; $1ED955 |
  STY $28                                   ; $1ED957 |
  BEQ code_1ED95F                           ; $1ED959 |
code_1ED95B:
  LDY $70                                   ; $1ED95B |
  BEQ code_1ED973                           ; $1ED95D |
code_1ED95F:
  STA $F5                                   ; $1ED95F |
  JSR select_PRG_banks                      ; $1ED961 |
  LDA #$1A                                  ; $1ED964 |
  JSR code_1FE8B4                           ; $1ED966 |
  LDA #$04                                  ; $1ED969 |
  STA $10                                   ; $1ED96B |
  JSR fill_nametable_progressive                           ; $1ED96D |
  LDX #$00                                  ; $1ED970 |
  RTS                                       ; $1ED972 |

code_1ED973:
  LDA $B0                                   ; $1ED973 |
  CMP #$9C                                  ; $1ED975 |
  BEQ code_1ED98C                           ; $1ED977 |
  LDA $95                                   ; $1ED979 |
  AND #$03                                  ; $1ED97B |
  BNE code_1ED990                           ; $1ED97D |
  INC $B0                                   ; $1ED97F |
  LDA $B0                                   ; $1ED981 |
  CMP #$81                                  ; $1ED983 |
  BEQ code_1ED990                           ; $1ED985 |
  LDA #$1C                                  ; $1ED987 |
  JMP submit_sound_ID                       ; $1ED989 |

code_1ED98C:
  LDA #$00                                  ; $1ED98C |
  STA $30                                   ; $1ED98E |
code_1ED990:
  RTS                                       ; $1ED990 |

; player state $0A: Top Spin recoil bounce (8 frames) [confirmed]
player_top_spin:
  LDY #$00                                  ; $1ED991 |
  JSR move_vertical_gravity                           ; $1ED993 |
  BCS code_1ED9B6                           ; $1ED996 |
  LDA $0580                                 ; $1ED998 |
  PHA                                       ; $1ED99B |
  AND #$40                                  ; $1ED99C |
  BNE code_1ED9A8                           ; $1ED99E |
  LDY #$00                                  ; $1ED9A0 |
  JSR move_right_collide                           ; $1ED9A2 |
  JMP code_1ED9AD                           ; $1ED9A5 |

code_1ED9A8:
  LDY #$01                                  ; $1ED9A8 |
  JSR move_left_collide                           ; $1ED9AA |
code_1ED9AD:
  PLA                                       ; $1ED9AD |
  STA $0580                                 ; $1ED9AE |
  DEC $0500                                 ; $1ED9B1 |
  BNE code_1ED9BD                           ; $1ED9B4 |
code_1ED9B6:
  LDA #$00                                  ; $1ED9B6 |
  STA $0500                                 ; $1ED9B8 |
  STA $30                                   ; $1ED9BB |
code_1ED9BD:
  RTS                                       ; $1ED9BD |

; player state $0B: Hard Knuckle fire freeze (16 frames) [confirmed]
player_weapon_recoil:
  DEC $0520                                 ; $1ED9BE |
  BNE code_1ED9D2                           ; $1ED9C1 |
  LDY $0500                                 ; $1ED9C3 |
  STY $30                                   ; $1ED9C6 |
  LDA $D297,y                               ; $1ED9C8 |
  JSR reset_sprite_anim                     ; $1ED9CB |
  LDA #$00                                  ; $1ED9CE |
  STA $32                                   ; $1ED9D0 |
code_1ED9D2:
  RTS                                       ; $1ED9D2 |

; player state $0C: boss defeated cutscene (jump, get weapon) [confirmed]
player_victory:
  LDA $0500                                 ; $1ED9D3 |
  AND #$0F                                  ; $1ED9D6 |
  BEQ code_1EDA31                           ; $1ED9D8 |
  LDA $0460                                 ; $1ED9DA |
  BPL code_1EDA31                           ; $1ED9DD |
  LDA #$68                                  ; $1ED9DF |
  CMP $03C0                                 ; $1ED9E1 |
  BEQ code_1ED9EB                           ; $1ED9E4 |
  BCS code_1EDA31                           ; $1ED9E6 |
  STA $03C0                                 ; $1ED9E8 |
code_1ED9EB:
  LDY #$0F                                  ; $1ED9EB |
code_1ED9ED:
  LDA $0310,y                               ; $1ED9ED |
  BMI code_1EDA02                           ; $1ED9F0 |
  DEY                                       ; $1ED9F2 |
  BPL code_1ED9ED                           ; $1ED9F3 |
  LDA $0500                                 ; $1ED9F5 |
  CMP #$04                                  ; $1ED9F8 |
  BEQ code_1EDA03                           ; $1ED9FA |
  JSR code_1EDB3A                           ; $1ED9FC |
  INC $0500                                 ; $1ED9FF |
code_1EDA02:
  RTS                                       ; $1EDA02 |

code_1EDA03:
  LDA #$31                                  ; $1EDA03 |
  JSR submit_sound_ID                       ; $1EDA05 |
  LDY $22                                   ; $1EDA08 |
  LDA $DD04,y                               ; $1EDA0A |
  STA $A1                                   ; $1EDA0D |
  LDA $DD0C,y                               ; $1EDA0F |
  STA $B4                                   ; $1EDA12 |
  CLC                                       ; $1EDA14 |
  ADC $A1                                   ; $1EDA15 |
  TAY                                       ; $1EDA17 |
  LDA #$80                                  ; $1EDA18 |
  STA $00A2,y                               ; $1EDA1A |
  LDA #$02                                  ; $1EDA1D |
  STA $F5                                   ; $1EDA1F |
  JSR select_PRG_banks                      ; $1EDA21 |
  JSR $A000                                 ; $1EDA24 |
  LDA #$0D                                  ; $1EDA27 |
  STA $30                                   ; $1EDA29 |
  LDA #$80                                  ; $1EDA2B |
  STA $0300                                 ; $1EDA2D |
  RTS                                       ; $1EDA30 |

code_1EDA31:
  LDA $22                                   ; $1EDA31 |
  CMP #$10                                  ; $1EDA33 |
  BCC code_1EDA55                           ; $1EDA35 |
  LDA $95                                   ; $1EDA37 |
  AND #$07                                  ; $1EDA39 |
  BNE code_1EDA55                           ; $1EDA3B |
  LDA $0520                                 ; $1EDA3D |
  BEQ code_1EDA49                           ; $1EDA40 |
  LDA $0610                                 ; $1EDA42 |
  CMP #$0F                                  ; $1EDA45 |
  BEQ code_1EDA55                           ; $1EDA47 |
code_1EDA49:
  LDA $0610                                 ; $1EDA49 |
  EOR #$2F                                  ; $1EDA4C |
  STA $0610                                 ; $1EDA4E |
  LDA #$FF                                  ; $1EDA51 |
  STA $18                                   ; $1EDA53 |
code_1EDA55:
  LDY #$00                                  ; $1EDA55 |
  JSR move_vertical_gravity                           ; $1EDA57 |
  BCC code_1EDA6C                           ; $1EDA5A |
  LDA $0520                                 ; $1EDA5C |
  BEQ code_1EDA6C                           ; $1EDA5F |
  LDA #$01                                  ; $1EDA61 |
  CMP $05C0                                 ; $1EDA63 |
  BEQ code_1EDA6C                           ; $1EDA66 |
  JSR reset_sprite_anim                     ; $1EDA68 |
  SEC                                       ; $1EDA6B |
code_1EDA6C:
  ROL $0F                                   ; $1EDA6C |
  LDY #$0F                                  ; $1EDA6E |
code_1EDA70:
  LDA $22                                   ; $1EDA70 |
  CMP #$11                                  ; $1EDA72 |
  BNE code_1EDA7A                           ; $1EDA74 |
  CPY #$00                                  ; $1EDA76 |
  BEQ code_1EDA82                           ; $1EDA78 |
code_1EDA7A:
  LDA $0310,y                               ; $1EDA7A |
  BMI code_1EDA02                           ; $1EDA7D |
  DEY                                       ; $1EDA7F |
  BPL code_1EDA70                           ; $1EDA80 |
code_1EDA82:
  LDA $22                                   ; $1EDA82 |
  CMP #$08                                  ; $1EDA84 |
  BCC code_1EDA92                           ; $1EDA86 |
  CMP #$0C                                  ; $1EDA88 |
  BCS code_1EDA92                           ; $1EDA8A |
  LDA $F9                                   ; $1EDA8C |
  CMP #$18                                  ; $1EDA8E |
  BCC code_1EDAC8                           ; $1EDA90 |
code_1EDA92:
  LDA $22                                   ; $1EDA92 |
  CMP #$11                                  ; $1EDA94 |
  BNE code_1EDAA6                           ; $1EDA96 |
  LDA #$37                                  ; $1EDA98 |
  CMP $D9                                   ; $1EDA9A |
  BEQ code_1EDAB4                           ; $1EDA9C |
  LDA #$00                                  ; $1EDA9E |
  STA $FD                                   ; $1EDAA0 |
  LDA #$37                                  ; $1EDAA2 |
  BNE code_1EDAAC                           ; $1EDAA4 |
code_1EDAA6:
  LDA #$38                                  ; $1EDAA6 |
  CMP $D9                                   ; $1EDAA8 |
  BEQ code_1EDAB4                           ; $1EDAAA |
code_1EDAAC:
  JSR submit_sound_ID_D9                    ; $1EDAAC |
  LDA #$FF                                  ; $1EDAAF |
  STA $0520                                 ; $1EDAB1 |
code_1EDAB4:
  LDA $0520                                 ; $1EDAB4 |
  BEQ code_1EDAC8                           ; $1EDAB7 |
  DEC $0520                                 ; $1EDAB9 |
  BNE code_1EDB2B                           ; $1EDABC |
  LDA $22                                   ; $1EDABE |
  CMP #$10                                  ; $1EDAC0 |
  BCC code_1EDAC8                           ; $1EDAC2 |
  LDA #$00                                  ; $1EDAC4 |
  STA $FD                                   ; $1EDAC6 |
code_1EDAC8:
  LDA $22                                   ; $1EDAC8 |
  CMP #$08                                  ; $1EDACA |
  BCC code_1EDAD1                           ; $1EDACC |
  JMP code_1EDB89                           ; $1EDACE |

code_1EDAD1:
  STY $00                                   ; $1EDAD1 |
  LDA $0360                                 ; $1EDAD3 |
  CMP #$80                                  ; $1EDAD6 |
  BEQ code_1EDB00                           ; $1EDAD8 |
  BCS code_1EDAEF                           ; $1EDADA |
  LDY #$00                                  ; $1EDADC |
  JSR move_right_collide                           ; $1EDADE |
  ROL $00                                   ; $1EDAE1 |
  LDA #$80                                  ; $1EDAE3 |
  CMP $0360                                 ; $1EDAE5 |
  BCS code_1EDB00                           ; $1EDAE8 |
  STA $0360                                 ; $1EDAEA |
  BCC code_1EDB00                           ; $1EDAED |
code_1EDAEF:
  LDY #$01                                  ; $1EDAEF |
  JSR move_left_collide                           ; $1EDAF1 |
  ROL $00                                   ; $1EDAF4 |
  LDA #$80                                  ; $1EDAF6 |
  CMP $0360                                 ; $1EDAF8 |
  BCC code_1EDB00                           ; $1EDAFB |
  STA $0360                                 ; $1EDAFD |
code_1EDB00:
  LDY #$00                                  ; $1EDB00 |
  LSR $0F                                   ; $1EDB02 |
  BCS code_1EDB07                           ; $1EDB04 |
  INY                                       ; $1EDB06 |
code_1EDB07:
  LDA $DC7F,y                               ; $1EDB07 |
  CMP $05C0                                 ; $1EDB0A |
  BEQ code_1EDB12                           ; $1EDB0D |
  JSR reset_sprite_anim                     ; $1EDB0F |
code_1EDB12:
  CPY #$01                                  ; $1EDB12 |
  BEQ code_1EDB88                           ; $1EDB14 |
  LSR $00                                   ; $1EDB16 |
  BCC code_1EDB88                           ; $1EDB18 |
  LDA $0360                                 ; $1EDB1A |
  CMP #$80                                  ; $1EDB1D |
  BEQ code_1EDB2C                           ; $1EDB1F |
  LDA #$E5                                  ; $1EDB21 |
  STA $0440                                 ; $1EDB23 |
  LDA #$04                                  ; $1EDB26 |
  STA $0460                                 ; $1EDB28 |
code_1EDB2B:
  RTS                                       ; $1EDB2B |

code_1EDB2C:
  LDA #$00                                  ; $1EDB2C |
  STA $0440                                 ; $1EDB2E |
  LDA #$08                                  ; $1EDB31 |
  STA $0460                                 ; $1EDB33 |
  INC $0500                                 ; $1EDB36 |
  RTS                                       ; $1EDB39 |

code_1EDB3A:
  LDY $0500                                 ; $1EDB3A |
  LDX $DD00,y                               ; $1EDB3D |
  LDY #$1F                                  ; $1EDB40 |
code_1EDB42:
  LDA #$5B                                  ; $1EDB42 |
  JSR init_child_entity                           ; $1EDB44 |
  LDA #$00                                  ; $1EDB47 |
  STA $0480,y                               ; $1EDB49 |
  LDA #$11                                  ; $1EDB4C |
  STA $0320,y                               ; $1EDB4E |
  LDA $DCE1,y                               ; $1EDB51 |
  STA $0360,y                               ; $1EDB54 |
  LDA $0380                                 ; $1EDB57 |
  STA $0380,y                               ; $1EDB5A |
  LDA $DCD1,y                               ; $1EDB5D |
  STA $03C0,y                               ; $1EDB60 |
  LDA $DC71,x                               ; $1EDB63 |
  STA $0400,y                               ; $1EDB66 |
  LDA $DC89,x                               ; $1EDB69 |
  STA $0420,y                               ; $1EDB6C |
  LDA $DCA1,x                               ; $1EDB6F |
  STA $0440,y                               ; $1EDB72 |
  LDA $DCB9,x                               ; $1EDB75 |
  STA $0460,y                               ; $1EDB78 |
  DEX                                       ; $1EDB7B |
  DEY                                       ; $1EDB7C |
  CPY #$0F                                  ; $1EDB7D |
  BNE code_1EDB42                           ; $1EDB7F |
  LDA #$32                                  ; $1EDB81 |
  JSR submit_sound_ID                       ; $1EDB83 |
  LDX #$00                                  ; $1EDB86 |
code_1EDB88:
  RTS                                       ; $1EDB88 |

code_1EDB89:
  LDA $22                                   ; $1EDB89 |
  CMP #$10                                  ; $1EDB8B |
  BCS code_1EDBB5                           ; $1EDB8D |
  CMP #$0C                                  ; $1EDB8F |
  BCS code_1EDBA6                           ; $1EDB91 |
  LDA $F9                                   ; $1EDB93 |
  CMP #$18                                  ; $1EDB95 |
  BCS code_1EDBA6                           ; $1EDB97 |
  LDA #$00                                  ; $1EDB99 |
  STA $30                                   ; $1EDB9B |
  LDY $22                                   ; $1EDB9D |
  LDA $CD0C,y                               ; $1EDB9F |
  JSR submit_sound_ID_D9                    ; $1EDBA2 |
  RTS                                       ; $1EDBA5 |

code_1EDBA6:
  LDA #$81                                  ; $1EDBA6 |
  STA $0300                                 ; $1EDBA8 |
  LDA #$00                                  ; $1EDBAB |
  STA $0500                                 ; $1EDBAD |
  LDA #$0D                                  ; $1EDBB0 |
  STA $30                                   ; $1EDBB2 |
  RTS                                       ; $1EDBB4 |

code_1EDBB5:
  LDA #$0F                                  ; $1EDBB5 |
  STA $0610                                 ; $1EDBB7 |
  STA $18                                   ; $1EDBBA |
  LDA #$00                                  ; $1EDBBC |
  STA $F8                                   ; $1EDBBE |
  STA $6A                                   ; $1EDBC0 |
  STA $6B                                   ; $1EDBC2 |
  STA $FD                                   ; $1EDBC4 |
  LDA $22                                   ; $1EDBC6 |
  CLC                                       ; $1EDBC8 |
  ADC #$04                                  ; $1EDBC9 |
  STA $30                                   ; $1EDBCB |
  LDA #$80                                  ; $1EDBCD |
  STA $0300                                 ; $1EDBCF |
  LDA #$00                                  ; $1EDBD2 |
  STA $0500                                 ; $1EDBD4 |
  STA $0520                                 ; $1EDBD7 |
  STA $0540                                 ; $1EDBDA |
  STA $0560                                 ; $1EDBDD |
  RTS                                       ; $1EDBE0 |

; player state $0D: teleport away, persists through menus [confirmed]
player_teleport:
  LDA $0300                                 ; $1EDBE1 |
  AND #$0F                                  ; $1EDBE4 |
  BNE code_1EDC0F                           ; $1EDBE6 |
  LDY #$00                                  ; $1EDBE8 |
  JSR move_vertical_gravity                           ; $1EDBEA |
  BCS code_1EDBFB                           ; $1EDBED |
  LDA $05A0                                 ; $1EDBEF |
  CMP #$04                                  ; $1EDBF2 |
  BNE code_1EDC0E                           ; $1EDBF4 |
  LDA #$07                                  ; $1EDBF6 |
  JMP reset_sprite_anim                     ; $1EDBF8 |

code_1EDBFB:
  INC $0300                                 ; $1EDBFB |
  STA $0440                                 ; $1EDBFE |
  STA $0460                                 ; $1EDC01 |
  LDA #$3C                                  ; $1EDC04 |
  STA $0500                                 ; $1EDC06 |
  LDA #$01                                  ; $1EDC09 |
  JSR reset_sprite_anim                     ; $1EDC0B |
code_1EDC0E:
  RTS                                       ; $1EDC0E |

code_1EDC0F:
  LDA $0500                                 ; $1EDC0F |
  BEQ code_1EDC18                           ; $1EDC12 |
  DEC $0500                                 ; $1EDC14 |
  RTS                                       ; $1EDC17 |

code_1EDC18:
  LDA #$13                                  ; $1EDC18 |
  CMP $05C0                                 ; $1EDC1A |
  BEQ code_1EDC2C                           ; $1EDC1D |
  JSR reset_sprite_anim                     ; $1EDC1F |
  LDA #$34                                  ; $1EDC22 |
  JSR submit_sound_ID                       ; $1EDC24 |
  LDA #$04                                  ; $1EDC27 |
  STA $05A0                                 ; $1EDC29 |
code_1EDC2C:
  LDA $05A0                                 ; $1EDC2C |
  CMP #$02                                  ; $1EDC2F |
  BNE code_1EDC73                           ; $1EDC31 |
  LDA #$00                                  ; $1EDC33 |
  STA $05E0                                 ; $1EDC35 |
  LDA $0440                                 ; $1EDC38 |
  CLC                                       ; $1EDC3B |
  ADC $99                                   ; $1EDC3C |
  STA $0440                                 ; $1EDC3E |
  LDA $0460                                 ; $1EDC41 |
  ADC #$00                                  ; $1EDC44 |
  STA $0460                                 ; $1EDC46 |
  JSR move_sprite_up                        ; $1EDC49 |
; --- boss defeat tracking ---
; called during teleport-away after boss explodes
; sets bit in $61 for defeated stage, awards special weapons
  LDA $03E0                                 ; $1EDC4C |\ if boss not defeated,
  BEQ code_1EDC73                           ; $1EDC4F |/ skip defeat tracking
  LDY $22                                   ; $1EDC51 |\ stage index
  CPY #$0C                                  ; $1EDC53 | | if stage >= $0C (Wily fortress),
  BCS .wily_stage_clear                     ; $1EDC55 |/ handle separately
  LDA $61                                   ; $1EDC57 |\ $61 |= (1 << stage_index)
  ORA $DEC2,y                               ; $1EDC59 | | mark this stage's boss as defeated
  STA $61                                   ; $1EDC5C |/ ($FF = all 8 Robot Masters beaten)
  INC $59                                   ; $1EDC5E |  advance stage progression
  LDA $22                                   ; $1EDC60 |\ stage $00 (Needle Man):
  CMP #$00                                  ; $1EDC62 | | awards Rush Jet
  BEQ .award_rush_jet                       ; $1EDC64 |/
  CMP #$07                                  ; $1EDC66 |\ stage $07 (Shadow Man):
  BNE code_1EDC73                           ; $1EDC68 |/ awards Rush Marine
  LDA #$9C                                  ; $1EDC6A |\ fill Rush Marine energy ($AB)
  STA $AB                                   ; $1EDC6C |/ $9C = full
  RTS                                       ; $1EDC6E |

.award_rush_jet:
  LDA #$9C                                  ; $1EDC6F |\ fill Rush Jet energy ($AD)
  STA $AD                                   ; $1EDC71 |/ $9C = full
code_1EDC73:
  RTS                                       ; $1EDC73 |

.wily_stage_clear:
  LDA #$FF                                  ; $1EDC74 |\ mark fortress stage cleared
  STA $74                                   ; $1EDC76 |/
  INC $75                                   ; $1EDC78 |  advance fortress progression
  LDA #$9C                                  ; $1EDC7A |\ refill player health
  STA $A2                                   ; $1EDC7C |/ $9C = full
  RTS                                       ; $1EDC7E |

  db $04, $07, $00, $C2, $00, $C2, $00, $3E ; $1EDC7F |
  db $00, $3E, $00, $E1, $00, $E1, $00, $1F ; $1EDC87 |
  db $00, $1F, $00, $F1, $80, $F1, $00, $0F ; $1EDC8F |
  db $80, $0F, $00, $FB, $FA, $FB, $00, $04 ; $1EDC97 |
  db $06, $04, $00, $FD, $FD, $FD, $00, $02 ; $1EDC9F |
  db $03, $02, $00, $FE, $FE, $FE, $00, $01 ; $1EDCA7 |
  db $01, $01, $00, $3E, $00, $C2, $00, $C2 ; $1EDCAF |
  db $00, $3E, $00, $1F, $00, $E1, $00, $E1 ; $1EDCB7 |
  db $00, $1F, $80, $0F, $00, $F1, $80, $F1 ; $1EDCBF |
  db $00, $0F, $06, $04, $00, $FB, $FA, $FB ; $1EDCC7 |
  db $00, $04, $03, $02, $00, $FD, $FD, $FD ; $1EDCCF |
  db $00, $02, $01, $01, $00, $FE, $FE, $FE ; $1EDCD7 |
  db $00, $01, $00, $23, $78, $C0, $F0, $CC ; $1EDCDF |
  db $78, $23, $00, $23, $78, $C0, $F0, $CC ; $1EDCE7 |
  db $78, $23, $80, $D4, $F8, $D4, $80, $2B ; $1EDCEF |
  db $08, $2B, $80, $D4, $F8, $D4, $80, $2B ; $1EDCF7 |
  db $08, $2B, $1F, $1F, $27, $02, $04, $01 ; $1EDCFF |
  db $03, $05, $00, $02, $04, $00, $00, $00 ; $1EDD07 |
  db $00, $00, $06, $06, $06                ; $1EDD0F |

; player state $10: vertical scroll transition between sections [confirmed]
player_screen_scroll:
  LDY #$00                                  ; $1EDD14 |
  JSR move_vertical_gravity                           ; $1EDD16 |
  BCC code_1EDD25                           ; $1EDD19 |
  LDA #$01                                  ; $1EDD1B |
  CMP $05C0                                 ; $1EDD1D |
  BEQ code_1EDD25                           ; $1EDD20 |
  JSR reset_sprite_anim                     ; $1EDD22 |
code_1EDD25:
  LDY #$26                                  ; $1EDD25 |
  CPY $52                                   ; $1EDD27 |
  BEQ code_1EDD38                           ; $1EDD29 |
  STY $52                                   ; $1EDD2B |
  LDY #$00                                  ; $1EDD2D |
  STY $A000                                 ; $1EDD2F |
  STY $70                                   ; $1EDD32 |
  STY $28                                   ; $1EDD34 |
  BEQ code_1EDD3C                           ; $1EDD36 |
code_1EDD38:
  LDY $70                                   ; $1EDD38 |
  BEQ code_1EDD52                           ; $1EDD3A |
code_1EDD3C:
  LDA #$11                                  ; $1EDD3C |
  STA $F5                                   ; $1EDD3E |
  JSR select_PRG_banks                      ; $1EDD40 |
  LDA #$04                                  ; $1EDD43 |
  JSR code_1FE8B4                           ; $1EDD45 |
  LDA #$04                                  ; $1EDD48 |
  STA $10                                   ; $1EDD4A |
  JSR fill_nametable_progressive                           ; $1EDD4C |
  LDX #$00                                  ; $1EDD4F |
  RTS                                       ; $1EDD51 |

code_1EDD52:
  LDY #$0F                                  ; $1EDD52 |
code_1EDD54:
  LDA $0308,y                               ; $1EDD54 |
  BMI code_1EDDA5                           ; $1EDD57 |
  DEY                                       ; $1EDD59 |
  BPL code_1EDD54                           ; $1EDD5A |
  LDA #$0B                                  ; $1EDD5C |
  CMP $F8                                   ; $1EDD5E |
  BEQ code_1EDD72                           ; $1EDD60 |
  STA $F8                                   ; $1EDD62 |
  LDA $FD                                   ; $1EDD64 |
  ORA #$01                                  ; $1EDD66 |
  STA $FD                                   ; $1EDD68 |
  LDA #$50                                  ; $1EDD6A |
  STA $FA                                   ; $1EDD6C |
  LDA #$52                                  ; $1EDD6E |
  STA $5E                                   ; $1EDD70 |
code_1EDD72:
  LDA $FA                                   ; $1EDD72 |
  SEC                                       ; $1EDD74 |
  SBC #$03                                  ; $1EDD75 |
  STA $FA                                   ; $1EDD77 |
  BCS code_1EDD81                           ; $1EDD79 |
  LDA #$00                                  ; $1EDD7B |
  STA $FA                                   ; $1EDD7D |
  STA $30                                   ; $1EDD7F |
code_1EDD81:
  LDY #$03                                  ; $1EDD81 |
code_1EDD83:
  LDA $DDA6,y                               ; $1EDD83 |
  SEC                                       ; $1EDD86 |
  SBC $FA                                   ; $1EDD87 |
  BCC code_1EDD96                           ; $1EDD89 |
  STA $03DC,y                               ; $1EDD8B |
  LDA $059C,y                               ; $1EDD8E |
  AND #$FB                                  ; $1EDD91 |
  STA $059C,y                               ; $1EDD93 |
code_1EDD96:
  DEY                                       ; $1EDD96 |
  BPL code_1EDD83                           ; $1EDD97 |
  LDA $30                                   ; $1EDD99 |
  BEQ code_1EDDA5                           ; $1EDD9B |
  LDA $059E                                 ; $1EDD9D |
  ORA #$04                                  ; $1EDDA0 |
  STA $059E                                 ; $1EDDA2 |
code_1EDDA5:
  RTS                                       ; $1EDDA5 |

  db $48, $3F, $3F, $3F                     ; $1EDDA6 |

; player state $11: teleporter tube area initialization [confirmed]
player_warp_init:
  LDA $05A0                                 ; $1EDDAA |
  CMP #$04                                  ; $1EDDAD |
  BNE code_1EDDA5                           ; $1EDDAF |
  LDY $6C                                   ; $1EDDB1 |
  LDA $DE5E,y                               ; $1EDDB3 |
  BPL code_1EDDC1                           ; $1EDDB6 |
  STA $74                                   ; $1EDDB8 |
  INC $75                                   ; $1EDDBA |
  LDA #$9C                                  ; $1EDDBC |
  STA $A2                                   ; $1EDDBE |
  RTS                                       ; $1EDDC0 |

code_1EDDC1:
  LDA #$00                                  ; $1EDDC1 |
  STA $EE                                   ; $1EDDC3 |
  JSR code_1EC752                           ; $1EDDC5 |
  LDA #$04                                  ; $1EDDC8 |
  STA $97                                   ; $1EDDCA |
  JSR code_1EC5E9                           ; $1EDDCC |
  JSR task_yield                           ; $1EDDCF |
  JSR code_1EC628                           ; $1EDDD2 |
  LDA #$01                                  ; $1EDDD5 |
  STA $F5                                   ; $1EDDD7 |
  JSR select_PRG_banks                      ; $1EDDD9 |
  LDY $6C                                   ; $1EDDDC |
  BNE code_1EDDE2                           ; $1EDDDE |
  STY $6E                                   ; $1EDDE0 |
code_1EDDE2:
  LDA $DE5E,y                               ; $1EDDE2 |
  STA $F9                                   ; $1EDDE5 |
  STA $0380                                 ; $1EDDE7 |
  STA $2B                                   ; $1EDDEA |
  STA $29                                   ; $1EDDEC |
  LDA #$20                                  ; $1EDDEE |
  STA $2A                                   ; $1EDDF0 |
  LDA $DE72,y                               ; $1EDDF2 |
  STA $0360                                 ; $1EDDF5 |
  LDA $DE86,y                               ; $1EDDF8 |
  STA $03C0                                 ; $1EDDFB |
  LDA $DE9A,y                               ; $1EDDFE |
  STA $9E                                   ; $1EDE01 |
  STA $9F                                   ; $1EDE03 |
  LDA $DEAE,y                               ; $1EDE05 |
  JSR $A000                                 ; $1EDE08 |
  JSR update_CHR_banks                      ; $1EDE0B |
  LDA #$01                                  ; $1EDE0E |
  STA $31                                   ; $1EDE10 |
  STA $23                                   ; $1EDE12 |
  STA $2E                                   ; $1EDE14 |
  DEC $29                                   ; $1EDE16 |
  LDA #$1F                                  ; $1EDE18 |
  STA $24                                   ; $1EDE1A |
  LDA #$21                                  ; $1EDE1C |
code_1EDE1E:
  PHA                                       ; $1EDE1E |
  LDA #$01                                  ; $1EDE1F |
  STA $10                                   ; $1EDE21 |
  JSR code_1FE4F1                           ; $1EDE23 |
  JSR task_yield                           ; $1EDE26 |
  PLA                                       ; $1EDE29 |
  SEC                                       ; $1EDE2A |
  SBC #$01                                  ; $1EDE2B |
  BNE code_1EDE1E                           ; $1EDE2D |
  STA $2C                                   ; $1EDE2F |
  STA $2D                                   ; $1EDE31 |
  STA $5A                                   ; $1EDE33 |
  LDA $F9                                   ; $1EDE35 |
  CMP #$08                                  ; $1EDE37 |
  BNE code_1EDE40                           ; $1EDE39 |
  LDA #$0A                                  ; $1EDE3B |
  JSR submit_sound_ID_D9                    ; $1EDE3D |
code_1EDE40:
  JSR task_yield                           ; $1EDE40 |
  JSR code_1EC74C                           ; $1EDE43 |
  LDX #$00                                  ; $1EDE46 |
  LDA #$13                                  ; $1EDE48 |
  JSR reset_sprite_anim                     ; $1EDE4A |
  LDA #$12                                  ; $1EDE4D |
  STA $30                                   ; $1EDE4F |
  RTS                                       ; $1EDE51 |

; player state $12: wait for warp animation, return to $00 [confirmed]
player_warp_anim:
  LDA $05A0                                 ; $1EDE52 |
  CMP #$04                                  ; $1EDE55 |
  BNE code_1EDE5D                           ; $1EDE57 |
  LDA #$00                                  ; $1EDE59 |
  STA $30                                   ; $1EDE5B |
code_1EDE5D:
  RTS                                       ; $1EDE5D |

  db $07, $00, $FF, $0A, $0C, $0E, $10, $12 ; $1EDE5E |
  db $14, $16, $18, $00, $08, $08, $08, $08 ; $1EDE66 |
  db $08, $08, $08, $08, $30, $00, $00, $20 ; $1EDE6E |
  db $20, $20, $20, $20, $20, $20, $20, $00 ; $1EDE76 |
  db $30, $30, $30, $70, $90, $D0, $D0, $D0 ; $1EDE7E |
  db $B0, $00, $00, $C0, $B0, $B0, $B0, $B0 ; $1EDE86 |
  db $B0, $A0, $B0, $00, $2C, $6C, $AC, $AC ; $1EDE8E |
  db $AC, $2C, $6C, $AC, $10, $10, $00, $1B ; $1EDE96 |
  db $1C, $1D, $1E, $1F, $20, $21, $22, $00 ; $1EDE9E |
  db $11, $11, $11, $11, $11, $11, $11, $11 ; $1EDEA6 |
  db $02, $02, $00, $25, $23, $27, $24, $2A ; $1EDEAE |
  db $26, $28, $29, $00, $02, $02, $02, $02 ; $1EDEB6 |
  db $02, $02, $02, $02                     ; $1EDEBE |

; boss_defeated_bitmask: indexed by stage ($22), sets bit in $61
; $00=Needle $01=Magnet $02=Gemini $03=Hard $04=Top $05=Snake $06=Spark $07=Shadow
  db $01, $02, $04, $08, $10, $20, $40, $80 ; $1EDEC2 |

; Doc Robot stage bitmask (4 stages: Needle=$08, Gemini=$09, Spark=$0A, Shadow=$0B)
  db $01, $04, $40, $80                     ; $1EDECA |

decrease_ammo:
  LDA $A0                                   ; $1EDECE |\
  CMP #$06                                  ; $1EDED0 | | if current weapon < 6
  BCC .check_frames                         ; $1EDED2 | | or is even
  AND #$01                                  ; $1EDED4 | | excludes Rush weapons
  BNE .ret                                  ; $1EDED6 |/
.check_frames:
  LDY $A0                                   ; $1EDED8 |\  increment number of frames/shots
  INC $B5                                   ; $1EDEDA | | for current weapon, if it has
  LDA $B5                                   ; $1EDEDC | | not yet reached the ammo decrease
  CMP weapon_framerate,y                    ; $1EDEDE | | threshold, return
  BNE .ret                                  ; $1EDEE1 |/
  LDA #$00                                  ; $1EDEE3 |\ upon reaching threshold, reset
  STA $B5                                   ; $1EDEE5 |/ frame/shot counter
  LDA $00A2,y                               ; $1EDEE7 |\
  AND #$1F                                  ; $1EDEEA | | fetch ammo value to decrease by
  SEC                                       ; $1EDEEC | | and decrease ammo
  SBC weapon_cost,y                         ; $1EDEED |/
  BCS .store_ammo                           ; $1EDEF0 |\ clamp to minimum zero
  LDA #$00                                  ; $1EDEF2 |/ (no negatives)
.store_ammo:
  ORA #$80                                  ; $1EDEF4 |\  flag "own weapon" back on
  STA $00A2,y                               ; $1EDEF6 | | store new ammo value
  CMP #$80                                  ; $1EDEF9 | | if not zero, return
  BNE .ret                                  ; $1EDEFB |/
; ammo has been depleted, clean up rush
  CPY #$0B                                  ; $1EDEFD |\ are we rush jet? disable him
  BEQ .disable_rush                         ; $1EDEFF |/
  CPY #$09                                  ; $1EDF01 |\ if we're rush marine
  BNE .ret                                  ; $1EDF03 |/ there's more to do:
  LDA #$02                                  ; $1EDF05 |\
  STA $EB                                   ; $1EDF07 | |
  JSR update_CHR_banks                      ; $1EDF09 | | reset mega man graphics,
  LDA #$01                                  ; $1EDF0C | | animation, ID & state
  JSR reset_sprite_anim                     ; $1EDF0E | |
  LDA #$00                                  ; $1EDF11 | |
  STA $30                                   ; $1EDF13 |/
.disable_rush:
  LDA #$00                                  ; $1EDF15 |\ set rush sprite to inactive
  STA $0301                                 ; $1EDF17 |/
.ret:
  RTS                                       ; $1EDF1A |

; how much ammo each weapon costs upon use
weapon_cost:
  db $00                                    ; $1EDF1B | Mega Buster
  db $02                                    ; $1EDF1C | Gemini Laser
  db $01                                    ; $1EDF1D | Needle Cannon
  db $02                                    ; $1EDF1E | Hard Knuckle
  db $02                                    ; $1EDF1F | Magnet Missile
  db $00                                    ; $1EDF20 | Top Spin
  db $01                                    ; $1EDF21 | Search Snake
  db $03                                    ; $1EDF22 | Rush Coil
  db $01                                    ; $1EDF23 | Spark Shock
  db $01                                    ; $1EDF24 | Rush Marine
  db $01                                    ; $1EDF25 | Shadow Blade
  db $01                                    ; $1EDF26 | Rush Jet

; the rate or number of frames of use before decreasing
; most weapons are 1 shot == 1 frame
; jet & marine count while using them
weapon_framerate:
  db $00                                    ; $1EDF27 | Mega Buster
  db $01                                    ; $1EDF28 | Gemini Laser
  db $04                                    ; $1EDF29 | Needle Cannon
  db $01                                    ; $1EDF2A | Hard Knuckle
  db $01                                    ; $1EDF2B | Magnet Missile
  db $00                                    ; $1EDF2C | Top Spin
  db $02                                    ; $1EDF2D | Search Snake
  db $01                                    ; $1EDF2E | Rush Coil
  db $01                                    ; $1EDF2F | Spark Shock
  db $1E                                    ; $1EDF30 | Rush Marine
  db $02                                    ; $1EDF31 | Shadow Blade
  db $1E                                    ; $1EDF32 | Rush Jet

; player state $13: teleport beam landing w/ gravity [unconfirmed]
player_teleport_beam:
  LDA $05C0                                 ; $1EDF33 |
  CMP #$13                                  ; $1EDF36 |
  BEQ code_1EDF51                           ; $1EDF38 |
  LDY #$00                                  ; $1EDF3A |
  JSR move_vertical_gravity                           ; $1EDF3C |
  BCC code_1EDF89                           ; $1EDF3F |
  LDA #$13                                  ; $1EDF41 |
  JSR reset_sprite_anim                     ; $1EDF43 |
  INC $05A0                                 ; $1EDF46 |
  LDA #$00                                  ; $1EDF49 |
  STA $0440                                 ; $1EDF4B |
  STA $0460                                 ; $1EDF4E |
code_1EDF51:
  LDA $05A0                                 ; $1EDF51 |
  BNE code_1EDF89                           ; $1EDF54 |
  STA $05E0                                 ; $1EDF56 |
  JSR move_sprite_up                        ; $1EDF59 |
  LDA $03E0                                 ; $1EDF5C |
  BNE code_1EDF73                           ; $1EDF5F |
  LDA $0440                                 ; $1EDF61 |
  CLC                                       ; $1EDF64 |
  ADC $99                                   ; $1EDF65 |
  STA $0440                                 ; $1EDF67 |
  LDA $0460                                 ; $1EDF6A |
  ADC #$00                                  ; $1EDF6D |
  STA $0460                                 ; $1EDF6F |
  RTS                                       ; $1EDF72 |

code_1EDF73:
  LDA #$00                                  ; $1EDF73 |
  STA $30                                   ; $1EDF75 |
  LDA #$80                                  ; $1EDF77 |
  STA $74                                   ; $1EDF79 |
  LDA #$FF                                  ; $1EDF7B |
  STA $60                                   ; $1EDF7D |
  LDY #$0B                                  ; $1EDF7F |
  LDA #$9C                                  ; $1EDF81 |
code_1EDF83:
  STA $00A2,y                               ; $1EDF83 |
  DEY                                       ; $1EDF86 |
  BPL code_1EDF83                           ; $1EDF87 |
code_1EDF89:
  RTS                                       ; $1EDF89 |

; player state $14: scripted walk to X=$50 (post-Wily cutscene) [confirmed]
player_auto_walk:
  LDY #$00                                  ; $1EDF8A |
  JSR move_vertical_gravity                           ; $1EDF8C |
  PHP                                       ; $1EDF8F |
  ROR $0F                                   ; $1EDF90 |
  PLP                                       ; $1EDF92 |
  BCS code_1EDFA2                           ; $1EDF93 |
  LDA #$07                                  ; $1EDF95 |
  CMP $05C0                                 ; $1EDF97 |
  BEQ code_1EDFAC                           ; $1EDF9A |
  JSR reset_sprite_anim                     ; $1EDF9C |
  JMP code_1EDFAC                           ; $1EDF9F |

code_1EDFA2:
  LDA #$04                                  ; $1EDFA2 |
  CMP $05C0                                 ; $1EDFA4 |
  BEQ code_1EDFAC                           ; $1EDFA7 |
  JSR reset_sprite_anim                     ; $1EDFA9 |
code_1EDFAC:
  LDA $0300                                 ; $1EDFAC |
  AND #$0F                                  ; $1EDFAF |
  BNE code_1FE015                           ; $1EDFB1 |
  LDA $0360                                 ; $1EDFB3 |
  CMP #$50                                  ; $1EDFB6 |
  BEQ code_1FE015                           ; $1EDFB8 |
  BCS code_1EDFC2                           ; $1EDFBA |
  INC $0360                                 ; $1EDFBC |
  JMP code_1EDFC5                           ; $1EDFBF |

code_1EDFC2:
  DEC $0360                                 ; $1EDFC2 |
code_1EDFC5:
  LDA $0360                                 ; $1EDFC5 |
  CMP #$50                                  ; $1EDFC8 |
  BNE code_1FE022                           ; $1EDFCA |
  LDA $031F                                 ; $1EDFCC |
  BMI code_1FE015                           ; $1EDFCF |
  LDA #$80                                  ; $1EDFD1 |
  STA $031F                                 ; $1EDFD3 |
  LDA #$90                                  ; $1EDFD6 |
  STA $059F                                 ; $1EDFD8 |
  LDA #$6D                                  ; $1EDFDB |
  STA $05DF                                 ; $1EDFDD |
  LDA #$00                                  ; $1EDFE0 |
  STA $05FF                                 ; $1EDFE2 |
  STA $05BF                                 ; $1EDFE5 |
  STA $03FF                                 ; $1EDFE8 |
  STA $03DF                                 ; $1EDFEB |
  STA $0520                                 ; $1EDFEE |
  LDA $F9                                   ; $1EDFF1 |
  STA $039F                                 ; $1EDFF3 |
  LDA #$C0                                  ; $1EDFF6 |
  STA $037F                                 ; $1EDFF8 |
  LDA #$EE                                  ; $1EDFFB |
  STA $033F                                 ; $1EDFFD |

bank $1F
org $E000

code_1FE000:
  LDA #$5A                                  ; $1FE000 |
  STA $0500                                 ; $1FE002 |
  LDA $0580                                 ; $1FE005 |
  ORA #$40                                  ; $1FE008 |
  STA $0580                                 ; $1FE00A |
  LDA #$78                                  ; $1FE00D |
  STA $0500                                 ; $1FE00F |
  INC $0300                                 ; $1FE012 |

code_1FE015:
  LDA $0500                                 ; $1FE015 |
  BEQ code_1FE023                           ; $1FE018 |
  DEC $0500                                 ; $1FE01A |
  LDA #$01                                  ; $1FE01D |
  JSR reset_sprite_anim                     ; $1FE01F |

code_1FE022:
  RTS                                       ; $1FE022 |

code_1FE023:
  LDA $0300                                 ; $1FE023 |
  AND #$0F                                  ; $1FE026 |
  CMP #$02                                  ; $1FE028 |
  BEQ code_1FE068                           ; $1FE02A |
  LDA $0360                                 ; $1FE02C |
  CMP #$A0                                  ; $1FE02F |
  BEQ code_1FE05A                           ; $1FE031 |
  LDA #$04                                  ; $1FE033 |
  CMP $05C0                                 ; $1FE035 |
  BEQ code_1FE03D                           ; $1FE038 |
  JSR reset_sprite_anim                     ; $1FE03A |
code_1FE03D:
  INC $0360                                 ; $1FE03D |
  LDA $0360                                 ; $1FE040 |
  CMP #$A0                                  ; $1FE043 |
  BNE code_1FE08B                           ; $1FE045 |
  LDA #$6E                                  ; $1FE047 |
  STA $05DF                                 ; $1FE049 |
  LDA #$00                                  ; $1FE04C |
  STA $05FF                                 ; $1FE04E |
  STA $05BF                                 ; $1FE051 |
  LDA #$3C                                  ; $1FE054 |
  STA $0500                                 ; $1FE056 |
  RTS                                       ; $1FE059 |

code_1FE05A:
  LDA #$E5                                  ; $1FE05A |
  STA $0440                                 ; $1FE05C |
  LDA #$04                                  ; $1FE05F |
  STA $0460                                 ; $1FE061 |
  INC $0300                                 ; $1FE064 |
  RTS                                       ; $1FE067 |

code_1FE068:
  LDA $0F                                   ; $1FE068 |
  BPL code_1FE079                           ; $1FE06A |
  LDA $0520                                 ; $1FE06C |
  BNE code_1FE07D                           ; $1FE06F |
  INC $0520                                 ; $1FE071 |
  LDA #$78                                  ; $1FE074 |
  STA $0500                                 ; $1FE076 |
code_1FE079:
  DEC $0360                                 ; $1FE079 |
  RTS                                       ; $1FE07C |

code_1FE07D:
  LDA #$81                                  ; $1FE07D |
  STA $0300                                 ; $1FE07F |
  LDA #$00                                  ; $1FE082 |
  STA $0500                                 ; $1FE084 |
  LDA #$0D                                  ; $1FE087 |
  STA $30                                   ; $1FE089 |
code_1FE08B:
  RTS                                       ; $1FE08B |

; player state $15: scripted walk to X=$68, ending cutscene [confirmed]
player_auto_walk_2:
  LDY #$00                                  ; $1FE08C |
  JSR move_vertical_gravity                           ; $1FE08E |
  BCS code_1FE097                           ; $1FE091 |
  LDA #$07                                  ; $1FE093 |
  BNE code_1FE099                           ; $1FE095 |
code_1FE097:
  LDA #$04                                  ; $1FE097 |
code_1FE099:
  CMP $05C0                                 ; $1FE099 |
  BEQ code_1FE0A1                           ; $1FE09C |
  JSR reset_sprite_anim                     ; $1FE09E |
code_1FE0A1:
  LDA $0360                                 ; $1FE0A1 |
  CMP #$68                                  ; $1FE0A4 |
  BEQ code_1FE0B2                           ; $1FE0A6 |
  BCS code_1FE0AE                           ; $1FE0A8 |
  INC $0360                                 ; $1FE0AA |
  RTS                                       ; $1FE0AD |

code_1FE0AE:
  DEC $0360                                 ; $1FE0AE |
  RTS                                       ; $1FE0B1 |

code_1FE0B2:
  LDA #$01                                  ; $1FE0B2 |
  CMP $05C0                                 ; $1FE0B4 |
  BEQ code_1FE0BC                           ; $1FE0B7 |
  JSR reset_sprite_anim                     ; $1FE0B9 |
code_1FE0BC:
  INC $0500                                 ; $1FE0BC |
  BNE code_1FE119                           ; $1FE0BF |
  LDA #$C0                                  ; $1FE0C1 |
  STA $0500                                 ; $1FE0C3 |
  LDA $0520                                 ; $1FE0C6 |
  CMP #$04                                  ; $1FE0C9 |
  BEQ code_1FE119                           ; $1FE0CB |
  JSR find_enemy_freeslot_y                 ; $1FE0CD |
  BCS code_1FE119                           ; $1FE0D0 |
  LDA #$80                                  ; $1FE0D2 |
  STA $0300,y                               ; $1FE0D4 |
  LDA #$90                                  ; $1FE0D7 |
  STA $0580,y                               ; $1FE0D9 |
  LDA #$00                                  ; $1FE0DC |
  STA $03C0,y                               ; $1FE0DE |
  STA $03E0,y                               ; $1FE0E1 |
  STA $05E0,y                               ; $1FE0E4 |
  STA $05A0,y                               ; $1FE0E7 |
  STA $0480,y                               ; $1FE0EA |
  STA $0440,y                               ; $1FE0ED |
  STA $0460,y                               ; $1FE0F0 |
  LDA #$7C                                  ; $1FE0F3 |
  STA $05C0,y                               ; $1FE0F5 |
  LDA #$F9                                  ; $1FE0F8 |
  STA $0320,y                               ; $1FE0FA |
  LDA #$C4                                  ; $1FE0FD |
  STA $0520,y                               ; $1FE0FF |
  LDA $0520                                 ; $1FE102 |
  STA $0500,y                               ; $1FE105 |
  TAX                                       ; $1FE108 |
  INC $0520                                 ; $1FE109 |
  LDA $E166,x                               ; $1FE10C |
  STA $0360,y                               ; $1FE10F |
  LDA $F9                                   ; $1FE112 |
  STA $0380,y                               ; $1FE114 |
  LDX #$00                                  ; $1FE117 |
code_1FE119:
  RTS                                       ; $1FE119 |

code_1FE11A:
  LDA #$80                                  ; $1FE11A |
  STA $030E                                 ; $1FE11C |
  LDA #$90                                  ; $1FE11F |
  STA $058E                                 ; $1FE121 |
  LDA #$EB                                  ; $1FE124 |
  STA $032E                                 ; $1FE126 |
  LDA #$67                                  ; $1FE129 |
  STA $05CE                                 ; $1FE12B |
  LDA #$00                                  ; $1FE12E |
  STA $05EE                                 ; $1FE130 |
  STA $05AE                                 ; $1FE133 |
  STA $03EE                                 ; $1FE136 |
  STA $B3                                   ; $1FE139 |
  LDA $F9                                   ; $1FE13B |
  STA $038E                                 ; $1FE13D |
  LDY $6C                                   ; $1FE140 |
  LDA $DE72,y                               ; $1FE142 |
  STA $036E                                 ; $1FE145 |
  LDA $DE86,y                               ; $1FE148 |
  AND #$F0                                  ; $1FE14B |
  STA $03CE                                 ; $1FE14D |
  LDA $6C                                   ; $1FE150 |
  CLC                                       ; $1FE152 |
  ADC #$18                                  ; $1FE153 |
  STA $04CE                                 ; $1FE155 |
  LDA $DEBF,y                               ; $1FE158 |
  ORA $6E                                   ; $1FE15B |
  STA $6E                                   ; $1FE15D |
  LDA #$0C                                  ; $1FE15F |
  STA $EC                                   ; $1FE161 |
  JMP update_CHR_banks                      ; $1FE163 |

  db $E0, $30, $B0, $68                     ; $1FE166 |

code_1FE16A:
  LDA $2A                                   ; $1FE16A |
  AND #$20                                  ; $1FE16C |
  BNE code_1FE173                           ; $1FE16E |
  JMP code_1FE228                           ; $1FE170 |

code_1FE173:
  LDA #$01                                  ; $1FE173 |
  STA $10                                   ; $1FE175 |
  STA $2E                                   ; $1FE177 |
  LDA $0360                                 ; $1FE179 |
  SEC                                       ; $1FE17C |
  SBC $FC                                   ; $1FE17D |
  STA $00                                   ; $1FE17F |
  SEC                                       ; $1FE181 |
  SBC #$80                                  ; $1FE182 |
  BCS code_1FE18A                           ; $1FE184 |
  EOR #$FF                                  ; $1FE186 |
  ADC #$01                                  ; $1FE188 |
code_1FE18A:
  STA $01                                   ; $1FE18A |
  LDA $0360                                 ; $1FE18C |
  SEC                                       ; $1FE18F |
  SBC $27                                   ; $1FE190 |
  STA $02                                   ; $1FE192 |
  BPL code_1FE1E1                           ; $1FE194 |
  EOR #$FF                                  ; $1FE196 |
  CLC                                       ; $1FE198 |
  ADC #$01                                  ; $1FE199 |
  STA $02                                   ; $1FE19B |
  LDA $01                                   ; $1FE19D |
  CMP #$09                                  ; $1FE19F |
  BCC code_1FE1A7                           ; $1FE1A1 |
  LDA $02                                   ; $1FE1A3 |
  STA $01                                   ; $1FE1A5 |
code_1FE1A7:
  LDA #$08                                  ; $1FE1A7 |
  CMP $01                                   ; $1FE1A9 |
  BCS code_1FE1AF                           ; $1FE1AB |
  STA $01                                   ; $1FE1AD |
code_1FE1AF:
  LDA #$02                                  ; $1FE1AF |
  STA $10                                   ; $1FE1B1 |
  STA $2E                                   ; $1FE1B3 |
  LDA $00                                   ; $1FE1B5 |
  CMP #$80                                  ; $1FE1B7 |
  BCS code_1FE228                           ; $1FE1B9 |
  LDA $FC                                   ; $1FE1BB |
  SEC                                       ; $1FE1BD |
  SBC $01                                   ; $1FE1BE |
  STA $FC                                   ; $1FE1C0 |
  BCS code_1FE224                           ; $1FE1C2 |
  LDA $2D                                   ; $1FE1C4 |
  DEC $2D                                   ; $1FE1C6 |
  BPL code_1FE1DC                           ; $1FE1C8 |
  STA $2D                                   ; $1FE1CA |
  LDA #$00                                  ; $1FE1CC |
  STA $FC                                   ; $1FE1CE |
  LDA #$10                                  ; $1FE1D0 |
  CMP $0360                                 ; $1FE1D2 |
  BCC code_1FE228                           ; $1FE1D5 |
  STA $0360                                 ; $1FE1D7 |
  BCS code_1FE228                           ; $1FE1DA |
code_1FE1DC:
  DEC $F9                                   ; $1FE1DC |
  JMP code_1FE224                           ; $1FE1DE |

code_1FE1E1:
  LDA $00                                   ; $1FE1E1 |
  CMP #$81                                  ; $1FE1E3 |
  BCC code_1FE228                           ; $1FE1E5 |
  LDA $2D                                   ; $1FE1E7 |
  CMP $2C                                   ; $1FE1E9 |
  BEQ code_1FE228                           ; $1FE1EB |
  LDA $01                                   ; $1FE1ED |
  CMP #$09                                  ; $1FE1EF |
  BCC code_1FE1F7                           ; $1FE1F1 |
  LDA $02                                   ; $1FE1F3 |
  STA $01                                   ; $1FE1F5 |
code_1FE1F7:
  LDA #$08                                  ; $1FE1F7 |
  CMP $01                                   ; $1FE1F9 |
  BCS code_1FE1FF                           ; $1FE1FB |
  STA $01                                   ; $1FE1FD |
code_1FE1FF:
  LDA $01                                   ; $1FE1FF |
  BEQ code_1FE228                           ; $1FE201 |
  LDA $FC                                   ; $1FE203 |
  CLC                                       ; $1FE205 |
  ADC $01                                   ; $1FE206 |
  STA $FC                                   ; $1FE208 |
  BCC code_1FE224                           ; $1FE20A |
  INC $2D                                   ; $1FE20C |
  LDA $2D                                   ; $1FE20E |
  CMP $2C                                   ; $1FE210 |
  BNE code_1FE222                           ; $1FE212 |
  LDA #$00                                  ; $1FE214 |
  STA $FC                                   ; $1FE216 |
  LDA #$F0                                  ; $1FE218 |
  CMP $0360                                 ; $1FE21A |
  BCS code_1FE222                           ; $1FE21D |
  STA $0360                                 ; $1FE21F |
code_1FE222:
  INC $F9                                   ; $1FE222 |
code_1FE224:
  JMP code_1FE467                           ; $1FE224 |

code_1FE227:
  RTS                                       ; $1FE227 |

code_1FE228:
  LDA $FC                                   ; $1FE228 |
  BNE code_1FE227                           ; $1FE22A |
  LDA $0360                                 ; $1FE22C |
  CMP #$10                                  ; $1FE22F |
  BCS code_1FE23D                           ; $1FE231 |
  LDA #$10                                  ; $1FE233 |
  STA $0360                                 ; $1FE235 |
  BEQ code_1FE23D                           ; $1FE238 |
code_1FE23A:
  JMP code_1FE33C                           ; $1FE23A |

code_1FE23D:
  CMP #$E5                                  ; $1FE23D |
  BCC code_1FE23A                           ; $1FE23F |
  CMP #$F0                                  ; $1FE241 |
  BCC code_1FE24A                           ; $1FE243 |
  LDA #$F0                                  ; $1FE245 |
  STA $0360                                 ; $1FE247 |
code_1FE24A:
  LDY $2B                                   ; $1FE24A |
  LDA $AA40,y                               ; $1FE24C |
  AND #$20                                  ; $1FE24F |
  BEQ code_1FE23A                           ; $1FE251 |
  LDA $AA41,y                               ; $1FE253 |
  AND #$C0                                  ; $1FE256 |
  BNE code_1FE23A                           ; $1FE258 |
  LDA $AA41,y                               ; $1FE25A |
  AND #$20                                  ; $1FE25D |
  BEQ code_1FE23A                           ; $1FE25F |
  STA $00                                   ; $1FE261 |
  LDA $22                                   ; $1FE263 |
  CMP #$08                                  ; $1FE265 |
  BNE code_1FE27A                           ; $1FE267 |
  LDA $F9                                   ; $1FE269 |
  CMP #$15                                  ; $1FE26B |
  BEQ code_1FE273                           ; $1FE26D |
  CMP #$1A                                  ; $1FE26F |
  BNE code_1FE27A                           ; $1FE271 |
code_1FE273:
  LDA $033F                                 ; $1FE273 |
  CMP #$FC                                  ; $1FE276 |
  BEQ code_1FE23A                           ; $1FE278 |
code_1FE27A:
  LDA $F9                                   ; $1FE27A |
  SEC                                       ; $1FE27C |
  SBC $AA30                                 ; $1FE27D |
  CMP #$02                                  ; $1FE280 |
  BNE code_1FE28F                           ; $1FE282 |
  LDA $031F                                 ; $1FE284 |
  BMI code_1FE23A                           ; $1FE287 |
  LDA $30                                   ; $1FE289 |
  CMP #$0C                                  ; $1FE28B |
  BCS code_1FE23A                           ; $1FE28D |
code_1FE28F:
  LDA $22                                   ; $1FE28F |
  CMP #$0F                                  ; $1FE291 |
  BNE code_1FE2A5                           ; $1FE293 |
  LDA $F9                                   ; $1FE295 |
  CMP #$08                                  ; $1FE297 |
  BNE code_1FE2A5                           ; $1FE299 |
  LDX #$0F                                  ; $1FE29B |
code_1FE29D:
  LDA $0310,x                               ; $1FE29D |
  BMI code_1FE23A                           ; $1FE2A0 |
  DEX                                       ; $1FE2A2 |
  BPL code_1FE29D                           ; $1FE2A3 |
code_1FE2A5:
  LDA $00                                   ; $1FE2A5 |
  STA $2A                                   ; $1FE2A7 |
  LDA $AA41,y                               ; $1FE2A9 |
  AND #$1F                                  ; $1FE2AC |
  STA $2C                                   ; $1FE2AE |
  LDA #$00                                  ; $1FE2B0 |
  STA $2D                                   ; $1FE2B2 |
  INC $2B                                   ; $1FE2B4 |
  LDY $F8                                   ; $1FE2B6 |
  LDA #$00                                  ; $1FE2B8 |
  STA $F8                                   ; $1FE2BA |
  STA $76                                   ; $1FE2BC |
  STA $B3                                   ; $1FE2BE |
  STA $5A                                   ; $1FE2C0 |
  LDA #$E8                                  ; $1FE2C2 |
  STA $5E                                   ; $1FE2C4 |
  CPY #$02                                  ; $1FE2C6 |
  BNE code_1FE2D5                           ; $1FE2C8 |
  LDA #$42                                  ; $1FE2CA |
  STA $E9                                   ; $1FE2CC |
  LDA #$09                                  ; $1FE2CE |
  STA $29                                   ; $1FE2D0 |
  JSR code_1EC83D                           ; $1FE2D2 |
code_1FE2D5:
  LDA $F9                                   ; $1FE2D5 |
  SEC                                       ; $1FE2D7 |
  SBC $AA30                                 ; $1FE2D8 |
  BCC code_1FE2F7                           ; $1FE2DB |
  CMP #$03                                  ; $1FE2DD |
  BCS code_1FE2E8                           ; $1FE2DF |
  TAX                                       ; $1FE2E1 |
  LDY $AA31,x                               ; $1FE2E2 |
  JMP code_1FE2F4                           ; $1FE2E5 |

code_1FE2E8:
  LDA $F9                                   ; $1FE2E8 |
  SEC                                       ; $1FE2EA |
  SBC $AA38                                 ; $1FE2EB |
  BCC code_1FE2F7                           ; $1FE2EE |
  TAX                                       ; $1FE2F0 |
  LDY $AA39,x                               ; $1FE2F1 |
code_1FE2F4:
  JSR call_bank10_8000                      ; $1FE2F4 |
code_1FE2F7:
  LDA $22                                   ; $1FE2F7 |
  BNE code_1FE308                           ; $1FE2F9 |
  LDX #$03                                  ; $1FE2FB |
code_1FE2FD:
  LDA $AAA2,x                               ; $1FE2FD |
  STA $060C,x                               ; $1FE300 |
  DEX                                       ; $1FE303 |
  BPL code_1FE2FD                           ; $1FE304 |
  STX $18                                   ; $1FE306 |
code_1FE308:
  LDA #$E4                                  ; $1FE308 |
  STA $0360                                 ; $1FE30A |
  JSR code_1FE5D1                           ; $1FE30D |
  LDA $22                                   ; $1FE310 |
  STA $F5                                   ; $1FE312 |
  JSR select_PRG_banks                      ; $1FE314 |
  LDA $F9                                   ; $1FE317 |
  SEC                                       ; $1FE319 |
  SBC $AA30                                 ; $1FE31A |
  BCC code_1FE33B                           ; $1FE31D |
  CMP #$05                                  ; $1FE31F |
  BCS code_1FE32A                           ; $1FE321 |
  TAX                                       ; $1FE323 |
  LDY $AA30,x                               ; $1FE324 |
  JMP code_1FE338                           ; $1FE327 |

code_1FE32A:
  LDA $F9                                   ; $1FE32A |
  SEC                                       ; $1FE32C |
  SBC $AA38                                 ; $1FE32D |
  BCC code_1FE33B                           ; $1FE330 |
  BEQ code_1FE33B                           ; $1FE332 |
  TAX                                       ; $1FE334 |
  LDY $AA38,x                               ; $1FE335 |
code_1FE338:
  JSR call_bank10_8003                      ; $1FE338 |
code_1FE33B:
  RTS                                       ; $1FE33B |

code_1FE33C:
  LDA $03C0                                 ; $1FE33C |
  CMP #$E8                                  ; $1FE33F |
  BCS code_1FE35E                           ; $1FE341 |
  CMP #$09                                  ; $1FE343 |
  BCS code_1FE33B                           ; $1FE345 |
  LDA $30                                   ; $1FE347 |
  CMP #$03                                  ; $1FE349 |
  BNE code_1FE33B                           ; $1FE34B |
  LDA #$80                                  ; $1FE34D |
  STA $10                                   ; $1FE34F |
  JSR code_1FE3C7                           ; $1FE351 |
  BCC code_1FE33B                           ; $1FE354 |
  LDA #$80                                  ; $1FE356 |
  STA $10                                   ; $1FE358 |
  LDA #$08                                  ; $1FE35A |
  BNE code_1FE372                           ; $1FE35C |
code_1FE35E:
  LDA $03E0                                 ; $1FE35E |
  BMI code_1FE3C6                           ; $1FE361 |
  LDA #$40                                  ; $1FE363 |
  STA $10                                   ; $1FE365 |
  JSR code_1FE3C7                           ; $1FE367 |
  BCC code_1FE3C6                           ; $1FE36A |
  LDA #$40                                  ; $1FE36C |
  STA $10                                   ; $1FE36E |
  LDA #$04                                  ; $1FE370 |
code_1FE372:
  STA $23                                   ; $1FE372 |
  LDA #$00                                  ; $1FE374 |
  STA $03E0                                 ; $1FE376 |
  LDX #$01                                  ; $1FE379 |
  LDY $2B                                   ; $1FE37B |
  LDA $AA40,y                               ; $1FE37D |
  AND #$C0                                  ; $1FE380 |
  CMP $10                                   ; $1FE382 |
  BEQ code_1FE388                           ; $1FE384 |
  LDX #$FF                                  ; $1FE386 |
code_1FE388:
  STX $12                                   ; $1FE388 |
  LDA #$00                                  ; $1FE38A |
  STA $03A0                                 ; $1FE38C |
  STA $F8                                   ; $1FE38F |
  LDA #$E8                                  ; $1FE391 |
  STA $5E                                   ; $1FE393 |
  JSR clear_destroyed_blocks                           ; $1FE395 |
  JSR code_1FE614                           ; $1FE398 |
  LDA $22                                   ; $1FE39B |
  STA $F5                                   ; $1FE39D |
  JSR select_PRG_banks                      ; $1FE39F |
  LDY $2B                                   ; $1FE3A2 |
  LDA $AA40,y                               ; $1FE3A4 |
  AND #$20                                  ; $1FE3A7 |
  BEQ code_1FE3AD                           ; $1FE3A9 |
  STA $2A                                   ; $1FE3AB |
code_1FE3AD:
  LDA #$01                                  ; $1FE3AD |
  STA $A000                                 ; $1FE3AF |
  LDA #$2A                                  ; $1FE3B2 |
  STA $52                                   ; $1FE3B4 |
  JSR code_1EC83D                           ; $1FE3B6 |
  LDX #$00                                  ; $1FE3B9 |
  LDY #$04                                  ; $1FE3BB |
  JSR check_tile_collision                           ; $1FE3BD |
  LDA $10                                   ; $1FE3C0 |
  BNE code_1FE3C6                           ; $1FE3C2 |
  STA $30                                   ; $1FE3C4 |
code_1FE3C6:
  RTS                                       ; $1FE3C6 |

code_1FE3C7:
  LDA $2D                                   ; $1FE3C7 |
  BEQ code_1FE3D1                           ; $1FE3C9 |
  CMP $2C                                   ; $1FE3CB |
  BEQ code_1FE3D1                           ; $1FE3CD |
  CLC                                       ; $1FE3CF |
  RTS                                       ; $1FE3D0 |

code_1FE3D1:
  LDA $F9                                   ; $1FE3D1 |
  STA $00                                   ; $1FE3D3 |
  LDY $2B                                   ; $1FE3D5 |
  LDA $2A                                   ; $1FE3D7 |
  AND #$C0                                  ; $1FE3D9 |
  BEQ code_1FE3E5                           ; $1FE3DB |
  LDA $2A                                   ; $1FE3DD |
  CMP $10                                   ; $1FE3DF |
  BEQ code_1FE403                           ; $1FE3E1 |
  BNE code_1FE411                           ; $1FE3E3 |
code_1FE3E5:
  LDA $2C                                   ; $1FE3E5 |
  BNE code_1FE3FF                           ; $1FE3E7 |
  LDA $AA41,y                               ; $1FE3E9 |
  AND #$C0                                  ; $1FE3EC |
  CMP $10                                   ; $1FE3EE |
  BEQ code_1FE403                           ; $1FE3F0 |
  LDA $AA3F,y                               ; $1FE3F2 |
  AND #$C0                                  ; $1FE3F5 |
  EOR #$C0                                  ; $1FE3F7 |
  CMP $10                                   ; $1FE3F9 |
  BEQ code_1FE411                           ; $1FE3FB |
  BNE code_1FE465                           ; $1FE3FD |
code_1FE3FF:
  LDA $2D                                   ; $1FE3FF |
  BEQ code_1FE411                           ; $1FE401 |
code_1FE403:
  INY                                       ; $1FE403 |
  LDA $AA40,y                               ; $1FE404 |
  AND #$C0                                  ; $1FE407 |
  CMP $10                                   ; $1FE409 |
  BNE code_1FE465                           ; $1FE40B |
  INC $00                                   ; $1FE40D |
  BNE code_1FE430                           ; $1FE40F |
code_1FE411:
  LDA $AA40,y                               ; $1FE411 |
  AND #$C0                                  ; $1FE414 |
  BEQ code_1FE465                           ; $1FE416 |
  DEY                                       ; $1FE418 |
  BMI code_1FE465                           ; $1FE419 |
  LDA $AA40,y                               ; $1FE41B |
  AND #$C0                                  ; $1FE41E |
  BNE code_1FE425                           ; $1FE420 |
  LDA $AA41,y                               ; $1FE422 |
code_1FE425:
  EOR #$C0                                  ; $1FE425 |
  CMP $10                                   ; $1FE427 |
  BEQ code_1FE425                           ; $1FE429 |
  DEC $00                                   ; $1FE42B |
  LDA $AA40,y                               ; $1FE42D |
code_1FE430:
  STA $2A                                   ; $1FE430 |
  LDA #$01                                  ; $1FE432 |
  STA $2E                                   ; $1FE434 |
  CPY $2B                                   ; $1FE436 |
  STY $2B                                   ; $1FE438 |
  BCS code_1FE440                           ; $1FE43A |
  LDA #$02                                  ; $1FE43C |
  STA $2E                                   ; $1FE43E |
code_1FE440:
  LDA $AA40,y                               ; $1FE440 |
  AND #$1F                                  ; $1FE443 |
  STA $2C                                   ; $1FE445 |
  LDX $00                                   ; $1FE447 |
  CPX $F9                                   ; $1FE449 |
  BCC code_1FE44F                           ; $1FE44B |
  LDA #$00                                  ; $1FE44D |
code_1FE44F:
  STA $2D                                   ; $1FE44F |
  LDA $00                                   ; $1FE451 |
  STA $29                                   ; $1FE453 |
  STA $F9                                   ; $1FE455 |
  STA $0380                                 ; $1FE457 |
  LDA #$00                                  ; $1FE45A |
  STA $A000                                 ; $1FE45C |
  LDA #$26                                  ; $1FE45F |
  STA $52                                   ; $1FE461 |
  SEC                                       ; $1FE463 |
  RTS                                       ; $1FE464 |

code_1FE465:
  CLC                                       ; $1FE465 |
  RTS                                       ; $1FE466 |

code_1FE467:
  LDA $F8                                   ; $1FE467 |
  CMP #$02                                  ; $1FE469 |
  BNE code_1FE4AF                           ; $1FE46B |
  JSR code_1FE4AF                           ; $1FE46D |
  BCS code_1FE4EF                           ; $1FE470 |
  LDA $0780                                 ; $1FE472 |
  ORA #$22                                  ; $1FE475 |
  STA $0780                                 ; $1FE477 |
  LDA $0781                                 ; $1FE47A |
  ORA #$80                                  ; $1FE47D |
  STA $0781                                 ; $1FE47F |
  LDA #$09                                  ; $1FE482 |
  STA $0782                                 ; $1FE484 |
  LDY #$00                                  ; $1FE487 |
code_1FE489:
  LDA $0797,y                               ; $1FE489 |
  STA $0783,y                               ; $1FE48C |
  INY                                       ; $1FE48F |
  CPY #$0A                                  ; $1FE490 |
  BNE code_1FE489                           ; $1FE492 |
  LDA $07A1                                 ; $1FE494 |
  BPL code_1FE49F                           ; $1FE497 |
  STA $078D                                 ; $1FE499 |
  STA $1A                                   ; $1FE49C |
  RTS                                       ; $1FE49E |

code_1FE49F:
  LDY #$00                                  ; $1FE49F |
code_1FE4A1:
  LDA $07B5,y                               ; $1FE4A1 |
  STA $078D,y                               ; $1FE4A4 |
  INY                                       ; $1FE4A7 |
  CPY #$0D                                  ; $1FE4A8 |
  BNE code_1FE4A1                           ; $1FE4AA |
  STA $1A                                   ; $1FE4AC |
  RTS                                       ; $1FE4AE |

code_1FE4AF:
  LDA $FC                                   ; $1FE4AF |
  SEC                                       ; $1FE4B1 |
  SBC $25                                   ; $1FE4B2 |
  BPL code_1FE4BB                           ; $1FE4B4 |
  EOR #$FF                                  ; $1FE4B6 |
  CLC                                       ; $1FE4B8 |
  ADC #$01                                  ; $1FE4B9 |
code_1FE4BB:
  STA $03                                   ; $1FE4BB |
  BEQ code_1FE4EF                           ; $1FE4BD |
  LDA $23                                   ; $1FE4BF |
  AND #$0C                                  ; $1FE4C1 |
  BEQ code_1FE4D6                           ; $1FE4C3 |
  LDA $10                                   ; $1FE4C5 |
  STA $23                                   ; $1FE4C7 |
  AND #$01                                  ; $1FE4C9 |
  TAX                                       ; $1FE4CB |
  LDA $E5CD,x                               ; $1FE4CC |
  STA $25                                   ; $1FE4CF |
  LDA $E5CF,x                               ; $1FE4D1 |
  STA $24                                   ; $1FE4D4 |
code_1FE4D6:
  LDA $10                                   ; $1FE4D6 |
  AND #$01                                  ; $1FE4D8 |
  BEQ code_1FE4E1                           ; $1FE4DA |
  LDA $25                                   ; $1FE4DC |
  JMP code_1FE4E5                           ; $1FE4DE |

code_1FE4E1:
  LDA $25                                   ; $1FE4E1 |
  EOR #$FF                                  ; $1FE4E3 |
code_1FE4E5:
  AND #$07                                  ; $1FE4E5 |
  CLC                                       ; $1FE4E7 |
  ADC $03                                   ; $1FE4E8 |
  LSR                                       ; $1FE4EA |
  LSR                                       ; $1FE4EB |
  LSR                                       ; $1FE4EC |
  BNE code_1FE4F1                           ; $1FE4ED |
code_1FE4EF:
  SEC                                       ; $1FE4EF |
  RTS                                       ; $1FE4F0 |

code_1FE4F1:
  LDA $10                                   ; $1FE4F1 |
  PHA                                       ; $1FE4F3 |
  AND #$01                                  ; $1FE4F4 |
  TAX                                       ; $1FE4F6 |
  PLA                                       ; $1FE4F7 |
  CMP $23                                   ; $1FE4F8 |
  STA $23                                   ; $1FE4FA |
  BEQ code_1FE501                           ; $1FE4FC |
  JMP code_1FE50F                           ; $1FE4FE |

code_1FE501:
  LDA $24                                   ; $1FE501 |
  CLC                                       ; $1FE503 |
  ADC $E5C3,x                               ; $1FE504 |
  CMP #$20                                  ; $1FE507 |
  AND #$1F                                  ; $1FE509 |
  STA $24                                   ; $1FE50B |
  BCC code_1FE517                           ; $1FE50D |
code_1FE50F:
  LDA $29                                   ; $1FE50F |
  CLC                                       ; $1FE511 |
  ADC $E5C3,x                               ; $1FE512 |
  STA $29                                   ; $1FE515 |
code_1FE517:
  LDA $22                                   ; $1FE517 |
  STA $F5                                   ; $1FE519 |
  JSR select_PRG_banks                      ; $1FE51B |
  LDA $24                                   ; $1FE51E |
  LSR                                       ; $1FE520 |
  LSR                                       ; $1FE521 |
  STA $28                                   ; $1FE522 |
  LDY $29                                   ; $1FE524 |
  JSR metatile_column_ptr                           ; $1FE526 |
  LDA #$00                                  ; $1FE529 |
  STA $03                                   ; $1FE52B |
code_1FE52D:
  JSR metatile_to_chr_tiles                           ; $1FE52D |
  LDY $28                                   ; $1FE530 |
  LDA $0640,y                               ; $1FE532 |
  STA $11                                   ; $1FE535 |
  LDA $24                                   ; $1FE537 |
  AND #$03                                  ; $1FE539 |
  TAY                                       ; $1FE53B |
  LDX $03                                   ; $1FE53C |
  LDA $06C0,y                               ; $1FE53E |
  STA $0783,x                               ; $1FE541 |
  LDA $06C4,y                               ; $1FE544 |
  STA $0784,x                               ; $1FE547 |
  LDA $28                                   ; $1FE54A |
  CMP #$38                                  ; $1FE54C |
  BCS code_1FE55C                           ; $1FE54E |
  LDA $06C8,y                               ; $1FE550 |
  STA $0785,x                               ; $1FE553 |
  LDA $06CC,y                               ; $1FE556 |
  STA $0786,x                               ; $1FE559 |
code_1FE55C:
  LDA $24                                   ; $1FE55C |
  AND #$01                                  ; $1FE55E |
  BEQ code_1FE588                           ; $1FE560 |
  LDA $10                                   ; $1FE562 |
  AND $E5C5,y                               ; $1FE564 |
  STA $10                                   ; $1FE567 |
  LDA $11                                   ; $1FE569 |
  AND $E5C9,y                               ; $1FE56B |
  ORA $10                                   ; $1FE56E |
  STA $07A4,x                               ; $1FE570 |
  LDY $28                                   ; $1FE573 |
  STA $0640,y                               ; $1FE575 |
  LDA #$23                                  ; $1FE578 |
  STA $07A1,x                               ; $1FE57A |
  TYA                                       ; $1FE57D |
  ORA #$C0                                  ; $1FE57E |
  STA $07A2,x                               ; $1FE580 |
  LDA #$00                                  ; $1FE583 |
  STA $07A3,x                               ; $1FE585 |
code_1FE588:
  INC $03                                   ; $1FE588 |
  INC $03                                   ; $1FE58A |
  INC $03                                   ; $1FE58C |
  INC $03                                   ; $1FE58E |
  LDA $28                                   ; $1FE590 |
  CLC                                       ; $1FE592 |
  ADC #$08                                  ; $1FE593 |
  STA $28                                   ; $1FE595 |
  CMP #$40                                  ; $1FE597 |
  BCC code_1FE52D                           ; $1FE599 |
  LDA #$20                                  ; $1FE59B |
  STA $0780                                 ; $1FE59D |
  LDA $24                                   ; $1FE5A0 |
  STA $0781                                 ; $1FE5A2 |
  LDA #$1D                                  ; $1FE5A5 |
  STA $0782                                 ; $1FE5A7 |
  LDY #$00                                  ; $1FE5AA |
  LDA $24                                   ; $1FE5AC |
  AND #$01                                  ; $1FE5AE |
  BEQ code_1FE5B4                           ; $1FE5B0 |
  LDY #$20                                  ; $1FE5B2 |
code_1FE5B4:
  LDA #$FF                                  ; $1FE5B4 |
  STA $07A1,y                               ; $1FE5B6 |
  LDY $F8                                   ; $1FE5B9 |
  CPY #$02                                  ; $1FE5BB |
  BEQ code_1FE5C1                           ; $1FE5BD |
  STA $1A                                   ; $1FE5BF |
code_1FE5C1:
  CLC                                       ; $1FE5C1 |
  RTS                                       ; $1FE5C2 |

  db $FF, $01, $33, $33, $CC, $CC, $CC, $CC ; $1FE5C3 |
  db $33, $33, $00, $FF, $01, $1F           ; $1FE5CB |

code_1FE5D1:
  JSR code_1EC628                           ; $1FE5D1 |
code_1FE5D4:
  LDA $FC                                   ; $1FE5D4 |
  CLC                                       ; $1FE5D6 |
  ADC #$04                                  ; $1FE5D7 |
  STA $FC                                   ; $1FE5D9 |
  BCC code_1FE5DF                           ; $1FE5DB |
  INC $F9                                   ; $1FE5DD |
code_1FE5DF:
  LDA #$01                                  ; $1FE5DF |
  STA $10                                   ; $1FE5E1 |
  JSR code_1FE467                           ; $1FE5E3 |
  LDA $FC                                   ; $1FE5E6 |
  STA $25                                   ; $1FE5E8 |
  LDA $0340                                 ; $1FE5EA |
  CLC                                       ; $1FE5ED |
  ADC #$D0                                  ; $1FE5EE |
  STA $0340                                 ; $1FE5F0 |
  LDA $0360                                 ; $1FE5F3 |
  ADC #$00                                  ; $1FE5F6 |
  STA $0360                                 ; $1FE5F8 |
  LDA $0380                                 ; $1FE5FB |
  ADC #$00                                  ; $1FE5FE |
  STA $0380                                 ; $1FE600 |
  JSR process_frame_yield_with_player                           ; $1FE603 |
  LDA $FC                                   ; $1FE606 |
  BNE code_1FE5D4                           ; $1FE608 |
  LDA $22                                   ; $1FE60A |
  STA $F5                                   ; $1FE60C |
  JSR select_PRG_banks                      ; $1FE60E |
  JMP code_1EC83D                           ; $1FE611 |

code_1FE614:
  JSR code_1EC628                           ; $1FE614 |
  LDA $23                                   ; $1FE617 |
  AND #$04                                  ; $1FE619 |
  LSR                                       ; $1FE61B |
  LSR                                       ; $1FE61C |
  TAX                                       ; $1FE61D |
  LDA $E7EB,x                               ; $1FE61E |
  STA $24                                   ; $1FE621 |
code_1FE623:
  LDA $23                                   ; $1FE623 |
  AND #$04                                  ; $1FE625 |
  BEQ code_1FE653                           ; $1FE627 |
  LDA $FA                                   ; $1FE629 |
  CLC                                       ; $1FE62B |
  ADC #$03                                  ; $1FE62C |
  STA $FA                                   ; $1FE62E |
  CMP #$F0                                  ; $1FE630 |
  BCC code_1FE638                           ; $1FE632 |
  ADC #$0F                                  ; $1FE634 |
  STA $FA                                   ; $1FE636 |
code_1FE638:
  LDA $03A0                                 ; $1FE638 |
  SEC                                       ; $1FE63B |
  SBC #$C0                                  ; $1FE63C |
  STA $03A0                                 ; $1FE63E |
  LDA $03C0                                 ; $1FE641 |
  SBC #$02                                  ; $1FE644 |
  STA $03C0                                 ; $1FE646 |
  BCS code_1FE67A                           ; $1FE649 |
  SBC #$0F                                  ; $1FE64B |
  STA $03C0                                 ; $1FE64D |
  JMP code_1FE67A                           ; $1FE650 |

code_1FE653:
  LDA $FA                                   ; $1FE653 |
  SEC                                       ; $1FE655 |
  SBC #$03                                  ; $1FE656 |
  STA $FA                                   ; $1FE658 |
  BCS code_1FE660                           ; $1FE65A |
  SBC #$0F                                  ; $1FE65C |
  STA $FA                                   ; $1FE65E |
code_1FE660:
  LDA $03A0                                 ; $1FE660 |
  CLC                                       ; $1FE663 |
  ADC #$C0                                  ; $1FE664 |
  STA $03A0                                 ; $1FE666 |
  LDA $03C0                                 ; $1FE669 |
  ADC #$02                                  ; $1FE66C |
  STA $03C0                                 ; $1FE66E |
  CMP #$F0                                  ; $1FE671 |
  BCC code_1FE67A                           ; $1FE673 |
  ADC #$0F                                  ; $1FE675 |
  STA $03C0                                 ; $1FE677 |
code_1FE67A:
  JSR code_1FE698                           ; $1FE67A |
  LDA $FA                                   ; $1FE67D |
  STA $26                                   ; $1FE67F |
  LDA $12                                   ; $1FE681 |
  PHA                                       ; $1FE683 |
  JSR process_frame_yield_with_player                           ; $1FE684 |
  PLA                                       ; $1FE687 |
  STA $12                                   ; $1FE688 |
  LDA $FA                                   ; $1FE68A |
  BEQ code_1FE691                           ; $1FE68C |
  JMP code_1FE623                           ; $1FE68E |

code_1FE691:
  LDA $22                                   ; $1FE691 |
  STA $F5                                   ; $1FE693 |
  JMP select_PRG_banks                      ; $1FE695 |

code_1FE698:
  LDA $FA                                   ; $1FE698 |
  SEC                                       ; $1FE69A |
  SBC $26                                   ; $1FE69B |
  BPL code_1FE6A4                           ; $1FE69D |
  EOR #$FF                                  ; $1FE69F |
  CLC                                       ; $1FE6A1 |
  ADC #$01                                  ; $1FE6A2 |
code_1FE6A4:
  STA $03                                   ; $1FE6A4 |
  BEQ code_1FE6C1                           ; $1FE6A6 |
  LDA $23                                   ; $1FE6A8 |
  AND #$04                                  ; $1FE6AA |
  BEQ code_1FE6B3                           ; $1FE6AC |
  LDA $26                                   ; $1FE6AE |
  JMP code_1FE6B7                           ; $1FE6B0 |

code_1FE6B3:
  LDA $26                                   ; $1FE6B3 |
  EOR #$FF                                  ; $1FE6B5 |
code_1FE6B7:
  AND #$07                                  ; $1FE6B7 |
  CLC                                       ; $1FE6B9 |
  ADC $03                                   ; $1FE6BA |
  LSR                                       ; $1FE6BC |
  LSR                                       ; $1FE6BD |
  LSR                                       ; $1FE6BE |
  BNE code_1FE6C2                           ; $1FE6BF |
code_1FE6C1:
  RTS                                       ; $1FE6C1 |

code_1FE6C2:
  LDA $23                                   ; $1FE6C2 |
  AND #$04                                  ; $1FE6C4 |
  LSR                                       ; $1FE6C6 |
  LSR                                       ; $1FE6C7 |
  TAY                                       ; $1FE6C8 |
  LDA $24                                   ; $1FE6C9 |
  CLC                                       ; $1FE6CB |
  ADC $E7E9,y                               ; $1FE6CC |
  STA $24                                   ; $1FE6CF |
  CMP #$1E                                  ; $1FE6D1 |
  BCC code_1FE6DA                           ; $1FE6D3 |
  LDA $E7E7,y                               ; $1FE6D5 |
  STA $24                                   ; $1FE6D8 |
code_1FE6DA:
  LDA $24                                   ; $1FE6DA |
  AND #$01                                  ; $1FE6DC |
  CMP $E7E5,y                               ; $1FE6DE |
  BEQ code_1FE6E6                           ; $1FE6E1 |
  JMP code_1FE79F                           ; $1FE6E3 |

code_1FE6E6:
  LDA $22                                   ; $1FE6E6 |
  STA $F5                                   ; $1FE6E8 |
  JSR select_PRG_banks                      ; $1FE6EA |
  LDY $29                                   ; $1FE6ED |
  JSR metatile_column_ptr                           ; $1FE6EF |
  LDA $24                                   ; $1FE6F2 |
  AND #$1C                                  ; $1FE6F4 |
  ASL                                       ; $1FE6F6 |
  STA $28                                   ; $1FE6F7 |
  ORA #$C0                                  ; $1FE6F9 |
  STA $07A4                                 ; $1FE6FB |
  LDA #$23                                  ; $1FE6FE |
  STA $07A3                                 ; $1FE700 |
  LDA #$07                                  ; $1FE703 |
  STA $07A5                                 ; $1FE705 |
  LDA #$00                                  ; $1FE708 |
  STA $03                                   ; $1FE70A |
code_1FE70C:
  LDY $28                                   ; $1FE70C |
  LDA $0640,y                               ; $1FE70E |
  STA $11                                   ; $1FE711 |
  JSR metatile_to_chr_tiles                           ; $1FE713 |
  LDY $03                                   ; $1FE716 |
  LDA $24                                   ; $1FE718 |
  AND #$03                                  ; $1FE71A |
  TAX                                       ; $1FE71C |
  LDA $E7D9,x                               ; $1FE71D |
  STA $04                                   ; $1FE720 |
  LDA $E7DD,x                               ; $1FE722 |
  STA $05                                   ; $1FE725 |
  LDA #$03                                  ; $1FE727 |
  STA $06                                   ; $1FE729 |
code_1FE72B:
  LDX $04                                   ; $1FE72B |
  LDA $06C0,x                               ; $1FE72D |
  STA $0783,y                               ; $1FE730 |
  LDX $05                                   ; $1FE733 |
  LDA $06C0,x                               ; $1FE735 |
  STA $07AF,y                               ; $1FE738 |
  INC $04                                   ; $1FE73B |
  INC $05                                   ; $1FE73D |
  INY                                       ; $1FE73F |
  DEC $06                                   ; $1FE740 |
  BPL code_1FE72B                           ; $1FE742 |
  STY $03                                   ; $1FE744 |
  LDA $24                                   ; $1FE746 |
  AND #$03                                  ; $1FE748 |
  TAX                                       ; $1FE74A |
  LDA $10                                   ; $1FE74B |
  AND $E7D1,x                               ; $1FE74D |
  STA $10                                   ; $1FE750 |
  LDA $11                                   ; $1FE752 |
  AND $E7D5,x                               ; $1FE754 |
  ORA $10                                   ; $1FE757 |
  STA $10                                   ; $1FE759 |
  LDX $28                                   ; $1FE75B |
  STA $0640,x                               ; $1FE75D |
  TXA                                       ; $1FE760 |
  AND #$07                                  ; $1FE761 |
  TAX                                       ; $1FE763 |
  LDA $10                                   ; $1FE764 |
  STA $07A6,x                               ; $1FE766 |
  INC $28                                   ; $1FE769 |
  CPX #$07                                  ; $1FE76B |
  BNE code_1FE70C                           ; $1FE76D |
  LDA $24                                   ; $1FE76F |
  PHA                                       ; $1FE771 |
  AND #$03                                  ; $1FE772 |
  TAY                                       ; $1FE774 |
  PLA                                       ; $1FE775 |
  LSR                                       ; $1FE776 |
  LSR                                       ; $1FE777 |
  TAX                                       ; $1FE778 |
  LDA $E8A9,x                               ; $1FE779 |
  STA $0780                                 ; $1FE77C |
  LDA $E8A1,x                               ; $1FE77F |
  ORA $E7E1,y                               ; $1FE782 |
  STA $0781                                 ; $1FE785 |
  LDA #$1F                                  ; $1FE788 |
  STA $0782                                 ; $1FE78A |
  LDA $23                                   ; $1FE78D |
  AND #$04                                  ; $1FE78F |
  LSR                                       ; $1FE791 |
  LSR                                       ; $1FE792 |
  TAY                                       ; $1FE793 |
  LDX $E7ED,y                               ; $1FE794 |
  LDA #$FF                                  ; $1FE797 |
  STA $0780,x                               ; $1FE799 |
  STA $19                                   ; $1FE79C |
  RTS                                       ; $1FE79E |

code_1FE79F:
  LDY #$1F                                  ; $1FE79F |
code_1FE7A1:
  LDA $07AF,y                               ; $1FE7A1 |
  STA $0783,y                               ; $1FE7A4 |
  DEY                                       ; $1FE7A7 |
  BPL code_1FE7A1                           ; $1FE7A8 |
  LDA $24                                   ; $1FE7AA |
  AND #$03                                  ; $1FE7AC |
  TAX                                       ; $1FE7AE |
  LDA $0781                                 ; $1FE7AF |
  AND #$80                                  ; $1FE7B2 |
  ORA $E7E1,x                               ; $1FE7B4 |
  STA $0781                                 ; $1FE7B7 |
  LDA #$23                                  ; $1FE7BA |
  STA $07A3                                 ; $1FE7BC |
  LDA $23                                   ; $1FE7BF |
  AND #$04                                  ; $1FE7C1 |
  LSR                                       ; $1FE7C3 |
  LSR                                       ; $1FE7C4 |
  TAY                                       ; $1FE7C5 |
  LDX $E7EF,y                               ; $1FE7C6 |
  LDA #$FF                                  ; $1FE7C9 |
  STA $0780,x                               ; $1FE7CB |
  STA $19                                   ; $1FE7CE |
  RTS                                       ; $1FE7D0 |

  db $0F, $0F, $F0, $F0, $F0, $F0, $0F, $0F ; $1FE7D1 |
  db $00, $04, $08, $0C, $04, $00, $0C, $08 ; $1FE7D9 |
  db $00, $20, $40, $60, $01, $00, $1D, $00 ; $1FE7E1 |
  db $FF, $01, $00, $1D, $23, $2E, $2E, $23 ; $1FE7E9 |

; ===========================================================================
; metatile_to_chr_tiles — convert 4 metatile quadrants to CHR tile IDs
; ===========================================================================
; Reads the current metatile definition via pointer at $00/$01 (set by
; metatile_chr_ptr). Each metatile has 4 quadrants (indexed 0-3).
; For each quadrant:
;   - Reads metatile sub-index from ($00),y
;   - Looks up 4 CHR tile IDs from tables $BB00-$BE00
;   - Stores them to $06C0 buffer in 2×2 layout
;   - Reads palette/attribute bits from $BF00
;   - Accumulates attribute byte in $10 (2 bits per quadrant)
;
; $E89D offset table: {$00,$02,$08,$0A} maps quadrants to $06C0 offsets.
; Output: $06C0 = 4×4 = 16 CHR tiles, $10 = attribute byte.
; ---------------------------------------------------------------------------
metatile_to_chr_tiles:
  JSR metatile_chr_ptr                           ; $1FE7F1 |
metatile_to_chr_tiles_continue:
  LDY #$03                                  ; $1FE7F4 | start with quadrant 3
  STY $02                                   ; $1FE7F6 | $02 = quadrant counter (3→0)
  LDA #$00                                  ; $1FE7F8 |
  STA $10                                   ; $1FE7FA | $10 = accumulated attribute bits
.next_quadrant:
  LDY $02                                   ; $1FE7FC | Y = current quadrant
  LDX $E89D,y                               ; $1FE7FE | X = buffer offset for this quadrant
  LDA ($00),y                               ; $1FE801 | read metatile sub-index
  TAY                                       ; $1FE803 | Y = sub-index for CHR lookup
  LDA $BB00,y                               ; $1FE804 |\ top-left tile
  STA $06C0,x                               ; $1FE807 |/
  LDA $BC00,y                               ; $1FE80A |\ top-right tile
  STA $06C1,x                               ; $1FE80D |/
  LDA $BD00,y                               ; $1FE810 |\ bottom-left tile
  STA $06C4,x                               ; $1FE813 |/
  LDA $BE00,y                               ; $1FE816 |\ bottom-right tile
  STA $06C5,x                               ; $1FE819 |/
  JSR breakable_block_override               ; $1FE81C | Gemini Man: zero destroyed blocks
  LDA $BF00,y                               ; $1FE81F |\ attribute: low 2 bits = palette
  AND #$03                                  ; $1FE822 | | merge into $10
  ORA $10                                   ; $1FE824 | |
  STA $10                                   ; $1FE826 |/
  DEC $02                                   ; $1FE828 | next quadrant
  BMI metatile_chr_exit                      ; $1FE82A | if all 4 done, return
  ASL $10                                   ; $1FE82C |\ shift attribute bits left 2
  ASL $10                                   ; $1FE82E | | (make room for next quadrant)
  JMP .next_quadrant                        ; $1FE830 |/

metatile_chr_exit:                              ;         | shared RTS (metatile + breakable_block)
  RTS                                       ; $1FE833 |

; ===========================================================================
; breakable_block_override — zero CHR tiles for destroyed blocks (Gemini Man)
; ===========================================================================
; Called from metatile_to_chr_tiles for Gemini Man stages only ($22 = $02 or
; $09). Checks if the current metatile is a breakable block type (attribute
; upper nibble = $7x). If so, looks up the destroyed-block bitfield at
; $0110 — if the bit is set, the block has been destroyed and its 4 CHR
; tiles are zeroed out (invisible).
;
; Y = metatile sub-index, X = $06C0 buffer offset (preserved on exit)
; Uses bitmask_table ($EB82) for bit testing: $80,$40,$20,...,$01
; ---------------------------------------------------------------------------
breakable_block_override:
  LDA $22                                   ; $1FE834 | current stage number
  CMP #$02                                  ; $1FE836 | Gemini Man?
  BEQ .check_block                          ; $1FE838 | yes → check
  CMP #$09                                  ; $1FE83A | Doc Robot (Gemini Man stage)?
  BNE metatile_chr_exit                      ; $1FE83C | no → skip (shared RTS above)
.check_block:
  LDA $BF00,y                               ; $1FE83E |\ attribute byte upper nibble
  AND #$F0                                  ; $1FE841 | |
  CMP #$70                                  ; $1FE843 | | breakable block type ($7x)?
  BNE metatile_chr_exit                      ; $1FE845 |/ no → skip
  STY $0F                                   ; $1FE847 | save Y (metatile sub-index)
  STX $0E                                   ; $1FE849 | save X (buffer offset)
  LDA $29                                   ; $1FE84B |\ compute destroyed-block array index:
  AND #$01                                  ; $1FE84D | | Y = ($29 & 1) << 5 | ($28 >> 1)
  ASL                                       ; $1FE84F | | ($29 bit 0 = screen page,
  ASL                                       ; $1FE850 | |  $28 = metatile column position)
  ASL                                       ; $1FE851 | |
  ASL                                       ; $1FE852 | |
  ASL                                       ; $1FE853 | |
  STA $0D                                   ; $1FE854 |/
  LDA $28                                   ; $1FE856 |
  PHA                                       ; $1FE858 | save $28
  LSR                                       ; $1FE859 |\ Y = byte index into $0110 array
  ORA $0D                                   ; $1FE85A | |
  TAY                                       ; $1FE85C |/
  PLA                                       ; $1FE85D |\ X = bit index within byte:
  ASL                                       ; $1FE85E | | ($28 << 2) & $04 | $02 (quadrant)
  ASL                                       ; $1FE85F | | combines column parity with quadrant
  AND #$04                                  ; $1FE860 | |
  ORA $02                                   ; $1FE862 | |
  TAX                                       ; $1FE864 |/
  LDA $0110,y                               ; $1FE865 |\ test destroyed bit
  AND bitmask_table,x                        ; $1FE868 | | via bitmask_table
  BEQ .restore                              ; $1FE86B |/ not destroyed → skip
  LDX $0E                                   ; $1FE86D | restore buffer offset
  LDA #$00                                  ; $1FE86F |\ zero all 4 CHR tiles (invisible)
  STA $06C0,x                               ; $1FE871 | |
  STA $06C1,x                               ; $1FE874 | |
  STA $06C4,x                               ; $1FE877 | |
  STA $06C5,x                               ; $1FE87A |/
.restore:
  LDY $0F                                   ; $1FE87D | restore Y
  LDX $0E                                   ; $1FE87F | restore X
  RTS                                       ; $1FE881 |

; metatile_chr_ptr: sets $00/$01 pointer to 4-byte metatile CHR definition
; reads metatile index from column data at ($20),y
; each metatile = 4 CHR tile indices (2x2 pattern: TL, TR, BL, BR)
; metatile definitions at $B700 + (metatile_index * 4) in stage bank
metatile_chr_ptr:
  JSR code_1EC8A0                           ; $1FE882 |  ensure stage bank selected
  LDA #$00                                  ; $1FE885 |
  STA $01                                   ; $1FE887 |
  LDY $28                                   ; $1FE889 |
  LDA ($20),y                               ; $1FE88B |  metatile index from column data
.calc_chr_offset:
  ASL                                       ; $1FE88D |\ multiply by 4
  ROL $01                                   ; $1FE88E | | (4 CHR tiles per metatile)
  ASL                                       ; $1FE890 | |
  ROL $01                                   ; $1FE891 |/
  STA $00                                   ; $1FE893 |\ $00/$01 = $B700 + (index * 4)
  LDA $01                                   ; $1FE895 | | pointer to CHR tile definition
  CLC                                       ; $1FE897 | |
  ADC #$B7                                  ; $1FE898 | |
  STA $01                                   ; $1FE89A |/
  RTS                                       ; $1FE89C |

  db $00, $02, $08, $0A, $00, $80, $00, $80 ; $1FE89D |
  db $00, $80, $00, $80, $20, $20, $21, $21 ; $1FE8A5 |
  db $22, $22, $23, $23                     ; $1FE8AD |

; metatile_column_ptr: sets $20/$21 pointer to metatile column data
; Y = screen page → reads column ID from $AA00,y in stage bank
; column data is at $AF00 + (column_ID * 64) — 64 bytes per column
metatile_column_ptr:
  LDA $AA00,y                               ; $1FE8B1 |  column ID from screen data
code_1FE8B4:
  PHA                                       ; $1FE8B4 |
  LDA #$00                                  ; $1FE8B5 |
  STA $00                                   ; $1FE8B7 |
  PLA                                       ; $1FE8B9 |
  ASL                                       ; $1FE8BA |
  ROL $00                                   ; $1FE8BB |
  ASL                                       ; $1FE8BD |
  ROL $00                                   ; $1FE8BE |
  ASL                                       ; $1FE8C0 |
  ROL $00                                   ; $1FE8C1 |
  ASL                                       ; $1FE8C3 |
  ROL $00                                   ; $1FE8C4 |
  ASL                                       ; $1FE8C6 |
  ROL $00                                   ; $1FE8C7 |
  ASL                                       ; $1FE8C9 |
  ROL $00                                   ; $1FE8CA |
  STA $20                                   ; $1FE8CC |\ $20/$21 = $AF00 + (column_ID << 6)
  LDA $00                                   ; $1FE8CE | | pointer to metatile column data
  CLC                                       ; $1FE8D0 | | in stage bank at $AF00+
  ADC #$AF                                  ; $1FE8D1 | |
  STA $21                                   ; $1FE8D3 |/
  RTS                                       ; $1FE8D5 |

; -----------------------------------------------
; check_tile_horiz — horizontal-scan tile collision
; -----------------------------------------------
; Checks multiple X positions at a fixed Y offset for collisions.
; Used for floor/ceiling detection (scanning across the entity's
; width at a specific vertical position).
;
; parameters:
;   Y = hitbox config index into $EBE2 offset table
;   X = entity slot
; hitbox offset tables:
;   $EBE2,y = starting offset index (into $EC12)
;   $EC10,y = number of check points - 1
;   $EC11,y = Y pixel offset (signed, relative to entity Y)
;   $EC12,y = X pixel offsets (signed, relative to entity X)
; results:
;   $42-$44 = tile type at each check point
;   $41     = max (highest priority) tile type encountered
;   $10     = OR of all tile types (AND #$10 tests solid)
; -----------------------------------------------
check_tile_horiz:
  LDA $EBE2,y                               ; $1FE8D6 |\ $40 = starting offset index
  STA $40                                   ; $1FE8D9 |/
  JSR tile_check_init                        ; $1FE8DB |  clear accumulators, switch to stage bank
  TAY                                       ; $1FE8DE |  Y = hitbox config index
  LDA $EC10,y                               ; $1FE8DF |\ $02 = number of check points - 1
  STA $02                                   ; $1FE8E2 |/
  LDA $03E0,x                               ; $1FE8E4 |\ $03 = entity Y screen
  STA $03                                   ; $1FE8E7 |/
  LDA $EC11,y                               ; $1FE8E9 |\ $11 = entity_Y + Y_offset
  PHA                                       ; $1FE8EC | | (compute check Y position)
  CLC                                       ; $1FE8ED | |
  ADC $03C0,x                               ; $1FE8EE | |
  STA $11                                   ; $1FE8F1 |/
  PLA                                       ; $1FE8F3 |  A = original Y offset (for sign check)
  BMI .y_offset_neg                         ; $1FE8F4 |  negative offset? handle differently
  BCS .y_offscreen                          ; $1FE8F6 |  positive offset + carry = past screen
  LDA $11                                   ; $1FE8F8 |\ check if Y wrapped past $F0
  CMP #$F0                                  ; $1FE8FA | | (screen height)
  BCS .y_offscreen                          ; $1FE8FC |/
  BCC .y_ok                                 ; $1FE8FE |  within bounds → proceed
.y_offset_neg:
  BCS .y_ok                                 ; $1FE900 |  neg offset + carry = no underflow → ok
.y_offscreen:
  LDA #$00                                  ; $1FE902 |\ Y out of bounds: zero all results
  LDY $02                                   ; $1FE904 |/
.clear_results:
  STA $0042,y                               ; $1FE906 |\ clear $42..$42+count
  DEY                                       ; $1FE909 | |
  BPL .clear_results                        ; $1FE90A |/
  JMP tile_check_cleanup                     ; $1FE90C |  restore bank and return

.y_ok:
  LDA $03                                   ; $1FE90F |\ Y screen != 0? treat as offscreen
  BNE .y_offscreen                          ; $1FE911 |/ (only check screen 0)
  ;--- convert pixel Y ($11) to metatile row/sub-tile ---
  LDA $11                                   ; $1FE913 |\ Y >> 2 = 4-pixel rows
  LSR                                       ; $1FE915 | |
  LSR                                       ; $1FE916 |/
  PHA                                       ; $1FE917 |\ $28 = metatile row (bits 5-3 of Y>>2)
  AND #$38                                  ; $1FE918 | | = column offset in metatile grid
  STA $28                                   ; $1FE91A |/
  PLA                                       ; $1FE91C |\ $03 bit1 = sub-tile Y (bit 2 of Y>>2)
  LSR                                       ; $1FE91D | | selects top/bottom half of metatile
  AND #$02                                  ; $1FE91E | |
  STA $03                                   ; $1FE920 |/
  ;--- compute first X check position ---
  LDA #$00                                  ; $1FE922 |\ $04 = sign extension for X offset
  STA $04                                   ; $1FE924 |/
  LDA $EC12,y                               ; $1FE926 |\ first X offset (signed)
  BPL .x_pos                                ; $1FE929 |/ positive? skip sign extend
  DEC $04                                   ; $1FE92B |  negative: $04 = $FF
.x_pos:
  CLC                                       ; $1FE92D |\ $12/$13 = entity_X + X_offset
  ADC $0360,x                               ; $1FE92E | | $12 = X pixel
  STA $12                                   ; $1FE931 | | $13 = X screen
  LDA $0380,x                               ; $1FE933 | |
  ADC $04                                   ; $1FE936 | |
  STA $13                                   ; $1FE938 |/
  ;--- convert pixel X ($12) to metatile column/sub-tile ---
  LDA $12                                   ; $1FE93A |\ X >> 4 = tile column
  LSR                                       ; $1FE93C | |
  LSR                                       ; $1FE93D | |
  LSR                                       ; $1FE93E | |
  LSR                                       ; $1FE93F |/
  PHA                                       ; $1FE940 |\ $03 bit0 = sub-tile X (bit 0 of X>>4)
  AND #$01                                  ; $1FE941 | | selects left/right half of metatile
  ORA $03                                   ; $1FE943 | | (combined with Y sub-tile in bits 0-1)
  STA $03                                   ; $1FE945 |/
  PLA                                       ; $1FE947 |\ $28 |= metatile column (X>>5)
  LSR                                       ; $1FE948 | | merged with row from Y
  ORA $28                                   ; $1FE949 | |
  STA $28                                   ; $1FE94B |/
  ;--- tile lookup loop: scan X positions at fixed Y ---
.switch_bank:
  STX $04                                   ; $1FE94D |\ save entity slot
  LDA $22                                   ; $1FE94F | | switch to stage PRG bank
  STA $F5                                   ; $1FE951 | |
  JSR select_PRG_banks                      ; $1FE953 | |
  LDX $04                                   ; $1FE956 |/ restore entity slot
  LDY $13                                   ; $1FE958 |\ get metatile column pointer for X screen
  JSR metatile_column_ptr                    ; $1FE95A |/
.new_column:
  JSR metatile_chr_ptr                       ; $1FE95D |  get CHR data pointer for column+row ($28)
.check_tile:
  LDY $03                                   ; $1FE960 |\ read metatile index at sub-tile ($03)
  LDA ($00),y                               ; $1FE962 | | $03 = {0,1,2,3} for TL/TR/BL/BR
  TAY                                       ; $1FE964 |/
  LDA $BF00,y                               ; $1FE965 |\ get collision attribute for this tile
  AND #$F0                                  ; $1FE968 |/ upper nibble = collision type
  JSR breakable_block_collision              ; $1FE96A |  override if destroyed breakable block
  JSR code_1FEB8A                           ; $1FE96D |  Proto Man wall override
  LDY $02                                   ; $1FE970 |\ store result in $42+count
  STA $0042,y                               ; $1FE972 |/
  CMP $41                                   ; $1FE975 |\ update max tile type
  BCC .not_max                              ; $1FE977 | |
  STA $41                                   ; $1FE979 |/
.not_max:
  ORA $10                                   ; $1FE97B |\ accumulate all tile types
  STA $10                                   ; $1FE97D |/
  DEC $02                                   ; $1FE97F |\ all check points done?
  BMI .done_scan                            ; $1FE981 |/
  ;--- advance to next X check point ---
  INC $40                                   ; $1FE983 |\ next offset index
  LDY $40                                   ; $1FE985 |/
  LDA $12                                   ; $1FE987 |\ save old bit4 of X (16px tile boundary)
  PHA                                       ; $1FE989 | |
  AND #$10                                  ; $1FE98A | |
  STA $04                                   ; $1FE98C |/
  PLA                                       ; $1FE98E |\ $12 += next X offset
  CLC                                       ; $1FE98F | |
  ADC $EC12,y                               ; $1FE990 | |
  STA $12                                   ; $1FE993 |/
  AND #$10                                  ; $1FE995 |\ did bit4 change? (crossed 16px tile?)
  CMP $04                                   ; $1FE997 | |
  BEQ .check_tile                           ; $1FE999 |/ no → same tile, just re-read
  LDA $03                                   ; $1FE99B |\ toggle sub-tile X (bit 0)
  EOR #$01                                  ; $1FE99D | |
  STA $03                                   ; $1FE99F |/
  AND #$01                                  ; $1FE9A1 |\ if now odd → just toggled into right half
  BNE .check_tile                           ; $1FE9A3 |/ same metatile, re-read sub-tile
  ;--- crossed metatile boundary (X moved 32px) ---
  INC $28                                   ; $1FE9A5 |\ advance metatile column index
  LDA $28                                   ; $1FE9A7 | |
  AND #$07                                  ; $1FE9A9 | | crossed column group? (8 columns)
  BNE .new_column                           ; $1FE9AB |/ no → same screen, new column
  ;--- crossed screen boundary ---
  INC $13                                   ; $1FE9AD |\ next X screen
  DEC $28                                   ; $1FE9AF | | wrap column index back
  LDA $28                                   ; $1FE9B1 | | keep row bits, clear column
  AND #$38                                  ; $1FE9B3 | |
  STA $28                                   ; $1FE9B5 |/
  JMP .switch_bank                          ; $1FE9B7 |  re-load metatile data for new screen

  ;--- scan complete: check for player damage ---
.done_scan:
  CPX #$00                                  ; $1FE9BA |\ only check damage for player (slot 0)
  BNE .exit                                 ; $1FE9BC |/
  LDA $39                                   ; $1FE9BE |\ skip if invincibility active
  BNE .exit                                 ; $1FE9C0 |/
  LDA $3D                                   ; $1FE9C2 |\ skip if damage already pending
  BNE .exit                                 ; $1FE9C4 |/
  LDA $30                                   ; $1FE9C6 |\ skip if player in damage state ($06)
  CMP #$06                                  ; $1FE9C8 | |
  BEQ .exit                                 ; $1FE9CA |/
  CMP #$0E                                  ; $1FE9CC |\ skip if player in death state ($0E)
  BEQ .exit                                 ; $1FE9CE |/
  LDY #$06                                  ; $1FE9D0 |  Y = damage state
  LDA $41                                   ; $1FE9D2 |\ $30 = damage tile?
  CMP #$30                                  ; $1FE9D4 | |
  BEQ .set_damage                           ; $1FE9D6 |/ → set $3D = $06
  LDY #$0E                                  ; $1FE9D8 |  Y = death state
  CMP #$50                                  ; $1FE9DA |\ $50 = spike tile?
  BNE .exit                                 ; $1FE9DC |/ no hazard → skip
.set_damage:
  STY $3D                                   ; $1FE9DE |  set pending damage/death transition
.exit:
  JMP tile_check_cleanup                     ; $1FE9E0 |  restore bank and return

; -----------------------------------------------
; check_tile_collision — vertical-scan tile collision
; -----------------------------------------------
; Checks multiple Y positions at a fixed X offset for collisions.
; Used for wall detection (scanning down the entity's height at a
; specific horizontal position).
;
; parameters:
;   Y = hitbox config index into $ECE1 offset table
;   X = entity slot
; hitbox offset tables:
;   $ECE1,y = starting offset index (into $ED09)
;   $ED07,y = number of check points - 1
;   $ED08,y = X pixel offset (signed, relative to entity X)
;   $ED09,y = Y pixel offsets (signed, relative to entity Y)
; results:
;   $42-$44 = tile type at each check point
;   $41     = max (highest priority) tile type encountered
;   $10     = OR of all tile types (AND #$10 tests solid)
; -----------------------------------------------
check_tile_collision:
  LDA $ECE1,y                               ; $1FE9E3 |\ $40 = starting offset index
  STA $40                                   ; $1FE9E6 |/
  JSR tile_check_init                        ; $1FE9E8 |  clear accumulators, switch to stage bank
  TAY                                       ; $1FE9EB |  Y = hitbox config index
  LDA $ED07,y                               ; $1FE9EC |\ $02 = number of check points - 1
  STA $02                                   ; $1FE9EF |/
  ;--- compute fixed X position ---
  LDA #$00                                  ; $1FE9F1 |\ $04 = sign extension for X offset
  STA $04                                   ; $1FE9F3 |/
  LDA $ED08,y                               ; $1FE9F5 |\ X offset (signed)
  BPL .x_pos                                ; $1FE9F8 |/
  DEC $04                                   ; $1FE9FA |  negative: $04 = $FF
.x_pos:
  CLC                                       ; $1FE9FC |\ $12/$13 = entity_X + X_offset
  ADC $0360,x                               ; $1FE9FD | | $12 = X pixel
  STA $12                                   ; $1FEA00 | | $13 = X screen
  LDA $0380,x                               ; $1FEA02 | |
  ADC $04                                   ; $1FEA05 | |
  STA $13                                   ; $1FEA07 |/
  ;--- convert pixel X ($12) to metatile column/sub-tile ---
  LDA $12                                   ; $1FEA09 |\ X >> 4 = tile column
  LSR                                       ; $1FEA0B | |
  LSR                                       ; $1FEA0C | |
  LSR                                       ; $1FEA0D | |
  LSR                                       ; $1FEA0E |/
  PHA                                       ; $1FEA0F |\ $03 bit0 = sub-tile X (left/right)
  AND #$01                                  ; $1FEA10 | |
  STA $03                                   ; $1FEA12 |/
  PLA                                       ; $1FEA14 |\ $28 = metatile column (X>>5)
  LSR                                       ; $1FEA15 | |
  STA $28                                   ; $1FEA16 |/
  ;--- compute first Y check position ---
  LDA $03E0,x                               ; $1FEA18 |  Y screen
  BMI .y_above_screen                       ; $1FEA1B |  negative screen → clamp to 0
  BNE .y_below_screen                       ; $1FEA1D |  screen > 0 → clamp to $EF
  LDA $03C0,x                               ; $1FEA1F |\ $11 = entity_Y + first Y offset
  CLC                                       ; $1FEA22 | |
  ADC $ED09,y                               ; $1FEA23 | |
  STA $11                                   ; $1FEA26 |/
  LDA $ED09,y                               ; $1FEA28 |  check offset sign
  BPL .y_offset_pos                         ; $1FEA2B |  positive offset
  BCC .y_above_screen                       ; $1FEA2D |  neg offset + no carry = underflow
  BCS .y_check_f0                           ; $1FEA2F |  neg offset + carry = ok, check $F0
.y_offset_pos:
  BCS .y_below_screen                       ; $1FEA31 |  pos offset + carry = overflow
.y_check_f0:
  LDA $11                                   ; $1FEA33 |\ within screen ($00-$EF)?
  CMP #$F0                                  ; $1FEA35 | |
  BCC .y_ready                              ; $1FEA37 |/ yes → proceed to tile lookup
  BCS .y_offset_pos                         ; $1FEA39 |  wrapped past $F0 → below screen
.y_below_screen:
  LDA #$EF                                  ; $1FEA3B |\ clamp to bottom of screen
  STA $11                                   ; $1FEA3D | |
  BNE .y_ready                              ; $1FEA3F |/
.y_above_screen:
  LDA #$00                                  ; $1FEA41 |\ clamp to top of screen
  STA $11                                   ; $1FEA43 | |
  BEQ .y_ready                              ; $1FEA45 |/
  ;--- advance to next Y check point (offscreen skip loop) ---
.advance_y:
  LDA $11                                   ; $1FEA47 |\ $11 += next Y offset
  CLC                                       ; $1FEA49 | |
  ADC $ED09,y                               ; $1FEA4A | |
  STA $11                                   ; $1FEA4D |/
  CMP #$F0                                  ; $1FEA4F |\ crossed screen boundary?
  BCC .skip_point                           ; $1FEA51 |/ no → skip this point
  ADC #$10                                  ; $1FEA53 |\ wrap into next screen
  STA $11                                   ; $1FEA55 | |
  INC $04                                   ; $1FEA57 | | Y screen++
  BEQ .y_ready                              ; $1FEA59 |/ reached screen 0 → start checking
.skip_point:
  INY                                       ; $1FEA5B |\ advance offset index
  STY $40                                   ; $1FEA5C |/
  LDY $02                                   ; $1FEA5E |\ zero this check point's result
  LDA #$00                                  ; $1FEA60 | |
  STA $0042,y                               ; $1FEA62 |/
  DEC $02                                   ; $1FEA65 |\ more points? continue skipping
  BPL .advance_y                            ; $1FEA67 |/
  JMP tile_check_cleanup                     ; $1FEA69 |  all offscreen → done

  ;--- convert pixel Y ($11) to metatile row and begin scan ---
.y_ready:
  LDA $11                                   ; $1FEA6C |\ Y >> 2 = 4-pixel rows
  LSR                                       ; $1FEA6E | |
  LSR                                       ; $1FEA6F |/
  PHA                                       ; $1FEA70 |\ $28 |= metatile row (bits 5-3)
  AND #$38                                  ; $1FEA71 | | merged with column from X
  ORA $28                                   ; $1FEA73 | |
  STA $28                                   ; $1FEA75 |/
  PLA                                       ; $1FEA77 |\ $03 bit1 = sub-tile Y (top/bottom)
  LSR                                       ; $1FEA78 | |
  AND #$02                                  ; $1FEA79 | |
  ORA $03                                   ; $1FEA7B | |
  STA $03                                   ; $1FEA7D |/
  ;--- tile lookup loop: scan Y positions at fixed X ---
  STX $04                                   ; $1FEA7F |\ switch to stage PRG bank
  LDA $22                                   ; $1FEA81 | |
  STA $F5                                   ; $1FEA83 | |
  JSR select_PRG_banks                      ; $1FEA85 | |
  LDX $04                                   ; $1FEA88 |/ restore entity slot
  LDY $13                                   ; $1FEA8A |\ get metatile column pointer for X screen
  JSR metatile_column_ptr                    ; $1FEA8C |/
.new_row:
  JSR metatile_chr_ptr                       ; $1FEA8F |  get CHR data pointer for column+row ($28)
.check_tile:
  LDY $03                                   ; $1FEA92 |\ read metatile index at sub-tile ($03)
  LDA ($00),y                               ; $1FEA94 | |
  TAY                                       ; $1FEA96 |/
  LDA $BF00,y                               ; $1FEA97 |\ get collision attribute
  AND #$F0                                  ; $1FEA9A |/ upper nibble = collision type
  JSR breakable_block_collision              ; $1FEA9C |  override if destroyed breakable block
  JSR code_1FEB8A                           ; $1FEA9F |  Proto Man wall override
  LDY $02                                   ; $1FEAA2 |\ store result in $42+count
  STA $0042,y                               ; $1FEAA4 |/
  CMP $41                                   ; $1FEAA7 |\ update max tile type
  BCC .not_max                              ; $1FEAA9 | |
  STA $41                                   ; $1FEAAB |/
.not_max:
  ORA $10                                   ; $1FEAAD |\ accumulate all tile types
  STA $10                                   ; $1FEAAF |/
  DEC $02                                   ; $1FEAB1 |\ all check points done?
  BMI .done_scan                            ; $1FEAB3 |/
  ;--- advance to next Y check point ---
  INC $40                                   ; $1FEAB5 |\ next offset index
  LDY $40                                   ; $1FEAB7 |/
  LDA $11                                   ; $1FEAB9 |\ save old bit4 of Y (16px tile boundary)
  PHA                                       ; $1FEABB | |
  AND #$10                                  ; $1FEABC | |
  STA $04                                   ; $1FEABE |/
  PLA                                       ; $1FEAC0 |\ $11 += next Y offset
  CLC                                       ; $1FEAC1 | |
  ADC $ED09,y                               ; $1FEAC2 | |
  STA $11                                   ; $1FEAC5 |/
  AND #$10                                  ; $1FEAC7 |\ did bit4 change? (crossed 16px tile?)
  CMP $04                                   ; $1FEAC9 | |
  BEQ .check_tile                           ; $1FEACB |/ no → same tile, just re-read
  LDA $03                                   ; $1FEACD |\ toggle sub-tile Y (bit 1)
  EOR #$02                                  ; $1FEACF | |
  STA $03                                   ; $1FEAD1 |/
  AND #$02                                  ; $1FEAD3 |\ if now set → toggled into bottom half
  BNE .check_tile                           ; $1FEAD5 |/ same metatile, re-read sub-tile
  ;--- crossed metatile row boundary (Y moved 32px) ---
  LDA $28                                   ; $1FEAD7 |\ advance metatile row ($28 += $08)
  PHA                                       ; $1FEAD9 | |
  CLC                                       ; $1FEADA | |
  ADC #$08                                  ; $1FEADB | |
  STA $28                                   ; $1FEADD |/
  CMP #$40                                  ; $1FEADF |\ past screen bottom? ($40 = 8 rows)
  PLA                                       ; $1FEAE1 | |
  BCC .new_row                              ; $1FEAE2 |/ no → same screen, new row
  STA $28                                   ; $1FEAE4 |\ restore row, check last sub-tile
  JMP .check_tile                           ; $1FEAE6 |/ (clamp — don't scroll to next screen)

  ;--- scan complete: check for player spike damage ---
.done_scan:
  CPX #$00                                  ; $1FEAE9 |\ only check damage for player (slot 0)
  BNE .v_exit                               ; $1FEAEB |/
  LDA $39                                   ; $1FEAED |\ skip if invincibility active
  BNE .v_exit                               ; $1FEAEF |/
  LDA $3D                                   ; $1FEAF1 |\ skip if damage already pending
  BNE .v_exit                               ; $1FEAF3 |/
  LDA $30                                   ; $1FEAF5 |\ skip if player in damage state ($06)
  CMP #$06                                  ; $1FEAF7 | |
  BEQ .v_exit                               ; $1FEAF9 |/
  CMP #$0E                                  ; $1FEAFB |\ skip if player in death state ($0E)
  BEQ .v_exit                               ; $1FEAFD |/
  LDA $41                                   ; $1FEAFF |\ $50 = spike tile → instant kill
  CMP #$50                                  ; $1FEB01 | |
  BNE .v_exit                               ; $1FEB03 |/
  LDA #$0E                                  ; $1FEB05 |\ set pending death transition
  STA $3D                                   ; $1FEB07 |/
.v_exit:
  JMP tile_check_cleanup                     ; $1FEB09 |  restore bank and return

; -----------------------------------------------
; tile_check_init — initialize tile collision check
; -----------------------------------------------
; Clears result accumulators ($10, $41), saves the current PRG bank
; to $2F, and switches to the stage PRG bank ($22) so the tile
; collision code can read metatile/attribute data from $A000-$BFFF.
; Preserves A and X across the bank switch.
; -----------------------------------------------
tile_check_init:
  PHA                                       ; $1FEB0C |\ save A (table index)
  TXA                                       ; $1FEB0D | |
  PHA                                       ; $1FEB0E |/ save X (entity slot)
  LDA #$00                                  ; $1FEB0F |\ clear collision accumulators
  STA $10                                   ; $1FEB11 | | $10 = OR of all tile types
  STA $41                                   ; $1FEB13 |/ $41 = max tile type
  LDA $F5                                   ; $1FEB15 |\ save current PRG bank to $2F
  STA $2F                                   ; $1FEB17 |/
  LDA $22                                   ; $1FEB19 |\ switch to stage PRG bank
  STA $F5                                   ; $1FEB1B | |
  JSR select_PRG_banks                      ; $1FEB1D |/
  PLA                                       ; $1FEB20 |\ restore X and A
  TAX                                       ; $1FEB21 | |
  PLA                                       ; $1FEB22 |/
  RTS                                       ; $1FEB23 |

; -----------------------------------------------
; tile_check_cleanup — restore PRG bank after tile collision
; -----------------------------------------------
; Restores the PRG bank saved in $2F by tile_check_init.
; Preserves X.
; -----------------------------------------------
tile_check_cleanup:
  TXA                                       ; $1FEB24 |\ save X
  PHA                                       ; $1FEB25 |/
  LDA $2F                                   ; $1FEB26 |\ restore saved PRG bank
  STA $F5                                   ; $1FEB28 | |
  JSR select_PRG_banks                      ; $1FEB2A |/
  PLA                                       ; $1FEB2D |\ restore X
  TAX                                       ; $1FEB2E |/
  RTS                                       ; $1FEB2F |

; ===========================================================================
; breakable_block_collision — override tile type for destroyed blocks
; ===========================================================================
; Called during collision detection. If tile type is $70 (breakable block)
; and we're on Gemini Man stages ($22 = $02 or $09), checks the $0110
; destroyed-block bitfield. If the block is destroyed, overrides tile type
; to $00 (passthrough) so the player can walk through it.
;
; A = tile type on entry, X = caller context (preserved)
; Returns: A = tile type ($70 if intact, $00 if destroyed), X preserved
; ---------------------------------------------------------------------------
breakable_block_collision:
  STA $06                                   ; $1FEB30 | save tile type
  STX $05                                   ; $1FEB32 | save X
  CMP #$70                                  ; $1FEB34 |\ only handle $70 (breakable block)
  BNE .exit                                 ; $1FEB36 |/
  LDA $22                                   ; $1FEB38 |\ only on Gemini Man stages
  CMP #$02                                  ; $1FEB3A | | ($02 = Robot Master,
  BEQ .check_destroyed                      ; $1FEB3C | |  $09 = Doc Robot)
  CMP #$09                                  ; $1FEB3E | |
  BNE .exit                                 ; $1FEB40 |/
.check_destroyed:
  LDA $13                                   ; $1FEB42 |\ compute array index (same as
  AND #$01                                  ; $1FEB44 | | breakable_block_override):
  ASL                                       ; $1FEB46 | | Y = ($13 & 1) << 5 | ($28 >> 1)
  ASL                                       ; $1FEB47 | | ($13 = screen page for collision,
  ASL                                       ; $1FEB48 | |  $28 = metatile column position)
  ASL                                       ; $1FEB49 | |
  ASL                                       ; $1FEB4A | |
  STA $07                                   ; $1FEB4B |/
  LDA $28                                   ; $1FEB4D |
  PHA                                       ; $1FEB4F | save $28
  LSR                                       ; $1FEB50 |\ Y = byte index into $0110 array
  ORA $07                                   ; $1FEB51 | |
  TAY                                       ; $1FEB53 |/
  PLA                                       ; $1FEB54 |\ X = bit index within byte:
  ASL                                       ; $1FEB55 | | ($28 << 2) & $04 | $03 (quadrant)
  ASL                                       ; $1FEB56 | |
  AND #$04                                  ; $1FEB57 | |
  ORA $03                                   ; $1FEB59 | |
  TAX                                       ; $1FEB5B |/
  LDA $0110,y                               ; $1FEB5C |\ test destroyed bit
  AND bitmask_table,x                       ; $1FEB5F | |
  BEQ .exit                                 ; $1FEB62 |/ not destroyed → keep tile type
  LDA #$00                                  ; $1FEB64 |\ destroyed → override to passthrough
  STA $06                                   ; $1FEB66 |/
.exit:
  LDA $06                                   ; $1FEB68 | return tile type (maybe overridden)
  LDX $05                                   ; $1FEB6A | restore X
  RTS                                       ; $1FEB6C |

; ---------------------------------------------------------------------------
; clear_destroyed_blocks — reset the $0110 destroyed-block bitfield
; ---------------------------------------------------------------------------
; Called on stage init. Zeros all 64 bytes ($0110-$014F) on Gemini Man
; stages ($22 = $02 or $09), making all breakable blocks solid again.
; ---------------------------------------------------------------------------
clear_destroyed_blocks:
  LDA $22                                   ; $1FEB6D |\ only on Gemini Man stages
  CMP #$02                                  ; $1FEB6F | |
  BEQ .clear                                ; $1FEB71 | |
  CMP #$09                                  ; $1FEB73 | |
  BNE .skip                                 ; $1FEB75 |/
.clear:
  LDA #$00                                  ; $1FEB77 |\ zero $0110..$014F (64 bytes)
  LDY #$3F                                  ; $1FEB79 | | = 64 block slots
.loop:                                              ; |
  STA $0110,y                               ; $1FEB7B | |
  DEY                                       ; $1FEB7E | |
  BPL .loop                                 ; $1FEB7F |/
.skip:
  RTS                                       ; $1FEB81 |

bitmask_table:                                  ;         | bit 7..0 test masks
  db $80, $40, $20, $10, $08, $04, $02, $01 ; $1FEB82 |

; proto_man_wall_override: when $68 (cutscene-complete) is set,
; checks if player is at a Proto Man breakable wall position.
; if so, overrides tile type to $00 (passthrough) to open the path.
; table at $EBC6 maps stage → wall position data.
code_1FEB8A:
  STA $05                                   ; $1FEB8A |
  STX $06                                   ; $1FEB8C |
  STY $07                                   ; $1FEB8E |
  LDA $68                                   ; $1FEB90 |\ $68 = cutscene-complete flag
  BEQ code_1FEBB9                           ; $1FEB92 |/ no cutscene → skip
  LDY $22                                   ; $1FEB94 |
  LDX $EBC6,y                               ; $1FEB96 |
  BMI code_1FEBC0                           ; $1FEB99 |
  LDA $EBCE,x                               ; $1FEB9B |
  CMP $F9                                   ; $1FEB9E |
  BNE code_1FEBC0                           ; $1FEBA0 |
  LDA $EBCF,x                               ; $1FEBA2 |
  STA $08                                   ; $1FEBA5 |
  LDA $28                                   ; $1FEBA7 |
code_1FEBA9:
  CMP $EBD0,x                               ; $1FEBA9 |
  BEQ code_1FEBB5                           ; $1FEBAC |
  INX                                       ; $1FEBAE |
  DEC $08                                   ; $1FEBAF |
  BPL code_1FEBA9                           ; $1FEBB1 |
  BMI code_1FEBB9                           ; $1FEBB3 |
code_1FEBB5:
  LDA #$00                                  ; $1FEBB5 |
  BEQ code_1FEBBB                           ; $1FEBB7 |
code_1FEBB9:
  LDA $05                                   ; $1FEBB9 |
code_1FEBBB:
  LDX $06                                   ; $1FEBBB |
  LDY $07                                   ; $1FEBBD |
  RTS                                       ; $1FEBBF |

code_1FEBC0:
  LDA #$00                                  ; $1FEBC0 |
  STA $68                                   ; $1FEBC2 |
  BEQ code_1FEBB9                           ; $1FEBC4 |

  db $FF, $00, $11, $04, $FF, $FF, $FF, $0E ; $1FEBC6 |
  db $05, $01, $31, $39, $13, $07, $23, $24 ; $1FEBCE |
  db $2B, $2C, $33, $34, $3B, $3C, $05, $00 ; $1FEBD6 |
  db $31, $09, $00, $00, $00, $05, $09, $0E ; $1FEBDE |
  db $12, $16, $1A, $1F, $24, $28, $2C, $31 ; $1FEBE6 |
  db $36, $3B, $40, $45, $49, $4E, $53, $57 ; $1FEBEE |
  db $5B, $5F, $63, $68, $6C, $70, $75, $79 ; $1FEBF6 |
  db $7D, $81, $85, $8A, $8F, $94, $99, $9E ; $1FEBFE |
  db $A3, $A8, $AD, $B2, $B7, $BC, $C1, $C6 ; $1FEC06 |
  db $CB, $CE, $02, $0C, $F9, $07, $07, $01 ; $1FEC0E |
  db $F4, $F9, $0E, $02, $0A, $F1, $0F, $0F ; $1FEC16 |
  db $01, $00, $F9, $0E, $01, $00, $08, $0E ; $1FEC1E |
  db $01, $00, $EA, $0E, $00, $00, $00, $00 ; $1FEC26 |
  db $00, $02, $16, $F9, $07, $07, $01, $08 ; $1FEC2E |
  db $F9, $0E, $01, $F8, $F9, $0E, $02, $10 ; $1FEC36 |
  db $F5, $0B, $0B, $02, $F0, $F5, $0B, $0B ; $1FEC3E |
  db $02, $08, $FC, $04, $04, $00, $00, $00 ; $1FEC46 |
  db $00, $00, $02, $0C, $F5, $0B, $0B, $01 ; $1FEC4E |
  db $0C, $F5, $16, $02, $18, $F1, $0F, $0F ; $1FEC56 |
  db $02, $E8, $F1, $0F, $0F, $01, $04, $FD ; $1FEC5E |
  db $06, $01, $FC, $FD, $06, $01, $1C, $F9 ; $1FEC66 |
  db $0E, $01, $10, $F9, $07, $02, $E8, $F9 ; $1FEC6E |
  db $07, $07, $01, $06, $F9, $0E, $01, $08 ; $1FEC76 |
  db $F5, $16, $02, $F8, $F5, $0B, $0B, $01 ; $1FEC7E |
  db $0C, $F9, $0E, $01, $F4, $F9, $0E, $01 ; $1FEC86 |
  db $04, $F9, $0E, $01, $FC, $F9, $0E, $02 ; $1FEC8E |
  db $10, $F1, $0F, $0F, $02, $F0, $F1, $0F ; $1FEC96 |
  db $0F, $02, $0D, $F5, $0B, $0B, $02, $F3 ; $1FEC9E |
  db $F5, $0B, $0B, $02, $10, $F1, $0F, $0F ; $1FECA6 |
  db $02, $E6, $F1, $0F, $0F, $02, $14, $F1 ; $1FECAE |
  db $0F, $0F, $02, $00, $00, $00, $00, $02 ; $1FECB6 |
  db $14, $F0, $10, $10, $02, $EC, $F0, $10 ; $1FECBE |
  db $10, $02, $18, $F1, $0F, $0F, $02, $E8 ; $1FECC6 |
  db $F1, $0F, $0F, $02, $1C, $F5, $0B, $0B ; $1FECCE |
  db $02, $DC, $F5, $0B, $0B, $00, $04, $00 ; $1FECD6 |
  db $00, $08, $00, $00, $05, $0A, $0E, $12 ; $1FECDE |
  db $17, $1C, $21, $26, $2A, $2E, $33, $38 ; $1FECE6 |
  db $3D, $42, $49, $50, $57, $5E, $65, $6C ; $1FECEE |
  db $71, $76, $7B, $80, $85, $8A, $8F, $94 ; $1FECF6 |
  db $99, $9E, $A2, $A6, $AB, $B0, $B5, $BA ; $1FECFE |
  db $BF, $02, $08, $F5, $0B, $0B, $02, $F8 ; $1FED06 |
  db $F5, $0B, $0B, $01, $10, $FB, $0C, $01 ; $1FED0E |
  db $F0, $FB, $0C, $02, $00, $F5, $0B, $0B ; $1FED16 |
  db $00, $00, $00, $00, $00, $00, $00, $00 ; $1FED1E |
  db $00, $00, $00, $00, $00, $00, $00, $01 ; $1FED26 |
  db $08, $F9, $0E, $01, $F8, $F9, $0E, $01 ; $1FED2E |
  db $0C, $F5, $0B, $0B, $02, $F4, $F5, $0B ; $1FED36 |
  db $0B, $02, $0C, $F5, $0B, $0B, $02, $F4 ; $1FED3E |
  db $F5, $0B, $0B, $04, $10, $E9, $10, $07 ; $1FED46 |
  db $10, $07, $04, $F0, $E9, $10, $07, $10 ; $1FED4E |
  db $07, $04, $0C, $E5, $10, $0B, $10, $0B ; $1FED56 |
  db $04, $F4, $E5, $10, $0B, $10, $0B, $04 ; $1FED5E |
  db $08, $E5, $10, $0B, $10, $0B, $01, $F8 ; $1FED66 |
  db $E5, $10, $0B, $10, $0B, $02, $10, $F1 ; $1FED6E |
  db $0F, $0F, $02, $F0, $F1, $0F, $0F, $02 ; $1FED76 |
  db $14, $F5, $0B, $0B, $02, $EC, $F5, $0B ; $1FED7E |
  db $0B, $02, $0C, $F9, $07, $07, $02, $F4 ; $1FED86 |
  db $F9, $07, $07, $02, $0C, $F9, $07, $07 ; $1FED8E |
  db $02, $F4, $F9, $07, $07, $02, $0C, $F9 ; $1FED96 |
  db $07, $07, $02, $F4, $F9, $07, $07, $01 ; $1FED9E |
  db $04, $FD, $06, $01, $FC, $FD, $06, $02 ; $1FEDA6 |
  db $10, $F1, $0F, $0F, $02, $F0, $F1, $0F ; $1FEDAE |
  db $0F, $02, $14, $EC, $14, $14, $02, $EC ; $1FEDB6 |
  db $EC, $14, $14, $02, $10, $E8, $18, $18 ; $1FEDBE |
  db $02, $F0, $E8, $18, $18                ; $1FEDC6 |

; -----------------------------------------------
; snap_x_to_wall_right — push entity left after hitting a wall on its right
; -----------------------------------------------
; After a rightward collision, aligns entity X to the left edge of the
; solid tile. $12 = collision check X; lower 4 bits = how far into the
; 16-pixel tile. Subtracts that offset from entity X position.
; -----------------------------------------------
snap_x_to_wall_right:
  LDA $12                                   ; $1FEDCB |\ offset = $12 & $0F
  AND #$0F                                  ; $1FEDCD | | (sub-tile penetration depth)
  STA $12                                   ; $1FEDCF |/
  LDA $0360,x                               ; $1FEDD1 |\ X pixel -= offset
  SEC                                       ; $1FEDD4 | | (push entity left)
  SBC $12                                   ; $1FEDD5 | |
  STA $0360,x                               ; $1FEDD7 |/
  LDA $0380,x                               ; $1FEDDA |\ X screen -= borrow
  SBC #$00                                  ; $1FEDDD | |
  STA $0380,x                               ; $1FEDDF |/
  RTS                                       ; $1FEDE2 |

; -----------------------------------------------
; snap_x_to_wall_left — push entity right after hitting a wall on its left
; -----------------------------------------------
; After a leftward collision, aligns entity X to the right edge of the
; solid tile + 1. $12 = collision check X; computes (16 - offset) and
; adds to entity X. EOR #$0F + SEC/ADC = add (16 - low_nibble).
; -----------------------------------------------
snap_x_to_wall_left:
  LDA $12                                   ; $1FEDE3 |\ offset = ($12 & $0F) ^ $0F
  AND #$0F                                  ; $1FEDE5 | | = 15 - sub-tile position
  EOR #$0F                                  ; $1FEDE7 |/
  SEC                                       ; $1FEDE9 |\ X pixel += (16 - sub_tile_pos)
  ADC $0360,x                               ; $1FEDEA | | SEC + ADC = add offset + 1
  STA $0360,x                               ; $1FEDED | | (push entity right)
  LDA $0380,x                               ; $1FEDF0 | | X screen += carry
  ADC #$00                                  ; $1FEDF3 | |
  STA $0380,x                               ; $1FEDF5 |/
  RTS                                       ; $1FEDF8 |

; -----------------------------------------------
; snap_y_to_ceil — push entity down after hitting a ceiling above
; -----------------------------------------------
; After an upward collision, aligns entity Y to the bottom of the
; solid tile + 1. Same math as snap_x_to_wall_left but for Y axis.
; Handles downward screen wrap at Y=$F0.
; -----------------------------------------------
snap_y_to_ceil:
  LDA $11                                   ; $1FEDF9 |\ offset = ($11 & $0F) ^ $0F
  AND #$0F                                  ; $1FEDFB | |
  EOR #$0F                                  ; $1FEDFD |/
  SEC                                       ; $1FEDFF |\ Y pixel += (16 - sub_tile_pos)
  ADC $03C0,x                               ; $1FEE00 | | (push entity down)
  STA $03C0,x                               ; $1FEE03 |/
  CMP #$F0                                  ; $1FEE06 |\ screen height = $F0
  BCC .done                                 ; $1FEE08 |/ within screen? done
  ADC #$0F                                  ; $1FEE0A |\ wrap to next screen down
  STA $03C0,x                               ; $1FEE0C | |
  INC $03E0,x                               ; $1FEE0F |/ Y screen++
.done:
  RTS                                       ; $1FEE12 |

; -----------------------------------------------
; snap_y_to_floor — push entity up after landing on a floor below
; -----------------------------------------------
; After a downward collision, aligns entity Y to the top of the
; solid tile. $11 = collision check Y; subtracts low nibble from
; entity Y. Preserves $11 (restored from stack after adjustment).
; Handles upward screen wrap (underflow).
; -----------------------------------------------
snap_y_to_floor:
  LDA $11                                   ; $1FEE13 |\ save original $11
  PHA                                       ; $1FEE15 |/
  AND #$0F                                  ; $1FEE16 |\ offset = $11 & $0F
  STA $11                                   ; $1FEE18 |/ (sub-tile penetration depth)
  LDA $03C0,x                               ; $1FEE1A |\ Y pixel -= offset
  SEC                                       ; $1FEE1D | | (push entity up)
  SBC $11                                   ; $1FEE1E | |
  STA $03C0,x                               ; $1FEE20 |/
  BCS .no_wrap                              ; $1FEE23 |\ no underflow? done
  SBC #$0F                                  ; $1FEE25 |\ wrap to previous screen
  STA $03C0,x                               ; $1FEE27 | |
  DEC $03E0,x                               ; $1FEE2A |/ Y screen--
.no_wrap:
  PLA                                       ; $1FEE2D |\ restore original $11
  STA $11                                   ; $1FEE2E |/
  RTS                                       ; $1FEE30 |

; ===========================================================================
; call_bank10_8000 / call_bank10_8003 — bank $10 trampolines
; ===========================================================================
; Save current $8000-$9FFF bank, switch to bank $10, call entry point
; ($8000 or $8003), then restore original bank. Called from player cutscene
; state machine (code_1FE2F4, code_1FE338). Bank $10 contains cutscene/
; scripted sequence routines.
; ---------------------------------------------------------------------------
call_bank10_8000:
  LDA $F4                                   ; $1FEE31 |\ save current $8000 bank
  PHA                                       ; $1FEE33 |/
  LDA #$10                                  ; $1FEE34 |\ switch $8000-$9FFF to bank $10
  STA $F4                                   ; $1FEE36 | |
  JSR select_PRG_banks                      ; $1FEE38 |/
  JSR $8000                                 ; $1FEE3B | call bank $10 entry point 0
  PLA                                       ; $1FEE3E |\ restore original $8000 bank
  STA $F4                                   ; $1FEE3F | |
  JMP select_PRG_banks                      ; $1FEE41 |/

call_bank10_8003:
  LDA $F4                                   ; $1FEE44 |\ save current $8000 bank
  PHA                                       ; $1FEE46 |/
  LDA #$10                                  ; $1FEE47 |\ switch $8000-$9FFF to bank $10
  STA $F4                                   ; $1FEE49 | |
  JSR select_PRG_banks                      ; $1FEE4B |/
  JSR $8003                                 ; $1FEE4E | call bank $10 entry point 1
  PLA                                       ; $1FEE51 |\ restore original $8000 bank
  STA $F4                                   ; $1FEE52 | |
  JMP select_PRG_banks                      ; $1FEE54 |/

; ===========================================================================
; queue_metatile_clear — queue a 2×2 blank metatile write to PPU
; ===========================================================================
; Converts entity X's screen position ($0360,x / $03C0,x) to a PPU nametable
; address and fills the NMI update buffer ($0780+) with two 2-tile rows of
; blank tiles ($00). NMI's code_1EC4F8 drains this buffer during VBlank.
;
; Buffer format: [addr_hi][addr_lo][count][tile × (count+1)]...[FF=end]
; This builds two entries (top row + bottom row of metatile) + terminator.
;
; Input:  X = entity slot index
; Output: C=0 on success (buffer queued), C=1 if PPU update already pending
; Clobbers: $0780-$078A, $19
; Called from: bank1C_1D (tile destruction / block breaking)
; ---------------------------------------------------------------------------
queue_metatile_clear:
  SEC                                       ; $1FEE57 | preset carry = fail
  LDA $1A                                   ; $1FEE58 |\ if nametable column or row
  ORA $19                                   ; $1FEE5A | | update already pending,
  BNE .ret                                  ; $1FEE5C |/ return C=1 (busy)
  LDA #$08                                  ; $1FEE5E |\ seed high byte = $08
  STA $0780                                 ; $1FEE60 |/ (becomes $20-$23 after shifts)
  LDA $03C0,x                               ; $1FEE63 |\ entity Y, upper nibble = metatile row
  AND #$F0                                  ; $1FEE66 | | ASL×2 with ROL into $0780:
  ASL                                       ; $1FEE68 | | row * 64 → PPU row offset
  ROL $0780                                 ; $1FEE69 | | (each metatile = 2 tile rows × 32)
  ASL                                       ; $1FEE6C | |
  ROL $0780                                 ; $1FEE6D | |
  STA $0781                                 ; $1FEE70 |/ low byte = row component
  LDA $0360,x                               ; $1FEE73 |\ entity X, upper nibble
  AND #$F0                                  ; $1FEE76 | | LSR×3 = metatile column × 2
  LSR                                       ; $1FEE78 | | (each metatile = 2 tiles wide)
  LSR                                       ; $1FEE79 | |
  LSR                                       ; $1FEE7A | |
  ORA $0781                                 ; $1FEE7B | |
  STA $0781                                 ; $1FEE7E |/ combine row + column
  ORA #$20                                  ; $1FEE81 |\ addr + 32 = next tile row
  STA $0786                                 ; $1FEE83 |/ (second entry low byte)
  LDA #$01                                  ; $1FEE86 |\ count = 1 → write 2 tiles per row
  STA $0782                                 ; $1FEE88 | |
  STA $0787                                 ; $1FEE8B |/
  LDA $0780                                 ; $1FEE8E |\ copy high byte for second entry
  STA $0785                                 ; $1FEE91 |/
  LDA #$00                                  ; $1FEE94 |\ tile data = $00 (blank) for all 4
  STA $0783                                 ; $1FEE96 | |
  STA $0784                                 ; $1FEE99 | |
  STA $0788                                 ; $1FEE9C | |
  STA $0789                                 ; $1FEE9F |/
  LDA #$FF                                  ; $1FEEA2 |\ terminator
  STA $078A                                 ; $1FEEA4 |/
  STA $19                                   ; $1FEEA7 | flag NMI to process buffer
  CLC                                       ; $1FEEA9 | success
.ret:
  RTS                                       ; $1FEEAA |

; ===========================================================================
; queue_metatile_update — build PPU update buffer for a 4×4 tile metatile
; ===========================================================================
; Converts metatile position ($28) to PPU nametable addresses and builds
; a 5-entry NMI update buffer at $0780: four 4-tile rows + one attribute
; byte. Tile data is sourced from $06C0-$06CF (filled by metatile_to_chr_tiles).
;
; $28 = metatile index (low 3 bits = column, upper bits = row)
; $10 = nametable select (bit 2: 0=$2000, 4=$2400)
; $68 = cutscene-complete flag (selects alternate tile lookup path)
; Y  = metatile ID (when $68=0, passed to code_1FE8B4)
;
; Buffer layout: 4 row entries (7 bytes each) + 1 attribute entry + $FF end
;   Entry: [addr_hi][addr_lo][count=3][tile0][tile1][tile2][tile3]
;   Attr:  [attr_addr_hi][attr_addr_lo][count=0][attr_byte][$FF]
;
; Edge case: if metatile row >= $38 (bottom of nametable), the attribute
; entry overwrites the 3rd row entry to avoid writing past nametable bounds.
;
; Called from: bank09 (enemy spawning), bank0C (level loading), bank18
; ---------------------------------------------------------------------------
queue_metatile_update:
  LDA $28                                   ; $1FEEAB |\ save metatile index
  PHA                                       ; $1FEEAD |/
  AND #$07                                  ; $1FEEAE |\ column bits × 4 = PPU column offset
  ASL                                       ; $1FEEB0 | | (4 tiles wide per metatile)
  ASL                                       ; $1FEEB1 | |
  STA $0781                                 ; $1FEEB2 |/
  LDA #$02                                  ; $1FEEB5 |\ seed high byte = $02
  STA $0780                                 ; $1FEEB7 |/ (becomes $20+ after shifts)
  PLA                                       ; $1FEEBA |\ row bits (upper 5 bits of $28)
  AND #$F8                                  ; $1FEEBB | | ASL×4 with ROL = row × 128
  ASL                                       ; $1FEEBD | | (each metatile row = 4 tile rows
  ROL $0780                                 ; $1FEEBE | |  × 32 bytes = 128)
  ASL                                       ; $1FEEC1 | |
  ROL $0780                                 ; $1FEEC2 | |
  ASL                                       ; $1FEEC5 | |
  ROL $0780                                 ; $1FEEC6 | |
  ASL                                       ; $1FEEC9 | |
  ROL $0780                                 ; $1FEECA | |
  ORA $0781                                 ; $1FEECD | |
  STA $0781                                 ; $1FEED0 |/ row 0 addr low byte
  CLC                                       ; $1FEED3 |
  ADC #$20                                  ; $1FEED4 |\ row 1 addr low = row 0 + 32
  STA $0788                                 ; $1FEED6 |/
  ADC #$20                                  ; $1FEED9 |\ row 2 addr low = row 1 + 32
  STA $078F                                 ; $1FEEDB |/
  ADC #$20                                  ; $1FEEDE |\ row 3 addr low = row 2 + 32
  STA $0796                                 ; $1FEEE0 |/
  LDA $28                                   ; $1FEEE3 |\ attribute addr low = $28 OR $C0
  ORA #$C0                                  ; $1FEEE5 | | (attribute table offset)
  STA $079D                                 ; $1FEEE7 |/
  LDA $0780                                 ; $1FEEEA |\ merge nametable select bit
  ORA $10                                   ; $1FEEED | | into all row high bytes
  STA $0780                                 ; $1FEEEF | | (rows 0-3 share same high byte)
  STA $0787                                 ; $1FEEF2 | |
  STA $078E                                 ; $1FEEF5 | |
  STA $0795                                 ; $1FEEF8 |/
  ORA #$03                                  ; $1FEEFB |\ attribute high byte = $23 or $27
  STA $079C                                 ; $1FEEFD |/
  LDA #$03                                  ; $1FEF00 |\ count = 3 → 4 tiles per row
  STA $0782                                 ; $1FEF02 | |
  STA $0789                                 ; $1FEF05 | |
  STA $0790                                 ; $1FEF08 | |
  STA $0797                                 ; $1FEF0B |/
  LDA #$00                                  ; $1FEF0E |\ attribute entry count = 0 (1 byte)
  STA $079E                                 ; $1FEF10 |/
  LDA $68                                   ; $1FEF13 |\ cutscene-complete flag?
  BEQ .normal_lookup                        ; $1FEF15 |/ no → normal metatile lookup
  LDA #$00                                  ; $1FEF17 |\ alternate path: use $11 (scroll pos)
  STA $01                                   ; $1FEF19 | | for CHR tile offset calculation
  LDA $11                                   ; $1FEF1B | |
  JSR .calc_chr_offset                      ; $1FEF1D | |
  JSR metatile_to_chr_tiles_continue        ; $1FEF20 | |
  JMP .copy_tiles                           ; $1FEF23 |/
.normal_lookup:
  TYA                                       ; $1FEF26 |\ Y = metatile ID
  JSR code_1FE8B4                           ; $1FEF27 | | look up metatile definition
  JSR metatile_to_chr_tiles                  ; $1FEF2A |/ convert to CHR tile indices
.copy_tiles:
  LDX #$03                                  ; $1FEF2D |\ copy 4×4 tile data from $06C0-$06CF
.copy_loop:                                          ; | into PPU buffer data slots
  LDA $06C0,x                               ; $1FEF2F | | row 0: $06C0-$06C3 → $0783-$0786
  STA $0783,x                               ; $1FEF32 | |
  LDA $06C4,x                               ; $1FEF35 | | row 1: $06C4-$06C7 → $078A-$078D
  STA $078A,x                               ; $1FEF38 | |
  LDA $06C8,x                               ; $1FEF3B | | row 2: $06C8-$06CB → $0791-$0794
  STA $0791,x                               ; $1FEF3E | |
  LDA $06CC,x                               ; $1FEF41 | | row 3: $06CC-$06CF → $0798-$079B
  STA $0798,x                               ; $1FEF44 | |
  DEX                                       ; $1FEF47 | |
  BPL .copy_loop                            ; $1FEF48 |/
  LDA $10                                   ; $1FEF4A |\ attribute byte = nametable select
  STA $079F                                 ; $1FEF4C |/
  STX $07A0                                 ; $1FEF4F | terminator ($FF from DEX past 0)
  LDA $28                                   ; $1FEF52 |\ if metatile row >= $38 (bottom edge),
  AND #$3F                                  ; $1FEF54 | | row 3+4 would overflow nametable.
  CMP #$38                                  ; $1FEF56 | | Move attribute entry up to replace
  BCC .done                                 ; $1FEF58 |/ row 3 entry to avoid overflow.
  LDX #$04                                  ; $1FEF5A |\ copy attribute entry ($079C-$07A0)
.overflow_fix:                                       ; | over row 3 entry ($078E-$0792)
  LDA $079C,x                               ; $1FEF5C | |
  STA $078E,x                               ; $1FEF5F | |
  DEX                                       ; $1FEF62 | |
  BPL .overflow_fix                         ; $1FEF63 |/
.done:
  STX $19                                   ; $1FEF65 | flag NMI to process buffer
  RTS                                       ; $1FEF67 |

; ===========================================================================
; write_attribute_table — queue attribute table write to PPU
; ===========================================================================
; Called after fill_nametable_progressive finishes all 64 metatile columns.
; Copies the 64-byte attribute buffer ($0640-$067F) to the PPU write queue,
; targeting PPU $23C0 (attribute table of nametable 0 or 1 based on $10).
; Resets $70 to 0 so the nametable fill can restart if needed.
; ---------------------------------------------------------------------------
write_attribute_table:
  LDA #$00                                  ; $1FEF68 | reset progress counter
  STA $70                                   ; $1FEF6A |
  LDA #$23                                  ; $1FEF6C |\ PPU address high byte: $23 or $27
  ORA $10                                   ; $1FEF6E | | ($10 bit 2 = nametable select)
  STA $0780                                 ; $1FEF70 |/
  LDA #$C0                                  ; $1FEF73 |\ PPU address low byte: $C0
  STA $0781                                 ; $1FEF75 |/ (attribute table start)
  LDY #$3F                                  ; $1FEF78 |\ count = 64 bytes ($3F+1)
  STY $0782                                 ; $1FEF7A |/
.copy_attr:
  LDA $0640,y                               ; $1FEF7D |\ copy attribute buffer to PPU queue
  STA $0783,y                               ; $1FEF80 |/
  DEY                                       ; $1FEF83 |
  BPL .copy_attr                            ; $1FEF84 |
  STY $07C3                                 ; $1FEF86 | $FF terminator after data
  STY $19                                   ; $1FEF89 | signal NMI to process queue
  RTS                                       ; $1FEF8B |

; ===========================================================================
; fill_nametable_progressive — fill nametable 4 metatile columns at a time
; ===========================================================================
; Called once per frame during level loading. Progress counter $70 tracks
; the current metatile column (0-63). Each call processes 4 columns,
; converting metatiles to CHR tiles and queuing them for PPU writes.
;
; Each metatile column = 2 CHR tiles wide. 4 columns = 8 tiles = one row
; group. The PPU write queue gets 4 entries (one per tile row), each
; containing 16 tiles ($0F + 1). After all 64 columns ($70=$40), branches
; to write_attribute_table.
;
; PPU address layout: $70 maps to nametable position:
;   - Low 3 bits × 4 = tile column offset within row
;   - High 5 bits × 16 = tile row offset (each row = 32 bytes)
;
; $10 = nametable select (bit 2: 0=NT0, 4=NT1).
; $28 = working column index within the 4-column group.
; $0640 = attribute buffer (one byte per metatile column).
; ---------------------------------------------------------------------------
fill_nametable_progressive:
  LDA $70                                   ; $1FEF8C |\ if $70 == $40 (64), all done
  CMP #$40                                  ; $1FEF8E | | → write attribute table and reset
  BEQ write_attribute_table                 ; $1FEF90 |/
  STA $28                                   ; $1FEF92 | $28 = working column index
; --- Compute PPU base address from $70 ---
; Column ($70 & $07) × 4 → low byte offset.
; Row ($70 & $F8) << 4 → high byte bits.
  PHA                                       ; $1FEF94 |
  AND #$07                                  ; $1FEF95 |\ column within row group × 4
  ASL                                       ; $1FEF97 | |
  ASL                                       ; $1FEF98 | |
  STA $0781                                 ; $1FEF99 |/ → PPU addr low byte (partial)
  LDA #$02                                  ; $1FEF9C |\ seed high byte = $02
  STA $0780                                 ; $1FEF9E |/ (nametable $2000 base >> 8)
  PLA                                       ; $1FEFA1 |
  AND #$F8                                  ; $1FEFA2 |\ row index × 128 via shift+rotate:
  ASL                                       ; $1FEFA4 | | ($70 & $F8) << 4 into high/low
  ROL $0780                                 ; $1FEFA5 | |
  ASL                                       ; $1FEFA8 | |
  ROL $0780                                 ; $1FEFA9 | |
  ASL                                       ; $1FEFAC | |
  ROL $0780                                 ; $1FEFAD | |
  ASL                                       ; $1FEFB0 | |
  ROL $0780                                 ; $1FEFB1 |/
  ORA $0781                                 ; $1FEFB4 |\ merge low byte parts
  STA $0781                                 ; $1FEFB7 |/
; --- Set up 4 PPU write entries (4 tile rows) ---
; Each entry is 19 bytes apart ($13). Low bytes advance by $20 (one row).
  CLC                                       ; $1FEFBA |
  ADC #$20                                  ; $1FEFBB | row 1 low byte
  STA $0794                                 ; $1FEFBD |
  ADC #$20                                  ; $1FEFC0 | row 2 low byte
  STA $07A7                                 ; $1FEFC2 |
  ADC #$20                                  ; $1FEFC5 | row 3 low byte
  STA $07BA                                 ; $1FEFC7 |
  LDA $0780                                 ; $1FEFCA |\ high byte + nametable select ($10)
  ORA $10                                   ; $1FEFCD | | same for all 4 entries
  STA $0780                                 ; $1FEFCF | |
  STA $0793                                 ; $1FEFD2 | |
  STA $07A6                                 ; $1FEFD5 | |
  STA $07B9                                 ; $1FEFD8 |/
  LDA #$0F                                  ; $1FEFDB |\ tile count = 16 ($0F+1) per entry
  STA $0782                                 ; $1FEFDD | |
  STA $0795                                 ; $1FEFE0 | |
  STA $07A8                                 ; $1FEFE3 | |
  STA $07BB                                 ; $1FEFE6 |/
; --- Process 4 metatile columns ---
.convert_column:
  JSR metatile_to_chr_tiles                 ; $1FEFE9 | convert metatile → 16 tiles in $06C0
  LDA $28                                   ; $1FEFEC |\ which column within group? (0-3)
  AND #$03                                  ; $1FEFEE | | determines position within entries
  TAX                                       ; $1FEFF0 |/
  LDY $F030,x                               ; $1FEFF1 | Y = starting offset {$03,$07,$0B,$0F}
  LDX #$00                                  ; $1FEFF4 | X = source offset into $06C0
.distribute_tiles:
  LDA $06C0,x                               ; $1FEFF6 |\ copy 4 tiles from $06C0
  STA $0780,y                               ; $1FEFF9 | | to current position in PPU entry
  INY                                       ; $1FEFFC | |
  INX                                       ; $1FEFFD | |
  TXA                                       ; $1FEFFE | |
  AND #$03                                  ; $1FEFFF | | (4 tiles per row)
  BNE .distribute_tiles                     ; $1FF001 |/
  TYA                                       ; $1FF003 |\ skip to next entry (+$0F)
  CLC                                       ; $1FF004 | |
  ADC #$0F                                  ; $1FF005 |/
  PHA                                       ; $1FF007 |
  LDY $28                                   ; $1FF008 |\ store attribute byte for this column
  LDA $10                                   ; $1FF00A | |
  STA $0640,y                               ; $1FF00C |/
  PLA                                       ; $1FF00F |
  TAY                                       ; $1FF010 |
  CPY #$4C                                  ; $1FF011 |\ loop until all 4 rows filled
  BCC .distribute_tiles                     ; $1FF013 |/ (Y < $4C → more rows)
  INC $70                                   ; $1FF015 | advance progress counter
  INC $28                                   ; $1FF017 | advance working column
  LDA $28                                   ; $1FF019 |\ repeat for 4 columns total
  AND #$03                                  ; $1FF01B | |
  BNE .convert_column                       ; $1FF01D |/
  LDA #$FF                                  ; $1FF01F |\ $FF terminator after 4th entry
  STA $07CC                                 ; $1FF021 |/
  LDY $28                                   ; $1FF024 |\ if past row 28 ($39 columns),
  CPY #$39                                  ; $1FF026 | | disable 3rd PPU entry (rows 29-30
  BCC .finish                               ; $1FF028 | | would overflow nametable)
  STA $07A6                                 ; $1FF02A |/ terminate 3rd entry early
.finish:
  STA $19                                   ; $1FF02D | signal NMI to process PPU queue
  RTS                                       ; $1FF02F |

; PPU entry column offsets — maps column-within-group (0-3) to starting
; byte offset within each PPU write entry's data area.
ppu_column_offsets:
  db $03, $07, $0B, $0F                     ; $1FF030 |

; --- update_entity_sprites ---
; main per-frame entity rendering loop
; iterates all 32 entity slots (0-31), alternating direction each frame
; on even frames: draws HUD first, then slots 0→31
; on odd frames: slots 31→0, then draws HUD
; $95 = global frame counter, $96 = current slot index
; $97 = OAM buffer write index (used by sprite assembly routines)
update_entity_sprites:
  INC $95                                   ; $1FF034 | advance global frame counter
  INC $4F                                   ; $1FF036 | advance secondary counter
  LDA $95                                   ; $1FF038 |\
  LSR                                       ; $1FF03A | | even frame? forward iteration
  BCS .reverse                              ; $1FF03B |/  odd? reverse
  JSR draw_energy_bars                      ; $1FF03D | draw HUD bars first on even frames
  LDX #$00                                  ; $1FF040 |\
  STX $96                                   ; $1FF042 |/ start at slot 0
.loop_fwd:
  LDA $0300,x                               ; $1FF044 |\ bit 7 = entity active
  BPL .skip_fwd                             ; $1FF047 |/ skip inactive
  JSR process_entity_display                ; $1FF049 | render this entity
.skip_fwd:
  INC $96                                   ; $1FF04C |\
  LDX $96                                   ; $1FF04E | | next slot
  CPX #$20                                  ; $1FF050 | | 32 slots total
  BNE .loop_fwd                             ; $1FF052 |/
  RTS                                       ; $1FF054 |

.reverse:
  LDX #$1F                                  ; $1FF055 |\
  STX $96                                   ; $1FF057 |/ start at slot 31
.loop_rev:
  LDA $0300,x                               ; $1FF059 |\ bit 7 = entity active
  BPL .skip_rev                             ; $1FF05C |/ skip inactive
  JSR process_entity_display                ; $1FF05E | render this entity
.skip_rev:
  DEC $96                                   ; $1FF061 |\
  LDX $96                                   ; $1FF063 | | previous slot
  BPL .loop_rev                             ; $1FF065 |/
  JSR draw_energy_bars                      ; $1FF067 | draw HUD bars last on odd frames
  RTS                                       ; $1FF06A |

; --- process_entity_display ---
; per-entity display handler: screen culling, death/damage, OAM assembly
; X = entity slot index (0-31)
; $FC/$F9 = camera scroll X pixel/screen
; $12/$13 = screen Y/X position for OAM drawing
process_entity_display:
  LDA $0580,x                               ; $1FF06B |\
  AND #$10                                  ; $1FF06E | | bit 4 = uses world coordinates
  BEQ .screen_fixed                         ; $1FF070 |/  (needs camera subtraction)
  LDA $0360,x                               ; $1FF072 |\
  SEC                                       ; $1FF075 | | screen X = entity X - camera X
  SBC $FC                                   ; $1FF076 | |
  STA $13                                   ; $1FF078 |/
  LDA $0380,x                               ; $1FF07A |\ entity X screen - camera screen
  SBC $F9                                   ; $1FF07D | | if different screen, offscreen
  BNE .diff_screen                          ; $1FF07F |/
  LDA $03E0,x                               ; $1FF081 |\ Y screen = 0? → on same screen
  BEQ .set_draw_pos                         ; $1FF084 |/
  CPX #$00                                  ; $1FF086 |\ player? keep visible
  BEQ .on_screen                            ; $1FF088 |/
  LDA $03E0,x                               ; $1FF08A |\ Y screen negative? keep visible
  BMI .on_screen                            ; $1FF08D |/ Y screen positive? deactivate
  BPL .deactivate                           ; $1FF08F |
.diff_screen:
  LDA $0580,x                               ; $1FF091 |\ bit 3 = wide offscreen margin
  AND #$08                                  ; $1FF094 | | (keep alive within 72px of edge)
  BEQ .deactivate                           ; $1FF096 |/
  LDA $13                                   ; $1FF098 |\ take absolute value of screen X
  BCS .check_margin                         ; $1FF09A | |
  EOR #$FF                                  ; $1FF09C | | negate if negative
  ADC #$01                                  ; $1FF09E |/
.check_margin:
  CMP #$48                                  ; $1FF0A0 |\ within 72px margin?
  BCC .on_screen                            ; $1FF0A2 |/ yes → keep alive
.deactivate:
  LDA #$00                                  ; $1FF0A4 |\ deactivate entity
  STA $0300,x                               ; $1FF0A6 |/
  LDA #$FF                                  ; $1FF0A9 |\ mark as despawned
  STA $04C0,x                               ; $1FF0AB |/
  RTS                                       ; $1FF0AE |

.on_screen:
  LDA $0580,x                               ; $1FF0AF |\
  AND #$7F                                  ; $1FF0B2 | | clear bit 7 (drawn flag)
  STA $0580,x                               ; $1FF0B4 |/
  CPX #$00                                  ; $1FF0B7 |\ not player? skip to sprite draw
  BNE .draw                                 ; $1FF0B9 |/
  LDA $17                                   ; $1FF0BB |\ $17 bit 0 = ??? flag
  AND #$01                                  ; $1FF0BD | |
  BNE .player_check_landing                 ; $1FF0BF |/
  LDA $03E0                                 ; $1FF0C1 |\ player Y screen negative? draw
  BMI .draw                                 ; $1FF0C4 |/
  LDA #$0E                                  ; $1FF0C6 |\ set player state = $0E (death)
  CMP $30                                   ; $1FF0C8 | | if already dead, skip
  BEQ .death_ret                            ; $1FF0CA |/
  STA $30                                   ; $1FF0CC | store death state
  LDA #$F2                                  ; $1FF0CE |\ play death sound
  JSR submit_sound_ID                       ; $1FF0D0 |/
  LDA #$17                                  ; $1FF0D3 |\ play death music
  JSR submit_sound_ID                       ; $1FF0D5 |/
.death_ret:
  RTS                                       ; $1FF0D8 |

.player_check_landing:
  LDA $03E0                                 ; $1FF0D9 |\ Y screen = 1? (landed from above)
  CMP #$01                                  ; $1FF0DC | |
  BNE .draw                                 ; $1FF0DE |/
  LDA #$01                                  ; $1FF0E0 |\ set player state = $01 (airborne)
  STA $30                                   ; $1FF0E2 |/
  LDA #$10                                  ; $1FF0E4 |\ set Y subpixel speed = $10
  STA $0440                                 ; $1FF0E6 |/
  LDA #$0D                                  ; $1FF0E9 |\ set Y velocity = $0D (falling fast)
  STA $0460                                 ; $1FF0EB |/
.draw:
  JMP setup_sprite_render                   ; $1FF0EE |

.screen_fixed:
  LDA $0360,x                               ; $1FF0F1 |\ for screen-fixed entities,
  STA $13                                   ; $1FF0F4 |/ X pos is already screen-relative
.set_draw_pos:
  LDA $03C0,x                               ; $1FF0F6 |\ Y pixel → draw Y position
  STA $12                                   ; $1FF0F9 |/
  LDA $0580,x                               ; $1FF0FB |\
  ORA #$80                                  ; $1FF0FE | | set bit 7 (mark as drawn)
  STA $0580,x                               ; $1FF100 |/
  AND #$04                                  ; $1FF103 |\ bit 2 = invisible (skip OAM)
  BEQ setup_sprite_render                   ; $1FF105 |/
.ret:
  RTS                                       ; $1FF107 |

; --- setup_sprite_render ---
; prepares sprite bank selection and animation state for OAM assembly
; X = entity slot, $10 = h-flip flag, $11 = flip offset
; $00/$01 = pointer to animation sequence data
setup_sprite_render:
  LDY #$00                                  ; $1FF108 |\
  LDA $0580,x                               ; $1FF10A | | bit 6 = horizontal flip
  AND #$40                                  ; $1FF10D | |
  STA $10                                   ; $1FF10F | | $10 = flip flag for OAM attr
  BEQ .no_flip                              ; $1FF111 |/
  INY                                       ; $1FF113 | Y=1 if flipped
.no_flip:
  STY $11                                   ; $1FF114 | $11 = flip table offset
  CPX #$10                                  ; $1FF116 |\ slot >= 16? (weapon/projectile)
  BCC .entity_bank                          ; $1FF118 |/
  LDA $5A                                   ; $1FF11A |\ $5A = weapon sprite bank override
  BEQ .entity_bank                          ; $1FF11C |/ 0 = use normal entity bank
  LDY #$15                                  ; $1FF11E |\ weapon sprites in PRG bank $15
  CPY $F4                                   ; $1FF120 | | already selected?
  BEQ .bank_ready                           ; $1FF122 |/
  BNE .select_bank                          ; $1FF124 |
.entity_bank:
  LDY #$1A                                  ; $1FF126 |\ OAM ID bit 7 selects bank:
  LDA $05C0,x                               ; $1FF128 | | $00-$7F → bank $1A
  BPL .bank_ok                              ; $1FF12B | | $80-$FF → bank $1B
  INY                                       ; $1FF12D |/
.bank_ok:
  CPY $F4                                   ; $1FF12E |\ already selected?
  BEQ .bank_ready                           ; $1FF130 |/
.select_bank:
  STY $F4                                   ; $1FF132 |\
  STX $00                                   ; $1FF134 | | select $8000-$9FFF PRG bank
  JSR select_PRG_banks                      ; $1FF136 | |
  LDX $00                                   ; $1FF139 |/  restore entity slot
.bank_ready:
  LDA $05C0,x                               ; $1FF13B |\ OAM ID = 0? no sprite
  BEQ .ret                                  ; $1FF13E |/ return
  AND #$7F                                  ; $1FF140 |\ strip bank select bit
  TAY                                       ; $1FF142 |/
  LDA $8000,y                               ; $1FF143 |\ $00/$01 = animation sequence ptr
  STA $00                                   ; $1FF146 | | (low bytes at $8000+ID,
  LDA $8080,y                               ; $1FF148 | |  high bytes at $8080+ID)
  STA $01                                   ; $1FF14B |/
; --- animation tick / frame advancement ---
; Animation sequence format at ($00):
;   byte 0 = total frames in sequence
;   byte 1 = ticks per frame (duration)
;   byte 2+ = sprite definition IDs per frame (0 = deactivate entity)
  LDA $17                                   ; $1FF14D |\ $17 bit 3 = slow-motion mode
  AND #$08                                  ; $1FF14F | |
  BEQ .anim_check_freeze                    ; $1FF151 |/  not set? check freeze
  LDA $95                                   ; $1FF153 |\ in slow-motion: only tick every 8th frame
  AND #$07                                  ; $1FF155 | |
  BNE .skip_anim_tick                       ; $1FF157 |/  skip 7 of 8 frames
  LDA $17                                   ; $1FF159 |\ $17 bit 7 = full freeze
  AND #$80                                  ; $1FF15B | |
  BNE .skip_anim_tick                       ; $1FF15D |/  completely frozen
.anim_check_freeze:
  LDA $58                                   ; $1FF15F |\ $58 = global animation freeze
  BNE .skip_anim_tick                       ; $1FF161 |/ nonzero = skip ticking
  LDA $05E0,x                               ; $1FF163 |\ $05E0 = frame tick counter
  AND #$7F                                  ; $1FF166 | | (bit 7 = damage flash flag)
  INC $05E0,x                               ; $1FF168 | | increment tick
  LDY #$01                                  ; $1FF16B | |
  CMP ($00),y                               ; $1FF16D | | compare tick vs duration at seq[1]
  BNE .skip_anim_tick                       ; $1FF16F |/  not reached? keep waiting
  LDA $05E0,x                               ; $1FF171 |\ tick reached duration:
  AND #$80                                  ; $1FF174 | | reset tick to 0, preserve bit 7
  STA $05E0,x                               ; $1FF176 |/  (damage flash flag)
  LDA $05A0,x                               ; $1FF179 |\ $05A0 = current frame index
  AND #$7F                                  ; $1FF17C | | (bit 7 preserved)
  INC $05A0,x                               ; $1FF17E | | advance to next frame
  DEY                                       ; $1FF181 | | Y=0
  CMP ($00),y                               ; $1FF182 | | compare frame vs total at seq[0]
  BNE .skip_anim_tick                       ; $1FF184 |/  more frames? continue
  LDA #$00                                  ; $1FF186 |\ reached end: loop back to frame 0
  STA $05A0,x                               ; $1FF188 |/
; --- damage flash and sprite definition lookup ---
.skip_anim_tick:
  LDA $0580,x                               ; $1FF18B |\ bit 7 = drawn flag (set by process_entity_display)
  BPL .ret                                  ; $1FF18E |/ not marked for drawing? skip
  LDA $05E0,x                               ; $1FF190 |\ bit 7 of tick counter = damage flash active
  BPL .no_flash                             ; $1FF193 |/ not flashing? draw normally
  LDA $92                                   ; $1FF195 |\ $92 = invincibility blink timer
  AND #$04                                  ; $1FF197 | | blink every 4 frames
  BNE .ret                                  ; $1FF199 |/ odd phase = skip draw (invisible)
.no_flash:
  CPX #$10                                  ; $1FF19B |\ slot < 16? not a weapon/projectile
  BCC .get_sprite_def                       ; $1FF19D |/
  LDA $04E0,x                               ; $1FF19F |\ $04E0 = projectile lifetime/timer
  AND #$E0                                  ; $1FF1A2 | | upper 3 bits = active countdown
  BEQ .get_sprite_def                       ; $1FF1A4 |/ not counting down? normal
  LDA $0300,x                               ; $1FF1A6 |\ $0300 bit 6 = slow decay flag
  AND #$40                                  ; $1FF1A9 | |
  BEQ .decay_timer                          ; $1FF1AB |/ not set? always decay
  LDA $4F                                   ; $1FF1AD |\ slow decay: only every 4th frame
  AND #$03                                  ; $1FF1AF | |
  BNE .check_explode                        ; $1FF1B1 |/ skip 3 of 4 frames
.decay_timer:
  LDA $04E0,x                               ; $1FF1B3 |\ subtract $20 from timer
  SEC                                       ; $1FF1B6 | | (decrement upper 3-bit counter)
  SBC #$20                                  ; $1FF1B7 | |
  STA $04E0,x                               ; $1FF1B9 |/
.check_explode:
  LDA $0300,x                               ; $1FF1BC |\ bit 6 = explode when timer expires?
  AND #$40                                  ; $1FF1BF | |
  BEQ .ret                                  ; $1FF1C1 |/ no flag? just disappear
  LDA $04E0,x                               ; $1FF1C3 |\ check if timer reached $20 threshold
  AND #$20                                  ; $1FF1C6 | |
  BEQ .get_sprite_def                       ; $1FF1C8 |/ not yet? keep going
  LDA #$AF                                  ; $1FF1CA |\ use explosion sprite def $AF
  BNE .write_oam                            ; $1FF1CC |/ (always branches)
.get_sprite_def:
  LDA $05A0,x                               ; $1FF1CE |\ current frame index (strip bit 7)
  AND #$7F                                  ; $1FF1D1 | |
  CLC                                       ; $1FF1D3 | | +2 to skip header bytes (count, duration)
  ADC #$02                                  ; $1FF1D4 | |
  TAY                                       ; $1FF1D6 | |
  LDA ($00),y                               ; $1FF1D7 | | load sprite def ID from sequence
  BNE .write_oam                            ; $1FF1D9 |/ nonzero? go draw it
  STA $0300,x                               ; $1FF1DB |\ def ID = 0: deactivate entity
  LDA #$FF                                  ; $1FF1DE | | mark as despawned
  STA $04C0,x                               ; $1FF1E0 |/
.ret:
  RTS                                       ; $1FF1E3 |

; -----------------------------------------------
; write_entity_oam — assembles OAM entries from sprite definition
; -----------------------------------------------
; Entry: A = sprite definition ID
;   $10 = H-flip mask ($40 or $00)
;   $11 = flip table offset (0=normal, 1=flipped)
;   $12 = entity screen Y position
;   $13 = entity screen X position
;   $97 = OAM buffer write pointer
; Sprite definition format:
;   byte 0 = sprite count (bit 7: use CHR bank $14 instead of $19)
;   byte 1 = position offset table index (for Y/X offsets)
;   byte 2+ = pairs of (CHR tile, OAM attribute) per sprite
; Position offset table at ($05/$06): Y offset, X offset per sprite
write_entity_oam:
  TAY                                       ; $1FF1E4 |\ sprite def ID → index
  LDA $8100,y                               ; $1FF1E5 | | $02/$03 = pointer to sprite definition
  STA $02                                   ; $1FF1E8 | | (low bytes at $8100+ID,
  LDA $8200,y                               ; $1FF1EA | |  high bytes at $8200+ID)
  STA $03                                   ; $1FF1ED |/
  LDY #$00                                  ; $1FF1EF |\
  LDA ($02),y                               ; $1FF1F1 | | byte 0 = sprite count + bank flag
  PHA                                       ; $1FF1F3 |/
  LDY #$19                                  ; $1FF1F4 |\ default CHR bank = $19
  PLA                                       ; $1FF1F6 | |
  BPL .chr_bank_ok                          ; $1FF1F7 | | bit 7 set? use bank $14
  AND #$7F                                  ; $1FF1F9 | |
  LDY #$14                                  ; $1FF1FB |/
.chr_bank_ok:
  STA $04                                   ; $1FF1FD | $04 = sprite count (0-based loop counter)
  CPY $F5                                   ; $1FF1FF |\ $F5 = currently selected CHR bank
  BEQ .chr_ready                            ; $1FF201 |/ already selected? skip
  STY $F5                                   ; $1FF203 |\ select CHR bank via $A000/$A001
  STX $05                                   ; $1FF205 | |
  JSR select_PRG_banks                      ; $1FF207 | |
  LDX $05                                   ; $1FF20A |/  restore temp
.chr_ready:
  LDY #$01                                  ; $1FF20C |\ byte 1 = position offset table index
  LDA ($02),y                               ; $1FF20E | | add flip offset ($11=0 or 1)
  CLC                                       ; $1FF210 | | to select normal/flipped offsets
  ADC $11                                   ; $1FF211 |/
  PHA                                       ; $1FF213 |
  LDA $0580,x                               ; $1FF214 |\ bit 5 = on-ladder flag
  AND #$20                                  ; $1FF217 | | stored to $11 for OAM attr overlay
  STA $11                                   ; $1FF219 |/ (behind-background priority)
  PLA                                       ; $1FF21B |\ offset table index → X
  TAX                                       ; $1FF21C | |
  LDA $BE00,x                               ; $1FF21D | | $BE00/$BF00 = pointer table for
  SEC                                       ; $1FF220 | | sprite position offsets
  SBC #$02                                  ; $1FF221 | | subtract 2 to align with def bytes
  STA $05                                   ; $1FF223 | | $05/$06 = offset data pointer
  LDA $BF00,x                               ; $1FF225 | |
  SBC #$00                                  ; $1FF228 | |
  STA $06                                   ; $1FF22A |/
  LDX $97                                   ; $1FF22C |\ X = OAM write position
  BEQ .oam_full                             ; $1FF22E |/ 0 = buffer wrapped, full
.sprite_loop:
  LDA #$F0                                  ; $1FF230 |\ default Y clip boundary = $F0
  STA $00                                   ; $1FF232 |/
  LDA $22                                   ; $1FF234 |\ stage $08 = Rush Marine underwater?
  CMP #$08                                  ; $1FF236 | |
  BNE .no_clip_override                     ; $1FF238 |/
  LDA $F9                                   ; $1FF23A |\ check specific screens ($15 or $1A)
  CMP #$15                                  ; $1FF23C | | for reduced Y clip boundary
  BEQ .set_b0_clip                          ; $1FF23E | |
  CMP #$1A                                  ; $1FF240 | |
  BNE .no_clip_override                     ; $1FF242 |/
.set_b0_clip:
  LDA #$B0                                  ; $1FF244 |\ Y clip = $B0 for these screens
  STA $00                                   ; $1FF246 |/
.no_clip_override:
  INY                                       ; $1FF248 |\ read CHR tile from def
  LDA ($02),y                               ; $1FF249 | |
  STA $0201,x                               ; $1FF24B |/ OAM byte 1 = tile index
  LDA $12                                   ; $1FF24E |\ screen Y + offset Y
  CLC                                       ; $1FF250 | |
  ADC ($05),y                               ; $1FF251 | |
  STA $0200,x                               ; $1FF253 |/ OAM byte 0 = Y position
  LDA ($05),y                               ; $1FF256 |\ overflow detection:
  BMI .y_overflow_neg                       ; $1FF258 | | if offset negative and result didn't
  BCC .y_in_range                           ; $1FF25A | | underflow, it's OK
  BCS .y_offscreen                          ; $1FF25C |/ positive offset + carry = overflow
.y_overflow_neg:
  BCC .y_offscreen                          ; $1FF25E | negative offset without borrow = underflow
.y_in_range:
  LDA $0200,x                               ; $1FF260 |\ check Y against clip boundary
  CMP $00                                   ; $1FF263 | |
  BCS .y_offscreen                          ; $1FF265 |/ Y >= clip? hide sprite
  INY                                       ; $1FF267 |\ read OAM attribute from def
  LDA ($02),y                               ; $1FF268 | | EOR with flip flag ($10)
  EOR $10                                   ; $1FF26A | | ORA with ladder priority ($11)
  ORA $11                                   ; $1FF26C | |
  STA $0202,x                               ; $1FF26E |/ OAM byte 2 = attribute
  LDA $13                                   ; $1FF271 |\ screen X + offset X
  CLC                                       ; $1FF273 | |
  ADC ($05),y                               ; $1FF274 | |
  STA $0203,x                               ; $1FF276 |/ OAM byte 3 = X position
  LDA ($05),y                               ; $1FF279 |\ overflow detection for X
  BMI .x_overflow_neg                       ; $1FF27B | |
  BCC .x_in_range                           ; $1FF27D | |
  BCS .x_hide                               ; $1FF27F |/
.x_overflow_neg:
  BCC .x_hide                               ; $1FF281 |
.x_in_range:
  INX                                       ; $1FF283 |\ advance OAM pointer by 4 bytes
  INX                                       ; $1FF284 | |
  INX                                       ; $1FF285 | |
  INX                                       ; $1FF286 | |
  STX $97                                   ; $1FF287 | | update write position
  BEQ .oam_full                             ; $1FF289 |/ wrapped to 0? buffer full
.next_sprite:
  DEC $04                                   ; $1FF28B |\ decrement sprite count
  BPL .sprite_loop                          ; $1FF28D |/ more sprites? continue
.oam_full:
  RTS                                       ; $1FF28F |

.y_offscreen:
  INY                                       ; $1FF290 | skip attribute byte
.x_hide:
  LDA #$F8                                  ; $1FF291 |\ hide sprite (Y=$F8 = below screen)
  STA $0200,x                               ; $1FF293 | |
  BNE .next_sprite                          ; $1FF296 |/ (always branches)
; -----------------------------------------------
; draw_energy_bars — draws up to 3 HUD energy meters
; -----------------------------------------------
; $B1-$B3 = bar slot IDs (bit 7 = active, bits 0-6 = energy index)
; $A2+Y = energy value ($80=empty, $9C=full, 28 units)
; Alternates iteration direction each frame for OAM priority fairness.
; Each bar draws 7 sprites vertically: tile selected from $F313 table,
; position from $F318 (OAM attr) and $F31B (X position).
draw_energy_bars:
  LDA $95                                   ; $1FF298 |\ alternate direction each frame
  LSR                                       ; $1FF29A | |
  BCS .bars_reverse                         ; $1FF29B |/ odd = reverse
  LDX #$00                                  ; $1FF29D |\ forward: bar 0, 1, 2
  STX $10                                   ; $1FF29F |/
.bars_fwd:
  JSR .draw_one_bar                         ; $1FF2A1 |
  INC $10                                   ; $1FF2A4 |
  LDX $10                                   ; $1FF2A6 |
  CPX #$03                                  ; $1FF2A8 |
  BNE .bars_fwd                             ; $1FF2AA |
  RTS                                       ; $1FF2AC |

.bars_reverse:
  LDX #$02                                  ; $1FF2AD |\ reverse: bar 2, 1, 0
  STX $10                                   ; $1FF2AF |/
.bars_rev:
  JSR .draw_one_bar                         ; $1FF2B1 |
  DEC $10                                   ; $1FF2B4 |
  LDX $10                                   ; $1FF2B6 |
  BPL .bars_rev                             ; $1FF2B8 |
.bar_inactive:
  RTS                                       ; $1FF2BA |

; draw_one_bar — draws a single energy meter
; X = bar index (0-2), $B1+X = slot ID
.draw_one_bar:
  LDA $B1,x                                 ; $1FF2BB |\ bit 7 = bar active?
  BPL .bar_inactive                         ; $1FF2BD |/ not active? skip
  AND #$7F                                  ; $1FF2BF |\ energy index (Y into $A2 table)
  TAY                                       ; $1FF2C1 | |
  LDA $00A2,y                               ; $1FF2C2 | | read energy value
  AND #$7F                                  ; $1FF2C5 | | strip bit 7 (display flag)
  STA $00                                   ; $1FF2C7 |/ $00 = energy remaining (0-28)
  LDA $F318,x                               ; $1FF2C9 |\ $01 = OAM attribute (palette)
  STA $01                                   ; $1FF2CC |/  bar 0=$00, 1=$01, 2=$02
  LDA $F31B,x                               ; $1FF2CE |\ $02 = X position
  STA $02                                   ; $1FF2D1 |/  bar 0=$10, 1=$18, 2=$28
  LDX $97                                   ; $1FF2D3 |\ X = OAM write pointer
  BEQ .bar_done                             ; $1FF2D5 |/ 0 = full, skip
  LDA #$48                                  ; $1FF2D7 |\ $03 = starting Y position ($48)
  STA $03                                   ; $1FF2D9 |/  draws upward 7 segments
.bar_segment:
  LDA $01                                   ; $1FF2DB |\ write OAM attribute
  STA $0202,x                               ; $1FF2DD |/
  LDA $02                                   ; $1FF2E0 |\ write X position
  STA $0203,x                               ; $1FF2E2 |/
  LDA $03                                   ; $1FF2E5 |\ write Y position
  STA $0200,x                               ; $1FF2E7 |/
  LDY #$04                                  ; $1FF2EA |\ each segment = 4 units of energy
  LDA $00                                   ; $1FF2EC | |
  SEC                                       ; $1FF2EE | | subtract 4 from remaining
  SBC #$04                                  ; $1FF2EF | |
  BCS .segment_full                         ; $1FF2F1 |/ still >= 0? full segment
  LDY $00                                   ; $1FF2F3 |\ partial: Y = remaining 0-3
  LDA #$00                                  ; $1FF2F5 |/  energy = 0
.segment_full:
  STA $00                                   ; $1FF2F7 | update remaining energy
  LDA $F313,y                               ; $1FF2F9 |\ tile from fill table: 4=$6B 3=$6A 2=$69 1=$68 0=$67
  STA $0201,x                               ; $1FF2FC |/ OAM tile
  INX                                       ; $1FF2FF |\ advance OAM by 4
  INX                                       ; $1FF300 | |
  INX                                       ; $1FF301 | |
  INX                                       ; $1FF302 | |
  BEQ .bar_done                             ; $1FF303 |/ OAM buffer full?
  LDA $03                                   ; $1FF305 |\ Y -= 8 (move up one tile)
  SEC                                       ; $1FF307 | |
  SBC #$08                                  ; $1FF308 | |
  STA $03                                   ; $1FF30A | |
  CMP #$10                                  ; $1FF30C | | stop at Y=$10 (7 segments: $48→$10)
  BNE .bar_segment                          ; $1FF30E |/
.bar_done:
  STX $97                                   ; $1FF310 | update OAM pointer
  RTS                                       ; $1FF312 |

; energy bar tile table: index=fill level (0=empty, 4=full)
bar_fill_tiles:
  db $6B, $6A, $69, $68, $67                ; $1FF313 |

; energy bar OAM attributes (palette): bar 0, 1, 2
bar_attributes:
  db $00, $01, $02                          ; $1FF318 |

; energy bar X positions: bar 0=$10, 1=$18, 2=$28
bar_x_positions:
  db $10, $18, $28                          ; $1FF31B |

; freespace
  db $A0, $FB, $2A, $EC, $88                ; $1FF31E |
  db $DF, $B8, $FE, $08, $50, $0A, $EB, $0A ; $1FF323 |
  db $6D, $8A, $6F, $2A, $D0, $A0, $B7, $8E ; $1FF32B |
  db $CD, $0A, $EC, $28, $C8, $28, $13, $A0 ; $1FF333 |
  db $F7, $68, $83, $80, $CC, $A8, $BE, $AA ; $1FF33B |
  db $FB, $AA, $ED, $2A, $F9, $08, $F4, $A8 ; $1FF343 |
  db $F7, $AA, $FB, $20, $CF, $2A, $9F, $28 ; $1FF34B |
  db $BF, $CA, $FC, $E0, $78, $CA, $FF, $A2 ; $1FF353 |
  db $BF, $20, $FB, $6A, $FF, $28, $FE, $AA ; $1FF35B |
  db $66, $A8, $B7, $8A, $59, $A2, $B2, $2B ; $1FF363 |
  db $AD, $0A, $96, $22, $3A, $82, $CA, $2A ; $1FF36B |
  db $DB, $A8, $92, $9A, $27, $88, $7E, $2A ; $1FF373 |
  db $E7, $46, $EE, $A2, $E9, $26, $C6, $C8 ; $1FF37B |
  db $8C, $02, $DE, $B6, $AF, $E2, $5F, $EA ; $1FF383 |
  db $7D, $8A, $BB, $BA, $EC, $02, $FE, $90 ; $1FF38B |
  db $E7, $88, $F7, $AE, $FE, $EA, $EE, $2A ; $1FF393 |
  db $B9, $2A, $BB, $A8, $77, $40, $E3, $AA ; $1FF39B |
  db $3D, $0A, $B2, $B8, $4F, $8A, $B8, $CC ; $1FF3A3 |
  db $FB, $A2, $FB, $81, $6E, $B2, $AD, $82 ; $1FF3AB |
  db $EF, $93, $76, $AC, $5F, $2E, $CF, $04 ; $1FF3B3 |
  db $E1, $B0, $FF, $82, $9C, $2A, $FF, $6A ; $1FF3BB |
  db $83, $A8, $D8, $AA, $4F, $2B, $F3, $28 ; $1FF3C3 |
  db $5C, $2E, $D4, $8A, $52, $82, $67, $0A ; $1FF3CB |
  db $D3, $EA, $5E, $0A, $9C, $8A, $36, $82 ; $1FF3D3 |
  db $AB, $2A, $7E, $AD, $F8, $A0, $CE, $2A ; $1FF3DB |
  db $2D, $A0, $ED, $88, $9F, $88, $D7, $2A ; $1FF3E3 |
  db $BF, $AA, $78, $A0, $ED, $A8, $DC, $0E ; $1FF3EB |
  db $9B, $28, $FE, $EA, $75, $A2, $57, $A8 ; $1FF3F3 |
  db $99, $A2, $7F, $A2, $B9, $7A, $04, $FC ; $1FF3FB |
  db $11, $DC, $05, $3B, $05, $9B, $40, $4B ; $1FF403 |
  db $55, $3C, $51, $8A, $00, $67, $54, $72 ; $1FF40B |
  db $15, $1A, $11, $59, $15, $AA, $45, $16 ; $1FF413 |
  db $41, $47, $05, $A0, $51, $F1, $45, $76 ; $1FF41B |
  db $10, $84, $11, $FF, $14, $6A, $54, $B8 ; $1FF423 |
  db $54, $DC, $55, $FD, $40, $92, $51, $1D ; $1FF42B |
  db $14, $32, $40, $C3, $44, $40, $11, $84 ; $1FF433 |
  db $45, $96, $44, $D9, $11, $0F, $01, $DB ; $1FF43B |
  db $40, $96, $01, $24, $11, $62, $19, $83 ; $1FF443 |
  db $55, $4F, $15, $E7, $14, $3F, $04, $A0 ; $1FF44B |
  db $45, $EE, $70, $8A, $54, $59, $44, $7D ; $1FF453 |
  db $11, $39, $44, $6F, $41, $1B, $15, $42 ; $1FF45B |
  db $05, $71, $50, $E8, $11, $FD, $44, $2E ; $1FF463 |
  db $00, $BC, $45, $F1, $14, $7B, $51, $E1 ; $1FF46B |
  db $45, $49, $10, $2C, $44, $46, $45, $F3 ; $1FF473 |
  db $45, $46, $04, $E7, $40, $41, $00, $E8 ; $1FF47B |
  db $41, $7A, $01, $E7, $11, $92, $11, $9F ; $1FF483 |
  db $00, $E7, $45, $4E, $51, $D0, $11, $C1 ; $1FF48B |
  db $45, $26, $41, $48, $40, $0C, $50, $CD ; $1FF493 |
  db $51, $31, $54, $4D, $50, $6B, $00, $98 ; $1FF49B |
  db $51, $78, $14, $CF, $55, $4C, $05, $8E ; $1FF4A3 |
  db $14, $26, $15, $EB, $04, $CB, $14, $68 ; $1FF4AB |
  db $50, $06, $00, $F9, $15, $9B, $20, $0C ; $1FF4B3 |
  db $15, $DE, $01, $C1, $55, $B5, $51, $20 ; $1FF4BB |
  db $11, $6A, $40, $C1, $00, $19, $54, $58 ; $1FF4C3 |
  db $05, $2C, $41, $0B, $40, $11, $00, $E6 ; $1FF4CB |
  db $50, $AF, $14, $94, $00, $03, $51, $E6 ; $1FF4D3 |
  db $04, $8F, $15, $EE, $51, $6E, $11, $D7 ; $1FF4DB |
  db $55, $F6, $05, $6E, $55, $C5, $D5, $CB ; $1FF4E3 |
  db $51, $FF, $40, $7A, $41, $FA, $50, $57 ; $1FF4EB |
  db $55, $59, $10, $40, $10, $29, $C4, $01 ; $1FF4F3 |
  db $00, $20, $54, $2D, $45, $60, $04, $89 ; $1FF4FB |
  db $14, $2F, $65, $84, $51, $A1, $41, $BA ; $1FF503 |
  db $1C, $07, $01, $6C, $41, $79, $54, $88 ; $1FF50B |
  db $51, $21, $40, $F9, $14, $3C, $11, $24 ; $1FF513 |
  db $15, $A0, $54, $86, $1A, $78, $10, $41 ; $1FF51B |
  db $05, $94, $54, $6D, $11, $85, $40, $A1 ; $1FF523 |
  db $45, $25, $45, $23, $45, $53, $14, $E3 ; $1FF52B |
  db $51, $67, $4C, $F7, $01, $8A, $14, $62 ; $1FF533 |
  db $44, $C6, $45, $CA, $44, $E0, $45, $E7 ; $1FF53B |
  db $01, $05, $14, $04, $41, $F6, $05, $C3 ; $1FF543 |
  db $10, $03, $40, $AA, $40, $CA, $01, $66 ; $1FF54B |
  db $05, $DB, $05, $0C, $14, $3D, $44, $80 ; $1FF553 |
  db $50, $0A, $51, $AC, $71, $EE, $40, $53 ; $1FF55B |
  db $D4, $F5, $05, $56, $00, $EC, $14, $9A ; $1FF563 |
  db $10, $B0, $50, $BE, $55, $F6, $14, $7C ; $1FF56B |
  db $01, $E0, $54, $2A, $45, $4A, $51, $6D ; $1FF573 |
  db $15, $38, $14, $E2, $50                ; $1FF57B |

; -----------------------------------------------
; move_right_collide — move right + set facing + tile collision
; -----------------------------------------------
; Sets H-flip flag (facing right), saves pre-move X for player,
; moves right, checks screen boundary (player only), checks tile collision.
; Returns: C=1 if hit solid tile, C=0 if clear
move_right_collide:
  LDA $0580,x                               ; $1FF580 |\ set bit 6 = facing right (no H-flip)
  ORA #$40                                  ; $1FF583 | |
  STA $0580,x                               ; $1FF585 |/
move_right_collide_no_face:
  CPX #$00                                  ; $1FF588 |\ player (slot 0)?
  BNE .mr_do_move                           ; $1FF58A |/ non-player: skip pre-move save
  LDA $0360                                 ; $1FF58C |\ save player X before move
  STA $02                                   ; $1FF58F | | (for screen boundary detection)
  LDA $0380                                 ; $1FF591 | |
  STA $03                                   ; $1FF594 |/
.mr_do_move:
  JSR move_sprite_right                     ; $1FF596 |
  CPX #$00                                  ; $1FF599 |\ player?
  BNE mr_tile_check                        ; $1FF59B |/ non-player: just check tile
  JSR check_platform_horizontal              ; $1FF59D |\ player overlapping horiz platform?
  BCC mr_tile_check                         ; $1FF5A0 |/ no → normal tile check
  JSR platform_push_x_left                  ; $1FF5A2 |  push player left (away from platform)
  JSR .mr_boundary_adj                      ; $1FF5A5 |
  SEC                                       ; $1FF5A8 |
  RTS                                       ; $1FF5A9 |

.mr_boundary_adj:
  BEQ mr_tile_check                        ; $1FF5AA |
  BCC mr_tile_check                        ; $1FF5AC |
  INY                                       ; $1FF5AE |
  JMP ml_tile_check                        ; $1FF5AF |

mr_tile_check:
  JSR check_tile_collision                   ; $1FF5B2 |
  JSR update_collision_flags                 ; $1FF5B5 |
  CLC                                       ; $1FF5B8 |
  LDA $10                                   ; $1FF5B9 |\ bit 4 = solid tile?
  AND #$10                                  ; $1FF5BB | |
  BEQ .mr_ret                               ; $1FF5BD |/ no? clear carry, return
  JSR snap_x_to_wall_right                           ; $1FF5BF | snap to tile boundary (right)
  SEC                                       ; $1FF5C2 | set carry = hit solid
.mr_ret:
  RTS                                       ; $1FF5C3 |

; -----------------------------------------------
; move_left_collide — move left + set facing + tile collision
; -----------------------------------------------
move_left_collide:
  LDA $0580,x                               ; $1FF5C4 |\ clear bit 6 = facing left (H-flip)
  AND #$BF                                  ; $1FF5C7 | |
  STA $0580,x                               ; $1FF5C9 |/
move_left_collide_no_face:
  CPX #$00                                  ; $1FF5CC |\ player (slot 0)?
  BNE .ml_do_move                           ; $1FF5CE |/
  LDA $0360                                 ; $1FF5D0 |\ save player X before move
  STA $02                                   ; $1FF5D3 | |
  LDA $0380                                 ; $1FF5D5 | |
  STA $03                                   ; $1FF5D8 |/
.ml_do_move:
  JSR move_sprite_left                      ; $1FF5DA |
  CPX #$00                                  ; $1FF5DD |\ player?
  BNE ml_tile_check                        ; $1FF5DF |/
  JSR check_platform_horizontal              ; $1FF5E1 |\ player overlapping horiz platform?
  BCC ml_tile_check                         ; $1FF5E4 |/ no → normal tile check
  JSR platform_push_x_right                 ; $1FF5E6 |  push player right (away from platform)
  JSR .ml_boundary_adj                      ; $1FF5E9 |
  SEC                                       ; $1FF5EC |
  RTS                                       ; $1FF5ED |

.ml_boundary_adj:
  BCS ml_tile_check                        ; $1FF5EE |
  DEY                                       ; $1FF5F0 |
  JMP mr_tile_check                        ; $1FF5F1 |

ml_tile_check:
  JSR check_tile_collision                   ; $1FF5F4 |
  JSR update_collision_flags                 ; $1FF5F7 |
  CLC                                       ; $1FF5FA |
  LDA $10                                   ; $1FF5FB |\ bit 4 = solid?
  AND #$10                                  ; $1FF5FD | |
  BEQ .ml_ret                               ; $1FF5FF |/
  JSR snap_x_to_wall_left                           ; $1FF601 | snap to tile boundary (left)
  SEC                                       ; $1FF604 |
.ml_ret:
  RTS                                       ; $1FF605 |

; -----------------------------------------------
; move_down_collide — move down + tile collision
; -----------------------------------------------
move_down_collide:
  CPX #$00                                  ; $1FF606 |\ player?
  BNE .md_do_move                           ; $1FF608 |/
  LDA $03C0                                 ; $1FF60A |\ save player Y before move
  STA $02                                   ; $1FF60D | |
  LDA $0380                                 ; $1FF60F | |
  STA $03                                   ; $1FF612 |/
.md_do_move:
  JSR move_sprite_down                      ; $1FF614 |
  CPX #$00                                  ; $1FF617 |\ player?
  BNE md_tile_check                        ; $1FF619 |/
  JSR check_platform_vertical                ; $1FF61B |\ player standing on vert platform?
  BCC md_tile_check                         ; $1FF61E |/ no → normal tile check
  JSR platform_push_y_up                    ; $1FF620 |  push player up (onto platform)
  JSR .md_boundary_adj                      ; $1FF623 |
  SEC                                       ; $1FF626 |
  RTS                                       ; $1FF627 |

.md_boundary_adj:
  BEQ md_tile_check                        ; $1FF628 |
  BCC md_tile_check                        ; $1FF62A |
  INY                                       ; $1FF62C |
  JMP mu_tile_check                        ; $1FF62D |

md_tile_check:
  JSR check_tile_horiz                           ; $1FF630 |\ vertical tile collision check
  JSR update_collision_flags                 ; $1FF633 |
  CLC                                       ; $1FF636 |
  LDA $10                                   ; $1FF637 |\ bit 4 = solid?
  AND #$10                                  ; $1FF639 | |
  BEQ .md_ret                               ; $1FF63B |/
  JSR snap_y_to_floor                           ; $1FF63D | snap to tile boundary (down)
  SEC                                       ; $1FF640 |
.md_ret:
  RTS                                       ; $1FF641 |

; -----------------------------------------------
; move_up_collide — move up + tile collision
; -----------------------------------------------
move_up_collide:
  CPX #$00                                  ; $1FF642 |\ player?
  BNE .mu_do_move                           ; $1FF644 |/
  LDA $03C0                                 ; $1FF646 |\ save player Y
  STA $02                                   ; $1FF649 | |
  LDA $0380                                 ; $1FF64B | |
  STA $03                                   ; $1FF64E |/
.mu_do_move:
  JSR move_sprite_up                        ; $1FF650 |
  CPX #$00                                  ; $1FF653 |\ player?
  BNE mu_tile_check                        ; $1FF655 |/
  JSR check_platform_vertical                ; $1FF657 |\ player touching vert platform?
  BCC mu_tile_check                         ; $1FF65A |/ no → normal tile check
  JSR platform_push_y_down                  ; $1FF65C |  push player down (below platform)
  JSR .mu_boundary_adj                      ; $1FF65F |
  SEC                                       ; $1FF662 |
  RTS                                       ; $1FF663 |

.mu_boundary_adj:
  BCS mu_tile_check                        ; $1FF664 |
  DEY                                       ; $1FF666 |
  JMP md_tile_check                        ; $1FF667 |

mu_tile_check:
  JSR check_tile_horiz                           ; $1FF66A |\ vertical tile collision check
  JSR update_collision_flags                 ; $1FF66D |
  CLC                                       ; $1FF670 |
  LDA $10                                   ; $1FF671 |\ bit 4 = solid?
  AND #$10                                  ; $1FF673 | |
  BEQ .mu_ret                               ; $1FF675 |/
  JSR snap_y_to_ceil                           ; $1FF677 | snap to tile boundary (up)
  SEC                                       ; $1FF67A |
.mu_ret:
  RTS                                       ; $1FF67B |

; -----------------------------------------------
; move_vertical_gravity — gravity-based vertical movement with collision
; -----------------------------------------------
; Combines velocity application, gravity, screen boundary handling,
; and tile collision for entities affected by gravity.
; Y velocity convention: positive = rising, negative = falling.
; Returns: C=1 if landed on solid ground, C=0 if airborne.
move_vertical_gravity:
  CPX #$00                                  ; $1FF67C |\ player?
  BNE .mvg_start                            ; $1FF67E |/
  LDA $03C0                                 ; $1FF680 |\ save player Y before move
  STA $02                                   ; $1FF683 | |
  LDA $0380                                 ; $1FF685 | |
  STA $03                                   ; $1FF688 |/
.mvg_start:
  LDA $0460,x                               ; $1FF68A |\ Y velocity whole byte
  BPL .mvg_rising                           ; $1FF68D |/ positive = rising
  ; --- falling (Y velocity negative) ---
  JSR apply_y_velocity_fall                  ; $1FF68F | pos -= vel (moves down)
  CPX #$00                                  ; $1FF692 |\ player?
  BNE .mvg_fall_collide                     ; $1FF694 |/
  JSR check_platform_vertical                ; $1FF696 |\ player landing on platform?
  BCC .mvg_fall_collide                     ; $1FF699 |/ no → normal tile collision
  JSR platform_push_y_up                    ; $1FF69B |  push player up (onto platform)
  JSR .mvg_fall_adj                         ; $1FF69E |
  JMP .mvg_landed                           ; $1FF6A1 |

.mvg_fall_adj:
  BEQ .mvg_fall_collide                     ; $1FF6A4 |\ boundary adj: if crossed screen
  BCC .mvg_fall_collide                     ; $1FF6A6 | | may need opposite tile check
  INY                                       ; $1FF6A8 | |
  JMP mu_tile_check                         ; $1FF6A9 |/ → upward tile check on new screen

.mvg_fall_collide:
  JSR apply_gravity                         ; $1FF6AC | increase downward velocity
  JSR check_tile_horiz                           ; $1FF6AF | vertical tile collision check
  JSR update_collision_flags                 ; $1FF6B2 |
  CPX #$00                                  ; $1FF6B5 |\ player?
  BNE .mvg_fall_solid                       ; $1FF6B7 |/
  LDA $41                                   ; $1FF6B9 |\ tile type = ladder top ($40)?
  CMP #$40                                  ; $1FF6BB | | player lands on ladder top
  BEQ .mvg_snap_down                        ; $1FF6BD |/
.mvg_fall_solid:
  LDA $10                                   ; $1FF6BF |\ bit 4 = solid tile?
  AND #$10                                  ; $1FF6C1 | |
  BEQ .mvg_airborne                         ; $1FF6C3 |/ no solid? still falling
.mvg_snap_down:
  JSR snap_y_to_floor                           ; $1FF6C5 | snap to tile boundary (down)
.mvg_landed:
  JSR reset_gravity                         ; $1FF6C8 | reset velocity to rest value
  SEC                                       ; $1FF6CB | C=1: landed
  RTS                                       ; $1FF6CC |

.mvg_rising:
  ; --- rising (Y velocity positive) ---
  INY                                       ; $1FF6CD | adjust collision check direction
  JSR apply_y_velocity_rise                  ; $1FF6CE | pos -= vel (moves up)
  CPX #$00                                  ; $1FF6D1 |\ player?
  BNE .mvg_rise_collide                     ; $1FF6D3 |/
  JSR check_platform_vertical                ; $1FF6D5 |\ player hitting platform from below?
  BCC .mvg_rise_collide                     ; $1FF6D8 |/ no → normal tile collision
  JSR platform_push_y_down                  ; $1FF6DA |  push player down (below platform)
  JSR .mvg_rise_adj                         ; $1FF6DD |
  JMP .mvg_rise_landed                      ; $1FF6E0 |

.mvg_rise_adj:
  BCS .mvg_rise_collide                     ; $1FF6E3 |\ boundary adj: if crossed screen
  DEY                                       ; $1FF6E5 | | may need opposite tile check
  JMP md_tile_check                         ; $1FF6E6 |/ → downward tile check on new screen

.mvg_rise_collide:
  JSR apply_gravity                         ; $1FF6E9 | apply gravity (slows rise)
  JSR check_tile_horiz                           ; $1FF6EC | vertical tile collision check
  JSR update_collision_flags                 ; $1FF6EF |
  LDA $10                                   ; $1FF6F2 |\ bit 4 = solid tile?
  AND #$10                                  ; $1FF6F4 | |
  BEQ .mvg_airborne                         ; $1FF6F6 |/ no solid? continue rising
  JSR snap_y_to_ceil                           ; $1FF6F8 | snap to tile boundary (up)
.mvg_rise_landed:
  JSR reset_gravity                         ; $1FF6FB | reset velocity
.mvg_airborne:
  CLC                                       ; $1FF6FE | C=0: airborne
  RTS                                       ; $1FF6FF |

; -----------------------------------------------
; update_collision_flags — update entity collision flags from tile check
; -----------------------------------------------
; $10 = tile collision result from check_tile_collision
; $41 = tile type from last collision (upper nibble of $BF00)
; Updates $0580 bit 5 (on-ladder) based on tile type $60 (ladder).
update_collision_flags:
  LDA $10                                   ; $1FF700 |\ bit 4 = solid tile hit?
  AND #$10                                  ; $1FF702 | |
  BNE .done                                 ; $1FF704 |/ solid? keep existing flags
  LDA $0580,x                               ; $1FF706 |\ clear on-ladder flag (bit 5)
  AND #$DF                                  ; $1FF709 | |
  STA $0580,x                               ; $1FF70B |/
  LDA $41                                   ; $1FF70E |\ $41 = tile type
  CMP #$60                                  ; $1FF710 | | $60 = ladder tile? (was $40 top + $20 body)
  BNE .done                                 ; $1FF712 |/ not ladder? done
  LDA $0580,x                               ; $1FF714 |\ set on-ladder flag (bit 5)
  ORA #$20                                  ; $1FF717 | | (used by OAM: behind-background priority)
  STA $0580,x                               ; $1FF719 |/
.done:
  RTS                                       ; $1FF71C |

; moves sprite right by its X speeds
; parameters:
; X: sprite slot
move_sprite_right:
  LDA $0340,x                               ; $1FF71D |\
  CLC                                       ; $1FF720 | | X subpixel += X subpixel speed
  ADC $0400,x                               ; $1FF721 | |
  STA $0340,x                               ; $1FF724 |/
  LDA $0360,x                               ; $1FF727 |\
  ADC $0420,x                               ; $1FF72A | | X pixel += X velocity
  STA $0360,x                               ; $1FF72D |/  (with carry from sub)
  BCC .ret                                  ; $1FF730 | no carry? no screen change
  LDA $0380,x                               ; $1FF732 |\
  ADC #$00                                  ; $1FF735 | | X screen += 1
  STA $0380,x                               ; $1FF737 |/
.ret:
  RTS                                       ; $1FF73A |

; moves sprite left by its X speeds
; parameters:
; X: sprite slot
move_sprite_left:
  LDA $0340,x                               ; $1FF73B |\
  SEC                                       ; $1FF73E | | X subpixel -= X subpixel speed
  SBC $0400,x                               ; $1FF73F | |
  STA $0340,x                               ; $1FF742 |/
  LDA $0360,x                               ; $1FF745 |\
  SBC $0420,x                               ; $1FF748 | | X pixel -= X speed
  STA $0360,x                               ; $1FF74B |/  (with carry from sub)
  BCS .ret                                  ; $1FF74E | carry on? no screen change
  LDA $0380,x                               ; $1FF750 |\
  SBC #$00                                  ; $1FF753 | | X screen -= 1
  STA $0380,x                               ; $1FF755 |/
.ret:
  RTS                                       ; $1FF758 |

; moves sprite down by its Y speeds
; parameters:
; X: sprite slot
move_sprite_down:
  LDA $03A0,x                               ; $1FF759 |\
  CLC                                       ; $1FF75C | | Y subpixel += Y subpixel speed
  ADC $0440,x                               ; $1FF75D | |
  STA $03A0,x                               ; $1FF760 |/
  LDA $03C0,x                               ; $1FF763 |\
  ADC $0460,x                               ; $1FF766 | | Y pixel += Y speed
  STA $03C0,x                               ; $1FF769 |/  (with carry from sub)
  CMP #$F0                                  ; $1FF76C |\
  BCC .ret                                  ; $1FF76E | | Y screens are only $F0 tall
  ADC #$0F                                  ; $1FF770 | | if Y < $F0, return
  STA $03C0,x                               ; $1FF772 | | else push down $F more and
  INC $03E0,x                               ; $1FF775 |/  increment Y screen
.ret:
  RTS                                       ; $1FF778 |

; moves sprite up by its Y speeds
; parameters:
; X: sprite slot
move_sprite_up:
  LDA $03A0,x                               ; $1FF779 |\
  SEC                                       ; $1FF77C | | Y subpixel += Y subpixel speed
  SBC $0440,x                               ; $1FF77D | |
  STA $03A0,x                               ; $1FF780 |/
  LDA $03C0,x                               ; $1FF783 |\
  SBC $0460,x                               ; $1FF786 | | Y pixel += Y speed
  STA $03C0,x                               ; $1FF789 |/  (with carry from sub)
  BCS .ret                                  ; $1FF78C |\  Y screens are only $F0 tall
  SBC #$0F                                  ; $1FF78E | | if result >= $00, return
  STA $03C0,x                               ; $1FF790 | | else push up $F more and
  DEC $03E0,x                               ; $1FF793 |/  decrement Y screen
.ret:
  RTS                                       ; $1FF796 |

; -----------------------------------------------
; apply_y_speed — apply Y velocity + gravity (no collision)
; -----------------------------------------------
; Dispatches to fall/rise velocity application based on sign,
; then applies gravity. Used by entities without tile collision.
apply_y_speed:
  LDA $0460,x                               ; $1FF797 |\ Y velocity sign check
  BPL .rising                               ; $1FF79A |/
  JSR apply_y_velocity_fall                  ; $1FF79C | falling: apply downward velocity
  JMP apply_gravity                          ; $1FF79F | then apply gravity

.rising:
  JSR apply_y_velocity_rise                  ; $1FF7A2 | rising: apply upward velocity
  JMP apply_gravity                          ; $1FF7A5 | then apply gravity

; -----------------------------------------------
; apply_y_velocity_fall — apply Y velocity when falling
; -----------------------------------------------
; Position -= velocity. When velocity is negative (falling),
; subtracting negative = adding to Y = moving down on screen.
; Handles downward screen wrap at Y=$F0.
apply_y_velocity_fall:
  LDA $03A0,x                               ; $1FF7A8 |\ Y subpixel -= Y sub velocity
  SEC                                       ; $1FF7AB | |
  SBC $0440,x                               ; $1FF7AC | |
  STA $03A0,x                               ; $1FF7AF |/
  LDA $03C0,x                               ; $1FF7B2 |\ Y pixel -= Y velocity
  SBC $0460,x                               ; $1FF7B5 | | (negative vel → Y increases)
  STA $03C0,x                               ; $1FF7B8 |/
  CMP #$F0                                  ; $1FF7BB |\ screen height = $F0
  BCC .done                                 ; $1FF7BD |/ within screen? done
  ADC #$0F                                  ; $1FF7BF |\ wrap to next screen
  STA $03C0,x                               ; $1FF7C1 | |
  INC $03E0,x                               ; $1FF7C4 |/ increment Y screen
.done:
  RTS                                       ; $1FF7C7 |

; -----------------------------------------------
; apply_y_velocity_rise — apply Y velocity when rising
; -----------------------------------------------
; Position -= velocity. When velocity is positive (rising),
; subtracting positive = decreasing Y = moving up on screen.
; Handles upward screen wrap (underflow).
apply_y_velocity_rise:
  LDA $03A0,x                               ; $1FF7C8 |\ Y subpixel -= Y sub velocity
  SEC                                       ; $1FF7CB | |
  SBC $0440,x                               ; $1FF7CC | |
  STA $03A0,x                               ; $1FF7CF |/
  LDA $03C0,x                               ; $1FF7D2 |\ Y pixel -= Y velocity
  SBC $0460,x                               ; $1FF7D5 | | (positive vel → Y decreases)
  STA $03C0,x                               ; $1FF7D8 |/
  BCS .done                                 ; $1FF7DB |\ no underflow? done
  SBC #$0F                                  ; $1FF7DD |\ wrap to previous screen
  STA $03C0,x                               ; $1FF7DF | |
  DEC $03E0,x                               ; $1FF7E2 |/ decrement Y screen
.done:
  RTS                                       ; $1FF7E5 |

; -----------------------------------------------
; apply_gravity — subtract gravity from Y velocity
; -----------------------------------------------
; Gravity ($99) subtracted from velocity each frame, making it
; more negative over time (falling faster). Clamps at terminal
; velocity $F9.00 (-7 px/frame). Player float timer ($B9) delays
; gravity while active.
apply_gravity:
  CPX #$00                                  ; $1FF7E6 |\ player?
  BNE .do_gravity                           ; $1FF7E8 |/
  LDA $B9                                   ; $1FF7EA |\ $B9 = player float timer
  BEQ .do_gravity                           ; $1FF7EC |/ 0 = not floating
  DEC $B9                                   ; $1FF7EE |\ decrement float timer
  BNE .ret                                  ; $1FF7F0 |/ still floating? skip gravity
.do_gravity:
  LDA $0440,x                               ; $1FF7F2 |\ Y sub velocity -= gravity ($99)
  SEC                                       ; $1FF7F5 | |
  SBC $99                                   ; $1FF7F6 | |
  STA $0440,x                               ; $1FF7F8 |/
  LDA $0460,x                               ; $1FF7FB |\ Y whole velocity -= borrow
  SBC #$00                                  ; $1FF7FE | |
  STA $0460,x                               ; $1FF800 |/
  BPL .ret                                  ; $1FF803 |\ still positive (rising)? done
  CMP #$F9                                  ; $1FF805 | | terminal velocity = $F9 = -7
  BCS .ret                                  ; $1FF807 |/ >= $F9 (-7 to -1)? within limit
  LDA $05C0,x                               ; $1FF809 |\ OAM ID check
  CMP #$13                                  ; $1FF80C | | $13 = exempt from terminal vel
  BEQ .ret                                  ; $1FF80E |/ (special entity, unlimited fall)
  LDA #$F9                                  ; $1FF810 |\ clamp to terminal velocity
  STA $0460,x                               ; $1FF812 | | $F9.00 = -7.0 px/frame
  LDA #$00                                  ; $1FF815 | |
  STA $0440,x                               ; $1FF817 |/
.ret:
  RTS                                       ; $1FF81A |

; resets a sprite's gravity/downward Y velocity
; parameters:
; X: sprite slot
reset_gravity:
  CPX #$00                                  ; $1FF81B |\ $00 means player
  BEQ .player                               ; $1FF81D |/
  LDA #$AB                                  ; $1FF81F |\
  STA $0440,x                               ; $1FF821 | | Y velocity
  LDA #$FF                                  ; $1FF824 | | = $FFAB, or -0.332
  STA $0460,x                               ; $1FF826 |/
  RTS                                       ; $1FF829 |

.player:
  LDA #$C0                                  ; $1FF82A |\
  STA $0440,x                               ; $1FF82C | | player Y velocity
  LDA #$FF                                  ; $1FF82F | | = $FFC0, or -0.25
  STA $0460,x                               ; $1FF831 |/
  RTS                                       ; $1FF834 |

; resets sprite's animation & sets ID
; parameters:
; A: OAM ID
; X: sprite slot
reset_sprite_anim:
  STA $05C0,x                               ; $1FF835 | store parameter -> OAM ID
  LDA #$00                                  ; $1FF838 |\ reset animation
  STA $05A0,x                               ; $1FF83A |/
  LDA $05E0,x                               ; $1FF83D |\
  AND #$80                                  ; $1FF840 | | reset anim frame counter
  STA $05E0,x                               ; $1FF842 |/
  RTS                                       ; $1FF845 |

; -----------------------------------------------
; init_child_entity — initialize a new child entity in slot Y
; -----------------------------------------------
; Sets up a child entity spawned by parent entity in slot X.
; Inherits the parent's horizontal flip for facing direction.
;
; parameters:
;   X = parent entity slot
;   Y = child entity slot (from find_enemy_freeslot_y)
;   A = child entity shape/type value (stored to $05C0,y)
; modifies:
;   $0300,y = $80 (active)
;   $0580,y = parent's hflip | $90 (active + flags)
;   $03E0,y = 0 (Y screen)
;   $05A0,y = 0 (timer/counter cleared)
;   $05E0,y = bit 7 only preserved
; -----------------------------------------------
init_child_entity:
  STA $05C0,y                               ; $1FF846 |  child shape/type
  LDA #$00                                  ; $1FF849 |\
  STA $05A0,y                               ; $1FF84B | | clear timer and Y screen
  STA $03E0,y                               ; $1FF84E |/
  LDA $0580,x                               ; $1FF851 |\ inherit parent's horizontal flip
  AND #$40                                  ; $1FF854 | | (bit 6) and combine with $90
  ORA #$90                                  ; $1FF856 | |
  STA $0580,y                               ; $1FF858 |/
  LDA #$80                                  ; $1FF85B |\ mark entity as active
  STA $0300,y                               ; $1FF85D |/
  LDA $05E0,y                               ; $1FF860 |\ preserve only bit 7 of $05E0
  AND #$80                                  ; $1FF863 | |
  STA $05E0,y                               ; $1FF865 |/
  RTS                                       ; $1FF868 |

; faces a sprite toward the player
; parameters:
; X: sprite slot
face_player:
  LDA #$01                                  ; $1FF869 |\ start facing right
  STA $04A0,x                               ; $1FF86B |/
  LDA $0360,x                               ; $1FF86E |\
  SEC                                       ; $1FF871 | | if sprite is to the left
  SBC $0360                                 ; $1FF872 | | of player
  LDA $0380,x                               ; $1FF875 | | (X screen priority, then
  SBC $0380                                 ; $1FF878 | | X pixel), return
  BCC .ret                                  ; $1FF87B |/
  LDA #$02                                  ; $1FF87D | else set facing to left
  STA $04A0,x                               ; $1FF87F |
.ret:
  RTS                                       ; $1FF882 |

; -----------------------------------------------
; set_sprite_hflip — set horizontal flip from facing direction
; -----------------------------------------------
; Converts $04A0,x bit 0 (facing right) into $0580,x bit 6
; (NES horizontal flip). Three ROR shifts move bit 0 → bit 6.
; Sprites face left by default; bit 6 set = flip to face right.
;
; parameters:
;   X = entity slot
; modifies:
;   $0580,x bit 6 = set if facing right ($04A0,x bit 0)
; -----------------------------------------------
set_sprite_hflip:
  LDA $04A0,x                               ; $1FF883 |  load facing direction
  ROR                                       ; $1FF886 |\ 3x ROR: bit 0 → bit 6
  ROR                                       ; $1FF887 | |
  ROR                                       ; $1FF888 |/
  AND #$40                                  ; $1FF889 |  isolate bit 6 (was bit 0)
  STA $00                                   ; $1FF88B |
  LDA $0580,x                               ; $1FF88D |\ clear old hflip, set new
  AND #$BF                                  ; $1FF890 | |
  ORA $00                                   ; $1FF892 | |
  STA $0580,x                               ; $1FF894 |/
  RTS                                       ; $1FF897 |

; submit a sound ID to global buffer for playing
; if full, do nothing
; parameters:
; A: sound ID
submit_sound_ID_D9:
  STA $D9                                   ; $1FF898 | also store ID in $D9

; this version doesn't store in $D9
submit_sound_ID:
  STX $00                                   ; $1FF89A | preserve X
  LDX $DA                                   ; $1FF89C | X = current circular buffer index
  STA $01                                   ; $1FF89E | sound ID -> $01 temp
  LDA $DC,x                                 ; $1FF8A0 |\  if current slot != $88
  CMP #$88                                  ; $1FF8A2 | | buffer FULL, return
  BNE .ret                                  ; $1FF8A4 |/
  LDA $01                                   ; $1FF8A6 |\ add sound ID to current
  STA $DC,x                                 ; $1FF8A8 |/ buffer slot
  INX                                       ; $1FF8AA |\
  TXA                                       ; $1FF8AB | | increment circular buffer index
  AND #$07                                  ; $1FF8AC | | with wraparound $07 -> $00
  STA $DA                                   ; $1FF8AE |/
.ret:
  LDX $00                                   ; $1FF8B0 | restore X
  RTS                                       ; $1FF8B2 |

; -----------------------------------------------
; entity_y_dist_to_player — |player_Y - entity_Y|
; -----------------------------------------------
; parameters:
;   X = entity slot
; results:
;   A = abs(player_Y - entity[X]_Y) (pixel portion, single screen)
;   carry = set if player is below entity, clear if above
; -----------------------------------------------
entity_y_dist_to_player:
  LDA $03C0                                 ; $1FF8B3 |\ player_Y - entity_Y
  SEC                                       ; $1FF8B6 | |
  SBC $03C0,x                               ; $1FF8B7 |/
  BCS .player_below                         ; $1FF8BA |  positive → player is below
  EOR #$FF                                  ; $1FF8BC |\ negate: player is above entity
  ADC #$01                                  ; $1FF8BE | |
  CLC                                       ; $1FF8C0 |/ C=0 means player is above
.player_below:
  RTS                                       ; $1FF8C1 |

; -----------------------------------------------
; entity_x_dist_to_player — |player_X - entity_X|
; -----------------------------------------------
; 16-bit subtraction (pixel + screen), returns pixel portion only.
; parameters:
;   X = entity slot
; results:
;   A = abs(player_X - entity[X]_X) (pixel portion)
;   carry = set if player is to the right, clear if left
; -----------------------------------------------
entity_x_dist_to_player:
  LDA $0360                                 ; $1FF8C2 |\ player_X_pixel - entity_X_pixel
  SEC                                       ; $1FF8C5 | |
  SBC $0360,x                               ; $1FF8C6 | |
  PHA                                       ; $1FF8C9 | | save low byte
  LDA $0380                                 ; $1FF8CA | | player_X_screen - entity_X_screen
  SBC $0380,x                               ; $1FF8CD | | (borrow propagates from pixel sub)
  PLA                                       ; $1FF8D0 |/ recover pixel difference
  BCS .player_right                         ; $1FF8D1 |  positive → player is to the right
  EOR #$FF                                  ; $1FF8D3 |\ negate: player is to the left
  ADC #$01                                  ; $1FF8D5 | |
  CLC                                       ; $1FF8D7 |/ C=0 means player is left
.player_right:
  RTS                                       ; $1FF8D8 |

; -----------------------------------------------
; calc_direction_to_player — 16-direction angle from entity to player
; -----------------------------------------------
; Computes the direction from entity X to the player as a 16-step
; compass index (0-15). Used by entity AI for homing/tracking.
;
; Direction values (clockwise from north):
;   $00=N  $01=NNE $02=NE  $03=ENE $04=E  $05=ESE $06=SE  $07=SSE
;   $08=S  $09=SSW $0A=SW  $0B=WSW $0C=W  $0D=WNW $0E=NW  $0F=NNW
;
; Algorithm:
;   1. Compute abs Y and X distances, track quadrant in Y register:
;      bit 2 = player above entity, bit 1 = player left of entity
;   2. Sort distances: $01 = larger, $00 = smaller (bit 0 = swapped)
;   3. Compute sub-angle from slope ratio:
;      larger/4 >= smaller → 0 (nearly axial)
;      larger/2 >= smaller → 1 (moderate)
;      else               → 2 (nearly diagonal)
;   4. Look up final direction from table: [quadrant*4 + sub-angle]
;
; parameters:
;   X = entity slot
; results:
;   A = direction index (0-15)
; -----------------------------------------------
calc_direction_to_player:
  LDY #$00                                  ; $1FF8D9 |  Y = quadrant bits
  LDA $03C0                                 ; $1FF8DB |\ player_Y - entity_Y
  SEC                                       ; $1FF8DE | |
  SBC $03C0,x                               ; $1FF8DF | |
  LDY #$00                                  ; $1FF8E2 | | (clear Y again — assembler artifact)
  BCS .y_positive                           ; $1FF8E4 |/ player below or same → skip
  EOR #$FF                                  ; $1FF8E6 |\ negate: player is above
  ADC #$01                                  ; $1FF8E8 | |
  LDY #$04                                  ; $1FF8EA |/ Y bit 2 = player above
.y_positive:
  STA $00                                   ; $1FF8EC |  $00 = abs(Y distance)
  LDA $0360                                 ; $1FF8EE |\ player_X - entity_X (16-bit)
  SEC                                       ; $1FF8F1 | |
  SBC $0360,x                               ; $1FF8F2 | |
  PHA                                       ; $1FF8F5 | |
  LDA $0380                                 ; $1FF8F6 | | screen portion
  SBC $0380,x                               ; $1FF8F9 | |
  PLA                                       ; $1FF8FC |/
  BCS .x_positive                           ; $1FF8FD |  player right or same → skip
  EOR #$FF                                  ; $1FF8FF |\ negate: player is left
  ADC #$01                                  ; $1FF901 | |
  INY                                       ; $1FF903 | | Y bit 1 = player left
  INY                                       ; $1FF904 |/
.x_positive:
  STA $01                                   ; $1FF905 |  $01 = abs(X distance)
  CMP $00                                   ; $1FF907 |\ if X_dist >= Y_dist, no swap needed
  BCS .no_swap                              ; $1FF909 |/
  PHA                                       ; $1FF90B |\ swap so $01=larger, $00=smaller
  LDA $00                                   ; $1FF90C | |
  STA $01                                   ; $1FF90E | |
  PLA                                       ; $1FF910 | |
  STA $00                                   ; $1FF911 | |
  INY                                       ; $1FF913 |/ Y bit 0 = axes swapped (Y dominant)
.no_swap:
  LDA #$00                                  ; $1FF914 |\ $02 = sub-angle (0-2)
  STA $02                                   ; $1FF916 |/
  LDA $01                                   ; $1FF918 |\ larger_dist / 4
  LSR                                       ; $1FF91A | |
  LSR                                       ; $1FF91B |/
  CMP $00                                   ; $1FF91C |  if larger/4 >= smaller → nearly axial
  BCS .lookup                               ; $1FF91E |
  INC $02                                   ; $1FF920 |  sub-angle = 1 (moderate)
  ASL                                       ; $1FF922 |  larger/4 * 2 = larger/2
  CMP $00                                   ; $1FF923 |  if larger/2 >= smaller → moderate
  BCS .lookup                               ; $1FF925 |
  INC $02                                   ; $1FF927 |  sub-angle = 2 (nearly diagonal)
.lookup:
  TYA                                       ; $1FF929 |\ table index = quadrant * 4 + sub-angle
  ASL                                       ; $1FF92A | |
  ASL                                       ; $1FF92B | |
  CLC                                       ; $1FF92C | |
  ADC $02                                   ; $1FF92D | |
  TAY                                       ; $1FF92F |/
  LDA direction_lookup_table,y              ; $1FF930 |  A = direction (0-15)
  RTS                                       ; $1FF933 |

; 16-direction lookup table indexed by [quadrant*4 + sub-angle]
; quadrant bits: bit2=above, bit1=left, bit0=Y-dominant
; sub-angle: 0=axial, 1=moderate, 2=diagonal
direction_lookup_table:
  db $04, $05, $06, $04                     ; $1FF934 | below+right, X-dom: E, ESE, SE, (pad)
  db $08, $07, $06, $04                     ; $1FF938 | below+right, Y-dom: S, SSE, SE, (pad)
  db $0C, $0B, $0A, $04                     ; $1FF93C | below+left,  X-dom: W, WSW, SW, (pad)
  db $08, $09, $0A, $04                     ; $1FF940 | below+left,  Y-dom: S, SSW, SW, (pad)
  db $04, $03, $02, $04                     ; $1FF944 | above+right, X-dom: E, ENE, NE, (pad)
  db $00, $01, $02, $04                     ; $1FF948 | above+right, Y-dom: N, NNE, NE, (pad)
  db $0C, $0D, $0E, $04                     ; $1FF94C | above+left,  X-dom: W, WNW, NW, (pad)
  db $00, $0F, $0E, $04                     ; $1FF950 | above+left,  Y-dom: N, NNW, NW, (pad)

; -----------------------------------------------
; track_direction_to_player — smoothly rotate entity toward player
; -----------------------------------------------
; Computes target direction via calc_direction_to_player, then
; adjusts entity's current direction ($04A0,x) by ±1 step toward
; the target using the shortest rotation path. Called once per
; frame for homing entities.
;
; parameters:
;   X = entity slot
; modifies:
;   $04A0,x = entity direction (0-15), adjusted by 1 toward player
; -----------------------------------------------
track_direction_to_player:
  JSR calc_direction_to_player              ; $1FF954 |  A = target direction (0-15)
  STA $00                                   ; $1FF957 |  $00 = target
  LDA $04A0,x                               ; $1FF959 |\ signed circular difference:
  CLC                                       ; $1FF95C | | (current + 8 - target) & $0F - 8
  ADC #$08                                  ; $1FF95D | | offset by 8 to center range
  AND #$0F                                  ; $1FF95F | | wrap to 0-15
  SEC                                       ; $1FF961 | |
  SBC $00                                   ; $1FF962 | | subtract target
  AND #$0F                                  ; $1FF964 | | wrap to 0-15
  SEC                                       ; $1FF966 | |
  SBC #$08                                  ; $1FF967 |/ remove offset → signed diff (-7..+8)
  BEQ .already_aligned                      ; $1FF969 |  diff=0: already facing target
  BCS .turn_clockwise                       ; $1FF96B |  diff>0: target is CCW → turn CW (DEC)
  INC $04A0,x                               ; $1FF96D |\ diff<0: target is CW → turn CCW (INC)
  BNE .wrap_direction                       ; $1FF970 |/ (always branches)
.turn_clockwise:
  DEC $04A0,x                               ; $1FF972 |
.wrap_direction:
  LDA $04A0,x                               ; $1FF975 |\ wrap direction to 0-15
  AND #$0F                                  ; $1FF978 | |
  STA $04A0,x                               ; $1FF97A |/
.already_aligned:
  RTS                                       ; $1FF97D |

; -----------------------------------------------
; check_platform_vertical — check if player stands on a platform entity
; -----------------------------------------------
; Scans all entity slots ($1F→$01) for platform entities that
; the player (slot 0) is standing on. Uses hitbox tables at
; $FB3B (half-heights) and $FB5B (half-widths) indexed by
; the entity's shape ($0480 & $1F).
;
; $0580 flag bits for platform entities:
;   bit 7 = active/collidable
;   bit 2 = disabled (skip if set)
;   bit 1 = horizontal platform flag
;   bit 0 = vertical platform flag (can stand on)
;
; parameters:
;   X = entity slot (must be player slot 0)
; results:
;   carry = set if standing on platform, clear if not
;   $11 = vertical overlap (clamped to max 8), used as push distance
;   $5D = platform entity slot
;   $36/$37/$38 = platform velocity data (if entity type $14)
; -----------------------------------------------
check_platform_vertical:
  LDA $0580,x                               ; $1FF97E |\ entity not active? bail
  BPL .no_platform                          ; $1FF981 |/
  STY $00                                   ; $1FF983 |  save caller's Y
  LDY #$1F                                  ; $1FF985 |\ start scanning from slot $1F
  STY $01                                   ; $1FF987 |/
.scan_loop:
  LDA $0300,y                               ; $1FF989 |\ entity type empty? skip
  BPL .next_slot                            ; $1FF98C |/
  LDA $0580,y                               ; $1FF98E |\ entity not active? skip
  BPL .next_slot                            ; $1FF991 |/
  LDA $0580,y                               ; $1FF993 |\ bit 2 set = disabled? skip
  AND #$04                                  ; $1FF996 | |
  BNE .next_slot                            ; $1FF998 |/
  LDA $0580,y                               ; $1FF99A |\ bits 0-1 = platform flags
  AND #$03                                  ; $1FF99D | | neither set? skip
  BEQ .next_slot                            ; $1FF99F |/
  AND #$01                                  ; $1FF9A1 |\ bit 0 = vertical platform?
  BEQ .check_distances                      ; $1FF9A3 |/ not set → check as horiz-only
  LDA $0460,x                               ; $1FF9A5 |\ player Y velocity positive (rising)?
  BPL .next_slot                            ; $1FF9A8 |/ can't land while rising → skip
.check_distances:
  JSR player_x_distance                     ; $1FF9AA |  $10 = |player_X - entity_X|
  JSR player_y_distance                     ; $1FF9AD |  $11 = |player_Y - entity_Y|
  BCC .check_hitbox                         ; $1FF9B0 |  player above entity? check hitbox
  LDA $0580,y                               ; $1FF9B2 |\ player below + bit0 (vert platform)?
  AND #$01                                  ; $1FF9B5 | | can't land from below
  BNE .next_slot                            ; $1FF9B7 |/
.check_hitbox:
  LDA $0480,y                               ; $1FF9B9 |\ shape index = $0480 & $1F
  AND #$1F                                  ; $1FF9BC | |
  TAY                                       ; $1FF9BE |/
  LDA $10                                   ; $1FF9BF |\ X distance >= half-width? no overlap
  CMP hitbox_mega_man_widths,y              ; $1FF9C1 | |
  BCS .next_slot                            ; $1FF9C4 |/
  SEC                                       ; $1FF9C6 |\ Y overlap = half-height - Y distance
  LDA hitbox_mega_man_heights,y             ; $1FF9C7 | |
  SBC $11                                   ; $1FF9CA | |
  BCC .next_slot                            ; $1FF9CC |/ negative? no Y overlap
  STA $11                                   ; $1FF9CE |\ $11 = overlap amount
  CMP #$08                                  ; $1FF9D0 | | clamp to max 8 pixels
  BCC .found_platform                       ; $1FF9D2 | |
  LDA #$08                                  ; $1FF9D4 | |
  STA $11                                   ; $1FF9D6 |/
.found_platform:
  LDY $01                                   ; $1FF9D8 |  Y = platform entity slot
  LDA $0320,y                               ; $1FF9DA |\ entity type == $14 (moving platform)?
  CMP #$14                                  ; $1FF9DD | |
  BNE .not_moving_platform                  ; $1FF9DF |/
  LDA $04A0,y                               ; $1FF9E1 |\ copy platform velocity to player vars
  STA $36                                   ; $1FF9E4 | | $36 = platform direction/speed
  LDA $0400,y                               ; $1FF9E6 | | $37 = platform X velocity
  STA $37                                   ; $1FF9E9 | | $38 = platform Y velocity
  LDA $0420,y                               ; $1FF9EB | |
  STA $38                                   ; $1FF9EE |/
.not_moving_platform:
  STY $5D                                   ; $1FF9F0 |  $5D = platform entity slot
  LDY $00                                   ; $1FF9F2 |  restore caller's Y
  SEC                                       ; $1FF9F4 |  C=1: standing on platform
  RTS                                       ; $1FF9F5 |

.next_slot:
  DEC $01                                   ; $1FF9F6 |\ next slot (decrement $1F→$01)
  LDY $01                                   ; $1FF9F8 | |
  BNE .scan_loop                            ; $1FF9FA |/ slot 0 = player, stop there
  LDY $00                                   ; $1FF9FC |  restore caller's Y
.no_platform:
  CLC                                       ; $1FF9FE |  C=0: not on any platform
  RTS                                       ; $1FF9FF |

; -----------------------------------------------
; check_platform_horizontal — check if player is pushed by a platform entity
; -----------------------------------------------
; Scans all entity slots ($1F→$01) for horizontal platform entities
; that overlap the player. Uses hitbox tables at $FB3B (half-heights)
; and $FB5B (half-widths). Unlike vertical check, this only requires
; bit 1 (horizontal flag) and does not check Y velocity direction.
;
; parameters:
;   X = entity slot (must be player slot 0)
; results:
;   carry = set if overlapping platform, clear if not
;   $10 = horizontal overlap (clamped to max 8), used as push distance
;   $5D = platform entity slot (shape index, not original slot)
; -----------------------------------------------
check_platform_horizontal:
  LDA $0580,x                               ; $1FFA00 |\ entity not active? bail
  BPL .no_platform_h                        ; $1FFA03 |/
  STY $00                                   ; $1FFA05 |  save caller's Y
  LDY #$1F                                  ; $1FFA07 |\ start scanning from slot $1F
  STY $01                                   ; $1FFA09 |/
.scan_loop_h:
  LDA $0300,y                               ; $1FFA0B |\ entity type empty? skip
  BPL .next_slot_h                          ; $1FFA0E |/
  LDA $0580,y                               ; $1FFA10 |\ bit 2 set = disabled? skip
  AND #$04                                  ; $1FFA13 | |
  BNE .next_slot_h                          ; $1FFA15 |/
  LDA $0580,y                               ; $1FFA17 |\ bit 1 = horizontal platform?
  AND #$02                                  ; $1FFA1A | | not set? skip
  BEQ .next_slot_h                          ; $1FFA1C |/
  JSR player_x_distance                     ; $1FFA1E |  $10 = |player_X - entity_X|
  JSR player_y_distance                     ; $1FFA21 |  $11 = |player_Y - entity_Y|
  LDA $0480,y                               ; $1FFA24 |\ shape index = $0480 & $1F
  AND #$1F                                  ; $1FFA27 | |
  TAY                                       ; $1FFA29 |/
  LDA $11                                   ; $1FFA2A |\ Y distance >= half-height? no overlap
  CMP hitbox_mega_man_heights,y             ; $1FFA2C | |
  BCS .next_slot_h                          ; $1FFA2F |/
  SEC                                       ; $1FFA31 |\ X overlap = half-width - X distance
  LDA hitbox_mega_man_widths,y              ; $1FFA32 | |
  SBC $10                                   ; $1FFA35 | |
  BCC .next_slot_h                          ; $1FFA37 |/ negative? no X overlap
  STA $10                                   ; $1FFA39 |\ $10 = overlap amount
  CMP #$08                                  ; $1FFA3B | | clamp to max 8 pixels
  BCC .found_platform_h                     ; $1FFA3D | |
  LDA #$08                                  ; $1FFA3F | |
  STA $10                                   ; $1FFA41 |/
.found_platform_h:
  STY $5D                                   ; $1FFA43 |  $5D = platform shape index
  LDY $00                                   ; $1FFA45 |  restore caller's Y
  SEC                                       ; $1FFA47 |  C=1: overlapping platform
  RTS                                       ; $1FFA48 |

.next_slot_h:
  DEC $01                                   ; $1FFA49 |\ next slot (decrement $1F→$01)
  LDY $01                                   ; $1FFA4B | |
  BNE .scan_loop_h                          ; $1FFA4D |/
  LDY $00                                   ; $1FFA4F |  restore caller's Y
.no_platform_h:
  CLC                                       ; $1FFA51 |  C=0: not overlapping any platform
  RTS                                       ; $1FFA52 |

; -----------------------------------------------
; player_x_distance — |player_X - entity_X|
; -----------------------------------------------
; Computes absolute X distance between player (slot 0) and entity Y.
; parameters:
;   Y = entity slot
; results:
;   $10 = abs(player_X - entity[Y]_X) (pixel portion)
;   carry = set if player is to the right, clear if left
; -----------------------------------------------
player_x_distance:
  LDA $0360                                 ; $1FFA53 |\ player_X_pixel - entity_X_pixel
  SEC                                       ; $1FFA56 | |
  SBC $0360,y                               ; $1FFA57 | |
  PHA                                       ; $1FFA5A | | (16-bit subtract, high byte for sign)
  LDA $0380                                 ; $1FFA5B | | player_X_screen - entity_X_screen
  SBC $0380,y                               ; $1FFA5E | |
  PLA                                       ; $1FFA61 |/
  BCS .player_right                         ; $1FFA62 |  player >= entity? already positive
  EOR #$FF                                  ; $1FFA64 |\ negate: entity is right of player
  ADC #$01                                  ; $1FFA66 | |
  CLC                                       ; $1FFA68 |/ C=0 means player is to the left
.player_right:
  STA $10                                   ; $1FFA69 |  $10 = abs X distance
  RTS                                       ; $1FFA6B |

; -----------------------------------------------
; player_y_distance — |player_Y - entity_Y|
; -----------------------------------------------
; Computes absolute Y distance between player (slot 0) and entity Y.
; parameters:
;   Y = entity slot
; results:
;   $11 = abs(player_Y - entity[Y]_Y) (pixel portion)
;   carry = set if player is below entity, clear if above
; -----------------------------------------------
player_y_distance:
  LDA $03C0                                 ; $1FFA6C |\ player_Y - entity_Y
  SEC                                       ; $1FFA6F | |
  SBC $03C0,y                               ; $1FFA70 |/
  BCS .player_below                         ; $1FFA73 |  player >= entity? positive
  EOR #$FF                                  ; $1FFA75 |\ negate: player is above entity
  ADC #$01                                  ; $1FFA77 | |
  CLC                                       ; $1FFA79 |/ C=0 means player is above
.player_below:
  STA $11                                   ; $1FFA7A |  $11 = abs Y distance
  RTS                                       ; $1FFA7C |

; -----------------------------------------------
; platform_push_x_left — push entity X left by $10
; -----------------------------------------------
; Subtracts $10 from entity[X] X position, then compares
; against reference point $02/$03 to determine side.
; results: carry = set if entity is left of $02/$03
; -----------------------------------------------
platform_push_x_left:
  SEC                                       ; $1FFA7D |\ entity_X -= $10 (push left)
  LDA $0360,x                               ; $1FFA7E | |
  SBC $10                                   ; $1FFA81 | |
  STA $0360,x                               ; $1FFA83 | |
  LDA $0380,x                               ; $1FFA86 | | (16-bit: X screen)
  SBC #$00                                  ; $1FFA89 | |
  STA $0380,x                               ; $1FFA8B |/
  JMP .compare_x                            ; $1FFA8E |

; -----------------------------------------------
; platform_push_x_right — push entity X right by $10
; -----------------------------------------------
platform_push_x_right:
  CLC                                       ; $1FFA91 |\ entity_X += $10 (push right)
  LDA $0360,x                               ; $1FFA92 | |
  ADC $10                                   ; $1FFA95 | |
  STA $0360,x                               ; $1FFA97 | |
  LDA $0380,x                               ; $1FFA9A | | (16-bit: X screen)
  ADC #$00                                  ; $1FFA9D | |
  STA $0380,x                               ; $1FFA9F |/
.compare_x:
  SEC                                       ; $1FFAA2 |\ compare: $02/$03 - entity_X
  LDA $02                                   ; $1FFAA3 | | result in carry flag
  SBC $0360,x                               ; $1FFAA5 | | C=1: entity left of ref point
  LDA $03                                   ; $1FFAA8 | | C=0: entity right of ref point
  SBC $0380,x                               ; $1FFAAA |/
  RTS                                       ; $1FFAAD |

; -----------------------------------------------
; platform_push_y_up — push entity Y up by $11
; -----------------------------------------------
; Subtracts $11 from entity[X] Y position, with screen
; underflow handling. Then compares against $02/$03.
; results: carry = set if entity is above $02/$03
; -----------------------------------------------
platform_push_y_up:
  SEC                                       ; $1FFAAE |\ entity_Y -= $11 (push up)
  LDA $03C0,x                               ; $1FFAAF | |
  SBC $11                                   ; $1FFAB2 | |
  STA $03C0,x                               ; $1FFAB4 |/
  BCS .compare_y                            ; $1FFAB7 |  no underflow? skip
  DEC $03E0,x                               ; $1FFAB9 |  underflow: decrement Y screen
  JMP .compare_y                            ; $1FFABC |

; -----------------------------------------------
; platform_push_y_down — push entity Y down by $11
; -----------------------------------------------
; Adds $11 to entity[X] Y position, with $F0 screen
; overflow handling. Then compares against $02/$03.
; results: carry = set if entity is above $02/$03
; -----------------------------------------------
platform_push_y_down:
  CLC                                       ; $1FFABF |\ entity_Y += $11 (push down)
  LDA $03C0,x                               ; $1FFAC0 | |
  ADC $11                                   ; $1FFAC3 | |
  STA $03C0,x                               ; $1FFAC5 |/
  BCS .y_screen_overflow                    ; $1FFAC8 |  carry? wrapped past $FF
  CMP #$F0                                  ; $1FFACA |\ below screen bottom ($F0)?
  BCC .compare_y                            ; $1FFACC |/ no → done
  ADC #$0F                                  ; $1FFACE |\ wrap Y: $F0+$0F+C = next screen
  STA $03C0,x                               ; $1FFAD0 |/
.y_screen_overflow:
  INC $03E0,x                               ; $1FFAD3 |  increment Y screen
.compare_y:
  SEC                                       ; $1FFAD6 |\ compare: $02/$03 - entity_Y
  LDA $02                                   ; $1FFAD7 | | result in carry flag
  SBC $03C0,x                               ; $1FFAD9 | | C=1: entity above ref point
  LDA $03                                   ; $1FFADC | | C=0: entity below ref point
  SBC $03E0,x                               ; $1FFADE |/
  RTS                                       ; $1FFAE1 |

; tests if a sprite is colliding
; with the player (Mega Man)
; parameters:
; X: sprite slot to check player collision for
; returns:
; Carry flag off = collision, on = no collision
check_player_collision:
  LDA $30                                   ; $1FFAE2 |\
  CMP #$0E                                  ; $1FFAE4 | | is player dead
  BEQ .ret                                  ; $1FFAE6 | | or teleporting in?
  CMP #$04                                  ; $1FFAE8 | | return
  BEQ .ret                                  ; $1FFAEA |/
  SEC                                       ; $1FFAEC |
  LDA $0580,x                               ; $1FFAED |\
  BPL .ret                                  ; $1FFAF0 | | if ??? sprite flag off
  AND #$04                                  ; $1FFAF2 | | or ??? sprite flag on
  BNE .ret                                  ; $1FFAF4 |/  return
.height:
  LDA $0480,x                               ; $1FFAF6 |\
  AND #$1F                                  ; $1FFAF9 | | y = hitbox ID
  TAY                                       ; $1FFAFB |/
  LDA hitbox_mega_man_heights,y             ; $1FFAFC |\ Mega Man hitbox height
  STA $00                                   ; $1FFAFF |/ -> $00
  LDA $05C0                                 ; $1FFB01 |\
  CMP #$10                                  ; $1FFB04 | |
  BNE .x_delta                              ; $1FFB06 | | if Mega Man is sliding,
  LDA $00                                   ; $1FFB08 | | adjust hitbox height
  SEC                                       ; $1FFB0A | | by subtracting 8
  SBC #$08                                  ; $1FFB0B | |
  STA $00                                   ; $1FFB0D |/
.x_delta:
  LDA $0360                                 ; $1FFB0F |\
  SEC                                       ; $1FFB12 | |
  SBC $0360,x                               ; $1FFB13 | | grab X delta
  PHA                                       ; $1FFB16 | | player X - sprite X
  LDA $0380                                 ; $1FFB17 | | taking screen into account
  SBC $0380,x                               ; $1FFB1A | | via carry
  PLA                                       ; $1FFB1D | | then take absolute value
  BCS .test_x_collision                     ; $1FFB1E | |
  EOR #$FF                                  ; $1FFB20 | |
  ADC #$01                                  ; $1FFB22 |/
.test_x_collision:
  CMP hitbox_mega_man_widths,y              ; $1FFB24 |\ if abs(X delta) > hitbox X delta
  BCS .ret                                  ; $1FFB27 |/ return
  LDA $03C0                                 ; $1FFB29 |\
  SEC                                       ; $1FFB2C | | get Y delta between
  SBC $03C0,x                               ; $1FFB2D | | the two sprites
  BCS .test_y_collision                     ; $1FFB30 | | A = player sprite Y
  EOR #$FF                                  ; $1FFB32 | | - current sprite Y
  ADC #$01                                  ; $1FFB34 |/  take absolute value
.test_y_collision:
  CMP $00                                   ; $1FFB36 |\ return
  BCC .ret                                  ; $1FFB38 |/ abs(Y delta) < hitbox delta
.ret:
  RTS                                       ; $1FFB3A |

; sprite hitbox heights for Mega Man collision
; the actual height is double this, cause it compares delta
hitbox_mega_man_heights:
  db $13, $1C, $18, $14, $1C, $28, $16, $1C ; $1FFB3B |
  db $18, $18, $1C, $10, $24, $24, $34, $14 ; $1FFB43 |
  db $20, $0E, $1C, $1C, $3C, $1C, $2C, $14 ; $1FFB4B |
  db $2C, $2C, $14, $34, $0C, $0C, $0C, $0C ; $1FFB53 |

; sprite hitbox widths for Mega Man collision
; the actual width is double this, cause it compares delta
hitbox_mega_man_widths:
  db $0F, $14, $14, $14, $10, $20, $18, $14 ; $1FFB5B |
  db $10, $18, $18, $0C, $14, $20, $10, $18 ; $1FFB63 |
  db $1C, $14, $40, $0C, $0C, $0F, $0C, $10 ; $1FFB6B |
  db $28, $18, $28, $2C, $08, $08, $08, $08 ; $1FFB73 |

; loops through all 3 weapon slots
; to check collision against each one
; for a passed in sprite slot
; parameters:
; X: sprite slot to check weapon collision for
; returns:
; Carry flag off = sprite is colliding with player's weapons, on = not
; $10: sprite slot of weapon collided with (if carry off)
check_sprite_weapon_collision:
  LDA $30                                   ; $1FFB7B |\
  CMP #$0E                                  ; $1FFB7D | | is player dead
  BEQ .ret_carry_on                         ; $1FFB7F | | or teleporting in?
  CMP #$04                                  ; $1FFB81 | | return carry on
  BEQ .ret_carry_on                         ; $1FFB83 |/
  LDA #$03                                  ; $1FFB85 |\ start loop through
  STA $10                                   ; $1FFB87 |/ all 3 weapon slots
.loop_weapon:
  LDY $10                                   ; $1FFB89 |
  LDA $0300,y                               ; $1FFB8B |\
  BPL .next_weapon                          ; $1FFB8E | | if weapon
  LDA $0580,y                               ; $1FFB90 | | is inactive
  BPL .next_weapon                          ; $1FFB93 | | or flag ???
  LDA $0320,y                               ; $1FFB95 | |
  CMP #$0F                                  ; $1FFB98 | | or main routine index ???
  BEQ .next_weapon                          ; $1FFB9A | |
  LDA $05C0,y                               ; $1FFB9C | |
  CMP #$13                                  ; $1FFB9F | | or OAM ID $13
  BEQ .next_weapon                          ; $1FFBA1 | |
  CMP #$D7                                  ; $1FFBA3 | | or $D7
  BEQ .next_weapon                          ; $1FFBA5 | |
  CMP #$D8                                  ; $1FFBA7 | | or $D8
  BEQ .next_weapon                          ; $1FFBA9 | |
  CMP #$D9                                  ; $1FFBAB | | or $D9
  BEQ .next_weapon                          ; $1FFBAD | | or if current sprite (passed in)
  LDA $0580,x                               ; $1FFBAF | | flags ???
  BPL .next_weapon                          ; $1FFBB2 | | or flags ???
  AND #$04                                  ; $1FFBB4 | | then don't check collision
  BNE .next_weapon                          ; $1FFBB6 |/
  LDA $0360,y                               ; $1FFBB8 |\
  STA $00                                   ; $1FFBBB | | store X, screen, and Y
  LDA $0380,y                               ; $1FFBBD | | information as parameters
  STA $01                                   ; $1FFBC0 | | for collision routine
  LDA $03C0,y                               ; $1FFBC2 | |
  STA $02                                   ; $1FFBC5 |/
  JSR check_weapon_collision                ; $1FFBC7 |\ carry cleared == collision
  BCC .ret                                  ; $1FFBCA |/ return carry off
.next_weapon:
  DEC $10                                   ; $1FFBCC |\ continue loop,
  BNE .loop_weapon                          ; $1FFBCE |/ stop at $00 (Mega Man)
.ret_carry_on:
  SEC                                       ; $1FFBD0 |
.ret:
  RTS                                       ; $1FFBD1 |

; parameters:
; X: sprite slot to check collision for
; $00: comparison sprite's X position
; $01: comparison sprite's X screen
; $02: comparison sprite's Y position
; returns:
; Carry flag off = collision, on = no collision
check_weapon_collision:
  SEC                                       ; $1FFBD2 |\
  LDA $0480,x                               ; $1FFBD3 | | Y = shape index
  AND #$1F                                  ; $1FFBD6 | | (mod $1F)
  TAY                                       ; $1FFBD8 |/
  LDA $00                                   ; $1FFBD9 |\
  SEC                                       ; $1FFBDB | | get an X delta between
  SBC $0360,x                               ; $1FFBDC | | the two sprites
  PHA                                       ; $1FFBDF | | A = comparison sprite X
  LDA $01                                   ; $1FFBE0 | | - current sprite X
  SBC $0380,x                               ; $1FFBE2 | | take screen into account
  PLA                                       ; $1FFBE5 | | as well via carry
  BCS .test_x_collision                     ; $1FFBE6 | | take absolute value
  EOR #$FF                                  ; $1FFBE8 | | so it's always positive
  ADC #$01                                  ; $1FFBEA |/  whichever side it's on
.test_x_collision:
  CMP hitbox_weapon_widths,y                ; $1FFBEC |\ if abs(X delta) > hitbox X delta
  BCS .ret                                  ; $1FFBEF |/ return
  LDA $02                                   ; $1FFBF1 |\
  SEC                                       ; $1FFBF3 | | get Y delta between
  SBC $03C0,x                               ; $1FFBF4 | | the two sprites
  BCS .test_y_collision                     ; $1FFBF7 | | A = comparison sprite Y
  EOR #$FF                                  ; $1FFBF9 | | - current sprite Y
  ADC #$01                                  ; $1FFBFB |/  take absolute value
.test_y_collision:
  CMP hitbox_weapon_heights,y               ; $1FFBFD |\ return
  BCC .ret                                  ; $1FFC00 |/ abs(Y delta) < hitbox delta
.ret:
  RTS                                       ; $1FFC02 | carry off means collision

; sprite hitbox heights for weapon collision
; the actual height is double this, cause it compares delta
hitbox_weapon_heights:
  db $0A, $12, $0E, $0A, $12, $1E, $0C, $16 ; $1FFC03 |
  db $0E, $0E, $12, $04, $1A, $1A, $2A, $0A ; $1FFC0B |
  db $16, $04, $12, $2E, $32, $12, $22, $0A ; $1FFC13 |
  db $22, $06, $02, $2A, $02, $02, $02, $02 ; $1FFC1B |

; sprite hitbox widths for weapon collision
; the actual width is double this, cause it compares delta
hitbox_weapon_widths:
  db $0B, $0F, $0D, $0F, $0B, $13, $13, $13 ; $1FFC23 |
  db $0B, $13, $13, $05, $0F, $1B, $0B, $13 ; $1FFC2B |
  db $17, $0F, $13, $07, $07, $0A, $07, $0B ; $1FFC33 |
  db $23, $0F, $03, $27, $03, $03, $03, $03 ; $1FFC3B |

; find free sprite slot routine, return in X register
; searches sprite state table $0300 (enemy slots)
; for free slots (inactive)
; returns:
; Carry flag off = slot found, on = not found
; X: next free slot # (if carry off)
find_enemy_freeslot_x:
  LDX #$1F                                  ; $1FFC43 | start looping from slot $1F
.loop:
  LDA $0300,x                               ; $1FFC45 |\ check sprite state sign bit
  BPL .ret_found                            ; $1FFC48 |/ off means inactive, return
  DEX                                       ; $1FFC4A |\  next slot (down)
  CPX #$0F                                  ; $1FFC4B | | $00-$0F slots not for enemies
  BNE .loop                                 ; $1FFC4D |/  so stop there
  SEC                                       ; $1FFC4F |\ return C=1
  RTS                                       ; $1FFC50 |/ for no slots found

.ret_found:
  CLC                                       ; $1FFC51 |\ return C=0 slot found
  RTS                                       ; $1FFC52 |/

; find free sprite slot routine, return in Y register
; searches sprite state table $0300 (enemy slots)
; for free slots (inactive)
; returns:
; Carry flag off = slot found, on = not found
; Y: next free slot # (if carry off)
find_enemy_freeslot_y:
  LDY #$1F                                  ; $1FFC53 | start looping from slot $1F
.loop:
  LDA $0300,y                               ; $1FFC55 |\ check sprite state sign bit
  BPL .ret_found                            ; $1FFC58 |/ off means inactive, return
  DEY                                       ; $1FFC5A |\  next slot (down)
  CPY #$0F                                  ; $1FFC5B | | $00-$0F slots not for enemies
  BNE .loop                                 ; $1FFC5D |/  so stop there
  SEC                                       ; $1FFC5F |\ return C=1
  RTS                                       ; $1FFC60 |/ for no slots found

.ret_found:
  CLC                                       ; $1FFC61 |\ return C=0 slot found
  RTS                                       ; $1FFC62 |/

; -----------------------------------------------
; calc_homing_velocity — proportional X/Y velocity toward player
; -----------------------------------------------
; Computes entity velocity that points at the player with the
; given speed magnitude. The dominant axis (larger distance) gets
; full speed; the minor axis gets proportional speed:
;   minor_vel = speed * minor_dist / major_dist
;
; Uses two successive divide_16bit calls to compute this ratio.
;
; parameters:
;   X = entity slot
;   $03.$02 = speed magnitude (8.8 fixed-point, whole.sub)
; results:
;   $0420,x.$0400,x = X velocity (8.8 fixed-point)
;   $0460,x.$0440,x = Y velocity (8.8 fixed-point)
;   $0C = direction bitmask:
;     bit 0 ($01) = player is right
;     bit 1 ($02) = player is left
;     bit 2 ($04) = player is below
;     bit 3 ($08) = player is above
;   Callers typically store $0C into $04A0,x and use it
;   to select move_sprite_right/left/up/down.
; -----------------------------------------------
calc_homing_velocity:
  JSR entity_x_dist_to_player             ; $1FFC63 |  A = |x_dist|, C = player right
  STA $0A                                   ; $1FFC66 |  $0A = x_distance
  LDA #$01                                  ; $1FFC68 |\ $01 = right
  BCS .store_x_dir                         ; $1FFC6A |/
  LDA #$02                                  ; $1FFC6C |  $02 = left
.store_x_dir:
  STA $0C                                   ; $1FFC6E |  $0C = X direction bit
  JSR entity_y_dist_to_player             ; $1FFC70 |  A = |y_dist|, C = player below
  STA $0B                                   ; $1FFC73 |  $0B = y_distance
  LDA #$04                                  ; $1FFC75 |\ $04 = below
  BCS .combine_dir                         ; $1FFC77 |/
  LDA #$08                                  ; $1FFC79 |  $08 = above
.combine_dir:
  ORA $0C                                   ; $1FFC7B |\ combine X and Y direction bits
  STA $0C                                   ; $1FFC7D |/
  LDA $0B                                   ; $1FFC7F |\ compare y_dist vs x_dist
  CMP $0A                                   ; $1FFC81 | |
  BCS .y_dominant                          ; $1FFC83 |/ y_dist >= x_dist → Y dominant
  ; --- X dominant: x_dist > y_dist ---
  LDA $02                                   ; $1FFC85 |\ X gets full speed
  STA $0400,x                               ; $1FFC87 | | X vel sub = speed sub
  LDA $03                                   ; $1FFC8A | |
  STA $0420,x                               ; $1FFC8C |/ X vel whole = speed whole
  LDA $0A                                   ; $1FFC8F |\ divide_16bit: (x_dist << 16) / speed
  STA $01                                   ; $1FFC91 | | → intermediate scale factor
  LDA #$00                                  ; $1FFC93 | |
  STA $00                                   ; $1FFC95 | |
  JSR divide_16bit                          ; $1FFC97 |/
  LDA $04                                   ; $1FFC9A |\ use scale factor as new divisor
  STA $02                                   ; $1FFC9C | |
  LDA $05                                   ; $1FFC9E | |
  STA $03                                   ; $1FFCA0 |/
  LDA $0B                                   ; $1FFCA2 |\ divide_16bit: (y_dist << 16) / scale
  STA $01                                   ; $1FFCA4 | | = speed * y_dist / x_dist
  LDA #$00                                  ; $1FFCA6 | |
  STA $00                                   ; $1FFCA8 | |
  JSR divide_16bit                          ; $1FFCAA |/
  LDA $04                                   ; $1FFCAD |\ Y gets proportional speed
  STA $0440,x                               ; $1FFCAF | | Y vel sub
  LDA $05                                   ; $1FFCB2 | |
  STA $0460,x                               ; $1FFCB4 |/ Y vel whole
  RTS                                       ; $1FFCB7 |

.y_dominant:
  ; --- Y dominant: y_dist >= x_dist ---
  LDA $02                                   ; $1FFCB8 |\ Y gets full speed
  STA $0440,x                               ; $1FFCBA | | Y vel sub = speed sub
  LDA $03                                   ; $1FFCBD | |
  STA $0460,x                               ; $1FFCBF |/ Y vel whole = speed whole
  LDA $0B                                   ; $1FFCC2 |\ divide_16bit: (y_dist << 16) / speed
  STA $01                                   ; $1FFCC4 | | → intermediate scale factor
  LDA #$00                                  ; $1FFCC6 | |
  STA $00                                   ; $1FFCC8 | |
  JSR divide_16bit                          ; $1FFCCA |/
  LDA $04                                   ; $1FFCCD |\ use scale factor as new divisor
  STA $02                                   ; $1FFCCF | |
  LDA $05                                   ; $1FFCD1 | |
  STA $03                                   ; $1FFCD3 |/
  LDA $0A                                   ; $1FFCD5 |\ divide_16bit: (x_dist << 16) / scale
  STA $01                                   ; $1FFCD7 | | = speed * x_dist / y_dist
  LDA #$00                                  ; $1FFCD9 | |
  STA $00                                   ; $1FFCDB | |
  JSR divide_16bit                          ; $1FFCDD |/
  LDA $04                                   ; $1FFCE0 |\ X gets proportional speed
  STA $0400,x                               ; $1FFCE2 | | X vel sub
  LDA $05                                   ; $1FFCE5 | |
  STA $0420,x                               ; $1FFCE7 |/ X vel whole
  RTS                                       ; $1FFCEA |

; -----------------------------------------------
; divide_8bit — 8-bit restoring division
; -----------------------------------------------
; Computes ($00 * 256) / $01 using shift-and-subtract.
; Effectively returns the ratio $00/$01 as a 0.8 fixed-point
; fraction, useful when $00 < $01.
;
; parameters:
;   $00 = dividend (8-bit)
;   $01 = divisor (8-bit)
; results:
;   $02 = quotient (= $00 * 256 / $01, 8-bit)
;   $03 = remainder
; -----------------------------------------------
divide_8bit:
  LDA #$00                                  ; $1FFCEB |\ clear quotient
  STA $02                                   ; $1FFCED |/ and remainder
  STA $03                                   ; $1FFCEF |
  LDA $00                                   ; $1FFCF1 |\ if both inputs zero,
  ORA $01                                   ; $1FFCF3 | | return 0
  BNE .begin                               ; $1FFCF5 |/
  STA $02                                   ; $1FFCF7 |
  RTS                                       ; $1FFCF9 |

.begin:
  LDY #$08                                  ; $1FFCFA |  8 iterations (8-bit quotient)
.loop:
  ASL $02                                   ; $1FFCFC |\ shift $03:$00:$02 left
  ROL $00                                   ; $1FFCFE | | (quotient ← dividend ← remainder)
  ROL $03                                   ; $1FFD00 |/
  SEC                                       ; $1FFD02 |\ try remainder - divisor
  LDA $03                                   ; $1FFD03 | |
  SBC $01                                   ; $1FFD05 | |
  BCC .no_fit                              ; $1FFD07 |/ divisor doesn't fit, skip
  STA $03                                   ; $1FFD09 |  update remainder
  INC $02                                   ; $1FFD0B |  set quotient bit
.no_fit:
  DEY                                       ; $1FFD0D |
  BNE .loop                                ; $1FFD0E |
  RTS                                       ; $1FFD10 |

; -----------------------------------------------
; divide_16bit — 16-bit restoring division
; -----------------------------------------------
; Computes ($01:$00 << 16) / ($03:$02) using shift-and-subtract.
; The dividend is placed in byte position 2 of the 32-bit shift
; chain ($07:$01:$00:$06), so the result is effectively:
;   ($01 * 65536) / ($03:$02)  [when $00 = 0, as typical]
;
; Used by calc_homing_velocity: two successive calls compute
; speed * minor_dist / major_dist for proportional velocity.
;
; parameters:
;   $01:$00 = dividend (16-bit, usually $01=value, $00=0)
;   $03:$02 = divisor (16-bit, 8.8 fixed-point speed)
; results:
;   $05:$04 = quotient (16-bit), $05=high, $04=low
; preserves:
;   X register (saved/restored via $09)
; -----------------------------------------------
divide_16bit:
  LDA #$00                                  ; $1FFD11 |\ clear quotient accumulator
  STA $06                                   ; $1FFD13 | | and remainder high byte
  STA $07                                   ; $1FFD15 |/
  LDA $00                                   ; $1FFD17 |\ if all inputs zero,
  ORA $01                                   ; $1FFD19 | | return 0
  ORA $02                                   ; $1FFD1B | |
  ORA $03                                   ; $1FFD1D | |
  BNE .begin                               ; $1FFD1F |/
  STA $04                                   ; $1FFD21 |
  STA $05                                   ; $1FFD23 |
  RTS                                       ; $1FFD25 |

.begin:
  STX $09                                   ; $1FFD26 |  save X (used as temp)
  LDY #$10                                  ; $1FFD28 |  16 iterations (16-bit quotient)
.loop:
  ASL $06                                   ; $1FFD2A |\ shift 32-bit chain left:
  ROL $00                                   ; $1FFD2C | | $07:$01:$00:$06
  ROL $01                                   ; $1FFD2E | | (remainder ← dividend ← quotient)
  ROL $07                                   ; $1FFD30 |/
  SEC                                       ; $1FFD32 |\ try $07:$01 - $03:$02
  LDA $01                                   ; $1FFD33 | | (remainder - divisor)
  SBC $02                                   ; $1FFD35 | |
  TAX                                       ; $1FFD37 | | X = low byte of difference
  LDA $07                                   ; $1FFD38 | |
  SBC $03                                   ; $1FFD3A | |
  BCC .no_fit                              ; $1FFD3C |/ divisor doesn't fit, skip
  STX $01                                   ; $1FFD3E |  update remainder low
  STA $07                                   ; $1FFD40 |  update remainder high
  INC $06                                   ; $1FFD42 |  set quotient bit
.no_fit:
  DEY                                       ; $1FFD44 |
  BNE .loop                                ; $1FFD45 |
  LDA $06                                   ; $1FFD47 |\ $04 = quotient low byte
  STA $04                                   ; $1FFD49 |/
  LDA $00                                   ; $1FFD4B |\ $05 = quotient high byte
  STA $05                                   ; $1FFD4D |/
  LDX $09                                   ; $1FFD4F |  restore X
  RTS                                       ; $1FFD51 |

; ===========================================================================
; Frame-yield trampolines — process one frame, yield to NMI, restore banks
; ===========================================================================
; These wrappers let banked code (boss AI, cutscenes, level transitions)
; run one frame of entity processing + sprite update, then yield to the
; cooperative scheduler until NMI completes. They save/restore PRG bank
; state across the yield so the caller doesn't need to worry about it.
;
; $97 controls OAM start offset for update_entity_sprites:
;   $04 = include player sprites (default, set by process_frame_yield_full)
;   $0C = skip player sprites (set by boss_frame_yield)
;
; Variants:
;   boss_frame_yield      — sets $5A (boss active), $97=$0C, saves $F5
;   process_frame_yield_full — saves both banks, $97=$04 (includes player)
;   process_frame_yield   — saves both banks, uses caller's $97
;   call_bank0E_A006      — bank $0E trampoline, calls $A006 with X=$B8
;   call_bank0E_A003      — bank $0E trampoline, calls $A003
; ---------------------------------------------------------------------------

; --- boss_frame_yield ---
; Called from bank03 (boss intro sequences). Sets boss-active flag, processes
; entities (skipping player sprites), yields, then restores banks.
boss_frame_yield:
  LDA #$80                                  ; $1FFD52 |\ set boss-active flag
  STA $5A                                   ; $1FFD54 |/ (bit 7 = boss fight in progress)
  LDA $F5                                   ; $1FFD56 |\ save $A000 bank
  PHA                                       ; $1FFD58 |/
  LDA #$0C                                  ; $1FFD59 |\ $97 = $0C: OAM offset past player
  STA $97                                   ; $1FFD5B |/ (skip first 3 sprite entries)
  JSR process_frame_and_yield               ; $1FFD5D | process entities + yield one frame
  LDA #$00                                  ; $1FFD60 |\ clear boss-active flag
  STA $5A                                   ; $1FFD62 |/
  LDA #$18                                  ; $1FFD64 |\ restore $8000 bank to $18
  STA $F4                                   ; $1FFD66 |/ (bank1C_1D fixed pair)
  PLA                                       ; $1FFD68 |\ restore $A000 bank
  STA $F5                                   ; $1FFD69 |/
  JMP select_PRG_banks                      ; $1FFD6B | re-select banks and return

; --- process_frame_yield_full ---
; Saves both PRG banks, sets $97=$04, processes frame, restores banks.
; Called from bank0C/0B (level loading, cutscenes), bank18 (stage select).
process_frame_yield_full:
  LDA $F4                                   ; $1FFD6E |\ save both PRG banks
  PHA                                       ; $1FFD70 | |
  LDA $F5                                   ; $1FFD71 | |
  PHA                                       ; $1FFD73 |/
  JSR process_frame_yield_with_player       ; $1FFD74 | $97=$04, process + yield
.restore_banks:
  PLA                                       ; $1FFD77 |\ restore $A000 bank
  STA $F5                                   ; $1FFD78 |/
  PLA                                       ; $1FFD7A |\ restore $8000 bank
  STA $F4                                   ; $1FFD7B |/
  JMP select_PRG_banks                      ; $1FFD7D | re-select and return

; --- process_frame_yield ---
; Same as above but uses caller's $97 value (doesn't set $04).
; Called from bank0B/0F (level transitions with custom OAM offset).
process_frame_yield:
  LDA $F4                                   ; $1FFD80 |\ save both PRG banks
  PHA                                       ; $1FFD82 | |
  LDA $F5                                   ; $1FFD83 | |
  PHA                                       ; $1FFD85 |/
  JSR process_frame_and_yield               ; $1FFD86 | process + yield (caller's $97)
  JMP .restore_banks                        ; $1FFD89 | restore banks and return

; --- call_bank0E_A006 ---
; Switches $A000-$BFFF to bank $0E, calls entry point $A006 with X=$B8.
; Called from bank12 (entity AI).
call_bank0E_A006:
  STX $0F                                   ; $1FFD8C | save X
  LDA $F5                                   ; $1FFD8E |\ save $A000 bank
  PHA                                       ; $1FFD90 |/
  LDA #$0E                                  ; $1FFD91 |\ switch $A000 to bank $0E
  STA $F5                                   ; $1FFD93 | |
  JSR select_PRG_banks                      ; $1FFD95 |/
  LDX $B8                                   ; $1FFD98 | X = parameter from $B8
  JSR $A006                                 ; $1FFD9A | call bank $0E entry point
.restore_A000:
  PLA                                       ; $1FFD9D |\ restore $A000 bank
  STA $F5                                   ; $1FFD9E | |
  JSR select_PRG_banks                      ; $1FFDA0 |/
  LDX $0F                                   ; $1FFDA3 | restore X
  RTS                                       ; $1FFDA5 |

; --- call_bank0E_A003 ---
; Switches $A000-$BFFF to bank $0E, calls entry point $A003.
; Called from bank12 (entity AI).
call_bank0E_A003:
  STX $0F                                   ; $1FFDA6 | save X
  LDA $F5                                   ; $1FFDA8 |\ save $A000 bank
  PHA                                       ; $1FFDAA |/
  LDA #$0E                                  ; $1FFDAB |\ switch $A000 to bank $0E
  STA $F5                                   ; $1FFDAD | |
  JSR select_PRG_banks                      ; $1FFDAF |/
  JSR $A003                                 ; $1FFDB2 | call bank $0E entry point
  JMP .restore_A000                         ; $1FFDB5 | restore and return

; unknown data table — 64 bytes, purpose not identified
  db $8A, $40, $A3, $00, $0F, $04, $4B, $50 ; $1FFDB8 |
  db $80, $04, $18, $10, $E0, $00, $64, $04 ; $1FFDC0 |
  db $C5, $45, $67, $50, $CA, $11, $1B, $51 ; $1FFDC8 |
  db $BA, $00, $44, $00, $3E, $00, $A2, $04 ; $1FFDD0 |
  db $99, $00, $DD, $04, $81, $10, $2B, $11 ; $1FFDD8 |
  db $80, $01, $4A, $40, $9C, $01, $47, $15 ; $1FFDE0 |
  db $F7, $11, $47, $44, $17, $40, $C2, $40 ; $1FFDE8 |
  db $28, $11, $CB, $44, $6E, $50, $8A, $54 ; $1FFDF0 |
  db $AE, $10, $2B, $00, $53, $05, $5D, $15 ; $1FFDF8 |

; ===========================================================================
; RESET — power-on initialization
; ===========================================================================
; Standard NES startup: disable interrupts, silence APU, wait for PPU,
; clear all RAM, initialize sound buffer, set up PRG/CHR banks, clear
; nametables, register the main game task at $C8D0, then fall into the
; cooperative scheduler.
; ---------------------------------------------------------------------------
RESET:
  SEI                                       ; $1FFE00 | disable interrupts
  CLD                                       ; $1FFE01 | clear decimal mode
  LDA #$08                                  ; $1FFE02 |\ PPUCTRL: sprite table = $1000
  STA $2000                                 ; $1FFE04 |/ (NMI not yet enabled)
  LDA #$40                                  ; $1FFE07 |\ APU frame counter: disable IRQ
  STA $4017                                 ; $1FFE09 |/
  LDX #$00                                  ; $1FFE0C |
  STX $2001                                 ; $1FFE0E | PPUMASK: rendering off
  STX $4010                                 ; $1FFE11 | DMC: disable
  STX $4015                                 ; $1FFE14 | APU status: silence all channels
  DEX                                       ; $1FFE17 |\ stack pointer = $FF
  TXS                                       ; $1FFE18 |/
; --- wait for PPU warm-up (4 VBlank cycles) ---
  LDX #$04                                  ; $1FFE19 | 4 iterations
.wait_vblank_start:
  LDA $2002                                 ; $1FFE1B |\ wait for VBlank flag set
  BPL .wait_vblank_start                    ; $1FFE1E |/
.wait_vblank_end:
  LDA $2002                                 ; $1FFE20 |\ wait for VBlank flag clear
  BMI .wait_vblank_end                      ; $1FFE23 |/
  DEX                                       ; $1FFE25 |\ repeat 4 times
  BNE .wait_vblank_start                    ; $1FFE26 |/
; --- exercise PPU address bus ---
  LDA $2002                                 ; $1FFE28 | reset PPU latch
  LDA #$10                                  ; $1FFE2B |\ toggle PPUADDR between $1010
  TAY                                       ; $1FFE2D |/ and $0000, 16 times
.ppu_warmup:
  STA $2006                                 ; $1FFE2E | write high byte
  STA $2006                                 ; $1FFE31 | write low byte
  EOR #$10                                  ; $1FFE34 | toggle $10 ↔ $00
  DEY                                       ; $1FFE36 |
  BNE .ppu_warmup                           ; $1FFE37 |
; --- clear zero page ($00-$FF) ---
  TYA                                       ; $1FFE39 | A = 0 (Y wrapped to 0)
.clear_zp:
  STA $0000,y                               ; $1FFE3A | clear byte at Y
  DEY                                       ; $1FFE3D | Y: 0, $FF, $FE, ..., $01
  BNE .clear_zp                             ; $1FFE3E |
; --- clear RAM pages $01-$06 ($0100-$06FF) ---
.clear_page:
  INC $01                                   ; $1FFE40 | advance page pointer ($01→$06)
.clear_byte:
  STA ($00),y                               ; $1FFE42 | clear byte via ($00/$01)+Y
  INY                                       ; $1FFE44 |
  BNE .clear_byte                           ; $1FFE45 | 256 bytes per page
  LDX $01                                   ; $1FFE47 |
  CPX #$07                                  ; $1FFE49 |\ stop after page $06
  BNE .clear_page                           ; $1FFE4B |/ (leaves stack area $0700+ alone)
; --- initialize sound buffer ($DC-$E3) to $88 (no sound) ---
  LDY #$07                                  ; $1FFE4D |
  LDA #$88                                  ; $1FFE4F | $88 = "no sound" sentinel
.init_sound_buf:
  STA $DC,x                                 ; $1FFE51 | X=7..0 → $E3..$DC
  DEX                                       ; $1FFE53 |
  BPL .init_sound_buf                       ; $1FFE54 |
; --- hardware/bank initialization ---
  LDA #$18                                  ; $1FFE56 |\ $FE = PPUMASK value
  STA $FE                                   ; $1FFE58 |/ ($18 = show sprites + background)
  LDA #$00                                  ; $1FFE5A |\ MMC3 mirroring: vertical
  STA $A000                                 ; $1FFE5C |/
  LDX #$1C                                  ; $1FFE5F |\ $F4/$F5 = initial PRG banks
  STX $F4                                   ; $1FFE61 | | bank $1C at $8000-$9FFF
  INX                                       ; $1FFE63 | | bank $1D at $A000-$BFFF
  STX $F5                                   ; $1FFE64 | |
  JSR select_PRG_banks                      ; $1FFE66 |/
  LDA #$40                                  ; $1FFE69 |\ CHR bank setup:
  STA $E8                                   ; $1FFE6B | | $E8=$40 (2KB bank 0)
  LDA #$42                                  ; $1FFE6D | | $E9=$42 (2KB bank 1)
  STA $E9                                   ; $1FFE6F | | $EA=$00 (1KB bank 2)
  LDA #$00                                  ; $1FFE71 | | $EB=$01 (1KB bank 3)
  STA $EA                                   ; $1FFE73 | | $EC=$0A (1KB bank 4)
  LDA #$01                                  ; $1FFE75 | | $ED=$0B (1KB bank 5)
  STA $EB                                   ; $1FFE77 | |
  LDA #$0A                                  ; $1FFE79 | |
  STA $EC                                   ; $1FFE7B | |
  LDA #$0B                                  ; $1FFE7D | |
  STA $ED                                   ; $1FFE7F | |
  JSR update_CHR_banks                      ; $1FFE81 |/
  JSR code_1EC5E9                           ; $1FFE84 | init OAM / sprite state
  LDA #$20                                  ; $1FFE87 |\ clear nametable 0 ($2000)
  LDX #$00                                  ; $1FFE89 | | A=addr hi, X=fill, Y=attr fill
  LDY #$00                                  ; $1FFE8B | |
  JSR code_1EC59D                           ; $1FFE8D |/
  LDA #$24                                  ; $1FFE90 |\ clear nametable 1 ($2400)
  LDX #$00                                  ; $1FFE92 | |
  LDY #$00                                  ; $1FFE94 | |
  JSR code_1EC59D                           ; $1FFE96 |/
; --- register main game task (slot 0, address $C8D0) ---
  LDA #$C8                                  ; $1FFE99 |\ $93/$94 = $C8D0 (main game entry)
  STA $94                                   ; $1FFE9B | | (in bank $1C, always-mapped range)
  LDA #$D0                                  ; $1FFE9D | |
  STA $93                                   ; $1FFE9F |/
  LDA #$00                                  ; $1FFEA1 | A = slot 0
  JSR task_register                         ; $1FFEA3 | register task with address
  LDA #$88                                  ; $1FFEA6 |\ $FF = PPUCTRL: NMI enable + sprite $1000
  STA $FF                                   ; $1FFEA8 |/
; fall through to scheduler
; ===========================================================================
; task_scheduler — cooperative multitasking scheduler
; ===========================================================================
; MM3 uses a simple cooperative scheduler with 4 task slots at $80-$8F.
; Each slot is 4 bytes:
;   byte 0 ($80,x): state — $00=free, $01=sleeping, $02=running,
;                            $04=ready (woken by NMI), $08=fresh (has address)
;   byte 1 ($81,x): sleep countdown (decremented by NMI when state=$01)
;   byte 2 ($82,x): saved stack pointer (state $04) or address low (state $08)
;   byte 3 ($83,x): address high (state $08 only)
;
; The scheduler spins until a task with state >= $04 is found, then either:
;   state $08: JMP to address stored in bytes 2-3 (fresh task launch)
;   state $04: restore stack pointer from byte 2 and RTS (resume coroutine)
;
; NMI decrements sleeping tasks' countdowns and sets state $04 when done.
; Task slot 0 gets controller input read on resume (code_1EC545).
;
; $90 = NMI-occurred flag (set $FF by NMI, forces rescan)
; $91 = current task slot index (0-3)
; ---------------------------------------------------------------------------
task_scheduler:
  LDX #$FF                                  ; $1FFEAA |\ reset stack to top
  TXS                                       ; $1FFEAC |/ (discard all coroutine frames)
.rescan:
  LDX #$00                                  ; $1FFEAD |\ clear NMI flag
  STX $90                                   ; $1FFEAF |/
  LDY #$04                                  ; $1FFEB1 | 4 slots to check
.scan_loop:
  LDA $80,x                                 ; $1FFEB3 |\ state >= $04? (ready or fresh)
  CMP #$04                                  ; $1FFEB5 | |
  BCS .found_task                           ; $1FFEB7 |/
  INX                                       ; $1FFEB9 |\ advance to next slot (+4 bytes)
  INX                                       ; $1FFEBA | |
  INX                                       ; $1FFEBB | |
  INX                                       ; $1FFEBC |/
  DEY                                       ; $1FFEBD |\ more slots?
  BNE .scan_loop                            ; $1FFEBE |/
  JMP .rescan                               ; $1FFEC0 | no runnable tasks, spin until NMI

.found_task:
  LDA $90                                   ; $1FFEC3 |\ if NMI fired during scan,
  BNE .rescan                               ; $1FFEC5 |/ rescan (states may have changed)
  DEY                                       ; $1FFEC7 |\ convert Y countdown → slot index
  TYA                                       ; $1FFEC8 | | Y=3→0, Y=2→1, Y=1→2, Y=0→3
  EOR #$03                                  ; $1FFEC9 | |
  STA $91                                   ; $1FFECB |/ $91 = current slot index
  LDY $80,x                                 ; $1FFECD | Y = task state
  LDA #$02                                  ; $1FFECF |\ mark slot as running
  STA $80,x                                 ; $1FFED1 |/
  CPY #$08                                  ; $1FFED3 |\ state $08? → fresh task (JMP)
  BNE .resume_coroutine                     ; $1FFED5 |/
  LDA $82,x                                 ; $1FFED7 |\ load address from slot
  STA $93                                   ; $1FFED9 | |
  LDA $83,x                                 ; $1FFEDB | |
  STA $94                                   ; $1FFEDD |/
  JMP ($0093)                               ; $1FFEDF | launch task at stored address

.resume_coroutine:
  LDA $82,x                                 ; $1FFEE2 |\ restore saved stack pointer
  TAX                                       ; $1FFEE4 | |
  TXS                                       ; $1FFEE5 |/
  LDA $91                                   ; $1FFEE6 |\ slot 0? read controllers first
  BNE .restore_regs                         ; $1FFEE8 |/ (only main game task gets input)
  JSR code_1EC545                           ; $1FFEEA | read_controllers
.restore_regs:
  PLA                                       ; $1FFEED |\ restore Y and X from stack
  TAY                                       ; $1FFEEE | | (saved by task_yield)
  PLA                                       ; $1FFEEF | |
  TAX                                       ; $1FFEF0 |/
  RTS                                       ; $1FFEF1 | resume coroutine after yield

; ===========================================================================
; Coroutine primitives — task registration, yielding, and destruction
; ===========================================================================
; These routines manage the cooperative scheduler's task slots.
;
; task_register:   register a new task with an address (state $08)
; task_kill_by_id: free a task slot by ID (A = slot index)
; task_kill_self:  free current task and return to scheduler
; slot_offset_self/slot_offset: convert slot index → byte offset (×4)
; task_yield_x:    yield for X frames (calls task_yield in a loop)
; task_yield:      yield for 1 frame (save state, sleep, return to scheduler)
; ---------------------------------------------------------------------------

; --- task_register — A = slot index, $93/$94 = entry address ---
task_register:
  JSR slot_offset                           ; $1FFEF2 | X = A × 4
  LDA $93                                   ; $1FFEF5 |\ store address in slot bytes 2-3
  STA $82,x                                 ; $1FFEF7 | |
  LDA $94                                   ; $1FFEF9 | |
  STA $83,x                                 ; $1FFEFB |/
  LDA #$08                                  ; $1FFEFD |\ state = $08 (fresh, has address)
  STA $80,x                                 ; $1FFEFF |/
  RTS                                       ; $1FFF01 |

; --- task_kill_by_id — A = slot index to kill ---
task_kill_by_id:
  JSR slot_offset                           ; $1FFF02 | X = A × 4
  LDA #$00                                  ; $1FFF05 |\ state = $00 (free)
  STA $80,x                                 ; $1FFF07 |/
  RTS                                       ; $1FFF09 |

; --- task_kill_self — kill current task ($91) and return to scheduler ---
task_kill_self:
  JSR slot_offset_self                      ; $1FFF0A | X = $91 × 4
  LDA #$00                                  ; $1FFF0D |\ state = $00 (free)
  STA $80,x                                 ; $1FFF0F |/
  JMP task_scheduler                        ; $1FFF11 | back to scheduler (never returns)

; --- slot_offset_self — X = $91 × 4 (current task's byte offset) ---
slot_offset_self:
  LDA $91                                   ; $1FFF14 | load current task index
; --- slot_offset — X = A × 4 (task slot byte offset) ---
slot_offset:
  ASL                                       ; $1FFF16 |\ A × 4
  ASL                                       ; $1FFF17 | |
  TAX                                       ; $1FFF18 |/
  RTS                                       ; $1FFF19 |

; --- task_yield_x — yield for X frames ---
; Called extensively from cutscene/level-transition code for timed waits.
task_yield_x:
  JSR task_yield                            ; $1FFF1A | yield one frame
  DEX                                       ; $1FFF1D |\ loop X times
  BNE task_yield_x                          ; $1FFF1E |/
  RTS                                       ; $1FFF20 |

; --- task_yield — yield current task for 1 frame ---
; Saves X/Y on stack, stores sleep countdown and stack pointer in the
; task slot, sets state to $01 (sleeping), then jumps to scheduler.
; NMI will decrement the countdown; when it reaches 0, state → $04.
; Scheduler then restores SP and does RTS to resume here.
task_yield:
  LDA #$01                                  ; $1FFF21 |\ $93 = sleep frames (1)
  STA $93                                   ; $1FFF23 |/
  TXA                                       ; $1FFF25 |\ save X and Y on stack
  PHA                                       ; $1FFF26 | | (scheduler's .restore_regs will
  TYA                                       ; $1FFF27 | |  PLA these back on resume)
  PHA                                       ; $1FFF28 |/
  JSR slot_offset_self                      ; $1FFF29 | X = $91 × 4
  LDA $93                                   ; $1FFF2C |\ store sleep countdown in byte 1
  STA $81,x                                 ; $1FFF2E |/
  LDA #$01                                  ; $1FFF30 |\ state = $01 (sleeping)
  STA $80,x                                 ; $1FFF32 |/
  TXA                                       ; $1FFF34 |\ Y = slot byte offset
  TAY                                       ; $1FFF35 |/
  TSX                                       ; $1FFF36 |\ save current stack pointer
  STX $82,y                                 ; $1FFF37 |/ in slot byte 2
  JMP task_scheduler                        ; $1FFF39 | hand off to scheduler

update_CHR_banks:
  LDA #$FF                                  ; $1FFF3C |\  turns on the flag for
  STA $1B                                   ; $1FFF3E | | refreshing CHR banks
  RTS                                       ; $1FFF40 |/  during NMI

; selects all 6 swappable CHR banks
; based on what's in $E8~$ED
select_CHR_banks:
  LDA $1B                                   ; $1FFF41 |\ test select CHR flag
  BEQ .ret                                  ; $1FFF43 |/ return if not on
.reset_flag:
  LDX #$00                                  ; $1FFF45 |\ reset select CHR flag
  STX $1B                                   ; $1FFF47 |/ immediately, one-off usage
.loop:
  STX $8000                                 ; $1FFF49 |\
  LDA $E8,x                                 ; $1FFF4C | | loop index $00 to $05
  STA $8001                                 ; $1FFF4E | | -> bank select register
  INX                                       ; $1FFF51 | | fetch CHR bank from RAM
  CPX #$06                                  ; $1FFF52 | | -> bank data register
  BNE .loop                                 ; $1FFF54 |/
.ret:
  RTS                                       ; $1FFF56 |

; ===========================================================================
; process_frame_and_yield — run one frame of game logic, then yield to NMI
; ===========================================================================
; Core game loop primitive. Processes all entities, builds OAM sprite data,
; clears $EE (signals "ready for NMI to render"), yields one frame, then
; sets $EE (signals "NMI done, safe to modify state").
;
; process_frame_yield_with_player: sets $97=$04 (include player sprites)
; process_frame_and_yield: uses caller's $97 value
;
; $97 = OAM write index start (controls which sprite slots to fill):
;   $04 = start after sprite 0 (include player), $0C = skip player sprites
; $EE = rendering phase flag (0=NMI pending, nonzero=NMI completed)
; ---------------------------------------------------------------------------
process_frame_yield_with_player:
  LDA #$04                                  ; $1FFF57 |\ $97 = $04: start OAM after sprite 0
  STA $97                                   ; $1FFF59 |/ (include player in sprite update)
process_frame_and_yield:
  JSR code_1EC5E9                           ; $1FFF5B | process entities (sprite state)
  JSR update_entity_sprites                 ; $1FFF5E | build OAM buffer from entity data
  LDA #$00                                  ; $1FFF61 |\ $EE = 0: "waiting for NMI"
  STA $EE                                   ; $1FFF63 |/
  JSR task_yield                            ; $1FFF65 | sleep 1 frame (NMI will render)
  INC $EE                                   ; $1FFF68 | $EE = 1: "NMI done, frame complete"
  RTS                                       ; $1FFF6A |

; selects both swappable PRG banks
; based on $F4 and $F5
select_PRG_banks:
  INC $F6                                   ; $1FFF6B | flag on "selecting PRG bank"
  LDA #$06                                  ; $1FFF6D |\
  STA $F0                                   ; $1FFF6F | |
  STA $8000                                 ; $1FFF71 | | select the bank in $F4
  LDA $F4                                   ; $1FFF74 | | as $8000-$9FFF
  STA $F2                                   ; $1FFF76 | | also mirror in $F2
  STA $8001                                 ; $1FFF78 |/
  LDA #$07                                  ; $1FFF7B |\
  STA $F0                                   ; $1FFF7D | |
  STA $8000                                 ; $1FFF7F | | select the bank in $F5
  LDA $F5                                   ; $1FFF82 | | as $A000-$BFFF
  STA $F3                                   ; $1FFF84 | | also mirror in $F3
  STA $8001                                 ; $1FFF86 |/
  DEC $F6                                   ; $1FFF89 | flag selecting back off (done)
  LDA $F7                                   ; $1FFF8B |\ if NMI and non-NMI race condition
  BNE play_sounds                           ; $1FFF8D |/ we still need to play sounds
  RTS                                       ; $1FFF8F | else just return

; go through circular sound buffer and pop for play
; handle NMI simultaneous bank changes as well
play_sounds:
  LDA $F6                                   ; $1FFF90 |\ this means both NMI and non
  BNE .flag_simultaneous                    ; $1FFF92 |/ are trying to select banks
  LDA #$06                                  ; $1FFF94 |\
  STA $8000                                 ; $1FFF96 | |
  LDA #$16                                  ; $1FFF99 | | select bank 16 for $8000-$9FFF
  STA $8001                                 ; $1FFF9B | | and 17 for $A000-$BFFF
  LDA #$07                                  ; $1FFF9E | |
  STA $8000                                 ; $1FFFA0 | |
  LDA #$17                                  ; $1FFFA3 | |
  STA $8001                                 ; $1FFFA5 |/
.loop_sound:
  LDX $DB                                   ; $1FFFA8 |\  is current sound slot in buffer
  LDA $DC,x                                 ; $1FFFAA | | == $88? this means
  CMP #$88                                  ; $1FFFAC | | no sound, skip processing
  BEQ .code_1FFFC2                          ; $1FFFAE |/
  PHA                                       ; $1FFFB0 | push sound ID
  LDA #$88                                  ; $1FFFB1 |\ clear sound ID immediately
  STA $DC,x                                 ; $1FFFB3 |/ in circular buffer
  INX                                       ; $1FFFB5 |\
  TXA                                       ; $1FFFB6 | | increment circular buffer index
  AND #$07                                  ; $1FFFB7 | | with wraparound $07 -> $00
  STA $DB                                   ; $1FFFB9 |/
  PLA                                       ; $1FFFBB |\ play sound ID
  JSR $8003                                 ; $1FFFBC |/
  JMP .loop_sound                           ; $1FFFBF | check next slot

.code_1FFFC2:
  JSR $8000                                 ; $1FFFC2 |
  LDA #$00                                  ; $1FFFC5 |\ clear race condition flag
  STA $F7                                   ; $1FFFC7 |/
  JMP select_PRG_banks                      ; $1FFFC9 |

.flag_simultaneous:
  INC $F7                                   ; $1FFFCC | flag the race condition
  RTS                                       ; $1FFFCE |

  db $05, $10, $11, $04, $41, $33, $5C, $D4 ; $1FFFCF |
  db $45, $82, $00, $EF, $51, $68, $50, $67 ; $1FFFD7 |
  db $10, $1C, $00, $07, $04, $CD, $50, $00 ; $1FFFDF |
  db $50, $04, $15, $96, $00, $71, $14, $94 ; $1FFFE7 |
  db $15, $DD, $0E, $97, $C3, $43, $04, $00 ; $1FFFEF |
  db $00, $08, $57                          ; $1FFFF7 |

; interrupt vectors
  dw NMI                                    ; $1FFFFA |
  dw RESET                                  ; $1FFFFC |
  dw IRQ                                    ; $1FFFFE |
