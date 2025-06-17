-- Author: BitBarn Mods
-- Date: 06-11-2025
-- Version: 1.0.0.0
-- yieldTracker.lua


PRINT_PREFIX = "[ YieldTracker ] - "

YieldTracker = {
    modDir = g_currentModDirectory,
    yieldData = {},
    saveFileName = "yieldTrackerData.xml",
}
YieldTracker.debug = true


--- Current active crop fill types that are tracked
source(g_currentModDirectory .. "scripts/trackedCropTypes.lua") --> TrackedCropTypes
local trackedCropTypes = TrackedCropTypes



-- Called every frame to update yield tracking for all combines in the current mission.
-- Iterates over all vehicles, checks for combines, determines active fill types, and tracks their fill units.
function YieldTracker:updateByFrame()
    local currentVehicles = {}

    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.spec_combine then
            -- Track current vehicle ids
            currentVehicles[vehicle.id] = true

            local cutterInputFillType, cutterOutputFillType = self:getCutterStatus(vehicle)
            local hasInternalFillUnit, combineFillType, activeFillLevel = self:getCombineStatus(vehicle)
            local fieldFillType = self:getFieldFillTypeFallback(vehicle)

            local activeFillType = hasInternalFillUnit
                and self:getActiveFillType(cutterInputFillType, combineFillType, fieldFillType)
                or  self:getActiveFillType(cutterOutputFillType, combineFillType, fieldFillType)

            local isBaler = false
            self:trackFillUnit(vehicle, activeFillType, activeFillLevel, isBaler)

        end

        if vehicle.spec_baler then
            currentVehicles[vehicle.id] = true
            local balerFillType = vehicle:getFillUnitFillType(1)
            local balerFillLevel = vehicle:getFillUnitFillLevel(1)
            local isbaler = true
            self:trackFillUnit(vehicle, balerFillType, balerFillLevel, isbaler)
        end

    end

    -- Remove vehicles from prevFillLevels that are no longer in game/sold
    if self.prevFillLevels then
        for vehicleId in pairs(self.prevFillLevels) do
            if not currentVehicles[vehicleId] then
                self.prevFillLevels[vehicleId] = nil
                self:debugMessage(string.format("Removed stale vehicle %d from tracking", vehicleId))
            end
        end
    end
end


-- Called every frame to track fill unit changes for a given combine vehicle.
function YieldTracker:trackFillUnit(vehicle, activeFillType, activeFillLevel, isbaler)
    if not self.yieldDataLoaded then return end
    if not vehicle or not activeFillType then return end 

    local currentYear = g_currentMission.environment.currentYear
    local vehicleId = vehicle.id
    local fieldID

    if not isbaler then
        fieldID = self:getCutterFieldID(vehicle)
    elseif isbaler then
        local baler_pos_x, baler_pos_y, baler_pos_z = getWorldTranslation(vehicle.rootNode)
        fieldID = g_farmlandManager:getFarmlandIdAtWorldPosition(baler_pos_x, baler_pos_z)
    end

    if not fieldID then return end

    local fillTypeDesc = g_fillTypeManager.indexToFillType[activeFillType]
    if not fillTypeDesc then return end

    local cropName = fillTypeDesc.title

    self.prevFillLevels = self.prevFillLevels or {}
    self.initializedVehicles = self.initializedVehicles or {}

    if activeFillLevel == nil then
        self:debugMessage(string.format("Vehicle %d has no valid fill level this frame; skipping", vehicle.id))
        return
    end

    -- If fill unit is empty or close to empty, reset baseline
    if activeFillLevel <= 0.1 and (self.prevFillLevels[vehicleId] or 0) > 0 then
        self.prevFillLevels[vehicleId] = 0
        self:debugMessage(string.format("Vehicle %d fill level is 0L; resetting baseline", vehicleId))
        return
    end

    -- First-time detection for this vehicle: skip initial fill, no yield recorded
    if self.initializedVehicles[vehicleId] == nil then
        self.initializedVehicles[vehicleId] = true
        self.prevFillLevels[vehicleId] = activeFillLevel
        self:debugMessage(string.format("Vehicle %d seen for first time this session with %.2fL", vehicleId, activeFillLevel))
    end

    local prevLevel = self.prevFillLevels[vehicleId] or 0
    local delta = activeFillLevel - prevLevel

    if delta > 0 then
        if self:isTrackedFillType(activeFillType) then
            -- Harvest increase detected for a tracked crop
            self:recordHarvest(currentYear, fieldID, cropName, delta, activeFillType)
            self:debugMessage(string.format("Harvest detected: +%.2fL of '%s' for vehicle %d on field %d.",
                delta, cropName, vehicleId, fieldID))
        else
            self:debugMessage(string.format("Skipping untracked crop type '%s' (fillTypeIndex: %d)", cropName, activeFillType))
        end
    end

    -- Always update baseline
    self.prevFillLevels[vehicleId] = activeFillLevel
