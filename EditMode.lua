--------------------------------------------------------------------------------
-- Puts PredUI bars into Blizzard's Edit Mode: its selection box, grid, snap
-- preview lines and magnetism.
--
--   * Edit Mode's snapping only needs a frame to answer a few questions about
--     where it is (GetScaledSelectionSides, IsAboveFrame, SnapToFrame...). They
--     are added here, so a bar can snap without being a real Edit Mode system.
--   * Our frames are only magnetic while one of them is being dragged. If they
--     stayed registered, Blizzard's frames could snap to them and Blizzard's
--     saved layouts would then depend on PredUI.
--   * A snap anchors to the frame it found. That is turned back into a plain
--     position on the screen, which is what we save. So the snap fixes where a
--     bar lands, and bars don't follow the frame afterwards.
--   * Positions are saved as soon as a bar is dropped, in PredUIDB, so Edit
--     Mode's own layouts and its Revert button don't cover them.
--------------------------------------------------------------------------------

local _, ns = ...

local E = {}
ns.EditMode = E

local SELECTION_PADDING = 2    -- Blizzard's gap between snapped selection boxes

local frames = {}              -- [frame] = onMoved
local selected                 -- the Selection box of ours that's selected
local dragged                  -- the frame being dragged

--------------------------------------------------------------------------------
-- What Edit Mode's magnetism asks of a frame
--------------------------------------------------------------------------------

local Snap = {}

function Snap:GetScaledCenter()
	local x, y = self:GetCenter()
	local scale = self:GetScale()
	return x * scale, y * scale
end

function Snap:GetScaledSelectionCenter()
	local x, y = self.Selection:GetCenter()
	local scale = self:GetScale()
	return x * scale, y * scale
end

-- left, right, bottom, top
function Snap:GetScaledSelectionSides()
	local left, bottom, width, height = self.Selection:GetRect()
	local scale = self:GetScale()
	return left * scale, (left + width) * scale, bottom * scale, (bottom + height) * scale
end

-- How far the selection box's edge is from the frame's own (they differ: a
-- bar's frame is taller than the bar).
function Snap:GetSelectionOffset(point, forYOffset)
	local sLeft, sBottom, sWidth, sHeight = self.Selection:GetRect()
	local left, bottom, width, height = self:GetRect()
	local offset
	if forYOffset then
		if point:find("TOP") then
			offset = sBottom + sHeight - bottom - height + SELECTION_PADDING
		elseif point:find("BOTTOM") then
			offset = sBottom - bottom - SELECTION_PADDING
		else
			offset = sBottom + sHeight / 2 - bottom - height / 2
		end
	elseif point:find("LEFT") then
		offset = sLeft - left - SELECTION_PADDING
	elseif point:find("RIGHT") then
		offset = sLeft + sWidth - left - width + SELECTION_PADDING
	else
		offset = sLeft + sWidth / 2 - left - width / 2
	end
	return offset * self:GetScale()
end

function Snap:GetCombinedSelectionOffset(frameInfo, forYOffset)
	local offset = -self:GetSelectionOffset(frameInfo.point, forYOffset) + frameInfo.offset
	if frameInfo.frame.Selection then
		offset = offset + frameInfo.frame:GetSelectionOffset(frameInfo.relativePoint, forYOffset)
	end
	return offset / self:GetScale()
end

function Snap:GetCombinedCenterOffset(other)
	local x, y = self:GetScaledCenter()
	local otherX, otherY
	if other.GetScaledCenter then
		otherX, otherY = other:GetScaledCenter()
	else
		otherX, otherY = other:GetCenter()
	end
	local scale = self:GetScale()
	return (x - otherX) / scale, (y - otherY) / scale
end

function Snap:GetSnapOffsets(frameInfo)
	if frameInfo.isCornerSnap then
		return self:GetCombinedSelectionOffset(frameInfo, false), self:GetCombinedSelectionOffset(frameInfo, true)
	end
	local x, y = self:GetCombinedCenterOffset(frameInfo.frame)
	if frameInfo.isHorizontal then
		x = self:GetCombinedSelectionOffset(frameInfo, false)
	else
		y = self:GetCombinedSelectionOffset(frameInfo, true)
	end
	return x, y
end

function Snap:SnapToFrame(frameInfo)
	local x, y = self:GetSnapOffsets(frameInfo)
	self:ClearAllPoints()
	self:SetPoint(frameInfo.point, frameInfo.frame, frameInfo.relativePoint, x, y)
end

function Snap:IsToTheLeftOfFrame(other)
	local _, right = self:GetScaledSelectionSides()
	return right < (other:GetScaledSelectionSides())
end

function Snap:IsToTheRightOfFrame(other)
	local left = self:GetScaledSelectionSides()
	return left > select(2, other:GetScaledSelectionSides())
end

function Snap:IsAboveFrame(other)
	local _, _, bottom = self:GetScaledSelectionSides()
	return bottom > select(4, other:GetScaledSelectionSides())
end

function Snap:IsBelowFrame(other)
	local _, _, _, top = self:GetScaledSelectionSides()
	return top < select(3, other:GetScaledSelectionSides())
end

function Snap:IsVerticallyAlignedWithFrame(other)
	local _, _, bottom, top = self:GetScaledSelectionSides()
	local _, _, otherBottom, otherTop = other:GetScaledSelectionSides()
	return top >= otherBottom and bottom <= otherTop
end

function Snap:IsHorizontallyAlignedWithFrame(other)
	local left, right = self:GetScaledSelectionSides()
	local otherLeft, otherRight = other:GetScaledSelectionSides()
	return right >= otherLeft and left <= otherRight
end

function Snap:GetFrameMagneticEligibility(other)
	if other == self then return nil end
	if other.HasValidSelectionRect and not other:HasValidSelectionRect() then return nil end
	return self:IsVerticallyAlignedWithFrame(other) and (self:IsToTheLeftOfFrame(other) or self:IsToTheRightOfFrame(other)),
		self:IsHorizontallyAlignedWithFrame(other) and (self:IsAboveFrame(other) or self:IsBelowFrame(other))
end

--------------------------------------------------------------------------------
-- Dragging and selecting
--------------------------------------------------------------------------------

local function SetOthersMagnetic(frame, on)
	if not EditModeMagnetismManager then return end
	for other in pairs(frames) do
		if other ~= frame then
			if on and other:IsVisible() then
				EditModeMagnetismManager:RegisterFrame(other)
			else
				EditModeMagnetismManager:UnregisterFrame(other)
			end
		end
	end
end

-- Whatever it snapped to, leave it placed on the screen itself.
local function PlaceOnScreen(frame)
	local x, y = frame:GetCenter()
	local screenX, screenY = UIParent:GetCenter()
	local scale = frame:GetScale()
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "CENTER", x - screenX / scale, y - screenY / scale)
end

