-- Connected Discord-GitHub | Discord: e1dev. (1564437886005415968) | Roblox: eldiavlo878 (5137913260)
--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

-- Type definitions enforce strict memory layout for hook states and configuration parameters
export type GrappleSide = "Left" | "Right"

export type HookState = {
	Active: boolean,
	AnchorPosition: Vector3,
	AnchorPart: BasePart?,
	AttachmentOrigin: Attachment,
	AttachmentTarget: Attachment?,
	CableBeam: Beam?,
	RopeLength: number,
}

export type ODMConfig = {
	MaxRayDistance: number,
	BasePullSpeed: number,
	BoostPullSpeed: number,
	StrafeForceMultiplier: number,
	VerticalLiftBias: number,
	MaxGasCapacity: number,
	GasDrainRate: number,
	GasRegenRate: number,
	BaseFOV: number,
	GrappleFOV: number,
	BoostFOV: number,
	MaxCameraRoll: number,
	Responsiveness: number,
}

local DEFAULT_CONFIG: ODMConfig = {
	MaxRayDistance = 420,
	BasePullSpeed = 88,
	BoostPullSpeed = 142,
	StrafeForceMultiplier = 46,
	VerticalLiftBias = 14,
	MaxGasCapacity = 100,
	GasDrainRate = 22,
	GasRegenRate = 15,
	BaseFOV = 70,
	GrappleFOV = 82,
	BoostFOV = 94,
	MaxCameraRoll = math.rad(11),
	Responsiveness = 12,
}

local ODMController = {}
ODMController.__index = ODMController

export type ODMControllerInstance = typeof(setmetatable(
	{} :: {
		Player: Player,
		Character: Model,
		Humanoid: Humanoid,
		RootPart: BasePart,
		Camera: Camera,
		Config: ODMConfig,
		GasAmount: number,
		IsBoosting: boolean,
		StrafeInput: number,
		CurrentVelocity: Vector3,
		CurrentRoll: number,
		RootAttachment: Attachment,
		LinearVelocity: LinearVelocity,
		AlignOrientation: AlignOrientation,
		BoostTrail: Trail,
		RaycastParams: RaycastParams,
		Hooks: { [GrappleSide]: HookState },
		Connections: { RBXScriptConnection },
	},
	ODMController
))

-- Helper function to create invisible, non-colliding attachments relative to the character rig
local function createRigAttachment(parent: Instance, name: string, offset: Vector3): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = offset
	attachment.Parent = parent
	return attachment
end

-- Constructs the visual cable using a camera-facing Beam between waist rig and world anchor
local function buildCableBeam(origin: Attachment, target: Attachment, parent: Instance): Beam
	local beam = Instance.new("Beam")
	beam.Name = "ODMCable"
	beam.Attachment0 = origin
	beam.Attachment1 = target
	beam.Width0 = 0.065
	beam.Width1 = 0.065
	beam.Color = ColorSequence.new(Color3.fromRGB(28, 28, 32))
	beam.LightEmission = 0
	beam.LightInfluence = 1
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Parent = parent
	return beam
end

-- Initializes physics constraints and input listeners per character spawn
function ODMController.new(player: Player, character: Model, customConfig: ODMConfig?): ODMControllerInstance
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	local camera = Workspace.CurrentCamera :: Camera
	local config = customConfig or DEFAULT_CONFIG

	local rootAttachment = createRigAttachment(rootPart, "ODMRootAttachment", Vector3.zero)
	local leftWaist = createRigAttachment(rootPart, "LeftWaistAttachment", Vector3.new(-1.05, -0.75, 0))
	local rightWaist = createRigAttachment(rootPart, "RightWaistAttachment", Vector3.new(1.05, -0.75, 0))
	local trailTop = createRigAttachment(rootPart, "GasTrailTop", Vector3.new(0, 0.4, 0.6))
	local trailBottom = createRigAttachment(rootPart, "GasTrailBottom", Vector3.new(0, -0.8, 0.6))

	-- LinearVelocity applies direct vector velocity without fighting default humanoid friction
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "ODMLinearVelocity"
	linearVelocity.Attachment0 = rootAttachment
	linearVelocity.MaxForce = math.huge
	linearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Enabled = false
	linearVelocity.Parent = rootPart

	-- AlignOrientation aligns the character smoothly along the active travel vector
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "ODMAlignOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = rootAttachment
	alignOrientation.Responsiveness = 18
	alignOrientation.MaxTorque = 100000
	alignOrientation.Enabled = false
	alignOrientation.Parent = rootPart

	local boostTrail = Instance.new("Trail")
	boostTrail.Name = "ODMGasTrail"
	boostTrail.Attachment0 = trailTop
	boostTrail.Attachment1 = trailBottom
	boostTrail.Lifetime = 0.28
	boostTrail.MinLength = 0.1
	boostTrail.FaceCamera = true
	boostTrail.LightEmission = 0
	boostTrail.Color = ColorSequence.new(Color3.fromRGB(225, 230, 235))
	boostTrail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	boostTrail.Enabled = false
	boostTrail.Parent = rootPart

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	rayParams.IgnoreWater = true

	local self = setmetatable({
		Player = player,
		Character = character,
		Humanoid = humanoid,
		RootPart = rootPart,
		Camera = camera,
		Config = config,
		GasAmount = config.MaxGasCapacity,
		IsBoosting = false,
		StrafeInput = 0,
		CurrentVelocity = Vector3.zero,
		CurrentRoll = 0,
		RootAttachment = rootAttachment,
		LinearVelocity = linearVelocity,
		AlignOrientation = alignOrientation,
		BoostTrail = boostTrail,
		RaycastParams = rayParams,
		Hooks = {
			Left = {
				Active = false,
				AnchorPosition = Vector3.zero,
				AnchorPart = nil,
				AttachmentOrigin = leftWaist,
				AttachmentTarget = nil,
				CableBeam = nil,
				RopeLength = 0,
			},
			Right = {
				Active = false,
				AnchorPosition = Vector3.zero,
				AnchorPart = nil,
				AttachmentOrigin = rightWaist,
				AttachmentTarget = nil,
				CableBeam = nil,
				RopeLength = 0,
			},
		},
		Connections = {},
	}, ODMController)

	self:BindInputs()
	return self
