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

local function MoveItemFromCountOfSlot(slot, srccontainer, destcontainer, count)
    count = math.max(1, math.floor(count))
    if TheWorld and TheWorld.ismastersim then
        local container = srccontainer.replica and (srccontainer.replica.container or srccontainer.replica.inventory)
        if container then
            container:MoveItemFromCountOfSlot(slot, destcontainer, count)
        end
    else
        if srccontainer == ThePlayer then
            SendRPCToServer(RPC.MoveInvItemFromCountOfSlot, slot, destcontainer, count)
        else
            SendRPCToServer(RPC.MoveItemFromCountOfSlot, slot, srccontainer, destcontainer, count)
        end
    end
end

-- 按需求清单从各来源凑齐食材，返回槽位及数量列表；数量不足返回 nil
-- data 支持 prefab 数组或 {prefab = count} 数量表
local function CheckIng(data, auto_cook_source, notcont)
    local ing_data = {}
    if #data > 0 then
        for _, prefab in ipairs(data) do
            ing_data[prefab] = (ing_data[prefab] or 0) + 1
        end
    else
        for prefab, count in pairs(data) do
            ing_data[prefab] = count
        end
    end

    local total_need = 0
    for _, count in pairs(ing_data) do
        total_need = total_need + count
    end

    local slots = GetSlotsFromAll(auto_cook_source)
    local order_slots = {}

    for prefab, size_ing in pairs(ing_data) do
        for _, slot in ipairs(slots) do
            if slot.item and slot.item.prefab == prefab then
                if not (notcont and slot.cont == notcont) then
                    local size_slot = GetStackSize(slot.item)
                    local take = math.min(size_slot, size_ing)
                    table.insert(order_slots, {
                        slot = slot.slot,
                        cont = slot.cont,
                        item = slot.item,
                        count = take,
                    })
                    size_ing = size_ing - take
                    if size_ing <= 0 then break end
                end
            end
        end
    end

    local total_found = 0
    for _, slot in ipairs(order_slots) do
        total_found = total_found + slot.count
    end
    if total_found == total_need then
        return order_slots
    end
end

-- 同步锅内食材：移出多余食材、补齐缺失食材（支持堆叠设备按数量搬运）
-- required 支持 prefab 数组或 {prefab = count} 数量表
local function SyncPotContents(container, cont, required, auto_cook_source, cooker_prefab)
    local items = container:GetItems() or {}
    local need = {}
    if #required > 0 then
        for _, p in ipairs(required) do
            local name = type(p) == "table" and p.prefab or p
            need[name] = (need[name] or 0) + (type(p) == "table" and p.count or 1)
        end
    else
        for name, count in pairs(required) do
            if type(name) == "string" then
                need[name] = count
            end
        end
    end

    -- 判断是否"4槽可堆叠 cooker"（如 medal_cookpot）：这种锅需要每格只放 1 个并占满 4 槽，
    -- 因此判断锅里已有食材时也必须按"每格最多 1 个"保留，把堆叠拆开，否则锅无法占满、烹饪无法触发
    local accepts_stacks = container and container.AcceptsStacks ~= nil and container:AcceptsStacks()
    local ok_slots, num_slots = pcall(function() return container:GetNumSlots() end)
    local ok_type, cont_type = pcall(function() return container.type end)
    local is_stackable_four_slot_cooker = accepts_stacks
        and ok_slots and num_slots == 4
        and ok_type and cont_type == "cooker"

    for slot, item in pairs(items) do
        if item and item.prefab then
            local stack_size = GetStackSize(item)
            local n = need[item.prefab] or 0
            if n > 0 then
                -- 4槽可堆叠锅：每格最多保留 1 个（拆开堆叠占满格子）；其他锅按实际数量保留
                local keep_per_slot = is_stackable_four_slot_cooker and 1 or stack_size
                local keep = math.min(n, keep_per_slot)
                local excess = stack_size - keep
                need[item.prefab] = n - keep
                if excess > 0 then
                    local dest = CanTakeItem(item)
                    if not dest then return false end
                    MoveItemFromCountOfSlot(slot, cont, dest, excess)
                    Sleep(0)
                end
            else
                local dest = CanTakeItem(item)
                if not dest then return false end
                MoveItemFromCountOfSlot(slot, cont, dest, stack_size)
                Sleep(0)
            end
        end
    end

    local remaining = 0
    for _, count in pairs(need) do
        remaining = remaining + count
    end
    if remaining == 0 then return true end

    local found = CheckIng(need, auto_cook_source, cont)
    if not found then return false end

    if accepts_stacks and not is_stackable_four_slot_cooker then
        for _, slot in ipairs(found) do
            MoveItemFromCountOfSlot(slot.slot, slot.cont, cont, slot.count)
            Sleep(0)
        end
    else
        -- 普通锅/红晶锅：每次只能放入 1 个，让游戏自动分配到不同槽位
        for _, slot in ipairs(found) do
            for _ = 1, slot.count do
                MoveItemFromAllOfSlot(slot.slot, slot.cont, cont)
                Sleep(0)
            end
        end
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
