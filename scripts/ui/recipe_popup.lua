-- 食谱弹窗：显示料理详情（三维、食物类型、腐烂时间、配方需求、最高限制）
-- 需求区域与可做配方区域已拆分为子组件（recipe_popup_req_section / recipe_popup_craft_section），
-- 本文件负责弹窗框架、信息区与视图切换
local Widget      = require("widgets/widget")
local Image       = require("widgets/image")
local ImageButton = require("widgets/imagebutton")
local Text        = require("widgets/text")

local ReqSection   = require("ui/recipe_popup_req_section")
local CraftSection = require("ui/recipe_popup_craft_section")

local POPUP_W = 200
local POPUP_H = 260
local BUFF_MAX_W = POPUP_W - 20
local MARQUEE_INTERVAL = 0.2

local CRAFT_VIEW_H = 155

local SCROLL_STEP = ReqSection.LAYOUT.SCROLL_STEP

local RecipePopup = Class(Widget, function(self, prefs, get_craftable_fn, cook_fn)
    Widget._ctor(self, "RecipePopup")

    self._prefs = prefs or {}
    self._get_craftable_fn = get_craftable_fn
    self._cook_fn = cook_fn

    self:SetScale(2, 2, 2)

    self.bg = self:AddChild(Image("images/global.xml", "square.tex"))
    self.bg:ScaleToSize(POPUP_W, POPUP_H)
    self.bg:SetTint(0.18, 0.12, 0.06, 0.85)
    self.bg:MoveToBack()

    self.name_text = self:AddChild(Text(UIFONT, 26))
    self.name_text:SetPosition(0, POPUP_H / 2 - 15)
    self.name_text:SetColour(1, 0.9, 0.5, 1)

    self.name_icon = self:AddChild(ImageButton(
        "images/button_icons.xml", "refresh.tex", "refresh.tex", "refresh.tex", "refresh.tex",
        nil, nil, {1, 1}, {0, 0}
    ))
    self.name_icon:ForceImageSize(12, 12)
    self.name_icon.scale_on_focus = false
    self.name_icon.move_on_click = false
    self.name_icon:Hide()

    self._showing_craft = self._prefs.show_craft_view or false
    self.name_icon:SetOnClick(function()
        self._showing_craft = not self._showing_craft
        self._prefs.show_craft_view = self._showing_craft
        if self._showing_craft then
            self:_UpdateCraftView()
        end
        self:_ApplyCraftView()
        if not self._showing_craft then
            ReqSection.ApplyScroll(self._min_section)
            ReqSection.ApplyScroll(self._max_section)
        end
    end)

    self.stats_text = self:AddChild(Text(BODYTEXTFONT, 20))
    self.stats_text:SetPosition(0, POPUP_H / 2 - 45)
    self.stats_text:SetColour(0.85, 0.85, 0.85, 1)

    self.info_text = self:AddChild(Text(BODYTEXTFONT, 18))
    self.info_text:SetPosition(0, POPUP_H / 2 - 65)
    self.info_text:SetColour(0.7, 0.7, 0.7, 1)

    self.buff_text = self:AddChild(Text(BODYTEXTFONT, 18))
    self.buff_text:SetPosition(0, POPUP_H / 2 - 85)
    self.buff_text:SetColour(0.6, 1, 0.6, 1)
    self.buff_text:SetRegionSize(BUFF_MAX_W, 22)
    self._buff_scroll = nil
    self._marquee_task = nil

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

    self._min_section = ReqSection.Create(self, "min", POPUP_H / 2 - 118)
    self._max_section = ReqSection.Create(self, "max", POPUP_H / 2 - 198)
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

    self._craft_section = CraftSection.Create(self, POPUP_H / 2 - 118, CRAFT_VIEW_H)
    self._current_recipe_data = nil

    self:_ApplyCraftView()
    self:Hide()
end)

function RecipePopup:_ApplyCraftView()
    if self._showing_craft then
        self._min_section.root:Hide()
        self._min_section.scrollbar:Hide()
        self.max_label:Hide()
        self.sep2_left:Hide()
        self.sep2_right:Hide()
        self._max_section.root:Hide()
        self._max_section.scrollbar:Hide()
        self._craft_section.root:Show()
    else
        self.min_label:SetString(STRINGS.CSP.POPUP_MIN_REQ)
        self._min_section.root:Show()
        self.max_label:Show()
        self.sep2_left:Show()
        self.sep2_right:Show()
        self._max_section.root:Show()
        self._craft_section.root:Hide()
        self._craft_section.scrollbar:Hide()
    end
