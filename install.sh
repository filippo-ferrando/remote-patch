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
		cmd = "RemotePatch",
		opts = {},
		keys = {
			{ "<leader>Rr", "<cmd>RemotePatch<cr>", desc = "Menu" },
			{ "<leader>RR", "<cmd>RemotePatch!<cr>", desc = "Menu (password)" },
			{ "<leader>Rc", "<cmd>RemotePatch create<cr>", desc = "Create patch" },
			{ "<leader>Ra", "<cmd>RemotePatch apply<cr>", desc = "Apply patch" },
			{ "<leader>Ru", "<cmd>RemotePatch revert<cr>", desc = "Revert (undo apply)" },
			{ "<leader>Rk", "<cmd>RemotePatch confirm<cr>", desc = "Confirm (keep change)" },
			{ "<leader>Rt", "<cmd>RemotePatch target<cr>", desc = "Set remote target" },
		},
	},
	{
		"folke/which-key.nvim",
		optional = true,
		opts = {
			spec = {
				{ "<leader>R", group = "remote patch", icon = { icon = "󰒍 ", color = "cyan" } },
			},
		},
	},
}
EOF

  echo "Installed: $target"
  echo "Restart Neovim, then press <leader>R."
}

main "$@"
