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

function CookbookData:Collect()
    self.all = {}
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

                table.insert(self.categories[category], item)
                table.insert(self.all, item)
            end
        end
    end

    self:PrecomputeMaxTagValues()

    self:_CollectBrewerRecipes()
    self:_CollectMythRecipes()

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

                table.insert(self.categories["alchmy_fur"], item)
                table.insert(self.categories["mod"], item)
                table.insert(self.all, item)
            end
        end
    end

    collect_from(pill_refining)
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

function CookbookData:GetPossibleRecipes(prefab_list, ingredients, max_slots, max_tag_values)
    if prefab_list == nil or #prefab_list == 0 then
        return nil
    end

    ingredients = ingredients or cooking.ingredients
    max_slots = max_slots or 4
    max_tag_values = max_tag_values or self._max_tag_values
    local remaining_slots = max_slots - #prefab_list
    local names, tags = _BuildNamesTags(prefab_list, ingredients)

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
                ok = _CheckMinRequirements(reqs, resolved, tags, remaining_slots, max_tag_values, ingredients, max_slots)
            end
            if ok then
                possible[item.prefab] = true
            end
        else
            possible[item.prefab] = true
        end
    end

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

function CookbookData:GetMatchingRecipes(cooker, prefab_list, ingredients)
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
                if (names[name] or 0) < count then
                    ok = false
                    break
                end
            end
            if ok then
                matching[item.prefab] = true
            end
        end
    end

    return next(matching) and matching or nil
end

function CookbookData:GetMatchingRecipesFromCounts(cooker, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients)
    return ComboMatcher.Match(cooker, self.all, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, self._ingredient_aliases)
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

return CookbookData