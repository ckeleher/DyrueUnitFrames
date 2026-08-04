-- Elements/ComboPoints.lua
--
-- Plan 9 — a row of flat rectangles above the target frame.
--
-- Whose resource this is matters, and is the reason for the one unusual thing
-- in here. Combo points belong to the PLAYER and are spent on the TARGET, so
-- the value is read as GetComboPoints("player", <target>) and the bar is drawn
-- on the target's frame. That asymmetry carries through to the events:
-- UNIT_COMBO_POINTS fires with "player" as its payload, so `eventUnits` below
-- overrides the frame's own display unit for that one event. Without it the
-- registration would be filtered against "target" and the handler would never
-- run -- silently, with no error, and the bar would simply never update.
--
-- The bar sits OUTSIDE the frame's bounds, occupying [top, top + height]. It
-- therefore takes no slot in the bar stack, LayoutBars is untouched, and
-- nothing inside the frame moves when it appears.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Colors = ns.Colors

local element = {
	order = 35,                 -- with the bars: after mana (30), before text (60)
	configKey = "combo",
	events = {
		-- BOTH, deliberately, and gated on nothing: Compat.HasEvent skips
		-- whichever one the running client does not have.
		--
		-- UNIT_COMBO_POINTS is the documented Classic event and is what
		-- Blizzard's own ComboFrame used. It does NOT exist on the Anniversary
		-- client -- C_EventUtils.IsEventValid("UNIT_COMBO_POINTS") returns
		-- false there -- because these clients run the modern shared code,
		-- which retired it and delivers combo points as a power type instead.
		--
		-- Registering an absent event is skipped silently, by design, and that
		-- is exactly how the first cut of this element shipped a bar that only
		-- ever updated when the target changed. Feature-probe, never
		-- version-check: declare both and let Compat decide.
		UNIT_COMBO_POINTS = true,
		UNIT_POWER_UPDATE = true,
	},
	-- See the header. This is the whole reason `def.eventUnits` exists: both of
	-- these carry "player", on a frame whose own unit is the target.
	eventUnits = {
		UNIT_COMBO_POINTS = "player",
		UNIT_POWER_UPDATE = "player",
	},
	globalEvents = {
		-- Points reset on a target switch. Already a change event on the target
		-- frame -- dispatch handles those first and returns -- so listing it here
		-- costs nothing there and is what makes the element work if someone
		-- enables it on the player frame.
		PLAYER_TARGET_CHANGED = true,
		PLAYER_ENTERING_WORLD = true,
	},
}

--------------------------------------------------------------------------------
-- Growth
--
-- Same vocabulary as the indicator row, minus the vertical directions: this is
-- a horizontal bar and "up" is not a fill order it can honor.
--------------------------------------------------------------------------------

function element.GrowthValues()
	return { RIGHT = L["Right"], LEFT = L["Left"] }
end

--------------------------------------------------------------------------------
-- Geometry
--
-- Borders, cheaply: ONE texture behind the group filled with borderColor, with
-- the pips laid on top leaving a `borderSize` gap between them and around the
-- outside. The backdrop showing through those gaps IS the border. Six textures
-- rather than the twenty-plus per-pip edges would need, and the line between
-- two pips is automatically a single shared line of exactly the requested
-- thickness rather than two abutting ones at double width.
--------------------------------------------------------------------------------

--- Pip widths for a bar of `width`, with `count` pips and `border` between and
-- around them.
--
-- The remainder is handed out one unit at a time to the leading pips, so
-- BORDERS STAY EXACTLY `border` EVERYWHERE and pips may differ by one. The
-- request asked for clear borders, so the borders are the quantity held
-- constant. (At a frame scale other than 1.0 a UI unit is not a screen pixel
-- and this is best-effort; not worth engineering around.)
-- @return table widths
local function pipWidths(width, border, count)
	local inner = width - border * (count + 1)
	if inner < count then inner = count end          -- degenerate, but never zero

	local base = math.floor(inner / count)
	local remainder = inner - base * count

	local widths = {}
	for i = 1, count do
		widths[i] = base + (i <= remainder and 1 or 0)
	end
	return widths
end

--------------------------------------------------------------------------------
-- Element
--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return cfg and cfg.enabled == true
end

