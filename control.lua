
---@type ModStorage
storage = storage

---@class player_index : integer
---@class surface_index : integer
---@class unit_number : integer
---@class bucket_key : integer
---@class tick_num : integer

---@class DisplayEntity : LuaEntity

---@class ModStorage
---@field all_displays table<unit_number, Display>
---@field poll_list Display[]
---@field poll_idx table<Display, integer>
---@field poll_cur integer
---@field buckets table<surface_index, table<bucket_key, Bucket>>
---@field draw_lists Bucket[]
---@field players table<player_index, Player>
---@field opened_guis table<unit_number, Display>
---@field need_rebuild boolean

---@class Display
---@field entity DisplayEntity
---@field ctrl LuaDisplayPanelControlBehavior?
---@field acs? table<defines.wire_connector_id.circuit_red|defines.wire_connector_id.circuit_green, LuaEntity?>
---@field [1] LuaEntity? -- ac1 (Use array since it's supposedly faster)
---@field [2] LuaEntity? -- ac2
---@field sid integer
---@field chunk_key bucket_key
---@field last_updated tick_num?

---@class Bucket -- Use array since it's supposedly faster
---@field [1] tick_num? -- last_updated
---@field [2] Display[] -- draw list
---@field [3] table<Display, bucket_key> -- draw list index map

---@class Player
---@field [any] any -- TODO:

local floor = math.floor
local ceil = math.ceil

local W = defines.wire_connector_id
local CR = defines.wire_connector_id.circuit_red
local CG = defines.wire_connector_id.circuit_green
local WO_SCRIPT = defines.wire_origin.script
local GT_ENTITY = defines.gui_type.entity
local RM_CHART = defines.render_mode.chart

-- example tich text:
-- [virtual-signal=signal-deny] [entity=big-biter]  [virtual-signal=signal-B]
-- [item=metallic-asteroid-chunk] [planet=gleba] [recipe=rocket-part] [fluid=crude-oil]
-- [item=parameter-2] [item=green-wire] [entity=entity-ghost] [quality=epic]"
local SIGNAL2RICH_TEXT = {
	--["item"]="item" -- actually nil in SignalID, so handled via nil check
	["fluid"]="fluid",
	["virtual"]="virtual-signal",
	["entity"]="entity",
	["recipe"]="recipe",
	["space-location"]="planet",
	["asteroid-chunk"]="item",
	["quality"]="quality"
}
local ANY_SIGNAL_COND = { first_signal={type="virtual", name="signal-anything"}, constant=0, comparator="≠" }

local AC_NEGATE_EACH_R = { ---@type ArithmeticCombinatorParameters
	first_signal={type="virtual", name="signal-each"}, second_constant=-1, operation="*", first_signal_networks={green=false},
	output_signal={type="virtual", name="signal-each"}
}
local AC_NEGATE_EACH_G = { ---@type ArithmeticCombinatorParameters
	first_signal={type="virtual", name="signal-each"}, second_constant=-1, operation="*", first_signal_networks={red=false},
	output_signal={type="virtual", name="signal-each"}
}


local CHART_KEY = 1 / 0  -- inf, can never collide with any real chunk key

-- MapPosition x/y  32bit with 8bits fractional => 24 bits units range (presumably signed)
-- => chunk_pos range is 2^23 / 32 => chunk pos should be [-262144, 262144)
-- chunks at y=0 are keys=[-CHUNK_HALF_RANGE, CHUNK_HALF_RANGE)
--           y=1 are keys=[CHUNK_HALF_RANGE, CHUNK_HALF_RANGE*3) and so on
local CHUNK_HALF_RANGE = 262144 -- 2^23 / 32
local CHUNK_RANGE = 524288 -- 2^24 / 32

---@param x integer
---@param y integer
---@returns bucket_key
local function chunk_key(x, y)
	-- x and y fit in double mantissa safely without collision
	return y * CHUNK_RANGE + x
end

---@param key bucket_key
---@returns integer, integer
local function chunk_key2pos(key)
	local x = key % CHUNK_RANGE
	local y = floor(key / CHUNK_RANGE)
	if x < CHUNK_HALF_RANGE then
		return x, y
	end
	return x - CHUNK_RANGE, y + 1
end

---@param entity LuaEntity
---@returns bucket_key
local function entity_chunk_pos(entity)
	local pos = entity.position
	return chunk_key(floor(pos.x / 32), floor(pos.y / 32))
end

local function _dbg_disp(display, col)
	local pos = display.position
	
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y-0.45 }, to={ x=pos.x+0.45, y=pos.y+0.45 }, color=col, width=2, surface=display.surface, time_to_live=1 }
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y+0.45 }, to={ x=pos.x+0.45, y=pos.y-0.45 }, color=col, width=2, surface=display.surface, time_to_live=1 }
	
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y-0.45 }, to={ x=pos.x+0.45, y=pos.y+0.45 }, color=col, width=6, surface=display.surface, time_to_live=1, render_mode="chart" }
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y+0.45 }, to={ x=pos.x+0.45, y=pos.y-0.45 }, color=col, width=6, surface=display.surface, time_to_live=1, render_mode="chart" }
end
local function _dbg_chunk(key, col)
	if key == CHART_KEY then return end
	
	local x,y = chunk_key2pos(key)
	local surf = game.get_player(1).surface
	
	local x0 = x*32 + 0.4
	local y0 = y*32 + 0.4
	local x1 = x*32 + 31.6
	local y1 = y*32 + 31.6
	
	rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y=y0 }, color=col, width=2, surface=surf, time_to_live=1 }
	rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y=y1 }, color=col, width=2, surface=surf, time_to_live=1 }
	rendering.draw_line{ from={ x=x1, y=y1 }, to={ x=x0, y=y1 }, color=col, width=2, surface=surf, time_to_live=1 }
	rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x0, y=y0 }, color=col, width=2, surface=surf, time_to_live=1 }
	
	rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y=y0 }, color=col, width=10, surface=surf, time_to_live=1, render_mode="chart" }
	rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y=y1 }, color=col, width=10, surface=surf, time_to_live=1, render_mode="chart" }
	rendering.draw_line{ from={ x=x1, y=y1 }, to={ x=x0, y=y1 }, color=col, width=10, surface=surf, time_to_live=1, render_mode="chart" }
	rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x0, y=y0 }, color=col, width=10, surface=surf, time_to_live=1, render_mode="chart" }
