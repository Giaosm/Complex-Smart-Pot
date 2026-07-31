-- 可做配方组合生成：为指定料理回溯搜索具体的食材组合 + 可制作份数（弹窗"可做配方"视图用）
local cooking = require("cooking")
local Matcher = require("data/recipe_matcher")
local ComboMatcher = require("data/combo_matcher")
local Logger = require("debug/logger")

local BuildNamesTags = Matcher.BuildNamesTags
local CheckRecipeByCounts = ComboMatcher.CheckRecipeByCounts

local CACHE_MAX = 500
local NEGATIVE = false  -- 负缓存哨兵：不可制作也缓存，避免每次刷新重跑回溯
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

-- 数量匹配模式：从计数表构造 names/tags 供 recipe.test 使用
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

-- 数量匹配模式：验证指定计数表是否确实产出目标料理（含优先级判定）
local function TestRecipeByCounts(cooker, recipe_item, sorted_defs, names, tags)
    if recipe_item.recipe_def == nil or recipe_item.recipe_def.test == nil then
        Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s 无 recipe_def.test", recipe_item.prefab)
        return false
    end
    local recipe_prefab = recipe_item.prefab

    -- 同时用分析时相同的空 cooker 调用，看看是否是 cooker 参数导致结果不同
    local st_empty, ret_empty = pcall(recipe_item.recipe_def.test, '', names, tags)
    local st_real, ret_real = pcall(recipe_item.recipe_def.test, cooker, names, tags)
    Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s cooker=%q names=%s tags=%s",
        recipe_prefab, tostring(cooker), DumpCounts(names), DumpCounts(tags))
    Logger.Logf("[智能锅]   test('')=%s test(cooker)=%s",
        tostring(st_empty and ret_empty), tostring(st_real and ret_real))

    if sorted_defs then
        -- sorted_defs 已按优先级降序排列：第一个匹配的料理才是实际产物
        for _, entry in ipairs(sorted_defs) do
            if entry.def ~= nil and entry.def.test ~= nil then
                local ok, r = pcall(entry.def.test, cooker, names, tags)
                if not ok then
                    Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s test 调用报错: %s", entry.prefab, tostring(r))
                end
                if ok and r then
                    local same_priority = (entry.def.priority or 0) == (recipe_item.recipe_def.priority or 0)
                    local matched = entry.prefab == recipe_prefab or same_priority
                    if not matched then
                        Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s 被高优先级料理 %s 抢占",
                            recipe_prefab, entry.prefab)
                    end
                    return matched
                end
            end
        end
        -- 没有任何料理匹配，说明当前 test 虽然返回 true 但已被优先级挤出
        Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s 在 sorted_defs 中无任何匹配", recipe_prefab)
        return false
    else
        local st, ret = pcall(recipe_item.recipe_def.test, cooker, names, tags)
        if not st then
            Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s test 调用报错: %s", recipe_prefab, tostring(ret))
        end
        Logger.Logf("[智能锅] TestRecipeByCounts: recipe=%s test 返回=%s", recipe_prefab, tostring(st and ret))
        return st and ret
    end
end

-- 把计数表序列化成可读的 k=v 字符串，仅用于调试输出
local function DumpCounts(counts)
    local items = {}
    for k, v in pairs(counts or {}) do
        if v > 0 then table.insert(items, k .. "=" .. v) end
    end
    table.sort(items)
    return "[" .. table.concat(items, ",") .. "]"
end

-- 把组合表（数组元素为 {prefab=, count=}）序列化，仅用于调试输出
local function DumpCombo(combo)
    if not combo then return "nil" end
    local items = {}
    for _, entry in ipairs(combo) do
        table.insert(items, entry.prefab .. "=" .. entry.count)
    end
    return "[" .. table.concat(items, ",") .. "]"
end

-- 把 recipe_requirements 序列化成可读字符串，仅用于调试输出
local function DumpRequirements(reqs)
    if not reqs then return "nil" end
    local parts = {}
    local function dump_map(label, map)
        if not map then return end
        local items = {}
        for k, v in pairs(map) do table.insert(items, k .. "=" .. v) end
        if #items > 0 then
            table.sort(items)
            table.insert(parts, label .. "[" .. table.concat(items, ",") .. "]")
        end
    end
    local function dump_groups(label, groups)
        if not groups then return end
        local gstrs = {}
        for _, g in ipairs(groups) do
            table.insert(gstrs, "(" .. table.concat(g.names or {}, "|") .. ")=" .. (g.amount or 0))
        end
        if #gstrs > 0 then
            table.insert(parts, label .. "[" .. table.concat(gstrs, ",") .. "]")
        end
    end
    dump_map("minnames", reqs.minnames)
    dump_map("maxnames", reqs.maxnames)
    dump_map("mintags", reqs.mintags)
    dump_map("maxtags", reqs.maxtags)
    dump_groups("analog", reqs.analog_groups)
    return table.concat(parts, " ")
