# amber-gtk4: one GTK4 build for the whole amber suite.
#
# `make gtk` builds it, `make deb` packages it to /usr/lib/amber-gtk4, and the apps
# point their RUNPATH there. See README.md for why it exists at all.
VERSION = 4.16.13
# The package revision, bumped when the packaging changes but the GTK version does not.
REVISION = 1
DEB = dist/amber-gtk4_$(VERSION)-$(REVISION)_amd64.deb
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-gtk4

# targets: no test (upstream GTK, built with its test suite off; check asserts the bundle's two shipping properties)

# Where the build lands, and where the deb installs it. Apps hardcode INSTALL_DIR in
# their release RUNPATH, so it is part of the contract with them.
#
# Configured with /usr and staged through DESTDIR: GTK compiles its prefix into the
# shipped .so, so a build-tree prefix would ship the builder's home directory.
# libdir=lib/amber-gtk4 lands the library where INSTALL_DIR expects it. `make check`
# asserts it.
INSTALL_DIR = /usr/lib/amber-gtk4
CONF_PREFIX = /usr
CONF_LIBDIR = lib/amber-gtk4
STAGE = build/gtk/stage
BUNDLE = $(STAGE)$(INSTALL_DIR)
# The release tarball, verified against the sum GNOME publishes beside it
# (download.gnome.org/sources/gtk/<major.minor>/gtk-<version>.sha256sum). A fetched
# archive that does not match is deleted, so a wrong VERSION bump fails here and not
# after a 20-minute build. Lives under build/, not /tmp: /tmp is shared and predictable.
TARBALL = build/gtk-$(VERSION).tar.xz
TARBALL_SHA256 = ddf3d9e12b848139a945d191d5ca56b78d0647f53b55b8bca5f9902b61624498
TARBALL_URL = https://download.gnome.org/sources/gtk/$(basename $(VERSION))/gtk-$(VERSION).tar.xz

.PHONY: deps help gtk build stage built check ci deb deb-path deb-install deb-remove clean push force-push lint hooks check-no-agent-files

deps: hooks ## install the build dependencies and git hooks
	sudo apt install meson ninja-build gperf sassc shellcheck \
		libglib2.0-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
		libgraphene-1.0-dev libepoxy-dev libxkbcommon-dev libwayland-dev \
		libx11-dev libxi-dev libxcursor-dev libxdamage-dev libxinerama-dev \
		libxrandr-dev libxext-dev libxfixes-dev libcairo-script-interpreter2 \
		libjpeg-dev libtiff-dev libharfbuzz-dev libfribidi-dev libdrm-dev

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(TARBALL):
	@echo "fetching gtk $(VERSION)"
	mkdir -p build
	curl -fL -o $(TARBALL).part $(TARBALL_URL)
	@echo "$(TARBALL_SHA256)  $(TARBALL).part" | sha256sum -c - || { rm -f $(TARBALL).part; exit 1; }
	mv $(TARBALL).part $(TARBALL)