end
local function _dbg_AABB(x0,x1,y0,y1, surface, color)
	rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x0, y= y1 }, color=color, width=4, surface=surface, time_to_live=1 }
	rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y= y1 }, color=color, width=4, surface=surface, time_to_live=1 }
	rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y= y0 }, color=color, width=4, surface=surface, time_to_live=1 }
	rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x1, y= y1 }, color=color, width=4, surface=surface, time_to_live=1 }
end

---@param data Display
---@param list Display[]
---@param idxs table<Display, bucket_key>
local function add_to_array(data, list, idxs)
	assert(idxs[data] == nil)
	local idx = #list + 1
	list[idx] = data
	idxs[data] = idx
end
---@param data Display
---@param list Display[]
---@param idxs table<Display, bucket_key>
local function remove_from_array(data, list, idxs)
	-- delete by swap with last
	local idx = idxs[data]
	local last_idx = #list
	
	local last = list[last_idx]
	list[idx] = last
	idxs[last] = idx
	
	list[last_idx] = nil
	idxs[data] = nil
end

---@param disp Display
local function add_to_poll_list(disp)
	add_to_array(disp, storage.poll_list, storage.poll_idx)
end
---@param disp Display
local function remove_from_poll_list(disp)
	remove_from_array(disp, storage.poll_list, storage.poll_idx)
end

---@param surf table<integer, Bucket>
---@param key bucket_key
---@param disp Display
---@param insert boolean
---@returns boolean -- was_added
local function add_or_remove_in_bucket(surf, key, disp, insert)
	local bucket = surf[key]
	if insert then
		if not bucket then
			bucket = { [2]={}, [3]={} }
			surf[key] = bucket
			storage.need_rebuild = true
		end
		
		local idxs = bucket[3]
		if not idxs[disp] then
			add_to_array(disp, bucket[2], idxs)
			return true
		end
	elseif bucket then
		local idxs = bucket[3]
		if idxs[disp] then
			local list = bucket[2]
			remove_from_array(disp, list, idxs)
			
			if #list == 0 then
				surf[key] = nil
				storage.need_rebuild = true
			end
		end
	end
	return false
end

---@param surf table<integer, Bucket>
---@param key bucket_key
---@param disp Display
local function try_remove_from_bucket(surf, key, disp)
	local bucket = surf[key]
	if bucket then
		local idxs = bucket[3]
		if idxs[disp] then
			local list = bucket[2]
			remove_from_array(disp, list, idxs)
			
			if #list == 0 then
				surf[key] = nil
				storage.need_rebuild = true
			end
		end
	end
end

---@param e LuaEntity?
---@returns boolean
local function is_display_panel(e)
	return e and e.valid and e.type == "display-panel"
