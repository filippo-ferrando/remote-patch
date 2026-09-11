-- Ensure local SSH control directory exists
vim.fn.mkdir(vim.fn.expand("~/.ssh"), "p")

-- Shared SSH multiplexing options (persists master connection for 15 mins)
local ssh_opts =
	"-o ControlMaster=auto -o ControlPath=~/.ssh/cm_%r_%h_%p -o ControlPersist=15m -o IgnoreUnknown=WarnWeakCrypto -o WarnWeakCrypto=no-pq-kex"

-- Helper function to check if a multiplexed SSH session is currently active
local function is_socket_active(remote_host)
	local check_cmd = string.format(
		"ssh -o ControlPath=~/.ssh/cm_%%r_%%h_%%p -O check %s 2>/dev/null",
		vim.fn.shellescape(remote_host)
	)
	vim.fn.system(check_cmd)
	return vim.v.shell_error == 0
end

-- Recursively parse an SSH config file (following Include directives) into
-- a list of { host = "...", user = "..." } entries, keyed by seen[] to dedupe.
local function parse_ssh_config_file(path, hosts, seen, visited)
	path = vim.fn.expand(path)
	if visited[path] or vim.fn.filereadable(path) == 0 then
		return
	end
	visited[path] = true

	local current_hosts = {}
	for _, line in ipairs(vim.fn.readfile(path)) do
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed ~= "" and not trimmed:match("^#") then
			local key, value = trimmed:match("^(%S+)%s+(.+)$")
			if key then
				local lkey = key:lower()
				if lkey == "host" then
					current_hosts = {}
					for pattern in value:gmatch("%S+") do
						-- Skip wildcard/negated patterns; only exact hostnames are useful for completion
						if not pattern:find("[%*%?]") and not pattern:find("^!") then
							table.insert(current_hosts, pattern)
							if not seen[pattern] then
								seen[pattern] = { host = pattern }
								table.insert(hosts, seen[pattern])
							end
						end
					end
				elseif lkey == "user" then
					for _, h in ipairs(current_hosts) do
						if seen[h] then
							seen[h].user = value
						end
					end
				elseif lkey == "include" then
					for pattern in value:gmatch("%S+") do
						local include_path = pattern
						if not include_path:match("^[~/]") then
							include_path = vim.fs.dirname(path) .. "/" .. include_path
						end
						for _, f in ipairs(vim.fn.glob(vim.fn.expand(include_path), false, true)) do
							parse_ssh_config_file(f, hosts, seen, visited)
						end
					end
				end
			end
		end
	end
end

-- Cache parsed ~/.ssh/config entries, invalidated when the file's mtime changes
local ssh_config_cache = { hosts = nil, mtime = nil }
local function get_ssh_config_hosts()
	local config_path = vim.fn.expand("~/.ssh/config")
	local mtime = vim.fn.getftime(config_path)
	if ssh_config_cache.hosts == nil or ssh_config_cache.mtime ~= mtime then
		local hosts = {}
		parse_ssh_config_file(config_path, hosts, {}, {})
		ssh_config_cache.hosts = hosts
		ssh_config_cache.mtime = mtime
	end
	return ssh_config_cache.hosts
end

