-- Elements/Indicators.lua
--
-- Plan 1 — combat and resting state icons.
--
-- A small ordered row of state markers. Two states ship, but the shape is a
-- LIST rather than two hardcoded icons, so a third (PvP, leader, raid target)
-- is a table entry rather than a rewrite.
--
-- Only *active* states take a slot, so combat on its own sits at position one
-- rather than leaving a resting-shaped hole.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Colors = ns.Colors

local element = {
	order = 80,                 -- after text (60) and auras (70), before highlight (90)
	configKey = "indicators",
	events = {
		-- Combat state for units other than the player arrives here.
		UNIT_FLAGS = true,
		-- Plan 24. Unit-filtered (SPEC §5.7), so only the pet frame ever wakes
		-- for it, and Compat.RegisterUnitEvent skips it outright on a client
		-- that does not have it. `element.GetEvents` could register it only
		-- while a happiness state is on, and is deliberately not used: one
		-- rarely-firing filtered event on one frame does not justify making
		-- this element's event set dynamic.
		UNIT_HAPPINESS = true,
	},
	globalEvents = {
		PLAYER_REGEN_DISABLED = true,
		PLAYER_REGEN_ENABLED = true,
		PLAYER_UPDATE_RESTING = true,
		PLAYER_ENTERING_WORLD = true,
	},
}

--------------------------------------------------------------------------------
-- The states
--
-- `order` fixes the slot sequence while leaving it changeable. Kept sorted at
-- file scope so Update never sorts.
--
-- Combat is LAST rather than second (Plan 24). It is the only state that
-- appears on more than one unit, so it is the only one whose position has to
-- work everywhere, and after is the right answer on both frames that have it:
--
--   player   resting, combat      -- unchanged; there is nothing between them
--   pet      happiness, combat    -- as requested
--
-- One global sequence rather than a per-unit one. That works because the states
-- either side of combat are single-unit -- resting is player-only and happiness
-- is pet-only -- so ordering them all on one axis cannot produce a conflict.
--
-- Two optional fields decide where a state can appear AT ALL, as opposed to
-- when it is active:
--
--   `requires`  names a Compat capability flag, exactly as Units/Registry does
--               for units. A client without the capability does not get the
--               state or its controls.
--   `units`     the set of unit keys the state can ever fire on.
--
-- Both are SPEC §FR-8.5 -- absent, not present-and-broken -- applied to a state
-- rather than to a unit. `units` is load-bearing rather than cosmetic for
-- happiness: GetPetHappiness answers about the player's pet whatever frame is
-- asking, so without it a happy pet would light an icon on the TARGET frame.
--------------------------------------------------------------------------------

local STATES = {
	{
		key = "resting",
		order = 1,
		label = L["Resting"],
		-- IsResting is about you, not about a unit.
		units = { player = true },
		active = function(frame)
			return IsResting and IsResting() and true or false
		end,
	},
	{
		key = "combat",
		order = 5,
		label = L["In combat"],
		-- UnitAffectingCombat works for any unit, so this is meaningful on the
		-- target and on party members too.
		active = function(frame)
			local unit = frame.unit
			if not unit or not UnitExists(unit) then return false end
			return UnitAffectingCombat(unit) and true or false
		end,
	},

	-- Plan 24 -- hunter pet happiness.
	--
	-- Three boolean states rather than one tri-state entry. They are mutually
	-- exclusive, so exactly one is ever active and the row still spends exactly
	-- one slot on happiness -- and this way each level keeps its own fixed art,
	-- which is what lets Layout go on applying art at config time instead of
	-- Update having to re-texture on every refresh.
	--
	-- The per-level enable that falls out of it is the point rather than a side
	-- effect: turning `happy` off and leaving the other two on is "only mark the
	-- pet when something is wrong", which a single tri-state entry could not
	-- express.
	{
		key = "happy",
		order = 2,
		label = L["Pet: happy"],
		requires = "hasPetHappiness",
		units = { pet = true },
		active = function() return Compat.GetPetHappiness() == Compat.PET_HAPPY end,
	},
	{
		key = "content",
		order = 3,
		label = L["Pet: content"],
		requires = "hasPetHappiness",
		units = { pet = true },
		active = function() return Compat.GetPetHappiness() == Compat.PET_CONTENT end,
	},
	{
		key = "unhappy",
		order = 4,
		label = L["Pet: unhappy"],
		requires = "hasPetHappiness",
		units = { pet = true },
		active = function() return Compat.GetPetHappiness() == Compat.PET_UNHAPPY end,
	},
}

table.sort(STATES, function(a, b) return a.order < b.order end)

element.STATES = STATES

--- Can this state ever appear on this unit, on this client?
-- Answers a question about capability and unit, never about the current value.
local function available(state, unitKey)
	if state.requires and not Compat[state.requires] then return false end
	if state.units and not state.units[unitKey] then return false end
	return true
