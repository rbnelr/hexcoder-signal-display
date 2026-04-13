---@type ModStorage
storage = storage

---@class DisplayEntity : LuaEntity
---@class DisplaySet : table<integer, Display>

---@class ModStorage
---@field all_displays DisplaySet
---@field surfaces table<integer, SurfUpdateLists>
---@field extra_update DisplaySet
---@field updated_last_tick table<DisplaySet, true>
---@field poll_list Display[]
---@field poll_cur integer

---@class Display
---@field entity DisplayEntity
---@field ctrl LuaDisplayPanelControlBehavior?
---@field acs? LuaEntity[]
---@field sid integer
---@field poll_idx integer

---@class SurfUpdateLists
---@field chart DisplaySet
---@field alt DisplaySet

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

-- TODO: should_update returns false if display not connected to circuit, but now it does not start updating on wire connect

---@param e LuaEntity?
---@returns boolean
local function is_display_planel(e)
	return e and e.valid and e.type == "display-panel"
end

local function add_to_poll_list(data)
	assert(data.poll_idx == nil)
	data.poll_idx = #storage.poll_list+1
	storage.poll_list[data.poll_idx] = data
end
local function remove_from_poll_list(data)
	-- delete by swap with last
	local idx = data.poll_idx
	data.poll_idx = nil
	local last = #storage.poll_list
	storage.poll_list[idx] = storage.poll_list[last]
	storage.poll_list[idx].poll_idx = idx
	storage.poll_list[last] = nil
end

---@param display DisplayEntity
---@returns boolean
-- any circuit connection not going to hidden change detector
local function is_actually_connected(display)
	for _, c in pairs(display.get_wire_connectors(false)) do
		if c.real_connection_count >= 2 then
			return true
		end
		if c.real_connection_count >= 1 and c.real_connections[1].origin == defines.wire_origin.player then
			return true
		end
	end
	return false
end

---@param display DisplayEntity
---@param ctrl LuaDisplayPanelControlBehavior?
---@returns boolean
local function is_active_display(display, ctrl)
	-- may be needed in multiplayer? sounds overkill
	for _, player in pairs(game.players) do
		if player.opened_gui_type == defines.gui_type.entity and display == player.opened then
			return false
		end
	end
	
	-- need to return false if display not connected to circuit to avoid display updating despite no circuit
	-- (and overwriting static user message since ctrl.messages still exists despite being hidden)
	if display.valid and ctrl and is_actually_connected(display) then
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
---@param id integer
---@param data Display
local function reset_display(id, data)
	-- reset messages even if not data yet, relevant for copy-pasted entities
	reset_messages(data)
	
	if data.acs then
		for _,ac in pairs(data.acs) do
			ac.destroy()
		end
		data.acs = nil
		
		local surf = storage.surfaces[data.sid]
		if surf then
			surf.chart[id] = nil
			surf.alt[id] = nil
		end
		
		storage.extra_update[id] = nil
	end
end

-- start or stop updating display depending on if any messages contain format trigger {}
---@param display DisplayEntity
local function check_display(display)
	local id = display.unit_number ---@cast id -nil
	local data = storage.all_displays[id]
	if not data then
		script.register_on_object_destroyed(display)
		
		data = { ---@diagnostic disable-line
			entity = display,
			sid = display.surface_index
		}
		add_to_poll_list(data)
		storage.all_displays[id] = data
	end
	
	data.ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
	
	if is_active_display(display, data.ctrl) then
		local function make_combinator(x,y, params, detect_wire)
			local ac = display.surface.create_entity{
				name="hexcoder-signal-display-hidden-change-detector", force=display.force,
				position={display.position.x+x, display.position.y+y}, snap_to_grid=false,
				direction=defines.direction.north
			} ---@cast ac -nil
			ac.destructible = false
			
			local ctrl = ac.get_or_create_control_behavior() --[[@as LuaArithmeticCombinatorControlBehavior]]
			ctrl.parameters = params
			
			local conn = ac.get_wire_connectors(true)
			local d = display.get_wire_connectors(true)
			
			if detect_wire == W.circuit_red then
				conn[W.combinator_input_red  ].connect_to(d[detect_wire], false, HIDDEN)
				conn[W.combinator_input_green].connect_to(conn[W.combinator_output_green], false, HIDDEN)
			else
				conn[W.combinator_input_red  ].connect_to(conn[W.combinator_output_red], false, HIDDEN)
				conn[W.combinator_input_green].connect_to(d[detect_wire], false, HIDDEN)
			end
			return ac
		end
		
		if not data.acs then
			data.acs = {
				make_combinator(-0.4, -1.5, AC_NEGATE_EACH_R, W.circuit_red),
				make_combinator(0.4, -1.5, AC_NEGATE_EACH_G, W.circuit_green),
			}
		end
		
		-- add to update lists
		local surf = storage.surfaces[display.surface_index]
		if not surf then
			script.register_on_object_destroyed(display.surface)
			surf = { chart={}, alt={} }
			storage.surfaces[display.surface_index] = surf
		end
		
		if (surf.chart[id] ~= nil) ~= display.display_panel_show_in_chart then
			surf.chart[id] = display.display_panel_show_in_chart and data or nil
			-- updated_last_tick optimization might not be valid for this display
			storage.extra_update[id] = data
		end
		if (surf.alt[id] ~= nil) ~= display.display_panel_always_show then
			surf.alt[id] = display.display_panel_always_show and data or nil
			storage.extra_update[id] = data
		end
	else
		reset_display(id, data)
	end
