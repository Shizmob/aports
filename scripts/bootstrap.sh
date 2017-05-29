#!/bin/sh

set -e

TARGET_ARCH="$1"
: ${SUDO_APK:=abuild-apk}

# optional cross build packages
KERNEL_PKG="linux-firmware linux-vanilla"

# check abuild existence
[ -e /usr/share/abuild/functions.sh ] || (echo "abuild not found" ; exit 1)

apkbuildname() {
	local repo="${1%%/*}"
	local pkg="${1##*/}"
	[ "$repo" = "$1" ] && repo="main"
	echo $APORTS/$repo/$pkg/APKBUILD
}

msg() {
	[ -n "$quiet" ] && return 0
	local prompt="$GREEN>>>${NORMAL}"
	local name="${BLUE}bootstrap-${TARGET_ARCH}${NORMAL}"
        printf "${prompt} ${name}: %s\n" "$1" >&2
}

if [ -z "$TARGET_ARCH" ]; then
	program=$(basename $0)
	cat <<EOF
usage: $program TARGET_ARCH [TOOLCHAIN]

This script creates a local cross-compiler, and uses it to
cross-compile an Alpine Linux base system for new architecture.

Steps for introducing new architecture include:
- adding the compiler tripler and arch type to abuild
- adding the arch type detection to apk-tools
- adjusting build rules for packages that are arch aware:
  gcc, libressl, linux-headers
- create new kernel config for linux-vanilla

After these steps the initial cross-build can be completed
by running this with the target arch as parameter, e.g.:
	./$program aarch64

EOF
	return 1
fi

# get abuild configurables
CBUILDROOT="$(CTARGET=$TARGET_ARCH . /usr/share/abuild/functions.sh ; echo $CBUILDROOT)"
. /usr/share/abuild/functions.sh
[ -z "$CBUILD_ARCH" ] && die "abuild is too old (use 2.29.0 or later)"
[ -z "$CBUILDROOT" ] && die "CBUILDROOT not set for $TARGET_ARCH"

# deduce aports directory
[ -z "$APORTS" ] && APORTS=$(realpath $(dirname $0)/../)
[ -e "$APORTS/main/build-base" ] || die "Unable to deduce aports base checkout"
[ -z "$2" ] || TOOLCHAIN="$2"
[ -n "$TOOLCHAIN" ] || TOOLCHAIN="gnu"
export TOOLCHAIN

