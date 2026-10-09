-- YieldTracker GUI 1.0.1.10. Read-only view of the harvest data.
YieldTrackerPage = {}
YieldTrackerPage._mt = Class(YieldTrackerPage, TabbedMenuFrameElement)
YieldTrackerPage.dir = g_currentModDirectory

function YieldTrackerPage.new(i18n, messageCenter)
    local self = YieldTrackerPage:superClass().new(nil, YieldTrackerPage._mt)
    self.name, self.hasCustomMenuButtons = "YieldTrackerPage", true
    self.i18n, self.messageCenter = i18n, messageCenter
    self.farmlandIDs, self.cropInfo, self.yieldYears = {}, {}, {}
    self.bars, self.ticks = {}, {}
    self.showingOwnedFields = false
    return self
end

function YieldTrackerPage:text(key) return self.i18n:getText("yt_" .. key) end
function YieldTrackerPage:volume(value) return self.i18n:formatNumber(value, 0) .. " l" end

function YieldTrackerPage:onGuiSetupFinished()
    YieldTrackerPage:superClass().onGuiSetupFinished(self)
    for _, id in ipairs({"farmlandList", "cropList", "yieldPerYearList", "fieldFilterButton", "resetSelectionButton",
        "emptyFieldsText", "emptyCropsText", "detailTitle", "totalText", "averageText",
        "bestText", "statsNote", "graphTitle", "scaleText", "barGraph", "noYieldHistoryText"}) do
        self[id] = self:getDescendantById(id)
    end
    for _, list in ipairs({self.farmlandList, self.cropList, self.yieldPerYearList}) do
        list:setDataSource(self)
        list:setDelegate(self)
    end
    -- Keep a valid navigation cursor while allowing no active data selection.
    -- SmoothList normally re-applies its cursor highlight on focus/scroll.
    for _, list in ipairs({self.farmlandList, self.cropList}) do
        local applySelection, focusEnter = list.applyElementSelection, list.onFocusEnter
        list.applyElementSelection = function(element)
            if element.ytSelectionCleared then element:clearElementSelection()
            else applySelection(element) end
        end
        list.onFocusEnter = function(element)
            if element.ytSelectionCleared then element:clearElementSelection()
            else focusEnter(element) end
        end
    end
    for i = 1, 20 do
        self.bars[i] = self:getDescendantById("bar" .. i)
        self.ticks[i] = self:getDescendantById("tick" .. i)
    end
    self:getDescendantById("pageHeaderIcon"):setImageFilename(
        Utils.getFilename("images/page_header_icon.dds", YieldTrackerPage.dir))
    self.filterButtonInfo = {inputAction = InputAction.MENU_ACTIVATE,
        callback = function() self:onClickToggleOwned() end}
    self.menuButtons = {{inputAction = InputAction.MENU_BACK}, self.filterButtonInfo}
    self:setMenuButtonInfo(self.menuButtons)
    self:updateFilterText()
    self.resetSelectionButton:setDisabled(true)
    self:updateDetails()
end

function YieldTrackerPage:updateFilterText()
    local label = self:text(self.showingOwnedFields and "showAll" or "showOwned")
    self.fieldFilterButton:setText(label)
    self.filterButtonInfo.text = label
    self:setMenuButtonInfoDirty()
end

function YieldTrackerPage:onClickToggleOwned()
    self.showingOwnedFields = not self.showingOwnedFields
    self:updateFilterText()
    self:refreshData()
end

function YieldTrackerPage:onClickResetSelection()
    self.selectedField, self.selectedCrop = nil, nil
    self.farmlandList.ytSelectionCleared, self.cropList.ytSelectionCleared = true, true
    self.farmlandList:clearElementSelection()
    self.cropList:clearElementSelection()
    self.resetSelectionButton:setDisabled(true)
    self:updateDetails()
    FocusManager:setFocus(self.fieldFilterButton)
end

-- Clicking or confirming the retained navigation cursor also selects it again.
function YieldTrackerPage:onClickSelection(list, section, index)
    self:onListSelectionChanged(list, section, index)
end

function YieldTrackerPage:onFrameOpen()
    YieldTrackerPage:superClass().onFrameOpen(self)
    self:refreshData()
    FocusManager:setFocus(self.selectedField ~= nil and self.farmlandList or self.fieldFilterButton)
end