end

local deathrattles = {}
deathrattles[defines.target_type.entity] = function(event)
	local data = storage.all_displays[event.useful_id]
	if data then
		reset_display(event.useful_id, data)
		remove_from_poll_list(data)
		storage.all_displays[event.useful_id] = nil
	end
end

local function _comp_signal(l, r)
	return l.count > r.count
end

--local dbg = true
--local function _dbg_update(display, no_change)
--	local pos = display.position
--	
--	local color = no_change and {.2,.2,1} or {.2,1,.2}
--	
--	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y-0.45 }, to={ x=pos.x+0.45, y=pos.y+0.45 }, color=color, width=2, surface=display.surface, time_to_live=1 }
--	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y+0.45 }, to={ x=pos.x+0.45, y=pos.y-0.45 }, color=color, width=2, surface=display.surface, time_to_live=1 }
--	
--	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y-0.45 }, to={ x=pos.x+0.45, y=pos.y+0.45 }, color=color, width=2, surface=display.surface, time_to_live=1, render_mode="chart" }
--	rendering.draw_line{ from={ x=pos.x-0.45, y=pos.y+0.45 }, to={ x=pos.x+0.45, y=pos.y-0.45 }, color=color, width=2, surface=display.surface, time_to_live=1, render_mode="chart" }
--end

---@param data Display
local function update_messages(data)
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
	
	--if dbg then _dbg_update(display) end
	
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
		if not all_signals or next(all_signals) == nil then
			return input:gsub("{[^{}]*}", "{}", 1)
		end
		
		table.sort(all_signals, _comp_signal)
		
		-- support fixed point values: /1000f3 => signal=1234567 -> 123.457 (.4567 rounded to .457)
		-- don't support more variations due to heavy lua regex limitations
		local divisor, precision = input:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		local num_format = precision and string.format("%%.%df", precision) or "%d"
		
		-- rich text is: [item=copper-plate] or for non-normal quality: [item=copper-plate,quality=epic]
		local form = "%s [%s=%s] "..num_format
		local formQ = "%s [%s=%s,quality=%s] "..num_format
		
		local text = "{"
		for _,s in ipairs(all_signals) do
			local sig = s.signal
			local type = SIGNAL2RICH_TEXT[sig.type] or "item"
			if not sig.quality then
				text = string.format(form, text, type,sig.name, s.count/div)
			else
				text = string.format(formQ, text, type,sig.name,sig.quality, s.count/div)
			end
		end
		
		return input:gsub("{[^{}]*}", text.." }", 1)
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
					-- this is one tick behind (I think?)
					local any_icon = display.display_panel_icon
					if any_icon and any_icon.name then
						text = get_signal_text(text, any_icon)
					end
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

