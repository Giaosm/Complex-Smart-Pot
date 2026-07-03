local RANGE_DEFAULT = 30
local RANGE_MIN = 5
local RANGE_MAX = 99
local STEWER_TAGS = {"structure", "_container", "stewer"}
local BREWER_TAGS = {"structure", "_container", "brewer"}

local function Say(msg)
    if ThePlayer and ThePlayer.components and ThePlayer.components.talker then
        ThePlayer.components.talker:Say(msg, nil, nil, nil, nil)
    end
    return true
end

local function Silent()
    return true
end

local function PlayerInv()
    return ThePlayer and ThePlayer.replica and ThePlayer.replica.inventory
end

local function HasActiveItem()
    local inv = PlayerInv()
    return inv and inv:GetActiveItem() ~= nil
end

local function ReturnActiveItem()
    if ThePlayer.components and ThePlayer.components.inventory then
        ThePlayer.components.inventory:ReturnActiveItem()
    else
        SendRPCToServer(RPC.ReturnActiveItem)
    end
end

local StewerFn = {}

local function IsCooker(ent)
    if not (ent and ent:IsValid()) then
        return false
    end
    if not (ent:HasTags(STEWER_TAGS) or ent:HasTags(BREWER_TAGS)) then
        return false
    end
    local container = ent.replica and ent.replica.container
    if not container then return false end
    local widget = container:GetWidget()
    local btn = widget and widget.buttoninfo
    return btn and btn.fn and btn.validfn
end

local function FindEnts(prefab, range)
    local pos = ThePlayer:GetPosition()
    local ents = TheSim:FindEntities(pos.x, 0, pos.z,
        range, {"structure", "_container"},
        {'FX', 'DECOR', 'INLIMBO', 'NOCLICK', 'player'}
    )
    local pots = {}
    for _, ent in ipairs(ents) do
        if ent.prefab == prefab and IsCooker(ent) then
            table.insert(pots, ent)
        end
    end
    return pots
end

local function IGetElement(tbl, fn)
    for _, v in ipairs(tbl) do
        local ret = fn(v)
        if ret then return v end
    end
end

local function GetTargetActions(target, pos, right)
    local picker = ThePlayer and ThePlayer.components and ThePlayer.components.playeractionpicker
    if not picker then return {} end

    local active_item = PlayerInv() and PlayerInv():GetActiveItem()
    local acts = {}

    if active_item then
        active_item:CollectActions("USEITEM", ThePlayer, target, acts, right)
    end

    target:CollectActions("SCENE", ThePlayer, acts, right)

    local equips = PlayerInv() and PlayerInv():GetEquips()
    if equips then
        for _, equip in pairs(equips) do
            equip:CollectActions("EQUIPPED", ThePlayer, target, acts, right)
        end
    end

    if picker.SortActionList then
        acts = picker:SortActionList(acts, target, active_item)
    end
    return acts
end

local function GetMouseActionSoft(code_list, target)
    local pos = target:GetPosition()
    local code_map = {}
    for _, c in ipairs(code_list) do code_map[c] = true end

    local acts_left = GetTargetActions(target, pos, false)
    local acts_right = GetTargetActions(target, pos, true)

    for _, act_right in ipairs(acts_right) do
        local r_id = act_right.action and act_right.action.id
        if r_id and code_map[r_id] then
            local in_left = false
            for _, act_left in ipairs(acts_left) do
                if act_left.action and act_left.action.id == r_id then
                    in_left = true
                    break
                end
            end
            if not in_left then
                return act_right, true
            end
        end
    end

    for _, act_left in ipairs(acts_left) do
        local l_id = act_left.action and act_left.action.id
        if l_id and code_map[l_id] then
            return act_left, false
        end
    end

    return nil, nil
end

local function DoAction(act, rpc, ...)
    local pc = ThePlayer and ThePlayer.components and ThePlayer.components.playercontroller
    if pc and act then
        local meta = {...}
        local n = select('#', ...)
        act.preview_cb = function()
            if rpc then
                SendRPCToServer(rpc, unpack(meta, 1, n))
            end
        end
        if pc.locomotor then
            pc:DoAction(act)
        else
            act.preview_cb()
        end
    end
end

