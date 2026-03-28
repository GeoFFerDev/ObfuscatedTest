-- This Script is Part of the Prometheus Obfuscator by Levno_710
--
-- pipeline.lua
--
-- This Script provides a configurable obfuscation pipeline that can obfuscate code using different modules
-- These modules can simply be added to the pipeline.

local Enums = require("prometheus.enums");
local util = require("prometheus.util");
local Parser = require("prometheus.parser");
local Unparser = require("prometheus.unparser");
local logger = require("logger");

local NameGenerators = require("prometheus.namegenerators");

local Steps = require("prometheus.steps");
local LuaVersion = Enums.LuaVersion;
local MAX_SAFE_SEED = 2147483647; -- 32-bit signed max for broad RNG compatibility
local MAX_SAFE_INT = 9007199254740991; -- max precise integer in IEEE754 doubles

-- Use CPU time for sub-second benchmark precision across platforms.
local function gettime()
	return os.clock();
end

local function parseHexToNumber(hex)
	local n = 0;
	for i = 1, #hex do
		local char = hex:sub(i, i):lower();
		local digit = char:match("%d") and (char:byte() - 48) or (char:byte() - 87);
		n = (n * 16 + digit) % MAX_SAFE_INT;
	end
	return n;
end

local function generateSecureSeed()
	-- Try /dev/urandom first to avoid process-spawn overhead.
	local success, seed = pcall(function()
		local handle = io.open("/dev/urandom", "rb");
		if handle then
			local bytes = handle:read(8);
			handle:close();
			if bytes and #bytes == 8 then
				return parseHexToNumber((bytes:gsub(".", function(c)
					return string.format("%02x", string.byte(c));
				end)));
			end
		end
		error("urandom unavailable");
	end);

	if success and seed then
		return seed;
	end

	-- Fallback for systems without /dev/urandom.
	success, seed = pcall(function()
		local cmd = io.popen("openssl rand -hex 8");
		if not cmd then
			error("openssl unavailable");
		end
		local hex = (cmd:read("*a") or ""):gsub("\n", "");
		cmd:close();
		if #hex == 0 then
			error("empty openssl output");
		end
		return parseHexToNumber(hex);
	end);

	if success and seed then
		return seed;
	end

	-- Last-resort seed with multiple low-correlation sources.
	local coarse = os.time();
	local fine = math.floor((os.clock() or 0) * 1000000);
	local mem = math.floor(collectgarbage("count") * 1000);
	return coarse + fine + mem;
end

local function normalizeSeed(seed)
	seed = math.floor(math.abs(tonumber(seed) or 0));
	seed = seed % MAX_SAFE_SEED;
	if seed == 0 then
		seed = (os.time() % MAX_SAFE_SEED);
		if seed == 0 then
			seed = 1;
		end
	end
	return seed;
end

local function simpleHash(text)
	local h = 7;
	for i = 1, #text do
		h = (h * 131 + text:byte(i));
		h = h % MAX_SAFE_SEED;
	end
	if h < 0 then
		h = -h;
	end
	return h;
end

local function toBase36(num)
	local alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
	if num == 0 then
		return "0";
	end
	local out = "";
	while num > 0 do
		local rem = (num % 36) + 1;
		out = alphabet:sub(rem, rem) .. out;
		num = math.floor(num / 36);
	end
	return out;
end

local function buildUniqueVarPrefix(seed, sourceLen, styleSignature)
	local signature = tostring(styleSignature or "default");
	local mixed = tostring(seed) .. ":" .. tostring(sourceLen) .. ":" .. signature;
	local hash = simpleHash(mixed);
	return "_" .. toBase36(hash) .. "_";
end

local function normalizePaddingRatio(value)
	if value == nil then
		return nil;
	end
	local ratio = tonumber(value);
	if not ratio then
		return nil;
	end
	-- Keep values sane; >10x source is very likely accidental.
	if ratio < 0 then
		ratio = 0;
	elseif ratio > 10 then
		ratio = 10;
	end
	return ratio;
end

