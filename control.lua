--[[
This is a mod that makes display panels able to show circuit signal counts in real time by inserting text into '{}' found in the display messages
Showing all signals sorted like the game guis do when hovering is fully supported
The game sadly limits the string to 500 characters, this is a maximum of around 20 signals (less if the numbers are big)
In alt mode there is an additional limitation in pixel width of what is considered one line, this is a maximum of around 12 signals

-- Number formatting:

*Show the raw integer by default
*I currently choose not to display large number as 1.0k or 5M like the game does, but if wanted this could be implemented
*Instead I do support fixed point values, which I often use with circuit (ex 1.23 is represented as a signal of 1230)
 to use this put something like /1000f3 _anywhere_ inside the message and signal=1234567 becomes 123.457 (.4567 rounds to .457)
 the format is /<divisor>f<precision>
  no spaces allowed, I'd support more flexibility but lua regexes are very limited
  divisor can be int (1000) or float (0.1) and can be negative, precision must be an int

-- Change detection:

I use one hidden arithmetic combinator per wire connected to the display panel for change detection (each*-1=>each wired to it's other input wire)
This allows me to check when to update the messages with a single API call, allowing hundreds of displays to be on-screen wiht minimal tick cost if they update infrequently

currently I detect changes to all signals even if only a single signal is shown, could seperate them out but would still need 1 API call either way TODO: test perf of that?

this adds no delay, since I'm reading the current+previous circuit signals directly of the entity (summed by the engine)
sadly on the engine side it likely sums the signals every time, but best case there are no changes and it returns nil, which should be good for performance
writing the display message add one tick of delay, this sounds bad, but control behaviors also all only happen one tick after the signal appears
This means my display actualy updates in sync with eg. a circuit enabled lamps turning on, but it is one tick delays compared to the game gui showing signals

note that this combiator-based change detection only works if tested every tick, so when displays become visibile I have to fall back to full updates

-- TODO: checking a specific signal might be cheaper then checking all for nil and getting that in a memory cell would eliminate slowpath
         but probably not possible without tick delay, which is my goal

-- Visibility optimization:

I seperate displays into lists depending on the surface, their display mode (hover-only, chart, alt or chart+alt), and recently also their chunk position
I check all players using events where possible, zoom and render mode are checked every tick
Displays are tracked based on 32-tile chunks per surface, called buckets here, any chart-mode displays go into a special single bucket
I determine the exact view AABBs based on zoom level and find visible chunks, player movment and zoom use minimal code to find when visible chunks change
If player has walked or zoomed enough, the list of unique buckets is rebuilt fully
The main drawing code based on these draw lists is then pretty fast

]]

local DEBUG = false

-- Limit max signals for Everything (sum) and Each (list) modes for performance
-- TODO: could make this configurable
local MAX_SIGNALS = 16
local POLL_PERIOD

---@type ModStorage
storage = storage

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

-- MapPosition x/y are signed 32bit with 8bits fractional => signed 24 bit tiles range
-- => chunk_pos range could be +-2^23 / 32 (19 bit) => chunk pos in [-262144, 262144)
-- But actually the map is limited to exactly +-1,000,000, with a few chunks around that still generating, so chunks should safely fit in +- 2^15
-- chunks at y=0 are keys=[-CHUNK_HALF_RANGE, CHUNK_HALF_RANGE)
--           y=1 are keys=[CHUNK_HALF_RANGE, CHUNK_HALF_RANGE*3) and so on
--local CHUNK_HALF_RANGE = 262144 -- 2^23 / 32
--local CHUNK_RANGE = 524288 -- 2^24 / 32
local CHUNK_RANGE = 65536 -- 2^16

-- Special bucket key for all chart mode displays
local CHART_KEY = 1 / 0  -- inf

---@param x integer
---@param y integer
---@return bucket_key
local function chunk_key(x, y)
	-- x and y fit in double mantissa safely without collision
	-- reversing this requires is a bit arkward due to negative x values (divmod + if) I think this could be fixed by biasing via x+CHUNK_RANGE/2
	return y * CHUNK_RANGE + x --[[@as bucket_key]]
end

---@param key bucket_key
---@return integer, integer
local function chunk_key2pos(key)
	local x = key % CHUNK_RANGE
	local y = floor(key / CHUNK_RANGE)
	if x < CHUNK_RANGE/2 then
		return x, y
	end
	return x - CHUNK_RANGE, y + 1
end

---@param entity LuaEntity
---@return bucket_key
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
local function _dbg_bucket(bucket, col, time)
	local key = bucket.chunk_key
	if key == CHART_KEY then return end
	
	local x,y = chunk_key2pos(key)
	local surf = bucket.surfID
	
	local x0 = x*32 + 0.4
	local y0 = y*32 + 0.4
	local x1 = x*32 + 31.6
	local y1 = y*32 + 31.6
	
	time = time or 1
	rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y=y0 }, color=col, width=2, surface=surf, time_to_live=time }
	rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y=y1 }, color=col, width=2, surface=surf, time_to_live=time }
	rendering.draw_line{ from={ x=x1, y=y1 }, to={ x=x0, y=y1 }, color=col, width=2, surface=surf, time_to_live=time }
	rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x0, y=y0 }, color=col, width=2, surface=surf, time_to_live=time }
	
	rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y=y0 }, color=col, width=10, surface=surf, time_to_live=time, render_mode="chart" }
	rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y=y1 }, color=col, width=10, surface=surf, time_to_live=time, render_mode="chart" }
	rendering.draw_line{ from={ x=x1, y=y1 }, to={ x=x0, y=y1 }, color=col, width=10, surface=surf, time_to_live=time, render_mode="chart" }
	rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x0, y=y0 }, color=col, width=10, surface=surf, time_to_live=time, render_mode="chart" }
