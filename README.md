# tb32emu

A graphical emulator and assembly IDE for the **TB32** instruction set, built on top of [libtb32](https://github.com/Tonic-Box/libtb32).

## Build and run

```
zig build run                        # build and launch
zig build test                       # unit tests
zig build -Doptimize=ReleaseFast     # optimized build in zig-out/bin/
```

Requires Zig 0.13 to build.

## Shortcuts

- **Ctrl-B** - assemble the active file
- **Ctrl-S** - save the active file

## License

[MIT](LICENSE). Bundled third-party components and their licenses are listed in
