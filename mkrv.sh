# assemble/link/run RISC-V (RV32IM) assembly with the GNU toolchain + QEMU user-mode emulation
export MKRV_ARCH="${MKRV_ARCH:-rv32im}"
export MKRV_ABI="${MKRV_ABI:-ilp32}"
export MKRV_PREFIX="${MKRV_PREFIX:-riscv64-linux-gnu-}"   # also assembles/links RV32
export MKRV_QEMU="${MKRV_QEMU:-qemu-riscv32}"
export MKRV_LDEMU="${MKRV_LDEMU:-elf32lriscv}"   # linker -m for RV32; elf64lriscv for RV64
export MKRV_GDB="${MKRV_GDB:-gdb-multiarch}"
export MKRV_GDBARCH="${MKRV_GDBARCH:-riscv:rv32}"
# export MKRV_COLS=4          # registers per row in regs/all mode

# Formats a register dump (gdb "info registers" output) the same way mkmips
# does: a grid, tagged so it can't be mistaken for program output.
_mkrv_report() {
  local color=0
  [[ -t 2 ]] && color=1
  awk -v cols="${MKRV_COLS:-4}" -v color=$color '
    BEGIN { tag = color ? "\033[36m[mkrv]\033[0m" : "[mkrv]"; nr = 0; nm = 0; w = 0 }
    NF >= 2 && $1 ~ /^[a-z][a-z0-9]*$/ && $2 ~ /^0x[0-9a-fA-F]+$/ {
      name[nr] = $1; val[nr] = $2
      if (length($2) > w) w = length($2)
      nr++; next
    }
    # benign qemu-user/gdb quirk about the emulated vDSO page -- not useful
    /corrupt string table index/ { next }
    NF { msg[nm++] = $0 }
    END {
      for (i = 0; i < nm; i++) print tag " " msg[i]
      if (nr) {
        print tag " registers"
        for (i = 0; i < nr; i++)
          printf "  %-4s %-*s%s", name[i], w, val[i],
                 ((i + 1) % cols == 0 || i == nr - 1) ? "\n" : "  "
      }
    }' "$1" >&2
}

