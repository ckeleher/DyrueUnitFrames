-- Elements/Auras.lua
--
-- SPEC §4.5 / PLAN Phase 5.
--
-- Buffs and debuffs as two independent groups with their own size, grid,
-- anchor, growth, sorting, filtering and border policy.
--
-- Two Classic-specific truths shape this file:
--   * duration and expiration are only reported for auras YOU applied, so a
--     third party's debuff gets no swipe and no timer, never a fabricated one
--     (FR-5.8);
--   * player-sourced auras must be visually distinguished by size and
--     optionally by border color (FR-5.3) — that is an explicit brief
--     requirement, not a nicety.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Colors = ns.Colors
local Errors = ns.Errors
local CombatQueue = ns.CombatQueue

local element = {
	order = 70,
	configKey = "auras",
	events = { UNIT_AURA = true },
	globalEvents = {},
}

local GROUPS = { buffs = "HELPFUL", debuffs = "HARMFUL" }

--------------------------------------------------------------------------------
-- Duration ticker
--
-- Permitted ticker #2 (SPEC §5.7): runs at 0.1s only while at least one aura
-- with a known duration is displaying built-in duration text, and stops the
-- moment that stops being true.
--------------------------------------------------------------------------------

local durationTicker = nil
local timedButtons = {}
local timedCount = 0

local function formatDuration(remaining)
	if remaining >= 3600 then
		return string.format("%dh", math.floor(remaining / 3600 + 0.5))
	elseif remaining >= 60 then
		return string.format("%dm", math.floor(remaining / 60 + 0.5))
	elseif remaining >= 10 then
		return string.format("%d", math.floor(remaining))
	end
	return string.format("%.1f", remaining)
end

local function tickDurations()
	local now = GetTime()
	for button in pairs(timedButtons) do
		if button:IsShown() and button.expirationTime and button.expirationTime > 0 then
			local remaining = button.expirationTime - now
			if remaining > 0 then
				button.duration:SetText(formatDuration(remaining))
			else
				button.duration:SetText("")
			end
		end
	end
end

local function stopDurationTicker()
	if durationTicker then
		durationTicker:Cancel()
		durationTicker = nil
	end
end

local function refreshDurationTicker()
	if timedCount > 0 and not durationTicker then
		durationTicker = C_Timer.NewTicker(0.1, tickDurations)
	elseif timedCount == 0 then
		stopDurationTicker()
	end
end

local function trackDuration(button, track)
	if track and not timedButtons[button] then
		timedButtons[button] = true
		timedCount = timedCount + 1
	elseif not track and timedButtons[button] then
		timedButtons[button] = nil
		timedCount = timedCount - 1
	end
end

function element.IsTicking()
	return durationTicker ~= nil
end

--------------------------------------------------------------------------------
-- LibClassicDurations (SPEC §FR-5.8)
--
-- Optionally detected, never bundled, never a hard dependency. Anything it
-- provides is flagged as estimated.
--------------------------------------------------------------------------------

local classicDurations = nil
local classicDurationsChecked = false

local function getClassicDurations()
	if not classicDurationsChecked then
		classicDurationsChecked = true
		classicDurations = LibStub and LibStub("LibClassicDurations", true) or nil
		if classicDurations and classicDurations.RegisterFrame then
			pcall(classicDurations.Register, classicDurations, ADDON)
		end
	end
	return classicDurations
end

function element.HasClassicDurations()
	return getClassicDurations() ~= nil
end

--------------------------------------------------------------------------------
-- Filtering helpers
--------------------------------------------------------------------------------

local function inList(list, name, spellId)
	if type(list) ~= "table" then return false end
	for i = 1, #list do
		local entry = list[i]
		if entry then
			if entry == name then return true end
			if tonumber(entry) and tonumber(entry) == spellId then return true end
		end
	end
	return false
end

local function isOwn(aura, cfg)
	local source = aura.source
	if source == "player" or source == "vehicle" then return true end
	if cfg.countOwnPet and source == "pet" then return true end
	return false
