#!/bin/bash
set -e

# color palette
BOLD='\033[1m'
ORANGE='\033[38;5;208m'
GRAY='\033[38;5;240m'
WHITE='\033[37m'
NC='\033[0m' 

divider() { echo -e "${ORANGE}---------------------------------------------${NC}"; }
step() { echo -e "${BOLD}${WHITE}$1${NC}"; }
pipeline() { echo -e "    ${BOLD}${ORANGE}~>${NC} ${GRAY}$1${NC}"; } 

# header
echo -e "${BOLD}${ORANGE}Flint${NC} ${BOLD}installer${NC}  ${GRAY}github.com/lucaas-d3v/flint${NC}"
divider
echo -e "${GRAY}deps ~> download ~> install${NC}\n"

# get os and arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

if [ "$ARCH" = "arm64" ]; then
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
    
    DEPS="clang libcurl" 
else
    IS_TERMUX=false
    SUDO_CMD="sudo"
    BIN_DIR="/usr/local/bin"
    SHARE_DIR="/usr/share/flint"
    
    if command -v apt-get >/dev/null; then
        PKG_MGR="sudo apt-get install -y"
        sudo dpkg --add-architecture arm64 > /dev/null 2>&1
        
        DEPS="clang libcurl4-openssl-dev libcurl4-openssl-dev:arm64 gcc-aarch64-linux-gnu libc6-dev-arm64-cross" 
    elif command -v pacman >/dev/null; then
        PKG_MGR="sudo pacman -S --noconfirm"
        DEPS="clang curl aarch64-linux-gnu-gcc aarch64-linux-gnu-glibc"
    elif command -v dnf >/dev/null; then
        PKG_MGR="sudo dnf install -y"
        DEPS="clang libcurl-devel gcc-aarch64-linux-gnu glibc-aarch64-linux-gnu"
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
    pipeline "C compiler and libcurl ready"
else
    pipeline "unsupported package manager. ensure clang and libcurl are installed."
fi
echo ""

# version fetch
step "fetching latest version"
REPO="lucaas-d3v/flint"

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

# ==========================================
# DOWNLOAD
# ==========================================
step "downloading flint $VERSION"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/flint-${OS}-${ARCH}.tar.gz"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR"

curl -fsSL "$DOWNLOAD_URL" -o flint.tar.gz || {
    pipeline "download failed for architecture: ${ARCH}"
    exit 1
}

pipeline "downloaded and extracted"
echo ""

# ==========================================
# INSTALLATION
# ==========================================
step "installing"

tar -xzf flint.tar.gz

$SUDO_CMD mkdir -p "$BIN_DIR"
$SUDO_CMD mkdir -p "$SHARE_DIR"

chmod +x bin/flint
$SUDO_CMD mv bin/flint "$BIN_DIR/flint"
$SUDO_CMD mv std/* "$SHARE_DIR/"

pipeline "installed to $BIN_DIR/flint"
echo "" 

# footer
divider
echo -e "${BOLD}flint ${VERSION}${NC} installed. run ${ORANGE}flint --help${NC} to get started."