local function DoMouseAction(act, right)
    if not act then return end

    local target = act.target
    if not target then return end

    local pos = target:GetPosition()

    if act.action.id == "WALKTO" then
        local item = PlayerInv() and PlayerInv():GetActiveItem()
        if item and not Profile:GetMovementPredictionEnabled() then
            act = BufferedAction(ThePlayer, nil, ACTIONS.DROP, item, pos)
        else
            act = BufferedAction(ThePlayer, nil, ACTIONS.WALKTO, nil, pos)
        end
    end

    if right then
        DoAction(act, RPC.RightClick, act.action.code, pos.x, pos.z,
            act.target, act.rotation, nil, nil, true, act.action.mod_name)
    else
        DoAction(act, RPC.LeftClick, act.action.code, pos.x, pos.z,
            act.target, nil, nil, true, nil, act.action.mod_name)
    end
end

local function IsOpenContainer(cont_inst)
    local container = cont_inst and cont_inst.replica and cont_inst.replica.container
    if not container then return false end

    local inv = PlayerInv()
    if not inv then return false end

    local open_conts = inv:GetOpenContainers()
    if open_conts then
        for _, oc in pairs(open_conts) do
            if oc == cont_inst then return container end
        end
    end

    local hud = ThePlayer.HUD
    local cont_ui = hud and hud.controls and hud.controls.containers and hud.controls.containers[cont_inst]
    if cont_ui then return container end

    if container.IsOpenedBy and container:IsOpenedBy(ThePlayer) then
        return container
    end

    return false
end

local function OpenContainer(target)
    local time_click, pos_lastsend = 0, ThePlayer:GetPosition()

    repeat
        local cont = IsOpenContainer(target)
        if cont then
            return cont
        else
            local now = GetTime()
            if now - time_click > 0.5 then
                local pos_player = ThePlayer:GetPosition()
                local dx = pos_lastsend.x - pos_player.x
                local dz = pos_lastsend.z - pos_player.z
                local dist_to_target = target:IsValid() and target:GetPosition()

                if dx * dx + dz * dz < 0.25 or (dist_to_target and ((dist_to_target.x - pos_player.x)^2 + (dist_to_target.z - pos_player.z)^2) > 36) then
                    local act, right = GetMouseActionSoft({"RUMMAGE"}, target)
                    if act then
                        DoMouseAction(act, right)
                    else
                        return
                    end
                end
                time_click, pos_lastsend = now, pos_player
            end
        end

        Sleep(0)
    until not (target and target.entity and target:IsValid() and target.Transform and GetMouseActionSoft({"RUMMAGE"}, target))
end

local function GetStackSize(item)
    if item and item.replica and item.replica.stackable then
        return item.replica.stackable:StackSize()
    end
    if item and item.components and item.components.stackable then
        return item.components.stackable:StackSize()
    end
    return 1
end

local function GetSlotsFromAll()
    local slots = {}
    local inv = PlayerInv()
    if not inv then return slots end

    local num = inv:GetNumSlots()
    for i = 1, num do
        local item = inv:GetItemInSlot(i)
        if item then
            table.insert(slots, { slot = i, cont = ThePlayer, item = item })
        end
    end

    local backpack = inv:GetEquippedItem("back")
    if backpack then
        local bp_cont = backpack.replica and backpack.replica.container
        if bp_cont then
            local num = bp_cont:GetNumSlots()
            for i = 1, num do
                local item = bp_cont:GetItemInSlot(i)
                if item then
                    table.insert(slots, { slot = i, cont = backpack, item = item })
                end
            end
        end
    end

    return slots
end

local function containerCanHas(invent, item)
    for i = 1, invent:GetNumSlots() do
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

    if containerCanHas(inv, item) then
        return ThePlayer
    end

    local backpack = inv:GetEquippedItem("back")
    if backpack then
        local bp_cont = backpack.replica and backpack.replica.container
        if bp_cont and containerCanHas(bp_cont, item) then
            return backpack
        end
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

local function CheckIng(data, notcont)
    local ing_data = {}
    for _, prefab in ipairs(data) do
        ing_data[prefab] = (ing_data[prefab] or 0) + 1
    end

    local slots = GetSlotsFromAll()
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

