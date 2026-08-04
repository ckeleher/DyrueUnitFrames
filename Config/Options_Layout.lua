-- Config/Options_Layout.lua
--
-- Per-unit layout and appearance (PLAN tasks 2.3, 2.4, 3.2, 3.3, 3.5, 3.9).
--
-- Every position and size value here is a `range` control, which AceConfig
-- renders as a slider plus an exact numeric entry box writing to the same
-- stored number. That is the literal requirement in SPEC §FR-1.2, and drag
-- mode writes to these same values so all three input methods agree.

local ADDON, ns = ...
local L = ns.L
local Compat = ns.Compat
local Registry = ns.Registry
local Options = ns.Options

local LSM = LibStub("LibSharedMedia-3.0")

--------------------------------------------------------------------------------

local POWER_TOKENS = {
	MANA = L["Mana"],
	RAGE = L["Rage"],
	ENERGY = L["Energy"],
	FOCUS = L["Focus (pet)"],
	HAPPINESS = L["Happiness"],
}

local function textureOption(name, order, getTable, apply)
	return {
		type = "select", order = order, name = name,
		dialogControl = "LSM30_Statusbar",
		values = function() return LSM:HashTable("statusbar") end,
		get = function() return getTable().texture end,
		set = function(_, v) getTable().texture = v; apply() end,
	}
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function layoutGroup(def)
	local unitKey = def.key
	local function cfg() return ns:UnitConfig(unitKey) end
	local function anchor() local c = cfg(); return c and c.anchor end
	local function background() local c = cfg(); return c and c.background end
	local function border() local c = cfg(); return c and c.border end
	local apply = Options.ApplyLayout(unitKey)

	local isPartyMember = (def.group == "party")
	local function groupOwned()
		return isPartyMember and ns.PartyGroup:Owns(unitKey)
	end
	local function sizeLocked()
		return groupOwned() and ns:Profile().partyGroup.overrideSize
	end

	local sizeArgs = {
		width = Options.Range(L["Width"], 1, "width", cfg, "width", apply, { disabled = sizeLocked }),
		height = Options.Range(L["Height"], 2, "height", cfg, "height", apply, { disabled = sizeLocked }),
		scale = Options.Range(L["Scale"], 3, "scale", cfg, "scale", apply),
		alpha = {
			type = "range", order = 4, name = L["Opacity"],
			min = 0.1, max = 1, step = 0.01,
			get = function() return cfg().alpha end,
			set = function(_, v) cfg().alpha = v; apply() end,
		},
		strata = {
			type = "select", order = 5, name = L["Frame strata"],
			values = Options.STRATA,
			get = function() return cfg().strata end,
			set = function(_, v) cfg().strata = v; apply() end,
		},
	}

	local positionArgs = {
		groupNote = {
			type = "description", order = 0,
			hidden = function() return not groupOwned() end,
			name = L["|cffffcc00This frame is positioned by the party group layout.|r Turn on 'Detach from the group' to position it individually."],
		},
		detached = {
			type = "toggle", order = 1, name = L["Detach from the group"],
			hidden = function() return not isPartyMember end,
			get = function() return cfg().detached end,
			set = function(_, v) cfg().detached = v; ns.PartyGroup:Apply(); apply() end,
		},
		anchorTo = {
			type = "select", order = 2, name = L["Anchor to"],
			desc = L["Moving the anchor moves this frame with it. Loops are rejected with a message."],
			disabled = groupOwned,
			values = function() return ns.Anchoring:TargetValues(unitKey) end,
			get = function() return anchor().to end,
			set = function(_, v)
				if ns.Anchoring:SetTarget(unitKey, v) then apply() end
			end,
		},
		point = {
			type = "select", order = 3, name = L["Point on this frame"],
			disabled = groupOwned,
			values = ns.Anchoring:PointValues(),
			get = function() return anchor().point end,
			set = function(_, v) anchor().point = v; apply() end,
		},
		relativePoint = {
			type = "select", order = 4, name = L["Point on the anchor"],
			disabled = groupOwned,
			values = ns.Anchoring:PointValues(),
			get = function() return anchor().relativePoint end,
			set = function(_, v) anchor().relativePoint = v; apply() end,
		},
		x = Options.Range(L["X offset"], 5, "offset", anchor, "x", apply, { disabled = groupOwned }),
		y = Options.Range(L["Y offset"], 6, "offset", anchor, "y", apply, { disabled = groupOwned }),
	}

	local backgroundArgs = {
		note = {
			type = "description", order = 0,
			name = L["Fills the whole frame, behind the bars. With the default layout the bars cover the frame exactly, so this only shows if you give a bar a fixed height and leave a gap. Note that it sits behind the bar backgrounds, so turning it on will mask their opacity settings."],
		},
		enabled = {
			type = "toggle", order = 1, name = L["Enable"],
			get = function() return background().enabled end,
			set = function(_, v) background().enabled = v; apply() end,
		},
		color = Options.Color(L["Color"], 2, background, "color", apply, { hasAlpha = true }),
		inset = {
			type = "range", order = 3, name = L["Inset"],
			min = -20, max = 20, step = 1,
			get = function() return background().inset end,
			set = function(_, v) background().inset = v; apply() end,
		},
	}

	local borderArgs = {
		enabled = {
			type = "toggle", order = 1, name = L["Enable"],
			get = function() return border().enabled end,
			set = function(_, v) border().enabled = v; apply() end,
		},
		color = Options.Color(L["Color"], 2, border, "color", apply, { hasAlpha = true }),
		size = {
			type = "range", order = 3, name = L["Thickness"],
			min = 1, max = 8, step = 1,
			get = function() return border().size end,
			set = function(_, v) border().size = v; apply() end,
		},
	}

	return {
		type = "group", order = 1, name = L["Layout"],
		args = {
			notice = Options.CombatNotice(0),
			size = { type = "group", order = 10, inline = true, name = L["Size"], args = sizeArgs },
			position = { type = "group", order = 20, inline = true, name = L["Position"], args = positionArgs },
			background = { type = "group", order = 30, inline = true, name = L["Background"], args = backgroundArgs },
			border = { type = "group", order = 40, inline = true, name = L["Border"], args = borderArgs },
		},
	}
