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

-- 收集辅助：确保分类表存在
local function _EnsureCategory(db, category)
    if db.categories[category] == nil then
        db.categories[category] = {}
    end
    return db.categories[category]
end

-- 收集辅助：构建以现有 prefab 为 key 的去重表
local function _BuildExisting(db)
    local existing = {}
    for _, item in ipairs(db.all) do
        existing[item.prefab] = true
    end
    return existing
end

-- 收集辅助：把条目写入 分类表 + mod 分类 + 总表
-- 原版食谱不归入 mod 分类，通过 with_mod=false 控制
local function _InsertItem(db, category, item, with_mod)
    table.insert(db.categories[category], item)
    if with_mod ~= false then
        table.insert(db.categories["mod"], item)
    end
    table.insert(db.all, item)
end

-- 收集辅助：分析 test 并建索引（无 test 则仅建索引）
local function _BuildRequirements(db, item, test, ingredients)
    if test ~= nil then
        item.recipe_requirements = Analyzer.Analyze(test, ingredients)
    end
    Analyzer.BuildRequirementsIndex(item)
    return item
end

-- 香脆松子模组的季节料理 prefab 名单（受环境影响，配方随季节变化）
-- 仅当"季节料理随时可做"（TUNING.SEASONAL_FOOD）关闭时才视为受环境限制
local _CRISPY_NUTS_SEASONAL = {
    nuts_dumpling = true,          -- 春季
    nuts_mungbean_soup = true,     -- 夏季
    nuts_sweetpotato_soup = true,  -- 冬季
    nuts_mistypine = true,         -- 秋季
    nuts_osmanthus = true,         -- 秋季（需棱镜mod）
    nuts_osmanthus2 = true,        -- 秋季（深拷贝）
}

-- 环境料理硬编码完整配方表（照抄两模组源码 test，去掉环境条件，仅保留食材/tag 需求）。
-- 用于 HasEnvironmentTypes 判断当前食材是否"完整满足"某环境料理配方；完整满足才带环境指纹，
-- 避免蜂蜜/冰块等常见食材被误判导致缓存频繁失效。判断按保守 >= 比较（names_eq 亦同）。
-- 字段：dim 环境维度(season/moon/season+moon)；names/names_eq 具体食材(>=)；names_or 二选一；
--       tags 标签(>=)。  棱镜：花=petals_legion 装饰=decoration 甜=sweetener 冰=frozen 怪=monster
-- 香脆松子：松果=pinecone。nuts_osmanthus2 为 osmanthus 深拷贝，配方相同，只留一份。
local _ENV_RECIPES = {
    -- 月饼
    { dim = "season+moon", tags = { petals_legion = 2, decoration = 1, sweetener = 1 } },
    -- 花儿粑
    { dim = "moon", tags = { petals_legion = 2, decoration = 1, sweetener = 1 } },
    -- 月酿
    { dim = "season+moon", tags = { petals_legion = 2, decoration = 1, frozen = 1 } },
    -- 花儿酒
    { dim = "moon", tags = { petals_legion = 2, decoration = 1, frozen = 1 } },
    -- 临别的纸杯蛋糕
    { dim = "moon", names_or = { { "red_cap", "red_cap_cooked" } }, tags = { monster = 1, decoration = 1 } },
    -- 松香饺子(春)
    { dim = "season", names = { pinecone = 1, corn = 1, carrot = 1 }, tags = { meat = 1 } },
    -- 绿豆汤(夏)
    { dim = "season", names = { pinecone = 1 }, names_eq = { watermelon = 2 }, tags = { frozen = 1 } },
    -- 红薯糖水(冬)
    { dim = "season", names = { pinecone = 1, carrot = 1 }, names_eq = { pumpkin = 2 } },
    -- 松间云雾奶茶(秋)
    { dim = "season", names = { pinecone = 1 }, names_eq = { pumpkin = 2 }, tags = { sweetener = 1 } },
    -- 桂馥兰香奶茶(秋) 及其深拷贝
    { dim = "season", names = { pinecone = 1 }, names_or = { { "pumpkin", "pumpkin_cooked" } }, names_eq = { petals_orchid = 1 }, tags = { sweetener = 1 } },
}

-- 解析料理受环境影响维度：season/moon/season+moon；nil 表示非环境料理。
-- 不依赖 KnownModIndex（打标时机早于模组启用表加载），料理能进 db.all 即说明对应模组已启用。
local function _EnvironmentDimension(item)
    local rd = item.recipe_def
    -- 棱镜：cook_cant 含"专属"即为环境料理
    if rd and rd.cook_cant and type(rd.cook_cant) == "string" and rd.cook_cant:find("专属") then
        local cant = rd.cook_cant
        if cant:find("秋季满月") then return "season+moon" end
        -- 满月/新月天专属视为仅月相
        if cant:find("满月") or cant:find("新月") then return "moon" end
        return "season+moon"  -- 其它"专属"保守归为季节+月相，宁可多刷新
    end
    -- 香脆松子：季节料理（关闭"随时可做"时才受限）
    if _CRISPY_NUTS_SEASONAL[item.prefab] then
        if _G.TUNING and _G.TUNING.SEASONAL_FOOD == true then return nil end
        return "season"
    end
    return nil
end

-- 判断料理是否受环境影响（等价于 _EnvironmentDimension 非 nil）
local function _IsEnvironmentLocked(item)
    return _EnvironmentDimension(item) ~= nil
end