function YieldTrackerPage:buildCropList()
    local crops, seen = {}, {}
    local manager = g_fillTypeManager
    local function add(index, fallback)
        if type(index) ~= "number" or index == FillType.UNKNOWN or seen[index] then return end
        local desc = manager ~= nil and manager:getFillTypeByIndex(index) or nil
        if desc == nil then return end
        local title = desc.title or desc.name or fallback or tostring(index)
        if title:sub(1, 6) == "$l10n_" then title = self.i18n:getText(title:sub(7)) end
        seen[index] = true
        table.insert(crops, {fillTypeIndex=index, title=title,
            hudOverlayFilename=desc.hudOverlayFilename or desc.iconFilename})
    end
    if g_fruitTypeManager ~= nil then
        for _, fruit in pairs(g_fruitTypeManager:getFruitTypes() or {}) do
            local fill = fruit.fillType
            add(type(fill) == "table" and (fill.index or fill.fillTypeIndex)
                or type(fill) == "number" and fill or fruit.fillTypeIndex, fruit.name)
        end
    end
    if manager ~= nil then
        for _, name in ipairs({"GRASS", "DRYGRASS_WINDROW", "CHAFF", "STRAW", "STRAW_WINDROW"}) do
            add(manager:getFillTypeIndexByName(name), name)
        end
    end
    -- Keep registered custom materials with historical yields accessible.
    for _, fields in pairs(YieldTracker.yieldData or {}) do
        for _, values in pairs(fields) do
            for index, entry in pairs(values) do add(index, entry.fillTypeTitle) end
        end
    end
    table.sort(crops, function(a,b)
        if a.title:lower() == b.title:lower() then return a.fillTypeIndex < b.fillTypeIndex end
        return a.title:lower() < b.title:lower()
    end)
    self.cropInfo = crops
end

