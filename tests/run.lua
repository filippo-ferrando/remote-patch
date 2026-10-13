-- nvim -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local rp = require("remote-patch")

-- remote path quoting keeps ~/ expandable and survives quotes/$
assert(rp.rpath("/etc/a b") == "'/etc/a b'")
assert(rp.rpath("~/x$y") == "~/'x$y'")
assert(rp.rpath("/it's") == [['/it'\''s']])

-- spec parsing
local h, p = rp.parse_spec(" root@box:/etc/hosts ")
assert(h == "root@box" and p == "/etc/hosts")
assert(rp.parse_spec("box:") == nil and rp.parse_spec("nocolon") == nil)

-- ssh config: wildcards skipped, Key=Value, first User wins, relative Include
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/conf.d", "p")
vim.fn.writefile({ "Host web db", "  User=deploy", "  User ignored", "Host *", "  User star", "Include " .. dir .. "/conf.d/*" }, dir .. "/config")
vim.fn.writefile({ "Host extra" }, dir .. "/conf.d/x")
local hosts, seen = {}, {}
rp._parse_ssh_config(dir .. "/config", hosts, seen, {})
assert(#hosts == 3, #hosts)
assert(seen.web.user == "deploy" and seen.db.user == "deploy" and seen.extra.user == nil)

-- command completion: actions first, then hosts
local c = rp.complete_cmd("cr", "RemotePatch cr", 14)
assert(c[1] == "create", vim.inspect(c))

-- buffer text round trip (dos line endings, trailing newline)
local b = vim.api.nvim_create_buf(false, true)
vim.bo[b].fileformat = "dos"
rp._set_buf_text(b, "a\r\nb\r\n")
assert(rp._buf_text(b) == "a\r\nb\r\n", vim.inspect(rp._buf_text(b)))

-- conflict block under cursor -> local / remote / both
local conflict = { "x", "<<<<<<< local", "L", "=======", "R", ">>>>>>> remote", "y" }
for which, want in pairs({ ["local"] = "x L y", remote = "x R y", both = "x L R y" }) do
	vim.api.nvim_buf_set_lines(0, 0, -1, false, conflict)
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	rp._take(which)
	local got = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), " ")
	assert(got == want, which .. ": " .. got)
end
print("ok")
