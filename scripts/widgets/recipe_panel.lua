local Widget         = require("widgets/widget")
local Image          = require("widgets/image")
local ImageButton    = require("widgets/imagebutton")
local Text           = require("widgets/text")
local TrueScrollList = require("widgets/truescrolllist")
local RecipePopup    = require("widgets/recipe_popup")
local PotPreviewBar  = require("widgets/pot_preview_bar")

local CRAFTING_ATLAS_RESOLVED = resolvefilepath(CRAFTING_ATLAS)

local function SafeSetTexture(img, atlas, tex)
    local ok = pcall(img.SetTexture, img, atlas, tex)
    if not ok then
        img:SetTexture("images/food_tags.xml", "unknown.tex")
    end
end
local cooking = require("cooking")

local AutoCook = nil
local function GetAutoCook()
    if not AutoCook then
        AutoCook = require("auto_cook")
    end
    return AutoCook
end

local SLOT_SIZE      = 64
local PADDING        = 6
local ROW_HEIGHT     = SLOT_SIZE + PADDING
local VISIBLE_ROWS   = 6

local LIST_HEIGHT    = VISIBLE_ROWS * ROW_HEIGHT
local LIST_WIDTH     = SLOT_SIZE + 12

local BTN_W          = 100
local BTN_H          = 40
local BTN_GAP        = 1

local BTN_AREA_W     = BTN_W + 8
local PANEL_WIDTH    = BTN_AREA_W + 8 + LIST_WIDTH
local PANEL_HEIGHT   = LIST_HEIGHT

local LIST_X         = PANEL_WIDTH / 2 - LIST_WIDTH / 2 - 4
local BTN_X          = -PANEL_WIDTH / 2 + BTN_W / 2 + 4
local LIST_TOP       = PANEL_HEIGHT / 2 - ROW_HEIGHT / 2

local CATEGORIES = {
    { id = "all",        label = STRINGS.CSP.CATEGORY_ALL },
    { id = "cookpot",    label = STRINGS.CSP.CATEGORY_COOKPOT },
    { id = "device",     label = STRINGS.CSP.CATEGORY_DEVICE },
    { id = "mod",        label = STRINGS.CSP.CATEGORY_MOD },
    { id = "buff",       label = STRINGS.CSP.CATEGORY_BUFF },
}

local SORTERS = {
    { id = "hunger", label = STRINGS.CSP.SORT_HUNGER, field = "hunger" },
    { id = "health", label = STRINGS.CSP.SORT_HEALTH, field = "health" },
    { id = "sanity", label = STRINGS.CSP.SORT_SANITY, field = "sanity" },
}

local SORT_STATE_NONE = 0
local SORT_STATE_DESC = 1
local SORT_STATE_ASC  = 2

local RecipePanel = Class(Widget, function(self, cookbook_data, env, player_inst, backpack_check_mode, enable_auto_cook, range_init, prefs)
    Widget._ctor(self, "RecipePanel")

    self.data = cookbook_data
    self._S = env.strings
    self._T = env.tuning
    self._player_inst = player_inst
    self._backpack_check_mode = backpack_check_mode or "off"
    self._enable_auto_cook = enable_auto_cook ~= false
    self._prefs = prefs or {}

    self._cooker = nil
    self._cooker_recipes = nil
    self._is_brewer = false
    self._brewing_ingredients = nil
    self._brewer_recipes = nil
    self._max_slots = 4

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

    if self._enable_auto_cook then
        self._auto_cook = GetAutoCook()(self, range_init)
    end

    self:SetScale(2 / 3, 2 / 3, 2 / 3)

    self.btn_root = self:AddChild(Widget("btn_root"))
    self:MakeButtons()

    self.scroll_list = self:AddChild(self:MakeScrollList())
    self.scroll_list:SetPosition(LIST_X, 0)

    if self._enable_auto_cook then
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
        end))
        self._pot_bar:SetPosition(LIST_X + LIST_WIDTH / 2 - self._pot_bar:GetBarWidth() / 2 - 3, LIST_TOP + 40 + self._pot_bar:GetBarHeight() / 2)

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

    self._recipe_popup = self:AddChild(RecipePopup())
    self._recipe_popup:SetPosition(140, 0)

    self:RefreshDisplay()
