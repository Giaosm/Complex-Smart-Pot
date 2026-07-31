-- 配置管理：接收 modmain 集中读取的配置，对外提供语义化访问接口
-- 运行在 _G 环境（strict 模式），禁止调用任何 mod API（GetModConfigData 等）

-- 顶层赋值：require 的文件属于 main chunk，strict 下自动声明全局键，
-- 保证后续函数体内读写 _G.CSP_* 不会触发 "variable is not declared" 报错
_G.CSP_SHOW_VIEWPORT_BORDER = false
_G.CSP_DEBUG_LOGGING = false
_G.CSP_MAX_RENDER_COMBOS = 100

local DEFAULTS = {
    language = "auto",
    enable_auto_cook = "off",
    enable_backpack_check = "off",
    recipe_select_behavior = "click",
    enable_hof_compat = false,
    enable_myth_compat = false,
    enable_xd_compat = false,
    max_render_combos = 100,
    show_viewport_border = false,
    enable_debug_logging = false,
}

local Config = { _data = nil }

-- 旧版布尔配置兼容转换：true -> "inv"，false/nil -> "off"
local function NormalizeSourceMode(v)
    if v == true then return "inv" end
    if v == false then return "off" end
    return v
end

-- 由 modmain 调用，传入 GetModConfigData 读取到的原始配置表
function Config.Setup(raw)
    raw = raw or {}
    local d = {}
    for k, v in pairs(DEFAULTS) do
        d[k] = raw[k]
        if d[k] == nil then d[k] = v end
    end
    d.enable_backpack_check = NormalizeSourceMode(d.enable_backpack_check)
    d.enable_auto_cook = NormalizeSourceMode(d.enable_auto_cook)
    d.max_render_combos = math.max(0, tonumber(d.max_render_combos) or DEFAULTS.max_render_combos)
    Config._data = d

    -- 同步全局调试开关（键已在文件顶层声明，此处为普通更新，无 strict 问题）
    _G.CSP_SHOW_VIEWPORT_BORDER = d.show_viewport_border == true
    _G.CSP_DEBUG_LOGGING = d.enable_debug_logging == true
    _G.CSP_MAX_RENDER_COMBOS = d.max_render_combos
    return d
end

local function Get(key)
    local d = Config._data
    if d == nil then return DEFAULTS[key] end
    local v = d[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

Config.Get = Get

function Config.GetLanguage() return Get("language") end
function Config.GetAutoCookSource() return Get("enable_auto_cook") end
function Config.GetBackpackCheckMode() return Get("enable_backpack_check") end
function Config.GetSelectMode() return Get("recipe_select_behavior") end
function Config.IsHofCompat() return Get("enable_hof_compat") == true end
function Config.IsMythCompat() return Get("enable_myth_compat") == true end
function Config.IsXdCompat() return Get("enable_xd_compat") == true end
function Config.IsDebugLogging() return _G.CSP_DEBUG_LOGGING == true end
function Config.ShowViewportBorder() return _G.CSP_SHOW_VIEWPORT_BORDER == true end
function Config.GetMaxRenderCombos() return _G.CSP_MAX_RENDER_COMBOS or Get("max_render_combos") end

function Config.SetMaxRenderCombos(n)
    n = math.max(0, tonumber(n) or 0)
    if Config._data then Config._data.max_render_combos = n end
    _G.CSP_MAX_RENDER_COMBOS = n
end

return Config
