# amber-gtk4: one GTK4 build for the whole amber suite.
#
# `make gtk` builds it, `make deb` packages it to /usr/lib/amber-gtk4, and the apps
# point their RUNPATH there. See README.md for why it exists at all.
# check-packaging: upstream (GTK 4.16.13, rebuilt for the suite with its patches)
VERSION = 4.16.13
# The package revision, bumped when the packaging changes but the GTK version does not.
REVISION = 1
DEB = dist/amber-gtk4_$(VERSION)-$(REVISION)_amd64.deb
DEV_DEB = dist/amber-gtk4-dev_$(VERSION)-$(REVISION)_amd64.deb
DEBS = $(DEB) $(DEV_DEB)
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-gtk4
# HOUSE_ROOT is the folder holding house-rules, which mise sets on a development machine; its
# check-narration and check-example-hosts are what `check-sources` runs where it is there.
# house-rules is private, so it is not in a siblings.txt, and a clone outside the house and the
# public runner go without those two checks, saying so.
HOUSE_SCRIPTS = $(HOUSE_ROOT)/house-rules/scripts

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
# Written when make check passes against the staged bundle.
CHECKED = build/checked
# The release tarball, verified against the sum GNOME publishes beside it
# (download.gnome.org/sources/gtk/<major.minor>/gtk-<version>.sha256sum). A fetched
# archive that does not match is deleted, so a wrong VERSION bump fails here and not
# after a 20-minute build. Lives under build/, not /tmp: /tmp is shared and predictable.
TARBALL = build/gtk-$(VERSION).tar.xz
TARBALL_SHA256 = ddf3d9e12b848139a945d191d5ca56b78d0647f53b55b8bca5f9902b61624498
TARBALL_URL = https://download.gnome.org/sources/gtk/$(basename $(VERSION))/gtk-$(VERSION).tar.xz

.PHONY: setup init-packages init-modules init-workstation help gtk build stage built check ci deb deb-path deb-install deb-remove clean push force-push lint check-sources check-lintian hooks check-no-agent-files

# A target whose recipe fails or is interrupted is removed, so it is never taken as made.
.DELETE_ON_ERROR:

# The system packages a build and the checks need, in one list: a development machine and the
# CI install the same with `make init-packages`, the CI with APT_FLAGS=-y. A package missing on
# the runner is added here, and a workflow names none. dpkg-dev is for dpkg-shlibdeps, binutils for the strip
# in the gtk target.
# curl fetches GTK's source tarball.
DEPS := meson ninja-build gperf sassc curl shellcheck shfmt dpkg-dev binutils lintian \
	libglib2.0-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev \
	libgraphene-1.0-dev libepoxy-dev libxkbcommon-dev libwayland-dev \
	libx11-dev libxi-dev libxcursor-dev libxdamage-dev libxinerama-dev \
	libxrandr-dev libxext-dev libxfixes-dev libcairo-script-interpreter2 \
	libjpeg-dev libtiff-dev libharfbuzz-dev libfribidi-dev libdrm-dev
APT_FLAGS ?=

init-packages: ## install the system packages a build and the checks need (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# GTK comes from its release tarball (`make gtk`), and nothing here has a lock of language
# packages. `ci` depends on it all the same, as in every repository.
init-modules: ## install the language packages from the lock: none here

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

# The checks need the bundle, so a checkout without one builds it here (`make gtk`, ~20 min).
built: stage
	@test -e $(BUNDLE)/libgtk-4.so.1 || $(MAKE) gtk

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
# The checks pass once per staged bundle: CHECKED is newer than the library and the scripts
# only after both pass, so check, deb and deb-install skip them until either changes.
check: built $(CHECKED) ## the bundle pulls in no newer stack and carries no build paths

$(CHECKED): $(BUNDLE)/libgtk-4.so.1 scripts/check-no-cascade scripts/check-no-buildpaths
	@scripts/check-no-cascade $(BUNDLE)/libgtk-4.so.1
	@scripts/check-no-buildpaths $(BUNDLE)
	@touch $@

# `built` makes the bundle before anything that names it is looked at; this rule is reached only
# when the stamp is asked for on its own.
$(BUNDLE)/libgtk-4.so.1:
	@echo "$@ is not there: make gtk first (~20 min)"; exit 2

# What a push must pass. Unlike amber-webkit's, it builds: a GTK build is 20 minutes, and CI
# keeps the staged bundle in its cache, so the runner checks and packages the bundle and runs
# lintian over both packages.
ci: init-modules check lint check-lintian ## everything a push must pass: check, lint, and lintian on both packages
	@echo "CI OK: the bundle resolves against the stock stack, carries no build paths, and packages; sources and packaging metadata check out"

