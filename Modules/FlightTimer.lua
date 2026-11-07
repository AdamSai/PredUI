--------------------------------------------------------------------------------
-- Flight Timer: a status bar that counts down the flight you're on.
--
-- The game has no API for a flight's remaining time, so:
--   * TakeTaxiNode is hooked to read the route while the flight map is open.
--   * UnitOnTaxi says when the flight really starts and ends.
--   * The measured time of each finished flight is saved per route, directional
--     ("A > B" and "B > A" are separate), account-wide.
--   * Until a route has been flown, its time is an estimate: the legs already
--     learned, plus straight-line distance at a speed calibrated from your own
--     flights. The bar labels which of these it is showing.
--   * Hovering a destination on the flight map shows the same time in its tooltip
--     (both the small TaxiFrame and the big FlightMapFrame are hooked).
--
-- Flights that were cut short (early landing, death, landing away from the
-- destination) are never learned.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("flight", {
	title = "Flight Timer",
	notes = "A faction-coloured bar counting down your flight. Learns each route's real time the first time you fly it.",
	defaults = { locked = false, tooltip = true },
})

local BAR_W, BAR_H = 340, 22
local DEFAULT_POINT = { "TOP", "TOP", 0, -170 }

local PENDING_TIMEOUT = 15     -- seconds to wait for take-off after picking a destination
local LAND_DEBOUNCE = 0.6      -- UnitOnTaxi must stay false this long to count as landed
local RESUME_GRACE = 3         -- the same, right after a /reload
local ARRIVED_RADIUS = 400     -- yards from the destination that still count as arriving
local MIN_LEARN_SECONDS = 5

-- Straight-line yards per second, used until your own flights refine it. The prior
-- counts as PRIOR_SECONDS of flying, so one odd flight can't swing the estimate.
local PRIOR_SPEED, PRIOR_SECONDS = 25, 120

local COLORS = {
	Alliance = { 0.16, 0.50, 1.00 },
	Horde    = { 0.92, 0.13, 0.13 },
	Neutral  = { 0.95, 0.70, 0.20 },
}

local db, charDB
local flight                   -- the flight in progress; also saved so it survives /reload
local pending                  -- what was picked on the flight map, waiting for take-off
local preview                  -- /flighttimer test
local mapNodes = {}            -- [slot] = { name=, inst=, x=, y= }, read when the flight map opens
local mapOrigin                -- name of the node you're standing at, ditto
local bar
local ready                    -- set at the first PLAYER_ENTERING_WORLD

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function OnTaxi()
	local v = Try(UnitOnTaxi, "player")
	if not Public(v) then return nil end   -- nil = can't tell right now
	return v and true or false
end

local Clock = ns.Clock

local function Short(name)
	return name and (name:match("^[^,]+") or name) or "?"
end

local function WorldPos(mapID, pos)
	if not (Public(pos) and pos and mapID and C_Map and C_Map.GetWorldPosFromMapPos) then return end
	local inst, world = Try(C_Map.GetWorldPosFromMapPos, mapID, pos)
	if not (Public(world) and Public(inst)) or not world then return end
	local x, y = Try(world.GetXY, world)
	x, y = PublicNumber(x), PublicNumber(y)
	if x and y then return inst, x, y end
end

local function Distance(a, b)
	if not (a and b and a.x and b.x) or a.inst ~= b.inst then return nil end
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

--------------------------------------------------------------------------------
-- Reading the flight map
--------------------------------------------------------------------------------

-- World and cosmic maps don't convert to world coordinates reliably.
local function UsableForDistance(mapID)
	local info = Try(C_Map and C_Map.GetMapInfo, mapID)
	local mapType = Public(info) and type(info) == "table" and PublicNumber(info.mapType)
	return not (mapType and mapType <= 1)
end

