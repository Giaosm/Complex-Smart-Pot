-- 调试日志：统一输出，受 config_manager 的调试开关（enable_debug_logging）控制
local Config = require("config/config_manager")

-- 季节/月相/节日的显示名称映射（ID 来源见游戏原版源码 constants.lua 与 components/clock.lua）
local _SEASON_NAMES = {
    autumn = "秋季",
    winter = "冬季",
    spring = "春季",
    summer = "夏季",
    caves = "洞穴",
}

local _MOON_PHASE_NAMES = {
    new = "新月",
    quarter = "四分之一",
    half = "半月",
    threequarter = "四分之三",
    full = "满月",
}

-- SPECIAL_EVENTS（constants.lua）各事件 ID 的中文名
local _EVENT_NAMES = {
    hallowed_nights = "万圣节",
    winters_feast = "冬季盛宴",
    crow_carnival = "仲夏鸦狂欢",
    year_of_the_gobbler = "火鸡之年",
    year_of_the_varg = "座狼之年",
    year_of_the_pig = "猪王之年",
    year_of_the_carrat = "胡萝卜鼠之年",
    year_of_the_beefalo = "皮弗娄牛之年",
    year_of_the_catcoon = "猫浣熊之年",
    year_of_the_bunnyman = "兔人之年",
    year_of_the_dragonfly = "龙蝇之年",
    year_of_the_snake = "蛇之年",
    year_of_the_knight = "骑士之年",
}

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

function Logger.LogScanResult(max_slots, use_quantity_matching, mode, bag_counts)
    if not Config.IsDebugLogging() then return end
    local items = {}
    for k, v in pairs(bag_counts) do table.insert(items, k .. "=" .. v) end
    table.sort(items)
    print(string.format("[智能锅] slots=%d qmatch=%s mode=%s scan(%d)",
        max_slots, tostring(use_quantity_matching), tostring(mode), #items))
    print("  [" .. table.concat(items, "、") .. "]")
end

-- 当前季节（原始 ID）
local function GetCurrentSeason()
    return _G.TheWorld and _G.TheWorld.state and _G.TheWorld.state.season
end

-- 当前月相（原始 ID）
local function GetCurrentMoonPhase()
    return _G.TheWorld and _G.TheWorld.state and _G.TheWorld.state.moonphase
end

-- 当前活跃节日列表（原始 ID，主事件 + 额外事件合并，可多种并存）
local function GetActiveEvents()
    local events = {}
    if _G.GetAllActiveEvents then
        local all = _G.GetAllActiveEvents(_G.WORLD_SPECIAL_EVENT, _G.WORLD_EXTRA_EVENTS)
        for event, _ in pairs(all or {}) do
            table.insert(events, event)
        end
    end
    table.sort(events)
    return events
end

-- 环境指纹：季节 + 月相 + 活跃节日，用于匹配缓存 key。
-- 季节/月相/节日变化会影响部分模组料理的可做性，若不纳入 key，
-- 缓存会在环境变化时返回旧结果（例如进游戏是满月，之后月相变了仍被判定为满月）。
-- 该函数为纯函数，不依赖调试开关，供 recipe_matcher / combo_matcher / craftable_combo_generator 使用。
function Logger.GetEnvironmentFingerprint()
    return table.concat({
        GetCurrentSeason() or "?",
        GetCurrentMoonPhase() or "?",
        table.concat(GetActiveEvents(), ","),
    }, "|")
end

-- 世界上下文日志：独立输出当日季节、当日月相、节日活动两行
-- 季节/月相来自 TheWorld.state（客户端已同步），节日来自全局常量 WORLD_SPECIAL_EVENT / WORLD_EXTRA_EVENTS（主事件 + 额外事件，可多种并存）
function Logger.LogWorldContext()
    if not Config.IsDebugLogging() then return end

    local season_str = _SEASON_NAMES[GetCurrentSeason()] or tostring(GetCurrentSeason() or "未知")
    local moon_str = _MOON_PHASE_NAMES[GetCurrentMoonPhase()] or tostring(GetCurrentMoonPhase() or "未知")

    print("[智能锅] 当前季节 " .. season_str .. "    当日月相 " .. moon_str)

    local events = GetActiveEvents()
    local names = {}
    for _, ev in ipairs(events) do
        names[#names + 1] = _EVENT_NAMES[ev] or ev
    end
    print("[智能锅] 节日活动 " .. (#names > 0 and table.concat(names, "、") or "无"))
end

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