end

-- Projects screen mouse coordinates into a 3D world raycast to validate grapple targets
function ODMController.CastHookRay(self: ODMControllerInstance): RaycastResult?
	local mousePos = UserInputService:GetMouseLocation()
	local viewportRay = self.Camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	local direction = viewportRay.Direction * self.Config.MaxRayDistance
	return Workspace:Raycast(viewportRay.Origin, direction, self.RaycastParams)
end

-- Attaches a grapple hook to the hit surface using local-space coordinates to support moving parts
function ODMController.DeployHook(self: ODMControllerInstance, side: GrappleSide)
	if self.GasAmount <= 0 or self.Humanoid.Health <= 0 then
		return
	end

	self:RetractHook(side)
	local hitResult = self:CastHookRay()
	if not hitResult or not hitResult.Instance then
		return
	end

	local hitPart = hitResult.Instance :: BasePart
	local hitPosition = hitResult.Position

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "ODMAnchor_" .. side
	targetAttachment.WorldPosition = hitPosition
	targetAttachment.Parent = hitPart

	local hookData = self.Hooks[side]
	local beam = buildCableBeam(hookData.AttachmentOrigin, targetAttachment, self.RootPart)

	hookData.Active = true
	hookData.AnchorPosition = hitPosition
	hookData.AnchorPart = hitPart
	hookData.AttachmentTarget = targetAttachment
	hookData.CableBeam = beam
	hookData.RopeLength = (hitPosition - self.RootPart.Position).Magnitude
end

-- Cleans up target attachments and disables constraints if both hooks are disengaged
function ODMController.RetractHook(self: ODMControllerInstance, side: GrappleSide)
	local hookData = self.Hooks[side]
	hookData.Active = false
	hookData.AnchorPart = nil

	if hookData.CableBeam then
		hookData.CableBeam:Destroy()
		hookData.CableBeam = nil
	end

	if hookData.AttachmentTarget then
		hookData.AttachmentTarget:Destroy()
		hookData.AttachmentTarget = nil
	end

	if not self.Hooks.Left.Active and not self.Hooks.Right.Active then
		self.LinearVelocity.Enabled = false
		self.AlignOrientation.Enabled = false
		self.BoostTrail.Enabled = false
		self.Humanoid.PlatformStand = false
	end
end

-- Computes the combined focal point when single or dual hooks are anchored
function ODMController.GetTargetFocusPoint(self: ODMControllerInstance): (Vector3?, number)
	local leftHook = self.Hooks.Left
	local rightHook = self.Hooks.Right
	local activeCount = 0
	local accumulatedPos = Vector3.zero

	if leftHook.Active and leftHook.AttachmentTarget then
		leftHook.AnchorPosition = leftHook.AttachmentTarget.WorldPosition
		accumulatedPos += leftHook.AnchorPosition
		activeCount += 1
	end

	if rightHook.Active and rightHook.AttachmentTarget then
		rightHook.AnchorPosition = rightHook.AttachmentTarget.WorldPosition
		accumulatedPos += rightHook.AnchorPosition
		activeCount += 1
	end

	if activeCount == 0 then
		return nil, 0
	end

	return accumulatedPos / activeCount, activeCount
end

