// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// [[joypad]] input handling for the Game Boy.
// JOYP register ([[IO_JOYP]]): bits 0-3 = button/direction state
// (active low), bits 4-5 = selection (active low).

// Joypad button and selection state.
export type joypad = struct {
	up: bool,
	down: bool,
	left: bool,
	right: bool,
	a: bool,
	b: bool,
	start: bool,
	select: bool,
	select_buttons: bool,
	select_dpad: bool,
};

// Joypad key identifiers for [[joypad_set_key]].
export type joy_key = enum {
	RIGHT,
	LEFT,
	UP,
	DOWN,
	A,
	B,
	START,
	SELECT,
};

// Returns true when at least one selected key line transitions
// from released (1) to pressed (0).
fn joypad_pressed_edge(prev: u8, next: u8) bool =
	((prev & ~next) & 0x0Fu8) != 0;

// Returns the JOYP register value based on current button state.
export fn joypad_read(j: *joypad) u8 = {
	let result: u8 = 0xFF;
	if (j.select_dpad) {
		if (j.right) result &= ~0x01u8;
		if (j.left) result &= ~0x02u8;
		if (j.up) result &= ~0x04u8;
		if (j.down) result &= ~0x08u8;
		result &= ~0x10u8;
	};
	if (j.select_buttons) {
		if (j.a) result &= ~0x01u8;
		if (j.b) result &= ~0x02u8;
		if (j.select) result &= ~0x04u8;
		if (j.start) result &= ~0x08u8;
		result &= ~0x20u8;
	};
	return result;
};

// Updates one joypad key and returns true when this change
// should request [[INT_JOYPAD]].
export fn joypad_set_key(
	j: *joypad,
	key: joy_key,
	pressed: bool,
) bool = {
	const prev = joypad_read(j);
	switch (key) {
	case joy_key::RIGHT => j.right = pressed;
	case joy_key::LEFT => j.left = pressed;
	case joy_key::UP => j.up = pressed;
	case joy_key::DOWN => j.down = pressed;
	case joy_key::A => j.a = pressed;
	case joy_key::B => j.b = pressed;
	case joy_key::START => j.start = pressed;
	case joy_key::SELECT => j.select = pressed;
	};
	const next = joypad_read(j);
	return joypad_pressed_edge(prev, next);
};

// Sets the JOYP selection bits from a write to 0xFF00.
export fn joypad_write(j: *joypad, value: u8) bool = {
	const prev = joypad_read(j);
	j.select_dpad = (value & 0x10) == 0;
	j.select_buttons = (value & 0x20) == 0;
	const next = joypad_read(j);
	return joypad_pressed_edge(prev, next);
};
