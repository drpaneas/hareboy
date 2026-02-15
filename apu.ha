// SPDX-License-Identifier: GPL-3.0-only
// (c) Panagiotis Georgiadis (aka drpaneas)

// Game Boy Audio Processing Unit ([[apu]]).
// Implements all 4 sound channels: CH1 ([[square_ch]] with sweep),
// CH2 ([[square_ch]]), CH3 ([[wave_ch]]), CH4 ([[noise_ch]]).
// Outputs stereo i16 samples via [[apu_flush]].

// Returned when [[apu_init_audio]] cannot open the SDL audio
// device.
export type audio_error = !void;

// Returns a human-readable message for an [[audio_error]].
export fn audio_strerror(err: audio_error) str =
	"Failed to open SDL audio device";

def APU_SAMPLE_RATE: i32 = 44100;
def APU_CPU_FREQ: i32 = 4194304;
def APU_FRAME_SEQ_PERIOD: i32 = 8192; // CPU_FREQ / 512
def AUDIO_S16LSB: u16 = 0x8010;

// SDL2 audio FFI - raw C bindings not in the Hare sdl2 module.
@symbol("SDL_OpenAudioDevice") fn sdl_open_audio_device(
	device: nullable *opaque, iscapture: i32,
	desired: *sdl_audio_spec,
	obtained: nullable *sdl_audio_spec,
	allowed_changes: i32,
) u32;

@symbol("SDL_PauseAudioDevice") fn sdl_pause_audio_device(
	dev: u32, pause_on: i32,
) void;

@symbol("SDL_QueueAudio") fn sdl_queue_audio(
	dev: u32, data: *opaque, len_bytes: u32,
) i32;

@symbol("SDL_CloseAudioDevice") fn sdl_close_audio_device(
	dev: u32,
) void;

@symbol("SDL_GetQueuedAudioSize") fn sdl_get_queued_audio_size(
	dev: u32,
) u32;

type sdl_audio_spec = struct {
	freq: i32,
	format: u16,
	channels: u8,
	silence: u8,
	samples: u16,
	padding: u16,
	sz: u32,
	callback: nullable *opaque,
	userdata: nullable *opaque,
};

const DUTY_WAVEFORMS: [4][8]i32 = [
	[0, 0, 0, 0, 0, 0, 0, 1], // 12.5%
	[1, 0, 0, 0, 0, 0, 0, 1], // 25%
	[1, 0, 0, 0, 0, 1, 1, 1], // 50%
	[0, 1, 1, 1, 1, 1, 1, 0], // 75%
];

const NOISE_DIVISORS: [8]i32 = [
	8, 16, 32, 48, 64, 80, 96, 112,
];
const WAVE_SHIFTS: [4]i32 = [4, 0, 1, 2];

// Square wave channel state (used by CH1 and CH2).
export type square_ch = struct {
	enabled: bool,
	dac_enabled: bool,
	duty: i32,
	duty_pos: i32,
	length_counter: i32,
	length_enabled: bool,
	volume: i32,
	volume_init: i32,
	volume_env_add: bool,
	volume_env_per: i32,
	volume_env_timer: i32,
	frequency: i32,
	freq_timer: i32,
	// Sweep (CH1 only)
	sweep_enabled: bool,
	sweep_period: i32,
	sweep_negate: bool,
	sweep_shift: i32,
	sweep_timer: i32,
	sweep_shadow: i32,
	sweep_calc_done: bool,
};

// Wave channel state (CH3).
export type wave_ch = struct {
	enabled: bool,
	dac_enabled: bool,
	length_counter: i32,
	length_enabled: bool,
	volume_code: i32,
	frequency: i32,
	freq_timer: i32,
	sample_pos: i32,
	sample_buffer: u8,
	wave_ram: [16]u8,
};

