-- 食谱面板：协调按钮列、料理列表、详情弹窗、预览条，负责容器监听、实时筛选、可做检测
local Widget         = require("widgets/widget")
local ImageButton    = require("widgets/imagebutton")
local Text           = require("widgets/text")
local RecipePopup    = require("ui/recipe_popup")
local PotPreviewBar  = require("ui/pot_preview_bar")
local CategoryButtons = require("ui/category_buttons")
local SortButtons    = require("ui/sort_buttons")
local RecipeList     = require("ui/recipe_list")
local L              = require("ui/panel_layout")
-- 拆分模块：各自把方法挂回本类（模块返回 function(RecipePanel)）
local InstallMatch     = require("ui/recipe_panel_match")
local InstallContainer = require("ui/recipe_panel_container")
local InstallCombo     = require("ui/recipe_panel_combo")

local cooking = require("cooking")

local AutoCook = nil

local function GetAutoCook()
    if not AutoCook then
        AutoCook = require("auto_cook/auto_cook_controller")
    end
    return AutoCook
end

local CATEGORIES = {
    { id = "all",        label = STRINGS.CSP.CATEGORY_ALL },
    { id = "cookpot",    label = STRINGS.CSP.CATEGORY_COOKPOT },
    { id = "device",     label = STRINGS.CSP.CATEGORY_DEVICE },
    { id = "mod",        label = STRINGS.CSP.CATEGORY_MOD },
    { id = "buff",       label = STRINGS.CSP.CATEGORY_BUFF },
}

local SORT_STATE_NONE = SortButtons.STATE_NONE
local SORT_STATE_DESC = SortButtons.STATE_DESC

