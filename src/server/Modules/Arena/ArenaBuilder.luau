local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local HexGrid = require(ReplicatedStorage.Modules.HexGrid)

local ArenaBuilder = {}

local MARGIN_CAMERA = 80
local MARGIN_BACK = 48
local MARGIN_SIDE = 62
local FLOOR_THICKNESS = 2
local TRIM_OUTSET = 6
local TRIM_DROP = 3

local function MakePart(props, parent)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false

	for key, value in pairs(props) do
		part[key] = value
	end

	part.Parent = parent
	return part
end

local function BuildLights(folder, theme, bounds)
	for index, spec in ipairs(theme.lights or {}) do
		local offset = spec.offset or Vector3.new()
		local anchor = MakePart({
			Name = "ArenaLight" .. index,
			Size = Vector3.new(0.4, 0.4, 0.4),
			CFrame = CFrame.new(bounds.boardCenterX + offset.X, bounds.floorY + spec.height, bounds.boardCenterZ + offset.Z),
			Transparency = 1,
		}, folder)

		local light = Instance.new(spec.class)
		light.Color = spec.color
		light.Brightness = spec.brightness
		light.Range = spec.range
		light.Parent = anchor
	end
end

function ArenaBuilder.Build(theme, origin, folderName)
	local folder = Instance.new("Folder")
	folder.Name = folderName
	folder:SetAttribute("Theme", theme.id)

	local boardMin, boardMax = HexGrid.GetBoardBounds(origin)
	local floorY = origin.Y - 0.5

	local bounds = {
		origin = origin,
		boardMin = boardMin,
		boardMax = boardMax,
		floorY = floorY,
		minX = boardMin.X - MARGIN_BACK,
		maxX = boardMax.X + MARGIN_CAMERA,
		minZ = boardMin.Z - MARGIN_SIDE,
		maxZ = boardMax.Z + MARGIN_SIDE,
	}
	bounds.centerX = (bounds.minX + bounds.maxX) / 2
	bounds.centerZ = (bounds.minZ + bounds.maxZ) / 2

	bounds.boardCenterX = (boardMin.X + boardMax.X) / 2
	bounds.boardCenterZ = (boardMin.Z + boardMax.Z) / 2

	local width = bounds.maxX - bounds.minX
	local depth = bounds.maxZ - bounds.minZ

	MakePart({
		Name = "Floor",
		Size = Vector3.new(width, FLOOR_THICKNESS, depth),
		CFrame = CFrame.new(bounds.centerX, floorY - FLOOR_THICKNESS / 2, bounds.centerZ),
		Color = theme.ground.color,
		Material = theme.ground.material,
		CanCollide = true,
	}, folder)

	MakePart({
		Name = "FloorTrim",
		Size = Vector3.new(width + TRIM_OUTSET, FLOOR_THICKNESS + TRIM_DROP, depth + TRIM_OUTSET),
		CFrame = CFrame.new(bounds.centerX, floorY - FLOOR_THICKNESS - (FLOOR_THICKNESS + TRIM_DROP) / 2, bounds.centerZ),
		Color = theme.trim.color,
		Material = theme.trim.material,
	}, folder)

	BuildLights(folder, theme, bounds)

	folder.Parent = Workspace
	return folder
end

function ArenaBuilder.CloneMaster(master, theme, origin, folderName)
	local center = HexGrid.GetBoardCenter(origin)
	local floorY = origin.Y - 0.5

	local folder = master:Clone()
	folder.Name = folderName
	folder:SetAttribute("Theme", theme.id)
	folder:SetAttribute("MasterName", master.Name)

	local reference = folder:FindFirstChild("Floor", true)
	local delta

	if reference and reference:IsA("BasePart") then
		delta = Vector3.new(
			center.X - reference.Position.X,
			floorY - (reference.Position.Y + reference.Size.Y / 2),
			center.Z - reference.Position.Z
		)
	elseif folder:IsA("PVInstance") then
		local pivot = folder:GetPivot()
		delta = Vector3.new(center.X - pivot.X, floorY - pivot.Y, center.Z - pivot.Z)
		warn(("ArenaBuilder: %s nao tem peca 'Floor' — alinhado pelo pivot do Model."):format(master.Name))
	else
		warn(("ArenaBuilder: %s nao tem peca 'Floor' e nao e Model — nao da pra alinhar."):format(master.Name))
		folder:Destroy()
		return nil
	end

	if folder:IsA("PVInstance") then
		folder:PivotTo(folder:GetPivot() + delta)
	else
		for _, descendant in ipairs(folder:GetDescendants()) do
			if descendant:IsA("PVInstance") and not descendant:FindFirstAncestorWhichIsA("Model") then
				descendant:PivotTo(descendant:GetPivot() + delta)
			end
		end
	end

	BuildLights(folder, theme, {
		boardCenterX = center.X,
		boardCenterZ = center.Z,
		floorY = floorY,
	})

	folder.Parent = Workspace
	return folder
end

return ArenaBuilder
