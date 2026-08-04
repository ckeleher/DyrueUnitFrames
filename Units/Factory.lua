-- Units/Factory.lua
--
-- PLAN task 1.5 / SPEC §5.3 — secure frame construction.
--
-- Every frame in the addon comes out of here, including party frames and
-- derived units. There is one frame system, not three (SPEC §5.4, §FR-8.6).
--
-- The protected/unprotected split matters and is deliberate:
--
--   * The Button itself is created from SecureUnitButtonTemplate, so it is
--     protected. Its size, scale, position, attributes, show/hide and unit
--     watch are all forbidden in combat and go through CombatQueue, always.
--
--   * frame.content is an ordinary Frame parented to it. Every bar, texture,
--     font string and aura icon lives in there and is NOT protected, so it can
--     be re-laid-out freely mid-combat. That is what lets a druid shifting form
--     get a mana bar immediately instead of at PLAYER_REGEN_ENABLED.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Errors = ns.Errors
local Colors = ns.Colors
local Registry = ns.Registry
local CombatQueue = ns.CombatQueue

local Factory = {}
ns.Factory = Factory

local FRAME_PREFIX = "DyrueUF_"

--------------------------------------------------------------------------------
-- Event classification
--
-- Unit-filtered registration (RegisterUnitEvent) means the client does the
-- filtering and we never wake up for a raid member's health tick (SPEC §5.7).
--------------------------------------------------------------------------------

local function isUnitEvent(event)
	return event:sub(1, 5) == "UNIT_" or event == "PLAYER_FLAGS_CHANGED"
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

local function runElement(frame, def, event, a, b, c)
	local context = frame.unitKey .. ":" .. def.name
	if Errors:IsDisabled(context) then return end
	local el = frame.elements[def.name]
	if not el then return end
	Errors:SetContext(context)
	def.Update(frame, el, frame.cfg[def.configKey], event, a, b, c)
end

local function dispatch(frame, event, a, b, c)
	-- Identity changes: the unit behind the token is now someone else, so
	-- everything is stale, not just the element that asked for this event.
	if frame.changeEvents[event] then
		if event == "UNIT_TARGET" then
			-- UNIT_TARGET fires with the *owning* unit as its payload, so
			-- "target" signals that targettarget now points at someone else
			-- (SPEC §FR-8.2). Anything else is not ours.
			if a ~= frame.def.owner then return end
		end
		frame:FullUpdate()
		return
	end

	local list = frame.eventMap[event]
	if not list then return end
	for i = 1, #list do
		runElement(frame, list[i], event, a, b, c)
	end
end

local function onEvent(frame, event, a, b, c)
	if not frame.configured then return end
	Errors:Dispatch(dispatch, frame, event, a, b, c)
end

--------------------------------------------------------------------------------
-- Frame methods
--------------------------------------------------------------------------------

local methods = {}

--- Rebuild the element set, re-register events, re-apply layout and refresh.
-- Callers route this through CombatQueue; it touches protected operations.
function methods:ApplyConfig()
	self.cfg = ns:UnitConfig(self.unitKey)
	if not self.cfg then return end

	local enabled = self.cfg.enabled ~= false

	for _, def in ipairs(ns.elementOrder) do
		local elementConfig = self.cfg[def.configKey]
		local context = self.unitKey .. ":" .. def.name

		-- What the CONFIG asks for, before the circuit breaker gets a vote.
		local configWants = enabled and def.IsEnabled(self, elementConfig) and true or false

		-- Turning an element back on is a user asking for another go, so it
		-- clears the breaker. Without this a single transient error disables an
		-- element for the whole session and the checkbox becomes a no-op with
		-- no indication why -- which is a bad failure mode for a safety net.
		-- Keyed on the transition rather than on the current value, so a normal
		-- refresh of an already-enabled element does not keep resetting the
		-- count and defeat the breaker entirely.
		if configWants and self.configWanted[def.name] == false then
			Errors:Reset(context)
		end
		self.configWanted[def.name] = configWants

		local wanted = configWants
			and Errors:IsElementAllowed(def.name)
			and not Errors:IsDisabled(context) and true or false

		if wanted then
			if not self.elements[def.name] then
				Errors:Guard(self.unitKey .. ":" .. def.name .. ":build", function()
					self.elements[def.name] = def.Build(self)
				end)
			end
			local el = self.elements[def.name]
			if el then
				Errors:Guard(self.unitKey .. ":" .. def.name .. ":layout", function()
					def.Layout(self, el, elementConfig)
				end)
			end
			self.activeElements[def.name] = def
		else
			local el = self.elements[def.name]
			if el and def.Disable then
				Errors:Guard(self.unitKey .. ":" .. def.name .. ":disable", function()
					def.Disable(self, el)
				end)
			end
			self.activeElements[def.name] = nil
		end
	end

	self:RegisterEvents()
	self:ApplyLayout()
	self.configured = true

	if not enabled then
		-- A disabled unit is hidden outright and stops watching its unit.
		UnregisterUnitWatch(self)
		self:Hide()
		return
	end

	if self.def.unitWatch then
		RegisterUnitWatch(self)
	else
		self:Show()
	end

	self:FullUpdate()
