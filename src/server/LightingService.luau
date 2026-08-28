--!strict
-- LightingService — the Essential UI Pack's lighting rig, in code.
--
-- The pack ships these as instances in its place file; keeping them here means
-- the whole look is version-controlled and applies to a fresh place with no
-- manual import. Values are copied verbatim from the pack.

local Lighting = game:GetService("Lighting")

local LightingService = {}

local SCALARS = {
	Ambient = Color3.fromRGB(70, 70, 70),
	OutdoorAmbient = Color3.fromRGB(70, 70, 70),
	Brightness = 3,
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 1,
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
		name = "Atmosphere",
		className = "Atmosphere",
		props = {
			Density = 0.3,
			Offset = 0.25,
			Color = Color3.fromRGB(199, 199, 199),
			Decay = Color3.fromRGB(106, 112, 125),
			Glare = 0,
			Haze = 0,
		},
	},
	{
		name = "Bloom",
		className = "BloomEffect",
		props = { Intensity = 1, Size = 24, Threshold = 2, Enabled = true },
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
