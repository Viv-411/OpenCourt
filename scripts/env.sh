# Source this before running uv/python tooling on this Mac:
#   source scripts/env.sh
# uv lives in ~/.uv because ~/.local is root-owned on this machine.
export PATH="$HOME/.uv/bin:$PATH"
export UV_PYTHON_INSTALL_DIR="$HOME/.uv/python"
export UV_PYTHON_BIN_DIR="$HOME/.uv/bin"
# /usr/bin/git, swift, etc. are blocked until the Xcode license is accepted;
# the Command Line Tools copies work without it.
if ! /usr/bin/git --version >/dev/null 2>&1; then
  export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
  export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
fi
