-- 任务队列：劫持玩家操作，支持任意按键中止，用于自动做饭流程控制
-- 注意：全局只应存在一个实例（由 auto_cook_controller 的 GetSharedTaskQueue 保证），
-- 否则多个实例各自包装 playercontroller.OnControl，销毁时会互相拆掉对方的包装链
local id_push_thread = "task_queue_push_thread"

local Mouse_controls = {
    [CONTROL_PRIMARY] = true,
    [CONTROL_SECONDARY] = true,
}

-- 在当前 playercontroller 上安装/刷新 OnControl 包装器
-- 支持首次安装、玩家重生/切换后重新获取新的 pc
local function InstallWrapper(self, pc)
    if not pc then return end
    if not self._wrapper_on_control then
        self._wrapper_on_control = function(pc, control, down, ...)
            if down then
                if not TheInput:IsControlPressed(CONTROL_FORCE_INSPECT)
                    and not (Mouse_controls[control] and TheInput:GetHUDEntityUnderMouse()) then
                    for func, ctrls in pairs(self._func_control) do
                        if ctrls[control] then
                            if func(pc) then
                                self._func_control[func] = nil
                            end
                        end
                    end
                end
            end
            if self._orig_on_control then
                return self._orig_on_control(pc, control, down, ...)
            end
        end
    end
    if pc.OnControl ~= self._wrapper_on_control then
        self._orig_on_control = pc.OnControl
        pc.OnControl = self._wrapper_on_control
    end
end

local TaskQueue = Class(function(self)
    self._running = false
    self._thread_push = nil
    self._task_func_stop = nil
    self._func_control = {}
    self._stop_control_func = nil
    self._orig_on_control = nil
    self._wrapper_on_control = nil

    local pc = ThePlayer and ThePlayer.components and ThePlayer.components.playercontroller
    InstallWrapper(self, pc)
end)

function TaskQueue:StopCurrent()
    if self._thread_push then
        KillThreadsWithID(id_push_thread)
        self._thread_push = nil
        if type(self._task_func_stop) == "function" then
            self._task_func_stop()
        end
    end
    if self._stop_control_func then
        self._func_control[self._stop_control_func] = nil
        self._stop_control_func = nil
    end
    self._running = false
end

function TaskQueue:Destroy()
    self:StopCurrent()
    self._func_control = {}
    if self._orig_on_control then
        if ThePlayer and ThePlayer.components and ThePlayer.components.playercontroller then
            ThePlayer.components.playercontroller.OnControl = self._orig_on_control
        end
    end
end

function TaskQueue:IsRunning()
    return self._running
end

function TaskQueue:RegFuncControls(func, controls)
    local ret
    local function addkeyboard()
        if not ret then ret = {} end
        for control = CONTROL_ATTACK, CONTROL_MOVE_RIGHT do
            ret[control] = true
        end
    end
    local function addmouse()
        if not ret then ret = {} end
        ret[CONTROL_PRIMARY] = true
        ret[CONTROL_SECONDARY] = true
    end
    if controls == "keyboard" then
        addkeyboard()
    elseif controls == "mouse" then
        addmouse()
    elseif controls == "null" then
        ret = nil
    elseif type(controls) == "table" then
        ret = controls
    else
        addkeyboard()
        addmouse()
    end

    if type(func) == "function" then
        self._func_control[func] = ret
    end
end

function TaskQueue:RegNowTask(func_loop, func_stop, controls)
    self:StopCurrent()

    local pc = ThePlayer and ThePlayer.components and ThePlayer.components.playercontroller
    InstallWrapper(self, pc)

    self._task_func_stop = func_stop
    self._running = true

    self._stop_control_func = function()
        self:StopCurrent()
        return true
    end
    self:RegFuncControls(self._stop_control_func, controls)

    self._thread_push = StartThread(function()
        while self._thread_push do
            if func_loop() then
                break
            end
        end
        self:StopCurrent()
    end, id_push_thread)

    return self._thread_push
end

return TaskQueue
