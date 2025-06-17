-- Author: BitBarn Mods
-- Date: 06-11-2025
-- Version: 1.0.0.0
-- yieldTrackerGUI.lua

---Handles GUI integration for the YieldTracker mod.
---Responsible for loading GUI pages, registering with InGameMenu, and managing page layout.
YieldTrackerGUI = {
    dir = g_currentModDirectory,  -- Mod directory path
    modName = g_currentModName    -- Name of the current mod
}

-- Load the YieldTrackerPage class for GUI logic
source(YieldTrackerGUI.dir .. "scripts/gui/yieldTrackerPage.lua") -- > YieldTrackerPage

---Helper function: Finds the index of a specific value in a sequential table.
---@param tbl table The table to search
---@param value any The value to find
---@return integer? Index of the value or nil if not found
local function findIndex(tbl, value)
    for i, v in ipairs(tbl) do
        if v == value then
            return i
        end
    end
    return nil
end

---Helper function: Moves an element to a new position within a table.
---@param tbl table The table to modify
---@param element any The element to move
---@param position integer The new index position
local function moveElement(tbl, element, position)
    for i, v in ipairs(tbl) do
        if v == element then
            table.remove(tbl, i)
            table.insert(tbl, position, element)
            break
        end
    end
end

---Initializes the YieldTracker GUI when the map loads.
---Loads GUI profiles, creates the GUI page, and inserts it into the in-game menu.
function YieldTrackerGUI:setup()
    local inGameMenu = g_gui.screenControllers[InGameMenu]

    -- Load custom GUI styles from XML
    g_gui:loadProfiles(self.dir .. "gui/guiProfiles.xml")

    -- Instantiate and load the YieldTracker GUI page
    local yieldPage = YieldTrackerPage.new(g_i18n, g_messageCenter)
    g_gui:loadGui(self.dir .. "gui/yieldTrackerPage.xml", "yieldTrackerPage", yieldPage, true)

    -- Add the new page to the in-game menu using the helper
    self.fixInGameMenu(yieldPage, "yieldTrackerPage", {0, 0, 1024, 1024}, 2, nil)
end

---Registers a custom GUI page with the in-game menu.
---Ensures correct ordering, visual integration, and control registration.
---@param frame table The GUI frame to add
---@param pageName string Unique name for the page
---@param uvs table UV coordinates for the page tab icon
---@param position integer Index position for the new page
---@param predicateFunc function? Optional function to determine page visibility
function YieldTrackerGUI.fixInGameMenu(frame, pageName, uvs, position, predicateFunc)
    local inGameMenu = g_gui.screenControllers[InGameMenu]

    -- Avoid duplicate control ID conflicts
    inGameMenu.controlIDs[pageName] = nil

    -- Find insertion point based on existing pages (e.g. above pageStatistics)
    local abovePrices = findIndex(inGameMenu.pagingElement.elements, inGameMenu.pageStatistics) or position

    -- Register the frame and expose it in the menu
    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(frame)
    inGameMenu:exposeControlsAsFields(pageName)

    -- Move the new frame into the desired slot in the page list
    moveElement(inGameMenu.pagingElement.elements, frame, abovePrices)

    -- Adjust internal page references accordingly
    for i, page in ipairs(inGameMenu.pagingElement.pages) do
        if page.element == frame then
            table.remove(inGameMenu.pagingElement.pages, i)
            table.insert(inGameMenu.pagingElement.pages, abovePrices, page)
            break
        end
    end

    -- Refresh layout and page mappings after changes
    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()

    -- Register logic to determine when the page is enabled
    inGameMenu:registerPage(frame, position, predicateFunc)

    -- Add tab icon to the menu bar
    local iconPath = Utils.getFilename("images/yieldTrackerMenuIcon.dds", YieldTrackerGUI.dir)
    inGameMenu:addPageTab(frame, iconPath, GuiUtils.getUVs(uvs))

    -- Ensure the new page appears in the correct order in pageFrames
    moveElement(inGameMenu.pageFrames, frame, abovePrices)

    -- Rebuild tab list to include the new page
    inGameMenu:rebuildTabList()
end