end

---@param data Display
---@param list Display[]
---@param idxs table<Display, integer>
local function add_to_array(data, list, idxs)
	assert(idxs[data] == nil)
	local idx = #list + 1
	list[idx] = data
	idxs[data] = idx
end
---@param data Display
---@param list Display[]
---@param idxs table<Display, integer>
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

---@param surf SurfaceBuckets
---@param key bucket_key
---@param disp Display
---@param insert boolean
---@return Bucket?
local function add_or_remove_in_bucket(surf, key, disp, insert)
	local bucket = surf[key]
	if insert then
		if not bucket then
			bucket = { draw_list={}, indexes={}, chunk_key=key, surfID=surf._surfID }
			surf[key] = bucket
			storage.need_rebuild = true
		end
		
		local idxs = bucket.indexes
		if not idxs[disp] then
			add_to_array(disp, bucket.draw_list, idxs)
		end
		return bucket -- is in bucket
	elseif bucket then
		local idxs = bucket.indexes
		if idxs[disp] then
			local list = bucket.draw_list
			remove_from_array(disp, list, idxs)
			
			if #list == 0 then
				surf[key] = nil
				storage.need_rebuild = true
			end
		end
	end
	return nil -- is not in bucket
end

local update_messages -- forward declare
local cache_format

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

---@param e LuaEntity?
---@return boolean
local function is_display_panel(e)
	return e and e.valid and e.type == "display-panel" or false
end

-- stop updating, destroy ACs and clean messages
---@param data Display
local function reset_display(data)
	-- reset messages even if not data yet, relevant for copy-pasted entities
	reset_messages(data)
	
	if data.acR then data.acR.destroy() end
	if data.acG then data.acG.destroy() end
	data.acR = nil
	data.acG = nil
	
	local surf = storage.buckets[data.sid]
	if surf then
		data.chart = add_or_remove_in_bucket(surf, CHART_KEY, data, false)
		data.alt = add_or_remove_in_bucket(surf, data.chunk_key, data, false)
	end
end

---@param id unit_number
local function delete_display(id)
	local data = storage.all_displays[id]
	if data then
		reset_display(data)
		remove_from_poll_list(data)
		storage.all_displays[id] = nil
		
		storage.opened_guis[id] = nil
	end
end

---@param display DisplayEntity
---@param ac LuaEntity?
---@param wire defines.wire_connector_id
---@param disp_conn LuaWireConnector
---@return LuaEntity?
local function update_combinator(display, ac, wire, disp_conn)
	if ac then
		ac.destroy()
		return nil
	end
	
	ac = display.surface.create_entity({
		name="hexcoder-signal-display-hidden-change-detector", force=display.force,
		position={display.position.x + (wire == CR and -0.4 or 0.4), display.position.y-1.5}, snap_to_grid=false,
		direction=defines.direction.north
	}) --[[@as LuaEntity]]
	ac.destructible = false
	
	local ctrl = ac.get_or_create_control_behavior() --[[@as LuaArithmeticCombinatorControlBehavior]]
	local ac_conn = ac.get_wire_connectors(true)
	
	if wire == CR then
		ctrl.parameters = AC_NEGATE_EACH_R
		ac_conn[W.combinator_input_red  ].connect_to(disp_conn, false, WO_SCRIPT)
		ac_conn[W.combinator_input_green].connect_to(ac_conn[W.combinator_output_green], false, WO_SCRIPT)
	else
		ctrl.parameters = AC_NEGATE_EACH_G
		ac_conn[W.combinator_input_red  ].connect_to(ac_conn[W.combinator_output_red], false, WO_SCRIPT)
		ac_conn[W.combinator_input_green].connect_to(disp_conn, false, WO_SCRIPT)
	end
	
	return ac
