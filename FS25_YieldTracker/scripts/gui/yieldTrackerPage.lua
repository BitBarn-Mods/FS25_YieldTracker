-- Author: BitBarn Mods
-- Date: 06-11-2025
-- Version: 1.0.0.0
-- yieldTrackerPage.lua

PRINT_PREFIX = "[ YieldTracker ] - "


YieldTrackerPage = {}
YieldTrackerPage._mt = Class(YieldTrackerPage, TabbedMenuFrameElement)
YieldTrackerPage.debug = false
YieldTrackerPage.dir = g_currentModDirectory

source(g_currentModDirectory .. "scripts/yieldTrackerPage.lua") --> YieldTracker.yieldData
source(g_currentModDirectory .. "scripts/trackedCropTypes.lua") --> TrackedCropTypes

local trackedCropTypes = TrackedCropTypes


function YieldTrackerPage.new(i18n, messageCenter)
    local self = YieldTrackerPage:superClass().new(nil, YieldTrackerPage._mt)
    self.name = "YieldTrackerPage"
    self.hasCustomMenuButtons = true
    self.i18n = i18n
    self.messageCenter = messageCenter
    self.dataBindings = {}
    self.farmlandIDs = {}
    self.yieldYears = {}
    self.cropInfo = trackedCropTypes
    self.selectedCrop = trackedCropTypes[1].fillTypeIndex
    self.selectedField = 1
    self.showingOwnedFields = false


    return self
end


local function formatWithCommas(n)
    n = math.floor(n + 0.5)  -- Round to nearest whole number
    local formatted = tostring(n)
    local k
    while true do
        formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end


function YieldTrackerPage:setupCustomButtons()
    
    self.backButtonInfo = {
		inputAction = InputAction.MENU_BACK
	}

    self.showAllFieldButton = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = "Show Owned Fields",
        callback = function ()
            self.showingOwnedFields = not self.showingOwnedFields

            if self.showingOwnedFields then
                self.showAllFieldButton.text = "Show All Fields"
                self:onShowOwnedFieldList() -- Call your actual method
            else
                self.showAllFieldButton.text = "Show Owned Fields"
                self:onShowAllFieldList()
            end

            self:setMenuButtonInfoDirty() -- Refresh the button text
        end
    }

    local info = {
		self.backButtonInfo,
        self.showAllFieldButton,
	}

    self.menuButtons = info

    self:setMenuButtonInfo(self.menuButtons)
end


function YieldTrackerPage:onShowOwnedFieldList()
    self:getFarmlandIDs()
    if self.farmlandList then
        self.farmlandList:reloadData()
    end
end


function YieldTrackerPage:onShowAllFieldList()
    self:getFarmlandIDs()
    if self.farmlandList then
        self.farmlandList:reloadData()
    end
end


function YieldTrackerPage:setButtons()
	local info = {
		self.backButtonInfo,
        self.showAllFieldButton,
	}

    self.menuButtons = info

	self:setMenuButtonInfoDirty()
end


function YieldTrackerPage:onGuiSetupFinished()
    YieldTrackerPage:superClass().onGuiSetupFinished(self)

    -- custom menu buttons
    self:setupCustomButtons()

    -- farm id list handling
    self.farmlandList = self:getDescendantById("farmlandList")
    self.farmlandList:setDataSource(self)
    self.farmlandList:setDelegate(self)

    -- crop list/fill type handling
    self.cropList = self:getDescendantById("cropList")
    self.cropList:setDataSource(self)
    self.cropList:setDelegate(self)

    if self.cropList then
        self.cropList:reloadData()
    end

    -- users yield history list
    self.yieldPerYearList = self:getDescendantById("yieldPerYearList")
    self.yieldPerYearList:setDataSource(self)
    self.yieldPerYearList:setDelegate(self)

    -- debuggers
    self:debugMessage("YieldPerYearList found: " .. tostring(self.yieldPerYearList ~= nil))
    self:debugMessage("CropList found: " .. tostring(self.cropList ~= nil))
    self:debugMessage("FarmlandList found: " .. tostring(self.farmlandList ~= nil))

    -- Set initial search param based on self.selectedField and self.selectedCrop
    self:setSelectedPageData()
end



