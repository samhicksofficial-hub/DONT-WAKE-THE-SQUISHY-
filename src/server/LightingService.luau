--!strict
-- LightingService — the world's lighting rig, in code.
--
-- The look is COZY: the soft, milky, evenly-lit pastel world of ASMR obby
-- games. That means the opposite of a dramatic rig — no harsh sun angle, no
-- deep shadows, no dark corners. Bright flat fill, a warm pink haze on the
-- horizon so the world fades into candy floss rather than into a hard skyline,
-- and just enough bloom to make the icing-white surfaces glow softly.
--
-- Keeping this in code (rather than as instances in the place file) means the
-- whole look is version-controlled and applies to a fresh place with no import.

local Lighting = game:GetService("Lighting")

local LightingService = {}

local SCALARS = {
	-- Early afternoon: the sun is high, so nothing casts a long hard shadow.
	ClockTime = 14,
	GeographicLatitude = 0,
	-- Bright, but the lift comes mostly from Ambient — a high Brightness alone
	-- would carve out exactly the harsh shadows this look avoids.
	Brightness = 1.6,
	-- Very high ambient fill is the whole trick: it flattens shadows into soft
	-- pastel shading, which is what makes these worlds read as plush.
	Ambient = Color3.fromRGB(146, 132, 146),
	OutdoorAmbient = Color3.fromRGB(162, 148, 162),
	EnvironmentDiffuseScale = 1,
	EnvironmentSpecularScale = 0.4, -- matte, not glossy
	-- A touch of exposure makes the creams read milky rather than grey.
	ExposureCompensation = 0,
	-- Shadows stay on, but ambient keeps them gentle.
	GlobalShadows = true,
	FogEnd = 100000,
}

local EFFECTS = {
	{
		-- No stars: this is a daytime candy world. The sky is left to the
		-- default gradient and then tinted pink by the Atmosphere below, which
		-- needs no texture assets.
		name = "Sky",
		className = "Sky",
		props = {
			StarCount = 0,
			SunAngularSize = 18,
			MoonAngularSize = 11,
			CelestialBodiesShown = false,
		},
	},
	{
		-- The pink haze. Dense and warm so distance melts into candy floss and
		-- the far walls never read as a hard dark edge.
		name = "Atmosphere",
		className = "Atmosphere",
		props = {
			-- Light touch: enough pink in the distance to feel warm, nowhere near
			-- enough to fog the arena out. Density and Haze both bite hard here.
			Density = 0.12,
			Offset = 0.2,
			Color = Color3.fromRGB(255, 226, 238),
			Decay = Color3.fromRGB(246, 198, 220),
			Glare = 0.05,
			Haze = 0.3,
		},
	},
	{
		-- Soft glow on the icing-white and neon surfaces. A low threshold makes
		-- the pale palette bloom gently; a high intensity would blow it out.
		name = "Bloom",
		className = "BloomEffect",
		props = { Intensity = 0.25, Size = 28, Threshold = 1.9, Enabled = true },
	},
	{
		-- Just a whisper — enough to catch the sun, not enough to streak.
		name = "SunRays",
		className = "SunRaysEffect",
		props = { Intensity = 0.02, Spread = 0.3, Enabled = true },
	},
	{
		-- Kept (and off) so the rig still owns the instance and a rerun cannot
		-- leave a stale one behind.
		name = "DepthOfField",
		className = "DepthOfFieldEffect",
		props = {
			FarIntensity = 0.1,
			FocusDistance = 0.05,
			InFocusRadius = 30,
			NearIntensity = 0.75,
			Enabled = false,
		},
	},
	{
		-- The colour grade that ties it together: a gentle lift toward warm
		-- pink with the contrast pulled down, so nothing in the world is ever
		-- truly dark. This is what sells "cozy" more than any single colour.
		name = "CozyGrade",
		className = "ColorCorrectionEffect",
		props = {
			Brightness = 0.02,
			Contrast = -0.12,
			Saturation = 0.08,
			TintColor = Color3.fromRGB(255, 246, 250),
			Enabled = true,
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
