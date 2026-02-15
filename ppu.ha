// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Pixel Processing Unit ([[ppu]]) - scanline-based renderer for
// the Game Boy. Simplified model: no pixel FIFO, no OAM
// corruption bugs. Renders one complete scanline at Mode 3 entry.

// Screen width in pixels.
export def SCREEN_W: size = 160;

// Screen height in pixels.
export def SCREEN_H: size = 144;

// LCDC register bit flags.
def LCDC_ENABLE: u8 = 0x80;
def LCDC_WIN_MAP: u8 = 0x40;
def LCDC_WIN_ENABLE: u8 = 0x20;
def LCDC_TILE_DATA: u8 = 0x10;
def LCDC_BG_MAP: u8 = 0x08;
def LCDC_OBJ_SIZE: u8 = 0x04;
def LCDC_OBJ_ENABLE: u8 = 0x02;
def LCDC_BG_ENABLE: u8 = 0x01;

// STAT register bit flags.
def STAT_LYC_INT: u8 = 0x40;
def STAT_OAM_INT: u8 = 0x20;
def STAT_VBLANK_INT: u8 = 0x10;
def STAT_HBLANK_INT: u8 = 0x08;
def STAT_LYC_FLAG: u8 = 0x04;

def TOTAL_SCANLINES: uint = 154;
def OAM_SCAN_CYCLES: uint = 80;
def PIXEL_TRANSFER_END: uint = 252;
def CYCLES_PER_SCANLINE: uint = 456;

// PPU state including framebuffer, scanline counters, and
// window tracking.
export type ppu = struct {
	framebuffer: [SCREEN_W * SCREEN_H]u8,
	bg_color_idx: [SCREEN_W * SCREEN_H]u8,
	scanline: uint,
	scanline_cycles: uint,
	window_line: uint,
	window_was_on: bool,
	lcd_enabled: bool,
	stat_line_high: bool,
};

// Advances the [[ppu]] by one T-cycle. Updates STAT, LY, and
// triggers scanline rendering and [[INT_VBLANK]] / [[INT_STAT]]
// interrupts as needed.
export fn ppu_update(g: *ppu, m: *mmu) void = {
	const lcd_on = (m.io[IO_LCDC] & LCDC_ENABLE) != 0;

	// LCD off: reset state
	if (!lcd_on) {
		g.lcd_enabled = false;
		g.scanline = 0;
		g.scanline_cycles = 0;
		g.window_line = 0;
		g.window_was_on = false;
		m.io[IO_LY] = 0;
		m.io[IO_STAT] &= ~0x03u8;
		g.stat_line_high = false;
		return;
	};

	// LCD just turned on
	if (!g.lcd_enabled) {
		g.lcd_enabled = true;
		g.scanline = 0;
		g.scanline_cycles = 0;
		g.window_line = 0;
		g.window_was_on = false;
		m.io[IO_LY] = 0;
		g.stat_line_high = false;
	};

	g.scanline_cycles += 1;

	// Render at mode 3 entry (cycle 80) so scroll
	// registers are latched before the game can modify
	// them during HBlank.  This matches real hardware
	// where the PPU reads SCX/SCY early in the scanline.
	if (g.scanline_cycles == OAM_SCAN_CYCLES
			&& g.scanline < SCREEN_H: uint) {
		ppu_render_scanline(g, m);
	};

	// End of scanline: advance counters and fire VBlank.
	if (g.scanline_cycles >= CYCLES_PER_SCANLINE) {
		g.scanline_cycles = 0;

		g.scanline += 1;
		if (g.scanline >= TOTAL_SCANLINES) {
			g.scanline = 0;
			g.window_line = 0;
			g.window_was_on = false;
		};

		m.io[IO_LY] = g.scanline: u8;

		if (g.scanline == SCREEN_H: uint) {
			m.io[IO_IF] |= INT_VBLANK;
		};
	};

	// Update STAT register mode
	const mode: u8 = if (g.scanline >= SCREEN_H: uint)
		1 // VBlank
	else if (g.scanline_cycles < OAM_SCAN_CYCLES)
		2 // OAM scan
	else if (g.scanline_cycles < PIXEL_TRANSFER_END)
		3 // Pixel transfer
	else
		0; // HBlank

	const stat = m.io[IO_STAT];
	m.io[IO_STAT] = (stat & 0xFC) | mode;

	// LYC coincidence flag
	const lyc = m.io[IO_LYC];
	const ly = m.io[IO_LY];
	if (ly == lyc) {
		m.io[IO_STAT] |= STAT_LYC_FLAG;
	} else {
		m.io[IO_STAT] &= ~STAT_LYC_FLAG;
	};

	// STAT interrupt (rising edge detection)
	const new_stat = m.io[IO_STAT];
	const stat_line =
		// LYC=LY
		((new_stat & STAT_LYC_INT) != 0
			&& (new_stat & STAT_LYC_FLAG) != 0)
		// Mode 2 (OAM scan)
		|| ((new_stat & STAT_OAM_INT) != 0
			&& mode == 2)
		// Mode 1 (VBlank)
		|| ((new_stat & STAT_VBLANK_INT) != 0
			&& mode == 1)
		// Mode 0 (HBlank)
		|| ((new_stat & STAT_HBLANK_INT) != 0
			&& mode == 0);

	if (stat_line && !g.stat_line_high) {
		m.io[IO_IF] |= INT_STAT;
	};
	g.stat_line_high = stat_line;
};