end

local function passesFilter(aura, cfg, own)
	if cfg.onlyOwn and not own then return false end

	local permanent = (not aura.duration) or aura.duration == 0
	if cfg.hidePermanent and permanent then return false end
	if (cfg.minDuration or 0) > 0 and not permanent and aura.duration < cfg.minDuration then
		return false
	end

	if cfg.useWhitelist and not inList(cfg.whitelist, aura.name, aura.spellId) then
		return false
	end
	if cfg.useBlacklist and inList(cfg.blacklist, aura.name, aura.spellId) then
		return false
	end

	return true
end

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

local INFINITE = math.huge

local function expiryKey(entry)
	if not entry.expirationTime or entry.expirationTime == 0 then return INFINITE end
	return entry.expirationTime
end

--- A key that stays with an aura for as long as it is applied (Plan 14).
--
-- `entry.index` is NOT that. It is the client's slot number, and the slot
-- container reuses freed slots rather than re-packing, so an aura's index
-- changes when some *other* aura falls off. Using it as the tie-break meant the
-- visible order churned -- and on a target it was the whole order, not a
-- tie-break: FR-5.8 means every aura you did not apply reports expiration 0, so
-- expiryKey returns INFINITE for all of them and they all tie.
--
-- auraInstanceID is issued per application and is not reused while the aura
-- lives. The legacy UnitAura path has none (Compat.GetAura sets it nil), so
-- spellId carries the order there: stable per spell, ambiguous only between two
-- casts of the same spell from different sources -- where `index` is still the
-- last word, below.
local function orderKey(entry)
	return entry.auraInstanceID or entry.spellId or 0
end

-- Every comparator ends on `index` because it is the only key guaranteed unique
-- within a scan. An order function that reports two entries as equal in both
-- directions is fine; one that is inconsistent makes table.sort raise "invalid
-- order function for sorting" outright. A unique final key makes that
-- unreachable by construction.
local sorters = {
	own_time = function(a, b)
		if a.own ~= b.own then return a.own end
		local ea, eb = expiryKey(a), expiryKey(b)
		if ea ~= eb then return ea < eb end
		local ka, kb = orderKey(a), orderKey(b)
		if ka ~= kb then return ka < kb end
		return a.index < b.index
	end,
	time = function(a, b)
		local ea, eb = expiryKey(a), expiryKey(b)
		if ea ~= eb then return ea < eb end
		local ka, kb = orderKey(a), orderKey(b)
		if ka ~= kb then return ka < kb end
		return a.index < b.index
	end,
	name = function(a, b)
		-- Coalesce once. Comparing a.name ~= b.name and then (a.name or "") <
		-- (b.name or "") disagreed with itself for nil vs "": the first test
		-- said they differ, the second said neither sorts first.
		local na, nb = a.name or "", b.name or ""
		if na ~= nb then return na < nb end
		local ka, kb = orderKey(a), orderKey(b)
		if ka ~= kb then return ka < kb end
		return a.index < b.index
	end,
	-- Deliberately unchanged: this mode means "however the client reports them",
	-- which is exactly the unstable order the others now avoid. It is the escape
	-- hatch, and the option text says so.
	index = function(a, b) return a.index < b.index end,
}

--------------------------------------------------------------------------------
-- Button pool (PLAN task 5.3 — create and reuse; never create per update)
--------------------------------------------------------------------------------

