-- 料理匹配：根据当前食材判断可做/精确匹配的料理，管理匹配缓存
local cooking = require("cooking")
local INGREDIENT_ALIASES = require("data/ingredient_aliases")
local ComboMatcher = require("data/combo_matcher")
local Config = require("config/config_manager")

local CACHE_MAX = Config.GetCacheMax()
local _possible_cache = {}
local _cache_keys = {}  -- LRU 顺序，最新在末尾

local function CacheGet(key)
    local cached = _possible_cache[key]
    if cached then
        return next(cached) and cached or nil
    end
    return nil
end

local function CacheSet(key, value)
    if _possible_cache[key] == nil then
        table.insert(_cache_keys, key)
        if #_cache_keys > CACHE_MAX then
            local old = table.remove(_cache_keys, 1)
            _possible_cache[old] = nil
        end
    end
    _possible_cache[key] = value
end

local function BuildNamesTags(prefab_list, ingredients)
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

-- 核心筛选：用排除法检查每个配方，食材必须满足 minnames/mintags，且不超 maxnames/maxtags
local function _CheckMinRequirements(reqs, resolved, tags, remaining_slots, max_tag_values, ingredients, max_slots)
    max_slots = max_slots or 4
    if remaining_slots >= max_slots then
        return true
    end

    local group_covered = {}
    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            for _, gname in ipairs(group.names) do
                group_covered[gname] = true
            end
        end
    end

    local name_deficit = 0

    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            local group_total = 0
            for _, gname in ipairs(group.names) do
                group_total = group_total + (resolved[gname] or 0)
            end
            if group_total < group.amount then
                name_deficit = name_deficit + (group.amount - group_total)
            end
        end
    end

    for name, min_amt in pairs(reqs.minnames or {}) do
        if not group_covered[name] then
            local current = resolved[name] or 0
            if current < min_amt then
                name_deficit = name_deficit + (min_amt - current)
            end
        end
    end

    if name_deficit > remaining_slots then
        return false
    end

    if reqs.mintags and max_tag_values then
        local remaining_tag_deficit = {}
        for tag, min_val in pairs(reqs.mintags) do
            local current = tags[tag] or 0
            if min_val == 0 and current == 0 then
                remaining_tag_deficit[tag] = max_tag_values[tag] or 1
            elseif current < min_val then
                remaining_tag_deficit[tag] = min_val - current
            end
        end

        if name_deficit > 0 and next(remaining_tag_deficit) then
            local name_ingredients = {}

            for name, min_amt in pairs(reqs.minnames or {}) do
                if not group_covered[name] then
                    local current = resolved[name] or 0
                    for _ = 1, math.max(0, min_amt - current) do
                        table.insert(name_ingredients, name)
                    end
                end
            end

            if reqs.analog_groups then
                for _, group in ipairs(reqs.analog_groups) do
                    local group_total = 0
                    for _, gname in ipairs(group.names) do
                        group_total = group_total + (resolved[gname] or 0)
                    end
                    local deficit = group.amount - group_total
                    for _ = 1, math.max(0, deficit) do
                        local best_name = nil
                        local best_score = -1
                        for _, gname in ipairs(group.names) do
                            local ing = ingredients[gname]
                            if ing and ing.tags then
                                local score = 0
                                for tag, def in pairs(remaining_tag_deficit) do
                                    if def > 0 and ing.tags[tag] then
                                        score = score + ing.tags[tag]
                                    end
                                end
                                if score > best_score then
                                    best_score = score
                                    best_name = gname
                                end
                            end
                        end
                        if best_name then
                            table.insert(name_ingredients, best_name)
                        end
                    end
                end
            end

            for _, name in ipairs(name_ingredients) do
                local ing = ingredients[name]
                if ing and ing.tags then
                    for tag, val in pairs(ing.tags) do
                        if remaining_tag_deficit[tag] then
                            remaining_tag_deficit[tag] = math.max(0, remaining_tag_deficit[tag] - val)
                        end
                    end
                end
            end
        end

        local tag_counts = {}
        local deficit_tag_count = 0
        for tag, deficit in pairs(remaining_tag_deficit) do
            if deficit > 0 then
                tag_counts[tag] = math.ceil(deficit / (max_tag_values[tag] or 1))
                deficit_tag_count = deficit_tag_count + 1
            end
        end

        local tag_bottleneck = 0
        if deficit_tag_count <= 1 then
            for _, needed in pairs(tag_counts) do tag_bottleneck = needed end
        else
            local can_cover_all = false
            for _, ing_data in pairs(ingredients) do
                if ing_data.tags then
                    local covers_all = true
                    for tag, _ in pairs(tag_counts) do
                        if not ing_data.tags[tag] then
                            covers_all = false
                            break
                        end
                    end
                    if covers_all then
                        can_cover_all = true
                        break
                    end
                end
            end
            if can_cover_all then
                for _, needed in pairs(tag_counts) do
                    if needed > tag_bottleneck then tag_bottleneck = needed end
                end
            else
                for _, needed in pairs(tag_counts) do
                    tag_bottleneck = tag_bottleneck + needed
                end
            end
        end

        if name_deficit + tag_bottleneck > remaining_slots then
            return false
        end
    end

    return true