function YieldTrackerPage:onFrameOpen()
    YieldTrackerPage:superClass().onFrameOpen(self)
    self:getFarmlandIDs()

    if self.farmlandList then
        self.farmlandList:reloadData()
        FocusManager:setFocus(self.farmlandList)
    else
        self:debugMessage("Error: farmlandList not found in onFrameOpen")
    end

    if self.yieldPerYearList then
        self:setSelectedPageData()
        self.yieldPerYearList:reloadData()
    end
end


function YieldTrackerPage:getFarmlandIDs()
    local farmlandIDs = {}
    for id, farmland in pairs(g_farmlandManager.farmlands) do
        if farmland.showOnFarmlandsScreen then
            local isOwned = farmland.farmId == g_currentMission:getFarmId()
            if self.showingOwnedFields then
                if isOwned then
                    table.insert(farmlandIDs, id)
                end
            else
                table.insert(farmlandIDs, id)
            end
        end
    end
    table.sort(farmlandIDs)
    self.farmlandIDs = farmlandIDs
    return farmlandIDs
end


function YieldTrackerPage:onClickCropSelected(element)
    local selected = self.cropInfo[element.indexInSection]
    self.selectedCrop = selected.fillTypeIndex
    self:setSelectedPageData()
end


function YieldTrackerPage:onClickFieldSelected(element)
    self.selectedField = self.farmlandIDs[element.indexInSection]
    self:setSelectedPageData()
end


function YieldTrackerPage:setSelectedPageData()
    self:initiateFieldCropStatsSearch()
    self:setOverviewStatsText()

    self:setGraphData()
end


function YieldTrackerPage:initiateFieldCropStatsSearch()
    local selectedField = self.selectedField
    local selectedFillTypeIndex = self.selectedCrop
    local yieldData = YieldTracker.yieldData
    local currentYear = g_currentMission.environment.currentYear
    local foundData = false
    self.yieldYears = {} -- Clear existing data

    self:debugMessage(string.format("Search stats for fill type index %d on field %d", selectedFillTypeIndex, selectedField))

    local yearAmountMap = {}
    local minYear = nil

    -- Step 1: Collect data and find min year
    for year, yearData in pairs(yieldData) do
        local fieldData = yearData[selectedField]
        if fieldData then
            local cropData = fieldData[selectedFillTypeIndex]
            if cropData then
                yearAmountMap[year] = cropData.amount
                minYear = (minYear == nil or year < minYear) and year or minYear
                foundData = true

                self:debugMessage(string.format(
                    "Year %d - Field %d - Crop: %s - Amount: %d",
                    year, selectedField, cropData.fillTypeTitle, cropData.amount
                ))
            else
                self:debugMessage(string.format("Year %d - Field %d - No data for fill type index %d", year, selectedField, selectedFillTypeIndex))
            end
        else
            self:debugMessage(string.format("Year %d - No data for field %d", year, selectedField))
        end
    end


    -- Step 2: Fill in all years from startYear (e.g., 1) to maxYear
    local startYear = 1 -- You can change this to the actual first possible year
    if minYear ~= nil then
        local maxYear = currentYear
        -- Extend maxYear to the latest year found in data if it's greater
        for year in pairs(yearAmountMap) do
            if year > maxYear then
                maxYear = year
            end
        end

        for year = startYear, maxYear do
            local amount = yearAmountMap[year] or 0
            table.insert(self.yieldYears, {
                year = year,
                amount = amount
            })
        end
    end

    -- -- Sort by year ascending
    -- table.sort(self.yieldYears, function(a, b) return a.year < b.year end)
    -- Sort by year descending
    table.sort(self.yieldYears, function(a, b) return a.year > b.year end)

    if self.yieldPerYearList then
        self.yieldPerYearList:reloadData()
    end

    -- Show message only if no data found
    self.noYieldHistoryText:setVisible(not foundData)
    self.yieldStatsInformation:setVisible(foundData)
end


