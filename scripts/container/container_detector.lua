-- 容器检测：判断容器类型（烹饪锅/酿酒桶/炼丹炉）
-- 设备列表配置表化：新增设备类型（如其他模组的炼丹炉）只需在 DEVICES 追加一条，
-- 或通过 ContainerDetector.RegisterDevice(def) 在外部注册
local Config = require("config/config_manager")

-- 每条设备定义：
--   id         设备标识
--   is_brewer  是否酿酒设备（面板据此切换 brewingredients / 3 槽逻辑）
--   config_key config_manager 的布尔开关接口名（nil 表示不校验配置，始终启用）
--   test       fn(container) -> bool
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
            local rep = container.replica and container.replica.container
            if rep == nil or rep.type ~= "brewer" then return false end
            return container:HasTag("brewer") and rep:GetNumSlots() == 3
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
            return container.prefab == "xd_liandanlu"
        end,
    },
}

local Detector = {}

-- 遍历设备配置表，返回命中的设备定义（未命中返回 nil）
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
-- def 结构同 DEVICES 条目；config_key 可留空表示始终启用
function Detector.RegisterDevice(def)
    table.insert(DEVICES, def)
end

-- 单类型判断的便捷接口（兼容旧调用风格，配置开关改由 config_manager 提供）
local function IsType(container, id)
    local def = Detector.Match(container)
    return def ~= nil and def.id == id
end

function Detector.IsCookpot(container) return IsType(container, "cookpot") end
function Detector.IsBrewer(container)  return IsType(container, "brewer") end
function Detector.IsMyth(container)    return IsType(container, "myth") end
function Detector.IsXd(container)      return IsType(container, "xd") end

return Detector
