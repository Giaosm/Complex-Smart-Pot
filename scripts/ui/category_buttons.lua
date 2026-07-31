-- 分类按钮列：可选的「自动做饭」按钮 + 分类按钮（全部/原版/设备/模组/BUFF/可做）
-- 与排序按钮共用同一条竖向按钮列，起始 y 由面板统一计算后传入
local Widget = require("widgets/widget")
local ImageButton = require("widgets/imagebutton")
local L = require("ui/panel_layout")

local CategoryButtons = Class(Widget, function(self, opts)
    Widget._ctor(self, "CategoryButtons")
    -- opts = {
    --   entries   = { { kind = "auto"|"cat", id =, label = }, ... },
    --   current   = 当前分类 id,
    --   start_y   = 第一个按钮的 y 坐标,
    --   on_select = fn(id),   -- 分类点击
    --   on_auto_cook = fn(),  -- 自动做饭点击
    -- }
    self._on_select = opts.on_select
    self._cat_btns = {}

    for idx, entry in ipairs(opts.entries) do
        local btn = self:AddChild(ImageButton(
            "images/global_redux.xml",
            "button_carny_square_normal.tex",
            "button_carny_square_hover.tex",
            "button_carny_square_disabled.tex",
            "button_carny_square_down.tex"
        ))
        btn:ForceImageSize(L.BTN_W, L.BTN_H)
        btn:SetText(entry.label)
        btn:SetFont(CHATFONT)
        btn:SetTextSize(25)
        btn:SetPosition(L.BTN_X, opts.start_y - (idx - 1) * (L.BTN_H + L.BTN_GAP))

        if entry.kind == "cat" then
            local id = entry.id
            btn:SetOnClick(function() self._on_select(id) end)
            table.insert(self._cat_btns, { btn = btn, id = id })
        else
            self._auto_cook_btn = btn
            btn:Disable()
            if opts.on_auto_cook then
                btn:SetOnClick(opts.on_auto_cook)
            end
        end
    end

    self:SetCurrent(opts.current)
end)

-- 刷新分类高亮
function CategoryButtons:SetCurrent(id)
    self._current = id
    for _, entry in ipairs(self._cat_btns) do
        if entry.id == id then
            entry.btn.image:SetTexture("images/global_redux.xml", "button_carny_square_hover.tex")
            entry.btn.image:SetTint(1, 1, 1, 1)
        else
            entry.btn.image:SetTexture("images/global_redux.xml", "button_carny_square_normal.tex")
            entry.btn.image:SetTint(0.5, 0.5, 0.5, 1)
        end
    end
end

function CategoryButtons:SetAutoCookEnabled(enabled)
    if not self._auto_cook_btn then return end
    if enabled then
        self._auto_cook_btn:Enable()
    else
        self._auto_cook_btn:Disable()
    end
end

return CategoryButtons