local function padOutputToRatio(code, sourceLen, ratio)
	if sourceLen <= 0 then
		return code;
	end
	local desiredSize = math.floor(sourceLen * ratio);
	if desiredSize <= #code then
		return code;
	end

	-- Block comment padding has zero runtime cost and is Roblox-safe.
	local payloadLen = desiredSize - #code;
	if payloadLen <= 8 then
		return code .. string.rep(" ", payloadLen);
	end

	local coreLen = payloadLen - 8; -- account for "\n--[[", "]]"
	return code .. "\n--[[" .. string.rep("P", coreLen) .. "]]";
end

local Pipeline = {
	NameGenerators = NameGenerators;
	Steps = Steps;
	Profiles = {
		-- Luraph-like strategy: high resistance with controlled runtime overhead.
		LuraphLikeFast = {
			LuaVersion = LuaVersion.LuaU;
			UniqueOutput = true;
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
				{
					Name = "NumbersToExpressions",
					Settings = {
						NumberRepresentationMutaton = false,
					},
				},
				{ Name = "Vmify", Settings = {} },
				{ Name = "WrapInFunction", Settings = {} },
			},
		},
		-- Roblox-safe level-3 profile:
		-- keeps VM virtualization enabled, avoids risky syntax tricks, and can
		-- pad the output size to look denser while preserving runtime behavior.
		RobloxSafeVMLevel3 = {
			LuaVersion = LuaVersion.LuaU;
			UniqueOutput = true;
			OutputPaddingRatio = 0.98;
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
				{
					Name = "NumbersToExpressions",
					Settings = {
						NumberRepresentationMutaton = false,
					},
				},
				-- Force VM virtualization in the Roblox-safe profile.
				{ Name = "Vmify", Settings = {} },
				{ Name = "WrapInFunction", Settings = {} },
			},
		},
		-- RedzHub-inspired string-table VM profile:
		-- focuses on dense encoded constants + VM wrapper while remaining LuaU-safe.
		RedzHubLikeVM = {
			LuaVersion = LuaVersion.LuaU;
			UniqueOutput = true;
			OutputPaddingRatio = 0.98;
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
				{ Name = "SplitStrings", Settings = {} },
				{
					Name = "NumbersToExpressions",
					Settings = {
						NumberRepresentationMutaton = false,
					},
				},
				{ Name = "Vmify", Settings = {} },
				{ Name = "WrapInFunction", Settings = {} },
			},
		},
	};
	DefaultSettings = {
		LuaVersion = LuaVersion.LuaU; -- The Lua Version to use for the Tokenizer, Parser and Unparser
		PrettyPrint = false; -- Note that Pretty Print is currently not producing Pretty results
		Seed = 0; -- The Seed. 0 or below uses the current time as a seed
		VarNamePrefix = ""; -- The Prefix that every variable will start with
		UniqueOutput = false; -- If true, derive a unique variable prefix from seed/style
		StyleSignature = "Default"; -- Free-form style token used in UniqueOutput prefix derivation
		StyleProfile = nil; -- Optional table for sample-guided style tweaks
		OutputPaddingRatio = nil; -- Optional minimum output/source ratio (e.g. 0.98)
	}
}


function Pipeline:new(settings)
	local luaVersion = settings.luaVersion or settings.LuaVersion or Pipeline.DefaultSettings.LuaVersion;
	local conventions = Enums.Conventions[luaVersion];
	if(not conventions) then
		logger:error("The Lua Version \"" .. luaVersion
			.. "\" is not recognized by the Tokenizer! Please use one of the following: \"" .. table.concat(util.keys(Enums.Conventions), "\",\"") .. "\"");
	end

	local prettyPrint = settings.PrettyPrint or Pipeline.DefaultSettings.PrettyPrint;
	local prefix = settings.VarNamePrefix or Pipeline.DefaultSettings.VarNamePrefix;
	local seed = settings.Seed or 0;

	local pipeline = {
		LuaVersion = luaVersion;
		PrettyPrint = prettyPrint;
		VarNamePrefix = prefix;
		Seed = seed;
			UniqueOutput = settings.UniqueOutput == true;
			StyleSignature = settings.StyleSignature or Pipeline.DefaultSettings.StyleSignature;
			StyleProfile = settings.StyleProfile;
			OutputPaddingRatio = normalizePaddingRatio(settings.OutputPaddingRatio);
			parser = Parser:new({
				LuaVersion = luaVersion;
			});
		unparser = Unparser:new({
			LuaVersion = luaVersion;
			PrettyPrint = prettyPrint;
			Highlight = settings.Highlight;
		});
		namegenerator = Pipeline.NameGenerators.MangledShuffled;
		conventions = conventions;
		steps = {};
	}

	setmetatable(pipeline, self);
	self.__index = self;

	return pipeline;
