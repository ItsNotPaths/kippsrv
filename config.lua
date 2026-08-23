-- kippsrv. Two window managers are shown; keep the one you run.
--
-- Every source names an adapter. An adapter file is loaded once however many
-- sources name it, so a seed and its stream share one state.
--
-- $VAR and ~ are expanded by kippsrv, so this file never reads the
-- environment and nothing in it can reach a variable it was not given.

return {
	socket = "$XDG_RUNTIME_DIR/kippsrv.sock",
	state  = "$XDG_RUNTIME_DIR/kippsrv.state",

	sources = {
		-- The tray. Owning the name needs compiled code; naming the kind
		-- does not, so the registrations arrive at an adapter like anything
		-- else.
		{ name = "tray", watcher = true, adapter = "lua/tray/snw.lua" },

		-- Hyprland. The first reads what is true now, the second the changes.
		{ name = "wm-seed", adapter = "lua/wm/hypr.lua",
		  exec = {"hyprctl", "monitors", "-j"} },

		{ name = "wm", adapter = "lua/wm/hypr.lua",
		  sock = "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" },

		-- dwl hands its status to one child, so kippsrv is that child.
		-- { name = "wm", adapter = "lua/wm/dwl.lua", exec = {"dwl", "-s", "cat"} },

		-- sway and i3 frame their messages with a length prefix. NOT YET
		-- USABLE: lua/wm/i3.lua reads a reply to GET_WORKSPACES, and nothing
		-- sends that request. It needs the outbound command path, and
		-- handling for subscribed events, whose type has the high bit set.
		-- { name = "wm", adapter = "lua/wm/i3.lua", sock = "$SWAYSOCK",
		--   framing = {kind = "prefix", header = 14, at = 6, width = 4, le = true} },

		{ name = "net", adapter = "lua/net/nm.lua",
		  exec = {"nmcli", "-t", "-f", "UUID,NAME,TYPE,DEVICE", "connection", "show"},
		  every = 5000 },

		-- steady: a person drives these. Backing off would mean pressing the
		-- volume key and waiting up to 32 s for the bar to notice. Both of
		-- these are polls that should not exist at all: volume is a PipeWire
		-- subscription, and /sys/class/backlight/*/brightness is watchable.
		{ name = "audio", adapter = "lua/audio/pw.lua", steady = true,
		  exec = {"pactl", "list", "short", "sinks"}, every = 2000 },

		{ name = "backlight", adapter = "lua/backlight/brightnessctl.lua",
		  steady = true, exec = {"brightnessctl", "-m"}, every = 2000 },
	},
}