end

--- State list for the options UI. Given a unit key, only the states that can
-- ever appear on it -- so the pet's happiness controls are absent from every
-- other frame rather than present and permanently idle.
function element.StateList(unitKey)
	if not unitKey then return STATES end

	local list = {}
	for i = 1, #STATES do
		if available(STATES[i], unitKey) then list[#list + 1] = STATES[i] end
	end
	return list
end

--------------------------------------------------------------------------------
-- Growth
--
-- Same shape as Units/PartyGroup's GROWTH table, so there is one idea of
-- "growth direction" in the codebase rather than two that drift apart.
--------------------------------------------------------------------------------

local GROWTH = {
	RIGHT = { x = 1, y = 0 },
	LEFT = { x = -1, y = 0 },
	UP = { x = 0, y = 1 },
	DOWN = { x = 0, y = -1 },
}

function element.GrowthValues()
	return { RIGHT = L["Right"], LEFT = L["Left"], UP = L["Up"], DOWN = L["Down"] }
end

--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	if not cfg or not cfg.enabled then return false end
	for i = 1, #STATES do
		local state = STATES[i]
		if available(state, frame.unitKey) then
			local stateCfg = cfg.states and cfg.states[state.key]
			if stateCfg and stateCfg.enabled then return true end
		end
	end
	return false
end

function element.Build(frame)
	-- Only the states that can appear on this frame get a texture, and
	-- `el.states` is the filtered list every entry point below walks. An
	-- unavailable state is therefore absent from the element rather than
	-- present and permanently hidden.
	--
	-- Settled once, here, rather than per update: availability turns on the
	-- client's capabilities and on the frame's unit, and neither changes for
	-- the life of the frame.
	local el = { icons = {}, states = {} }

	for i = 1, #STATES do
		local state = STATES[i]
		if available(state, frame.unitKey) then
			el.states[#el.states + 1] = state
			-- On the overlay, above the bars. A texture on frame.content would
			-- be covered by them outright -- bars are child frames, and frame
			-- level beats draw layer.
			local icon = frame.overlay:CreateTexture(nil, "OVERLAY", nil, 4)
			icon:Hide()
			el.icons[state.key] = icon
		end
	end

	return el
end

--- Apply art and size. Position is decided per update, since it depends on how
-- many states are active.
function element.Layout(frame, el, cfg)
	local size = math.max(cfg.size or 20, 1)

	for i = 1, #el.states do
		local state = el.states[i]
		local icon = el.icons[state.key]
		local stateCfg = cfg.states and cfg.states[state.key]

		icon:SetSize(size, size)

		if cfg.style == "square" then
			-- The escape hatch for art that has moved: a solid marker still
			-- tells you the state is on, which is the point of the indicator.
			icon:SetColorTexture(Colors:Unpack(stateCfg and stateCfg.color))
		else
			local texture, left, right, top, bottom = Compat.GetStateIcon(state.key)
			if texture then
				icon:SetTexture(texture)
				icon:SetTexCoord(left, right, top, bottom)
				icon:SetVertexColor(Colors:Unpack(stateCfg and stateCfg.color))
			else
				icon:SetColorTexture(Colors:Unpack(stateCfg and stateCfg.color))
			end
		end

		icon:SetAlpha(cfg.alpha or 1)
	end
end

function element.Update(frame, el, cfg)
	-- Named `anchored` rather than `available`: the file-scope `available` above
	-- answers a different question -- can this state exist here at all, as
	-- against is its anchor bar currently showing.
	local widget, anchored = ns:AnchorWidget(frame, cfg.anchorTo)

	-- Anchored to a bar that is not showing: hide, rather than dropping the
	-- row onto the frame body. Same rule as bar-anchored text.
	if not anchored then
		for i = 1, #el.states do el.icons[el.states[i].key]:Hide() end
		return
	end

	local growth = GROWTH[cfg.growth] or GROWTH.RIGHT
	local step = (cfg.size or 20) + (cfg.spacing or 0)
	local slot = 0

	for i = 1, #el.states do
		local state = el.states[i]
		local icon = el.icons[state.key]
		local stateCfg = cfg.states and cfg.states[state.key]

		local on = stateCfg and stateCfg.enabled and state.active(frame) or false

		if on then
			local offset = step * slot
			slot = slot + 1
			icon:ClearAllPoints()
			icon:SetPoint(cfg.point or "TOPLEFT", widget, cfg.relativePoint or "TOPLEFT",
				(cfg.x or 0) + growth.x * offset,
				(cfg.y or 0) + growth.y * offset)
			icon:Show()
		else
			icon:Hide()
		end
	end
end

function element.Disable(frame, el)
	for i = 1, #el.states do
		el.icons[el.states[i].key]:Hide()
	end
end

ns:RegisterElement("indicators", element)
