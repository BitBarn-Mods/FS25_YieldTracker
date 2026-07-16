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
YieldTracker.debug = false
YieldTracker.debugHarvest = false


--- Active crop fill types are resolved dynamically from g_fruitTypeManager.


-- Called every frame to update yield tracking for all combines in the current mission.
-- Iterates over all vehicles, checks for combines, determines active fill types, and tracks their fill units.
function YieldTracker:updateByFrame()
    -- Harvest amounts are recorded by Combine.onUpdateTick tank deltas and Dischargeable.onUpdateTick pipe deltas.
    -- The old per-frame scan is intentionally disabled.
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





-- EVENT-BASED HARVEST TRACKING
--=======================================================================================================================================================================

function YieldTracker:installFillUnitHook()
    self:debugHarvestMessage("installFillUnitHook() called")

    if self.fillUnitHookInstalled then
        self:debugHarvestMessage("installFillUnitHook() skipped: already installed")
        return
    end

    self:debugHarvestMessage("Vehicle exists=" .. tostring(Vehicle ~= nil))
    self:debugHarvestMessage("Vehicle.addFillUnitFillLevel exists=" .. tostring(Vehicle ~= nil and Vehicle.addFillUnitFillLevel ~= nil))
    self:debugHarvestMessage("FillUnit exists=" .. tostring(FillUnit ~= nil))
    self:debugHarvestMessage("FillUnit.addFillUnitFillLevel exists=" .. tostring(FillUnit ~= nil and FillUnit.addFillUnitFillLevel ~= nil))

    local tracker = self
    local installedAnyHook = false

    if Vehicle ~= nil and Vehicle.addFillUnitFillLevel ~= nil then
        Vehicle.addFillUnitFillLevel = Utils.overwrittenFunction(Vehicle.addFillUnitFillLevel, function(vehicle, superFunc, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, ...)
            tracker:debugHarvestMessage(string.format(
                "HOOK_CALL Vehicle.addFillUnitFillLevel vehicle='%s' vehicleId=%s farmId=%s fillUnitIndex=%s delta=%s fillTypeIndex=%s",
                tracker:getVehicleDebugName(vehicle),
                tostring(vehicle ~= nil and vehicle.id or nil),
                tostring(farmId),
                tostring(fillUnitIndex),
                tostring(fillLevelDelta),
                tostring(fillTypeIndex)
            ))

            local oldFillLevel = nil
            if vehicle ~= nil and fillUnitIndex ~= nil and vehicle.getFillUnitFillLevel ~= nil then
                oldFillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
            end

            local result = superFunc(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, ...)

            local appliedAmount = fillLevelDelta
            if type(result) == "number" then
                appliedAmount = result
            elseif oldFillLevel ~= nil and vehicle ~= nil and vehicle.getFillUnitFillLevel ~= nil then
                local newFillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or oldFillLevel
                local measuredDelta = newFillLevel - oldFillLevel
                tracker:debugHarvestMessage(string.format(
                    "HOOK_AFTER Vehicle.addFillUnitFillLevel old=%s new=%s measuredDelta=%s result=%s",
                    tostring(oldFillLevel), tostring(newFillLevel), tostring(measuredDelta), tostring(result)
                ))
                if measuredDelta > 0 then
                    appliedAmount = measuredDelta
                end
            end

            tracker:handleHarvestFillUnitAdded(vehicle, fillUnitIndex, appliedAmount, fillTypeIndex)
            return result
        end)

        installedAnyHook = true
        self:debugHarvestMessage("Installed hook: Vehicle.addFillUnitFillLevel")
    end

    -- Additional trace hook in case FS25 calls the specialization table directly instead of Vehicle.*
    if FillUnit ~= nil and FillUnit.addFillUnitFillLevel ~= nil and (Vehicle == nil or FillUnit.addFillUnitFillLevel ~= Vehicle.addFillUnitFillLevel) then
        FillUnit.addFillUnitFillLevel = Utils.overwrittenFunction(FillUnit.addFillUnitFillLevel, function(vehicle, superFunc, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, ...)
            tracker:debugHarvestMessage(string.format(
                "HOOK_CALL FillUnit.addFillUnitFillLevel vehicle='%s' vehicleId=%s farmId=%s fillUnitIndex=%s delta=%s fillTypeIndex=%s",
                tracker:getVehicleDebugName(vehicle),
                tostring(vehicle ~= nil and vehicle.id or nil),
                tostring(farmId),
                tostring(fillUnitIndex),
                tostring(fillLevelDelta),
                tostring(fillTypeIndex)
            ))

            local oldFillLevel = nil
            if vehicle ~= nil and fillUnitIndex ~= nil and vehicle.getFillUnitFillLevel ~= nil then
                oldFillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or 0
            end

            local result = superFunc(vehicle, farmId, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, ...)

            local appliedAmount = fillLevelDelta
            if type(result) == "number" then
                appliedAmount = result
            elseif oldFillLevel ~= nil and vehicle ~= nil and vehicle.getFillUnitFillLevel ~= nil then
                local newFillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex) or oldFillLevel
                local measuredDelta = newFillLevel - oldFillLevel
                tracker:debugHarvestMessage(string.format(
                    "HOOK_AFTER FillUnit.addFillUnitFillLevel old=%s new=%s measuredDelta=%s result=%s",
                    tostring(oldFillLevel), tostring(newFillLevel), tostring(measuredDelta), tostring(result)
                ))
                if measuredDelta > 0 then
                    appliedAmount = measuredDelta
                end
            end

            tracker:handleHarvestFillUnitAdded(vehicle, fillUnitIndex, appliedAmount, fillTypeIndex)
            return result
        end)

        installedAnyHook = true
        self:debugHarvestMessage("Installed hook: FillUnit.addFillUnitFillLevel")
    end

    if not installedAnyHook then
        self:debugHarvestMessage("ERROR: no fill unit hook installed; no supported addFillUnitFillLevel function found")
        self:debugMessage("Could not install fill unit hook: no addFillUnitFillLevel function found")
        return
    end

    self.fillUnitHookInstalled = true
    self:debugHarvestMessage("installFillUnitHook() finished")
    self:debugMessage("Installed fill unit harvest hook")
