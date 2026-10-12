-- 可做配方组合（弹窗「可做配方」视图）：由 recipe_panel 通过 Install 挂回方法
return function(RecipePanel)
-- 把组合计算状态同步到弹窗（CraftSection.Update 通过 popup._combo_status 读取显示提示）
function RecipePanel:_SyncComboStatusToPopup()
    if self._recipe_popup then
        self._recipe_popup._combo_status = self._combo_status
    end
end

-- 从匹配路径共享的组合映射缓存中还原目标料理的可做组合
-- 返回 { ingredients={ {prefab,count}, ... }, portions=N } 列表，未命中返回 nil
function RecipePanel:_RestoreCombosFromMap(recipe_item)
    local bag_counts = self._cached_bag_counts
    if not bag_counts or next(bag_counts) == nil then return nil end
    local pot_counts = self._cached_pot_counts or {}
    local raw_bag_counts = self._cached_bag_counts_raw or bag_counts

    -- 匹配缓存 key 用 fixed_counts（锅里占的槽数，每格算1，不含堆叠）
    -- 用真实数量(raw)查缓存，与主面板一致（放料后背包被裁剪，raw 才能命中同一组合全集）
    local fixed_counts = self._cached_fixed_counts or pot_counts
    local map_entry = self.data:GetCachedCombosMap(raw_bag_counts, fixed_counts, pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
    if not map_entry or next(map_entry.combos) == nil then
        return nil
    end

    local target = recipe_item.prefab
    local target_priority = recipe_item.recipe_def and recipe_item.recipe_def.priority or 0

    -- 每个组合只能产出最高优先级的料理；目标料理须是该组合的最高优先级之一才视为可做
    local available = {}
    for k, v in pairs(pot_counts) do available[k] = (available[k] or 0) + v end
    for k, v in pairs(raw_bag_counts) do available[k] = (available[k] or 0) + v end

    local result = {}
    for combo_key, matched in pairs(map_entry.combos) do
        -- 环境组合映射的值为 { dims={...}, matched={prefab=priority} } 嵌套结构，需取子表
        if type(matched) == "table" and matched.matched ~= nil then
            matched = matched.matched
        end
        -- 放料（fixed 非空）缩小：组合必须含全部锅里固定的料
        local ok_fixed = true
        if fixed_counts and next(fixed_counts) ~= nil then
            local cc = {}
            for prefab in combo_key:gmatch("[^,]+") do
                cc[prefab] = (cc[prefab] or 0) + 1
            end
            for p, need in pairs(fixed_counts) do
                if (cc[p] or 0) < need then ok_fixed = false break end
            end
        end
        -- 计算该组合的最高优先级
        local max_p = nil
        for _, p in pairs(matched) do
            if max_p == nil or p > max_p then max_p = p end
        end
        if ok_fixed and max_p ~= nil and matched[target] ~= nil and max_p == target_priority then
            -- 还原组合：组合串 "a,b,b" 展开为槽位列表（普通锅每个槽位一个食材，显示独立图标）
            local ingredients = {}
            for prefab in combo_key:gmatch("[^,]+") do
                table.insert(ingredients, prefab)
            end
            -- 份数 = 最紧缺食材可提供的份数
            local counts = {}
            for _, prefab in ipairs(ingredients) do
                counts[prefab] = (counts[prefab] or 0) + 1
            end
            local portions = math.huge
            for prefab, cnt in pairs(counts) do
                local have = (available[prefab] or 0)
                if cnt > 0 then
                    portions = math.min(portions, math.floor(have / cnt))
                end
            end
            portions = math.max(1, portions)
            table.insert(result, { ingredients = ingredients, portions = portions })
        end
    end

    if #result == 0 then
        return nil
    end
    table.sort(result, function(a, b) return a.portions > b.portions end)
    return result
end

function RecipePanel:GetCraftableCombinations(recipe_item)
    if not recipe_item then return nil end

    -- 没有任何材料：不可能做出料理，直接返回 nil，避免误设"计算中"
    if not self._cached_bag_counts or next(self._cached_bag_counts) == nil then
        self._combo_status = nil
        self:_SyncComboStatusToPopup()
        return nil
    end

    -- 数量匹配设备（炼丹炉等）：保留贪心构造（数量匹配无组合枚举概念，不走统一映射）
    if self._use_quantity_matching then
        local r = self.data:GetRecipeCraftableCombos(
            recipe_item,
            self._cached_bag_counts,
            self._cached_pot_counts,
            self._cooker,
            self._max_slots,
            true,
            self._cached_bag_counts_raw,
            self._cached_sorted_defs
        )
        return r
    end

    -- 不可堆叠设备：从匹配路径的组合映射缓存还原（唯一枚举来源，不为单个料理单独枚举）
    -- 用真实数量(raw)构造 key，与主面板一致（放料后背包被裁剪到更小格子数，用 raw 才能命中同一缓存）
    local fixed_counts = self._cached_fixed_counts or self._cached_pot_counts
    local key_bag = self._cached_bag_counts_raw or self._cached_bag_counts
    local map_entry = self.data:GetCachedCombosMap(key_bag, fixed_counts, self._cached_pot_counts, self._cooker_recipes, self._max_slots, false)
    -- 无分片任务在跑(_match_task 为 nil) = 枚举已结束（无论是否有组合），都不应再显示"计算中"；
    -- 组合映射命中且有数据时直接还原显示；做不出料理(空组合/无缓存)时也清空计算中状态，避免弹窗卡死。
    if not self._match_task then
        self._combo_status = nil
        self:_SyncComboStatusToPopup()
        if map_entry and next(map_entry.combos or {}) then
            return self:_RestoreCombosFromMap(recipe_item)
        end
        return nil
    end

    -- 分片任务仍在运行，且已有部分组合数据可先展示；否则显示"计算中"等待枚举完整
    if map_entry and next(map_entry.combos or {}) then
        return self:_RestoreCombosFromMap(recipe_item)
    end
    -- 仍在计算中：显示"计算中"，等枚举完整后（RefreshDisplay）再还原
    if self._combo_status ~= "calculating" then
        self._combo_status = "calculating"
        self:_SyncComboStatusToPopup()
    end
    return nil
end
end
