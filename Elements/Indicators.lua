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
-- `order` fixes resting-before-combat as requested while leaving it changeable.
-- Kept sorted at file scope so Update never sorts.
--------------------------------------------------------------------------------

local STATES = {
	{
		key = "resting",
		order = 1,
		label = L["Resting"],
		-- IsResting is about you, not about a unit. Returning false for
		-- everything else keeps that fact here rather than special-cased in
		-- the layout below.
		active = function(frame)
			if frame.unitKey ~= "player" then return false end
			return IsResting and IsResting() and true or false
		end,
	},
	{
		key = "combat",
		order = 2,
		label = L["In combat"],
		-- UnitAffectingCombat works for any unit, so this is meaningful on the
		-- target and on party members too.
		active = function(frame)
			local unit = frame.unit
			if not unit or not UnitExists(unit) then return false end
			return UnitAffectingCombat(unit) and true or false
		end,
	},
}

table.sort(STATES, function(a, b) return a.order < b.order end)

element.STATES = STATES

--- State list for the options UI.
function element.StateList()
	return STATES
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
		local state = cfg.states and cfg.states[STATES[i].key]
		if state and state.enabled then return true end
	end
	return false
end

function element.Build(frame)
	local el = { icons = {} }
	for i = 1, #STATES do
		-- On the overlay, above the bars. A texture on frame.content would be
		-- covered by them outright -- bars are child frames, and frame level
		-- beats draw layer.
		local icon = frame.overlay:CreateTexture(nil, "OVERLAY", nil, 4)
		icon:Hide()
		el.icons[STATES[i].key] = icon
	end
	return el
end

--- Apply art and size. Position is decided per update, since it depends on how
-- many states are active.
function element.Layout(frame, el, cfg)
	local size = math.max(cfg.size or 20, 1)

	for i = 1, #STATES do
		local state = STATES[i]
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
	local widget, available = ns:AnchorWidget(frame, cfg.anchorTo)

	-- Anchored to a bar that is not showing: hide, rather than dropping the
	-- row onto the frame body. Same rule as bar-anchored text.
	if not available then
		for i = 1, #STATES do el.icons[STATES[i].key]:Hide() end
		return
	end

	local growth = GROWTH[cfg.growth] or GROWTH.RIGHT
	local step = (cfg.size or 20) + (cfg.spacing or 0)
	local slot = 0

	for i = 1, #STATES do
		local state = STATES[i]
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
	for i = 1, #STATES do
		el.icons[STATES[i].key]:Hide()
	end
end

ns:RegisterElement("indicators", element)
