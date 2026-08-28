--!strict
-- LightingService — the Essential UI Pack's lighting rig, in code, set to NIGHT.
--
-- The pack ships these as instances in its place file; keeping them here means
-- the whole look is version-controlled and applies to a fresh place with no
-- manual import. The pack's effects are kept (its 3000-star Sky is the whole
-- point at night); the scalars are shifted to the night rig the Map Design
-- Contract in DESIGN.md calls for: ClockTime 0, low brightness, a deep
-- blue-purple ambient. Bases read as bright interiors because of the Neon
-- ceiling panels and PointLights PlotService builds into their roofs.

local Lighting = game:GetService("Lighting")

local LightingService = {}

local SCALARS = {
	-- Midnight. The moon is up, so Brightness is moonlight, not sunlight.
	ClockTime = 0,
	-- Night SKY, but a brightly-lit world: the reference reads as vivid green
	-- grass under stars, not a murky midnight.
	Brightness = 2.6,
	-- Deep blue-purple fill so unlit geometry reads as night, not as black.
	Ambient = Color3.fromRGB(120, 116, 148),
	OutdoorAmbient = Color3.fromRGB(132, 128, 162),
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 1,
	-- A touch of exposure keeps the arena legible without washing out the sky.
	ExposureCompensation = 0,
	GlobalShadows = true,
	FogEnd = 100000,
}

local EFFECTS = {
	{
		name = "Sky",
		className = "Sky",
		props = {
			StarCount = 3000,
			SunAngularSize = 11,
			MoonAngularSize = 11,
			CelestialBodiesShown = true,
		},
	},
	{
		-- Thinner and bluer than the pack's daytime haze: at ClockTime 0 the
		-- original grey density muddies the stars and the far wall.
		name = "Atmosphere",
		className = "Atmosphere",
		props = {
			Density = 0.18,
			Offset = 0.1,
			Color = Color3.fromRGB(74, 80, 122),
			Decay = Color3.fromRGB(44, 46, 84),
			Glare = 0,
			Haze = 0,
		},
	},
	{
		-- Threshold drops so the Neon pads and base ceiling panels glow; the
		-- pack's 2 only ever blooms daylight.
		name = "Bloom",
		className = "BloomEffect",
		props = { Intensity = 0.9, Size = 20, Threshold = 1.2, Enabled = true },
	},
	{
		name = "SunRays",
		className = "SunRaysEffect",
		props = { Intensity = 0.01, Spread = 0.1, Enabled = true },
	},
	{
		name = "DepthOfField",
		className = "DepthOfFieldEffect",
		props = {
			FarIntensity = 0.1,
			FocusDistance = 0.05,
			InFocusRadius = 30,
			NearIntensity = 0.75,
			Enabled = false, -- off in the pack; kept so it can be toggled
		},
	},
}

-- Idempotent: replaces any effect it owns, so a rerun never stacks duplicates.
function LightingService.Apply()
	pcall(function()
		Lighting.Technology = Enum.Technology.ShadowMap
	end)
	for name, value in SCALARS do
		pcall(function()
			(Lighting :: any)[name] = value
		end)
	end

	for _, spec in EFFECTS do
		pcall(function()
			local existing = Lighting:FindFirstChild(spec.name)
			if existing then
				existing:Destroy()
			end
			local effect = Instance.new(spec.className)
			effect.Name = spec.name
			for prop, value in spec.props do
				(effect :: any)[prop] = value
			end
			effect.Parent = Lighting
		end)
	end
end

return LightingService
