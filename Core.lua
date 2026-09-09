--[[
    FrameBoss - Core.lua
    简洁首领框体：名称 / 大血条 / 能量条 / 重要 buff / 玩家 debuff（无头像、无底板）
    纯暴雪原生 API + Ace3 骨架；布局严格 8px 栅格。
--]]

local FrameBoss = LibStub("AceAddon-3.0"):NewAddon("FrameBoss", "AceEvent-3.0", "AceConsole-3.0")
_G.FrameBoss = FrameBoss

-- 12.0 起，副本内敌方单位的血量/能量等可能是 "secret" 数值：
-- 插件代码不能对它做算术或字符串拼接（会抛 "numeric conversion on a secret number"），
-- 只能原样传给 StatusBar 等引擎 API；需要显示百分比时用 UnitHealthPercent/UnitPowerPercent。
local isSecret = issecretvalue or function() return false end

-- 布局常量（内容紧贴，无内边距；头像为矩形，占满整高）
local FRAME_W    = 240
local PORTRAIT_W = 56
local NAME_H     = 12
local HEALTH_H   = 20
local POWER_H    = 10
local FRAME_H    = NAME_H + HEALTH_H + POWER_H  -- 42
local FRAME_H_NP = NAME_H + HEALTH_H            -- 32（无能量条）
local BAR_X      = PORTRAIT_W                   -- 56
local BAR_W      = FRAME_W - PORTRAIT_W         -- 184
local GAP        = 0                            -- 元素全部紧贴
local MAX_BOSS   = 5

-- 原生风格状态条材质（暴雪自带的光泽状态条）
local BAR_TEX    = "Interface\\TargetingFrame\\UI-StatusBar"

FrameBoss.FRAME_W = FRAME_W

local DEFAULT_POINT = { "TOPLEFT", "UIParent", "TOPLEFT", 400, -300 }

local defaults = {
    profile = {
        scale       = 1.0,
        auraSize    = 32,
        showPower   = true,
        healthColor = { 0.9, 0.2, 0.2 },
        locked      = true,
        testMode    = false,
        point       = { unpack(DEFAULT_POINT) },
    },
}

-- 把 unit token（boss1..boss5）映射到框体
local function BossFrame(unit)
    if type(unit) ~= "string" then return nil end
    local n = unit:match("^boss(%d)$")
    if not n then return nil end
    n = tonumber(n)
    if n < 1 or n > MAX_BOSS then return nil end
    return FrameBoss.frames[n]
end

function FrameBoss:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("FrameBossDB", defaults)
    self:SetupOptions()
end

function FrameBoss:OnEnable()
    self:DisableBlizzardBossFrames()
    self:CreateMover()
    self:CreateFrames()
    self:ApplySettings()
    self:RegisterEvents()
end

-- 禁用原生首领框体 ---------------------------------------------------------
-- 做法参考 oUF blizzard.lua：容器反注册事件、Hide、reparent 到隐藏父级，
-- 并 hook SetParent 防止编辑模式/布局管理器把它捞回来；
-- 子框体（Boss1TargetFrame…）只反注册事件 + Hide——不能 reparent，
-- 容器的布局代码会因算不出尺寸而报错。

local hiddenBossParent = CreateFrame("Frame", nil, UIParent)
hiddenBossParent:SetAllPoints()
hiddenBossParent:Hide()

-- 战斗中对受保护框体 SetParent 会被阻断，退出战斗后补做
local looseBossFrames = {}
local bossWatcher = CreateFrame("Frame")
bossWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
bossWatcher:SetScript("OnEvent", function()
    for frame in next, looseBossFrames do
        frame:SetParent(hiddenBossParent)
    end
    table.wipe(looseBossFrames)
end)

function FrameBoss:DisableBlizzardBossFrames()
    local container = _G.BossTargetFrameContainer
    if container then
        container:UnregisterAllEvents()
        container:Hide()
        container:SetParent(hiddenBossParent)
        hooksecurefunc(container, "SetParent", function(self, parent)
            if parent ~= hiddenBossParent then
                if InCombatLockdown() and self:IsProtected() then
                    looseBossFrames[self] = true
                else
                    self:SetParent(hiddenBossParent)
                end
            end
        end)
    end

    for i = 1, (_G.MAX_BOSS_FRAMES or MAX_BOSS) do
        local bf = _G["Boss" .. i .. "TargetFrame"]
        if bf then
            bf:UnregisterAllEvents()
            bf:Hide()
        end
    end
