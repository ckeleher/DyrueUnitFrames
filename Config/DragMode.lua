-- Config/DragMode.lua
--
-- SPEC §FR-1.4 — the third way to position a frame.
--
-- Sliders, typed values and dragging all write to the SAME stored x/y. There
-- is one source of truth; drag mode is an input method, not a parallel layout
-- system. Drop a frame and its numbers in the options panel have already moved.
--
-- The draggable overlay is an ordinary insecure frame sitting on top of each
-- unit frame. It handles the mouse and the keyboard so that we never have to
-- attach input scripts to the protected button itself.

local ADDON, ns = ...
local L = ns.L
local Errors = ns.Errors
local Registry = ns.Registry
local Options = ns.Options

local DragMode = {}
ns.DragMode = DragMode

DragMode.active = false

local overlays = {}
local selected = nil
local gridFrame = nil
local gridPool = {}

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

--- Screen coordinates of a named point on a frame, in that frame's own units.
local function pointCoords(frame, point)
	local left, bottom = frame:GetLeft(), frame:GetBottom()
	if not left or not bottom then return nil end
	local width, height = frame:GetWidth(), frame:GetHeight()

	local x
	if point:find("LEFT") then x = left
	elseif point:find("RIGHT") then x = left + width
	else x = left + width / 2 end

	local y
	if point:find("BOTTOM") then y = bottom
	elseif point:find("TOP") then y = bottom + height
	else y = bottom + height / 2 end

	return x, y
end

local function snap(value, grid)
	if not grid or grid <= 0 then return value end
	return math.floor(value / grid + 0.5) * grid
end

--- Which anchor table does dragging this frame write to?
-- Party frames under group layout move the group, not themselves — and only
-- the first one, because the other three chain off it.
local function anchorTarget(frame)
	local unitKey = frame.unitKey
	if ns.PartyGroup:Owns(unitKey) then
		local def = Registry:Get(unitKey)
		if (def.groupIndex or 1) > 1 then
			return nil, L["This frame is positioned by the party group. Drag Party 1 to move all four, or detach it under its Layout tab."]
		end
		return ns:Profile().partyGroup.anchor, nil, true
	end
	local cfg = ns:UnitConfig(unitKey)
	return cfg and cfg.anchor
end

--- Convert the frame's current on-screen position into anchor offsets and
-- store them.
local function commit(frame)
	local anchor, refusal, isGroup = anchorTarget(frame)
	if not anchor then
		if refusal then Errors:Print(refusal) end
		ns.Anchoring:Apply(frame.unitKey)
		return
	end

	local relative, point, relativePoint = ns.Anchoring:Resolve(frame.unitKey)
	local fx, fy = pointCoords(frame, point)
	local rx, ry = pointCoords(relative, relativePoint)
	if not fx or not rx then return end

	local frameScale = frame:GetEffectiveScale()
	local relativeScale = relative:GetEffectiveScale()

	local x = (fx * frameScale - rx * relativeScale) / frameScale
	local y = (fy * frameScale - ry * relativeScale) / frameScale

	local general = ns:General()
	if general.gridSnap then
		x = snap(x, general.gridSize)
		y = snap(y, general.gridSize)
	end

	anchor.x = x
	anchor.y = y

	ns:BumpSerial()
	if isGroup then
		ns.PartyGroup:Apply()
	else
		ns.Anchoring:Apply(frame.unitKey)
	end
	Options:Notify()
end

local function nudge(frame, dx, dy)
	local anchor, refusal, isGroup = anchorTarget(frame)
	if not anchor then
		if refusal then Errors:Print(refusal) end
		return
	end
	anchor.x = (anchor.x or 0) + dx
	anchor.y = (anchor.y or 0) + dy
	ns:BumpSerial()
	if isGroup then
		ns.PartyGroup:Apply()
	else
		ns.Anchoring:Apply(frame.unitKey)
	end
	Options:Notify()
end

--------------------------------------------------------------------------------
-- Grid
--------------------------------------------------------------------------------

local MAX_GRID_LINES = 240

local function releaseGrid()
	for i = 1, #gridPool do gridPool[i]:Hide() end
end

local function acquireLine(index)
	local line = gridPool[index]
	if not line then
		line = gridFrame:CreateTexture(nil, "BACKGROUND")
		gridPool[index] = line
	end
	line:Show()
	return line
end

function DragMode:RefreshGrid()
	if not gridFrame then return end
	releaseGrid()

	local general = ns:General()
	if not self.active or not general.gridSnap then
		gridFrame:Hide()
		return
	end

	local size = math.max(general.gridSize or 8, 2)
	local width, height = UIParent:GetWidth(), UIParent:GetHeight()

	-- A 2px grid across a 4K screen would be thousands of textures; cap it and
	-- widen the spacing rather than melting the frame rate.
	local columns = math.floor(width / size)
	local rows = math.floor(height / size)
	while columns + rows > MAX_GRID_LINES do
		size = size * 2
		columns = math.floor(width / size)
		rows = math.floor(height / size)
	end

	gridFrame:Show()
	local index = 0
	for i = 0, columns do
		index = index + 1
		local line = acquireLine(index)
		line:SetColorTexture(1, 1, 1, 0.08)
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", UIParent, "TOPLEFT", i * size, 0)
		line:SetSize(1, height)
	end
	for i = 0, rows do
		index = index + 1
		local line = acquireLine(index)
		line:SetColorTexture(1, 1, 1, 0.08)
		line:ClearAllPoints()
		line:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -i * size)
		line:SetSize(width, 1)
	end
