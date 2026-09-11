-- 容器检测：判断容器类型（烹饪锅/酿酒桶/炼丹炉），配置表驱动
local Config = require("config/config_manager")

-- 设备定义：id / is_brewer(酿酒设备) / config_key(开关接口名，nil 始终启用) / test(判定函数)
local DEVICES = {
    {
        id = "cookpot",
        is_brewer = false,
        test = function(container)
            local rep = container.replica and container.replica.container
            if rep == nil or rep.type ~= "cooker" then return false end
            return container:HasTag("stewer") and rep:GetNumSlots() == 4
        end,
    },
    {
        id = "brewer",
        is_brewer = true,
        config_key = "IsHofCompat",
        test = function(container)
            local prefab = container.prefab
            return prefab == "kyno_woodenkeg" or prefab == "kyno_preservesjar"
                or prefab == "kyno_portablebrewer"  -- or prefab == "kyno_wx78_inventorybrewer"  -- WX78 随身酿酒桶：挂在角色身上的子容器，当前寻设备逻辑搜不到，暂注释
        end,
    },
    {
        id = "myth",
        is_brewer = false,
        config_key = "IsMythCompat",
        test = function(container)
            return container.prefab == "alchmy_fur"
        end,
    },
    {
        id = "xd",
        is_brewer = false,
        config_key = "IsXdCompat",
        test = function(container)
            return container.prefab == "xd_liandanlu" or container.prefab == "xd_xcdf"
        end,
    },
    {
        id = "water",
        is_brewer = false,
        config_key = "IsWaterCompat",
        test = function(container)
            local prefab = container.prefab
            -- 蒸馏器(distillers)需走堆叠设备(槽1酒类堆叠≥4)，暂不支持，注释掉
            return prefab == "kettle" or prefab == "portablekettle"
                or prefab == "brewery" -- or prefab == "distillers"
        end,
    },
}

local Detector = {}

function Detector.Match(container)
    if container == nil then return nil end
    for _, def in ipairs(DEVICES) do
        if (def.config_key == nil or Config[def.config_key]()) and def.test(container) then
            return def
        end
    end
    return nil
end

-- 供外部扩展新设备类型，追加到检测链末尾
function Detector.RegisterDevice(def)
    table.insert(DEVICES, def)
end

-- 单类型判断便捷接口
local function IsType(container, id)
    local def = Detector.Match(container)
    return def ~= nil and def.id == id
end

function Detector.IsCookpot(container) return IsType(container, "cookpot") end
function Detector.IsBrewer(container)  return IsType(container, "brewer") end
function Detector.IsMyth(container)    return IsType(container, "myth") end
function Detector.IsXd(container)      return IsType(container, "xd") end

return Detector