end

function YieldTracker:getVehicleDebugName(vehicle)
    if vehicle == nil then
        return "nil"
    end

    if vehicle.getName ~= nil then
        local ok, name = pcall(function() return vehicle:getName() end)
        if ok and name ~= nil and name ~= "" then
            return tostring(name)
        end
    end

    if vehicle.configFileName ~= nil then
        return tostring(vehicle.configFileName)
    end

    if vehicle.typeName ~= nil then
        return tostring(vehicle.typeName)
    end

    return tostring(vehicle)
end

function YieldTracker:debugHarvestMessage(message)
    if self.debugHarvest then
        print(PRINT_PREFIX .. "HARVEST_DEBUG - " .. tostring(message))
    end
end

function YieldTracker:debugHarvestDecision(vehicle, fieldID, fillTypeIndex, amount, reason)
    if not self.debugHarvest then
        return
    end

    local vehicleName = self:getVehicleDebugName(vehicle)
    local fillTypeName = "nil"
    if fillTypeIndex ~= nil and g_fillTypeManager ~= nil and g_fillTypeManager.indexToFillType ~= nil then
        local desc = g_fillTypeManager.indexToFillType[fillTypeIndex]
        if desc ~= nil then
            fillTypeName = tostring(desc.title or desc.name or fillTypeIndex)
        else
            fillTypeName = tostring(fillTypeIndex)
        end
    end

    self:debugHarvestMessage(string.format(
        "vehicle='%s' vehicleId=%s combine=%s baler=%s field=%s fillType=%s(%s) amount=%.2f reason=%s",
        vehicleName,
        tostring(vehicle ~= nil and vehicle.id or nil),
        tostring(vehicle ~= nil and vehicle.spec_combine ~= nil),
        tostring(vehicle ~= nil and vehicle.spec_baler ~= nil),
        tostring(fieldID),
        fillTypeName,
        tostring(fillTypeIndex),
        tonumber(amount or 0) or 0,
        tostring(reason)
    ))
end

function YieldTracker:handleHarvestFillUnitAdded(vehicle, fillUnitIndex, fillLevelDelta, fillTypeIndex)
    local rawAmount = tonumber(fillLevelDelta or 0) or 0

    if not self.yieldDataLoaded then
        self:debugHarvestDecision(vehicle, nil, fillTypeIndex, rawAmount, "SKIP_yieldData_not_loaded")
        return
    end

    if vehicle == nil or fillUnitIndex == nil or fillLevelDelta == nil or rawAmount <= 0 then
        self:debugHarvestDecision(vehicle, nil, fillTypeIndex, rawAmount, "SKIP_invalid_or_non_positive_delta")
        return
    end

    local isCombine = vehicle.spec_combine ~= nil
    local isBaler = vehicle.spec_baler ~= nil

    -- Count only where crop is generated. Ignore trailer/silo/transfer additions.
    if not isCombine and not isBaler then
        self:debugHarvestDecision(vehicle, nil, fillTypeIndex, rawAmount, "SKIP_not_combine_or_baler")
        return
    end

    local fieldID = self:getHarvestFieldID(vehicle, isBaler)

    if isCombine and not self:getIsCombineHarvesting(vehicle) then
        self:debugHarvestDecision(vehicle, fieldID, fillTypeIndex, rawAmount, "SKIP_combine_not_harvesting")
        return
    end

    if isBaler and not self:getIsBalerHarvesting(vehicle) then
        self:debugHarvestDecision(vehicle, fieldID, fillTypeIndex, rawAmount, "SKIP_baler_not_harvesting")
        return
    end

    local activeFillType = fillTypeIndex
    if (activeFillType == nil or activeFillType == FillType.UNKNOWN) and vehicle.getFillUnitFillType ~= nil then
        activeFillType = vehicle:getFillUnitFillType(fillUnitIndex)
    end
    if activeFillType == nil or activeFillType == FillType.UNKNOWN then
        activeFillType = self:getFieldFillTypeFallback(vehicle)
    end
    if activeFillType == nil or activeFillType == FillType.UNKNOWN then
        self:debugHarvestDecision(vehicle, fieldID, activeFillType, rawAmount, "SKIP_no_active_fillType")
        return
    end

    if not self:isTrackedFillType(activeFillType) then
        self:debugHarvestDecision(vehicle, fieldID, activeFillType, rawAmount, "SKIP_fillType_not_registered_fruit")
        return
    end

    if fieldID == nil then
        self:debugHarvestDecision(vehicle, fieldID, activeFillType, rawAmount, "SKIP_no_fieldID")
        return
    end

    local fillTypeDesc = g_fillTypeManager.indexToFillType[activeFillType]
    if fillTypeDesc == nil then
        self:debugHarvestDecision(vehicle, fieldID, activeFillType, rawAmount, "SKIP_no_fillTypeDesc")
        return
    end

    local currentYear = g_currentMission.environment.currentYear
    self:recordHarvest(currentYear, fieldID, fillTypeDesc.title, rawAmount, activeFillType)
    self:debugHarvestDecision(vehicle, fieldID, activeFillType, rawAmount, "RECORDED")
