-- 自动做饭控制器：对外入口，协调配方记忆、设备查找、食材搬运、烹饪执行各子模块
local TaskQueue = require("auto_cook/task_queue")
local CookerFinder = require("auto_cook/cooker_finder")
local Mover = require("auto_cook/ingredient_mover")
local Action = require("auto_cook/cooking_action")
local MemoryStore = require("auto_cook/recipe_memory")
local Logger = require("debug/logger")
local PanelManager = require("ui/recipe_panel_manager")
local GetStackSize = require("utils/getstacksize")

local RANGE_DEFAULT = 30
local RANGE_MIN = 5
local RANGE_MAX = 99

-- 烹饪确认与重试：stewer_fn 点击后最多等 1 秒确认，未确认则重试（重新同步食材+点击），最多 3 次尝试
local MAX_COOK_ATTEMPTS = 3
local COOK_CONFIRM_TIMEOUT = 1

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
    if not Logger.IsEnabled() then return "" end
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

-- 获取锅的容器对象（优先服务端 components.container，客户端 replica.container）
local function GetPotContainer(pot)
    if not pot then return nil end
    if pot.components and pot.components.container then
        return pot.components.container
    end
    if pot.replica and pot.replica.container then
        return pot.replica.container
    end
    return nil
end

local function IsContainerOpenable(container)
    if container.CanBeOpened then
        local ok, v = pcall(function() return container:CanBeOpened() end)
        if ok then return v end
    end
    -- 服务端 components.container 没有 CanBeOpened 方法，直接读字段
    if container.canbeopened ~= nil then
        return container.canbeopened
    end
    return nil
end

-- 记录容器状态，用于确认烹饪/收获是否完成
local function CaptureContainerState(container)
    if not container then return nil end
    local ok, empty = pcall(function() return container:IsEmpty() end)
    if not ok then return nil end
    local ok2, full = pcall(function() return container:IsFull() end)
    return {
        empty = empty or false,
        full = full or false,
        can_open = IsContainerOpenable(container) ~= false,
    }
end

-- 服务端/主机：stewer 组件可直接判断
local function IsStewerCooking(pot)
    local stewer = pot and pot.components and pot.components.stewer
    if not stewer then return false end
    return stewer:IsCooking()
end

local function IsPotAnimCooking(pot)
    local animstate = pot and pot.AnimState
    if not animstate then return false end
    local ok1, is_loop = pcall(function() return animstate:IsCurrentAnimation("cooking_loop") end)
    local ok2, is_pre = pcall(function() return animstate:IsCurrentAnimation("cooking_pre") end)
    if not ok1 or not ok2 then return false end
    return is_loop or is_pre
end

local function IsContainerBusy(pot)
    local rep = pot and pot.replica and pot.replica.container
    if rep and rep.IsBusy then
        local ok, busy = pcall(function() return rep:IsBusy() end)
        if ok then return busy end
    end
    return false
end

-- 客户端：通过动画 + 容器锁定状态推断烹饪是否已经开始
-- 烹饪前：能打开；烹饪后：锁定（canbeopened=false）。
-- 注意容器关闭后 replica 的 IsEmpty/IsFull 会返回 nil，所以不依赖它们。
local function IsCookingStarted(pot, before_state)
    if not pot or not pot:IsValid() then return false end
    if IsStewerCooking(pot) then return true end
    if IsPotAnimCooking(pot) then return true end

    local container = GetPotContainer(pot)
    if not container then return false end

    local can_open = IsContainerOpenable(container)
    if can_open == nil then return false end
    local now_locked = not can_open

    -- 我们调用 stewer_fn 前已经确认容器是满且可打开的；
    -- 只要现在变成锁定，就说明服务器已经开始烹饪。
    if before_state and before_state.full and before_state.can_open then
        return now_locked
    end

    return false
end

local function IsHarvestDone(pot, before_state)
    if not pot or not pot:IsValid() then return false end
    local stewer = pot.components and pot.components.stewer
    if stewer then
        return not stewer:IsDone()
    end
    local container = GetPotContainer(pot)
    if not container then return false end
    local can_open = IsContainerOpenable(container)
    if can_open == nil then return false end
    -- 收获前：锁定；收获后：可打开
    if before_state and not before_state.can_open then
        return can_open
    end
    return can_open
end

local function CountRequiredIngredients(data)
    local need = {}
    if not data then return need end
    if #data > 0 then
        for _, ing in ipairs(data) do
            local name = type(ing) == "table" and ing.prefab or ing
            need[name] = (need[name] or 0) + (type(ing) == "table" and ing.count or 1)
        end
    else
        for name, count in pairs(data) do
            if type(name) == "string" then
                need[name] = (need[name] or 0) + count
            end
        end
    end
    return need
end

