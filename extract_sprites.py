#!/usr/bin/env python3
"""Extract enemy sprites from MM3 ROM as PNG files, named by entity ID.

Reads the assembled ROM (mm3_orig_test.nes) and extracts the first animation
frame of each entity's sprite. Uses the NES 8x16 sprite rendering pipeline:
  entity → OAM ID → animation sequence → sprite definition → CHR tiles + positions

Output: enemy_sprites/XX.png for each entity ID $00-$8F with a valid sprite.
"""

import os
import struct
from PIL import Image

ROM_PATH = "mm3_orig_test.nes"
OUTPUT_DIR = "enemy_sprites"
HEADER_SIZE = 16
PRG_BANK_SIZE = 0x2000  # 8KB per bank
PRG_BANKS = 32
CHR_START = HEADER_SIZE + PRG_BANKS * PRG_BANK_SIZE  # after 16 + 256KB PRG

# --- NES master palette (FCEUX standard 2C02) ---
NES_PALETTE = [
    (0x62,0x62,0x62), (0x00,0x1F,0xB2), (0x24,0x04,0xC8), (0x52,0x00,0xB2),
    (0x73,0x00,0x76), (0x80,0x00,0x24), (0x73,0x0B,0x00), (0x52,0x28,0x00),
    (0x24,0x44,0x00), (0x00,0x57,0x00), (0x00,0x5C,0x00), (0x00,0x53,0x24),
    (0x00,0x3C,0x76), (0x00,0x00,0x00), (0x00,0x00,0x00), (0x00,0x00,0x00),
    (0xAB,0xAB,0xAB), (0x0D,0x57,0xFF), (0x4B,0x30,0xFF), (0x8A,0x13,0xFF),
    (0xBC,0x08,0xD6), (0xD2,0x12,0x69), (0xC7,0x2E,0x00), (0x9D,0x54,0x00),
    (0x60,0x7B,0x00), (0x20,0x98,0x00), (0x00,0xA3,0x00), (0x00,0x99,0x42),
    (0x00,0x7D,0xB4), (0x00,0x00,0x00), (0x00,0x00,0x00), (0x00,0x00,0x00),
    (0xFF,0xFF,0xFF), (0x53,0xAE,0xFF), (0x90,0x85,0xFF), (0xD3,0x65,0xFF),
    (0xFF,0x57,0xFF), (0xFF,0x5D,0xCF), (0xFF,0x77,0x57), (0xFF,0x9E,0x13),
    (0xB5,0xC5,0x00), (0x6E,0xE2,0x00), (0x38,0xED,0x2E), (0x12,0xE5,0x8C),
    (0x20,0xC8,0xFB), (0x3C,0x3C,0x3C), (0x00,0x00,0x00), (0x00,0x00,0x00),
    (0xFF,0xFF,0xFF), (0xB6,0xDA,0xFF), (0xCE,0xCA,0xFF), (0xE9,0xBE,0xFF),
    (0xFF,0xB8,0xFF), (0xFF,0xBA,0xEA), (0xFF,0xC5,0xBD), (0xFF,0xD5,0x9A),
    (0xE1,0xE5,0x8D), (0xBE,0xF0,0x8D), (0xA4,0xF5,0xA2), (0x98,0xF2,0xC8),
    (0x9E,0xE8,0xFC), (0xAE,0xAE,0xAE), (0x00,0x00,0x00), (0x00,0x00,0x00),
]

# Default sprite palettes (SP0-SP1) from fixed bank at $C898
# SP0: Mega Man (black, sky-blue, blue)
# SP1: Projectiles (black, white, pale yellow)
DEFAULT_SP01 = [0x0F, 0x0F, 0x2C, 0x11, 0x0F, 0x0F, 0x30, 0x37]

# Per-stage SP2-SP3 palette table offset in bank $01 at $A030
SP23_TABLE_ADDR = 0xA030


def nes_color_to_rgba(nes_idx, transparent=False):
    """Convert NES palette index to RGBA tuple."""
    if transparent:
        return (0, 0, 0, 0)
    nes_idx &= 0x3F  # mask to valid range
    r, g, b = NES_PALETTE[nes_idx]
    return (r, g, b, 255)


