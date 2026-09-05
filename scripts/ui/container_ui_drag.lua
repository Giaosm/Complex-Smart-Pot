-- 容器UI可拖拽（智能锅面板随容器widget移动）
-- 棱镜/勋章各有游戏内拖拽开关：对方接管时让位，否则用自己的

local SETTING_SECTION = "complex_smart_pot"
local SETTING_KEY = "ui_pos"

local ContainerUiDrag = {}
local _ui_pos_cache = nil
local Config, PanelManager, AddClassPostConstruct = nil, nil, nil -- modmain 注入

local function LoadUiPos()
    if _ui_pos_cache ~= nil then return _ui_pos_cache end
    local str = TheSim:GetSetting(SETTING_SECTION, SETTING_KEY)
    local ok, d = str and str ~= "" and pcall(json.decode, str)
    _ui_pos_cache = (ok and type(d) == "table") and d or {}
    return _ui_pos_cache
end

local function SaveUiPos()
    if _ui_pos_cache ~= nil then
        local ok, str = pcall(json.encode, _ui_pos_cache)
        if ok then TheSim:SetSetting(SETTING_SECTION, SETTING_KEY, str) end
    end
end

-- 容器对应 widget（拖拽键名与勋章容器识别共用）
local function GetContainerWidget(cw)
    local rep = cw and cw.container and cw.container.replica and cw.container.replica.container
    return rep ~= nil and rep.GetWidget ~= nil and rep:GetWidget() or nil
end

-- ===== 冲突判定：true=对方接管拖拽，本模组让位 =====
-- 勋章在场时棱镜自动让位，故先判勋章。
-- 勋章开关 MEDAL_CLIENT_DRAG_SWITCH，范围 MEDAL_CONTAINERDRAG_SETTING(0关/1仅勋章容器/2全部)；
-- 棱镜开关 CONFIGS_LEGION.DRAGABLEUI。
local _legion_present
local function IsLegionPresent() -- 加载态会话固定，探测一次
    if _legion_present == nil then
        _legion_present = _G.rawget ~= nil and _G.rawget(_G, "CONFIGS_LEGION") ~= nil
    end
    return _legion_present
end

local function IsConflicted(cw)
    local TUNING = _G.TUNING
    if TUNING ~= nil and TUNING.FUNCTIONAL_MEDAL_IS_OPEN == true then
        if TUNING.MEDAL_CLIENT_DRAG_SWITCH ~= true then return false end
        local setting = TUNING.MEDAL_CONTAINERDRAG_SETTING or 0
        if setting <= 0 then return false end
        if setting >= 2 then return true end
        local widget = GetContainerWidget(cw) -- 仅勋章容器(带 dragtype)
        return widget ~= nil and widget.dragtype ~= nil
    end
    if IsLegionPresent() then
        local OPTS = _G.CONFIGS_LEGION
        return OPTS ~= nil and OPTS.DRAGABLEUI == true
    end
    return false
end

-- 开关低频变化而容器高频开关：TTL 复用；设置界面打开时作废缓存
local _DRAG_SWITCH_TTL = 1
local _check_time = -math.huge
local _conflict = false

local function Invalidate()
    _check_time = -math.huge
end

local function UiDragConflict(cw)
    local now = (_G.GetTime ~= nil and _G.GetTime()) or 0
    if now - _check_time >= 0 and now - _check_time < _DRAG_SWITCH_TTL then
        return _conflict
    end
    _check_time = now
    _conflict = IsConflicted(cw)
    return _conflict
end

-- 拖动状态清理（Close 与拖放结束共用）
local function ClearDragState(self)
    if self.followhandler ~= nil then
        self.followhandler:Remove()
        self.followhandler = nil
    end
    self.m_startpos = nil
    self.p_startpos = nil
    self.csp_panel = nil
end