end

--------------------------------------------------------------------------------
-- Health bar (SPEC §4.4)
--------------------------------------------------------------------------------

local function healthGroup(def)
	local unitKey = def.key
	local function health() local c = ns:UnitConfig(unitKey); return c and c.health end
	local function gradient() local h = health(); return h and h.gradient end
	local apply = Options.ApplyUnit(unitKey)

	local function notGradient() return health().colorMode ~= "gradient" end

	-- The swatch is only shown when something actually reads it: as the color
	-- itself in static mode, or as the NPC fallback in class mode. Reaction and
	-- gradient use neither, and leaving a live-looking color picker next to a
	-- mode that ignores it is how you get someone changing it and concluding
	-- the addon is broken.
	local function swatchUnused()
		local mode = health().colorMode
		if mode == "static" then return false end
		if mode == "class" then return health().npcFallback ~= "static" end
		return true
	end

	local function swatchName()
		return health().colorMode == "class" and L["Color for NPCs"] or L["Color"]
	end

	local args = {
		notice = Options.CombatNotice(0),
		enabled = {
			type = "toggle", order = 1, name = L["Enable"],
			get = function() return health().enabled end,
			set = function(_, v) health().enabled = v; apply() end,
		},
		height = {
			type = "range", order = 2, name = L["Height"],
			desc = L["0 means fill whatever the power and mana bars leave."],
			min = 0, max = 1000, softMax = 300, step = 1,
			get = function() return health().height end,
			set = function(_, v) health().height = v; apply() end,
		},
		texture = textureOption(L["Texture"], 3, health, apply),

		colorHeader = { type = "header", order = 10, name = L["Color"] },
		colorMode = {
			type = "select", order = 11, name = L["Color mode"],
			desc = L["Class coloring is per unit, so you can have it on the target but not on yourself, or the other way round."],
			values = {
				static = L["Single color"],
				class = L["Class color"],
				reaction = L["Reaction color"],
				gradient = L["Gradient by health"],
			},
			get = function() return health().colorMode end,
			set = function(_, v) health().colorMode = v; apply() end,
		},
		npcFallback = {
			type = "select", order = 12, name = L["NPCs use"],
			desc = L["Class colors only ever apply to actual players, so NPCs fall through to this."],
			hidden = function() return health().colorMode ~= "class" end,
			values = { reaction = L["Reaction color"], static = L["A fixed color"] },
			get = function() return health().npcFallback end,
			set = function(_, v) health().npcFallback = v; apply(); Options:Notify() end,
		},
		color = Options.Color(swatchName, 13, health, "color", apply, {
			hidden = swatchUnused,
		}),
		gradient1 = Options.GradientColor(L["Gradient: empty"], 15, gradient, 1, apply, { hidden = notGradient }),
		gradient2 = Options.GradientColor(L["Gradient: middle"], 16, gradient, 2, apply, { hidden = notGradient }),
		gradient3 = Options.GradientColor(L["Gradient: full"], 17, gradient, 3, apply, { hidden = notGradient }),

		brightness = {
			type = "range", order = 18, name = L["Brightness"],
			desc = L["Scales whatever color the mode above resolves to, so it works the same on a class color, a reaction color or a gradient. The bar's background follows it, since the background is derived from the bar color."],
			min = 0, max = 2, step = 0.05,
			get = function() return health().brightness end,
			set = function(_, v) health().brightness = v; apply() end,
		},

		stateHeader = { type = "header", order = 20, name = L["States"] },
		dimWhenDead = {
			type = "toggle", order = 21, name = L["Dim when dead"],
			get = function() return health().dimWhenDead end,
			set = function(_, v) health().dimWhenDead = v; apply() end,
		},
		offlineColor = Options.Color(L["Offline color"], 22, health, "offlineColor", apply),
		tapColor = Options.Color(L["Tapped by someone else"], 23, health, "tapColor", apply),

		bgHeader = { type = "header", order = 30, name = L["Background (the depleted part of the bar)"] },
		bgNote = {
			type = "description", order = 30.5,
			name = L["These control the empty portion of the bar, not the filled portion. If nothing appears to change, check that the frame background under the Layout tab is off -- it sits behind the bars and will mask any transparency set here."],
		},
		bgMultiplier = {
			type = "range", order = 31, name = L["Background brightness"],
			desc = L["A fraction of the bar's own color, so a class-colored bar keeps a matching background."],
			min = 0, max = 1, step = 0.01,
			get = function() return health().bgMultiplier end,
			set = function(_, v) health().bgMultiplier = v; apply() end,
		},
		bgAlpha = {
			type = "range", order = 32, name = L["Background opacity"],
			desc = L["0 makes the empty part of the bar fully transparent."],
			min = 0, max = 1, step = 0.01,
			get = function() return health().bgAlpha end,
			set = function(_, v) health().bgAlpha = v; apply() end,
		},
		inverseFill = {
			type = "toggle", order = 33, name = L["Inverse fill"],
			desc = L["The bar depletes from the opposite side."],
			get = function() return health().inverseFill end,
			set = function(_, v) health().inverseFill = v; apply() end,
		},
	}

	return { type = "group", order = 2, name = L["Health"], args = args }