def build_stage_palettes(rom, stage):
    """Build 4 sprite palettes for a given stage using actual NES colors.

    SP0-SP1: fixed defaults from $C898
    SP2-SP3: per-stage from bank $01 $A030 table
    """
    return build_param_palettes(rom, stage)


def build_param_palettes(rom, param):
    """Build 4 sprite palettes from a CHR/palette param index.

    The $A000 init routine in bank $01 indexes the $A030 palette table
    by param*8. SP0-SP1 are always fixed defaults from $C898.
    SP2-SP3 are read from $A030 + param*8.
    """
    palettes = []
    # SP0 and SP1 from defaults
    for pal_idx in range(2):
        base = pal_idx * 4
        pal = [
            nes_color_to_rgba(DEFAULT_SP01[base], transparent=True),  # color 0 = transparent
            nes_color_to_rgba(DEFAULT_SP01[base + 1]),
            nes_color_to_rgba(DEFAULT_SP01[base + 2]),
            nes_color_to_rgba(DEFAULT_SP01[base + 3]),
        ]
        palettes.append(pal)
    # SP2 and SP3 from param-indexed table
    table_off = prg_offset(0x01, SP23_TABLE_ADDR + param * 8)
    for pal_idx in range(2):
        base = pal_idx * 4
        pal = [
            nes_color_to_rgba(rom[table_off + base], transparent=True),
            nes_color_to_rgba(rom[table_off + base + 1]),
            nes_color_to_rgba(rom[table_off + base + 2]),
            nes_color_to_rgba(rom[table_off + base + 3]),
        ]
        palettes.append(pal)
    return palettes


def prg_offset(bank, cpu_addr):
    """ROM file offset for a PRG bank CPU address ($8000-$BFFF)."""
    if cpu_addr >= 0xC000:
        # Fixed bank $1E/$1F
        bank = 0x1E + (cpu_addr - 0xC000) // PRG_BANK_SIZE
        local = (cpu_addr - 0xC000) % PRG_BANK_SIZE
    elif cpu_addr >= 0xA000:
        local = cpu_addr - 0xA000
    else:
        local = cpu_addr - 0x8000
    return HEADER_SIZE + bank * PRG_BANK_SIZE + local


def chr_ppu_to_rom(ppu_addr, chr_regs):
    """Convert PPU address to ROM file offset using CHR bank registers."""
    if ppu_addr < 0x0800:
        page = chr_regs[0]  # 2KB register, covers 2 pages
        sub = ppu_addr // 0x400
        local = ppu_addr % 0x400
        return CHR_START + (page + sub) * 0x400 + local
    elif ppu_addr < 0x1000:
        page = chr_regs[1]
        rel = ppu_addr - 0x0800
        sub = rel // 0x400
        local = rel % 0x400
        return CHR_START + (page + sub) * 0x400 + local
    elif ppu_addr < 0x1400:
        page = chr_regs[2]
        local = ppu_addr - 0x1000
        return CHR_START + page * 0x400 + local
    elif ppu_addr < 0x1800:
        page = chr_regs[3]
        local = ppu_addr - 0x1400
        return CHR_START + page * 0x400 + local
    elif ppu_addr < 0x1C00:
        page = chr_regs[4]
        local = ppu_addr - 0x1800
        return CHR_START + page * 0x400 + local
    else:
        page = chr_regs[5]
        local = ppu_addr - 0x1C00
        return CHR_START + page * 0x400 + local


def decode_tile_8x8(rom, rom_offset):
    """Decode a 16-byte NES 2bpp tile into 8x8 array of palette indices (0-3)."""
    if rom_offset < 0 or rom_offset + 16 > len(rom):
        return [[0]*8 for _ in range(8)]  # blank tile for out-of-bounds
    pixels = []
    for row in range(8):
        lo = rom[rom_offset + row]
        hi = rom[rom_offset + row + 8]
        row_px = []
        for col in range(7, -1, -1):
            px = ((lo >> col) & 1) | (((hi >> col) & 1) << 1)
            row_px.append(px)
        pixels.append(row_px)
    return pixels