end

function Pipeline:applyProfile(profileName)
	local profile = Pipeline.Profiles[profileName];
	if not profile then
		logger:error(string.format("Profile \"%s\" was not found!", tostring(profileName)));
	end

	if profile.LuaVersion then
		self.LuaVersion = profile.LuaVersion;
	end
	if profile.UniqueOutput ~= nil then
		self.UniqueOutput = profile.UniqueOutput == true;
	end
	if profile.OutputPaddingRatio ~= nil then
		self.OutputPaddingRatio = normalizePaddingRatio(profile.OutputPaddingRatio);
	end

	self:resetSteps();
	local steps = profile.Steps or {};
	for _, step in ipairs(steps) do
		local constructor = self.Steps[step.Name];
		if constructor then
			self:addStep(constructor:new(step.Settings or {}));
		else
			logger:warn(string.format("Profile step \"%s\" not available in this build, skipping.", step.Name));
		end
	end
end

function Pipeline:fromConfig(config)
	config = config or {};
	local pipeline = Pipeline:new({
		LuaVersion = config.LuaVersion or LuaVersion.Lua51;
		PrettyPrint = config.PrettyPrint or false;
		VarNamePrefix = config.VarNamePrefix or "";
		Seed = config.Seed or 0;
		UniqueOutput = config.UniqueOutput == true;
		StyleSignature = config.StyleSignature or Pipeline.DefaultSettings.StyleSignature;
		StyleProfile = config.StyleProfile;
		OutputPaddingRatio = config.OutputPaddingRatio;
	});

	pipeline:setNameGenerator(config.NameGenerator or "MangledShuffled")

	if type(config.Profile) == "string" and config.Profile ~= "" then
		pipeline:applyProfile(config.Profile);
	end

	-- Add all Steps defined in Config
	local steps = config.Steps or {};
	for i, step in ipairs(steps) do
		if type(step.Name) ~= "string" then
			logger:error("Step.Name must be a String");
		end
		local constructor = pipeline.Steps[step.Name];
		if not constructor then
			logger:error(string.format("The Step \"%s\" was not found!", step.Name));
		end
		pipeline:addStep(constructor:new(step.Settings or {}));
	end

	return pipeline;
end

function Pipeline:addStep(step)
	table.insert(self.steps, step);
end

function Pipeline:resetSteps(_)
	self.steps = {};
end

function Pipeline:getSteps()
	return self.steps;
end

function Pipeline:setOption(name, _)
	assert(false, "TODO");
	if(Pipeline.DefaultSettings[name] ~= nil) then

	else
		logger:error(string.format("\"%s\" is not a valid setting"));
	end
end

function Pipeline:setLuaVersion(luaVersion)
	local conventions = Enums.Conventions[luaVersion];
	if(not conventions) then
		logger:error("The Lua Version \"" .. luaVersion
			.. "\" is not recognized by the Tokenizer! Please use one of the following: \"" .. table.concat(util.keys(Enums.Conventions), "\",\"") .. "\"");
	end

	self.parser = Parser:new({
		luaVersion = luaVersion;
	});
	self.unparser = Unparser:new({
		luaVersion = luaVersion;
	});
	self.conventions = conventions;
end

function Pipeline:getLuaVersion()
	return self.luaVersion;
end