function YieldTrackerPage:refreshData()
    self.refreshing = true -- reloadData can emit selection callbacks
    local oldField, oldCrop = self.selectedField, self.selectedCrop
    self.farmlandIDs = {}
    local farmId = g_currentMission:getFarmId()
    for id, farmland in pairs(g_farmlandManager.farmlands or {}) do
        if farmland.showOnFarmlandsScreen and YieldTracker:hasRegisteredField(id)
            and (not self.showingOwnedFields or farmland.farmId == farmId) then
            table.insert(self.farmlandIDs, id)
        end
    end
    table.sort(self.farmlandIDs)
    self:buildCropList()
    local fieldIndex, cropIndex
    if not self.hasLoadedData then fieldIndex, cropIndex = 1, 1 end
    self.hasLoadedData = true
    for i,id in ipairs(self.farmlandIDs) do if id == oldField then fieldIndex = i end end
    for i,crop in ipairs(self.cropInfo) do if crop.fillTypeIndex == oldCrop then cropIndex = i end end
    self.selectedField = self.farmlandIDs[fieldIndex]
    self.selectedCrop = self.cropInfo[cropIndex] and self.cropInfo[cropIndex].fillTypeIndex or nil
    self.farmlandList.ytSelectionCleared = self.selectedField == nil
    self.cropList.ytSelectionCleared = self.selectedCrop == nil
    self.farmlandList:reloadData()
    self.cropList:reloadData()
    if self.selectedField ~= nil then self.farmlandList:setSelectedIndex(fieldIndex, true) end
    if self.selectedCrop ~= nil then self.cropList:setSelectedIndex(cropIndex, true) end
    self.emptyFieldsText:setVisible(#self.farmlandIDs == 0)
    self.emptyCropsText:setVisible(#self.cropInfo == 0)
    self.emptyFieldsText:setText(self:text("noFields"))
    self.emptyCropsText:setText(self:text("noCrops"))
    self.resetSelectionButton:setDisabled(self.selectedField == nil and self.selectedCrop == nil)
    self.refreshing = false
    self:updateDetails()
end

function YieldTrackerPage:onListSelectionChanged(list, section, index)
    if self.refreshing then return end
    if list == self.farmlandList then
        self.selectedField = self.farmlandIDs[index]
    elseif list == self.cropList then
        self.selectedCrop = self.cropInfo[index] and self.cropInfo[index].fillTypeIndex or nil
    else
        return
    end
    list.ytSelectionCleared = (list == self.farmlandList and self.selectedField == nil)
        or (list == self.cropList and self.selectedCrop == nil)
    list:applyElementSelection()
    self.resetSelectionButton:setDisabled(self.selectedField == nil and self.selectedCrop == nil)
    self:updateDetails()
end

function YieldTrackerPage:collectHistory()
    self.yieldYears = {}
    if self.selectedField == nil or self.selectedCrop == nil then return end
    local first, last = nil, math.floor(g_currentMission.environment.currentYear or 1)
    local amounts = {}
    for year, fields in pairs(YieldTracker.yieldData or {}) do
        local crops = fields[self.selectedField]
        local entry = crops and crops[self.selectedCrop]
        if entry ~= nil and type(year) == "number" and year == math.floor(year) then
            local amount = tonumber(entry.amount)
            if amount ~= nil and amount == amount and amount >= 0 and amount < math.huge then
                amounts[year] = amount
                first = first == nil and year or math.min(first, year)
                last = math.max(last, year)
            end
        end
    end
    if first == nil then return end
    for year = last, first, -1 do
        table.insert(self.yieldYears, {year=year, amount=amounts[year] or 0})
    end
end

function YieldTrackerPage:fetchOverviewStats()
    local stats = {totalAmount=0, totalYears=0, averageYield=0, highestYieldAmount=0}
    for _,entry in ipairs(self.yieldYears) do
        if entry.amount > 0 then
            stats.totalAmount = stats.totalAmount + entry.amount
            stats.totalYears = stats.totalYears + 1
            if entry.amount > stats.highestYieldAmount then
                stats.highestYieldAmount = entry.amount
                stats.highestYear = entry.year
            end
        end
    end
    if stats.totalYears > 0 then stats.averageYield = stats.totalAmount / stats.totalYears end
    return stats
end

function YieldTrackerPage:updateDetails()
    self:collectHistory()
    local selected
    for _, crop in ipairs(self.cropInfo) do
        if crop.fillTypeIndex == self.selectedCrop then selected = crop end
    end
    local valid = self.selectedField ~= nil and selected ~= nil
    self.detailTitle:setText(valid and (self:text("fieldIDLabel") .. " " .. self.selectedField .. "  ·  " .. selected.title)
        or self:text("selectPrompt"))
    local stats = self:fetchOverviewStats()
    local hasData = #self.yieldYears > 0
    self.totalText:setText(hasData and self:volume(stats.totalAmount) or "–")
    self.averageText:setText(stats.totalYears > 0 and self:volume(stats.averageYield) or "–")
    self.bestText:setText(stats.totalYears > 0 and self:volume(stats.highestYieldAmount) or "–")
    self.statsNote:setText(valid and string.format(self:text("statsNote"), stats.totalYears, stats.highestYear or "–") or "")
    self.noYieldHistoryText:setVisible(not hasData)
    self.noYieldHistoryText:setText(self:text(valid and "noYieldHistoryMsg" or "selectPrompt"))
    self.yieldPerYearList:reloadData()
    self:setGraphData()
end

function YieldTrackerPage:setGraphData()
    -- Fixed pool prevents leaking cloned elements and stale bars on empty selections.
    for i=1,20 do self.bars[i]:setVisible(false); self.ticks[i]:setVisible(false) end
    self.scaleText:setText("")
    if #self.yieldYears == 0 then return end
    local last = self.yieldYears[1].year
    local first = math.max(self.yieldYears[#self.yieldYears].year, last - 19)
    local values, maximum = {}, 0
    for _, entry in ipairs(self.yieldYears) do
        if entry.year >= first then
            values[entry.year] = entry.amount
            maximum = math.max(maximum, entry.amount)
        end
    end
    self.scaleText:setText(string.format(self:text("scale"), self:volume(maximum), first, last))
    local width, height = self.barGraph.size[1], self.barGraph.size[2]
    local count = last - first + 1
    local slot = width / count
    local tickHeight = self.ticks[1].size[2]
    for i=1,count do
        local year = first + i - 1
        local amount = values[year] or 0
        local bar, tick = self.bars[i], self.ticks[i]
        bar:setSize(slot * 0.55, maximum > 0 and height * amount / maximum or 0)
        bar:setPosition((i - 1) * slot + slot * 0.225, 0)
        bar:setVisible(amount > 0)
        tick:setSize(slot, tickHeight)
        tick:setPosition((i - 1) * slot, -tickHeight - 0.003)
        tick:setText(tostring(year))
        tick:setVisible(count <= 10 or i % 2 == 1 or i == count)
    end
end

function YieldTrackerPage:getNumberOfSections() return 1 end
function YieldTrackerPage:getTitleForSectionHeader() return "" end
function YieldTrackerPage:getCellTypeForItemInSection() return "default" end
function YieldTrackerPage:getNumberOfItemsInSection(list)
    if list == self.farmlandList then return #self.farmlandIDs end
    if list == self.cropList then return #self.cropInfo end
    if list == self.yieldPerYearList then return #self.yieldYears end
    return 0
end

function YieldTrackerPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.farmlandList then
        local id = self.farmlandIDs[index]
        local farmland = g_farmlandManager.farmlands[id]
        cell:getAttribute("field"):setText(self:text("fieldIDLabel") .. " " .. tostring(id))
        local area = farmland and tonumber(farmland.areaInHa)
        cell:getAttribute("area"):setText(area ~= nil and area > 0 and (self.i18n:formatNumber(area, 2) .. " ha") or "–")
    elseif list == self.cropList then
        local crop = self.cropInfo[index]
        cell:getAttribute("crop"):setText(crop.title)
        local icon = cell:getAttribute("icon")
        local hasIcon = crop.hudOverlayFilename ~= nil and crop.hudOverlayFilename ~= ""
        icon:setVisible(hasIcon)
        if hasIcon then icon:setImageFilename(crop.hudOverlayFilename) end
    elseif list == self.yieldPerYearList then
        local entry = self.yieldYears[index]
        cell:getAttribute("year"):setText(tostring(entry.year))
        cell:getAttribute("amount"):setText(self:volume(entry.amount))
    end
end