-- Every node the open flight map offers, by slot.
local function ReadMapNodes()
	local count = PublicNumber(Try(NumTaxiNodes)) or 0
	if count == 0 then return false end

	wipe(mapNodes)
	mapOrigin = nil
	local byName = {}
	for slot = 1, count do
		local name = PublicString(Try(TaxiNodeName, slot))
		local kind = Try(TaxiNodeGetType, slot)
		if name then
			mapNodes[slot] = { name = name }
			byName[name] = mapNodes[slot]
			if Public(kind) and kind == "CURRENT" then mapOrigin = name end
		end
	end

	-- Positions come per map: try the flight map's own, then wherever you stand, then
	-- the continents. A node with no position only costs the distance estimate.
	if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
		local maps = { Try(GetTaxiMapID), Try(C_Map and C_Map.GetBestMapForUnit, "player"), 1414, 1415 }
		for i = 1, 4 do
			local mapID = PublicNumber(maps[i])
			local list = mapID and UsableForDistance(mapID) and Try(C_TaxiMap.GetAllTaxiNodes, mapID)
			if Public(list) and type(list) == "table" then
				for _, info in ipairs(list) do
					local slot = type(info) == "table" and PublicNumber(info.slotIndex)
					local node = slot and mapNodes[slot] or type(info) == "table" and byName[PublicString(info.name) or ""]
					if node and not node.x then
						local inst, x, y = WorldPos(mapID, info.position)
						if x then node.inst, node.x, node.y = inst, x, y end
					end
				end
			end
		end
	end
	return true
end