function element.Build(frame)
	local el = { pips = {} }

	-- A container frame rather than loose textures on frame.overlay: one place
	-- to Show/Hide, one frame level to set, and a real widget for anything that
	-- later wants to anchor to this bar. Parented to frame.content, which is
	-- unprotected, so none of this is combat-restricted.
	el.container = CreateFrame("Frame", nil, frame.content)
	el.container:SetFrameLevel(ns:Level(frame, "OVERLAY"))
	el.container:Hide()

	el.border = el.container:CreateTexture(nil, "BACKGROUND")
	el.border:SetAllPoints(el.container)

	for i = 1, Compat.MAX_COMBO_POINTS do
		el.pips[i] = el.container:CreateTexture(nil, "ARTWORK")
	end

	el.lastPoints = nil

	return el
end

function element.Layout(frame, el, cfg)
	local container = el.container
	container:SetFrameLevel(ns:Level(frame, "OVERLAY"))
	container:SetAlpha(cfg.alpha or 1)

	local width = (cfg.widthMode == "custom")
		and (cfg.width or 200)
		or math.max(frame.cfg and frame.cfg.width or 200, 1)
	local height = math.max(cfg.height or 10, 1)
	local border = math.max(cfg.borderSize or 1, 0)

	-- Two borders plus one row of pips have to fit, both ways round.
	local count = #el.pips
	if border * 2 >= height then border = math.max(math.floor((height - 1) / 2), 0) end
	if border * (count + 1) >= width then border = 0 end

	container:SetSize(width, height)
	el.border:SetColorTexture(Colors:Unpack(cfg.borderColor))

	local widths = pipWidths(width, border, count)
	local pipHeight = math.max(height - border * 2, 1)
	local x = border

	for i = 1, count do
		local pip = el.pips[i]
		pip:ClearAllPoints()
		pip:SetPoint("TOPLEFT", container, "TOPLEFT", x, -border)
		pip:SetSize(widths[i], pipHeight)
		x = x + widths[i] + border
	end

	-- The colors are per-value and belong to Update, but a Layout that left them
	-- unset would render five untextured pips until the first event arrives.
	element.Paint(el, cfg, el.lastPoints or 0)
end

--- Color every pip for a given point total, honoring growth direction.
function element.Paint(el, cfg, points)
	local count = #el.pips
	if points < 0 then points = 0 end
	if points > count then points = count end       -- clamp rather than error

	local fromLeft = (cfg.growth ~= "LEFT")
	local fr, fg, fb, fa = Colors:Unpack(cfg.color)
	local er, eg, eb, ea = Colors:Unpack(cfg.emptyColor)

	for i = 1, count do
		-- Spelled out rather than written as `fromLeft and X or Y`: X is a
		-- boolean here, and that idiom silently falls through to Y whenever X is
		-- false, which would light up every pip the growth direction meant to
		-- leave empty.
		local filled
		if fromLeft then
			filled = (i <= points)
		else
			filled = (i > count - points)
		end
		if filled then
			el.pips[i]:SetColorTexture(fr, fg, fb, fa)
		else
			el.pips[i]:SetColorTexture(er, eg, eb, ea)
		end
	end
end

function element.Update(frame, el, cfg, event)
	local widget, available = ns:AnchorWidget(frame, cfg.anchorTo)

	-- Anchored to a bar that is not showing: hide, rather than dropping the bar
	-- onto the frame body. Same rule as bar-anchored text and the indicator row.
	if not available then
		el.container:Hide()
		el.lastPoints = nil
		return
	end

	local points = Compat.GetComboPoints(frame.unit)

	-- Combo points now arrive on the player's power event, which for an energy
	-- user fires several times a second and carries a changed combo count on
	-- almost none of them. Scoped to that one event on purpose: a full update
	-- or a target change must always repaint, because those are the paths a
	-- configuration change comes back through.
	if event == "UNIT_POWER_UPDATE" and points == el.lastPoints then return end

	el.lastPoints = points

	if points <= 0 and cfg.hideWhenEmpty then
		el.container:Hide()
		return
	end

	el.container:ClearAllPoints()
	el.container:SetPoint(cfg.point or "BOTTOMLEFT", widget,
		cfg.relativePoint or "TOPLEFT", cfg.x or 0, cfg.y or 0)

	element.Paint(el, cfg, points)
	el.container:Show()
end

function element.Disable(frame, el)
	el.lastPoints = nil
	el.container:Hide()
end

ns:RegisterElement("combo", element)