end)

function RecipePanel:MakeButtons()
    local all_btns = {}
    if self._enable_auto_cook then
        table.insert(all_btns, { type = "dummy", cfg = { label = STRINGS.CSP.BTN_AUTO_COOK } })
    end
    for _, cfg in ipairs(CATEGORIES) do
        if cfg.id ~= "mod" or next(self.data.categories["mod"] or {}) then
            table.insert(all_btns, { type = "cat", cfg = cfg })
        end
    end
    if self._backpack_check_mode ~= "off" then
        table.insert(all_btns, { type = "cat", cfg = { id = "craftable", label = STRINGS.CSP.CATEGORY_CRAFTABLE } })
    end
    for _, cfg in ipairs(SORTERS) do
        table.insert(all_btns, { type = "sort", cfg = cfg })
    end

    local start_y = (BTN_H + BTN_GAP) * (#all_btns - 1) / 2
    self._cat_btns = {}
    self._sort_btns = {}

    for idx, entry in ipairs(all_btns) do
        local cfg = entry.cfg
        local btn = self.btn_root:AddChild(ImageButton(
            "images/global_redux.xml",
            "button_carny_square_normal.tex",
            "button_carny_square_hover.tex",
            "button_carny_square_disabled.tex",
            "button_carny_square_down.tex"
        ))
        btn:ForceImageSize(BTN_W, BTN_H)
        btn:SetText(cfg.label)
        btn:SetFont(CHATFONT)
        btn:SetTextSize(25)

        local y = start_y - (idx - 1) * (BTN_H + BTN_GAP)
        btn:SetPosition(BTN_X, y)

        if entry.type == "cat" then
            local function refresh_cat()
                if self._category == cfg.id then
                    btn.image:SetTexture("images/global_redux.xml", "button_carny_square_hover.tex")
                    btn.image:SetTint(1, 1, 1, 1)
                else
                    btn.image:SetTexture("images/global_redux.xml", "button_carny_square_normal.tex")
                    btn.image:SetTint(0.5, 0.5, 0.5, 1)
                end
            end
            btn:SetOnClick(function()
                self._category = cfg.id
                self._prefs.category = cfg.id
                for _, b in ipairs(self._cat_btns) do b.refresh() end
                self.scroll_list:ResetScroll()
                self:RefreshDisplay()
            end)
            btn.refresh = refresh_cat
            refresh_cat()
            table.insert(self._cat_btns, btn)
        elseif entry.type == "sort" then
            local function refresh_sort()
                if self._sort_id == cfg.id then
                    if self._sort_state == SORT_STATE_DESC then
                        btn:SetText("▼" .. cfg.label)
                        btn.image:SetTexture("images/global_redux.xml", "button_carny_square_hover.tex")
                        btn.image:SetTint(1, 1, 1, 1)
                    elseif self._sort_state == SORT_STATE_ASC then
                        btn:SetText("▲" .. cfg.label)
                        btn.image:SetTexture("images/global_redux.xml", "button_carny_square_hover.tex")
                        btn.image:SetTint(1, 1, 1, 1)
                    end
                else
                    btn:SetText(cfg.label)
                    btn.image:SetTexture("images/global_redux.xml", "button_carny_square_normal.tex")
                    btn.image:SetTint(0.5, 0.5, 0.5, 1)
                end
            end
            btn:SetOnClick(function()
                if self._sort_id == cfg.id then
                    if self._sort_state == SORT_STATE_DESC then
                        self._sort_state = SORT_STATE_ASC
                    elseif self._sort_state == SORT_STATE_ASC then
                        self._sort_id = nil
                        self._sort_state = SORT_STATE_NONE
                    end
                else
                    self._sort_id = cfg.id
                    self._sort_state = SORT_STATE_DESC
                end
                self._prefs.sort_id = self._sort_id
                self._prefs.sort_state = self._sort_state
                for _, b in ipairs(self._sort_btns) do b.refresh() end
                self.scroll_list:ResetScroll()
                self:RefreshDisplay()
            end)
            btn.refresh = refresh_sort
            refresh_sort()
            table.insert(self._sort_btns, btn)
        else
            self._auto_cook_btn = btn
            btn:Disable()
            btn:SetOnClick(function()
                self._auto_cook:Execute()
            end)
        end
    end
end

function RecipePanel:MakeScrollList()
    local scissor_x = -LIST_WIDTH / 2
    local scissor_y = -PANEL_HEIGHT / 2
    local scissor_w = LIST_WIDTH
    local scissor_h = LIST_HEIGHT

    return TrueScrollList(
        { data = self.data },
        function(ctx, list_root, scroll_list)
            local bg_panel = list_root:AddChild(Image("images/global.xml", "square.tex"))
            bg_panel:SetScale(LIST_WIDTH + 16, LIST_HEIGHT + 16)
            bg_panel:SetTint(0.18, 0.12, 0.06, 0.85)
            bg_panel:SetPosition(0, 0)
            bg_panel:MoveToBack()

            local widgets = {}
            for i = 1, VISIBLE_ROWS do
                local w = Widget("recipe_slot_" .. i)
                local bg = w:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex"))
                bg:SetScale(0.5)
                w._bg = bg

                local icon = w:AddChild(Image("images/ui.xml", "blank.tex"))
                icon:SetScale(0.20)
                w._icon = icon

                local lock = w:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_fg_lock.tex"))
                lock:SetScale(0.5)
                w._lock = lock

                local hover = w:AddChild(ImageButton(
                    "images/ui.xml", "blank.tex", "blank.tex", "blank.tex",
                    nil, nil, {1, 1}, {0, 0}
                ))
                hover.scale_on_focus = false
                hover.move_on_click = false
                hover.image:ScaleToSize(SLOT_SIZE + 8, SLOT_SIZE + 8)
                hover.image:SetTint(0, 0, 0, 0)
                hover:SetOnClick(function()
                    if w._recipe_data then
                        if self._active_popup_data and self._active_popup_data.prefab == w._recipe_data.prefab then
                            self._recipe_popup:Hide()
                            self._active_popup_data = nil
                            if self._on_dish_click then
                                self._on_dish_click(nil)
                            end
                        else
                            self._active_popup_data = w._recipe_data
                            self._recipe_popup:SetPosition(320, 0)
                            self._recipe_popup:ShowForRecipe(w._recipe_data, self._S, self._T)
                            if self._enable_auto_cook and self._on_dish_click then
                                self._on_dish_click(w._recipe_data.prefab)
                                self.scroll_list:RefreshView()
                            end
                        end
                    end
                end)
                w:SetPosition(0, LIST_TOP - (i - 1) * ROW_HEIGHT)
                list_root:AddChild(w)
                table.insert(widgets, w)
            end
            return widgets, 1, ROW_HEIGHT, VISIBLE_ROWS, 1
        end,
        function(ctx, widget, data, index)
            local icon = widget._icon
            if data ~= nil then
                SafeSetTexture(icon, data.food_atlas, data.food_tex)
                local tex_w, tex_h = icon:GetSize()
                local scale = (SLOT_SIZE - 2) / math.max(tex_w, tex_h)
                icon:SetScale(scale)
                widget:Show()

                local is_highlighted = self._highlighted_recipes ~= nil
                    and self._highlighted_recipes[data.prefab]
                if is_highlighted then
                    widget._bg:SetTexture(CRAFTING_ATLAS_RESOLVED, "slot_bg_buffered.tex")
                else
                    widget._bg:SetTexture(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex")
                end

                local is_available = true
                if self._cooker ~= nil and self._cooker_recipes ~= nil then
                    is_available = self._cooker_recipes[data.prefab] ~= nil
                end

                if is_highlighted then
                    icon:SetTint(1, 1, 1, 1)
                    widget._bg:SetTint(1, 1, 1, 1)
                    widget._lock:Hide()
                elseif is_available then
                    local has_backpack = self._backpack_recipes ~= nil
                        and self._backpack_recipes[data.prefab]
                    if has_backpack then
                        icon:SetTint(1, 1, 1, 1)
                        widget._bg:SetTint(1, 1, 1, 1)
                    else
                        icon:SetTint(0.25, 0.25, 0.25, 1)
                        widget._bg:SetTint(0.5, 0.45, 0.35, 1)
                    end
                    widget._lock:Hide()
                else
                    icon:SetTint(0.1, 0.1, 0.1, 1)
                    widget._bg:SetTint(0.3, 0.25, 0.15, 1)
                    widget._lock:Show()
                end
                icon:Show()
                widget._recipe_data = data
            else
                widget:Hide()
            end
        end,
        scissor_x, scissor_y, scissor_w, scissor_h,
        14, -ROW_HEIGHT, 1
    )
end

function RecipePanel:RefreshDisplay()
    if self._backpack_dirty then
        self:_RefreshBackpackRecipes()
    end

    local raw
    if self._category == "all" or self._category == "buff" or self._category == "craftable" then
        raw = self.data.all
    elseif self._category == "cookpot" then
        raw = {}
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
    elseif self._category == "device" then
        raw = {}
        if self._cooker_recipes then
            for _, v in ipairs(self.data.all) do
                if self._cooker_recipes[v.prefab] then
                    table.insert(raw, v)
                end
            end
        end
    else
        raw = self.data.categories[self._category] or {}
    end

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
        for _, s in ipairs(SORTERS) do
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
                local max_row = math.max(1, #items - VISIBLE_ROWS + 1)
                local target_row = math.max(1, math.min(i - math.floor(VISIBLE_ROWS / 2), max_row))
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
            end
            local max_row = math.max(1, #items - VISIBLE_ROWS + 1)
            local target_row = math.max(1, math.min(current_idx - math.floor(VISIBLE_ROWS / 2), max_row))
            self.scroll_list:ScrollToScrollPos(target_row)
        else
            self._recipe_popup:Hide()
        end
    end
end

function RecipePanel:SetAutoCookEnabled(enabled)
    if not self._auto_cook_btn then return end
    if enabled then
        self._auto_cook_btn:Enable()
    else
        self._auto_cook_btn:Disable()
    end
end

function RecipePanel:ScrollToRecipe(prefab)
    self._scroll_to_prefab = prefab
    self:RefreshDisplay()
end

function RecipePanel:SetCooker(cooker_prefab, is_brewer)
    self._cooker = cooker_prefab
    self._is_brewer = is_brewer == true

    if self._is_brewer then
        self._max_slots = 3
        local hof_brewing = _G.package.loaded["hof_brewing"]
        if hof_brewing then
            self._brewing_ingredients = hof_brewing.brewingredients
            self._brewer_recipes = (hof_brewing.recipes or {})[cooker_prefab] or {}
            self._cooker_recipes = self._brewer_recipes
        else
            self._brewing_ingredients = nil
            self._brewer_recipes = {}
            self._cooker_recipes = {}
        end
    else
        self._max_slots = 4
        self._brewing_ingredients = nil
        self._brewer_recipes = nil
        if cooker_prefab ~= nil then
            self._cooker_recipes = cooking.recipes[cooker_prefab] or {}
            if next(self._cooker_recipes) == nil and cooker_prefab == "alchmy_fur" then
                if TUNING and TUNING.MYTH_PILL_RECIPES then
                    self._cooker_recipes = TUNING.MYTH_PILL_RECIPES
                end
                if self.data and self.data._CollectMythRecipes then
                    self.data:_CollectMythRecipes()
                end
            end
            if cooker_prefab == "alchmy_fur" and self._cooker_recipes then
                self._myth_ingredients = {}
                for _, recipe_def in pairs(self._cooker_recipes) do
                    if recipe_def.recipe then
                        for ingredient, _ in pairs(recipe_def.recipe) do
                            self._myth_ingredients[ingredient] = true
                        end
                    end
                end
            else
                self._myth_ingredients = nil
            end
        else
            self._cooker_recipes = nil
        end
    end
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
    local pot_count = 0
    for _, c in pairs(pot_counts) do
        pot_count = pot_count + c
    end

    if pot_count >= self._max_slots then
        self._backpack_recipes = self.data:GetHighlightedRecipes(self._matching_recipes, self._cooker_recipes)
        self._backpack_dirty = false
        return
    end

    local max_per_type = self._max_slots - pot_count
    local function count_items(items, bag_counts)
        if not items then return end
        for _, item in pairs(items) do
            if item and item.prefab then
                local is_ingredient = cooking.ingredients[item.prefab] ~= nil
                    or cooking.ingredients[self.data._ingredient_aliases[item.prefab]] ~= nil
                    or (self._brewing_ingredients and self._brewing_ingredients[item.prefab])
                    or (self._myth_ingredients and self._myth_ingredients[item.prefab])
                if is_ingredient then
                    local count = 1
                    if item.replica and item.replica.stackable then
                        count = item.replica.stackable:StackSize()
                    elseif item.components and item.components.stackable then
                        count = item.components.stackable:StackSize()
                    end
                    bag_counts[item.prefab] = math.min((bag_counts[item.prefab] or 0) + count, max_per_type)
                end
            end
        end
    end

    local bag_counts = {}
    count_items(inv:GetItems(), bag_counts)

    if self._backpack_check_mode == "backpack_and_inv" or self._backpack_check_mode == "all" then
        local open_containers = inv:GetOpenContainers() or {}
        for container_inst, _ in pairs(open_containers) do
            if container_inst ~= self._container then
                local container = container_inst.replica and container_inst.replica.container
                if container then
                    local is_backpack = container_inst:HasTag("INLIMBO")
                    if is_backpack or self._backpack_check_mode == "all" then
                        count_items(container:GetItems(), bag_counts)
                    end
                end
            end
        end
    end

    self._backpack_recipes = self.data:GetMatchingRecipesFromCounts(self._cooker, bag_counts, pot_counts, self._cooker_recipes, self._max_slots, self._brewing_ingredients)
    self._backpack_dirty = false
end

function RecipePanel:SetPotIngredients(prefab_list, cooker)
    self._pot_prefabs = prefab_list
    if prefab_list ~= nil and #prefab_list >= 1 then
        if #prefab_list >= self._max_slots then
            self._possible_recipes = nil
            self._matching_recipes = self.data:GetMatchingRecipes(cooker, prefab_list, self._brewing_ingredients)
            self._highlighted_recipes = self.data:GetHighlightedRecipes(self._matching_recipes, self._cooker_recipes)
        else
            self._possible_recipes = self.data:GetPossibleRecipes(
                prefab_list,
                self._brewing_ingredients,
                self._max_slots,
                self._is_brewer and self.data._brewer_max_tag_values or nil
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
            self:RefreshDisplay()
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
    for _, prefab in pairs(self._slot_data) do
        table.insert(prefabs, prefab)
        counts[prefab] = (counts[prefab] or 0) + 1
    end
    self._cached_pot_counts = counts
    self._backpack_dirty = true
    self:SetPotIngredients(prefabs, self._container)
end

return RecipePanel
