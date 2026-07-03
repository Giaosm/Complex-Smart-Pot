-- 容器检测：判断容器类型（烹饪锅/酿酒桶/炼丹炉）
local function IsCookpotContainer(container)
    if container == nil then
        return false
    end
    local rep = container.replica and container.replica.container
    if rep == nil or rep.type ~= "cooker" then
        return false
    end
    return container:HasTag("stewer") and rep:GetNumSlots() == 4
end

local function IsBrewerContainer(container, enable_hof)
    if container == nil or not enable_hof then
        return false
    end
    local rep = container.replica and container.replica.container
    if rep == nil or rep.type ~= "brewer" then
        return false
    end
    return container:HasTag("brewer") and rep:GetNumSlots() == 3
end

local function IsMythContainer(container, enable_myth)
    if container == nil or not enable_myth then
        return false
    end
    return container.prefab == "alchmy_fur"
end

return {
    IsCookpot = IsCookpotContainer,
    IsBrewer = IsBrewerContainer,
    IsMyth = IsMythContainer,
}