// Returns the VRAM address for a tile based on
// [[LCDC_TILE_DATA]] addressing mode.
fn ppu_get_tile_addr(tile_idx: u8, lcdc: u8) uint = {
	if ((lcdc & LCDC_TILE_DATA) != 0) {
		// 0x8000 mode: unsigned addressing
		return tile_idx: uint * 16;
	};
	// 0x8800 mode: signed addressing
	const signed_idx = tile_idx: i8;
	return (0x1000
		+ signed_idx: int * 16): uint;
};

// Decodes a single tile pixel, returning the 2-bit color
// index. Looks up the tile in the given map_base region of
// VRAM and extracts pixel (px, py) within the tile at
// (tile_x, tile_y).
fn ppu_decode_tile_pixel(
	m: *mmu,
	lcdc: u8,
	map_base: uint,
	tile_x: uint,
	tile_y: uint,
	px: uint,
	py: uint,
) u8 = {
	const map_addr = map_base + tile_y * 32 + tile_x;
	if (map_addr >= len(m.vram)) return 0;
	const ti = m.vram[map_addr];
	const ta = ppu_get_tile_addr(ti, lcdc) + py * 2;
	if (ta + 1 >= len(m.vram)) return 0;
	const b1 = m.vram[ta];
	const b2 = m.vram[ta + 1];
	const bit = 7 - px;
	const lo = (b1 >> bit: u8) & 1;
	const hi = (b2 >> bit: u8) & 1;
	return lo | (hi << 1);
};

// Renders a complete scanline (background, window, sprites).
fn ppu_render_scanline(g: *ppu, m: *mmu) void = {
	const ly = g.scanline;
	const lcdc = m.io[IO_LCDC];
	const bgp = m.io[IO_BGP];
	const obp0 = m.io[IO_OBP0];
	const obp1 = m.io[IO_OBP1];
	const wy = m.io[IO_WY];
	const wx = m.io[IO_WX];
	const scy = m.io[IO_SCY];
	const scx = m.io[IO_SCX];

	const window_enabled =
		(lcdc & LCDC_WIN_ENABLE) != 0;
	const window_visible = window_enabled
		&& wy: uint <= ly && wx <= 166;
	// Render each pixel
	for (let x: uint = 0; x < SCREEN_W; x += 1) {
		let color_idx: u8 = 0;
		const in_window = window_visible
			&& x: int >= wx: int - 7;

		if ((lcdc & LCDC_BG_ENABLE) != 0) {
			if (in_window) {
				const win_x: uint =
					(x: int - (wx: int - 7)): uint;
				const win_y = g.window_line;
				const map_base: uint =
					if ((lcdc & LCDC_WIN_MAP) != 0)
						0x1C00
					else
						0x1800;
				color_idx =
					ppu_decode_tile_pixel(
						m, lcdc, map_base,
						win_x / 8,
						win_y / 8,
						win_x % 8,
						win_y % 8,
					);
			} else {
				const bg_x =
					(x + scx: uint) & 0xFF;
				const bg_y =
					(ly + scy: uint) & 0xFF;
				const map_base: uint =
					if ((lcdc & LCDC_BG_MAP) != 0)
						0x1C00
					else
						0x1800;
				color_idx =
					ppu_decode_tile_pixel(
						m, lcdc, map_base,
						bg_x / 8, bg_y / 8,
						bg_x % 8, bg_y % 8,
					);
			};
		};

		const idx = ly * SCREEN_W + x;
		g.bg_color_idx[idx] = color_idx;
		g.framebuffer[idx] =
			(bgp >> (color_idx * 2)) & 0x03;
	};

	if (window_visible) {
		g.window_line += 1;
		g.window_was_on = true;
	};

	// Render sprites
	if ((lcdc & LCDC_OBJ_ENABLE) != 0) {
		ppu_render_sprites(
			g, m, ly, lcdc, obp0, obp1,
		);
	};
};