local function ClearContainer(container, cont)
    while type(cont) == "table" and cont.entity and cont:IsValid() and cont.Transform do
        local items = container:GetItems() or {}
        if next(items) then
            for slot, item in pairs(items) do
                local cont_cantake = CanTakeItem(item)
                if cont_cantake then
                    MoveItemFromAllOfSlot(slot, cont, cont_cantake)
                else
                    return false
                end
            end
        else
            return true
        end
        Sleep(0)
    end
end

local function Cook(prefab, data, range)
    if HasActiveItem() then
        return Silent()
    end

    local conts = FindEnts(prefab, range)
    if not conts[1] then
        return Silent()
    end

    local ret = CheckIng(data)
    if ret then
        local act, right
        local cont = IGetElement(conts, function(target)
            act, right = GetMouseActionSoft({"HARVEST", "RUMMAGE"}, target)
            if act then
                if target._flag_next and act.action.id == "RUMMAGE" then
                    return
                end
                return target
            end
        end)

        if cont then
            if act.action.id == "RUMMAGE" then
                local container = OpenContainer(cont)
                if container then
                    if ClearContainer(container, cont) then
                        ret = CheckIng(data, cont)
                        if ret then
                            for _, slot in ipairs(ret) do
                                MoveItemFromAllOfSlot(slot.slot, slot.cont, cont)
                            end
                            StewerFn[prefab](cont, ThePlayer)
                            if #conts > 1 then
                                cont._flag_next = true
                                cont:DoTaskInTime(10 * FRAMES, function()
                                    cont._flag_next = nil
                                end)
                            end
                        else
                            return Silent()
                        end
                    else
                        return Silent()
                    end
                else
                    return Silent()
                end
            else
                DoMouseAction(act, right)
                Sleep(0)
                if HasActiveItem() then
                    return Silent()
                end
            end
        end
    else
        local act, right
        local pot = IGetElement(conts, function(target)
            act, right = GetMouseActionSoft({"HARVEST"}, target)
            return act and target
        end)
        if pot then
            DoMouseAction(act, right)
            Sleep(0)
            if HasActiveItem() then
                return Silent()
            end
        else
            if not IGetElement(conts, function(target)
                return not GetMouseActionSoft({"RUMMAGE"}, target)
            end) then
                return true
            end
        end
    end
    Sleep(0)
end

local AutoCook = Class(function(self, panel, range_init)
    self._panel = panel
    self._memory = nil
    self._range_search = range_init or RANGE_DEFAULT
    self._task_queue = require("task_queue")()
end)

function AutoCook:SetStewerFn(prefab, fn)
    StewerFn[prefab] = fn
end

function AutoCook:GetRangeSearch()
    return self._range_search
end

function AutoCook:SetRangeSearch(v)
    self._range_search = math.clamp(v, RANGE_MIN, RANGE_MAX)
    if self._on_save then
        self._on_save()
    end
end

function AutoCook:SetSaveCallback(fn)
    self._on_save = fn
end

function AutoCook:SaveMemory(ingredients)
    local max_slots = self._panel._max_slots or 4
    if not ingredients or #ingredients ~= max_slots then
        return false
    end
    self._memory = { ingredients = ingredients }
    if self._panel._pot_bar then
        self._panel._pot_bar:UpdateSlots(ingredients)
    end
    return true
end

function AutoCook:_GetOrCreateMem(recipe_name)
    if not self._recipe_memories then
        self._recipe_memories = {}
    end
    local mem = self._recipe_memories[recipe_name]
    if not mem then
        mem = { slots = {}, selected = 1 }
        self._recipe_memories[recipe_name] = mem
    end
    return mem
end

function AutoCook:SaveRecipeMemory(recipe_name, ingredients)
    local max_slots = self._panel._max_slots or 4
    if not recipe_name or not ingredients or #ingredients ~= max_slots then
        return false
    end
    local mem = self:_GetOrCreateMem(recipe_name)
    mem.slots[mem.selected] = { ingredients = ingredients }
    self._active_recipe = recipe_name
    self:SaveMemory(ingredients)
    if self._on_memory_save then
        self._on_memory_save(recipe_name, mem)
    end
    return true
end

