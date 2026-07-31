-- 食材扫描：面板「可做」检测与自动做饭取货共用的库存/容器扫描
-- 注意：两种用途在各来源模式下的语义存在差异（如 ScanForAutoCook 的 "inv" 实际包含背包），
-- 逐条对照见 重构待办.md 第六节行为矩阵，当前保持现状未做行为修正
local cooking = require("cooking")
local GetStackSize = require("utils/getstacksize")

local function PlayerInv()
    return ThePlayer and ThePlayer.replica and ThePlayer.replica.inventory
end

local Scanner = {}

-- 基础计数（单个物品表），结果累计进 bag_counts（按 max_per_type 截断）与 raw_counts（原始数量）
function Scanner.CountIngredients(items, max_per_type, device_ingredients, bag_counts, raw_counts)
    if not items then return end
    device_ingredients = device_ingredients or cooking.ingredients
    bag_counts = bag_counts or {}

    for _, item in pairs(items) do
        if item and item.prefab and device_ingredients[item.prefab] then
            local count = GetStackSize(item)
            bag_counts[item.prefab] = math.min((bag_counts[item.prefab] or 0) + count, max_per_type)
            if raw_counts ~= nil then
                raw_counts[item.prefab] = (raw_counts[item.prefab] or 0) + count
            end
        end
    end
    return bag_counts
end

-- 面板「可做」检测扫描（ScanForCraftCheck）：
-- 按模式从物品栏 + 手持 + 打开容器中统计食材，返回 (截断计数表, 原始计数表)
-- mode: inv / backpack_and_inv / all / fridge / fridge_and_inv
-- exclude_container: 当前打开的烹饪锅本身（其内容走锅槽监听，不在此重复统计）
function Scanner.CountIngredientsForMode(player_inst, mode, max_per_type, device_ingredients, exclude_container)
    local bag_counts = {}
    local raw_counts = {}
    local inv = player_inst and player_inst.replica and player_inst.replica.inventory
    if not inv then return bag_counts, raw_counts end

    if mode ~= "fridge" then
        bag_counts = Scanner.CountIngredients(inv:GetItems(), max_per_type, device_ingredients, nil, raw_counts) or {}
    end

    local active_item = inv:GetActiveItem()
    if active_item and active_item.prefab and device_ingredients and device_ingredients[active_item.prefab] then
        local count = GetStackSize(active_item)
        bag_counts[active_item.prefab] = math.min((bag_counts[active_item.prefab] or 0) + count, max_per_type)
        raw_counts[active_item.prefab] = (raw_counts[active_item.prefab] or 0) + count
    end

    local open_containers = inv:GetOpenContainers() or {}
    for container_inst, _ in pairs(open_containers) do
        if container_inst ~= exclude_container then
            local container = container_inst.replica and container_inst.replica.container
            if container then
                local is_backpack = container_inst:HasTag("INLIMBO")
                local is_fridge = container_inst.prefab == "icebox" or container_inst.prefab == "saltbox"

                local should_scan = false
                if mode == "backpack_and_inv" then
                    should_scan = is_backpack
                elseif mode == "all" then
                    should_scan = true
                elseif mode == "fridge" or mode == "fridge_and_inv" then
                    should_scan = is_fridge
                end

                if should_scan then
                    Scanner.CountIngredients(container:GetItems(), max_per_type, device_ingredients, bag_counts, raw_counts)
                end
            end
        end
    end

    return bag_counts, raw_counts
end

-- 自动做饭取货扫描（ScanForAutoCook）：按来源模式列出全部可取食材的槽位列表
-- 返回 { { slot =, cont =, item = }, ... }
local function ShouldScanContainer(container_inst, source)
    if source == "inv" then return false end
    local is_fridge = container_inst.prefab == "icebox" or container_inst.prefab == "saltbox"
    if source == "fridge" or source == "fridge_and_inv" then return is_fridge end
    return true
end

local function GetOpenContainerSlots(inv, source)
    local slots = {}
    local backpack = inv:GetEquippedItem(EQUIPSLOTS.BODY)
    local open_conts = inv:GetOpenContainers() or {}
    for cont_inst, _ in pairs(open_conts) do
        if cont_inst ~= backpack and ShouldScanContainer(cont_inst, source) then
            local container = cont_inst.replica and cont_inst.replica.container
            if container then
                for i = 1, container:GetNumSlots() do
                    local item = container:GetItemInSlot(i)
                    if item then
                        table.insert(slots, { slot = i, cont = cont_inst, item = item })
                    end
                end
            end
        end
    end
    return slots
end

function Scanner.GetSlotsFromAll(source)
    source = source or "inv"
    local slots = {}

    local inv = PlayerInv()
    if not inv then return slots end

    if source ~= "inv" then
        local open_slots = GetOpenContainerSlots(inv, source)
        for _, s in ipairs(open_slots) do table.insert(slots, s) end
    end

    if source ~= "fridge" then
        local backpack = inv:GetEquippedItem(EQUIPSLOTS.BODY)
        if backpack then
            local bp_cont = backpack.replica and backpack.replica.container
            if bp_cont then
                for i = 1, bp_cont:GetNumSlots() do
                    local item = bp_cont:GetItemInSlot(i)
                    if item then
                        table.insert(slots, { slot = i, cont = backpack, item = item })
                    end
                end
            end
        end
    end

    if source ~= "fridge" then
        for i = 1, inv:GetNumSlots() do
            local item = inv:GetItemInSlot(i)
            if item then
                table.insert(slots, { slot = i, cont = ThePlayer, item = item })
            end
        end
    end

    return slots
end

return Scanner
