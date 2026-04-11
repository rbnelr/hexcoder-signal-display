--[[
	TODO: add nixie tube style mode?
	TODO: I think there's now some bugs with copy pasting, possibly only directly selecting signals for some reason?
	TODO: maybe add the option with braces required, as this would ensures undo/redo, blueprint over etc. to all work 100% as expected
	      trade off is that it's slightly uglier, but code is easier as well
		  -> or just revert these changes
]]

---@type ModStorage
storage = storage

---@class unit_number integer

---@class ModStorage
---@field tracked_displays table<unit_number, DisplayData>
---@field polling_displays DisplayData[]
---@field polling_displays_cur integer
---@field surfaces table

---@class DisplayData
---@field entity LuaEntity
---@field set_convenient_condition_once? boolean -- set condition conveniently once, set to nil afterwards
---@field unmodified_messages DisplayPanelMessageDefinition[]
---@field acs LuaEntity[]
---@field active_acs LuaEntity[]
---@field poll_idx integer

local W = defines.wire_connector_id
local HIDDEN = defines.wire_origin.script
--local HIDDEN = defines.wire_origin.player
local CR = defines.wire_connector_id.circuit_red
local CG = defines.wire_connector_id.circuit_green

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

--local function migrate()
--	for _,data in pairs(storage.tracked_displays) do
--		for i,m in ipairs(data.unmodified_messages) do
--			if m.text then
--				local form = m.text:match("(/%d+f%d+)") or ""
--				m.text = m.text:gsub("{[^{}]*}", "{"..form.."}")
--			end
--		end
--	end
--end

local function add_to_poll_list(data)
	assert(data.poll_idx == nil)
	data.poll_idx = #storage.polling_displays+1
	storage.polling_displays[data.poll_idx] = data
end
local function remove_from_poll_list(data)
	-- delete by swap with last
	local idx = data.poll_idx
	data.poll_idx = nil
	local last = #storage.polling_displays
	storage.polling_displays[idx] = storage.polling_displays[last]
	storage.polling_displays[idx].poll_idx = idx
	storage.polling_displays[last] = nil
end

---@param ctrl LuaDisplayPanelControlBehavior
---@returns boolean
local function has_any_trigger_message(ctrl)
	for _,m in ipairs(ctrl.messages) do
		if m.icon and m.text and m.text:find("{[^{}]*}") then
			return true
		end
	end
	return false
end

-- stop tracking, restore unmodified messages so user can properly edit
---@param id unit_number
---@param display? LuaEntity
local function stop_tracking(id, display)
	local data = storage.tracked_displays[id]
	if data then
		for _,ac in pairs(data.acs) do
			ac.destroy()
		end
		
		local ctrl = display and display.get_or_create_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
		if ctrl then
			ctrl.messages = data.unmodified_messages
		end
		
		remove_from_poll_list(data)
		
		local surf = storage.surfaces[data.sid]
		if surf then
			surf.chart[id] = nil
			surf.alt[id] = nil
		end
		storage.tracked_displays[id] = nil
	end