def get_8x8_tile(rom, tile_id, chr_regs):
    """Get one 8x8 tile for an 8x8 sprite mode tile ID.

    MM3 uses 8x8 sprite mode with PPUCTRL bit 3 = 1 (sprites at $1000).
    Tile PPU address = $1000 + tile_id * 16.
    """
    ppu_addr = 0x1000 + tile_id * 16
    rom_off = chr_ppu_to_rom(ppu_addr, chr_regs)
    return decode_tile_8x8(rom, rom_off)


def extract_entity_sprite(rom, entity_id, chr_regs, palettes=None):
    """Extract the first animation frame sprite for an entity.

    palettes: list of 4 palettes, each a list of 4 RGBA tuples.
    Returns (image, info_dict) or (None, reason_string).
    """
    # 1. Get OAM ID from bank $00, table at $A300
    oam_id = rom[prg_offset(0x00, 0xA300 + entity_id)]
    if oam_id == 0:
        return None, "no OAM ID"

    # 2. Select animation bank ($1A or $1B based on bit 7)
    if oam_id & 0x80:
        anim_bank = 0x1B
    else:
        anim_bank = 0x1A
    anim_index = oam_id & 0x7F

    # 3. Get animation sequence pointer from $8000/$8080 in anim_bank
    ptr_lo = rom[prg_offset(anim_bank, 0x8000 + anim_index)]
    ptr_hi = rom[prg_offset(anim_bank, 0x8080 + anim_index)]
    anim_ptr = (ptr_hi << 8) | ptr_lo

    if anim_ptr < 0x8000 or anim_ptr >= 0xA000:
        return None, f"bad anim ptr ${anim_ptr:04X}"

    # 4. Read animation sequence: byte 0=frame_count, byte 1=duration, byte 2+=def_IDs
    anim_off = prg_offset(anim_bank, anim_ptr)
    frame_count = rom[anim_off]
    # duration = rom[anim_off + 1]
    sprite_def_id = rom[anim_off + 2]  # first frame

    if sprite_def_id == 0:
        return None, "sprite def ID = 0"

    # 5. Get sprite definition pointer from $8100/$8200 in anim_bank
    def_ptr_lo = rom[prg_offset(anim_bank, 0x8100 + sprite_def_id)]
    def_ptr_hi = rom[prg_offset(anim_bank, 0x8200 + sprite_def_id)]
    def_ptr = (def_ptr_hi << 8) | def_ptr_lo

    if def_ptr < 0x8000 or def_ptr >= 0xA000:
        return None, f"bad def ptr ${def_ptr:04X}"

    def_off = prg_offset(anim_bank, def_ptr)

    # 6. Parse sprite definition
    byte0 = rom[def_off]
    use_bank14 = bool(byte0 & 0x80)
    sprite_count = (byte0 & 0x7F) + 1  # 0-based counter → actual count
    offset_table_idx = rom[def_off + 1]

    # 7. Get position offset data from bank $19 (or $14)
    pos_bank = 0x14 if use_bank14 else 0x19
    pos_ptr_lo = rom[prg_offset(pos_bank, 0xBE00 + offset_table_idx)]
    pos_ptr_hi = rom[prg_offset(pos_bank, 0xBF00 + offset_table_idx)]
    pos_ptr = (pos_ptr_hi << 8) | pos_ptr_lo

    if pos_ptr < 0xA000 or pos_ptr >= 0xC000:
        return None, f"bad pos ptr ${pos_ptr:04X}"

    # Position data: Y0, X0, Y1, X1, ... for each sprite
    pos_off = prg_offset(pos_bank, pos_ptr)

    # 8. Read all sprites: tile IDs, attributes, positions
    sprites = []
    for i in range(sprite_count):
        tile_id = rom[def_off + 2 + i * 2]
        attr = rom[def_off + 3 + i * 2]
        y_off_raw = rom[pos_off + i * 2]
        x_off_raw = rom[pos_off + i * 2 + 1]
        # Convert to signed
        y_off = y_off_raw if y_off_raw < 128 else y_off_raw - 256
        x_off = x_off_raw if x_off_raw < 128 else x_off_raw - 256
        palette_idx = attr & 0x03
        h_flip = bool(attr & 0x40)
        v_flip = bool(attr & 0x80)
        sprites.append({
            'tile_id': tile_id,
            'y_off': y_off,
            'x_off': x_off,
            'palette': palette_idx,
            'h_flip': h_flip,
            'v_flip': v_flip,
        })

    if not sprites:
        return None, "no sprites"

    # 9. Calculate bounding box
    min_x = min(s['x_off'] for s in sprites)
    min_y = min(s['y_off'] for s in sprites)
    max_x = max(s['x_off'] + 8 for s in sprites)
    max_y = max(s['y_off'] + 8 for s in sprites)

    width = max_x - min_x
    height = max_y - min_y

    if width <= 0 or height <= 0 or width > 128 or height > 128:
        return None, f"bad dimensions {width}x{height}"

    # 10. Render to image
    img = Image.new('RGBA', (width, height), (0, 0, 0, 0))

    all_blank = True
    for s in sprites:
        tile = get_8x8_tile(rom, s['tile_id'], chr_regs)
        palette = palettes[s['palette']]

        # Apply V-flip: reverse row order
        if s['v_flip']:
            tile = tile[::-1]

        # Apply H-flip: reverse each row
        if s['h_flip']:
            tile = [row[::-1] for row in tile]

        # Draw 8x8 tile
        bx = s['x_off'] - min_x
        by = s['y_off'] - min_y
        for row in range(8):
            for col in range(8):
                px = tile[row][col]
                if px > 0:
                    all_blank = False
                    img.putpixel((bx + col, by + row), palette[px])

    if all_blank:
        return None, "all tiles blank (wrong CHR bank?)"

    # Scale up 3x for visibility
    img = img.resize((width * 3, height * 3), Image.NEAREST)

    info = {
        'oam_id': oam_id,
        'anim_bank': anim_bank,
        'sprite_def_id': sprite_def_id,
        'sprite_count': sprite_count,
        'use_bank14': use_bank14,
        'hp': rom[prg_offset(0x00, 0xA400 + entity_id)],
        'main_routine': rom[prg_offset(0x00, 0xA100 + entity_id)],
    }
    return img, info


