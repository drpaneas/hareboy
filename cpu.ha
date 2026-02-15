// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Sharp LR35902 [[cpu]] - instruction execution for the Game Boy.
// Simplified model: no T-cycle bus timing, no OAM corruption bugs.
// Each [[cpu_step]] call executes one instruction and returns
// consumed T-cycles.

def FLAG_Z: u8 = 0x80;
def FLAG_N: u8 = 0x40;
def FLAG_H: u8 = 0x20;
def FLAG_C: u8 = 0x10;

// CPU register file and execution state.
export type cpu = struct {
	a: u8,
	f: u8,
	b: u8,
	c: u8,
	d: u8,
	e: u8,
	h: u8,
	l: u8,
	pc: u16,
	sp: u16,
	halted: bool,
	locked: bool,
	ime: bool,
	ime_scheduled: bool,
	halt_bug: bool,
};

// Returns the HL register pair as a 16-bit value.
fn cpu_hl(c: *cpu) u16 = c.h: u16 << 8 | c.l: u16;

// Returns the BC register pair as a 16-bit value.
fn cpu_bc(c: *cpu) u16 = c.b: u16 << 8 | c.c: u16;

// Returns the DE register pair as a 16-bit value.
fn cpu_de(c: *cpu) u16 = c.d: u16 << 8 | c.e: u16;

// Returns the AF register pair as a 16-bit value.
fn cpu_af(c: *cpu) u16 = c.a: u16 << 8 | c.f: u16;

// Sets the HL register pair from a 16-bit value.
fn cpu_set_hl(c: *cpu, v: u16) void = {
	c.h = (v >> 8): u8;
	c.l = v: u8;
};

// Sets the BC register pair from a 16-bit value.
fn cpu_set_bc(c: *cpu, v: u16) void = {
	c.b = (v >> 8): u8;
	c.c = v: u8;
};

// Sets the DE register pair from a 16-bit value.
fn cpu_set_de(c: *cpu, v: u16) void = {
	c.d = (v >> 8): u8;
	c.e = v: u8;
};

// Sets the AF register pair from a 16-bit value.
// The lower nibble of F is always masked to zero.
fn cpu_set_af(c: *cpu, v: u16) void = {
	c.a = (v >> 8): u8;
	c.f = v: u8 & 0xF0;
};

// Returns true if the zero flag is set.
fn cpu_z(c: *cpu) bool = (c.f & FLAG_Z) != 0;

// Returns true if the carry flag is set.
fn cpu_carry(c: *cpu) bool = (c.f & FLAG_C) != 0;

// Sets or clears the zero flag.
fn cpu_set_z(c: *cpu, val: bool) void = {
	if (val) c.f |= FLAG_Z
	else c.f &= ~FLAG_Z;
};

// Read register by index (B=0 .. A=7, 6=(HL)).
fn cpu_get_reg(c: *cpu, m: *mmu, idx: u8) u8 = switch (idx) {
case 0 => yield c.b;
case 1 => yield c.c;
case 2 => yield c.d;
case 3 => yield c.e;
case 4 => yield c.h;
case 5 => yield c.l;
case 6 => yield mmu_read(m, cpu_hl(c));
case 7 => yield c.a;
// idx & 0x07 restricts to 0-7, all handled above
case => abort("unreachable");
};

// Write register by index (B=0 .. A=7, 6=(HL)).
fn cpu_set_reg(c: *cpu, m: *mmu, idx: u8, val: u8) void = switch (idx) {
case 0 => c.b = val;
case 1 => c.c = val;
case 2 => c.d = val;
case 3 => c.e = val;
case 4 => c.h = val;
case 5 => c.l = val;
case 6 => mmu_write(m, cpu_hl(c), val);
case 7 => c.a = val;
// idx & 0x07 restricts to 0-7, all handled above
case => abort("unreachable");
};

// Fetch next byte from PC.
fn fetch8(c: *cpu, m: *mmu) u8 = {
	const v = mmu_read(m, c.pc);
	c.pc += 1;
	return v;
};

// Fetch next 16-bit value from PC (little-endian).
fn fetch16(c: *cpu, m: *mmu) u16 = {
	const lo = fetch8(c, m);
	const hi = fetch8(c, m);
	return hi: u16 << 8 | lo: u16;
};

// Push a 16-bit value onto the stack.
fn push16(c: *cpu, m: *mmu, v: u16) void = {
	c.sp -= 1;
	mmu_write(m, c.sp, (v >> 8): u8);
	c.sp -= 1;
	mmu_write(m, c.sp, v: u8);
};

