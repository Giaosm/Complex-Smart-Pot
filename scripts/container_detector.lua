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

local function IsBrewerContainer(container)
    if container == nil then
        return false
    end
    if not GetModConfigData("enable_hof_compat") then
        return false
    end
    local rep = container.replica and container.replica.container
    if rep == nil or rep.type ~= "brewer" then
        return false
    end
    return container:HasTag("brewer") and rep:GetNumSlots() == 3
end

local function IsMythContainer(container)
    if container == nil then
        return false
    end
    if not GetModConfigData("enable_myth_compat") then
        return false
    end
    return container.prefab == "alchmy_fur"
end

return {
    IsCookpot = IsCookpotContainer,
    IsBrewer = IsBrewerContainer,
    IsMyth = IsMythContainer,
}