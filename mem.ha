// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Memory Management Unit ([[mmu]]) for the Game Boy.
// Handles memory mapping, I/O registers, and OAM DMA.
// Holds references to peripheral components for bus routing;
// call [[init]] on the parent [[gameboy]] before use.

use fmt;

// I/O register offsets (relative to 0xFF00).
def IO_JOYP: size = 0x00;
def IO_SB: size = 0x01;
def IO_SC: size = 0x02;
def IO_IF: size = 0x0F;
def IO_LCDC: size = 0x40;
def IO_STAT: size = 0x41;
def IO_SCY: size = 0x42;
def IO_SCX: size = 0x43;
def IO_LY: size = 0x44;
def IO_LYC: size = 0x45;
def IO_DMA: size = 0x46;
def IO_BGP: size = 0x47;
def IO_OBP0: size = 0x48;
def IO_OBP1: size = 0x49;
def IO_WY: size = 0x4A;
def IO_WX: size = 0x4B;

// Interrupt flag bits for IF (0xFF0F) and IE (0xFFFF).
export def INT_VBLANK: u8 = 0x01;
export def INT_STAT: u8 = 0x02;
export def INT_TIMER: u8 = 0x04;
export def INT_SERIAL: u8 = 0x08;
export def INT_JOYPAD: u8 = 0x10;

// Returns true if the given I/O address is unused and should
// return 0xFF on read or be ignored on write.
fn is_unused_io(addr: u16) bool =
	addr == 0xFF03
	|| (addr >= 0xFF08 && addr <= 0xFF0E)
	|| addr == 0xFF15
	|| addr == 0xFF1F
	|| addr == 0xFF27
	|| addr == 0xFF28
	|| addr == 0xFF29
	|| (addr >= 0xFF4C && addr <= 0xFF4F)
	|| (addr >= 0xFF51 && addr <= 0xFF7F);

// Memory management unit. Routes bus reads and writes to the
// [[cartridge]], [[timer]], [[joypad]], and [[apu]] via internal
// pointers set up by [[init]].
export type mmu = struct {
	// Peripheral pointers are nullable because the mmu is
	// constructed inside [[gameboy]] before stable addresses
	// exist for sibling fields.  [[init]] sets them once the
	// parent struct is placed; after that they are always
	// non-null.
	cart: nullable *cartridge,
	tmr: nullable *timer,
	joy: nullable *joypad,
	snd: nullable *apu,
	wram: [8192]u8,   // Work RAM (0xC000-0xDFFF)
	vram: [8192]u8,   // Video RAM (0x8000-0x9FFF)
	oam: [160]u8,     // OAM (0xFE00-0xFE9F)
	hram: [127]u8,    // High RAM (0xFF80-0xFFFE)
	io: [128]u8,      // I/O registers (0xFF00-0xFF7F)
	ie: u8,           // Interrupt Enable (0xFFFF)

	// Serial output for test ROMs.
	serial_buffer: [256]u8,
	serial_len: size,

	// OAM DMA state.
	dma_active: bool,
	dma_source: u16,
	dma_index: uint,
	dma_delay: i32,
	dma_cycles: i32,
};

// Reads a byte from the memory bus. Routes to [[cartridge]],
// [[timer]], [[joypad]], or [[apu]] as appropriate for the
// given address.
export fn mmu_read(m: *mmu, addr: u16) u8 = {
	if (addr < 0x8000) {
		return cart_read_rom(
			m.cart as *cartridge, addr,
		);
	};
	if (addr < 0xA000) {
		return m.vram[addr - 0x8000];
	};
	if (addr < 0xC000) {
		return cart_read_ram(
			m.cart as *cartridge, addr,
		);
	};
	if (addr < 0xE000) {
		return m.wram[addr - 0xC000];
	};
	if (addr < 0xFE00) {
		return m.wram[addr - 0xE000]; // Echo RAM
	};
	if (addr < 0xFEA0) {
		return m.oam[addr - 0xFE00];
	};
	if (addr < 0xFF00) {
		return 0xFF; // Unused
	};
	if (addr < 0xFF80) {
		return mmu_read_io(m, addr);
	};
	if (addr < 0xFFFF) {
		return m.hram[addr - 0xFF80];
	};
	return m.ie; // 0xFFFF
};

// Reads an I/O register (0xFF00-0xFF7F), dispatching to
// [[timer]], [[joypad]], or [[apu]] as needed.
fn mmu_read_io(m: *mmu, addr: u16) u8 = {
	const tmr = m.tmr as *timer;
	const joy = m.joy as *joypad;
	const snd = m.snd as *apu;

	// Range-based dispatches
	if (addr >= 0xFF04 && addr <= 0xFF07)
		return timer_read(tmr, addr);
	if ((addr >= 0xFF10 && addr <= 0xFF26)
			|| (addr >= 0xFF30
			&& addr <= 0xFF3F)) {
		return apu_read(snd, addr);
	};

	// Unused I/O registers return 0xFF
	if (is_unused_io(addr)) return 0xFF;

	return mmu_read_io_discrete(m, joy, addr);
};