-- The slots a flight to destSlot passes through, origin first. Falls back to just the
-- two ends when the client won't say.
local function ReadRouteSlots(destSlot)
	local hops = PublicNumber(Try(GetNumRoutes, destSlot))
	if not hops or hops < 1 then return nil, nil end
	local slots = {}
	for hop = 1, hops do
		local src = PublicNumber(Try(TaxiGetNodeSlot, destSlot, hop, true))
		local dst = PublicNumber(Try(TaxiGetNodeSlot, destSlot, hop, false))
		if not (src and dst) then return nil, hops end
		if hop == 1 then slots[1] = src end
		slots[#slots + 1] = dst
	end
	if slots[#slots] ~= destSlot and slots[1] == destSlot then   -- given back to front
		local rev = {}
		for i = #slots, 1, -1 do rev[#rev + 1] = slots[i] end
		slots = rev
	end
	return slots, hops
end

local function LegKey(a, b)
	return a .. " > " .. b
end

local function Speed()
	return (PRIOR_SPEED * PRIOR_SECONDS + (db.speedYards or 0)) / (PRIOR_SECONDS + (db.speedSeconds or 0))
end

--------------------------------------------------------------------------------
-- Estimating and learning
--------------------------------------------------------------------------------

-- What the bar shows for a route. kind is one of:
--   learned   this exact route has been flown
--   legs      every leg has been flown, though not this route as a whole
--   distance  at least one leg comes from the distance estimate
--   unknown   no idea yet
local function EstimateRoute(names, nodes)
	local key = table.concat(names, " > ")
	local rec = db.routes[key]
	if rec then return rec.t, "learned", rec.n end

	local total, measuredAll = 0, true
	for i = 1, #names - 1 do
		local leg = db.routes[LegKey(names[i], names[i + 1])]
		if leg then
			total = total + leg.t
		else
			measuredAll = false
			local yards = Distance(nodes[i], nodes[i + 1])
			if not yards then return nil, "unknown" end
			total = total + yards / Speed()
		end
	end
	return total, measuredAll and "legs" or "distance"
end

local function Remember(key, secs)
	local rec = db.routes[key]
	-- Similar to before: average out the jitter. Very different: the route has probably
	-- changed, so trust the new one.
	if rec and math.abs(secs - rec.t) <= rec.t * 0.15 then
		local weight = math.min(rec.n, 4)
		rec.t = (rec.t * weight + secs) / (weight + 1)
		rec.n = rec.n + 1
	else
		db.routes[key] = { t = secs, n = 1 }
	end
end

local function PlayerPos()
	if not C_Map then return end
	local mapID = PublicNumber(Try(C_Map.GetBestMapForUnit, "player"))
	if not mapID then return end
	local inst, x, y = WorldPos(mapID, (Try(C_Map.GetPlayerMapPosition, mapID, "player")))
	if x then return { inst = inst, x = x, y = y } end
end

-- Whether a finished flight went the whole way.
local function ReachedDestination(f, elapsed)
	if f.early then return false end
	local dead = Try(UnitIsDeadOrGhost, "player")
	if Public(dead) and dead then return false end

	local yards = f.dest and Distance(PlayerPos(), f.dest)
	if yards then return yards <= ARRIVED_RADIUS end

	-- No position to check against: compare with what was expected instead.
	if f.total then
		local floor = f.kind == "learned" and 0.7 or 0.4
		return elapsed >= f.total * floor
	end
	return true
end

--------------------------------------------------------------------------------
-- The bar
--------------------------------------------------------------------------------

local function ApplyFactionColor(faction)
	local group = faction or UnitFactionGroup("player")
	local c = COLORS[Public(group) and group or "Neutral"] or COLORS.Neutral
	bar:SetColor(c[1], c[2], c[3])
end

-- What the bar is showing: the real flight or the preview.
local function Current()
	return preview or flight
end

local function Elapsed(f)
	return GetTime() - f.start
end

local function Describe(f)
	if f.isPreview then
		return db.locked and "Preview - bar is locked" or "Preview - drag the bar to move it"
	elseif f.kind == "learned" then
		return f.flights == 1 and "Time learned from your last flight"
			or ("Time learned from %d flights"):format(f.flights or 1)
	elseif f.kind == "legs" then
		return "Estimate from legs you've flown - learning this route now"
	elseif f.kind == "distance" then
		return "Estimate from distance - first flight here, learning it now"
	elseif f.to then
		return "Time unknown - first flight here, learning it now"
	end
	return "Time unknown - started outside the flight map, can't be learned"
end

local function Render()
	local f = Current()
	if not f then return end
	local elapsed = Elapsed(f)
	local frac, urgent = 1, false

	if f.total then
		local remaining = f.total - elapsed
		frac = math.max(0, math.min(1, remaining / f.total))
		urgent = remaining < 10
		local mark = f.kind == "learned" and "" or "~"
		local shownTotal = math.floor(f.total + 0.5)
		if remaining > 0 then
			local shownLeft = math.min(math.ceil(remaining), shownTotal)
			bar:SetTexts(nil, ("%s%s left / %s%s total"):format(mark, Clock(shownLeft), mark, Clock(shownTotal)), Describe(f))
		else
			bar:SetTexts(nil, ("0:00 left / %s%s total"):format(mark, Clock(shownTotal)), "Longer than expected - should be landing soon")
		end
	else
		bar:SetTexts(nil, Clock(elapsed) .. " elapsed / total unknown", Describe(f))
	end

	-- A dim, full bar when there's nothing to count down, so it can't be read as progress.
	bar:Animate(frac, f.total ~= nil, urgent)
end

local function ShowBar()
	bar:ShowBar()
	local f = Current()
	bar:SetTexts(f and f.to and Short(f.to) or "In flight")
	Render()
end

local function HideBar()
	bar.fadeStart = nil
	bar:Hide()
end

local function OnBarUpdate()
	if bar:UpdateFade() then return end
	if preview and Elapsed(preview) >= preview.total then
		preview = nil
		bar:Still(0)
		bar:SetTexts(nil, "0:00", "Preview finished")
		bar:FadeOut()
		return
	end
	Render()
end

local function BuildBar()
	bar = S.Bar({
		name = "PredUIFlightBar", width = BAR_W, height = BAR_H,
		db = db, pointKey = "point", defaultPoint = DEFAULT_POINT,
		locked = function() return db.locked end,
	})
	bar:SetScript("OnUpdate", OnBarUpdate)
	ApplyFactionColor()
end

--------------------------------------------------------------------------------
-- Flight state
--------------------------------------------------------------------------------

local function Begin(picked)
	preview = nil
	local f = picked or {}
	f.start = GetTime()
	f.wall = time()
	flight = f
	charDB.active = f
	ApplyFactionColor()
	ShowBar()
end

local function Land(landedAt)
	local f = flight
	flight, charDB.active = nil, nil
	local elapsed = landedAt - f.start

	-- Never saw it in the air since the /reload: nothing to report.
	if f.unconfirmed then
		if not preview then HideBar() end
		return
	end

	local message
	if not f.key then
		message = ("Landed after %s"):format(Clock(elapsed))
	elseif not ReachedDestination(f, elapsed) then
		message = "Flight cut short - time not saved"
	elseif elapsed < MIN_LEARN_SECONDS then
		message = ("Landed after %s"):format(Clock(elapsed))
	else
		Remember(f.key, elapsed)
		if f.yards then
			db.speedYards = (db.speedYards or 0) + f.yards
			db.speedSeconds = (db.speedSeconds or 0) + elapsed
		end
		message = f.kind == "learned"
			and ("Landed in %s"):format(Clock(elapsed))
			or ("Landed in %s - route learned"):format(Clock(elapsed))
	end

	bar:Still(0)
	bar:SetTexts(nil, Clock(elapsed) .. " flown", message)
	bar:FadeOut()
end

-- Runs a few times a second. UnitOnTaxi has no event of its own, and polling it
-- catches flights however they started.
local function Tick()
	if not ready then return end
	local onTaxi = OnTaxi()
	if onTaxi == nil then return end
	local now = GetTime()

	if flight then
		if onTaxi then
			flight.offSince = nil
			if flight.unconfirmed then
				flight.unconfirmed = nil
				preview = nil
				ApplyFactionColor()
				ShowBar()
			end
		else
			flight.offSince = flight.offSince or now
			local wait = flight.unconfirmed and RESUME_GRACE or LAND_DEBOUNCE
			if now - flight.offSince >= wait then Land(flight.offSince) end
		end
	elseif onTaxi then
		local picked = pending
		pending = nil
		Begin(picked and picked.flight)
	elseif pending and now - pending.asked > PENDING_TIMEOUT then
		pending = nil   -- never took off: no money, cancelled, moved away
	end
end

-- Everything known about a flight from where you stand to destSlot: the route's key,
-- its estimated time and how sure that is. nil if the map can't say.
local function PlanRoute(destSlot)
	local destNode = mapNodes[destSlot]
	local to = destNode and destNode.name or PublicString(Try(TaxiNodeName, destSlot))
	if not (to and mapOrigin) then return end

	local names, nodes
	local slots, hops = ReadRouteSlots(destSlot)
	if slots then
		names, nodes = {}, {}
		for i, slot in ipairs(slots) do
			local node = mapNodes[slot]
			if not node then
				slots = nil
				break
			end
			names[i], nodes[i] = node.name, node
		end
	end
	if not slots then
		-- Only the ends are known, so a route with stops gets a key of its own rather
		-- than being mistaken for a direct leg.
		local origin = false
		for _, node in pairs(mapNodes) do
			if node.name == mapOrigin then origin = node end
		end
		if hops and hops > 1 then
			names = { mapOrigin, ("(%d stops)"):format(hops - 1), to }
			nodes = { origin, false, destNode or false }
		else
			names = { mapOrigin, to }
			nodes = { origin, destNode or false }
		end
	end

	local total, kind, flights = EstimateRoute(names, nodes)

	local yards = 0
	for i = 1, #nodes - 1 do
		local d = Distance(nodes[i] or nil, nodes[i + 1] or nil)
		if not d then
			yards = nil
			break
		end
		yards = yards + d
	end

	return {
		key = table.concat(names, " > "),
		to = to,
		total = total,
		kind = kind,
		flights = flights,
		yards = yards,
		dest = destNode and destNode.x and { inst = destNode.inst, x = destNode.x, y = destNode.y } or nil,
	}
end

local function OnTakeTaxiNode(destSlot)
	if not Public(destSlot) then return end
	ReadMapNodes()   -- mapNodes keeps what TAXIMAP_OPENED read if the map's already gone
	local plan = PlanRoute(destSlot)
	if plan then pending = { asked = GetTime(), flight = plan } end
end

--------------------------------------------------------------------------------
-- Flight time on the flight map's tooltips
--------------------------------------------------------------------------------

local function FormatCost(copper)
	if MoneyFormatterUtil and MoneyFormatterUtil.FormatMoney and GameTooltipMoneyFormat then
		local text = Try(MoneyFormatterUtil.FormatMoney, copper, GameTooltipMoneyFormat)
		if Public(text) and type(text) == "string" and text ~= "" then return text end
	end
	local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	return (g > 0 and g .. "g " or "") .. ((g > 0 or sv > 0) and sv .. "s " or "") .. c .. "c"
end

-- Whether the tooltip already has a line with exactly this text (Blizzard's own cost line).
local function TooltipHasLine(text)
	for i = 1, GameTooltip:NumLines() do
		local line = _G["GameTooltipTextLeft" .. i]
		local have = line and line:GetText()
		if Public(have) and have == text then return true end
	end
	return false
end

-- The flight's cost. Blizzard's tooltip is meant to show it, but it can go missing,
-- so add it unless it's already there.
local function AddCostLine(slot)
	local cost = PublicNumber(Try(TaxiNodeCost, slot))
	if not cost or cost <= 0 then return end
	local text = FormatCost(cost)
	if TooltipHasLine(text) then return end
	local money = PublicNumber(Try(GetMoney))
	if money and money < cost then
		GameTooltip:AddLine("Cost: " .. text, 1, 0.3, 0.3)
	else
		GameTooltip:AddLine("Cost: " .. text, 1, 1, 1)
	end
end

-- Both flight map windows build their tooltip on hover and then call Show(); this
-- adds the cost and time after that. The nodes were read when the map opened
-- (TAXIMAP_OPENED).
local function AddTooltipLine(owner, slot)
	if not db.tooltip or not Public(slot) or not slot then return end
	if GameTooltip:GetOwner() ~= owner then return end
	if not mapOrigin then ReadMapNodes() end
	AddCostLine(slot)
	local plan = PlanRoute(slot)
	if not plan then
		GameTooltip:Show()
		return
	end

	local text
	if not plan.total then
		text = "Flight time: unknown until you fly it"
	elseif plan.kind == "learned" then
		text = "Flight time: " .. Clock(math.floor(plan.total + 0.5))
	else
		text = ("Flight time: ~%s (estimate)"):format(Clock(math.floor(plan.total + 0.5)))
	end
	GameTooltip:AddLine(text, 1, 1, 1)
	GameTooltip:Show()   -- resize to fit the new line
end

-- The small classic window (TaxiFrame). Its XML calls TaxiNodeOnButtonEnter by name.
local function OnTaxiButtonEnter(button)
	if not button then return end
	local kind = Try(TaxiNodeGetType, button:GetID())
	if not Public(kind) then return end
	if kind == "REACHABLE" then
		AddTooltipLine(button, button:GetID())
	elseif kind == "UNREACHABLE" and db.tooltip and GameTooltip:GetOwner() == button then
		-- Blizzard shows only the name here, which looks broken; say why there's no time.
		GameTooltip:AddLine("No flight time: you can't fly here yet", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end
end

-- The big map (Blizzard_FlightMap, load on demand). Pins copy the mixin's OnMouseEnter
-- when they're made, so hooking the mixin covers every pin made afterwards; pins that
-- already exist get the hook on their OnEnter script instead.
local hookedPins = setmetatable({}, { __mode = "k" })
local mixinHooked

local function OnPinEnter(pin)
	local data = pin and pin.taxiNodeData
	if type(data) ~= "table" then return end
	if not (Enum.FlightPathState and data.state == Enum.FlightPathState.Reachable) then return end
	AddTooltipLine(pin, PublicNumber(data.slotIndex))
end

local function HookFlightMap()
	if not FlightMap_FlightPointPinMixin or mixinHooked then return end
	mixinHooked = true
	local iter, state, start
	if FlightMapFrame and FlightMapFrame.EnumeratePinsByTemplate then
		iter, state, start = FlightMapFrame:EnumeratePinsByTemplate("FlightMap_FlightPointPinTemplate")
	end
	if type(iter) == "function" then
		for pin in iter, state, start do
			if not hookedPins[pin] then
				hookedPins[pin] = true
				pin:HookScript("OnEnter", OnPinEnter)
			end
		end
	end
	hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", OnPinEnter)
end

function M:OnAddonLoaded(name)
	if name == "Blizzard_FlightMap" then HookFlightMap() end
end

local function OnEarlyLanding()
	if flight then flight.early = true end
end

-- After a /reload the flight carries on from the saved table. time() keeps running
-- through it, so the elapsed time stays right; GetTime() is only used for smoothness.
local function Resume()
	local saved = charDB.active
	if type(saved) ~= "table" or type(saved.wall) ~= "number" then
		charDB.active = nil
		return
	end
	local gone = math.max(0, time() - saved.wall)
	saved.start = GetTime() - gone
	saved.offSince = nil
	saved.unconfirmed = true   -- stays hidden until UnitOnTaxi says it's still going
	flight = saved
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test(arg)
	if flight and not flight.unconfirmed then
		M.Say("you're in the air, so the bar is busy.")
		return
	end
	preview = {
		isPreview = true,
		to = "Stormwind, Elwynn",
		start = GetTime(),
		total = 30,
		kind = "learned",
		flights = 3,
	}
	local faction = arg == "horde" and "Horde" or arg == "alliance" and "Alliance" or nil
	ApplyFactionColor(faction)
	ShowBar()
	M.Say(db.locked and "preview running. The bar is locked: unlock it to drag it."
		or "preview running. Drag the bar where you want it.")
end

function M.ResetPosition()
	db.point = nil
	S.RestorePoint(bar, db, "point", DEFAULT_POINT)
	M.Say("bar position reset.")
end

local function CountRoutes()
	local n = 0
	for _ in pairs(db.routes) do n = n + 1 end
	return n
end

function M.Forget()
	ns.Confirm("Erase every learned flight time?", function()
		wipe(db.routes)
		db.speedYards, db.speedSeconds = nil, nil
		M.Say("all learned flight times erased.")
	end)
end

function M.Status()
	return ("%d route(s) learned; estimating at %.1f yards a second."):format(CountRoutes(), Speed())
end

local function OnSlash(input)
	local cmd, arg = input:lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "test" then
		M.Test(arg)
	elseif cmd == "lock" or cmd == "unlock" then
		db.locked = cmd == "lock"
		M.Say(db.locked and "bar locked." or "bar unlocked: drag it while it's showing.")
	elseif cmd == "reset" then
		M.ResetPosition()
	elseif cmd == "status" then
		M.Say(M.Status())
	elseif cmd == "nodes" then
		-- What the open flight map reports for each node, to check why a tooltip has no time.
		local count = PublicNumber(Try(NumTaxiNodes)) or 0
		if count == 0 then
			M.Say("open the flight map at a flight master first.")
			return
		end
		M.Say(("%d flight paths on this map:"):format(count))
		for slot = 1, count do
			local name = PublicString(Try(TaxiNodeName, slot)) or "?"
			local kind = Try(TaxiNodeGetType, slot)
			local hops = PublicNumber(Try(GetNumRoutes, slot)) or 0
			print(("  %d. %s - %s, %d hop(s)"):format(slot, name, Public(kind) and tostring(kind) or "?", hops))
		end
	elseif cmd == "forget" then
		M.Forget()
	elseif cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("drag the bar to move it. Commands for /flighttimer (or /ftimer):")
		print("  test [alliance|horde] - show a 30 second preview, to position the bar")
		print("  lock / unlock - stop or allow dragging")
		print("  reset - put the bar back in its default place")
		print("  status - how many routes have been learned")
		print("  nodes - list the open flight map's flight paths and whether you can reach them")
		print("  forget - erase every learned time")
		print("  options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "locked", label = "Lock the bar", tooltip = "Stop the bar from being dragged." },
	{ type = "checkbox", key = "tooltip", label = "Flight time on the flight map", tooltip = "Show the learned or estimated flight time when you hover a destination at a flight master." },
	{ type = "button", label = "Preview", button = "Test bar", tooltip = "Show a 30 second preview so you can place the bar.", func = function() M.Test() end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the bar back in its default place.", func = function() M.ResetPosition() end },
	{ type = "button", label = "Learned times", button = "Forget all", tooltip = "Erase every learned flight time.", func = function() M.Forget() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db, charDB = self.db, self.charDB
	db.routes = type(db.routes) == "table" and db.routes or {}

	BuildBar()
	if TakeTaxiNode then hooksecurefunc("TakeTaxiNode", OnTakeTaxiNode) end
	if TaxiRequestEarlyLanding then hooksecurefunc("TaxiRequestEarlyLanding", OnEarlyLanding) end
	if TaxiNodeOnButtonEnter then hooksecurefunc("TaxiNodeOnButtonEnter", OnTaxiButtonEnter) end
	HookFlightMap()   -- in case Blizzard_FlightMap is already loaded

	local driver = CreateFrame("Frame")
	local sinceTick = 0
	local function OnDriverUpdate(_, dt)
		sinceTick = sinceTick + dt
		local interval = (flight or pending) and 0.1 or 0.5
		if sinceTick >= interval then
			sinceTick = 0
			Tick()
		end
	end

	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:RegisterEvent("TAXIMAP_OPENED")
	driver:RegisterEvent("PLAYER_CONTROL_LOST")
	driver:RegisterEvent("PLAYER_CONTROL_GAINED")
	driver:SetScript("OnEvent", function(self, event, arg1, arg2)
		if event == "PLAYER_ENTERING_WORLD" then
			-- arg1 = logging in, arg2 = /reload; a plain loading screen is neither. After a
			-- logout the time in the air can't be trusted, so a saved flight is only kept on
			-- /reload. If you log in still flying, Tick shows it as an unknown flight.
			ready = true
			self:SetScript("OnUpdate", OnDriverUpdate)
			if arg2 then
				if not flight then Resume() end
			elseif arg1 then
				charDB.active = nil
			end
			Tick()
		elseif event == "TAXIMAP_OPENED" then
			ReadMapNodes()
		else
			Tick()   -- control lost/gained usually means take-off or landing: check right away
		end
	end)
end

SLASH_PREDUIFLIGHT1, SLASH_PREDUIFLIGHT2 = "/flighttimer", "/ftimer"
SlashCmdList.PREDUIFLIGHT = ns.SlashHandler(M, OnSlash)