end

--------------------------------------------------------------------------------
-- Sweep lines (Plans 2 and 10, Systems/BarSweep.lua)
--
-- The same controls appear on both bars for both indicators, so they are built
-- once. Player only: another unit's tick cadence and mana expenditure are not
-- observable, so the controls are absent rather than present and permanently
-- idle — the §FR-8.5 call the combo bar also makes.
--------------------------------------------------------------------------------

local SWEEP_DIRECTIONS = {
	RIGHT = L["Left to right"],
	LEFT = L["Right to left"],
}

local function sweepGroup(unitKey, getBar, apply, key, order, name, description)
	local function sweep() local bar = getBar(); return bar and bar[key] end

	local args = {
		explain = { type = "description", order = 1, name = description },
		enabled = {
			type = "toggle", order = 2, name = L["Enable"],
			get = function() return sweep().enabled end,
			set = function(_, v) sweep().enabled = v; apply() end,
		},
		direction = {
			type = "select", order = 3, name = L["Direction"],
			values = SWEEP_DIRECTIONS,
			get = function() return sweep().direction end,
			set = function(_, v) sweep().direction = v; apply() end,
		},
		width = {
			type = "range", order = 4, name = L["Line width"],
			min = 1, max = 10, step = 1,
			get = function() return sweep().width end,
			set = function(_, v) sweep().width = v; apply() end,
		},
		color = Options.Color(L["Color"], 5, sweep, "color", apply),
		alpha = {
			type = "range", order = 6, name = L["Opacity"],
			min = 0, max = 1, step = 0.01,
			get = function() return sweep().alpha end,
			set = function(_, v) sweep().alpha = v; apply() end,
		},
	}

	if key == "tick" then
		args.atMax = {
			-- Radio rather than a dropdown, and full width on purpose.
			--
			-- An AceGUI dropdown sizes its pullout to the dropdown's OWN width
			-- (AceGUIWidget-DropDown.lua, `SetWidth(self.pulloutWidth or
			-- self.frame:GetWidth())`), and in a two-column flow that is half a
			-- panel — which clipped two of these four labels to "Keep it on
			-- energy, hide i...". There is no option key for pullout width, and
			-- Libs/ is version-pinned and not patched in place.
			--
			-- A radio row is laid out full width with its label anchored across
			-- the whole row, so nothing can be truncated whatever the label says
			-- or is later translated to. Showing all four at once also suits a
			-- setting whose options are only meaningful next to each other.
			type = "select", style = "radio", width = "full",
			order = 7, name = L["At maximum power"],
			desc = L["At full power the tick is still landing, it just has nothing to add. A healer watching for the next mana tick usually wants the countdown anyway; a line sweeping a permanently full energy bar is usually just noise. This is which of those you are."],
			values = {
				always = L["Keep showing it"],
				mana = L["Keep it on mana, hide it on energy"],
				energy = L["Keep it on energy, hide it on mana"],
				never = L["Hide it"],
			},
			-- Without this the entries come out sorted by KEY, which is how the
			-- dropdown was ordering them: always, energy, mana, never. Spelling
			-- the order out puts the two "keep it" cases together between the
			-- unconditional ones.
			sorting = { "always", "mana", "energy", "never" },
			get = function() return sweep().atMax end,
			set = function(_, v) sweep().atMax = v; apply() end,
		}
	end

	if key == "fsr" then
		args.fade = {
			type = "range", order = 7, name = L["Fade out"],
			desc = L["Seconds spent fading at the far edge once the five seconds are up, instead of vanishing outright."],
			min = 0, max = 2, step = 0.05,
			get = function() return sweep().fade end,
			set = function(_, v) sweep().fade = v; apply() end,
		}
		args.hideTick = {
			-- Full width so the label is not clipped, the same lesson the
			-- at-maximum-power control above learned the hard way.
			type = "toggle", order = 8, width = "full",
			name = L["Hide the power tick line while this counts down"],
			desc = L["Only on this bar, and only for the five seconds themselves. Two lines sweeping one bar in opposite directions is hard to read, and during the rule the mana tick is still landing but has no Spirit contribution to add - so this one is the more informative of the two. A druid's energy bar is never affected, since the rule does not apply there."],
			get = function() return sweep().hideTick end,
			set = function(_, v) sweep().hideTick = v; apply() end,
		}
	end

	return {
		type = "group", inline = true, order = order, name = name,
		hidden = unitKey ~= "player",
		args = args,
	}
