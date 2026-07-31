-- 排序按钮列：三维排序（生命/饱食/理智），点击循环 降序→升序→取消
local Widget = require("widgets/widget")
local ImageButton = require("widgets/imagebutton")
local L = require("ui/panel_layout")

local SORTERS = {
    { id = "hunger", label = STRINGS.CSP.SORT_HUNGER, field = "hunger" },
    { id = "health", label = STRINGS.CSP.SORT_HEALTH, field = "health" },
    { id = "sanity", label = STRINGS.CSP.SORT_SANITY, field = "sanity" },
}

local SORT_STATE_NONE = 0
local SORT_STATE_DESC = 1
local SORT_STATE_ASC  = 2

local SortButtons = Class(Widget, function(self, opts)
    Widget._ctor(self, "SortButtons")
    -- opts = {
    --   current_id    = 当前排序 id（nil 表示未排序）,
    --   current_state = 当前排序状态,
    --   start_y       = 第一个按钮的 y 坐标,
    --   on_change     = fn(id, state),  -- 排序状态变化（id 可能为 nil）
    -- }
    self._on_change = opts.on_change
    self._sort_id = opts.current_id
    self._sort_state = opts.current_state or SORT_STATE_NONE
    self._btns = {}

    for idx, cfg in ipairs(SORTERS) do
        local btn = self:AddChild(ImageButton(
            "images/global_redux.xml",
            "button_carny_square_normal.tex",
            "button_carny_square_hover.tex",
            "button_carny_square_disabled.tex",
            "button_carny_square_down.tex"
        ))
        btn:ForceImageSize(L.BTN_W, L.BTN_H)
        btn:SetFont(CHATFONT)
        btn:SetTextSize(25)
        btn:SetPosition(L.BTN_X, opts.start_y - (idx - 1) * (L.BTN_H + L.BTN_GAP))

        local id = cfg.id
        btn:SetOnClick(function()
            -- 循环：未选中→降序→升序→取消
            if self._sort_id == id then
                if self._sort_state == SORT_STATE_DESC then
                    self._sort_state = SORT_STATE_ASC
                elseif self._sort_state == SORT_STATE_ASC then
                    self._sort_id = nil
                    self._sort_state = SORT_STATE_NONE
                end
            else
                self._sort_id = id
                self._sort_state = SORT_STATE_DESC
            end
            self:_Refresh()
            self._on_change(self._sort_id, self._sort_state)
        end)

        table.insert(self._btns, { btn = btn, cfg = cfg })
    end

    self:_Refresh()
end)

function SortButtons:_Refresh()
    for _, entry in ipairs(self._btns) do
        local btn, cfg = entry.btn, entry.cfg
        if self._sort_id == cfg.id then
            if self._sort_state == SORT_STATE_DESC then
                btn:SetText("▼" .. cfg.label)
            elseif self._sort_state == SORT_STATE_ASC then
                btn:SetText("▲" .. cfg.label)
            end
            btn.image:SetTexture("images/global_redux.xml", "button_carny_square_hover.tex")
            btn.image:SetTint(1, 1, 1, 1)
        else
            btn:SetText(cfg.label)
            btn.image:SetTexture("images/global_redux.xml", "button_carny_square_normal.tex")
            btn.image:SetTint(0.5, 0.5, 0.5, 1)
        end
    end
end

SortButtons.SORTERS = SORTERS
SortButtons.STATE_NONE = SORT_STATE_NONE
SortButtons.STATE_DESC = SORT_STATE_DESC
SortButtons.STATE_ASC  = SORT_STATE_ASC

return SortButtons
