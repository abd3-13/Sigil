# Building an arm64 Debian/Devuan `.deb`

This fork adds Debian packaging for Sigil so that an installable arm64 package
can be produced on a native arm64 machine and published automatically by
GitHub Actions.

Everything lives in `packaging/deb/` and is driven by one script so the package
built on a dev box and the package built in CI are produced by identical steps.

## Requirements

Build dependencies (Debian 13 / Devuan 6 names):

```
build-essential cmake ninja-build pkgconf python3-dev
qt6-base-dev qt6-base-dev-tools qt6-tools-dev qt6-tools-dev-tools
qt6-webengine-dev qt6-webengine-dev-tools qt6-l10n-tools qt6-svg-dev
libqt6webenginecore6-bin
libhunspell-dev libpcre2-dev libminizip-dev zlib1g-dev libssl-dev xz-utils
```

## Build

```
packaging/deb/build-deb.sh
```

Useful environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `BUILD_DIR` | `build` | CMake build tree (reused between runs) |
| `OUT_DIR` | `dist` | where the `.deb` is written |
| `JOBS` | `nproc` | compile parallelism |
| `DEB_VERSION` | `<upstream>-1` | Debian revision, bump to re-release packaging |
| `PKG_ARCH` | `dpkg --print-architecture` | architecture field |

The script is safe to re-run: it reuses the CMake build tree and only rebuilds
what changed. Pass `--no-build` to skip compilation and just re-package the
existing build tree.

Build options used (matching Debian's own packaging where relevant):

* `-DUSE_SYSTEM_LIBS=1 -DSYSTEM_LIBS_REQUIRED=1` — link against the distro's
  zlib/minizip/hunspell/pcre2 instead of the bundled copies.
* `-DDISABLE_UPDATE_CHECK=1` — the update checker looks for upstream binary
  releases which are not useful for a distro package.
* `-DINSTALL_HICOLOR_ICONS=1` — install the full icon theme set.
* `-DINSTALL_BUNDLED_DICTS=1` — ship the hunspell dictionaries so spell
  checking works out of the box.

## Install

```
sudo apt install ./sigil_2.8.6-1_arm64.deb
```

or

```
sudo dpkg -i sigil_2.8.6-1_arm64.deb && sudo apt-get -f install
```

The executable is `/usr/bin/sigil` (a small launcher that sets up the library
path), the real binary is
`/usr/lib/<multiarch-tuple>/sigil/sigil`, and application data lives in
`/usr/share/sigil`.

## Layout of the package

```
/usr/bin/sigil                                  launcher script
/usr/lib/<triplet>/sigil/sigil                  binary
/usr/lib/<triplet>/sigil/libsigilgumbo.so       bundled-for-internal-use parser
/usr/share/applications/sigil.desktop
/usr/share/icons/hicolor/...                    icons
/usr/share/man/man1/sigil.1.gz
/usr/share/sigil/translations                   UI translations
/usr/share/sigil/hunspell_dictionaries          spell check dictionaries
/usr/share/sigil/plugin_launchers/python        plugin framework
/usr/share/sigil/python3lib                     helper python libraries
/usr/share/sigil/polyfills                      MathJax
```

## CI

Two workflows are involved:

* `.github/workflows/release-deb.yml` — triggered by a `2.*` tag push or manually.
  It only forwards to the reusable builder below.
* `.github/workflows/deb-build.yml` — `workflow_call` builder: `ubuntu-24.04-arm`
  runner, `debian:trixie` container, builds with `packaging/deb/build-deb.sh`,
  smoke-tests the package headless, uploads it as an artifact, publishes it with
  `softprops/action-gh-release`, and finally re-downloads the published asset
  from its public release URL and compares its size with the built `.deb`.
  That last step is token-free and reports through `::notice::`/`::error::`
  annotations, so a failed verification is readable without access to the
  (authenticated) job log.

Note for local runs of the CI recipe: the container needs `curl` and `file` on
top of the build dependencies; `debian:trixie` ships neither.
* `.github/workflows/upstream-watch.yml` — daily cron. When upstream publishes a
  new `X.Y.Z` tag it merges it into `arm64-deb`, verifies that `CMakeLists.txt`
  matches, creates tag `X.Y.Z-1` and runs the builder. If a previous run failed
  to publish, it retries building the existing tag on the next run.

The upstream workflows (AppImage, Windows, macOS, Linux distro, winget, blog
post) are limited to manual dispatch so only the deb build runs automatically.

Trigger a release by hand:

```
git tag 2.8.6-1
git push origin 2.8.6-1
```

or run the workflow manually and pass an existing tag in the `tag` input.

### Tag naming

The release tag must point at a commit that contains `packaging/deb/`, so the
upstream tag itself cannot be used (it is a pure upstream commit). The
convention is `<upstream version>-<deb revision>`, e.g. `2.8.6-1`:

* the tag name becomes the Debian version, so the asset is
  `sigil_2.8.6-1_arm64.deb`;
* it never collides with an upstream tag, so `git fetch upstream --tags` keeps
  working;
* bump the revision (`2.8.6-2`) for packaging-only changes without touching the
  upstream version.

