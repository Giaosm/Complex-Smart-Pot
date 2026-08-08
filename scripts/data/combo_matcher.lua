-- 组合匹配：给定食材计数，回溯遍历所有组合找到能做的最高优先级料理
local cooking = require("cooking")
local Config = require("config/config_manager")
local Logger = require("debug/logger")
local Collector = require("data/recipe_data_collector")

local ComboMatcher = {}

local CACHE_MAX = Config.GetCacheMax()
local _match_cache = {}
local _cache_keys = {}  -- LRU 顺序，最新的在末尾

-- 组合→料理映射缓存：供组合路径复用，避免重复枚举
-- 值：{ combos = { [组合串] = { [prefab] = priority, ... }, ... }, complete = bool }
-- complete=false 表示部分结果（面板被打断时写入），命中后需续算补齐
local _combo_map_cache = {}
local _map_cache_keys = {}  -- LRU 顺序，最新的在末尾

-- 环境料理专用缓存：普通料理结果跨环境复用（无指纹缓存）；
-- 环境料理结果随季节/月相变化，需按环境指纹单独缓存，环境变化时只重算环境料理部分（量小）。
local _env_match_cache = {}
local _env_match_keys = {}
local _env_map_cache = {}
local _env_map_keys = {}

-- ============ 缓存统计（调试用） ============
-- 统计组合映射缓存的"组合条目数"，用于输出"组合缓存 / 本次新增 / 命中率"
local _combo_count = 0

-- 实时统计当前缓存中的组合总数
local function _UpdateMapComboStats()
    local total = 0
    for _, entry in pairs(_combo_map_cache) do
        for _ in pairs(entry.combos or {}) do
            total = total + 1
        end
    end
    _combo_count = total
end

-- 上次输出统计时的组合总数（用于计算"本次新增"）
local _last_stats_combo_count = 0

local function _MapSummary()
    -- "新增" = 自上次统计以来新增的组合数（本次增量，非累计）
    local added_this = _combo_count - _last_stats_combo_count
    if added_this < 0 then added_this = 0 end
    -- "命中率" = 按组合算：本次涉及的组合中，命中缓存（无需新算）的占比
    -- 即 (当前组合总数 - 本次新增) / 当前组合总数
    local rate = 0
    if _combo_count > 0 then
        rate = (_combo_count - added_this) / _combo_count * 100
    end
    return string.format("组合缓存:%d 新增:%d 命中:%.1f%%",
        _combo_count, added_this, rate)
end

function ComboMatcher.LogCacheStats()
    if not Logger.IsEnabled() then return end
    local line = "[智能锅][缓存] 映射:" .. _MapSummary()
    -- 输出前更新基准，供下次计算"本次新增"
    _last_stats_combo_count = _combo_count
    print(line)
end

local function MapCacheGet(key)
    return _combo_map_cache[key]
end

local function MapCacheSet(key, value)
    if _combo_map_cache[key] == nil then
        table.insert(_map_cache_keys, key)
        if #_map_cache_keys > CACHE_MAX then
            local old = table.remove(_map_cache_keys, 1)
            _combo_map_cache[old] = nil
        end
    end
    _combo_map_cache[key] = value
    _UpdateMapComboStats()
end

-- 写入 _match_cache 并维护 LRU 顺序（最新在末尾，超限淘汰表头最久未用）
local function SetCache(key, value)
    if _match_cache[key] == nil then
        table.insert(_cache_keys, key)
        if #_cache_keys > CACHE_MAX then
            local old = table.remove(_cache_keys, 1)
            _match_cache[old] = nil
        end
    end
    _match_cache[key] = value
end

