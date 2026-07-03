-- 资源验证：检查纹理和图集文件是否存在，不存在的回退到 unknown.tex
local UNKNOWN_TEX = "unknown.tex"
local UNKNOWN_ATLAS = resolvefilepath_soft("images/food_tags.xml")

return function(item_tex, atlas, localized_name)
  if atlas and TheSim:AtlasContains(atlas, item_tex) then
    return item_tex, resolvefilepath(atlas), localized_name
  else
    return UNKNOWN_TEX, UNKNOWN_ATLAS, localized_name
  end
end