end

---@param c LuaWireConnector?
---@returns boolean
-- any circuit connection not going to hidden change detector
local function is_actually_connected(c)
	if not c then return false end
	local count = c.real_connection_count
	return count >= 2 or count >= 1 and c.real_connections[1].origin ~= WO_SCRIPT
end

local update_messages

---@param display DisplayEntity
---@param ctrl LuaDisplayPanelControlBehavior?
---@returns boolean
local function is_active_display(display, ctrl)
	-- need to return false if display not connected to circuit to avoid display updating despite no circuit
	-- (and overwriting static user message since ctrl.messages still exists despite being hidden)
	if display.valid and ctrl then
		for _,m in ipairs(ctrl.messages) do
			if m.icon and m.text and m.text:find("{[^{}]*}") then
				return true
			end
		end
	end
	return false
end

---@param data Display
local function reset_messages(data)
	local ctrl = data.ctrl
	if ctrl and ctrl.valid then
		for i,m in ipairs(ctrl.messages) do
			if m.text then
				m.text = m.text:gsub("{[^{}]*}", "{}")
				ctrl.set_message(i, m)
			end
		end
	end
	local display = data.entity
	if display and display.valid then
		display.display_panel_text = display.display_panel_text:gsub("{[^{}]*}", "{}")
	end
end

-- stop updating, clean messages so user can properly edit
---@param data Display
local function reset_display(data)
	-- reset messages even if not data yet, relevant for copy-pasted entities
	reset_messages(data)
	
	for _,ac in pairs(data.acs) do
		ac.destroy()
	end
	data.acs = {}
	data[1] = nil -- ac1
	data[2] = nil -- ac2
	
	local surf = storage.buckets[data.sid]
	if surf then
		try_remove_from_bucket(surf, CHART_KEY, data)
		try_remove_from_bucket(surf, data.chunk_key, data)
	end
end

-- start or stop updating display depending on if any messages contain format trigger {}
---@param display DisplayEntity
local function check_display(display)
	local id = display.unit_number ---@cast id -nil
	
	if storage.opened_guis[id] then
		return -- don't touch!
	end
	
	local data = storage.all_displays[id]
	if not data then
		script.register_on_object_destroyed(display)
		
		data = {
			entity = display,
			acs = {},
			sid = display.surface_index,
			chunk_key = entity_chunk_pos(display)
		}
		add_to_poll_list(data)
		storage.all_displays[id] = data
	end
	
	data.ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
	
	local active = is_active_display(display, data.ctrl)
	local need_update = false
	
	if active then
		local d_conns = display.get_wire_connectors(false)
		local acs = data.acs ---@cast acs -nil
		
		local function update_combinator(wire)
			local d_conn = d_conns and d_conns[wire]
			local ac = acs[wire]
			if (ac ~= nil) == is_actually_connected(d_conn) then
				return false -- nothing to do
			end
			
			if ac then
				ac.destroy()
				acs[wire] = nil
				return true
			end
			
			ac = display.surface.create_entity{
				name="hexcoder-signal-display-hidden-change-detector", force=display.force,
				position={display.position.x + (wire == CR and -0.4 or 0.4), display.position.y-1.5}, snap_to_grid=false,
				direction=defines.direction.north
			} ---@cast ac -nil
			ac.destructible = false
			
			local ctrl = ac.get_or_create_control_behavior() --[[@as LuaArithmeticCombinatorControlBehavior]]
			
			local ac_conn = ac.get_wire_connectors(true)
			
			if wire == CR then
				ctrl.parameters = AC_NEGATE_EACH_R
				ac_conn[W.combinator_input_red  ].connect_to(d_conn, false, WO_SCRIPT)
				ac_conn[W.combinator_input_green].connect_to(ac_conn[W.combinator_output_green], false, WO_SCRIPT)
			else
				ctrl.parameters = AC_NEGATE_EACH_G
				ac_conn[W.combinator_input_red  ].connect_to(ac_conn[W.combinator_output_red], false, WO_SCRIPT)
				ac_conn[W.combinator_input_green].connect_to(d_conn, false, WO_SCRIPT)
			end
			
			acs[wire] = ac
			return true
		end
		
		need_update = update_combinator(CR) or need_update
		need_update = update_combinator(CG) or need_update
		if need_update then
			if acs[CR] then
				data[1] = acs[CR]
				data[2] = acs[CG]
			else
				data[1] = acs[CG]
			end
		end
	end
	if active and data[1] then
		-- add to update appropriate update lists
		local surf = storage.buckets[data.sid]
		if not surf then
			script.register_on_object_destroyed(display.surface)
			surf = {}
			storage.buckets[data.sid] = surf
			storage.need_rebuild = true
		end
		
		need_update = add_or_remove_in_bucket(surf, CHART_KEY, data, display.display_panel_show_in_chart) or need_update
		need_update = add_or_remove_in_bucket(surf, data.chunk_key, data, display.display_panel_always_show) or need_update
		
		if need_update then
			-- ensure update, as change detection might not trigger after creation
			-- let future ticks be handled by change detection
			update_messages(data)
		end
	else
		reset_display(data)
	end