end

-- lazy init display data, manage hidden change detector ACs
-- and start or stop updating display depending on settings and wire connections
---@param display DisplayEntity
local function update_display(display)
	local id = display.unit_number ---@cast id -nil
	if storage.opened_guis[id] then
		return -- don't touch!
	end
	
	if DEBUG and display and display.valid then _dbg_disp(display, {.2,.2,1}) end
	
	-- create Display data if not seen yet (built or init/migrate)
	local data = storage.all_displays[id]
	if not data then
		-- Cache wire connectors to avoid API call on polling
		local conns = display.get_wire_connectors(true)
		-- cache control behavior as well, unclear if creating if even if not needed is bad in any way
		-- Prevously I called get_control_behavior and checked nil, I belive that can happen while not yet connected to circuits
		-- Both of these are probably ok to optimize a mod, unlikely that users even have that many display panels in total
		local ctrl = display.get_or_create_control_behavior() --[[@as LuaDisplayPanelControlBehavior]]
		
		data = {
			entity = display,
			sid = display.surface_index,
			chunk_key = entity_chunk_pos(display),
			ctrl = ctrl,
			connR = conns[CR],
			connG = conns[CG],
			message_cache = {}
		}
		
		script.register_on_object_destroyed(display)
		storage.all_displays[id] = data
		add_to_poll_list(data)
		
		-- lazily-create surface data here to avoid doing it during polling
		if not storage.buckets[data.sid] then
			script.register_on_object_destroyed(display.surface)
			storage.buckets[data.sid] = { _surfID=data.sid }
			storage.need_rebuild = true
		end
	end
	
	local ctrl = data.ctrl
	local activeR = data.acR ~= nil
	local activeG = data.acG ~= nil
	
	local is_active = false
	
	-- check if display actually has messages to update, if not reset
	local messages = ctrl.messages
	local message_cache = {}
	for i=1,#messages do local m = messages[i]
		local cached = { text=m.text, icon=m.icon }
		if m.icon and m.text and m.text:find("{[^{}]*}") then
			cache_format(cached, m)
			is_active = true
		end
		message_cache[i] = cached
	end
	data.message_cache = message_cache
	
	if is_active then
		local connR = data.connR
		local countR = connR.real_connection_count
		local actually_connectedR = countR >= 2 or countR >= 1 and connR.real_connections[1].origin ~= WO_SCRIPT
		if activeR ~= actually_connectedR then
			data.acR = update_combinator(display, data.acR, CR, data.connR)
			activeR = data.acR ~= nil
		end
		
		local connG = data.connG
		local countG = connG.real_connection_count
		local actually_connectedG = countG >= 2 or countG >= 1 and connG.real_connections[1].origin ~= WO_SCRIPT
		if activeG ~= actually_connectedG then
			data.acG = update_combinator(display, data.acG, CG, data.connG)
			activeG = data.acG ~= nil
		end
		
		is_active = activeR or activeG
	end
	if is_active then
		-- add to update appropriate update lists
		local surf = storage.buckets[data.sid]
		if not surf then
			script.register_on_object_destroyed(display.surface)
			surf = { _surfID=data.sid }
			storage.buckets[data.sid] = surf
			storage.need_rebuild = true
		end
		
		data.chart = add_or_remove_in_bucket(surf, CHART_KEY, data, display.display_panel_show_in_chart)
		data.alt = add_or_remove_in_bucket(surf, data.chunk_key, data, display.display_panel_always_show)
		
		-- ensure update, as change detection might not trigger after creation
		-- let future ticks be handled by change detection
		update_messages(data)
	else
		reset_display(data)
	end
end

