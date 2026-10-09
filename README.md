# RISC-V

A collection of RISC-V tools.

## Installation

Get the toolchain:
```bash
sudo apt update
sudo apt install -y gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu qemu-user gdb-multiarch
```

This toolchain targets both RV32 and RV64. The one you get is decided per-invocation by `-march`/`-mabi` flags.

## Usage

### `mkrv`: the global command

Save [mkrv.sh](mkrv.sh) somewhere (like `~/tools/riscv/mkrv.sh`), then add to your `~/.bashrc` (or other profile):

```
source ~/your/path/to/mkrv.sh
```

### Using `mkrv`

```
mkrv run main.s                  # single file
mkrv run main.s math_utils.s     # linked together, like a real project
mkrv stats main.s math_utils.s   # + instruction count
mkrv regs  main.s math_utils.s   # registers at your `ebreak`
mkrv all   main.s math_utils.s   # both
mkrv lst   main.s math_utils.s   # listing (see below)
mkrv map   main.s math_utils.s   # linker map (see below)
mkrv asm   main.s math_utils.s   # just check it assembles
mkrv debug main.s math_utils.s   # interactive gdb session
```

The mode always comes first, then the source files.
The first file's name (without extension) names the build output: `main.elf`, `main.map`, `main.o`, etc.

### Width wrappers

The `mkrv` bash file also includes two width wrapper functions: `mkrv32` and `mkrv64`, which are equivalent to setting the necessary environment variables for either RV32 or RV64, and which mark the choice as made *on purpose*.
Their usage is the same as `mkrv`.

Bare `mkrv` (no wrapper) still builds something — RV64 by default — but is treated as not having picked a width deliberately. See [width defaulting](#width-defaulting) below.

### Making breakpoints

To check the registers at a breakpoint, add an `ebreak` instruction and run `mkrv regs`.

> Register naming note: Register `x8` has two names in the RISC-V ABI: `s0` and `fp`.
> GDB's register dump displays it as `fp` even if you write `s0`.
> They are the same register.

### `lst` and `map`

`mkrv lst file...` runs `objdump -d` generates a disassembly listing featuring addresses, machine code, instructions, and resolves every branch/jump target to the actual label name across all linked files.

`mkrv map file...` prints the linker's `-Map` output, including every section's address and size, and every symbol's final address.

Either of these can be redirected to save it: `mkrv lst main.s math_utils.s > main.lst`

### Width defaulting

`mkrv` always tells `as` which width it's building for, via `--defsym XLEN=32` or `--defsym XLEN=64`, matching whatever `-march`/`-mabi` it's using. Any `.s` file can branch on this at assemble time:

```asm
.if XLEN == 64
        ld      a0, 0(sp)
.elseif XLEN == 32
        lw      a0, 0(sp)
.endif
```

Calling `mkrv32`/`mkrv64` also passes `--defsym MKRV_EXPLICIT=1`, marking the width as chosen on purpose. Calling bare `mkrv` does not. The shared headers (`rv.inc` and friends) check for this: if `MKRV_EXPLICIT` isn't set, the assembler itself prints a one-line warning reminding you to call `mkrv32`/`mkrv64` instead — build still succeeds, nothing fails, you just get a nudge. This only fires for files that `.include "rv.inc"`; a standalone `.s` file that doesn't pull in the shared headers builds silently at the default width either way.
