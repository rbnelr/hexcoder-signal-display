---@type ModStorage
storage = storage

---@class ModStorage
---@field active_displays table<integer, DisplayData>
---@field surfaces table<integer, SurfUpdateLists>
---@field extra_update table<DisplayData, true>
---@field updated_last_tick table<LuaEntity[], true>

---@class DisplayData
---@field entity LuaEntity
---@field sid integer
---@field acs? LuaEntity[]

---@class SurfUpdateLists
---@field chart DisplayData[]
---@field alt DisplayData[]

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

---@param display LuaEntity
---@returns boolean
local function should_update(display)
	-- only actually needed in multiplayer, might be overkill
	for _, player in pairs(game.players) do
		local open = player.opened_gui_type == defines.gui_type.entity and player.opened --[[@as LuaEntity?]]
		if display == open then
			return false
		end
	end
	
	-- Need to reject unconnected displays or we might inexplicably overwrite user typed message
	local connected = display.get_circuit_network(W.circuit_red) ~= nil or
	                  display.get_circuit_network(W.circuit_green) ~= nil
	local ctrl = connected and display.get_control_behavior() or nil --[[@as LuaDisplayPanelControlBehavior]]
	if ctrl then
		for _,m in ipairs(ctrl.messages) do
			if m.icon and m.text and m.text:find("{[^{}]*}") then
				return true
			end
		end
	end
	return false
end

---@param ctrl LuaDisplayPanelControlBehavior
local function reset_messages(ctrl)
	for i,m in ipairs(ctrl.messages) do
		if m.text then
			m.text = m.text:gsub("{[^{}]*}", "{}")
			ctrl.set_message(i, m)
		end
	end
end

-- stop updating, clean messages so user can properly edit
---@param id integer
local function reset_display(id)
	local data = storage.active_displays[id]
	if data then
		local ctrl = data.entity and data.entity.valid and data.entity.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior]]
		if ctrl then
			reset_messages(ctrl)
		end
		
		for _,ac in pairs(data.acs) do
			ac.destroy()
		end
		
		local surf = storage.surfaces[data.sid]
		if surf then
			surf.chart[id] = nil
			surf.alt[id] = nil
		end
		
		storage.extra_update[data] = nil
		
		storage.active_displays[id] = nil
	end
end

-- start or stop updating display depending on if any messages contain format trigger {}
---@param display LuaEntity
local function check_display(display)
	local id = display.unit_number ---@cast id -nil
	
	if should_update(display) then
		local data = storage.active_displays[id]
		if not data then
			script.register_on_object_destroyed(display)
			
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
			
			data = {
				entity = display,
				sid = display.surface_index,
				acs = {
					make_combinator(-0.4, -1.5, AC_NEGATE_EACH_R, W.circuit_red),
					make_combinator(0.4, -1.5, AC_NEGATE_EACH_G, W.circuit_green),
				}
			}
			storage.active_displays[id] = data
		end
		
		-- update update lists
		local surf = storage.surfaces[display.surface_index] or { chart={}, alt={} }
		
		surf.chart[id] = display.display_panel_show_in_chart and data or nil
		surf.alt[id] = display.display_panel_always_show and data or nil
		
		storage.surfaces[display.surface_index] = surf
		
		-- updated_last_tick optimization might not be valid for this display
		storage.extra_update[data] = true
	else
		reset_display(id)
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

---@param display LuaEntity
local function update_messages(display)
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
		if not all_signals then
			return input:gsub("{[^{}]*}", "{ }", 1)
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
	-- Destructive operation, does not work with current {} approach
	-----@param input string
	-----@returns string, SignalID
	--local function get_any_signal_text(input)
	--	all_signals = all_signals or display.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
	--	
	--	if not all_signals or #all_signals == 0 then
	--		return {}, ""
	--	end
	--	
	--	table.sort(all_signals, _comp_signal)
	--	
	--	local signal = all_signals[1]
	--	
	--	return signal.signal, format_count_text(input, signal.count)
	--end
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
				
				--ctrl.set_message(i, {
				--	icon = icon,
				--	text = text,
				--	condition = m.condition,
				--})
			end
		end
	end
end