end

function FrameBoss:RegisterEvents()
    self:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT", "RefreshAll")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "RefreshAll")
    self:RegisterEvent("UNIT_HEALTH", "UnitHealth")
    self:RegisterEvent("UNIT_MAXHEALTH", "UnitHealth")
    self:RegisterEvent("UNIT_POWER_UPDATE", "UnitPower")
    self:RegisterEvent("UNIT_MAXPOWER", "UnitPower")
    self:RegisterEvent("UNIT_DISPLAYPOWER", "UnitPower")
    self:RegisterEvent("UNIT_NAME_UPDATE", "UnitName")
    self:RegisterEvent("UNIT_PORTRAIT_UPDATE", "UnitPortrait")
    -- UNIT_AURA 无需注册：原生 AuraContainer 内部自动刷新光环
end

-- 事件处理 ---------------------------------------------------------------

function FrameBoss:UnitHealth(event, unit)
    if self.db.profile.testMode then return end
    local f = BossFrame(unit)
    if f and UnitExists(unit) then self:UpdateHealth(f, unit) end
end

function FrameBoss:UnitPower(event, unit)
    if self.db.profile.testMode then return end
    local f = BossFrame(unit)
    if f and UnitExists(unit) then self:UpdatePower(f, unit) end
end

function FrameBoss:UnitName(event, unit)
    if self.db.profile.testMode then return end
    local f = BossFrame(unit)
    if f and UnitExists(unit) then f.name:SetText(UnitName(unit)) end
end

function FrameBoss:UnitPortrait(event, unit)
    if self.db.profile.testMode then return end
    local f = BossFrame(unit)
    if f and UnitExists(unit) then SetPortraitTexture(f.portrait, unit) end
end

-- 容器（锚点/拖动/缩放）---------------------------------------------------

function FrameBoss:CreateMover()
    local mover = CreateFrame("Frame", "FrameBossAnchor", UIParent, "BackdropTemplate")
    mover:SetSize(FRAME_W, MAX_BOSS * FRAME_H + (MAX_BOSS - 1) * GAP)
    mover:SetClampedToScreen(true)
    mover:SetMovable(true)
    mover:EnableMouse(false)
    mover:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
    })
    mover.label = mover:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mover.label:SetPoint("BOTTOMLEFT", mover, "TOPLEFT", 0, 4)
    mover.label:SetText("FrameBoss（拖动移动）")
    mover:SetScript("OnDragStart", function(self) self:StartMoving() end)
    mover:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, rel, relPoint, x, y = self:GetPoint(1)
        local relName = "UIParent"
        if rel and rel.GetName then
            local n = rel:GetName()
            if n then relName = n end
        end
        FrameBoss.db.profile.point = { point, relName, relPoint, x, y }
    end)
    mover:Hide()
    self.mover = mover
end

function FrameBoss:ApplyMover()
    local db = self.db.profile
    local mover = self.mover
    local stackH = MAX_BOSS * FRAME_H + (2 * MAX_BOSS - 1) * GAP + MAX_BOSS * db.auraSize
    mover:SetSize(FRAME_W, stackH)
    mover:ClearAllPoints()
    mover:SetPoint(unpack(db.point))
    mover:SetScale(db.scale)
    local active = db.testMode or not db.locked
    mover:EnableMouse(active)
    mover:SetMovable(active)
    if active then
        mover:RegisterForDrag("LeftButton")
        mover:SetBackdropColor(0, 0.4, 0, 0.35)
        mover:SetBackdropBorderColor(0, 1, 0, 0.8)
        mover.label:Show()
    else
        mover:RegisterForDrag()
        mover:SetBackdropColor(0, 0, 0, 0)
        mover:SetBackdropBorderColor(0, 0, 0, 0)
        mover.label:Hide()
    end