// Noise channel state (CH4).
export type noise_ch = struct {
	enabled: bool,
	dac_enabled: bool,
	length_counter: i32,
	length_enabled: bool,
	volume: i32,
	volume_init: i32,
	volume_env_add: bool,
	volume_env_per: i32,
	volume_env_timer: i32,
	clock_shift: i32,
	width_mode: bool,
	divisor_code: i32,
	freq_timer: i32,
	lfsr: u16,
};

// Audio processing unit with four sound channels and an output
// sample buffer.
export type apu = struct {
	ch1: square_ch,
	ch2: square_ch,
	ch3: wave_ch,
	ch4: noise_ch,
	nr50: u8,
	nr51: u8,
	nr52: u8,
	frame_seq_timer: i32,
	frame_seq_step: i32,
	sample_timer: i32,
	sample_period: i32,
	// Audio output buffer.
	audio_buf: [2048]i16, // stereo pairs
	audio_len: size,
	audio_dev: u32,
};

// Creates an [[apu]] initialized to DMG post-boot state.
export fn newapu() apu = apu {
	nr52 = 0xF1,
	nr50 = 0x77,
	nr51 = 0xFF,
	sample_period = APU_CPU_FREQ / APU_SAMPLE_RATE,
	...
};

// Opens the SDL audio device for playback.
export fn apu_init_audio(a: *apu) (void | audio_error) = {
	let desired = sdl_audio_spec {
		freq = APU_SAMPLE_RATE,
		format = AUDIO_S16LSB,
		channels = 2,
		samples = 1024,
		...
	};
	a.audio_dev = sdl_open_audio_device(
		null, 0, &desired, null, 0,
	);
	if (a.audio_dev == 0) return audio_error;
	// Unpause to start playback
	sdl_pause_audio_device(a.audio_dev, 0);
};

// Closes the audio device.
export fn apu_close(a: *apu) void = {
	if (a.audio_dev != 0) {
		sdl_close_audio_device(a.audio_dev);
		a.audio_dev = 0;
	};
};

// Advances the [[apu]] by the given number of T-cycles.
export fn apu_update(a: *apu, cycles: i32) void = {
	if ((a.nr52 & 0x80) == 0) return;

	for (let i: i32 = 0; i < cycles; i += 1) {
		a.frame_seq_timer += 1;
		if (a.frame_seq_timer >= APU_FRAME_SEQ_PERIOD) {
			a.frame_seq_timer = 0;
			apu_tick_frame_seq(a);
		};
		apu_tick_channels(a);
		a.sample_timer += 1;
		if (a.sample_timer >= a.sample_period) {
			a.sample_timer -= a.sample_period;
			apu_mix_sample(a);
		};
	};
};

// Flushes buffered audio samples to SDL via
// [[apu_init_audio]]'s device.
export fn apu_flush(a: *apu) void = {
	if (a.audio_dev == 0 || a.audio_len == 0)
		return;

	// Don't let the queue grow too large (~100ms)
	const queued =
		sdl_get_queued_audio_size(a.audio_dev);
	if (queued > APU_SAMPLE_RATE: u32 * 4 / 10)
		return;

	sdl_queue_audio(
		a.audio_dev,
		&a.audio_buf: *opaque,
		(a.audio_len * 2): u32, // i16 = 2 bytes
	);
	a.audio_len = 0;
};

// Advances the 512 Hz frame sequencer by one step, clocking
// length, sweep, and envelope units on the appropriate steps.
fn apu_tick_frame_seq(a: *apu) void = {
	switch (a.frame_seq_step) {
	case 0 =>
		apu_tick_length(a);
	case 2 =>
		apu_tick_length(a);
		apu_tick_sweep(a);
	case 4 =>
		apu_tick_length(a);
	case 6 =>
		apu_tick_length(a);
		apu_tick_sweep(a);
	case 7 =>
		apu_tick_envelope(a);
	case => void;
	};
	a.frame_seq_step = (a.frame_seq_step + 1) & 7;
};

