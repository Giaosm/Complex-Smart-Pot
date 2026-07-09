-- 模组配置：名称、版本、语言、功能开关
local isCh = locale and locale:match("^zh")

name = isCh and "复杂智能锅" or "Complex Smart Pot"
version = "1.1.2"
author = "哇唧唧哇"
forumthread = ""
dont_starve_compatible = false
dst_compatible = true
all_clients_require_mod = false
client_only_mod = true
api_version = 10
icon_atlas = "modicon.xml"
icon = "modicon.tex"
priority = 0

description = isCh
    and [[打开烹饪锅时显示全部料理图鉴面板，功能如下：
1. 分类浏览：全部、原版、设备、模组、BUFF、可做 分类
2. 三维排序：按饱食/生命/理智升降序排列
3. 食材实时筛选：放入食材自动排除不可能的料理
4. 配方需求分析：点击料理图标查看食材/标签上下限（再点取消）
5. 兄弟食材合并：可互换的食材自动合并显示
6. 可做检测(默认关闭)：根据选中来源检测可制作的料理
7. 自动做饭(默认关闭)：一键多锅烹饪，可调范围(默认30格)；
   点击图标→添加食材→点击做饭保存配方；
   右键料理图标直接放入该设备烹饪；
   控制台 ClearAutoCookMemory() 清空记忆]]
	    or [[Displays the full recipe encyclopedia when opening a cookpot, features:
1. Browse by category: All, Vanilla, Device, Mod, Buffs, Craftable
2. Sort by Hunger/Health/Sanity ascending/descending
3. Real-time ingredient filter: auto-excludes impossible recipes as you add
4. Recipe analysis: click an icon to view ingredient/tag limits (click again to dismiss)
5. Analog groups: interchangeable ingredients auto-merged
6. Craft check (off by default): checks craftable recipes from selected source
7. Auto cook (off by default): one-click multi-pot cooking, adjustable range (default 30);
   Click icon → add ingredients → click cook to save the recipe;
   Right-click a recipe icon to cook directly in the current device;
   Console: ClearAutoCookMemory() to clear all memory]]

local function Subtitle(name_cn, name_en)
    return {
        name = name_cn,
        label = isCh and name_cn or name_en,
        options = { {description = "", data = false}, },
        default = false,
    }
end

configuration_options = {
    {
        name = "language",
        label = isCh and "语言" or "Language",
        hover = isCh and "选择界面语言" or "Select UI language",
        options = {
            { description = isCh and "自动" or "Auto", data = "auto" },
            { description = "中文", data = "zh" },
            { description = "English", data = "en" },
        },
        default = "auto",
    },
    {
        name = "enable_auto_cook",
        label = isCh and "自动做饭" or "Auto Cook",
        hover = isCh and "开启后，烹饪锅面板增加「自动做饭」按钮，一键自动烹饪+收料理\n决定从哪些来源拿取食材，优先级：已打开的容器>背包>物品栏"
            or "Adds Auto Cook button to the cookpot panel for one-click cooking\nIngredient source priority: open containers > backpack > inventory",
        options = {
            { description = isCh and "关闭" or "Off", data = "off", hover = isCh and "关闭后右键点击料理的快捷烹饪也同时关闭" or "Also disables right-click quick cook" },
            { description = isCh and "物品栏" or "Inv", data = "inv", hover = isCh and "只从物品栏拿取" or "player inventory only" },
            { description = isCh and "背包+物品栏" or "Bag+Inv", data = "backpack_and_inv", hover = isCh and "从背包和物品栏拿取" or "backpack + inventory" },
            { description = isCh and "所有容器" or "All", data = "all", hover = isCh and "从所有打开的容器拿取" or "all open containers" },
            { description = isCh and "冰箱+盐盒" or "Fridge+Salt", data = "fridge", hover = isCh and "从冰箱和盐盒拿取" or "icebox + saltbox" },
            { description = isCh and "冰箱+盐盒+物品栏" or "Fridge+Salt+Inv", data = "fridge_and_inv", hover = isCh and "从冰箱、盐盒和物品栏拿取" or "icebox + saltbox + inventory" },
        },
        default = "off",
    },
    {
        name = "enable_backpack_check",
        label = isCh and "可做检测" or "Craft Check",
        hover = isCh and "检测食材来源，决定「可做」分类显示哪些料理\n注意：检测的地方越多性能要求越大，慎重选择！"
            or "Ingredient source for Craftable tab\nNote: more sources = more CPU, choose wisely!",
        options = {
            { description = isCh and "关闭" or "Off", data = "off" },
            { description = isCh and "物品栏" or "Inv", data = "inv", hover = isCh and "只检测物品栏" or "player inventory" },
            { description = isCh and "背包+物品栏" or "Bag+Inv", data = "backpack_and_inv", hover = isCh and "检测背包和物品栏" or "backpack + inventory" },
            { description = isCh and "所有容器" or "All", data = "all", hover = isCh and "检测所有打开的容器" or "all open containers" },
            { description = isCh and "冰箱+盐盒" or "Fridge+Salt", data = "fridge", hover = isCh and "检测冰箱和盐盒" or "icebox + saltbox" },
            { description = isCh and "冰箱+盐盒+物品栏" or "Fridge+Salt+Inv", data = "fridge_and_inv", hover = isCh and "检测冰箱、盐盒和物品栏" or "icebox + saltbox + inventory" },
        },
        default = "off",
    },
    {
        name = "recipe_select_behavior",
        label = isCh and "料理选中方式" or "Recipe Select",
        hover = isCh and "点击选中/取消选中，或鼠标悬浮选中+左击取消选中"
            or "Click to toggle, or hover to select + click to deselect",
        options = {
            { description = isCh and "点击选中" or "Click", data = "click" },
            { description = isCh and "悬浮选中" or "Hover", data = "hover" },
        },
        default = "click",
    },
    Subtitle("模组兼容", "Compat"),
    {
        name = "enable_hof_compat",
        label = "Heap of Foods",
        hover = isCh and "开启后，兼容Heap of Foods模组的酿酒桶(Wooden Keg)和泡菜罐(Preserves Jar)"
            or "Enable compatibility with Heap of Foods (Wooden Keg & Preserves Jar)",
        options = {
            { description = isCh and "开启" or "On", data = true },
            { description = isCh and "关闭" or "Off", data = false },
        },
        default = false,
    },
    {
        name = "enable_myth_compat",
        label = isCh and "神话书说" or "Myth Words Theme",
        hover = isCh and "开启后，兼容神话书说模组的炼丹炉烹饪设备"
            or "Compatible with Myth Words Theme (Alchemy Furnace)",
        options = {
            { description = isCh and "开启" or "On", data = true },
            { description = isCh and "关闭" or "Off", data = false },
        },
        default = false,
    },
    Subtitle("其他", "Other"),
    {
        name = "show_viewport_border",
        label = isCh and "显示视口边框" or "Show Viewport Border",
        hover = isCh and "在食谱上下限区域显示调试边框" or "Show debug border around recipe requirement area",
        options = {
            { description = isCh and "关闭" or "Off", data = false },
            { description = isCh and "开启" or "On", data = true },
        },
        default = false,
    },
}