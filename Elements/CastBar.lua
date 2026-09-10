-- Elements/CastBar.lua
--
-- Plan 30. `SPEC.md` §2.3 deferred this to v1.x and `PLAN.md` §14 made it
-- backlog item 2, with the note that it "shares no systems with anything else,
-- so it costs the same later as now". That was true of the bar and false of the
-- frame; making it independently movable is Plan 31. This is the bar.
--
-- Built from primitives like every other element, and unit-agnostic like every
-- other element: nothing below knows or cares that only the player ships with
-- it turned on, which is what lets Plans 32 and 33 be table entries.
--
--------------------------------------------------------------------------------
-- THE DRIVER, AND WHY IT IS NOT A FIFTH TICKER
--
-- §5.7 lists three permitted tickers and says a fourth is a design smell to be
-- argued for explicitly. Systems/BarSweep spent that argument. This is not the
-- next one in the sequence:
--
--   * It polls nothing. A ticker exists to sample a value the game will not
--     push. Here the start and end times are known exactly, from an event,
--     before the first frame is drawn -- the driver interpolates between two
--     known numbers and asks the game nothing.
--
--   * It is a hidden frame, not a timer. A hidden frame's OnUpdate does not
--     run, so Show/Hide IS the start/stop and there is no timer object to
--     cancel or leak. With nothing casting the cost is zero, and `/duf profile`
--     reports both the running state and the attached count so that claim is
--     checkable rather than asserted.
--
--   * One driver serves every cast bar, started by the first bar becoming
--     active and stopped by the last one finishing -- the rule §FR-8.3 sets for
--     the derived poller. This is why Plans 32 and 33 add no driver cost.
--
--------------------------------------------------------------------------------
-- WHAT THE MEASUREMENT CHANGED
--
-- /dufprobe cast, 1 September 2026, five runs across both clients. Four
-- findings in Documents/COMPAT_FINDINGS.md are load-bearing here, and each one
-- is a bug this file would otherwise contain:
--
--   1. A channel's UNIT_SPELLCAST_SUCCEEDED fires at its START, at the same
--      timestamp as CHANNEL_START. Clearing on SUCCEEDED unconditionally --
--      the obvious implementation -- blanks every channel the instant it
--      begins. So SUCCEEDED only clears a non-channel.
--
--   2. UNIT_SPELLCAST_INTERRUPTED fires FOUR times per interrupt, and does not
--      order stably against STOP: Era put INTERRUPTED first every time, one
--      Anniversary run put STOP first. Ending is therefore idempotent, and no
--      handler may assume it is the first to arrive.
--
--   3. Clipping a channel raises CHANNEL_STOP, not CHANNEL_UPDATE.
--      CHANNEL_UPDATE never fired in five runs. It stays wired to the re-read
--      path with DELAYED -- that is right whatever raises it -- but it is not
--      the clipping signal and nothing here waits for it.
--
--   4. Instants raise no start event at all, so they need no suppressing. One
--      of the observed instants was a Regrowth, made instant by Nature's
--      Swiftness -- which is why "is this instant" is answered by the absence
--      of a start event and never by the spell.

local ADDON, ns = ...
local L = ns.L
local Colors = ns.Colors
local Compat = ns.Compat

local element = {
	order = 40,
	configKey = "cast",
	events = {
		UNIT_SPELLCAST_START = true,
		UNIT_SPELLCAST_STOP = true,
		UNIT_SPELLCAST_DELAYED = true,
		UNIT_SPELLCAST_INTERRUPTED = true,
		UNIT_SPELLCAST_FAILED = true,
		UNIT_SPELLCAST_SUCCEEDED = true,
		UNIT_SPELLCAST_CHANNEL_START = true,
		UNIT_SPELLCAST_CHANNEL_UPDATE = true,
		UNIT_SPELLCAST_CHANNEL_STOP = true,
	},
	globalEvents = {},
}

--------------------------------------------------------------------------------
-- The driver
--
-- Deliberately the same shape as Systems/BarSweep's, down to the names. Two
-- files doing the identical thing by the identical mechanism should look
-- identical; the alternative -- extracting a shared module -- would amount to
-- sharing a Show and a Hide, since what the two DO per frame has nothing in
-- common.
--------------------------------------------------------------------------------

