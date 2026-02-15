// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Game Boy [[timer]] (DIV, TIMA, TMA, TAC).
// DIV is the upper 8 bits of a 16-bit internal counter that
// increments every T-cycle. TIMA increments at a rate selected by
// TAC and generates an [[INT_TIMER]] interrupt on overflow.

// Timer subsystem state.
export type timer = struct {
	tima: u8,         // Timer counter (0xFF05)
	tma: u8,          // Timer modulo (0xFF06)
	tac: u8,          // Timer control (0xFF07)
	div: u16,         // Internal divider; DIV reads upper 8 bits
	reload_delay: i32,
	reload_cycle_b: i32,
};

// Creates a [[timer]] initialized to DMG post-boot state.
export fn newtimer() timer = timer {
	div = 0xABE8,
	...
};

// Returns true if the timer is enabled (TAC bit 2).
fn timer_enabled(t: *timer) bool =
	(t.tac & 0x04) != 0;

// Returns the DIV bit position that drives TIMA, selected
// by TAC bits 0-1.
fn timer_selected_bit(t: *timer) u16 = switch (t.tac & 0x03) {
case 0 => yield 9;  // 4096 Hz
case 1 => yield 3;  // 262144 Hz
case 2 => yield 5;  // 65536 Hz
case 3 => yield 7;  // 16384 Hz
case => abort("unreachable");
};

// Returns the logical AND of the timer-enable flag and the
// selected DIV bit, used for falling-edge detection.
fn timer_input(t: *timer, div: u16) bool =
	timer_enabled(t)
	&& ((div >> timer_selected_bit(t)) & 1) == 1;

// Increments TIMA. Returns true on overflow (0xFF -> 0x00),
// which schedules a reload from TMA.
fn timer_inc_tima(t: *timer) bool = {
	t.tima += 1;
	if (t.tima == 0) {
		t.reload_delay = 4;
		t.reload_cycle_b = 0;
		return true;
	};
	return false;
};

// Advances the timer by one T-cycle. Returns true if an
// interrupt should fire.
fn timer_step_t(t: *timer) bool = {
	const old_in = timer_input(t, t.div);
	t.div += 1;
	const new_in = timer_input(t, t.div);

	let overflowed = false;
	if (old_in && !new_in) {
		overflowed = timer_inc_tima(t);
	};

	let started_b = false;
	if (t.reload_delay > 0 && !overflowed) {
		t.reload_delay -= 1;
		if (t.reload_delay == 0) {
			t.tima = t.tma;
			t.reload_cycle_b = 4;
			started_b = true;
		};
	};
	if (t.reload_cycle_b > 0 && !started_b) {
		t.reload_cycle_b -= 1;
	};
	return started_b && t.reload_delay == 0;
};

// Advances the [[timer]] by n T-cycles. Returns true if an
// [[INT_TIMER]] interrupt should fire.
export fn timer_update(t: *timer, cycles: i32) bool = {
	let interrupt = false;
	for (let i: i32 = 0; i < cycles; i += 1) {
		if (timer_step_t(t)) interrupt = true;
	};
	return interrupt;
};

// Returns the value of a timer register.
export fn timer_read(t: *timer, addr: u16) u8 = switch (addr) {
case 0xFF04 => yield (t.div >> 8): u8;
case 0xFF05 => yield t.tima;
case 0xFF06 => yield t.tma;
case 0xFF07 => yield t.tac | 0xF8;
case => yield 0xFF;
};

// Sets a timer register value.
export fn timer_write(
	t: *timer,
	addr: u16,
	value: u8,
) void = switch (addr) {
case 0xFF04 =>
	const old_in = timer_input(t, t.div);
	t.div = 0;
	if (old_in && !timer_input(t, t.div)) {
		timer_inc_tima(t);
	};
case 0xFF05 =>
	if (t.reload_cycle_b > 0) return;
	if (t.reload_delay > 0) t.reload_delay = 0;
	t.tima = value;
case 0xFF06 =>
	t.tma = value;
	if (t.reload_cycle_b > 0) t.tima = value;
case 0xFF07 =>
	const old_in = timer_input(t, t.div);
	t.tac = value & 0x07;
	if (old_in && !timer_input(t, t.div)) {
		timer_inc_tima(t);
	};
case => void;
};
