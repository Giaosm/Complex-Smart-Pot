-- 食物图标图集：注册和查询食物图标资源
global("RegisterFoodAtlas")
global("GetFoodAtlas")
local FoodAtlasLookup = {}
function RegisterFoodAtlas(prefab, imagename, atlasname)
  if prefab ~= nil and atlasname ~= nil and imagename ~= nil then
    if FoodAtlasLookup[prefab] ~= nil then
      return
    end
    FoodAtlasLookup[prefab] = {imagename, atlasname}
  end
end
function GetFoodAtlas(prefab)
  local lookup = FoodAtlasLookup[prefab]
  if lookup then return unpack(lookup) end
  return nil, nil
end