// Pop a 16-bit value from the stack.
fn pop16(c: *cpu, m: *mmu) u16 = {
	const lo = mmu_read(m, c.sp);
	c.sp += 1;
	const hi = mmu_read(m, c.sp);
	c.sp += 1;
	return hi: u16 << 8 | lo: u16;
};

// Adds val to A, setting Z, N, H, C flags.
fn alu_add(c: *cpu, val: u8) void = {
	const a = c.a;
	const r = a: u16 + val: u16;
	c.a = r: u8;
	cpu_set_z(c, c.a == 0);
	c.f &= ~FLAG_N;
	if ((a & 0x0F) + (val & 0x0F) > 0x0F)
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	if (r > 0xFF)
		c.f |= FLAG_C
	else
		c.f &= ~FLAG_C;
};

// Adds val plus carry to A, setting Z, N, H, C flags.
fn alu_adc(c: *cpu, val: u8) void = {
	const carry: u16 = if (cpu_carry(c)) 1 else 0;
	const a = c.a;
	const r = a: u16 + val: u16 + carry;
	c.a = r: u8;
	cpu_set_z(c, c.a == 0);
	c.f &= ~FLAG_N;
	if ((a & 0x0F): u16 + (val & 0x0F): u16
			+ carry > 0x0F)
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	if (r > 0xFF)
		c.f |= FLAG_C
	else
		c.f &= ~FLAG_C;
};

// Subtracts val from A, setting Z, N, H, C flags.
fn alu_sub(c: *cpu, val: u8) void = {
	const a = c.a;
	const r = a: i16 - val: i16;
	c.a = r: u8;
	cpu_set_z(c, c.a == 0);
	c.f |= FLAG_N;
	if ((a & 0x0F) < (val & 0x0F))
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	if (a < val)
		c.f |= FLAG_C
	else
		c.f &= ~FLAG_C;
};

// Subtracts val plus carry from A, setting Z, N, H, C flags.
fn alu_sbc(c: *cpu, val: u8) void = {
	const carry: u16 = if (cpu_carry(c)) 1 else 0;
	const a = c.a;
	const r: i32 = a: i32 - val: i32 - carry: i32;
	c.a = r: u8;
	cpu_set_z(c, c.a == 0);
	c.f |= FLAG_N;
	if ((a & 0x0F): i32 - (val & 0x0F): i32
			- carry: i32 < 0)
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	if (r < 0)
		c.f |= FLAG_C
	else
		c.f &= ~FLAG_C;
};

// Bitwise ANDs val with A, setting Z, N, H, C flags.
fn alu_and(c: *cpu, val: u8) void = {
	c.a &= val;
	cpu_set_z(c, c.a == 0);
	c.f &= ~FLAG_N;
	c.f |= FLAG_H;
	c.f &= ~FLAG_C;
};

// Bitwise XORs val with A, setting Z, N, H, C flags.
fn alu_xor(c: *cpu, val: u8) void = {
	c.a ^= val;
	cpu_set_z(c, c.a == 0);
	c.f &= ~(FLAG_N | FLAG_H | FLAG_C);
};

// Bitwise ORs val with A, setting Z, N, H, C flags.
fn alu_or(c: *cpu, val: u8) void = {
	c.a |= val;
	cpu_set_z(c, c.a == 0);
	c.f &= ~(FLAG_N | FLAG_H | FLAG_C);
};

// Compares val with A (subtract without storing), setting flags.
fn alu_cp(c: *cpu, val: u8) void = {
	const a = c.a;
	cpu_set_z(c, a == val);
	c.f |= FLAG_N;
	if ((a & 0x0F) < (val & 0x0F))
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	if (a < val)
		c.f |= FLAG_C
	else
		c.f &= ~FLAG_C;
};

// Increments val, setting Z, N, H flags. Returns result.
fn alu_inc(c: *cpu, val: u8) u8 = {
	if ((val & 0x0F) == 0x0F)
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	const r = val + 1;
	cpu_set_z(c, r == 0);
	c.f &= ~FLAG_N;
	return r;
};

// Decrements val, setting Z, N, H flags. Returns result.
fn alu_dec(c: *cpu, val: u8) u8 = {
	if ((val & 0x0F) == 0)
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	const r = val - 1;
	cpu_set_z(c, r == 0);
	c.f |= FLAG_N;
	return r;
};

// Adds val to HL, setting N, H, C flags.
fn cpu_add_hl(c: *cpu, val: u16) void = {
	const hl = cpu_hl(c);
	const r: u32 = hl: u32 + val: u32;
	cpu_set_hl(c, r: u16);
	c.f &= ~FLAG_N;
	if ((hl & 0x0FFF) + (val & 0x0FFF) > 0x0FFF)
		c.f |= FLAG_H
	else
		c.f &= ~FLAG_H;
	if (r > 0xFFFF)
		c.f |= FLAG_C
	else
		c.f &= ~FLAG_C;
};