end

function YieldTracker:getIsCombineHarvesting(vehicle)
    if vehicle == nil or vehicle.spec_combine == nil then
        return false
    end

    local spec = vehicle.spec_combine
    if spec.attachedCutters ~= nil then
        for _, cutter in pairs(spec.attachedCutters) do
            if cutter ~= nil and cutter.spec_cutter ~= nil and cutter.spec_cutter.isWorking then
                return true
            end
        end
    end

    return false
end

function YieldTracker:getIsBalerHarvesting(vehicle)
    if vehicle == nil or vehicle.spec_baler == nil then
        return false
    end

    if vehicle.getIsTurnedOn ~= nil and vehicle:getIsTurnedOn() then
        return true
    end

    if vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() > 0.5 then
        return true
    end

    return true
end

function YieldTracker:getHarvestFieldID(vehicle, isBaler)
    if isBaler then
        local x, _, z = getWorldTranslation(vehicle.rootNode)
        return g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    end

    return self:getCutterFieldID(vehicle)
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
    if fillTypeIndex == nil then
        return false
    end

    if g_fruitTypeManager == nil or g_fruitTypeManager.getFruitTypes == nil then
        return false
    end

    for _, fruitType in ipairs(g_fruitTypeManager:getFruitTypes()) do
        if fruitType ~= nil then
            local fillType = fruitType.fillType
            local fruitFillTypeIndex = fruitType.fillTypeIndex

            if fillType ~= nil then
                fruitFillTypeIndex = fillType.index or fillType.fillTypeIndex or fruitFillTypeIndex
            end

            if fruitFillTypeIndex == fillTypeIndex then
                return true
            end
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





-- COMBINE FILL LEVEL DELTA DEBUG HOOK
--=======================================================================================================================================================================
function YieldTracker:installCombineFillLevelDeltaDebugHook()
    self:debugHarvestMessage("installCombineFillLevelDeltaDebugHook() called")

    if self.combineFillLevelDeltaDebugHookInstalled then
        self:debugHarvestMessage("installCombineFillLevelDeltaDebugHook() skipped: already installed")
        return
    end

    self.combineFillLevelDebugCallCount = self.combineFillLevelDebugCallCount or {}
    self.combineFillLevelDebugMaxIdleLogsPerVehicle = 25
    self.combinePreviousFillLevels = self.combinePreviousFillLevels or {}
    self.combinePreviousFillTypes = self.combinePreviousFillTypes or {}

    self:debugHarvestMessage("DELTA_EXISTS Combine=" .. tostring(Combine ~= nil))
    self:debugHarvestMessage("DELTA_EXISTS Combine.onUpdateTick=" .. tostring(Combine ~= nil and type(Combine.onUpdateTick) == "function"))
    self:debugHarvestMessage("DELTA_EXISTS Combine.updateTick=" .. tostring(Combine ~= nil and type(Combine.updateTick) == "function"))

    if Combine == nil or type(Combine.onUpdateTick) ~= "function" then
        self:debugHarvestMessage("ERROR: Combine.onUpdateTick not found; combine delta debug hook not installed")
        return
    end

    local tracker = self

    Combine.onUpdateTick = Utils.overwrittenFunction(Combine.onUpdateTick, function(vehicle, superFunc, dt, ...)
        local result = superFunc(vehicle, dt, ...)

        -- Compare against the previous onUpdateTick call, not against a value
        -- read earlier in the same tick. In FS25 the combine fill level can
        -- already be updated before Combine.onUpdateTick is entered.
        local currentLevel, currentFillType, fillUnitIndex = tracker:getCombineInternalFillState(vehicle)
        local vehicleId = vehicle ~= nil and (vehicle.id or tostring(vehicle)) or nil
        local key = nil

        if vehicleId ~= nil and fillUnitIndex ~= nil then
            key = tostring(vehicleId) .. ":" .. tostring(fillUnitIndex)
        end

        local previousLevel = nil
        local previousFillType = nil

        if key ~= nil then
            previousLevel = tracker.combinePreviousFillLevels[key]
            previousFillType = tracker.combinePreviousFillTypes[key]
        end

        local delta = nil
        if previousLevel ~= nil and currentLevel ~= nil then
            delta = currentLevel - previousLevel
        end

        tracker:handleCombineFillLevelDeltaDebug(vehicle, fillUnitIndex, previousLevel, currentLevel, delta, previousFillType, currentFillType)

        -- Update baseline only after logging/recording.
        if key ~= nil and currentLevel ~= nil then
            tracker.combinePreviousFillLevels[key] = currentLevel
            tracker.combinePreviousFillTypes[key] = currentFillType
        end

        return result
    end)

    self.combineFillLevelDeltaDebugHookInstalled = true
    self:debugHarvestMessage("DELTA_INSTALLED Combine.onUpdateTick")
    self:debugHarvestMessage("installCombineFillLevelDeltaDebugHook() finished")