local function polling(event)
	--if not storage.polling_radars_cur then return end
	
	-- update entire list and thus each entity exactly once every period
	local period = 90
	local list = storage.poll_list
	local ratio = (event.tick % period) + 1 -- +1 only works with tick freq=1, period must be divisible by this, so 1 is good
	local last = math.ceil((ratio / period) * #list)
	
	for i=storage.poll_cur,last do
		check_display(list[i].entity)
	end
	
	if ratio == period then -- end of list reached
		storage.poll_cur = 1
	else
		storage.poll_cur = last+1
	end
end
local function optimized_update()
	-- optimize if no displays are placed
	if next(storage.all_displays) == nil then
		storage.updated_last_tick = {}
		storage.extra_update = {}
		return
	end
	
	-- collect lists of per-surface chart and alt lists that are observed
	-- plus lists of any displays that are not in chart or alt but are hovered
	-- use 'update_lists[obj] = true' to deduplicate
	local update_lists = {}
	local extra_update = storage.extra_update
	for _, player in pairs(game.players) do
		if not player.connected then goto continue end
		
		local surf = storage.surfaces[player.surface_index]
		if surf then
			if player.render_mode == defines.render_mode.chart then -- game view or char_zoomed_in render actual entities, chart is map mode
				update_lists[surf.chart] = true
			elseif player.game_view_settings.show_entity_info then
				update_lists[surf.alt] = true
			end
		end
		
		local open_id = player.opened_gui_type == defines.gui_type.entity and player.opened.unit_number or nil
		
		local sel_id = player.selected and player.selected.unit_number
		local data = sel_id and sel_id ~= open_id and storage.all_displays[sel_id] or nil
		if data then ---@cast sel_id -nil
			extra_update[sel_id] = data
		elseif open_id then
			extra_update[open_id] = nil
		end
		
		::continue::
	end
	
	-- if update list was not updates last tick, bypass change detection
	local updated_last_tick = storage.updated_last_tick
	
	for update_list, _ in pairs(update_lists) do
		if updated_last_tick[update_list] == nil then
			-- change detect ACs not valid since did not update this list read last tick
			-- (Alt mode toggle, enter/exit chart mode, surface switch, new player etc.)
			for id, data in pairs(update_list) do
				update_messages(data)
				extra_update[id] = nil
			end
		else
			for id, data in pairs(update_list) do
				-- Cool optimization: edge detector AC, read combined inputs (current + negated_previous tick signals) if get_signals()=nil, then no change
				-- Need 2 to catch red and green wires (could usually avoid get_signals if wire connect/disconnect was an event, but unclear how slow 1 API call actually is vs the extra check in lua
				-- This change detection only works if we also updated this display last tick!
				local acA = data.acs[1]
				local acB = data.acs[2]
				if acA.get_signals(CR, CG) ~= nil or
				   acB.get_signals(CR, CG) ~= nil then
					update_messages(data)
					extra_update[id] = nil
				--else
				--	_dbg_update(data.entity, true)
				end
			end
		end
	end
	
	-- handle hovered displays and displays that were modified/added potentially breaking change detect
	-- (don't add observed checks as this is rare)
	for _, data in pairs(extra_update) do
		update_messages(data)
	end
	
	storage.updated_last_tick = update_lists
	storage.extra_update = {}
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
		local entity = player.opened_gui_type == defines.gui_type.entity and player.opened or nil --[[@as LuaEntity?]]
		if entity and entity.valid and entity.type == "display-panel" then
			tick_gui(entity)
		end
	end
end)

script.on_event(defines.events.on_tick, function(event)
	polling(event)
	optimized_update()
end)

local function on_entity_event(event)
	--game.print("on_entity_event: ".. serpent.line(event))
	local entity = event.entity or event.destination
	if is_display_planel(entity) then ---@cast entity DisplayEntity
		check_display(entity)
	end
end
script.on_event(defines.events.on_gui_opened, function(event)
	local entity = event.entity
	if is_display_planel(entity) then ---@cast entity DisplayEntity
		local data = storage.all_displays[entity.unit_number]
		if data then
			reset_display(entity.unit_number, data)
		end
	end
end)
script.on_event(defines.events.on_gui_closed, on_entity_event)

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

-- Choose to not react to undo/redo, blueprinting or wire changes even is technically possible via various techniques or libraries
-- as it is very, very complicated and not worth it over polling

deathrattles[defines.target_type.surface] = function(event)
	storage.surfaces[event.useful_id] = nil
end
script.on_event(defines.events.on_object_destroyed, function(event)
	local handler = deathrattles[event.type]
	if handler then handler(event) end
end)

local function init()
	storage = {}
	storage.all_displays = {}
	storage.surfaces = {}
	storage.extra_update = {}
	storage.updated_last_tick = {}
	storage.poll_list = {}
	storage.poll_cur = 1
	
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
--commands.add_command("hexcoder-signal-display-reset", nil, function(command)
--	_reset()
--end)