end

-- 数量匹配模式：为一个料理构造一组带数量的食材（可堆叠设备用）
local function BuildQuantityCombo(recipe_item, bag_counts, pot_counts, cooker, max_slots, ingredients, ingredient_aliases, sorted_defs)
    local recipe_name = recipe_item.prefab
    local reqs = recipe_item.recipe_requirements
    Logger.Logf("[智能锅] BuildQuantityCombo 开始: recipe=%s max_slots=%d", recipe_name, max_slots or 4)
    Logger.Logf("[智能锅]   requirements: %s", DumpRequirements(reqs))
    Logger.Logf("[智能锅]   bag=%s pot=%s", DumpCounts(bag_counts), DumpCounts(pot_counts))
    if not reqs then
        Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s 无 recipe_requirements", recipe_name)
        return nil
    end

    local chosen = {}
    local function add(name, count)
        chosen[name] = (chosen[name] or 0) + count
    end
    local function chosen_count(name)
        return chosen[name] or 0
    end
    local function bag_count(name)
        return bag_counts[name] or 0
    end

    -- 锅里已有的也算入已选
    for name, count in pairs(pot_counts or {}) do
        add(name, count)
    end
    Logger.Logf("[智能锅]   加入锅中食材后 chosen=%s", DumpCounts(chosen))

    -- 1. 满足强制名食材
    if reqs.minnames then
        for name, min_count in pairs(reqs.minnames) do
            local need = min_count - chosen_count(name)
            if need > 0 then
                if bag_count(name) < need then
                    Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s minnames %s 需要%d 库存只有%d",
                        recipe_name, name, need, bag_count(name))
                    return nil
                end
                add(name, need)
            end
        end
        Logger.Logf("[智能锅]   满足 minnames 后 chosen=%s", DumpCounts(chosen))
    end

    -- 2. 满足可替代组（同类食材可互相替代）
    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            local have = 0
            for _, gname in ipairs(group.names) do
                have = have + chosen_count(gname)
            end
            if have < group.amount then
                local need = group.amount - have
                for _, gname in ipairs(group.names) do
                    local take = math.min(bag_count(gname), need)
                    if take > 0 then
                        add(gname, take)
                        need = need - take
                        if need <= 0 then break end
                    end
                end
                if need > 0 then
                    Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s analog_group 仍缺%d", recipe_name, need)
                    return nil
                end
            end
        end
        Logger.Logf("[智能锅]   满足 analog_groups 后 chosen=%s", DumpCounts(chosen))
    end

    -- 3. 满足标签需求
    if reqs.mintags then
        for tag, min_val in pairs(reqs.mintags) do
            local have = 0
            for name, count in pairs(chosen) do
                local ing_name = ingredient_aliases and ingredient_aliases[name] or name
                local data = ingredients and ingredients[ing_name]
                if data ~= nil and data.tags ~= nil and data.tags[tag] ~= nil then
                    have = have + count * data.tags[tag]
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
                        add(name, take)
                        need = need - take * val
                        if need <= 0 then
                            found = true
                            break
                        end
                    end
                end
                if not found then
                    Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s mintag %s 需要%d 无法满足",
                        recipe_name, tag, min_val)
                    return nil
                end
            end
        end
        Logger.Logf("[智能锅]   满足 mintags 后 chosen=%s", DumpCounts(chosen))
    end

    -- 4. 验证组合是否满足料理要求
    local names, tags = BuildNamesTagsFromCounts(chosen, ingredients, ingredient_aliases)
    Logger.Logf("[智能锅]   test 前 names=%s tags=%s", DumpCounts(names), DumpCounts(tags))
    if recipe_item.recipe_def ~= nil and recipe_item.recipe_def.test ~= nil then
        -- 有原始 test 函数（原版/HOF）：用游戏原始 test 验证，并做优先级判定
        if not TestRecipeByCounts(cooker, recipe_item, sorted_defs, names, tags) then
            Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s 未通过 recipe_def.test 或优先级判定", recipe_name)
            return nil
        end
    else
        -- 无原始 test 函数（如登仙炼丹炉 recipe_def 传的是空表）：用推导出的 requirements 校验
        if not CheckRecipeByCounts(recipe_item, names, tags, nil, ingredients) then
            Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s 未通过 recipe_requirements 校验", recipe_name)
            return nil
        end
    end

    -- 5. 可堆叠设备：不同食材种类数不能超过槽位数
    local distinct = 0
    for _, count in pairs(chosen) do
        if count > 0 then distinct = distinct + 1 end
    end
    if distinct > max_slots then
        Logger.Logf("[智能锅] BuildQuantityCombo 失败: recipe=%s 食材种类数%d 超过 max_slots%d",
            recipe_name, distinct, max_slots)
        return nil
    end

    -- 6. 构造带数量的组合表
    local combo = {}
    for name, count in pairs(chosen) do
        if count > 0 then
            table.insert(combo, { prefab = name, count = count })
        end
    end
    table.sort(combo, function(a, b) return a.prefab < b.prefab end)
    Logger.Logf("[智能锅] BuildQuantityCombo 成功: recipe=%s combo=%s", recipe_name, DumpCombo(combo))

    return combo