// Execute one instruction. Reads from [[mmu_read]] and writes
// via [[mmu_write]]. Returns T-cycles consumed.
export fn cpu_step(c: *cpu, m: *mmu) i32 = {
	if (c.locked) return 4;
	if (c.halted) return 4;

	const enable_ime = c.ime_scheduled;
	const opcode = fetch8(c, m);

	// HALT bug: when HALT was entered with IME=0 and a
	// pending interrupt, the first fetch after un-halting
	// does not advance PC.
	if (c.halt_bug) {
		c.pc -= 1;
		c.halt_bug = false;
	};

	const cycles: i32 = switch (opcode) {
	// NOP
	case 0x00 => yield 4;

	// LD rr, d16
	case 0x01 =>
		cpu_set_bc(c, fetch16(c, m));
		yield 12;
	case 0x11 =>
		cpu_set_de(c, fetch16(c, m));
		yield 12;
	case 0x21 =>
		cpu_set_hl(c, fetch16(c, m));
		yield 12;
	case 0x31 =>
		c.sp = fetch16(c, m);
		yield 12;

	// LD r, d8
	case 0x06 => c.b = fetch8(c, m); yield 8;
	case 0x0E => c.c = fetch8(c, m); yield 8;
	case 0x16 => c.d = fetch8(c, m); yield 8;
	case 0x1E => c.e = fetch8(c, m); yield 8;
	case 0x26 => c.h = fetch8(c, m); yield 8;
	case 0x2E => c.l = fetch8(c, m); yield 8;
	case 0x3E => c.a = fetch8(c, m); yield 8;
	case 0x36 =>
		const n = fetch8(c, m);
		mmu_write(m, cpu_hl(c), n);
		yield 12;

	// LD (rr), A
	case 0x02 =>
		mmu_write(m, cpu_bc(c), c.a);
		yield 8;
	case 0x12 =>
		mmu_write(m, cpu_de(c), c.a);
		yield 8;

	// LD A, (rr)
	case 0x0A =>
		c.a = mmu_read(m, cpu_bc(c));
		yield 8;
	case 0x1A =>
		c.a = mmu_read(m, cpu_de(c));
		yield 8;

	// LD A, (HL+) / LD A, (HL-)
	case 0x2A =>
		const hl = cpu_hl(c);
		c.a = mmu_read(m, hl);
		cpu_set_hl(c, hl + 1);
		yield 8;
	case 0x3A =>
		const hl = cpu_hl(c);
		c.a = mmu_read(m, hl);
		cpu_set_hl(c, hl - 1);
		yield 8;

	// LD (HL+), A / LD (HL-), A
	case 0x22 =>
		const hl = cpu_hl(c);
		mmu_write(m, hl, c.a);
		cpu_set_hl(c, hl + 1);
		yield 8;
	case 0x32 =>
		const hl = cpu_hl(c);
		mmu_write(m, hl, c.a);
		cpu_set_hl(c, hl - 1);
		yield 8;

	// LD (a16), A and LD A, (a16)
	case 0xEA =>
		const addr = fetch16(c, m);
		mmu_write(m, addr, c.a);
		yield 16;
	case 0xFA =>
		const addr = fetch16(c, m);
		c.a = mmu_read(m, addr);
		yield 16;

	// LD (a16), SP
	case 0x08 =>
		const addr = fetch16(c, m);
		mmu_write(m, addr, c.sp: u8);
		mmu_write(m, addr + 1, (c.sp >> 8): u8);
		yield 20;

	// LDH (a8), A and LDH A, (a8)
	case 0xE0 =>
		const off = fetch8(c, m);
		mmu_write(m, 0xFF00 + off: u16, c.a);
		yield 12;
	case 0xF0 =>
		const off = fetch8(c, m);
		c.a = mmu_read(m, 0xFF00 + off: u16);
		yield 12;

	// LD (C), A and LD A, (C)
	case 0xE2 =>
		mmu_write(m, 0xFF00 + c.c: u16, c.a);
		yield 8;
	case 0xF2 =>
		c.a = mmu_read(m, 0xFF00 + c.c: u16);
		yield 8;

	// LD SP, HL
	case 0xF9 => c.sp = cpu_hl(c); yield 8;

	// LD HL, SP+e8
	case 0xF8 =>
		const e = fetch8(c, m): i8;
		const sp = c.sp;
		const r = (sp: i32 + e: i32): u16;
		cpu_set_hl(c, r);
		c.f = 0;
		if ((sp & 0x0F) + (e: u16 & 0x0F) > 0x0F)
			c.f |= FLAG_H;
		if ((sp & 0xFF) + (e: u16 & 0xFF) > 0xFF)
			c.f |= FLAG_C;
		yield 12;

	// LD r, r (0x40-0x7F block, except 0x76=HALT)
	case 0x40 => yield 4; // LD B,B
	case 0x41 => c.b = c.c; yield 4;
	case 0x42 => c.b = c.d; yield 4;
	case 0x43 => c.b = c.e; yield 4;
	case 0x44 => c.b = c.h; yield 4;
	case 0x45 => c.b = c.l; yield 4;
	case 0x46 =>
		c.b = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x47 => c.b = c.a; yield 4;
	case 0x48 => c.c = c.b; yield 4;
	case 0x49 => yield 4; // LD C,C
	case 0x4A => c.c = c.d; yield 4;
	case 0x4B => c.c = c.e; yield 4;
	case 0x4C => c.c = c.h; yield 4;
	case 0x4D => c.c = c.l; yield 4;
	case 0x4E =>
		c.c = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x4F => c.c = c.a; yield 4;
	case 0x50 => c.d = c.b; yield 4;
	case 0x51 => c.d = c.c; yield 4;
	case 0x52 => yield 4; // LD D,D
	case 0x53 => c.d = c.e; yield 4;
	case 0x54 => c.d = c.h; yield 4;
	case 0x55 => c.d = c.l; yield 4;
	case 0x56 =>
		c.d = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x57 => c.d = c.a; yield 4;
	case 0x58 => c.e = c.b; yield 4;
	case 0x59 => c.e = c.c; yield 4;
	case 0x5A => c.e = c.d; yield 4;
	case 0x5B => yield 4; // LD E,E
	case 0x5C => c.e = c.h; yield 4;
	case 0x5D => c.e = c.l; yield 4;
	case 0x5E =>
		c.e = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x5F => c.e = c.a; yield 4;
	case 0x60 => c.h = c.b; yield 4;
	case 0x61 => c.h = c.c; yield 4;
	case 0x62 => c.h = c.d; yield 4;
	case 0x63 => c.h = c.e; yield 4;
	case 0x64 => yield 4; // LD H,H
	case 0x65 => c.h = c.l; yield 4;
	case 0x66 =>
		c.h = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x67 => c.h = c.a; yield 4;
	case 0x68 => c.l = c.b; yield 4;
	case 0x69 => c.l = c.c; yield 4;
	case 0x6A => c.l = c.d; yield 4;
	case 0x6B => c.l = c.e; yield 4;
	case 0x6C => c.l = c.h; yield 4;
	case 0x6D => yield 4; // LD L,L
	case 0x6E =>
		c.l = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x6F => c.l = c.a; yield 4;
	case 0x70 =>
		mmu_write(m, cpu_hl(c), c.b);
		yield 8;
	case 0x71 =>
		mmu_write(m, cpu_hl(c), c.c);
		yield 8;
	case 0x72 =>
		mmu_write(m, cpu_hl(c), c.d);
		yield 8;
	case 0x73 =>
		mmu_write(m, cpu_hl(c), c.e);
		yield 8;
	case 0x74 =>
		mmu_write(m, cpu_hl(c), c.h);
		yield 8;
	case 0x75 =>
		mmu_write(m, cpu_hl(c), c.l);
		yield 8;
	case 0x77 =>
		mmu_write(m, cpu_hl(c), c.a);
		yield 8;
	case 0x78 => c.a = c.b; yield 4;
	case 0x79 => c.a = c.c; yield 4;
	case 0x7A => c.a = c.d; yield 4;
	case 0x7B => c.a = c.e; yield 4;
	case 0x7C => c.a = c.h; yield 4;
	case 0x7D => c.a = c.l; yield 4;
	case 0x7E =>
		c.a = mmu_read(m, cpu_hl(c));
		yield 8;
	case 0x7F => yield 4; // LD A,A

	// HALT
	case 0x76 =>
		if (!c.ime
				&& (m.io[IO_IF] & m.ie & 0x1F)
				!= 0) {
			c.halt_bug = true;
		} else {
			c.halted = true;
		};
		yield 4;

	// ALU A, r
	case 0x80 => alu_add(c, c.b); yield 4;
	case 0x81 => alu_add(c, c.c); yield 4;
	case 0x82 => alu_add(c, c.d); yield 4;
	case 0x83 => alu_add(c, c.e); yield 4;
	case 0x84 => alu_add(c, c.h); yield 4;
	case 0x85 => alu_add(c, c.l); yield 4;
	case 0x86 =>
		alu_add(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0x87 => alu_add(c, c.a); yield 4;
	case 0x88 => alu_adc(c, c.b); yield 4;
	case 0x89 => alu_adc(c, c.c); yield 4;
	case 0x8A => alu_adc(c, c.d); yield 4;
	case 0x8B => alu_adc(c, c.e); yield 4;
	case 0x8C => alu_adc(c, c.h); yield 4;
	case 0x8D => alu_adc(c, c.l); yield 4;
	case 0x8E =>
		alu_adc(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0x8F => alu_adc(c, c.a); yield 4;
	case 0x90 => alu_sub(c, c.b); yield 4;
	case 0x91 => alu_sub(c, c.c); yield 4;
	case 0x92 => alu_sub(c, c.d); yield 4;
	case 0x93 => alu_sub(c, c.e); yield 4;
	case 0x94 => alu_sub(c, c.h); yield 4;
	case 0x95 => alu_sub(c, c.l); yield 4;
	case 0x96 =>
		alu_sub(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0x97 => alu_sub(c, c.a); yield 4;
	case 0x98 => alu_sbc(c, c.b); yield 4;
	case 0x99 => alu_sbc(c, c.c); yield 4;
	case 0x9A => alu_sbc(c, c.d); yield 4;
	case 0x9B => alu_sbc(c, c.e); yield 4;
	case 0x9C => alu_sbc(c, c.h); yield 4;
	case 0x9D => alu_sbc(c, c.l); yield 4;
	case 0x9E =>
		alu_sbc(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0x9F => alu_sbc(c, c.a); yield 4;
	case 0xA0 => alu_and(c, c.b); yield 4;
	case 0xA1 => alu_and(c, c.c); yield 4;
	case 0xA2 => alu_and(c, c.d); yield 4;
	case 0xA3 => alu_and(c, c.e); yield 4;
	case 0xA4 => alu_and(c, c.h); yield 4;
	case 0xA5 => alu_and(c, c.l); yield 4;
	case 0xA6 =>
		alu_and(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0xA7 => alu_and(c, c.a); yield 4;
	case 0xA8 => alu_xor(c, c.b); yield 4;
	case 0xA9 => alu_xor(c, c.c); yield 4;
	case 0xAA => alu_xor(c, c.d); yield 4;
	case 0xAB => alu_xor(c, c.e); yield 4;
	case 0xAC => alu_xor(c, c.h); yield 4;
	case 0xAD => alu_xor(c, c.l); yield 4;
	case 0xAE =>
		alu_xor(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0xAF => alu_xor(c, c.a); yield 4;
	case 0xB0 => alu_or(c, c.b); yield 4;
	case 0xB1 => alu_or(c, c.c); yield 4;
	case 0xB2 => alu_or(c, c.d); yield 4;
	case 0xB3 => alu_or(c, c.e); yield 4;
	case 0xB4 => alu_or(c, c.h); yield 4;
	case 0xB5 => alu_or(c, c.l); yield 4;
	case 0xB6 =>
		alu_or(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0xB7 => alu_or(c, c.a); yield 4;
	case 0xB8 => alu_cp(c, c.b); yield 4;
	case 0xB9 => alu_cp(c, c.c); yield 4;
	case 0xBA => alu_cp(c, c.d); yield 4;
	case 0xBB => alu_cp(c, c.e); yield 4;
	case 0xBC => alu_cp(c, c.h); yield 4;
	case 0xBD => alu_cp(c, c.l); yield 4;
	case 0xBE =>
		alu_cp(c, mmu_read(m, cpu_hl(c)));
		yield 8;
	case 0xBF => alu_cp(c, c.a); yield 4;

	// ALU A, d8
	case 0xC6 =>
		alu_add(c, fetch8(c, m));
		yield 8;
	case 0xCE =>
		alu_adc(c, fetch8(c, m));
		yield 8;
	case 0xD6 =>
		alu_sub(c, fetch8(c, m));
		yield 8;
	case 0xDE =>
		alu_sbc(c, fetch8(c, m));
		yield 8;
	case 0xE6 =>
		alu_and(c, fetch8(c, m));
		yield 8;
	case 0xEE =>
		alu_xor(c, fetch8(c, m));
		yield 8;
	case 0xF6 =>
		alu_or(c, fetch8(c, m));
		yield 8;
	case 0xFE =>
		alu_cp(c, fetch8(c, m));
		yield 8;

	// INC r8
	case 0x04 => c.b = alu_inc(c, c.b); yield 4;
	case 0x0C => c.c = alu_inc(c, c.c); yield 4;
	case 0x14 => c.d = alu_inc(c, c.d); yield 4;
	case 0x1C => c.e = alu_inc(c, c.e); yield 4;
	case 0x24 => c.h = alu_inc(c, c.h); yield 4;
	case 0x2C => c.l = alu_inc(c, c.l); yield 4;
	case 0x34 =>
		const hl = cpu_hl(c);
		const v = alu_inc(c, mmu_read(m, hl));
		mmu_write(m, hl, v);
		yield 12;
	case 0x3C => c.a = alu_inc(c, c.a); yield 4;

	// DEC r8
	case 0x05 => c.b = alu_dec(c, c.b); yield 4;
	case 0x0D => c.c = alu_dec(c, c.c); yield 4;
	case 0x15 => c.d = alu_dec(c, c.d); yield 4;
	case 0x1D => c.e = alu_dec(c, c.e); yield 4;
	case 0x25 => c.h = alu_dec(c, c.h); yield 4;
	case 0x2D => c.l = alu_dec(c, c.l); yield 4;
	case 0x35 =>
		const hl = cpu_hl(c);
		const v = alu_dec(c, mmu_read(m, hl));
		mmu_write(m, hl, v);
		yield 12;
	case 0x3D => c.a = alu_dec(c, c.a); yield 4;

	// INC/DEC rr
	case 0x03 =>
		cpu_set_bc(c, cpu_bc(c) + 1);
		yield 8;
	case 0x13 =>
		cpu_set_de(c, cpu_de(c) + 1);
		yield 8;
	case 0x23 =>
		cpu_set_hl(c, cpu_hl(c) + 1);
		yield 8;
	case 0x33 => c.sp += 1; yield 8;
	case 0x0B =>
		cpu_set_bc(c, cpu_bc(c) - 1);
		yield 8;
	case 0x1B =>
		cpu_set_de(c, cpu_de(c) - 1);
		yield 8;
	case 0x2B =>
		cpu_set_hl(c, cpu_hl(c) - 1);
		yield 8;
	case 0x3B => c.sp -= 1; yield 8;

	// ADD HL, rr
	case 0x09 => cpu_add_hl(c, cpu_bc(c)); yield 8;
	case 0x19 => cpu_add_hl(c, cpu_de(c)); yield 8;
	case 0x29 => cpu_add_hl(c, cpu_hl(c)); yield 8;
	case 0x39 => cpu_add_hl(c, c.sp); yield 8;

	// ADD SP, e8
	case 0xE8 =>
		const e = fetch8(c, m): i8;
		const sp = c.sp;
		const r = (sp: i32 + e: i32): u16;
		c.f = 0;
		if ((sp & 0x0F) + (e: u16 & 0x0F) > 0x0F)
			c.f |= FLAG_H;
		if ((sp & 0xFF) + (e: u16 & 0xFF) > 0xFF)
			c.f |= FLAG_C;
		c.sp = r;
		yield 16;

	// Rotates on A
	case 0x07 => // RLCA
		const bit7 = (c.a >> 7) & 1;
		c.a = (c.a << 1) | bit7;
		c.f = 0;
		if (bit7 != 0) c.f |= FLAG_C;
		yield 4;
	case 0x17 => // RLA
		const carry: u8 =
			if (cpu_carry(c)) 1 else 0;
		const bit7 = (c.a >> 7) & 1;
		c.a = (c.a << 1) | carry;
		c.f = 0;
		if (bit7 != 0) c.f |= FLAG_C;
		yield 4;
	case 0x0F => // RRCA
		const bit0 = c.a & 1;
		c.a = (c.a >> 1) | (bit0 << 7);
		c.f = 0;
		if (bit0 != 0) c.f |= FLAG_C;
		yield 4;
	case 0x1F => // RRA
		const carry: u8 =
			if (cpu_carry(c)) 0x80 else 0;
		const bit0 = c.a & 1;
		c.a = (c.a >> 1) | carry;
		c.f = 0;
		if (bit0 != 0) c.f |= FLAG_C;
		yield 4;

	// Jumps
	case 0xC3 => // JP a16
		c.pc = fetch16(c, m);
		yield 16;
	case 0xC2 => // JP NZ, a16
		const addr = fetch16(c, m);
		if (!cpu_z(c)) {
			c.pc = addr;
			yield 16;
		};
		yield 12;
	case 0xCA => // JP Z, a16
		const addr = fetch16(c, m);
		if (cpu_z(c)) {
			c.pc = addr;
			yield 16;
		};
		yield 12;
	case 0xD2 => // JP NC, a16
		const addr = fetch16(c, m);
		if (!cpu_carry(c)) {
			c.pc = addr;
			yield 16;
		};
		yield 12;
	case 0xDA => // JP C, a16
		const addr = fetch16(c, m);
		if (cpu_carry(c)) {
			c.pc = addr;
			yield 16;
		};
		yield 12;
	case 0xE9 => // JP HL
		c.pc = cpu_hl(c);
		yield 4;

	// JR
	case 0x18 => // JR e8
		const e = fetch8(c, m): i8;
		c.pc = (c.pc: i32 + e: i32): u16;
		yield 12;
	case 0x20 => // JR NZ, e8
		const e = fetch8(c, m): i8;
		if (!cpu_z(c)) {
			c.pc = (c.pc: i32 + e: i32): u16;
			yield 12;
		};
		yield 8;
	case 0x28 => // JR Z, e8
		const e = fetch8(c, m): i8;
		if (cpu_z(c)) {
			c.pc = (c.pc: i32 + e: i32): u16;
			yield 12;
		};
		yield 8;
	case 0x30 => // JR NC, e8
		const e = fetch8(c, m): i8;
		if (!cpu_carry(c)) {
			c.pc = (c.pc: i32 + e: i32): u16;
			yield 12;
		};
		yield 8;
	case 0x38 => // JR C, e8
		const e = fetch8(c, m): i8;
		if (cpu_carry(c)) {
			c.pc = (c.pc: i32 + e: i32): u16;
			yield 12;
		};
		yield 8;

	// CALL
	case 0xCD => // CALL a16
		const addr = fetch16(c, m);
		push16(c, m, c.pc);
		c.pc = addr;
		yield 24;
	case 0xC4 =>
		const addr = fetch16(c, m);
		if (!cpu_z(c)) {
			push16(c, m, c.pc);
			c.pc = addr;
			yield 24;
		};
		yield 12;
	case 0xCC =>
		const addr = fetch16(c, m);
		if (cpu_z(c)) {
			push16(c, m, c.pc);
			c.pc = addr;
			yield 24;
		};
		yield 12;
	case 0xD4 =>
		const addr = fetch16(c, m);
		if (!cpu_carry(c)) {
			push16(c, m, c.pc);
			c.pc = addr;
			yield 24;
		};
		yield 12;
	case 0xDC =>
		const addr = fetch16(c, m);
		if (cpu_carry(c)) {
			push16(c, m, c.pc);
			c.pc = addr;
			yield 24;
		};
		yield 12;

	// RET
	case 0xC9 =>
		c.pc = pop16(c, m);
		yield 16;
	case 0xC0 =>
		if (!cpu_z(c)) {
			c.pc = pop16(c, m);
			yield 20;
		};
		yield 8;
	case 0xC8 =>
		if (cpu_z(c)) {
			c.pc = pop16(c, m);
			yield 20;
		};
		yield 8;
	case 0xD0 =>
		if (!cpu_carry(c)) {
			c.pc = pop16(c, m);
			yield 20;
		};
		yield 8;
	case 0xD8 =>
		if (cpu_carry(c)) {
			c.pc = pop16(c, m);
			yield 20;
		};
		yield 8;
	case 0xD9 => // RETI
		c.pc = pop16(c, m);
		c.ime = true;
		yield 16;

	// PUSH/POP
	case 0xC5 =>
		push16(c, m, cpu_bc(c));
		yield 16;
	case 0xD5 =>
		push16(c, m, cpu_de(c));
		yield 16;
	case 0xE5 =>
		push16(c, m, cpu_hl(c));
		yield 16;
	case 0xF5 =>
		push16(c, m, cpu_af(c));
		yield 16;
	case 0xC1 =>
		cpu_set_bc(c, pop16(c, m));
		yield 12;
	case 0xD1 =>
		cpu_set_de(c, pop16(c, m));
		yield 12;
	case 0xE1 =>
		cpu_set_hl(c, pop16(c, m));
		yield 12;
	case 0xF1 =>
		cpu_set_af(c, pop16(c, m));
		yield 12;

	// RST
	case 0xC7 =>
		push16(c, m, c.pc);
		c.pc = 0x0000;
		yield 16;
	case 0xCF =>
		push16(c, m, c.pc);
		c.pc = 0x0008;
		yield 16;
	case 0xD7 =>
		push16(c, m, c.pc);
		c.pc = 0x0010;
		yield 16;
	case 0xDF =>
		push16(c, m, c.pc);
		c.pc = 0x0018;
		yield 16;
	case 0xE7 =>
		push16(c, m, c.pc);
		c.pc = 0x0020;
		yield 16;
	case 0xEF =>
		push16(c, m, c.pc);
		c.pc = 0x0028;
		yield 16;
	case 0xF7 =>
		push16(c, m, c.pc);
		c.pc = 0x0030;
		yield 16;
	case 0xFF =>
		push16(c, m, c.pc);
		c.pc = 0x0038;
		yield 16;

	// Misc
	case 0x2F => // CPL
		c.a = ~c.a;
		c.f |= FLAG_N | FLAG_H;
		yield 4;
	case 0x37 => // SCF
		c.f &= ~(FLAG_N | FLAG_H);
		c.f |= FLAG_C;
		yield 4;
	case 0x3F => // CCF
		c.f &= ~(FLAG_N | FLAG_H);
		c.f ^= FLAG_C;
		yield 4;
	case 0x27 => // DAA
		let a = c.a: u16;
		if ((c.f & FLAG_N) == 0) {
			if ((c.f & FLAG_H) != 0
					|| (a & 0x0F) > 9)
				a += 0x06;
			if ((c.f & FLAG_C) != 0
					|| a > 0x9F) {
				a += 0x60;
				c.f |= FLAG_C;
			};
		} else {
			if ((c.f & FLAG_H) != 0)
				a = (a - 6) & 0xFF;
			if ((c.f & FLAG_C) != 0)
				a -= 0x60;
		};
		c.a = (a & 0xFF): u8;
		cpu_set_z(c, c.a == 0);
		c.f &= ~FLAG_H;
		yield 4;

	// DI / EI
	case 0xF3 =>
		c.ime = false;
		c.ime_scheduled = false;
		yield 4;
	case 0xFB =>
		c.ime_scheduled = true;
		yield 4;

	// STOP (two-byte instruction)
	case 0x10 =>
		fetch8(c, m); // consume second byte
		yield 4;

	// CB prefix
	case 0xCB =>
		yield execute_cb(c, m);

	// Undefined opcodes
	case =>
		c.locked = true;
		yield 4;
	};

	// EI delayed enable
	if (enable_ime && c.ime_scheduled) {
		c.ime = true;
		c.ime_scheduled = false;
	};

	return cycles;
};

// Executes a CB-prefixed instruction. Handles bit rotates,
// shifts, BIT/RES/SET operations. Returns T-cycles consumed.
fn execute_cb(c: *cpu, m: *mmu) i32 = {
	const op = fetch8(c, m);
	const reg_idx = op & 0x07;
	const is_hl = reg_idx == 6;
	const base_cycles: i32 =
		if (is_hl) 16 else 8;

	let val = cpu_get_reg(c, m, reg_idx);

	const group = op >> 3;
	switch (group) {
	case 0 => // RLC
		const bit7 = (val >> 7) & 1;
		val = (val << 1) | bit7;
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit7 != 0) c.f |= FLAG_C;
	case 1 => // RRC
		const bit0 = val & 1;
		val = (val >> 1) | (bit0 << 7);
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit0 != 0) c.f |= FLAG_C;
	case 2 => // RL
		const carry: u8 =
			if (cpu_carry(c)) 1 else 0;
		const bit7 = (val >> 7) & 1;
		val = (val << 1) | carry;
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit7 != 0) c.f |= FLAG_C;
	case 3 => // RR
		const carry: u8 =
			if (cpu_carry(c)) 0x80 else 0;
		const bit0 = val & 1;
		val = (val >> 1) | carry;
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit0 != 0) c.f |= FLAG_C;
	case 4 => // SLA
		const bit7 = (val >> 7) & 1;
		val <<= 1;
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit7 != 0) c.f |= FLAG_C;
	case 5 => // SRA
		const bit7 = val & 0x80;
		const bit0 = val & 1;
		val = (val >> 1) | bit7;
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit0 != 0) c.f |= FLAG_C;
	case 6 => // SWAP
		val = (val >> 4) | (val << 4);
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
	case 7 => // SRL
		const bit0 = val & 1;
		val >>= 1;
		c.f = 0;
		if (val == 0) c.f |= FLAG_Z;
		if (bit0 != 0) c.f |= FLAG_C;
	case => // BIT, RES, SET
		const bit = (op >> 3) & 0x07;
		const op_type = op >> 6;
		switch (op_type) {
		case 1 => // BIT
			cpu_set_z(c, (val & (1 << bit)) == 0);
			c.f &= ~FLAG_N;
			c.f |= FLAG_H;
			return if (is_hl) 12 else 8;
		case 2 => // RES
			val &= ~(1u8 << bit);
		case 3 => // SET
			val |= 1u8 << bit;
		// op_type >> 6 restricts to 0-3; 0 handled
		// by outer switch, 1-3 handled above
		case => abort("unreachable");
		};
	};

	cpu_set_reg(c, m, reg_idx, val);
	return base_cycles;
};