function AutoCook:GetRecipeMemory(recipe_name)
    if not self._recipe_memories or not recipe_name then
        return nil
    end
    local mem = self._recipe_memories[recipe_name]
    if not mem then return nil end
    local slot = mem.slots[mem.selected or 1]
    return slot and slot.ingredients or nil
end

function AutoCook:SwitchToRecipe(recipe_name)
    self._active_recipe = recipe_name
    local ings = self:GetRecipeMemory(recipe_name)
    if ings then
        self:SaveMemory(ings)
    else
        self._memory = nil
        if self._panel._pot_bar then
            self._panel._pot_bar:UpdateSlots(nil)
        end
    end
    self:_UpdatePotBarLabel()
    return ings ~= nil
end

function AutoCook:GetCurrentSlotIndex(recipe_name)
    if not recipe_name or not self._recipe_memories then
        return 0
    end
    local mem = self._recipe_memories[recipe_name]
    if not mem then return 1 end
    return mem.selected or 1
end

function AutoCook:SwitchToRecipeSlot(recipe_name, slot_idx)
    if not recipe_name then return false end
    local mem = self:_GetOrCreateMem(recipe_name)
    mem.selected = ((slot_idx - 1) % 5) + 1
    self._active_recipe = recipe_name
    if self._on_memory_save then
        self._on_memory_save(recipe_name, mem)
    end
    local slot_data = mem.slots[mem.selected]
    if slot_data then
        self:SaveMemory(slot_data.ingredients)
        self:_UpdatePotBarLabel()
        return true
    end
    self._memory = nil
    if self._panel._pot_bar then
        self._panel._pot_bar:UpdateSlots(nil)
    end
    self:_UpdatePotBarLabel()
    return false
end

function AutoCook:_UpdatePotBarLabel()
    if not self._panel._pot_bar then return end
    local name = self._active_recipe
    if not name then
        self._panel._pot_bar:SetSlotLabel("0/5")
        return
    end
    local idx = self:GetCurrentSlotIndex(name)
    self._panel._pot_bar:SetSlotLabel(tostring(idx) .. "/5")
end

function AutoCook:GetActiveRecipeName()
    return self._active_recipe
end

function AutoCook:SetRecipeMemorySaveCallback(fn)
    self._on_memory_save = fn
end

function AutoCook:RestoreRecipeMemories(recipe_map)
    if not recipe_map then return end
    local max_slots = self._panel._max_slots or 4
    self._recipe_memories = {}
    for recipe_name, mem in pairs(recipe_map) do
        if type(mem) == "table" then
            if mem.slots then
                local new_mem = { slots = {}, selected = mem.selected or 1 }
                for i, slot_data in pairs(mem.slots) do
                    if type(slot_data) == "table" and type(slot_data.ingredients) == "table"
                        and #slot_data.ingredients == max_slots then
                        new_mem.slots[tonumber(i) or i] = { ingredients = slot_data.ingredients }
                    end
                end
                self._recipe_memories[recipe_name] = new_mem
            elseif type(mem[1]) == "string" and #mem == max_slots then
                self._recipe_memories[recipe_name] = {
                    slots = { [1] = { ingredients = mem } },
                    selected = 1,
                }
            end
        end
    end
end

function AutoCook:Execute()
    if self._task_queue:IsRunning() then
        return false
    end

    local max_slots = self._panel._max_slots or 4
    if not self._memory or not self._memory.ingredients or #self._memory.ingredients ~= max_slots then
        Say(STRINGS.CSP.AUTO_NEED_RECIPE)
        return false
    end

    local current_container = self._panel._container
    if not current_container then
        return false
    end

    local prefab = current_container.prefab
    local data = self._memory.ingredients

    local hud = ThePlayer and ThePlayer.HUD
    if hud and hud.CloseContainer and current_container then
        hud:CloseContainer(current_container)
    end

    if HasActiveItem() then
        ReturnActiveItem()
    end

    Say(STRINGS.CSP.AUTO_START)
    self._task_queue:RegNowTask(
        function()
            return Cook(prefab, data, self._range_search)
        end,
        function()
            Say(STRINGS.CSP.AUTO_STOP)
        end
    )

    return true
end

return AutoCook