end

local deathrattles = {}
deathrattles[defines.target_type.entity] = function(event)
	local data = storage.all_displays[event.useful_id]
	if data then
		reset_display(data)
		remove_from_poll_list(data)
		storage.all_displays[event.useful_id] = nil
	end
end

local function _comp_signal(l, r)
	return l.count > r.count
end

-- TODO: use /editor to look at the exact tick delay my display has
-- change detection adds no delay, since I'm reading the current+previous signals directly (summed by the engine)
-- the engine either susm red+green on the API call or has the sum already cached, there's a chance that since the change detector.get_signals returns nil, it's fater than usual
-- writing the display message may get displayed in the tick, or next tick, I haven't checked
-- a circuit network might show iron=1 (was 0) on tick=0, a control behavior like a lamp turning on if iron>0 actually lights up one tick later at tick=1, my display matches this! (showing iron=1 at tick=1)
-- -> either get_signals add the delay, or setting the message, but I belive it should be the message
-- -> LuaEntity.get_signals supposedly is "current", ie the same as the the in-game gui should show

---@param data Display
update_messages = function(data)
	local display = data.entity
	-- display.display_panel_text and display.display_panel_icon
	-- are essentially variables that the player can config if the display is not connect to circuits
	-- when the display is connected to circuits they can configure circuit conditions
	-- and the first condition that is true overwrites the variables permanently
	-- sadly the API does not let us write display_panel_text if connected to circuits (maybe because the game itself updates this string later)
	-- so we have to permanently clobber the message texts/icons in the control behavior instead
	
	-- Message text is limited to (around?) 500 characters where rich text codes count all the individual chars
	-- It's limited in message edit GUI, when setting it from lua it's still cut off in game but extra chars persist when read in lua (? needs more testing)
	-- Alt view is limited to even less (it auto wraps into multiple lines, where only the first one shows unless hovered)
	-- If the 500 char limit cuts off inside a icon code, or before a color or font code close, it breaks the rich text
	-- It appears that the line cutoff logic is based on rendered width and never cuts off icons, but does not respect color and font ranges and tends to cut them off
	-- Here I avoid using color/font for more than one number
	-- I had a decent version of preventing exceeding 500 chars when showing multiple signals, but ran into the fact that the line cutoff still breaks color/font
	-- so it's pointless to do, I now let the game itself cutoff get_all_signals_text()
	
	-- don't update while gui is open, via check so we avoid having to mess with buckets which can cause rebuilds
	if storage.opened_guis[display.unit_number] then
		return -- don't touch!
	end
	
	-- skip double updates for alt/chart overlaps, or alt + hovered as it is cheap compared to actual update
	local tick = game.tick
	if game.tick == data.last_updated then
		return
	end
	data.last_updated = tick
	
	--_dbg_update(display)
	
	-- cache in case multiple messages exist
	local all_signals = nil
	
	---@param input string
	---@param count integer
	---@returns string
	local function format_count_text(input, count)
		local divisor, precision = input:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		--local num_format = precision and string.format("{ [font=default-bold]%%.%df[/font] }", precision) or "{ [font=default-bold]%d[/font] }"
		local num_format = precision and string.format("{ %%.%df }", precision) or "{ %d }"
		
		-- TODO: string.format + regex.gsub sounds close to optimal, but...
		-- since I'm now polling, it's acceptable to return the wrong result until the poll happens, so I can cache the format string based on the message
		-- which could remove the regex!
		return input:gsub("{[^{}]*}", string.format(num_format, count / div), 1)
	end
	
	---@param input string
	---@returns string
	local function get_all_signals_sum_text(input)
		all_signals = all_signals or display.get_signals(CR, CG)
		
		-- Is the the only way to do this?
		local count = 0
		if all_signals then
			for _,sig in ipairs(all_signals) do
				count = count + sig.count
			end
		end
		
		return format_count_text(input, count)
	end
	---@param input string
	---@returns string
	local function get_all_signals_text(input)
		all_signals = all_signals or display.get_signals(CR, CG)
		if not all_signals or next(all_signals) == nil then
			return input:gsub("{[^{}]*}", "{}", 1)
		end
		
		local limit = 17 -- 16+1
		all_signals[limit] = nil
		
		table.sort(all_signals, _comp_signal)
		
		-- TODO: I don't know performance characteristics of lua, but creating new strings might be slow
		-- -> consider optimizing by caching this in storage: /(%d+)f(%d+) -> form/formQ (via polling)
		
		-- support fixed point values: /1000f3 => signal=1234567 -> 123.457 (.4567 rounded to .457)
		-- don't support more variations due to heavy lua regex limitations
		local divisor, precision = input:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		local num_format = precision and string.format("%%.%df", precision) or "%d"
		
		-- rich text is: [item=copper-plate] or for non-normal quality: [item=copper-plate,quality=epic]
		local form = "%s [%s=%s] "..num_format
		local formQ = "%s [%s=%s,quality=%s] "..num_format
		
		-- the string.format here is needed every tick, but signals tend to not change that much, might be able to cache more here
		-- -> could cache [%s=%s,quality=%s] entirely, but unclear how what to use as key
		-- TODO: since items are most common and appear with sig.type=nil, could add fastpath for it instead of formatting in "item", not sur?
		local text = "{"
		for _,s in ipairs(all_signals) do
			local sig = s.signal
			local type = SIGNAL2RICH_TEXT[sig.type] or "item"
			if not sig.quality then
				text = string.format(form, text, type,sig.name, s.count/div)
			else
				text = string.format(formQ, text, type,sig.name,sig.quality, s.count/div)
			end
			-- TODO: stop after 10 items or so, or track string length at stop at 500 at the latest
			-- about 12 signals per line if each has count=1, and at ~20 I reach 500 char limit
		end
		
		-- TODO: supposedly pushing individual formatted strings into a list, then doing  table.concat(str_list) could be faster
		-- test this by disabling change detect and possibly using LuaProfiler?
		return input:gsub("{[^{}]*}", text.." }", 1)
	end
	---@param input string
	---@param icon SignalID
	---@returns string
	local function get_signal_text(input, icon)
		local count = display.get_signal(icon, CR, CG) or 0
		
		return format_count_text(input, count)
	end
	
	-- during tick handler, display_panel_text will be from last tick and the condition may cause a different text based on current signals
	-- the easy solution is to update all messages every tick
	
	local ctrl = data.ctrl
	if ctrl and ctrl.valid then
		for i,m in ipairs(ctrl.messages) do
			local icon = m.icon
			local text = m.text
			
			if text and icon.name then
				local virt_name = icon.type == "virtual" and icon.name or nil
				if virt_name == "signal-everything" then
					text = get_all_signals_sum_text(text)
				elseif virt_name == "signal-each" then
					text = get_all_signals_text(text)
				elseif virt_name == "signal-anything" then
					-- this is one tick behind (oI think?)
					-- yes -> it appears that if change detection only triggers on one tick, this can acutally get stuck displaying 0
					-- TODO: need to either figure out a way to do find the same icon that will appear in display_panel_icon without actually knowing
					-- or update for one more tick after change detect (ugh...)
					-- if I'm lucky display.get_signals(CR, CG)[1] is that signal...
					
					--local any_icon = display.display_panel_icon
					--if any_icon and any_icon.name then
					--	text = get_signal_text(text, any_icon)
					--end
					
					-- Seems to be working, the unsorted signals appear to be in a fixed order (order like in UI / internal ID order?)
					-- it's inefficient but I do change detection, so...!
					all_signals = all_signals or display.get_signals(CR, CG)
					
					local any_signal = all_signals and all_signals[1]
					local any_signal_count = any_signal and any_signal.count or 0
					text = format_count_text(text, any_signal_count)
				else
					-- show signal count
					text = get_signal_text(text, icon)
				end
				
				m.text = text
				ctrl.set_message(i, m)
			end
		end
	end
