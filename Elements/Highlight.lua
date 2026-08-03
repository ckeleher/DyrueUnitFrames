-- Elements/Highlight.lua
--
-- Target and mouseover outlines. Four thin textures rather than a Blizzard
-- highlight template, for the same containment reason as everything else.

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors

local element = {
	order = 90,
	configKey = "highlight",
	events = {},
	globalEvents = { PLAYER_TARGET_CHANGED = true },
}

--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return cfg and (cfg.targetEnabled or cfg.mouseoverEnabled)
end

local function buildOutline(parent, level)
	local outline = { edges = {} }
	for i = 1, 4 do
		local texture = parent:CreateTexture(nil, "OVERLAY", nil, level)
		texture:Hide()
		outline.edges[i] = texture
	end
	return outline
end

local function placeOutline(outline, anchor, thickness)
	local top, bottom, left, right = outline.edges[1], outline.edges[2], outline.edges[3], outline.edges[4]

	top:ClearAllPoints()
	top:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
	top:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
	top:SetHeight(thickness)

	bottom:ClearAllPoints()
	bottom:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
	bottom:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
	bottom:SetHeight(thickness)

	left:ClearAllPoints()
	left:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -thickness)
	left:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, thickness)
	left:SetWidth(thickness)

	right:ClearAllPoints()
	right:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -thickness)
	right:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, thickness)
	right:SetWidth(thickness)
end

local function colorOutline(outline, r, g, b, a)
	for i = 1, 4 do
		outline.edges[i]:SetColorTexture(r, g, b, a)
	end
end

local function showOutline(outline, shown)
	for i = 1, 4 do
		outline.edges[i]:SetShown(shown)
	end
end

--------------------------------------------------------------------------------

function element.Build(frame)
	return {
		target = buildOutline(frame.overlay, 2),
		mouseover = buildOutline(frame.overlay, 3),
	}
end

function element.Layout(frame, el, cfg)
	local thickness = math.max(1, cfg.thickness or 1)
	placeOutline(el.target, frame.content, thickness)
	placeOutline(el.mouseover, frame.content, thickness)
	colorOutline(el.target, Colors:Unpack(cfg.targetColor))
	colorOutline(el.mouseover, Colors:Unpack(cfg.mouseoverColor))
end

function element.Update(frame, el, cfg)
	local unit = frame.unit
	local isTarget = cfg.targetEnabled and unit and UnitExists(unit)
		and UnitIsUnit(unit, "target") and not UnitIsUnit(unit, "player")
	showOutline(el.target, isTarget and true or false)

	local isMouseover = cfg.mouseoverEnabled and frame.mouseIsOver and true or false
	showOutline(el.mouseover, isMouseover)
end

function element.Disable(frame, el)
	showOutline(el.target, false)
	showOutline(el.mouseover, false)
end

ns:RegisterElement("highlight", element)
