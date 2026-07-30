-- 料理数据：收集全部食谱（原版+酿酒+炼丹），提供筛选/匹配/评分/组合搜索
local cooking = require("cooking")
local Detector = require("recipe_detector")
local ResolveIcon = require("utils/resolveinventoryitemassets")
local ComboMatcher = require("combo_matcher")

local _vanilla_recipes = {}
do
    local cookbook_recipes = cooking.cookbook_recipes
    if cookbook_recipes then
        for _, cat in ipairs({"cookpot", "portablecookpot"}) do
            local recipes = cookbook_recipes[cat]
            if recipes then
                for prefab, _ in pairs(recipes) do
                    _vanilla_recipes[prefab] = true
                end
            end
        end
    end
end

local INGREDIENT_ALIASES = {
    cookedsmallmeat      = "smallmeat_cooked",
    cookedmonstermeat    = "monstermeat_cooked",
    cookedmeat           = "meat_cooked",
}

local CookbookData = Class(function(self)
    self.categories = {
        cookpot = {},
        portablecookpot = {},
        mod = {},
    }
    self.all = {}
    self._ingredient_aliases = INGREDIENT_ALIASES
    self._possible_cache = {}
end)

local function _ResolveFoodIcon(prefab, cookbook_tex, cookbook_atlas)
    local tex, atlas = ResolveIcon(prefab)
    if atlas then
        return tex, atlas
    end
    return cookbook_tex or (prefab .. ".tex"),
           cookbook_atlas or "images/inventoryimages/" .. prefab .. ".xml"
end

local function _BuildRecipeItem(prefab, recipe_def, category, extra)
    extra = extra or {}
    local name_key = string.upper(prefab)
    local name = STRINGS.NAMES[name_key]
    if name == nil or name == "" then
        name = prefab
    end

    local atlas_override = extra.atlas_override
    local food_tex, food_atlas = _ResolveFoodIcon(
        prefab,
        recipe_def.cookbook_tex,
        atlas_override or recipe_def.cookbook_atlas
    )

    local rd = recipe_def
    local has_buff = extra.has_buff
    if has_buff == nil then
        has_buff = (rd.temperature ~= nil and rd.temperature ~= 0)
            or rd.oneatenfn ~= nil
            or (rd.chargevalue ~= nil and rd.chargevalue ~= 0)
    end

    local item = {
        prefab      = prefab,
        name        = name,
        category    = category,
        recipe_def  = recipe_def,
        food_atlas  = food_atlas,
        food_tex    = food_tex,
        health      = recipe_def.health or 0,
        hunger      = recipe_def.hunger or 0,
        sanity      = recipe_def.sanity or 0,
        has_buff    = has_buff,
        defaultsorthash = hash(prefab),
        recipe_requirements = extra.recipe_requirements,
    }

    if extra.is_vanilla ~= nil then item.is_vanilla = extra.is_vanilla end
    if extra.is_brewer then item.is_brewer = true end
    if extra.is_myth then item.is_myth = true end

    return item
end

local function _ComputeMaxTagValues(ingredients)
    local max_vals = {}
    for name, data in pairs(ingredients) do
        if data.tags then
            for tag, val in pairs(data.tags) do
                local cur = max_vals[tag] or 0
                if val > cur then
                    max_vals[tag] = val
                end
            end
        end
    end
    return max_vals
end

local function _BuildMythRequirements(prefab, myth_recipes)
    if not myth_recipes or not myth_recipes[prefab] or not myth_recipes[prefab].recipe then
        return nil
    end
    local minnames = {}
    for ingredient, count in pairs(myth_recipes[prefab].recipe) do
        minnames[ingredient] = count
    end
    return { minnames = minnames, mintags = {}, maxtags = {} }
end

local function _by_hash(a, b)
    return a.defaultsorthash < b.defaultsorthash
end

local function _BuildRecipeRequirementsIndex(item)
    local req_types = {}
    local req_tags = {}
    local min_total = 0

    local reqs = item.recipe_requirements
    if reqs then
        if reqs.minnames then
            for name, amt in pairs(reqs.minnames) do
                req_types[name] = true
                min_total = min_total + amt
            end
        end
        if reqs.analog_groups then
            for _, group in ipairs(reqs.analog_groups) do
                local group_amount = group.amount or 1
                min_total = min_total + group_amount
                for _, gname in ipairs(group.names) do
                    req_types[gname] = true
                end
            end
        end
        if reqs.mintags then
            for tag, _ in pairs(reqs.mintags) do
                req_tags[tag] = true
            end
        end
    end

    item._required_types = req_types
    item._required_tags = req_tags
    item._min_total = min_total
end