end

-- Tick for convenience feature
---@param display LuaEntity
local function tick_gui(display)
	local ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
	if ctrl then
		for i,m in ipairs(ctrl.messages) do
			if m.icon and m.icon.type == "virtual" then
				-- convenience feature: its annoying that when connecting circuit to display panel by default it shows nothing
				if m.text == nil and m.condition == nil then
					m.text = "{}"
					m.condition = ANY_SIGNAL_COND
					ctrl.set_message(i,m)
				end
			end
		end
	end
	-- ctrl.set_message(i,m) does not actually cause the gui to update
	-- if condition is not already fulfilled or something, this fixes that
	if not display.display_panel_always_show then
		display.display_panel_always_show = true
		display.display_panel_always_show = false
	end
end
script.on_nth_tick(12, function(event)
	for _,player in pairs(game.players) do
		local entity = player.opened_gui_type == GT_ENTITY and player.opened or nil --[[@as LuaEntity?]]
		if is_display_panel(entity) then ---@cast entity DisplayEntity
			tick_gui(entity)
		end
	end
end)

local view_margin = 3
-- unlike many games, zoom is not tied to vertical or horizontal fov/orthographic diameter
-- instead at zoom=1: 1 tile is drawn at 32 pixels at my specific window resolution, 2 is zoomed in to 1tile=64px
-- I hope this is actually correct for a all setups
local zoom_scale = 0.5/32 -- could listen to on_player_display_resolution_changed

