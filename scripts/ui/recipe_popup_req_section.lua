-- 需求区域：弹窗中最低/最高需求的滚动区域框架与条目布局
-- 提供通用滚动区域（root + scissor + content + pool + scrollbar）、需求列表构建与渲染
local Widget      = require("widgets/widget")
local Image       = require("widgets/image")
local Text        = require("widgets/text")

local AddViewportBorder = require("debug/viewport_border")
local ResolveInventoryItemAssets = require "utils/resolveinventoryitemassets"
local ResolveFoodTagAssets = require "utils/resolvefoodtagassets"

local CRAFTING_ATLAS_RESOLVED = resolvefilepath(CRAFTING_ATLAS)

-- 区域布局常量（弹窗内各滚动区域共用）
local LAYOUT = {
    POPUP_W        = 200,
    REQ_VIEW_H     = 75,
    REQ_VIEW_W     = 187,
    REQ_VIEW_PAD   = 16,
    REQ_VIEW_PAD_X = 8.5,
    SCROLL_STEP    = 36,
}

local GEQ = "\226\137\165"
local LEQ = "\226\137\164"

local function ResolveReqAssets(key, is_tag)
    if is_tag then
        return ResolveFoodTagAssets(key)
    end
    return ResolveInventoryItemAssets(key)
end

local function MakeScrollbar(name, bar_h)
    bar_h = bar_h or LAYOUT.REQ_VIEW_H
    local w = Widget(name)
    local bar = w:AddChild(Image("images/quagmire_recipebook.xml", "quagmire_recipe_scroll_bar.tex"))
    bar:ScaleToSize(2, bar_h)
    local handle = w:AddChild(Image("images/quagmire_recipebook.xml", "quagmire_recipe_scroll_handle.tex"))
    handle:ScaleToSize(6, 8)
    w._handle = handle
    w._bar_h = bar_h
    w:Hide()
    return w
end

local function UpdateScrollbar(scrollbar, scroll, content_rows, visible_rows)
    visible_rows = visible_rows or 2
    if content_rows <= visible_rows then
        scrollbar:Hide()
        return
    end
    scrollbar:Show()
    local bar_h = scrollbar._bar_h
    local total = math.max(1, (content_rows - visible_rows) * LAYOUT.SCROLL_STEP)
    local handle_h = 8
    scrollbar._handle:ScaleToSize(6, handle_h)
    local max_y = bar_h / 2 - handle_h / 2
    local ratio = total > 0 and math.min(scroll, total) / total or 0
    scrollbar._handle:SetPosition(0, max_y - ratio * (bar_h - handle_h))
end

local ReqSection = { LAYOUT = LAYOUT }

-- 创建通用滚动区域：root（带 scissor）+ content + 条目池 + 滚动条
function ReqSection.Create(popup, name, y_offset, view_h)
    view_h = view_h or LAYOUT.REQ_VIEW_H
    local root = popup:AddChild(Widget("req_" .. name .. "_root"))
    local root_x = -LAYOUT.POPUP_W / 2 + 15
    root:SetPosition(root_x, y_offset)
    root:SetScissor(-LAYOUT.REQ_VIEW_PAD_X, -(view_h - LAYOUT.REQ_VIEW_PAD), LAYOUT.REQ_VIEW_W, view_h)

    local content = root:AddChild(Widget(name .. "_content"))
    AddViewportBorder(root, -LAYOUT.REQ_VIEW_PAD_X + 1, -(view_h - LAYOUT.REQ_VIEW_PAD) + 1, LAYOUT.REQ_VIEW_W - 2, view_h - 2)

    local scrollbar = MakeScrollbar(name .. "_scrollbar", view_h)
    scrollbar:SetPosition(root_x + LAYOUT.REQ_VIEW_W - LAYOUT.REQ_VIEW_PAD_X + 3, y_offset - view_h / 2 + LAYOUT.REQ_VIEW_PAD)
    popup:AddChild(scrollbar)

    -- 兄弟食材聚合悬浮层（默认隐藏；热区用于鼠标停留其上时保持展开）
    local expand = popup:AddChild(Widget("req_" .. name .. "_expand"))
    expand.bg = expand:AddChild(Image("images/global.xml", "square.tex"))
    expand.bg:SetTint(0.18, 0.12, 0.06, 0.85)
    expand.icons = {}
    expand.hover = expand:AddChild(Image("images/ui.xml", "blank.tex"))
    expand.hover:SetTint(0, 0, 0, 0)
    expand:Hide()

    local section = {
        root = root, content = content, pool = {}, scroll = 0, max_rows = 0,
        visible_rows = 2, scrollbar = scrollbar, view_h = view_h,
        root_x = root_x, y_offset = y_offset, expand = expand,
        hide_task = nil,
    }
    expand.hover:SetOnGainFocus(function() ReqSection.CancelHide(section) end)
    expand.hover:SetOnLoseFocus(function() ReqSection.ScheduleHide(section) end)
    return section
