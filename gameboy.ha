// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Ties all components together and runs emulation frames.
// The top-level [[gameboy]] struct owns the [[cpu]], [[mmu]],
// [[ppu]], [[timer]], [[joypad]], [[cartridge]], and [[apu]]
// subsystems.

def CYCLES_PER_FRAME: i32 = 70224;

// Interrupt vector table: [flag_bit, handler_address] pairs
// ordered by priority (VBlank highest).
const INT_VECTORS: [5][2]u16 = [
	[INT_VBLANK: u16, 0x0040],
	[INT_STAT: u16, 0x0048],
	[INT_TIMER: u16, 0x0050],
	[INT_SERIAL: u16, 0x0058],
	[INT_JOYPAD: u16, 0x0060],
];

// Top-level emulator state holding all subsystems.
export type gameboy = struct {
	cpu: cpu,
	mmu: mmu,
	ppu: ppu,
	tmr: timer,
	joy: joypad,
	cart: cartridge,
	snd: apu,
	total_cycles: u64,
	frame_count: u64,
	leftover_cycles: i32,
};

// DMG shade palette: index 0-3 -> RGBA (greenish Game Boy
// colors).
export const PALETTE: [4][4]u8 = [
	[0xE0, 0xF8, 0xD0, 0xFF], // Lightest
	[0x88, 0xC0, 0x70, 0xFF], // Light
	[0x34, 0x68, 0x56, 0xFF], // Dark
	[0x08, 0x18, 0x20, 0xFF], // Darkest
];

// DMG post-boot register values: A, F, B, C, D, E, H, L.
const DMG_BOOT_REGS: [8]u8 = [
	0x01, 0xB0, 0x00, 0x13,
	0x00, 0xD8, 0x01, 0x4D,
];

// DMG post-boot I/O values: [offset, value] pairs.
const DMG_BOOT_IO: [31][2]u8 = [
	[0x00, 0xCF], [0x01, 0x00], [0x02, 0x7E],
	[0x10, 0x80], [0x11, 0xBF], [0x12, 0xF3],
	[0x14, 0xBF],
	[0x16, 0x3F], [0x17, 0x00], [0x19, 0xBF],
	[0x1A, 0x7F], [0x1B, 0xFF], [0x1C, 0x9F],
	[0x1E, 0xBF],
	[0x20, 0xFF], [0x21, 0x00], [0x22, 0x00],
	[0x23, 0xBF],
	[0x24, 0x77], [0x25, 0xF3], [0x26, 0xF1],
	[0x40, 0x91], [0x41, 0x80], [0x42, 0x00],
	[0x43, 0x00],
	[0x45, 0x00], [0x47, 0xFC], [0x48, 0xFF],
	[0x49, 0xFF],
	[0x4A, 0x00], [0x4B, 0x00],
];

// Creates a new [[gameboy]] initialized to DMG post-boot
// state. The caller must call [[init]] before [[run_frame]].
export fn newgameboy(rom: []u8) gameboy = {
	let gb = gameboy {
		tmr = newtimer(),
		cart = newcart(rom),
		snd = newapu(),
		...
	};

	// CPU registers
	gb.cpu.pc = 0x0100;
	gb.cpu.sp = 0xFFFE;
	gb.cpu.a = DMG_BOOT_REGS[0];
	gb.cpu.f = DMG_BOOT_REGS[1];
	gb.cpu.b = DMG_BOOT_REGS[2];
	gb.cpu.c = DMG_BOOT_REGS[3];
	gb.cpu.d = DMG_BOOT_REGS[4];
	gb.cpu.e = DMG_BOOT_REGS[5];
	gb.cpu.h = DMG_BOOT_REGS[6];
	gb.cpu.l = DMG_BOOT_REGS[7];

	// I/O registers
	for (let i = 0z; i < len(DMG_BOOT_IO); i += 1) {
		gb.mmu.io[DMG_BOOT_IO[i][0]] =
			DMG_BOOT_IO[i][1];
	};

	return gb;
};

// Links the [[mmu]] bus to its peripheral components. Must be
// called once after [[newgameboy]], before calling [[run_frame]].
export fn init(gb: *gameboy) void = {
	gb.mmu.cart = &gb.cart;
	gb.mmu.tmr = &gb.tmr;
	gb.mmu.joy = &gb.joy;
	gb.mmu.snd = &gb.snd;
};

// Frees resources owned by the [[gameboy]].
export fn finish(gb: *gameboy) void = {
	apu_close(&gb.snd);
	cart_free(&gb.cart);
};

// Advances all hardware ([[ppu]], [[timer]], DMA, [[apu]]) by
// the given T-cycles.
fn tick_hardware(gb: *gameboy, cycles: i32) void = {
	for (let t: i32 = 0; t < cycles; t += 1) {
		ppu_update(&gb.ppu, &gb.mmu);
	};
	if (timer_update(&gb.tmr, cycles)) {
		gb.mmu.io[IO_IF] |= INT_TIMER;
	};
	mmu_tick_dma(&gb.mmu, cycles);
	apu_update(&gb.snd, cycles);
};

// Runs one frame (70224 T-cycles) of emulation. Carries over
// excess cycles from the previous frame so the PPU stays
// aligned with presentation and never overwrites the
// framebuffer with next-frame content.
export fn run_frame(gb: *gameboy) void = {
	let cycles_this_frame: i32 = gb.leftover_cycles;
	for (cycles_this_frame < CYCLES_PER_FRAME) {
		// Handle interrupts
		const int_cycles = handle_interrupts(gb);
		if (int_cycles > 0) {
			tick_hardware(gb, int_cycles);
			cycles_this_frame += int_cycles;
			gb.total_cycles += int_cycles: u64;
			continue;
		};

		// Check if halted
		if (gb.cpu.halted) {
			if ((gb.mmu.io[IO_IF]
					& gb.mmu.ie & 0x1F)
					!= 0) {
				gb.cpu.halted = false;
			} else {
				tick_hardware(gb, 4);
				cycles_this_frame += 4;
				gb.total_cycles += 4;
				continue;
			};
		};

		// Execute one instruction
		const cycles = cpu_step(
			&gb.cpu, &gb.mmu,
		);

		// Advance hardware
		tick_hardware(gb, cycles);
		cycles_this_frame += cycles;
		gb.total_cycles += cycles: u64;
	};

	gb.leftover_cycles =
		cycles_this_frame - CYCLES_PER_FRAME;

	// Flush any remaining audio samples to SDL
	apu_flush(&gb.snd);
	gb.frame_count += 1;
};

// Handles pending interrupts. Returns T-cycles consumed
// (0 or 20).
fn handle_interrupts(gb: *gameboy) i32 = {
	if (!gb.cpu.ime) return 0;

	const if_reg = gb.mmu.io[IO_IF];
	const ie_reg = gb.mmu.ie;
	const pending = if_reg & ie_reg & 0x1F;
	if (pending == 0) return 0;

	gb.cpu.ime = false;
	gb.cpu.halted = false;

	// Push PC to stack
	push16(&gb.cpu, &gb.mmu, gb.cpu.pc);

	// Dispatch to highest-priority pending interrupt.
	for (let i = 0z; i < len(INT_VECTORS); i += 1) {
		if ((pending & INT_VECTORS[i][0]: u8)
				!= 0) {
			gb.mmu.io[IO_IF] &=
				~(INT_VECTORS[i][0]: u8);
			gb.cpu.pc = INT_VECTORS[i][1];
			return 20;
		};
	};

	// pending != 0 guarantees at least one bit is set
	abort("unreachable: no matching interrupt");
};