end

local Matcher = {
    BuildNamesTags = BuildNamesTags,
}

function Matcher.ClearCache()
    _possible_cache = {}
    _cache_keys = {}
end

function Matcher.GetPossibleRecipes(db, prefab_list, ingredients, max_slots, max_tag_values, counts, use_quantity_matching)
    if prefab_list == nil or #prefab_list == 0 then
        return nil
    end

    -- 缓存键：prefab 列表必须先排序——调用方用 pairs 遍历槽位构建列表，顺序不保证，
    -- 不排序会导致相同食材集产生不同 key，缓存命中率不稳且缓存表无界增长
    local sorted_prefabs = {}
    for _, p in ipairs(prefab_list) do table.insert(sorted_prefabs, p) end
    table.sort(sorted_prefabs)
    local cache_key = table.concat(sorted_prefabs, ",") .. "|" .. (max_slots or 4) .. "|" .. (use_quantity_matching and "1" or "0")
    if counts then
        local ck = {}
        for k, v in pairs(counts) do table.insert(ck, k .. "=" .. v) end
        table.sort(ck)
        cache_key = cache_key .. "|" .. table.concat(ck, ",")
    end
    local cached = CacheGet(cache_key)
    if cached then
        return cached
    end

    ingredients = ingredients or cooking.ingredients
    max_slots = max_slots or 4
    max_tag_values = max_tag_values or db._max_tag_values
    local remaining_slots
    if use_quantity_matching then
        local distinct = 0
        for _, c in pairs(counts or {}) do
            if c > 0 then
                distinct = distinct + 1
            end
        end
        remaining_slots = max_slots - distinct
    else
        remaining_slots = max_slots - #prefab_list
    end
    local names, tags = BuildNamesTags(prefab_list, ingredients)
    if counts then
        for name, count in pairs(counts) do
            names[name] = count
        end
        tags = {}
        for name, count in pairs(names) do
            local ing_name = INGREDIENT_ALIASES[name] or name
            local data = ingredients[ing_name]
            if data and data.tags then
                for tag, val in pairs(data.tags) do
                    tags[tag] = (tags[tag] or 0) + val * count
                end
            end
        end
    end

    local resolved = {}
    for raw, count in pairs(names) do
        resolved[raw] = count
        local aliased = INGREDIENT_ALIASES[raw]
        if aliased then
            resolved[aliased] = (resolved[aliased] or 0) + count
        end
    end

    local possible = {}
    for _, item in ipairs(db.all) do
        local reqs = item.recipe_requirements
        if reqs then
            local ok = true
            local group_members = nil
            if reqs.analog_groups then
                group_members = {}
                for _, group in ipairs(reqs.analog_groups) do
                    for _, gname in ipairs(group.names) do
                        group_members[gname] = true
                    end
                end
            end
            for name, count in pairs(resolved) do
                if not group_members or not group_members[name] then
                    local maxval = reqs.maxnames and reqs.maxnames[name]
                    if maxval ~= nil and count > maxval then
                        ok = false
                        break
                    end
                end
            end
            if ok and reqs.analog_groups then
                for _, group in ipairs(reqs.analog_groups) do
                    local group_total = 0
                    for _, gname in ipairs(group.names) do
                        group_total = group_total + (resolved[gname] or 0)
                    end
                    local group_max = nil
                    for _, gname in ipairs(group.names) do
                        local m = reqs.maxnames and reqs.maxnames[gname]
                        if m ~= nil and (group_max == nil or m > group_max) then
                            group_max = m
                        end
                    end
                    if group_max ~= nil and group_total > group_max then
                        ok = false
                        break
                    end
                end
            end
            if ok then
                for tag, count in pairs(tags) do
                    local maxval = reqs.maxtags and reqs.maxtags[tag]
                    if maxval ~= nil and count > maxval then
                        ok = false
                        break
                    end
                end
            end
            if ok then
                -- 检查食材是否满足配方的最低需求，含兄弟食材组的最小数量约束
                -- 没有 test 函数的配方（如丹药）minnames 是堆叠数量，按食材种类计槽位
                -- 已经在锅里的食材只差数量不差槽位，只有尚未放入的食材种类才需要额外槽位
                if not item.recipe_def.test and reqs.minnames then
                    local needed_slots = 0
                    for name, min_amt in pairs(reqs.minnames) do
                        if (resolved[name] or 0) <= 0 then
                            needed_slots = needed_slots + 1
                        end
                    end
                    -- 检查替代材料组（analog_groups）是否至少有一种材料
                    if reqs.analog_groups then
                        for _, group in ipairs(reqs.analog_groups) do
                            local has_any = false
                            for _, gname in ipairs(group.names) do
                                if (resolved[gname] or 0) > 0 then
                                    has_any = true
                                    break
                                end
                            end
                            if not has_any then
                                needed_slots = needed_slots + 1
                            end
                        end
                    end
                    if needed_slots > remaining_slots then
                        ok = false
                    end
                else
                    ok = _CheckMinRequirements(reqs, resolved, tags, remaining_slots, max_tag_values, ingredients, max_slots)
                end
            end
            if ok then
                possible[item.prefab] = true
            end
        else
            possible[item.prefab] = true
        end
    end

    CacheSet(cache_key, possible)
    return next(possible) and possible or nil