// Decrements length counters for all channels. Disables a
// channel when its counter reaches zero.
fn apu_tick_length(a: *apu) void = {
	if (a.ch1.length_enabled
			&& a.ch1.length_counter > 0) {
		a.ch1.length_counter -= 1;
		if (a.ch1.length_counter == 0)
			a.ch1.enabled = false;
	};
	if (a.ch2.length_enabled
			&& a.ch2.length_counter > 0) {
		a.ch2.length_counter -= 1;
		if (a.ch2.length_counter == 0)
			a.ch2.enabled = false;
	};
	if (a.ch3.length_enabled
			&& a.ch3.length_counter > 0) {
		a.ch3.length_counter -= 1;
		if (a.ch3.length_counter == 0)
			a.ch3.enabled = false;
	};
	if (a.ch4.length_enabled
			&& a.ch4.length_counter > 0) {
		a.ch4.length_counter -= 1;
		if (a.ch4.length_counter == 0)
			a.ch4.enabled = false;
	};
};

// Clocks the CH1 frequency sweep unit. Adjusts frequency
// and disables the channel on overflow.
fn apu_tick_sweep(a: *apu) void = {
	if (a.ch1.sweep_timer > 0)
		a.ch1.sweep_timer -= 1;
	if (a.ch1.sweep_timer == 0) {
		a.ch1.sweep_timer =
			if (a.ch1.sweep_period > 0)
				a.ch1.sweep_period
			else
				8;
		if (a.ch1.sweep_enabled
				&& a.ch1.sweep_period > 0) {
			const nf = apu_calc_sweep(a);
			if (nf < 2048
					&& a.ch1.sweep_shift > 0) {
				a.ch1.frequency = nf;
				a.ch1.sweep_shadow = nf;
				apu_calc_sweep(a);
			};
		};
	};
};

// Computes the new sweep frequency for CH1. Disables the
// channel if the result exceeds 2047.
fn apu_calc_sweep(a: *apu) i32 = {
	const delta: i32 =
		((a.ch1.sweep_shadow: u32)
		>> (a.ch1.sweep_shift: u32)): i32;
	const nf: i32 = if (a.ch1.sweep_negate) {
		a.ch1.sweep_calc_done = true;
		yield a.ch1.sweep_shadow - delta;
	} else {
		yield a.ch1.sweep_shadow + delta;
	};
	if (nf >= 2048) a.ch1.enabled = false;
	return nf;
};

// Clocks the volume envelope for CH1, CH2, and CH4.
fn apu_tick_envelope(a: *apu) void = {
	apu_tick_env_ch(&a.ch1);
	apu_tick_env_ch(&a.ch2);
	// CH4 envelope
	if (a.ch4.volume_env_per > 0) {
		a.ch4.volume_env_timer -= 1;
		if (a.ch4.volume_env_timer <= 0) {
			a.ch4.volume_env_timer =
				a.ch4.volume_env_per;
			if (a.ch4.volume_env_add
					&& a.ch4.volume < 15)
				a.ch4.volume += 1
			else if (!a.ch4.volume_env_add
					&& a.ch4.volume > 0)
				a.ch4.volume -= 1;
		};
	};
};

// Clocks the volume envelope for a single [[square_ch]].
fn apu_tick_env_ch(ch: *square_ch) void = {
	if (ch.volume_env_per > 0) {
		ch.volume_env_timer -= 1;
		if (ch.volume_env_timer <= 0) {
			ch.volume_env_timer =
				ch.volume_env_per;
			if (ch.volume_env_add
					&& ch.volume < 15)
				ch.volume += 1
			else if (!ch.volume_env_add
					&& ch.volume > 0)
				ch.volume -= 1;
		};
	};
};

