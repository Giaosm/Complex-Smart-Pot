-- 自动做饭控制器：对外入口，协调配方记忆、设备查找、食材搬运、烹饪执行各子模块
local TaskQueue = require("auto_cook/task_queue")
local CookerFinder = require("auto_cook/cooker_finder")
local Mover = require("auto_cook/ingredient_mover")
local Action = require("auto_cook/cooking_action")
local MemoryStore = require("auto_cook/recipe_memory")
local Logger = require("debug/logger")

local RANGE_DEFAULT = 30
local RANGE_MIN = 5
local RANGE_MAX = 99

-- 共享任务队列：所有权不跟随 panel 生命周期（QuickCook/Execute 先关闭容器面板再注册任务，
-- 若队列随面板销毁，任务会被立即杀掉）；同时保证 playercontroller.OnControl 全局只被包装一次，
-- 多面板共存（锅+酒桶）时不会出现输入劫持链互相拆除的问题
local shared_task_queue = nil
local function GetSharedTaskQueue()
    if not shared_task_queue then
        shared_task_queue = TaskQueue()
    end
    return shared_task_queue
end

local function Say(msg)
    if ThePlayer and ThePlayer.components and ThePlayer.components.talker then
        ThePlayer.components.talker:Say(msg, nil, nil, nil, nil)
    end
    return true
end

local function Silent()
    return true
end

local function IGetElement(tbl, fn)
    for _, v in ipairs(tbl) do
        local ret = fn(v)
        if ret then return v end
    end
end

-- 校验食材列表是否适合当前设备槽位规则
-- 普通设备：食材数量必须严格等于槽位数
-- 特殊设备（如炼丹炉）：总数量可超过槽位，但不同种类数不能超过槽位
local function ValidateIngredientsForCooker(ingredients, max_slots, use_quantity)
    if not ingredients or #ingredients == 0 then
        return false, "empty"
    end
    if not use_quantity then
        if #ingredients ~= max_slots then
            return false, "slot_mismatch", #ingredients, max_slots
        end
    else
        local distinct = {}
        local distinct_count = 0
        for _, ing in ipairs(ingredients) do
            local name = type(ing) == "table" and ing.prefab or ing
            if not distinct[name] then
                distinct[name] = true
                distinct_count = distinct_count + 1
            end
        end
        if distinct_count > max_slots then
            return false, "too_many_types", distinct_count, max_slots
        end
    end
    return true
end

-- 把 {prefab=, count=} 或扁平字符串数组统一展开为扁平 prefab 列表（执行层均按此处理）
local function NormalizeIngredients(ingredients)
    if not ingredients then return nil end
    local flat = {}
    for _, ing in ipairs(ingredients) do
        if type(ing) == "table" and ing.prefab then
            for _ = 1, ing.count or 1 do
                table.insert(flat, ing.prefab)
            end
        else
            table.insert(flat, ing)
        end
    end
    return flat
end

-- 仅用于调试：把食材列表序列化
local function DumpIngredients(ingredients)
    if not ingredients then return "nil" end
    local counts = {}
    for _, ing in ipairs(ingredients) do
        local name = type(ing) == "table" and ing.prefab or ing
        counts[name] = (counts[name] or 0) + (type(ing) == "table" and ing.count or 1)
    end
    local items = {}
    for k, v in pairs(counts) do table.insert(items, k .. "=" .. v) end
    table.sort(items)
    return "[" .. table.concat(items, ",") .. "]"
end