end

function YieldTracker:getCombineInternalFillState(vehicle)
    if vehicle == nil or vehicle.spec_combine == nil then
        return nil, nil, nil
    end

    local spec = vehicle.spec_combine
    local fillUnitIndex = spec.fillUnitIndex
    if fillUnitIndex == nil then
        return nil, nil, nil
    end

    local fillLevel = nil
    local fillType = nil

    if vehicle.getFillUnitFillLevel ~= nil then
        fillLevel = vehicle:getFillUnitFillLevel(fillUnitIndex)
    end

    if vehicle.getFillUnitFillType ~= nil then
        fillType = vehicle:getFillUnitFillType(fillUnitIndex)
    end

    return fillLevel, fillType, fillUnitIndex
end

function YieldTracker:handleCombineFillLevelDeltaDebug(vehicle, fillUnitIndex, oldLevel, newLevel, delta, oldFillType, newFillType)
    if not self.debugHarvest then
        return
    end

    if vehicle == nil then
        self:debugHarvestMessage("DELTA_SKIP vehicle=nil")
        return
    end

    local vehicleId = vehicle.id or tostring(vehicle)
    self.combineFillLevelDebugCallCount[vehicleId] = (self.combineFillLevelDebugCallCount[vehicleId] or 0) + 1

    local fieldID = self:getCutterFieldID(vehicle)
    local cutterInputFillType, cutterOutputFillType = self:getCutterStatus(vehicle)
    local activeFillType = self:getActiveFillType(newFillType, cutterOutputFillType, cutterInputFillType)

    if activeFillType == nil or activeFillType == FillType.UNKNOWN then
        activeFillType = self:getFieldFillTypeFallback(vehicle)
    end

    local fillTypeTitle = self:getFillTypeDebugTitle(activeFillType)
    local vehicleName = self:getVehicleDebugName(vehicle)
    local amount = tonumber(delta or 0) or 0

    if newLevel == nil then
        self:debugHarvestMessage(string.format(
            "DELTA_SKIP vehicle='%s' vehicleId=%s field=%s fillUnit=%s old=%s new=%s delta=%s activeFillType=%s(%s) reason=no_current_fill_state",
            vehicleName, tostring(vehicleId), tostring(fieldID), tostring(fillUnitIndex), tostring(oldLevel), tostring(newLevel), tostring(delta), fillTypeTitle, tostring(activeFillType)
        ))
        return
    end

    if oldLevel == nil then
        self:debugHarvestMessage(string.format(
            "COMBINE_DELTA_BASELINE vehicle='%s' vehicleId=%s field=%s fillUnit=%s current=%.2f newFillType=%s activeFillType=%s(%s) reason=baseline_initialized",
            vehicleName,
            tostring(vehicleId),
            tostring(fieldID),
            tostring(fillUnitIndex),
            tonumber(newLevel or 0) or 0,
            tostring(newFillType),
            fillTypeTitle,
            tostring(activeFillType)
        ))
        return
    end

    if amount > 0.001 then
        local reason = "DELTA_POSITIVE"
        local recorded = false

        if not self.yieldDataLoaded then
            reason = "DELTA_POSITIVE_SKIP_yieldData_not_loaded"
        elseif fieldID == nil then
            reason = "DELTA_POSITIVE_SKIP_no_fieldID"
        elseif activeFillType == nil or activeFillType == FillType.UNKNOWN then
            reason = "DELTA_POSITIVE_SKIP_no_active_fillType"
        elseif not self:isTrackedFillType(activeFillType) then
            reason = "DELTA_POSITIVE_SKIP_fillType_not_registered_fruit"
        else
            local fillTypeDesc = g_fillTypeManager.indexToFillType[activeFillType]
            local cropName = fillTypeDesc ~= nil and (fillTypeDesc.title or fillTypeDesc.name or tostring(activeFillType)) or tostring(activeFillType)
            local currentYear = g_currentMission.environment.currentYear
            self:recordHarvest(currentYear, fieldID, cropName, amount, activeFillType)
            reason = "DELTA_POSITIVE_RECORDED"
            recorded = true
        end

        self:debugHarvestMessage(string.format(
            "COMBINE_DELTA vehicle='%s' vehicleId=%s field=%s fillUnit=%s old=%.2f new=%.2f delta=%.2f oldFillType=%s newFillType=%s cutterInput=%s cutterOutput=%s activeFillType=%s(%s) recorded=%s reason=%s",
            vehicleName,
            tostring(vehicleId),
            tostring(fieldID),
            tostring(fillUnitIndex),
            tonumber(oldLevel or 0) or 0,
            tonumber(newLevel or 0) or 0,
            amount,
            tostring(oldFillType),
            tostring(newFillType),
            tostring(cutterInputFillType),
            tostring(cutterOutputFillType),
            fillTypeTitle,
            tostring(activeFillType),
            tostring(recorded),
            reason
        ))
    else
        local count = self.combineFillLevelDebugCallCount[vehicleId] or 0
        if count <= self.combineFillLevelDebugMaxIdleLogsPerVehicle or count % 300 == 0 then
            self:debugHarvestMessage(string.format(
                "COMBINE_DELTA_IDLE vehicle='%s' vehicleId=%s field=%s fillUnit=%s old=%.2f new=%.2f delta=%.2f newFillType=%s activeFillType=%s(%s) call=%d",
                vehicleName,
                tostring(vehicleId),
                tostring(fieldID),
                tostring(fillUnitIndex),
                tonumber(oldLevel or 0) or 0,
                tonumber(newLevel or 0) or 0,
                amount,
                tostring(newFillType),
                self:getFillTypeDebugTitle(activeFillType),
                tostring(activeFillType),
                count
            ))
        end
    end
