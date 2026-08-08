-- 料理数据总线（facade）：组合收集/分析/匹配/组合生成各子模块，对外提供统一接口
-- 调用方（RecipePanel 等）的接口保持与本类一致，子模块拆分对 UI 透明
local Collector = require("data/recipe_data_collector")
local Matcher = require("data/recipe_matcher")
local ComboGen = require("data/craftable_combo_generator")
local ComboMatcher = require("data/combo_matcher")
local INGREDIENT_ALIASES = require("data/ingredient_aliases")

local CookbookData = Class(function(self)
    self.categories = {
        cookpot = {},
        portablecookpot = {},
        mod = {},
    }
    self.all = {}
    self._ingredient_aliases = INGREDIENT_ALIASES
    -- 以下字段由收集器在 Collect 过程中填充：
    --   _max_tag_values / _brewer_max_tag_values / _brewer_ingredients / _myth_collected
end)

function CookbookData:Collect()
    Matcher.ClearCache()
    ComboGen.ClearCache()
    Collector.CollectAll(self)
    return self
end

-- 环境变化：只局部刷新受环境影响的料理（重新反推配方），不清缓存、不重建其他料理
function CookbookData:RefreshEnvironmentLocked()
    return Collector.RefreshEnvironmentLocked(self)
end

-- 当前食材组合是否可能涉及环境料理（用于匹配缓存 key 决定是否纳入环境指纹）
function CookbookData:HasEnvironmentTypes(bag_counts, fixed_counts, pot_counts)
    return Collector.HasEnvironmentTypes(self, bag_counts, fixed_counts, pot_counts)
end

function CookbookData:GetIngredientAliases()
    return self._ingredient_aliases
end

function CookbookData:GetMaxTagValues(device)
    if device == "brewer" then
        return self._brewer_max_tag_values
    end
    return self._max_tag_values
end

-- 神话/登仙数据可能延迟就绪，UI 打开对应设备时补收集
function CookbookData:EnsureCollected(device)
    if device == "alchmy_fur" then
        Collector.EnsureMyth(self)
    else
        Collector.CollectXd(self)
    end
end

-- 兼容旧调用（UI 直接调用私有收集方法的历史接口）
function CookbookData:_CollectMythRecipes()
    self:EnsureCollected("alchmy_fur")
end

function CookbookData:_CollectXdRecipes()
    Collector.CollectXd(self)
end

function CookbookData:GetPossibleRecipes(prefab_list, ingredients, max_slots, max_tag_values, counts, use_quantity_matching)
    return Matcher.GetPossibleRecipes(self, prefab_list, ingredients, max_slots, max_tag_values, counts, use_quantity_matching)
end

function CookbookData:GetRecipeMatchScore(reqs, prefab_list, ingredients)
    return Matcher.GetRecipeMatchScore(reqs, prefab_list, ingredients)
end

function CookbookData:GetMatchingRecipes(cooker, prefab_list, ingredients, counts)
    return Matcher.GetMatchingRecipes(self, cooker, prefab_list, ingredients, counts)
end

function CookbookData:GetMatchingRecipesFromCounts(cooker, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, pot_counts, use_quantity_matching)
    return Matcher.GetMatchingRecipesFromCounts(self, cooker, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, pot_counts, use_quantity_matching)
end

function CookbookData:GetHighlightedRecipes(matching, cooker_recipes)
    return Matcher.GetHighlightedRecipes(self, matching, cooker_recipes)
end

function CookbookData:GetRecipeCraftableCombos(recipe_item, bag_counts, pot_counts, cooker, max_slots, use_quantity_matching, raw_bag_counts, sorted_defs)
    return ComboGen.GetRecipeCraftableCombos(self, recipe_item, bag_counts, pot_counts, cooker, max_slots, use_quantity_matching, raw_bag_counts, sorted_defs)
end

-- 方案A：分片匹配任务（透传到底层 ComboMatcher）
function CookbookData:ShouldUseMatchTask(bag_counts, fixed_counts, max_slots, use_quantity_matching)
    return ComboMatcher.ShouldUseTask(bag_counts, fixed_counts, max_slots, use_quantity_matching)
end

-- 分片匹配缓存读写（与同步匹配共用缓存，避免每次开锅/库存变化都重算）
function CookbookData:GetCachedMatch(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
    return ComboMatcher.GetCachedMatch(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
end

function CookbookData:CacheMatch(result, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, combos_map, complete, has_env, result_env, env_combos_map)
    ComboMatcher.CacheMatch(result, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, combos_map, complete, has_env, result_env, env_combos_map)
end

function CookbookData:GetCachedCombosMap(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
    return ComboMatcher.GetCachedCombosMap(bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, has_env)
end

function CookbookData:CacheCombosMap(combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete, has_env)
    ComboMatcher.CacheCombosMap(combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete, has_env)
end

function CookbookData:CacheEnvCombosMap(env_combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete)
    ComboMatcher.CacheEnvCombosMap(env_combos_map, bag_counts, fixed_counts, pot_counts, cooker_recipes, max_slots, use_quantity_matching, complete)
end

function CookbookData:GetRecipesFromCombosMap(cache_entry)
    return ComboMatcher.GetRecipesFromCombosMap(cache_entry)
end

function CookbookData:LogCacheStats()
    ComboMatcher.LogCacheStats()
end

function CookbookData:CreateMatchTask(cooker, bag_counts, fixed_counts, cooker_recipes, max_slots, ingredients, pot_counts, use_quantity_matching)
    return ComboMatcher.CreateMatchTask(
        cooker, self.all, bag_counts, fixed_counts, cooker_recipes, max_slots,
        ingredients, self._ingredient_aliases, pot_counts, use_quantity_matching
    )
end

return CookbookData
