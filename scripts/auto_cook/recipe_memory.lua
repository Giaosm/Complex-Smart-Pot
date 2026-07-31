-- 配方记忆存储：全局单例，负责持久化（TheSim:GetSetting/SetSetting）与记忆数据读写
-- setter 只改内存数据，需显式调 Save() 落盘；Clear() 会自行落盘
local SETTING_SECTION = "complex_smart_pot"
local SETTING_KEY = "memory"
local SLOT_COUNT = 5

local PANEL_PREFS_DEFAULT = { category = "all", sort_id = nil, sort_state = 0 }

local MemoryStore = { _data = nil }

-- 规范化记忆表：兼容旧格式（直接存食材数组）与 json 反序列化后的字符串键
local function NormalizeRecipeMap(recipe_map)
    local out = {}
    if type(recipe_map) ~= "table" then return out end
    for recipe_name, mem in pairs(recipe_map) do
        if type(mem) == "table" then
            if mem.slots then
                local new_mem = { slots = {}, selected = mem.selected or 1 }
                for i, slot_data in pairs(mem.slots) do
                    if type(slot_data) == "table" and type(slot_data.ingredients) == "table" then
                        new_mem.slots[tonumber(i) or i] = {
                            ingredients = slot_data.ingredients,
                            use_quantity = slot_data.use_quantity,
                        }
                    end
                end
                out[recipe_name] = new_mem
            elseif type(mem[1]) == "string" then
                out[recipe_name] = {
                    slots = { [1] = { ingredients = mem } },
                    selected = 1,
                }
            end
        end
    end
    return out
end

function MemoryStore.Load()
    local str = TheSim:GetSetting(SETTING_SECTION, SETTING_KEY)
    local data
    if str and str ~= "" then
        local ok, decoded = pcall(json.decode, str)
        if ok and type(decoded) == "table" then
            data = decoded
        end
    end
    data = data or {}
    data._recipe_memories = NormalizeRecipeMap(data._recipe_memories)
    MemoryStore._data = data
    return data
end

function MemoryStore.Save()
    local d = MemoryStore._data
    if not d then return end
    local ok, str = pcall(json.encode, d)
    if ok then
        TheSim:SetSetting(SETTING_SECTION, SETTING_KEY, str)
    end
end

local function Data()
    if not MemoryStore._data then
        MemoryStore.Load()
    end
    return MemoryStore._data
end

function MemoryStore.GetOrCreatePanelPrefs()
    local d = Data()
    if type(d._panel_prefs) ~= "table" then
        d._panel_prefs = { category = PANEL_PREFS_DEFAULT.category, sort_id = PANEL_PREFS_DEFAULT.sort_id, sort_state = PANEL_PREFS_DEFAULT.sort_state }
    end
    return d._panel_prefs
end

function MemoryStore.GetRangeSearch(default)
    return Data()._range_search or default
end

function MemoryStore.SetRangeSearch(v)
    Data()._range_search = v
end

function MemoryStore.GetActiveRecipe()
    return Data()._active_recipe
end

function MemoryStore.SetActiveRecipe(name)
    Data()._active_recipe = name
end

function MemoryStore.GetOrCreateMem(recipe_name)
    local map = Data()._recipe_memories
    local mem = map[recipe_name]
    if not mem then
        mem = { slots = {}, selected = 1 }
        map[recipe_name] = mem
    end
    return mem
end

function MemoryStore.GetMem(recipe_name)
    if not recipe_name then return nil end
    return Data()._recipe_memories[recipe_name]
end

-- 清空全部配方记忆并立即落盘
function MemoryStore.Clear()
    local d = Data()
    d._recipe_memories = {}
    d._active_recipe = nil
    MemoryStore.Save()
end

MemoryStore.SLOT_COUNT = SLOT_COUNT

return MemoryStore