local active = {}          -- el -> frame
local activeCount = 0
local driver = nil
local running = false

local function render()
	local now = GetTime()
	for el, frame in pairs(active) do
		element.Render(frame, el, now)
	end
end

local function stop()
	if not running then return end
	if driver then driver:Hide() end
	running = false
end

local function start()
	if running then return end
	if not driver then
		driver = CreateFrame("Frame")
		driver:Hide()
		driver:SetScript("OnUpdate", render)
	end
	driver:Show()
	running = true
end

local function attach(frame, el)
	if active[el] then return end
	active[el] = frame
	activeCount = activeCount + 1
	start()
end

local function detach(el)
	if not active[el] then return end
	active[el] = nil
	activeCount = activeCount - 1
	if activeCount <= 0 then
		activeCount = 0
		stop()
	end
end

--- For /duf profile. The §5.7 argument above is only worth anything if it can
-- be checked, and this is what checks it.
function element.DriverStats()
	return running, activeCount
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function barColor(el, cfg)
	if el.state == "failed" then return cfg.failedColor end
	-- notInterruptible is a tri-state and reads nil on these clients; only a
	-- literal true means the cast cannot be interrupted.
	if el.notInterruptible == true then return cfg.uninterruptibleColor end
	if el.channel then return cfg.channelColor end
	return cfg.color
end

local function applyColor(el, cfg)
	local r, g, b = Colors:Unpack(barColor(el, cfg))
	r, g, b = Colors:Brighten(r, g, b, cfg.brightness)
	el.bar:SetStatusBarColor(r, g, b)

	local br, bg, bb, ba = Colors:Background(r, g, b, cfg.bgMultiplier, cfg.bgAlpha)
	el.bg:SetVertexColor(br, bg, bb, ba)
end

--- Format the seconds readout. Deliberately not a tag: this string changes
-- every frame, and Systems/Tags is built on caching the rendered string per
-- element and skipping SetText when it has not changed. A tag that never
-- matches its cache defeats that mechanism for every other tag on the frame.
local function timeString(cfg, remaining, total)
	local decimals = cfg.timeText.decimals or 1
	if cfg.timeText.showTotal then
		return string.format("%." .. decimals .. "f / %." .. decimals .. "f",
			remaining, total)
	end
	return string.format("%." .. decimals .. "f", remaining)
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------

--- Take the bar down. Idempotent by construction, because finding 2 means it is
-- called up to five times for one interrupted cast, in either order against
-- STOP, and any of those may be the first to arrive.
local function clear(frame, el)
	detach(el)
	el.casting = false
	el.state = nil
	-- When the cast stopped, so that an INTERRUPTED arriving just after a STOP
	-- can still tell the difference between the cast it just ended and a stray
	-- event about something long gone. See fail() below.
	el.endedAt = GetTime()
	el.bar:Hide()
end

-- How long after a cast ends an INTERRUPTED still counts as being about it.
--
-- Measured, both clients: STOP and the first INTERRUPTED arrive at the SAME
-- timestamp, and the three repeats 0.15 s later. So this only has to be wide
-- enough to survive a frame boundary landing between two events that the game
-- sent together -- it is not a guess at how late an event might be.
local RECENTLY_ENDED = 0.1

--- A cast that ended badly holds briefly in the failure color rather than
-- vanishing, so a fumbled cast is visible at all. The hold is driven by the
-- driver rather than by C_Timer: it is already running, it stops when the hold
-- expires, and a timer here would be a real fifth ticker.
--
-- Finding 2 is what shapes this. One interrupt produces four INTERRUPTED events
-- and a STOP, in either order depending on the client, so:
--
--   * a repeat must not restart the hold, which is the state check; and
--   * STOP arriving FIRST must not swallow the interrupt. It clears the bar, so
--     a guard of `if not el.casting then return end` -- the obvious one, and the
--     one this shipped with for an hour -- means an interrupted cast simply
--     vanishes on whichever client sends STOP first. The suite caught it in the
--     ordering test written from the measurement, before it ever ran in game.
local function fail(frame, el, cfg)
	if el.state == "failed" then return end

	local now = GetTime()
	local recentlyEnded = el.endedAt and (now - el.endedAt) <= RECENTLY_ENDED
	if not el.casting and not recentlyEnded then return end

	el.casting = false
	el.state = "failed"
	el.holdUntil = now + (cfg.holdTime or 0.5)

	if (cfg.holdTime or 0.5) <= 0 then
		clear(frame, el)
		return
	end

	applyColor(el, cfg)
	-- A drained channel and a filled cast both end at their own "finished" end.
	el.bar:SetValue(el.channel and 0 or 1)
	if el.timeText then el.timeText:SetText("") end
	-- Show explicitly: STOP may already have hidden the bar.
	el.bar:Show()
	attach(frame, el)
