---@type ModStorage
storage = storage

---@class unit_number integer

---@class ModStorage
---@field displays table<unit_number, DisplayData>

---@class DisplayData
---@field entity LuaEntity

script.on_event(defines.events.on_gui_opened, function(event)
	if (event.gui_type == defines.gui_type.entity and
	  event.entity and event.entity.valid and event.entity.type == "display-panel") then
		-- register all displays that were opened for now
		local _, id = script.register_on_object_destroyed(event.entity)
		
		local data = storage.displays[id]
		if not data then
			storage.displays[id] = { entity=event.entity }
		end
	end
end)

script.on_event(defines.events.on_object_destroyed, function(event)
	if event.type == defines.target_type.entity then
		storage.displays[event.useful_id] = nil
	end
end)

-- TODO: display_panel_always_show and display_panel_show_in_chart
-- It think display_panel_always_show means we only need to update if player.selected == display (?)

local _cached_signals = {}

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
	
	local ctrl = display.get_control_behavior() ---@as LuaDisplayPanelControlBehavior?
	if not ctrl then return end
	
	-- Message text is limited to 500 characters without respecting rich text formatting
	-- and if it exceeds that the rich text might break!
	-- In GUI it is limited to 500 chars, the show in alt view is limited to even less (it auto wraps into multiple lines)
	-- in all of these cases rich text visually breaks
	
	-- format:
	-- if text empty: entire text becomes mixed signals
	-- or {RG} becomes mixed signals {R} or {G} become their respective signals
	--
	local function format_all_signals_text(last_text)
		-- TODO: cache
		--local r = display.get_circuit_network(defines.wire_connector_id.circuit_red)
		--local g = display.get_circuit_network(defines.wire_connector_id.circuit_green)
		--
		--r = r and _cached_signals[r.network_id] or {}
		--g = g and _cached_signals[g.network_id] or {}
		
		local signals = display.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green) or {}
		
		local function comp_signal(l, r)
			return l.count > r.count
		end
		table.sort(signals, comp_signal)
		
		
		local format = last_text:gsub("{%[color=red%].*%[/color%]}", "{R}")
		
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
			["asteroid-chunk"]="item", -- TODO: test as these are weird
			["quality"]="quality"
		}
		local max_per_line = 4
		
		-- length of {[color=red][/color]} = 21
		local safe_len = 500 - (#format-3) - 21
		
		local stext = nil
		for i,s in ipairs(signals) do
			local new_text = stext and (stext.." ") or "" -- space as list seperator
			
			-- rich text is: [item=copper-plate] or for non-normal quality: [item=copper-plate,quality=epic]
			local sig = s.signal
			local type = signal2rich_text[sig.type] or "item"
			if not sig.quality then
				new_text = string.format("%s[%s=%s] %d", new_text, type,sig.name, s.count)
			else
				new_text = string.format("%s[%s=%s,quality=%s] %d", new_text, type,sig.name,sig.quality, s.count)
			end
			
			if #new_text > safe_len then
				goto stop
			end
			stext = new_text
		end
		::stop::
		
		text = format:gsub("{R}", string.format("{[color=red]%s[/color]}", stext or ""))
		local len = #text
		
		return text
	end
	
	-- in on_tick display_panel_text will be from last tick, ie the selected message based on its condition has not yet taken into account the current signals
	-- -> we either have to update all messages every tick so they game displays them updated, or figure out the condition ourselves
	
	--game.print("circuit: ".. serpent.line(r.signals))
	
	for i,m in ipairs(ctrl.messages) do
		if m.icon and m.icon.type == "virtual" and m.icon.name == "signal-everything" then
			-- convenience feature: its annoying that when connecting circuit to display panel by default it shows nothing
			--if m.text == "" and m.condition then
			--	m.text = "[]"
			--end
			
			m.text = format_all_signals_text(m.text)
			ctrl.set_message(i, m)
		end
	end
	
	--game.print(serpent.line({ signals }))
	
end

script.on_event(defines.events.on_tick, function(event)
	_cached_signals = {}
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