function ContainerUiDrag.Init(config, panel_manager, addclasspostconstruct)
    Config, PanelManager, AddClassPostConstruct = config, panel_manager, addclasspostconstruct

    -- 棱镜(OptionsLegion)/勋章(MedalSettingsScreens)设置界面打开即作废缓存：
    -- 拖拽开关只在这两界面里可改，改完出来首次开容器必重查
    AddClassPostConstruct("screens/playerhud", function(self)
        local _OpenScreenUnderPause = self.OpenScreenUnderPause
        if _OpenScreenUnderPause == nil then return end
        self.OpenScreenUnderPause = function(self, screen, ...)
            if screen ~= nil and (screen.name == "OptionsLegion" or screen.name == "MedalSettingsScreens") then
                Invalidate()
            end
            return _OpenScreenUnderPause(self, screen, ...)
        end
    end)

    AddClassPostConstruct("widgets/containerwidget", function(self)
        local _Close = self.Close
        self.Close = function(self, ...)
            ClearDragState(self)
            self.csp_base_pos, self.csp_panel_offset, self.csp_draggable = nil, nil, nil
            return _Close(self, ...)
        end

        local _Open = self.Open
        self.Open = function(self, container, doer, ...)
            _Open(self, container, doer, ...)
            if self.csp_draggable or not Config.IsUiDragEnabled() or UiDragConflict(self) then return end

            local uikey = self.container.prefab
            local widget = GetContainerWidget(self)
            if widget ~= nil and widget.dragtype ~= nil then uikey = widget.dragtype end

            self.csp_draggable = true
            if self.csp_base_pos == nil then self.csp_base_pos = self:GetPosition() end

            local saved = LoadUiPos()[uikey]
            if saved then self:SetPosition(saved.x, saved.y, saved.z or 0) end

            local drag_offset = 0.6
            local tip = STRINGS.CSP.DRAG_TIP or "右键拖拽移动窗口"
            local function BindTarget(uitarget) -- 右键按住拖动容器
                if not uitarget then return end
                -- 棱镜的 Open 链会随后把 tooltip 覆盖成它自己的文案（其开关关闭时该文案被过滤隐藏），
                -- 延迟一帧重设，保证最终显示的提示是本模组的文案
                local inst = self.inst
                if inst ~= nil and inst.DoTaskInTime ~= nil then
                    inst:DoTaskInTime(0, function() if uitarget.SetTooltip ~= nil then uitarget:SetTooltip(tip) end end)
                else
                    uitarget:SetTooltip(tip)
                end
                local old_OnControl = uitarget.OnControl
                uitarget.OnControl = function(sel, control, down, ...)
                    local parent = sel:GetParent()
                    if control == CONTROL_SECONDARY and parent then
                        if down then parent:csp_StartDrag() else parent:csp_EndDrag() end
                    end
                    return old_OnControl and old_OnControl(sel, control, down, ...)
                end
            end
            BindTarget(self.bgimage)
            BindTarget(self.bganim)

            -- 方法用 csp_ 前缀命名，避免与棱镜(l_*)/勋章(StartDrag等)的同名拖拽方法互相覆盖
            function self:csp_SetDragPos(x, y, z)
                local pos = type(x) == "number" and Vector3(x, y, z) or x
                local newpos = self.p_startpos + (pos - self.m_startpos) / (self:GetScale().x / drag_offset)
                self:SetPosition(newpos)
                if self.csp_panel and self.csp_panel:IsVisible() then
                    self.csp_panel:SetPosition(newpos + self.csp_panel_offset)
                end
            end
            function self:csp_StartDrag()
                if self.followhandler == nil then
                    local mousepos = TheInput:GetScreenPosition()
                    self.m_startpos = mousepos
                    self.p_startpos = self:GetPosition()
                    local panel = PanelManager.GetPanel(self.container)
                    self.csp_panel = panel
                    if panel then self.csp_panel_offset = panel:GetPosition() - self:GetPosition() end
                    self.followhandler = TheInput:AddMoveHandler(function(x, y)
                        self:csp_SetDragPos(x, y, 0)
                        if not Input:IsMouseDown(MOUSEBUTTON_RIGHT) then self:csp_EndDrag() end
                    end)
                    self:csp_SetDragPos(mousepos)
                end
            end
            function self:csp_EndDrag()
                ClearDragState(self)
                local p = self:GetPosition()
                LoadUiPos()[uikey] = { x = p.x, y = p.y, z = p.z }
                SaveUiPos()
            end
        end
    end)
end

-- 记录面板相对容器偏移（modmain 面板创建后调用）
function ContainerUiDrag.RecordPanelOffset(containerwidget)
    if containerwidget == nil or containerwidget.csp_panel_offset ~= nil then return end
    local panel = PanelManager.GetPanel(containerwidget.container)
    if panel then
        containerwidget.csp_panel_offset = panel:GetPosition() - containerwidget:GetPosition()
    end
end

-- 重置UI位置（仅重置未被对方接管的容器）
function ContainerUiDrag.ResetPositions()
    local reset_any = false
    if _ui_pos_cache ~= nil then
        for k in pairs(_ui_pos_cache) do _ui_pos_cache[k] = nil; reset_any = true end
    end
    local player = ThePlayer
    if player and player.HUD and player.HUD.controls then
        for _, cw in pairs(player.HUD.controls.containers or {}) do
            if cw.csp_base_pos ~= nil and not UiDragConflict(cw) then
                cw:SetPosition(cw.csp_base_pos)
                reset_any = true
                if cw.csp_panel_offset ~= nil then
                    local panel = PanelManager.GetPanel(cw.container)
                    if panel then panel:SetPosition(cw.csp_base_pos + cw.csp_panel_offset) end
                end
            end
        end
    end
    SaveUiPos()
    if reset_any then print(STRINGS.CSP.UI_POS_RESET or "已重置烹饪锅UI位置") end
end

return ContainerUiDrag
