#!/usr/bin/env bash
# Install remote-patch into a LazyVim config as lua/plugins/remote-patch.lua.
#   curl -fsSL https://git.fferrando.cc/rdfilippo/remote-patch/raw/branch/main/install.sh | bash
#   ./install.sh               # from a checkout: use it in place (dir = ...)
#   ./install.sh <git-url>     # or: curl ... | bash -s -- <git-url>
set -euo pipefail

# Wrapped in main so a truncated `curl | bash` download runs nothing
main() {
  repo_url="${REMOTE_PATCH_REPO:-https://git.fferrando.cc/rdfilippo/remote-patch}"
  src="${BASH_SOURCE[0]:-}"
  nvim_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}"
  target="$nvim_cfg/lua/plugins/remote-patch.lua"

  [ -d "$nvim_cfg/lua/plugins" ] || {
    echo "No LazyVim config found at $nvim_cfg (missing lua/plugins/)" >&2
    exit 1
  }

  for bin in nvim ssh diff; do
    command -v "$bin" >/dev/null || {
      echo "Missing required dependency: $bin" >&2
      exit 1
    }
  done
  command -v sshpass >/dev/null || echo "Note: install 'sshpass' for password (non-key) auth."
  command -v git >/dev/null || echo "Note: install 'git' for 3-way merge."
  command -v delta >/dev/null || echo "Note: install 'delta' for the side-by-side diff view (falls back to native diff)."

  if [ $# -gt 0 ]; then
    source_line="url = \"$1\","
  elif [ -f "$src" ] && [ -f "$(dirname "$src")/lua/remote-patch/init.lua" ]; then
    source_line="dir = \"$(cd "$(dirname "$src")" && pwd)\","
  else
    source_line="url = \"$repo_url\","
  fi

  if [ -e "$target" ]; then
    cp "$target" "$target.bak"
    echo "Backed up existing spec to $target.bak"
  fi

  cat >"$target" <<EOF
-- remote-patch: edit remote files locally, push changes as patches over SSH
return {
	{
		$source_line
		name = "remote-patch",
		main = "remote-patch",
		event = "VeryLazy", -- setup() registers the <leader>R keymaps
		opts = {},
	},
}
EOF

  echo "Installed: $target"
  echo "Restart Neovim, then press <leader>R."
}

main "$@"
