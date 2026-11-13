-- 锅容器监听与锅内状态维护：由 recipe_panel 通过 Install 挂回方法
local GetStackSize = require("utils/getstacksize")

return function(RecipePanel)
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
        -- 只统计原料格：灵界炼丹炉第 5 格为异火燃料，不参与配方
        if slot_idx <= self._max_slots then
            table.insert(prefabs, prefab)
            local item = self._container and self._container.replica
                and self._container.replica.container
                and self._container.replica.container:GetItemInSlot(slot_idx)
            local stack_size = item and GetStackSize(item) or 1
            counts[prefab] = (counts[prefab] or 0) + stack_size
        end
    end
    self._cached_pot_counts = counts
    self._backpack_dirty = true
    self:SetPotIngredients(prefabs, self._container)
end
end
