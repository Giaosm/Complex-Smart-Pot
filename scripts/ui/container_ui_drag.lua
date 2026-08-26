-- 容器UI可拖拽（参考棱镜 SetUIDragable 思路实现）
-- 拖动原版容器widget，智能锅面板跟随其位置；检测到棱镜/能力勋章时自动跳过；受 enable_ui_drag 开关控制。

local SETTING_SECTION = "complex_smart_pot"
local SETTING_KEY = "ui_pos"

local ContainerUiDrag = {}
local _ui_pos_cache = nil

-- 由 modmain 注入
local Config, PanelManager, AddClassPostConstruct = nil, nil, nil

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

-- 棱镜/能力勋章已提供拖拽？
local function UiDragConflict()
    if _G.rawget ~= nil and _G.rawget(_G, "CONFIGS_LEGION") ~= nil then return true end
    local TUNING = _G.TUNING
    return TUNING ~= nil and TUNING.FUNCTIONAL_MEDAL_IS_OPEN == true
end

-- 清理拖拽监听与状态（Close 与拖动结束时共用）
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
            if self.csp_draggable or not Config.IsUiDragEnabled() or UiDragConflict() then return end

            local rep = self.container and self.container.replica and self.container.replica.container
            if rep == nil or rep.GetWidget == nil then return end
            local widget = rep:GetWidget()
            local uikey = widget and widget.dragtype or self.container.prefab
            if uikey == nil then return end

            self.csp_draggable = true
            if self.csp_base_pos == nil then self.csp_base_pos = self:GetPosition() end

            -- 应用已保存位置
            local saved = LoadUiPos()[uikey]
            if saved then self:SetPosition(saved.x, saved.y, saved.z or 0) end

            -- 背景图接收右键：按下/松开拖动面板
            local drag_offset = 0.6
            local function BindTarget(uitarget)
                if not uitarget then return end
                uitarget:SetTooltip(STRINGS.CSP.DRAG_TIP or "右键按住可拖拽")
                local old_OnControl = uitarget.OnControl
                uitarget.OnControl = function(sel, control, down, ...)
                    local parent = sel:GetParent()
                    if control == CONTROL_SECONDARY and parent then
                        if down then parent:l_StartDrag() else parent:l_EndDrag() end
                    end
                    return old_OnControl and old_OnControl(sel, control, down, ...)
                end
            end
            BindTarget(self.bgimage)
            BindTarget(self.bganim)

            function self:l_SetDragPosition(x, y, z)
                local pos = type(x) == "number" and Vector3(x, y, z) or x
                local scale = self:GetScale()
                local newpos = self.p_startpos + (pos - self.m_startpos) / (scale.x / drag_offset)
                self:SetPosition(newpos)
                if self.csp_panel and self.csp_panel:IsVisible() then
                    self.csp_panel:SetPosition(newpos + self.csp_panel_offset)
                end
            end
            function self:l_StartDrag()
                if self.followhandler == nil then
                    local mousepos = TheInput:GetScreenPosition()
                    self.m_startpos = mousepos
                    self.p_startpos = self:GetPosition()
                    -- 记录面板相对偏移，拖动时保持相对位置
                    local panel = PanelManager.GetPanel(self.container)
                    self.csp_panel = panel
                    if panel then self.csp_panel_offset = panel:GetPosition() - self:GetPosition() end
                    self.followhandler = TheInput:AddMoveHandler(function(x, y)
                        self:l_SetDragPosition(x, y, 0)
                        if not Input:IsMouseDown(MOUSEBUTTON_RIGHT) then self:l_EndDrag() end
                    end)
                    self:l_SetDragPosition(mousepos)
                end
            end
            function self:l_EndDrag()
                ClearDragState(self)
                local uipos = LoadUiPos()
                local p = self:GetPosition()
                uipos[uikey] = { x = p.x, y = p.y, z = p.z }
                SaveUiPos()
            end
        end
    end)
end

-- 记录面板相对容器widget初始偏移（面板创建后由 modmain 调用）
function ContainerUiDrag.RecordPanelOffset(containerwidget)
    if containerwidget == nil or containerwidget.csp_panel_offset ~= nil then return end
    local panel = PanelManager and PanelManager.GetPanel(containerwidget.container)
    if panel then
        containerwidget.csp_panel_offset = panel:GetPosition() - containerwidget:GetPosition()
    end
end

-- 重置UI位置：清空缓存并恢复容器widget及其面板到初始位置
function ContainerUiDrag.ResetPositions()
    if UiDragConflict() then return end

    local reset_any = false
    if _ui_pos_cache ~= nil then
        for k in pairs(_ui_pos_cache) do _ui_pos_cache[k] = nil; reset_any = true end
    end

    local player = ThePlayer
    if player and player.HUD and player.HUD.controls then
        for _, cw in pairs(player.HUD.controls.containers or {}) do
            if cw.csp_base_pos ~= nil then
                cw:SetPosition(cw.csp_base_pos)
                reset_any = true
                if cw.csp_panel_offset ~= nil then
                    local panel = PanelManager and PanelManager.GetPanel(cw.container)
                    if panel then panel:SetPosition(cw.csp_base_pos + cw.csp_panel_offset) end
                end
            end
        end
    end

    SaveUiPos()
    if reset_any then print(STRINGS.CSP.UI_POS_RESET or "已重置烹饪锅UI位置") end
end

return ContainerUiDrag
