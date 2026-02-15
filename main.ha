// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Game Boy emulator entry point.
// Uses SDL2 for display and input. Creates a [[gameboy]] and
// drives the main loop via [[run_frame]].

use fmt;
use fs;
use io;
use os;
use sdl2;

def SCALE: int = 4;

// Frame pacing near 59.7275 Hz using a 16/17 ms cadence.
def FRAME_MS_BASE: u32 = 16;
def FRAME_MS_FRAC_NUM: u32 = 7427;
def FRAME_MS_FRAC_DEN: u32 = 10000;

// SDL_PIXELFORMAT_ARGB8888 bitmask value (0x16362004).
// Workaround: the hare-sdl2 binding defines pixel format enums
// with sequential values instead of the bitmask encoding that
// SDL2 uses, so we hardcode the correct constant here.
// See: https://github.com/Angluca/hare-sdl2
def PIXFMT_ARGB8888: u32 = 0x16362004;

export fn main() void = match (run()) {
case let err: sdl2::error =>
	fmt::fatal("SDL2 error:",
		sdl2::strerror(err));
case let err: io::error =>
	fmt::fatal("I/O error:",
		io::strerror(err));
case let err: fs::error =>
	fmt::fatal("Error:", fs::strerror(err));
case void => void;
};

// Updates one joypad key and raises [[INT_JOYPAD]] on press edge.
fn set_joypad_key(
	gb: *gameboy,
	key: joy_key,
	pressed: bool,
) void = {
	if (joypad_set_key(&gb.joy, key, pressed)) {
		gb.mmu.io[IO_IF] |= INT_JOYPAD;
	};
};