end

function RecipePopup:_UpdateCraftView()
    local count = CraftSection.Update(self, self._craft_section, self._current_recipe_data)
    if count ~= nil then
        self.min_label:SetString(STRINGS.CSP.POPUP_CRAFTABLE .. " (" .. count .. ")")
    end
end

local function _round1(v) return math.floor((v or 0) * 10 + 0.5) / 10 end

function RecipePopup:ShowForRecipe(data, S, T)
    if data == nil then
        self.name_icon:Hide()
        self:Hide()
        return
    end

    self._current_recipe_data = data

    self.name_text:SetString(data.name)
    local name_w = self.name_text:GetRegionSize()
    self.name_icon:SetPosition(name_w / 2 + 3, POPUP_H / 2 - 18)
    self.name_icon:Show()

    local stats = string.format(STRINGS.CSP.POPUP_STATS_FMT,
        _round1(data.health), _round1(data.hunger), _round1(data.sanity))
    self.stats_text:SetString(stats)

    local rd = data.recipe_def
    local info = {}
    local food_type_str = (S.UI.FOOD_TYPES[rd.foodtype or "GENERIC"] or rd.foodtype or "Edible")
    table.insert(info, food_type_str)
    if rd.perishtime ~= nil then
        if type(rd.perishtime) == "number" then
            table.insert(info, string.format(STRINGS.CSP.POPUP_SPOIL_FMT, _round1(rd.perishtime / 480)))
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
        local full = STRINGS.CSP.POPUP_SPECIAL .. buff:gsub("\n", "")
        self.buff_text:SetString(full)
        self.buff_text:ResetRegionSize()
        local tw = self.buff_text:GetRegionSize()
        self.buff_text:SetRegionSize(BUFF_MAX_W, 22)
        if tw > BUFF_MAX_W then
            local padded = full .. "    "
            self._buff_scroll = padded .. padded
            self._buff_scroll_pos = 1
            local cycle = string.utf8len(padded)
            if not self._marquee_task then
                self._marquee_task = self.inst:DoPeriodicTask(MARQUEE_INTERVAL, function()
                    if not self._buff_scroll then return end
                    self._buff_scroll_pos = self._buff_scroll_pos + 1
                    if self._buff_scroll_pos > cycle then
                        self._buff_scroll_pos = 1
                    end
                    self.buff_text:SetString(self._buff_scroll:utf8sub(self._buff_scroll_pos))
                end)
            end
        else
            self:_StopMarquee()
        end
        self.buff_text:Show()
    else
        self.buff_text:Hide()
        self:_StopMarquee()
    end

    local min_reqs, max_reqs = ReqSection.BuildReqLists(data.recipe_requirements)
    self._min_section.max_rows = ReqSection.UpdateEntries(self._min_section, min_reqs)
    self._max_section.max_rows = ReqSection.UpdateEntries(self._max_section, max_reqs)
    self._min_section.scroll = 0
    self._max_section.scroll = 0
    ReqSection.ApplyScroll(self._min_section)
    ReqSection.ApplyScroll(self._max_section)

    self:_UpdateCraftView()
    self:Show()
    self:_ApplyCraftView()
    if self._showing_craft then
        ReqSection.ApplyScroll(self._craft_section)
    end
end

function RecipePopup:OnHide()
    self:_StopMarquee()
end

function RecipePopup:_StopMarquee()
    self._buff_scroll = nil
    if self._marquee_task then
        self._marquee_task:Cancel()
        self._marquee_task = nil
    end
end

function RecipePopup:OnControl(control, down)
    if RecipePopup._base.OnControl(self, control, down) then return true end
    if not down then return false end
    if control ~= CONTROL_SCROLLBACK and control ~= CONTROL_SCROLLFWD then return false end

    local mouse = TheInput:GetScreenPosition()
    local px, py = self:GetWorldPosition():Get()
    local s = self:GetScale()
    local ly = (mouse.y - py) / s.y

    local delta = control == CONTROL_SCROLLFWD and SCROLL_STEP or -SCROLL_STEP
    local section
    if self._showing_craft then
        section = self._craft_section
    else
        section = ly >= -49 and self._min_section or self._max_section
    end
    section.scroll = section.scroll + delta
    ReqSection.ApplyScroll(section)
    return true
end

return RecipePopup