# The checks that need no build: the shell scripts, the docs, the packaging metadata.
check-sources: ## shellcheck, the changelog and control templates, and house-rules' narration and example-host checks where it is there
	@if [ -n "$(HOUSE_ROOT)" ] && [ -x "$(HOUSE_SCRIPTS)/check-narration" ]; then \
		"$(HOUSE_SCRIPTS)/check-narration" && "$(HOUSE_SCRIPTS)/check-example-hosts" "$(CURDIR)" || exit 1; \
	else echo "house-rules not found (HOUSE_ROOT=$(HOUSE_ROOT)): check-narration and check-example-hosts skipped; house-rules is private"; fi
	@git ls-files | while read -r f; do \
		case "$$f" in *.sh|*.bash) echo "$$f";; \
		*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
	done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"
	@dpkg-parsechangelog -l packaging/debian/changelog -S Version | grep -qx '$(VERSION)-$(REVISION)' || \
		{ echo "packaging/debian/changelog is not at $(VERSION)-$(REVISION)"; exit 1; }
	@test "$$(dpkg-parsechangelog -l packaging/debian/changelog -S Changes | grep -c '^  \*')" = 1 || \
		{ echo "packaging/debian/changelog has more than its one entry"; exit 1; }
	@for c in packaging/control.in packaging/control-dev.in; do \
		grep -q '^Package: ' $$c && grep -q '^Version: @VERSION@$$' $$c || { echo "$$c: no Package or Version line"; exit 1; }; \
	done
	@echo "check-sources OK"

# Two binary packages from the one build.
#   amber-gtk4: the shared object and the module directory under /usr/lib/amber-gtk4; no
#     binaries.
#   amber-gtk4-dev: the headers, the unversioned .so link and the .pc files, all under
#     /usr/lib/amber-gtk4, so they never meet the distro's libgtk-4-dev; the suite's
#     bindings are generated from these headers.
# The stage keeps meson's layout (headers in usr/include), which the suite's bindings and
# amber-glycin read; the headers move under /usr/lib/amber-gtk4 in the -dev package, and its
# .pc files' includedir with them (scripts/check-pc checks them in the package).
DEBROOT = build/deb/amber-gtk4
DEVROOT = build/deb/amber-gtk4-dev
deb: built $(DEBS) ## package the bundle into dist/: amber-gtk4 and amber-gtk4-dev