end

--- Position, size, scale, strata. Protected: only ever called inside
-- CombatQueue (SPEC §FR-1.6).
function methods:ApplyLayout()
	local cfg = self.cfg
	if not cfg then return end

	self:SetSize(math.max(cfg.width or 100, 1), math.max(cfg.height or 20, 1))
	self:SetScale(cfg.scale or 1)
	self:SetAlpha(cfg.alpha or 1)
	self:SetFrameStrata(cfg.strata or "MEDIUM")

	-- Changing strata can reset explicitly-set child frame levels, and the
	-- whole draw order depends on those, so re-assert them here.
	self.content:SetFrameLevel(self:GetFrameLevel() + 1)
	self.overlay:SetFrameLevel(ns:Level(self, "OVERLAY"))

	self:ClearAllPoints()
	local relative, point, relativePoint, x, y = ns.Anchoring:Resolve(self.unitKey)
	self:SetPoint(point, relative, relativePoint, x, y)

	-- Everything below here is unprotected.
	local background = cfg.background
	if background and background.enabled then
		self.background:Show()
		self.background:SetColorTexture(Colors:Unpack(background.color))
		self.background:ClearAllPoints()
		self.background:SetPoint("TOPLEFT", self.content, "TOPLEFT", -(background.inset or 0), background.inset or 0)
		self.background:SetPoint("BOTTOMRIGHT", self.content, "BOTTOMRIGHT", background.inset or 0, -(background.inset or 0))
	else
		self.background:Hide()
	end

	self:ApplyBorder()
	self:LayoutBars()
end

--- Four edge textures rather than a backdrop, so the thickness is exact at any
-- UI scale and there is no Blizzard template involved (SPEC §FR-4.5).
function methods:ApplyBorder()
	local border = self.cfg and self.cfg.border
	local edges = self.borderEdges

	if not border or not border.enabled then
		for i = 1, 4 do edges[i]:Hide() end
		return
	end

	local size = math.max(border.size or 1, 1)
	local r, g, b, a = Colors:Unpack(border.color)
	local content = self.content

	local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]

	top:ClearAllPoints()
	top:SetPoint("TOPLEFT", content, "TOPLEFT", -size, size)
	top:SetPoint("TOPRIGHT", content, "TOPRIGHT", size, size)
	top:SetHeight(size)

	bottom:ClearAllPoints()
	bottom:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", -size, -size)
	bottom:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", size, -size)
	bottom:SetHeight(size)

	left:ClearAllPoints()
	left:SetPoint("TOPLEFT", content, "TOPLEFT", -size, 0)
	left:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", -size, 0)
	left:SetWidth(size)

	right:ClearAllPoints()
	right:SetPoint("TOPRIGHT", content, "TOPRIGHT", size, 0)
	right:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", size, 0)
	right:SetWidth(size)

	for i = 1, 4 do
		edges[i]:SetColorTexture(r, g, b, a)
		edges[i]:Show()
	end
end

--- The bar stack: health, then power, then shapeshift mana.
--
-- Not protected (everything is inside frame.content), so this is safe to call
-- from an event handler during combat — which the shapeshift mana bar relies
-- on when a form change makes it appear or disappear.
function methods:LayoutBars()
	local cfg = self.cfg
	if not cfg then return end

	local elements = self.elements
	local width = math.max(cfg.width or 100, 1)
	local height = math.max(cfg.height or 20, 1)

	local powerCfg, manaCfg, healthCfg = cfg.power, cfg.mana, cfg.health

	local powerSlot = 0
	if self.activeElements.power and powerCfg.enabled then
		powerSlot = (powerCfg.height or 0) + (powerCfg.spacing or 0)
	end

	local manaSlot = 0
	if self.activeElements.mana then
		manaSlot = ns.elements.mana.SlotHeight(self, manaCfg, elements.mana)
	end
	-- In "reserve" mode the slot comes out of the frame's own height so nothing
	-- moves when the bar appears. In "append" mode the bar hangs below the
	-- frame instead, which keeps a form change free of protected calls.
	local reserveSlot = (manaCfg.mode == "reserve") and manaSlot or 0

	local healthHeight = (healthCfg.height or 0) > 0
		and healthCfg.height
		or (height - powerSlot - reserveSlot)
	if healthHeight < 1 then healthHeight = 1 end

	local y = 0
	if elements.health then
		ns.elements.health.SetGeometry(self, elements.health, 0, y, width, healthHeight)
	end
	y = y - healthHeight

	if powerSlot > 0 and elements.power then
		y = y - (powerCfg.spacing or 0)
		ns.elements.power.SetGeometry(self, elements.power, 0, y, width, powerCfg.height)
		y = y - (powerCfg.height or 0)
	end

	if manaSlot > 0 and elements.mana and elements.mana.shown then
		y = y - (manaCfg.spacing or 0)
		local manaWidth = (manaCfg.widthMode == "custom") and (manaCfg.width or width) or width
		ns.elements.mana.SetGeometry(self, elements.mana, 0, y, manaWidth, manaCfg.height)
	end

	-- Text elements anchored to a bar need re-pointing when a bar's visibility
	-- changes, which is exactly the shapeshift case.
	if self.activeElements.text and elements.text then
		ns.elements.text.Layout(self, elements.text, cfg.texts)
	end
