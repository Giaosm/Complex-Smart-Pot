-- 食物标签图标解析：验证并返回标签图标的有效资源
local SanitizeAssets = require "utils/sanitizeassets"
local ResolveInventoryItemAssets = require "utils/resolveinventoryitemassets"

return function(foodTag)
  local tagData = FOODTAGDEFINITIONS[foodTag] or {}

  local item_tex = tagData.tex or foodTag..'.tex'
  local atlas = tagData.atlas and resolvefilepath(tagData.atlas) or nil
  local localized_name = STRINGS.NAMES[string.upper(foodTag)] or GetLocalizedFoodTagName(foodTag)

  local result = {SanitizeAssets(item_tex, atlas, localized_name)}
  if result[1] == "unknown.tex" then
    item_tex, atlas, localized_name = ResolveInventoryItemAssets(foodTag)
    result = {SanitizeAssets(item_tex, atlas, localized_name)}
  end

  return result[1], result[2], result[3]
end