end

function YieldTracker:getFillTypeDebugTitle(fillTypeIndex)
    if fillTypeIndex == nil then
        return "nil"
    end

    if g_fillTypeManager ~= nil and g_fillTypeManager.indexToFillType ~= nil then
        local desc = g_fillTypeManager.indexToFillType[fillTypeIndex]
        if desc ~= nil then
            return tostring(desc.title or desc.name or fillTypeIndex)
        end
    end

    return tostring(fillTypeIndex)
end



-- REDUCED PIPE TRACKING HOOK
-- Tracks only the most likely pipe transfer path: Dischargeable.onUpdateTick.
-- Debug output is restricted to harvest vehicles only.
-- Pipe-only comparison formula:
--   pipeHarvestAmount = targetDelta
--   targetDelta = liters added to the overload/trailer target during this discharge tick
-- Tank drawdown is NOT subtracted anymore. For the pipe-only approach, every liter that
-- leaves the combine/harvester pipe is relevant.
function YieldTracker:installPipeDischargeTrackingHook()
    self:debugHarvestMessage("installPipeDischargeTrackingHook() called")

    if self.pipeDischargeTrackingHookInstalled then
        self:debugHarvestMessage("installPipeDischargeTrackingHook() skipped: already installed")
        return
    end

    self.pipeDischargeCallCount = self.pipeDischargeCallCount or {}
    self.pipeDischargeMaxIdleLogsPerVehicle = 20

    self:debugHarvestMessage("PIPE_ONLY_DEBUG_V2_EXISTS Dischargeable=" .. tostring(Dischargeable ~= nil))
    self:debugHarvestMessage("PIPE_ONLY_DEBUG_V2_EXISTS Dischargeable.onUpdateTick=" .. tostring(Dischargeable ~= nil and type(Dischargeable.onUpdateTick) == "function"))

    if Dischargeable == nil or type(Dischargeable.onUpdateTick) ~= "function" then
        self:debugHarvestMessage("ERROR: Dischargeable.onUpdateTick not found; pipe tracking hook not installed")
        return
    end

    local tracker = self

    Dischargeable.onUpdateTick = Utils.overwrittenFunction(Dischargeable.onUpdateTick, function(vehicle, superFunc, dt, ...)
        local args = {...}
        local beforeCombineLevel, beforeCombineFillType, combineFillUnitIndex = tracker:getCombineInternalFillState(vehicle)
        local beforeTargetObject, beforeTargetFillUnitIndex, beforeTargetLevel, beforeTargetFillType = tracker:getPipeTargetState(vehicle, args)

        local result = superFunc(vehicle, dt, ...)

        local afterCombineLevel, afterCombineFillType = tracker:getCombineInternalFillState(vehicle)
        local afterTargetObject, afterTargetFillUnitIndex, afterTargetLevel, afterTargetFillType = tracker:getPipeTargetState(vehicle, args, beforeTargetObject, beforeTargetFillUnitIndex)

        tracker:handlePipeDischargeTracking(
            vehicle,
            dt,
            beforeTargetObject,
            beforeTargetFillUnitIndex,
            beforeTargetLevel,
            beforeTargetFillType,
            afterTargetObject,
            afterTargetFillUnitIndex,
            afterTargetLevel,
            afterTargetFillType,
            combineFillUnitIndex,
            beforeCombineLevel,
            beforeCombineFillType,
            afterCombineLevel,
            afterCombineFillType
        )

        return result
    end)

    self.pipeDischargeTrackingHookInstalled = true
    self:debugHarvestMessage("PIPE_ONLY_DEBUG_V2_INSTALLED Dischargeable.onUpdateTick")
    self:debugHarvestMessage("installPipeDischargeTrackingHook() finished")
end

