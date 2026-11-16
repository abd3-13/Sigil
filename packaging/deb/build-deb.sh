#!/bin/bash
#
# Build a .deb package for Sigil from this source tree.
#
# Usage:  packaging/deb/build-deb.sh [--no-build]
#
# Environment:
#   BUILD_DIR   build directory to use      (default: build)
#   OUT_DIR     where the .deb is written   (default: dist)
#   JOBS        compile parallelism         (default: nproc)
#   PKG_ARCH    architecture override       (default: dpkg --print-architecture)
#
# The script is self contained and deliberately does not use debhelper: the
# same steps run on a dev machine and in CI, which keeps the locally tested
# artifact identical to the released one.

set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BUILD_DIR=${BUILD_DIR:-$SRC_DIR/build}
OUT_DIR=${OUT_DIR:-$SRC_DIR/dist}
JOBS=${JOBS:-$(nproc)}
PKG_ARCH=${PKG_ARCH:-$(dpkg --print-architecture)}
DO_BUILD=1
[ "${1:-}" = "--no-build" ] && DO_BUILD=0

# ---------------------------------------------------------------------------
# version + metadata
# ---------------------------------------------------------------------------
cmake_var() {
  sed -n "s/^ *set *( *$1 *\([0-9][0-9]*\).*/\1/p" "$SRC_DIR/CMakeLists.txt" | head -1
}
SIGIL_VERSION="$(cmake_var SIGIL_MAJOR_VERSION).$(cmake_var SIGIL_MINOR_VERSION).$(cmake_var SIGIL_REVISION_VERSION)"
case "$SIGIL_VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "!! could not determine Sigil version from CMakeLists.txt" >&2; exit 1 ;;
esac
# Distro revision, lets us re-release packaging changes for the same upstream tag
DEB_VERSION="${DEB_VERSION:-${SIGIL_VERSION}-1}"

# Guard against a tag that does not match the source tree it points at:
# a release tag must be <upstream version> or <upstream version>-<revision>.
case "$DEB_VERSION" in
  "$SIGIL_VERSION"|"$SIGIL_VERSION"-*) ;;
  *)
    echo "!! DEB_VERSION '$DEB_VERSION' does not match upstream version '$SIGIL_VERSION'." >&2
    echo "!! Refusing to build a package whose version does not describe its source." >&2
    exit 1
    ;;
esac

echo "== Sigil $SIGIL_VERSION  =>  ${DEB_VERSION} (${PKG_ARCH})"

# ---------------------------------------------------------------------------
# build + stage
# ---------------------------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
  cmake -G Ninja -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DUSE_SYSTEM_LIBS=1 \
    -DSYSTEM_LIBS_REQUIRED=1 \
    -DDISABLE_UPDATE_CHECK=1 \
    -DINSTALL_BUNDLED_DICTS=1 \
    -DINSTALL_HICOLOR_ICONS=1
  cmake --build "$BUILD_DIR" -j "$JOBS"
fi

STAGE="$BUILD_DIR/stage"
rm -rf "$STAGE"
DESTDIR="$STAGE" cmake --install "$BUILD_DIR"

# Where did we really install to? Debian's cmake uses a multiarch libdir.
LIBDIR_REL=$(cd "$STAGE/usr" && find lib* -maxdepth 2 -type d -name sigil | head -1)
[ -n "$LIBDIR_REL" ] || { echo "!! could not locate installed sigil lib dir" >&2; exit 1; }
SIGIL_BIN="$STAGE/usr/$LIBDIR_REL/sigil"
[ -x "$SIGIL_BIN" ] || { echo "!! missing $SIGIL_BIN" >&2; exit 1; }

# Strip debug/unneeded symbols, keep the package lean
find "$STAGE" -type f \( -name 'sigil' -o -name '*.so' -o -name '*.so.*' \) -print0 |
  xargs -0 -r strip --strip-unneeded 2>/dev/null || true

# Documentation: license + manual page
mkdir -p "$STAGE/usr/share/doc/sigil" "$STAGE/usr/share/man/man1"
cp "$SRC_DIR/packaging/deb/copyright" "$STAGE/usr/share/doc/sigil/copyright"
cp "$SRC_DIR/ChangeLog.txt" "$STAGE/usr/share/doc/sigil/changelog"
gzip -9n -c "$SRC_DIR/packaging/deb/sigil.1" > "$STAGE/usr/share/man/man1/sigil.1.gz"

# ---------------------------------------------------------------------------
# dependency calculation (shlibs:Depends) — needs a debian/control stub
# ---------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/debian"
cat > "$WORK/debian/control" <<EOF
Source: sigil
Section: editors
Priority: optional
Maintainer: nobody <nobody@example.com>

Package: sigil
Architecture: $PKG_ARCH
EOF

SHLIBS_DEPENDS=$(cd "$WORK" && dpkg-shlibdeps -O --ignore-missing-info -e"$SIGIL_BIN" 2>/dev/null |
  sed -n 's/^shlibs:Depends=//p')
if [ -z "$SHLIBS_DEPENDS" ]; then
  echo "!! dpkg-shlibdeps produced no dependencies" >&2
  exit 1
fi
# libsigilgumbo/libhunspell are shipped in the package itself; drop any bogus refs
SHLIBS_DEPENDS=$(echo "$SHLIBS_DEPENDS" | tr ',' '\n' | sed '/^\s*$/d' | sort -u | paste -sd, - | sed -e 's/,/, /g' -e 's/  */ /g')

# Python 3 is required for the plugin framework and embedded python
DEPENDS="$SHLIBS_DEPENDS, python3 (>= 3.9)"

INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)

mkdir -p "$STAGE/DEBIAN"
sed -e "s|@VERSION@|$DEB_VERSION|g" \
    -e "s|@ARCH@|$PKG_ARCH|g" \
    -e "s|@DEPENDS@|$DEPENDS|g" \
    -e "s|@INSTALLED_SIZE@|$INSTALLED_SIZE|g" \
    "$SRC_DIR/packaging/deb/control.in" > "$STAGE/DEBIAN/control"

# desktop/mime integration and icon cache
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  fi
fi
exit 0
EOF
cat > "$STAGE/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] || [ "$1" = purge ]; then
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q /usr/share/applications || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
  fi
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
chmod 0644 "$STAGE/DEBIAN/control"

# ---------------------------------------------------------------------------
# build the package
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/sigil_${DEB_VERSION}_${PKG_ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB" >/dev/null
echo "== built: $DEB ($(du -h "$DEB" | cut -f1))"
echo "== depends: $DEPENDS"
