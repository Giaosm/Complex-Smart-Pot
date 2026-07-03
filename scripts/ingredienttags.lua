global("FOODTAGDEFINITIONS")
FOODTAGDEFINITIONS = FOODTAGDEFINITIONS or {}

global("AddFoodTag")
AddFoodTag = function(tag, data)
  local mergedData = FOODTAGDEFINITIONS[tag] or {}

  for k, v in pairs(data) do
    mergedData[k] = v
  end

  FOODTAGDEFINITIONS[tag] = mergedData
end

AddFoodTag('meat', { name= 'Meats', name_cn='肉类', atlas="images/food_tags.xml" })
AddFoodTag('veggie', { name="Vegetables", name_cn='蔬菜', atlas="images/food_tags.xml" })
AddFoodTag('fish', { name="Fish", name_cn='鱼类', atlas="images/food_tags.xml" })
AddFoodTag('sweetener', { name="Sweets", name_cn='甜味剂', atlas="images/food_tags.xml" })

AddFoodTag('monster', { name="Monster Foods", name_cn='怪肉食材', atlas="images/food_tags.xml" })
AddFoodTag('fruit', { name="Fruits", name_cn='水果', atlas="images/food_tags.xml" })
AddFoodTag('egg', { name="Eggs", name_cn='蛋类', atlas="images/food_tags.xml" })
AddFoodTag('inedible', { name="Inedibles", name_cn='不可食用', tex="Inedible.tex", atlas="images/food_types.xml" })

AddFoodTag('frozen', { name="Ice", name_cn='冰块', atlas="images/food_tags.xml" })
AddFoodTag('magic', { name="Magic", name_cn='魔法食材', atlas="images/food_tags.xml" })
AddFoodTag('decoration', { name="Decoration", name_cn='装饰', atlas="images/food_tags.xml" })
AddFoodTag('seed', { name="Seeds", name_cn='种子', tex="seed_alt.tex", atlas="images/food_tags.xml" })

AddFoodTag('dairy', { name="Dairies", name_cn='乳制品', atlas="images/food_tags.xml" })
AddFoodTag('fat', { name="Fat", name_cn='油脂', atlas="images/food_tags.xml" })

AddFoodTag('alkaline', { name="Alkaline", name_cn='碱性', atlas="images/food_tags.xml" })
AddFoodTag('flora', { name="Flora", name_cn='植物', atlas="images/food_tags.xml" })
AddFoodTag('fungus', { name="Fungi", name_cn='真菌', atlas="images/food_tags.xml" })
AddFoodTag('leek', { name="Leek", name_cn='韭葱', atlas="images/food_tags.xml" })
AddFoodTag('citrus', { name="Citrus", name_cn='柑橘', atlas="images/food_tags.xml" })

AddFoodTag('dairy_alt', { name="Dairy", name_cn='乳制品', atlas="images/food_tags.xml" })
AddFoodTag('fat_alt', { name="Fat", name_cn='油脂', atlas="images/food_tags.xml" })

AddFoodTag('mushrooms', { name="Mushrooms", name_cn='蘑菇', atlas="images/food_tags.xml" })
AddFoodTag('mogu', { name="Mushrooms", name_cn='蘑菇', tex="mushrooms.tex", atlas="images/food_tags.xml" })
AddFoodTag('nut', { name="Nuts", name_cn='坚果', atlas="images/food_tags.xml" })
AddFoodTag('poultry', { name="Poultries", name_cn='禽肉', atlas="images/food_tags.xml" })
AddFoodTag('pungent', { name="Pungents", name_cn='辛辣', atlas="images/food_tags.xml" })
AddFoodTag('grapes', { name="Grapes", name_cn='葡萄', atlas="images/food_tags.xml" })

AddFoodTag('decoration_alt', { name="Decoration", name_cn='装饰', atlas="images/food_tags.xml" })
AddFoodTag('seed_alt', { name="Seeds", name_cn='种子', atlas="images/food_tags.xml" })

AddFoodTag('root', { name="Roots", name_cn='根茎', atlas="images/food_tags.xml" })
AddFoodTag('seafood', { name="Seafood", name_cn='海鲜', atlas="images/food_tags.xml" })
AddFoodTag('shellfish', { name="Shellfish", name_cn='贝类', atlas="images/food_tags.xml" })
AddFoodTag('spices', { name="Spices", name_cn='香料', atlas="images/food_tags.xml" })
AddFoodTag('wings', { name="Wings", name_cn='翅膀', atlas="images/food_tags.xml" })

AddFoodTag('monster_alt', { name="Monster Foods", name_cn='怪肉食材', atlas="images/food_tags.xml" })
AddFoodTag('sweetener_alt', { name="Sweets", name_cn='甜味剂', atlas="images/food_tags.xml" })

AddFoodTag('squash', { name="Squash", name_cn='南瓜', atlas="images/food_tags.xml" })
AddFoodTag('starch', { name="Starch", name_cn='淀粉', atlas="images/food_tags.xml" })
AddFoodTag('tuber', { name="Tuber", name_cn='块茎', atlas="images/food_tags.xml" })
AddFoodTag('precook', { name="Precooked", name_cn='预制食材', atlas="images/food_tags.xml" })
AddFoodTag('cactus', { name="Cactus", name_cn='仙人掌', atlas="images/food_tags.xml" })

function GetLocalizedFoodTagName(tag)
    local data = FOODTAGDEFINITIONS[tag]
    if not data then return tag end

    local lang = Profile and Profile:GetLanguageID()
    if lang == LANGUAGE.CHINESE_S or lang == LANGUAGE.CHINESE_T or lang == LANGUAGE.CHINESE_S_RAIL then
        return data.name_cn or data.name or tag
    end
    return data.name or tag
end
