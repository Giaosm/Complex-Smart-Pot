return function(item)
  if TheSim:GetGameID() == "DST" or IsDLCEnabled(PORKLAND_DLC) then
    return GetInventoryItemAtlas(item)
  end
  return resolvefilepath("images/inventoryimages.xml")
end
