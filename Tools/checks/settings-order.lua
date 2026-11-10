-- AddonCheck scenario: every page of the settings menu is in alphabetical order.
-- Rebuilds the menu with recording stand-ins, then compares what was added.

local pages, page = {}, nil

local function NewPage(name)
	page = { name = name, sections = {} }
	page.section = { name = "", rows = {} }
	page.sections[1] = page.section
	pages[#pages + 1] = page
	return { GetID = function() return #pages end }, { AddInitializer = function() end }
end

local function Row(label)
	local rows = page.section.rows
	if label ~= "" then rows[#rows + 1] = label end
end

rawset(G.Settings, "RegisterVerticalLayoutCategory", NewPage)
rawset(G.Settings, "RegisterVerticalLayoutSubcategory", function(_, name) return NewPage(name) end)
rawset(G.Settings, "RegisterProxySetting", function(_, _, _, label) Row(label) return {} end)
rawset(G.Settings, "RegisterAddOnCategory", function() end)
rawset(G, "CreateSettingsListSectionHeaderInitializer", function(text)
	page.section = { name = text, rows = {} }
	page.sections[#page.sections + 1] = page.section
	return {}
end)
rawset(G, "CreateSettingsButtonInitializer", function(label) Row(label) return {} end)

Fire("ADDON_LOADED", "PredUI")

local function Sorted(list, what)
	for i = 2, #list do
		local a, b = list[i - 1]:lower(), list[i]:lower()
		expect(a <= b, what .. ": '" .. list[i - 1] .. "' comes before '" .. list[i] .. "'")
	end
end

expect(#pages > 1, "the menu was rebuilt")
local names = {}
for i = 2, #pages do names[#names + 1] = pages[i].name end
Sorted(names, "module pages")

for i, p in ipairs(pages) do
	local headers = {}
	-- Section 1 is the rows before any header. A module page's own title header
	-- (section 2) is always first, so the sorted sections start after it.
	for s = (i == 1 and 2 or 3), #p.sections do headers[#headers + 1] = p.sections[s].name end
	Sorted(headers, p.name .. " sections")
	for _, section in ipairs(p.sections) do
		Sorted(section.rows, p.name .. " / " .. section.name)
	end
end

note(#pages .. " pages checked")
