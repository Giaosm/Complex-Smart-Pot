-- 组合匹配：给定食材计数，回溯遍历所有组合找到能做的最高优先级料理
local cooking = require("cooking")

local ComboMatcher = {}

local _match_cache = {}

local function BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local parts = {}
    table.insert(parts, tostring(max_slots))
    table.insert(parts, use_quantity_matching and "Q" or "S")

    local function append_counts(label, counts)
        local keys = {}
        for k, v in pairs(counts or {}) do
            table.insert(keys, k .. "=" .. v)
        end
        table.sort(keys)
        table.insert(parts, label .. ":" .. table.concat(keys, ","))
    end

    append_counts("B", bag_counts)
    append_counts("F", fixed_counts)
    append_counts("P", pot_counts)

    if cooker_recipes then
        local names = {}
        for k, _ in pairs(cooker_recipes) do
            table.insert(names, k)
        end
        table.sort(names)
        table.insert(parts, "R:" .. table.concat(names, ","))
    end

    return table.concat(parts, "|")
end

local function BuildNamesTags(prefab_list, ingredient_aliases, ingredients)
    local names = {}
    local tags = {}
    for _, prefab in ipairs(prefab_list) do
        names[prefab] = (names[prefab] or 0) + 1
        local ingredient_name = ingredient_aliases[prefab] or prefab
        local data = ingredients[ingredient_name]
        if data ~= nil and data.tags ~= nil then
            for tag, val in pairs(data.tags) do
                tags[tag] = (tags[tag] or 0) + val
            end
        end
    end
    return names, tags
end

-- 快速预过滤：料理所需的食材类型必须在 bag/fixed/pot 中至少出现一种
local function PrefilterRecipe(item, bag_counts, fixed_counts, pot_counts)
    local req_types = item._required_types
    if not req_types or not next(req_types) then
        return true
    end
    for t, _ in pairs(req_types) do
        if (bag_counts[t] or 0) + (fixed_counts[t] or 0) + (pot_counts[t] or 0) > 0 then
            return true
        end
    end
    return false
end

-- 用数量向量直接检查一个料理是否可被满足（用于可堆叠设备）
local function CheckRecipeByCounts(item, names, tags, counts, ingredients)
    local reqs = item.recipe_requirements
    if not reqs then
        return false
    end

    if reqs.minnames then
        for name, count in pairs(reqs.minnames) do
            local have = names[name] or 0
            if have < count and counts and counts[name] then
                have = counts[name]
            end
            if have < count then
                return false
            end
        end
    end

    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            local total = 0
            for _, gname in ipairs(group.names) do
                local have = names[gname] or 0
                if have < group.amount and counts and counts[gname] then
                    have = counts[gname]
                end
                total = total + have
            end
            if total < group.amount then
                return false
            end
        end
    end

    if reqs.mintags then
        for tag, min_val in pairs(reqs.mintags) do
            if (tags[tag] or 0) < min_val then
                return false
            end
        end
    end

    if reqs.maxnames then
        for name, max_val in pairs(reqs.maxnames) do
            if (names[name] or 0) > max_val then
                return false
            end
        end
    end

    if reqs.analog_groups and reqs.maxnames then
        for _, group in ipairs(reqs.analog_groups) do
            local total = 0
            local group_max = nil
            for _, gname in ipairs(group.names) do
                total = total + (names[gname] or 0)
                local m = reqs.maxnames[gname]
                if m ~= nil and (group_max == nil or m > group_max) then
                    group_max = m
                end
            end
            if group_max ~= nil and total > group_max then
                return false
            end
        end
    end

    if reqs.maxtags then
        for tag, max_val in pairs(reqs.maxtags) do
            if (tags[tag] or 0) > max_val then
                return false
            end
        end
    end

    return true
end