// Advances the frequency timers for all four channels by
// one T-cycle.
fn apu_tick_channels(a: *apu) void = {
	// CH1
	a.ch1.freq_timer -= 1;
	if (a.ch1.freq_timer <= 0) {
		a.ch1.freq_timer =
			(2048 - a.ch1.frequency) * 4;
		a.ch1.duty_pos =
			(a.ch1.duty_pos + 1) & 7;
	};
	// CH2
	a.ch2.freq_timer -= 1;
	if (a.ch2.freq_timer <= 0) {
		a.ch2.freq_timer =
			(2048 - a.ch2.frequency) * 4;
		a.ch2.duty_pos =
			(a.ch2.duty_pos + 1) & 7;
	};
	// CH3
	a.ch3.freq_timer -= 1;
	if (a.ch3.freq_timer <= 0) {
		a.ch3.freq_timer =
			(2048 - a.ch3.frequency) * 2;
		a.ch3.sample_pos =
			(a.ch3.sample_pos + 1) & 31;
		const byte_idx = a.ch3.sample_pos / 2;
		if (a.ch3.sample_pos & 1 == 0) {
			a.ch3.sample_buffer =
				(a.ch3.wave_ram[byte_idx] >> 4)
				& 0x0F;
		} else {
			a.ch3.sample_buffer =
				a.ch3.wave_ram[byte_idx]
				& 0x0F;
		};
	};
	// CH4
	a.ch4.freq_timer -= 1;
	if (a.ch4.freq_timer <= 0) {
		a.ch4.freq_timer =
			((NOISE_DIVISORS[a.ch4.divisor_code]: u32)
			<< (a.ch4.clock_shift: u32)): i32;
		const xor_bit = (a.ch4.lfsr & 1)
			^ ((a.ch4.lfsr >> 1) & 1);
		a.ch4.lfsr = (a.ch4.lfsr >> 1)
			| (xor_bit << 14);
		if (a.ch4.width_mode) {
			a.ch4.lfsr &= ~(1u16 << 6);
			a.ch4.lfsr |= xor_bit << 6;
		};
	};
};

// Mixes one stereo sample from all enabled channels and
// appends it to the audio output buffer.
fn apu_mix_sample(a: *apu) void = {
	let left: i32 = 0;
	let right: i32 = 0;

	// CH1
	if (a.ch1.enabled && a.ch1.dac_enabled) {
		const s =
			DUTY_WAVEFORMS[a.ch1.duty][a.ch1.duty_pos]
			* a.ch1.volume;
		if ((a.nr51 & 0x10) != 0) left += s;
		if ((a.nr51 & 0x01) != 0) right += s;
	};
	// CH2
	if (a.ch2.enabled && a.ch2.dac_enabled) {
		const s =
			DUTY_WAVEFORMS[a.ch2.duty][a.ch2.duty_pos]
			* a.ch2.volume;
		if ((a.nr51 & 0x20) != 0) left += s;
		if ((a.nr51 & 0x02) != 0) right += s;
	};
	// CH3
	if (a.ch3.enabled && a.ch3.dac_enabled) {
		const shift = WAVE_SHIFTS[a.ch3.volume_code];
		const s =
			(a.ch3.sample_buffer >> shift: u32): i32;
		if ((a.nr51 & 0x40) != 0) left += s;
		if ((a.nr51 & 0x04) != 0) right += s;
	};
	// CH4
	if (a.ch4.enabled && a.ch4.dac_enabled) {
		const bit = 1 - (a.ch4.lfsr & 1): i32;
		const s = bit * a.ch4.volume;
		if ((a.nr51 & 0x80) != 0) left += s;
		if ((a.nr51 & 0x08) != 0) right += s;
	};

	// Master volume
	const left_vol = ((a.nr50 >> 4) & 7): i32 + 1;
	const right_vol = (a.nr50 & 7): i32 + 1;
	left = left * left_vol / 8;
	right = right * right_vol / 8;

	// Scale to i16 range
	const left_sample: i16 = (left * 273): i16;
	const right_sample: i16 = (right * 273): i16;

	// Buffer samples
	if (a.audio_len + 2 <= len(a.audio_buf)) {
		a.audio_buf[a.audio_len] = left_sample;
		a.audio_buf[a.audio_len + 1] = right_sample;
		a.audio_len += 2;
	};

	// Auto-flush when buffer is full
	if (a.audio_len >= len(a.audio_buf)) {
		apu_flush(a);
	};
};

