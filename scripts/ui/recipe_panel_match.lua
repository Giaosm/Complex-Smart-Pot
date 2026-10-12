-- 面板匹配与「可做」检测（含分片任务）：由 recipe_panel 通过 Install 挂回方法
local Scanner = require("inventory/inventory_scanner")
local Logger = require("debug/logger")
local FollowText = require("widgets/followtext")

return function(RecipePanel)
-- 匹配收尾：槽位容量过滤 + 清脏标记 + 调试统计（同步路径与分片路径共用）
local function FinishMatchLog(self, bag_counts)
    self:_FilterByPossibleRecipes()
    self._backpack_dirty = false
    if Logger.IsEnabled() then
        local elapsed = self._t_match_start and (os.clock() - self._t_match_start) * 1000 or 0
        Logger.Logf("[智能锅] 扫描+匹配总耗时 %.1fms", elapsed)
        Logger.LogWorldContext()
        Logger.LogScanResult(self._max_slots, self._use_quantity_matching, self._backpack_check_mode, bag_counts)
        Logger.LogMatchResult(self._backpack_recipes)
        self._t_match_start = nil
    end
    if self.data.LogCacheStats then self.data:LogCacheStats() end
end

function RecipePanel:_RefreshBackpackRecipes()
    if self._backpack_check_mode == "off" or not self._player_inst or not self._cooker then
        self._backpack_recipes = nil
        return
    end

    local inv = self._player_inst.replica and self._player_inst.replica.inventory
    if not inv then
        return
    end

    local pot_counts = self._cached_pot_counts or {}
    local occupied_slots = 0
    for _ in pairs(self._slot_data) do
        occupied_slots = occupied_slots + 1
    end

    if occupied_slots >= self._max_slots then
        self._backpack_recipes = self.data:GetHighlightedRecipes(self._matching_recipes, self._cooker_recipes)
        self._cached_bag_counts = {}
        self._backpack_dirty = false
        return
    end

    local max_per_type
    if self._use_quantity_matching then
        -- 可堆叠设备：单格可放多份同种食材，从配方算出最大需求量
        local max_needed = 0
        for _, recipe_def in pairs(self._cooker_recipes or {}) do
            if recipe_def.recipe then
                for _, count in pairs(recipe_def.recipe) do
                    max_needed = math.max(max_needed, count)
                end
            end
            if recipe_def.alternative_recipe then
                for _, alt_group in pairs(recipe_def.alternative_recipe) do
                    for _, count in pairs(alt_group) do
                        max_needed = math.max(max_needed, count)
                    end
                end
            end
        end
        max_per_type = math.max(max_needed, self._max_slots - occupied_slots)
    else
        max_per_type = self._max_slots - occupied_slots
    end

    local fixed_counts = {}
    for _, prefab in pairs(self._slot_data) do
        fixed_counts[prefab] = (fixed_counts[prefab] or 0) + 1
    end
    self._cached_fixed_counts = fixed_counts  -- 缓存按槽的固定食材数，供组合映射查询用

    -- 库存/容器扫描已统一收口到 inventory_scanner（语义见重构待办第六节行为矩阵）
    if Logger.IsEnabled() then self._t_match_start = os.clock() end
    local bag_counts, raw_counts = Scanner.CountIngredientsForMode(
        self._player_inst, self._backpack_check_mode, max_per_type,
        self._cached_device_ingredients, self._container
    )

    if next(bag_counts) == nil then
	self._backpack_recipes = nil
	self._cached_bag_counts = {}
    else
	local cached = self._cached_bag_counts
	local same = cached and true or false
	if same then
	    for k, v in pairs(bag_counts) do
	        if (cached[k] or 0) ~= math.min(v, max_per_type) then same = false; break end
	    end
	end
	if same then
	    for k, v in pairs(cached) do
	        if v ~= math.min(bag_counts[k] or 0, max_per_type) then same = false; break end
	    end
	end
	-- 锅里材料变化（放入/取出）也必须重算：背包相同但锅状态不同，可做结果可能不同
	if same then
	    local last = self._last_pot_counts
	    local cur = pot_counts
	    if (last == nil) ~= (next(cur) == nil) then
	        same = false
	    else
	        for k, v in pairs(cur) do
	            if (last[k] or 0) ~= v then same = false; break end
	        end
	        if same then
	            for k, v in pairs(last) do
	                if (cur[k] or 0) ~= v then same = false; break end
	            end
	        end
	    end
	end
	-- 环境变化（季节/月相）影响环境料理可做性：即使背包/锅没变，也需重算（否则秋季料理在春季仍显示可做）
	if same then
	    local cur_env = Logger.GetEnvFingerprintForDim("season+moon")
	    if self._cached_env_fingerprint ~= cur_env then
	        same = false
	    end
	end
	if same then
	    self._backpack_dirty = false
	    if not self._active_popup_data then
	        self._cached_bag_counts_raw = raw_counts
	        return
	    end
	else
	    self._cached_bag_counts = {}
	    for k, v in pairs(bag_counts) do
	        self._cached_bag_counts[k] = math.min(v, max_per_type)
	    end
	    self._last_pot_counts = pot_counts
	    self._cached_env_fingerprint = Logger.GetEnvFingerprintForDim("season+moon")
	end
	self._cached_bag_counts_raw = raw_counts

	if not same then
	    if self.data:ShouldUseMatchTask(bag_counts, fixed_counts, self._max_slots, self._use_quantity_matching) then
	        -- 优先查组合映射缓存：命中即可立即展示（部分或完整），不完整则后台续算
	        -- 用真实数量(raw)构造 key：放料后背包被裁剪到更小格子数，须用未裁剪总数才能命中空锅缓存
	        local key_bag = self._cached_bag_counts_raw or bag_counts
	        local map_entry = self.data:GetCachedCombosMap(key_bag, fixed_counts, pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
	        if map_entry and next(map_entry.combos) then
	            -- 放料（fixed 非空）时：从组合全集里缩小出"含全部锅里固定料"的组合，再聚合可做料理
	            local set
	            if fixed_counts and next(fixed_counts) ~= nil then
	                local shrunk = {}
	                for combo_key, matched in pairs(map_entry.combos) do
	                    local counts = {}
	                    for prefab in combo_key:gmatch("[^,]+") do
	                        counts[prefab] = (counts[prefab] or 0) + 1
	                    end
	                    local ok = true
	                    for p, need in pairs(fixed_counts) do
	                        if (counts[p] or 0) < need then ok = false break end
	                    end
	                    if ok then shrunk[combo_key] = matched end
	                end
	                set = self.data:GetRecipesFromCombosMap({ combos = shrunk })
	            else
	                set = self.data:GetRecipesFromCombosMap(map_entry)
	            end
	            self._backpack_recipes = {}
	            if set then
	                for k, _ in pairs(set) do
	                    self._backpack_recipes[k] = true
	                end
	            end
            if map_entry.complete then
                -- 完整缓存，直接使用；取消可能仍在运行的分片任务，避免"正在计算"提示残留
                Logger.Logf("[智能锅][缓存] 命中完整映射缓存，直接使用")
                self:_CancelBackpackMatchTask()
                self._match_pending = false
            else
                -- 部分缓存：先展示已算部分，同时从头重新枚举补齐完整（不接断点）
                Logger.Logf("[智能锅][缓存] 命中未完成映射缓存，先展示已算部分并重新枚举补齐")
                self:_StartBackpackMatchTask(key_bag, fixed_counts, pot_counts)
                self._match_pending = true
            end
	        else
            local cached = self.data:GetCachedMatch(key_bag, fixed_counts, pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
            if cached then
                self._backpack_recipes = {}  -- 拷贝，避免槽位检查污染缓存表
                for k, _ in pairs(cached) do
                    self._backpack_recipes[k] = true
                end
                -- 命中完整缓存，取消可能仍在运行的分片任务，避免"正在计算"提示残留
                self:_CancelBackpackMatchTask()
                self._match_pending = false
            else
                self:_StartBackpackMatchTask(key_bag, fixed_counts, pot_counts)
                self._match_pending = true
            end
	        end
	    else
	        self._backpack_recipes = self.data:GetMatchingRecipesFromCounts(self._cooker, bag_counts, fixed_counts, self._cooker_recipes, self._max_slots, self._brewing_ingredients, pot_counts, self._use_quantity_matching)
	    end
	end

        if not self._match_pending then
            FinishMatchLog(self, bag_counts)
        end
    end
    -- 分片模式保持 dirty 由 OnUpdate 驱动，完成后再置 false
    if not self._match_pending then
        self._backpack_dirty = false
    end
end

-- ============ 方案A：分片匹配任务驱动 ============

-- 比较两个哈希表是否含完全相同的键集合
local function SameKeySet(a, b)
    if a == b then return true end
    if (a == nil) ~= (b == nil) then return false end
    for k in pairs(a) do
        if not b[k] then return false end
    end
    for k in pairs(b) do
        if not a[k] then return false end
    end
    return true
end

-- 懒创建头顶计算提示（StopMonitor 销毁后下次显示时自动重建）
function RecipePanel:_CreateCalcHint()
    if self._calc_hint then return end
    if ThePlayer and ThePlayer.HUD then
        self._calc_hint = FollowText(UIFONT, 28, STRINGS.CSP.CALCULATING)
        self._calc_hint:SetHUD(ThePlayer.HUD.inst)
        self._calc_hint:SetTarget(ThePlayer)
        self._calc_hint:SetOffset(Vector3(0, -350, 0))
        self._calc_hint:SetScreenOffset(0, 0)
        if self._calc_hint.text then
            self._calc_hint.text:SetHAlign(ANCHOR_MIDDLE)
        end
        ThePlayer.HUD:AddChild(self._calc_hint)
        self._calc_hint:Hide()
    end
end

-- 计算中在玩家头顶显示提示，完成/无任务时隐藏
function RecipePanel:_UpdateCalcHint()
    if self._match_task then
        self:_CreateCalcHint()
        if self._calc_hint then
            self._calc_hint:Show()
        end
    elseif self._calc_hint then
        self._calc_hint:Hide()
    end
end

-- 可做分类的槽位容量检查：就地过滤 self._backpack_recipes，返回是否还有剩余
function RecipePanel:_FilterByPossibleRecipes()
    if self._backpack_recipes and self._possible_recipes then
        for prefab, _ in pairs(self._backpack_recipes) do
            if not self._possible_recipes[prefab] then
                self._backpack_recipes[prefab] = nil
            end
        end
        if next(self._backpack_recipes) == nil then
            self._backpack_recipes = nil
        end
    end
    return self._backpack_recipes ~= nil
end

function RecipePanel:_StartBackpackMatchTask(bag_counts, fixed_counts, pot_counts)
    self:_CancelBackpackMatchTask()
    self._last_backpack_partial = nil
    pot_counts = pot_counts or self._cached_pot_counts or {}
    local task = self.data:CreateMatchTask(
        self._cooker, bag_counts, fixed_counts, self._cooker_recipes,
        self._max_slots, self._brewing_ingredients, pot_counts,
        self._use_quantity_matching
    )
    self._match_task = task
    self._match_task_cache_info = { bag_counts, fixed_counts, pot_counts }
    self._match_pending = true
    self._backpack_dirty = false
    self:_ScheduleMatchStep()
end

-- 每帧 DoTaskInTime 驱动一次任务推进，_match_step_scheduled 防同帧叠加
function RecipePanel:_ScheduleMatchStep()
    if not self._match_task then return end
    if self._match_step_scheduled then return end
    self._match_step_scheduled = true
    self.inst:DoTaskInTime(0, function()
        self._match_step_scheduled = false
        if not self._match_task then return end
        self:_StepBackpackMatchTask()
        if self._match_task then
            self:_ScheduleMatchStep()
        end
    end)
end

function RecipePanel:_CancelBackpackMatchTask()
    if self._match_task then
        -- 面板被打断/库存变化前，把已算出的组合映射（partial）写入缓存（标记未完成）
        -- 下次开锅命中即可先展示已算部分，再后台重新枚举补齐完整
        if self._match_task_cache_info then
            local info = self._match_task_cache_info
            local partial_combos = self._match_task:GetPartialCombos()
            if partial_combos and next(partial_combos) then
                self.data:CacheCombosMap(partial_combos, info[1], info[2], info[3], self._cooker_recipes, self._max_slots, self._use_quantity_matching, false)
            end
            local partial_env_combos = self._match_task:GetPartialEnvCombos()
            if partial_env_combos and next(partial_env_combos) then
                self.data:CacheEnvCombosMap(partial_env_combos, info[1], info[2], info[3], self._cooker_recipes, self._max_slots, self._use_quantity_matching, false)
            end
        end
        self._match_task:Cancel()
        self._match_task = nil
    end
    self._match_step_scheduled = false
    self._match_task_cache_info = nil
    -- 任务取消：清空"计算中"状态，避免残留
    self._combo_status = nil
    self:_SyncComboStatusToPopup()
end

-- 单帧推进（循环时间片直到用满帧预算或完成）；渐进显示：把新算出的部分结果应用到列表
function RecipePanel:_StepBackpackMatchTask()
    local task = self._match_task
    if not task then return end
    if self._backpack_dirty then
        -- 库存已变化，结果作废：取消旧任务后按新食材重新匹配（命中缓存或启动新分片任务）
        self:_CancelBackpackMatchTask()
        self._match_pending = false
        self:_RefreshBackpackRecipes()
        return
    end
    local t0 = os.clock() * 1000
    local frame_budget = 12
    local partial_updated = false
    while self._match_task do
        local done = task:Step(12)
        -- 渐进显示：合并普通+环境料理结果。必须拷贝到 new_bp，不能原地改 partial
        -- （partial 与 task:GetResult() 共享表，原地改会污染普通 result 缓存）
        local partial = task:GetPartialResult()
        local partial_env = task:GetPartialResultEnv()
        if partial ~= nil or partial_env ~= nil then
            local new_bp = {}
            if partial ~= nil then
                for k, _ in pairs(partial) do
                    new_bp[k] = true
                end
            end
            if partial_env ~= nil then
                for k, _ in pairs(partial_env) do
                    new_bp[k] = true
                end
            end
            -- 仅当有新增料理才刷新，避免无变化刷屏
            if not SameKeySet(self._last_backpack_partial, new_bp) then
                self._backpack_recipes = new_bp
                self._last_backpack_partial = {}
                for k, _ in pairs(new_bp) do
                    self._last_backpack_partial[k] = true
                end
                partial_updated = true
            end
        end
        if done then
            self:_ApplyBackpackMatchResult(task:GetResult(), task:GetPartialCombos(), task:GetPartialResultEnv(), task:GetPartialEnvCombos())
            return
        end
        if os.clock() * 1000 - t0 >= frame_budget then
            break
        end
    end
    if partial_updated and self._match_task then
        self:_ApplyBackpackPartialDisplay()
    end
end

-- 渐进显示刷新：保持滚动位置，不标记完成
function RecipePanel:_ApplyBackpackPartialDisplay()
    self:_FilterByPossibleRecipes()
    self._preserve_scroll = true
    if self.RefreshDisplay then self:RefreshDisplay() end
    self._preserve_scroll = false
end

-- 应用分片匹配结果（后处理 + 写缓存 + 刷新）
function RecipePanel:_ApplyBackpackMatchResult(result, combos_map, result_env, env_combos_map)
    self._match_task = nil
    self._match_step_scheduled = false
    self._last_backpack_partial = nil
    -- 枚举完成：清空"计算中"状态，避免做不出来时弹窗一直显示"计算中"
    self._combo_status = nil
    self:_SyncComboStatusToPopup()
    if self._match_task_cache_info then
        local info = self._match_task_cache_info
        -- 放料（锅里锁料，fixed 非空）缩小集 = 不全但正确的脏缓存，标记 complete=false：
        -- 下次开锅命中时知道不完整，复用已有部分并补齐，避免污染空锅全集、也不会白算。
        local is_fixed = info[2] ~= nil and next(info[2]) ~= nil
        -- 放料缩小集不写 _match_cache（可做料理集合缓存），避免污染空锅全集；
        -- 只写 _combo_map_cache（组合映射）并标 complete=false，供下次开锅命中补齐。
        -- 显示仍用本次算出的 result（内存），不受 CacheMatch 写缓存参数影响。
        self.data:CacheMatch(is_fixed and nil or result, info[1], info[2], info[3], self._cooker_recipes, self._max_slots, self._use_quantity_matching, combos_map, not is_fixed, nil, is_fixed and nil or result_env, env_combos_map)
        self._match_task_cache_info = nil
    end
    self._backpack_recipes = {}
    -- env_only 补算场景：result（普通）为 nil，需从缓存合并普通料理部分 + 新算的环境料理部分
    if result ~= nil then
        for k, _ in pairs(result) do
            self._backpack_recipes[k] = true
        end
    else
        -- 用真实数量(raw)查缓存，与主面板 key 一致，避免补算时普通料理缓存 miss
        local cached = self.data:GetCachedMatch(self._cached_bag_counts_raw or self._cached_bag_counts, self._cached_fixed_counts or self._cached_pot_counts, self._cached_pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
        if cached then
            for k, _ in pairs(cached) do
                self._backpack_recipes[k] = true
            end
        end
    end
    if result_env ~= nil then
        for k, _ in pairs(result_env) do
            self._backpack_recipes[k] = true
        end
    end
    self._match_pending = false
    self._cached_env_fingerprint = Logger.GetEnvFingerprintForDim("season+moon")

    FinishMatchLog(self, self._cached_bag_counts or {})
    if self.RefreshDisplay then self:RefreshDisplay() end
end

-- 库存变化时取消分片任务（结果作废）并按新食材重新匹配，避免"计算中放料后不再计算"卡住
function RecipePanel:OnUpdate(dt)
    if self._match_task and self._backpack_dirty then
        self:_CancelBackpackMatchTask()
        self._match_step_scheduled = false
        self._match_pending = false
        self:_RefreshBackpackRecipes()
    end
end
end