local function GetContainerItemCounts(container)
    local counts = {}
    if not container then return counts end
    local ok, num_slots = pcall(function() return container:GetNumSlots() end)
    if not ok or not num_slots then return counts end
    for i = 1, num_slots do
        local ok2, item = pcall(function() return container:GetItemInSlot(i) end)
        if ok2 and item and item.prefab then
            counts[item.prefab] = (counts[item.prefab] or 0) + GetStackSize(item)
        end
    end
    return counts
end

-- 等待容器处于可点击“烹饪”的状态：不 busy、能打开、且实际食材数量满足 data 要求
-- 普通锅 data 是 4 个食材，必须占满 4 个槽；炼丹炉/酿酒桶等数量匹配设备则按堆叠数量判断
local function IsContainerReadyForCook(pot, data)
    if not pot or not pot:IsValid() then return false end
    local container = GetPotContainer(pot)
    if not container then return false end
    if IsContainerBusy(pot) then return false end
    local can_open = IsContainerOpenable(container)
    if can_open == false then return false end

    local required = CountRequiredIngredients(data)
    local actual = GetContainerItemCounts(container)
    for prefab, count in pairs(required) do
        if (actual[prefab] or 0) < count then return false end
    end
    return true
end

local function WaitForContainerReady(pot, data, timeout)
    timeout = timeout or 2
    local start_time = GetTime()
    while GetTime() - start_time < timeout do
        if IsContainerReadyForCook(pot, data) then
            Logger.Log("[智能锅] 容器已准备好，可以执行烹饪")
            return true
        end
        Sleep(FRAMES * 3)
    end
    Logger.Log("[智能锅] 容器准备超时")
    return false
end

local function DebugPotState(pot, label)
    if not pot or not pot:IsValid() then
        Logger.Logf("[智能锅] %s pot invalid", label)
        return
    end
    local container = GetPotContainer(pot)
    local empty, full, can_open
    if container then
        local ok1, v1 = pcall(function() return container:IsEmpty() end)
        local ok2, v2 = pcall(function() return container:IsFull() end)
        empty = ok1 and tostring(v1) or "err"
        full = ok2 and tostring(v2) or "err"
        can_open = IsContainerOpenable(container)
    end
    local anim_loop, anim_pre = false, false
    if pot.AnimState then
        local ok1, v1 = pcall(function() return pot.AnimState:IsCurrentAnimation("cooking_loop") end)
        local ok2, v2 = pcall(function() return pot.AnimState:IsCurrentAnimation("cooking_pre") end)
        anim_loop = ok1 and v1 or false
        anim_pre = ok2 and v2 or false
    end
    local busy = IsContainerBusy(pot)
    local stewer_cooking = IsStewerCooking(pot)
    Logger.Logf("[智能锅] %s empty=%s full=%s can_open=%s anim_loop=%s anim_pre=%s busy=%s stewer=%s",
        label, tostring(empty), tostring(full), tostring(can_open), tostring(anim_loop), tostring(anim_pre), tostring(busy), tostring(stewer_cooking))
end

-- 等待烹饪真正开始（轮询容器状态/动画/stewer，而非固定等待时间）
local function WaitForCookingStart(pot, before_state, timeout)
    timeout = timeout or 5
    local start_time = GetTime()
    local iterations = 0
    while GetTime() - start_time < timeout do
        if IsCookingStarted(pot, before_state) then
            Logger.Log("[智能锅] 烹饪已确认开始")
            return true
        end
        iterations = iterations + 1
        if iterations % 30 == 0 then
            DebugPotState(pot, "烹饪等待中状态")
        end
        Sleep(FRAMES * 3)
    end
    DebugPotState(pot, "烹饪确认超时最终状态")
    Logger.Log("[智能锅] 烹饪确认超时")
    return false
end

local function WaitForHarvestDone(pot, before_state, timeout)
    timeout = timeout or 5
    local start_time = GetTime()
    while GetTime() - start_time < timeout do
        if IsHarvestDone(pot, before_state) then
            Logger.Log("[智能锅] 收获已确认完成")
            return true
        end
        Sleep(FRAMES * 3)
    end
    Logger.Log("[智能锅] 收获确认超时")
    return false
end

