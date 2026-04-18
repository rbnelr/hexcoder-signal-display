data:extend({
	{
		type = "int-setting",
		name = "hexcoder-signal-display-poll-period",
		localised_name = "Polling interval (performance)",
		localised_description = "Raise to improve performance with many non-updating displays\nSet to 0 to disable polling\nPolling is only done to ensure correct display even after changing settings by blueprinting-over, undo/redo or changing wires, which lack modding-API events",
		setting_type = "runtime-global",
		default_value = 360, minimum_value = 0, maximum_value = 1800
	}
})