local RecipePanel = Class(Widget, function(self, cookbook_data, env, player_inst, backpack_check_mode, auto_cook_source, auto_cook_mode, range_init, prefs, select_mode, debug_logging)
    Widget._ctor(self, "RecipePanel")

    self.data = cookbook_data
    self._S = env.strings
    self._T = env.tuning
    self._player_inst = player_inst
    self._backpack_check_mode = backpack_check_mode or "off"
    self._auto_cook_source = auto_cook_source or "off"
    self._enable_auto_cook = self._auto_cook_source ~= "off"
    self._auto_cook_mode = auto_cook_mode or "normal"
    self._prefs = prefs or {}
    self._select_mode = select_mode or "click"
    self._debug_logging = debug_logging == true

    self._cooker = nil
    self._cooker_recipes = nil
    self._is_brewer = false
    self._brewing_ingredients = nil
    self._brewer_recipes = nil
    self._max_slots = 4
    self._accepts_stacks = false
    self._use_quantity_matching = false

    self._category  = self._prefs.category  or "all"
    if self._category == "craftable" and self._backpack_check_mode == "off" then
        self._category = "all"
    end
    if self._category == "mod" and not next(self.data.categories["mod"] or {}) then
        self._category = "all"
    end
    self._sort_id   = self._prefs.sort_id   or nil
    self._sort_state = self._prefs.sort_state or SORT_STATE_NONE
    self._show_memory = self._prefs.show_memory or false

    self._matching_recipes = nil
    self._possible_recipes = nil
    self._backpack_recipes = nil
    self._highlighted_recipes = nil
    self._slot_data = {}
    self._cached_pot_counts = nil
    self._cached_fixed_counts = nil  -- 锅里按槽计的固定食材数（每格1，不含堆叠）
    self._last_pot_counts = nil
    self._cached_env_fingerprint = nil  -- 上次匹配时的环境指纹（季节+月相），环境变化需重算
    self._slot_debounce_task = nil
    self._active_popup_data = nil
    self._backpack_dirty = false
    self._scroll_to_prefab = nil
    self._cached_device_ingredients = nil
    self._cached_bag_counts = nil
    self._cached_bag_counts_raw = nil
    self._cached_sorted_defs = nil
    self._match_task = nil         -- 分片匹配任务
    self._match_task_bag_sig = nil -- 库存快照签名（用于取消过期任务）
    self._match_pending = false    -- 分片完成后待刷新
    self._match_step_scheduled = false  -- 分片每帧驱动是否已调度
    self._preserve_scroll = false  -- 渐进显示期间保持滚动位置
    self._last_backpack_partial = nil  -- 上次显示的渐进结果快照（避免无变化刷屏）
    self._match_task_cache_info = nil  -- 缓存写入信息 {bag_counts, fixed_counts, pot_counts}
    self._combo_status = nil        -- 组合计算状态：calculating（等待匹配枚举完整）/nil

	if self._enable_auto_cook then
        self._auto_cook = GetAutoCook()(self, range_init, self._auto_cook_source)
        if self._auto_cook_mode == "memory" then
            self._on_right_click = function(prefab)
                self._auto_cook:QuickCook(prefab)
            end
        end
    end

    self:SetScale(2 / 3, 2 / 3, 2 / 3)

    -- 按钮列要等 SetCooker 确定设备类型后再建（炼丹炉才有「关闭」按钮），见 SetCooker 末尾
    self.btn_root = self:AddChild(Widget("btn_root"))

    self.scroll_list = self:AddChild(RecipeList.Create(self))
    self.scroll_list:SetPosition(L.LIST_X, 0)

    self._calc_hint = nil  -- 头顶计算提示（懒创建，见 _CreateCalcHint）

    if self._enable_auto_cook and self._auto_cook_mode == "memory" then
        self._pot_bar = self:AddChild(PotPreviewBar(self._show_memory, function(checked)
            self._show_memory = checked
            self._prefs.show_memory = checked
        end, function()
            if self._pending_recipe_name then
                local idx = self._auto_cook:GetCurrentSlotIndex(self._pending_recipe_name)
                self._auto_cook:SwitchToRecipeSlot(self._pending_recipe_name, idx - 1)
            end
        end, function()
            if self._pending_recipe_name then
                local idx = self._auto_cook:GetCurrentSlotIndex(self._pending_recipe_name)
                self._auto_cook:SwitchToRecipeSlot(self._pending_recipe_name, idx + 1)
            end
        end, self._use_quantity_matching))
        self._pot_bar:SetPosition(L.LIST_X + L.LIST_WIDTH / 2 - self._pot_bar:GetBarWidth() / 2 - 3, L.LIST_TOP + 40 + self._pot_bar:GetBarHeight() / 2)

        self._range_arrows = self:AddChild(Widget("range_arrows"))
        local cb_local_x = -50
        local cb_local_y = -67
        local cb_world_x = self._pot_bar:GetPosition().x + cb_local_x
        local cb_world_y = self._pot_bar:GetPosition().y + cb_local_y
        local arrow_w = 32
        local arrow_base_x = cb_world_x - 60

        local function refresh_range()
            local v = self._auto_cook:GetRangeSearch()
            self._range_text:SetString(tostring(v))
        end

        self._arrow_left = self._range_arrows:AddChild(ImageButton(
            "images/ui.xml",
            "crafting_inventory_arrow_l_idle.tex",
            "crafting_inventory_arrow_l_hl.tex",
            nil, nil
        ))
        self._arrow_left:ForceImageSize(arrow_w, arrow_w)
        self._arrow_left:SetPosition(arrow_base_x - arrow_w / 2, cb_world_y)
        self._arrow_left:SetOnClick(function()
            self._auto_cook:SetRangeSearch(self._auto_cook:GetRangeSearch() - 1)
            refresh_range()
        end)

        self._range_text = self._range_arrows:AddChild(Text(UIFONT, 32, "30"))
        self._range_text:SetHAlign(ANCHOR_MIDDLE)
        self._range_text:SetPosition(arrow_base_x + 8, cb_world_y)

        self._arrow_right = self._range_arrows:AddChild(ImageButton(
            "images/ui.xml",
            "crafting_inventory_arrow_r_idle.tex",
            "crafting_inventory_arrow_r_hl.tex",
            nil, nil
        ))
        self._arrow_right:ForceImageSize(arrow_w, arrow_w)
        self._arrow_right:SetPosition(arrow_base_x + arrow_w / 2 + 16, cb_world_y)
        self._arrow_right:SetOnClick(function()
            self._auto_cook:SetRangeSearch(self._auto_cook:GetRangeSearch() + 1)
            refresh_range()
        end)

        refresh_range()
    end

    self._recipe_popup = self:AddChild(RecipePopup(self._prefs, function(recipe_item)
        return self:GetCraftableCombinations(recipe_item)
    end, function(recipe_name, ingredients, multi_pot)
        if not self._auto_cook then return end
        -- 炼丹炉不支持多锅联动：弹窗按钮右击视为无效
        if self._lj_mode and multi_pot then return end
        if self._auto_cook_mode == "memory" then
            self._auto_cook:QuickCookWithIngredients(recipe_name, ingredients)
        else
            self._auto_cook:CookWithIngredients(recipe_name, ingredients, multi_pot)
        end
    end))
    self._recipe_popup:SetPosition(140, 0)

    self:RefreshDisplay()
end)

