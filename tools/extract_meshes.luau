--!strict
-- Extract the imported squishy mesh templates from the Squishy Clicker place
-- file into a single .rbxm the other game can load with game:GetObjects().

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local PLACE = "C:/Users/crocs/OneDrive/Documents/GitHub/Squishy-Clicker-Roblox/squishy-clicker/place/SquishyLauncher.rbxl"
local OUT = "C:/Users/crocs/OneDrive/Documents/GitHub/DONT WAKE THE SQUISHY!/Assets/SquishyMeshes.rbxm"

-- Template names from the clicker's MESH_SHAPES table.
local TEMPLATES = {
	"OpalDumpling", "BananaSquishy", "ButterSquishy", "RainbowButter",
	"GlowDonut", "SquishCheese", "CoconutBall", "GlitterBaby", "SparkleDrop",
	"SquishyBrain", "BlobfishSquishy", "DoughCloud", "StrawberrySquishy",
	"PugSquishy", "IceCubeSquishy",
}

local game = roblox.deserializePlace(fs.readFile(PLACE))

local wanted: { [string]: boolean } = {}
for _, name in TEMPLATES do
	wanted[name] = true
end

-- Search the whole place; prefer matches inside ReplicatedStorage.
local found: { [string]: any } = {}
local function scan(inst: any, depth: number)
	if depth > 12 then
		return
	end
	for _, child in inst:GetChildren() do
		if wanted[child.Name] and not found[child.Name] then
			found[child.Name] = child
		end
		scan(child, depth + 1)
	end
end
scan(game:GetService("ReplicatedStorage"), 0)
scan(game:GetService("Workspace"), 0)
scan(game:GetService("ServerStorage"), 0)

local folder = roblox.Instance.new("Folder")
folder.Name = "SquishyMeshes"
local gotten, missing = {}, {}
for _, name in TEMPLATES do
	local inst = found[name]
	if inst then
		inst.Parent = folder
		table.insert(gotten, name)
	else
		table.insert(missing, name)
	end
end

fs.writeFile(OUT, roblox.serializeModel({ folder }))
print("extracted:", table.concat(gotten, ", "))
print("missing:", #missing > 0 and table.concat(missing, ", ") or "(none)")