end

--- Read whatever the unit is casting right now and put it on the bar.
-- Used both by the start events and by a full update, which is what picks up a
-- cast already in progress -- the case a start event cannot cover and the one
-- that matters for every unit Plans 32 and 33 add.
local function acquire(frame, el, cfg)
	local unit = frame.unit
	if not unit then return clear(frame, el) end

	-- Position 1, never position 2: for a channel, position 2 is the literal
	-- string "Channeling" rather than the spell's name (measured, both clients).
	local name, icon, startTime, endTime, isChannel, notInterruptible =
		Compat.GetCastInfo(unit)
	if not name then return clear(frame, el) end

	el.casting = true
	el.state = nil
	el.channel = isChannel and true or false
	el.notInterruptible = notInterruptible
	el.startTime = startTime
	el.endTime = endTime
	el.holdUntil = nil

	el.bar:SetMinMaxValues(0, 1)
	applyColor(el, cfg)

	if el.spellText then
		el.spellText:SetText(cfg.spellText.enabled and name or "")
	end
	if el.icon then
		el.icon:SetTexture(icon)
		el.icon:SetShown(cfg.icon.enabled and icon ~= nil)
	end

	el.bar:Show()
	attach(frame, el)
	element.Render(frame, el, GetTime())
end

--------------------------------------------------------------------------------
-- Per-frame render
--------------------------------------------------------------------------------

--- Called by the driver for every attached bar. Allocation-free.
function element.Render(frame, el, now)
	local cfg = frame.cfg and frame.cfg.cast
	if not cfg then return detach(el) end

	if el.state == "failed" then
		if not el.holdUntil or now >= el.holdUntil then
			clear(frame, el)
		end
		return
	end

	if not el.casting or not el.endTime or not el.startTime then
		return detach(el)
	end

	local total = el.endTime - el.startTime
	if total <= 0 then return clear(frame, el) end

	local remaining = el.endTime - now
	if remaining <= 0 then
		-- The end arrived before the event did. Finish the bar rather than
		-- leaving it stuck at 99%; the event will clear it a frame later.
		remaining = 0
	end

	local elapsed = total - remaining
	-- A channel drains. Same two numbers, read the other way round.
	el.bar:SetValue(el.channel and (remaining / total) or (elapsed / total))

	if el.timeText and cfg.timeText.enabled then
		el.timeText:SetText(timeString(cfg, remaining, total))
	end
end

--------------------------------------------------------------------------------
-- Element contract
--------------------------------------------------------------------------------

function element.IsEnabled(frame, cfg)
	return cfg and cfg.enabled == true
end

function element.Build(frame)
	local el = {}

	el.bar = CreateFrame("StatusBar", nil, frame.content)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))
	el.bar:Hide()

	el.bg = el.bar:CreateTexture(nil, "BACKGROUND")
	el.bg:SetAllPoints(el.bar)

	el.icon = el.bar:CreateTexture(nil, "ARTWORK")

	-- Above the fill, for the same reason Core/Core.lua's LEVELS scheme exists:
	-- a child frame outranks every draw layer of its parent, and the fill is a
	-- child frame. frame.overlay is already at the right level.
	el.spellText = ns:NewFontString(frame.overlay, "OVERLAY")
	el.timeText = ns:NewFontString(frame.overlay, "OVERLAY")

	el.casting = false

	return el
end