end
-- start or stop updating depending on if any messages contain {}
---@param display LuaEntity
---@param copy_from? LuaEntity
local function update_tracking(display, copy_from)
	local id = display.unit_number ---@cast id -nil
	
	local data
	local ctrl
	if copy_from then
		local data_src = storage.tracked_displays[copy_from.unit_number]
		if data_src then
			-- copy control behavior
			ctrl = display.get_or_create_control_behavior() --[[@as LuaDisplayPanelControlBehavior]]
			if ctrl then
				ctrl.messages = data_src.unmodified_messages
			end
		end
	end
	
	ctrl = ctrl or display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior]]
	if copy_from or (ctrl and has_any_trigger_message(ctrl)) then
		data = storage.tracked_displays[id]
		if not data then
			script.register_on_object_destroyed(display)
			
			data = {
				entity = display, sid = display.surface_index,
				unmodified_messages = ctrl.messages
			}
			storage.tracked_displays[id] = data
		end
	else
		stop_tracking(id, display)
	end
	
	-- update update lists
	if data then
		local surf = storage.surfaces[display.surface_index] or { chart={}, alt={} }
		
		surf.chart[id] = display.display_panel_show_in_chart and data or nil
		surf.alt[id] = display.display_panel_always_show and data or nil
		
		storage.surfaces[display.surface_index] = surf
		
		add_to_poll_list(data)
		
		if not data.acs then
			local function make_combinator(x,y, params)
				local ac = display.surface.create_entity{
					name="hexcoder-signal-display-ac", force=display.force,
					position={display.position.x+x, display.position.y+y}, snap_to_grid=false,
					direction=defines.direction.north
				} ---@cast ac -nil
				ac.destructible = false
				ac.get_or_create_control_behavior().parameters = params
				return ac
			end
			
			data.acs = {
				make_combinator(-0.4, -1.5, AC_NEGATE_EACH_R),
				make_combinator(0.4, -1.5, AC_NEGATE_EACH_G),
			}
			data.active_acs = {}
			
			local acR = data.acs[1].get_wire_connectors(true)
			local acG = data.acs[2].get_wire_connectors(true)
			local d = display.get_wire_connectors(true)
			
			acR[W.combinator_input_red  ].connect_to(d[W.circuit_red], false, HIDDEN)
			acR[W.combinator_input_green].connect_to(acR[W.combinator_output_green], false, HIDDEN)
			acG[W.combinator_input_red  ].connect_to(acG[W.combinator_output_red], false, HIDDEN)
			acG[W.combinator_input_green].connect_to(d[W.circuit_green], false, HIDDEN)
		end
	end
end

script.on_event(defines.events.on_object_destroyed, function(event)
	if event.type == defines.target_type.entity then
		stop_tracking(event.useful_id --[[@as unit_number]])
	end
end)

local has_set_convenient_condition_once

---@param display LuaEntity
local function tick_gui(display)
	local ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
	if ctrl then
		for i,m in ipairs(ctrl.messages) do
			if m.icon and m.icon.type == "virtual" then
				-- convenience feature: its annoying that when connecting circuit to display panel by default it shows nothing
				if has_set_convenient_condition_once == nil and m.text == nil and m.condition == nil then
					m.text = "{}"
					m.condition = ANY_SIGNAL_COND
					ctrl.set_message(i,m)
				end
				has_set_convenient_condition_once = true
			end
		end
	end
end

local function _comp_signal(l, r)
	return l.count > r.count
end

local dbg = true
local function _dbg_update(display)
	local pos = display.position
	
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y-0.45 }, to={ x=pos.x+0.45, y=pos.y+0.45 }, color={.2,1,.2}, width=2, surface=display.surface, time_to_live=1 }
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y+0.45 }, to={ x=pos.x+0.45, y=pos.y-0.45 }, color={.2,1,.2}, width=2, surface=display.surface, time_to_live=1 }
	
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y-0.45 }, to={ x=pos.x+0.45, y=pos.y+0.45 }, color={.2,1,.2}, width=2, surface=display.surface, time_to_live=1, render_mode="chart" }
	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y+0.45 }, to={ x=pos.x+0.45, y=pos.y-0.45 }, color={.2,1,.2}, width=2, surface=display.surface, time_to_live=1, render_mode="chart" }
end

local _changed

