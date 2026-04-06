---@type ModStorage
storage = storage

---@class unit_number integer

---@class ModStorage
---@field displays table<unit_number, DisplayData>

---@class DisplayData
---@field entity LuaEntity

-- TODO: optimize for updating only close to players !!!
-- also: display_panel_always_show and display_panel_show_in_chart
-- TODO: nixie tube style (automatically config which 

local function on_created_or_gui_opened(event)
	local entity = event.entity or event.destination
	if entity and entity.valid and entity.type == "display-panel" then
		local _, id = script.register_on_object_destroyed(entity)
		
		local data = storage.displays[id]
		if not data then
			storage.displays[id] = { entity=entity }
		end
	end
end

script.on_event(defines.events.on_object_destroyed, function(event)
	if event.type == defines.target_type.entity then
		storage.displays[event.useful_id] = nil
	end
end)

for _, event in ipairs({
	defines.events.on_built_entity,
	defines.events.on_robot_built_entity,
	defines.events.on_space_platform_built_entity,
	defines.events.script_raised_built,
	defines.events.script_raised_revive,
	defines.events.on_entity_cloned,
}) do
	script.on_event(event, on_created_or_gui_opened, {{filter = "type", type = "display-panel"}})
end
-- catch existing display panels after installing mod (lazy, should do migrations with surface scanning)
script.on_event(defines.events.on_gui_opened, on_created_or_gui_opened)

-- examples:
-- [virtual-signal=signal-deny] [entity=big-biter]  [virtual-signal=signal-B]
-- [item=metallic-asteroid-chunk] [planet=gleba] [recipe=rocket-part] [fluid=crude-oil]
-- [item=parameter-2] [item=green-wire] [entity=entity-ghost] [quality=epic]"

local signal2rich_text = {
	--["item"]="item" -- actually nil in SignalID, so handled via nil check
	["fluid"]="fluid",
	["virtual"]="virtual-signal",
	["entity"]="entity",
	["recipe"]="recipe",
	["space-location"]="planet",
	["asteroid-chunk"]="item",
	["quality"]="quality"
}

---@param display LuaEntity
---@param data DisplayData
local function update(display, data)
	-- display.display_panel_text and display.display_panel_icon
	-- are essentially variables that the player can config if the display is not connect to circuits
	-- when the display is connected to circuits they can configure circuit conditions
	-- and the first condition that is true overwrites the variables permanently
	-- sadly the API does not let us write display_panel_text if connected to circuits (maybe becasue the game itself updates this string later)
	-- so we have to permanently clobber the message texts/icons in the control behavior instead
	
	local ctrl = display.get_control_behavior() ---@as LuaDisplayPanelControlBehavior?
	if not ctrl then return end
	
	-- Message text is limited to 500 characters without respecting rich text formatting
	-- and if it exceeds that the rich text might break!
	-- In GUI it is limited to 500 chars, the show in alt view is limited to even less (it auto wraps into multiple lines)
	-- in all of these cases rich text visually breaks
	
	-- cache signal text for local displays since they might countain multiple conditions and we have to update all of them
	-- actually want to customize printing now, so be careful for now
	--local cached_signal_text
	local function get_all_signals_text(input)
		--if cached_signal_text then return cached_signal_text end
		
		local signals = display.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green) or {}
		if not signals then
			return input:gsub("{[^{}]*}", "{}", 1)
		end
		
		local function comp_signal(l, r)
			return l.count > r.count
		end
		table.sort(signals, comp_signal)
		
		-- support fixed point values: /1000f3 => signal=1234567 -> 123.457 (.4567 rounded to .457)
		-- don't support more variations due to heavy lua regex limitations
		local divisor, precision = input:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		local num_format = precision and string.format("%%.%df", precision) or "%d"
		
		local form = "%s[%s=%s] "..num_format
		local formQ = "%s[%s=%s,quality=%s] "..num_format
		
		local text = nil
		for i,s in ipairs(signals) do
			text = text and (text.." ") or "" -- space as list seperator
			
			-- rich text is: [item=copper-plate] or for non-normal quality: [item=copper-plate,quality=epic]
			local sig = s.signal
			local type = signal2rich_text[sig.type] or "item"
			if not sig.quality then
				text = string.format(form, text, type,sig.name, s.count/div)
			else
				text = string.format(formQ, text, type,sig.name,sig.quality, s.count/div)
			end
		end
		text = text or ""
		
		--cached_signal_text = text
		return input:gsub("{[^{}]*}", string.format("{%s}", text), 1)
	end
	local function get_signal_text(input, icon)
		-- replace {} with rich text font to remove ugly {} in display while still allowing user defined text surrounding it
		local format = input:gsub("%[font=default%-bold%].*%[/font%]", "{}")
		
		local count = display.get_signal(icon, defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		
		local divisor, precision = format:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		local num_format = precision and string.format("[font=default-bold]%%.%df[/font]", precision) or "[font=default-bold]%d[/font]"
		
		return format:gsub("{[^{}]*}", string.format(num_format, count / div), 1)
	end
	local function get_any_signal_text(input, icon)
		-- replace {} with rich text font to remove ugly {} in display while still allowing user defined text surrounding it
		local format = input:gsub("%[font=default%-bold%].*%[/font%]", "{}")
		
		local count = display.get_signal(icon, defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
		
		local divisor, precision = format:match("/(%d+)f(%d+)")
		local div = tonumber(divisor) or 1
		local num_format = precision and string.format("[font=default-bold]%%.%df[/font]", precision) or "[font=default-bold]%d[/font]"
		
		return format:gsub("{[^{}]*}", string.format(num_format, count / div), 1)
	end
	
	-- in on_tick display_panel_text will be from last tick, ie the selected message based on its condition has not yet taken into account the current signals
	-- -> we either have to update all messages every tick so they game displays them updated, or figure out the condition ourselves
	
	--game.print("circuit: ".. serpent.line(r.signals))
	
	for i,m in ipairs(ctrl.messages) do
		if m.icon then
			if m.icon.type == "virtual" then
				-- TODO:
				-- -> consider this: each=showing all signals, everything=showing sum, anything=show anything like vanilla + count
				if m.icon.name == "signal-everything" then
					-- convenience feature: its annoying that when connecting circuit to display panel by default it shows nothing
					--if m.text == "" and m.condition then
					--	m.text = "[]"
					--end
					
					m.text = get_all_signals_text(m.text or "")
					ctrl.set_message(i, m)
				elseif m.icon.name == "signal-each" then
					
				elseif m.icon.name == "signal-anything" then
					-- if any icon is configured, game shows some signal (not sorted by count)
					-- display.display_panel_icon we read here is from last tick!
					-- seemingly there is no easy way to ask for the first signal in the sorted list
					-- this sounds bad, but the count will be 0-tick, only on signal switches is this 1-tick delay, which is probalby fine...
					if display.display_panel_icon then
						m.text = get_signal_text(m.text or "", display.display_panel_icon)
						ctrl.set_message(i, m)
					end
				end
			else
				-- show configured signal
				m.text = get_signal_text(m.text or "", m.icon)
				ctrl.set_message(i, m)
			end
		end
	end
	
	--game.print(serpent.line({ signals }))
	
end

local function need_update(chart_view, alt_mode, selected, open, entity)
	if entity == open then
		return true
	end
	if chart_view then
		return entity.display_panel_show_in_chart
	else
		return (entity.display_panel_always_show and alt) or entity == sel
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
		local displays = player.surface.find_entities_filtered{type="display-panel", name="display-panel", area={{x0,y0}, {x1,y1}}, force=player.force}
		for _,entity in ipairs(displays) do
			local data = storage.displays[entity.unit_number]
			if data then
				if need_update(chart, alt, sel, open, entity) then
					update(entity, data)
				end
			end
		end
		::continue::
	end
end

script.on_event(defines.events.on_tick, function(event)
	--for _, data in pairs(storage.displays) do
	--	if display and display.valid then
	--		update(_, data)
	--	end
	--end
	
	test_observed_optimization()
end)

local function init(clean)
	storage.displays = {}
	
	if not clean then
		-- TODO: register existing panels that might be configured for signal display already
	end
end
local function _reset()
	init(false)
end
script.on_init(function(event)
	init(true)
end)

-- removed to not clutter up /help
--commands.add_command("hexcoder-signal-display-reset", nil, function(command)
--	_reset()
--end)
