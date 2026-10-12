-- remote-patch: edit a remote file locally, ship the change as a patch over SSH.
-- Workflow: create (diff buffer vs remote) -> apply (patch remote, keep .orig)
--           -> revert (restore .orig) | confirm (drop .orig and local .patch)
local M = {}

M.config = {
	-- Shared SSH options; ControlMaster keeps one connection alive for 15 minutes
	-- so completion and repeated actions don't reconnect (or re-ask a password).
	ssh_opts = {
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=~/.ssh/cm_%r_%h_%p",
		"-o", "ControlPersist=15m",
		"-o", "ConnectTimeout=5",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "IgnoreUnknown=WarnWeakCrypto",
		"-o", "WarnWeakCrypto=no-pq-kex",
	},
	-- Open the generated patch in a split for review after `create`
	open_patch = true,
}

M.actions = {
	{ name = "create", desc = "Diff buffer against remote file -> .patch" },
	{ name = "apply", desc = "Apply patch on remote (keeps .orig backup)" },
	{ name = "revert", desc = "Restore remote file from .orig backup" },
	{ name = "confirm", desc = "Delete remote backup and local .patch" },
	{ name = "target", desc = "Change remote target for this file" },
}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "RemotePatch" })
end

-- POSIX single-quote; vim.fn.shellescape follows the *local* 'shell' (e.g. fish)
local function q(s)
	return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- Quote a remote path but keep a leading ~/ unquoted so the remote shell expands it
function M.rpath(p)
	local rest = p:match("^~/(.*)$")
	return rest and "~/" .. q(rest) or q(p)
end

function M.parse_spec(spec)
	local host, path = (spec or ""):match("^%s*([^:%s]+):(.-)%s*$")
	if host and path ~= "" then
		return host, path
	end
end

--------------------------------------------------------------------------------
-- Persisted targets: { last = "host:path", targets = { [local_file] = "host:path" } }

local state_file = vim.fn.stdpath("data") .. "/remote-patch.json"
local state

local function get_state()
	if not state then
		local ok, data = pcall(function()
			return vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
		end)
		state = ok and type(data) == "table" and data or {}
		state.targets = type(state.targets) == "table" and state.targets or {}
	end
	return state
end

local function set_target(file, spec)
	local s = get_state()
	s.last, s.targets[file] = spec, spec
	pcall(vim.fn.writefile, { vim.json.encode(s) }, state_file)
end

-- Suggest a target: this file's saved one, else last host + last dir + this filename
local function default_target(file)
	local s = get_state()
	if s.targets[file] then
		return s.targets[file]
	end
	local host, path = M.parse_spec(s.last)
	if host then
		return host .. ":" .. vim.fs.dirname(path) .. "/" .. vim.fs.basename(file)
	end
	return ""
end

--------------------------------------------------------------------------------
-- SSH

local function socket_active(host)
	local cmd = vim.list_extend({ "ssh" }, M.config.ssh_opts)
	vim.list_extend(cmd, { "-O", "check", "--", host })
	return vim.system(cmd):wait().code == 0
end

local function ask_password(host, cb)
	vim.ui.input({ prompt = "SSH password for " .. host .. ": ", secret = true }, function(pw)
		if pw and pw ~= "" then
			cb(pw)
		end
	end)
end

