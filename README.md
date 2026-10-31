# amber-gtk4

One GTK 4.16 build shared by the [Amber Linux](https://amberlinux.org) applications,
installed to `/usr/lib/amber-gtk4` and reached only through those applications' RUNPATH.
amber-gtk4-dev carries its headers and pkg-config files, which the suite's Odin bindings are
generated from and build against.

## Why it exists

Linux Mint 22 ships GTK 4.14.5. kat800's terminal widget (VTE 0.84) needs the termprop
API and the X11 fixes that arrived in 4.16, so kat800 needs a newer GTK than the distro
has. The suite carries one build and every application points at it, so all of them render
through the same GTK.

## Install

From the suite's apt archive:

```sh
sudo curl -fsSL -o /usr/share/keyrings/amberlinux-archive-keyring.gpg \
  https://apt.amberlinux.org/amberlinux-archive-keyring.gpg

echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/amberlinux-archive-keyring.gpg] https://apt.amberlinux.org amber main' \
  | sudo tee /etc/apt/sources.list.d/amberlinux.list

sudo apt update
sudo apt install amber-gtk4
```

Applications that need it declare `Depends: amber-gtk4`, so installing one of them installs
this. To build and install the package yourself, see [Building](#building).

## What the packages contain

**amber-gtk4**, the runtime:

| path | what |
|---|---|
| `/usr/lib/amber-gtk4/libgtk-4.so.1` | the library, stripped |
| `/usr/lib/amber-gtk4/gtk-4.0/` | GTK's own module directory: a print backend, nothing else |
| `/usr/share/doc/amber-gtk4/` | copyright and changelog |

No binaries. Its `Depends` are the distro's own `libglib2.0-0t64`, `libpango-1.0-0`,
`libcairo2` and friends, computed by `dpkg-shlibdeps`.

**amber-gtk4-dev**, for building against the bundle:

| path | what |
|---|---|
| `/usr/lib/amber-gtk4/include/gtk-4.0/` | the GTK, GDK and GSK headers |
| `/usr/lib/amber-gtk4/pkgconfig/` | `gtk4.pc`, `gtk4-atspi.pc`, `gtk4-unix-print.pc`, `gtk4-wayland.pc`, `gtk4-x11.pc` |
| `/usr/lib/amber-gtk4/libgtk-4.so` | the link a linker looks for |

It depends on amber-gtk4 at the same version, and on the -dev packages of the libraries its
`.pc` files require (glib, pango, cairo, gdk-pixbuf, graphene, wayland, X11). The headers
and `.pc` files sit under `/usr/lib/amber-gtk4`, so they never meet Mint's `libgtk-4-dev`,
which can stay installed beside it.

`/usr/lib/amber-gtk4` is deliberately not on the `ldconfig` path. Only a binary whose
RUNPATH names that directory picks the bundle up, so installing it changes nothing for any
other program on the system: no `ldconfig` trigger, no shlibs file, no diversion.

## Two properties the build enforces

**It resolves against the distro's stock stack and nothing else.** 4.18 wants pango ≥ 1.56,
which wants glib ≥ 2.82; Mint has neither. Bundling GTK is cheap; bundling glib and pango
behind it is a different project. `scripts/check-no-cascade` passes only when every library
the bundle needs resolves to a file some dpkg package owns, which is the precise statement of
"stock": a hand-built glib in `/usr/local`, or a second bundle's directory on the path, is
owned by nothing and fails.

**It carries no path from the machine that built it.** GTK compiles its prefix in:
`GTK_LIBDIR`, `GTK_DATADIR`, `GTK_SYSCONFDIR` and the locale dir are string constants in the
shipped `.so`, and `strip` does not touch them. The build is therefore configured with
`--prefix=/usr --libdir=lib/amber-gtk4`, the paths the package installs under, and staged
through `DESTDIR`. `scripts/check-no-buildpaths` asserts the result on the staged bundle and
again on the packaged tree, so building a package is not a way around the check. Two paths
survive, `/home/jimmac/...` and `/home/sam/...`, baked into upstream's committed Adwaita
assets; they are in every GTK build including Mint's own and are reported, not failed on.

```
$ make check
no-cascade OK: 66 dependencies, all from distro packages
no-buildpaths OK: 2 objects and 5 text files, none from this build (2 upstream path(s) left in place)
```

`scripts/check-pc` asserts, in the packaged tree, that the `.pc` files' `libdir` and
`includedir` are inside the bundle.

Both run in `make ci` and in the GitHub workflow.

## Downstream patches

`make gtk` applies every `patches/*.patch` to the upstream tarball before `meson setup`, with
`patch -p1 -N`, and fails the build if one stops applying, so a patch that no longer fits a
new GTK is a build error rather than a bundle that silently ships upstream's behaviour. Each
patch carries its own header saying what it changes; [`patches/README.md`](patches/README.md)
carries the measurement behind it. A patch is deleted the moment upstream moves past it.

| patch | changes | status |
|---|---|---|
| [`0001-x11-run-text-list-conversion-on-the-main-thread`](patches/0001-x11-run-text-list-conversion-on-the-main-thread.patch) | `GdkX11TextListConverter` converts a `COMPOUND_TEXT` / `STRING` / `TEXT` selection to UTF-8 by calling into `GdkDisplay` and Xlib. GIO runs that conversion on a worker thread, because the X11 selection stream is not pollable and `GConverterInputStream` has no async read. The patch hops the conversion onto the main context. | Measured: the unsafe threading is gone. Not verified against the crash that prompted it, which is unreproducible on demand. Not upstream. |

The package is therefore not an unmodified upstream build; `debian/copyright` says so.

## Input methods: what every consumer must do

A bundle built for size has no input-method modules. Its `gtk-4.0` directory holds a print
backend, where Mint's holds `immodules/libim-ibus.so`. Unless GTK is told where the system's
modules are, IME input silently stops working, with no dialog and no error.

Every application linking this bundle calls this before `gtk_init`:

```odin
import gtkenv "amber:gtkenv"

gtkenv.use_system_modules()
```

It lives in amber-lib so that every application
runs the same code instead of its own copy. It sets `GTK_PATH`, which GTK *prepends* to its own search path, so the call
is additive and safe whether the application runs against the bundle or the distro's GTK.

## Consuming it

Build against amber-gtk4-dev's headers, and point the release RUNPATH at the bundle:

```sh
export PKG_CONFIG_PATH=/usr/lib/amber-gtk4/pkgconfig
cc app.c $(pkg-config --cflags --libs gtk4) \
  -Wl,--enable-new-dtags,-rpath,/usr/lib/amber-gtk4
```

An Odin program links the same way:

```make
odin build src/main -extra-linker-flags:"-Wl,-rpath,/usr/lib/amber-gtk4" -out:myapp
```

Depend on it:

```
Depends: amber-gtk4 (>= 4.16.13)
```

Check a shipped binary with `ldd`: `libgtk-4.so.1` resolves to
`/usr/lib/amber-gtk4/libgtk-4.so.1`.

## Building

Requires Linux Mint 22 or Ubuntu 24.04 (the `Depends` are computed against that stack).

| target | does |
|---|---|
| `make setup` | after a fresh clone: `init-packages`, `init-modules` and `init-workstation` |
| `make init-packages` | installs meson, ninja and GTK's build dependencies (sudo apt) |
| `make init-modules` | nothing: no language packages here (`ci` runs it, as in every repository) |
| `make init-workstation` | the git hooks |
| `make gtk` | fetches the release tarball into `build/`, verifies it against the sha256 GNOME publishes beside it, applies `patches/`, builds, stages under `build/gtk/stage`, strips (slow; once per version) |
| `make check` | the two assertions above, against the staged bundle; they run again only when the bundle or a check script changes |
| `make deb` | `dist/amber-gtk4_<version>-<revision>_amd64.deb` and `dist/amber-gtk4-dev_…`, made again only when the checked bundle or a packaging file changed; re-runs the build-path check on the packaged tree and checks the `.pc` files |
| `make deb-install` / `make deb-remove` | install or remove both packages locally; an up-to-date pair is installed as it is |
| `make deb-path` | the packages' absolute paths, one a line, for the apt archive's ingest |
| `make lint` | shfmt, shellcheck, the agent-file guard and the source checks (the changelog's one entry, the control templates), with no build |
| `make check-lintian` | lintian on both packages, after `make deb` |
| `make ci` | what the GitHub workflow runs: `init-modules`, `check`, `lint` and `check-lintian`; builds the bundle first when it is missing |

The build disables the non-application features (cups, colord, sysprof, gstreamer, vulkan,
cloud providers, introspection, documentation, demos and tests), which is what leaves it at
10 MB installed and a 3.1 MB package, and without input-method modules.

## Upgrading GTK

1. Set `VERSION` and `TARBALL_SHA256` in the `Makefile`; the sum is in the
   `gtk-<version>.sha256sum` file beside the tarball on download.gnome.org.
2. `make gtk && make check`. If the check fails, the new version has started a cascade, and
   the answer is to stay where you are, not to bundle more.
3. If a patch no longer applies, `make gtk` stops. Rebase it, or delete it if upstream has
   fixed the problem.
4. Bump the `Depends` floor in each consuming application.

## Contributing

Issues and pull requests are welcome on GitHub. Run `make hooks` once after cloning so the
shellcheck pre-commit hook is active, and `make ci` before opening a pull request. A new
patch needs, in its own header, what it fixes and how that was measured.

Suspected problems in the packaging, the patches or the checks belong in this
repository's issues. Problems in GTK itself belong upstream at
[gitlab.gnome.org/GNOME/gtk](https://gitlab.gnome.org/GNOME/gtk/-/issues); if one affects
the suite before upstream ships a fix, it may be carried here as a patch in the meantime.

## Licence

The packaging in this repository (Makefile, scripts, Debian metadata, patches) is
Copyright © 2025 Andre Bremer <hyperquader@gmail.com>, https://hyperquader.com, under LGPL-2.1-or-later, the same licence as the software
it packages. GTK is Copyright © The GTK Team and contributors under the same licence; this
repository ships no GTK source, and `make gtk` fetches the upstream release tarball.
[`LICENSE`](LICENSE) is the licence text verbatim; `packaging/debian/copyright` is the
machine-readable statement that ships in the package.