-- Global completion function exposed to Neovim's completion engine
_G.RemotePatchComplete = function(arg_lead, _, _)
	local remote_host, path_prefix = arg_lead:match("^([^:]+):(.*)$")
	if not remote_host then
		local candidates = {}
		local added = {}

		local function add_candidate(spec)
			if spec ~= "" and not added[spec] and spec:sub(1, #arg_lead) == arg_lead then
				added[spec] = true
				table.insert(candidates, spec .. ":")
			end
		end

		if vim.g.last_remote_patch_spec then
			local last_host = vim.g.last_remote_patch_spec:match("^([^:]+):")
			if last_host then
				add_candidate(last_host)
			end
		end

		for _, entry in ipairs(get_ssh_config_hosts()) do
			if entry.user then
				add_candidate(entry.user .. "@" .. entry.host)
			end
			add_candidate(entry.host)
		end

		return candidates
	end

	local search_path = path_prefix
	if search_path == "" then
		search_path = "~/"
	end

	-- Autocomplete reuses active multiplexed socket instantly
	local cmd = string.format(
		'ssh %s -o ConnectTimeout=2 %s "ls -1d -p %s* 2>/dev/null"',
		ssh_opts,
		vim.fn.shellescape(remote_host),
		vim.fn.shellescape(search_path)
	)

	local results = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 or #results == 0 then
		return {}
	end

	local completions = {}
	for _, item in ipairs(results) do
		table.insert(completions, remote_host .. ":" .. item)
	end
	return completions
end

return {
	"nvim-lua/plenary.nvim",
	keys = {
		{ "<leader>cp", "<cmd>RemotePatch<cr>", desc = "Remote Patch (SSH Key)" },
		{ "<leader>cP", "<cmd>RemotePatch!<cr>", desc = "Remote Patch (Password)" },
	},
	config = function()
		local function collect_output(table_ref)
			return function(_, data)
				for _, line in ipairs(data) do
					if line ~= "" then
						table.insert(table_ref, line)
					end
				end
			end
		end

		local function run_action(action, remote_spec, password)
			local current_buf = vim.api.nvim_buf_get_name(0)
			if current_buf == "" then
				vim.notify("Current buffer must be saved to a file!", vim.log.levels.ERROR)
				return
			end

			local remote_host, remote_path = remote_spec:match("([^:]+):(.+)")
			if not remote_host or not remote_path then
				vim.notify("Invalid format! Use 'user@ip:/path/to/file'", vim.log.levels.ERROR)
				return
			end

			local filename = vim.fs.basename(remote_path)
			local patch_file = current_buf .. ".patch"

			local ssh_prefix = ""
			if password and password ~= "" then
				ssh_prefix = string.format("SSHPASS=%s sshpass -e ssh %s", vim.fn.shellescape(password), ssh_opts)
			else
				ssh_prefix = string.format("ssh %s", ssh_opts)
			end

			local remote_path_esc = vim.fn.shellescape(remote_path)
			local local_buf_esc = vim.fn.shellescape(current_buf)
			local patch_file_esc = vim.fn.shellescape(patch_file)

			-- Action: CREATE
			if action == "create" then
				local temp_remote = vim.fn.tempname()
				local temp_remote_esc = vim.fn.shellescape(temp_remote)

				vim.notify("Fetching remote file content...", vim.log.levels.INFO)

				local fetch_cmd =
					string.format('%s %s "cat %s" > %s', ssh_prefix, remote_host, remote_path_esc, temp_remote_esc)
				local fetch_output = {}

				vim.fn.jobstart({ "bash", "-c", fetch_cmd }, {
					on_stdout = collect_output(fetch_output),
					on_stderr = collect_output(fetch_output),
					on_exit = function(_, fetch_exit)
						if fetch_exit ~= 0 then
							vim.fn.delete(temp_remote)
							local err_msg = table.concat(fetch_output, "\n")
							if err_msg == "" then
								err_msg = "SSH connection failed (exit code " .. fetch_exit .. ")"
							end
							vim.notify(
								"❌ RemotePatch create failed (Fetch error):\n" .. err_msg,
								vim.log.levels.ERROR
							)
							return
						end

						local diff_cmd = string.format(
							'diff -u --label "a/%s" %s --label "b/%s" %s > %s',
							filename,
							temp_remote_esc,
							filename,
							local_buf_esc,
							patch_file_esc
						)
						local diff_output = {}

						vim.fn.jobstart({ "bash", "-c", diff_cmd }, {
							on_stdout = collect_output(diff_output),
							on_stderr = collect_output(diff_output),
							on_exit = function(_, diff_exit)
								vim.fn.delete(temp_remote)

								if diff_exit == 1 then
									vim.notify(
										"✅ RemotePatch create succeeded! Patch file generated.",
										vim.log.levels.INFO
									)
								elseif diff_exit == 0 then
									vim.notify(
										"⚠️ Local and remote files are identical. No diff needed.",
										vim.log.levels.WARN
									)
								else
									local err_msg = table.concat(diff_output, "\n")
									if err_msg == "" then
										err_msg = "Diff execution failed (exit code " .. diff_exit .. ")"
									end
									vim.notify(
										"❌ RemotePatch create failed (Diff error):\n" .. err_msg,
										vim.log.levels.ERROR
									)
								end
							end,
						})
					end,
				})
				return
			end

			-- Actions: APPLY / REVERT / CONFIRM
			local cmd = ""
			if action == "apply" then
				if vim.fn.filereadable(patch_file) == 0 then
					vim.notify("Patch file not found! Run 'create' first.", vim.log.levels.ERROR)
					return
				end
				cmd = string.format(
					'%s %s "patch --backup %s" < %s',
					ssh_prefix,
					remote_host,
					remote_path_esc,
					patch_file_esc
				)
			elseif action == "revert" then
				cmd = string.format(
					"%s %s \"if [ -f %s.orig ]; then mv %s.orig %s; else echo 'No backup found!'; false; fi\"",
					ssh_prefix,
					remote_host,
					remote_path_esc,
					remote_path_esc,
					remote_path_esc
				)
			elseif action == "confirm" then
				cmd = string.format(
					'%s %s "rm -f %s.orig %s~" && rm -f %s',
					ssh_prefix,
					remote_host,
					remote_path_esc,
					remote_path_esc,
					patch_file_esc
				)
			end

			vim.notify("Running Remote Patch (" .. action .. ")...", vim.log.levels.INFO)

			local output_chunks = {}
			vim.fn.jobstart({ "bash", "-c", cmd }, {
				on_stdout = collect_output(output_chunks),
				on_stderr = collect_output(output_chunks),
				on_exit = function(_, exit_code)
					if exit_code == 0 then
						vim.notify("✅ RemotePatch " .. action .. " succeeded!", vim.log.levels.INFO)
					else
						local err_msg = table.concat(output_chunks, "\n")
						if err_msg == "" then
							err_msg = "Command failed (exit code " .. exit_code .. ")"
						end
						vim.notify("❌ RemotePatch " .. action .. " failed:\n" .. err_msg, vim.log.levels.ERROR)
					end
				end,
			})
		end

		local function prompt_action(remote_spec, has_bang)
			local remote_host = remote_spec:match("([^:]+)")
			if not remote_host then
				vim.notify("Invalid format! Use 'user@ip:/path/to/file'", vim.log.levels.ERROR)
				return
			end

			vim.ui.select({ "create", "apply", "revert", "confirm" }, { prompt = "Select Action:" }, function(action)
				if not action then
					return
				end

				local socket_active = is_socket_active(remote_host)

				-- Only prompt for password if bang is passed AND no active session exists
				if has_bang and not socket_active then
					vim.ui.input({ prompt = "SSH Password: ", secret = true }, function(password)
						run_action(action, remote_spec, password)
					end)
				else
					if socket_active then
						vim.notify("⚡ Reusing active SSH session!", vim.log.levels.INFO)
					end
					run_action(action, remote_spec, nil)
				end
			end)
		end

		vim.api.nvim_create_user_command("RemotePatch", function(opts)
			if opts.args and opts.args ~= "" then
				vim.g.last_remote_patch_spec = opts.args
				prompt_action(opts.args, opts.bang)
				return
			end

			local default_remote = vim.g.last_remote_patch_spec or "test@172.16.24.195:/"

			vim.ui.input({
				prompt = "Remote spec (user@host:/path): ",
				default = default_remote,
				completion = "customlist,v:lua.RemotePatchComplete",
			}, function(remote_spec)
				if not remote_spec or remote_spec == "" then
					return
				end
				vim.g.last_remote_patch_spec = remote_spec
				prompt_action(remote_spec, opts.bang)
			end)
		end, {
			bang = true,
			nargs = "?",
			complete = "customlist,v:lua.RemotePatchComplete",
		})
	end,
}