-- Run `script` with sh on the remote (whatever the login shell is).
-- cb(ok, stdout, err) runs on the main loop. If key auth is refused, asks for a
-- password once and retries; the password lives in ctx for the follow-up calls.
local function ssh(ctx, script, stdin, cb)
	local cmd, env = { "ssh" }, nil
	if ctx.password then
		if vim.fn.executable("sshpass") == 0 then
			return notify("Password auth needs `sshpass` installed", vim.log.levels.ERROR)
		end
		cmd, env = { "sshpass", "-e", "ssh" }, { SSHPASS = ctx.password } -- env, not argv: keeps it out of `ps`
	else
		-- Never let ssh prompt on /dev/tty: that's Neovim's terminal
		vim.list_extend(cmd, { "-o", "BatchMode=yes" })
	end
	vim.list_extend(cmd, M.config.ssh_opts)
	vim.list_extend(cmd, { "--", ctx.host, "sh -c " .. q(script) })

	vim.system(cmd, { env = env, stdin = stdin }, vim.schedule_wrap(function(r)
		if r.code == 0 then
			return cb(true, r.stdout)
		end
		-- patch reports hunk failures on stdout
		local err = vim.trim((r.stderr or "") .. "\n" .. (r.stdout or ""))
		if not ctx.password and err:find("Permission denied") then
			return ask_password(ctx.host, function(pw)
				ctx.password = pw
				ssh(ctx, script, stdin, cb)
			end)
		end
		if ctx.password and r.code == 5 then
			ctx.password = nil
			err = "Wrong password"
		end
		cb(false, nil, err ~= "" and err or ("exit code " .. r.code))
	end))
end

--------------------------------------------------------------------------------
-- Actions

local function show_patch(patch)
	local win = vim.fn.bufwinid(patch)
	if win ~= -1 then
		vim.api.nvim_win_call(win, function()
			vim.cmd("edit!")
		end)
	else
		vim.cmd("botright split " .. vim.fn.fnameescape(patch))
	end
end

local run = {}

function run.create(ctx)
	local name = vim.fs.basename(ctx.path)
	local nl = vim.bo[ctx.buf].fileformat == "dos" and "\r\n" or "\n"
	local text = table.concat(vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false), nl)
	if vim.bo[ctx.buf].eol or vim.bo[ctx.buf].fixeol then
		text = text .. nl
	end

	notify("Fetching " .. ctx.spec .. " ...")
	ssh(ctx, "cat -- " .. M.rpath(ctx.path), nil, function(ok, remote, err)
		if not ok then
			return notify("Fetch failed:\n" .. err, vim.log.levels.ERROR)
		end
		local tmp = vim.fn.tempname()
		local f = assert(io.open(tmp, "wb"))
		f:write(remote)
		f:close()
		-- Diff against the buffer (stdin), so unsaved edits are included
		local cmd = { "diff", "-u", "--label", "a/" .. name, tmp, "--label", "b/" .. name, "-" }
		vim.system(cmd, { stdin = text }, vim.schedule_wrap(function(r)
			vim.fn.delete(tmp)
			if r.code == 0 then
				return notify("Local buffer and remote file are identical", vim.log.levels.WARN)
			elseif r.code ~= 1 then
				return notify("diff failed:\n" .. (r.stderr or ""), vim.log.levels.ERROR)
			end
			vim.fn.writefile(vim.split(r.stdout, "\n", { plain = true }), ctx.patch, "b")
			notify("Patch created: " .. vim.fn.fnamemodify(ctx.patch, ":~:."))
			if M.config.open_patch then
				show_patch(ctx.patch)
			end
		end))
	end)
end

function run.apply(ctx)
	if vim.fn.filereadable(ctx.patch) == 0 then
		return notify("No patch found, run `create` first", vim.log.levels.ERROR)
	end
	local p = M.rpath(ctx.path)
	-- Dry-run first so a mismatching patch never leaves the file half-applied
	local script = table.concat({
		't=$(mktemp) || exit 1; cat > "$t"',
		"patch --dry-run -N -s " .. p .. ' < "$t" && patch -b -N -s ' .. p .. ' < "$t"',
		'rc=$?; rm -f "$t"; exit $rc',
	}, "\n")
	notify("Applying patch to " .. ctx.spec .. " ...")
	ssh(ctx, script, table.concat(vim.fn.readfile(ctx.patch, "b"), "\n"), function(ok, _, err)
		if ok then
			notify("Patch applied (backup: " .. vim.fs.basename(ctx.path) .. ".orig)")
		else
			notify("Apply failed, remote file untouched:\n" .. err, vim.log.levels.ERROR)
		end
	end)
end