// Writes to an [[apu]] register (0xFF10-0xFF3F).
export fn apu_write(a: *apu, addr: u16, value: u8) void = {
	if ((a.nr52 & 0x80) == 0 && addr != 0xFF26
			&& !(addr >= 0xFF30
			&& addr <= 0xFF3F)) {
		return;
	};
	switch (addr) {
	case 0xFF10 => // NR10
		a.ch1.sweep_period =
			((value >> 4) & 0x07): i32;
		const old_neg = a.ch1.sweep_negate;
		a.ch1.sweep_negate = (value & 0x08) != 0;
		a.ch1.sweep_shift = (value & 0x07): i32;
		if (old_neg && !a.ch1.sweep_negate
				&& a.ch1.sweep_calc_done)
			a.ch1.enabled = false;
	case 0xFF11 => // NR11
		a.ch1.duty = ((value >> 6) & 0x03): i32;
		a.ch1.length_counter =
			64 - (value & 0x3F): i32;
	case 0xFF12 => // NR12
		a.ch1.volume_init =
			((value >> 4) & 0x0F): i32;
		a.ch1.volume_env_add =
			(value & 0x08) != 0;
		a.ch1.volume_env_per =
			(value & 0x07): i32;
		a.ch1.dac_enabled = (value & 0xF8) != 0;
		if (!a.ch1.dac_enabled)
			a.ch1.enabled = false;
	case 0xFF13 => // NR13
		a.ch1.frequency =
			(a.ch1.frequency & 0x700)
			| value: i32;
	case 0xFF14 => // NR14
		a.ch1.frequency =
			(a.ch1.frequency & 0xFF)
			| ((value & 0x07): i32 << 8);
		a.ch1.length_enabled =
			(value & 0x40) != 0;
		if ((value & 0x80) != 0)
			apu_trigger_ch1(a);
	case 0xFF16 => // NR21
		a.ch2.duty = ((value >> 6) & 0x03): i32;
		a.ch2.length_counter =
			64 - (value & 0x3F): i32;
	case 0xFF17 => // NR22
		a.ch2.volume_init =
			((value >> 4) & 0x0F): i32;
		a.ch2.volume_env_add =
			(value & 0x08) != 0;
		a.ch2.volume_env_per =
			(value & 0x07): i32;
		a.ch2.dac_enabled = (value & 0xF8) != 0;
		if (!a.ch2.dac_enabled)
			a.ch2.enabled = false;
	case 0xFF18 => // NR23
		a.ch2.frequency =
			(a.ch2.frequency & 0x700)
			| value: i32;
	case 0xFF19 => // NR24
		a.ch2.frequency =
			(a.ch2.frequency & 0xFF)
			| ((value & 0x07): i32 << 8);
		a.ch2.length_enabled =
			(value & 0x40) != 0;
		if ((value & 0x80) != 0)
			apu_trigger_ch2(a);
	case 0xFF1A => // NR30
		a.ch3.dac_enabled = (value & 0x80) != 0;
		if (!a.ch3.dac_enabled)
			a.ch3.enabled = false;
	case 0xFF1B => // NR31
		a.ch3.length_counter = 256 - value: i32;
	case 0xFF1C => // NR32
		a.ch3.volume_code =
			((value >> 5) & 0x03): i32;
	case 0xFF1D => // NR33
		a.ch3.frequency =
			(a.ch3.frequency & 0x700)
			| value: i32;
	case 0xFF1E => // NR34
		a.ch3.frequency =
			(a.ch3.frequency & 0xFF)
			| ((value & 0x07): i32 << 8);
		a.ch3.length_enabled =
			(value & 0x40) != 0;
		if ((value & 0x80) != 0)
			apu_trigger_ch3(a);
	case 0xFF20 => // NR41
		a.ch4.length_counter =
			64 - (value & 0x3F): i32;
	case 0xFF21 => // NR42
		a.ch4.volume_init =
			((value >> 4) & 0x0F): i32;
		a.ch4.volume_env_add =
			(value & 0x08) != 0;
		a.ch4.volume_env_per =
			(value & 0x07): i32;
		a.ch4.dac_enabled = (value & 0xF8) != 0;
		if (!a.ch4.dac_enabled)
			a.ch4.enabled = false;
	case 0xFF22 => // NR43
		a.ch4.clock_shift =
			((value >> 4) & 0x0F): i32;
		a.ch4.width_mode = (value & 0x08) != 0;
		a.ch4.divisor_code =
			(value & 0x07): i32;
	case 0xFF23 => // NR44
		a.ch4.length_enabled =
			(value & 0x40) != 0;
		if ((value & 0x80) != 0)
			apu_trigger_ch4(a);
	case 0xFF24 => a.nr50 = value;
	case 0xFF25 => a.nr51 = value;
	case 0xFF26 => // NR52
		const was_on = (a.nr52 & 0x80) != 0;
		const now_on = (value & 0x80) != 0;
		if (was_on && !now_on) apu_reset(a);
		a.nr52 = (a.nr52 & 0x0F) | (value & 0x80);
	case =>
		if (addr >= 0xFF30 && addr <= 0xFF3F) {
			a.ch3.wave_ram[addr - 0xFF30] =
				value;
		};
	};
};