function Pipeline:setNameGenerator(nameGenerator)
	if(type(nameGenerator) == "string") then
		nameGenerator = Pipeline.NameGenerators[nameGenerator];
	end

	if(type(nameGenerator) == "function" or type(nameGenerator) == "table") then
		self.namegenerator = nameGenerator;
		return;
	else
		logger:error("The Argument to Pipeline:setNameGenerator must be a valid NameGenerator function or function name e.g: \"mangled\"")
	end
end

function Pipeline:apply(code, filename)
	local startTime = gettime();
	filename = filename or "Anonymous Script";
	logger:info(string.format("Applying Obfuscation Pipeline to %s ...", filename));

	-- Seed the Random Generator
	local seed;
	if(self.Seed > 0) then
		seed = normalizeSeed(self.Seed);
		math.randomseed(seed);
	else
		seed = normalizeSeed(generateSecureSeed());
		math.randomseed(seed);
	end

	logger:info("Parsing ...");
	local parserStartTime = gettime();

	local sourceLen = string.len(code);
	local ast = self.parser:parse(code);

	local parserTimeDiff = gettime() - parserStartTime;
	logger:info(string.format("Parsing Done in %.2f seconds", parserTimeDiff));

	-- User Defined Steps
	for i, step in ipairs(self.steps) do
		local stepStartTime = gettime();
		logger:info(string.format("Applying Step \"%s\" ...", step.Name or "Unnamed"));
		local newAst = step:apply(ast, self);
		if type(newAst) == "table" then
			ast = newAst;
		end
		logger:info(string.format("Step \"%s\" Done in %.2f seconds", step.Name or "Unnamed", gettime() - stepStartTime));
	end

	-- Rename Variables Step
	if type(self.StyleProfile) == "table" and type(self.StyleProfile.VarNamePrefix) == "string" then
		if self.VarNamePrefix == nil or self.VarNamePrefix == "" then
			self.VarNamePrefix = self.StyleProfile.VarNamePrefix;
		end
	end

	if self.UniqueOutput and (self.VarNamePrefix == nil or self.VarNamePrefix == "") then
		self.VarNamePrefix = buildUniqueVarPrefix(seed, sourceLen, self.StyleSignature);
	end
	self:renameVariables(ast);

	code = self:unparse(ast);
	if self.OutputPaddingRatio then
		code = padOutputToRatio(code, sourceLen, self.OutputPaddingRatio);
	end

	local timeDiff = gettime() - startTime;
	logger:info(string.format("Obfuscation Done in %.2f seconds", timeDiff));

	logger:info(string.format("Generated Code size is %.2f%% of the Source Code size", (string.len(code) / sourceLen)*100))

	return code;
end

function Pipeline:unparse(ast)
	local startTime = gettime();
	logger:info("Generating Code ...");

	local unparsed = self.unparser:unparse(ast);

	local timeDiff = gettime() - startTime;
	logger:info(string.format("Code Generation Done in %.2f seconds", timeDiff));

	return unparsed;
end

function Pipeline:renameVariables(ast)
	local startTime = gettime();
	logger:info("Renaming Variables ...");


	local generatorFunction = self.namegenerator or Pipeline.NameGenerators.mangled;
	if(type(generatorFunction) == "table") then
		if (type(generatorFunction.prepare) == "function") then
			generatorFunction.prepare(ast);
		end
		generatorFunction = generatorFunction.generateName;
	end

	if not self.unparser:isValidIdentifier(self.VarNamePrefix) and #self.VarNamePrefix ~= 0 then
		logger:error(string.format("The Prefix \"%s\" is not a valid Identifier in %s", self.VarNamePrefix, self.LuaVersion));
	end

	local globalScope = ast.globalScope;
	globalScope:renameVariables({
		Keywords = self.conventions.Keywords;
		generateName = generatorFunction;
		prefix = self.VarNamePrefix;
	});

	local timeDiff = gettime() - startTime;
	logger:info(string.format("Renaming Done in %.2f seconds", timeDiff));
end

return Pipeline;
