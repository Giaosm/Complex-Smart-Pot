local Widget = require("widgets/widget")
local Image  = require("widgets/image")
local Text   = require("widgets/text")

local CRAFTING_ATLAS_RESOLVED = resolvefilepath(CRAFTING_ATLAS)

local ResolveInventoryItemAssets = require "utils/resolveinventoryitemassets"
local ResolveFoodTagAssets = require "utils/resolvefoodtagassets"

local POPUP_W = 200
local POPUP_H = 260

local RecipePopup = Class(Widget, function(self)
    Widget._ctor(self, "RecipePopup")

    self:SetScale(2, 2, 2)

    self.bg = self:AddChild(Image("images/global.xml", "square.tex"))
    self.bg:ScaleToSize(POPUP_W, POPUP_H)
    self.bg:SetTint(0.18, 0.12, 0.06, 0.85)
    self.bg:MoveToBack()

    self.name_text = self:AddChild(Text(UIFONT, 26))
    self.name_text:SetPosition(0, POPUP_H / 2 - 15)
    self.name_text:SetColour(1, 0.9, 0.5, 1)

    self.stats_text = self:AddChild(Text(BODYTEXTFONT, 20))
    self.stats_text:SetPosition(0, POPUP_H / 2 - 45)
    self.stats_text:SetColour(0.85, 0.85, 0.85, 1)

    self.info_text = self:AddChild(Text(BODYTEXTFONT, 18))
    self.info_text:SetPosition(0, POPUP_H / 2 - 65)
    self.info_text:SetColour(0.7, 0.7, 0.7, 1)

    self.buff_text = self:AddChild(Text(BODYTEXTFONT, 18))
    self.buff_text:SetPosition(0, POPUP_H / 2 - 85)
    self.buff_text:SetColour(0.6, 1, 0.6, 1)
    self.buff_text:SetRegionSize(POPUP_W - 20, 22)

    local label_w = 68
    local sep_gap = 6
    local half_sep_w = (POPUP_W - 20 - label_w - sep_gap * 2) / 2
    local sep1_y = POPUP_H / 2 - 100

    self.sep1_left = self:AddChild(Image("images/global.xml", "square.tex"))
    self.sep1_left:ScaleToSize(half_sep_w, 2)
    self.sep1_left:SetPosition(-label_w / 2 - sep_gap - half_sep_w / 2, sep1_y)
    self.sep1_left:SetTint(0.5, 0.4, 0.3, 1)

    self.sep1_right = self:AddChild(Image("images/global.xml", "square.tex"))
    self.sep1_right:ScaleToSize(half_sep_w, 2)
    self.sep1_right:SetPosition(label_w / 2 + sep_gap + half_sep_w / 2, sep1_y)
    self.sep1_right:SetTint(0.5, 0.4, 0.3, 1)

    self.min_label = self:AddChild(Text(UIFONT, 14))
    self.min_label:SetPosition(0, sep1_y)
    self.min_label:SetColour(0.7, 0.7, 0.7, 1)
    self.min_label:SetString(STRINGS.CSP.POPUP_MIN_REQ)

    self.req_min_root = self:AddChild(Widget("req_min_root"))
    self.req_min_root:SetPosition(-POPUP_W / 2 + 15, POPUP_H / 2 - 118)
    self._min_pool = {}
    for i = 1, 14 do
        table.insert(self._min_pool, self:_CreatePoolSlot(self.req_min_root))
    end

    self.req_max_root = self:AddChild(Widget("req_max_root"))
    self.req_max_root:SetPosition(-POPUP_W / 2 + 15, POPUP_H / 2 - 198)
    self._max_pool = {}
    for i = 1, 14 do
        table.insert(self._max_pool, self:_CreatePoolSlot(self.req_max_root))
    end
    local sep2_y = POPUP_H / 2 - 180

    self.sep2_left = self:AddChild(Image("images/global.xml", "square.tex"))
    self.sep2_left:ScaleToSize(half_sep_w, 2)
    self.sep2_left:SetPosition(-label_w / 2 - sep_gap - half_sep_w / 2, sep2_y)
    self.sep2_left:SetTint(0.4, 0.35, 0.25, 1)

    self.sep2_right = self:AddChild(Image("images/global.xml", "square.tex"))
    self.sep2_right:ScaleToSize(half_sep_w, 2)
    self.sep2_right:SetPosition(label_w / 2 + sep_gap + half_sep_w / 2, sep2_y)
    self.sep2_right:SetTint(0.4, 0.35, 0.25, 1)

    self.max_label = self:AddChild(Text(UIFONT, 14))
    self.max_label:SetPosition(0, sep2_y)
    self.max_label:SetColour(0.7, 0.7, 0.7, 1)
    self.max_label:SetString(STRINGS.CSP.POPUP_MAX_REQ)

    self:Hide()
end)

function RecipePopup:_ResolveReqAssets(key, is_tag)
    if is_tag then
        return ResolveFoodTagAssets(key)
    else
        return ResolveInventoryItemAssets(key)
    end
end