---@param display LuaEntity
---@param data DisplayData
local function update(display, data)
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
	
	-- TODO: wanted to cache signal texts in some way
	-- for example so that if the user uses multiple messages with conditions if all of them try to show the same signals, I only compute them once
	-- however I don't tend to use this so I don't bother for now
	-- I guess caching by actually just not updating displays with unchanged signals would be far better?
	
	--if dbg then _dbg_update(display) end
	
	-- cache in case multiple messages exist
	local all_signals = nil
	
	---@param input string
	---@param count integer
	---@returns string
	local function format_count_text(input, count)
		local divisor, precision = input:match("{/(%d+)f(%d+)}")
		local div = tonumber(divisor) or 1
		--local num_format = precision and string.format("[font=default-bold]%%.%df[/font]", precision) or "[font=default-bold]%d[/font]"
		local num_format = precision and string.format("%%.%df", precision) or "%d"
		
		return input:gsub("{[^{}]*}", string.format(num_format, count / div), 1)
	end
	
	---@param input string
	---@returns string
	local function get_all_signals_sum_text(input)
		all_signals = all_signals or display.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		
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
		all_signals = all_signals or display.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		if not all_signals then
			return input:gsub("{[^{}]*}", "{}", 1)
		end
		
		table.sort(all_signals, _comp_signal)
		
		-- support fixed point values: /1000f3 => signal=1234567 -> 123.457 (.4567 rounded to .457)
		-- don't support more variations due to heavy lua regex limitations
		local divisor, precision = input:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		local num_format = precision and string.format("%%.%df", precision) or "%d"
		
		-- rich text is: [item=copper-plate] or for non-normal quality: [item=copper-plate,quality=epic]
		local form = "%s[%s=%s] "..num_format
		local formQ = "%s[%s=%s,quality=%s] "..num_format
		
		local text = nil
		for _,s in ipairs(all_signals) do
			text = text and (text.." ") or "" -- space as list seperator
			
			local sig = s.signal
			local type = SIGNAL2RICH_TEXT[sig.type] or "item"
			if not sig.quality then
				text = string.format(form, text, type,sig.name, s.count/div)
			else
				text = string.format(formQ, text, type,sig.name,sig.quality, s.count/div)
			end
		end
		text = text or ""
		
		return input:gsub("{[^{}]*}", text, 1)
	end
	---@param input string
	---@returns string, SignalID
	local function get_any_signal_text(input)
		all_signals = all_signals or display.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		
		if not all_signals or #all_signals == 0 then
			return {}, ""
		end
		
		table.sort(all_signals, _comp_signal)
		
		local signal = all_signals[1]
		
		return signal.signal, format_count_text(input, signal.count)
	end
	---@param input string
	---@param icon SignalID
	---@returns string
	local function get_signal_text(input, icon)
		local count = display.get_signal(icon, defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green) or 0
		
		return format_count_text(input, count)
	end
	
	-- during tick handler, display_panel_text will be from last tick and the condition may cause a different text based on current signals
	-- the easy solution is to update all messages every tick
	
	local ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
	if ctrl then
		for i,m in ipairs(data.unmodified_messages) do
			local icon = m.icon
			local text = m.text
			
			if icon.name then
				local virt_name = icon.type == "virtual" and icon.name or nil
				if virt_name == "signal-everything" then
					text = get_all_signals_sum_text(text or "")
				elseif virt_name == "signal-each" then
					text = get_all_signals_text(text or "")
				elseif virt_name == "signal-anything" then
					icon, text = get_any_signal_text(text or "")
				else
					-- show signal count
					text = get_signal_text(text or "", icon)
				end
			end
			
			ctrl.set_message(i, {
				icon = icon,
				text = text,
				condition = m.condition,
			})
		end
	end
	
	--_changed = _changed + 1
end

--[[
local function optimized_update()
	local margin = 1.10 -- at least try to catch stuff that is slightly off-screen
	--local margin = 0.6 -- debugging
	-- unlike many games, zoom is not tied to vertical or horizontal fov/orthographic diameter
	-- instead at zoom=1 I get 1 tile being drawn at 32 pixels at my specific window resolution, 2 is zoomed in to 1 tile=64
	local factor = margin*0.5/32
	
	-- do not update display twice
	local updated = {}
	
	--local _in_update_list = 0
	--local _updated = 0
	--_changed = 0
	
	for _, player in pairs(game.players) do
		if not player.connected then goto continue end
		
		local surf = storage.surfaces[player.surface_index]
		
		local update_list ---@type table<unit_number, DisplayData>
		if surf then
			if player.render_mode == defines.render_mode.chart then -- game view or char_zoomed_in render actual entities, chart is map mode
				update_list = surf.chart
			elseif player.game_view_settings.show_entity_info then
				update_list = surf.alt
			end
		end
		
		-- update chart or alt mode displays unless player is in non-alt mode
		if update_list then
			local half_sizeX = player.display_resolution.width * factor / player.zoom -- can listen to on_player_display_resolution_changed
			local half_sizeY = player.display_resolution.height * factor / player.zoom
			
			local x0 = player.position.x - half_sizeX - 1
			local x1 = player.position.x + half_sizeX + 1
			local y0 = player.position.y - half_sizeY - 1
			local y1 = player.position.y + half_sizeY + 1
			--rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x0, y= y1 }, color={1,.2,.2}, width=4, surface=player.surface, time_to_live=1 }
			--rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y= y1 }, color={1,.2,.2}, width=4, surface=player.surface, time_to_live=1 }
			--rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y= y0 }, color={1,.2,.2}, width=4, surface=player.surface, time_to_live=1 }
			--rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x1, y= y1 }, color={1,.2,.2}, width=4, surface=player.surface, time_to_live=1 }
			
			for _, data in pairs(update_list) do
				local pos = data.entity.position
				local x = pos.x
				local y = pos.y
				if x > x0 and x < x1 and y > y0 and y < y1 then
					if data and not updated[data] then
						update(data.entity, data, seen_last_tick[data] == nil)
						updated[data] = true
	--
						--_updated = _updated + 1
					end
				end
				
				--_in_update_list = _in_update_list + 1
			end
		end
		
		function _update(display)
			local data = display and display.valid and storage.tracked_displays[display.unit_number] or nil
			if data and not updated[data] then
				update(display, data, seen_last_tick[data] == nil)
				updated[data] = true
				
				--_updated = _updated + 1
			end
		end
		
		-- update always if hovered
		_update(player.selected) -- hovered
		
		-- update always if gui opened (actually never since I now 
		--if player.opened_gui_type == defines.gui_type.entity then
		--	_update(player.opened) -- open gui
		--end
		
		-- update chart or alt mode displays unless player is in non-alt mode
		if update_list then
			for _, data in pairs(update_list) do
				update(data.entity, data, false)
			end
		end
		
		-- update always if hovered
		local sel = player.selected
		local data = sel and sel.valid and storage.tracked_displays[sel.unit_number] or nil
		if data and not update_list[data] then
			update(sel, data, false)
		end
		
		::continue::
	end
	
	seen_last_tick = updated
end
]]