local function Cook(prefab, data, range, auto_cook_source, target_cont, quiet)
    if not ThePlayer then
        return Silent()
    end
    Logger.Logf("[智能锅] Cook: prefab=%s data=%s quiet=%s", tostring(prefab), DumpIngredients(data), tostring(quiet))
    if Action.HasActiveItem() then
        Logger.Log("[智能锅] Cook 退出: 玩家正持有物品")
        return Silent()
    end

    local conts = target_cont and {target_cont} or CookerFinder.FindEnts(prefab, range)
    if not conts[1] then
        Logger.Log("[智能锅] Cook 退出: 未找到设备")
        return Silent()
    end

    local ret = Mover.CheckIng(data, auto_cook_source)
    Logger.Logf("[智能锅] Cook CheckIng=%s", tostring(ret ~= nil))
    if ret then
        local act, right
        local cont = IGetElement(conts, function(target)
            act, right = Action.GetMouseActionSoft({"HARVEST", "RUMMAGE"}, target)
            if act then
                if not quiet and target._flag_next and act.action.id == "RUMMAGE" then
                    return
                end
                return target
            end
        end)

        if cont then
            if act.action.id == "RUMMAGE" then
                local container = Action.OpenContainer(cont)
                if container then
                    if Mover.SyncPotContents(container, cont, data, auto_cook_source) then
                        Logger.Log("[智能锅] Cook SyncPotContents 成功")
                        local stewer_fn = Action.GetStewerFn(prefab)
                        if stewer_fn then
                            stewer_fn(cont, ThePlayer)
                        end
                        if not quiet and #conts > 1 then
                            cont._flag_next = true
                            cont:DoTaskInTime(10 * FRAMES, function()
                                cont._flag_next = nil
                            end)
                        end
                    else
                        Logger.Log("[智能锅] Cook 失败: SyncPotContents 返回 false")
                        return Silent()
                    end
                else
                    return Silent()
                end
            elseif not quiet then
                Action.DoMouseAction(act, right)
                Sleep(0)
                if Action.HasActiveItem() then
                    return Silent()
                end
            end
        end
    elseif not quiet then
        local act, right
        local pot = IGetElement(conts, function(target)
            act, right = Action.GetMouseActionSoft({"HARVEST"}, target)
            return act and target
        end)
        if pot then
            Action.DoMouseAction(act, right)
            Sleep(0)
            if Action.HasActiveItem() then
                return Silent()
            end
        else
            if not IGetElement(conts, function(target)
                return not Action.GetMouseActionSoft({"RUMMAGE"}, target)
            end) then
                return true
            end
        end
    end
    Sleep(0)
end

local AutoCook = Class(function(self, panel, range_init, auto_cook_source)
    self._panel = panel
    self._memory = nil
    self._active_recipe = nil
    self._range_search = range_init or RANGE_DEFAULT
    self._auto_cook_source = auto_cook_source or "inv"
    self._task_queue = GetSharedTaskQueue()
end)

function AutoCook:SetStewerFn(prefab, fn)
    Action.SetStewerFn(prefab, fn)
end

function AutoCook:GetRangeSearch()
    return self._range_search
end

function AutoCook:SetRangeSearch(v)
    self._range_search = math.clamp(v, RANGE_MIN, RANGE_MAX)
    MemoryStore.SetRangeSearch(self._range_search)
    MemoryStore.Save()
end

function AutoCook:SaveMemory(ingredients, use_quantity)
    local max_slots = self._panel._max_slots or 4
    if use_quantity == nil then
        use_quantity = self._panel._use_quantity_matching == true
    end
    Logger.Logf("[智能锅] SaveMemory: use_quantity=%s max_slots=%d ingredients=%s",
        tostring(use_quantity), max_slots, DumpIngredients(ingredients))
    local ok, err, a, b = ValidateIngredientsForCooker(ingredients, max_slots, use_quantity)
    if not ok then
        if err == "empty" then
            Logger.Log("[智能锅] SaveMemory 失败: 食材为空")
        elseif err == "slot_mismatch" then
            Logger.Logf("[智能锅] SaveMemory 失败: 普通设备食材数%d 不等于槽位数%d", a, b)
        elseif err == "too_many_types" then
            Logger.Logf("[智能锅] SaveMemory 失败: 特殊设备食材种类数%d 超过槽位数%d", a, b)
        end
        return false
    end
    self._memory = { ingredients = ingredients, use_quantity = use_quantity }
    if self._panel._pot_bar then
        self._panel._pot_bar:UpdateSlots(ingredients, use_quantity)
    end
    Logger.Log("[智能锅] SaveMemory 成功")
    return true
end

function AutoCook:SaveRecipeMemory(recipe_name, ingredients)
    local max_slots = self._panel._max_slots or 4
    local use_quantity = self._panel._use_quantity_matching == true
    Logger.Logf("[智能锅] SaveRecipeMemory: recipe=%s use_quantity=%s ingredients=%s",
        tostring(recipe_name), tostring(use_quantity), DumpIngredients(ingredients))
    if not recipe_name then
        Logger.Log("[智能锅] SaveRecipeMemory 失败: recipe 为空")
        return false
    end
    local ok, err, a, b = ValidateIngredientsForCooker(ingredients, max_slots, use_quantity)
    if not ok then
        if err == "empty" then
            Logger.Log("[智能锅] SaveRecipeMemory 失败: 食材为空")
        elseif err == "slot_mismatch" then
            Logger.Logf("[智能锅] SaveRecipeMemory 失败: 普通设备食材数%d 不等于槽位数%d", a, b)
        elseif err == "too_many_types" then
            Logger.Logf("[智能锅] SaveRecipeMemory 失败: 特殊设备食材种类数%d 超过槽位数%d", a, b)
        end
        return false
    end
    local mem = MemoryStore.GetOrCreateMem(recipe_name)
    mem.slots[mem.selected] = { ingredients = ingredients, use_quantity = use_quantity }
    self._active_recipe = recipe_name
    MemoryStore.SetActiveRecipe(recipe_name)
    MemoryStore.Save()
    self:SaveMemory(ingredients, use_quantity)
    Logger.Log("[智能锅] SaveRecipeMemory 成功")
    return true