function RecipePopup:_CreatePoolSlot(parent)
    local slot = parent:AddChild(Widget("slot"))
    slot:Hide()
    slot.bg = slot:AddChild(Image(CRAFTING_ATLAS_RESOLVED, "slot_frame.tex"))
    slot.bg:MoveToBack()
    slot.img = slot:AddChild(Image())
    slot.txt = slot:AddChild(Text(NUMBERFONT, 14))
    slot.txt:SetString("")
    return slot
end

function RecipePopup:_UpdateReqSection(pool, reqs)
    local icon_size = 24
    local spacing   = 26
    local max_per_row = 7
    local row_w   = (max_per_row - 1) * spacing
    local y_step  = -36

    local row_center_base = POPUP_W / 2 - 15
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

    local entries = {}
    for _, item in ipairs(layout) do
        local cx = row_center_base - row_w / 2 + item.col * spacing
        local py = item.row * y_step

        if item.req.type == "group" then
            local is_first = true
            for mi, m in ipairs(item.req.members) do
                local tex, atlas, tooltip = self:_ResolveReqAssets(m.key, m.is_tag)
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
            local tex, atlas, tooltip = self:_ResolveReqAssets(item.req.key, item.req.is_tag)
            table.insert(entries, {
                tex = tex, atlas = atlas, tooltip = tooltip,
                display_amt = item.req.display_amount,
                x = cx, y = py,
                bg_w = spacing,
                bg_h = spacing,
            })
        end
    end

    local used = 0
    for _, entry in ipairs(entries) do
        used = used + 1
        if used > #pool then break end
        local slot = pool[used]
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
                slot.img:ScaleToSize(icon_size, icon_size)
                slot.img:SetTooltip(entry.tooltip)
            else
                slot.img:SetTexture("images/food_tags.xml", "unknown.tex")
                slot.img:ScaleToSize(icon_size, icon_size)
            end
            slot.txt:SetString(entry.display_amt or "")
        end
    end
    for i = used + 1, #pool do
        pool[i]:Hide()
    end
end

function RecipePopup:ShowForRecipe(data, S, T)
    if data == nil then
        self:Hide()
        return
    end

    self.name_text:SetString(data.name)

    local stats = string.format(STRINGS.CSP.POPUP_STATS_FMT,
        data.health or 0, data.hunger or 0, data.sanity or 0)
    self.stats_text:SetString(stats)

    local rd = data.recipe_def
    local info = {}
    local food_type_str = (S.UI.FOOD_TYPES[rd.foodtype or "GENERIC"] or rd.foodtype or "Edible")
    table.insert(info, food_type_str)
    if rd.perishtime ~= nil then
        if type(rd.perishtime) == "number" then
            table.insert(info, string.format(STRINGS.CSP.POPUP_SPOIL_FMT, rd.perishtime / 480))
        else
            table.insert(info, tostring(rd.perishtime))
        end
    end
    if rd.cooktime ~= nil then
        if type(rd.cooktime) == "number" then
            table.insert(info, string.format(STRINGS.CSP.POPUP_COOK_FMT, math.floor(T.BASE_COOK_TIME * rd.cooktime + 0.5)))
        else
            table.insert(info, tostring(rd.cooktime))
        end
    end
    self.info_text:SetString(table.concat(info, " | "))

    local buff = rd.oneat_desc
    if not buff and rd.temperature ~= nil then
        if rd.temperature > 0 then
            buff = S.UI.COOKBOOK.FOOD_EFFECTS_HOT_FOOD
        elseif rd.temperature < 0 then
            buff = S.UI.COOKBOOK.FOOD_EFFECTS_COLD_FOOD
        end
    end
    if buff then
        self.buff_text:SetString(STRINGS.CSP.POPUP_SPECIAL .. buff)
        self.buff_text:Show()
    else
        self.buff_text:Hide()
    end

    local min_reqs = {}
    local max_reqs = {}
    if data.recipe_requirements ~= nil then
        local reqs = data.recipe_requirements

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
                    display_amount = "\226\137\165" .. group.amount,
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
                    display_amount = "\226\137\165" .. amt,
                })
            end
        end

        if reqs.mintag_display then
            for tag, info_d in pairs(reqs.mintag_display) do
                local op = info_d.mode == ">" and ">" or "\226\137\165"
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
                    display_amount = "\226\137\165" .. amt,
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
                        display_amount = (group_max == 0) and "=0" or ("\226\137\164" .. group_max),
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
                    display_amount = (amt == 0) and "=0" or ("\226\137\164" .. amt),
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
                    display = "\226\137\164" .. info_d.value
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
                local display = (amt == 0) and "=0" or ("\226\137\164" .. amt)
                table.insert(max_reqs, {
                    type = "tag",
                    key = tag,
                    is_tag = true,
                    amount = amt,
                    display_amount = display,
                })
            end
        end
    end

    self:_UpdateReqSection(self._min_pool, min_reqs)
    self:_UpdateReqSection(self._max_pool, max_reqs)

    self:Show()
end

return RecipePopup