function YieldTrackerPage:setOverviewStatsText()
    local cropName = ""
    local cropIcon = ""
    local fieldID = self.selectedField or 0

    -- Get crop name from fillTypeIndex
    for _, crop in ipairs(self.cropInfo) do
        if crop.fillTypeIndex == self.selectedCrop then
            cropName = crop.title
            cropIcon = crop.hudOverlayFilename
            break
        end
    end

    local pageIcon = Utils.getFilename("images/page_header_icon.dds", YieldTrackerPage.dir)
    local pageHeaderIcon = self:getDescendantById("pageHeaderIcon")
    pageHeaderIcon:setImageFilename(pageIcon)

    local selectedOverviewData = self:fetchOverviewStats()
    local selectedFieldNumText = self:getDescendantById("selectedFieldNumText")
    local selectedCropTypeText = self:getDescendantById("selectedCropTypeText")
    local selectedCropTypeIcon = self:getDescendantById("selectedCropicon")
    local selectedCropTotalHarvests = self:getDescendantById("selectedCropTotalHarvests")
    local selectedCropAverageYield = self:getDescendantById("selectedCropAverageYield")
    local selectedCropBestYear = self:getDescendantById("selectedCropBestYear")

    if selectedFieldNumText and selectedCropTypeText and selectedCropTypeIcon and selectedCropTotalHarvests and selectedCropAverageYield and selectedCropBestYear then
        selectedFieldNumText:setText(string.format("%s %d", self.i18n:getText("yt_fieldIDLabel"), fieldID))

        local cropKey = cropName:lower():gsub(" ", "") .. "Label"
        selectedCropTypeText:setText(self.i18n:getText(cropKey) or cropName)

        selectedCropTotalHarvests:setText(selectedOverviewData.totalYears)
        selectedCropAverageYield:setText(string.format("%s l", formatWithCommas(selectedOverviewData.averageYield)))

        selectedCropBestYear:setText(string.format("%s %d  -->  %s l", self.i18n:getText("yt_yearLabel"), selectedOverviewData.highestYear, formatWithCommas(selectedOverviewData.highestYieldAmount)))

        selectedCropTypeIcon:setImageFilename(cropIcon)
    end
end


function YieldTrackerPage:fetchOverviewStats()
    local totalYears = 0
    local totalAmount = 0
    local totalEntries = 0
    local highestYieldAmount = 0
    local highestYear = 0

    for _, entry in ipairs(self.yieldYears) do
        local yearYieldAmount = entry.amount or 0

        if yearYieldAmount > 0 then
            totalAmount = totalAmount + yearYieldAmount
            totalEntries = totalEntries + 1
            totalYears = totalYears + 1

            if yearYieldAmount > highestYieldAmount then
                highestYieldAmount = yearYieldAmount
                highestYear = entry.year
            end
        end
    end

    local averageYield = totalEntries > 0 and (totalAmount / totalEntries) or 0

    return {
        totalYears = totalYears,
        averageYield = averageYield,
        highestYear = highestYear,
        highestYieldAmount = highestYieldAmount
    }
end


-- SET GRAPH FUNCTIONALITY
function YieldTrackerPage:clearOldElements(container, template)
    for i = #container.elements, 1, -1 do
        local child = container.elements[i]
        if child ~= template then
            container:removeElement(child)
        end
    end
end


function YieldTrackerPage:extractYears(data)
    local years = {}
    for _, harvest in ipairs(data) do
        if harvest.year then
            table.insert(years, harvest.year)
        end
    end
    table.sort(years)
    return years
end


function YieldTrackerPage:calculateDisplayRange(minYear, maxYear)
    local rangeYears = maxYear - minYear + 1
    local displayMinYear, displayMaxYear
    if rangeYears >= 20 then
        displayMaxYear = maxYear
        displayMinYear = displayMaxYear - 19
    else
        displayMinYear = minYear
        displayMaxYear = displayMinYear + 19
    end
    return displayMinYear, displayMaxYear
end


function YieldTrackerPage:createHarvestLookup(data, minYear, maxYear)
    local lookup = {}
    for _, harvest in ipairs(data) do
        if harvest.year and harvest.year >= minYear and harvest.year <= maxYear then
            lookup[harvest.year] = harvest
        end
    end
    return lookup
end


function YieldTrackerPage:findMaxYield(harvestByYear, minYear, maxYear)
    local maxYield = 0
    for year = minYear, maxYear do
        local h = harvestByYear[year]
        if h and h.amount and h.amount > maxYield then
            maxYield = h.amount
        end
    end
    return maxYield
end

function YieldTrackerPage:findMinYield(harvestByYear, startYear, endYear)
    local min = math.huge
    for year = startYear, endYear do
        local data = harvestByYear[year]
        if data and data.amount and data.amount < min then
            min = data.amount
        end
    end
    return min
end


