-- Elements/Portrait.lua
--
-- SPEC §4.7. Three modes: none (default), 2D, 3D.
--
-- Model frames are the least reliable widget in the API (risk R11), so every
-- failure mode in FR-7.4 is handled explicitly here rather than hoped away:
--
--   * the widget is never trusted to notice a unit change — SetUnit is re-called,
--   * the camera is re-applied after every loading screen,
--   * a unit whose model cannot load falls back to the 2D portrait, silently,
--   * a repeated SetUnit for an unchanged GUID is skipped.
--
-- The feature is cosmetic and default-off, so if it ever misbehaves on a patch
-- it can be turned off without affecting anything else.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Errors = ns.Errors
local Colors = ns.Colors

local element = {
	order = 5,
	configKey = "portrait",
	events = {
		UNIT_PORTRAIT_UPDATE = true,
		UNIT_MODEL_CHANGED = true,
		UNIT_CONNECTION = true,
	},
	globalEvents = {},
}

--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return cfg and cfg.mode and cfg.mode ~= "none"
end

function element.Build(frame)
	local el = {}

	-- Plan 18. On frame.content rather than on the model, which is the whole
	-- mechanism: the model is a CHILD frame of content, and a child draws above
	-- every layer of its parent (see Core.lua's draw-order note), so a texture
	-- here is behind the model with no frame-level arithmetic to get wrong.
	--
	-- Sublevel 1, between the frame backdrop at 0 and the portrait art at 2.
	-- All three are explicit because the backdrop can overlap this one, and a
	-- tie in a draw layer resolves by creation order -- which works until an
	-- element is built in a different order and then breaks with no error.
	el.background = frame.content:CreateTexture(nil, "BACKGROUND", nil, 1)
	el.background:Hide()

	-- The 2D texture always exists: it is both a mode in its own right and the
	-- fallback for a 3D model that will not load.
	el.texture = frame.content:CreateTexture(nil, "BACKGROUND", nil, 2)
	el.texture:Hide()

	el.model = nil          -- created lazily; a PlayerModel is not free
	el.lastGUID = nil
	el.modelFailed = false

	-- Last resolved geometry. `inset` is what the bars give up to the column;
	-- Factory reads it back for the hit rect.
	el.width, el.height, el.inset = 0, 0, 0
	el.barStack = 0

	return el
end

--------------------------------------------------------------------------------
-- Geometry (Plan 7)
--
-- The portrait is a column of the frame, not an ornament beside it: it lives
-- inside the secure button so clicks on it target the unit, it is flush with
-- the bars, and it is exactly as tall as they are. The bars inset to make room,
-- which is the same idea as the shapeshift mana bar's vertical slot rather than
-- a second one.
--------------------------------------------------------------------------------

-- Below this a bar stops being a bar. A column wide enough to leave less than
-- this is clamped, and shrinks with the slot so the two never overlap.
local MIN_BAR_WIDTH = 20

--- The portrait's size, and the width it takes out of the frame.
--
-- Pure, so `Units/Factory.lua` can ask for the inset before anything is drawn
-- and a test can check the arithmetic without building a frame.
--
-- @param cfg table the portrait config
-- @param barStack number height of the health + power stack, 0 if unknown
-- @param frameWidth number the frame's own width, for the clamp
-- @return number width, number height, number slot (0 unless `column`)
function element.Resolve(cfg, barStack, frameWidth)
	if not cfg or (cfg.mode or "none") == "none" then return 0, 0, 0 end

	barStack = barStack or 0
	local height = (cfg.matchBarHeight ~= false and barStack > 0)
		and barStack
		or math.max(cfg.height or 40, 1)
	local width = cfg.square and height or math.max(cfg.width or 40, 1)

	if (cfg.placement or "column") ~= "column" then
		return width, height, 0
	end

	-- The column occupies its own width plus whatever gap `x` asks for.
	-- Negative x would mean overlapping the bars, which the inset cannot
	-- express, so it does not shrink the slot.
	local gap = math.max(cfg.x or 0, 0)
	local slot = width + gap

	local room = math.max((frameWidth or 0) - MIN_BAR_WIDTH, 0)
	if slot > room then
		slot = room
		width = math.max(slot - gap, 1)
	end

	return width, height, slot
end

--- Size, anchor and alpha for one portrait widget, from the last resolved size.
--
-- File-local rather than a closure inside Layout, because the 3D model is
-- created lazily — the first time 3D mode actually renders — which is after
-- Layout has already run. It has to be placed at creation time too, or it comes
-- into the world with no size, no anchor and no alpha, and stays that way until
-- something else happens to trigger a re-layout.
local function place(frame, el, cfg, widget)
	widget:ClearAllPoints()
	widget:SetSize(el.width or cfg.width or 40, el.height or cfg.height or 40)

	local placement = cfg.placement or "column"
	local x, y = cfg.x or 0, cfg.y or 0

	if placement == "detached" then
		-- Its own space beyond the frame's bounds, so the bars keep the full
		-- width. Outside the button's rect too; see Factory:ApplyHitRect.
		if cfg.side == "RIGHT" then
			widget:SetPoint("LEFT", frame.content, "RIGHT", x, y)
		else
			widget:SetPoint("RIGHT", frame.content, "LEFT", -x, y)
		end
	elseif placement == "column" then
		-- Anchored to the frame's top corner, which is the top of the health
		-- bar: that is the edge the height is measured from.
		if cfg.side == "RIGHT" then
			widget:SetPoint("TOPRIGHT", frame.content, "TOPRIGHT", -x, y)
		else
			widget:SetPoint("TOPLEFT", frame.content, "TOPLEFT", x, y)
		end
	else
		widget:SetPoint(cfg.point or "LEFT", frame.content, cfg.relativePoint or "LEFT", x, y)
	end

	widget:SetAlpha(cfg.alpha or 1)
end

--- Resolve and apply the portrait's geometry, and report the space it took.
--
-- Called from `LayoutBars`, which is the only place that knows how tall the
-- health bar came out — so it is the only place that can size a portrait
-- tracking the bar stack.
--
-- @return number the width to inset the bars by, 0 in every other placement
function element.SetGeometry(frame, el, cfg, barStack, frameWidth)
	el.width, el.height, el.inset = element.Resolve(cfg, barStack, frameWidth)
	el.barStack = barStack

	place(frame, el, cfg, el.texture)
	place(frame, el, cfg, el.background)
	if el.model then place(frame, el, cfg, el.model) end

	return el.inset
end

local function ensureModel(frame, el)
	if el.model then return el.model end

	local ok, model = pcall(CreateFrame, "PlayerModel", nil, frame.content)
	if not ok or not model then
		el.modelFailed = true
		return nil
	end

	-- Behind the bars, so an overlay-placed portrait reads as a backdrop.
	model:SetFrameLevel(ns:Level(frame, "PORTRAIT"))

	-- A model frame is a real frame, and a frame inside the secure button that
	-- takes the mouse would swallow the click that is supposed to target the
	-- unit. Textures never do; this one is asserted rather than assumed,
	-- because `column` placement puts it directly over the button's rect.
	pcall(model.EnableMouse, model, false)

	model:Hide()
	el.model = model

	local cfg = frame.cfg and frame.cfg.portrait
	if cfg then place(frame, el, cfg, model) end

	return model
end

--- Whether the fill behind the portrait should be drawn (Plan 18).
--
-- Keyed on the configured MODE, not on which widget happens to be rendering.
-- A 3D model that is briefly unavailable — out of range, not yet seen — falls
-- back to the 2D texture for a moment (FR-7.4), and a background strobing off
-- and on with it would be worse than one that simply stays where it is. The
-- user asked for a background on their 3D portrait; a transient failure does
-- not make it a 2D portrait.
local function backgroundShown(cfg)
	if (cfg.mode or "none") ~= "3d" then return false end
	local background = cfg.background
	return background ~= nil and background.enabled ~= false
end

function element.Layout(frame, el, cfg)
	-- Seed the geometry from the last known bar stack. `LayoutBars` runs
	-- immediately after this, from the same ApplyConfig, and settles it with
	-- the real number — but a portrait must never be left unsized in between.
	local unitCfg = frame.cfg
	element.SetGeometry(frame, el, cfg, el.barStack, unitCfg and unitCfg.width)

	local mode = cfg.mode or "none"
	if mode == "none" then
		el.texture:Hide()
		el.background:Hide()
		if el.model then el.model:Hide() end
	end

	if cfg.background then
		el.background:SetColorTexture(Colors:Unpack(cfg.background.color))
	end
	if not backgroundShown(cfg) then el.background:Hide() end

	el.texture:SetDesaturated(cfg.desaturate and true or false)
end

--------------------------------------------------------------------------------
-- Camera (SPEC §FR-7.5)
--------------------------------------------------------------------------------

local function applyCamera(el, cfg)
	local model = el.model
	if not model then return end
	pcall(model.SetPortraitZoom, model, 1)
	pcall(model.SetCamDistanceScale, model, 1 + (cfg.camera or 0))
	pcall(model.SetPosition, model, 0, 0, cfg.cameraY or 0)
end

--- Called from Core on PLAYER_ENTERING_WORLD. A loading screen resets a model
-- frame's camera and, often enough, its unit as well.
function element.OnEnteringWorld(frame, el)
	local cfg = frame.cfg and frame.cfg.portrait
	if not cfg or cfg.mode ~= "3d" then return end
	el.lastGUID = nil          -- force a re-SetUnit
	applyCamera(el, cfg)
	element.Update(frame, el, cfg)
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

-- The game's portrait art is round: the corners of the texture are
-- transparent. There is no way to square that off, so "square" crops to the
-- inscribed square instead -- the largest region that is fully opaque. For a
-- circle of radius 0.5 centered at 0.5 that is 0.5 - 0.5/sqrt(2) = 0.146 in from
-- each edge, which is also very close to the crop addons have long used to trim
-- the border off square icon art.
local SQUARE_INSET = 0.146

local function applyShape(el, cfg)
	if (cfg.shape or "square") == "square" then
		el.texture:SetTexCoord(SQUARE_INSET, 1 - SQUARE_INSET, SQUARE_INSET, 1 - SQUARE_INSET)
	else
		el.texture:SetTexCoord(0, 1, 0, 1)
	end
end

local function show2D(frame, el, cfg)
	local unit = frame.unit
	el.texture:Show()
	if el.model then el.model:Hide() end

	if unit and UnitExists(unit) and UnitIsVisible(unit)
		and Compat.SetPortraitTexture(el.texture, unit) then
		applyShape(el, cfg)
		return
	end

	-- FR-7.3: the question-mark fallback when the portrait is unavailable.
	el.texture:SetTexture(Compat.QUESTION_MARK_TEXTURE)
	el.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

local function show3D(frame, el, cfg)
	local unit = frame.unit
	local model = ensureModel(frame, el)

	-- No model widget, or the unit is out of range / not yet seen: fall back to
	-- 2D silently. The user asked for a portrait, not for an error.
	if not model or not unit or not UnitExists(unit) or not UnitIsVisible(unit) then
		show2D(frame, el, cfg)
		return
	end

	el.texture:Hide()
	model:Show()

	local guid = UnitGUID(unit)
	if guid ~= el.lastGUID then
		-- Never assume the widget noticed the unit change (FR-7.4).
		el.lastGUID = guid
		local ok = pcall(model.ClearModel, model)
		ok = pcall(model.SetUnit, model, unit) and ok
		if not ok then
			el.modelFailed = true
			show2D(frame, el, cfg)
			return
		end
		applyCamera(el, cfg)
	end
end

function element.Update(frame, el, cfg)
	local mode = cfg and cfg.mode or "none"

	if mode == "none" then
		el.texture:Hide()
		el.background:Hide()
		if el.model then el.model:Hide() end
		el.lastGUID = nil
		return
	end

	local unit = frame.unit
	if not unit or not UnitExists(unit) then
		el.texture:Hide()
		el.background:Hide()
		if el.model then el.model:Hide() end
		el.lastGUID = nil
		return
	end

	el.background:SetShown(backgroundShown(cfg))

	if mode == "3d" and not el.modelFailed then
		show3D(frame, el, cfg)
	else
		show2D(frame, el, cfg)
	end
end

function element.Disable(frame, el)
	el.texture:Hide()
	el.background:Hide()
	if el.model then el.model:Hide() end
	el.lastGUID = nil
	-- The bars reclaim the column, and Factory's hit rect reads this back.
	el.inset = 0
end

--- Anchor target name for text elements that want to sit on the portrait.
function element.GetAnchorWidget(el, cfg)
	if cfg and cfg.mode == "3d" and el.model and el.model:IsShown() then
		return el.model
	end
	return el.texture
end

ns:RegisterElement("portrait", element)