end

function methods:RegisterEvents()
	self:UnregisterAllEvents()
	self.eventMap = {}

	-- The DISPLAY unit, not the definition's token: test mode substitutes a
	-- real unit into frames whose own unit does not exist, and the events have
	-- to follow the substitution or the stand-in data would never update.
	local unit = self.unit or self.def.token

	-- Which units each event is filtered against, so a second element asking
	-- for the same event under a different one can be detected. `false` records
	-- "widened to unfiltered".
	local filteredAs = {}

	local function subscribe(event, def)
		-- An element may override the unit for one of its events. Combo points
		-- are what forces this: UNIT_COMBO_POINTS fires with "player" as its
		-- payload but the bar lives on the TARGET frame, so filtering it against
		-- the frame's own display unit means the handler never runs -- with no
		-- error and no warning, just a bar that never updates.
		local wanted = isUnitEvent(event)
			and ((def.eventUnits and def.eventUnits[event]) or unit)
			or nil

		local list = self.eventMap[event]
		if not list then
			list = {}
			self.eventMap[event] = list
			if isUnitEvent(event) then
				if not Compat.RegisterUnitEvent(self, event, wanted) then
					self.eventMap[event] = nil
					return
				end
				filteredAs[event] = { wanted }
			else
				if not Compat.RegisterEvent(self, event) then
					self.eventMap[event] = nil
					return
				end
			end
		elseif wanted and filteredAs[event] then
			local units = filteredAs[event]
			local known = false
			for i = 1, #units do
				if units[i] == wanted then known = true end
			end

			if not known then
				units[#units + 1] = wanted
				-- Two elements want the same event under different units.
				-- Re-filtering to the second one's unit would silently starve
				-- the first, so serve both -- and RegisterUnitEvent takes TWO
				-- units, which covers every case this addon actually has. The
				-- combo bar is the live one: it wants UNIT_POWER_UPDATE for
				-- "player" on the target frame, where the power bar already
				-- wants it for "target".
				if #units == 2 then
					Compat.RegisterUnitEvent(self, event, units[1], units[2])
				elseif Compat.RegisterEvent(self, event) then
					-- Three or more: no filter can express it. Dropping the
					-- filter still delivers to every element, but it means the
					-- frame wakes for units it does not draw -- a real cost on
					-- a noisy event in a raid (SPEC §5.7) -- so it is last.
					filteredAs[event] = false
				end
			end
		end
		list[#list + 1] = def
	end

	for name, def in pairs(self.activeElements) do
		local events, globalEvents = def.events, def.globalEvents
		if def.GetEvents then
			events, globalEvents = def.GetEvents(self, self.cfg[def.configKey])
		end
		if events then
			for event in pairs(events) do subscribe(event, def) end
		end
		if globalEvents then
			for event in pairs(globalEvents) do subscribe(event, def) end
		end
	end

	-- Identity changes: whole-frame refresh rather than per-element.
	self.changeEvents = {}
	for _, event in ipairs(self.def.changeEvents or {}) do
		self.changeEvents[event] = true
		if isUnitEvent(event) then
			-- UNIT_TARGET must be registered for the OWNING unit, not for this
			-- frame's own token: it is the owner's target that changed.
			Compat.RegisterUnitEvent(self, event, self.def.owner or unit)
		else
			Compat.RegisterEvent(self, event)
		end
	end
end

-- Hoisted so a full update allocates nothing. FullUpdate runs on every target
-- change and on every derived-unit poll tick.
local function fullUpdateInner(frame)
	local order = ns.elementOrder
	for i = 1, #order do
		local def = order[i]
		if frame.activeElements[def.name] then
			runElement(frame, def, nil)
		end
	end
end

function methods:FullUpdate()
	if not self.cfg then return end
	Errors:Dispatch(fullUpdateInner, self)
end

function methods:UpdateElement(name)
	local def = self.activeElements[name]
	if not def then return end
	Errors:Dispatch(runElement, self, def, nil)
end

--- The unit token this frame displays. Test mode substitutes here.
function methods:GetDisplayUnit()
	return self.unit
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function onShow(frame)
	if frame.def.derived then
		ns.DerivedPoller:Add(frame)
	end
	frame:FullUpdate()
end

local function onHide(frame)
	if frame.def.derived then
		ns.DerivedPoller:Remove(frame)
	end
end

local function onEnter(frame)
	frame.mouseIsOver = true
	if frame.activeElements and frame.activeElements.highlight then
		frame:UpdateElement("highlight")
	end
	if UnitExists(frame.unit) and ns:General() and ns:General().unitTooltips then
		GameTooltip:SetOwner(frame, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:SetUnit(frame.unit)
		GameTooltip:Show()
	end
end

local function onLeave(frame)
	frame.mouseIsOver = false
	if frame.activeElements and frame.activeElements.highlight then
		frame:UpdateElement("highlight")
	end
	GameTooltip:Hide()
end

function Factory:Create(def)
	local name = FRAME_PREFIX .. def.key

	local ok, frame = pcall(CreateFrame, "Button", name, UIParent, "SecureUnitButtonTemplate")
	Compat.NoteSecureUnitButton(ok and frame ~= nil)
	if not ok or not frame then
		Errors:Print("|cffff5555" .. string.format(
			L["Could not create a secure unit button for %s. Unit frames need SecureUnitButtonTemplate."],
			def.key) .. "|r")
		return nil
	end

	frame.unitKey = def.key
	frame.unit = def.token
	frame.def = def
	frame.elements = {}
	frame.activeElements = {}
	frame.configWanted = {}     -- last known config intent, for breaker resets
	frame.eventMap = {}
	frame.changeEvents = {}
	frame.configured = false

	-- SPEC §5.3
	frame:SetAttribute("unit", def.token)
	frame:SetAttribute("type1", "target")
	frame:SetAttribute("type2", "togglemenu")
	frame:RegisterForClicks("AnyUp")
	frame:SetMovable(true)
	frame:SetClampedToScreen(false)
	Compat.RegisterClickCast(frame)

	-- Unprotected content layer: everything visual lives in here.
	frame.content = CreateFrame("Frame", nil, frame)
	frame.content:SetAllPoints(frame)
	frame.content:SetFrameLevel(frame:GetFrameLevel() + 1)

	frame.background = frame.content:CreateTexture(nil, "BACKGROUND")

	-- Text, highlights and borders need a frame of their own ABOVE the bars.
	-- Putting them on frame.content at OVERLAY is not enough: the bars are
	-- child frames, and a child frame outranks every layer of its parent.
	frame.overlay = CreateFrame("Frame", nil, frame.content)
	frame.overlay:SetAllPoints(frame.content)
	frame.overlay:SetFrameLevel(ns:Level(frame, "OVERLAY"))

	frame.borderEdges = {}
	for i = 1, 4 do
		local edge = frame.overlay:CreateTexture(nil, "ARTWORK", nil, 1)
		edge:Hide()
		frame.borderEdges[i] = edge
	end

	for methodName, fn in pairs(methods) do
		frame[methodName] = fn
	end

	frame:SetScript("OnEvent", onEvent)
	frame:HookScript("OnShow", onShow)
	frame:HookScript("OnHide", onHide)
	frame:HookScript("OnEnter", onEnter)
	frame:HookScript("OnLeave", onLeave)

	ns.frames[def.key] = frame
	return frame
end

function Factory:CreateAll()
	for _, def in ipairs(Registry:Sorted()) do
		-- SPEC §FR-8.5: focus frames are not created at all on Classic Era.
		if Registry:IsAvailable(def.key) and not ns.frames[def.key] then
			self:Create(def)
		end
	end

	for _, def in ipairs(Registry:Sorted()) do
		local frame = ns.frames[def.key]
		if frame then
			CombatQueue:Run("apply:" .. def.key, function()
				frame:ApplyConfig()
			end)
		end
	end
end

--- Copy every setting from one unit to another (PLAN task 2.7).
-- Layout position is deliberately excluded: copying x/y would stack two frames
-- on top of each other, which is never what anyone means.
function Factory:CopySettings(fromKey, toKey)
	local source = ns:UnitConfig(fromKey)
	local destination = ns:UnitConfig(toKey)
	if not source or not destination then return false end

	local anchor = destination.anchor
	local copy = ns.Defaults.DeepCopy(source)
	copy.anchor = anchor

	for key in pairs(destination) do destination[key] = nil end
	for key, value in pairs(copy) do destination[key] = value end

	ns:BumpSerial()
	ns:RefreshUnit(toKey)
	return true
end
