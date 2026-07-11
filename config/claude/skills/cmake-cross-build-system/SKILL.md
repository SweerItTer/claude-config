---
name: cmake-cross-build-system
description: Create, migrate, or standardize a C/C++ CMake build system with optional Linux cross-compilation, safe YAML configuration, wrappers, install rules, and verified output under out/. Use only for build-system work.
---

# CMake Cross Build System

Create the smallest reproducible CMake build that preserves existing behavior and produces verifiable artifacts.

## Scope

**In scope:** CMake creation/migration, native or Linux cross-builds, toolchain files, platform wrappers, restricted YAML config, install rules, and `out/` layout.

**Out of scope:** application redesign, unrelated refactoring, deployment, packaging, release, flashing, git-history cleanup, or dependency replacement without approval.

Source edits are allowed only when strictly required to preserve the build; report each edit and reason.

## Mandatory rules

1. Inspect before editing; never infer the old build from filenames alone.
2. Preserve targets, sources, generated files, macros, includes, standards, compile/link flags, link order, ABI flags, assets, and install layout unless change is requested.
3. Preserve working CMake where practical; do not rewrite wholesale.
4. Prefer target-scoped CMake. Do not guess platforms, SDKs, dependencies, paths, or ABI settings.
5. Never commit machine-specific paths or secrets.
6. Keep build products, generated files, caches, and logs under `out/`. Only root `compile_commands.json` may exist outside it.
7. Never parse config with `eval` or `source`.
8. Build success alone is insufficient: verify compiler, target ELF/ABI, dependencies, and install tree.
9. Never hide failures by disabling targets/tests, removing inherited flags, suppressing diagnostics, adding stubs, or changing runtime behavior.

## Workflow

### Audit

Inspect relevant CMake, Make, GN, shell, generator, SDK, and install inputs. Write `out/.audit-baseline.txt` with:

- targets, types, sources, and generated files
- includes, macros, standards, optimization, CPU/FPU/ABI flags
- linker options, dependency origins, order/groups
- runtime assets, install destinations, original command, expected artifacts

Run the original build when safe. First check for `sudo`, system installation, downloads, deployment, flashing, uploads, or deletion outside the project. Run only separable safe build steps.

Skip baseline execution only for a missing toolchain/SDK, unavailable build system, unsafe inseparable side effects, or explicit user waiver. Record the reason.

### Implement

Create only files needed by the actual project. A typical layout is:

```text
CMakeLists.txt
cmake/toolchain.cmake
scripts/common/build.sh
scripts/build_<platform>.sh
building-config.template.yaml
building-config-<platform>.template.yaml
out/
```

Do **not** copy `yaml_parse.py` into the project. Use the parser bundled at `<skill-root>/scripts/yaml_parse.py`, resolved from the installed skill package. Pass its resolved path through the standard skill runtime or an explicit argument/environment variable; never commit that host path.

### Verify

Run the intended wrapper, compare with the baseline, fix build-system-introduced differences, and rerun the same command.

## CMake contract

- Enable only languages actually used; preserve existing standards.
- Use explicit source lists; no recursive globs.
- Use target-scoped includes, definitions, compile/link options, and correct visibility.
- Use `add_custom_command(OUTPUT ...)` for generated files.
- Add install rules for requested binaries, libraries, headers, configs, modules, and assets.
- Preserve existing RPATH unless it leaks host paths. New RPATH must be target-relative when needed; never embed build-tree or host SDK paths.

## Dependency contract

Determine each dependency's actual origin; do not assume it is prebuilt.

- installed/sysroot package: `find_package` or `find_library`
- source in tree: `add_subdirectory`
- generated dependency: custom command plus explicit target dependency
- external/prebuilt artifact: imported target
- existing project mechanism: preserve unless it prevents a correct reproducible build

Do not introduce network fetching without existing project precedent or user approval.

For cross-build **prebuilt** artifacts only, verify architecture and ABI before linking. For ARM archives, inspect at least one member with the target `ar` and `readelf -A`.

## Platform and toolchain contract