// Renders sprites on a given scanline.
fn ppu_render_sprites(
	g: *ppu,
	m: *mmu,
	ly: uint,
	lcdc: u8,
	obp0: u8,
	obp1: u8,
) void = {
	const sprite_height: uint =
		if ((lcdc & LCDC_OBJ_SIZE) != 0) 16 else 8;

	// Collect visible sprites (max 10, sorted by X
	// then OAM index)
	let visible: [10]uint = [0...];
	let visible_x: [10]int = [0...];
	let vcount: uint = 0;

	for (let i: uint = 0; i < 40 && vcount < 10;
			i += 1) {
		const oam_y = m.oam[i * 4]: int - 16;
		const oam_x = m.oam[i * 4 + 1]: int - 8;
		if (ly: int >= oam_y && ly: int < oam_y
				+ sprite_height: int) {
			// Insertion sort by X, then OAM index
			let pos = vcount;
			for (pos > 0
					&& (oam_x < visible_x[pos - 1]
					|| (oam_x == visible_x[pos - 1]
					&& i < visible[pos - 1]))) {
				visible[pos] = visible[pos - 1];
				visible_x[pos] =
					visible_x[pos - 1];
				pos -= 1;
			};
			visible[pos] = i;
			visible_x[pos] = oam_x;
			vcount += 1;
		};
	};

	// Render in reverse order so higher-priority
	// sprites draw last
	let i = vcount;
	for (i > 0) {
		i -= 1;
		const sprite = visible[i];
		const oam_addr = sprite * 4;
		const sprite_y =
			m.oam[oam_addr]: int - 16;
		const sprite_x =
			m.oam[oam_addr + 1]: int - 8;
		let tile_idx = m.oam[oam_addr + 2];
		const attrs = m.oam[oam_addr + 3];

		const priority = (attrs & 0x80) != 0;
		const y_flip = (attrs & 0x40) != 0;
		const x_flip = (attrs & 0x20) != 0;
		const use_pal1 = (attrs & 0x10) != 0;

		if (sprite_height == 16)
			tile_idx &= 0xFE;

		let row: int = ly: int - sprite_y;
		if (y_flip)
			row = sprite_height: int - 1 - row;

		let actual_tile = tile_idx;
		if (sprite_height == 16 && row >= 8) {
			actual_tile = tile_idx + 1;
			row -= 8;
		};

		const tile_addr = actual_tile: uint * 16
			+ row: uint * 2;
		if (tile_addr + 1 >= len(m.vram))
			continue;
		const b1 = m.vram[tile_addr];
		const b2 = m.vram[tile_addr + 1];

		const pal: u8 =
			if (use_pal1) obp1 else obp0;

		for (let px: int = 0; px < 8; px += 1) {
			const screen_x = sprite_x + px;
			if (screen_x < 0
					|| screen_x
					>= SCREEN_W: int)
				continue;

			const bit: uint =
				if (x_flip) px: uint
				else (7 - px): uint;

			const c =
				((b1 >> bit: u8) & 1)
				| (((b2 >> bit: u8) & 1)
				<< 1);
			if (c == 0) continue;

			const fb_idx = ly * SCREEN_W
				+ screen_x: uint;
			if (priority
					&& g.bg_color_idx[fb_idx]
					!= 0)
				continue;

			g.framebuffer[fb_idx] =
				(pal >> (c * 2)) & 0x03;
		};
	};
};
