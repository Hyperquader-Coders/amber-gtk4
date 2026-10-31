# patches

Downstream fixes applied to the GTK tarball before `meson setup`. `make gtk` applies every
`*.patch` here with `patch -p1 -N` and stops the build if one fails, so a patch that no
longer applies to a new GTK is a build error rather than a bundle that silently ships
upstream's behaviour.

Each patch must carry, in its own header, what it fixes and how that was measured. Delete a
patch once upstream GTK has fixed what it works around.

## 0001: run X11 text-list conversion on the main thread

`GdkX11TextListConverter` converts a selection offered as `COMPOUND_TEXT`, `STRING` or
`TEXT` into UTF-8, and does it by calling into `GdkDisplay` and Xlib. Neither is safe off
the main thread.

`GConverterInputStream` and `GConverterOutputStream` implement no async read or write, so
GIO's `g_input_stream_real_read_async` falls back to running the synchronous one on a GTask
worker whenever the stream underneath cannot be polled. `GdkX11SelectionInputStream` is
driven by X events and is not a `GPollableInputStream`, so that fallback is taken every
time: the conversion runs on a worker thread on every such paste.

Measured on 2026-08-28:

- A standalone GIO harness wrapping a non-pollable base stream in a `GConverterInputStream`
  shows `convert()` on a worker thread; the same harness over a (pollable)
  `GMemoryInputStream` stays on the main thread. That is the exact difference between GDK's
  X11 selection stream and everything else.
- Instrumenting this converter and driving Ambrosia against an Xlib selection owner that
  offers `[TARGETS, COMPOUND_TEXT]` and refuses everything else: `convert` is entered on a
  worker thread on every read, three for three. `xclip` cannot produce this case (GDK
  negotiates its offers back to `UTF8_STRING`), which is why the owner is hand-written.

The symptom that prompted it: two `SIGSEGV`s in Ambrosia's `crash.log` (2026-08-19,
2026-08-26), both faulting in `_gdk_x11_display_text_property_to_utf8_list`
(`gdkselection-x11.c:197`) reached from `gdk_x11_text_list_converter_convert`, on a GTask
thread-pool worker. The fault is a string compare on `conv->encoding`, which the
constructor fills from a table of string literals, so the object read there is not the one
that was constructed.

The patch hops the conversion onto the default main context and waits for it, so everything
below the hop keeps GDK's usual single-thread guarantee. A caller that already owns the
main context skips the hop, which is the ordinary synchronous-read path and would otherwise
deadlock. The wait warns after ten seconds and then keeps waiting: the queued source still
points at the waiting frame's stack, so there is nothing safe to return early.

**Not verified against the original crash.** It is unreproducible on demand (the two
faults came 6.4 days and 38 minutes into their sessions), so what is demonstrated is that
the unsafe threading is gone, not that the specific fault cannot recur by another route.