-- 判断食材(names/tags)是否"完整满足"环境料理配方 rec；names/names_eq 按 >=，names_or 任一生/熟其一 >=1
local function _EnvRecipeMatches(names, tags, rec)
    if rec.names then
        for ing, need in pairs(rec.names) do
            if (names[ing] or 0) < need then
                return false
            end
        end
    end
    if rec.names_eq then
        for ing, need in pairs(rec.names_eq) do
            if (names[ing] or 0) < need then
                return false
            end
        end
    end
    if rec.names_or then
        for _, group in ipairs(rec.names_or) do
            local ok = false
            for _, ing in ipairs(group) do
                if (names[ing] or 0) >= 1 then
                    ok = true
                    break
                end
            end
            if not ok then
                return false
            end
        end
    end
    if rec.tags then
        for tag, need in pairs(rec.tags) do
            if (tags[tag] or 0) < need then
                return false
            end
        end
    end
    return true
end

-- 将当前食材计数(bag/fixed/pot)合并为 names/tags，用于环境料理配方匹配
local function _CountsToNamesTags(bag_counts, fixed_counts, pot_counts, ingredients)
    local names = {}
    local tags = {}
    local function add(counts)
        for ing, n in pairs(counts or {}) do
            names[ing] = (names[ing] or 0) + n
            local data = ingredients[ing]
            if data and data.tags then
                for tag in pairs(data.tags) do
                    tags[tag] = (tags[tag] or 0) + n
                end
            end
        end
    end
    add(bag_counts)
    add(fixed_counts)
    add(pot_counts)
    return names, tags
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
        _EnsureCategory(db, category)
        for prefab, recipe_def in pairs(recipes) do
            if not recipe_def.no_cookbook and not seen[prefab] then
                seen[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, category, {
                    is_vanilla = _vanilla_recipes[prefab] or false,
                })
                _BuildRequirements(db, item, recipe_def.test, cooking.ingredients)
                _InsertItem(db, category, item, false)
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

    local existing = _BuildExisting(db)
    for category, recipes in pairs(hof_brewing.brewbook_recipes) do
        _EnsureCategory(db, category)
        for prefab, recipe_def in pairs(recipes) do
            if not recipe_def.no_brewbook and not existing[prefab] then
                existing[prefab] = true
                local item = _BuildRecipeItem(prefab, recipe_def, category, {
                    atlas_override = recipe_def.brewbook_atlas,
                    is_brewer = true,
                })
                _BuildRequirements(db, item, recipe_def.test, brewingredients)
                _InsertItem(db, category, item)
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

    _EnsureCategory(db, "alchmy_fur")
    local existing = _BuildExisting(db)

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
                _InsertItem(db, "alchmy_fur", item)
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

    local existing = _BuildExisting(db)
    for device, recipes in pairs(xd_pill_recipes) do
        _EnsureCategory(db, device)
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
                _InsertItem(db, device, item)
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

    -- 统一清空所有标志位与辅助数据，确保每次全量重建、不留旧值
    db._max_tag_values = nil
    db._brewer_max_tag_values = nil
    db._brewer_ingredients = nil
    db._myth_collected = nil

    if not CollectVanilla(db) then
        return db
    end

    db._max_tag_values = _ComputeMaxTagValues(cooking.ingredients)

    Collector.CollectBrewer(db)
    Collector.EnsureMyth(db)
    Collector.CollectXd(db)

    -- 为环境料理打标（is_environment_locked / env_dim）
    -- 供"单料理级"缓存（craftable_combo_generator）按维度取指纹用；
    -- 整锅级缓存是否涉及环境料理，由 HasEnvironmentTypes 用硬编码配方表实时判断，无需这些字段。
    for _, item in ipairs(db.all) do
        item.is_environment_locked = false
        item.env_dim = nil
        local dim = _EnvironmentDimension(item)
        if dim then
            item.is_environment_locked = true
            item.env_dim = dim
        end
    end

    for _, list in pairs(db.categories) do
        table.sort(list, _by_hash)
    end
    table.sort(db.all, _by_hash)

    return db
end

-- 环境变化：局部刷新受环境影响的料理（重新反推配方），不清缓存、不重建其他料理
-- 返回刷新了多少个料理
function Collector.RefreshEnvironmentLocked(db)
    local refreshed = 0
    for _, item in ipairs(db.all) do
        if _IsEnvironmentLocked(item) then
            local test = item.recipe_def and item.recipe_def.test
            if test ~= nil then
                item.recipe_requirements = Analyzer.Analyze(test, db._brewer_ingredients or cooking.ingredients)
            else
                item.recipe_requirements = nil
            end
            Analyzer.BuildRequirementsIndex(item)
            refreshed = refreshed + 1
        end
    end
    return refreshed
end

-- 判断给定食材(names/tags)是否满足任一环境料理配方，返回其环境维度集合（去重）
-- 返回 nil 表示普通组合（不涉及任何环境料理），否则返回字符串集合 { [dim]=true }
-- 供匹配枚举时区分"普通组合 / 环境组合"，环境组合的映射需按维度指纹缓存
function Collector.IsEnvCombination(names, tags)
    if not _ENV_RECIPES or #_ENV_RECIPES == 0 then
        return nil
    end
    local dims
    for _, rec in ipairs(_ENV_RECIPES) do
        if _EnvRecipeMatches(names, tags, rec) then
            if dims == nil then dims = {} end
            dims[rec.dim] = true
        end
    end
    return dims
end

-- 判断当前食材组合（bag/fixed/pot）是否可能涉及任何环境料理
-- 供整份背包状态快速判断；详见 Collector.IsEnvCombination
function Collector.HasEnvironmentTypes(db, bag_counts, fixed_counts, pot_counts)
    local ingredients = cooking.ingredients
    local names, tags = _CountsToNamesTags(bag_counts, fixed_counts, pot_counts, ingredients)
    return Collector.IsEnvCombination(names, tags) ~= nil
end

return Collector
