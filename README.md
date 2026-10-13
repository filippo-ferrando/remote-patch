# remote-patch

Edit a remote file locally in Neovim, then push the change to the host as a patch over SSH. Each step can be undone.

```
pull    → load the remote file into the buffer and record it as the base
diff    → show buffer vs remote side by side in a float (delta, or native diff mode)
create  → diff the current buffer (unsaved edits included) against the remote file → <file>.patch (opens in a split)
apply   → dry-run, then `patch -b` on the remote (keeps <file>.orig; refused while a .orig is pending)
revert  → restore <file>.orig
confirm → delete the remote backup and the local .patch
merge   → resolve buffer vs remote: choose local, choose remote or 3-way merge
```

### Conflicts

The **base** is the remote content your edits started from. `pull`, `apply` and `revert` update it. The first `create` on a file sets it if there isn't one yet.
If the remote no longer matches the base, `create` and `apply` stop and offer:

- **View diff**: the side-by-side float, then back to this menu.
- **Choose local**: keep your buffer. The remote's changes will be overwritten.
- **Choose remote**: replace the buffer with the remote (undo with `u`).
- **Merge**: `git merge-file` 3-way merge. Non-overlapping changes merge automatically. Real conflicts open a float with remote | result: `co`/`ct`/`cb` take local/remote/both, `]x`/`[x` jump between conflicts, `:w` accepts, `q` cancels. Native `do`/`]c` work too.

Then you pick where the result goes: **local buffer** only (run create/apply when ready), or **local buffer + remote** (create and apply right away).

## Install (LazyVim)

```sh
curl -fsSL https://git.fferrando.cc/rdfilippo/remote-patch/raw/branch/main/install.sh | bash
```

Other ways to run it:

```sh
curl -fsSL .../install.sh | bash -s -- <git-url>   # clone from another repo (or set REMOTE_PATCH_REPO)
./install.sh                                       # from a checkout: point lazy.nvim at it (for development)
```

This writes `~/.config/nvim/lua/plugins/remote-patch.lua`. If that file already exists, it is backed up to `.bak` first.

You need `ssh`, `diff` and `patch` on the remote. Password auth also needs `sshpass`. The 3-way merge needs `git` locally, and the diff float uses [`delta`](https://github.com/dandavison/delta) when it's installed.

## Usage

| Key          | Action                         |
|--------------|--------------------------------|
| `<leader>Rr` | Remote actions                 |
| `<leader>RR` | Remote actions (password)      |
| `<leader>Rp` | Pull                           |
| `<leader>Rd` | Diff (float)                   |
| `<leader>Rc` | Create patch                   |
| `<leader>Ra` | Apply                          |
| `<leader>Ru` | Revert                         |
| `<leader>Rk` | Confirm                        |
| `<leader>Rm` | Merge                          |
| `<leader>Rt` | Set remote target              |

`:RemotePatch[!] [pull|diff|create|apply|revert|confirm|merge|target] [user@host:/path]`

- The target is remembered per local file, even after a restart. A new file gets a suggested target: the last host and directory you used, plus the new file's name.
- `<Tab>` completes hosts from `~/.ssh/config` (including `Include`d files), then remote paths.
- When key auth is refused, it asks for a password and retries. The SSH connection stays open for 15 minutes, so you won't be asked again during that time.
- Actions work from the patch review split too.

## Options

```lua
opts = {
  ssh_opts = { ... }, -- replaces the defaults (see lua/remote-patch/init.lua)
  open_patch = true,  -- open the patch in a split after create
  keys = true,        -- set the <leader>R keymaps and which-key group
}
```

## Test

```sh
nvim -l tests/run.lua
```
