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
pipeline() { echo -e "    ${BOLD}${ORANGE}~>${NC} ${GRAY}$1${NC}\n"; }

# header
echo -e "${BOLD}${ORANGE}Flint${NC} ${BOLD}installer${NC}  ${GRAY}github.com/lucaas-d3v/flint${NC}"
divider
echo -e "${GRAY}deps ~> download ~> install${NC}\n"

# get os and arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

# dependeces
step "checking dependencies"

if command -v apt-get >/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq clang libcurl4-openssl-dev tcc libtcc-dev > /dev/null
    pipeline "clang, libcurl, libtcc ready"
else
    pipeline "unsupported package manager. ensure deps are installed."
fi

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

# download
step "downloading flint $VERSION"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/flint-${OS}-${ARCH}.tar.gz"

echo DOWNLOAD_URL

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$TMP_DIR"

curl -fsSL "$DOWNLOAD_URL" -o flint.tar.gz || {
    pipeline "download failed"
    exit 1
}

pipeline "extracted"

# installation
step "installing"

tar -xzf flint.tar.gz

sudo mkdir -p /usr/local/bin/
sudo mkdir -p /usr/share/flint/

chmod +x bin/flint
sudo mv bin/flint /usr/local/bin/flint
sudo mv std/* /usr/share/flint/

echo "" 

# footer
divider
echo -e "${BOLD}flint ${VERSION}${NC} installed. run ${ORANGE}flint --help${NC} to get started."
