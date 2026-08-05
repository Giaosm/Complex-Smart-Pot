-- 料理数据收集：原版食谱 + HOF 酿酒 + 神话炼丹 + 登仙炼丹
-- 所有收集函数操作同一个 db 实例，写入 db.categories / db.all
local cooking = require("cooking")
local Analyzer = require("data/recipe_requirement_analyzer")
local ResolveIcon = require("utils/resolveinventoryitemassets")

-- 原版料理集合（cookpot + portablecookpot 分类），用于标记 is_vanilla
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

local Collector = {}

-- 原版 + 官方"mod"分类食谱
local function CollectVanilla(db)
    local cookbook_recipes = cooking.cookbook_recipes
    if cookbook_recipes == nil then
        return false
    end

    local seen = {}
    for category, recipes in pairs(cookbook_recipes) do
        if db.categories[category] == nil then
            db.categories[category] = {}
        end

        for prefab, recipe_def in pairs(recipes) do
            if not recipe_def.no_cookbook and not seen[prefab] then
                seen[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, category, {
                    is_vanilla = _vanilla_recipes[prefab] or false,
                })

                if recipe_def.test ~= nil then
                    item.recipe_requirements = Analyzer.Analyze(
                        recipe_def.test, cooking.ingredients
                    )
                end
                Analyzer.BuildRequirementsIndex(item)

                table.insert(db.categories[category], item)
                table.insert(db.all, item)
            end
        end
    end
    return true
end

-- Heap of Foods 酿酒桶食谱；返回是否收集成功（模组存在且有数据）
function Collector.CollectBrewer(db)
    local hof_brewing = _G.package.loaded["hof_brewing"]
    if not hof_brewing or not hof_brewing.brewbook_recipes then
        return false
    end

    local brewingredients = hof_brewing.brewingredients
    if not brewingredients then
        return false
    end

    db._brewer_ingredients = brewingredients
    db._brewer_max_tag_values = _ComputeMaxTagValues(brewingredients)

    local existing = {}
    for _, item in ipairs(db.all) do
        existing[item.prefab] = true
    end

    for category, recipes in pairs(hof_brewing.brewbook_recipes) do
        if db.categories[category] == nil then
            db.categories[category] = {}
        end

        for prefab, recipe_def in pairs(recipes) do
            if not recipe_def.no_brewbook and not existing[prefab] then
                existing[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, category, {
                    atlas_override = recipe_def.brewbook_atlas,
                    is_brewer = true,
                })

                if recipe_def.test ~= nil then
                    item.recipe_requirements = Analyzer.Analyze(
                        recipe_def.test, brewingredients
                    )
                end
                Analyzer.BuildRequirementsIndex(item)

                table.insert(db.categories[category], item)
                table.insert(db.categories["mod"], item)
                table.insert(db.all, item)
            end
        end
    end
    return true
end

-- 神话书说炼丹炉食谱；返回是否成功（调用方只在成功时标记已收集，便于数据延迟就绪时重试）
function Collector.CollectMyth(db)
    local pill_refining = rawget(_G, "MYTH_PillRefining")
    if not pill_refining then
        return false
    end

    if db.categories["alchmy_fur"] == nil then
        db.categories["alchmy_fur"] = {}
    end

    local existing = {}
    for _, item in ipairs(db.all) do
        existing[item.prefab] = true
    end

    local myth_recipes = _G.TUNING and _G.TUNING.MYTH_PILL_RECIPES

    if myth_recipes then
        for _, item in ipairs(db.all) do
            if item.recipe_requirements == nil then
                item.recipe_requirements = _BuildMythRequirements(item.prefab, myth_recipes)
                Analyzer.BuildRequirementsIndex(item)
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
                Analyzer.BuildRequirementsIndex(item)

                table.insert(db.categories["alchmy_fur"], item)
                table.insert(db.categories["mod"], item)
                table.insert(db.all, item)
            end
        end
    end

    collect_from(pill_refining)
    return true
end

-- 登仙炼丹炉食谱；幂等（已收集的 prefab 会跳过），可反复调用以等待数据就绪
function Collector.CollectXd(db)
    local xd_pill_recipes = _G.TUNING and _G.TUNING.XD_PILL_RECIPES
    if not xd_pill_recipes then
        return false
    end

    local existing = {}
    for _, item in ipairs(db.all) do
        existing[item.prefab] = true
    end

    for device, recipes in pairs(xd_pill_recipes) do
        if db.categories[device] == nil then
            db.categories[device] = {}
        end

        for prefab, data in pairs(recipes) do
            if not existing[prefab] and data.recipe then
                existing[prefab] = true

                local minnames = {}
                for ingredient, count in pairs(data.recipe) do
                    minnames[ingredient] = count
                end

                -- 替代配方：同组内任意一个食材即可，数量取组内任意 count
                local analog_groups = nil
                if data.alternative_recipe then
                    analog_groups = {}
                    for _, alt_group in pairs(data.alternative_recipe) do
                        local group = { names = {}, amount = 1 }
                        local first_count = nil
                        for ing_name, ing_count in pairs(alt_group) do
                            table.insert(group.names, ing_name)
                            if first_count == nil then
                                first_count = ing_count
                            end
                        end
                        group.amount = first_count or 1
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
                Analyzer.BuildRequirementsIndex(item)

                table.insert(db.categories[device], item)
                table.insert(db.categories["mod"], item)
                table.insert(db.all, item)
            end
        end
    end
    return true
end

-- 神话食谱懒收集：成功才标记，允许重试
function Collector.EnsureMyth(db)
    if db._myth_collected then return end
    if Collector.CollectMyth(db) then
        db._myth_collected = true
    end
end

-- 全量收集入口：清空并重建 db 的全部数据
function Collector.CollectAll(db)
    db.all = {}
    for cat, _ in pairs(db.categories) do
        db.categories[cat] = {}
    end

    if not CollectVanilla(db) then
        return db
    end

    db._max_tag_values = _ComputeMaxTagValues(cooking.ingredients)

    Collector.CollectBrewer(db)
    Collector.EnsureMyth(db)
    Collector.CollectXd(db)

    for _, list in pairs(db.categories) do
        table.sort(list, _by_hash)
    end
    table.sort(db.all, _by_hash)

    return db
end

return Collector