---@param data Display
---@param entity DisplayEntity
---@return boolean
local function display_was_modified(data, entity)
	local cached = data.message_cache
	local messages = data.ctrl.messages
	for i=1,#messages do
		local m = messages[i]
		local c = cached[i]
		local mi = m.icon
		local ci = c.icon
		if m.text ~= c.text then return true end
		if mi ~= nil then
			if ci == nil or not (mi.type == ci.type and mi.name == ci.name and mi.quality == ci.quality) then
				return true
			end
		else
			if ci ~= nil then return true end
		end
	end
	
	local activeR = data.acR ~= nil
	local activeG = data.acG ~= nil
	
	if activeR or activeG then
		local connR = data.connR
		local countR = connR.real_connection_count
		local actually_connectedR = countR >= 2 or countR >= 1 and connR.real_connections[1].origin ~= WO_SCRIPT
		if activeR ~= actually_connectedR then
			return true
		end
		
		local connG = data.connG
		local countG = connG.real_connection_count
		local actually_connectedG = countG >= 2 or countG >= 1 and connG.real_connections[1].origin ~= WO_SCRIPT
		if activeG ~= actually_connectedG then
			return true
		end
		
		if (data.chart ~= nil) ~= entity.display_panel_show_in_chart then
			return true
		end
		if (data.alt ~= nil) ~= entity.display_panel_always_show then
			return true
		end
	end
	
	return false
end

----

local function _comp_signal(l, r)
	return l.count > r.count
end

-- Cache format strings as determining them is quite complex because of my fixed point format support
-- This updates during check ie. during setup and edits but also when polling
---@param message DisplayPanelMessageDefinition
---@param cached Message
cache_format = function(cached, message)
	-- fixed-point display support, accept this anywhere inside the message
	-- ideally would be to put it into {} but then I'd have to avoid replacing it in the regex gsub
	local divisor, precision = message.text:match("/(%d+)f(%d+)")
	if divisor then
		cached.div = tonumber(divisor)
		
		cached.num_form = precision and string.format("{ %%.%df }", precision)
		
		local num_format2 = precision and string.format("%%.%df", precision)
		
		-- rich text is: [item=copper-plate] or for non-normal quality: [item=copper-plate,quality=epic]
		cached.form = "%s [%s=%s] "..num_format2
		cached.formQ = "%s [%s=%s,quality=%s] "..num_format2
	end
end

---@param input string
---@param count integer
---@param F Message
---@return string, _
local function format_count_text(input, count, F)
	local num_form = F.num_form or "{ %d }"
	local div = F.div or 1
	
	-- TODO: string.format + regex.gsub sounds close to optimal, but...
	-- TODO: since I now cache num_form in polling I could also cache the entire format string instead
	-- which would remove the regex!
	return input:gsub("{[^{}]*}", string.format(num_form, count / div), 1)
end
---@param input string
---@param all_signals Signal[]?
---@param F Message
---@return string, _
local function get_all_signals_sum_text(input, all_signals, F)
	-- Is the the only way to do this?
	local count = 0
	if all_signals then
		for _,sig in ipairs(all_signals) do
			count = count + sig.count
		end
	end
	
	return format_count_text(input, count, F)
end
---@param input string
---@param all_signals Signal[]?
---@param F Message
---@return string, _
local function get_all_signals_text(input, all_signals, F)
	if not all_signals or all_signals[1] == nil then
		return input:gsub("{[^{}]*}", "{}", 1)
	end
	
	table.sort(all_signals, _comp_signal)
	
	-- limit signals to 16 for now, as only about that much fit in 500 char limit anyway
	all_signals[MAX_SIGNALS+1] = nil
	
	local form = F.form or "%s [%s=%s] %d"
	local formQ = F.formQ or "%s [%s=%s,quality=%s] %d"
	local div = F.div or 1
	
	-- the string.format here is needed every tick, but signals tend to not change that much, might be able to cache more here
	-- -> could cache [%s=%s,quality=%s] entirely, but unclear how to construct key fast
	local text = "{"
	for _,s in ipairs(all_signals) do
		local sig = s.signal
		local type = sig.type
		local typeS = type and SIGNAL2RICH_TEXT[type] or "item"
		local Q = sig.quality
		if Q then
			text = string.format(formQ, text, typeS, sig.name, Q, s.count/div)
		else
			text = string.format(form, text, typeS, sig.name, s.count/div)
		end
	end
	
	-- TODO: supposedly pushing individual formatted strings into a list, then doing  table.concat(str_list) could be faster
	-- test this by disabling change detect and possibly using LuaProfiler?
	return input:gsub("{[^{}]*}", text.." }", 1)