def score_sprite_coherence(rom, entity_id, chr_regs, palettes):
    """Score a sprite rendering by visual coherence (connected vs scattered).

    Correct CHR banks produce tiles that form connected shapes.
    Wrong CHR banks produce scattered noise with many isolated pixels.
    Returns (score, img, info) where higher score = more coherent.
    """
    img, info = extract_entity_sprite(rom, entity_id, chr_regs, palettes)
    if img is None:
        return -1, img, info

    # Work on unscaled image (before 3x resize) - undo the resize
    w, h = img.size
    uw, uh = w // 3, h // 3
    small = img.resize((uw, uh), Image.NEAREST)
    pixels = small.load()

    # Count non-transparent pixels and neighbor connections
    opaque = 0
    connections = 0
    for y in range(uh):
        for x in range(uw):
            if pixels[x, y][3] > 0:
                opaque += 1
                # Check 4-connected neighbors
                for dx, dy in [(1, 0), (0, 1)]:
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < uw and 0 <= ny < uh and pixels[nx, ny][3] > 0:
                        connections += 1

    if opaque == 0:
        return -1, img, info

    # Coherence = neighbor connections per opaque pixel
    # Coherent sprites: ~1.5-2.0 (most pixels have 2+ neighbors)
    # Garbled sprites: ~0.5-1.0 (many isolated pixels/thin lines)
    coherence = connections / opaque
    # Weight by pixel count too (prefer renderings with more visible content)
    score = coherence * 1000 + opaque
    return score, img, info