end

local TICK_DESCRIPTION = L["A thin line sweeping across the bar towards the next energy or mana regeneration tick. The interval is measured from the game as it runs rather than assumed to be two seconds, so it stays correct if the cadence is ever different from what is expected."]

local FSR_DESCRIPTION = L["Spending mana suppresses Spirit-based regeneration for five seconds, and every fresh expenditure restarts it. The line sweeps for exactly that window. Regeneration resumes on the first tick AFTER the window closes, so it can be up to one tick later than the line suggests - the power tick indicator above covers that remainder. Only shown while this bar is showing mana."]

--------------------------------------------------------------------------------
-- Power bar
--------------------------------------------------------------------------------

local function powerGroup(def)
	local unitKey = def.key
	local function power() local c = ns:UnitConfig(unitKey); return c and c.power end
	local apply = Options.ApplyUnit(unitKey)

	local args = {
		notice = Options.CombatNotice(0),
		enabled = {
			type = "toggle", order = 1, name = L["Enable"],
			get = function() return power().enabled end,
			set = function(_, v) power().enabled = v; apply() end,
		},
		height = Options.Range(L["Height"], 2, "height", power, "height", apply),
		spacing = {
			type = "range", order = 3, name = L["Gap above"],
			min = 0, max = 20, step = 1,
			get = function() return power().spacing end,
			set = function(_, v) power().spacing = v; apply() end,
		},
		texture = textureOption(L["Texture"], 4, power, apply),
		hideWhenEmpty = {
			type = "toggle", order = 5, name = L["Hide for units with no power"],
			get = function() return power().hideWhenEmpty end,
			set = function(_, v) power().hideWhenEmpty = v; apply() end,
		},

		colorHeader = { type = "header", order = 10, name = L["Color"] },
		colorMode = {
			type = "select", order = 11, name = L["Color mode"],
			values = {
				power = L["By power type"],
				static = L["Single color"],
				class = L["Class color"],
			},
			get = function() return power().colorMode end,
			set = function(_, v) power().colorMode = v; apply() end,
		},
		color = Options.Color(L["Color"], 12, power, "color", apply, {
			hidden = function() return power().colorMode ~= "static" end,
		}),
		useOverrides = {
			type = "toggle", order = 13, name = L["Override individual power types"],
			hidden = function() return power().colorMode ~= "power" end,
			get = function() return power().useOverrides end,
			set = function(_, v)
				power().useOverrides = v
				if v then
					-- Seed from the game's own colors so the pickers open on
					-- the right value rather than on white.
					for token in pairs(POWER_TOKENS) do
						if not power().overrides[token] then
							local r, g, b = ns.Colors:Power(nil, token)
							power().overrides[token] = { r = r, g = g, b = b, a = 1 }
						end
					end
				end
				apply()
				Options:Notify()
			end,
		},

		brightness = {
			type = "range", order = 14, name = L["Brightness"],
			desc = L["Scales whatever color the mode above resolves to, so it works the same on a class color, a reaction color or a gradient. The bar's background follows it, since the background is derived from the bar color."],
			min = 0, max = 2, step = 0.05,
			get = function() return power().brightness end,
			set = function(_, v) power().brightness = v; apply() end,
		},

		bgHeader = { type = "header", order = 20, name = L["Background"] },
		bgMultiplier = {
			type = "range", order = 21, name = L["Background brightness"],
			min = 0, max = 1, step = 0.01,
			get = function() return power().bgMultiplier end,
			set = function(_, v) power().bgMultiplier = v; apply() end,
		},
		bgAlpha = {
			type = "range", order = 22, name = L["Background opacity"],
			min = 0, max = 1, step = 0.01,
			get = function() return power().bgAlpha end,
			set = function(_, v) power().bgAlpha = v; apply() end,
		},

		tick = sweepGroup(unitKey, power, apply, "tick", 40,
			L["Power tick indicator"], TICK_DESCRIPTION),
		fsr = sweepGroup(unitKey, power, apply, "fsr", 50,
			L["Five second rule indicator"], FSR_DESCRIPTION),
	}

	local order = 30
	for token, label in pairs(POWER_TOKENS) do
		order = order + 1
		args["override_" .. token] = {
			type = "color", order = order, name = label,
			hidden = function()
				return power().colorMode ~= "power" or not power().useOverrides
			end,
			get = function()
				local c = power().overrides[token]
				if not c then return ns.Colors:Power(nil, token) end
				return c.r or 1, c.g or 1, c.b or 1
			end,
			set = function(_, r, g, b)
				power().overrides[token] = power().overrides[token] or {}
				local c = power().overrides[token]
				c.r, c.g, c.b, c.a = r, g, b, 1
				apply()
			end,
		}
	end

	return { type = "group", order = 3, name = L["Power"], args = args }
end