end

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
	
	if DEBUG then _dbg_disp(data.entity, {.2,1,.2}) end
	
	-- cache in case multiple messages exist
	local all_signals = nil
	
	-- during tick handler, display_panel_text will be from last tick and the condition may cause a different text based on current signals
	-- the easy solution is to update all messages every tick
	
	local ctrl = data.ctrl
	local cached = data.message_cache
	
	for i,m in ipairs(ctrl.messages) do
		local icon = m.icon
		local text = m.text
		local cached_msg = cached[i]
		
		if text and icon.name and cached_msg then
			local name = icon.name
			if icon.type == "virtual" then
				if name == "signal-each" then
					all_signals = all_signals or display.get_signals(CR, CG)
					
					text = get_all_signals_text(text, all_signals, cached_msg)
				elseif name == "signal-everything" then
					all_signals = all_signals or display.get_signals(CR, CG)
					
					text = get_all_signals_sum_text(text, all_signals, cached_msg)
				elseif name == "signal-anything" then
					
					-- this is one tick behind (I think?)
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
					local any_signal_count = 0
					if all_signals then
						local any_signal = all_signals[1]
						if any_signal then
							any_signal_count = any_signal.count
						end
					end
					text = format_count_text(text, any_signal_count, cached_msg)
				else
					-- show virtual signal count
					local count = display.get_signal(icon, CR, CG) or 0
					text = format_count_text(text, count, cached_msg)
				end
			else
				-- show signal count
				local count = display.get_signal(icon, CR, CG) or 0
				text = format_count_text(text, count, cached_msg)
			end
			
			m.text = text
			cached_msg.text = text
			ctrl.set_message(i, m)
		end
	end
end

local view_margin = 3 -- absolute extra tiles around screen to render, probably not perfect
-- unlike many games, zoom is not tied to aspect ration, instead being directly related to resolution
-- at zoom=1: 1 tile == 32 pixels, zoom=2 1 tile == 64 pixels
local zoom_scale = 0.5/32 -- could listen to on_player_display_resolution_changed

local function rebuild_drawlists()
	local draw_lists = {}
	
	local players = storage.players
	for _, player in pairs(game.connected_players) do
		local pl = players[player.index] or {}
		
		local mode = player.render_mode
		local chart = mode == RM_CHART
		local alt = player.game_view_settings.show_entity_info
		pl.render_mode = mode
		
		local pos = player.position
		-- player chunk index
		local posX = floor(pos.x / 32)
		local posY = floor(pos.y / 32)
		
		local zoom = player.zoom
		local res = player.display_resolution
		-- what does these actually do? my zoom computation seems correct
		--local scale = player.display_scale -- may only affect GUI?
		--local density = player.display_density_scale
		
		local tiles_per_px = zoom_scale / zoom
		-- player view
		local half_sizeX = ceil((res.width * tiles_per_px + view_margin) / 32)
		local half_sizeY = ceil((res.height * tiles_per_px + view_margin) / 32)
		
		pl.posX = posX
		pl.posY = posY
		pl.zoom = zoom
		pl.half_sizeX = half_sizeX
		pl.half_sizeY = half_sizeY
		pl.resX = res.width
		pl.resY = res.height
		
		-- visible chunk indexes, inclusive
		local x0 = posX - half_sizeX
		local x1 = posX + half_sizeX
		local y0 = posY - half_sizeY
		local y1 = posY + half_sizeY
		
		pl.alt_mode = false
		
		-- TODO: optimize via on_player_toggled_alt_mode + ?
		-- sadly chart mode does not seem to have en event? poll that one infrequently?
		local surf = storage.buckets[player.surface_index]
		if surf then
			if chart then -- game view or char_zoomed_in render actual entities, chart is map mode
				local bucket = surf[CHART_KEY]
				if bucket then
					draw_lists[bucket] = true
				end
			elseif alt then
				pl.alt_mode = true
				for y=y0,y1 do
					for x=x0,x1 do
						local key = chunk_key(x,y)
						local bucket = surf[key]
						if bucket then
							draw_lists[bucket] = true
						end
					end
				end
			end
		end
		
		players[player.index] = pl
	end
	
	if DEBUG then
		local _total = 0
		for bucket, _ in pairs(draw_lists) do
			_total = _total + #bucket.draw_list
			
			--if not storage.draw_lists[bucket] then _dbg_bucket(bucket, {1,.2,1}, 60) end
		end
		
		game.print(string.format("rebuild_drawlists: at %d: buckets: %d displays: %d", game.tick, table_size(draw_lists), _total))
	end
	
	storage.draw_lists = draw_lists
