--[[
	TODO: add nixie tube style mode?
]]

---@type ModStorage
storage = storage

---@class unit_number integer

---@class ModStorage
---@field tracked_displays table<unit_number, DisplayData>

---@class DisplayData
---@field entity LuaEntity
---@field set_convenient_condition_once? boolean -- set condition conveniently once, set to nil afterwards
---@field unmodified_messages DisplayPanelMessageDefinition[]

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


local function migrate()
	for _,data in pairs(storage.tracked_displays) do
		for i,m in ipairs(data.unmodified_messages) do
			if m.text then
				local form = m.text:match("(/%d+f%d+)") or ""
				m.text = m.text:gsub("{[^{}]*}", "{"..form.."}")
			end
		end
	end
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
---@param display LuaEntity
local function stop_tracking(display)
	local id = display.unit_number ---@cast id -nil
	local data = storage.tracked_displays[id]
	if data then
		local ctrl = display.get_or_create_control_behavior() --[[@as LuaDisplayPanelControlBehavior?]]
		if ctrl then
			ctrl.messages = data.unmodified_messages
		end
		
		storage.tracked_displays[id] = nil
	end
end
-- start or stop updating depending on if any messages contain {}
---@param display LuaEntity
local function update_tracking(display)
	local ctrl = display.get_control_behavior() --[[@as LuaDisplayPanelControlBehavior]]
	if ctrl and has_any_trigger_message(ctrl) then
		local id = display.unit_number ---@cast id -nil
		local data = storage.tracked_displays[id]
		if not data then
			script.register_on_object_destroyed(display)
			
			data = {
				entity = display,
				set_convenient_condition_once = true,
				unmodified_messages = ctrl.messages
			}
			storage.tracked_displays[id] = data
		end
	else
		stop_tracking(display)
	end
end

script.on_event(defines.events.on_object_destroyed, function(event)
	if event.type == defines.target_type.entity then
		storage.tracked_displays[event.useful_id] = nil
	end
end)

local has_set_convenient_condition_once

---@param display LuaEntity
local function tick_gui(display)
	local id = display.unit_number ---@cast id -nil
	
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
					-- if signal-anything is set, game shows arbitrary signal (not sorted by count)
					-- entity.display_panel_icon is what signal game chose, but is from last tick!
					-- could pick one signal ourselves, for example the highest count, but let's rely on the game
					-- the count will be 0-tick, if the signal switches this will be wrong for 1-tick...
					--disp_text = get_signal_text(m.text or "", display.display_panel_icon)
					
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
end

local function need_update(chart_view, alt_mode, selected, open, entity)
	if entity == open then -- update always if gui is open
		--return true
		assert(false)
	end
	if chart_view then
		return entity.display_panel_show_in_chart -- update if player in chart mode
	else
		return (entity.display_panel_always_show and alt_mode) or entity == selected -- update if play and panel in alt mode or if hovered
	end
end
local function test_observed_optimization()
	local margin = 1.15 -- at least try to catch stuff that is slightly off-screen
	-- unlike many games, zoom is not tied to vertical or horizontal fov/orthographic diameter
	-- instead at zoom=1 I get 1 tile being drawn at 32 pixels at my specific window resolution, 2 is zoomed in to 1 tile=64
	local factor = margin*0.5/32
	
	for _, player in pairs(game.players) do
		if not player.connected then goto continue end
		local chart = player.render_mode == defines.render_mode.chart -- game view or char_zoomed_in render actual entities, chart is map mode
		local alt = player.game_view_settings.show_entity_info
		local sel = player.selected -- hovered
		local open = player.opened
		--game.print("".. serpent.block(player.render_mode))
		
		local half_sizeX = player.display_resolution.width * factor / player.zoom -- can listen to on_player_display_resolution_changed
		local half_sizeY = player.display_resolution.height * factor / player.zoom
		
		local x0 = player.position.x - half_sizeX
		local x1 = player.position.x + half_sizeX
		local y0 = player.position.y - half_sizeY
		local y1 = player.position.y + half_sizeY
		--rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x0, y= y1 }, color={.2,1,.2}, width=4, surface=player.surface, time_to_live=1 }
		--rendering.draw_line{ from={ x=x1, y=y0 }, to={ x=x1, y= y1 }, color={.2,1,.2}, width=4, surface=player.surface, time_to_live=1 }
		--rendering.draw_line{ from={ x=x0, y=y0 }, to={ x=x1, y= y0 }, color={.2,1,.2}, width=4, surface=player.surface, time_to_live=1 }
		--rendering.draw_line{ from={ x=x0, y=y1 }, to={ x=x1, y= y1 }, color={.2,1,.2}, width=4, surface=player.surface, time_to_live=1 }
		--
		--game.print("".. serpent.block{ player.display_resolution, player.zoom, half_sizeX })
		
		-- simply run entities filtered per player to find entities, this may be expensive, especially in chart mode if most displays have display_panel_show_in_chart=false
		-- TODO: could query 1 chunk more and cache chart/alt/all entity lists unless player switched chunks! should be really cheap
		-- alternatively have to scan large list or build accel structure in lua (simple chunk display lists lookup?) -> annoying though
		-- TODO: actually is is extremely slow!!
		local displays = player.surface.find_entities_filtered{type="display-panel", area={{x0,y0}, {x1,y1}}, force=player.force}
		for _,entity in ipairs(displays) do
			local data = storage.tracked_displays[entity.unit_number]
			if data then
				if need_update(chart, alt, sel, open, entity) then
					update(entity, data)
				end
			end
		end
		::continue::
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
	--for _, data in pairs(storage.displays) do
	--	if display and display.valid then
	--		update(_, data)
	--	end
	--end
	
	test_observed_optimization()
end)

-- Start tracking new or existing entities if needed
local function on_entity_event(event)
	local entity = event.entity or event.destination --[[@as LuaEntity]]
	if entity and entity.valid and entity.type == "display-panel" then
		update_tracking(entity)
	end
end
local function on_gui_open(event)
	local entity = event.entity --[[@as LuaEntity]]
	if entity and entity.valid and entity.type == "display-panel" then
		stop_tracking(entity)
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
	defines.events.on_entity_cloned,
}) do
	script.on_event(event, on_entity_event, {{filter = "type", type = "display-panel"}})
end
script.on_event(defines.events.on_gui_opened, on_gui_open)
script.on_event(defines.events.on_gui_closed, on_gui_close)

local function init(clean)
	storage.tracked_displays = {}
	
	if not clean then
		for _, surface in pairs(game.surfaces) do
			for _, display in ipairs(surface.find_entities_filtered{ type="display-panel" }) do
				update_tracking(display)
			end
		end
	end
end
local function _reset()
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

commands.add_command("hexcoder-signal-display-migrate", nil, function(command)
	migrate()
end)