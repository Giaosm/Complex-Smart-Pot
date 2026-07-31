-- 烹饪设备查找：按 prefab 与范围搜索附近可用的烹饪设备（锅/酒桶/炼丹炉）
local ContainerDetector = require("container/container_detector")

-- 只要求带容器组件，具体设备类型交给 ContainerDetector 判定（支持原版锅、酒桶、神话/登仙炼丹炉等）
local FIND_TAGS = {"_container"}
-- 注意：这是 FindEntities 的 canttags（排除项），别误命名成 MUST
local FIND_CANT_TAGS = {'FX', 'DECOR', 'INLIMBO', 'NOCLICK', 'player'}

local function IsCooker(ent)
    if not (ent and ent:IsValid()) then
        return false
    end
    if not ContainerDetector.Match(ent) then
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
        range, FIND_TAGS, FIND_CANT_TAGS
    )
    local pots = {}
    for _, ent in ipairs(ents) do
        if ent.prefab == prefab and IsCooker(ent) then
            table.insert(pots, ent)
        end
    end
    return pots
end

return {
    IsCooker = IsCooker,
    FindEnts = FindEnts,
}
