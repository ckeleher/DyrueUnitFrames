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
		color = Options.Color(L["Colour"], 2, background, "color", apply, { hasAlpha = true }),
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
		color = Options.Color(L["Colour"], 2, border, "color", apply, { hasAlpha = true }),
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

		colorHeader = { type = "header", order = 10, name = L["Colour"] },
		colorMode = {
			type = "select", order = 11, name = L["Colour mode"],
			desc = L["Class colouring is per unit, so you can have it on the target but not on yourself, or the other way round."],
			values = {
				static = L["Single colour"],
				class = L["Class colour"],
				reaction = L["Reaction colour"],
				gradient = L["Gradient by health"],
			},
			get = function() return health().colorMode end,
			set = function(_, v) health().colorMode = v; apply() end,
		},
		color = Options.Color(L["Colour"], 12, health, "color", apply, {
			hidden = function() return health().colorMode == "gradient" end,
		}),
		npcFallback = {
			type = "select", order = 13, name = L["NPCs use"],
			desc = L["Class colours only ever apply to actual players. NPCs fall through to this."],
			hidden = function() return health().colorMode ~= "class" end,
			values = { reaction = L["Reaction colour"], static = L["The single colour above"] },
			get = function() return health().npcFallback end,
			set = function(_, v) health().npcFallback = v; apply() end,
		},
		gradient1 = Options.GradientColor(L["Gradient: empty"], 15, gradient, 1, apply, { hidden = notGradient }),
		gradient2 = Options.GradientColor(L["Gradient: middle"], 16, gradient, 2, apply, { hidden = notGradient }),
		gradient3 = Options.GradientColor(L["Gradient: full"], 17, gradient, 3, apply, { hidden = notGradient }),

		brightness = {
			type = "range", order = 18, name = L["Brightness"],
			desc = L["Scales whatever colour the mode above resolves to, so it works the same on a class colour, a reaction colour or a gradient. The bar's background follows it, since the background is derived from the bar colour."],
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
		offlineColor = Options.Color(L["Offline colour"], 22, health, "offlineColor", apply),
		tapColor = Options.Color(L["Tapped by someone else"], 23, health, "tapColor", apply),

		bgHeader = { type = "header", order = 30, name = L["Background (the depleted part of the bar)"] },
		bgNote = {
			type = "description", order = 30.5,
			name = L["These control the empty portion of the bar, not the filled portion. If nothing appears to change, check that the frame background under the Layout tab is off -- it sits behind the bars and will mask any transparency set here."],
		},
		bgMultiplier = {
			type = "range", order = 31, name = L["Background brightness"],
			desc = L["A fraction of the bar's own colour, so a class-coloured bar keeps a matching background."],
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

		colorHeader = { type = "header", order = 10, name = L["Colour"] },
		colorMode = {
			type = "select", order = 11, name = L["Colour mode"],
			values = {
				power = L["By power type"],
				static = L["Single colour"],
				class = L["Class colour"],
			},
			get = function() return power().colorMode end,
			set = function(_, v) power().colorMode = v; apply() end,
		},
		color = Options.Color(L["Colour"], 12, power, "color", apply, {
			hidden = function() return power().colorMode ~= "static" end,
		}),
		useOverrides = {
			type = "toggle", order = 13, name = L["Override individual power types"],
			hidden = function() return power().colorMode ~= "power" end,
			get = function() return power().useOverrides end,
			set = function(_, v)
				power().useOverrides = v
				if v then
					-- Seed from the game's own colours so the pickers open on
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
			desc = L["Scales whatever colour the mode above resolves to, so it works the same on a class colour, a reaction colour or a gradient. The bar's background follows it, since the background is derived from the bar colour."],
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
		color = Options.Color(L["Colour"], 9, mana, "color", apply),
		brightness = {
			type = "range", order = 10, name = L["Brightness"],
			desc = L["Scales whatever colour the mode above resolves to, so it works the same on a class colour, a reaction colour or a gradient. The bar's background follows it, since the background is derived from the bar colour."],
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
	}

	return { type = "group", order = 4, name = L["Shapeshift mana"], args = args }
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

		placement = {
			type = "select", order = 10, name = L["Placement"],
			hidden = isNone,
			values = {
				inside = L["Inside the frame (behind the bars)"],
				outside = L["Outside the frame"],
			},
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
			targetColor = Options.Color(L["Target outline colour"], 2, highlight, "targetColor", apply,
				{ hasAlpha = true }),
			mouseoverEnabled = {
				type = "toggle", order = 3, name = L["Outline on mouseover"],
				get = function() return highlight().mouseoverEnabled end,
				set = function(_, v) highlight().mouseoverEnabled = v; apply() end,
			},
			mouseoverColor = Options.Color(L["Mouseover outline colour"], 4, highlight, "mouseoverColor", apply,
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
		portrait = portraitGroup(def),
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
