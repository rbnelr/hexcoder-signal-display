---@type ModStorage
storage = storage

---@class unit_number integer

---@class ModStorage
---@field displays table<unit_number, DisplayData>

---@class DisplayData
---@field entity LuaEntity



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
	script.on_event(event, on_created_or_gui_opened, {{filter = "type", type = "radar"}, {filter = "name", name = "radar"}})
end
-- catch existing display panels after installing mod (lazy, should do migrations with surface scanning)
script.on_event(defines.events.on_gui_opened, on_created_or_gui_opened)

-- TODO: optimize for updating only close to players
-- also: display_panel_always_show and display_panel_show_in_chart

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

---@param id unit_number
---@param data DisplayData
local function update(id, data)
	local display = data.entity
	-- display.display_panel_text and display.display_panel_icon
	-- are essentially variables that the player can config if the display is not connect to circuits
	-- when the display is connected to circuits they can configure circuit conditions
	-- and the first condition that is true overwrites the variables permanently
	-- sadly the API does not let us write display_panel_text if connected to circuits (maybe becasue the game itself updates this string later)
	-- so we have to permanently clobber the message texts/icons in the control behavior instead
	
	local ctrl = display and display.valid and display.get_control_behavior() ---@as LuaDisplayPanelControlBehavior?
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
			if m.icon.type == "virtual" and m.icon.name == "signal-everything" then
				-- convenience feature: its annoying that when connecting circuit to display panel by default it shows nothing
				--if m.text == "" and m.condition then
				--	m.text = "[]"
				--end
				
				m.text = get_all_signals_text(m.text or "")
				ctrl.set_message(i, m)
			elseif m.icon.type == "virtual" and m.icon.name == "signal-anything" then
				-- any configured, game shows some signal, get last tick shown signal
				-- this is bad? perhaps we can easily determine actually shown signal? like get is it just all_signals[1]?
				if display.display_panel_icon then
					m.text = get_signal_text(m.text or "", display.display_panel_icon)
					ctrl.set_message(i, m)
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

script.on_event(defines.events.on_tick, function(event)
	for id, data in pairs(storage.displays) do
		update(id, data)
	end
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

commands.add_command("hexcoder-signal-display-reset", nil, function(command)
	_reset()
end)