---@param data DisplayData
local function poll_display(data)
	data.active_acs = {}
	local conn1 = data.entity.get_wire_connector(defines.wire_connector_id.circuit_red, false)
	local conn2 = data.entity.get_wire_connector(defines.wire_connector_id.circuit_green, false)
	if conn1 and conn1.real_connection_count > 1 then -- 1 to exclude wire to AC
		table.insert(data.active_acs, data.acs[1])
	end
	if conn2 and conn2.real_connection_count > 1 then
		table.insert(data.active_acs, data.acs[2])
	end
end

local function infrequent_poll(event)
	-- update entire list and thus each entity exactly once every period
	local period = 120
	local list = storage.polling_displays
	local ratio = (event.tick % period) + 1 -- +1 only works with tick freq=1, period must be divisible by this, so 1 is good
	local last = math.ceil((ratio / period) * #list)
	
	for i=storage.polling_displays_cur,last do
		poll_display(list[i])
	end
	
	if ratio == period then -- end of list reached
		storage.polling_displays_cur = 1
	else
		storage.polling_displays_cur = last+1
	end
end

-- TODO: fix this version for multiple players: need to determine active surfaces then only iterate list for surface once
local function optimized_update(event)
	infrequent_poll(event)
	
	local _updated_prev = storage._updated_prev or {}
	updated = {}
	
	for _, player in pairs(game.players) do
		if not player.connected then goto continue end
		
		local surf = storage.surfaces[player.surface_index]
		
		-- update chart or alt mode displays unless player is in non-alt mode
		local update_list ---@type table<unit_number, DisplayData>
		if surf then
			if player.render_mode == defines.render_mode.chart then -- game view or char_zoomed_in render actual entities, chart is map mode
				update_list = surf.chart
			elseif player.game_view_settings.show_entity_info then
				update_list = surf.alt
			end
		end
		
		-- update chart or alt mode displays unless player is in non-alt mode
		if update_list then
			for _, data in pairs(update_list) do
				if data.active_acs == nil then data.active_acs = {} end
				
				-- Cool optimization: edge detector AC, read combined inputs (current + negated_previous tick signals) if get_signals()=nil, then no change
				-- TODO: could try cache if R and G are actually connected and avoid one of these reads most of the time
				-- newly_revealed: Need to track which checks were skipped by player optimization, since we might miss changes older that last tick
				--local acA = data.active_acs[1]
				--local acB = data.active_acs[2]
				--if _updated_prev[data] == nil or
				--   (acA and acA.get_signals(CR, CG) ~= nil) or
				--   (acB and acB.get_signals(CR, CG) ~= nil) then
				--	update(data.entity, data)
				--end
				local acA = data.acs[1]
				local acB = data.acs[2]
				if _updated_prev[data] == nil or
				   acA.get_signals(CR, CG) ~= nil or
				   acB.get_signals(CR, CG) ~= nil then
					update(data.entity, data)
				end
				
				updated[data] = true
			end
		end
		
		-- update always if hovered
		local sel = player.selected
		local data = sel and sel.valid and storage.tracked_displays[sel.unit_number] or nil
		if data and not (update_list and update_list[data]) then
			update(sel, data)
			
			updated[data] = true
		end
		
		::continue::
	end
	
	storage._updated_prev = updated
end

script.on_nth_tick(12, function(event)
	for _,player in pairs(game.players) do
		local entity = player.opened_gui_type == defines.gui_type.entity and player.opened or nil --[[@as LuaEntity?]]
		if entity and entity.valid and entity.type == "display-panel" then
			tick_gui(entity)
		end
	end
end)

script.on_event(defines.events.on_tick, optimized_update)

---@param e LuaEntity
---@returns boolean
local function is_display_planel(e)
	return e and e.valid and e.type == "display-panel"
end

-- Start tracking new or existing entities if needed
local function on_entity_event(event)
	local entity = event.entity or event.destination --[[@as LuaEntity]]
	local source = is_display_planel(event.source) and event.source or nil
	
	if is_display_planel(entity) then
		update_tracking(entity, source)
	end
end
local function on_gui_open(event)
	local entity = event.entity --[[@as LuaEntity]]
	if entity and entity.valid and entity.type == "display-panel" then
		stop_tracking(entity.unit_number --[[@as unit_number]], entity)
	end
end
local function on_gui_close(event)
	local entity = event.entity --[[@as LuaEntity]]
	if entity and entity.valid and entity.type == "display-panel" then
		update_tracking(entity)
		has_set_convenient_condition_once = nil
	end
end

for _, event in ipairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned, -- source to destination
}) do
	script.on_event(event, on_entity_event, {{filter="type", type="display-panel"}})