function YieldTrackerPage:setGraphData()
    if not self.yieldYears or #self.yieldYears == 0 then return end

    local tickContainer = self:getDescendantById("graphYearTickContainer")
    local barGraph = self:getDescendantById("barGraph")

    self:clearOldElements(tickContainer, self.graphYearTickTemplate)
    self:clearOldElements(barGraph, self.graphCandleTemplate)

    local years = self:extractYears(self.yieldYears)
    if #years == 0 then return end

    local actualMinYear = years[1]
    local actualMaxYear = years[#years]

    local displayMinYear, displayMaxYear = self:calculateDisplayRange(actualMinYear, actualMaxYear)

    local harvestByYear = self:createHarvestLookup(self.yieldYears, displayMinYear, displayMaxYear)

    local maxYield = self:findMaxYield(harvestByYear, displayMinYear, displayMaxYear)
    local minYield = self:findMinYield(harvestByYear, displayMinYear, displayMaxYear)
    local yieldRange = math.max(1, maxYield - minYield)

    local numTicks = displayMaxYear - displayMinYear + 1
    local totalGraphWidth = 0.42
    local spacing = totalGraphWidth / math.max(1, numTicks - 1)



    for year = displayMinYear, displayMaxYear do
        local tickX = (year - displayMinYear) * spacing

        -- Year tick label
        local tickClone = self.graphYearTickTemplate:clone(tickContainer)
        tickClone:setText(tostring(year))
        tickClone:setPosition(tickX, 0)
        tickClone:setVisible(true)

        -- Yield candle if data exists for this year
        local harvest = harvestByYear[year]
        if harvest then
            local yearYieldAmount = harvest.amount or 0
            local candleClone = self.graphCandleTemplate:clone(barGraph)
            local minHeight = 0.08
            local heightRatio = (yearYieldAmount - minYield) / yieldRange
            -- heightRatio = math.sqrt(heightRatio) -- apply easing
            local candleHeight = minHeight + heightRatio * (0.27 - minHeight)

            candleClone:setSize(0.01, candleHeight)
            candleClone:setPosition(tickX + 0.0185, 0)
            candleClone:setVisible(true)
        end
    end
end
-- SET GRAPH FUNCTIONALITY - END


function YieldTrackerPage:populateCellForItemInSection(list, sectionIndex, index, listItem)
    if list == self.farmlandList then
        local farmlandID = self.farmlandIDs[index]
        local fieldIDListText = listItem:getAttribute("fieldIDListText")
        if fieldIDListText then
            fieldIDListText:setText(string.format("%s %d", self.i18n:getText("yt_fieldIDLabel"), farmlandID))
        end
    elseif list == self.cropList then
        local crop = self.cropInfo[index]
        if crop then
            local cropListText = listItem:getAttribute("cropListText")
            local icon = listItem:getAttribute("icon")

            if cropListText then
                local cropKey = crop.title:lower():gsub(" ", "") .. "Label"
                cropListText:setText(self.i18n:getText(cropKey) or crop.title)
            end

            if icon then
                icon:setImageFilename(crop.hudOverlayFilename)
            end
        end
    elseif list == self.yieldPerYearList then
        local entry = self.yieldYears[index]
        if entry then
            local yearText = listItem:getDescendantByName("year")
            local amountText = listItem:getDescendantByName("yieldAmt")
            if yearText then
                yearText:setText(string.format("%s %s", self.i18n:getText("yt_yearLabel"), tostring(entry.year)))
            end
            if amountText then
                amountText:setText(formatWithCommas(entry.amount) .. " l")
            end   
        end
    end
end



function YieldTrackerPage:getCellTypeForItemInSection(_, sectionIndex, index)
    return "default"
end


function YieldTrackerPage:getNumberOfItemsInSection(list, sectionIndex)
    if list == self.farmlandList then
        return #self.farmlandIDs
    elseif list == self.cropList then
        return #self.cropInfo
    elseif list == self.yieldPerYearList then
        return #self.yieldYears
    end
    return 0
end



function YieldTrackerPage:debugMessage(message)
    if self.debug then
        print(PRINT_PREFIX .. message)
    end
end


-- DEBUG
-- function dump(o, indent, depth)
--     indent = indent or ""
--     depth = depth or 1

--     if type(o) ~= "table" then
--         return tostring(o)
--     elseif depth <= 0 then
--         return "{...}"
--     end

--     local s = "{\n"
--     for k, v in pairs(o) do
--         s = s .. indent .. "  [" .. tostring(k) .. "] = "
--         if type(v) == "table" then
--             s = s .. dump(v, indent .. "  ", depth - 1)
--         else
--             s = s .. tostring(v)
--         end
--         s = s .. "\n"
--     end
--     return s .. indent .. "}"
-- end