-- 从映射聚合出"能做的料理集合"：每个组合取最高优先级料理的并集
local function CombineCombosToSet(combos)
    local set = {}
    for _, matched in pairs(combos) do
        -- 环境组合映射的值为 { dims={...}, matched={prefab=priority} } 嵌套结构，需取子表
        if type(matched) == "table" and matched.matched ~= nil then
            matched = matched.matched
        end
        local max_p = nil
        for prefab, p in pairs(matched) do
            if max_p == nil or p > max_p then max_p = p end
        end
        if max_p ~= nil then
            for prefab, p in pairs(matched) do
                if p == max_p then set[prefab] = true end
            end
        end
    end
    return next(set) and set or nil
end


local function BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
    local parts = {}
    table.insert(parts, tostring(max_slots))
    table.insert(parts, use_quantity_matching and "Q" or "S")

    -- 数量裁剪：不可堆叠设备（烹饪锅）中，超过槽位上限的食材数量不影响"能否做"（只影响份数），
    -- 份数由 _RestoreCombosFromMap 用原始 bag_counts 实时计算，因此 key 可裁剪，避免超量食材变化导致缓存 miss。
    -- 可堆叠设备（数量匹配）不裁剪（其匹配结果与数量直接相关）。
    local cap = use_quantity_matching and math.huge or (max_slots or 4)

    local function append_counts(label, counts)
        local keys = {}
        for k, v in pairs(counts or {}) do
            local vv = v
            if vv > cap then vv = cap end
            table.insert(keys, k .. "=" .. vv)
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

    -- 环境指纹：仅当当前食材组合可能涉及环境料理时才纳入（避免普通料理缓存随环境变化失效）
    -- has_env 由调用方根据当前食材中是否含环境料理需求的食材类型判断
    if has_env then
        table.insert(parts, "E:" .. Logger.GetEnvironmentFingerprint())
    end

    return table.concat(parts, "|")
end

-- 环境缓存 key = 无指纹普通 key + 环境指纹（季节+月相，不含节日；环境料理不依赖节日）
local function BuildEnvCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local plain = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
    return plain .. "|" .. Logger.GetEnvFingerprintForDim("season+moon")
end

local function EnvSetCache(key, value)
    if _env_match_cache[key] == nil then
        table.insert(_env_match_keys, key)
        if #_env_match_keys > CACHE_MAX then
            local old = table.remove(_env_match_keys, 1)
            _env_match_cache[old] = nil
        end
    end
    _env_match_cache[key] = value
end

local function EnvMapCacheSet(key, value)
    if _env_map_cache[key] == nil then
        table.insert(_env_map_keys, key)
        if #_env_map_keys > CACHE_MAX then
            local old = table.remove(_env_map_keys, 1)
            _env_map_cache[old] = nil
        end
    end
    _env_map_cache[key] = value
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

-- 预过滤：料理所需食材类型在 bag/fixed/pot 中至少出现一种
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

-- 用数量向量直接检查一个料理是否可被满足（用于可堆叠或高数量需求设备）
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

-- 数量向量匹配：用于可堆叠设备（单 slot 可放多份同种食材），判断能否从 bag+pot 满足 min 且不超 max
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
                -- 无反向推导需求，保守跳过（避免误报）
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

