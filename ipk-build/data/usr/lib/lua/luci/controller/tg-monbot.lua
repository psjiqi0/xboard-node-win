-- tg-monbot LuCI controller
-- 提供: 配置面板(模板, 含启停控制按钮) + action 控制
-- 菜单不显示入口, 但路由有效,
-- 可直接通过 http://<ip>/cgi-bin/luci/admin/services/tg-monbot 访问
module("luci.controller.tg-monbot", package.seeall)

function index()
	if not nixio.fs.access("/etc/tg-monbot/config.json") then
		return
	end

	entry({"admin", "services", "tg-monbot"},
		call("index_page"), nil, 94).dependent = true

	entry({"admin", "services", "tg-monbot", "start"},
		call("action_ctl"), nil, 1).leaf = true
	entry({"admin", "services", "tg-monbot", "stop"},
		call("action_ctl"), nil, 2).leaf = true
	entry({"admin", "services", "tg-monbot", "restart"},
		call("action_ctl"), nil, 3).leaf = true
end

local function read_json()
	local j = require("luci.json")
	local f = io.open("/etc/tg-monbot/config.json", "r")
	if not f then
		return {}
	end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(j.decode, content)
	if ok and type(data) == "table" then
		return data
	end
	return {}
end

local function write_json(data)
	local j = require("luci.json")
	local f = io.open("/etc/tg-monbot/config.json", "w")
	if not f then
		return false
	end
	f:write(j.encode(data))
	f:close()
	return true
end

function index_page()
	if luci.http.formvalue("save") then
		local cfg = read_json()
		local v = luci.http.formvalue("bot_token")
		if v then cfg.bot_token = v end
		v = luci.http.formvalue("chat_id")
		if v and v ~= "" then
			local num = tonumber(v)
			cfg.chat_id = num or 0
		end
		v = luci.http.formvalue("monitor_on")
		cfg.monitor_on = (v == "1")
		local au = luci.http.formvalue("allowed_users")
		local users = {}
		if au then
			for one in au:gmatch("[^,]+") do
				one = one:gsub("^%s+", ""):gsub("%s+$", "")
				if one ~= "" and tonumber(one) then
					table.insert(users, tonumber(one))
				end
			end
		end
		cfg.allowed_users = users
		write_json(cfg)
		luci.http.redirect(luci.dispatcher.build_url("admin/services/tg-monbot"))
		return
	end

	-- router add/remove actions
	local act = luci.http.formvalue("router_act")
	if act == "add" then
		local cfg = read_json()
		local name = (luci.http.formvalue("r_name") or ""):gsub("%s+", "")
		local host = luci.http.formvalue("r_host") or ""
		local port = tonumber(luci.http.formvalue("r_port")) or 22
		local user = luci.http.formvalue("r_user") or ""
		local pass = luci.http.formvalue("r_pass") or ""
		if name ~= "" and host ~= "" and user ~= "" then
			local id = (name:lower():gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", ""))
			if id == "" then id = "router" end
			cfg.routers = cfg.routers or {}
			cfg.routers[#cfg.routers + 1] = {
				id = id, name = name, host = host,
				port = port, username = user, password = pass
			}
			write_json(cfg)
		end
		luci.http.redirect(luci.dispatcher.build_url("admin/services/tg-monbot"))
		return
	elseif act == "del" then
		local cfg = read_json()
		local rid = luci.http.formvalue("router_id") or ""
		local out = {}
		for _, r in ipairs(cfg.routers or {}) do
			if r.id ~= rid then
				out[#out + 1] = r
			end
		end
		cfg.routers = out
		write_json(cfg)
		luci.http.redirect(luci.dispatcher.build_url("admin/services/tg-monbot"))
		return
	end

	luci.template.render("tg-monbot/control",
		{ token = luci.dispatcher.context.authtoken,
		  cfg = read_json() })
end

function action_ctl()
	local node = luci.dispatcher.context.path[#luci.dispatcher.context.path]
	local action = "restart"
	if node == "start" then
		action = "start"
	elseif node == "stop" then
		action = "stop"
	end

	os.execute("/etc/init.d/tg-monbot " .. action .. " >/dev/null 2>&1")

	luci.http.redirect(luci.dispatcher.build_url("admin/services/tg-monbot"))
end
