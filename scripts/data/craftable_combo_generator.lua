-- 可做配方组合生成：为指定料理回溯搜索具体的食材组合 + 可制作份数（弹窗"可做配方"视图用）
local cooking = require("cooking")
local ComboMatcher = require("data/combo_matcher")
local Logger = require("debug/logger")
local Config = require("config/config_manager")

local CheckRecipeByCounts = ComboMatcher.CheckRecipeByCounts

local CACHE_MAX = Config.GetCacheMax()
local NEGATIVE = false  -- 负缓存哨兵：不可制作也缓存
local _combo_cache = {}
local _cache_keys = {}

local function CacheGet(key)
    local cached = _combo_cache[key]
    if cached ~= nil then
        return cached ~= NEGATIVE and cached or nil
    end
    return nil
end

local function CacheSet(key, value)
    if _combo_cache[key] == nil then
        table.insert(_cache_keys, key)
        if #_cache_keys > CACHE_MAX then
            local old = table.remove(_cache_keys, 1)
            _combo_cache[old] = nil
        end
    end
    _combo_cache[key] = value or NEGATIVE
end

-- 构建组合缓存 key（料理 + bag + pot + raw_bag + 数量匹配标志 + 环境指纹）
-- 环境指纹按该料理自身维度纳入：普通料理不带指纹（永久复用），环境料理带对应维度指纹（按需失效）
local function BuildComboCacheKey(recipe_item, bag_counts, pot_counts, raw_bag_counts, use_quantity_matching)
    local cache_key = recipe_item.prefab .. "|q" .. (use_quantity_matching and "1" or "0") .. "|"
    local keys = {}
    for k, v in pairs(bag_counts) do keys[#keys + 1] = "b" .. k .. "=" .. v end
    for k, v in pairs(pot_counts or {}) do keys[#keys + 1] = "p" .. k .. "=" .. v end
    for k, v in pairs(raw_bag_counts or {}) do keys[#keys + 1] = "r" .. k .. "=" .. v end
    table.sort(keys)
    cache_key = cache_key .. table.concat(keys, ";")
    if recipe_item.is_environment_locked then
        local fp = Logger.GetEnvFingerprintForDim(recipe_item.env_dim)
        if fp then
            cache_key = cache_key .. "|" .. fp
        end
    end
    return cache_key
end

-- 从计数表构造 names/tags 供 recipe.test 使用
local function BuildNamesTagsFromCounts(counts, ingredients, ingredient_aliases)
    local names = {}
    local tags = {}
    for prefab, count in pairs(counts) do
        if count > 0 then
            names[prefab] = (names[prefab] or 0) + count
            local ingredient_name = ingredient_aliases and ingredient_aliases[prefab] or prefab
            local data = ingredients and ingredients[ingredient_name]
            if data ~= nil and data.tags ~= nil then
                for tag, val in pairs(data.tags) do
                    tags[tag] = (tags[tag] or 0) + val * count
                end
            end
        end
    end
    return names, tags
end

-- 验证计数表是否产出目标料理（含优先级判定）
local function TestRecipeByCounts(cooker, recipe_item, sorted_defs, names, tags)
    if recipe_item.recipe_def == nil or recipe_item.recipe_def.test == nil then
        return false
    end
    local recipe_prefab = recipe_item.prefab

    if sorted_defs then
        -- 第一个匹配的料理才是实际产物
        for _, entry in ipairs(sorted_defs) do
            if entry.def ~= nil and entry.def.test ~= nil then
                local ok, r = pcall(entry.def.test, cooker, names, tags)
                if not ok then
                    Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s test 调用报错: %s", entry.prefab, tostring(r))
                end
                if ok and r then
                    local same_priority = (entry.def.priority or 0) == (recipe_item.recipe_def.priority or 0)
                    local matched = entry.prefab == recipe_prefab or same_priority
                    return matched
                end
            end
        end
        return false
    else
        local st, ret = pcall(recipe_item.recipe_def.test, cooker, names, tags)
        if not st then
            Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s test 调用报错: %s", recipe_prefab, tostring(ret))
        end
        return st and ret
    end
end

-- 为一个料理构造一组带数量的食材（可堆叠/高数量需求设备用）
-- 返回的组合 = 配方需求的完整清单（不受锅里已放材料影响，恒定），
-- 锅里已有材料仅用于抵扣背包消耗和验证可做性，绝不混入返回组合。
local function BuildQuantityCombo(recipe_item, bag_counts, pot_counts, cooker, max_slots, ingredients, ingredient_aliases, sorted_defs)
    local reqs = recipe_item.recipe_requirements
    if not reqs then
        return nil
    end

    -- provided：锅里已投入的材料（只用于抵扣/验证，不进返回组合）
    local provided = {}
    for name, count in pairs(pot_counts or {}) do
        if count > 0 then provided[name] = count end
    end
    local function provided_count(name)
        return provided[name] or 0
    end
    local function bag_count(name)
        return bag_counts[name] or 0
    end

    -- combo：配方需求的完整组合（恒定展示）；chosen：需从背包补充的部分（用于验证/份数）
    local combo = {}
    local chosen = {}
    local function add_combo(name, count)
        combo[name] = (combo[name] or 0) + count
    end
    local function add_chosen(name, count)
        chosen[name] = (chosen[name] or 0) + count
    end
    -- 某一材料当前已投入总量（锅里 + 背包已补）
    local function have(name)
        return provided_count(name) + (chosen[name] or 0)
    end

    -- 1. 强制名食材：需求恒定 = min_count；背包补足缺口
    if reqs.minnames then
        for name, min_count in pairs(reqs.minnames) do
            add_combo(name, min_count)
            local need = min_count - have(name)
            if need > 0 then
                if bag_count(name) < need then
                    return nil
                end
                add_chosen(name, need)
            end
        end
    end

    -- 2. 可替代组（同类食材可互相替代）：优先用锅里的，不足的用背包选一种补
    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            local have = 0
            for _, gname in ipairs(group.names) do
                have = have + provided_count(gname) + (chosen[gname] or 0)
            end
            if have < group.amount then
                local need = group.amount - have
                -- 从背包选组内材料补足（组合展示该组实际采用的材料）
                for _, gname in ipairs(group.names) do
                    local take = math.min(bag_count(gname), need)
                    if take > 0 then
                        add_chosen(gname, take)
                        add_combo(gname, take)
                        need = need - take
                        if need <= 0 then break end
                    end
                end
                if need > 0 then
                    return nil
                end
            end
        end
    end

    -- 3. 标签需求
    if reqs.mintags then
        for tag, min_val in pairs(reqs.mintags) do
            local have = 0
            for name in pairs(combo) do
                local ing_name = ingredient_aliases and ingredient_aliases[name] or name
                local data = ingredients and ingredients[ing_name]
                if data ~= nil and data.tags ~= nil and data.tags[tag] ~= nil then
                    have = have + have(name) * data.tags[tag]
                end
            end
            if have < min_val then
                local need = min_val - have
                local found = false
                local bag_list = {}
                for name, _ in pairs(bag_counts) do table.insert(bag_list, name) end
                table.sort(bag_list)
                for _, name in ipairs(bag_list) do
                    local ing_name = ingredient_aliases and ingredient_aliases[name] or name
                    local data = ingredients and ingredients[ing_name]
                    if data ~= nil and data.tags ~= nil and data.tags[tag] ~= nil then
                        local val = data.tags[tag]
                        local take = math.min(bag_count(name), math.ceil(need / val))
                        add_chosen(name, take)
                        add_combo(name, take)
                        need = need - take * val
                        if need <= 0 then
                            found = true
                            break
                        end
                    end
                end
                if not found then
                    return nil
                end
            end
        end
    end

    -- 4. 验证组合是否满足料理要求（用锅里+背包的完整投入验证）
    local verify = {}
    for name, count in pairs(provided) do verify[name] = count end
    for name, count in pairs(chosen) do verify[name] = (verify[name] or 0) + count end
    local names, tags = BuildNamesTagsFromCounts(verify, ingredients, ingredient_aliases)
    if recipe_item.recipe_def ~= nil and recipe_item.recipe_def.test ~= nil then
        -- 用游戏原始 test 验证，并做优先级判定
        if not TestRecipeByCounts(cooker, recipe_item, sorted_defs, names, tags) then
            return nil
        end
    else
        -- 无原始 test 函数：用推导出的 requirements 校验
        if not CheckRecipeByCounts(recipe_item, names, tags, nil, ingredients) then
            return nil
        end
    end

    -- 5. 可堆叠设备：不同食材种类数不能超过槽位数（按配方需求组合算）
    local distinct = 0
    for _, count in pairs(combo) do
        if count > 0 then distinct = distinct + 1 end
    end
    if distinct > max_slots then
        return nil
    end

    -- 6. 构造带数量的组合表（返回配方需求清单，不含锅里多余材料）
    local result = {}
    for name, count in pairs(combo) do
        if count > 0 then
            table.insert(result, { prefab = name, count = count })
        end
    end
    table.sort(result, function(a, b) return a.prefab < b.prefab end)
    return result
end

local ComboGen = {}

function ComboGen.ClearCache()
    _combo_cache = {}
    _cache_keys = {}
end

function ComboGen.GetRecipeCraftableCombos(db, recipe_item, bag_counts, pot_counts, cooker, max_slots, use_quantity_matching, raw_bag_counts, sorted_defs)
    if not recipe_item or not bag_counts or next(bag_counts) == nil then
        return nil
    end

    -- 用 (料理 + bag + pot + raw_bag + 数量匹配标志 + 环境指纹) 做缓存 key
    local cache_key = BuildComboCacheKey(recipe_item, bag_counts, pot_counts, raw_bag_counts, use_quantity_matching)
    if _combo_cache[cache_key] ~= nil then
        return CacheGet(cache_key)
    end

    local reqs = recipe_item.recipe_requirements
    if not reqs then return nil end

    -- 酿酒设备用 brewingredients（tag 体系与烹饪锅不同）
    local ingredients = (recipe_item.is_brewer and db._brewer_ingredients) or cooking.ingredients

    -- 仅数量匹配设备使用（炼丹炉等可堆叠设备，贪心 + test 生成带数量组合）
    -- 不可堆叠设备的可做配方已统一走匹配路径的组合映射缓存（recipe_panel._RestoreCombosFromMap）
    if not use_quantity_matching then
        return nil
    end

    raw_bag_counts = raw_bag_counts or bag_counts
    local combo = BuildQuantityCombo(recipe_item, bag_counts, pot_counts, cooker, max_slots or 4, ingredients, db._ingredient_aliases, sorted_defs)
    if combo then
        local portions = math.huge
        for _, entry in ipairs(combo) do
            local available = (pot_counts[entry.prefab] or 0) + (raw_bag_counts[entry.prefab] or bag_counts[entry.prefab] or 0)
            if entry.count > 0 then
                portions = math.min(portions, math.floor(available / entry.count))
            end
        end
        portions = math.max(1, portions)
        local r = { { ingredients = combo, portions = portions } }
        CacheSet(cache_key, r)
        return r
    end
    CacheSet(cache_key, nil)
    return nil
end

return ComboGen
