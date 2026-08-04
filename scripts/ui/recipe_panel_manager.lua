-- 面板管理器：管理所有已打开的 RecipePanel 实例
-- 响应容器开关创建/销毁面板，绑定外部容器的物品变化通知，承接烹饪按钮包装派发
local RecipePanel = require("ui/recipe_panel")
local Config = require("config/config_manager")
local MemoryStore = require("auto_cook/recipe_memory")

local Manager = {
    _panels = {},                 -- container ent -> RecipePanel
    _cookbook_data = nil,
    _ext_container_listeners = {},
    _notify_debounce_task = nil,
}

function Manager.Setup(cookbook_data)
    Manager._cookbook_data = cookbook_data
end

function Manager.HasPanels()
    return next(Manager._panels) ~= nil
end

function Manager.GetPanel(container)
    return Manager._panels[container]
end

-- 包装烹饪按钮：在烹饪开始且锅满时，把当前食材保存为配方记忆。
-- 注意：rep:GetWidget() 返回的是 containers.params 里的共享表（containers.lua 的 widgetsetup 是浅拷贝，
-- 且 portablecookpot 与 cookpot 共享同一张表），因此全局只能包装一次——否则每次开面板都会叠加一层闭包，
-- 永久污染共享配置并让旧 panel 无法被回收。包装后通过 Manager._panels[ent] 查当前面板派发。
local function WrapCookButtonOnce(btn)
    if btn._csp_wrapped then return end
    btn._csp_wrapped = true
    local orig_fn = btn.fn
    btn._csp_orig_fn = orig_fn
    btn.fn = function(ent, ...)
        local panel = ent and Manager._panels[ent]
        if panel and ent.replica and ent.replica.container then
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
                if panel._auto_cook_mode == "memory" and panel._pending_recipe_name then
                    if panel._auto_cook and panel._cooker_recipes and panel._cooker_recipes[panel._pending_recipe_name] then
                        panel._auto_cook:SaveRecipeMemory(panel._pending_recipe_name, prefab_data)
                    end
                end
                panel._pending_recipe_name = nil
            end
        end
        return orig_fn(ent, ...)
    end
end

function Manager.CreatePanel(hud, container, is_brewer)
    if Manager._panels[container] ~= nil then
        return Manager._panels[container]
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

    local enable_backpack = Config.GetBackpackCheckMode()
	local auto_cook_source = Config.GetAutoCookSource()
	local auto_cook_mode = Config.GetAutoCookMode()
	local select_mode = Config.GetSelectMode()
	local debug_logging = Config.IsDebugLogging()
	local panel_prefs = MemoryStore.GetOrCreatePanelPrefs()

	local range_init = nil
	if auto_cook_source ~= "off" and auto_cook_mode == "memory" then
		range_init = MemoryStore.GetRangeSearch(30)
	end

	local panel = RecipePanel(Manager._cookbook_data, { strings = STRINGS, tuning = TUNING }, hud.owner, enable_backpack, auto_cook_source, auto_cook_mode, range_init, panel_prefs, select_mode, debug_logging)
    parent:AddChild(panel)
    local pos = containerwidget:GetPosition()
    panel:SetPosition(pos.x + 100, pos.y)
    panel:SetCooker(container.prefab, is_brewer)
    panel:SetAcceptsStacksFromContainer(container)
    panel:StartMonitor(container)

    if auto_cook_source ~= "off" and panel._auto_cook and panel._auto_cook_mode == "memory" then
        local active_name = MemoryStore.GetActiveRecipe()
        if active_name then
            panel._auto_cook:SwitchToRecipe(active_name)
            panel:ScrollToRecipe(active_name)
        end

        panel._on_dish_click = function(recipe_name)
            panel._pending_recipe_name = recipe_name
            if recipe_name and panel._cooker_recipes and panel._cooker_recipes[recipe_name] then
                panel:SetAutoCookEnabled(true)
                MemoryStore.SetActiveRecipe(recipe_name)
                MemoryStore.Save()
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
        -- 记录烹饪按钮原始函数供自动做饭调用（必须存原始函数，而非包装后的版本）
        if auto_cook_source ~= "off" then
            panel._auto_cook:SetStewerFn(container.prefab, btn._csp_orig_fn or btn.fn)
        end
        -- 包装烹饪按钮（全局只包装一次，见 WrapCookButtonOnce 注释）
        WrapCookButtonOnce(btn)
    end

    Manager._panels[container] = panel
    return panel