local function Select(selection)
	if selected == selection then return end
	if selected then selected:ShowHighlighted() end
	EditModeManagerFrame:ClearSelectedSystem()
	selection:ShowSelected()
	selected = selection
end

local function StopDrag(frame)
	dragged = nil
	frame:StopMovingOrSizing()
	EditModeManagerFrame:ClearSnapPreviewFrame()
end

local function OnDragStart(selection)
	local frame = selection:GetParent()
	Select(selection)
	SetOthersMagnetic(frame, true)
	frame:StartMoving()
	dragged = frame
	EditModeManagerFrame:SetSnapPreviewFrame(frame)
end

local function OnDragStop(selection)
	local frame = selection:GetParent()
	if dragged ~= frame then return end
	StopDrag(frame)
	if EditModeManagerFrame:IsSnapEnabled() then
		EditModeMagnetismManager:ApplyMagnetism(frame)
	end
	SetOthersMagnetic(frame, false)
	PlaceOnScreen(frame)
	frames[frame](frame)
end

--------------------------------------------------------------------------------
-- For the modules
--------------------------------------------------------------------------------

-- Makes frame movable in Edit Mode. onMoved(frame) runs after each drop.
-- selectionTarget is the region the selection box covers.
function E.Add(frame, label, selectionTarget, onMoved)
	if not EditModeManagerFrame or frames[frame] then return end
	local selection = CreateFrame("Frame", nil, frame, "EditModeSystemSelectionTemplate")
	selection:SetAllPoints(selectionTarget)
	selection.system = { GetSystemName = function() return label end }
	selection:SetScript("OnMouseDown", Select)
	selection:SetScript("OnDragStart", OnDragStart)
	selection:SetScript("OnDragStop", OnDragStop)
	selection:Hide()
	frame.Selection = selection
	Mixin(frame, Snap)
	frames[frame] = onMoved
end

function E.Show(frame)
	if frames[frame] then frame.Selection:ShowHighlighted() end
end

function E.Hide(frame)
	if not frames[frame] then return end
	if dragged == frame then
		StopDrag(frame)
		SetOthersMagnetic(frame, false)
	end
	if selected == frame.Selection then selected = nil end
	frame.Selection:Hide()
end

-- Runs onEnter / onExit when Edit Mode opens and closes.
function E.Watch(onEnter, onExit)
	if not EditModeManagerFrame then return end
	hooksecurefunc(EditModeManagerFrame, "EnterEditMode", onEnter)
	hooksecurefunc(EditModeManagerFrame, "ExitEditMode", onExit)
	if E.watching then return end
	E.watching = true
	-- Selecting one of Blizzard's frames deselects ours.
	hooksecurefunc(EditModeManagerFrame, "SelectSystem", function()
		if selected then
			selected:ShowHighlighted()
			selected = nil
		end
	end)
end