end

function Matcher.GetRecipeMatchScore(reqs, prefab_list, ingredients)
    if not reqs or not prefab_list then
        return 0
    end

    ingredients = ingredients or cooking.ingredients

    local group_covered = {}
    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            for _, gname in ipairs(group.names) do
                group_covered[gname] = true
            end
        end
    end

    local score = 0
    for _, prefab in ipairs(prefab_list) do
        local name = INGREDIENT_ALIASES[prefab] or prefab
        if (reqs.minnames and reqs.minnames[name]) or group_covered[name] then
            score = score + 1
        end
        local ing = ingredients[name]
        if ing and ing.tags and reqs.mintags then
            for tag, _ in pairs(ing.tags) do
                if reqs.mintags[tag] then
                    score = score + 0.5
                end
            end
        end
    end
    return score
end

function Matcher.GetMatchingRecipes(db, cooker, prefab_list, ingredients, counts)
    if prefab_list == nil or #prefab_list == 0 then
        return nil
    end

    local names, tags = BuildNamesTags(prefab_list, ingredients)

    local matching = {}
    for _, item in ipairs(db.all) do
        if item.recipe_def.test ~= nil then
            local ok, result = pcall(item.recipe_def.test, cooker, names, tags)
            if ok and result then
                matching[item.prefab] = true
            end
        elseif item.recipe_requirements and item.recipe_requirements.minnames then
            local ok = true
            for name, count in pairs(item.recipe_requirements.minnames) do
                local have = (names[name] or 0)
                -- 如果 minnames 要求的大于格子数，使用实际堆叠计数
                if have < count and counts and counts[name] then
                    have = counts[name]
                end
                if have < count then
                    ok = false
                    break
                end
            end
            if ok and item.recipe_requirements.analog_groups then
                for _, group in ipairs(item.recipe_requirements.analog_groups) do
                    local group_total = 0
                    for _, gname in ipairs(group.names) do
                        local have = (names[gname] or 0)
                        if have < group.amount and counts and counts[gname] then
                            have = counts[gname]
                        end
                        group_total = group_total + have
                    end
                    if group_total < group.amount then
                        ok = false
                        break
                    end
                end
            end
            if ok then
                matching[item.prefab] = true
            end
        end
    end

    return next(matching) and matching or nil
end

function Matcher.GetMatchingRecipesFromCounts(db, cooker, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, pot_counts, use_quantity_matching)
    return ComboMatcher.Match(cooker, db.all, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, db._ingredient_aliases, pot_counts, use_quantity_matching)
end

-- 从匹配结果中选出游戏实际会产出的料理（最高优先级，且当前设备可做）
function Matcher.GetHighlightedRecipes(db, matching, cooker_recipes)
    if matching == nil then
        return nil
    end

    local by_priority = {}
    for _, item in ipairs(db.all) do
        if matching[item.prefab] then
            local p = item.recipe_def.priority or 0
            if by_priority[p] == nil then
                by_priority[p] = {}
            end
            by_priority[p][item.prefab] = true
        end
    end

    if next(by_priority) == nil then
        return nil
    end

    local priorities = {}
    for p, _ in pairs(by_priority) do
        table.insert(priorities, p)
    end
    table.sort(priorities, function(a, b) return a > b end)

    local highlight_group = nil
    for _, p in ipairs(priorities) do
        if cooker_recipes == nil then
            highlight_group = by_priority[p]
            break
        end
        local available = {}
        for prefab, _ in pairs(by_priority[p]) do
            if cooker_recipes[prefab] then
                available[prefab] = true
            end
        end
        if next(available) then
            highlight_group = available
            break
        end
    end

    return highlight_group
end

return Matcher