--- Geometry and appearance. Unlike health/power/mana this element places
-- itself, rather than being handed a slot by Factory's LayoutBars: it is not
-- part of the bar stack, it can sit outside the frame, and Plan 31 will give it
-- a frame of its own. That makes it the Indicators pattern, not the HealthBar
-- pattern, and it means this plan touches Units/Factory.lua not at all.
function element.Layout(frame, el, cfg)
	local texture = ns:Texture(cfg.texture)
	el.bar:SetStatusBarTexture(texture)
	el.bg:SetTexture(texture)
	el.bar:SetFrameLevel(ns:Level(frame, "BARS"))

	local widget, available = ns:AnchorWidget(frame, cfg.anchorTo)
	if not available then
		-- Anchored to a bar that is not showing. Hide rather than dropping the
		-- cast bar onto the frame body on top of whatever is already there --
		-- the same rule bar-anchored text and the indicator row follow.
		el.bar:Hide()
		el.anchorMissing = true
		return
	end
	el.anchorMissing = nil

	local width = (cfg.widthMode == "custom" and (cfg.width or 0) > 0)
		and cfg.width
		or (widget:GetWidth() > 0 and widget:GetWidth() or (frame.cfg.width or 100))

	el.bar:ClearAllPoints()
	el.bar:SetPoint(cfg.point or "TOPLEFT", widget, cfg.relativePoint or "BOTTOMLEFT",
		cfg.x or 0, cfg.y or 0)
	el.bar:SetSize(math.max(width, 1), math.max(cfg.height or 18, 1))

	-- The icon is square on the bar's height and takes its width out of the
	-- text's room, the same way the portrait's column inset does on the frame.
	local iconSize = (cfg.icon.size or 0) > 0 and cfg.icon.size or (cfg.height or 18)
	local onLeft = (cfg.icon.side or "LEFT") ~= "RIGHT"
	el.icon:ClearAllPoints()
	el.icon:SetPoint(onLeft and "RIGHT" or "LEFT", el.bar,
		onLeft and "LEFT" or "RIGHT", onLeft and -(cfg.icon.gap or 2) or (cfg.icon.gap or 2), 0)
	el.icon:SetSize(iconSize, iconSize)
	el.icon:SetShown(cfg.icon.enabled and el.casting)

	local function place(fontString, block, defaultPoint, defaultX)
		ns:SetFont(fontString, block.font, block.size, block.outline, block.shadow)
		fontString:SetTextColor(Colors:Unpack(block.color))
		fontString:ClearAllPoints()
		fontString:SetPoint(block.point or defaultPoint, el.bar,
			block.point or defaultPoint, block.x or defaultX, block.y or 0)
		fontString:SetShown(block.enabled ~= false)
	end

	place(el.spellText, cfg.spellText, "LEFT", 4)
	place(el.timeText, cfg.timeText, "RIGHT", -4)

	el.bar:SetShown(element.IsEnabled(frame, cfg) and el.casting)
end

--- Every event re-reads the unit rather than trusting its payload.
--
-- The payload carries a castGUID that could be matched against, and matching is
-- what would be needed if the bar tracked casts it could not otherwise see. It
-- cannot help here: UnitCastingInfo IS the state, a stale event about a cast
-- that has already ended reads back as "nothing casting", and CHANNEL_START
-- sends nil in the castGUID slot anyway (measured). Re-reading is both simpler
-- and more correct than bookkeeping.
function element.Update(frame, el, cfg, event)
	if el.anchorMissing then return end

	if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
		or event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE"
	then
		-- Start and re-read are the same operation. DELAYED is pushback and
		-- CHANNEL_UPDATE is whatever raises it -- both mean the window moved,
		-- and acquire() reads the window fresh, so neither needs its own path.
		return acquire(frame, el, cfg)
	end

	if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
		return fail(frame, el, cfg)
	end

	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Finding 1. A channel's SUCCEEDED arrives at its START, so this event
		-- says nothing about a channel ending and must not clear one.
		if el.channel and el.casting then return end
		return clear(frame, el)
	end

	if event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		-- Finding 2. STOP may arrive before or after INTERRUPTED depending on
		-- the client, so it must not overwrite a failure that is already being
		-- held -- and it must still work when it arrives first.
		if el.state == "failed" then return end
		return clear(frame, el)
	end

	-- Anything else is a full update: a config change, a frame becoming
	-- visible, or a unit whose identity changed underneath us. Read the truth.
	acquire(frame, el, cfg)
end

function element.Disable(frame, el)
	detach(el)
	el.casting = false
	el.bar:Hide()
	el.spellText:Hide()
	el.timeText:Hide()
	el.icon:Hide()
end

ns:RegisterElement("cast", element)
