local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")

local MatchManager = require(ServerScriptService.Modules.MatchManager)

local SeatBuilder = {}

local MODEL_NAMES = { Seat = true, Bench = true }
local SURFACE_NAME = "Top"
local SEAT_NAME = "LobbySeat"

local SEAT_THICKNESS = 0.2
local SEAT_INSET = 0.85
local SEAT_SPAN = 3.6
local PROMPT_DISTANCE = 9

local function BuildSlot(model, surface, index, slots)
	local span = surface.Size.X / slots
	local offset = (index - (slots + 1) / 2) * span

	local seat = Instance.new("Seat")
	seat.Name = SEAT_NAME .. index
	seat.Size = Vector3.new(span * SEAT_INSET, SEAT_THICKNESS, surface.Size.Z * SEAT_INSET)
	seat.CFrame = surface.CFrame
		* CFrame.new(offset, (surface.Size.Y + SEAT_THICKNESS) / 2, 0)
	seat.Anchored = true
	seat.Transparency = 1
	seat.CastShadow = false
	seat.CanCollide = false
	seat.CanTouch = false
	seat.Parent = model

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SitPrompt"
	prompt.ActionText = "Sentar"
	prompt.ObjectText = "Banco"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		prompt.Enabled = seat.Occupant == nil
	end)

	prompt.Triggered:Connect(function(player)
		if MatchManager.IsInMatch(player) then return end
		if seat.Occupant then return end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		seat:Sit(humanoid)
	end)

	return seat
end

local function BuildOne(model)
	local surface = model:FindFirstChild(SURFACE_NAME)
	if not (surface and surface:IsA("BasePart")) then return 0 end
	if model:FindFirstChild(SEAT_NAME .. "1") then return 0 end

	local slots = math.max(1, math.floor(surface.Size.X / SEAT_SPAN))
	for index = 1, slots do
		BuildSlot(model, surface, index, slots)
	end

	return slots
end

function SeatBuilder.Build()
	local built = 0

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant:IsA("Model") and MODEL_NAMES[descendant.Name] then
			built += BuildOne(descendant)
		end
	end

	return built
end

return SeatBuilder