-- Calculates tangential orbital velocity and tension pull per frame
function ODMController.StepPhysics(self: ODMControllerInstance, deltaTime: number)
	local focusPoint, activeHooks = self:GetTargetFocusPoint()

	local aDown = UserInputService:IsKeyDown(Enum.KeyCode.A)
	local dDown = UserInputService:IsKeyDown(Enum.KeyCode.D)
	self.StrafeInput = (dDown and 1 or 0) - (aDown and 1 or 0)

	if not focusPoint or activeHooks == 0 or self.GasAmount <= 0 then
		if activeHooks > 0 and self.GasAmount <= 0 then
			self:RetractHook("Left")
			self:RetractHook("Right")
		end
		self.GasAmount = math.min(self.Config.MaxGasCapacity, self.GasAmount + self.Config.GasRegenRate * deltaTime)
		self:UpdateCameraEffects(deltaTime, false)
		return
	end

	local drainMultiplier = self.IsBoosting and 1.85 or 1.0
	self.GasAmount = math.max(0, self.GasAmount - (self.Config.GasDrainRate * drainMultiplier * deltaTime))

	local rootPos = self.RootPart.Position
	local displacement = focusPoint - rootPos
	local distance = displacement.Magnitude
	local pullDir = distance > 0.1 and displacement.Unit or self.Camera.CFrame.LookVector

	-- Compute perpendicular orbital vector using cross product against world up axis
	local rightTangent = pullDir:Cross(Vector3.yAxis)
	if rightTangent.Magnitude > 0.01 then
		rightTangent = rightTangent.Unit
	else
		rightTangent = self.Camera.CFrame.RightVector
	end

	local targetSpeed = self.IsBoosting and self.Config.BoostPullSpeed or self.Config.BasePullSpeed
	local dualHookMultiplier = activeHooks == 2 and 1.15 or 1.0
	local primaryVelocity = pullDir * (targetSpeed * dualHookMultiplier)
	local orbitalVelocity = rightTangent * (self.StrafeInput * self.Config.StrafeForceMultiplier)
	local liftVector = Vector3.new(0, self.Config.VerticalLiftBias, 0)

	local desiredVelocity = primaryVelocity + orbitalVelocity + liftVector
	local alpha = math.clamp(deltaTime * self.Config.Responsiveness, 0, 1)
	self.CurrentVelocity = self.CurrentVelocity:Lerp(desiredVelocity, alpha)

	self.LinearVelocity.VectorVelocity = self.CurrentVelocity
	self.LinearVelocity.Enabled = true
	self.AlignOrientation.Enabled = true
	self.BoostTrail.Enabled = self.IsBoosting

	if self.CurrentVelocity.Magnitude > 2 then
		local lookTarget = rootPos + Vector3.new(self.CurrentVelocity.X, self.CurrentVelocity.Y * 0.35, self.CurrentVelocity.Z)
		self.AlignOrientation.CFrame = CFrame.lookAt(rootPos, lookTarget)
	end

	self:UpdateCameraEffects(deltaTime, true)
end

-- Interpolates camera FieldOfView and banking roll angle based on lateral strafe momentum
function ODMController.UpdateCameraEffects(self: ODMControllerInstance, deltaTime: number, isGrappling: boolean)
	local targetFOV = self.Config.BaseFOV
	local targetRoll = 0

	if isGrappling then
		targetFOV = self.IsBoosting and self.Config.BoostFOV or self.Config.GrappleFOV
		targetRoll = -self.StrafeInput * self.Config.MaxCameraRoll
	end

	local lerpAlpha = math.clamp(deltaTime * 8, 0, 1)
	self.Camera.FieldOfView = self.Camera.FieldOfView + (targetFOV - self.Camera.FieldOfView) * lerpAlpha
	self.CurrentRoll = self.CurrentRoll + (targetRoll - self.CurrentRoll) * lerpAlpha

	if math.abs(self.CurrentRoll) > 0.001 then
		self.Camera.CFrame = self.Camera.CFrame * CFrame.Angles(0, 0, self.CurrentRoll)
	end
end

-- Registers input connections and binds physics stepping to RenderStepped
function ODMController.BindInputs(self: ODMControllerInstance)
	local inputBeganConn = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Q then
			self:DeployHook("Left")
		elseif input.KeyCode == Enum.KeyCode.E then
			self:DeployHook("Right")
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			self.IsBoosting = true
		end
	end)

	local inputEndedConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Q then
			self:RetractHook("Left")
		elseif input.KeyCode == Enum.KeyCode.E then
			self:RetractHook("Right")
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			self.IsBoosting = false
		end
	end)

	local renderConn = RunService.RenderStepped:Connect(function(deltaTime: number)
		self:StepPhysics(deltaTime)
	end)

	local diedConn = self.Humanoid.Died:Connect(function()
		self:Destroy()
	end)

	table.insert(self.Connections, inputBeganConn)
	table.insert(self.Connections, inputEndedConn)
	table.insert(self.Connections, renderConn)
	table.insert(self.Connections, diedConn)
end

-- Disconnects events and removes instances on character death or cleanup
function ODMController.Destroy(self: ODMControllerInstance)
	self:RetractHook("Left")
	self:RetractHook("Right")
	for _, connection in ipairs(self.Connections) do
		connection:Disconnect()
	end
	table.clear(self.Connections)
end

local localPlayer = Players.LocalPlayer
local activeCharacter = localPlayer.Character or localPlayer.CharacterAdded:Wait()
ODMController.new(localPlayer, activeCharacter)