end

script.on_event(defines.events.on_player_changed_position, function(event)
	-- player moved by one tile
	local id = event.player_index
	local pl = storage.players[id]
	if pl and pl.alt_mode then
		local player = game.get_player(id) ---@cast player -nil
		local pos = player.position
		--local surf = player.surface
		--local ppos = player.physical_position
		--local psurf = player.physical_surface
		--game.print("on_player_changed_position: ".. serpent.line({ pos, surf, ppos, psurf, event }), {skip=defines.print_skip.never})
		
		-- player chunk index
		local posX = floor(pos.x / 32)
		local posY = floor(pos.y / 32)
		if posX ~= pl.posX or posY ~= pl.posY then -- player moved to another chunk
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

---@param tick integer
local function polling(tick)
	-- update each entity exactly once every period
	-- should be safe to resize list or change POLLING_PERIOD without updating poll_cur
	local period = POLL_PERIOD
	if period <= 0 then return end
	local list = storage.poll_list
	local ratio = (tick % period) + 1 -- +1 only works with tick freq=1, period must be divisible by this, so 1 is good
	local last = math.ceil((ratio / period) * #list)
	
	for i=storage.poll_cur,last do
		local data = list[i]
		local e = data.entity
		-- .valid check is supposedly needed even with on_object_destroyed
		-- check nil as well just to be safe
		if e and e.valid then
			if display_was_modified(data, e) then
				update_display(e)
			end
		end
	end
	
	if ratio == period then -- end of list reached
		storage.poll_cur = 1
	else
		storage.poll_cur = last+1
	end
end

local function optimized_message_update()
	local need_rebuild = storage.need_rebuild
	local players = storage.players
	
	local connected = game.connected_players
	for pi=1,#connected do
		local player = connected[pi]
		local pl = players[player.index]
		
		local mode = player.render_mode
		if not pl or mode ~= pl.render_mode then
			-- rebuild if player switched to/from char view
			need_rebuild = true
		elseif pl.alt_mode then
			local zoom = player.zoom
			if zoom ~= pl.zoom then -- avoid some computation if zoom did not change
				local f = zoom_scale / zoom
				local half_sizeX = ceil((pl.resX * f + view_margin) / 32)
				local half_sizeY = ceil((pl.resY * f + view_margin) / 32)
				if half_sizeX ~= pl.half_sizeX or half_sizeY ~= pl.half_sizeY then
					need_rebuild = true
				end
				pl.zoom = zoom
			end
			
			if pl.selected then
				update_messages(pl.selected)
			end
		end
	end
	
	if need_rebuild then
		storage.need_rebuild = false
		rebuild_drawlists()
	end
	
	local draw_lists = storage.draw_lists
	
	local tick = game.tick
	local last_tick = tick-1
	
	for bucket, _ in pairs(draw_lists) do
		local last_updated = bucket.last_updated
		bucket.last_updated = tick
		local list = bucket.draw_list
		
		if DEBUG then _dbg_bucket(bucket, {1,.2,.2}) end
		
		if last_updated == last_tick then
			-- fastpath, do circuit change detection
			for i=1,#list do
				local data = list[i]
				-- This change detection only works if we also updated this display last tick!
				local r = data.acR
				local g = data.acG
				if (r and r.get_signals(CR, CG)) or (g and g.get_signals(CR, CG)) then
					update_messages(data)
				end
			end
		else
			-- slowpath, chunk was not observed last tick
			-- Happens due to chunk getting created or newly observed due to
			-- alt mode toggle, enter/exit chart mode, surface switch, new player, player moved or zoomed etc.
			-- change detect ACs not valid since we may have missed changes!
			for i=1,#list do
				local data = list[i]
				update_messages(data)
			end
		end
	end
end

if DEBUG then
	local p, p2
	script.on_event(defines.events.on_tick, function(event)
		p = p or game.create_profiler(true)
		p2 = p2 or game.create_profiler(true)

		p.restart()
		polling(event.tick)
		p.stop()
		
		p2.restart()
		optimized_message_update()
		p2.stop()
		
		if event.tick % 60 == 0 then
			p.divide(60)
			p2.divide(60)
			game.print({"", "on_tick: ", p, "\n", p2})
			p.reset()
			p2.reset()
		end
	end)
else
	script.on_event(defines.events.on_tick, function(event)
		polling(event.tick)
		optimized_message_update()
	end)
end

script.on_event(defines.events.on_selected_entity_changed, function(event)
	--game.print("on_selected_entity_changed: ".. serpent.line(event))
	local id = event.player_index
	local pl = storage.players[id]
	if pl then
		local player = game.get_player(id) ---@cast player -nil
		local e = player.selected
		pl.selected = e and storage.all_displays[e.unit_number]
	end
end)

-- Tick for convenience feature
---@param display Display
local function tick_gui(display)
	local entity = display.entity
	local ctrl = entity.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
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
	if not entity.display_panel_always_show then
		entity.display_panel_always_show = true
		entity.display_panel_always_show = false
	end
end
script.on_nth_tick(20, function(event)
	--for _,player in pairs(game.players) do
	--	local entity = player.opened_gui_type == GT_ENTITY and player.opened or nil --[[@as LuaEntity?]]
	--	if is_display_panel(entity) then ---@cast entity DisplayEntity
	--		tick_gui(entity)
	--	end
	--end
	
	for _,display in pairs(storage.opened_guis) do
		tick_gui(display)
	end
end)

script.on_event(defines.events.on_gui_opened, function(event)
	local entity = event.entity
	if event.gui_type == GT_ENTITY and is_display_panel(entity) then ---@cast entity DisplayEntity
		local pl = storage.players[event.player_index] or {}
		pl.open = entity
		storage.players[event.player_index] = pl
		
		local data = storage.all_displays[entity.unit_number]
		if data then
			storage.opened_guis[entity.unit_number] = data
			
			--used to call reset_display but it's better to not touch buckets for efficiency, simply skip update in update_messages instead
			-- just reset messages for cleaner user edits
			reset_messages(data)
		end
	end
end)
script.on_event(defines.events.on_gui_closed, function(event)
	local entity = event.entity
	if event.gui_type == GT_ENTITY and is_display_panel(entity) then ---@cast entity DisplayEntity
		local pl = storage.players[event.player_index] or {}
		pl.open = nil
		storage.players[event.player_index] = pl
		
		-- can multiple people actually open the same entity? if so I think this makes sense to correctly _not_ update if any have it open
		for _, pl in pairs(storage.players) do
			if pl.open == entity then
				return -- still open
			end
		end
		
		storage.opened_guis[entity.unit_number] = nil
		
		update_display(entity) -- reactivate display once no gui open
	end
end)

local function on_entity_event(event)
	--game.print("on_entity_event: ".. serpent.line(event))
	local entity = event.entity or event.destination
	if is_display_panel(entity) then ---@cast entity DisplayEntity
		update_display(entity)
	end
end

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
-- React to entity settings paste
script.on_event(defines.events.on_entity_settings_pasted, on_entity_event) -- source to destination

-- Don't try to handle all possibilities of settings and wires being changed as it is barely possible, polling is more reliable
-- don't react to undo/redo changing settings as it is too complex
-- don't react to circuit wire add/remove as there are no events (perel is great but does not handle blueprint-over and undo/redo)
-- don't react to blueprinting as it already mostly works, and blueprinting over is very complex (but blueprint lib is nice)

local deathrattles = {} ---@type function(EventData.on_object_destroyed)[]
deathrattles[defines.target_type.surface] = function(event)
	storage.buckets[event.useful_id] = nil
	rebuild_drawlists()
end
deathrattles[defines.target_type.player] = function(event)
	storage.players[event.useful_id] = nil
	rebuild_drawlists()
end
deathrattles[defines.target_type.entity] = function(event)
	delete_display(event.useful_id)
end
script.on_event(defines.events.on_object_destroyed, function(event)
	local handler = deathrattles[event.type]
	if handler then handler(event) end
end)

POLL_PERIOD = settings.global["hexcoder-signal-display-poll-period"].value --[[@as integer]]

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	POLL_PERIOD = settings.global["hexcoder-signal-display-poll-period"].value --[[@as integer]]
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
			update_display(display)
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

--[[
commands.add_command("profile1", nil, function(command)
	local N = 10000000
	
	local s_tbl = { s1=1, s2=2, s3=3, s4=4, s5=5, s6=6, s7=7, s8=8, s9=9, s10=10 }
	
	local short =     "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	local long =      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabb"
	local very_long = "long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_"
	s_tbl[short] = 11
	s_tbl[long] = 12
	s_tbl[very_long] = 13
	
	local short2 =     string.format("%saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "a")
	local long2 =      string.format("%saaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabb", "a")
	local very_long2 = string.format("%s_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_long_string_",
		"long")
	
	local a_tbl = {}; for i = 1, 10 do a_tbl[i] = i end
	local f_tbl = {}; for i = 1, 10 do f_tbl[i + 0.5] = i end
	
	local ps = game.create_profiler(); for i = 1, N do
		local _ = s_tbl.s3
		local _ = s_tbl.s6
		local _ = s_tbl.s9
	end; ps.stop()
	
	local ps2 = game.create_profiler(); for i = 1, N do
		local _ = s_tbl["s3"]
		local _ = s_tbl["s6"]
		local _ = s_tbl["s9"]
	end; ps2.stop()
	
	local ps3 = game.create_profiler(); for i = 1, N do
		local _ = s_tbl[short2]
		local _ = s_tbl[short2]
		local _ = s_tbl[short2]
	end; ps3.stop()
	
	local ps4 = game.create_profiler(); for i = 1, N do
		local _ = s_tbl[long2]
		local _ = s_tbl[long2]
		local _ = s_tbl[long2]
	end; ps4.stop()
	
	local ps5 = game.create_profiler(); for i = 1, N do
		local _ = s_tbl[very_long2]
		local _ = s_tbl[very_long2]
		local _ = s_tbl[very_long2]
	end; ps5.stop()
	
	local pa = game.create_profiler(); for i = 1, N do
		local _ = a_tbl[3]
		local _ = a_tbl[6]
		local _ = a_tbl[9]
	end; pa.stop()
	
	local pf = game.create_profiler(); for i = 1, N do 
		local _ = f_tbl[3.5]
		local _ = f_tbl[6.5]
		local _ = f_tbl[9.5]
	end; pf.stop()
	
	game.player.print({ "", "  string_key=", ps,
		"\nstring_key[str]=", ps2,
		"\nstring_key[short]=", ps3, 
		"\nstring_key[long]=", ps4, 
		"\nstring_key[very_long]=", ps5, 
		"\narray_index=", pa,
		"\nfloat_key=", pf })
end)]]

commands.add_command("profile1", nil, function(command)
	local list = storage.poll_list
	local p = game.create_profiler()
	for i=1,#list do
		local data = list[i]
		local e = data.entity
		-- .valid check is supposedly needed even with on_object_destroyed
		-- check nil as well just to be safe
		if e and e.valid then
			if display_was_modified(data, e) then
				update_display(e)
			end
		end
	end
	p.stop()
	
	game.player.print({ "", "  poll_total=", p })
	p.divide(#list)
	game.player.print({ "", "  avg=", p })
end)

---@class player_index : integer
---@class surface_index : integer
---@class unit_number : integer
---@class bucket_key : number -- double
---@class tick_num : integer

---@class DisplayEntity : LuaEntity

---@class ModStorage
---@field all_displays table<unit_number, Display>
---@field poll_list Display[]
---@field poll_idx table<Display, integer>
---@field poll_cur integer
---@field buckets table<surface_index, SurfaceBuckets>
---@field draw_lists table<Bucket, boolean>
---@field players table<player_index, Player>
---@field opened_guis table<unit_number, Display>
---@field need_rebuild boolean

---@class Display
---@field entity DisplayEntity
---@field acR? LuaEntity
---@field acG? LuaEntity
---@field sid integer
---@field chunk_key bucket_key
---@field last_updated tick_num?
---@field ctrl LuaDisplayPanelControlBehavior
---@field connR LuaWireConnector
---@field connG LuaWireConnector
---@field chart Bucket?
---@field alt Bucket?
---@field message_cache table<integer, Message>

---@class Message
---@field text string
---@field icon SignalID
---@field num_form? string
---@field form? string
---@field formQ? string
---@field div? number

---@class SurfaceBuckets
---@field _surfID surface_index
---@field [bucket_key] Bucket

---@class Bucket
---@field last_updated tick_num?
---@field draw_list Display[]
---@field indexes table<Display, bucket_key> -- draw list index map
---@field surfID surface_index
---@field chunk_key bucket_key

---@class Player
---@field render_mode defines.render_mode
---@field alt_mode boolean
---@field posX number
---@field posY number
---@field zoom number
---@field resX number
---@field resY number
---@field half_sizeX number
---@field half_sizeY number
---@field open DisplayEntity?
---@field selected Display?