# Both packages come from one staging, so one rule makes them together, and only when the
# checked bundle or what goes into a package changed: an up-to-date pair is installed or
# ingested as it is. `built` runs first and re-stages a rebuilt library, so the bundle's time is
# the staged one. A recipe that fails or is interrupted deletes them (.DELETE_ON_ERROR), so a
# half-written package never counts as made.
$(DEBS) &: $(CHECKED) packaging/control.in packaging/control-dev.in packaging/debian/copyright packaging/debian/changelog $(wildcard packaging/lintian-overrides/*) scripts/check-no-buildpaths scripts/check-pc Makefile
	rm -rf build/deb build/shlibwork
	install -d $(DEBROOT)$(INSTALL_DIR) $(DEVROOT)$(INSTALL_DIR)
	# Copy the real file and re-create the SONAME symlink, rather than copying a
	# dangling link into the package; the unversioned link belongs to -dev.
	install -D -m644 $$(readlink -f $(BUNDLE)/libgtk-4.so.1) \
		$(DEBROOT)$(INSTALL_DIR)/$$(basename $$(readlink -f $(BUNDLE)/libgtk-4.so.1))
	ln -sf $$(basename $$(readlink -f $(BUNDLE)/libgtk-4.so.1)) \
		$(DEBROOT)$(INSTALL_DIR)/libgtk-4.so.1
	# The bundle's own module dir (print backend). The apps get input methods from the
	# distro's directory instead (see kat:gtkenv).
	cp -a $(BUNDLE)/gtk-4.0 $(DEBROOT)$(INSTALL_DIR)/gtk-4.0
	cp -a $(BUNDLE)/libgtk-4.so $(BUNDLE)/pkgconfig $(DEVROOT)$(INSTALL_DIR)/
	cp -a $(STAGE)/usr/include $(DEVROOT)$(INSTALL_DIR)/
	sed -i 's|^includedir=.*|includedir=$${prefix}/lib/amber-gtk4/include|' $(DEVROOT)$(INSTALL_DIR)/pkgconfig/*.pc
	# Assert on what is actually packaged, both packages, the objects and the text beside
	# them, not only on what was staged: `make deb` must not be a way around `make check`.
	@scripts/check-no-buildpaths build/deb
	@scripts/check-pc $(DEVROOT)$(INSTALL_DIR)/pkgconfig $(INSTALL_DIR)
	@set -e; for p in amber-gtk4 amber-gtk4-dev; do \
		root=build/deb/$$p; \
		install -D -m644 packaging/lintian-overrides/$$p $$root/usr/share/lintian/overrides/$$p; \
		install -D -m644 packaging/debian/copyright $$root/usr/share/doc/$$p/copyright; \
		gzip -9n < packaging/debian/changelog > $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		chmod 644 $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		find $$root -type d -exec chmod 755 {} +; \
		mkdir -p $$root/DEBIAN; \
		(cd $$root && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums); \
	done
	# The bundle is deliberately NOT on the ldconfig path: only a binary whose RUNPATH
	# names $(INSTALL_DIR) picks it up, so installing this cannot change what any other
	# program on the system links against.
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-gtk4\n\nPackage: amber-gtk4\nArchitecture: amd64\n' > build/shlibwork/debian/control
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info \
		../../$(DEBROOT)$(INSTALL_DIR)/libgtk-4.so.1 > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e "s/@SIZE@/$$(du -sk $(DEBROOT) --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed 's/^shlibs:Depends=//' build/shlibwork/deps.txt)|" \
		packaging/control.in > $(DEBROOT)/DEBIAN/control
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e "s/@SIZE@/$$(du -sk $(DEVROOT) --exclude=DEBIAN | cut -f1)/" \
		packaging/control-dev.in > $(DEVROOT)/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group $(DEBROOT) $(DEB)
	dpkg-deb --build --root-owner-group $(DEVROOT) $(DEV_DEB)

# Where `make deb` puts the packages: one absolute path a line, nothing else.
# amberlinux-apt ingests them through this.
deb-path: ## print the absolute paths of the two .debs, one a line
	@for d in $(DEBS); do echo "$(CURDIR)/$$d"; done

deb-install: deb ## install both .debs, packaging them first if the bundle changed (sudo)
	# --allow-downgrades: once the packages are published, the archive carries the same
	# version at a higher pin priority than a local file, so apt reads installing your own
	# build as a downgrade and refuses.
	sudo apt install --reinstall --allow-downgrades $(patsubst %,./%,$(DEBS))

deb-remove: ## remove the installed packages (sudo)
	sudo apt remove amber-gtk4-dev amber-gtk4

# build/ holds the GTK build as well: after a clean, `make gtk` compiles everything again
# (about 20 minutes).
clean: ## remove build/ and dist/, the GTK build included
	rm -rf build dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/|\.codex/|AGENTS\.md|CLAUDE\.md)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber .codex AGENTS.md CLAUDE.md; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored: 'git add -A' would publish it"; \
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
	other_wt="$$(git worktree list --porcelain | awk -v b="branch refs/heads/$(BRANCH)" '/^worktree /{w=substr($$0, 10)} $$0 == b {print w}')"; \
	if [ -n "$$other_wt" ] && [ "$$other_wt" != "$$(git rev-parse --show-toplevel)" ]; then \
		git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 || true; \
		git checkout -q --detach; git branch -D "$$tmp_branch" >/dev/null; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
		echo "$(BRANCH) is checked out in $$other_wt; once it is clean: git -C $$other_wt fetch && git -C $$other_wt reset --keep $(REMOTE)/$(BRANCH)"; \
	else \
		git branch -M "$$tmp_branch" "$(BRANCH)"; \
		git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
	fi

# lint needs no build: the formatting, the agent-file guard and the source checks.
lint: check-fmt check-no-agent-files check-sources ## check-fmt, the agent-file guard and check-sources
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed, run 'make hooks'"

# lintian reads the packages, so it needs the build; ci runs it after check.
check-lintian: deb ## lintian on both packages (needs the build)
	@if command -v lintian >/dev/null; then \
		lintian --tag-display-limit 0 -L '>=pedantic' --fail-on error,warning $(DEBS) && echo "lintian OK"; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo "lintian is not installed on this runner; make init-packages installs it"; exit 1; \
	else echo "lintian not installed: skipping (make init-packages installs it)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"

# Shell scripts are laid out by shfmt (sudo apt install shfmt), with tabs: every tracked file
# that is a shell script by its name or its first line.
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard -- . | xargs -0 -r $(SHFMT) -f
.PHONY: fmt check-fmt fmt-sh check-fmt-sh
fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; make init-packages installs it"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

fmt: fmt-sh ## format the code in place: here, the shell scripts
check-fmt: check-fmt-sh ## fail on code that is not as make fmt leaves it

init-workstation: hooks ## set up a desk: the git hooks

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: the system packages (sudo apt), then the git hooks
