# tang-arm-docker

A statically-linked, from-scratch [tang](https://github.com/latchset/tang)
(NBDE key server) image for `arm64`, built to run under MikroTik RouterOS's
container feature.

Image: `ghcr.io/zumoshi/tang-arm-docker:arm64` (public)

## Quick start (RouterOS)

RouterOS's container feature has no external disk on boards like the hAP ax²
(check with `/disk print` — if it's empty, there's no `diskN/` to reference).
On those boards, plain relative paths resolve against the router's own
internal flash instead:

```
/container/mounts/add list=tang-db src=containers/tang-db dst=/db
/container/add remote-image=ghcr.io/zumoshi/tang-arm-docker:arm64 \
    interface=veth1 root-dir=containers/tang mountlists=tang-db \
    logging=yes start-on-boot=yes
/container/start [find remote-image~"tang-arm-docker"]
```

Omitting `root-dir` puts the container store in RAM, not flash, it won't
survive a reboot. `logging=yes` routes stdout/stderr into `/log print`, in
addition to `/container/log/print`, which keeps the last 100 lines
per-container regardless of that setting (RouterOS 7.20+).

Tang generates its own signing (ES512) and exchange (ECMR) keys on first
start if the key directory is empty — no separate init step needed. Check
it's up:

```
curl http://<router-ip>:9090/adv
```

## Build layout

- `Containerfile.deps` → `ghcr.io/zumoshi/tang-arm-docker-deps:arm64`.
  Everything slow to rebuild: a source-built OpenSSL, jansson, zlib,
  http_parser, and jose, as static libs under `/opt/staticlibs`. Only
  rebuilds (`build-deps.yml`) when this file changes, roughly 30 minutes
  under QEMU emulation, OpenSSL is most of that.
- `Containerfile` → `ghcr.io/zumoshi/tang-arm-docker:arm64`. `FROM`s the
  deps image, builds tang against it, copies the stripped static binary
  into a `scratch` final stage. Rebuilds (`build.yml`) on its own changes,
  a couple of minutes, no OpenSSL recompile.

Split this way because iterating on tang/entrypoint/link-flag issues is
common; iterating on the OpenSSL/jose dependency chain is rare. Don't fold
them back into one file without expecting every iteration to cost 30
minutes.

Both build with `podman build --platform linux/arm64` on a plain
`ubuntu-latest` runner via `docker/setup-qemu-action`, genuine native ARM
compilation isn't available cheaply in CI, so this builds by running actual
Alpine `aarch64` binaries under user-mode emulation, slow but simple, no
cross-toolchain to maintain.

`build.yml` runs a smoke test before pushing: starts the freshly built
image with a throwaway `/db`, and requires `GET /adv` to return 200 within
20s. This exists because the failure mode below only showed up at runtime,
not at build time.

## Why this needed four separate fixes

Getting a statically-linked tang binary that actually works, rather than
one that just compiles, took working through four unrelated problems.

**1. No systemd, no `socat` — use tang's standalone mode.**
Tang's normal deployment model assumes systemd socket activation
(`Accept=true`, `StandardInput=socket`), a new `tangd` process spawned per
connection with the socket handed to it as stdin. Distro packages lean on
`socat` to replicate that outside systemd. Neither exists in a RouterOS
container. Tang has its own self-contained listener (`tangd -l`), own
`getaddrinfo`/accept loop, own fork-per-connection, own `SIGCHLD` handling,
documented as the path OpenWrt uses. No systemd, no socat, no wrapper
needed. Also no separate `tangd-keygen` step: `tangd` generates its own
ES512/ECMR keys on first start if the key directory is empty.

**2. `musl.cc` is unreliable.** True cross-compilation with a prebuilt
`aarch64-linux-musl-cross` toolchain was the original plan. `musl.cc`
timed out completely from GitHub's runners, it's had ongoing hosting
problems. Switched to QEMU-emulated native `arm64` Alpine builds instead:
slower, but depends only on Alpine's own CDN.

**3. Static linking fights pkg-config's `.so` preference.** jose's
`meson.build` always builds a shared library regardless of
`--default-library`, so its `.so` got archived by hand from the already-
compiled `.o` files instead. Separately, meson's pkg-config resolution
kept resolving to absolute `.so` paths even with `libcrypto.a`/`libjansson.a`
sitting right next to them, and jose's real `.pc` only lists
`-lcrypto -lssl -lz` under a `--static` pkg-config query, which tang's
plain `dependency('jose', ...)` call never makes. Fixed with a private
`/opt/staticlibs` directory containing only `.a` files plus a hand-written
`jose.pc` listing every needed static lib unconditionally, rather than
deleting the system's own `.so` files (tried that first: it broke `curl`
and Python/meson themselves, both dynamically linked against
libz/libssl/libcrypto in the builder image).