function YieldTracker:getPipeTargetState(vehicle, args, knownTargetObject, knownTargetFillUnitIndex)
    if knownTargetObject ~= nil and knownTargetFillUnitIndex ~= nil and knownTargetObject.getFillUnitFillLevel ~= nil then
        local level = knownTargetObject:getFillUnitFillLevel(knownTargetFillUnitIndex)
        local fillType = nil
        if knownTargetObject.getFillUnitFillType ~= nil then
            fillType = knownTargetObject:getFillUnitFillType(knownTargetFillUnitIndex)
        end
        return knownTargetObject, knownTargetFillUnitIndex, level, fillType
    end

    if vehicle == nil or vehicle.getDischargeTargetObject == nil then
        return nil, nil, nil, nil
    end

    if args ~= nil then
        for _, possibleDischargeNode in ipairs(args) do
            local ok, targetObject, targetFillUnitIndex = pcall(function()
                return vehicle:getDischargeTargetObject(possibleDischargeNode)
            end)

            if ok and targetObject ~= nil and targetFillUnitIndex ~= nil then
                local level = nil
                local fillType = nil
                if targetObject.getFillUnitFillLevel ~= nil then
                    level = targetObject:getFillUnitFillLevel(targetFillUnitIndex)
                end
                if targetObject.getFillUnitFillType ~= nil then
                    fillType = targetObject:getFillUnitFillType(targetFillUnitIndex)
                end
                return targetObject, targetFillUnitIndex, level, fillType
            end
        end
    end

    local dischargeSpec = vehicle.spec_dischargeable or (vehicle.spec_combine ~= nil and vehicle.spec_combine.spec_dischargeable) or nil
    if dischargeSpec ~= nil and dischargeSpec.dischargeNodes ~= nil then
        for _, dischargeNode in pairs(dischargeSpec.dischargeNodes) do
            local ok, targetObject, targetFillUnitIndex = pcall(function()
                return vehicle:getDischargeTargetObject(dischargeNode)
            end)

            if ok and targetObject ~= nil and targetFillUnitIndex ~= nil then
                local level = nil
                local fillType = nil
                if targetObject.getFillUnitFillLevel ~= nil then
                    level = targetObject:getFillUnitFillLevel(targetFillUnitIndex)
                end
                if targetObject.getFillUnitFillType ~= nil then
                    fillType = targetObject:getFillUnitFillType(targetFillUnitIndex)
                end
                return targetObject, targetFillUnitIndex, level, fillType
            end
        end
    end

    return nil, nil, nil, nil
end


function YieldTracker:isPipeDebugHarvestVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    -- Normal combine harvesters and many specialized harvesters use spec_combine.
    if vehicle.spec_combine ~= nil then
        return true
    end

    -- Fallback for modded harvesters that expose a harvester specialization/name instead of spec_combine.
    if vehicle.spec_harvester ~= nil or vehicle.spec_combineDrivable ~= nil then
        return true
    end

    local typeName = nil
    if vehicle.typeName ~= nil then
        typeName = tostring(vehicle.typeName):lower()
    elseif vehicle.configFileName ~= nil then
        typeName = tostring(vehicle.configFileName):lower()
    end

    if typeName ~= nil then
        if typeName:find("combine", 1, true) ~= nil or typeName:find("harvester", 1, true) ~= nil then
            return true
        end
    end

    return false
end

function YieldTracker:handlePipeDischargeTracking(vehicle, dt, beforeTargetObject, beforeTargetFillUnitIndex, beforeTargetLevel, beforeTargetFillType, afterTargetObject, afterTargetFillUnitIndex, afterTargetLevel, afterTargetFillType, combineFillUnitIndex, beforeCombineLevel, beforeCombineFillType, afterCombineLevel, afterCombineFillType)
    if vehicle == nil then
        return
    end

    if not self:isPipeDebugHarvestVehicle(vehicle) then
        return
    end

    if not self.yieldDataLoaded then
        return
    end

    local targetDelta = 0
    if beforeTargetLevel ~= nil and afterTargetLevel ~= nil then
        targetDelta = (tonumber(afterTargetLevel) or 0) - (tonumber(beforeTargetLevel) or 0)
    end

    if targetDelta <= 0.001 then
        return
    end

    local fieldID = self:getCutterFieldID(vehicle)
    if fieldID == nil then
        return
    end

    local cutterInputFillType, cutterOutputFillType = self:getCutterStatus(vehicle)
    local activeFillType = self:getActiveFillType(afterCombineFillType, afterTargetFillType, cutterOutputFillType)
    if activeFillType == nil or activeFillType == FillType.UNKNOWN then
        activeFillType = self:getActiveFillType(cutterOutputFillType, cutterInputFillType, beforeCombineFillType)
    end
    if activeFillType == nil or activeFillType == FillType.UNKNOWN then
        activeFillType = self:getFieldFillTypeFallback(vehicle)
    end

    if activeFillType == nil or activeFillType == FillType.UNKNOWN or not self:isTrackedFillType(activeFillType) then
        return
    end

    local currentYear = g_currentMission.environment.currentYear
    self:addPipeHarvestAmount(currentYear, fieldID, activeFillType, targetDelta)

    -- After a successful pipe transfer, the combine tank usually changed too.
    -- Refresh the transient tank contribution so the GUI shows pipe + remaining tank.
    self:updateCombineLiveTank(vehicle, fieldID, activeFillType)
end



-- PIPE-BASED FINAL HARVEST CALCULATION
--=======================================================================================================================================================================
function YieldTracker:makeYieldKey(year, fieldID, fillTypeIndex)
    if year == nil or fieldID == nil or fillTypeIndex == nil then
        return nil
    end
    return tostring(year) .. ":" .. tostring(fieldID) .. ":" .. tostring(fillTypeIndex)
end

function YieldTracker:getFillTypeTitle(fillTypeIndex)
    local fillTypeDesc = g_fillTypeManager ~= nil and g_fillTypeManager.indexToFillType ~= nil and g_fillTypeManager.indexToFillType[fillTypeIndex] or nil
    if fillTypeDesc ~= nil then
        return fillTypeDesc.title or fillTypeDesc.name or tostring(fillTypeIndex)
    end
    return tostring(fillTypeIndex)
end