local function createButton(group, index)
	local button = CreateFrame("Button", nil, group.frame)
	button:EnableMouse(true)
	-- Stable key so combat-queue de-duplication never builds strings per update.
	button.cancelKey = "auracancel:" .. group.id .. ":" .. index

	button.border = button:CreateTexture(nil, "BACKGROUND")
	button.border:SetAllPoints(button)

	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- A standard Cooldown frame so OmniCC attaches automatically (SPEC §7).
	-- Guarded: this is a Blizzard template, and a template that has moved or
	-- gone throws outright. A missing swipe is a cosmetic loss; an aura element
	-- that cannot display anything is not.
	local ok, cooldown = pcall(CreateFrame, "Cooldown", nil, button, "CooldownFrameTemplate")
	if ok and cooldown then
		button.cooldown = cooldown
		pcall(cooldown.SetAllPoints, cooldown, button.icon)
		pcall(cooldown.SetDrawEdge, cooldown, false)
	end

	button.count = ns:NewFontString(button, "OVERLAY")
	button.duration = ns:NewFontString(button, "OVERLAY")

	button:SetScript("OnEnter", function(self)
		local cfg = self.groupConfig
		if not cfg or not cfg.tooltips then return end
		if InCombatLockdown() and not cfg.tooltipsInCombat then return end
		if not self.unit or not self.auraIndex then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		local ok = pcall(GameTooltip.SetUnitAura, GameTooltip, self.unit, self.auraIndex, self.filter)
		if not ok then GameTooltip:Hide() return end
		if self.estimated then
			GameTooltip:AddLine("|cffffcc00" .. L["Duration estimated by LibClassicDurations"] .. "|r")
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	group.buttons[index] = button
	return button
end

local function getButton(group, index)
	return group.buttons[index] or createButton(group, index)
end

--------------------------------------------------------------------------------
-- Right-click cancel on the player's own buffs (SPEC §FR-5.9)
--
-- This is a protected action, so it goes through a secure button attribute
-- rather than a script handler. The overlay is a separate secure button so the
-- icon itself can stay insecure and therefore be shown, hidden and re-pointed
-- freely during combat, which aura display fundamentally requires.
--
-- Separate means SIBLING, not child. Parenting the overlay to the icon was the
-- original arrangement and it silently defeated the whole split: a frame that
-- owns a protected child cannot be moved, resized, shown or hidden in combat
-- either, so every aura update in combat had its SetSize, ClearAllPoints,
-- SetPoint and Show refused, and the player's buffs stopped re-laying-out for
-- the duration of the fight. The overlays live on frame.cancelLayer, which
-- exists for no other purpose and is never touched after creation (Plan 25).
--
-- Consequence, stated plainly: the overlay is protected, so both its geometry
-- and its attributes are routed through CombatQueue. While you are in combat
-- the overlays keep the position and the aura index they had when combat
-- started. Canceling a buff mid-fight may therefore cancel a neighboring one.
-- Out of combat it is exact.
--------------------------------------------------------------------------------

--- Build the secure overlay for one aura button, or give up on it.
--
-- Every step here is guarded, and a failure sets `cancelFailed` so this button
-- never retries. Right-click-cancel is a convenience; the aura display is not,
-- and the convenience must never be able to take the display down with it.
--
-- Nothing is attempted during combat. RegisterForClicks, SetAttribute and Hide
-- are all protected on a secure frame, so a buff gained mid-fight would
-- otherwise throw here on a freshly created overlay. Out of combat the next
-- aura update builds it.
local function ensureCancelOverlay(frame, button)
	if button.cancel then return button.cancel end
	if button.cancelFailed then return nil end
	if InCombatLockdown() then return nil end

	-- No cancel layer, no overlay. Never fall back to parenting on the button:
	-- that is the bug this function was rewritten to remove, and a silent
	-- fallback would reintroduce it on whatever path skipped the layer.
	local parent = frame.cancelLayer
	if not parent then
		button.cancelFailed = true
		return nil
	end

	local ok, overlay = pcall(CreateFrame, "Button", nil, parent, "SecureActionButtonTemplate")
	if not ok or not overlay then
		button.cancelFailed = true
		return nil
	end

	local configured = pcall(function()
		-- Anchored across parents, so it tracks the icon without being under
		-- it. Re-applied on every update through the queue, because the icon
		-- moves in combat and this frame cannot follow until combat ends.
		overlay:SetAllPoints(button)
		overlay:SetFrameLevel(button:GetFrameLevel() + 1)
		overlay:RegisterForClicks("RightButtonUp")
		overlay:SetAttribute("type2", "cancelaura")
		overlay:Hide()
		-- Forward hover to the icon so the tooltip still works through it.
		overlay:SetScript("OnEnter", function()
			local handler = button:GetScript("OnEnter")
			if handler then handler(button) end
		end)
		overlay:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end)

	if not configured then
		button.cancelFailed = true
		pcall(overlay.Hide, overlay)
		return nil
	end

	button.cancel = overlay
	return overlay
end

--- Hide one button's overlay, if it has one and it is showing.
--
-- Hiding the icon no longer hides the overlay -- they are siblings now -- so
-- every path that hides a button has to come through here or leave an
-- invisible click target behind. Hide is protected, hence the queue; the
-- IsShown check keeps the common case (every frame that is not the player's
-- buff group) from queueing anything at all.
local function hideCancelOverlay(button)
	local overlay = button.cancel
	if not overlay or not overlay:IsShown() then return end
	CombatQueue:Run(button.cancelKey, function() overlay:Hide() end)
end

local function updateCancelOverlay(button, frame, cfg, filter, auraIndex, own, auraName)
	local wanted = own and filter == "HELPFUL" and frame.unitKey == "player"

	if not wanted then
		hideCancelOverlay(button)
		return
	end

	local overlay = ensureCancelOverlay(frame, button)
	if not overlay then return end

	CombatQueue:Run(button.cancelKey, function()
		-- Same reasoning as ensureCancelOverlay: if this fails, lose the
		-- overlay for this button, not the aura display.
		local ok = pcall(function()
			-- The icon may have changed size or cell since this was queued.
			overlay:SetAllPoints(button)
			overlay:SetAttribute("unit", "player")
			overlay:SetAttribute("index", auraIndex)
			overlay:SetAttribute("filter", filter)
			-- Both forms, because it is not established which one this client's
			-- cancelaura handler reads. OPie -- which works here -- drives it
			-- with `spell` alone; this addon has only ever set index+filter and
			-- has never been observed to cancel anything. Setting both is a
			-- superset, not a guess: whichever the handler looks at first is
			-- correct, and the probe records which API actually gets called.
			overlay:SetAttribute("spell", auraName)
			overlay:Show()
		end)
		if not ok then
			button.cancelFailed = true
			pcall(overlay.Hide, overlay)
		end
	end)
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

--- Fill `group.list` with the auras that survive filtering, sorted.
--
-- Entry tables come from a per-group pool rather than being created fresh.
-- UNIT_AURA fires constantly in combat and allocating thirty-two tables per
-- event per frame is exactly the kind of quiet cost the §6 memory budget is
-- there to prevent.
local function scan(frame, group, cfg, filter)
	local list, pool = group.list, group.entryPool
	for i = #list, 1, -1 do list[i] = nil end

	local unit = frame.unit
	if not unit or not UnitExists(unit) then return list end

	local maxScan = math.max(cfg.maxShown or 32, 40)
	local lib = ns:General().useClassicDurations and getClassicDurations() or nil
	local count = 0

	for index = 1, maxScan do
		local aura = Compat.GetAura(unit, index, filter)
		if not aura then break end

		local own = isOwn(aura, cfg)
		if passesFilter(aura, cfg, own) then
			local duration, expirationTime, estimated =
				aura.duration, aura.expirationTime, false

			-- FR-5.8: a third party's aura reports nothing in Classic. Only
			-- LibClassicDurations can fill that in, and only as an estimate.
			if (not duration or duration == 0) and lib and aura.spellId then
				local ok, libDuration, libExpiration =
					pcall(lib.GetAuraDurationByUnit, lib, unit, aura.spellId, nil, aura.name)
				-- The expiration is required, not optional. A duration with no
				-- expiration still sorts as INFINITE, so the aura would land
				-- back among the unordered ones while looking timed to
				-- everything else that reads `duration`.
				if ok and libDuration and libDuration > 0
					and libExpiration and libExpiration > 0 then
					duration, expirationTime, estimated = libDuration, libExpiration, true
				end
			end

			count = count + 1
			local entry = pool[count]
			if not entry then
				entry = {}
				pool[count] = entry
			end

			entry.index = index
			entry.name = aura.name
			entry.icon = aura.icon
			entry.count = aura.count
			entry.dispelType = aura.dispelType
			entry.duration = duration
			entry.expirationTime = expirationTime
			entry.estimated = estimated
			entry.own = own
			entry.spellId = aura.spellId
			-- Assigned unconditionally, nil included: the entry tables are
			-- pooled, and a stale instance ID left behind by a previous scan
			-- would order this aura as if it were the one that vacated the slot.
			entry.auraInstanceID = aura.auraInstanceID

			list[count] = entry
		end
	end

	local sorter = sorters[cfg.sort or "own_time"] or sorters.own_time
	table.sort(list, sorter)

	return list
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function groupAnchorWidget(frame, el, key, selfKey)
	local elements = frame.elements
	if key == "health" and elements.health then return elements.health.bar end
	if key == "power" and elements.power then return elements.power.bar end

	if key == "buffs" or key == "debuffs" then
		-- Refuse a self-anchor and refuse a mutual anchor: buffs -> debuffs ->
		-- buffs would be a SetPoint loop and the client would error on it.
		if key == selfKey then return frame.content end
		local other = frame.cfg.auras[key]
		if other and other.anchorTo == selfKey then return frame.content end
		if el[key] then return el[key].frame end
	end

	return frame.content
end

local function layoutGroup(frame, el, group, cfg, name)
	local size = cfg.size or 20
	local perRow = math.max(1, cfg.perRow or 8)
	local rows = math.max(1, cfg.rows or 2)

	group.frame:SetSize(
		perRow * size + (perRow - 1) * (cfg.spacingX or 0),
		rows * size + (rows - 1) * (cfg.spacingY or 0))

	group.frame:SetFrameLevel(ns:Level(frame, "AURAS"))
	group.frame:ClearAllPoints()
	local widget = groupAnchorWidget(frame, el, cfg.anchorTo, name)
	group.frame:SetPoint(cfg.point or "BOTTOMLEFT", widget, cfg.relativePoint or "TOPLEFT",
		cfg.x or 0, cfg.y or 0)

	group.frame:SetShown(cfg.enabled and true or false)

	-- Cells are laid out on the BASE size so rows stay aligned even when own
	-- auras are scaled up; the larger button simply overflows its cell,
	-- centered (FR-5.3).
	group.cells = group.cells or {}
	local cells = group.cells
	for i = #cells, 1, -1 do cells[i] = nil end

	for row = 1, rows do
		for col = 1, perRow do
			local c = (cfg.growthX == "LEFT") and (perRow + 1 - col) or col
			local r = (cfg.growthY == "UP") and (rows + 1 - row) or row
			cells[#cells + 1] = {
				x = (c - 0.5) * size + (c - 1) * (cfg.spacingX or 0),
				y = -((r - 0.5) * size + (r - 1) * (cfg.spacingY or 0)),
			}
		end
	end

	group.dirty = true
end

--------------------------------------------------------------------------------
-- Text placement
--
-- Both numeric overlays -- the duration timer and the stack count -- are placed
-- by one rule, because they compete for the same 20 pixels and configuring them
-- differently would be arbitrary.
--
-- The old code placed them by two hardcoded rules, and one of them was wrong:
-- the stack count used a fixed (-1, 1) inset, which points *inward* only when
-- the anchor happens to be BOTTOMRIGHT. Choosing TOPLEFT from the corner
-- dropdown pushed the text left and up, clear off the icon. The signed table
-- below is that bug's fix -- a positive inset moves toward the middle from any
-- of the nine points.
--------------------------------------------------------------------------------

local TEXT_INSET = {
	TOPLEFT     = {  1, -1 }, TOP    = { 0, -1 }, TOPRIGHT    = { -1, -1 },
	LEFT        = {  1,  0 }, CENTER = { 0,  0 }, RIGHT       = { -1,  0 },
	BOTTOMLEFT  = {  1,  1 }, BOTTOM = { 0,  1 }, BOTTOMRIGHT = { -1,  1 },
}

--- Position one aura overlay on its button.
--
-- `anchor` is one of the nine points, or ABOVE / BELOW for the two placements
-- that sit outside the icon and leave the art alone. BELOW is what the duration
-- text did before it was configurable, so a profile that liked it keeps it.
--
-- dx/dy are plain screen-space nudges on top of the 1px inset, deliberately not
-- mirrored per anchor: a slider that moves text right moves it right everywhere.
local function placeAuraText(fontString, button, anchor, dx, dy)
	dx, dy = dx or 0, dy or 0
	fontString:ClearAllPoints()

	if anchor == "ABOVE" then
		fontString:SetPoint("BOTTOM", button, "TOP", dx, dy + 1)
		return
	elseif anchor == "BELOW" then
		fontString:SetPoint("TOP", button, "BOTTOM", dx, dy - 1)
		return
	end

	local point = TEXT_INSET[anchor] and anchor or "BOTTOMRIGHT"
	local inset = TEXT_INSET[point]
	fontString:SetPoint(point, button, point, inset[1] + dx, inset[2] + dy)
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local function applyButton(frame, group, cfg, button, entry, cell, filter)
	local size = cfg.size or 20
	local buttonSize = entry.own and size * (cfg.ownSizeMultiplier or 1) or size
	local borderSize = math.max(1, math.floor(buttonSize * 0.08 + 0.5))

	button:SetSize(buttonSize, buttonSize)
	button:ClearAllPoints()
	button:SetPoint("CENTER", group.frame, "TOPLEFT", cell.x, cell.y)

	button.icon:ClearAllPoints()
	button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", borderSize, -borderSize)
	button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -borderSize, borderSize)
	button.icon:SetTexture(entry.icon)
	button.icon:SetDesaturated((cfg.desaturateOthers and not entry.own) and true or false)

	-- Border policy (FR-5.3 / FR-5.4). Own-source and debuff-type coloring
	-- are mutually exclusive per group; the user picks which wins.
	local mode = cfg.borderMode or "own"
	local r, g, b, a
	if mode == "own" and entry.own then
		r, g, b, a = Colors:Unpack(cfg.ownBorderColor)
	elseif mode == "type" then
		r, g, b = Compat.GetDebuffTypeColor(entry.dispelType)
		if not r then r, g, b, a = Colors:Unpack(cfg.defaultBorderColor) end
		a = a or 1
	end
	if not r then r, g, b, a = Colors:Unpack(cfg.defaultBorderColor) end
	button.border:SetColorTexture(r, g, b, a or 1)
	button.border:SetShown(mode ~= "none")

	-- Cooldown. Unknown duration means no swipe and no timer, ever: a fake one
	-- is worse than none (FR-5.8).
	local known = entry.duration and entry.duration > 0 and entry.expirationTime
	if button.cooldown then
		if cfg.showCooldown and known then
			button.cooldown:Show()
			button.cooldown:SetCooldown(entry.expirationTime - entry.duration, entry.duration)
		else
			button.cooldown:Hide()
			pcall(button.cooldown.Clear, button.cooldown)
		end
	end

	-- Built-in duration text, for users without OmniCC.
	button.expirationTime = known and entry.expirationTime or nil
	if cfg.showDurationText and known then
		ns:SetFont(button.duration, cfg.durationFont, cfg.durationSize, cfg.durationOutline, true)
		placeAuraText(button.duration, button, cfg.durationAnchor, cfg.durationX, cfg.durationY)
		button.duration:Show()
		trackDuration(button, true)
	else
		button.duration:SetText("")
		button.duration:Hide()
		trackDuration(button, false)
	end

	if cfg.showStacks and (entry.count or 0) > 1 then
		ns:SetFont(button.count, cfg.stackFont, cfg.stackSize, cfg.stackOutline, true)
		placeAuraText(button.count, button, cfg.stackCorner, cfg.stackX, cfg.stackY)
		button.count:SetText(entry.count)
		button.count:Show()
	else
		button.count:Hide()
	end

	button.unit = frame.unit
	button.auraIndex = entry.index
	button.filter = filter
	button.estimated = entry.estimated
	button.groupConfig = cfg

	updateCancelOverlay(button, frame, cfg, filter, entry.index, entry.own, entry.name)

	button:Show()