local function Cook(prefab, data, range, auto_cook_source, target_cont, quiet, preferred_cont)
    if not ThePlayer then
        return Silent()
    end
    Logger.LogLazy(function()
        return string.format("[智能锅] Cook: prefab=%s data=%s quiet=%s", tostring(prefab), DumpIngredients(data), tostring(quiet))
    end)
    if Action.HasActiveItem() then
        Logger.Log("[智能锅] Cook 退出: 玩家正持有物品")
        return Silent()
    end

    local conts = target_cont and {target_cont} or CookerFinder.FindEnts(prefab, range, preferred_cont)
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
                local cook_started = false
                for attempt = 1, MAX_COOK_ATTEMPTS do
                    Logger.Logf("[智能锅] Cook 第%d/%d次尝试开始", attempt, MAX_COOK_ATTEMPTS)
                    local container = Action.OpenContainer(cont)
                    if not container then
                        Logger.Log("[智能锅] Cook 失败: 无法打开容器")
                        return Silent()
                    end
                    Logger.Log("[智能锅] Cook 容器已就绪")

                    if not Mover.SyncPotContents(container, cont, data, auto_cook_source, prefab) then
                        Logger.Log("[智能锅] Cook 失败: SyncPotContents 返回 false")
                        return Silent()
                    end
                    Logger.Log("[智能锅] Cook SyncPotContents 成功")

                    if not WaitForContainerReady(cont, data) then
                        if attempt < MAX_COOK_ATTEMPTS then
                            Logger.Logf("[智能锅] Cook 容器未准备好，进行第%d次重试", attempt)
                            Sleep(FRAMES * 10)
                        else
                            Logger.Log("[智能锅] Cook 失败: 容器未准备好，重试次数已用完")
                            return Silent()
                        end
                    else
                        local stewer_fn = Action.GetStewerFn(prefab)
                        Logger.Logf("[智能锅] Cook 获取到 stewer_fn=%s", tostring(stewer_fn ~= nil))
                        if not stewer_fn then
                            Logger.Log("[智能锅] Cook 失败: 未找到 stewer_fn")
                            return Silent()
                        end
                        Logger.Log("[智能锅] Cook 调用 stewer_fn")
                        local before_state = CaptureContainerState(GetPotContainer(cont))
                        stewer_fn(cont, ThePlayer)
                        if WaitForCookingStart(cont, before_state, COOK_CONFIRM_TIMEOUT) then
                            cook_started = true
                            break
                        end
                        if attempt < MAX_COOK_ATTEMPTS then
                            Logger.Logf("[智能锅] Cook 烹饪未确认开始，进行第%d次重试", attempt)
                            Sleep(FRAMES * 10)
                        else
                            Logger.Log("[智能锅] Cook 失败: 烹饪未确认开始，重试次数已用完")
                            return Silent()
                        end
                    end
                end

                if cook_started and not quiet and #conts > 1 then
                    cont._flag_next = true
                    cont:DoTaskInTime(10 * FRAMES, function()
                        cont._flag_next = nil
                    end)
                end
            elseif not quiet then
                local before_state = CaptureContainerState(GetPotContainer(cont))
                Action.DoMouseAction(act, right)
                if not WaitForHarvestDone(cont, before_state) then
                    Logger.Log("[智能锅] Cook 失败: 收获未确认完成")
                    return Silent()
                end
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
            local before_state = CaptureContainerState(GetPotContainer(pot))
            Action.DoMouseAction(act, right)
            if not WaitForHarvestDone(pot, before_state) then
                Logger.Log("[智能锅] Cook 失败: 收获未确认完成")
                return Silent()
            end
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
    Logger.LogLazy(function()
        return string.format("[智能锅] SaveMemory: use_quantity=%s max_slots=%d ingredients=%s",
            tostring(use_quantity), max_slots, DumpIngredients(ingredients))
    end)
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
    Logger.LogLazy(function()
        return string.format("[智能锅] SaveRecipeMemory: recipe=%s use_quantity=%s ingredients=%s",
            tostring(recipe_name), tostring(use_quantity), DumpIngredients(ingredients))
    end)
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
    Logger.LogLazy(function()
        return string.format("[智能锅] QuickCook: recipe=%s use_quantity=%s memory=%s",
            tostring(recipe_name), tostring(use_quantity), DumpIngredients(memory))
    end)
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

    if Action.HasActiveItem() then
        Action.ReturnActiveItem()
    end

    if current_container then
        PanelManager.DestroyPanel(current_container)
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

    if Action.HasActiveItem() then
        Action.ReturnActiveItem()
    end

    if current_container then
        PanelManager.DestroyPanel(current_container)
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
    Logger.LogLazy(function()
        return string.format("[智能锅] Execute: use_quantity=%s max_slots=%d memory=%s",
            tostring(use_quantity), max_slots, DumpIngredients(self._memory and self._memory.ingredients))
    end)
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

    if Action.HasActiveItem() then
        Action.ReturnActiveItem()
    end

    if current_container then
        PanelManager.DestroyPanel(current_container)
    end

    Say(STRINGS.CSP.AUTO_START)
    self._task_queue:RegNowTask(
        function()
            return Cook(prefab, data, self._range_search, self._auto_cook_source, nil, nil, current_container)
        end,
        function()
            Say(STRINGS.CSP.AUTO_STOP)
        end
    )

    return true
end

return AutoCook
