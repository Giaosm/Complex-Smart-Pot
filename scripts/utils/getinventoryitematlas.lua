-- 物品图标解析：根据物品 prefab 返回对应的图集和纹理
return function(item)
  if TheSim:GetGameID() == "DST" or IsDLCEnabled(PORKLAND_DLC) then
    return GetInventoryItemAtlas(item)
  end
  return resolvefilepath("images/inventoryimages.xml")
end
