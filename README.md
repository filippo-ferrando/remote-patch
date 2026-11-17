# remote-patch

Edit a remote file locally in Neovim, then push the change to the host as a patch over SSH. Each step can be undone.

- Your editor, your config, your LSP. No `scp` round trips, no editing over `sshfs`.
- Every change is a reviewable `.patch`. It is dry-run before it touches the remote, and a backup is kept until you confirm.
- If someone changed the remote file while you were editing, you get asked what to do. Nothing gets silently overwritten.

```
pull    → load the remote file into the buffer and record it as the base
diff    → show buffer vs remote side by side in a float (delta, or native diff mode)
create  → diff the current buffer (unsaved edits included) against the remote file → <file>.patch (opens in a split)
apply   → dry-run, then `patch -b` on the remote (keeps <file>.orig; refused while a .orig is pending)
revert  → restore <file>.orig
confirm → delete the remote backup and the local .patch
merge   → resolve buffer vs remote: choose local, choose remote or 3-way merge
```

Full reference: `:help remote-patch`.

## Requirements

**Local**

- Neovim **0.11+**
- `ssh` and `diff`
- Optional: `sshpass` (password auth), `git` (3-way merge), [`delta`](https://github.com/dandavison/delta) (nicer diff view, falls back to native diff mode)
- Optional: [which-key.nvim](https://github.com/folke/which-key.nvim) to label the `<leader>R` group

**Remote**

- A POSIX `sh`, `patch`, `mktemp` and the usual coreutils (`cat`, `mv`, `rm`, `ls`)
- Write access to the file and to its directory (for the `.orig` backup)

## Install

### LazyVim (script)

```sh
curl -fsSL https://git.fferrando.cc/rdfilippo/remote-patch/raw/branch/main/install.sh | bash
```

This writes `~/.config/nvim/lua/plugins/remote-patch.lua`. If that file already exists, it is backed up to `.bak` first. `$XDG_CONFIG_HOME` and `$NVIM_APPNAME` are respected.

Other ways to run it:

```sh
curl -fsSL .../install.sh | bash -s -- <git-url>   # clone from another repo (or set REMOTE_PATCH_REPO)
./install.sh                                       # from a checkout: point lazy.nvim at it (for development)
```

### lazy.nvim (manual)

```lua
{
  url = "https://git.fferrando.cc/rdfilippo/remote-patch",
  name = "remote-patch",
  main = "remote-patch",
  event = "VeryLazy",
  opts = {},
}
```

### Other plugin managers

Add the repo to your runtime path and call `setup()`. The `:RemotePatch` command and the keymaps are only created there.

```lua
require("remote-patch").setup({})
```

## Quick start

1. Open a local copy of the file, or an empty buffer with a file name (`:e nginx.conf`).
2. `<leader>Rp` (pull). Enter the target, for example `root@web:/etc/nginx/nginx.conf`. `<Tab>` completes hosts and remote paths.
3. Edit. Saving is optional, because the buffer content is what gets diffed.
4. `<leader>Rc` (create). Review the `.patch` in the split.
5. `<leader>Ra` (apply). The remote is patched and `nginx.conf.orig` is kept next to it.
6. Check the service. Then `<leader>Rk` (confirm) to keep the change, or `<leader>Ru` (revert) to restore the backup.

The target is remembered for this file, so you only enter it once.

## Actions

| Action    | What it does |
|-----------|--------------|
| `pull`    | Fetches the remote file. If the buffer is empty or unchanged since the last pull, it is replaced. If it has local edits, you get the [conflict menu](#conflicts). |
| `diff`    | Read-only side-by-side view, buffer vs remote. `q` closes it. |
| `create`  | Diffs the buffer (unsaved edits included) against the current remote file and writes `<file>.patch` next to the local file. |
| `apply`   | Sends the `.patch` **file on disk**, so after more edits, run `create` again. It dry-runs first, so a patch that doesn't fit leaves the remote untouched. It is refused while a `.orig` from an earlier apply is still there. |
| `revert`  | Moves `<remote>.orig` back over the remote file. Your local buffer is not changed. |
| `confirm` | Deletes `<remote>.orig` and the local `.patch`, and closes the patch buffer. |
| `merge`   | Opens the conflict menu on demand, even if the remote hasn't moved. |
| `target`  | Changes the remote target saved for this file. |

One change at a time: after `apply`, run `confirm` or `revert` before the next `apply`.

## Conflicts

The **base** is the remote content your edits started from. It is stored per local file and target. `pull`, `apply`, `revert` and *Choose remote* update it, and so does resolving with *Choose local* or *Merge*. If there isn't one yet, the first `create` sets it.

If the remote no longer matches the base, `create` and `apply` stop and offer:

- **View diff**: the side-by-side float, then back to this menu.
- **Choose local**: keep your buffer. The remote's changes will be overwritten.
- **Choose remote**: replace the buffer with the remote (undo with `u`).
- **Merge**: a `git merge-file` 3-way merge. Non-overlapping changes merge automatically. Real conflicts open the merge view.

After *Choose local* or *Merge*, you pick where the result goes: **local buffer** only (run create/apply when ready), or **local buffer + remote** (create and apply right away).

### Merge view

Two floats: remote (read-only) on the left, the editable result on the right.

| Key          | Action                                   |
|--------------|------------------------------------------|
| `co`         | Take local for the conflict under cursor |
| `ct`         | Take remote                              |
| `cb`         | Take both (local, then remote)           |
| `]x` / `[x`  | Next / previous conflict                 |
| `:w`         | Accept the result (refused while conflict markers are left) |
| `q`          | Cancel                                   |

Native diff-mode commands (`do`, `dp`, `]c`, `[c`) work too. Without a base (you never pulled or created), there's nothing to merge from, so the view opens directly with your buffer as the result.

## Usage

### Keymaps

| Key          | Action                         |
|--------------|--------------------------------|
| `<leader>Rr` | Remote actions (menu)          |
| `<leader>RR` | Remote actions (password)      |
| `<leader>Rp` | Pull                           |
| `<leader>Rd` | Diff (float)                   |
| `<leader>Rc` | Create patch                   |
| `<leader>Ra` | Apply                          |
| `<leader>Ru` | Revert                         |
| `<leader>Rk` | Confirm                        |
| `<leader>Rm` | Merge                          |
| `<leader>Rt` | Set remote target              |

Set `keys = false` to define your own. All keymaps call `:RemotePatch`.

### Command

```
:RemotePatch[!] [pull|diff|create|apply|revert|confirm|merge|target] [user@host:/path]
```

- With no action, it opens the action menu.
- `:RemotePatch user@host:/path` sets the target for this file and opens the menu.
- `!` asks for the password up front, unless an SSH connection to the host is already open.
- Targets accept anything `ssh` does as a host, including `~/.ssh/config` aliases. Paths can start with `~/`.

### Details

- The target is remembered per local file, even after a restart. A new file gets a suggested target: the last host and directory you used, plus the new file's name.
- `<Tab>` completes hosts from your history and `~/.ssh/config` (including `Include`d files), then remote paths. Path completion needs key auth or an open connection, and waits up to 2 s for the host.
- When key auth is refused, it asks for a password and retries. The SSH connection stays open for 15 minutes (ControlMaster), so you won't be asked again during that time. The password is only kept in memory for the current action and is passed to `sshpass` through the environment, not the command line.
- Actions work from the patch review split too. They act on the file the patch belongs to.

## Options

Defaults:

```lua
opts = {
  -- Replaces the defaults entirely; it is not merged.
  ssh_opts = {
    "-o", "ControlMaster=auto",
    "-o", "ControlPath=~/.ssh/cm_%r_%h_%p",
    "-o", "ControlPersist=15m",
    "-o", "ConnectTimeout=5",
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "IgnoreUnknown=WarnWeakCrypto",
    "-o", "WarnWeakCrypto=no-pq-kex",
  },
  open_patch = true, -- open the patch in a split after create
  keys = true,       -- set the <leader>R keymaps and which-key group
}
```

If you override `ssh_opts`, keep the `ControlMaster` lines. Without them, every action opens a new connection, and password hosts ask every time. `StrictHostKeyChecking=accept-new` trusts unknown hosts on first connect. Remove it if you want ssh to refuse them instead.

## Files

| Where | What |
|-------|------|
| `<local file>.patch` | The generated patch. Removed by `confirm`. |
| `<remote file>.orig` | Backup on the host after `apply`. Removed by `confirm`, restored by `revert`. |
| `stdpath("data")/remote-patch.json` | Saved targets, per local file. |
| `stdpath("data")/remote-patch/bases/` | One base snapshot per file and target. |
| `~/.ssh/cm_*` | SSH ControlMaster sockets. |

## Troubleshooting

- **"Pending change (.orig exists)"**: an earlier apply was never confirmed or reverted. Run `confirm` or `revert` first.
- **"Apply failed, remote file untouched"**: the patch doesn't fit the remote file, and the message includes `patch`'s output. Run `pull` or `merge`, then `create` again.
- **"Password auth needs `sshpass` installed"**: install it, or set up key auth.
- **"Wrong password"**: the next action asks again.
- **No path completion**: the host needs key auth or an open connection. Run any action once to open one.

## Test

```sh
nvim -l tests/run.lua
```