def build_entity_chr_map(rom):
    """Build per-entity CHR configs by scanning enemy tables with per-room CHR.

    Each room within a stage has its own CHR/palette param (from $AA60),
    which indexes the $A200 CHR table and $A030 palette table in bank $01.
    The $AA40 table gives screen counts per room for screen→room mapping.

    Returns: dict of entity_id → list of (stage, chr_regs, param) tuples
    """
    chr_table_off = prg_offset(0x01, 0xA200)
    stage_to_bank_off = prg_offset(0x1E, 0xC8B9)
    entity_configs = {}  # entity_id → list of (stage, chr_regs, param)

    for stage in range(0x12):
        bank = rom[stage_to_bank_off + stage]

        # BG CHR banks for this stage
        e8 = rom[prg_offset(bank, 0xAA80)]
        e9 = rom[prg_offset(bank, 0xAA81)]

        # Build screen → CHR param mapping from $AA40/$AA60
        aa40_off = prg_offset(bank, 0xAA40)
        aa60_off = prg_offset(bank, 0xAA60)

        screen_to_param = {}
        screen_num = 0
        for room in range(32):
            config = rom[aa40_off + room]
            screen_count = config & 0x1F
            param = rom[aa60_off + room * 2]

            if param >= 0x40:  # end of valid rooms
                break

            for s in range(screen_count + 1):
                screen_to_param[screen_num + s] = param
            screen_num += screen_count + 1

        # Read enemy table and map each to its room's CHR config
        ab00_off = prg_offset(bank, 0xAB00)
        ae00_off = prg_offset(bank, 0xAE00)

        for i in range(256):
            scr = rom[ab00_off + i]
            entity_id = rom[ae00_off + i]
            if scr == 0xFF and entity_id == 0xFF:
                break
            if entity_id <= 0x8F:
                param = screen_to_param.get(scr, stage)  # fallback to stage index
                ec = rom[chr_table_off + param * 2]
                ed = rom[chr_table_off + param * 2 + 1]
                chr_regs = [e8, e9, 0x00, 0x01, ec, ed]

                if entity_id not in entity_configs:
                    entity_configs[entity_id] = []
                entity_configs[entity_id].append((stage, chr_regs, param))

    return entity_configs


def entity_has_stage_tiles(rom, entity_id):
    """Check if entity uses any tiles in $80-$FF (stage-specific CHR)."""
    oam_id = rom[prg_offset(0x00, 0xA300 + entity_id)]
    if oam_id == 0:
        return False

    anim_bank = 0x1B if (oam_id & 0x80) else 0x1A
    anim_index = oam_id & 0x7F

    ptr_lo = rom[prg_offset(anim_bank, 0x8000 + anim_index)]
    ptr_hi = rom[prg_offset(anim_bank, 0x8080 + anim_index)]
    anim_ptr = (ptr_hi << 8) | ptr_lo
    if anim_ptr < 0x8000 or anim_ptr >= 0xA000:
        return False

    anim_off = prg_offset(anim_bank, anim_ptr)
    sprite_def_id = rom[anim_off + 2]
    if sprite_def_id == 0:
        return False

    def_ptr_lo = rom[prg_offset(anim_bank, 0x8100 + sprite_def_id)]
    def_ptr_hi = rom[prg_offset(anim_bank, 0x8200 + sprite_def_id)]
    def_ptr = (def_ptr_hi << 8) | def_ptr_lo
    if def_ptr < 0x8000 or def_ptr >= 0xA000:
        return False

    def_off = prg_offset(anim_bank, def_ptr)
    sprite_count = (rom[def_off] & 0x7F) + 1
    for i in range(sprite_count):
        tile_id = rom[def_off + 2 + i * 2]
        if tile_id >= 0x80:
            return True
    return False