end

function Manager.DestroyPanel(container)
    local panel = Manager._panels[container]
    if panel ~= nil then
        panel:StopMonitor()
        panel._pending_recipe_name = nil
        -- 任务队列是全局共享实例（见 auto_cook/auto_cook_controller.lua），不随面板销毁：
        -- QuickCook/Execute 的流程就是先关闭面板再注册任务，随面板销毁会把刚注册的任务杀掉
        panel:Kill()
        Manager._panels[container] = nil
        -- 持久化面板偏好（分类/排序等改动随 blob 一并落盘）
        MemoryStore.Save()
        return true
    end
    return false
end

-- 强制刷新所有面板：清空图鉴列表缓存(_cached_raw_key)与可做检测缓存(_cached_bag_counts)，
-- 让面板立即按最新数据重渲染。用于环境（季节/月相）变化后，无需重新开关锅即可实时更新。
function Manager.ForceRefreshPanels()
    for _, panel in pairs(Manager._panels) do
        if panel then
            panel._cached_raw_key = nil      -- 图鉴列表强制重新构建（拿到最新 data.all）
            panel._cached_raw = nil
            panel._cached_bag_counts = nil   -- 可做检测强制重新匹配（绕过食材相同即跳过）
            panel._backpack_recipes = nil
            if panel.MarkBackpackDirty then panel:MarkBackpackDirty() end
            if panel.RefreshDisplay then panel:RefreshDisplay() end
        end
    end
end

-- 外部容器（背包/箱子/冰箱等）内容变化时，通知所有面板刷新「可做」检测（防抖）
function Manager.NotifyAll()
    if Manager._notify_debounce_task then return end
    if not ThePlayer then
        for _, panel in pairs(Manager._panels) do
            if panel.MarkBackpackDirty then
                panel:MarkBackpackDirty()
                panel:RefreshDisplay()
            end
        end
        return
    end
    Manager._notify_debounce_task = ThePlayer:DoTaskInTime(0.15, function()
        Manager._notify_debounce_task = nil
        for _, panel in pairs(Manager._panels) do
            if panel.MarkBackpackDirty then
                panel:MarkBackpackDirty()
                panel:RefreshDisplay()
            end
        end
    end)
end

function Manager.BindExtContainer(container)
    if not container or not container.prefab then return end
    if Manager._ext_container_listeners[container] then return end

    local cb = function()
        Manager.NotifyAll()
    end

    container:RemoveEventCallback("itemget", cb)
    container:ListenForEvent("itemget", cb)
    container:RemoveEventCallback("itemlose", cb)
    container:ListenForEvent("itemlose", cb)

    Manager._ext_container_listeners[container] = {cb = cb}
end

function Manager.UnbindExtContainer(container)
    local entry = Manager._ext_container_listeners[container]
    if not entry then return end
    container:RemoveEventCallback("itemget", entry.cb)
    container:RemoveEventCallback("itemlose", entry.cb)
    Manager._ext_container_listeners[container] = nil
end

-- 清空全部配方记忆（数据 + 各面板会话状态）
function Manager.ClearAllAutoCookMemory()
    MemoryStore.Clear()
    if ThePlayer and ThePlayer.HUD then
        for _, panel in pairs(Manager._panels) do
            if panel and panel._auto_cook then
                panel._pending_recipe_name = nil
                panel._auto_cook:ClearMemory()
            end
        end
    end
end

return Manager
