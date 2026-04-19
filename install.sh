#!/bin/bash
set -e

# color palette
ORANGE='\033[38;5;208m'
GRAY='\033[38;5;240m'
WHITE='\033[37m'
NC='\033[0m' 

divider() { echo -e "${ORANGE}---------------------------------------------${NC}"; }
step() { echo -e "${BOLD}${WHITE}$1${NC}"; }
pipeline() { echo -e "    ${BOLD}${ORANGE}~>${NC} ${GRAY}$1${NC}"; } 

# header 
echo -e "${BOLD}${ORANGE}Flint${NC} ${BOLD}installer${NC}  ${GRAY}github.com/the-flint-lang/flint${NC}"
divider
echo -e "${GRAY}deps ~> download ~> install ~> compile cache${NC}\n"

# get os and arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    ARCH="aarch64"
fi

# environment detection
if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
    IS_TERMUX=true
    SUDO_CMD=""
    PREFIX_DIR="${PREFIX:-/data/data/com.termux/files/usr}"
    BIN_DIR="$PREFIX_DIR/bin"
    SHARE_DIR="$PREFIX_DIR/share/flint"
    PKG_MGR="pkg install -y"
    
    DEPS="clang libcurl libtcc" 
else
    IS_TERMUX=false
    SUDO_CMD="sudo"
    BIN_DIR="/usr/local/bin"
    SHARE_DIR="/usr/share/flint"
    
    if command -v apt-get >/dev/null; then
        PKG_MGR="sudo apt-get install -y"
        DEPS="clang libcurl4-openssl-dev libtcc-dev musl-tools" 
    elif command -v pacman >/dev/null; then
        PKG_MGR="sudo pacman -S --noconfirm"
        DEPS="clang curl musl"
    elif command -v dnf >/dev/null; then
        PKG_MGR="sudo dnf install -y"
        DEPS="clang libcurl-devel musl-gcc"
    else
        PKG_MGR=""
    fi
fi

# dependencies
step "checking dependencies"

if [ -n "$PKG_MGR" ]; then
    if [ "$IS_TERMUX" = false ]; then
        sudo apt-get update -qq 2>/dev/null || true 
    fi
    $PKG_MGR $DEPS > /dev/null 2>&1
    pipeline "Native C compiler, libcurl and libtcc ready"
else
    pipeline "unsupported package manager. ensure clang, libcurl and libtcc are installed."
fi
echo ""

# version fetch
step "fetching latest version"
REPO="the-flint-lang/flint"

VERSION=$(curl -s "https://api.github.com/repos/${REPO}/tags" \
  | grep '"name"' \
  | cut -d'"' -f4 \
  | grep -v '\-test' \
  | sort -V \
  | tail -n 1)

if [ -z "$VERSION" ]; then
    pipeline "failed to fetch API data"
    exit 1
fi

pipeline "version ${WHITE}${BOLD}$VERSION${NC}"
echo ""

# download
step "downloading flint $VERSION"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/flint-${OS}-${ARCH}.tar.gz"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR"

curl -fsSL "$DOWNLOAD_URL" -o flint.tar.gz || {
    pipeline "download failed for architecture: ${ARCH}"
    exit 1
}

tar -xzf flint.tar.gz
pipeline "downloaded and extracted"
echo ""

# installation 
step "installing"

$SUDO_CMD mkdir -p "$BIN_DIR"
$SUDO_CMD mkdir -p "$SHARE_DIR/std"

chmod +x bin/flint
$SUDO_CMD mv bin/flint "$BIN_DIR/flint"

$SUDO_CMD cp -r std/* "$SHARE_DIR/std/"
if [ -f "flint_rt.c" ]; then
    $SUDO_CMD cp flint_rt.* "$SHARE_DIR/"
fi

pipeline "installed to $BIN_DIR/flint"
echo "" 

# compile cache (Bare-Metal/Runtime Tuning)
step "building optimized runtime for your CPU"

RT_C="$SHARE_DIR/flint_rt.c"
RT_H="$SHARE_DIR/flint_rt.h"
RT_O="$SHARE_DIR/flint_rt.o"
RT_HTTP_O="$SHARE_DIR/flint_rt_http.o"
RT_PCH="$SHARE_DIR/flint_rt.h.pch"

if command -v clang > /dev/null 2>&1; then
    CC=clang
elif command -v gcc > /dev/null 2>&1; then
    CC=gcc
else
    pipeline "warning: clang/gcc not found, runtime not precompiled."
    CC=""
fi

if [ -n "$CC" ]; then
    pipeline "compiling base runtime ($CC)..."
    $SUDO_CMD "$CC" -O3 -ffunction-sections -fdata-sections -fvisibility=hidden -march=native -fno-semantic-interposition -DFLINT_NO_HTTP -c "$RT_C" -o "$RT_O"
    
    pipeline "compiling http runtime ($CC)..."
    $SUDO_CMD "$CC" -O3 -ffunction-sections -fdata-sections -fvisibility=hidden -march=native -fno-semantic-interposition -c "$RT_C" -o "$RT_HTTP_O"

    if [ "$CC" = "clang" ]; then
        pipeline "generating precompiled header..."
        $SUDO_CMD clang -O3 -x c-header "$RT_H" -o "$RT_PCH" || $SUDO_CMD rm -f "$RT_PCH"
    fi
fi
echo ""

# footer
divider
echo -e "${BOLD}flint ${VERSION}${NC} installed. run ${ORANGE}flint --help${NC} to get started."
echo -e "${GRAY}Note: For ARM64 cross-compilation, install 'zig' manually.${NC}"