--------------------------------------------------------------------------------
-- Shapeshift mana bar (SPEC §4.2)
--------------------------------------------------------------------------------

local function manaGroup(def)
	local unitKey = def.key
	local function mana() local c = ns:UnitConfig(unitKey); return c and c.mana end
	local apply = Options.ApplyUnit(unitKey)

	local args = {
		notice = Options.CombatNotice(0),
		explain = {
			type = "description", order = 1,
			name = L["Shown whenever this unit's displayed power is not mana but it still has a mana pool. That is a general rule, not a druid check - in Classic and TBC it fires for Bear, Dire Bear and Cat form and for nothing else."],
		},
		enabled = {
			type = "toggle", order = 2, name = L["Enable"],
			get = function() return mana().enabled end,
			set = function(_, v) mana().enabled = v; apply() end,
		},
		mode = {
			type = "select", order = 3, name = L["When it appears"],
			desc = L["Append keeps the frame's own height and click area unchanged and hangs the bar underneath, which also means a form change never touches a protected operation. Reserve keeps everything inside the frame at the cost of a slightly shorter health bar at all times."],
			values = {
				append = L["Add it below the frame (nothing else moves)"],
				reserve = L["Always reserve its space inside the frame"],
			},
			get = function() return mana().mode end,
			set = function(_, v) mana().mode = v; apply() end,
		},
		height = Options.Range(L["Height"], 4, "height", mana, "height", apply),
		spacing = {
			type = "range", order = 5, name = L["Gap above"],
			min = 0, max = 20, step = 1,
			get = function() return mana().spacing end,
			set = function(_, v) mana().spacing = v; apply() end,
		},
		widthMode = {
			type = "select", order = 6, name = L["Width"],
			values = { inherit = L["Match the frame"], custom = L["Custom"] },
			get = function() return mana().widthMode end,
			set = function(_, v) mana().widthMode = v; apply() end,
		},
		width = Options.Range(L["Custom width"], 7, "width", mana, "width", apply, {
			hidden = function() return mana().widthMode ~= "custom" end,
		}),
		texture = textureOption(L["Texture"], 8, mana, apply),
		color = Options.Color(L["Color"], 9, mana, "color", apply),
		brightness = {
			type = "range", order = 10, name = L["Brightness"],
			desc = L["Scales whatever color the mode above resolves to, so it works the same on a class color, a reaction color or a gradient. The bar's background follows it, since the background is derived from the bar color."],
			min = 0, max = 2, step = 0.05,
			get = function() return mana().brightness end,
			set = function(_, v) mana().brightness = v; apply() end,
		},

		tickerHeader = { type = "header", order = 20, name = L["Update reliability"] },
		tickerExplain = {
			type = "description", order = 21,
			name = L["Mana events have historically been unreliable while shapeshifted. 'Automatic' runs a fallback ticker only while the bar is visible and counts how often it caught a value the events missed. If that count stays at zero across a few sessions, the events are fine on this client and you can turn it off."],
		},
		tickerMode = {
			type = "select", order = 22, name = L["Fallback ticker"],
			values = { auto = L["Automatic"], on = L["Always on"], off = L["Off"] },
			get = function() return mana().tickerMode end,
			set = function(_, v) mana().tickerMode = v; apply() end,
		},
		tickerInterval = {
			type = "range", order = 23, name = L["Ticker interval"],
			min = 0.1, max = 1, step = 0.05,
			disabled = function() return mana().tickerMode == "off" end,
			get = function() return mana().tickerInterval end,
			set = function(_, v) mana().tickerInterval = v; apply() end,
		},
		tickerStats = {
			type = "description", order = 24,
			name = function()
				local corrections, ticks = ns.elements.mana.TickerStats()
				return string.format(
					L["This session: %d tick(s), %d value(s) the events did not deliver."],
					ticks, corrections)
			end,
		},

		tick = sweepGroup(unitKey, mana, apply, "tick", 30,
			L["Power tick indicator"], TICK_DESCRIPTION),
		fsr = sweepGroup(unitKey, mana, apply, "fsr", 40,
			L["Five second rule indicator"], FSR_DESCRIPTION),
	}

	return { type = "group", order = 4, name = L["Shapeshift mana"], args = args }
end

--------------------------------------------------------------------------------
-- Combo points (Plan 9)
--------------------------------------------------------------------------------