function RecipePanel:MakeButtons()
    local entries = {}
    if self._enable_auto_cook and self._auto_cook_mode == "memory" and not self._lj_mode then
        table.insert(entries, { kind = "auto", label = STRINGS.CSP.BTN_AUTO_COOK })
    end
    for _, cfg in ipairs(CATEGORIES) do
        if cfg.id ~= "mod" or next(self.data.categories["mod"] or {}) then
            table.insert(entries, { kind = "cat", id = cfg.id, label = cfg.label })
        end
    end
    if self._backpack_check_mode ~= "off" then
        table.insert(entries, { kind = "cat", id = "craftable", label = STRINGS.CSP.CATEGORY_CRAFTABLE })
    end
    -- 炼丹炉：灵界自带的容器界面会被本面板挡住一格，追加「关闭」按钮收起本面板
    if self._lj_mode then
        table.insert(entries, { kind = "close", label = STRINGS.CSP.BTN_CLOSE })
    end

    -- 按钮列整体竖直居中：分类（含自动做饭、关闭）在上、排序在下
    local total = #entries + #SortButtons.SORTERS
    local start_y = (L.BTN_H + L.BTN_GAP) * (total - 1) / 2

    self._cat_buttons = self.btn_root:AddChild(CategoryButtons({
        entries = entries,
        current = self._category,
        start_y = start_y,
        on_select = function(id)
            self._category = id
            self._prefs.category = id
            self._cat_buttons:SetCurrent(id)
            self.scroll_list:ResetScroll()
            self:RefreshDisplay()
        end,
        on_auto_cook = function()
            self._auto_cook:Execute()
        end,
        on_close = function()
            self:RequestClose()
        end,
    }))

    self._sort_buttons = self.btn_root:AddChild(SortButtons({
        current_id = self._sort_id,
        current_state = self._sort_state,
        start_y = start_y - #entries * (L.BTN_H + L.BTN_GAP),
        on_change = function(id, state)
            self._sort_id = id
            self._sort_state = state
            self._prefs.sort_id = id
            self._prefs.sort_state = state
            self.scroll_list:ResetScroll()
            self:RefreshDisplay()
        end,
    }))
end

-- 收起本面板：只销毁模组面板，容器界面保持打开（回调由面板管理器注入）
function RecipePanel:RequestClose()
    if self._on_request_close then
        self._on_request_close()
    end
end

function RecipePanel:_BuildRawList()
    if self._category == "all" or self._category == "buff" or self._category == "craftable" then
        return self.data.all
    end
    if self._category == "cookpot" then
        local raw = {}
        local seen = {}
        local function add(cat)
            for _, v in ipairs(self.data.categories[cat] or {}) do
                if not seen[v.prefab] and v.is_vanilla then
                    seen[v.prefab] = true
                    table.insert(raw, v)
                end
            end
        end
        add("cookpot")
        add("portablecookpot")
        return raw
    end
    if self._category == "device" then
        local raw = {}
        local seen = {}
        if self._cooker_recipes then
            for _, v in ipairs(self.data.all) do
                -- 同名 prefab 多设备共存时，只保留当前设备那份（xd_liandanlu / xd_xcdf 丹方不同）
                if self._cooker_recipes[v.prefab] and not seen[v.prefab]
                    and (not v.device or v.device == self._cooker) then
                    seen[v.prefab] = true
                    table.insert(raw, v)
                end
            end
        end
        return raw
    end
    return self.data.categories[self._category] or {}
end

