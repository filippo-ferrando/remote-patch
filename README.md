# remote-patch

Edit a remote file locally in Neovim, then push the change to the host as a patch over SSH. Each step can be undone.

```
create  → diff the current buffer (unsaved edits included) against the remote file → <file>.patch (opens in a split)
apply   → dry-run, then `patch -b` on the remote (keeps <file>.orig)
revert  → restore <file>.orig
confirm → delete the remote backup and the local .patch
```

## Install (LazyVim)

```sh
curl -fsSL https://git.fferrando.cc/rdfilippo/RemotePatch/raw/branch/main/install.sh | bash
```

Other ways to run it:

```sh
curl -fsSL .../install.sh | bash -s -- <git-url>   # clone from another repo (or set REMOTE_PATCH_REPO)
./install.sh                                       # from a checkout: point lazy.nvim at it (for development)
```

This writes `~/.config/nvim/lua/plugins/remote-patch.lua`. If that file already exists, it is backed up to `.bak` first.

You need `ssh`, `diff` and `patch` on the remote. Password auth also needs `sshpass`.

## Usage

| Key          | Action                         |
|--------------|--------------------------------|
| `<leader>Rr` | Action menu                    |
| `<leader>RR` | Action menu, ask for password  |
| `<leader>Rc` | Create patch                   |
| `<leader>Ra` | Apply                          |
| `<leader>Ru` | Revert                         |
| `<leader>Rk` | Confirm                        |
| `<leader>Rt` | Set remote target              |

`:RemotePatch[!] [create|apply|revert|confirm|target] [user@host:/path]`

- The target is remembered per local file, even after a restart. A new file gets a suggested target: the last host and directory you used, plus the new file's name.
- `<Tab>` completes hosts from `~/.ssh/config` (including `Include`d files), then remote paths.
- When key auth is refused, it asks for a password and retries. The SSH connection stays open for 15 minutes, so you won't be asked again during that time.
- Actions work from the patch review split too.

## Options

```lua
opts = {
  ssh_opts = { ... }, -- replaces the defaults (see lua/remote-patch/init.lua)
  open_patch = true,  -- open the patch in a split after create
}
```

## Test

```sh
nvim -l tests/run.lua
```
