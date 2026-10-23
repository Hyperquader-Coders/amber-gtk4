# Decisions: amber-gtk4

What was weighed and settled, with the reasons that make each choice hold. An entry that stops
being true is rewritten, not appended to.

1. **Two packages from one build: amber-gtk4 and amber-gtk4-dev.** The runtime package holds
   what a running app loads: the library, its soname link and the print backend. The -dev
   package holds the headers, the unversioned `.so` link and the `.pc` files, all under
   `/usr/lib/amber-gtk4` (`include/`, `pkgconfig/`), so they never meet Mint's
   `libgtk-4-dev`. The headers ship because the suite's Odin bindings, odin-gtk4 and the
   bindings built on it, are generated from this bundle's 4.16 headers and build and test
   against the published archive, as amber-webkit-dev, amber-libgit2-dev and amber-llhttp-dev
   serve theirs. The stage keeps meson's layout, the headers in `usr/include`, which the
   bindings' generators and amber-glycin's build read; `make deb` copies them under
   `/usr/lib/amber-gtk4/include` and rewrites the packaged `.pc` files' `includedir` to match,
   and `scripts/check-pc` checks `libdir` and `includedir` in the package. The -dev package
   depends on amber-gtk4 at its own version and on the -dev packages of the libraries the
   `.pc` files require (glib, pango, cairo, gdk-pixbuf, graphene, wayland, X11), since
   pkg-config reads their `.pc` files.
