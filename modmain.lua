-- 模组入口：Hook 容器开关、创建/销毁 RecipePanel、管理自动做饭记忆
GLOBAL.setmetatable(env, { __index = function(t, k) return GLOBAL.rawget(GLOBAL, k) end })

Assets = Assets or {}
table.insert(Assets, Asset("ATLAS", "images/food_tags.xml"))
table.insert(Assets, Asset("IMAGE", "images/food_tags.tex"))
table.insert(Assets, Asset("ATLAS", "images/food_types.xml"))
table.insert(Assets, Asset("IMAGE", "images/food_types.tex"))

require "ingredienttags"
require "foodatlas"

local _language_map = {
    zh = "cn",  zhr = "cn", zht = "cn",
    ch = "cn",  chs = "cn", sc = "cn", chinese = "cn",
    ru = "ru",  russian = "ru",
}
local function LoadLanguage()
    local lang = GetModConfigData("language")
    if lang == "auto" then
        lang = _language_map[_G.LanguageTranslator and _G.LanguageTranslator.defaultlang] or "en"
    end
    modimport("scripts/language/cn.lua")
    if lang == "en" then
        modimport("scripts/language/en.lua")
    end
end
LoadLanguage()

local ContainerDetector = require("container_detector")
local CookbookData = require("cookbook_data")
local RecipePanel  = require("widgets/recipe_panel")

local g_cookbook_data = CookbookData()
local enable_hof_compat = GetModConfigData("enable_hof_compat")
local enable_myth_compat = GetModConfigData("enable_myth_compat")
local enable_xd_compat = GetModConfigData("enable_xd_compat")
local show_viewport_border = GetModConfigData("show_viewport_border")
GLOBAL.CSP_SHOW_VIEWPORT_BORDER = show_viewport_border

AddSimPostInit(function()
    g_cookbook_data:Collect()
end)

local recipe_panels = {}

local panel_prefs = { category = "all", sort_id = nil, sort_state = 0 }

local memory_data = {}

local function LoadMemoryData()
    local str = TheSim:GetSetting("complex_smart_pot", "memory")
    if str and str ~= "" then
        local ok, data = pcall(json.decode, str)
        if ok and type(data) == "table" then
            return data
        end
    end
    return {}
end

local function SaveMemoryData()
    memory_data._panel_prefs = panel_prefs
    local ok, str = pcall(json.encode, memory_data)
    if ok then
        TheSim:SetSetting("complex_smart_pot", "memory", str)
    end
end

AddSimPostInit(function()
    memory_data = LoadMemoryData()
    if memory_data._panel_prefs then
        panel_prefs = memory_data._panel_prefs
        memory_data._panel_prefs = nil
    end
end)

local function ClearAutoCookMemory()
    memory_data = {}
    SaveMemoryData()
    if ThePlayer and ThePlayer.HUD then
        for container, panel in pairs(recipe_panels) do
            if panel and panel._auto_cook then
                panel._auto_cook:RestoreRecipeMemories(nil)
                panel._auto_cook._memory = nil
                panel._auto_cook._active_recipe = nil
                panel._pending_recipe_name = nil
                if panel._pot_bar then
                    panel._pot_bar:UpdateSlots(nil)
                end
                panel._auto_cook:_UpdatePotBarLabel()
            end
        end
    end
end
_G.ClearAutoCookMemory = ClearAutoCookMemory

local function CreateRecipePanel(hud, container, is_brewer)
    if recipe_panels[container] ~= nil then
        return recipe_panels[container]
    end

    local containerwidget = hud.controls ~= nil
            and hud.controls.containers ~= nil
            and hud.controls.containers[container]
    if containerwidget == nil then
        return nil
    end

    local parent = containerwidget:GetParent()
    if parent == nil then
        return nil
    end

    local enable_backpack = GetModConfigData("enable_backpack_check")
	if enable_backpack == true then enable_backpack = "inv" end
	if enable_backpack == false then enable_backpack = "off" end
	local auto_cook_source = GetModConfigData("enable_auto_cook")
	local range_init = auto_cook_source ~= "off" and (memory_data._range_search or 30) or nil
	local select_mode = GetModConfigData("recipe_select_behavior") or "click"
	local panel = RecipePanel(g_cookbook_data, { strings = STRINGS, tuning = TUNING }, hud.owner, enable_backpack, auto_cook_source, range_init, panel_prefs, select_mode)
    parent:AddChild(panel)
    local pos = containerwidget:GetPosition()
    panel:SetPosition(pos.x + 100, pos.y)
    panel:SetCooker(container.prefab, is_brewer)
    panel:StartMonitor(container)

    if auto_cook_source ~= "off" then
	    local recipe_map = memory_data._recipe_memories
        if type(recipe_map) == "table" then
            panel._auto_cook:RestoreRecipeMemories(recipe_map)
            local active_name = memory_data._active_recipe
            if active_name then
                panel._auto_cook:SwitchToRecipe(active_name)
                panel:ScrollToRecipe(active_name)
            end
        end

        panel._auto_cook:SetSaveCallback(function()
            memory_data._range_search = panel._auto_cook:GetRangeSearch()
            SaveMemoryData()
        end)

        panel._auto_cook:SetRecipeMemorySaveCallback(function(recipe_name, mem)
            if not memory_data._recipe_memories then
                memory_data._recipe_memories = {}
            end
            memory_data._recipe_memories[recipe_name] = mem
            memory_data._active_recipe = recipe_name
            SaveMemoryData()
        end)

        panel._on_dish_click = function(recipe_name)
            panel._pending_recipe_name = recipe_name
            if recipe_name and panel._cooker_recipes and panel._cooker_recipes[recipe_name] then
                panel:SetAutoCookEnabled(true)
                memory_data._active_recipe = recipe_name
                SaveMemoryData()
                panel._auto_cook:SwitchToRecipe(recipe_name)
            else
                panel:SetAutoCookEnabled(false)
                panel._auto_cook._memory = nil
                panel._auto_cook._active_recipe = nil
                if panel._pot_bar then
                    panel._pot_bar:UpdateSlots(nil)
                end
                panel._auto_cook:_UpdatePotBarLabel()
            end
        end
    end

    local rep = container.replica and container.replica.container
    local btn = rep and rep:GetWidget() and rep:GetWidget().buttoninfo
    if btn and btn.fn then
        if auto_cook_source ~= "off" then
            panel._auto_cook:SetStewerFn(container.prefab, btn.fn)
        end

        local orig_fn = btn.fn
        btn.fn = function(ent, ...)
            if auto_cook_source ~= "off" and ent and ent.replica and ent.replica.container then
                local c = ent.replica.container
                local prefab_data = {}
                local has_empty_slot
                for i = 1, c:GetNumSlots() do
                    local item = c:GetItemInSlot(i)
                    local p = item and item.prefab
                    if p then
                        table.insert(prefab_data, p)
                    else
                        has_empty_slot = true
                        break
                    end
                end
                if not has_empty_slot then
                    if panel._pending_recipe_name then
                        if panel._cooker_recipes and panel._cooker_recipes[panel._pending_recipe_name] then
                            panel._auto_cook:SaveRecipeMemory(panel._pending_recipe_name, prefab_data)
                        end
                    end
                    panel._pending_recipe_name = nil
                end
            end
            return orig_fn(ent, ...)
        end
    end

    recipe_panels[container] = panel
    return panel