// Reads an [[apu]] register (0xFF10-0xFF3F).
export fn apu_read(a: *apu, addr: u16) u8 = switch (addr) {
case 0xFF10 =>
	const neg: u8 =
		if (a.ch1.sweep_negate)
			0x08
		else
			0;
	yield (a.ch1.sweep_period << 4): u8
		| neg
		| a.ch1.sweep_shift: u8
		| 0x80;
case 0xFF11 =>
	yield (a.ch1.duty << 6): u8 | 0x3F;
case 0xFF12 =>
	const add: u8 =
		if (a.ch1.volume_env_add)
			0x08
		else
			0;
	yield (a.ch1.volume_init << 4): u8
		| add
		| a.ch1.volume_env_per: u8;
case 0xFF14 =>
	yield if (a.ch1.length_enabled)
		0xFF: u8
	else
		0xBF: u8;
case 0xFF16 =>
	yield (a.ch2.duty << 6): u8 | 0x3F;
case 0xFF17 =>
	const add: u8 =
		if (a.ch2.volume_env_add)
			0x08
		else
			0;
	yield (a.ch2.volume_init << 4): u8
		| add
		| a.ch2.volume_env_per: u8;
case 0xFF19 =>
	yield if (a.ch2.length_enabled)
		0xFF: u8
	else
		0xBF: u8;
case 0xFF1A =>
	yield if (a.ch3.dac_enabled)
		0xFF: u8
	else
		0x7F: u8;
case 0xFF1C =>
	yield (a.ch3.volume_code << 5): u8
		| 0x9F;
case 0xFF1E =>
	yield if (a.ch3.length_enabled)
		0xFF: u8
	else
		0xBF: u8;
case 0xFF21 =>
	const add: u8 =
		if (a.ch4.volume_env_add)
			0x08
		else
			0;
	yield (a.ch4.volume_init << 4): u8
		| add
		| a.ch4.volume_env_per: u8;
case 0xFF22 =>
	const wb: u8 =
		if (a.ch4.width_mode)
			0x08
		else
			0;
	yield (a.ch4.clock_shift << 4): u8
		| wb
		| a.ch4.divisor_code: u8;
case 0xFF23 =>
	yield if (a.ch4.length_enabled)
		0xFF: u8
	else
		0xBF: u8;
case 0xFF24 => yield a.nr50;
case 0xFF25 => yield a.nr51;
case 0xFF26 =>
	let status = a.nr52 & 0x80;
	if (a.ch1.enabled) status |= 0x01;
	if (a.ch2.enabled) status |= 0x02;
	if (a.ch3.enabled) status |= 0x04;
	if (a.ch4.enabled) status |= 0x08;
	yield status | 0x70;
case =>
	if (addr >= 0xFF30 && addr <= 0xFF3F) {
		yield a.ch3.wave_ram[addr - 0xFF30];
	};
	yield 0xFF;
};