end
script.on_event(defines.events.on_entity_settings_pasted, on_entity_event) -- source to destination
script.on_event(defines.events.on_gui_opened, on_gui_open)
script.on_event(defines.events.on_gui_closed, on_gui_close)

-- blueprinting over does not work like always
script.on_event(defines.events.on_player_setup_blueprint, function(event)
	local player = game.get_player(event.player_index) ---@cast player -nil
	local blueprint = event.stack
	if not blueprint or not blueprint.valid_for_read then blueprint = player.blueprint_to_setup end
	if not blueprint or not blueprint.valid_for_read then blueprint = player.cursor_stack end
	if not blueprint or not blueprint.valid_for_read then return end
	
	local entities = blueprint.get_blueprint_entities()
	local mapping = nil
	if not entities then return end
	local changed = false
	
	for i, bp_entity in pairs(entities) do
		if bp_entity.name == "display-panel" then
			mapping = mapping or event.mapping.get() --[[@as LuaEntity[] ]]
			local data = storage.tracked_displays[mapping[i].unit_number]
			if data then
				bp_entity.control_behavior.parameters = data.unmodified_messages
			end
			changed = true
		end
	end
	if changed then
		blueprint.set_blueprint_entities(entities)
	end
end)

-- undo-redo placing displays causes them to copy displayed text, not formatting text

local function init(clean)
	storage.tracked_displays = {}
	storage.polling_displays = {}
	storage.polling_displays_cur = 1
	storage.surfaces = {}
	
	if not clean then
		for _, surface in pairs(game.surfaces) do
			for _, display in ipairs(surface.find_entities_filtered{ type="display-panel" }) do
				update_tracking(display)
			end
		end
	end
end
local function _reset()
	for id,data in pairs(storage.tracked_displays) do
		stop_tracking(id, data.entity)
	end
	
	for _, s in pairs(game.surfaces) do
		for _, name in pairs({"ac"}) do
			for _, e in pairs(s.find_entities_filtered{ name="hexcoder-signal-display-"..name }) do
				e.destroy()
			end
		end
	end

	storage = {}
	init(false)
end
script.on_init(function(event)
	init(true)
end)

-- removed to not clutter up /help
commands.add_command("hexcoder-signal-display-reset", nil, function(command)
	_reset()
end)

--commands.add_command("hexcoder-signal-display-migrate", nil, function(command)
--	migrate()
--end)