function YieldTracker:initializePipeBaseFromYieldData()
    self.pipeBaseTotals = {}
    self.liveTankContributions = {}
    self.vehicleLiveTankKeys = {}

    local liveByKey = {}
    if self.savedLiveTankContributions ~= nil then
        for _, entry in pairs(self.savedLiveTankContributions) do
            local key = self:makeYieldKey(entry.year, entry.fieldID, entry.fillTypeIndex)
            if key ~= nil then
                liveByKey[key] = (liveByKey[key] or 0) + (tonumber(entry.amount) or 0)
            end
        end
    end

    for year, fields in pairs(self.yieldData or {}) do
        self.pipeBaseTotals[year] = self.pipeBaseTotals[year] or {}
        for fieldID, crops in pairs(fields) do
            self.pipeBaseTotals[year][fieldID] = self.pipeBaseTotals[year][fieldID] or {}
            for fillTypeIndex, cropData in pairs(crops) do
                local amount = tonumber(cropData.amount or 0) or 0
                local key = self:makeYieldKey(year, fieldID, fillTypeIndex)
                local liveAmount = liveByKey[key] or 0
                self.pipeBaseTotals[year][fieldID][fillTypeIndex] = math.max(0, amount - liveAmount)
            end
        end
    end

    self.savedLiveTankContributions = nil
end

function YieldTracker:getPipeBaseAmount(year, fieldID, fillTypeIndex)
    if self.pipeBaseTotals == nil or self.pipeBaseTotals[year] == nil or self.pipeBaseTotals[year][fieldID] == nil then
        return 0
    end
    return tonumber(self.pipeBaseTotals[year][fieldID][fillTypeIndex] or 0) or 0
end

function YieldTracker:getLiveTankAmountForKey(key)
    local total = 0
    for _, contribution in pairs(self.liveTankContributions or {}) do
        if contribution.key == key then
            total = total + (tonumber(contribution.amount) or 0)
        end
    end
    return total
end

function YieldTracker:syncYieldDataEntry(year, fieldID, fillTypeIndex)
    if year == nil or fieldID == nil or fillTypeIndex == nil then
        return
    end

    self.yieldData[year] = self.yieldData[year] or {}
    self.yieldData[year][fieldID] = self.yieldData[year][fieldID] or {}

    local key = self:makeYieldKey(year, fieldID, fillTypeIndex)
    local amount = self:getPipeBaseAmount(year, fieldID, fillTypeIndex) + self:getLiveTankAmountForKey(key)

    self.yieldData[year][fieldID][fillTypeIndex] = self.yieldData[year][fieldID][fillTypeIndex] or {
        amount = 0,
        fillTypeTitle = self:getFillTypeTitle(fillTypeIndex)
    }

    self.yieldData[year][fieldID][fillTypeIndex].amount = amount
    self.yieldData[year][fieldID][fillTypeIndex].fillTypeTitle = self:getFillTypeTitle(fillTypeIndex)
end

function YieldTracker:addPipeHarvestAmount(year, fieldID, fillTypeIndex, amount)
    amount = tonumber(amount or 0) or 0
    if year == nil or fieldID == nil or fillTypeIndex == nil or amount <= 0.001 then
        return
    end

    self.pipeBaseTotals = self.pipeBaseTotals or {}
    self.pipeBaseTotals[year] = self.pipeBaseTotals[year] or {}
    self.pipeBaseTotals[year][fieldID] = self.pipeBaseTotals[year][fieldID] or {}
    self.pipeBaseTotals[year][fieldID][fillTypeIndex] = (self.pipeBaseTotals[year][fieldID][fillTypeIndex] or 0) + amount

    self:syncYieldDataEntry(year, fieldID, fillTypeIndex)
end

function YieldTracker:updateCombineLiveTank(vehicle, fieldID, fillTypeIndex)
    if vehicle == nil or not self.yieldDataLoaded then
        return
    end

    local year = g_currentMission.environment.currentYear
    local vehicleId = vehicle.id or tostring(vehicle)
    local oldContribution = self.liveTankContributions ~= nil and self.liveTankContributions[vehicleId] or nil

    if oldContribution ~= nil then
        self.liveTankContributions[vehicleId] = nil
        self:syncYieldDataEntry(oldContribution.year, oldContribution.fieldID, oldContribution.fillTypeIndex)
    end

    local tankLevel = 0
    local tankFillType = fillTypeIndex
    local fillLevel, currentFillType = self:getCombineInternalFillState(vehicle)
    if fillLevel ~= nil then
        tankLevel = tonumber(fillLevel or 0) or 0
    end
    if currentFillType ~= nil and currentFillType ~= FillType.UNKNOWN then
        tankFillType = currentFillType
    end

    if tankLevel <= 0.001 then
        return
    end

    if fieldID == nil or fillTypeIndex == nil or fillTypeIndex == FillType.UNKNOWN then
        return
    end

    local key = self:makeYieldKey(year, fieldID, fillTypeIndex)
    self.liveTankContributions = self.liveTankContributions or {}
    self.liveTankContributions[vehicleId] = {
        key = key,
        year = year,
        fieldID = fieldID,
        fillTypeIndex = fillTypeIndex,
        amount = tankLevel
    }

    self:syncYieldDataEntry(year, fieldID, fillTypeIndex)
end