function CookbookData:Collect()
    self.all = {}
    self._possible_cache = {}
    for cat, _ in pairs(self.categories) do
        self.categories[cat] = {}
    end

    local cookbook_recipes = cooking.cookbook_recipes
    if cookbook_recipes == nil then
        return self
    end

    local seen = {}
    for category, recipes in pairs(cookbook_recipes) do
        if self.categories[category] == nil then
            self.categories[category] = {}
        end

        for prefab, recipe_def in pairs(recipes) do
            if not recipe_def.no_cookbook and not seen[prefab] then
                seen[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, category, {
                    is_vanilla = _vanilla_recipes[prefab] or false,
                })

                if recipe_def.test ~= nil then
                    item.recipe_requirements = Detector.Detect(
                        recipe_def.test, cooking.ingredients
                    )
                end
                _BuildRecipeRequirementsIndex(item)

                table.insert(self.categories[category], item)
                table.insert(self.all, item)
            end
        end
    end

    self:PrecomputeMaxTagValues()

    self:_CollectBrewerRecipes()
    self:_CollectMythRecipes()
    self:_CollectXdRecipes()

    for _, list in pairs(self.categories) do
        table.sort(list, _by_hash)
    end
    table.sort(self.all, _by_hash)

    return self
end

function CookbookData:_CollectBrewerRecipes()
    local hof_brewing = _G.package.loaded["hof_brewing"]
    if not hof_brewing or not hof_brewing.brewbook_recipes then
        return
    end

    local brewingredients = hof_brewing.brewingredients
    if not brewingredients then
        return
    end

    self._brewer_max_tag_values = _ComputeMaxTagValues(brewingredients)

    local existing = {}
    for _, item in ipairs(self.all) do
        existing[item.prefab] = true
    end

    for category, recipes in pairs(hof_brewing.brewbook_recipes) do
        if self.categories[category] == nil then
            self.categories[category] = {}
        end

        for prefab, recipe_def in pairs(recipes) do
            if not recipe_def.no_brewbook and not existing[prefab] then
                existing[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, category, {
                    atlas_override = recipe_def.brewbook_atlas,
                    is_brewer = true,
                })

                if recipe_def.test ~= nil then
                    item.recipe_requirements = Detector.Detect(
                        recipe_def.test, brewingredients
                    )
                end
                _BuildRecipeRequirementsIndex(item)

                table.insert(self.categories[category], item)
                table.insert(self.categories["mod"], item)
                table.insert(self.all, item)
            end
        end
    end
end

function CookbookData:_CollectMythRecipes()
    if self._myth_collected then return end
    self._myth_collected = true

    local pill_refining = rawget(_G, "MYTH_PillRefining")

    if not pill_refining then
        return
    end

    if self.categories["alchmy_fur"] == nil then
        self.categories["alchmy_fur"] = {}
    end

    local existing = {}
    for _, item in ipairs(self.all) do
        existing[item.prefab] = true
    end

    local myth_recipes = _G.TUNING and _G.TUNING.MYTH_PILL_RECIPES

    if myth_recipes then
        for _, item in ipairs(self.all) do
            if item.recipe_requirements == nil then
                item.recipe_requirements = _BuildMythRequirements(item.prefab, myth_recipes)
                _BuildRecipeRequirementsIndex(item)
            end
        end
    end

    local function collect_from(source_table)
        if not source_table then return end
        for prefab, recipe_def in pairs(source_table) do
            if not existing[prefab] then
                existing[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, "alchmy_fur", {
                    has_buff = true,
                    is_vanilla = false,
                    is_myth = true,
                    recipe_requirements = _BuildMythRequirements(prefab, myth_recipes),
                })
                _BuildRecipeRequirementsIndex(item)

                table.insert(self.categories["alchmy_fur"], item)
                table.insert(self.categories["mod"], item)
                table.insert(self.all, item)
            end
        end
    end

    collect_from(pill_refining)
end

function CookbookData:_CollectXdRecipes()
    local xd_pill_recipes = _G.TUNING and _G.TUNING.XD_PILL_RECIPES
    if not xd_pill_recipes then
        return
    end

    local existing = {}
    for _, item in ipairs(self.all) do
        existing[item.prefab] = true
    end

    for device, recipes in pairs(xd_pill_recipes) do
        if self.categories[device] == nil then
            self.categories[device] = {}
        end

        for prefab, data in pairs(recipes) do
            if not existing[prefab] and data.recipe then
                existing[prefab] = true

                local minnames = {}
                for ingredient, count in pairs(data.recipe) do
                    minnames[ingredient] = count
                end

                -- 处理替代配方（alternative_recipe = {[1] = {trunk_summer=1, trunk_winter=1}}）
                local analog_groups = nil
                if data.alternative_recipe then
                    analog_groups = {}
                    for _, alt_group in pairs(data.alternative_recipe) do
                        local group = { names = {}, amount = 1 }
                        for ing_name, ing_count in pairs(alt_group) do
                            table.insert(group.names, ing_name)
                        end
                        if #group.names > 0 then
                            table.insert(analog_groups, group)
                        end
                    end
                    if #analog_groups == 0 then
                        analog_groups = nil
                    end
                end

                local reqs = {
                    minnames = minnames,
                    mintags = {},
                    maxtags = {},
                }
                if analog_groups then
                    reqs.analog_groups = analog_groups
                end

                local item = _BuildRecipeItem(prefab, {}, device, {
                    recipe_requirements = reqs,
                    has_buff = true,
                    is_vanilla = false,
                })
                _BuildRecipeRequirementsIndex(item)

                table.insert(self.categories[device], item)
                table.insert(self.categories["mod"], item)
                table.insert(self.all, item)
            end
        end
    end