end





-- UTIL METHODS
--=======================================================================================================================================================================

-- Fetches the currently attached cutter's fill types.
function YieldTracker:getCutterStatus(vehicle)
    local spec = vehicle.spec_combine
    if not spec then 
        return FillType.UNKNOWN, nil 
    end

    if spec.attachedCutters then
        for _, cutter in pairs(spec.attachedCutters) do
            if cutter and cutter.spec_cutter and cutter.spec_cutter.isWorking then
                local cutterInputFillType = cutter.spec_cutter.currentInputFillType or FillType.UNKNOWN
                local cutterOutputFillType = cutter.spec_cutter.currentOutputFillType or FillType.UNKNOWN
                return cutterInputFillType, cutterOutputFillType
            end
        end
    end

    return FillType.UNKNOWN, nil
end


---Fetches the current combine fill unit status.
function YieldTracker:getCombineStatus(vehicle)
    if not vehicle or not vehicle.spec_combine then
        return false, FillType.UNKNOWN, 0
    end

    local spec = vehicle.spec_combine
    local fillUnitIndex = spec.fillUnitIndex
    local fillUnitCapacity = vehicle:getFillUnitCapacity(fillUnitIndex)

    -- Combine has an Internal fill unit - case
    if type(fillUnitCapacity) == "number" and fillUnitCapacity > 0 and fillUnitCapacity ~= math.huge then
        -- local isFilling = spec.isFilling -- DEPRACTED
        local fillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
        local combineFillType = vehicle:getFillUnitFillType(fillUnitIndex)
        local hasInternalFillUnit = true
        return hasInternalFillUnit, combineFillType, fillLevel
    end

    -- Discharge to external target (fillUnitCapacity <= 0 or is inf)
    local dischargeSpec = vehicle.spec_combine.spec_dischargeable
    if dischargeSpec then
        for i, dischargeNode in ipairs(dischargeSpec.dischargeNodes) do
            local targetObject, targetFillUnitIndex = vehicle:getDischargeTargetObject(dischargeNode)

            if targetObject and targetFillUnitIndex then
                local fillLevel = targetObject:getFillUnitFillLevel(targetFillUnitIndex)
                local targetFillType = targetObject:getFillUnitFillType(targetFillUnitIndex)
                local hasInternalFillUnit = false
                return hasInternalFillUnit, targetFillType, fillLevel
            end
        end
    end


    return nil, nil, nil
end


-- Fallback method to determine the field's fill type when the fill unit is empty but the cutter is active.
function YieldTracker:getFieldFillTypeFallback(vehicle)
    local cutterFieldID = self:getCutterFieldID(vehicle)
    if not cutterFieldID then
        return nil
    end

    local field = g_fieldManager.fields[cutterFieldID]
    if not field then
        return nil
    end

    local fruitTypeIndex = field.fieldState.fruitTypeIndex
    if fruitTypeIndex == nil or fruitTypeIndex == 0 then
        return nil
    end

    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    if fruitType then
        return fruitType.fillType
    end

    return FillType.UNKNOWN
