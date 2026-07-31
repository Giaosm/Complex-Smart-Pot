-- 需求区域：弹窗中最低/最高需求的滚动区域框架与条目布局
-- 提供通用滚动区域（root + scissor + content + pool + scrollbar）、需求列表构建与渲染
local Widget = require("widgets/widget")
local Image  = require("widgets/image")
local Text   = require("widgets/text")

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

    return { root = root, content = content, pool = {}, scroll = 0, max_rows = 0, visible_rows = 2, scrollbar = scrollbar, view_h = view_h }
end

-- 区域条目池的槽位工厂
function ReqSection.CreatePoolSlot(parent)
    local slot = parent:AddChild(Widget("slot"))
    slot:Hide()
    slot.bg = slot:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex"))
    slot.bg:MoveToBack()
    slot.img = slot:AddChild(Image())
    slot.txt = slot:AddChild(Text(NUMBERFONT, 14))
    slot.txt:SetString("")
    return slot
end

-- 应用滚动位置并刷新滚动条
function ReqSection.ApplyScroll(section)
    local max_rows = section.max_rows
    local visible_rows = section.visible_rows or 2
    local max_scroll = math.max(0, (max_rows - visible_rows) * LAYOUT.SCROLL_STEP)
    section.scroll = math.clamp(section.scroll, 0, max_scroll)
    section.content:SetPosition(0, section.scroll)
    UpdateScrollbar(section.scrollbar, section.scroll, max_rows, visible_rows)
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

    local icon_size = 24
    local spacing   = 26
    local max_per_row = 7
    local row_w   = (max_per_row - 1) * spacing
    local y_step  = -36

    local row_center_base = LAYOUT.POPUP_W / 2 - 15
    local layout = {}
    local cur_row = 0
    local cur_col = 0

    if reqs then
        for _, req in ipairs(reqs) do
            local need = req.type == "group" and #req.members or 1
            if cur_col + need > max_per_row then
                cur_row = cur_row + 1
                cur_col = 0
            end
            table.insert(layout, {
                row = cur_row, col = cur_col, need = need, req = req,
            })
            cur_col = cur_col + need
        end
    end

    local total_rows = cur_row + 1

    local entries = {}
    for _, item in ipairs(layout) do
        local cx = row_center_base - row_w / 2 + item.col * spacing
        local py = item.row * y_step

        if item.req.type == "group" then
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
                slot.img:SetTooltip(entry.tooltip)
            else
                slot.img:SetTexture("images/food_tags.xml", "unknown.tex")
            end
            slot.img:ScaleToSize(icon_size, icon_size)
            slot.txt:SetString(entry.display_amt or "")
        end
    end
    for i = #entries + 1, #pool do
        pool[i]:Hide()
    end
    return total_rows
end

return ReqSection