end

local ComboGen = {}

function ComboGen.ClearCache()
    _combo_cache = {}
    _cache_keys = {}
end

-- 为指定料理生成具体的食材组合 + 份数
function ComboGen.GetRecipeCraftableCombos(db, recipe_item, bag_counts, pot_counts, cooker, max_slots, use_quantity_matching, raw_bag_counts, sorted_defs)
    if not recipe_item or not bag_counts or next(bag_counts) == nil then
        return nil
    end

    -- 用 (料理 + bag + pot + raw_bag + 数量匹配标志) 做缓存 key，输入不变时直接返回
    local cache_key = recipe_item.prefab .. "|q" .. (use_quantity_matching and "1" or "0") .. "|"
    local keys = {}
    for k, v in pairs(bag_counts) do keys[#keys + 1] = "b" .. k .. "=" .. v end
    for k, v in pairs(pot_counts or {}) do keys[#keys + 1] = "p" .. k .. "=" .. v end
    for k, v in pairs(raw_bag_counts or {}) do keys[#keys + 1] = "r" .. k .. "=" .. v end
    table.sort(keys)
    cache_key = cache_key .. table.concat(keys, ";")
    if _combo_cache[cache_key] ~= nil then
        return CacheGet(cache_key)
    end

    local reqs = recipe_item.recipe_requirements
    if not reqs then return nil end

    -- 设备对应的食材表：酿酒（HOF）配方的 tag 体系与烹饪锅不同，必须用 brewingredients，
    -- 否则回溯匹配对 brewer 算出的 tag 是错的（旧实现硬编码 cooking.ingredients，是个 bug）
    local ingredients = (recipe_item.is_brewer and db._brewer_ingredients) or cooking.ingredients

    -- 数量匹配模式：可堆叠设备（如炼丹炉）单个格子可放多份同种食材，
    -- 用贪心 + test 验证生成一组带数量的食材，而不是把每个食材当成独立 slot。
    if use_quantity_matching then
        Logger.Logf("[智能锅] GetRecipeCraftableCombos 进入数量匹配分支: recipe=%s", recipe_item.prefab)
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
            Logger.Logf("[智能锅] GetRecipeCraftableCombos 返回组合: recipe=%s combo=%s portions=%d",
                recipe_item.prefab, DumpCombo(combo), portions)
            local r = { { ingredients = combo, portions = portions } }
            CacheSet(cache_key, r)
            return r
        end
        Logger.Logf("[智能锅] GetRecipeCraftableCombos 无组合: recipe=%s", recipe_item.prefab)
        CacheSet(cache_key, nil)
        return nil
    end
    max_slots = max_slots or 4
    pot_counts = pot_counts or {}
    raw_bag_counts = raw_bag_counts or bag_counts

    -- 份数计算用原始（未截断）库存
    local available = {}
    for k, v in pairs(pot_counts) do available[k] = (available[k] or 0) + v end
    for k, v in pairs(raw_bag_counts) do available[k] = (available[k] or 0) + v end

    local recipe_prefab = recipe_item.prefab

    -- 测试一组完整食材是否被游戏实际匹配为当前料理
    local function _testCombo(slot_list)
        local names, tags = BuildNamesTags(slot_list, ingredients)
        -- 首先当前料理必须符合
        if recipe_item.recipe_def.test ~= nil then
            local ok, ret = pcall(recipe_item.recipe_def.test, cooker, names, tags)
            if not (ok and ret) then return false end
        else
            if reqs.minnames then
                for name, min_amt in pairs(reqs.minnames) do
                    if (names[name] or 0) < min_amt then return false end
                end
            end
            if reqs.analog_groups then
                for _, group in ipairs(reqs.analog_groups) do
                    local total = 0
                    for _, gname in ipairs(group.names) do
                        total = total + (names[gname] or 0)
                    end
                    if total < group.amount then return false end
                end
            end
            if reqs.mintags then
                for tag, min_val in pairs(reqs.mintags) do
                    if (tags[tag] or 0) < min_val then return false end
                end
            end
            if reqs.maxnames then
                for name, max_val in pairs(reqs.maxnames) do
                    if (names[name] or 0) > max_val then return false end
                end
            end
            if reqs.maxtags then
                for tag, max_val in pairs(reqs.maxtags) do
                    if (tags[tag] or 0) > max_val then return false end
                end
            end
        end

        -- 按优先级验证：第一个匹配的料理才是游戏实际会产出的
        -- 同优先级料理之间不互相抢占，用户仍可查看任意一个的组合
        if sorted_defs then
            for _, entry in ipairs(sorted_defs) do
                if entry.def.test ~= nil then
                    local ok, ret = pcall(entry.def.test, cooker, names, tags)
                    if ok and ret then
                        local same_priority = (entry.def.priority or 0) == (recipe_item.recipe_def.priority or 0)
                        return entry.prefab == recipe_prefab or same_priority
                    end
                end
            end
        end

        return true
    end

    -- 构建候选食材列表（来自容器）
    local candidates = {}
    for prefab, count in pairs(bag_counts) do
        if count > 0 then
            table.insert(candidates, prefab)
        end
    end
    if #candidates == 0 then
        local base = {}
        for prefab, count in pairs(pot_counts) do
            for _ = 1, count do table.insert(base, prefab) end
        end
        if #base == max_slots and _testCombo(base) then
            local r = {{ ingredients = base, portions = 1 }}
            CacheSet(cache_key, r)
            return r
        end
        CacheSet(cache_key, nil)
        return nil
    end
    table.sort(candidates)

    local result = {}
    local seen = {}

    -- 固定底槽：锅里的食材
    local base_slots = {}
    for prefab, count in pairs(pot_counts) do
        for _ = 1, count do
            table.insert(base_slots, prefab)
        end
    end

    local remaining = max_slots - #base_slots
    if remaining < 0 then
        CacheSet(cache_key, nil)
        return nil
    end

    -- 复制 bag_counts 以便回溯时修改
    local bag_copy = {}
    for k, v in pairs(bag_counts) do bag_copy[k] = v end

    -- 回溯搜索：填充剩余槽位
    local function _search(filled, start_idx, rem)
        if rem == 0 then
            -- 去重
            local key_parts = {}
            for _, p in ipairs(filled) do table.insert(key_parts, p) end
            table.sort(key_parts)
            local skey = table.concat(key_parts, ",")
            if seen[skey] then return end
            seen[skey] = true

            if _testCombo(filled) then
                local used = {}
                for _, p in ipairs(filled) do used[p] = (used[p] or 0) + 1 end
                local portions = math.huge
                for p, c in pairs(used) do
                    local a = available[p] or 0
                    if c > 0 then
                        portions = math.min(portions, math.floor(a / c))
                    end
                end
                portions = math.max(1, portions)
                local ingr_copy = {}
                for _, v in ipairs(filled) do table.insert(ingr_copy, v) end
                table.insert(result, { ingredients = ingr_copy, portions = portions })
            end
            return
        end

        for i = start_idx, #candidates do
            local p = candidates[i]
            if bag_copy[p] > 0 then
                table.insert(filled, p)
                bag_copy[p] = bag_copy[p] - 1
                _search(filled, i, rem - 1)
                bag_copy[p] = bag_copy[p] + 1
                table.remove(filled)
            end
        end
    end

    _search(base_slots, 1, remaining)

    table.sort(result, function(a, b) return a.portions > b.portions end)

    CacheSet(cache_key, #result > 0 and result or nil)
    return CacheGet(cache_key)
end

return ComboGen