end


-- Determines fill type based on primary, secondary triggers, or fallback (cutter input/output, combine fill unit, and field fill type).
function YieldTracker:getActiveFillType(primary, secondary, fallback)
    if primary and primary ~= FillType.UNKNOWN then
        return primary
    elseif secondary and secondary ~= FillType.UNKNOWN then
        return secondary
    elseif fallback and fallback ~= FillType.Unknow then
        return fallback -- Field fillType
    end
    return FillType.UNKNOWN
end


-- Uses the cutter's position to determine the current field being harvested.
function YieldTracker:getCutterFieldID(vehicle)
    local spec_combine = vehicle.spec_combine
    if not spec_combine then return nil end
    
    for _, cutter in pairs(spec_combine.attachedCutters) do
        if cutter and cutter.spec_cutter then
            local x, y, z = getWorldTranslation(cutter.rootNode)
            local fieldID = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
            return fieldID
        end
    end
    return nil
end


-- Checks if a given fill type index is in the tracked crop types.
function YieldTracker:isTrackedFillType(fillTypeIndex)
    for _, crop in ipairs(trackedCropTypes) do
        if crop.fillTypeIndex == fillTypeIndex then
            return true
        end
    end
    return false
end


---Updates the yieldData table with the latest harvested amount. Also referenced during game save.
function YieldTracker:recordHarvest(year, fieldId, cropName, amount, fillTypeIndex)
    self.yieldData[year] = self.yieldData[year] or {}
    self.yieldData[year][fieldId] = self.yieldData[year][fieldId] or {}

    local fillTypeEntry = self.yieldData[year][fieldId][fillTypeIndex]
    if not fillTypeEntry then
        self.yieldData[year][fieldId][fillTypeIndex] = {
            amount = 0,
            fillTypeTitle = cropName
        }
        fillTypeEntry = self.yieldData[year][fieldId][fillTypeIndex]
    end

    fillTypeEntry.amount = fillTypeEntry.amount + amount

    self:debugMessage(string.format(
        "Recorded %.2fL of %s (fillTypeIndex=%d) on field %d (year %d)",
        amount, cropName, fillTypeIndex, fieldId, year
    ))

end


-- Prints a debug message if debugging is enabled.
function YieldTracker:debugMessage(message)
    if self.debug then
        print(PRINT_PREFIX .. message)
    end
end

--=======================================================================================================================================================================




-- SAVE/LOAD METHODS
--=======================================================================================================================================================================

-- Call required dependencies upon loadmap from main.lua
function YieldTracker:setup()
    self:loadYieldData()
    self:hookInGameSaveEvent()
end


-- Hooks into the save event to trigger yield data saving on every game save.
function YieldTracker:hookInGameSaveEvent()
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
    FSCareerMissionInfo.saveToXMLFile,
    function() YieldTracker:saveYieldData() end)
end