mkrv() {
  emulate -L zsh

  if (( $# < 2 )) || [[ $1 == -h || $1 == --help ]]; then
    cat <<'HELP'
usage: mkrv <mode> <file1.s> [file2.s ...]
       mkrv32 / mkrv64 <mode> <files...>   same modes, fixed to RV32I / RV64I

  run     (default-ish) assemble, link, and execute
  stats   run, then print the instruction count
  regs    run to the first `ebreak` in your code, print registers there
  all     run, then print instruction count and registers (needs `ebreak`)
  asm     assemble each file only -- just check for errors
  lst     disassembly listing: address, machine code, instruction, symbols
  map     print the linker map (section layout and symbol addresses)
  debug   attach an interactive gdb session (qemu runs as the gdbserver)

  Every file is assembled separately and linked together, so splitting a
  project across files (main.s, math_utils.s, ...) works like a normal
  compiled language. Build output (main.elf, main.map, each file's .o)
  lands in the same directory as the first file you pass.

  regs/all require your code to execute an `ebreak` where you want to
  look at the registers -- think of it as a breakpoint you place yourself.
  Program exit code (0-255) is always shown after `run`.

  In 'debug', set a breakpoint with the label name (break gcd) or a raw
  address with an asterisk (break *0x10084) -- break 0x10084 without the
  asterisk tries to look up a function named that and fails.
HELP
    return 0
  fi

  local mode=$1
  shift
  case $mode in
    run|stats|regs|all|asm|lst|map|debug) ;;
    *) print -u2 "mkrv: unknown mode '$mode' (try: mkrv -h)"; return 2 ;;
  esac

  local -a srcs objs
  local f base stem out rc

  for f in "$@"; do
    if   [[ -f $f ]];     then :
    elif [[ -f $f.s ]];   then f=$f.s
    elif [[ -f $f.asm ]]; then f=$f.asm
    else print -u2 "mkrv: no such file: $f (tried .s and .asm)"; return 1
    fi
    srcs+=("$f")
  done
  (( ${#srcs} )) || { print -u2 "mkrv: no source files given"; return 1 }

  local builddir=${srcs[1]:h}     # directory of the first source file
  out=${builddir}/${srcs[1]:t:r}  # build output lives next to that file

  for f in "$MKRV_PREFIX"as "$MKRV_PREFIX"ld "$MKRV_QEMU"; do
    command -v "$f" >/dev/null || { print -u2 "mkrv: $f not found"; return 1 }
  done

  objs=()
  for f in "${srcs[@]}"; do
    stem=${builddir}/${f:t:r}
    "${MKRV_PREFIX}as" -march="$MKRV_ARCH" -mabi="$MKRV_ABI" -o "$stem.o" "$f" \
      || return 1
    objs+=("$stem.o")
  done
  [[ $mode == asm ]] && { print "OK: assembles cleanly"; return 0 }

  "${MKRV_PREFIX}ld" -m "$MKRV_LDEMU" -o "$out.elf" "${objs[@]}" -Map="$out.map" \
    || return 1

  case $mode in
    run)
      "$MKRV_QEMU" "$out.elf"
      rc=$?
      print -u2 "[mkrv] exit code: $rc"
      if (( rc == 133 )); then
        print -u2 "[mkrv] (133 = hit an ebreak with no debugger attached," \
                   "which is expected -- use 'regs'/'all'/'debug' instead" \
                   "of 'run' to stop there and look around)"
      fi
      return $rc
      ;;
    stats)
      local log
      log=$(mktemp) || return 1
      "$MKRV_QEMU" -d nochain -singlestep -d exec -D "$log" "$out.elf" >/dev/null
      rc=$?
      print -u2 "[mkrv] instructions executed: $(grep -c Trace "$log")"
      print -u2 "[mkrv] exit code: $rc"
      rm -f "$log"
      return $rc
      ;;
    regs|all)
      setopt localoptions nomonitor nonotify
      local gport glog rlog qpid
      command -v "$MKRV_GDB" >/dev/null || { print -u2 "mkrv: $MKRV_GDB not found"; return 1 }
      gport=$(( 20000 + RANDOM % 10000 ))
      glog=$(mktemp); rlog=$(mktemp)
      timeout 20 "$MKRV_QEMU" -g "$gport" "$out.elf" >"$glog" 2>&1 &
      qpid=$!
      disown 2>/dev/null
      sleep 0.3
      timeout 10 "$MKRV_GDB" -q -nx \
        -ex "set architecture $MKRV_GDBARCH" \
        -ex "set pagination off" \
        -ex "set confirm off" \
        -ex "target remote :$gport" \
        -ex "continue" \
        -ex "info registers" \
        -ex "kill" -ex "quit" \
        "$out.elf" </dev/null >"$rlog" 2>&1
      kill -9 "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
      if ! grep -q SIGTRAP "$rlog"; then
        print -u2 "[mkrv] never hit an ebreak -- add one where you want to inspect registers"
      fi
      if [[ $mode == all ]]; then
        local log
        log=$(mktemp)
        "$MKRV_QEMU" -d nochain -singlestep -d exec -D "$log" "$out.elf" >/dev/null 2>&1
        print -u2 "[mkrv] instructions executed: $(grep -c Trace "$log")"
        rm -f "$log"
      fi
      sed -n '/^[a-z]/p' "$rlog" > "$rlog.filtered"
      _mkrv_report "$rlog.filtered"
      rm -f "$glog" "$rlog" "$rlog.filtered"
      ;;
    lst)
      "${MKRV_PREFIX}objdump" -d -M no-aliases "$out.elf"
      ;;
    map)
      cat "$out.map"
      ;;
    debug)
      setopt localoptions nomonitor nonotify
      print "Starting qemu as a gdbserver, then attaching gdb..."
      print "gdb cheatsheet: c=continue, si=step one instruction, i r=registers,"
      print "                b LABEL=breakpoint, q=quit"
      print "(the 'corrupt string table index' warning below is a harmless" \
            "qemu-user quirk -- ignore it)"
      local gport=$(( 20000 + RANDOM % 10000 ))
      "$MKRV_QEMU" -g "$gport" "$out.elf" &
      local qpid=$!
      disown 2>/dev/null
      sleep 0.3
      "$MKRV_GDB" -q -nx \
        -ex "set architecture $MKRV_GDBARCH" \
        -ex "set pagination off" \
        -ex "target remote :$gport" \
        "$out.elf"
      kill -9 "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
      ;;
  esac
}

_mkrv() {
  if (( CURRENT >= 3 )); then _files -g '*.(s|asm)'
  elif (( CURRENT == 2 )); then compadd run stats regs all asm lst map debug
  fi
}
command -v compdef >/dev/null && compdef _mkrv mkrv mkrv32 mkrv64

# ---------- fixed-width wrappers ----------
# mkrv32 / mkrv64 always target one width, regardless of the MKRV_* settings.
# The base ISA (extensions) can still be overridden per width, e.g.
#   export MKRV64_ARCH=rv64im   # allow mul/div in mkrv64 builds
mkrv32() {
  local MKRV_ARCH=${MKRV32_ARCH:-rv32i}
  local MKRV_ABI=ilp32
  local MKRV_QEMU=qemu-riscv32
  local MKRV_LDEMU=elf32lriscv
  local MKRV_GDBARCH=riscv:rv32
  mkrv "$@"
}

mkrv64() {
  local MKRV_ARCH=${MKRV64_ARCH:-rv64i}
  local MKRV_ABI=lp64
  local MKRV_QEMU=qemu-riscv64
  local MKRV_LDEMU=elf64lriscv
  local MKRV_GDBARCH=riscv:rv64
  mkrv "$@"
}