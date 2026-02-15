
<h1 align="center"><b>HareBoy</b></h1>
<p align="center">A Game Boy (DMG) emulator written in <a href="https://harelang.org">Hare</a></p>


<p align="center">
  <img src="docs/gifs/demo-1.gif" width="160" alt="Demo 1">
  <img src="docs/gifs/demo-2.gif" width="160" alt="Demo 2">
  <img src="docs/gifs/demo-3.gif" width="160" alt="Demo 3">
</p>
<p align="center">
  <img src="docs/gifs/demo-4.gif" width="160" alt="Demo 4">
  <img src="docs/gifs/demo-5.gif" width="160" alt="Demo 5">
  <img src="docs/gifs/demo-6.gif" width="160" alt="Demo 6">
</p>

## Usage

```
./hareboy <rom.gb>
```

## Controls

| Key         | Action |
|-------------|--------|
| Arrow keys  | D-pad  |
| Z           | A      |
| X           | B      |
| Enter       | Start  |
| Shift       | Select |
| Escape      | Quit   |


## Building

You need [Hare](https://harelang.org) (including QBE and harec), [SDL2](https://libsdl.org) development libraries via [hare-sdl2](https://git.sr.ht/~sircmpwn/hare-sdl2) bindings.

Install SDL2 on your system:

```
sudo apt-get install libsdl2-dev
```

Install the hare-sdl2 bindings into Hare's third-party module path:

```shell
git clone https://git.sr.ht/~sircmpwn/hare-sdl2
sudo mkdir -p /usr/local/src/hare/third-party
sudo cp -r hare-sdl2/sdl2 /usr/local/src/hare/third-party/
```

### Compile

```shell
hare build -lSDL2 -o hareboy .
```