-- 按数量向量判断（用于炼丹炉/酿酒桶等需要特定数量×N 的设备）。
-- 一个 slot 可以放多个同种食材，不需要枚举 slot 分配，
-- 而是判断能否从 bag+pot 中选出一份满足 min 需求、不超过 max 限制的输入。
local function MatchByQuantity(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
    local pot_counts_combined = {}
    for name, count in pairs(fixed_counts or {}) do
        pot_counts_combined[name] = (pot_counts_combined[name] or 0) + count
    end
    for name, count in pairs(pot_counts or {}) do
        pot_counts_combined[name] = (pot_counts_combined[name] or 0) + count
    end

    local result = {}
    for _, item in ipairs(all_items) do
        local cooker_ok = cooker_recipes == nil or cooker_recipes[item.prefab]
        if cooker_ok and PrefilterRecipe(item, bag_counts, fixed_counts, pot_counts) then
            local reqs = item.recipe_requirements
            if not reqs then
                -- 没有反向推导出的需求，保守跳过（避免误报）
            else
                local ok = true
                local min_names = {}
                for name, count in pairs(pot_counts_combined) do
                    if count > 0 then
                        min_names[name] = count
                    end
                end

                -- minnames：锅里的不够就从 bag 补
                if ok and reqs.minnames then
                    for name, min_count in pairs(reqs.minnames) do
                        local pot_have = pot_counts_combined[name] or 0
                        if pot_have < min_count then
                            local need = min_count - pot_have
                            if (bag_counts[name] or 0) < need then
                                ok = false
                                break
                            end
                        end
                        min_names[name] = math.max(min_names[name] or 0, min_count)
                    end
                end

                -- analog_groups：锅里的不够就从 bag 补
                if ok and reqs.analog_groups then
                    for _, group in ipairs(reqs.analog_groups) do
                        local pot_total = 0
                        for _, gname in ipairs(group.names) do
                            pot_total = pot_total + (pot_counts_combined[gname] or 0)
                        end
                        if pot_total < group.amount then
                            local remaining = group.amount - pot_total
                            local bag_total = 0
                            for _, gname in ipairs(group.names) do
                                bag_total = bag_total + (bag_counts[gname] or 0)
                            end
                            if bag_total < remaining then
                                ok = false
                                break
                            end
                            for _, gname in ipairs(group.names) do
                                local use = math.min(bag_counts[gname] or 0, remaining)
                                if use > 0 then
                                    min_names[gname] = (min_names[gname] or 0) + use
                                    remaining = remaining - use
                                    if remaining <= 0 then break end
                                end
                            end
                        end
                    end
                end

                -- mintags：锅里的不够就从 bag 补一种能提供该 tag 的食材
                if ok and reqs.mintags then
                    for tag, min_val in pairs(reqs.mintags) do
                        local have = 0
                        for name, count in pairs(min_names) do
                            local ing_name = ingredient_aliases[name] or name
                            local data = ingredients[ing_name]
                            if data and data.tags and data.tags[tag] then
                                have = have + count * data.tags[tag]
                            end
                        end
                        if have < min_val then
                            local need = min_val - have
                            local found = false
                            for name, count in pairs(bag_counts) do
                                local ing_name = ingredient_aliases[name] or name
                                local data = ingredients[ing_name]
                                if data and data.tags and data.tags[tag] then
                                    local val = data.tags[tag]
                                    local use = math.min(count, math.ceil(need / val))
                                    if use > 0 then
                                        min_names[name] = (min_names[name] or 0) + use
                                        need = need - use * val
                                        if need <= 0 then
                                            found = true
                                            break
                                        end
                                    end
                                end
                            end
                            if not found then
                                ok = false
                                break
                            end
                        end
                    end
                end

                -- slot 限制：实际用到的不同食材种类数
                if ok then
                    local distinct = 0
                    for _, count in pairs(min_names) do
                        if count > 0 then
                            distinct = distinct + 1
                        end
                    end
                    if distinct > max_slots then
                        ok = false
                    end
                end

                -- 最终用最小用量检查 maxnames/maxtags 限制
                if ok then
                    local min_tags = {}
                    for name, count in pairs(min_names) do
                        local ing_name = ingredient_aliases[name] or name
                        local data = ingredients[ing_name]
                        if data and data.tags then
                            for tag, val in pairs(data.tags) do
                                min_tags[tag] = (min_tags[tag] or 0) + val * count
                            end
                        end
                    end
                    ok = CheckRecipeByCounts(item, min_names, min_tags, nil, ingredients)
                end

                if ok then
                    result[item.prefab] = true
                end
            end
        end
    end

    return next(result) and result or nil
end

-- 不可堆叠设备：slot 级回溯，但只枚举相关食材类型
local function MatchNonStacked(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
    local total_fixed = 0
    for _, c in pairs(fixed_counts) do
        total_fixed = total_fixed + c
    end
    local free_slots = max_slots - total_fixed
    if free_slots <= 0 then
        return nil
    end

    -- 预过滤：先淘汰不可能料理
    local candidate_items = {}
    for _, item in ipairs(all_items) do
        local cooker_ok = cooker_recipes == nil or cooker_recipes[item.prefab]
        if cooker_ok and PrefilterRecipe(item, bag_counts, fixed_counts, pot_counts) then
            table.insert(candidate_items, item)
        end
    end

    if #candidate_items == 0 then
        return nil
    end

    local types = {}
    local seen = {}
    local min_counts = {}
    local max_counts = {}

    local function add_type(p)
        if seen[p] then return end
        seen[p] = true
        table.insert(types, p)
        min_counts[p] = fixed_counts[p] or 0
        max_counts[p] = math.min((bag_counts[p] or 0) + (fixed_counts[p] or 0), max_slots)
    end

    for p, _ in pairs(fixed_counts) do
        add_type(p)
    end
    for p, _ in pairs(bag_counts) do
        add_type(p)
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
            local names, tags = BuildNamesTags(flat, ingredient_aliases, ingredients)
            local matched = {}
            local max_priority = nil
            for _, item in ipairs(candidate_items) do
                local matched_ok = false
                if item.recipe_def.test ~= nil then
                    local ok, ret = pcall(item.recipe_def.test, cooker, names, tags)
                    if ok and ret then
                        matched_ok = true
                    end
                elseif item.recipe_requirements and item.recipe_requirements.minnames then
                    matched_ok = CheckRecipeByCounts(item, names, tags, nil, ingredients)
                end
                if matched_ok then
                    local p = item.recipe_def.priority or 0
                    matched[item.prefab] = p
                    if max_priority == nil or p > max_priority then
                        max_priority = p
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

function ComboMatcher.Match(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, use_quantity_matching)
    if not bag_counts or next(bag_counts) == nil then
        return nil
    end

    fixed_counts = fixed_counts or {}
    pot_counts = pot_counts or {}
    max_slots = max_slots or 4
    ingredients = ingredients or cooking.ingredients
    ingredient_aliases = ingredient_aliases or {}

    local cache_key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local cached = _match_cache[cache_key]
    if cached then
        return next(cached) and cached or nil
    end

    local result
    if use_quantity_matching then
        result = MatchByQuantity(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
    else
        result = MatchNonStacked(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
    end

    _match_cache[cache_key] = result or {}
    return result
end

return ComboMatcher
