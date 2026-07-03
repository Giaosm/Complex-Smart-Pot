-- 自动做饭预览条：显示槽位食材，支持 5 套配方记忆切换
local Widget = require("widgets/widget")
local Image = require("widgets/image")
local ImageButton = require("widgets/imagebutton")
local Text = require("widgets/text")
local ResolveInventoryItemAssets = require("utils/resolveinventoryitemassets")

local CRAFTING_ATLAS_RESOLVED = resolvefilepath(CRAFTING_ATLAS)

local SLOT_VISUAL = 64
local SLOT_GAP = 6
local SLOT_PAD = 4
local CHECKBOX_SIZE = 36

local PotPreviewBar = Class(Widget, function(self, initial_checked, on_toggle, on_up, on_down)
    Widget._ctor(self, "PotPreviewBar")

    self._checked = initial_checked or false
    self._on_toggle = on_toggle

    local slot_area_w = 4 * SLOT_VISUAL + 3 * SLOT_GAP + SLOT_PAD * 2
    self._total_w = slot_area_w
    self._total_h = SLOT_VISUAL + SLOT_PAD * 2

    self._bar_root = self:AddChild(Widget("bar_root"))

    local bg = self._bar_root:AddChild(Image("images/global.xml", "square.tex"))
    bg:ScaleToSize(self._total_w, self._total_h)
    bg:SetTint(0.18, 0.12, 0.06, 0.85)
    bg:MoveToBack()

    self._slot_icons = {}
    local slot_area_x = -self._total_w / 2
    for i = 1, 4 do
        local slot = self._bar_root:AddChild(Widget("slot_" .. i))
        slot:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex")):SetScale(0.5)
        local icon = slot:AddChild(Image("images/ui.xml", "blank.tex"))
        icon:SetScale(0.90)
        slot:SetPosition(slot_area_x + SLOT_PAD + SLOT_VISUAL / 2 + (i - 1) * (SLOT_VISUAL + SLOT_GAP), 0)
        table.insert(self._slot_icons, icon)
    end

    local arrow_size = 32
    local arrow_y_gap = 2
    local arrow_x = slot_area_x + SLOT_PAD + 4 * SLOT_VISUAL + 3 * SLOT_GAP + SLOT_PAD + arrow_size / 2

    self._slot_label = self._bar_root:AddChild(Text(UIFONT, 20, "1/5"))
    self._slot_label:SetHAlign(ANCHOR_MIDDLE)
    self._slot_label:SetPosition(arrow_x, 0)

    self._arrow_up = self._bar_root:AddChild(ImageButton(
        "images/ui.xml", "crafting_inventory_arrow_r_idle.tex", "crafting_inventory_arrow_r_hl.tex", nil, nil
    ))
    self._arrow_up:ForceImageSize(arrow_size, arrow_size)
    self._arrow_up:SetPosition(arrow_x, arrow_y_gap + arrow_size / 2)
    self._arrow_up.image:SetRotation(-90)
    self._arrow_up.scale_on_focus = false
    self._arrow_up.move_on_click = false
    self._arrow_up:SetOnClick(on_up or function() end)

    self._arrow_down = self._bar_root:AddChild(ImageButton(
        "images/ui.xml", "crafting_inventory_arrow_r_idle.tex", "crafting_inventory_arrow_r_hl.tex", nil, nil
    ))
    self._arrow_down:ForceImageSize(arrow_size, arrow_size)
    self._arrow_down:SetPosition(arrow_x, -arrow_y_gap - arrow_size / 2)
    self._arrow_down.image:SetRotation(90)
    self._arrow_down.scale_on_focus = false
    self._arrow_down.move_on_click = false
    self._arrow_down:SetOnClick(on_down or function() end)

    self.cb_icon = self:AddChild(Image("images/button_icons2.xml", self._checked and "enabled_filter.tex" or "disabled_filter.tex"))
    self.cb_icon:ScaleToSize(CHECKBOX_SIZE, CHECKBOX_SIZE)
    self.cb_icon:SetPosition(-50, -67)

    self.cb_btn = self:AddChild(ImageButton(
        "images/ui.xml", "blank.tex", "blank.tex", nil, "blank.tex",
        nil, nil, {1, 1}, {0, 0}
    ))
    self.cb_btn.image:ScaleToSize(CHECKBOX_SIZE + 8, CHECKBOX_SIZE + 8)
    self.cb_btn.image:SetTint(0, 0, 0, 0)
    self.cb_btn:SetPosition(-50, -67)
    self.cb_btn.scale_on_focus = false
    self.cb_btn.move_on_click = false
    self.cb_btn:SetOnClick(function()
        self._checked = not self._checked
        local tex = self._checked and "enabled_filter.tex" or "disabled_filter.tex"
        self.cb_icon:SetTexture("images/button_icons2.xml", tex)
        if self._checked then
            self._bar_root:Show()
        else
            self._bar_root:Hide()
        end
        if self._on_toggle then
            self._on_toggle(self._checked)
        end
    end)

    if not self._checked then
        self._bar_root:Hide()
    end
end)

function PotPreviewBar:GetBarWidth() return self._total_w end
function PotPreviewBar:GetBarHeight() return self._total_h end
function PotPreviewBar:IsChecked() return self._checked end

function PotPreviewBar:SetSlotLabel(text)
    if self._slot_label then
        self._slot_label:SetString(text)
    end
end

function PotPreviewBar:UpdateSlots(ingredients)
    for i = 1, 4 do
        local icon = self._slot_icons[i]
        if not icon then break end
        icon:SetTexture("images/ui.xml", "blank.tex")
    end

    for i = 1, 4 do
        local icon = self._slot_icons[i]
        if not icon then break end

        if ingredients and ingredients[i] then
            local prefab = ingredients[i]
            local tex, atlas, _ = ResolveInventoryItemAssets(prefab)
            icon:SetTexture(atlas, tex)
            icon:SetTint(1, 1, 1, 1)
        end
    end
end

return PotPreviewBar