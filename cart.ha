// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Game Boy [[cartridge]] and Memory Bank Controller ([[mbc_type]])
// support. Supports no-MBC, MBC1, MBC3 (without RTC), and MBC5.

// Memory bank controller type.
export type mbc_type = enum {
	NONE,
	MBC1,
	MBC3,
	MBC5,
};

// ROM cartridge with optional MBC and external RAM.
export type cartridge = struct {
	mbc: mbc_type,
	rom: []u8,
	ram: []u8,
	rom_bank: uint,
	ram_bank: uint,
	ram_enabled: bool,
	banking_mode: uint,  // MBC1 only: 0=ROM, 1=RAM
	mbc1_low5: uint,     // MBC1 only
	mbc1_high2: uint,    // MBC1 only
	rom_bank_mask: uint,
	ram_bank_mask: uint,
};

// Creates a [[cartridge]] from ROM data. The caller retains
// ownership of rom.
export fn newcart(rom: []u8) cartridge = {
	let c = cartridge {
		rom = rom,
		ram = [],
		rom_bank = 1,
		...
	};
	if (len(rom) <= 0x147) return c;

	const cart_type = rom[0x147];
	c.mbc = cart_detect_mbc(cart_type);

	let rom_banks: uint = len(rom): uint / 0x4000;
	if (rom_banks < 2) rom_banks = 2;
	c.rom_bank_mask = rom_banks - 1;

	cart_init_ram(&c, rom);
	if (c.mbc == mbc_type::MBC1) {
		c.mbc1_low5 = 1;
		c.mbc1_high2 = 0;
		cart_sync_mbc1(&c);
	};

	return c;
};

// Returns the [[mbc_type]] for a cartridge type byte (0x147).
fn cart_detect_mbc(cart: u8) mbc_type = switch (cart) {
case 0x01, 0x02, 0x03 =>
	yield mbc_type::MBC1;
case 0x0F, 0x10, 0x11, 0x12, 0x13 =>
	yield mbc_type::MBC3;
case 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E =>
	yield mbc_type::MBC5;
case =>
	yield mbc_type::NONE;
};

// Allocates external RAM based on the ROM header (0x149).
// The cartridge takes ownership of the allocated RAM;
// free it with [[cart_free]].
fn cart_init_ram(c: *cartridge, rom: []u8) void = {
	if (len(rom) <= 0x149) {
		c.ram = alloc([0u8...], 8192)!;
		return;
	};
	switch (rom[0x149]) {
	case 0x02 =>
		c.ram = alloc([0u8...], 8 * 1024)!;
	case 0x03 =>
		c.ram = alloc([0u8...], 32 * 1024)!;
		c.ram_bank_mask = 3;
	case 0x04 =>
		c.ram = alloc([0u8...], 128 * 1024)!;
		c.ram_bank_mask = 15;
	case 0x05 =>
		c.ram = alloc([0u8...], 64 * 1024)!;
		c.ram_bank_mask = 7;
	case =>
		c.ram = alloc([0u8...], 8 * 1024)!;
	};
};

// Frees the RAM allocated for the [[cartridge]]. Must be called
// when the cartridge is no longer needed.
export fn cart_free(c: *cartridge) void =
	free(c.ram);

// Reads from ROM with bank switching.
export fn cart_read_rom(c: *cartridge, addr: u16) u8 = {
	if (addr < 0x4000) {
		if (c.mbc == mbc_type::MBC1
				&& c.banking_mode == 1) {
			const bank = cart_wrap_rom_bank(
				c, c.mbc1_high2 << 5,
			);
			const off = bank * 0x4000 + addr: uint;
			if (off < len(c.rom))
				return c.rom[off];
			return 0xFF;
		};
		if (addr: uint < len(c.rom))
			return c.rom[addr];
		return 0xFF;
	};
	const off = c.rom_bank * 0x4000
		+ (addr: uint - 0x4000);
	if (off < len(c.rom)) return c.rom[off];
	return 0xFF;
};

// Reads from external RAM.
export fn cart_read_ram(c: *cartridge, addr: u16) u8 = {
	if (!c.ram_enabled) return 0xFF;
	if (len(c.ram) == 0) return 0xFF;
	if (c.mbc == mbc_type::MBC3 && c.ram_bank > 3)
		return 0xFF;

	const bank = cart_effective_ram_bank(c);
	const off = bank * 0x2000 + (addr: uint - 0xA000);
	if (off < len(c.ram)) return c.ram[off];
	return 0xFF;
};

