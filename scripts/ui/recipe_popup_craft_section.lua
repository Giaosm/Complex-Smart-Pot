-- 可做配方区域：弹窗中"可做配方"视图，列出每种可做组合（食材图标 + 份数 + 烹饪按钮）
local Widget      = require("widgets/widget")
local ImageButton = require("widgets/imagebutton")
local Text        = require("widgets/text")

local Config = require "config/config_manager"
local Logger = require("debug/logger")
local ReqSection = require("ui/recipe_popup_req_section")
local ResolveInventoryItemAssets = require "utils/resolveinventoryitemassets"

local CraftSection = {}

-- 基于通用滚动区域创建，附带组合槽位/份数标签/烹饪按钮三个池
function CraftSection.Create(popup, y_offset, view_h)
    local section = ReqSection.Create(popup, "craft", y_offset, view_h)
    section.root:Hide()
    section.scrollbar:Hide()
    section.slot_pool = {}
    section.portions = {}
    section.btns = {}
    return section
end

-- 刷新可做组合列表
-- 返回组合数量；无数据或无取数函数时返回 nil（调用方据此决定是否更新标题）
function CraftSection.Update(popup, section, recipe_item)
    local content = section.content
    local pool = section.slot_pool
    local portions_labels = section.portions

    -- 清空旧槽位
    for _, slot in ipairs(pool) do slot:Hide() end
    for _, label in ipairs(portions_labels) do label:Hide() end
    for _, btn in ipairs(section.btns) do btn:Hide() end

    if not recipe_item or not popup._get_craftable_fn then
        return nil
    end

    local combos = popup._get_craftable_fn(recipe_item)
    local combo_count = combos and #combos or 0
    Logger.Logf("[智能锅] CraftSection.Update: recipe=%s combos=%d", recipe_item.prefab, combo_count)
    if combos and combo_count > 0 then
        for i, c in ipairs(combos) do
            local parts = {}
            for _, ing in ipairs(c.ingredients or {}) do
                if type(ing) == "table" and ing.prefab then
                    table.insert(parts, ing.prefab .. "=" .. ing.count)
                else
                    table.insert(parts, tostring(ing))
                end
            end
            Logger.Logf("[智能锅]   combo[%d]: portions=%d ingredients=%s", i, c.portions or 1, "[" .. table.concat(parts, ",") .. "]")
        end
    end
    local max_render = Config.GetMaxRenderCombos()
    if max_render > 0 and combo_count > max_render then
        local sliced = {}
        for i = 1, max_render do sliced[i] = combos[i] end
        combos = sliced
    end
    if combo_count == 0 then
        return combo_count
    end

    -- 使用与最低需求一致的尺寸：24px icon，26px 间距，36px 行高
    local icon_size = 24
    local spacing   = 26
    local y_step    = -36
    section.visible_rows = math.floor(section.view_h / (-y_step))
    section.max_rows = #combos

    local col_start_x = 7

    for ci, combo in ipairs(combos) do
        local ingrs = combo.ingredients
        -- 统一把食材项规范为 {prefab=, count=}，普通非堆叠设备 count 为 1
        local normalized = {}
        for _, ing in ipairs(ingrs) do
            if type(ing) == "table" and ing.prefab then
                table.insert(normalized, { prefab = ing.prefab, count = ing.count or 1 })
            else
                table.insert(normalized, { prefab = ing, count = 1 })
            end
        end
        local n = #normalized
        local slot_base = (ci - 1) * n
        local py = (ci - 1) * y_step

        -- 食材图标
        for si = 1, n do
            local idx = slot_base + si
            local slot
            if #pool >= idx then
                slot = pool[idx]
            else
                slot = ReqSection.CreatePoolSlot(content)
                table.insert(pool, slot)
            end
            local entry = normalized[si]
            local prefab = entry.prefab
            local tex, atlas = ResolveInventoryItemAssets(prefab)
            slot:Show()
            slot:SetPosition(col_start_x + (si - 1) * spacing, py)
            if atlas then
                pcall(slot.img.SetTexture, slot.img, atlas, tex)
            else
                slot.img:SetTexture("images/food_tags.xml", "unknown.tex")
            end
            slot.img:ScaleToSize(icon_size, icon_size)
            slot.bg:Show()
            slot.bg:ScaleToSize(spacing, spacing)
            -- 堆叠数量显示在图标下方，格式同需求视图的上下限
            if entry.count > 1 then
                slot.txt:SetPosition(0, -icon_size / 2)
                slot.txt:SetString("*" .. entry.count)
                slot.txt:SetColour(0.9, 0.9, 0.2, 1)
            else
                slot.txt:SetPosition(0, 0)
                slot.txt:SetString("")
            end
        end

        -- 份数标签
        local label
        if #portions_labels >= ci then
            label = portions_labels[ci]
        else
            label = content:AddChild(Text(NUMBERFONT, 14))
            table.insert(portions_labels, label)
        end
        label:Show()
        label:SetPosition(col_start_x + n * spacing + 4, py)
        label:SetString("×" .. combo.portions)
        label:SetColour(0.9, 0.8, 0.3, 1)

        -- 烹饪按钮
        local btn
        if #section.btns >= ci then
            btn = section.btns[ci]
        else
            btn = content:AddChild(ImageButton(
                "images/global_redux.xml",
                "button_carny_square_normal.tex",
                "button_carny_square_hover.tex",
                "button_carny_square_disabled.tex",
                "button_carny_square_down.tex"
            ))
            btn.scale_on_focus = false
            btn.move_on_click = false
            btn:SetFont(CHATFONT)
            btn:SetTextSize(18)
            table.insert(section.btns, btn)
        end
        btn:Show()
        btn:SetText(STRINGS.CSP.POPUP_COOK_BTN)
        btn:ForceImageSize(50, 20)
        btn:SetPosition(col_start_x + n * spacing + 46, py)
        local captured_combo = combo
        btn:SetOnClick(function()
            if popup._cook_fn and popup._current_recipe_data then
                popup._cook_fn(popup._current_recipe_data.prefab, captured_combo.ingredients)
            end
        end)
    end

    -- 隐藏多余项
    for i = #combos + 1, #portions_labels do
        portions_labels[i]:Hide()
    end
    for i = #combos + 1, #section.btns do
        section.btns[i]:Hide()
    end

    ReqSection.ApplyScroll(section)
    return combo_count
end

return CraftSection