Use lowercase platform IDs matching `[a-z][a-z0-9_.-]*`. Define supported platforms once, or verify shell and CMake copies are identical.

Use `cmake/toolchain.cmake` only for cross builds. It must:

- set Linux system name and requested processor
- prefer explicit compiler paths; otherwise resolve root + triple
- resolve and validate tools before assigning them
- require C++ only when CXX is enabled
- validate `ar`/`ranlib` when supplied; require them only when compatible tools cannot be derived
- set sysroot only when non-empty and existing
- use root-path modes: programs `NEVER`, libraries/includes/packages `ONLY`

Use `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY` only when target link checks cannot run; comment and report the exact reason.

For native builds, derive effective architecture from the compiler/host and reject conflicting config.

## Restricted YAML contract

```yaml
platform: <platform-id>
arch: <arch>              # required for cross builds
build_type: Release       # Release|Debug|RelWithDebInfo|MinSizeRel
generator: ninja          # ninja|make|auto

toolchain:                # omit for native builds
  root: ""
  triple: ""
  cc: ""
  cxx: ""
  ar: ""
  ranlib: ""
  sysroot: ""

paths:                    # optional; project-declared allowlist only
  <declared_name>: ""
```

Rules:

- `platform` must be supported.
- native `arch` may be derived; cross build requires it.
- absent build type/generator defaults to `Release`/`ninja`.
- presence of `toolchain` means cross build; require `cc` or both `root` and `triple`.
- `paths` accepts only project-declared names such as SDK or dependency roots.
- reject duplicate/unknown keys, tabs, anchors, tags, multiline values, malformed quoting, and deeper nesting.
- parser output is NUL-delimited key/value pairs.

Execute the bundled parser separately and check its status before consuming output. Do not rely on process-substitution error propagation.

## Build wrapper contract

`scripts/common/build.sh` must:

1. use `set -euo pipefail`; require and canonicalize `--config`
2. locate/validate the bundled parser without copying it
3. parse to a temporary file under `out/`, then validate every key/value and resolved tool
4. resolve Ninja/Make and fingerprint the **resolved** generator
5. build in `out/<platform>-<arch>/<build-type-lowercase>/`
6. purge only a path proven to be inside `out/` when the fingerprint changes
7. configure, build, install, and refresh root `compile_commands.json`

Fingerprint every CMake-affecting input: resolved generator, platform, effective architecture, build type, tools, root/triple, sysroot, project path values, and toolchain-file hash.

Platform wrappers contain no build logic. They select a default local config or forward explicit arguments.

## Verification contract

Summarize repeated identical results; do not flood context.

- **Build:** configure, compile, link, and install succeed; generator/compiler match config.
- **Compile commands:** inspect three representative entries, or all if fewer. Confirm required macros/includes/CPU/FPU/ABI flags and no unintended host paths in cross builds.
- **Artifacts:** fully inspect every installed executable/shared library and critical runtime artifact using `file` and applicable `readelf -h/-l/-A/-d`. Batch-screen other artifacts and expand anomalies only. Inspect one representative member per static-archive ABI/toolchain group.
- **Install:** confirm expected binaries, libraries, headers, configs, modules, and assets.
- **Migration:** compare against `out/.audit-baseline.txt`; report intentional divergences.

Skip a check only when inapplicable or blocked by the first external obstacle; state why.

## Failure and final response

Fix build-system-introduced errors and rerun. For an external blocker, stop at the first unresolved item and report the missing item, setting/file required, and one concrete next action. Do not accumulate speculation.

```text
Command:        <exact command>
Result:         PASS | FAIL at <configure|compile|link|install|verify>
Build dir:      <relative path>
Install dir:    <relative path>
Compiler:       <resolved compiler>
Target:         <arch> <endianness> <word size> <ABI>
Files:          <created/modified paths>
Source edits:   <file and reason>
Divergences:    <intentional baseline differences>
Exceptions:     <exception and reason>
Skipped checks: <check and reason>
Blocker:        <missing item | setting | single next action>
```