local function comboGroup(def)
	local unitKey = def.key
	local function combo() local c = ns:UnitConfig(unitKey); return c and c.combo end
	local apply = Options.ApplyUnit(unitKey)

	local args = {
		notice = Options.CombatNotice(0),
		breaker = Options.BreakerNotice(unitKey, "combo", 0.5),
		explain = {
			type = "description", order = 1,
			name = L["Combo points are the player's, spent on the player's target, so this reads your own points and draws them on this frame. It ships on the target frame, hidden until you actually have a point -- which is also what keeps it out of the way for every class that has no combo points at all."],
		},
		enabled = {
			type = "toggle", order = 2, name = L["Enable"],
			get = function() return combo().enabled end,
			set = function(_, v) combo().enabled = v; apply() end,
		},
		hideWhenEmpty = {
			type = "toggle", order = 3, name = L["Hide at zero points"],
			desc = L["Off shows an empty row instead, which is a capacity readout for classes that have combo points and a permanent row of dark rectangles for the ones that do not."],
			get = function() return combo().hideWhenEmpty end,
			set = function(_, v) combo().hideWhenEmpty = v; apply() end,
		},

		layoutHeader = { type = "header", order = 10, name = L["Layout"] },
		layoutNote = {
			type = "description", order = 10.5,
			name = L["The bar sits outside the frame, above its top edge, so nothing inside the frame moves when it appears. The target's buff row is offset to clear it; if you move one, check the other."],
		},
		anchorTo = {
			type = "select", order = 11, name = L["Anchor to"],
			values = function() return ns:AnchorWidgetValues() end,
			get = function() return combo().anchorTo end,
			set = function(_, v) combo().anchorTo = v; apply() end,
		},
		point = {
			type = "select", order = 12, name = L["Point on the bar"],
			values = ns.Anchoring:PointValues(),
			get = function() return combo().point end,
			set = function(_, v) combo().point = v; apply() end,
		},
		relativePoint = {
			type = "select", order = 13, name = L["Point on the anchor"],
			values = ns.Anchoring:PointValues(),
			get = function() return combo().relativePoint end,
			set = function(_, v) combo().relativePoint = v; apply() end,
		},
		x = Options.Range(L["X offset"], 14, "offset", combo, "x", apply),
		y = Options.Range(L["Y offset"], 15, "offset", combo, "y", apply),
		widthMode = {
			type = "select", order = 16, name = L["Width"],
			desc = L["A custom width will usually want the two points above set to BOTTOM and TOP, which centers the bar instead of leaving it flush left."],
			values = { inherit = L["Match the frame"], custom = L["Custom"] },
			get = function() return combo().widthMode end,
			set = function(_, v) combo().widthMode = v; apply() end,
		},
		width = Options.Range(L["Custom width"], 17, "width", combo, "width", apply, {
			hidden = function() return combo().widthMode ~= "custom" end,
		}),
		height = Options.Range(L["Height"], 18, "height", combo, "height", apply),
		growth = {
			type = "select", order = 19, name = L["Fill direction"],
			values = ns.elements.combo.GrowthValues(),
			get = function() return combo().growth end,
			set = function(_, v) combo().growth = v; apply() end,
		},
		alpha = {
			type = "range", order = 20, name = L["Opacity"],
			min = 0, max = 1, step = 0.01,
			get = function() return combo().alpha end,
			set = function(_, v) combo().alpha = v; apply() end,
		},

		colorHeader = { type = "header", order = 30, name = L["Color"] },
		color = Options.Color(L["Filled"], 31, combo, "color", apply),
		emptyColor = Options.Color(L["Empty"], 32, combo, "emptyColor", apply, { hasAlpha = true }),
		borderColor = Options.Color(L["Border"], 33, combo, "borderColor", apply, { hasAlpha = true }),
		borderSize = {
			type = "range", order = 34, name = L["Border thickness"],
			desc = L["Applied all the way round the group and in the gaps between rectangles. Adjacent rectangles share one line, so the border reads the same thickness everywhere. The rectangles absorb any remainder, which is why two of them may differ by a pixel."],
			min = 0, max = 8, step = 1,
			get = function() return combo().borderSize end,
			set = function(_, v) combo().borderSize = v; apply() end,
		},
	}

	return { type = "group", order = 4.5, name = L["Combo points"], args = args }
end

--------------------------------------------------------------------------------
-- Portrait (SPEC §4.7)
--------------------------------------------------------------------------------