end

function CookbookData:PrecomputeMaxTagValues()
    self._max_tag_values = _ComputeMaxTagValues(cooking.ingredients)
end

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

function CookbookData:GetPossibleRecipes(prefab_list, ingredients, max_slots, max_tag_values, counts, use_quantity_matching)
    if prefab_list == nil or #prefab_list == 0 then
        return nil
    end

    -- 缓存键：排序后的 prefab 列表 + 关键参数
    local cache_key = table.concat(prefab_list, ",") .. "|" .. (max_slots or 4) .. "|" .. (use_quantity_matching and "1" or "0")
    if counts then
        local ck = {}
        for k, v in pairs(counts) do table.insert(ck, k .. "=" .. v) end
        table.sort(ck)
        cache_key = cache_key .. "|" .. table.concat(ck, ",")
    end
    local cached = self._possible_cache[cache_key]
    if cached then
        return next(cached) and cached or nil
    end

    ingredients = ingredients or cooking.ingredients
    max_slots = max_slots or 4
    max_tag_values = max_tag_values or self._max_tag_values
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
    local names, tags = _BuildNamesTags(prefab_list, ingredients)
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
    for _, item in ipairs(self.all) do
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

    self._possible_cache[cache_key] = possible
    return next(possible) and possible or nil
end

function CookbookData:GetRecipeMatchScore(reqs, prefab_list, ingredients)
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

function CookbookData:GetMatchingRecipes(cooker, prefab_list, ingredients, counts)
    if prefab_list == nil or #prefab_list == 0 then
        return nil
    end

    local names, tags = _BuildNamesTags(prefab_list, ingredients)

    local matching = {}
    for _, item in ipairs(self.all) do
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

function CookbookData:GetMatchingRecipesFromCounts(cooker, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, pot_counts, use_quantity_matching)
    return ComboMatcher.Match(cooker, self.all, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, self._ingredient_aliases, pot_counts, use_quantity_matching)
end

function CookbookData:GetHighlightedRecipes(matching, cooker_recipes)
    if matching == nil then
        return nil
    end

    local by_priority = {}
    for _, item in ipairs(self.all) do
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

-- 为指定料理生成具体的食材组合 + 份数（用于弹窗"可做配方"视图）
function CookbookData:GetRecipeCraftableCombos(recipe_item, bag_counts, pot_counts, cooker, max_slots, use_quantity_matching, raw_bag_counts, sorted_defs)
    if not recipe_item or not bag_counts or next(bag_counts) == nil then
        return nil
    end

    -- 用 (料理 + bag + pot + raw_bag) 做缓存 key，输入不变时直接返回
    local cache_key = recipe_item.prefab .. "|"
    local keys = {}
    for k, v in pairs(bag_counts) do keys[#keys + 1] = "b" .. k .. "=" .. v end
    for k, v in pairs(pot_counts or {}) do keys[#keys + 1] = "p" .. k .. "=" .. v end
    for k, v in pairs(raw_bag_counts or {}) do keys[#keys + 1] = "r" .. k .. "=" .. v end
    table.sort(keys)
    cache_key = cache_key .. table.concat(keys, ";")
    if self._craft_combo_cache and self._craft_combo_cache[cache_key] then
        return self._craft_combo_cache[cache_key]
    end

    local reqs = recipe_item.recipe_requirements
    if not reqs then return nil end

    local ingredients = cooking.ingredients
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
        local names, tags = _BuildNamesTags(slot_list, ingredients)
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
        if sorted_defs then
            for _, entry in ipairs(sorted_defs) do
                if entry.def.test ~= nil then
                    local ok, ret = pcall(entry.def.test, cooker, names, tags)
                    if ok and ret then
                        return entry.prefab == recipe_prefab
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
            if not self._craft_combo_cache then self._craft_combo_cache = {} end
            local r = {{ ingredients = base, portions = 1 }}
            self._craft_combo_cache[cache_key] = r
            return r
        end
        if not self._craft_combo_cache then self._craft_combo_cache = {} end
        self._craft_combo_cache[cache_key] = nil
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
        if not self._craft_combo_cache then self._craft_combo_cache = {} end
        self._craft_combo_cache[cache_key] = nil
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

    if not self._craft_combo_cache then self._craft_combo_cache = {} end
    self._craft_combo_cache[cache_key] = #result > 0 and result or nil
    return self._craft_combo_cache[cache_key]
end

return CookbookData