end

-- 框体创建 ---------------------------------------------------------------

function FrameBoss:CreateFrames()
    self.frames = {}
    for i = 1, MAX_BOSS do
        -- 无底版框体；矩形头像在左占满整高，右侧名称/血条/能量条紧贴排列
        local f = CreateFrame("Frame", nil, self.mover)
        f:SetSize(FRAME_W, FRAME_H)
        if i == 1 then
            f:SetPoint("TOPLEFT", self.mover, "TOPLEFT", 0, 0)
        else
            f:SetPoint("TOPLEFT", self.frames[i - 1].auraRow, "BOTTOMLEFT", 0, -GAP)
        end
        f.bossIndex = i
        f.unit = "boss" .. i

        -- 矩形头像（宽 56，高度跟随框体 42/32）
        f.portrait = f:CreateTexture(nil, "ARTWORK")
        f.portrait:SetWidth(PORTRAIT_W)
        f.portrait:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        f.portrait:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        f.portrait:SetTexCoord(0.05, 0.95, 0.08, 0.92)
        local pborder = CreateFrame("Frame", nil, f, "BackdropTemplate")
        pborder:SetAllPoints(f.portrait)
        pborder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        pborder:SetBackdropBorderColor(0, 0, 0, 1)

        -- 名称（紧贴顶部）
        f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.name:SetPoint("TOPLEFT", f, "TOPLEFT", BAR_X, 0)
        f.name:SetSize(BAR_W - 52, NAME_H)
        f.name:SetJustifyH("LEFT")
        f.name:SetJustifyV("MIDDLE")
        f.name:SetWordWrap(false)

        -- 血量百分比（名称行右侧）
        f.percent = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.percent:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
        f.percent:SetSize(48, NAME_H)
        f.percent:SetJustifyH("RIGHT")
        f.percent:SetJustifyV("MIDDLE")

        -- 大血条（高 20，紧贴名称行）
        f.health = CreateFrame("StatusBar", nil, f)
        f.health:SetSize(BAR_W, HEALTH_H)
        f.health:SetPoint("TOPLEFT", f, "TOPLEFT", BAR_X, -NAME_H)
        f.health:SetStatusBarTexture(BAR_TEX)
        local hbg = f.health:CreateTexture(nil, "BACKGROUND")
        hbg:SetAllPoints()
        hbg:SetTexture(BAR_TEX)
        hbg:SetVertexColor(0.12, 0.04, 0.04)

        -- 能量条（高 10，紧贴血条下方）
        f.power = CreateFrame("StatusBar", nil, f)
        f.power:SetSize(BAR_W, POWER_H)
        f.power:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, 0)
        f.power:SetStatusBarTexture(BAR_TEX)
        local pbg = f.power:CreateTexture(nil, "BACKGROUND")
        pbg:SetAllPoints()
        pbg:SetTexture(BAR_TEX)
        pbg:SetVertexColor(0.04, 0.04, 0.08)

        -- 光环行占位（紧贴框体下方；本身不渲染，只用于框体间距布局，
        -- 实际图标由 Auras.lua 的原生 AuraContainer 承载）
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W, self.db.profile.auraSize)
        row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -GAP)
        f.auraRow = row

        -- 原生光环容器（战斗中创建会失败，Auras 内部会在脱战后自动补建）
        self.Auras.CreateContainers(f)

        f:Hide()
        self.frames[i] = f
    end
end

-- 数据更新 ---------------------------------------------------------------

function FrameBoss:RefreshFrame(f, unit)
    SetPortraitTexture(f.portrait, unit)
    f.name:SetText(UnitName(unit))
    self:UpdateHealth(f, unit)
    self:UpdatePower(f, unit)
    self.Auras.SetUnit(f, unit)
end