// Reads discrete I/O registers not handled by range dispatch.
fn mmu_read_io_discrete(m: *mmu, joy: *joypad, addr: u16) u8 =
	switch (addr) {
	case 0xFF00 =>
		yield joypad_read(joy) | 0xC0;
	case 0xFF02 =>
		yield m.io[IO_SC] | 0x7E;
	case 0xFF0F =>
		yield m.io[IO_IF] | 0xE0;
	case 0xFF41 =>
		yield m.io[IO_STAT] | 0x80;
	case =>
		yield m.io[addr - 0xFF00];
	};

// Writes a byte to the memory bus. Routes to [[cartridge]],
// [[timer]], [[joypad]], or [[apu]] as appropriate for the
// given address.
export fn mmu_write(
	m: *mmu,
	addr: u16,
	value: u8,
) void = {
	if (addr < 0x8000) {
		cart_write_control(
			m.cart as *cartridge, addr, value,
		);
		return;
	};
	if (addr < 0xA000) {
		m.vram[addr - 0x8000] = value;
		return;
	};
	if (addr < 0xC000) {
		cart_write_ram(
			m.cart as *cartridge, addr, value,
		);
		return;
	};
	if (addr < 0xE000) {
		m.wram[addr - 0xC000] = value;
		return;
	};
	if (addr < 0xFE00) {
		m.wram[addr - 0xE000] = value; // Echo RAM
		return;
	};
	if (addr < 0xFEA0) {
		m.oam[addr - 0xFE00] = value;
		return;
	};
	if (addr < 0xFF00) {
		return; // Unused
	};
	if (addr < 0xFF80) {
		mmu_write_io(m, addr, value);
		return;
	};
	if (addr < 0xFFFF) {
		m.hram[addr - 0xFF80] = value;
		return;
	};
	m.ie = value; // 0xFFFF
};

// Writes an I/O register (0xFF00-0xFF7F), dispatching to
// [[timer]], [[joypad]], or [[apu]] as needed. Handles
// special behaviors for serial, STAT, LYC, and DMA.
fn mmu_write_io(m: *mmu, addr: u16, value: u8) void = {
	const tmr = m.tmr as *timer;
	const joy = m.joy as *joypad;
	const snd = m.snd as *apu;

	// Unused registers ignore writes
	if (is_unused_io(addr)) return;

	// Range-based dispatches (timer and audio)
	if (addr >= 0xFF04 && addr <= 0xFF07) {
		timer_write(tmr, addr, value);
		return;
	};
	if ((addr >= 0xFF10 && addr <= 0xFF26)
			|| (addr >= 0xFF30
			&& addr <= 0xFF3F)) {
		apu_write(snd, addr, value);
		return;
	};

	// Discrete I/O registers with special behavior
	switch (addr) {
	case 0xFF00 =>
		if (joypad_write(joy, value)) {
			m.io[IO_IF] |= INT_JOYPAD;
		};
	case 0xFF02 =>
		if (value == 0x81) {
			const ch = m.io[IO_SB];
			if (ch == 0x0A || ch == 0x0D
					|| ch == 0x09
					|| (ch >= 0x20
					&& ch <= 0x7E)) {
				fmt::printf(
					"{}", ch: u32: rune,
				)!;
			};
			if (m.serial_len
					< len(m.serial_buffer)) {
				m.serial_buffer[m.serial_len] =
					ch;
				m.serial_len += 1;
			};
		};
	case 0xFF0F =>
		m.io[IO_IF] = value & 0x1F;
		return;
	case 0xFF41 =>
		const old_stat = m.io[IO_STAT];
		m.io[IO_STAT] = (old_stat & 0x07)
			| (value & 0x78) | 0x80;
		return;
	case 0xFF45 =>
		m.io[IO_LYC] = value;
		const lcd_on =
			(m.io[IO_LCDC] & LCDC_ENABLE) != 0;
		if (lcd_on) {
			const ly = m.io[IO_LY];
			if (value == ly) {
				m.io[IO_STAT] |= STAT_LYC_FLAG;
			} else {
				m.io[IO_STAT] &= ~STAT_LYC_FLAG;
			};
		};
		return;
	case 0xFF46 =>
		let high = value;
		if (high >= 0xE0) high &= 0xDF;
		m.dma_active = true;
		m.dma_source = high: u16 << 8;
		m.dma_index = 0;
		m.dma_delay = 8;
		m.dma_cycles = 0;
	case => void;
	};

	m.io[addr - 0xFF00] = value;
};

// Advances an active OAM DMA transfer by the given number
// of T-cycles.
export fn mmu_tick_dma(m: *mmu, cycles: i32) void = {
	if (!m.dma_active) return;

	let work = cycles;
	if (m.dma_delay > 0) {
		if (work < m.dma_delay) {
			m.dma_delay -= work;
			return;
		};
		work -= m.dma_delay;
		m.dma_delay = 0;
	};

	if (work <= 0) return;

	m.dma_cycles += work;
	for (m.dma_cycles >= 4
			&& m.dma_index < 160) {
		m.dma_cycles -= 4;
		const src = m.dma_source
			+ m.dma_index: u16;
		m.oam[m.dma_index] =
			mmu_read(m, src);
		m.dma_index += 1;
	};
	if (m.dma_index >= 160) {
		m.dma_active = false;
		m.dma_cycles = 0;
	};
};