end

local function updateGroup(frame, el, group, cfg, filter)
	if not cfg.enabled then
		group.frame:Hide()
		for i = 1, #group.buttons do
			local button = group.buttons[i]
			button:Hide()
			trackDuration(button, false)
			hideCancelOverlay(button)
		end
		refreshDurationTicker()
		return
	end

	group.frame:Show()

	local list = scan(frame, group, cfg, filter)
	local cells = group.cells or {}
	local maxShown = math.min(cfg.maxShown or 32, #cells)
	local shown = math.min(#list, maxShown)

	for i = 1, shown do
		applyButton(frame, group, cfg, getButton(group, i), list[i], cells[i], filter)
	end

	for i = shown + 1, #group.buttons do
		local button = group.buttons[i]
		button:Hide()
		trackDuration(button, false)
		-- Was building "auracancel-hide:" .. tostring(button) here, per unused
		-- button, per UNIT_AURA. The helper uses the button's own stable key.
		hideCancelOverlay(button)
	end

	refreshDurationTicker()
end

--------------------------------------------------------------------------------
-- Element interface
--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	if type(cfg) ~= "table" then return false end
	return (cfg.buffs and cfg.buffs.enabled) or (cfg.debuffs and cfg.debuffs.enabled) or false
end

function element.Build(frame)
	local el = {}
	for name in pairs(GROUPS) do
		el[name] = {
			id = frame.unitKey .. ":" .. name,
			frame = CreateFrame("Frame", nil, frame.content),
			buttons = {},
			list = {},
			entryPool = {},
			cells = {},
		}
		el[name].frame:SetFrameLevel(ns:Level(frame, "AURAS"))
	end
	return el
end

function element.Layout(frame, el, cfg)
	for name in pairs(GROUPS) do
		layoutGroup(frame, el, el[name], cfg[name], name)
	end
end

function element.Update(frame, el, cfg, event, unit, updateInfo)
	-- SPEC §5.7: use the incremental payload where it exists. We use it to skip
	-- work entirely, not to maintain a parallel aura store — a full rescan of
	-- 16 debuffs is cheap, and the bookkeeping a true incremental path needs is
	-- a bug surface that buys nothing measurable at Classic's aura counts.
	if event == "UNIT_AURA" and type(updateInfo) == "table" then
		Compat.NoteIncrementalAuraUpdate()
		if not updateInfo.isFullUpdate
			and not updateInfo.addedAuras
			and not updateInfo.removedAuraInstanceIDs
			and not updateInfo.updatedAuraInstanceIDs then
			return
		end
	end

	for name, filter in pairs(GROUPS) do
		updateGroup(frame, el, el[name], cfg[name], filter)
	end
end

function element.Disable(frame, el)
	for name in pairs(GROUPS) do
		local group = el[name]
		group.frame:Hide()
		for i = 1, #group.buttons do
			local button = group.buttons[i]
			button:Hide()
			trackDuration(button, false)
			hideCancelOverlay(button)
		end
	end
	refreshDurationTicker()
end

ns:RegisterElement("auras", element)