end

function ReqSection.CreatePoolSlot(parent)
    local slot = parent:AddChild(Widget("slot"))
    slot:Hide()
    slot.bg = slot:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex"))
    slot.bg:MoveToBack()
    slot.img = slot:AddChild(Image())
    slot.txt = slot:AddChild(Text(NUMBERFONT, 14))
    slot.txt:SetString("")
    -- 右下角角标（聚合组成员总数）
    slot.corner = slot:AddChild(Text(NUMBERFONT, 11))
    slot.corner:SetString("")
    slot.corner:Hide()
    slot.corner:SetHAlign(ANCHOR_MIDDLE)
    slot.corner:SetVAlign(ANCHOR_MIDDLE)
    -- 透明悬浮热区（聚合组悬浮展开用）
    slot.hover = slot:AddChild(Image("images/ui.xml", "blank.tex"))
    slot.hover:SetTint(0, 0, 0, 0)
    slot.hover:Hide()
    return slot
end

function ReqSection.ApplyScroll(section)
    local max_rows = section.max_rows
    local visible_rows = section.visible_rows or 2
    local max_scroll = math.max(0, (max_rows - visible_rows) * LAYOUT.SCROLL_STEP)
    section.scroll = math.clamp(section.scroll, 0, max_scroll)
    section.content:SetPosition(0, section.scroll)
    UpdateScrollbar(section.scrollbar, section.scroll, max_rows, visible_rows)
    -- 滚动会使聚合图标位移，悬浮层跟随不准确，直接隐藏
    ReqSection.HideExpand(section)
end

-- 悬浮层参数：每个成员带格子，格子在背景框内居中，逐格铺设
local EXPAND_ICON = 24  -- 图标尺寸
local EXPAND_SLOT = 30  -- 格子尺寸（略大于图标）
local EXPAND_GAP  = 2   -- 格子间距
local EXPAND_PAD  = 6   -- 背景内边距
local EXPAND_MAX_COLS = 10 -- 每行最多列数（列数上限）
local EXPAND_STEP = EXPAND_SLOT + EXPAND_GAP

-- 立即隐藏悬浮层
function ReqSection.HideExpand(section)
    ReqSection.CancelHide(section)
    section.expand:Hide()
end

-- 取消待执行的延迟隐藏
function ReqSection.CancelHide(section)
    if section.hide_task then
        section.hide_task:Cancel()
        section.hide_task = nil
    end
end

-- 延迟隐藏：鼠标移向悬浮层过渡期间不关闭；结束仍不在悬浮层内才隐藏
function ReqSection.ScheduleHide(section)
    if section.hide_task then return end
    section.hide_task = section.expand.inst:DoTaskInTime(0.2, function()
        section.hide_task = nil
        if not ReqSection.IsMouseInExpand(section) then
            section.expand:Hide()
        end
    end)
end

-- 鼠标是否在悬浮层背景框内（世界坐标换算）
function ReqSection.IsMouseInExpand(section)
    if not section._expand_world then return false end
    local w, s = section._expand_world, section._expand_scale
    local mouse = TheInput:GetScreenPosition()
    local lx = (mouse.x - w.x) / s.x
    local ly = (mouse.y - w.y) / s.y
    return math.abs(lx - section._cx) <= section._hw
        and math.abs(ly - section._cy) <= section._hh
end