-- Loads yield tracking data and vehicle baseline fill levels from an XML file in the current savegame directory.
-- Rebuilds the yieldData structure by year, field, and crop, and restores previous fill levels per vehicle.
-- If no file exists or loading fails, initializes with empty data and marks data as loaded.
function YieldTracker:loadYieldData()
    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        self:debugMessage("Load skipped: no savegame directory")
        self.yieldDataLoaded = true
        return
    end

    local filePath = g_currentMission.missionInfo.savegameDirectory .. "/" .. self.saveFileName
    if not fileExists(filePath) then
        self:debugMessage("No existing yield data XML found")
        self.yieldDataLoaded = true
        return
    end

    local xmlFile = loadXMLFile("YieldDataXML", filePath)
    if not xmlFile then
        self:debugMessage("Failed to load yield data XML")
        return
    end

    self.yieldData = {}

    local i = 0
    while true do
        local yearKey = string.format("yieldData.year(%d)", i)
        if not hasXMLProperty(xmlFile, yearKey) then break end

        local year = getXMLInt(xmlFile, yearKey .. "#value")
        self.yieldData[year] = {}

        local j = 0
        while true do
            local fieldKey = string.format("%s.field(%d)", yearKey, j)
            if not hasXMLProperty(xmlFile, fieldKey) then break end

            local fieldId = getXMLInt(xmlFile, fieldKey .. "#id")
            self.yieldData[year][fieldId] = {}

            local k = 0
            while true do
                local cropKey = string.format("%s.crop(%d)", fieldKey, k)
                if not hasXMLProperty(xmlFile, cropKey) then break end

                local cropName = getXMLString(xmlFile, cropKey .. "#name")
                local amount = getXMLFloat(xmlFile, cropKey .. "#amount")
                local fillTypeIndex = getXMLInt(xmlFile, cropKey .. "#fillTypeIndex")

                self.yieldData[year][fieldId][fillTypeIndex] = {
                    amount = amount,
                    fillTypeTitle = cropName
                }

                k = k + 1
            end

            j = j + 1
        end

        i = i + 1
    end

    -- Load prevFillLevels baseline per vehicle
    self.prevFillLevels = {}
    local v = 0
    while true do
        local vehicleKey = string.format("yieldData.prevFillLevels.vehicle(%d)", v)
        if not hasXMLProperty(xmlFile, vehicleKey) then break end

        local vehicleId = getXMLInt(xmlFile, vehicleKey .. "#id")
        local level = getXMLFloat(xmlFile, vehicleKey .. "#level")

        if vehicleId and level then
            self.prevFillLevels[vehicleId] = level
        end

        v = v + 1
    end

    delete(xmlFile)

    self.yieldDataLoaded = true
    self:debugMessage("Yield data loaded from XML")
end



-- Saves yield tracking data and vehicle baseline fill levels to an XML file in the current savegame directory.
-- Data saved includes harvested amounts grouped by year, field, and crop, as well as last known fill levels per vehicle.
function YieldTracker:saveYieldData()
    if not g_currentMission or not g_currentMission.missionInfo.savegameDirectory then
        self:debugMessage("Save skipped: no savegame directory")
        return
    end

    local filePath = g_currentMission.missionInfo.savegameDirectory .. "/" .. self.saveFileName
    local xmlFile = createXMLFile("YieldDataXML", filePath, "yieldData")

    -- Save yield data per year/field/crop
    local i = 0
    for year, fields in pairs(self.yieldData) do
        local yearKey = string.format("yieldData.year(%d)", i)
        setXMLInt(xmlFile, yearKey .. "#value", year)

        local j = 0
        for fieldId, crops in pairs(fields) do
            local fieldKey = string.format("%s.field(%d)", yearKey, j)
            setXMLInt(xmlFile, fieldKey .. "#id", fieldId)

            local k = 0
            for fillTypeIndex, cropData in pairs(crops) do
                local cropKey = string.format("%s.crop(%d)", fieldKey, k)
                setXMLInt(xmlFile, cropKey .. "#fillTypeIndex", fillTypeIndex)
                setXMLString(xmlFile, cropKey .. "#name", cropData.fillTypeTitle)
                setXMLFloat(xmlFile, cropKey .. "#amount", cropData.amount)
                k = k + 1
            end
            j = j + 1
        end
        i = i + 1
    end

    -- Save prevFillLevels baseline per vehicle
    local v = 0
    for vehicleId, level in pairs(self.prevFillLevels or {}) do
        local vehicleKey = string.format("yieldData.prevFillLevels.vehicle(%d)", v)
        setXMLInt(xmlFile, vehicleKey .. "#id", vehicleId)
        setXMLFloat(xmlFile, vehicleKey .. "#level", level)
        v = v + 1
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)

    self:debugMessage("Yield data saved to XML")
end

--=======================================================================================================================================================================