// Resets all channels and master volume when NR52 bit 7
// is cleared.
fn apu_reset(a: *apu) void = {
	a.ch1 = square_ch { ... };
	a.ch2 = square_ch { ... };
	// Reset ch3 field-by-field to preserve wave_ram contents.
	a.ch3.enabled = false;
	a.ch3.dac_enabled = false;
	a.ch3.length_counter = 0;
	a.ch3.length_enabled = false;
	a.ch3.volume_code = 0;
	a.ch3.frequency = 0;
	a.ch4 = noise_ch { ... };
	a.nr50 = 0;
	a.nr51 = 0;
};

// Triggers CH1: reloads length, envelope, sweep, and
// frequency timer.
fn apu_trigger_ch1(a: *apu) void = {
	a.ch1.enabled = a.ch1.dac_enabled;
	if (a.ch1.length_counter == 0)
		a.ch1.length_counter = 64;
	a.ch1.freq_timer =
		(2048 - a.ch1.frequency) * 4;
	a.ch1.volume_env_timer = a.ch1.volume_env_per;
	a.ch1.volume = a.ch1.volume_init;
	a.ch1.sweep_shadow = a.ch1.frequency;
	a.ch1.sweep_timer =
		if (a.ch1.sweep_period > 0)
			a.ch1.sweep_period
		else
			8;
	a.ch1.sweep_enabled =
		a.ch1.sweep_period > 0
		|| a.ch1.sweep_shift > 0;
	a.ch1.sweep_calc_done = false;
	if (a.ch1.sweep_shift > 0)
		apu_calc_sweep(a);
};

// Triggers CH2: reloads length, envelope, and frequency
// timer.
fn apu_trigger_ch2(a: *apu) void = {
	a.ch2.enabled = a.ch2.dac_enabled;
	if (a.ch2.length_counter == 0)
		a.ch2.length_counter = 64;
	a.ch2.freq_timer =
		(2048 - a.ch2.frequency) * 4;
	a.ch2.volume_env_timer = a.ch2.volume_env_per;
	a.ch2.volume = a.ch2.volume_init;
};

// Triggers CH3: reloads length and frequency timer, resets
// sample position.
fn apu_trigger_ch3(a: *apu) void = {
	a.ch3.enabled = a.ch3.dac_enabled;
	if (a.ch3.length_counter == 0)
		a.ch3.length_counter = 256;
	a.ch3.freq_timer =
		(2048 - a.ch3.frequency) * 2;
	a.ch3.sample_pos = 0;
};

// Triggers CH4: reloads length, envelope, frequency timer,
// and resets the LFSR.
fn apu_trigger_ch4(a: *apu) void = {
	a.ch4.enabled = a.ch4.dac_enabled;
	if (a.ch4.length_counter == 0)
		a.ch4.length_counter = 64;
	a.ch4.freq_timer =
		((NOISE_DIVISORS[a.ch4.divisor_code]: u32)
		<< (a.ch4.clock_shift: u32)): i32;
	a.ch4.volume_env_timer = a.ch4.volume_env_per;
	a.ch4.volume = a.ch4.volume_init;
	a.ch4.lfsr = 0x7FFF;
};