local function rebuild_drawlists()
	local set = {}
	local draw_lists = {}
	local _total = 0
	
	local players = storage.players
	for _, player in pairs(game.connected_players) do
		local pl = players[player.index]
		if not pl then
			pl = {}
			players[player.index] = pl
		end
		
		local mode = player.render_mode
		local chart = mode == RM_CHART
		local alt = player.game_view_settings.show_entity_info
		pl[1] = mode
		
		local pos = player.position
		-- player chunk index
		local posX = floor(pos.x / 32)
		local posY = floor(pos.y / 32)
		
		local zoom = player.zoom
		local res = player.display_resolution
		--local scale = player.display_scale
		--local density = player.display_density_scale
		
		local f = zoom_scale / zoom
		-- player view
		local half_sizeX = ceil((res.width * f + view_margin) / 32)
		local half_sizeY = ceil((res.height * f + view_margin) / 32)
		
		--player.zoom_limits = {
		--	closest = { zoom = 4 },
		--	furthest = { distance = 800, max_distance = 1000 },
		--	furthest_game_view = { distance = 800, max_distance = 1000 }
		--}
		
		pl[3] = zoom
		pl[4] = posX
		pl[5] = posY
		pl.half_sizeX = half_sizeX
		pl.half_sizeY = half_sizeY
		pl.resX = res.width
		pl.resY = res.height
		
		-- visible chunk indexes, inclusive
		local x0 = posX - half_sizeX
		local x1 = posX + half_sizeX
		local y0 = posY - half_sizeY
		local y1 = posY + half_sizeY
		
		-- TODO: optimize via on_player_toggled_alt_mode + ?
		-- sadly chart mode does not seem to have en event? poll that one infrequently?
		local surf = storage.buckets[player.surface_index]
		if surf then
			
			pl[2] = false
			if chart then -- game view or char_zoomed_in render actual entities, chart is map mode
				local bucket = surf[CHART_KEY]
				if bucket and not set[bucket] then
					set[bucket] = bucket
					table.insert(draw_lists, bucket)
					_total = _total + #bucket[2]
				end
			elseif alt then
				pl[2] = true
				
				for y=y0,y1 do
					local keyY = CHUNK_RANGE*y
					for x=x0,x1 do
						local key = keyY+x
						local bucket = surf[key]
						if bucket and not set[bucket] then
							set[bucket] = bucket
							table.insert(draw_lists, bucket)
							_total = _total + #bucket[2]
						end
					end
				end
			end
		end
	end
		---- TODO: This should be optimized via on_selected_entity_changed and on_gui_opened/closed
		--local open_id = player.opened_gui_type == GT_ENTITY and player.opened.unit_number or nil
		--
		--local sel_id = player.selected and player.selected.unit_number
		--local data = sel_id and sel_id ~= open_id and storage.all_displays[sel_id] or nil
		--if data then ---@cast sel_id -nil
		--	extra_update[sel_id] = data
		--end
		--
		---- weird logic, and doens't even work if player 1 has ui open, and player 2 hovers it
		---- TODO: optimize by just not removing from update list on open, remove this check here, and then just skip if update_messages actually happens?
		--if open_id then
		--	extra_update[open_id] = nil
		--end
	storage.draw_lists = draw_lists
	
	game.print(string.format("rebuild_drawlists: at %d: buckets: %d displays: %d", game.tick, #draw_lists, _total))
end

script.on_event(defines.events.on_player_changed_position, function(event)
	-- player moved by one tile
	local id = event.player_index
	local pl = storage.players[id]
	if pl and pl[2] then
		local player = game.get_player(id) ---@cast player -nil
		local pos = player.position
		--local surf = player.surface
		--local ppos = player.physical_position
		--local psurf = player.physical_surface
		--game.print("on_player_changed_position: ".. serpent.line({ pos, surf, ppos, psurf, event }), {skip=defines.print_skip.never})
		
		-- if moved into another chunk while in map_view and 
		-- player chunk index
		local posX = floor(pos.x / 32)
		local posY = floor(pos.y / 32)
		if posX ~= pl[4] or posY ~= pl[5] then
			storage.need_rebuild = true
		end
	end
end)

script.on_event({
	defines.events.on_player_joined_game,
	defines.events.on_player_left_game,
	defines.events.on_player_respawned,
	defines.events.on_player_changed_surface,
	defines.events.on_player_controller_changed,
	defines.events.on_player_display_resolution_changed,
	--defines.events.on_player_display_scale_changed,
	defines.events.on_player_toggled_alt_mode,
}, rebuild_drawlists)

-- Choose to not react to undo/redo, blueprinting or wire changes even is technically possible via various techniques or libraries
-- but it is very, very complicated and not worth it over polling
-- I tried blueprint lib + perel + custom undo/redo handlers, and it still did not work correctly
-- polling checks all displays for possible changes, the cost is probably ok
-- not sure if there's any point to try to optimize this other than the rate
-- -> like somehow knowing when a display is more likely to need it, robots place things nearby, player is nearby etc.

local function polling(event)
	-- update entire list and thus each entity exactly once every period
	local period = 300 -- 5 seconds are bearable, and should keep the overhead low
	local list = storage.poll_list
	local ratio = (event.tick % period) + 1 -- +1 only works with tick freq=1, period must be divisible by this, so 1 is good
	local last = math.ceil((ratio / period) * #list)
	
	for i=storage.poll_cur,last do
		local e = list[i].entity
		if e and e.valid then
			check_display(list[i].entity)
			--_dbg_disp(list[i].entity, {.2,.2,1})
		end
	end
	
	if ratio == period then -- end of list reached
		storage.poll_cur = 1
	else
		storage.poll_cur = last+1
	end
end

local function optimized_update()
	
	local need_rebuild = storage.need_rebuild
	local players = storage.players
	
	local connected = game.connected_players
	for pi=1,#connected do
		local player = connected[pi]
		local pl = players[player.index]
		
		local mode = player.render_mode
		if not pl or mode ~= pl[1] then
			-- rebuild if player switched to/from char view
			need_rebuild = true
		elseif pl[2] then
			local zoom = player.zoom
			if zoom ~= pl[3] then
				local f = zoom_scale / zoom
				local half_sizeX = ceil((pl.resX * f + view_margin) / 32)
				local half_sizeY = ceil((pl.resY * f + view_margin) / 32)
				if half_sizeX ~= pl.half_sizeX or half_sizeY ~= pl.half_sizeY then
					need_rebuild = true
				end
				pl[3] = zoom
			end
			
			if pl[10] then
				update_messages(pl[10])
			end
		end
	end
	
	if need_rebuild --[[or (game.tick%300==0)]] then
		storage.need_rebuild = false
		rebuild_drawlists()
	end
	
	--for _, player in pairs(game.connected_players) do
	--	local pl = storage.players[player.index]
	--	local x0 = pl[4] - pl.half_sizeX
	--	local x1 = pl[4] + pl.half_sizeX
	--	local y0 = pl[5] - pl.half_sizeY
	--	local y1 = pl[5] + pl.half_sizeY
	--	_dbg_AABB(x0*32, x1*32+32, y0*32,y1*32+32, player.surface, {1,1,.2})
	--	
	--	x0 = x0+1
	--	x1 = x1-1
	--	y0 = y0+1
	--	y1 = y1-1
	--	_dbg_AABB(x0*32, x1*32+32, y0*32,y1*32+32, player.surface, {0,1,.2})
	--end
	
	local draw_lists = storage.draw_lists
	
	local tick = game.tick
	local last_tick = tick-1
	
	for b=1,#draw_lists do
		local bucket = draw_lists[b]
		local last_updated = bucket[1]
		local list = bucket[2]
		
		bucket[1] = tick
		
		--_dbg_chunk(entity_chunk_pos(list[1].entity), {1,.2,.2})
		
		if last_updated ~= last_tick then
			-- slowpath, chunk was not observed last tick
			-- Due to new chunk, alt mode toggle, enter/exit chart mode, surface switch, new player, player moved or zoomed etc.
			-- change detect ACs not valid since did not update this list last tick
			for i=1,#list do
				local data = list[i]
				update_messages(data)
				
				--_dbg_disp(data.entity, {.2,1,.2})
			end
		else
			-- fastpath, do circuit change detection
			for i=1,#list do
				local data = list[i]
				-- Cool optimization: edge detector AC, read combined inputs (current + negated_previous tick signals) if get_signals()=nil, then no change
				-- Need 2 to catch red and green wires, but second get_signals likely is rare
				-- This change detection only works if we also updated this display last tick!
				local b = data[2]
				if data[1].get_signals(CR, CG) or (b and b.get_signals(CR, CG)) then
					update_messages(data)
					
					--_dbg_disp(data.entity, {.2,1,.2})
				end
				--_dbg_disp(data.entity, {.2,1,.2})
			end
		end
	end
end

local _reset2

script.on_event(defines.events.on_tick, function(event)
	--if _reset2 then _reset2() end
	--_reset2 = nil
	
	polling(event)
	optimized_update()
end)

script.on_event(defines.events.on_selected_entity_changed, function(event)
	--game.print("on_selected_entity_changed: ".. serpent.line(event))
	local id = event.player_index
	local pl = storage.players[id]
	if pl then
		local player = game.get_player(id) ---@cast player -nil
		local e = player.selected
		pl[10] = e and storage.all_displays[e.unit_number]
	end
end)

local function on_entity_event(event)
	--game.print("on_entity_event: ".. serpent.line(event))
	local entity = event.entity or event.destination
	if is_display_panel(entity) then ---@cast entity DisplayEntity
		check_display(entity)
	end
end

script.on_event(defines.events.on_gui_opened, function(event)
	local entity = event.entity
	if is_display_panel(entity) then ---@cast entity DisplayEntity
		local pid = event.player_index
		local data = storage.all_displays[entity.unit_number]
		if data then
			local pl = storage.players[pid] or {}
			local open = storage.opened_guis or {}
			
			pl.open = entity
			open[entity.unit_number] = data
			
			storage.players[pid] = pl
			
			--reset_display(data) -- TODO: don't remove from buckets for efficiency, simply skip update in update_messages?
			reset_messages(data)
		end
	end
end)
script.on_event(defines.events.on_gui_closed, function(event)
	local entity = event.entity
	if is_display_panel(entity) then ---@cast entity DisplayEntity
		local pid = event.player_index
		local pl = storage.players[pid] or {}
		pl.open = nil
		storage.players[pid] = pl
		
		-- may be needed in multiplayer? sounds overkill
		for _, pl in pairs(storage.players) do
			if pl.open == entity then
				return -- still open
			end
		end
		
		local open = storage.opened_guis or {}
		open[entity.unit_number] = nil
		
		check_display(entity) -- reactivate display once no gui open
	end
end)

-- React to the all entity create events
for _, event in pairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned, -- source to destination
}) do
	script.on_event(event, on_entity_event, {{filter="type", type="display-panel"}})
end
-- React to the all simple entity settings paste
script.on_event(defines.events.on_entity_settings_pasted, on_entity_event) -- source to destination

deathrattles[defines.target_type.surface] = function(event)
	storage.buckets[event.useful_id] = nil
	rebuild_drawlists()
end
deathrattles[defines.target_type.player] = function(event)
	storage.players[event.useful_id] = nil
	rebuild_drawlists()
end
script.on_event(defines.events.on_object_destroyed, function(event)
	local handler = deathrattles[event.type]
	if handler then handler(event) end
end)

local function init()
	storage = {}
	storage.all_displays = {}
	storage.poll_list = {}
	storage.poll_idx = {}
	storage.poll_cur = 1
	storage.buckets = {}
	storage.draw_lists = {}
	storage.players = {}
	storage.opened_guis = {}
	storage.need_rebuild = true
	
	for _, surface in pairs(game.surfaces) do
		for _, display in ipairs(surface.find_entities_filtered{ type="display-panel" }) do ---@cast display DisplayEntity
			check_display(display)
		end
	end
end
local function _reset()
	for _, s in pairs(game.surfaces) do
		for _, name in pairs({"hidden-change-detector"}) do
			for _, e in pairs(s.find_entities_filtered{ name="hexcoder-signal-display-"..name }) do
				e.destroy()
			end
		end
	end
	
	init()
end
script.on_configuration_changed(function(data)
	local changes = data.mod_changes["hexcoder-signal-display"]
	if not changes then return end
	_reset()
end)

-- removed to not clutter up /help
commands.add_command("hexcoder-signal-display-reset", nil, function(command)
	_reset()
end)

_reset2 = _reset