fn run() (void | sdl2::error | io::error | fs::error) = {
	if (len(os::args) < 2) {
		fmt::println(
			"Usage: hareboy <rom.gb>",
		)!;
		fmt::println(
			"Controls: Arrows=D-pad, Z=A, X=B,"
			" Enter=Start, Shift=Select,"
			" ESC=Quit",
		)!;
		os::exit(1);
	};

	const rom_path = os::args[1];
	const file = os::open(rom_path)?;
	defer io::close(file)!;
	const rom = io::drain(file)?;
	defer free(rom);

	fmt::println("Game Boy Emulator - Hare Edition")!;
	fmt::printfln(
		"Loaded: {} ({} bytes)",
		rom_path, len(rom),
	)!;
	fmt::println(
		"Controls: Arrows=D-pad, Z=A, X=B,"
		" Enter=Start, Shift=Select, ESC=Quit",
	)!;

	let gb = newgameboy(rom);
	init(&gb);
	defer finish(&gb);

	// Initialize SDL2 (video + audio)
	sdl2::SDL_Init(
		sdl2::SDL_INIT_VIDEO
		| sdl2::SDL_INIT_AUDIO,
	)!;
	defer sdl2::SDL_Quit();

	// Initialize audio
	match (apu_init_audio(&gb.snd)) {
	case void => void;
	case let err: audio_error =>
		fmt::printfln(
			"Warning: {}",
			audio_strerror(err),
		)!;
	};

	const win = sdl2::SDL_CreateWindow(
		"Game Boy Emulator",
		sdl2::SDL_WINDOWPOS_CENTERED,
		sdl2::SDL_WINDOWPOS_CENTERED,
		SCREEN_W: int * SCALE,
		SCREEN_H: int * SCALE,
		sdl2::SDL_WindowFlags::SHOWN,
	)?;
	defer sdl2::SDL_DestroyWindow(win);

	const ren = sdl2::SDL_CreateRenderer(
		win, -1,
		sdl2::SDL_RendererFlags::ACCELERATED
		| sdl2::SDL_RendererFlags::PRESENTVSYNC,
	)?;
	defer sdl2::SDL_DestroyRenderer(ren);

	const tex = sdl2::SDL_CreateTexture(
		ren, PIXFMT_ARGB8888,
		1, // SDL_TEXTUREACCESS_STREAMING
		SCREEN_W: int, SCREEN_H: int,
	)?;
	defer sdl2::SDL_DestroyTexture(tex);

	// ARGB pixel buffer
	let pixels: [SCREEN_W * SCREEN_H * 4]u8 = [0...];

	let next_frame = sdl2::SDL_GetTicks();
	let frame_frac: u32 = 0;

	// Main loop
	let quit = false;
	for (!quit) {

		// Poll SDL events
		let ev = sdl2::event { ... };
		for (sdl2::SDL_PollEvent(&ev)? == 1)
		switch (ev.event_type) {
		case sdl2::SDL_EventType::QUIT =>
			quit = true;
		case sdl2::SDL_EventType::KEYDOWN =>
			switch (ev.key.keysym.scancode) {
			case sdl2::SDL_Scancode::UP =>
				set_joypad_key(&gb, joy_key::UP, true);
			case sdl2::SDL_Scancode::DOWN =>
				set_joypad_key(&gb, joy_key::DOWN, true);
			case sdl2::SDL_Scancode::LEFT =>
				set_joypad_key(&gb, joy_key::LEFT, true);
			case sdl2::SDL_Scancode::RIGHT =>
				set_joypad_key(&gb, joy_key::RIGHT, true);
			case sdl2::SDL_Scancode::Z =>
				set_joypad_key(&gb, joy_key::A, true);
			case sdl2::SDL_Scancode::X =>
				set_joypad_key(&gb, joy_key::B, true);
			case sdl2::SDL_Scancode::RETURN =>
				set_joypad_key(&gb, joy_key::START, true);
			case sdl2::SDL_Scancode::LSHIFT,
					sdl2::SDL_Scancode::RSHIFT =>
				set_joypad_key(
					&gb, joy_key::SELECT, true,
				);
			case sdl2::SDL_Scancode::ESCAPE =>
				quit = true;
			case => void;
			};
		case sdl2::SDL_EventType::KEYUP =>
			switch (ev.key.keysym.scancode) {
			case sdl2::SDL_Scancode::UP =>
				set_joypad_key(&gb, joy_key::UP, false);
			case sdl2::SDL_Scancode::DOWN =>
				set_joypad_key(
					&gb, joy_key::DOWN, false,
				);
			case sdl2::SDL_Scancode::LEFT =>
				set_joypad_key(
					&gb, joy_key::LEFT, false,
				);
			case sdl2::SDL_Scancode::RIGHT =>
				set_joypad_key(
					&gb, joy_key::RIGHT, false,
				);
			case sdl2::SDL_Scancode::Z =>
				set_joypad_key(&gb, joy_key::A, false);
			case sdl2::SDL_Scancode::X =>
				set_joypad_key(&gb, joy_key::B, false);
			case sdl2::SDL_Scancode::RETURN =>
				set_joypad_key(
					&gb, joy_key::START, false,
				);
			case sdl2::SDL_Scancode::LSHIFT,
					sdl2::SDL_Scancode::RSHIFT =>
				set_joypad_key(
					&gb, joy_key::SELECT, false,
				);
			case sdl2::SDL_Scancode::ESCAPE =>
				quit = true;
			case => void;
			};
		case => void;
		};

		// Run one emulation frame
		run_frame(&gb);

		// Convert framebuffer to ARGB pixels
		for (let i = 0z;
				i < SCREEN_W * SCREEN_H;
				i += 1) {
			const shade =
				gb.ppu.framebuffer[i];
			const color = PALETTE[shade];
			// ARGB byte order: B, G, R, A
			// (little-endian u32 = 0xAARRGGBB)
			pixels[i * 4 + 0] = color[2]; // B
			pixels[i * 4 + 1] = color[1]; // G
			pixels[i * 4 + 2] = color[0]; // R
			pixels[i * 4 + 3] = color[3]; // A
		};

		// Update texture and render
		sdl2::SDL_UpdateTexture(
			tex, null,
			&pixels: *opaque,
			SCREEN_W: int * 4,
		)?;
		sdl2::SDL_RenderClear(ren)?;
		sdl2::SDL_RenderCopy(
			ren, tex, null, null,
		)?;
		sdl2::SDL_RenderPresent(ren);

		// Frame timing: advance absolute target.
		// VSync handles smooth presentation on 60 Hz.
		// The delay below is a fallback for high-refresh
		// displays where VSync alone would run too fast.
		next_frame += FRAME_MS_BASE;
		frame_frac += FRAME_MS_FRAC_NUM;
		if (frame_frac >= FRAME_MS_FRAC_DEN) {
			next_frame += 1;
			frame_frac -= FRAME_MS_FRAC_DEN;
		};
		const now = sdl2::SDL_GetTicks();
		if (next_frame > now) {
			sdl2::SDL_Delay(next_frame - now);
		} else {
			// Fell behind; snap forward to prevent
			// a burst of catch-up frames.
			next_frame = now;
		};
	};
};
