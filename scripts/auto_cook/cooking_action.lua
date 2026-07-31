-- 烹饪动作执行：动作收集、模拟点击、开关容器、烹饪按钮触发
-- 同时持有 StewerFn 注册表（各类设备的烹饪按钮原始函数，由 modmain 在包装前登记）

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
        for oc, _ in pairs(open_conts) do
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

-- 各类设备烹饪按钮的原始函数（未包装版本），由 modmain 在 WrapCookButtonOnce 之前登记
local StewerFn = {}

local function SetStewerFn(prefab, fn)
    StewerFn[prefab] = fn
end

local function GetStewerFn(prefab)
    return StewerFn[prefab]
end

return {
    PlayerInv = PlayerInv,
    HasActiveItem = HasActiveItem,
    ReturnActiveItem = ReturnActiveItem,
    GetTargetActions = GetTargetActions,
    GetMouseActionSoft = GetMouseActionSoft,
    DoAction = DoAction,
    DoMouseAction = DoMouseAction,
    IsOpenContainer = IsOpenContainer,
    OpenContainer = OpenContainer,
    SetStewerFn = SetStewerFn,
    GetStewerFn = GetStewerFn,
}
