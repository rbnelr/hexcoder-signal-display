mod_name = "hexcoder-signal-display-"
local dbg = true

local function make_hidden(thing)
	thing.flags = {"not-on-map",
		"not-rotatable", "not-flammable", "not-repairable",
		"not-deconstructable", "not-blueprintable", "no-copy-paste", "not-upgradable",
		"not-in-kill-statistics", "not-in-made-in",
		"no-automated-item-removal", "no-automated-item-insertion"
	}
	
	thing.hidden = true
	thing.minable = {minable=false, mining_time=999999}
	thing.corpse = nil
	thing.dying_explosion = nil
	thing.collision_box = nil
	thing.collision_mask = { layers = {} }
	thing.damaged_trigger_effect = nil
	thing.fast_replaceable_group = nil
	thing.open_sound = nil
	thing.close_sound = nil
	thing.impact_category = nil
	
	if dbg then
		thing.selection_priority = 100
	else
		table.insert(thing.flags, "hide-alt-info")
		
		thing.picture = nil
		thing.sprites = nil
		
		thing.selection_box = {{0,0}, {0,0}}
		thing.selectable_in_game = false
		
		thing.draw_circuit_wires = false
		
		-- CC
		thing.activity_led_light = nil
		thing.activity_led_sprites = nil
		-- DC
		thing.equal_symbol_sprites = nil
		thing.greater_symbol_sprites = nil
		thing.less_symbol_sprites = nil
		thing.greater_or_equal_symbol_sprites = nil
		thing.less_or_equal_symbol_sprites = nil
		thing.not_equal_symbol_sprites = nil
		-- AC
		thing.plus_symbol_sprites = nil
		thing.minus_symbol_sprites = nil
		thing.multiply_symbol_sprites = nil
		thing.divide_symbol_sprites = nil
		thing.modulo_symbol_sprites = nil
		thing.power_symbol_sprites = nil
		thing.left_shift_symbol_sprites = nil
		thing.right_shift_symbol_sprites = nil
		thing.and_symbol_sprites = nil
		thing.or_symbol_sprites = nil
		thing.xor_symbol_sprites = nil
	end
end

local ac = util.table.deepcopy(data.raw["arithmetic-combinator"]["arithmetic-combinator"])
ac.name = mod_name.."hidden-change-detector"
ac.energy_source = { type = "void" }
make_hidden(ac)

data:extend({ac})