local function portraitGroup(def)
	local unitKey = def.key
	local function portrait() local c = ns:UnitConfig(unitKey); return c and c.portrait end
	local apply = Options.ApplyUnit(unitKey)

	local function isNone() return portrait().mode == "none" end
	local function not3D() return portrait().mode ~= "3d" end
	local function notInside()
		return isNone() or portrait().placement == "outside"
	end

	local args = {
		notice = Options.CombatNotice(0),
		mode = {
			type = "select", order = 1, name = L["Mode"],
			values = { none = L["None"], ["2d"] = L["2D"], ["3d"] = L["3D model"] },
			get = function() return portrait().mode end,
			set = function(_, v) portrait().mode = v; apply() end,
		},
		honest = {
			type = "description", order = 2,
			name = L["|cffffcc002D is the more robust choice.|r Model frames are the least reliable widget in the API: they go stale on unit changes, lose their camera on loading screens, and will not load for units out of range. All of that is handled here and a model that will not load falls back to 2D silently - but the option to avoid the whole category exists, and it is this one."],
		},

		shape = {
			type = "select", order = 9, name = L["Shape"],
			desc = L["The game's portrait art is round -- its corners are transparent. Square crops to the largest fully opaque part of it, which zooms in slightly. Native shows it exactly as the game provides it, corners and all."],
			hidden = function() return portrait().mode ~= "2d" end,
			values = { square = L["Square"], native = L["Native (round)"] },
			get = function() return portrait().shape end,
			set = function(_, v) portrait().shape = v; apply() end,
		},
		placement = {
			type = "select", order = 10, name = L["Placement"],
			hidden = isNone,
			values = {
				outside = L["Beside the frame"],
				inside = L["Over the frame (behind the bars)"],
			},
			desc = L["The bars are an opaque fill covering the whole frame, so 'over the frame' hides the portrait almost completely unless you make the bars translucent."],
			get = function() return portrait().placement end,
			set = function(_, v) portrait().placement = v; apply() end,
		},
		side = {
			type = "select", order = 11, name = L["Side"],
			hidden = function() return isNone() or portrait().placement ~= "outside" end,
			values = { LEFT = L["Left"], RIGHT = L["Right"] },
			get = function() return portrait().side end,
			set = function(_, v) portrait().side = v; apply() end,
		},
		width = Options.Range(L["Width"], 12, "width", portrait, "width", apply,
			{ hidden = isNone, min = 4, softMin = 8, softMax = 200 }),
		height = Options.Range(L["Height"], 13, "height", portrait, "height", apply,
			{ hidden = isNone, min = 4, softMin = 8, softMax = 200 }),
		point = {
			type = "select", order = 14, name = L["Point on the portrait"],
			hidden = notInside,
			values = ns.Anchoring:PointValues(),
			get = function() return portrait().point end,
			set = function(_, v) portrait().point = v; apply() end,
		},
		relativePoint = {
			type = "select", order = 15, name = L["Point on the unit frame"],
			hidden = notInside,
			values = ns.Anchoring:PointValues(),
			get = function() return portrait().relativePoint end,
			set = function(_, v) portrait().relativePoint = v; apply() end,
		},
		x = Options.Range(L["X offset"], 16, "offset", portrait, "x", apply, { hidden = isNone }),
		y = Options.Range(L["Y offset"], 17, "offset", portrait, "y", apply, { hidden = isNone }),
		alpha = {
			type = "range", order = 18, name = L["Opacity"],
			hidden = isNone, min = 0, max = 1, step = 0.01,
			get = function() return portrait().alpha end,
			set = function(_, v) portrait().alpha = v; apply() end,
		},
		desaturate = {
			type = "toggle", order = 19, name = L["Desaturate"],
			hidden = function() return portrait().mode ~= "2d" end,
			get = function() return portrait().desaturate end,
			set = function(_, v) portrait().desaturate = v; apply() end,
		},

		cameraHeader = { type = "header", order = 30, name = L["Camera"], hidden = not3D },
		camera = {
			type = "range", order = 31, name = L["Distance"],
			hidden = not3D, min = -0.9, max = 3, step = 0.05,
			get = function() return portrait().camera end,
			set = function(_, v) portrait().camera = v; apply() end,
		},
		cameraY = {
			type = "range", order = 32, name = L["Vertical offset"],
			hidden = not3D, min = -2, max = 2, step = 0.05,
			get = function() return portrait().cameraY end,
			set = function(_, v) portrait().cameraY = v; apply() end,
		},
	}

	return { type = "group", order = 5, name = L["Portrait"], args = args }
end

--------------------------------------------------------------------------------
-- Highlight
--------------------------------------------------------------------------------

local function highlightGroup(def)
	local unitKey = def.key
	local function highlight() local c = ns:UnitConfig(unitKey); return c and c.highlight end
	local apply = Options.ApplyUnit(unitKey)

	return {
		type = "group", order = 6, name = L["Highlight"],
		args = {
			targetEnabled = {
				type = "toggle", order = 1, name = L["Outline when this unit is your target"],
				get = function() return highlight().targetEnabled end,
				set = function(_, v) highlight().targetEnabled = v; apply() end,
			},
			targetColor = Options.Color(L["Target outline color"], 2, highlight, "targetColor", apply,
				{ hasAlpha = true }),
			mouseoverEnabled = {
				type = "toggle", order = 3, name = L["Outline on mouseover"],
				get = function() return highlight().mouseoverEnabled end,
				set = function(_, v) highlight().mouseoverEnabled = v; apply() end,
			},
			mouseoverColor = Options.Color(L["Mouseover outline color"], 4, highlight, "mouseoverColor", apply,
				{ hasAlpha = true }),
			thickness = {
				type = "range", order = 5, name = L["Thickness"],
				min = 1, max = 8, step = 1,
				get = function() return highlight().thickness end,
				set = function(_, v) highlight().thickness = v; apply() end,
			},
		},
	}
end

--------------------------------------------------------------------------------
-- State indicators (Plan 1)
--------------------------------------------------------------------------------

