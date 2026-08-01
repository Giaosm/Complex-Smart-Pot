-- 模组入口：初始化顺序、配置读取、Hook 注册与事件转发；具体逻辑见各子模块
-- 注意：游戏不会给模组 env 安装元表，下面这行是 modmain 内裸名访问 _G 全局（STRINGS/TUNING/json 等）的前提
GLOBAL.setmetatable(env, { __index = function(t, k) return GLOBAL.rawget(GLOBAL, k) end })

Assets = Assets or {}
table.insert(Assets, Asset("ATLAS", "images/food_tags.xml"))
table.insert(Assets, Asset("IMAGE", "images/food_tags.tex"))
table.insert(Assets, Asset("ATLAS", "images/food_types.xml"))
table.insert(Assets, Asset("IMAGE", "images/food_types.tex"))

require "ingredienttags"
require "foodatlas"

local Config = require("config/config_manager")

-- 集中读取全部配置（GetModConfigData 只能在 modmain 直接调用），统一交给 config_manager
Config.Setup({
    language               = GetModConfigData("language"),
    enable_auto_cook       = GetModConfigData("enable_auto_cook"),
    enable_backpack_check  = GetModConfigData("enable_backpack_check"),
    recipe_select_behavior = GetModConfigData("recipe_select_behavior"),
    enable_hof_compat      = GetModConfigData("enable_hof_compat"),
    enable_myth_compat     = GetModConfigData("enable_myth_compat"),
    enable_xd_compat       = GetModConfigData("enable_xd_compat"),
    max_render_combos      = GetModConfigData("max_render_combos"),
    show_viewport_border   = GetModConfigData("show_viewport_border"),
    enable_debug_logging   = GetModConfigData("enable_debug_logging"),
})

-- 语言包必须先于任何 UI 模块加载：UI 模块顶层即读取 STRINGS.CSP 常量
local _language_map = {
    zh = "cn",  zhr = "cn", zht = "cn",
    ch = "cn",  chs = "cn", sc = "cn", chinese = "cn",
    ru = "ru",  russian = "ru",
}
local function LoadLanguage()
    local lang = Config.GetLanguage()
    if lang == "auto" then
        lang = _language_map[_G.LanguageTranslator and _G.LanguageTranslator.defaultlang] or "en"
    end
    if lang == "cn" then
        modimport("scripts/language/cn.lua")
    else
        modimport("scripts/language/en.lua")
    end
end
LoadLanguage()

local ContainerDetector = require("container/container_detector")
local CookbookData = require("data/cookbook_data")
local PanelManager = require("ui/recipe_panel_manager")

local g_cookbook_data = CookbookData()
PanelManager.Setup(g_cookbook_data)

AddSimPostInit(function()
    g_cookbook_data:Collect()
end)

-- 控制台命令：清空自动做饭配方记忆
_G.ClearAutoCookMemory = function()
    PanelManager.ClearAllAutoCookMemory()
    print(STRINGS.CSP.MEMORY_CLEARED)
end

-- 控制台命令：设置弹窗「可做配方」最大渲染组合数
_G.SetMaxRenderCombos = function(n)
    Config.SetMaxRenderCombos(n)
    print(STRINGS.CSP.COMBO_LIMIT_SET .. tostring(Config.GetMaxRenderCombos()))
end

-- 面板打开期间屏蔽相机缩放（防止误触滚轮改变视角）
AddClassPostConstruct("cameras/followcamera", function(self)
    local _ZoomIn = self.ZoomIn
    self.ZoomIn = function(self, ...)
        if PanelManager.HasPanels() then return end
        return _ZoomIn(self, ...)
    end
    local _ZoomOut = self.ZoomOut
    self.ZoomOut = function(self, ...)
        if PanelManager.HasPanels() then return end
        return _ZoomOut(self, ...)
    end
end)

-- 容器开关 Hook：烹饪设备开面板，其余容器绑定变化通知
-- 设备类型判定统一走 ContainerDetector.Match（配置表驱动，新增设备类型无需改这里）
AddClassPostConstruct("screens/playerhud", function(self)
    local _OpenContainer = self.OpenContainer
    self.OpenContainer = function(self, container, side)
        _OpenContainer(self, container, side)

        local device = ContainerDetector.Match(container)
        if device then
            PanelManager.CreatePanel(self, container, device.is_brewer)
        else
            PanelManager.BindExtContainer(container)
            PanelManager.NotifyAll()
        end
    end

    local _CloseContainer = self.CloseContainer
    self.CloseContainer = function(self, container, side)
        if ContainerDetector.Match(container) then
            PanelManager.DestroyPanel(container)
        else
            PanelManager.UnbindExtContainer(container)
            PanelManager.NotifyAll()
        end
        _CloseContainer(self, container, side)
    end
end)