function YieldTracker:installCombineLiveTankTrackingHook()
    if self.combineLiveTankTrackingHookInstalled then
        return
    end

    if Combine == nil or type(Combine.onUpdateTick) ~= "function" then
        return
    end

    local tracker = self
    Combine.onUpdateTick = Utils.overwrittenFunction(Combine.onUpdateTick, function(vehicle, superFunc, dt, ...)
        local result = superFunc(vehicle, dt, ...)

        if tracker:isPipeDebugHarvestVehicle(vehicle) then
            local fieldID = tracker:getCutterFieldID(vehicle)
            local currentLevel, currentFillType = tracker:getCombineInternalFillState(vehicle)
            local cutterInputFillType, cutterOutputFillType = tracker:getCutterStatus(vehicle)
            local activeFillType = tracker:getActiveFillType(currentFillType, cutterOutputFillType, cutterInputFillType)
            if activeFillType == nil or activeFillType == FillType.UNKNOWN then
                activeFillType = tracker:getFieldFillTypeFallback(vehicle)
            end

            if fieldID ~= nil and activeFillType ~= nil and activeFillType ~= FillType.UNKNOWN and tracker:isTrackedFillType(activeFillType) then
                tracker:updateCombineLiveTank(vehicle, fieldID, activeFillType)
            elseif currentLevel ~= nil and currentLevel <= 0.001 then
                tracker:updateCombineLiveTank(vehicle, nil, nil)
            end
        end

        return result
    end)

    self.combineLiveTankTrackingHookInstalled = true
end

-- PIPE-ONLY DEBUG CALCULATION
--=======================================================================================================================================================================
function YieldTracker:addPipeOnlyDebugAmount(year, fieldID, fillTypeIndex, amount)
    if year == nil or fieldID == nil or fillTypeIndex == nil then
        return
    end

    amount = tonumber(amount or 0) or 0
    if amount <= 0.001 then
        return
    end

    self.pipeOnlyDebugTotals = self.pipeOnlyDebugTotals or {}
    self.pipeOnlyDebugTotals[year] = self.pipeOnlyDebugTotals[year] or {}
    self.pipeOnlyDebugTotals[year][fieldID] = self.pipeOnlyDebugTotals[year][fieldID] or {}
    self.pipeOnlyDebugTotals[year][fieldID][fillTypeIndex] = (self.pipeOnlyDebugTotals[year][fieldID][fillTypeIndex] or 0) + amount
end

function YieldTracker:getPipeOnlyDebugAmount(year, fieldID, fillTypeIndex)
    if self.pipeOnlyDebugTotals == nil then
        return 0
    end

    if self.pipeOnlyDebugTotals[year] == nil or self.pipeOnlyDebugTotals[year][fieldID] == nil then
        return 0
    end

    return self.pipeOnlyDebugTotals[year][fieldID][fillTypeIndex] or 0
end

function YieldTracker:getCurrentCombineTankForDebug(vehicle, expectedFillType)
    local level, fillType, fillUnitIndex = self:getCombineInternalFillState(vehicle)

    if expectedFillType ~= nil and fillType ~= nil and fillType ~= expectedFillType then
        return 0, fillType, fillUnitIndex
    end

    return tonumber(level or 0) or 0, fillType, fillUnitIndex
end

function YieldTracker:formatDebugNumber(value)
    if value == nil then
        return "nil"
    end
    local numberValue = tonumber(value)
    if numberValue == nil then
        return tostring(value)
    end
    return string.format("%.2f", numberValue)
end


-- SAVE/LOAD METHODS
--=======================================================================================================================================================================

-- Call required dependencies upon loadmap from main.lua
function YieldTracker:setup()
    self:loadYieldData()
    self:initializePipeBaseFromYieldData()
    self:installCombineLiveTankTrackingHook()
    self:installPipeDischargeTrackingHook()
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


    -- Load transient live tank contributions that were included in the saved display amount.
    -- They are subtracted from pipeBaseTotals after loading to avoid double counting when the same tank is unloaded after reload.
    self.savedLiveTankContributions = {}
    local lt = 0
    while true do
        local liveKey = string.format("yieldData.liveTankContributions.vehicle(%d)", lt)
        if not hasXMLProperty(xmlFile, liveKey) then break end

        table.insert(self.savedLiveTankContributions, {
            vehicleId = getXMLString(xmlFile, liveKey .. "#id"),
            year = getXMLInt(xmlFile, liveKey .. "#year"),
            fieldID = getXMLInt(xmlFile, liveKey .. "#fieldId"),
            fillTypeIndex = getXMLInt(xmlFile, liveKey .. "#fillTypeIndex"),
            amount = getXMLFloat(xmlFile, liveKey .. "#amount") or 0
        })

        lt = lt + 1
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



    -- Save transient live tank contributions separately so they can be subtracted from pipe base totals on reload.
    local lt = 0
    for vehicleId, contribution in pairs(self.liveTankContributions or {}) do
        if contribution.amount ~= nil and contribution.amount > 0.001 then
            local liveKey = string.format("yieldData.liveTankContributions.vehicle(%d)", lt)
            setXMLString(xmlFile, liveKey .. "#id", tostring(vehicleId))
            setXMLInt(xmlFile, liveKey .. "#year", contribution.year)
            setXMLInt(xmlFile, liveKey .. "#fieldId", contribution.fieldID)
            setXMLInt(xmlFile, liveKey .. "#fillTypeIndex", contribution.fillTypeIndex)
            setXMLFloat(xmlFile, liveKey .. "#amount", contribution.amount)
            lt = lt + 1
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)

    self:debugMessage("Yield data saved to XML")
end

--=======================================================================================================================================================================