local function indicatorsGroup(def)
	local unitKey = def.key
	local function indicators() local c = ns:UnitConfig(unitKey); return c and c.indicators end
	local apply = Options.ApplyUnit(unitKey)

	local args = {
		notice = Options.CombatNotice(0),
		breaker = Options.BreakerNotice(unitKey, "indicators", 0.5),
		explain = {
			type = "description", order = 1,
			name = L["Small markers for unit state. Only the ones currently active take a slot, so a single active state always sits at the start of the row rather than leaving a gap where the others would be."],
		},
		enabled = {
			type = "toggle", order = 2, name = L["Enable"],
			get = function() return indicators().enabled end,
			set = function(_, v) indicators().enabled = v; apply() end,
		},

		layoutHeader = { type = "header", order = 10, name = L["Layout"] },
		anchorTo = {
			type = "select", order = 11, name = L["Anchor to"],
			values = function() return ns:AnchorWidgetValues() end,
			get = function() return indicators().anchorTo end,
			set = function(_, v) indicators().anchorTo = v; apply() end,
		},
		point = {
			type = "select", order = 12, name = L["Point on the row"],
			values = ns.Anchoring:PointValues(),
			get = function() return indicators().point end,
			set = function(_, v) indicators().point = v; apply() end,
		},
		relativePoint = {
			type = "select", order = 13, name = L["Point on the anchor"],
			values = ns.Anchoring:PointValues(),
			get = function() return indicators().relativePoint end,
			set = function(_, v) indicators().relativePoint = v; apply() end,
		},
		x = Options.Range(L["X offset"], 14, "offset", indicators, "x", apply),
		y = Options.Range(L["Y offset"], 15, "offset", indicators, "y", apply),
		growth = {
			type = "select", order = 16, name = L["Growth direction"],
			values = ns.elements.indicators.GrowthValues(),
			get = function() return indicators().growth end,
			set = function(_, v) indicators().growth = v; apply() end,
		},
		size = {
			type = "range", order = 17, name = L["Icon size"],
			min = 4, max = 100, softMax = 48, step = 1,
			get = function() return indicators().size end,
			set = function(_, v) indicators().size = v; apply() end,
		},
		spacing = {
			type = "range", order = 18, name = L["Spacing"],
			min = 0, max = 40, step = 1,
			get = function() return indicators().spacing end,
			set = function(_, v) indicators().spacing = v; apply() end,
		},
		alpha = {
			type = "range", order = 19, name = L["Opacity"],
			min = 0, max = 1, step = 0.01,
			get = function() return indicators().alpha end,
			set = function(_, v) indicators().alpha = v; apply() end,
		},
		style = {
			type = "select", order = 20, name = L["Style"],
			desc = L["The game's own state artwork, or a plain colored square. The square is the fallback if a shared-code patch ever moves that artwork and the icons come up blank."],
			values = { icon = L["Game artwork"], square = L["Solid square"] },
			get = function() return indicators().style end,
			set = function(_, v) indicators().style = v; apply() end,
		},
	}

	local order = 30
	for _, state in ipairs(ns.elements.indicators.StateList()) do
		local key = state.key
		local function stateCfg() return indicators().states[key] end

		args["header_" .. key] = { type = "header", order = order, name = state.label }
		args["enabled_" .. key] = {
			type = "toggle", order = order + 1, name = L["Show"],
			get = function() return stateCfg().enabled end,
			set = function(_, v) stateCfg().enabled = v; apply() end,
		}
		args["color_" .. key] = Options.Color(L["Tint"], order + 2, stateCfg, "color", apply)
		if key == "resting" then
			args["note_" .. key] = {
				type = "description", order = order + 3,
				name = L["Resting is something the game only reports about you, so this never shows on any other unit."],
			}
		end
		order = order + 10
	end

	return { type = "group", order = 6.5, name = L["Indicators"], args = args }
end

--------------------------------------------------------------------------------
-- Assembly
--------------------------------------------------------------------------------

function Options.BuildUnit(def)
	local unitKey = def.key
	local function cfg() return ns:UnitConfig(unitKey) end

	local args = {
		enabled = {
			type = "toggle", order = 0, name = L["Enable this frame"],
			get = function() return cfg().enabled end,
			set = function(_, v)
				cfg().enabled = v
				ns:RefreshUnit(unitKey)
				if def.group then ns.PartyGroup:Apply() end
			end,
		},
		derivedNote = {
			type = "description", order = 1,
			hidden = not def.derived,
			name = L["|cffffcc00This is a derived unit.|r Its identity updates instantly, but its health, power and auras are sampled on a timer, so they lag slightly. That is a property of the game rather than something the addon can engineer around, which is why it ships text-light with auras off. Turn on whatever you like and accept the latency."],
		},
		layout = layoutGroup(def),
		health = healthGroup(def),
		power = powerGroup(def),
		mana = manaGroup(def),
		-- SPEC §FR-8.5: absent rather than present-and-broken. Combo points are
		-- the player's resource against the player's target; on a party frame
		-- the control would be meaningless.
		combo = (function()
			local group = comboGroup(def)
			group.hidden = not (def.key == "player" or def.key == "target")
			return group
		end)(),
		portrait = portraitGroup(def),
		indicators = indicatorsGroup(def),
		highlight = highlightGroup(def),
		texts = Options.BuildTexts(def),
		auras = Options.BuildAuras(def),
		reset = {
			type = "execute", order = 99, name = L["Reset this unit"],
			confirm = true,
			confirmText = L["Reset every setting on this frame to its default?"],
			func = function()
				ns.Defaults:ResetUnit(ns:Profile(), unitKey)
				ns:BumpSerial()
				ns:RefreshUnit(unitKey)
				Options:Notify()
			end,
		},
	}

	return {
		type = "group",
		name = def.label,
		order = def.order,
		childGroups = "tab",
		args = args,
	}
end