def main():
    with open(ROM_PATH, 'rb') as f:
        rom = f.read()

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    stage_names = [
        "Needle", "Magnet", "Gemini", "Hard", "Top", "Snake", "Spark", "Shadow",
        "DR-Needle", "DR-Gemini", "DR-Shadow", "DR-Spark",
        "Wily1", "Wily2", "Wily3", "Wily4", "Wily5", "Wily6",
    ]

    # Build entity → per-room CHR configs from $AE00 + $AA40/$AA60 tables
    entity_chr_map = build_entity_chr_map(rom)
    print(f"Entity→CHR mapping: {len(entity_chr_map)} entities in level data")

    # Fallback: per-stage default configs for entities not in level data
    chr_table_off = prg_offset(0x01, 0xA200)
    fallback_configs = []
    for stage in range(0x12):
        ec = rom[chr_table_off + stage * 2]
        ed = rom[chr_table_off + stage * 2 + 1]
        stg_bank = rom[prg_offset(0x1E, 0xC8B9 + stage)]
        e8 = rom[prg_offset(stg_bank, 0xAA80)]
        e9 = rom[prg_offset(stg_bank, 0xAA81)]
        fallback_configs.append({
            'stage': stage,
            'chr_regs': [e8, e9, 0x00, 0x01, ec, ed],
            'palettes': build_stage_palettes(rom, stage),
        })

    success = 0
    failed = 0

    for eid in range(0x90):
        has_stage_tiles = entity_has_stage_tiles(rom, eid)
        entity_configs = entity_chr_map.get(eid)

        if entity_configs and has_stage_tiles:
            # Entity has per-room CHR configs — prefer robot master stages (0-7)
            # over Doc Robot (8-11) over Wily fortress (12+), because bosses
            # appear in Wily stages with wrong initial-room CHR (the game
            # switches CHR dynamically when the boss spawns).
            rm_configs = [(s, c, p) for s, c, p in entity_configs if s < 8]
            doc_configs = [(s, c, p) for s, c, p in entity_configs if 8 <= s < 12]
            wily_configs = [(s, c, p) for s, c, p in entity_configs if s >= 12]
            preferred = rm_configs or doc_configs or wily_configs

            seen = set()
            configs_to_try = []
            for stage, chr_regs, param in preferred:
                key = (chr_regs[4], chr_regs[5])  # (ec, ed)
                if key not in seen:
                    seen.add(key)
                    palettes = build_param_palettes(rom, param)
                    configs_to_try.append({
                        'stage': stage,
                        'chr_regs': chr_regs,
                        'palettes': palettes,
                        'param': param,
                    })
        elif entity_configs:
            # Entity uses only shared tiles — any config works, use first
            stage, chr_regs, param = entity_configs[0]
            palettes = build_param_palettes(rom, param)
            configs_to_try = [{'stage': stage, 'chr_regs': chr_regs,
                               'palettes': palettes, 'param': param}]
        else:
            # Entity not in level data — try all 58 CHR params ($00-$39)
            # from the $A200 table, not just the 18 stage defaults.
            # Fortress bosses and spawned entities may use non-default params.
            seen = set()
            configs_to_try = []
            for param in range(0x3A):
                ec = rom[chr_table_off + param * 2]
                ed = rom[chr_table_off + param * 2 + 1]
                key = (ec, ed)
                if key not in seen:
                    seen.add(key)
                    chr_regs = [0, 0, 0x00, 0x01, ec, ed]
                    palettes = build_param_palettes(rom, param)
                    configs_to_try.append({
                        'stage': -1,
                        'chr_regs': chr_regs,
                        'palettes': palettes,
                        'param': param,
                    })

        best_count = -1
        best_img = None
        best_info = None
        best_stage = -1
        best_param = -1

        for cfg in configs_to_try:
            count, img, info = score_sprite_coherence(rom, eid, cfg['chr_regs'], cfg['palettes'])
            if count > best_count:
                best_count = count
                best_img = img
                best_info = info
                best_stage = cfg['stage']
                best_param = cfg.get('param', -1)

        if best_img is not None:
            path = os.path.join(OUTPUT_DIR, f"{eid:02X}.png")
            best_img.save(path)
            hp = best_info['hp']
            hp_str = "INV" if hp == 0xFF else str(hp)
            if best_stage >= 0 and best_stage < len(stage_names):
                stg_name = stage_names[best_stage]
            else:
                stg_name = "param"
            mapped = "room" if entity_configs else "heuristic"
            param_str = f"p${best_param:02X}" if best_param >= 0 else ""
            print(f"  ${eid:02X}: OAM=${best_info['oam_id']:02X} "
                  f"main=${best_info['main_routine']:02X} HP={hp_str} "
                  f"sprites={best_info['sprite_count']} "
                  f"CHR={stg_name} {param_str} ({mapped}) → {path}")
            success += 1
        else:
            reason = best_info if isinstance(best_info, str) else "unknown"
            if reason != "no OAM ID":
                print(f"  ${eid:02X}: SKIP ({reason})")
            failed += 1

    print(f"\nDone: {success} sprites extracted, {failed} skipped")


if __name__ == '__main__':
    main()