if [ ! -d "$CBUILDROOT" ]; then
	msg "Creating sysroot in $CBUILDROOT"
	mkdir -p "$CBUILDROOT/etc/apk/keys"
	cp -a /etc/apk/keys/* "$CBUILDROOT/etc/apk/keys"
	${SUDO_APK} add --quiet --initdb --arch $TARGET_ARCH --root $CBUILDROOT
fi

msg "Installing dependencies"

if [ "$TOOLCHAIN" = llvm ]; then
	apk add --virtual .bootstrap-deps compiler-rt clang clang-dev llvm4-utils
	trap 'apk del .bootstrap-deps' EXIT INT
fi

msg "Building cross toolchain"

# Build and install cross binutils (--with-sysroot)
CTARGET=$TARGET_ARCH BOOTSTRAP=nobase APKBUILD=$(apkbuildname binutils) abuild -r
export EXTRADEPENDS_BUILD="binutils-$TARGET_ARCH"
export EXTRADEPENDS_TARGET
export CROSSFLAGS

case "$TOOLCHAIN" in
llvm)
	CROSSFLAGS="-fuse-ld=lld -Wno-unused-command-line-argument"

	# libc headers and runtime libraries
	for PKG in musl-dev compiler-rt; do
		CHOST=$TARGET_ARCH BOOTSTRAP=nocc APKBUILD=$(apkbuildname ${PKG%-dev}) abuild -r
		EXTRADEPENDS_TARGET="$EXTRADEPENDS_TARGET $PKG"
	done

	crtver=$(. $(apkbuildname compiler-rt) && echo $pkgver)
	CROSSFLAGS="$CROSSFLAGS -resource-dir ${CBUILDROOT}/usr/lib/clang/$crtver --rtlib=compiler-rt"

	# libc and libc++ headers
	for PKG in musl libc++-dev; do
		CHOST=$TARGET_ARCH BOOTSTRAP=nolibc APKBUILD=$(apkbuildname ${PKG%-dev}) abuild -r
		EXTRADEPENDS_TARGET="$EXTRADEPENDS_TARGET $PKG"
	done

	CROSSFLAGS="$CROSSFLAGS -stdlib=libc++"

	# unwinding and libc++
	for PKG in llvm-libunwind libc++; do
		CHOST=$TARGET_ARCH BOOTSTRAP=nobase APKBUILD=$(apkbuildname $PKG) abuild -r
	done
	;;
gnu)
	if ! CHOST=$TARGET_ARCH BOOTSTRAP=nolibc APKBUILD=$(apkbuildname musl) abuild up2date 2>/dev/null; then
		# C-library headers for target
		CHOST=$TARGET_ARCH BOOTSTRAP=nocc APKBUILD=$(apkbuildname musl) abuild -r

		# Minimal cross GCC
		EXTRADEPENDS_HOST="musl-dev" \
		CTARGET=$TARGET_ARCH BOOTSTRAP=nolibc APKBUILD=$(apkbuildname gcc) abuild -r

		# Cross build bootstrap C-library for the target
		EXTRADEPENDS_BUILD="gcc-pass2-$TARGET_ARCH" \
		CHOST=$TARGET_ARCH BOOTSTRAP=nolibc APKBUILD=$(apkbuildname musl) abuild -r
	fi

	# Full cross GCC
	EXTRADEPENDS_TARGET="musl musl-dev" \
	CTARGET=$TARGET_ARCH BOOTSTRAP=nobase APKBUILD=$(apkbuildname gcc) abuild -r
	;;
esac

# Cross remainder of build-base
CTARGET=$TARGET_ARCH BOOTSTRAP=nobase APKBUILD=$(apkbuildname build-base) abuild -r

msg "Cross building base system"

case "$TOOLCHAIN" in
gnu)  implicit_deps="libgcc libstdc++ musl-dev";;
llvm) implicit_deps="compiler-rt musl-dev libc++-dev llvm-libunwind-dev";;
esac

# add implicit target prerequisite packages
apk info --quiet --installed --root "$CBUILDROOT" $implicit_deps || \
	${SUDO_APK} --root "$CBUILDROOT" add --repository "$REPODEST/main" $implicit_deps

case "$TOOLCHAIN" in
gnu)  toolchain="binutils mpf3 mpc1 isl cloog gcc";;
llvm) toolchain="binutils llvm4 libxml2 isl clang lld";;
esac

# ordered cross-build
for PKG in fortify-headers linux-headers musl libc-dev pkgconf zlib gmp libffi \
	   busybox busybox-initscripts binutils make \
	   libressl libfetch apk-tools \
	   $toolchain \
	   openrc alpine-conf alpine-baselayout alpine-keys alpine-base build-base \
	   attr libcap patch sudo acl fakeroot tar \
	   pax-utils abuild openssh \
	   ncurses libcap-ng util-linux lvm2 popt xz cryptsetup kmod lddtree mkinitfs \
	   community/go libffi community/ghc \
	   $KERNEL_PKG ; do
	CHOST=$TARGET_ARCH BOOTSTRAP=bootimage APKBUILD=$(apkbuildname $PKG) abuild -r

	case "$PKG" in
	fortify-headers | libc-dev | build-base)
		# headers packages which are implicit but mandatory dependency
		apk info --quiet --installed --root "$CBUILDROOT" $PKG || \
			${SUDO_APK} --update --root "$CBUILDROOT" --repository "$REPODEST/main" add $PKG
		;;
	musl | gcc | clang)
		# target libraries rebuilt, force upgrade
		[ "$(apk upgrade --root "$CBUILDROOT" --repository "$REPODEST/main" --available --simulate | wc -l)" -gt 1 ] &&
			${SUDO_APK} upgrade --root "$CBUILDROOT" --repository "$REPODEST/main" --available
		;;
	esac
done