end

function AutoCook:GetRecipeMemory(recipe_name)
    local slot_data = self:GetRecipeMemorySlot(recipe_name)
    return slot_data and slot_data.ingredients or nil
end

function AutoCook:GetRecipeMemorySlot(recipe_name)
    local mem = MemoryStore.GetMem(recipe_name)
    if not mem then return nil end
    return mem.slots[mem.selected or 1]
end

function AutoCook:SwitchToRecipe(recipe_name)
    self._active_recipe = recipe_name
    local slot_data = self:GetRecipeMemorySlot(recipe_name)
    if slot_data and slot_data.ingredients then
        self:SaveMemory(slot_data.ingredients, slot_data.use_quantity)
    else
        self._memory = nil
        if self._panel._pot_bar then
            self._panel._pot_bar:UpdateSlots(nil)
        end
    end
    self:_UpdatePotBarLabel()
    return slot_data ~= nil
end

function AutoCook:GetCurrentSlotIndex(recipe_name)
    if not recipe_name then
        return 0
    end
    local mem = MemoryStore.GetMem(recipe_name)
    if not mem then return 1 end
    return mem.selected or 1
end

function AutoCook:SwitchToRecipeSlot(recipe_name, slot_idx)
    if not recipe_name then return false end
    local mem = MemoryStore.GetOrCreateMem(recipe_name)
    mem.selected = ((slot_idx - 1) % MemoryStore.SLOT_COUNT) + 1
    self._active_recipe = recipe_name
    MemoryStore.SetActiveRecipe(recipe_name)
    MemoryStore.Save()
    local slot_data = mem.slots[mem.selected]
    if slot_data then
        self:SaveMemory(slot_data.ingredients, slot_data.use_quantity)
        self:_UpdatePotBarLabel()
        return true
    end
    self._memory = nil
    if self._panel._pot_bar then
        self._panel._pot_bar:UpdateSlots(nil)
    end
    self:_UpdatePotBarLabel()
    return false
end

function AutoCook:_UpdatePotBarLabel()
    if not self._panel._pot_bar then return end
    local name = self._active_recipe
    if not name then
        self._panel._pot_bar:SetSlotLabel("1/" .. tostring(MemoryStore.SLOT_COUNT))
        return
    end
    local idx = self:GetCurrentSlotIndex(name)
    self._panel._pot_bar:SetSlotLabel(tostring(idx) .. "/" .. tostring(MemoryStore.SLOT_COUNT))
end

function AutoCook:GetActiveRecipeName()
    return self._active_recipe
end

-- 清空当前会话状态（配方记忆数据的清空由 MemoryStore.Clear 负责）
function AutoCook:ClearMemory()
    self._memory = nil
    self._active_recipe = nil
    if self._panel._pot_bar then
        self._panel._pot_bar:UpdateSlots(nil)
    end
    self:_UpdatePotBarLabel()
end

function AutoCook:QuickCook(recipe_name)
    if self._task_queue:IsRunning() then
        return false
    end

    local max_slots = self._panel._max_slots or 4
    local use_quantity = self._panel._use_quantity_matching == true
    local current_container = self._panel._container
    if not current_container then
        return false
    end

    if self._panel._cooker_recipes and not self._panel._cooker_recipes[recipe_name] then
        Say(STRINGS.CSP.QUICK_WRONG_DEVICE)
        return false
    end

    local memory = self:GetRecipeMemory(recipe_name)
    Logger.Logf("[智能锅] QuickCook: recipe=%s use_quantity=%s memory=%s",
        tostring(recipe_name), tostring(use_quantity), DumpIngredients(memory))
    if not memory or #memory == 0 then
        Say(STRINGS.CSP.QUICK_NO_MEMORY)
        return false
    end
    local ok, err, a, b = ValidateIngredientsForCooker(memory, max_slots, use_quantity)
    if not ok then
        if err == "slot_mismatch" then
            Logger.Logf("[智能锅] QuickCook 失败: 普通设备记忆长度%d 不等于槽位数%d", a, b)
        elseif err == "too_many_types" then
            Logger.Logf("[智能锅] QuickCook 失败: 特殊设备记忆种类数%d 超过槽位数%d", a, b)
        end
        Say(STRINGS.CSP.QUICK_NO_MEMORY)
        return false
    end

    local slot_data = self._panel._slot_data
    if slot_data and next(slot_data) then
        local container = current_container.replica and current_container.replica.container
        if container then
            for _, item in pairs(container:GetItems() or {}) do
                if item and not Mover.CanTakeItem(item) then
                    Say(STRINGS.CSP.QUICK_NO_SPACE)
                    return false
                end
            end
        end
    end

    if not Mover.CheckIng(memory, self._auto_cook_source, current_container) then
        Logger.Log("[智能锅] QuickCook 失败: Mover.CheckIng 食材不足")
        Say(STRINGS.CSP.QUICK_NO_INGREDIENTS)
        return false
    end
    Logger.Log("[智能锅] QuickCook CheckIng 通过，注册烹饪任务")

    local hud = ThePlayer and ThePlayer.HUD
    if hud and hud.CloseContainer and current_container then
        hud:CloseContainer(current_container)
    end

    if Action.HasActiveItem() then
        Action.ReturnActiveItem()
    end

    self._task_queue:RegNowTask(
        function()
            return Cook(current_container.prefab, memory, self._range_search, self._auto_cook_source, current_container, true)
        end
    )

    return true