function FrameBoss:UpdateHealth(f, unit)
    -- hp/hpMax 可能是 secret：原样喂给 StatusBar，绝不参与算术
    local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
    if isSecret(hpMax) then
        f.health:SetMinMaxValues(0, hpMax)
    else
        f.health:SetMinMaxValues(0, math.max(hpMax or 1, 1))
    end
    f.health:SetValue(hp)

    -- 百分比：UnitHealthPercent 对副本内首领也可能返回 secret。
    -- secret 只能穿过 string.format 这类 C 函数（产出 secret 字符串，SetText 接受），
    -- 绝不能做 Lua 算术（+/math.floor）或 .. 拼接。写法同 oUF perhp 标签。
    if not UnitIsConnected(unit) then
        f.percent:SetText("离线")
    elseif UnitIsDeadOrGhost(unit) then
        f.percent:SetText("死亡")
    elseif not UnitHealthPercent then
        f.percent:SetText("")
    else
        local curve = CurveConstants and CurveConstants.ScaleTo100
        local pct = UnitHealthPercent(unit, false, curve)
        if pct == nil then
            f.percent:SetText("")
        elseif isSecret(pct) then
            f.percent:SetText(string.format("%.0f%%", pct))
        else
            f.percent:SetText(math.floor((tonumber(pct) or 0) + 0.5) .. "%")
        end
    end
end

function FrameBoss:UpdatePower(f, unit)
    if not self.db.profile.showPower then
        f.power:Hide()
        f:SetHeight(FRAME_H_NP)
        return
    end
    local power, powerMax = UnitPower(unit), UnitPowerMax(unit)
    local secret = isSecret(powerMax)
    if not secret and (not powerMax or powerMax <= 0) then
        f.power:Hide()
        f:SetHeight(FRAME_H_NP)
    else
        f.power:Show()
        f:SetHeight(FRAME_H)
        -- secret 时原样传入；普通数值时兜底 max >= 1
        f.power:SetMinMaxValues(0, secret and powerMax or math.max(powerMax, 1))
        f.power:SetValue(power)
        local c = PowerBarColor[UnitPowerType(unit)] or PowerBarColor[0]
        if c then f.power:SetStatusBarColor(c.r, c.g, c.b) end
    end
end

-- 全量刷新（开战/进世界/测试切换）-----------------------------------------

function FrameBoss:RefreshAll()
    local db = self.db.profile
    -- 光环尺寸选项可能在面板里被改动，每次全量刷新时同步布局
    for i = 1, MAX_BOSS do self.Auras.ApplySize(self.frames[i]) end
    local anyShown = false
    for i = 1, MAX_BOSS do
        local f = self.frames[i]
        local unit = f.unit
        if db.testMode then
            self:FillTestFrame(f, i)
            f:Show()
            anyShown = true
        elseif UnitExists(unit) then
            self:RefreshFrame(f, unit)
            f:Show()
            anyShown = true
        else
            self.Auras.Clear(f)
            f:Hide()
        end
    end
    if not db.locked then anyShown = true end
    self.mover:SetShown(anyShown)
    self:ApplyMover()
end

function FrameBoss:ApplySettings()
    local c = self.db.profile.healthColor
    for i = 1, MAX_BOSS do
        self.frames[i].health:SetStatusBarColor(c[1], c[2], c[3])
    end
    self:ApplyMover()
    self:RefreshAll()
end

function FrameBoss:SetTestMode(v)
    self.db.profile.testMode = v
    self:RefreshAll()
end

function FrameBoss:ResetPosition()
    self.db.profile.point = { unpack(DEFAULT_POINT) }
    self:ApplyMover()
end

-- 测试模式假数据 ----------------------------------------------------------

function FrameBoss:FillTestFrame(f, i)
    SetPortraitTexture(f.portrait, "player")
    f.name:SetText("测试首领 " .. i)
    local hp = 90 - i * 10
    f.health:SetMinMaxValues(0, 100)
    f.health:SetValue(hp)
    f.percent:SetText(hp .. "%")
    if self.db.profile.showPower then
        f.power:Show()
        f:SetHeight(FRAME_H)
        f.power:SetMinMaxValues(0, 100)
        f.power:SetValue(60)
        local c = PowerBarColor[0]
        if c then f.power:SetStatusBarColor(c.r, c.g, c.b) end
    else
        f.power:Hide()
        f:SetHeight(FRAME_H_NP)
    end
    self.Auras.ShowTest(f)
end