end

--------------------------------------------------------------------------------
-- Overlays
--------------------------------------------------------------------------------

local function selectOverlay(overlay)
	if selected and selected ~= overlay then
		selected:EnableKeyboard(false)
		selected.border:SetColorTexture(0.2, 0.6, 1, 0.9)
	end
	selected = overlay
	if overlay then
		overlay:EnableKeyboard(true)
		overlay.border:SetColorTexture(1, 0.8, 0.1, 1)
	end
end

local function buildOverlay(frame)
	local overlay = CreateFrame("Frame", nil, UIParent)
	overlay.frame = frame
	overlay:SetFrameStrata("FULLSCREEN_DIALOG")
	overlay:SetAllPoints(frame)
	overlay:EnableMouse(true)
	overlay:RegisterForDrag("LeftButton")
	overlay:Hide()

	overlay.bg = overlay:CreateTexture(nil, "BACKGROUND")
	overlay.bg:SetAllPoints(overlay)
	overlay.bg:SetColorTexture(0.1, 0.4, 0.8, 0.35)

	overlay.border = overlay:CreateTexture(nil, "BORDER")
	overlay.border:SetAllPoints(overlay)
	overlay.border:SetColorTexture(0.2, 0.6, 1, 0.9)
	overlay.border:SetAlpha(0.5)

	overlay.label = ns:NewFontString(overlay, "OVERLAY")
	ns:SetFont(overlay.label, nil, 11, "OUTLINE", true)
	overlay.label:SetPoint("CENTER", overlay, "CENTER", 0, 0)
	overlay.label:SetText(Registry:Get(frame.unitKey).label)

	overlay.coords = ns:NewFontString(overlay, "OVERLAY")
	ns:SetFont(overlay.coords, nil, 10, "OUTLINE", true)
	overlay.coords:SetPoint("TOP", overlay, "BOTTOM", 0, -2)

	overlay:SetScript("OnMouseDown", function(self) selectOverlay(self) end)

	overlay:SetScript("OnDragStart", function(self)
		if InCombatLockdown() then
			Errors:Print(L["Frames cannot be moved during combat."])
			return
		end
		selectOverlay(self)
		self.frame:StartMoving()
		self.dragging = true
	end)

	overlay:SetScript("OnDragStop", function(self)
		if not self.dragging then return end
		self.dragging = false
		self.frame:StopMovingOrSizing()
		commit(self.frame)
		DragMode:UpdateLabels()
	end)

	overlay:SetScript("OnKeyDown", function(self, key)
		local general = ns:General()
		local step = IsShiftKeyDown() and (general.nudgeStepLarge or 10) or (general.nudgeStep or 1)
		local dx, dy = 0, 0

		if key == "UP" then dy = step
		elseif key == "DOWN" then dy = -step
		elseif key == "LEFT" then dx = -step
		elseif key == "RIGHT" then dx = step
		elseif key == "ESCAPE" then
			if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
			DragMode:Toggle(false)
			return
		else
			-- Anything we do not handle must keep working normally.
			if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
			return
		end

		if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
		nudge(self.frame, dx, dy)
		DragMode:UpdateLabels()
	end)

	overlays[frame.unitKey] = overlay
	return overlay
end

function DragMode:UpdateLabels()
	for unitKey, overlay in pairs(overlays) do
		if overlay:IsShown() then
			local cfg = ns:UnitConfig(unitKey)
			local anchor = cfg and cfg.anchor
			if ns.PartyGroup:Owns(unitKey) then
				overlay.coords:SetText("|cffffcc00" .. L["group"] .. "|r")
			elseif anchor then
				overlay.coords:SetText(string.format("%.0f, %.0f", anchor.x or 0, anchor.y or 0))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Toggle
--------------------------------------------------------------------------------

function DragMode:Toggle(force)
	local wanted = force
	if wanted == nil then wanted = not self.active end
	if wanted == self.active then return end

	if wanted and InCombatLockdown() then
		Errors:Print(L["Frames cannot be moved during combat."])
		return
	end

	self.active = wanted
	ns:General().locked = not wanted

	if not gridFrame then
		gridFrame = CreateFrame("Frame", nil, UIParent)
		gridFrame:SetAllPoints(UIParent)
		gridFrame:SetFrameStrata("BACKGROUND")
		gridFrame:Hide()

		local watcher = CreateFrame("Frame")
		watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
		watcher:SetScript("OnEvent", function()
			if DragMode.active then
				DragMode:Toggle(false)
				Errors:Print(L["Combat started; drag mode turned off."])
			end
		end)
	end

	for unitKey, frame in pairs(ns.frames) do
		local overlay = overlays[unitKey] or buildOverlay(frame)
		if wanted then
			-- Every frame becomes visible so that units which do not currently
			-- exist can still be positioned.
			ns.TestMode:HoldVisible(frame, true)
			overlay:Show()
		else
			overlay:Hide()
			ns.TestMode:HoldVisible(frame, false)
		end
	end

	if not wanted then
		selectOverlay(nil)
	end

	self:RefreshGrid()
	self:UpdateLabels()

	Errors:Print(wanted
		and L["Drag mode ON. Drag to move, click to select then use the arrow keys (Shift for larger steps). Escape or /duf move to finish."]
		or L["Drag mode OFF."])
end

function DragMode:IsActive()
	return self.active
end