local function optimized_update(event)
	-- optimize if no displays are placed
	if next(storage.active_displays) == nil then
		storage.updated_last_tick = storage.updated_last_tick or {}
		storage.extra_update = storage.extra_update or {}
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
		
		local sel = player.selected
		local data = sel and sel.valid and storage.active_displays[sel.unit_number] or nil
		if data and not (surf.chart[data] or surf.alt[data]) then
			extra_update[data] = true
		end
		
		::continue::
	end
	
	-- if update list was not updates last tick, bypass change detection
	local updated_last_tick = storage.updated_last_tick
	
	for update_list, _ in pairs(update_lists) do
		if updated_last_tick[update_list] == nil then
			-- change detect ACs not valid since not read last tick
			for _, data in pairs(update_list) do
				update_messages(data.entity)
				extra_update[data] = nil
			end
		else
			for _, data in pairs(update_list) do
				-- Cool optimization: edge detector AC, read combined inputs (current + negated_previous tick signals) if get_signals()=nil, then no change
				-- Need 2 to catch red and green wires (could usually avoid get_signals if wire connect/disconnect was an event, but unclear how slow 1 API call actually is vs the extra check in lua
				-- This change detection only works if we also updated this display last tick!
				local acA = data.acs[1]
				local acB = data.acs[2]
				if acA.get_signals(CR, CG) ~= nil or
				   acB.get_signals(CR, CG) ~= nil then
					update_messages(data.entity)
					extra_update[data] = nil
				end
			end
		end
	end
	
	-- handle hovered displays and displays that were modified/added potentially breaking change detect
	-- (don't add observed checks as this is rare)
	for data, _ in pairs(extra_update) do
		update_messages(data.entity)
	end
	
	storage.updated_last_tick = update_lists
	storage.extra_update = {}
end

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

script.on_event(defines.events.on_tick, optimized_update)

---@param e LuaEntity
---@returns boolean
local function is_display_planel(e)
	return e and e.valid and e.type == "display-panel"
end

-- Start tracking new entities
-- stop updating while gui is open to make editing message easier
local function on_entity_event(event)
	local entity = event.entity or event.destination --[[@as LuaEntity]]
	if is_display_planel(entity) then
		if event.name == defines.events.on_gui_opened then
			reset_display(entity.unit_number)
		else
			check_display(entity)
		end
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
script.on_event(defines.events.on_gui_opened, on_entity_event)
script.on_event(defines.events.on_gui_closed, on_entity_event)

script.on_event(defines.events.on_entity_settings_pasted, on_entity_event) -- source to destination

script.on_event(defines.events.on_object_destroyed, function(event)
	if event.type == defines.target_type.entity then
		reset_display(event.useful_id)
	end
end)

local function init()
	storage = {}
	storage.active_displays = {}
	storage.surfaces = {}
	storage.extra_update = {}
	storage.updated_last_tick = {}
	
	for _, surface in pairs(game.surfaces) do
		for _, display in ipairs(surface.find_entities_filtered{ type="display-panel" }) do
			check_display(display)
		end
	end
end
local function _reset()
	for id,_ in pairs(storage.active_displays) do
		reset_display(id)
	end
	
	for _, s in pairs(game.surfaces) do
		for _, name in pairs({"hidden-change-detector"}) do
			for _, e in pairs(s.find_entities_filtered{ name="hexcoder-signal-display-"..name }) do
				e.destroy()
			end
		end
	end
	
	init()
end
script.on_init(function(event)
	init()
end)

--script.on_configuration_changed(function(data)
--	local changes = data.mod_changes["hexcoder-signal-display"]
--	if not changes then return end
--	local old = changes.old_version
--	if not old then return end -- on_init already handles existing save
--	
--	game.print("")
--end)

-- removed to not clutter up /help
commands.add_command("hexcoder-signal-display-reset", nil, function(command)
	_reset()
end)

commands.add_command("hexcoder-signal-display-migrate", nil, function(command)
	for _, surface in pairs(game.surfaces) do
		for _, display in ipairs(surface.find_entities_filtered{ type="display-panel" }) do
			local ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior]]
			for i,m in ipairs(ctrl.messages) do
				--m.text:gsub("(%[[%w-]+=[%w-]+%] [%d.]+[ ]?)+", "{}")
				m.text:gsub("%[[^%[%]]%]", "{}")
				m.text:gsub("[%d.]+", "{}")
				ctrl.set_message(i, m)
			end
		end
	end
	
	_reset()
end)