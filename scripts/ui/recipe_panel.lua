-- 食谱面板：协调分类/排序按钮列、料理列表、详情弹窗、预览条等子组件，
-- 并负责容器监听、实时筛选、背包「可做」检测
local Widget         = require("widgets/widget")
local ImageButton    = require("widgets/imagebutton")
local Text           = require("widgets/text")
local RecipePopup    = require("ui/recipe_popup")
local PotPreviewBar  = require("ui/pot_preview_bar")
local CategoryButtons = require("ui/category_buttons")
local SortButtons    = require("ui/sort_buttons")
local RecipeList     = require("ui/recipe_list")
local L              = require("ui/panel_layout")

local cooking = require("cooking")
local Scanner = require("inventory/inventory_scanner")
local Logger = require("debug/logger")

local AutoCook = nil
local GetStackSize = require("utils/getstacksize")

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
    self._active_popup_data = nil
    self._backpack_dirty = false
    self._scroll_to_prefab = nil
    self._cached_device_ingredients = nil
    self._cached_bag_counts = nil
    self._cached_bag_counts_raw = nil
    self._cached_sorted_defs = nil

	if self._enable_auto_cook then
        self._auto_cook = GetAutoCook()(self, range_init, self._auto_cook_source)
        if self._auto_cook_mode == "memory" then
            self._on_right_click = function(prefab)
                self._auto_cook:QuickCook(prefab)
            end
        end
    end

    self:SetScale(2 / 3, 2 / 3, 2 / 3)

    self.btn_root = self:AddChild(Widget("btn_root"))
    self:MakeButtons()

    self.scroll_list = self:AddChild(RecipeList.Create(self))
    self.scroll_list:SetPosition(L.LIST_X, 0)

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
        Logger.Logf("[智能锅] 弹窗烹饪回调: mode=%s multi_pot=%s recipe=%s",
            tostring(self._auto_cook_mode), tostring(multi_pot), tostring(recipe_name))
        if not self._auto_cook then return end
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
    if self._enable_auto_cook and self._auto_cook_mode == "memory" then
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

    -- 按钮列整体竖直居中：分类（含自动做饭）在上、排序在下
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
        if self._cooker_recipes then
            for _, v in ipairs(self.data.all) do
                if self._cooker_recipes[v.prefab] then
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
    for _, v in ipairs(raw) do
        local valid = true
        if is_buff and not v.has_buff then
            valid = false
        end
        if is_craftable then
            local has_backpack = self._backpack_recipes ~= nil
                and self._backpack_recipes[v.prefab]
            if not has_backpack then
                valid = false
            end
        end
        if valid and not is_craftable and filter and not filter[v.prefab] then
            valid = false
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
                local target_row = math.max(1, math.min(i - math.floor(L.VISIBLE_ROWS / 2), max_row))
                self.scroll_list:ScrollToScrollPos(target_row)
                break
            end
        end
    elseif not self._active_popup_data then
        self.scroll_list:ScrollToScrollPos(1)
    end

    if self._active_popup_data then
        local still_visible
        local current_idx
        for i, v in ipairs(items) do
            if v.prefab == self._active_popup_data.prefab then
                still_visible = true
                current_idx = i
                break
            end
        end
        if still_visible then
            if not self._recipe_popup:IsVisible() then
                self._recipe_popup:ShowForRecipe(self._active_popup_data, self._S, self._T)
            else
                self._recipe_popup:_UpdateCraftView()
            end
            local max_row = math.max(1, #items - L.VISIBLE_ROWS + 1)
            local target_row = math.max(1, math.min(current_idx - math.floor(L.VISIBLE_ROWS / 2), max_row))
            self.scroll_list:ScrollToScrollPos(target_row)
        else
            self._recipe_popup:Hide()
        end
    end
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

        -- 动态获取格子数量：优先用 replica 的 GetNumSlots，否则从 widget 推断
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

        -- 动态获取是否可堆叠
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

    if self._is_brewer then
        self._max_slots = 3 -- 默认值，后续会被 SetAcceptsStacksFromContainer 动态覆盖
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
        self._max_slots = 4 -- 默认值，后续会被 SetAcceptsStacksFromContainer 动态覆盖
        self._brewing_ingredients = nil
        self._brewer_recipes = nil
        if cooker_prefab ~= nil then
            self._cooker_recipes = cooking.recipes[cooker_prefab] or {}
            if cooker_prefab == "alchmy_fur" then
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
    self._cached_raw_key = nil
    self:RefreshDisplay()
end

function RecipePanel:_RefreshBackpackRecipes()
    if self._backpack_check_mode == "off" or not self._player_inst or not self._cooker then
        self._backpack_recipes = nil
        return
    end

    local inv = self._player_inst.replica and self._player_inst.replica.inventory
    if not inv then
        return
    end

    local pot_counts = self._cached_pot_counts or {}
    local occupied_slots = 0
    for _ in pairs(self._slot_data) do
        occupied_slots = occupied_slots + 1
    end

    if occupied_slots >= self._max_slots then
        self._backpack_recipes = self.data:GetHighlightedRecipes(self._matching_recipes, self._cooker_recipes)
        self._cached_bag_counts = {}
        self._backpack_dirty = false
        return
    end

    local max_per_type
    if self._use_quantity_matching then
        -- 炼丹炉等可堆叠特殊设备：单个格子可放大量同种食材，从配方中算出最大需求量
        local max_needed = 0
        for _, recipe_def in pairs(self._cooker_recipes or {}) do
            if recipe_def.recipe then
                for _, count in pairs(recipe_def.recipe) do
                    max_needed = math.max(max_needed, count)
                end
            end
            if recipe_def.alternative_recipe then
                for _, alt_group in pairs(recipe_def.alternative_recipe) do
                    for _, count in pairs(alt_group) do
                        max_needed = math.max(max_needed, count)
                    end
                end
            end
        end
        max_per_type = math.max(max_needed, self._max_slots - occupied_slots)
    else
        -- 普通烹饪设备：每个格子只算 1 份食材，扫描上限 = 剩余槽位数
        max_per_type = self._max_slots - occupied_slots
    end

    local fixed_counts = {}
    for _, prefab in pairs(self._slot_data) do
        fixed_counts[prefab] = (fixed_counts[prefab] or 0) + 1
    end

    -- 库存/容器扫描已统一收口到 inventory_scanner（语义见重构待办第六节行为矩阵）
    local _t_scan
    if Logger.IsEnabled() then _t_scan = os.clock() end
    local bag_counts, raw_counts = Scanner.CountIngredientsForMode(
        self._player_inst, self._backpack_check_mode, max_per_type,
        self._cached_device_ingredients, self._container
    )
    if Logger.IsEnabled() then
        Logger.Logf("[智能锅] 扫描耗时 %.1fms", (os.clock() - _t_scan) * 1000)
    end

    if next(bag_counts) == nil then
	self._backpack_recipes = nil
	self._cached_bag_counts = {}
    else
	local cached = self._cached_bag_counts
	local same = cached and true or false
	if same then
	    for k, v in pairs(bag_counts) do
	        if (cached[k] or 0) ~= math.min(v, max_per_type) then same = false; break end
	    end
	end
	if same then
	    for k, v in pairs(cached) do
	        if v ~= math.min(bag_counts[k] or 0, max_per_type) then same = false; break end
	    end
	end
	if same then
	    self._backpack_dirty = false
	    if not self._active_popup_data then
	        self._cached_bag_counts_raw = raw_counts
	        return
	    end
	else
	    self._cached_bag_counts = {}
	    for k, v in pairs(bag_counts) do
	        self._cached_bag_counts[k] = math.min(v, max_per_type)
	    end
	end
	self._cached_bag_counts_raw = raw_counts

	if not same then
	    local _t_match
	    if Logger.IsEnabled() then _t_match = os.clock() end
	    self._backpack_recipes = self.data:GetMatchingRecipesFromCounts(self._cooker, bag_counts, fixed_counts, self._cooker_recipes, self._max_slots, self._brewing_ingredients, pot_counts, self._use_quantity_matching)
	    if Logger.IsEnabled() then
	        Logger.Logf("[智能锅] 匹配耗时 %.1fms", (os.clock() - _t_match) * 1000)
	    end
	    Logger.LogWorldContext()
	end

        Logger.LogScanResult(self._max_slots, self._use_quantity_matching, self._backpack_check_mode, bag_counts)
        Logger.LogMatchResult(self._backpack_recipes)
        -- 可做分类还需检查槽位容量：缺的材料种类数不能超过剩余格子
        -- 防止丹药类配方 bag_have 补充后数量够但格子不够装的情况
        if self._backpack_recipes and self._possible_recipes then
            for prefab, _ in pairs(self._backpack_recipes) do
                if not self._possible_recipes[prefab] then
                    self._backpack_recipes[prefab] = nil
                end
            end
            if next(self._backpack_recipes) == nil then
                self._backpack_recipes = nil
            end
        end
    end
    self._backpack_dirty = false
end

function RecipePanel:SetPotIngredients(prefab_list, cooker)
    self._pot_prefabs = prefab_list
    if prefab_list ~= nil and #prefab_list >= 1 then
        if #prefab_list >= self._max_slots then
            self._possible_recipes = nil
            self._matching_recipes = self.data:GetMatchingRecipes(cooker, prefab_list, self._brewing_ingredients, self._cached_pot_counts)
            self._highlighted_recipes = self.data:GetHighlightedRecipes(self._matching_recipes, self._cooker_recipes)
        else
            self._possible_recipes = self.data:GetPossibleRecipes(
                prefab_list,
                self._brewing_ingredients,
                self._max_slots,
                self._is_brewer and self.data:GetMaxTagValues("brewer") or nil,
                self._cached_pot_counts,
                self._use_quantity_matching
            )
            self._matching_recipes = nil
            self._highlighted_recipes = nil
        end
    else
        self._possible_recipes = nil
        self._matching_recipes = nil
        self._highlighted_recipes = nil
    end
    self:RefreshDisplay()
end

function RecipePanel:StartMonitor(container)
    self:StopMonitor()

    self._container = container
    self._slot_data = {}

    self._onitemget = function(inst, data)
        if data ~= nil and data.slot ~= nil and data.item ~= nil and data.item.prefab ~= nil then
            self._slot_data[data.slot] = data.item.prefab
            self:OnSlotChanged()
        end
    end

    self._onitemlose = function(inst, data)
        if data ~= nil and data.slot ~= nil then
            self._slot_data[data.slot] = nil
            self:OnSlotChanged()
        end
    end

    self._onrefresh = function()
        local items = nil
        if container.GetItems ~= nil then
            items = container:GetItems()
        elseif container.components ~= nil and container.components.container ~= nil
            and container.components.container.GetItems ~= nil then
            items = container.components.container:GetItems()
        elseif container.replica ~= nil and container.replica.container ~= nil then
            local rep = container.replica.container
            if rep.GetItems ~= nil then
                items = rep:GetItems()
            elseif rep.GetNumSlots ~= nil then
                items = {}
                for i = 0, rep:GetNumSlots() - 1 do
                    local item = rep:GetItemInSlot(i)
                    if item ~= nil then
                        items[i] = item
                    end
                end
            end
        end

        if items ~= nil then
            self._slot_data = {}
            for i, item in pairs(items) do
                if item ~= nil and item.prefab ~= nil then
                    self._slot_data[i] = item.prefab
                end
            end
            self:OnSlotChanged()
        end
    end

    self.inst:ListenForEvent("itemget", self._onitemget, container)
    self.inst:ListenForEvent("itemlose", self._onitemlose, container)
    self.inst:ListenForEvent("refresh", self._onrefresh, container)

    if self._backpack_check_mode ~= "off" and self._player_inst then
        self._on_player_inventory_change = function()
            self._backpack_dirty = true
            if self._inv_debounce_task then
                self._inv_debounce_task:Cancel()
            end
            self._inv_debounce_task = self.inst:DoTaskInTime(0.15, function()
                self._inv_debounce_task = nil
                self:RefreshDisplay()
            end)
        end
        self._player_inst:ListenForEvent("itemget", self._on_player_inventory_change)
        self._player_inst:ListenForEvent("itemlose", self._on_player_inventory_change)
        self._player_inst:ListenForEvent("stacksizechange", self._on_player_inventory_change)

        self._on_player_equip = function(_, meta)
            if meta and meta.item and self:_IsContainerItem(meta.item) then
                self._backpack_dirty = true
                self:RefreshDisplay()
            end
        end
        self._on_player_unequip = function(_, meta)
            if meta and meta.eslot and self:_IsContainerSlot(meta.eslot) then
                self._backpack_dirty = true
                self:RefreshDisplay()
            end
        end
        self._player_inst:ListenForEvent("equip", self._on_player_equip)
        self._player_inst:ListenForEvent("unequip", self._on_player_unequip)
    end

    self._backpack_dirty = self._backpack_check_mode ~= "off"

    self._onrefresh()
end

function RecipePanel:StopMonitor()
    if self._onitemget then
        self.inst:RemoveEventCallback("itemget", self._onitemget, self._container)
        self._onitemget = nil
    end
    if self._onitemlose then
        self.inst:RemoveEventCallback("itemlose", self._onitemlose, self._container)
        self._onitemlose = nil
    end
    if self._onrefresh then
        self.inst:RemoveEventCallback("refresh", self._onrefresh, self._container)
        self._onrefresh = nil
    end
    if self._on_player_inventory_change then
        self._player_inst:RemoveEventCallback("itemget", self._on_player_inventory_change)
        self._player_inst:RemoveEventCallback("itemlose", self._on_player_inventory_change)
        self._player_inst:RemoveEventCallback("stacksizechange", self._on_player_inventory_change)
        self._on_player_inventory_change = nil
    end
    if self._on_player_equip then
        self._player_inst:RemoveEventCallback("equip", self._on_player_equip)
        self._on_player_equip = nil
    end
    if self._on_player_unequip then
        self._player_inst:RemoveEventCallback("unequip", self._on_player_unequip)
        self._on_player_unequip = nil
    end
    self._container = nil
end

function RecipePanel:MarkBackpackDirty()
    self._backpack_dirty = true
end

function RecipePanel:_IsContainerItem(item)
    if not item then return false end
    return item:HasTag("container") or item:HasTag("backpack") or item:HasTag("body")
end

function RecipePanel:_IsContainerSlot(eslot)
    return eslot == "body" or eslot == "backpack"
end

function RecipePanel:OnSlotChanged()
    local prefabs = {}
    local counts = {}
    for slot_idx, prefab in pairs(self._slot_data) do
        table.insert(prefabs, prefab)
        local item = self._container and self._container.replica
            and self._container.replica.container
            and self._container.replica.container:GetItemInSlot(slot_idx)
        local stack_size = item and GetStackSize(item) or 1
        counts[prefab] = (counts[prefab] or 0) + stack_size
    end
    self._cached_pot_counts = counts
    self._backpack_dirty = true
    self:SetPotIngredients(prefabs, self._container)
end

function RecipePanel:GetCraftableCombinations(recipe_item)
    if not recipe_item then return nil end
    Logger.Logf("[智能锅] GetCraftableCombinations: recipe=%s qmatch=%s max_slots=%d",
        recipe_item.prefab, tostring(self._use_quantity_matching), self._max_slots or 4)
    local _t_combo
    if Logger.IsEnabled() then _t_combo = os.clock() end
    local r = self.data:GetRecipeCraftableCombos(
        recipe_item,
        self._cached_bag_counts,
        self._cached_pot_counts,
        self._cooker,
        self._max_slots,
        self._use_quantity_matching,
        self._cached_bag_counts_raw,
        self._cached_sorted_defs
    )
    if Logger.IsEnabled() then
        Logger.Logf("[智能锅] 可做组合耗时 %.1fms", (os.clock() - _t_combo) * 1000)
    end
    Logger.LogLazy(function()
        return string.format("[智能锅] GetCraftableCombinations 返回: recipe=%s result=%s",
            recipe_item.prefab, r and ("count=" .. #r) or "nil")
    end)
    return r
end

return RecipePanel