// Writes to external RAM.
export fn cart_write_ram(
	c: *cartridge,
	addr: u16,
	val: u8,
) void = {
	if (!c.ram_enabled) return;
	if (len(c.ram) == 0) return;
	if (c.mbc == mbc_type::MBC3 && c.ram_bank > 3)
		return;

	const bank = cart_effective_ram_bank(c);
	const off = bank * 0x2000 + (addr: uint - 0xA000);
	if (off < len(c.ram)) c.ram[off] = val;
};

// Returns the active RAM bank, respecting MBC1 banking mode.
fn cart_effective_ram_bank(c: *cartridge) uint =
	if (c.mbc == mbc_type::MBC1 && c.banking_mode == 0)
		0
	else
		c.ram_bank;

// Recomputes effective MBC1 ROM/RAM banks from register state.
fn cart_sync_mbc1(c: *cartridge) void = {
	if (c.banking_mode == 0) {
		c.ram_bank = 0;
		let bank = (c.mbc1_high2 << 5)
			| (c.mbc1_low5 & 0x1F);
		if ((bank & 0x1F) == 0) bank += 1;
		c.rom_bank = cart_wrap_rom_bank(c, bank);
		return;
	};

	c.ram_bank = (c.mbc1_high2 & 0x03)
		& c.ram_bank_mask;
	let bank = c.mbc1_low5 & 0x1F;
	if (bank == 0) bank = 1;
	c.rom_bank = cart_wrap_rom_bank(c, bank);
};

// Wraps a ROM bank index to the available ROM bank range.
fn cart_wrap_rom_bank(c: *cartridge, bank: uint) uint =
	bank % (c.rom_bank_mask + 1);

// Handles MBC register writes (0x0000-0x7FFF).
export fn cart_write_control(
	c: *cartridge,
	addr: u16,
	val: u8,
) void = switch (c.mbc) {
case mbc_type::NONE => void;
case mbc_type::MBC1 => cart_write_mbc1(c, addr, val);
case mbc_type::MBC3 => cart_write_mbc3(c, addr, val);
case mbc_type::MBC5 => cart_write_mbc5(c, addr, val);
};

// Handles MBC1 register writes for bank switching.
fn cart_write_mbc1(c: *cartridge, addr: u16, val: u8) void = {
	if (addr < 0x2000) {
		c.ram_enabled = (val & 0x0F) == 0x0A;
	} else if (addr < 0x4000) {
		let low = val: uint & 0x1F;
		if (low == 0) low = 1;
		c.mbc1_low5 = low;
		cart_sync_mbc1(c);
	} else if (addr < 0x6000) {
		c.mbc1_high2 = val: uint & 0x03;
		cart_sync_mbc1(c);
	} else {
		c.banking_mode = val: uint & 0x01;
		cart_sync_mbc1(c);
	};
};

// Handles MBC3 register writes for bank switching.
fn cart_write_mbc3(c: *cartridge, addr: u16, val: u8) void = {
	if (addr < 0x2000) {
		c.ram_enabled = (val & 0x0F) == 0x0A;
	} else if (addr < 0x4000) {
		let bank = val: uint & 0x7F;
		if (bank == 0) bank = 1;
		c.rom_bank = cart_wrap_rom_bank(c, bank);
	} else if (addr < 0x6000) {
		const s = val: uint;
		if (s <= 0x03) {
			c.ram_bank = s & c.ram_bank_mask;
		} else if (s >= 0x08 && s <= 0x0C) {
			// RTC register select (not implemented;
			// reads return 0xFF via ram_bank > 3
			// guard)
			c.ram_bank = s;
		};
	};
	// RTC latch support omitted for simplicity.
};

// Handles MBC5 register writes for bank switching.
fn cart_write_mbc5(c: *cartridge, addr: u16, val: u8) void = {
	if (addr < 0x2000) {
		c.ram_enabled = (val & 0x0F) == 0x0A;
	} else if (addr < 0x3000) {
		const bank = c.rom_bank & 0x100 | val: uint;
		c.rom_bank = cart_wrap_rom_bank(c, bank);
	} else if (addr < 0x4000) {
		const bank = c.rom_bank & 0xFF
			| (val: uint & 0x01) << 8;
		c.rom_bank = cart_wrap_rom_bank(c, bank);
	} else if (addr < 0x6000) {
		c.ram_bank = (val: uint & 0x0F)
			& c.ram_bank_mask;
	};
};