# Build GTK $(VERSION) for bundling. Mint ships 4.14.5, whose X11 clipboard-serialize
# and stale-snapshot bugs are fixed in 4.16.
#
# 4.16 and NOT 4.18: 4.18 wants pango >= 1.56, which wants glib >= 2.82, neither of
# which Mint has, and bundling those too is the cascade this approach exists to avoid.
# `make check` enforces it.
#
# Non-app features (cups, colord, sysprof, gstreamer, vulkan) are off to keep the bundle
# lean. This leaves the prefix with no input-method modules, which is why every
# app must call kat:gtkenv's use_system_modules before gtk_init.
gtk: $(TARBALL) ## fetch, patch and build GTK into build/gtk/stage (~20 min)
	rm -rf build/gtk
	mkdir -p build/gtk
	tar xf $(TARBALL) -C build/gtk --strip-components=1
	# patches/ carries the downstream fixes. The extract above is unconditional, so a
	# patch that stops applying is a hard failure here rather than a bundle that quietly
	# ships upstream's behaviour: -N makes reapplication a no-op, not an error, and the
	# exit status is checked. See patches/README.md for what each one is for.
	@for p in patches/*.patch; do \
		test -e "$$p" || continue; \
		echo "applying $$p"; \
		patch -p1 -N -d build/gtk --input="$(CURDIR)/$$p" || exit 1; \
	done
	meson setup build/gtk/_build build/gtk --prefix=$(CONF_PREFIX) \
		--libdir=$(CONF_LIBDIR) -Dintrospection=disabled -Ddocumentation=false -Dman-pages=false \
		-Dbuild-demos=false -Dbuild-testsuite=false -Dbuild-examples=false -Dbuild-tests=false \
		-Dmedia-gstreamer=disabled -Dvulkan=disabled -Dprint-cups=disabled \
		-Dcolord=disabled -Dsysprof=disabled -Dcloudproviders=disabled
	DESTDIR=$$(pwd)/$(STAGE) ninja -C build/gtk/_build install
	# Strip in place, so `make check` sees exactly what `make deb` will ship. Debug info
	# is 30 MB of the 40, and its DW_AT_comp_dir names the build directory, the one
	# build path that a correct --prefix does not already remove.
	find $(BUNDLE) -type f -name '*.so*' -exec strip --strip-unneeded {} +

# The standard name for the build; the one build there is.
build: gtk ## the same as gtk

built: stage
	@test -e $(BUNDLE)/libgtk-4.so.1 || \
		{ echo "no bundle at $(BUNDLE) — run 'make gtk'"; exit 1; }

# Re-stage whenever the meson build tree is newer than the staged bundle.
#
# `deb` packages $(BUNDLE), which only `ninja install` writes. Building the library on its
# own (`ninja -C build/gtk/_build gtk/libgtk-4.so.1...`, which is what you do while
# iterating on a patch) updates the build tree and leaves the stage untouched, so without
# this the deb ships the previous library without any error. ninja install is a no-op
# when the tree is already staged, so this costs nothing on a normal build.
stage:
	@test -d build/gtk/_build || exit 0; \
	built=build/gtk/_build/gtk/libgtk-4.so.1.1600.13; \
	staged=$(BUNDLE)/libgtk-4.so.1.1600.13; \
	if [ -e "$$built" ] && { [ ! -e "$$staged" ] || [ "$$built" -nt "$$staged" ]; }; then \
		echo "re-staging: $$built is newer than the staged bundle"; \
		DESTDIR=$$(pwd)/$(STAGE) ninja -C build/gtk/_build install >/dev/null || exit 1; \
		find $(BUNDLE) -type f -name '*.so*' -exec strip --strip-unneeded {} + ; \
	fi

# Two properties make this bundle safe to ship, and the scripts below enforce both:
#   1. it resolves against the distro's stock glib/pango/cairo and pulls nothing else in
#   2. it carries no path from the machine that built it
check: built ## the bundle pulls in no newer stack and carries no build paths
	@scripts/check-no-cascade $(BUNDLE)/libgtk-4.so.1
	@scripts/check-no-buildpaths $(BUNDLE)

ci: check lint deb ## everything a push must pass
	@echo "CI OK — bundle resolves against the stock stack, carries no build paths, and packages"

# Binary .deb. Ships the shared object and the module directory only: no headers, no
# pkg-config, no binaries. This is a runtime bundle for the amber apps, not a -dev
# package, and anything building against GTK uses the distro's libgtk-4-dev.
deb: check ## package the bundle into dist/
	rm -rf build/deb build/shlibwork
	install -d build/deb$(INSTALL_DIR)
	# Copy the real file and re-create the SONAME symlink, rather than copying a
	# dangling link into the package.
	install -D -m644 $$(readlink -f $(BUNDLE)/libgtk-4.so.1) \
		build/deb$(INSTALL_DIR)/$$(basename $$(readlink -f $(BUNDLE)/libgtk-4.so.1))
	ln -sf $$(basename $$(readlink -f $(BUNDLE)/libgtk-4.so.1)) \
		build/deb$(INSTALL_DIR)/libgtk-4.so.1
	# The bundle's own module dir (print backend). The apps get input methods from the
	# distro's directory instead (see kat:gtkenv).
	cp -a $(BUNDLE)/gtk-4.0 build/deb$(INSTALL_DIR)/gtk-4.0
	# Assert on what is actually packaged, not only on what was staged: `make deb` must
	# not be a way around `make check`.
	@scripts/check-no-buildpaths build/deb
	install -D -m644 packaging/lintian-overrides build/deb/usr/share/lintian/overrides/amber-gtk4
	install -D -m644 packaging/debian/copyright build/deb/usr/share/doc/amber-gtk4/copyright
	gzip -9n < packaging/debian/changelog > build/deb/usr/share/doc/amber-gtk4/changelog.Debian.gz
	chmod 644 build/deb/usr/share/doc/amber-gtk4/changelog.Debian.gz
	mkdir -p build/deb/DEBIAN
	# The bundle is deliberately NOT on the ldconfig path: only a binary whose RUNPATH
	# names $(INSTALL_DIR) picks it up, so installing this cannot change what any other
	# program on the system links against.
	cd build/deb && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-gtk4\n\nPackage: amber-gtk4\nArchitecture: amd64\n' > build/shlibwork/debian/control
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info \
		../deb$(INSTALL_DIR)/libgtk-4.so.1 > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e "s/@SIZE@/$$(du -sk build/deb --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed 's/^shlibs:Depends=//' build/shlibwork/deps.txt)|" \
		packaging/control.in > build/deb/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group build/deb $(DEB)

# Where `make deb` puts the package: one absolute path, nothing else.
# amberlinux-apt ingests it through this.
deb-path: ## print the absolute path of the .deb
	@echo "$(CURDIR)/$(DEB)"

deb-install: deb ## build and install the .deb (sudo)
	# --allow-downgrades: once the package is published, the archive
	# carries the same version at a higher pin priority than a local
	# file, so apt reads installing your own build as a downgrade and
	# refuses.
	sudo apt install --reinstall --allow-downgrades ./$(DEB)

deb-remove: ## remove the installed package (sudo)
	sudo apt remove amber-gtk4

clean: ## remove the deb staging and dist/ (keeps the GTK build)
	rm -rf build/deb build/shlibwork dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: check check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	git branch -M "$$tmp_branch" "$(BRANCH)"; \
	git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."

lint: deb check-no-agent-files ## shellcheck, lintian, hooks installed, agent-file guard
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed — run 'make hooks'"
	@if command -v lintian >/dev/null; then lintian --no-tag-display-limit -L '>=pedantic' $(DEB); \
	else echo "lintian not installed — skipping (apt install lintian)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"