**4. The real bug: jose's own algorithm registry gets dropped.**
The build succeeded and pushed, but every `/adv` request on the router
failed with `Error generating JWK with alg ES512`. Long chase:

- First guess: OpenSSL 3's providers normally load as `dlopen()`-able
  modules, impossible in a fully `-static` binary with no dynamic linker.
  Rebuilt OpenSSL from source with `no-shared` (providers compiled
  directly into `libcrypto.a`). Same failure. Wrong theory.
- A/B test: extracted the exact same static `tangd` binary, rebuilt it
  into an Alpine-based image instead of `scratch` (full filesystem,
  `/dev`, `/proc`, everything). Still failed identically. Ruled out the
  `scratch` environment; the bug was in the binary itself.
- Ran OpenSSL's own CLI and jose's own CLI directly (both dynamically
  linked overall, both built against the exact same static-built OpenSSL
  code): both generated valid ES512/P-521 keys with no issue. Ruled out
  OpenSSL and jose's crypto code as broken.
- Added an explicit `OSSL_PROVIDER_load(NULL, "default")` shim, force-
  included via `--whole-archive` so its constructor couldn't be dropped.
  Debug output confirmed it ran and returned a valid, non-null provider.
  Key generation still failed afterward. OpenSSL's provider system was
  never the problem.
- Actual cause: jose has its own internal hook-based algorithm registry
  (`jose_hook_alg_find`), separate from OpenSSL's provider system
  entirely. Each algorithm implementation self-registers into it, and
  hits the same static-linking gotcha, a normal static link only pulls
  in the `.o` files needed to resolve symbols something else references;
  if a translation unit's only visible effect is a self-registration
  call with no other externally-referenced symbol, the linker can drop
  it silently. (jose's own changelog has a prior instance of this exact
  class of bug for a different algorithm.) Fixed by wrapping just
  `-ljose` in `--whole-archive`, small, unlike the full OpenSSL static
  libs, everything else keeps normal dead-code elimination.

Whole-archiving `-ljose` does pull in every algorithm jose implements
(RSA-OAEP, AES-KW, HMAC, compression, not just EC), each dragging in real,
legitimate OpenSSL references of its own, which is why the final binary
is ~4.35MB rather than the ~280KB a version linking only EC support would
be. The fully surgical fix would isolate jose's EC-specific object file
into its own tiny archive and whole-archive only that. Not done here:
each attempt at this class of fix costs a ~30 minute OpenSSL rebuild to
test, and 4.35MB is not a meaningful cost on a home router.

## RouterOS gotchas hit along the way

- `/container/mounts/add` uses `list=`, not `name=`, in current RouterOS.
  Some older docs/forum posts show `name=`.
- `root-dir=`/`src=` use `diskN/path` only when an actual external disk
  exists. With none (`/disk print` empty), use a plain relative path
  instead, it resolves against internal flash. Omitting `root-dir`
  entirely defaults to RAM, not flash.
- `/container/log/print` keeps a 100-line-per-container ring buffer in
  RAM by default (RouterOS 7.20+), independent of `logging=yes`, which
  is what's needed instead to reach `/log print`, RouterOS's general
  system log.