function run.revert(ctx)
	local p = M.rpath(ctx.path)
	local script = ("[ -f %s.orig ] || { echo 'No backup (.orig) found' >&2; exit 1; }; mv -f -- %s.orig %s"):format(p, p, p)
	ssh(ctx, script, nil, function(ok, _, err)
		if ok then
			notify("Remote file restored from backup")
		else
			notify("Revert failed:\n" .. err, vim.log.levels.ERROR)
		end
	end)
end

function run.confirm(ctx)
	local p = M.rpath(ctx.path)
	ssh(ctx, ("rm -f -- %s.orig %s~"):format(p, p), nil, function(ok, _, err)
		if not ok then
			return notify("Confirm failed:\n" .. err, vim.log.levels.ERROR)
		end
		vim.fn.delete(ctx.patch)
		local b = vim.fn.bufnr(ctx.patch)
		if b ~= -1 then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		end
		notify("Change confirmed, backup and patch removed")
	end)
end

--------------------------------------------------------------------------------
-- Entry point

local function ask_target(file, cb)
	vim.ui.input({
		prompt = "Remote target (user@host:/path): ",
		default = default_target(file),
		completion = "customlist,v:lua.RemotePatchComplete",
	}, function(spec)
		if not spec or spec == "" then
			return
		end
		if not M.parse_spec(spec) then
			return notify("Invalid target, expected user@host:/path", vim.log.levels.ERROR)
		end
		spec = vim.trim(spec)
		set_target(file, spec)
		cb(spec)
	end)
end

local function pick_action(spec, cb)
	vim.ui.select(M.actions, {
		prompt = "RemotePatch  " .. spec,
		format_item = function(a)
			return ("%-8s %s"):format(a.name, a.desc)
		end,
	}, function(a)
		if a then
			cb(a.name)
		end
	end)
end

-- action: one of M.actions names or nil (menu); spec: "host:path" or nil (saved/ask)
-- force_password: ask for a password up front unless an SSH session is already open
function M.run(action, spec, force_password)
	local buf = vim.api.nvim_get_current_buf()
	local file = vim.api.nvim_buf_get_name(buf)
	if file == "" or vim.bo[buf].buftype ~= "" then
		return notify("Current buffer must be a file", vim.log.levels.ERROR)
	end
	-- Called from the patch review split: act on the file it belongs to
	local source = file:match("^(.*)%.patch$")
	if source and get_state().targets[source] then
		file, buf = source, vim.fn.bufadd(source)
		vim.fn.bufload(buf)
	end

	local function go(target, act)
		if act == "target" then
			return ask_target(file, function() end)
		end
		local host, path = M.parse_spec(target)
		local ctx = { buf = buf, spec = target, host = host, path = path, patch = file .. ".patch" }
		if force_password and not socket_active(host) then
			return ask_password(host, function(pw)
				ctx.password = pw
				run[act](ctx)
			end)
		end
		run[act](ctx)
	end

	local function with_action(target)
		if action then
			go(target, action)
		else
			pick_action(target, function(act)
				go(target, act)
			end)
		end
	end

	if spec then
		if not M.parse_spec(spec) then
			return notify("Invalid target, expected user@host:/path", vim.log.levels.ERROR)
		end
		set_target(file, spec)
		if action == "target" then
			return notify("Target set: " .. spec)
		end
		return with_action(spec)
	end
	local saved = get_state().targets[file]
	if saved and action ~= "target" then
		return with_action(saved)
	end
	ask_target(file, action == "target" and function() end or with_action)
end

--------------------------------------------------------------------------------
-- Completion

