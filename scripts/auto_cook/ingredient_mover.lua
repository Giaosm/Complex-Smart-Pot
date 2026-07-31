-- 食材移动：在容器/背包/锅之间搬运食材；食材来源扫描统一由 inventory_scanner 提供
local GetStackSize = require("utils/getstacksize")
local Action = require("auto_cook/cooking_action")
local Scanner = require("inventory/inventory_scanner")

local PlayerInv = Action.PlayerInv
local GetSlotsFromAll = Scanner.GetSlotsFromAll

local function containerCanHas(invent, item)
    local num = invent:GetNumSlots()
    for i = 1, num do
        local slot_item = invent:GetItemInSlot(i)
        if not slot_item then
            return true
        end
        if slot_item.prefab == item.prefab and slot_item.skinname == item.skinname then
            if slot_item.replica and slot_item.replica.stackable and not slot_item.replica.stackable:IsFull() then
                return true
            end
        end
    end
end

local function CanTakeItem(item)
    local inv = PlayerInv()
    if not inv then return nil end

    local backpack = inv:GetEquippedItem(EQUIPSLOTS.BODY)
    if backpack then
        local bp_cont = backpack.replica and backpack.replica.container
        if bp_cont and containerCanHas(bp_cont, item) then
            return backpack
        end
    end

    if containerCanHas(inv, item) then
        return ThePlayer
    end

    return nil
end

local function MoveItemFromAllOfSlot(slot, srccontainer, destcontainer)
    if TheWorld and TheWorld.ismastersim then
        local container = srccontainer.replica and (srccontainer.replica.container or srccontainer.replica.inventory)
        if container then
            container:MoveItemFromAllOfSlot(slot, destcontainer)
        end
    else
        if srccontainer == ThePlayer then
            SendRPCToServer(RPC.MoveInvItemFromAllOfSlot, slot, destcontainer)
        else
            SendRPCToServer(RPC.MoveItemFromAllOfSlot, slot, srccontainer, destcontainer)
        end
    end
end

-- 按需求清单（prefab 数组）从各来源凑齐食材，返回槽位列表；数量不足返回 nil
local function CheckIng(data, auto_cook_source, notcont)
    local ing_data = {}
    for _, prefab in ipairs(data) do
        ing_data[prefab] = (ing_data[prefab] or 0) + 1
    end

    local slots = GetSlotsFromAll(auto_cook_source)
    local order_slots = {}

    for prefab, size_ing in pairs(ing_data) do
        for _, slot in ipairs(slots) do
            if slot.item and slot.item.prefab == prefab then
                if not (notcont and slot.cont == notcont) then
                    local size_slot = GetStackSize(slot.item)
                    local take = math.min(size_slot, size_ing)
                    for i = 1, take do
                        table.insert(order_slots, slot)
                    end
                    size_ing = size_ing - take
                    if size_ing <= 0 then break end
                end
            end
        end
    end

    if #order_slots == #data then
        return order_slots
    end
end

-- 同步锅内食材：移出多余食材、补齐缺失食材
local function SyncPotContents(container, cont, required, auto_cook_source)
    local items = container:GetItems() or {}
    local need = {}
    for _, p in ipairs(required) do
        need[p] = (need[p] or 0) + 1
    end

    for slot, item in pairs(items) do
        if item and item.prefab then
            local n = need[item.prefab] or 0
            if n > 0 then
                need[item.prefab] = n - 1
            else
                local dest = CanTakeItem(item)
                if not dest then return false end
                MoveItemFromAllOfSlot(slot, cont, dest)
                Sleep(0)
            end
        end
    end

    local missing = {}
    for prefab, count in pairs(need) do
        for _ = 1, count do
            table.insert(missing, prefab)
        end
    end
    if #missing == 0 then return true end

    local found = CheckIng(missing, auto_cook_source, cont)
    if not found then return false end
    for _, slot in ipairs(found) do
        MoveItemFromAllOfSlot(slot.slot, slot.cont, cont)
        Sleep(0)
    end
    return true
end

return {
    GetSlotsFromAll = GetSlotsFromAll,
    CanTakeItem = CanTakeItem,
    MoveItemFromAllOfSlot = MoveItemFromAllOfSlot,
    CheckIng = CheckIng,
    SyncPotContents = SyncPotContents,
}