end

local function DestroyRecipePanel(container)
    local panel = recipe_panels[container]
    if panel ~= nil then
        panel:StopMonitor()
        panel._pending_recipe_name = nil
        if panel._auto_cook and panel._auto_cook._task_queue then
            panel._auto_cook._task_queue:Destroy()
        end
        panel:Kill()
        recipe_panels[container] = nil
        SaveMemoryData()
        return true
    end
    return false
end

AddClassPostConstruct("cameras/followcamera", function(self)
    local _ZoomIn = self.ZoomIn
    self.ZoomIn = function(self, ...)
        if next(recipe_panels) then return end
        return _ZoomIn(self, ...)
    end
    local _ZoomOut = self.ZoomOut
    self.ZoomOut = function(self, ...)
        if next(recipe_panels) then return end
        return _ZoomOut(self, ...)
    end
end)

local ext_container_listeners = {}

local notify_debounce_task = nil
local function NotifyAllPanels()
    if notify_debounce_task then return end
    if not ThePlayer then
        for _, panel in pairs(recipe_panels) do
            if panel.MarkBackpackDirty then
                panel:MarkBackpackDirty()
                panel:RefreshDisplay()
            end
        end
        return
    end
    notify_debounce_task = ThePlayer:DoTaskInTime(0.15, function()
        notify_debounce_task = nil
        for _, panel in pairs(recipe_panels) do
            if panel.MarkBackpackDirty then
                panel:MarkBackpackDirty()
                panel:RefreshDisplay()
            end
        end
    end)
end

local function BindExtContainer(container)
    if not container or not container.prefab then return end
    if ext_container_listeners[container] then return end

    local cb = function()
        NotifyAllPanels()
    end

    container:RemoveEventCallback("itemget", cb)
    container:ListenForEvent("itemget", cb)
    container:RemoveEventCallback("itemlose", cb)
    container:ListenForEvent("itemlose", cb)

    ext_container_listeners[container] = {cb = cb}
end

local function UnbindExtContainer(container)
    local entry = ext_container_listeners[container]
    if not entry then return end
    container:RemoveEventCallback("itemget", entry.cb)
    container:RemoveEventCallback("itemlose", entry.cb)
    ext_container_listeners[container] = nil
end

AddClassPostConstruct("screens/playerhud", function(self)
    local _OpenContainer = self.OpenContainer
    self.OpenContainer = function(self, container, side)
        _OpenContainer(self, container, side)

        if ContainerDetector.IsCookpot(container) then
            CreateRecipePanel(self, container, false)
        elseif ContainerDetector.IsBrewer(container, enable_hof_compat) then
            CreateRecipePanel(self, container, true)
        elseif ContainerDetector.IsMyth(container, enable_myth_compat) then
            CreateRecipePanel(self, container, false)
        elseif ContainerDetector.IsXd(container, enable_xd_compat) then
            CreateRecipePanel(self, container, false)
        else
            BindExtContainer(container)
            NotifyAllPanels()
        end
    end

    local _CloseContainer = self.CloseContainer
    self.CloseContainer = function(self, container, side)
        if ContainerDetector.IsCookpot(container) or ContainerDetector.IsBrewer(container, enable_hof_compat) or ContainerDetector.IsMyth(container, enable_myth_compat) or ContainerDetector.IsXd(container, enable_xd_compat) then
            DestroyRecipePanel(container)
        else
            UnbindExtContainer(container)
            NotifyAllPanels()
        end
        _CloseContainer(self, container, side)
    end
end)