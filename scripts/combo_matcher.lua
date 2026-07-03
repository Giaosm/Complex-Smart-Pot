-- 组合匹配：给定食材计数，回溯遍历所有组合找到能做的最高优先级料理
local cooking = require("cooking")

local INGREDIENT_ALIASES = {
    cookedsmallmeat      = "smallmeat_cooked",
    cookedmonstermeat    = "monstermeat_cooked",
    cookedmeat           = "meat_cooked",
}

local function _BuildNamesTags(prefab_list, ingredients)
    ingredients = ingredients or cooking.ingredients
    local names = {}
    local tags = {}
    for _, prefab in ipairs(prefab_list) do
        names[prefab] = (names[prefab] or 0) + 1
        local ingredient_name = INGREDIENT_ALIASES[prefab] or prefab
        local data = ingredients[ingredient_name]
        if data ~= nil and data.tags ~= nil then
            for tag, val in pairs(data.tags) do
                tags[tag] = (tags[tag] or 0) + val
            end
        end
    end
    return names, tags
end

local ComboMatcher = {}

function ComboMatcher.Match(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients)
    if not bag_counts or next(bag_counts) == nil then
        return nil
    end
    fixed_counts = fixed_counts or {}
    max_slots = max_slots or 4
    ingredients = ingredients or cooking.ingredients

    local total_fixed = 0
    for _, c in pairs(fixed_counts) do
        total_fixed = total_fixed + c
    end
    local free_slots = max_slots - total_fixed
    if free_slots <= 0 then
        return nil
    end

    local types = {}
    local seen = {}
    local min_counts = {}
    local max_counts = {}

    for p, _ in pairs(fixed_counts) do
        if not seen[p] then
            seen[p] = true
            table.insert(types, p)
            min_counts[p] = fixed_counts[p] or 0
            max_counts[p] = math.min((bag_counts[p] or 0) + (fixed_counts[p] or 0), max_slots)
        end
    end
    for p, _ in pairs(bag_counts) do
        if not seen[p] then
            seen[p] = true
            table.insert(types, p)
            min_counts[p] = fixed_counts[p] or 0
            max_counts[p] = math.min((bag_counts[p] or 0) + (fixed_counts[p] or 0), max_slots)
        end
    end

    local total_avail = 0
    for _, p in ipairs(types) do
        total_avail = total_avail + max_counts[p]
    end
    if total_avail < max_slots then
        return nil
    end

    local n = #types
    local result = {}
    local sel_prefabs = {}
    local sel_counts = {}

    -- 回溯遍历每种食材的取量组合，剩余槽位为 0 时用 test 函数验证能否匹配
    local function try_combine(idx, depth, remaining)
        if depth > 0 and remaining == 0 then
            local flat = {}
            for i = 1, depth do
                local p = sel_prefabs[i]
                for _ = 1, sel_counts[i] do
                    table.insert(flat, p)
                end
            end
            for i = idx, n do
                local p = types[i]
                local fixed = fixed_counts[p]
                if fixed and fixed > 0 then
                    for _ = 1, fixed do
                        table.insert(flat, p)
                    end
                end
            end
            local names, tags = _BuildNamesTags(flat, ingredients)
            local matched = {}
            local max_priority = nil
            for _, item in ipairs(all_items) do
                local cooker_ok = (cooker_recipes == nil or cooker_recipes[item.prefab])
                if cooker_ok then
                    local matched_ok = false
                    if item.recipe_def.test ~= nil then
                        local ok, ret = pcall(item.recipe_def.test, cooker, names, tags)
                        if ok and ret then
                            matched_ok = true
                        end
                    elseif item.recipe_requirements and item.recipe_requirements.minnames then
                        matched_ok = true
                        for name, count in pairs(item.recipe_requirements.minnames) do
                            if (names[name] or 0) < count then
                                matched_ok = false
                                break
                            end
                        end
                    end
                    if matched_ok then
                        local p = item.recipe_def.priority or 0
                        matched[item.prefab] = p
                        if max_priority == nil or p > max_priority then
                            max_priority = p
                        end
                    end
                end
            end
            if max_priority ~= nil then
                for prefab, p in pairs(matched) do
                    if p == max_priority then
                        result[prefab] = true
                    end
                end
            end
            return
        end
        if idx > n or remaining == 0 then
            return
        end

        local p = types[idx]
        local min_take = min_counts[p]
        local max_take = math.min(max_counts[p], remaining + min_take)

        for take = max_take, min_take, -1 do
            if take > 0 then
                sel_prefabs[depth + 1] = p
                sel_counts[depth + 1] = take
                try_combine(idx + 1, depth + 1, remaining - (take - min_take))
            else
                try_combine(idx + 1, depth, remaining)
            end
        end
    end

    try_combine(1, 0, free_slots)
    return next(result) and result or nil
end

return ComboMatcher