-- Recursively parse an SSH config (following Include) into { host=, user= } entries
local function parse_ssh_config(path, hosts, seen, visited)
	path = vim.fn.expand(path)
	if visited[path] or vim.fn.filereadable(path) == 0 then
		return
	end
	visited[path] = true

	local current = {}
	for _, line in ipairs(vim.fn.readfile(path)) do
		local key, value = line:match("^%s*([^%s=]+)%s*=?%s*(.-)%s*$")
		key = key and key:lower()
		if not key or key:match("^#") or value == "" then
			-- skip blanks and comments
		elseif key == "host" then
			current = {}
			for pattern in value:gmatch("%S+") do
				-- Wildcards and negations aren't real hosts
				if not pattern:find("[%*%?!]") then
					table.insert(current, pattern)
					if not seen[pattern] then
						seen[pattern] = { host = pattern }
						table.insert(hosts, seen[pattern])
					end
				end
			end
		elseif key == "match" then
			current = {}
		elseif key == "user" then
			for _, h in ipairs(current) do
				seen[h].user = seen[h].user or value -- ssh: first value wins
			end
		elseif key == "include" then
			for pattern in value:gmatch("%S+") do
				if not pattern:match("^[~/]") then
					pattern = vim.fn.expand("~/.ssh/") .. pattern
				end
				for _, f in ipairs(vim.fn.glob(vim.fn.expand(pattern), false, true)) do
					parse_ssh_config(f, hosts, seen, visited)
				end
			end
		end
	end
end
M._parse_ssh_config = parse_ssh_config

local ssh_cache = {}
local function ssh_hosts()
	local cfg = vim.fn.expand("~/.ssh/config")
	local mtime = vim.fn.getftime(cfg)
	if ssh_cache.mtime ~= mtime then
		ssh_cache.hosts, ssh_cache.mtime = {}, mtime
		parse_ssh_config(cfg, ssh_cache.hosts, {}, {})
	end
	return ssh_cache.hosts
end

-- Complete "host:" from history + ~/.ssh/config, then "host:/path" over SSH
function M.complete_spec(arg_lead)
	local host, prefix = arg_lead:match("^([^:]+):(.*)$")
	if not host then
		local out, added = {}, {}
		local function add(h)
			if h and not added[h] and vim.startswith(h, arg_lead) then
				added[h] = true
				table.insert(out, h .. ":")
			end
		end
		add((M.parse_spec(get_state().last)))
		for _, e in ipairs(ssh_hosts()) do
			add(e.user and (e.user .. "@" .. e.host))
			add(e.host)
		end
		return out
	end

	if prefix == "" then
		prefix = "~/"
	end
	-- Blocking, but BatchMode + short timeout keep it bounded; instant on a live socket
	local cmd = vim.list_extend({ "ssh", "-o", "BatchMode=yes" }, M.config.ssh_opts)
	vim.list_extend(cmd, { "-o", "ConnectTimeout=2", "--", host, "sh -c " .. q("ls -1dp " .. M.rpath(prefix) .. "* 2>/dev/null") })
	local r = vim.system(cmd, { text = true }):wait()
	if r.code ~= 0 then
		return {}
	end
	local out = {}
	for item in r.stdout:gmatch("[^\n]+") do
		table.insert(out, host .. ":" .. item)
	end
	return out
end

-- :RemotePatch [action] [target]
function M.complete_cmd(arg_lead, cmdline, pos)
	local before = cmdline:sub(1, pos):gsub("^%s*%S+%s*", "")
	local _, nargs = before:gsub("%S+%s+", "")
	if nargs == 0 and not arg_lead:find(":") then
		local out = {}
		for _, a in ipairs(M.actions) do
			if vim.startswith(a.name, arg_lead) then
				table.insert(out, a.name)
			end
		end
		return vim.list_extend(out, M.complete_spec(arg_lead))
	end
	return M.complete_spec(arg_lead)
end

function M.setup(opts)
	M.config = vim.tbl_extend("force", M.config, opts or {}) -- shallow: ssh_opts is replaced, not merged
	vim.fn.mkdir(vim.fn.expand("~/.ssh"), "p", tonumber("700", 8))
	_G.RemotePatchComplete = M.complete_spec

	vim.api.nvim_create_user_command("RemotePatch", function(o)
		local action, spec = o.fargs[1], o.fargs[2]
		local names = vim.tbl_map(function(a)
			return a.name
		end, M.actions)
		if action and not vim.tbl_contains(names, action) then
			action, spec = nil, o.fargs[1] -- `:RemotePatch host:path` opens the menu
		end
		M.run(action, spec, o.bang)
	end, {
		bang = true,
		nargs = "*",
		complete = M.complete_cmd,
		desc = "Patch a remote file over SSH (! = ask for password)",
	})
end

return M