function RecipePanel:RefreshDisplay()
    if self._backpack_dirty then
        self:_RefreshBackpackRecipes()
    end

    -- 缓存 raw 列表，仅在分类或设备变更时重建
    local cache_key = self._category
    if self._category == "device" then
        cache_key = cache_key .. (self._cooker and ("_" .. self._cooker) or "")
    end
    if self._cached_raw_key ~= cache_key then
        self._cached_raw_key = cache_key
        self._cached_raw = self:_BuildRawList()
    end
    local raw = self._cached_raw

    local items = {}
    local is_buff = self._category == "buff"
    local is_craftable = self._category == "craftable"
    local filter = self._matching_recipes or self._possible_recipes

    -- 总览分类（全部/模组/BUFF）展示所有设备的料理，不受当前设备限制：
    -- 当前设备做不了的由列表按 _cooker_recipes 显示为锁定图标。
    -- 同名多设备丹方（xd_liandanlu / xd_xcdf）只留一条，优先当前设备那份。
    local show_all_devices = self._category == "all"
        or self._category == "mod"
        or self._category == "buff"
    if show_all_devices then
        local best = {}
        local order = {}
        for _, v in ipairs(raw) do
            local cur = best[v.prefab]
            if cur == nil then
                best[v.prefab] = v
                table.insert(order, v.prefab)
            elseif cur.device ~= self._cooker and v.device == self._cooker then
                best[v.prefab] = v
            end
        end
        local deduped = {}
        for _, prefab in ipairs(order) do
            table.insert(deduped, best[prefab])
        end
        raw = deduped
    end

    local seen = {}
    for _, v in ipairs(raw) do
        local valid = true
        -- 设备相关分类：同名丹药多设备共存时，只保留当前设备那份
        if not show_all_devices and v.device and v.device ~= self._cooker then
            valid = false
        end
        if valid and is_buff and not v.has_buff then
            valid = false
        end
        if valid and is_craftable then
            local has_backpack = self._backpack_recipes ~= nil
                and self._backpack_recipes[v.prefab]
            if not has_backpack then
                valid = false
            end
        end
        if valid and not is_craftable and filter and not filter[v.prefab] then
            valid = false
        end
        -- 可做分类按 prefab 去重（同名丹药只显示一次）
        if valid and is_craftable then
            if seen[v.prefab] then
                valid = false
            else
                seen[v.prefab] = true
            end
        end
        if valid then
            table.insert(items, v)
        end
    end

    if self._sort_id ~= nil and self._sort_state ~= SORT_STATE_NONE then
        local field = nil
        for _, s in ipairs(SortButtons.SORTERS) do
            if s.id == self._sort_id then
                field = s.field
                break
            end
        end
        if field ~= nil then
            local is_desc = self._sort_state == SORT_STATE_DESC
            table.sort(items, function(a, b)
                local va = a[field] or 0
                local vb = b[field] or 0
                if va ~= vb then
                    if is_desc then return va > vb else return va < vb end
                end
                return a.defaultsorthash < b.defaultsorthash
            end)
        end
    elseif self._pot_prefabs and #self._pot_prefabs > 0 then
        local scores = {}
        for _, v in ipairs(items) do
            scores[v.prefab] = self.data:GetRecipeMatchScore(v.recipe_requirements, self._pot_prefabs, self._brewing_ingredients)
        end
        table.sort(items, function(a, b)
            local sa = scores[a.prefab] or 0
            local sb = scores[b.prefab] or 0
            if sa ~= sb then
                return sa > sb
            end
            return a.defaultsorthash < b.defaultsorthash
        end)
    end

    self.scroll_list:SetItemsData(items)

    if self._scroll_to_prefab then
        local target = self._scroll_to_prefab
        self._scroll_to_prefab = nil
        for i, v in ipairs(items) do
            if v.prefab == target then
                local max_row = math.max(1, #items - L.VISIBLE_ROWS + 1)
                local target_row = math.clamp(i - math.floor(L.VISIBLE_ROWS / 2), 1, max_row)
                self.scroll_list:ScrollToScrollPos(target_row)
                break
            end
        end
    elseif not self._active_popup_data and not self._preserve_scroll then
        self.scroll_list:ScrollToScrollPos(1)
    end

    if self._active_popup_data then
        local still_visible
        local current_idx
        local data_changed = false
        for i, v in ipairs(items) do
            if v.prefab == self._active_popup_data.prefab then
                still_visible = true
                current_idx = i
                -- 数据重建（如环境变化触发 Collect）后，更新为最新数据对象并强制重渲染
                if v ~= self._active_popup_data then
                    self._active_popup_data = v
                    data_changed = true
                end
                break
            end
        end
        if still_visible then
            if not self._recipe_popup:IsVisible() or data_changed then
                self._recipe_popup:ShowForRecipe(self._active_popup_data, self._S, self._T)
            elseif self._recipe_popup._showing_craft then
                -- 仅可做配方视图下才刷新可做组合；最低需求视图下不调用，避免误改"最低需求"标题
                self._recipe_popup:_UpdateCraftView()
            end
            local max_row = math.max(1, #items - L.VISIBLE_ROWS + 1)
            local target_row = math.clamp(current_idx - math.floor(L.VISIBLE_ROWS / 2), 1, max_row)
            self.scroll_list:ScrollToScrollPos(target_row)
        else
            self._recipe_popup:Hide()
        end
    end

    self:_UpdateCalcHint()
end

function RecipePanel:SetAutoCookEnabled(enabled)
    if not self._cat_buttons then return end
    self._cat_buttons:SetAutoCookEnabled(enabled)
end

function RecipePanel:ScrollToRecipe(prefab)
    self._scroll_to_prefab = prefab
    self:RefreshDisplay()
end

function RecipePanel:SetAcceptsStacksFromContainer(container)
    if container and container.replica and container.replica.container then
        local rep = container.replica.container

        local num_slots = 4
        if rep.GetNumSlots then
            num_slots = rep:GetNumSlots()
        elseif rep.GetWidget then
            local widget = rep:GetWidget()
            if widget then
                num_slots = widget.numslots or (widget.slotpos and #widget.slotpos) or 4
            end
        end
        self._max_slots = num_slots
        -- 灵界炼丹炉共 5 格，但第 5 格只收异火燃料，参与配方的原料格固定 4 个
        if container.prefab == "lj_alchemy_furnace" then
            self._max_slots = 4
        end

        if rep.AcceptsStacks then
            self._accepts_stacks = rep:AcceptsStacks()
        elseif rep.acceptsstacks ~= nil then
            self._accepts_stacks = rep.acceptsstacks
        else
            self._accepts_stacks = false
        end
    else
        self._accepts_stacks = false
        self._max_slots = 4
    end

    -- 判断是否为特殊设备：某个料理配方中单个食材的需求量超过了设备格子数
    self._use_quantity_matching = false
    if self._cooker_recipes then
        for _, recipe_def in pairs(self._cooker_recipes) do
            if recipe_def.recipe then
                for _, count in pairs(recipe_def.recipe) do
                    if count > self._max_slots then
                        self._use_quantity_matching = true
                        break
                    end
                end
            end
            if self._use_quantity_matching then break end
            if recipe_def.alternative_recipe then
                for _, alt_group in pairs(recipe_def.alternative_recipe) do
                    for _, count in pairs(alt_group) do
                        if count > self._max_slots then
                            self._use_quantity_matching = true
                            break
                        end
                    end
                    if self._use_quantity_matching then break end
                end
            end
            if self._use_quantity_matching then break end
        end
    end
end

function RecipePanel:SetCooker(cooker_prefab, is_brewer)
    self._cooker = cooker_prefab
    self._is_brewer = is_brewer == true
    self._cached_bag_counts = nil
    self._cached_bag_counts_raw = nil

    self._lj_mode = nil

    if self._is_brewer then
        self._max_slots = 3
        local hof_brewing = _G.package.loaded["hof_brewing"]
        if hof_brewing then
            self._brewing_ingredients = hof_brewing.brewingredients
            self._brewer_recipes = (hof_brewing.recipes or {})[cooker_prefab] or {}
            self._cooker_recipes = self._brewer_recipes
            self._cached_device_ingredients = self._brewing_ingredients
        else
            self._brewing_ingredients = nil
            self._brewer_recipes = {}
            self._cooker_recipes = {}
            self._cached_device_ingredients = nil
        end
    else
        self._max_slots = 4
        self._brewing_ingredients = nil
        self._brewer_recipes = nil
        if cooker_prefab ~= nil then
            self._cooker_recipes = cooking.recipes[cooker_prefab] or {}
            if cooker_prefab == "lj_alchemy_furnace" then
                -- 灵界炼丹炉：配方不在 cooking.recipes 里，由数据层从灵界 mod 数据转换
                self._lj_mode = true
                self.data:EnsureCollected(cooker_prefab)
                self._cooker_recipes = self.data:GetLjRecipeMap()
                -- 原料槽 1~4；第 5 格是异火燃料，不参与配料，故格子数固定 4
                self._max_slots = 4
                self._lj_ingredients = {}
                for _, recipe_def in pairs(self._cooker_recipes) do
                    for ingredient in pairs(recipe_def.recipe or {}) do
                        self._lj_ingredients[ingredient] = true
                    end
                    if recipe_def.alternative_recipe then
                        for _, alt_group in ipairs(recipe_def.alternative_recipe) do
                            for ingredient in pairs(alt_group) do
                                self._lj_ingredients[ingredient] = true
                            end
                        end
                    end
                end
                self._cached_device_ingredients = self._lj_ingredients
            elseif cooker_prefab == "alchmy_fur" then
                if next(self._cooker_recipes) == nil and TUNING and TUNING.MYTH_PILL_RECIPES then
                    self._cooker_recipes = TUNING.MYTH_PILL_RECIPES
                end
                -- 神话数据可能延迟就绪，通知数据层补收集
                self.data:EnsureCollected("alchmy_fur")
                self._myth_ingredients = {}
                for _, recipe_def in pairs(self._cooker_recipes) do
                    if recipe_def.recipe then
                        for ingredient, _ in pairs(recipe_def.recipe) do
                            self._myth_ingredients[ingredient] = true
                        end
                    end
                end
                self._cached_device_ingredients = self._myth_ingredients
            elseif cooker_prefab == "xd_liandanlu" or cooker_prefab == "xd_xcdf" then
                if next(self._cooker_recipes) == nil and TUNING and TUNING.XD_PILL_RECIPES then
                    self._cooker_recipes = TUNING.XD_PILL_RECIPES[cooker_prefab] or {}
                end
                -- 登仙数据可能延迟就绪，通知数据层补收集
                self.data:EnsureCollected(cooker_prefab)
                self._xd_ingredients = {}
                for _, recipe_def in pairs(self._cooker_recipes) do
                    if recipe_def.recipe then
                        for ingredient, _ in pairs(recipe_def.recipe) do
                            self._xd_ingredients[ingredient] = true
                        end
                    end
                    if recipe_def.alternative_recipe then
                        for _, alt_group in pairs(recipe_def.alternative_recipe) do
                            for ingredient, _ in pairs(alt_group) do
                                self._xd_ingredients[ingredient] = true
                            end
                        end
                    end
                end
                self._cached_device_ingredients = self._xd_ingredients
            else
                self._myth_ingredients = nil
                self._lj_ingredients = nil
                self._cached_device_ingredients = {}
                for k, v in pairs(cooking.ingredients) do
                    self._cached_device_ingredients[k] = v
                end
                for alias, _ in pairs(self.data:GetIngredientAliases()) do
                    self._cached_device_ingredients[alias] = true
                end
            end
        else
            self._cooker_recipes = nil
            self._myth_ingredients = nil
            self._lj_ingredients = nil
            self._cached_device_ingredients = nil
        end
    end
    -- 缓存按优先级排序的料理列表（用于可做配方视图的优先级验证）
    self._cached_sorted_defs = nil
    if self._cooker_recipes then
        local sorted = {}
        for prefab, def in pairs(self._cooker_recipes) do
            table.insert(sorted, { prefab = prefab, def = def })
        end
        table.sort(sorted, function(a, b)
            local pa = a.def.priority or 0
            local pb = b.def.priority or 0
            if pa ~= pb then return pa > pb end
            return a.prefab < b.prefab
        end)
        self._cached_sorted_defs = sorted
    end
    -- 设备类型此时才确定：按钮列统一在此构建
    -- （炼丹炉隐藏「自动做饭」多锅联动入口，并追加「关闭」按钮）
    self.btn_root:KillAllChildren()
    self:MakeButtons()

    self._cached_raw_key = nil
    self:RefreshDisplay()
end


InstallMatch(RecipePanel)
InstallContainer(RecipePanel)
InstallCombo(RecipePanel)

return RecipePanel