end

function AutoCook:QuickCookWithIngredients(recipe_name, ingredients)
    if self._task_queue:IsRunning() then
        return false
    end

    local current_container = self._panel._container
    if not current_container then
        return false
    end

    if self._panel._cooker_recipes and not self._panel._cooker_recipes[recipe_name] then
        Say(STRINGS.CSP.QUICK_WRONG_DEVICE)
        return false
    end

    -- 弹窗可能传入 {prefab=, count=} 的堆叠格式，执行层统一展开为扁平 prefab 列表
    local flat_ingredients = NormalizeIngredients(ingredients)
    if not flat_ingredients or #flat_ingredients == 0 then
        return false
    end

    local slot_data = self._panel._slot_data
    if slot_data and next(slot_data) then
        local container = current_container.replica and current_container.replica.container
        if container then
            for _, item in pairs(container:GetItems() or {}) do
                if item and not Mover.CanTakeItem(item) then
                    Say(STRINGS.CSP.QUICK_NO_SPACE)
                    return false
                end
            end
        end
    end

    if not Mover.CheckIng(flat_ingredients, self._auto_cook_source, current_container) then
        Say(STRINGS.CSP.QUICK_NO_INGREDIENTS)
        return false
    end

    local hud = ThePlayer and ThePlayer.HUD
    if hud and hud.CloseContainer and current_container then
        hud:CloseContainer(current_container)
    end

    if Action.HasActiveItem() then
        Action.ReturnActiveItem()
    end

    self:SaveRecipeMemory(recipe_name, flat_ingredients)

    self._task_queue:RegNowTask(
        function()
            return Cook(current_container.prefab, flat_ingredients, self._range_search, self._auto_cook_source, current_container, true)
        end
    )

    return true
end

function AutoCook:Execute()
    if self._task_queue:IsRunning() then
        return false
    end

    local max_slots = self._panel._max_slots or 4
    local use_quantity = self._panel._use_quantity_matching == true
    Logger.Logf("[智能锅] Execute: use_quantity=%s max_slots=%d memory=%s",
        tostring(use_quantity), max_slots, DumpIngredients(self._memory and self._memory.ingredients))
    if not self._memory or not self._memory.ingredients or #self._memory.ingredients == 0 then
        Say(STRINGS.CSP.AUTO_NEED_RECIPE)
        return false
    end
    local ok, err, a, b = ValidateIngredientsForCooker(self._memory.ingredients, max_slots, use_quantity)
    if not ok then
        if err == "slot_mismatch" then
            Logger.Logf("[智能锅] Execute 失败: 普通设备记忆长度%d 不等于槽位数%d", a, b)
        elseif err == "too_many_types" then
            Logger.Logf("[智能锅] Execute 失败: 特殊设备记忆种类数%d 超过槽位数%d", a, b)
        end
        Say(STRINGS.CSP.AUTO_NEED_RECIPE)
        return false
    end

    local current_container = self._panel._container
    if not current_container then
        return false
    end

    local prefab = current_container.prefab
    local data = self._memory.ingredients
    Logger.Log("[智能锅] Execute 检查通过，注册烹饪任务")

    local hud = ThePlayer and ThePlayer.HUD
    if hud and hud.CloseContainer and current_container then
        hud:CloseContainer(current_container)
    end

    if Action.HasActiveItem() then
        Action.ReturnActiveItem()
    end

    Say(STRINGS.CSP.AUTO_START)
    self._task_queue:RegNowTask(
        function()
            return Cook(prefab, data, self._range_search, self._auto_cook_source)
        end,
        function()
            Say(STRINGS.CSP.AUTO_STOP)
        end
    )

    return true
end

return AutoCook
