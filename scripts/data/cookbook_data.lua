-- 料理数据总线（facade）：组合收集/分析/匹配/组合生成各子模块，对外提供统一接口
-- 调用方（RecipePanel 等）的接口保持与本类一致，子模块拆分对 UI 透明
local Collector = require("data/recipe_data_collector")
local Matcher = require("data/recipe_matcher")
local ComboGen = require("data/craftable_combo_generator")
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

-- 公开接口：食材别名表
function CookbookData:GetIngredientAliases()
    return self._ingredient_aliases
end

-- 公开接口：设备对应的最大 tag 值表（device 传 "brewer" 取酿酒设备的）
function CookbookData:GetMaxTagValues(device)
    if device == "brewer" then
        return self._brewer_max_tag_values
    end
    return self._max_tag_values
end

-- 懒收集接口：神话/登仙的数据在 SimPostInit 时可能未就绪，UI 打开对应设备时调用
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

return CookbookData
