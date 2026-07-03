-- 食材图标解析：多策略解析（prefab资产→AllRecipes→Scrapbook→FoodAtlas），带缓存
local GetInventoryItemAtlas = require "utils/getinventoryitematlas"
local SanitizeAssets = require "utils/sanitizeassets"

local function TryResolveAtlas(atlas_path, tex_name)
  if not atlas_path or atlas_path == "FROMNUM" then return nil end
  local resolved = resolvefilepath_soft(atlas_path)
  if resolved and TheSim:AtlasContains(resolved, tex_name) then
    return resolved
  end
  if TheSim:AtlasContains(atlas_path, tex_name) then
    return atlas_path
  end
  return nil
end

local function ExtractFileName(path)
  if not path then return nil end
  local rev = string.reverse(path)
  local slash_pos = string.find(rev, "/")
  if slash_pos then
    return string.reverse(rev:sub(1, slash_pos - 1))
  end
  return path
end

local function TryPair(tex, atlas)
  local resolved = TryResolveAtlas(atlas, tex)
  if resolved then
    return tex, resolved
  end
  return nil, nil
end

local _icon_cache = {}

return function(prefab)
  local cached = _icon_cache[prefab]
  if cached then
    return cached[1], cached[2], cached[3]
  end

  if not Prefabs[prefab] then
    for _, entry in ipairs{
      {"_cooked", "cooked"},
      {"_dried",  "dried"},
      {"_inv",    ""},
    } do
      local suffix, prefix = entry[1], entry[2]
      local base = prefab:match("^(.+)" .. suffix .. "$")
      if base and Prefabs[prefix .. base] then
        prefab = prefix .. base
        break
      end
    end
  end
  local item_tex, atlas
  local localized_name = STRINGS.NAMES[string.upper(prefab)] or prefab
  local prefabData = Prefabs[prefab]

  do
    local tex = prefab .. ".tex"
    local alt = GetInventoryItemAtlas(tex)
    item_tex, atlas = TryPair(tex, alt)
    if not atlas then
      item_tex, atlas = TryPair(tex, "images/inventoryimages/" .. prefab .. ".xml")
    end
  end

  if not atlas and prefabData then
    local assets = prefabData.assets

    for _, asset in ipairs(assets) do
      if asset.type == "INV_IMAGE" then
        local tex = "quagmire_" .. asset.file .. ".tex"
        local alt = GetInventoryItemAtlas(tex)
        item_tex, atlas = TryPair(tex, alt)
        if atlas then break end
      end
    end

    if not atlas then
      for _, asset in ipairs(assets) do
        if asset.type == "INV_IMAGE" then
          local tex = asset.file .. ".tex"
          local alt = GetInventoryItemAtlas(tex)
          item_tex, atlas = TryPair(tex, alt)
        elseif asset.type == "ATLAS" then
          item_tex, atlas = TryPair(prefab .. ".tex", asset.file)
        elseif asset.type == "IMAGE" then
          local img_name = ExtractFileName(asset.file)
          if img_name then
            for _, a2 in ipairs(assets) do
              if a2.type == "ATLAS" then
                item_tex, atlas = TryPair(img_name, a2.file)
                if atlas then break end
              end
            end
          end
        end
        if atlas then break end
      end
    end

  end

  if not atlas and AllRecipes then
    local rd = AllRecipes[prefab]
    if rd and rd.image then
      local tex = rd.image
      local alt = rd.atlas or GetInventoryItemAtlas(tex)
      item_tex, atlas = TryPair(tex, alt)
    end
  end

  if not atlas then
    local tex = prefab .. ".tex"
    item_tex, atlas = TryPair(tex, GetScrapbookIconAtlas(tex))
  end

  if not atlas then
    local reg_img, reg_atlas = GetFoodAtlas(prefab)
    if reg_atlas then
      item_tex, atlas = TryPair(reg_img or prefab .. ".tex", reg_atlas)
    end
  end

  local result = {SanitizeAssets(item_tex, atlas, localized_name)}

  if result[1] == "unknown.tex" then
    local tagData = FOODTAGDEFINITIONS[prefab]
    if tagData then
      local tag_tex = tagData.tex or prefab .. ".tex"
      local tag_atlas = tagData.atlas and resolvefilepath(tagData.atlas) or nil
      result = {SanitizeAssets(tag_tex, tag_atlas, localized_name)}
    end
  end

  _icon_cache[prefab] = result
  return result[1], result[2], result[3]
end