-- 不可堆叠设备：slot 级回溯，只枚举相关食材类型
-- yield_fn：每处理完一个组合后调用(result,combos_map)，用于分片执行；nil 则一次性算完。
-- 返回：result/combos_map(普通) + result_env/env_combos_map(环境)。
-- env_only=true 时只枚举环境料理（普通缓存已命中、仅需补算环境），仅返回环境部分。
local function MatchNonStacked(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, yield_fn, env_only)
    local total_fixed = 0
    for _, c in pairs(fixed_counts) do
        total_fixed = total_fixed + c
    end
    local free_slots = max_slots - total_fixed
    if free_slots <= 0 then
        return nil
    end

    -- 预过滤：先淘汰不可能料理；env_only 时只保留环境料理（避免使用 goto，保证各 Lua 版本兼容）
    local candidate_items = {}
    for _, item in ipairs(all_items) do
        if not (env_only and not item.is_environment_locked) then
            local cooker_ok = cooker_recipes == nil or cooker_recipes[item.prefab]
            if cooker_ok and PrefilterRecipe(item, bag_counts, fixed_counts, pot_counts) then
                table.insert(candidate_items, item)
            end
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
    local result = {}          -- 普通料理可做集合（无指纹缓存，跨环境复用）
    local result_env = {}      -- 环境料理可做集合（带维度指纹缓存）
    local combos_map = {}      -- 普通组合→料理映射
    local env_combos_map = {}  -- 环境组合→料理映射（值 { dims={[dim]=true}, matched={[prefab]=priority} }）
    local sel_prefabs = {}
    local sel_counts = {}

    -- 分片挂起点：每处理完一个完整组合后触发（仅当传入 yield_fn 且当前处于协程内）
    local _yield_fn = yield_fn

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
            -- 普通料理与环境料理分流：普通料理结果可跨环境复用，环境料理结果需按维度指纹缓存
            local matched_plain = {}
            local matched_env = {}
            local max_priority_plain = nil
            local max_priority_env = nil
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
                    if item.is_environment_locked then
                        matched_env[item.prefab] = p
                        if max_priority_env == nil or p > max_priority_env then
                            max_priority_env = p
                        end
                    else
                        matched_plain[item.prefab] = p
                        if max_priority_plain == nil or p > max_priority_plain then
                            max_priority_plain = p
                        end
                    end
                end
            end
            -- 记录组合→料理映射（含优先级），供组合路径复用/续算
            local combo_key = table.concat(flat, ",")
            if next(matched_plain) then
                combos_map[combo_key] = matched_plain
            end
            if next(matched_env) then
                -- 维度聚合自匹配出的环境料理 env_dim，兜底用食材配方匹配
                local dims = {}
                local found = false
                for _, item in ipairs(candidate_items) do
                    if matched_env[item.prefab] and item.env_dim then
                        dims[item.env_dim] = true
                        found = true
                    end
                end
                if not found then
                    local env_dims = Collector.IsEnvCombination(names, tags)
                    if env_dims then
                        for d in pairs(env_dims) do dims[d] = true end
                    end
                end
                env_combos_map[combo_key] = { dims = dims, matched = matched_env }
            end
            if max_priority_plain ~= nil then
                for prefab, p in pairs(matched_plain) do
                    if p == max_priority_plain then
                        result[prefab] = true
                    end
                end
            end
            if max_priority_env ~= nil then
                for prefab, p in pairs(matched_env) do
                    if p == max_priority_env then
                        result_env[prefab] = true
                    end
                end
            end
            if _yield_fn ~= nil then
                _yield_fn(result, combos_map, result_env, env_combos_map)
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

    -- 调试统计：候选料理 / 最终料理（按原版/模组拆分，仅调试开启时输出）
    if Logger.IsEnabled() then
        local cand_vanilla, cand_mod = 0, 0
        local fin_vanilla, fin_mod = 0, 0
        for _, item in ipairs(candidate_items) do
            if item.is_vanilla then
                cand_vanilla = cand_vanilla + 1
            else
                cand_mod = cand_mod + 1
            end
            if result[item.prefab] or result_env[item.prefab] then
                if item.is_vanilla then
                    fin_vanilla = fin_vanilla + 1
                else
                    fin_mod = fin_mod + 1
                end
            end
        end
        Logger.Logf("[智能锅] 候选料理%d(模组%d+原版%d) 最终料理%d(模组%d+原版%d)",
            #candidate_items, cand_mod, cand_vanilla, fin_mod + fin_vanilla, fin_mod, fin_vanilla)
    end
    -- env_combos_map 始终返回表（空表也返回，便于 CacheMatch 写入空环境缓存，避免"计算中"卡死）
    return next(result) and result or nil, next(combos_map) and combos_map or nil,
           next(result_env) and result_env or nil, env_combos_map
end

function ComboMatcher.Match(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, use_quantity_matching, has_env)
    if not bag_counts or next(bag_counts) == nil then
        return nil
    end

    fixed_counts = fixed_counts or {}
    pot_counts = pot_counts or {}
    max_slots = max_slots or 4
    ingredients = ingredients or cooking.ingredients
    ingredient_aliases = ingredient_aliases or {}

    -- 查缓存：普通(无指纹) + 环境(带指纹)
    local plain_key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
    local env_key = BuildEnvCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local plain_cached = _match_cache[plain_key]
    local env_cached = _env_match_cache[env_key]

    -- 普通命中但环境 miss（如环境变化）：仅补算环境料理，普通料理用缓存，避免重枚举
    if plain_cached and not env_cached and not use_quantity_matching then
        local _, _, result_env, env_combos_map = MatchNonStacked(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, nil, true)
        EnvSetCache(env_key, result_env or {})
        if env_combos_map and next(env_combos_map) then
            EnvMapCacheSet(env_key, { combos = env_combos_map, complete = true })
        end
        local merged = {}
        for k in pairs(plain_cached) do merged[k] = true end
        for k in pairs(result_env or {}) do merged[k] = true end
        return next(merged) and merged or nil
    end

    if plain_cached or env_cached then
        local merged = {}
        for k in pairs(plain_cached or {}) do merged[k] = true end
        for k in pairs(env_cached or {}) do merged[k] = true end
        return next(merged) and merged or nil
    end

    local result, combos_map, result_env, env_combos_map
    if use_quantity_matching then
        result = MatchByQuantity(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
    else
        result, combos_map, result_env, env_combos_map = MatchNonStacked(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
    end

    SetCache(plain_key, result or {})           -- 普通：无指纹缓存
    EnvSetCache(env_key, result_env or {})      -- 环境：带指纹缓存
    if not use_quantity_matching then
        MapCacheSet(plain_key, { combos = combos_map or {}, complete = true })
        EnvMapCacheSet(env_key, { combos = env_combos_map or {}, complete = true })
    end
    -- 返回普通 + 环境合并的可做料理集合
    if result_env and next(result_env) then
        local merged = {}
        for k in pairs(result or {}) do merged[k] = true end
        for k in pairs(result_env) do merged[k] = true end
        return next(merged) and merged or nil
    end
    return result
end

-- 分片路径的缓存读写（与同步 Match 共用同一 _match_cache + LRU）
function ComboMatcher.GetCachedMatch(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
    if not bag_counts or next(bag_counts) == nil then
        return nil
    end
    -- 普通 + 环境都命中才合并返回；任一 miss（如环境变化）返回 nil，由上层补算
    local plain_key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
    local env_key = BuildEnvCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local plain_cached = _match_cache[plain_key]
    local env_cached = _env_match_cache[env_key]
    if plain_cached and env_cached then
        local merged = {}
        for k in pairs(plain_cached) do merged[k] = true end
        for k in pairs(env_cached) do merged[k] = true end
        return next(merged) and merged or nil
    end
    return nil
end

function ComboMatcher.CacheMatch(result, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, combos_map, complete, has_env, result_env, env_combos_map)
    if not bag_counts or next(bag_counts) == nil then
        return
    end
    local plain_key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
    local env_key = BuildEnvCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    -- result 仅在传入时写入（env_only 补算场景 result 为 nil，保留已有普通缓存）
    if result ~= nil then
        SetCache(plain_key, result or {})
    end
    EnvSetCache(env_key, result_env or {})
    if combos_map ~= nil and combos_map ~= false and next(combos_map) then
        ComboMatcher.CacheCombosMap(combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete, has_env)
    end
    -- 环境组合映射始终写入（空表也写，表示"当前环境无环境料理组合"，避免误判不完整导致弹窗"计算中"）
    if env_combos_map ~= nil and env_combos_map ~= false then
        ComboMatcher.CacheEnvCombosMap(env_combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete)
    end
end

ComboMatcher.CheckRecipeByCounts = CheckRecipeByCounts

-- 分片匹配任务：把回溯拆成时间片执行，避免单次阻塞主线程（算法不变，精度与同步一致）
-- Step(budget_ms)/IsDone/GetResult/Cancel
local YIELD_EVERY = 64

local MatchTask = Class(function(self)
    self._co = nil
    self._done = false
    self._result = nil
    self._combos = nil
    self._result_env = nil
    self._env_combos = nil
    self._partial_result = nil
    self._partial_combos = nil
    self._partial_result_env = nil
    self._partial_env_combos = nil
    self._canceled = false
    self._slice_deadline = 0
end)

function MatchTask:Init(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, use_quantity_matching)
    ingredients = ingredients or cooking.ingredients  -- 普通锅未传 brewingredients 时回退
    ingredient_aliases = ingredient_aliases or {}
    fixed_counts = fixed_counts or {}
    pot_counts = pot_counts or {}
    max_slots = max_slots or 4

    local self_ = self
    local function make_yield_fn()
        local count = 0
        return function(current_result, current_combos, current_result_env, current_env_combos)
            count = count + 1
            if count >= YIELD_EVERY then
                count = 0
                if os.clock() * 1000 >= self_._slice_deadline then
                    coroutine.yield(current_result, current_combos, current_result_env, current_env_combos)
                end
            end
        end
    end

    -- 普通料理已缓存时只补算环境料理（env_only），避免环境变化时重复枚举普通料理
    local env_only = false
    if not use_quantity_matching then
        local plain_key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
        env_only = _match_cache[plain_key] ~= nil
    end
    self._env_only = env_only

    self._co = coroutine.create(function()
        local result, combos_map, result_env, env_combos_map
        if use_quantity_matching then
            result = MatchByQuantity(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts)
        else
            result, combos_map, result_env, env_combos_map = MatchNonStacked(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, make_yield_fn(), env_only)
        end
        self._result = result
        self._combos = combos_map
        self._result_env = result_env
        self._env_combos = env_combos_map
    end)
    return self
end

function MatchTask:Step(budget_ms)
    if self._done or self._canceled then
        return true
    end
    self._slice_deadline = os.clock() * 1000 + (budget_ms or 3)
    local ok, partial, partial_combos, partial_result_env, partial_env_combos = coroutine.resume(self._co)
    if not ok then
        self._done = true
        self._result = nil
        self._combos = nil
        self._result_env = nil
        self._env_combos = nil
        self._partial_result = nil
        self._partial_combos = nil
        self._partial_result_env = nil
        self._partial_env_combos = nil
        Logger.Logf("[智能锅] 分片匹配协程出错: %s", tostring(partial))
        return true
    end
    if partial ~= nil then
        self._partial_result = partial
    end
    if partial_combos ~= nil then
        self._partial_combos = partial_combos
    end
    if partial_result_env ~= nil then
        self._partial_result_env = partial_result_env
    end
    if partial_env_combos ~= nil then
        self._partial_env_combos = partial_env_combos
    end
    if coroutine.status(self._co) == "dead" then
        self._done = true
        self._partial_result = self._result
        self._partial_combos = self._combos
        self._partial_result_env = self._result_env
        self._partial_env_combos = self._env_combos
    end
    return self._done
end

function MatchTask:IsDone()
    return self._done or self._canceled
end

-- 是否为"仅补算环境料理"任务（普通料理结果已缓存，只重算环境部分）
function MatchTask:IsEnvOnly()
    return self._env_only == true
end

function MatchTask:GetPartialResult()
    if self._canceled or self._partial_result == nil then
        return nil
    end
    return next(self._partial_result) and self._partial_result or nil
end

function MatchTask:GetPartialCombos()
    if self._canceled or self._partial_combos == nil then
        return nil
    end
    return self._partial_combos
end

function MatchTask:GetPartialResultEnv()
    if self._canceled or self._partial_result_env == nil then
        return nil
    end
    return next(self._partial_result_env) and self._partial_result_env or nil
end

function MatchTask:GetPartialEnvCombos()
    if self._canceled or self._partial_env_combos == nil then
        return nil
    end
    return self._partial_env_combos
end

function MatchTask:GetResult()
    if self._done and self._result ~= nil then
        return next(self._result) and self._result or nil
    end
    return nil
end

function MatchTask:Cancel()
    self._canceled = true
    self._co = nil
    self._result = nil
    self._combos = nil
    self._result_env = nil
    self._env_combos = nil
end

local MATCH_TASK_TYPE_THRESHOLD = 10

function ComboMatcher.ShouldUseTask(bag_counts, fixed_counts, max_slots, use_quantity_matching)
    if use_quantity_matching then
        return false  -- 数量匹配走贪心，本就快
    end
    local total_fixed = 0
    for _, c in pairs(fixed_counts or {}) do
        total_fixed = total_fixed + c
    end
    local free_slots = (max_slots or 4) - total_fixed
    if free_slots <= 0 then
        return false
    end
    local num_types = 0
    for _ in pairs(bag_counts or {}) do
        num_types = num_types + 1
    end
    return num_types >= MATCH_TASK_TYPE_THRESHOLD
end

function ComboMatcher.CreateMatchTask(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, use_quantity_matching)
    local task = MatchTask()
    task:Init(cooker, all_items, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, ingredient_aliases, pot_counts, use_quantity_matching)
    return task
end

-- ============ 组合→料理映射缓存 ============

-- 查询组合映射（普通无指纹 + 环境带指纹，合并返回）；还原逻辑无需感知环境差异
function ComboMatcher.GetCachedCombosMap(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
    if not bag_counts or next(bag_counts) == nil then
        return nil
    end
    local plain_key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
    local env_key = BuildEnvCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local plain = MapCacheGet(plain_key)
    local env = _env_map_cache[env_key]
    if not plain and not env then
        return nil
    end
    local merged = {}
    if plain then for k, v in pairs(plain.combos or {}) do merged[k] = v end end
    if env then for k, v in pairs(env.combos or {}) do merged[k] = v end end
    -- 普通 + 环境组合映射都完整才算完整；任一 miss（环境变化）返回 false，由上层分片补齐
    local complete = (plain and plain.complete == true) and (env and env.complete == true)
    return { combos = merged, complete = complete }
end

-- 写入普通组合映射缓存；complete 默认 true；仅不可堆叠路径使用（数量匹配无组合枚举）
function ComboMatcher.CacheCombosMap(combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete, has_env)
    if use_quantity_matching or not bag_counts or next(bag_counts) == nil then
        return
    end
    if combos_map == nil or next(combos_map) == nil then
        return
    end
    local key = BuildCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, false)
    local existing = _combo_map_cache[key]
    if existing and existing.complete then
        return  -- 已有完整结果，不覆盖
    end
    MapCacheSet(key, { combos = combos_map, complete = complete ~= false })
end

-- 写入环境组合映射缓存（带环境指纹 key）
function ComboMatcher.CacheEnvCombosMap(env_combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete)
    if use_quantity_matching or not bag_counts or next(bag_counts) == nil then
        return
    end
    if env_combos_map == nil then
        return
    end
    local key = BuildEnvCacheKey(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching)
    local existing = _env_map_cache[key]
    if existing and existing.complete then
        return  -- 已有完整结果，不覆盖
    end
    EnvMapCacheSet(key, { combos = env_combos_map, complete = complete ~= false })
end

-- 从映射缓存还原"能做的料理集合"（每个组合取最高优先级）
function ComboMatcher.GetRecipesFromCombosMap(cache_entry)
    if not cache_entry then return nil end
    return CombineCombosToSet(cache_entry.combos)
end

return ComboMatcher
