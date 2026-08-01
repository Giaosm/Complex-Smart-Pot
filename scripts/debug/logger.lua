-- 调试日志：统一输出，受 config_manager 的调试开关（enable_debug_logging）控制
local Config = require("config/config_manager")

local Logger = {}

function Logger.IsEnabled()
    return Config.IsDebugLogging()
end

function Logger.Log(...)
    if not Config.IsDebugLogging() then return end
    print(...)
end

function Logger.Logf(fmt, ...)
    if not Config.IsDebugLogging() then return end
    print(string.format(fmt, ...))
end

-- 惰性日志：传入一个返回字符串的函数，仅在调试开启时执行，避免关闭时产生昂贵拼接/求值
function Logger.LogLazy(fn)
    if not Config.IsDebugLogging() then return end
    print(fn())
end

-- 语义化接口：食材扫描结果
function Logger.LogScanResult(max_slots, use_quantity_matching, mode, bag_counts)
    if not Config.IsDebugLogging() then return end
    local items = {}
    for k, v in pairs(bag_counts) do table.insert(items, k .. "=" .. v) end
    table.sort(items)
    print(string.format("[智能锅] slots=%d qmatch=%s mode=%s scan(%d)",
        max_slots, tostring(use_quantity_matching), tostring(mode), #items))
    print("  [" .. table.concat(items, "、") .. "]")
end

-- 语义化接口：「可做」匹配结果
function Logger.LogMatchResult(recipes)
    if not Config.IsDebugLogging() then return end
    if recipes then
        local rec = {}
        for k, _ in pairs(recipes) do table.insert(rec, k) end
        table.sort(rec)
        print("[智能锅] 可做料理(" .. #rec .. "): [" .. table.concat(rec, "、") .. "]")
    end
end

return Logger
