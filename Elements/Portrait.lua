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

	-- The 2D texture always exists: it is both a mode in its own right and the
	-- fallback for a 3D model that will not load.
	el.texture = frame.content:CreateTexture(nil, "BACKGROUND", nil, 1)
	el.texture:Hide()

	el.model = nil          -- created lazily; a PlayerModel is not free
	el.lastGUID = nil
	el.modelFailed = false

	return el
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

--- Size, anchor and alpha for one portrait widget.
--
-- File-local rather than a closure inside Layout, because the 3D model is
-- created lazily — the first time 3D mode actually renders — which is after
-- Layout has already run. It has to be placed at creation time too, or it comes
-- into the world with no size, no anchor and no alpha, and stays that way until
-- something else happens to trigger a re-layout.
local function place(frame, el, cfg, widget)
	widget:ClearAllPoints()
	widget:SetSize(cfg.width or 40, cfg.height or 40)

	if cfg.placement == "outside" then
		-- Its own space beside the frame, so the bars keep the full width.
		if cfg.side == "RIGHT" then
			widget:SetPoint("LEFT", frame.content, "RIGHT", cfg.x or 0, cfg.y or 0)
		else
			widget:SetPoint("RIGHT", frame.content, "LEFT", -(cfg.x or 0), cfg.y or 0)
		end
	else
		widget:SetPoint(cfg.point or "LEFT", frame.content, cfg.relativePoint or "LEFT",
			cfg.x or 0, cfg.y or 0)
	end

	widget:SetAlpha(cfg.alpha or 1)
end

local function ensureModel(frame, el)
	if el.model then return el.model end

	local ok, model = pcall(CreateFrame, "PlayerModel", nil, frame.content)
	if not ok or not model then
		el.modelFailed = true
		return nil
	end

	-- Behind the bars, which sit at content level + 1.
	model:SetFrameLevel(frame.content:GetFrameLevel())
	model:Hide()
	el.model = model

	local cfg = frame.cfg and frame.cfg.portrait
	if cfg then place(frame, el, cfg, model) end

	return model
end

function element.Layout(frame, el, cfg)
	place(frame, el, cfg, el.texture)
	if el.model then place(frame, el, cfg, el.model) end

	local mode = cfg.mode or "none"
	if mode == "none" then
		el.texture:Hide()
		if el.model then el.model:Hide() end
	end

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

local function show2D(frame, el, cfg)
	local unit = frame.unit
	el.texture:Show()
	if el.model then el.model:Hide() end

	if unit and UnitExists(unit) and UnitIsVisible(unit)
		and Compat.SetPortraitTexture(el.texture, unit) then
		el.texture:SetTexCoord(0, 1, 0, 1)
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
		if el.model then el.model:Hide() end
		el.lastGUID = nil
		return
	end

	local unit = frame.unit
	if not unit or not UnitExists(unit) then
		el.texture:Hide()
		if el.model then el.model:Hide() end
		el.lastGUID = nil
		return
	end

	if mode == "3d" and not el.modelFailed then
		show3D(frame, el, cfg)
	else
		show2D(frame, el, cfg)
	end
end

function element.Disable(frame, el)
	el.texture:Hide()
	if el.model then el.model:Hide() end
	el.lastGUID = nil
end

--- Anchor target name for text elements that want to sit on the portrait.
function element.GetAnchorWidget(el, cfg)
	if cfg and cfg.mode == "3d" and el.model and el.model:IsShown() then
		return el.model
	end
	return el.texture
end

ns:RegisterElement("portrait", element)
