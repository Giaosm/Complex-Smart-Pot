-- 视口调试边框：在指定父节点上画出可视区域边界，受 show_viewport_border 开关控制
local Widget = require("widgets/widget")
local Image = require("widgets/image")
local Config = require("config/config_manager")

local function makeLine(parent, x, y, w, h, r, g, b, a)
    local line = parent:AddChild(Image("images/global.xml", "square.tex"))
    line:ScaleToSize(w, h)
    line:SetPosition(x, y)
    line:SetTint(r, g, b, a)
    return line
end

local function AddViewportBorder(parent, x, y, w, h)
    if not Config.ShowViewportBorder() then return end
    local border = parent:AddChild(Widget("viewport_border"))
    border:MoveToFront()
    makeLine(border, x + w / 2, y + h, w, 1, 0.5, 0.4, 0.3, 0.5)
    makeLine(border, x + w / 2, y, w, 1, 0.5, 0.4, 0.3, 0.5)
    makeLine(border, x, y + h / 2, 1, h, 0.5, 0.4, 0.3, 0.5)
    makeLine(border, x + w, y + h / 2, 1, h, 0.5, 0.4, 0.3, 0.5)
end

return AddViewportBorder
