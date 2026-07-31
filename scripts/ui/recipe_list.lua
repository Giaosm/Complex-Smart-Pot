-- 料理列表：TrueScrollList 封装，单条目的渲染、高亮、锁定、点击/右键事件
-- 渲染时从 panel 读取状态字段：_highlighted_recipes / _cooker / _cooker_recipes /
--   _backpack_recipes / _select_mode / _active_popup_data / _recipe_popup / _S / _T /
--   _enable_auto_cook / _on_dish_click / _on_right_click / scroll_list
local Widget = require("widgets/widget")
local Image = require("widgets/image")
local ImageButton = require("widgets/imagebutton")
local TrueScrollList = require("widgets/truescrolllist")
local L = require("ui/panel_layout")

local CRAFTING_ATLAS_RESOLVED = resolvefilepath(CRAFTING_ATLAS)

local function SafeSetTexture(img, atlas, tex)
    if TheSim:AtlasContains(atlas, tex) then
        img:SetTexture(atlas, tex)
    else
        img:SetTexture("images/food_tags.xml", "unknown.tex")
    end
end

local function Create(panel)
    local scissor_x = -L.LIST_WIDTH / 2
    local scissor_y = -L.PANEL_HEIGHT / 2
    local scissor_w = L.LIST_WIDTH
    local scissor_h = L.LIST_HEIGHT

    return TrueScrollList(
        { data = panel.data },
        function(ctx, list_root, scroll_list)
            local bg_panel = list_root:AddChild(Image("images/global.xml", "square.tex"))
            bg_panel:SetScale(L.LIST_WIDTH + 16, L.LIST_HEIGHT + 16)
            bg_panel:SetTint(0.18, 0.12, 0.06, 0.85)
            bg_panel:SetPosition(0, 0)
            bg_panel:MoveToBack()

            local widgets = {}
            for i = 1, L.VISIBLE_ROWS do
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
                hover.image:ScaleToSize(L.SLOT_SIZE + 8, L.SLOT_SIZE + 8)
                hover.image:SetTint(0, 0, 0, 0)
                if panel._select_mode == "hover" then
                    hover:SetOnGainFocus(function()
                        if w._recipe_data then
                            if not (panel._active_popup_data and panel._active_popup_data.prefab == w._recipe_data.prefab) then
                                panel._active_popup_data = w._recipe_data
                                panel._recipe_popup:SetPosition(320, 0)
                                panel._recipe_popup:ShowForRecipe(w._recipe_data, panel._S, panel._T)
                                if panel._enable_auto_cook and panel._on_dish_click then
                                    panel._on_dish_click(w._recipe_data.prefab)
                                    panel.scroll_list:RefreshView()
                                end
                            end
                        end
                    end)
                    hover:SetOnClick(function()
                        if w._recipe_data then
                            if panel._active_popup_data and panel._active_popup_data.prefab == w._recipe_data.prefab then
                                panel._recipe_popup:Hide()
                                panel._active_popup_data = nil
                                if panel._on_dish_click then
                                    panel._on_dish_click(nil)
                                end
                            end
                        end
                    end)
                else
                    hover:SetOnClick(function()
                        if w._recipe_data then
                            if panel._active_popup_data and panel._active_popup_data.prefab == w._recipe_data.prefab then
                                panel._recipe_popup:Hide()
                                panel._active_popup_data = nil
                                if panel._on_dish_click then
                                    panel._on_dish_click(nil)
                                end
                            else
                                panel._active_popup_data = w._recipe_data
                                panel._recipe_popup:SetPosition(320, 0)
                                panel._recipe_popup:ShowForRecipe(w._recipe_data, panel._S, panel._T)
                                if panel._enable_auto_cook and panel._on_dish_click then
                                    panel._on_dish_click(w._recipe_data.prefab)
                                    panel.scroll_list:RefreshView()
                                end
                            end
                        end
                    end)
                end
                if panel._on_right_click then
                    local base_on_control = hover.OnControl
                    hover.OnControl = function(self_btn, control, down)
                        if control == CONTROL_SECONDARY and not down and w._recipe_data then
                            panel._on_right_click(w._recipe_data.prefab)
                            return true
                        end
                        return base_on_control(self_btn, control, down)
                    end
                end
                w:SetPosition(0, L.LIST_TOP - (i - 1) * L.ROW_HEIGHT)
                list_root:AddChild(w)
                table.insert(widgets, w)
            end
            return widgets, 1, L.ROW_HEIGHT, L.VISIBLE_ROWS, 1
        end,
        function(ctx, widget, data, index)
            local icon = widget._icon
            if data ~= nil then
                SafeSetTexture(icon, data.food_atlas, data.food_tex)
                local tex_w, tex_h = icon:GetSize()
                local scale = (L.SLOT_SIZE - 2) / math.max(tex_w, tex_h)
                icon:SetScale(scale)
                widget:Show()

                local is_highlighted = panel._highlighted_recipes ~= nil
                    and panel._highlighted_recipes[data.prefab]
                if is_highlighted then
                    widget._bg:SetTexture(CRAFTING_ATLAS_RESOLVED, "slot_bg_buffered.tex")
                else
                    widget._bg:SetTexture(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex")
                end

                local is_available = true
                if panel._cooker ~= nil and panel._cooker_recipes ~= nil then
                    is_available = panel._cooker_recipes[data.prefab] ~= nil
                end

                if is_highlighted then
                    icon:SetTint(1, 1, 1, 1)
                    widget._bg:SetTint(1, 1, 1, 1)
                    widget._lock:Hide()
                elseif is_available then
                    local has_backpack = panel._backpack_recipes ~= nil
                        and panel._backpack_recipes[data.prefab]
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
        14, -L.ROW_HEIGHT, 1
    )
end

return { Create = Create }