-- 显示聚合悬浮层：定位到聚合槽位上方并填充全部成员格子
function ReqSection.ShowExpand(section, members, slot_x, slot_y)
    local expand = section.expand
    -- 动态布局：从 2 行起找最小行数，使每行不超过 MAX_COLS 列
    local ncols, nrows
    for r = 2, #members do
        local c = math.ceil(#members / r)
        if c <= EXPAND_MAX_COLS then
            nrows, ncols = r, c
            break
        end
    end
    if not nrows then
        nrows, ncols = #members, 1
    end
    local grid_w = (ncols - 1) * EXPAND_STEP
    local grid_h = (nrows - 1) * EXPAND_STEP

    -- 逐格铺设成员（格子 + 纯 Image 图标）
    local row, col = 0, 0
    for i, m in ipairs(members) do
        local cell = expand.icons[i]
        if not cell then
            cell = expand:AddChild(Widget("expand_cell"))
            cell.bg = cell:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex"))
            cell.bg:ScaleToSize(EXPAND_SLOT, EXPAND_SLOT)
            cell.bg:MoveToBack()
            cell.img = cell:AddChild(Image())
            cell.img:SetOnGainFocus(function() ReqSection.CancelHide(section) end)
            cell.img:SetOnLoseFocus(function() ReqSection.ScheduleHide(section) end)
            table.insert(expand.icons, cell)
        end
        cell:Show()
        local tex, atlas, tooltip = ResolveReqAssets(m.key, m.is_tag)
        cell.img:Show()
        if atlas then
            pcall(cell.img.SetTexture, cell.img, atlas, tex)
        else
            cell.img:SetTexture("images/food_tags.xml", "unknown.tex")
        end
        cell.img:ScaleToSize(EXPAND_ICON, EXPAND_ICON)
        cell.img:SetTooltip(tooltip)
        cell:SetPosition(col * EXPAND_STEP, -row * EXPAND_STEP)
        col = col + 1
        if col >= ncols then
            col = 0
            row = row + 1
        end
    end
    for i = #members + 1, #expand.icons do
        expand.icons[i]:Hide()
    end

    -- 背景框居中包裹全部格子
    local bg_w = ncols * EXPAND_SLOT + (ncols - 1) * EXPAND_GAP + EXPAND_PAD * 2
    local bg_h = nrows * EXPAND_SLOT + (nrows - 1) * EXPAND_GAP + EXPAND_PAD * 2
    expand.bg:ScaleToSize(bg_w, bg_h)
    expand.bg:SetPosition(grid_w / 2, -grid_h / 2)
    expand.bg:SetTint(0.18, 0.12, 0.06, 0.85)

    -- 定位：水平对齐聚合槽位，整体上移 20px
    expand:SetPosition(slot_x - grid_w / 2, slot_y + grid_h + 36)
    -- 悬浮层热区覆盖背景框，鼠标停留其上时保持展开
    expand.hover:ScaleToSize(bg_w, bg_h)
    expand.hover:SetPosition(grid_w / 2, -grid_h / 2)
    expand.hover:Show()
    -- 记录鼠标位置判断数据（世界坐标 + 背景框局部矩形）
    section._expand_world = expand:GetWorldPosition()
    section._expand_scale = expand:GetScale()
    section._cx, section._cy = grid_w / 2, -grid_h / 2
    section._hw, section._hh = bg_w / 2, bg_h / 2
    ReqSection.CancelHide(section)
    expand:MoveToFront()
    expand:Show()
end

-- 由 recipe_requirements 构建最低/最高需求展示列表
function ReqSection.BuildReqLists(reqs)
    local min_reqs = {}
    local max_reqs = {}
    if reqs == nil then
        return min_reqs, max_reqs
    end

    local group_covered = {}
    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            local members = {}
            for _, gname in ipairs(group.names) do
                table.insert(members, { key = gname, is_tag = false })
                group_covered[gname] = true
            end
            table.insert(min_reqs, {
                type = "group",
                members = members,
                amount = group.amount,
                display_amount = GEQ .. group.amount,
            })
        end
    end

    for name, amt in pairs(reqs.minnames or {}) do
        if not group_covered[name] then
            table.insert(min_reqs, {
                type = "name",
                key = name,
                is_tag = false,
                amount = amt,
                display_amount = GEQ .. amt,
            })
        end
    end

    if reqs.mintag_display then
        for tag, info_d in pairs(reqs.mintag_display) do
            local op = info_d.mode == ">" and ">" or GEQ
            table.insert(min_reqs, {
                type = "tag",
                key = tag,
                is_tag = true,
                amount = info_d.value,
                display_amount = op .. info_d.value,
            })
        end
    else
        for tag, amt in pairs(reqs.mintags or {}) do
            table.insert(min_reqs, {
                type = "tag",
                key = tag,
                is_tag = true,
                amount = amt,
                display_amount = GEQ .. amt,
            })
        end
    end

    local max_group_covered = {}
    if reqs.analog_groups then
        for _, group in ipairs(reqs.analog_groups) do
            local group_max = nil
            for _, gname in ipairs(group.names) do
                local m = reqs.maxnames and reqs.maxnames[gname]
                if m ~= nil and (group_max == nil or m > group_max) then
                    group_max = m
                end
            end
            if group_max ~= nil then
                local members = {}
                for _, gname in ipairs(group.names) do
                    table.insert(members, { key = gname, is_tag = false })
                    max_group_covered[gname] = true
                end
                table.insert(max_reqs, {
                    type = "group",
                    members = members,
                    amount = group_max,
                    display_amount = (group_max == 0) and "=0" or (LEQ .. group_max),
                })
            end
        end
    end

    for name, amt in pairs(reqs.maxnames or {}) do
        if not max_group_covered[name] then
            table.insert(max_reqs, {
                type = "name",
                key = name,
                is_tag = false,
                amount = amt,
                display_amount = (amt == 0) and "=0" or (LEQ .. amt),
            })
        end
    end

    if reqs.maxtag_display then
        for tag, info_d in pairs(reqs.maxtag_display) do
            local display
            if info_d.mode == "<=" and info_d.value == 0 then
                display = "=0"
            elseif info_d.mode == "<" then
                display = "<" .. info_d.value
            else
                display = LEQ .. info_d.value
            end
            table.insert(max_reqs, {
                type = "tag",
                key = tag,
                is_tag = true,
                amount = info_d.value,
                display_amount = display,
            })
        end
    else
        for tag, amt in pairs(reqs.maxtags or {}) do
            local display = (amt == 0) and "=0" or (LEQ .. amt)
            table.insert(max_reqs, {
                type = "tag",
                key = tag,
                is_tag = true,
                amount = amt,
                display_amount = display,
            })
        end
    end

    return min_reqs, max_reqs
end

-- 渲染需求条目列表，返回总行数（供滚动范围计算）
function ReqSection.UpdateEntries(section, reqs)
    local pool = section.pool
    local content = section.content
    ReqSection.HideExpand(section)

    local icon_size = 24
    local spacing   = 26
    local max_per_row = 7
    local row_w   = (max_per_row - 1) * spacing
    local y_step  = -36

    local COLLAPSE_MIN = 8 -- 兄弟成员 >= 8 才聚合显示
    local row_center_base = LAYOUT.POPUP_W / 2 - 15
    local layout = {}
    local cur_row = 0
    local cur_col = 0

    if reqs then
        for _, req in ipairs(reqs) do
            local collapsed = false
            local need
            if req.type == "group" and #req.members >= COLLAPSE_MIN then
                collapsed = true
                need = 1
            else
                need = req.type == "group" and #req.members or 1
            end
            if cur_col + need > max_per_row then
                cur_row = cur_row + 1
                cur_col = 0
            end
            table.insert(layout, {
                row = cur_row, col = cur_col, need = need, req = req, collapsed = collapsed,
            })
            cur_col = cur_col + need
        end
    end

    local total_rows = cur_row + 1

    local entries = {}
    for _, item in ipairs(layout) do
        local cx = row_center_base - row_w / 2 + item.col * spacing
        local py = item.row * y_step

        if item.req.type == "group" and item.collapsed then
            -- 聚合显示：占一格，显示第一个成员 + 右下角总数角标 + 下方 ≥N
            local m = item.req.members[1]
            local tex, atlas = ResolveReqAssets(m.key, m.is_tag)
            table.insert(entries, {
                tex = tex, atlas = atlas,
                display_amt = item.req.display_amount,
                corner = #item.req.members,
                expand_members = item.req.members,
                x = cx, y = py,
                bg_w = spacing,
                bg_h = spacing,
            })
        elseif item.req.type == "group" then
            local is_first = true
            for mi, m in ipairs(item.req.members) do
                local tex, atlas, tooltip = ResolveReqAssets(m.key, m.is_tag)
                local entry = {
                    tex = tex, atlas = atlas, tooltip = tooltip,
                    display_amt = nil,
                    x = cx + (mi - 1) * spacing, y = py,
                }
                if is_first then
                    entry.bg_w = item.need * spacing
                    entry.bg_h = spacing
                    entry.bg_x = (item.need - 1) * spacing / 2
                    is_first = false
                else
                    entry.bg_w = 0
                end
                table.insert(entries, entry)
            end
            if item.req.display_amount then
                local group_cx = cx + (item.need - 1) * spacing / 2
                table.insert(entries, {
                    is_label = true, text = item.req.display_amount,
                    x = group_cx, y = py - spacing / 2,
                })
            end
        else
            local tex, atlas, tooltip = ResolveReqAssets(item.req.key, item.req.is_tag)
            table.insert(entries, {
                tex = tex, atlas = atlas, tooltip = tooltip,
                display_amt = item.req.display_amount,
                x = cx, y = py,
                bg_w = spacing,
                bg_h = spacing,
            })
        end
    end

    while #pool < #entries do
        table.insert(pool, ReqSection.CreatePoolSlot(content))
    end

    for i, entry in ipairs(entries) do
        local slot = pool[i]
        slot:Show()
        slot:SetPosition(entry.x, entry.y)

        if entry.is_label then
            slot.bg:Hide()
            slot.img:Hide()
            slot.txt:SetPosition(0, 0)
            slot.txt:SetString(entry.text or "")
            slot.corner:Hide()
            slot.corner:SetString("")
            slot.hover:Hide()
        else
            if entry.bg_w and entry.bg_w > 0 then
                slot.bg:Show()
                slot.bg:SetPosition(entry.bg_x or 0, 0)
                slot.bg:ScaleToSize(entry.bg_w, entry.bg_h)
            else
                slot.bg:Hide()
            end
            slot.img:Show()
            slot.img:SetTexture("images/ui.xml", "blank.tex")
            slot.txt:SetPosition(0, -spacing / 2)
            if entry.atlas then
                local ok = pcall(slot.img.SetTexture, slot.img, entry.atlas, entry.tex)
                if not ok then
                    slot.img:SetTexture("images/food_tags.xml", "unknown.tex")
                end
                -- 聚合条目不设 tooltip，避免与悬浮热区焦点竞争导致闪烁
                slot.img:SetTooltip(entry.expand_members and nil or entry.tooltip)
            else
                slot.img:SetTexture("images/food_tags.xml", "unknown.tex")
            end
            slot.img:ScaleToSize(icon_size, icon_size)
            slot.txt:SetString(entry.display_amt or "")

            -- 角标：聚合组在右下角显示成员总数；普通条目隐藏
            if entry.corner then
                slot.corner:Show()
                slot.corner:SetString(tostring(entry.corner))
                slot.corner:SetPosition(spacing / 2 - 4, -spacing / 2 + 4)
                slot.corner:SetColour(1, 1, 1, 1)
            else
                slot.corner:Hide()
                slot.corner:SetString("")
            end

            -- 悬浮热区：聚合组悬浮时展开全部成员
            if entry.expand_members then
                local members = entry.expand_members
                slot.hover:Show()
                slot.hover:ScaleToSize(spacing, spacing)
                slot.hover:SetOnGainFocus(function()
                    ReqSection.ShowExpand(section, members,
                        entry.x + section.root_x,
                        entry.y + section.scroll + section.y_offset)
                end)
                slot.hover:SetOnLoseFocus(function()
                    ReqSection.ScheduleHide(section)
                end)
            else
                slot.hover:Hide()
                slot.hover:SetOnGainFocus(nil)
                slot.hover:SetOnLoseFocus(nil)
            end
        end
    end
    for i = #entries + 1, #pool do
        pool[i]:Hide()
    end
    return total_rows
end

return ReqSection
