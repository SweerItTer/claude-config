# Binary-Level & Memory-Corruption Forensics

Use when the evidence is a crash on an embedded/cross-compiled target: SIGSEGV with
register dumps (`epc`/`ra` on MIPS, `pc`/`lr` on ARM), memory corruption suspected
(buffer overflow, poisoned globals), or a protocol frame believed to be the trigger.
This reference extends the main workflow with binary-level techniques. The evidence
grading of the main SKILL.md applies unchanged: a hexdump is **Verified**, an offset
table from DWARF is **Verified** (for that toolchain), "this global caused this crash"
stays **Inference** until an intervention test.

Real case used as running example: MIPS32 indoor-intercom firmware, remote 60-byte
Ethernet frame triggers `strncpy` overflow of a 32-byte global; process later SIGSEGVs
in an unrelated function (issue #117 of project `sip/sip_app`).

## 0. The one rule that burns people: layout authority

**Struct layout, sizeof, and offsets MUST come from the target toolchain. Never from
the host compiler.** A pointer is 8 bytes on host x86-64 and 4 bytes on MIPS32 o32;
every offset after the first pointer diverges, and the overflow analysis built on host
layout is confidently wrong. In the running example, host-layout offsets were off by
up to +72 bytes and sizeof by +32 — the entire "which globals got hit" table was wrong
until re-measured.

The authoritative source is DWARF emitted by the *product* cross compiler at the
*product* optimization level, compiled against the *exact tag's* headers. You never
need to run the target binary to get layout — compile an offsetof probe (§3).

## 1. Capture raw bytes before they lie to you

Log viewers and terminals hide non-printable bytes; those bytes are often the
evidence. Before interpreting a suspicious log line:

```bash
sed -n '51p' crash.log | od -c        # exact bytes incl. \002, \r, stray NULs
xxd poison_frame.bin                  # full frame, field by field
```

In the running example the log showed 36 `A`s then "garbage"; `od -c` revealed the
37th copied byte was `\002` — not part of the frame, proof of a source-side over-read
(`strncpy` ran past the 60-byte frame into receive-stack residue because the frame had
no NUL terminator).

For protocol frames, build a field table and mark the attack surface explicitly:
declared length (in-frame byte claiming 255) vs actual carried bytes (36). The delta
*is* the bug's entry point.

## 2. Version-exact rebuild for symbolization

Field firmware is usually stripped; you symbolize against a local rebuild. Declare
drift, don't hide it:

```bash
git worktree add /tmp/field_tag <TAG>          # exact field version
# rebuild with the product's release config (is_debug=false, same product args)
readelf -S out/rel/prog | grep .text           # compare size against field crash logs
```

If rebuilt `.text` size ≠ field-logged text size (e.g. 0x7282c0 vs 0x729000), state
the drift (0xd40 here) and treat symbolization as function-boundary-accurate, not
instruction-exact. Function-level attribution survives small drift; instruction-level
claims need the field ELF.

## 3. offsetof probe with the cross toolchain

Compile a probe against the *real headers from the tag*; the compiler is the layout
oracle.

```bash
# extract the tag's headers (iterate: each fatal error names the next header)
git show <TAG>:src/public/com/sub_lpd.h > /tmp/probe/sub_lpd.h
git show <TAG>:src/includes/shsm_utils.h > /tmp/probe/shsm_utils.h
# ... repeat until the include chain closes

# product cross compiler, product flags
mips-linux-gnu-gcc -mips32r2 -EL -g -O2 -c probe.c -o probe.o -I.
```

Read results two ways — they must agree:

```bash
mips-linux-gnu-readelf --debug-dump=info probe.o   # DWARF member locations
mips-linux-gnu-objdump -dr probe.o                 # -O2 folds offsetof to li imm
```

At `-O2` DWARF may drop unreferenced struct detail, but the disassembly's immediate
operands are the folded offsetof/sizeof values the compiler actually committed to
(`li a1,232` = sizeof 232; `li a1,192` = victim offset). Private structs not in any
header (file-static context types) get a mirror header copied line-by-line from
`git show <TAG>:...c` — with pointer-sized members replaced by any pointer type,
which preserves layout.

**Cross-check layout against observed corruption before publishing.** If the log
shows a field holding `0x41414141`, that field's offset minus the victim buffer's
offset must equal the position of the `A` run that hit it (setup_no at victim+32).
If the arithmetic fails, your layout is wrong — stop and re-derive, do not publish.

## 4. Symbolize the crash registers

```bash
mips-linux-gnu-nm -S --size-sort --radix=x prog.elf | sort > syms.txt
# find function containing epc=0x4b4e70:
awk '$1 <= "4b4e70" {f=$0} END{print f}' <(sort syms.txt)
mips-linux-gnu-objdump -d --start-address=0x4b4e50 --stop-address=0x4b4ea0 prog.elf
```

Map `epc` (faulting instruction) and `ra` (caller context) to symbol+offset, then to
`file:line` via the rebuild. Two lists matter as much as the crash site:

- **who calls the crashing function** (`objdump -d | grep` for `jal <symbol>`):
  if none of the callers is on the culprit's code path, the crash point is a victim,
  not the culprit;
- **what the faulting instruction actually did**: `lw a3,0(v1)` = dereference of a
  poisoned pointer/base — name the register semantics, not just "it crashed".

Crash address regions narrow the mechanism: address outside ELF mapping and .bss but
inside heap range → a corrupted pointer drove a scan into an unmapped hole.

## 5. The global-corruption signature

When a buffer overflow hits `.bss`/`.data` (not the stack), the signature is:
**crashing code has no call relationship with the code that corrupted memory.**
Stack overwrites return addresses (crash near the culprit); global overwrites make
unrelated code dereference garbage later. If `epc` lands in a function whose callers
never include the suspect subsystem, that is *evidence for* global corruption, not a
reason to chase a different bug.

State the triggering as probabilistic unless shown otherwise: the write is
deterministic (every poison frame overflows), the crash depends on which victim field
is later used as pointer/bound — this explains "1764 corruptions survived in one run,
crash at +13s in another".

## 6. Exact write accounting

Name the libc semantics precisely; "copies n bytes" is wrong for `strncpy`:

- `strncpy(dst, src_without_NUL, 255)`: source-side over-read first (runs past src
  until a NUL), then copies, then **zero-pads the remainder of 255** — plus caller's
  `dst[255]=0` → total 256 bytes written against a 32-byte buffer = 224 overflowed.
- Zero-fill means distant victims are *silently cleared*, not filled with `A` —
  less visible in logs, equally lethal (NULL-pointer derefs later).
- Publish the byte-range table: which ranges are visible pollution (`A`s), which are
  zero-fill, which land inside the struct, which escape it into neighbors.

## 7. Evidence grading for binary claims

| Claim | Label |
|---|---|
| Frame bytes, `od -c` output, hexdump | Verified |
| offsetof/sizeof from target-toolchain DWARF/disasm | Verified (for that toolchain+flags) |
| Which neighbor globals the overflow reaches | Verified only with nm/symbols of the *field* ELF; else Inference |
| Symbolization from a drifted rebuild | Verified at function granularity; note drift |
| "Corrupted global X caused the SIGSEGV at Y" | Inference until an intervention (patch → no crash) confirms |

When the supporting artifact no longer exists (deleted worktree, lost ELF), downgrade
the claim in writing rather than letting it ride on its old label.

## 8. What made the original analysis wrong (keep as lesson)

The first published report computed the struct layout with host `gcc` on x86-64 and
presented it as fact for a MIPS32 target, and the hexdump included 20 zero bytes of
"padding" that were never in the 60-byte frame (they were invented to reach minimum
Ethernet frame length). Both errors share one root: numbers were *constructed to look
plausible* instead of *measured from the artifact*. The corrections — cross-toolchain
DWARF probe, `od -c` on the actual log line, victim+32 consistency check against the
observed `0x41414141` — are the procedures in §1 and §3.
