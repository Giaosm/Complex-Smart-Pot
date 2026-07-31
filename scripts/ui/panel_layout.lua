-- 面板布局常量：recipe_panel 与其子组件（按钮列/列表）共用，避免多处硬编码漂移
local SLOT_SIZE      = 64
local PADDING        = 6
local ROW_HEIGHT     = SLOT_SIZE + PADDING
local VISIBLE_ROWS   = 6

local L = {
    SLOT_SIZE      = SLOT_SIZE,
    PADDING        = PADDING,
    ROW_HEIGHT     = ROW_HEIGHT,
    VISIBLE_ROWS   = VISIBLE_ROWS,
    LIST_HEIGHT    = VISIBLE_ROWS * ROW_HEIGHT,
    LIST_WIDTH     = SLOT_SIZE + 12,
    BTN_W          = 100,
    BTN_H          = 40,
    BTN_GAP        = 1,
}

L.BTN_AREA_W   = L.BTN_W + 8
L.PANEL_WIDTH  = L.BTN_AREA_W + 8 + L.LIST_WIDTH
L.PANEL_HEIGHT = L.LIST_HEIGHT
L.LIST_X       = L.PANEL_WIDTH / 2 - L.LIST_WIDTH / 2 - 4
L.BTN_X        = -L.PANEL_WIDTH / 2 + L.BTN_W / 2 + 4
L.LIST_TOP     = L.PANEL_HEIGHT / 2 - L.ROW_HEIGHT / 2

return L
