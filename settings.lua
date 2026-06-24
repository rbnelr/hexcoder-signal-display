mod_name = "hexcoder-signal-display-"
data:extend({
	{
		type = "bool-setting",
		name = mod_name.."debug",
		localised_name = "Debug Mode",
		localised_description = "Developer setting to show hidden combinators and visualize updates",
		setting_type = "startup",
		default_value = false
	}
})
