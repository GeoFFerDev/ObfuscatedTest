-- Roblox/loadstring-safe config.
-- Use with: lua ./cli.lua --config ./configs/roblox_safe.lua ./your_file.lua

return {
	LuaVersion = "LuaU",
	VarNamePrefix = "",
	NameGenerator = "MangledShuffled",
	PrettyPrint = false,
	Seed = 0,
	Steps = {
		{ Name = "EncryptStrings", Settings = {} },
		{
			Name = "ConstantArray",
			Settings = {
				Threshold = 1,
				StringsOnly = true,
				Shuffle = true,
				Rotate = true,
				LocalWrapperThreshold = 0,
			},
		},
		{ Name = "NumbersToExpressions", Settings = {} },
		{ Name = "WrapInFunction", Settings = {} },
	},
}
