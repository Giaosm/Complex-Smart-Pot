-- 食谱面板：协调按钮列、料理列表、详情弹窗、预览条，负责容器监听、实时筛选、可做检测
local Widget         = require("widgets/widget")
local ImageButton    = require("widgets/imagebutton")
local Text           = require("widgets/text")
local FollowText     = require("widgets/followtext")
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
    self._last_pot_counts = nil
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
    self._combo_task = nil          -- 组合分片任务
    self._combo_step_scheduled = false  -- 组合分片每帧驱动是否已调度
    self._combo_task_recipe = nil   -- 组合分片对应的料理 prefab
    self._combo_status = nil        -- 组合计算状态：calculating/queued/nil
    self._last_combo_count = nil    -- 上一次显示的渐进组合数（避免无变化刷屏）

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
            local target_row = math.max(1, math.min(current_idx - math.floor(L.VISIBLE_ROWS / 2), max_row))
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
        -- 可堆叠设备：单格可放多份同种食材，从配方算出最大需求量
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
        max_per_type = self._max_slots - occupied_slots
    end

    local fixed_counts = {}
    for _, prefab in pairs(self._slot_data) do
        fixed_counts[prefab] = (fixed_counts[prefab] or 0) + 1
    end

    -- 库存/容器扫描已统一收口到 inventory_scanner（语义见重构待办第六节行为矩阵）
    if Logger.IsEnabled() then self._t_match_start = os.clock() end
    local bag_counts, raw_counts = Scanner.CountIngredientsForMode(
        self._player_inst, self._backpack_check_mode, max_per_type,
        self._cached_device_ingredients, self._container
    )

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
	-- 锅里材料变化（放入/取出）也必须重算：背包相同但锅状态不同，可做结果可能不同
	if same then
	    local last = self._last_pot_counts
	    local cur = pot_counts
	    if (last == nil) ~= (next(cur) == nil) then
	        same = false
	    else
	        for k, v in pairs(cur) do
	            if (last[k] or 0) ~= v then same = false; break end
	        end
	        if same then
	            for k, v in pairs(last) do
	                if (cur[k] or 0) ~= v then same = false; break end
	            end
	        end
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
	    self._last_pot_counts = pot_counts
	end
	self._cached_bag_counts_raw = raw_counts

	if not same then
	    if self.data:ShouldUseMatchTask(bag_counts, fixed_counts, self._max_slots, self._use_quantity_matching) then
	        -- 优先查组合映射缓存：命中即可立即展示（部分或完整），不完整则后台续算
	        local map_entry = self.data:GetCachedCombosMap(bag_counts, fixed_counts, pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
	        if map_entry and next(map_entry.combos) then
	            local set = self.data:GetRecipesFromCombosMap(map_entry)
	            self._backpack_recipes = {}
	            if set then
	                for k, _ in pairs(set) do
	                    self._backpack_recipes[k] = true
	                end
	            end
            if map_entry.complete then
                Logger.Logf("[智能锅][缓存] 命中完整映射缓存，直接使用（无续算）")
            else
                -- 部分缓存：先展示，同时续算补齐
                Logger.Logf("[智能锅][缓存] 命中未完成映射缓存，先展示已算部分并启动续算")
                self:_StartBackpackMatchTask(bag_counts, fixed_counts, pot_counts)
                self._match_pending = true
            end
	        else
	            local cached = self.data:GetCachedMatch(bag_counts, fixed_counts, pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
	            if cached then
	                self._backpack_recipes = {}  -- 拷贝，避免槽位检查污染缓存表
	                for k, _ in pairs(cached) do
	                    self._backpack_recipes[k] = true
	                end
	            else
	                self:_StartBackpackMatchTask(bag_counts, fixed_counts, pot_counts)
	                self._match_pending = true
	            end
	        end
	    else
	        self._backpack_recipes = self.data:GetMatchingRecipesFromCounts(self._cooker, bag_counts, fixed_counts, self._cooker_recipes, self._max_slots, self._brewing_ingredients, pot_counts, self._use_quantity_matching)
	    end
	end

        if not self._match_pending then
            -- 可做分类还需检查槽位容量：缺的材料种类数不能超过剩余格子
            self:_FilterByPossibleRecipes()
            self._backpack_dirty = false
            if Logger.IsEnabled() then
                local elapsed = self._t_match_start and (os.clock() - self._t_match_start) * 1000 or 0
                Logger.Logf("[智能锅] 扫描+匹配总耗时 %.1fms", elapsed)
                Logger.LogWorldContext()
                Logger.LogScanResult(self._max_slots, self._use_quantity_matching, self._backpack_check_mode, bag_counts)
                Logger.LogMatchResult(self._backpack_recipes)
                self._t_match_start = nil
            end
            if self.data.LogCacheStats then self.data:LogCacheStats() end
        end
    end
    -- 分片模式保持 dirty 由 OnUpdate 驱动，完成后再置 false
    if not self._match_pending then
        self._backpack_dirty = false
    end
end

-- ============ 方案A：分片匹配任务驱动 ============

-- 比较两个哈希表是否含完全相同的键集合
local function SameKeySet(a, b)
    if a == b then return true end
    if (a == nil) ~= (b == nil) then return false end
    for k in pairs(a) do
        if not b[k] then return false end
    end
    for k in pairs(b) do
        if not a[k] then return false end
    end
    return true
end

-- 懒创建头顶计算提示（StopMonitor 销毁后下次显示时自动重建）
function RecipePanel:_CreateCalcHint()
    if self._calc_hint then return end
    if ThePlayer and ThePlayer.HUD then
        self._calc_hint = FollowText(UIFONT, 28, STRINGS.CSP.CALCULATING)
        self._calc_hint:SetHUD(ThePlayer.HUD.inst)
        self._calc_hint:SetTarget(ThePlayer)
        self._calc_hint:SetOffset(Vector3(0, -350, 0))
        self._calc_hint:SetScreenOffset(0, 0)
        if self._calc_hint.text then
            self._calc_hint.text:SetHAlign(ANCHOR_MIDDLE)
        end
        ThePlayer.HUD:AddChild(self._calc_hint)
        self._calc_hint:Hide()
    end
end

-- 计算中在玩家头顶显示提示，完成/无任务时隐藏
function RecipePanel:_UpdateCalcHint()
    if self._match_task then
        self:_CreateCalcHint()
        if self._calc_hint then
            self._calc_hint:Show()
        end
    elseif self._calc_hint then
        self._calc_hint:Hide()
    end
end

-- 可做分类的槽位容量检查：就地过滤 self._backpack_recipes，返回是否还有剩余
function RecipePanel:_FilterByPossibleRecipes()
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
    return self._backpack_recipes ~= nil
end

function RecipePanel:_StartBackpackMatchTask(bag_counts, fixed_counts, pot_counts)
    self:_CancelBackpackMatchTask()
    self._last_backpack_partial = nil
    pot_counts = pot_counts or self._cached_pot_counts or {}
    local task = self.data:CreateMatchTask(
        self._cooker, bag_counts, fixed_counts, self._cooker_recipes,
        self._max_slots, self._brewing_ingredients, pot_counts,
        self._use_quantity_matching
    )
    self._match_task = task
    self._match_task_cache_info = { bag_counts, fixed_counts, pot_counts }
    self._match_pending = true
    self._backpack_dirty = false
    self:_ScheduleMatchStep()
end

-- 每帧 DoTaskInTime 驱动一次任务推进，_match_step_scheduled 防同帧叠加
function RecipePanel:_ScheduleMatchStep()
    if not self._match_task then return end
    if self._match_step_scheduled then return end
    self._match_step_scheduled = true
    self.inst:DoTaskInTime(0, function()
        self._match_step_scheduled = false
        if not self._match_task then return end
        self:_StepBackpackMatchTask()
        if self._match_task then
            self:_ScheduleMatchStep()
        end
    end)
end

function RecipePanel:_CancelBackpackMatchTask()
    if self._match_task then
        -- 面板被打断/库存变化前，把已算出的组合映射（partial）写入缓存（标记未完成）
        -- 下次开锅命中即可先展示已算部分，再后台续算补齐，避免完全重算
        if self._match_task_cache_info then
            local info = self._match_task_cache_info
            local partial_combos = self._match_task:GetPartialCombos()
            if partial_combos and next(partial_combos) then
                self.data:CacheCombosMap(partial_combos, info[1], info[2], info[3], self._cooker_recipes, self._max_slots, self._use_quantity_matching, false)
            end
        end
        self._match_task:Cancel()
        self._match_task = nil
    end
    self._match_step_scheduled = false
    self._match_task_cache_info = nil
end

-- 单帧推进（循环时间片直到用满帧预算或完成）；渐进显示：把新算出的部分结果应用到列表
function RecipePanel:_StepBackpackMatchTask()
    local task = self._match_task
    if not task then return end
    if self._backpack_dirty then
        self:_CancelBackpackMatchTask()  -- 库存已变化，结果作废
        self._match_pending = false
        return
    end
    local t0 = os.clock() * 1000
    local frame_budget = 12
    local partial_updated = false
    while self._match_task do
        local done = task:Step(12)
        local partial = task:GetPartialResult()
        if partial ~= nil then
            local new_bp = {}
            for k, _ in pairs(partial) do
                new_bp[k] = true
            end
            -- 仅当有新增料理时才刷新，避免无变化刷屏；拷贝避免污染协程内部 result
            if not SameKeySet(self._last_backpack_partial, new_bp) then
                self._backpack_recipes = new_bp
                self._last_backpack_partial = {}
                for k, _ in pairs(new_bp) do
                    self._last_backpack_partial[k] = true
                end
                partial_updated = true
            end
        end
        if done then
            self:_ApplyBackpackMatchResult(task:GetResult(), task:GetPartialCombos())
            return
        end
        if os.clock() * 1000 - t0 >= frame_budget then
            break
        end
    end
    if partial_updated and self._match_task then
        self:_ApplyBackpackPartialDisplay()
    end
end

-- 渐进显示刷新：保持滚动位置，不标记完成
function RecipePanel:_ApplyBackpackPartialDisplay()
    self:_FilterByPossibleRecipes()
    self._preserve_scroll = true
    if self.RefreshDisplay then self:RefreshDisplay() end
    self._preserve_scroll = false
end

-- 应用分片匹配结果（后处理 + 写缓存 + 刷新）
function RecipePanel:_ApplyBackpackMatchResult(result, combos_map)
    self._match_task = nil
    self._match_step_scheduled = false
    self._last_backpack_partial = nil
    if self._match_task_cache_info then
        local info = self._match_task_cache_info
        -- 任务完成时把完整组合映射写入缓存（标记 complete=true），供组合路径复用
        self.data:CacheMatch(result, info[1], info[2], info[3], self._cooker_recipes, self._max_slots, self._use_quantity_matching, combos_map, true)
        self._match_task_cache_info = nil
    end
    self._backpack_recipes = {}
    if result ~= nil then
        for k, _ in pairs(result) do
            self._backpack_recipes[k] = true
        end
    end
    self._match_pending = false

    -- 可做分类还需检查槽位容量：缺的材料种类数不能超过剩余格子
    self:_FilterByPossibleRecipes()

    self._backpack_dirty = false
    if Logger.IsEnabled() then
        local elapsed = self._t_match_start and (os.clock() - self._t_match_start) * 1000 or 0
        Logger.Logf("[智能锅] 扫描+匹配总耗时 %.1fms", elapsed)
        Logger.LogScanResult(self._max_slots, self._use_quantity_matching, self._backpack_check_mode, self._cached_bag_counts or {})
        Logger.LogMatchResult(self._backpack_recipes)
        self._t_match_start = nil
    end
    if self.data.LogCacheStats then self.data:LogCacheStats() end
    if self.RefreshDisplay then self:RefreshDisplay() end
end

-- 库存变化时取消分片任务（结果作废，下次刷新重启）；任务推进由 DoTaskInTime 驱动
function RecipePanel:OnUpdate(dt)
    if self._match_task and self._backpack_dirty then
        self:_CancelBackpackMatchTask()
        self._match_step_scheduled = false
        self._match_pending = false
    end
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
            self:_DebouncedSlotChanged()
        end
    end

    self._onitemlose = function(inst, data)
        if data ~= nil and data.slot ~= nil then
            self._slot_data[data.slot] = nil
            self:_DebouncedSlotChanged()
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
            self:_DebouncedSlotChanged()
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
    if self._slot_debounce_task then
        self._slot_debounce_task:Cancel()
        self._slot_debounce_task = nil
    end
    if self._on_player_equip then
        self._player_inst:RemoveEventCallback("equip", self._on_player_equip)
        self._on_player_equip = nil
    end
    if self._on_player_unequip then
        self._player_inst:RemoveEventCallback("unequip", self._on_player_unequip)
        self._on_player_unequip = nil
    end
    self:_CancelBackpackMatchTask()
    self:_CancelComboTask()
    self._match_pending = false
    if self._inv_debounce_task then
        self._inv_debounce_task:Cancel()
        self._inv_debounce_task = nil
    end
    if self._calc_hint then  -- 挂在 HUD 上，需手动清理避免残留
        self._calc_hint:Kill()
        self._calc_hint = nil
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

-- 锅里槽位变化防抖刷新：跨容器移动（如 shift+左击 从锅移到冰箱）时，
-- 锅的 itemlose 先触发，若立即刷新扫描，目标容器（冰箱）尚未收到材料，
-- 会导致 raw_counts 丢失移动中的材料、份数偏低。延迟到移动完成后再统一刷新。
function RecipePanel:_DebouncedSlotChanged()
    if self._slot_debounce_task then
        self._slot_debounce_task:Cancel()
    end
    self._slot_debounce_task = self.inst:DoTaskInTime(0.15, function()
        self._slot_debounce_task = nil
        self:OnSlotChanged()
    end)
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

-- 判断组合回溯规模是否巨大、值得分片（不可堆叠 + 候选食材种类超过阈值）
function RecipePanel:_ShouldUseComboTask()
    local bag_counts = self._cached_bag_counts
    if not bag_counts then return false end
    local num_types = 0
    for _ in pairs(bag_counts) do
        num_types = num_types + 1
    end
    return num_types >= 10
end

-- 启动组合分片任务
function RecipePanel:_StartComboTask(recipe_item)
    self:_CancelComboTask()
    local task = self.data:CreateComboTask(
        recipe_item,
        self._cached_bag_counts,
        self._cached_pot_counts,
        self._cooker,
        self._max_slots,
        self._use_quantity_matching,
        self._cached_bag_counts_raw,
        self._cached_sorted_defs
    )
    self._combo_task = task
    self._combo_task_recipe = recipe_item.prefab
    self._combo_status = "calculating"
    self._last_combo_count = nil
    self:_SyncComboStatusToPopup()
    self:_ScheduleComboStep()
end

-- 每帧推进组合分片任务，完成后刷新弹窗
function RecipePanel:_ScheduleComboStep()
    if not self._combo_task then return end
    if self._combo_step_scheduled then return end
    self._combo_step_scheduled = true
    self.inst:DoTaskInTime(0, function()
        self._combo_step_scheduled = false
        if not self._combo_task then return end
        -- 优化：已切出可做配方视图（如切换到最低需求视图）时，组合结果不再被展示，
        -- 提前取消后台分片计算，避免白算浪费性能
        local popup = self._recipe_popup
        if popup and popup._showing_craft ~= nil and not popup._showing_craft then
            self:_CancelComboTask()
            return
        end
        local done = self._combo_task:Step(12)
        if not done then
            -- 渐进：仅当弹窗仍显示正在计算的料理(A)时才更新其进度数字，
            -- 避免 A 的进度被显示到 B 的标题下（B 排队中不更新数字）
            local pc = self._combo_task:GetPartialCount()
            local popup = self._recipe_popup
            local cur = popup and popup._current_recipe_data
            if pc ~= nil and pc ~= self._last_combo_count
                and cur ~= nil and cur.prefab == self._combo_task_recipe then
                self._last_combo_count = pc
                popup:_UpdateCraftCountLabel(pc)
            end
            self:_ScheduleComboStep()
        else
            local recipe = self._combo_task_recipe
            self._combo_task = nil
            self._combo_task_recipe = nil
            self._combo_status = nil
            self:_SyncComboStatusToPopup()
            self:_RefreshComboPopup(recipe)
        end
    end)
end

function RecipePanel:_CancelComboTask()
    if self._combo_task then
        self._combo_task:Cancel()
        self._combo_task = nil
    end
    self._combo_step_scheduled = false
    self._combo_task_recipe = nil
    self._combo_status = nil
    self:_SyncComboStatusToPopup()
end

-- 组合算完后刷新弹窗（仅当弹窗仍显示刚算完的料理，避免算完 A 误刷新 B）
function RecipePanel:_RefreshComboPopup(recipe_prefab)
    local popup = self._recipe_popup
    if popup and popup:IsVisible() and popup._showing_craft then
        if recipe_prefab == nil or (popup._current_recipe_data and popup._current_recipe_data.prefab == recipe_prefab) then
            popup:_UpdateCraftView()
        end
    end
end

-- 把组合计算状态同步到弹窗（CraftSection.Update 通过 popup._combo_status 读取显示提示）
function RecipePanel:_SyncComboStatusToPopup()
    if self._recipe_popup then
        self._recipe_popup._combo_status = self._combo_status
    end
end

-- 从匹配路径共享的组合映射缓存中还原目标料理的可做组合
-- 返回 { ingredients={ {prefab,count}, ... }, portions=N } 列表，未命中返回 nil
function RecipePanel:_RestoreCombosFromMap(recipe_item)
    local bag_counts = self._cached_bag_counts
    if not bag_counts or next(bag_counts) == nil then return nil end
    local pot_counts = self._cached_pot_counts or {}
    local raw_bag_counts = self._cached_bag_counts_raw or bag_counts

    -- 匹配缓存 key 用 fixed_counts（锅里占的槽）；不可堆叠设备 pot_counts 即 fixed_counts
    local map_entry = self.data:GetCachedCombosMap(bag_counts, pot_counts, pot_counts, self._cooker_recipes, self._max_slots, self._use_quantity_matching)
    if not map_entry or next(map_entry.combos) == nil then
        return nil
    end
    local map_count = 0
    for _ in pairs(map_entry.combos) do map_count = map_count + 1 end
    Logger.Logf("[智能锅][缓存][组合复用] 命中映射缓存 recipe=%s combos=%d complete=%s",
        recipe_item.prefab, map_count, tostring(map_entry.complete))

    local target = recipe_item.prefab
    local target_priority = recipe_item.recipe_def and recipe_item.recipe_def.priority or 0

    -- 每个组合只能产出最高优先级的料理；目标料理须是该组合的最高优先级之一才视为可做
    local available = {}
    for k, v in pairs(pot_counts) do available[k] = (available[k] or 0) + v end
    for k, v in pairs(raw_bag_counts) do available[k] = (available[k] or 0) + v end

    local result = {}
    for combo_key, matched in pairs(map_entry.combos) do
        -- 计算该组合的最高优先级
        local max_p = nil
        for _, p in pairs(matched) do
            if max_p == nil or p > max_p then max_p = p end
        end
        if max_p ~= nil and matched[target] ~= nil and max_p == target_priority then
            -- 还原组合：组合串 "a,b,b" 展开为槽位列表（普通锅每个槽位一个食材，显示独立图标）
            local ingredients = {}
            for prefab in combo_key:gmatch("[^,]+") do
                table.insert(ingredients, prefab)
            end
            -- 份数 = 最紧缺食材可提供的份数
            local counts = {}
            for _, prefab in ipairs(ingredients) do
                counts[prefab] = (counts[prefab] or 0) + 1
            end
            local portions = math.huge
            for prefab, cnt in pairs(counts) do
                local have = (available[prefab] or 0)
                if cnt > 0 then
                    portions = math.min(portions, math.floor(have / cnt))
                end
            end
            portions = math.max(1, portions)
            table.insert(result, { ingredients = ingredients, portions = portions })
        end
    end

    if #result == 0 then
        return nil
    end
    table.sort(result, function(a, b) return a.portions > b.portions end)
    return result
end

function RecipePanel:GetCraftableCombinations(recipe_item)
    if not recipe_item then return nil end

    -- 组合分片计算中：返回 nil，记录状态（当前在算=calculating，其他在算排队=queued）
    if self._combo_task then
        if self._combo_task_recipe == recipe_item.prefab then
            self._combo_status = "calculating"
        else
            self._combo_status = "queued"
        end
        self:_SyncComboStatusToPopup()
        return nil
    end
    self._combo_status = nil
    self:_SyncComboStatusToPopup()

    -- 复用匹配路径的组合映射缓存：不可堆叠设备优先从映射还原，避免重复枚举
    if not self._use_quantity_matching then
        local restored = self:_RestoreCombosFromMap(recipe_item)
        if restored ~= nil then
            return restored
        end
    end

    -- 组合量巨大（不可堆叠 + 食材种类多）且未在计算时：先查缓存，命中直接返回，未命中启动分片任务
    if not self._use_quantity_matching and self:_ShouldUseComboTask() then
        local cached = self.data:GetCachedCombos(recipe_item, self._cached_bag_counts, self._cached_pot_counts, self._cached_bag_counts_raw, self._use_quantity_matching)
        if cached ~= nil then
            return cached
        end
        self:_StartComboTask(recipe_item)
        return nil
    end

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
    return r
end

return RecipePanel
