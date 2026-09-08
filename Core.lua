--[[
    FrameBoss - Core.lua
    简洁首领框体：头像 / 名称 / 大血条 / 能量条 / 重要 buff / 玩家 debuff
    纯暴雪原生 API + Ace3 骨架；布局严格 8px 栅格。
--]]

local FrameBoss = LibStub("AceAddon-3.0"):NewAddon("FrameBoss", "AceEvent-3.0", "AceConsole-3.0")
_G.FrameBoss = FrameBoss

-- 8px 栅格常量
local PAD        = 8
local FRAME_W    = 240
local FRAME_H    = 56    -- 含能量条：8 + 16 + 16 + 8 + 8
local FRAME_H_NP = 48    -- 无能量条：8 + 16 + 16 + 8
local PORTRAIT_S = 40
local NAME_H     = 16
local HEALTH_H   = 16
local POWER_H    = 8
local RIGHT_X    = PAD + PORTRAIT_S + PAD   -- 56
local BAR_W      = FRAME_W - RIGHT_X - PAD  -- 176
local GAP        = 8
local MAX_BOSS   = 5

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
    self:CreateMover()
    self:CreateFrames()
    self:ApplySettings()
    self:RegisterEvents()
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
    self:RegisterEvent("UNIT_AURA", "UnitAura")
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

function FrameBoss:UnitAura(event, unit)
    if self.db.profile.testMode then return end
    local f = BossFrame(unit)
    if f and UnitExists(unit) then self.Auras.Update(f, unit) end
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
    mover.label:SetPoint("BOTTOMLEFT", mover, "TOPLEFT", 0, GAP)
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
        local f = CreateFrame("Frame", nil, self.mover, "BackdropTemplate")
        f:SetSize(FRAME_W, FRAME_H)
        f:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
        })
        f:SetBackdropColor(0, 0, 0, 0.55)
        f:SetBackdropBorderColor(0, 0, 0, 0.9)
        if i == 1 then
            f:SetPoint("TOPLEFT", self.mover, "TOPLEFT", 0, 0)
        else
            f:SetPoint("TOPLEFT", self.frames[i - 1].auraRow, "BOTTOMLEFT", 0, -GAP)
        end
        f.bossIndex = i
        f.unit = "boss" .. i

        -- 头像（40×40，左上 8,8）
        f.portrait = f:CreateTexture(nil, "ARTWORK")
        f.portrait:SetSize(PORTRAIT_S, PORTRAIT_S)
        f.portrait:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
        local pborder = CreateFrame("Frame", nil, f, "BackdropTemplate")
        pborder:SetSize(PORTRAIT_S, PORTRAIT_S)
        pborder:SetPoint("TOPLEFT", f.portrait)
        pborder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        pborder:SetBackdropBorderColor(0, 0, 0, 1)

        -- 名称（行高 16）
        f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.name:SetPoint("TOPLEFT", f, "TOPLEFT", RIGHT_X, -PAD)
        f.name:SetSize(BAR_W - 56, NAME_H)
        f.name:SetJustifyH("LEFT")
        f.name:SetJustifyV("MIDDLE")
        f.name:SetWordWrap(false)

        -- 血量百分比（名称行右侧）
        f.percent = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.percent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -PAD)
        f.percent:SetSize(48, NAME_H)
        f.percent:SetJustifyH("RIGHT")
        f.percent:SetJustifyV("MIDDLE")

        -- 大血条（高 16，y=24）
        f.health = CreateFrame("StatusBar", nil, f)
        f.health:SetSize(BAR_W, HEALTH_H)
        f.health:SetPoint("TOPLEFT", f, "TOPLEFT", RIGHT_X, -(PAD + NAME_H))
        f.health:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local hbg = f.health:CreateTexture(nil, "BACKGROUND")
        hbg:SetAllPoints()
        hbg:SetColorTexture(0.15, 0.05, 0.05, 0.8)

        -- 能量条（高 8，紧贴血条下方）
        f.power = CreateFrame("StatusBar", nil, f)
        f.power:SetSize(BAR_W, POWER_H)
        f.power:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, 0)
        f.power:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local pbg = f.power:CreateTexture(nil, "BACKGROUND")
        pbg:SetAllPoints()
        pbg:SetColorTexture(0.05, 0.05, 0.1, 0.8)

        -- 光环行（框体下方 8px，图标由 Auras.lua 填充）
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W, 32)
        row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -GAP)
        row:Hide()
        f.auraRow = row

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
    self.Auras.Update(f, unit)
end

function FrameBoss:UpdateHealth(f, unit)
    local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
    f.health:SetMinMaxValues(0, math.max(hpMax, 1))
    f.health:SetValue(hp)
    local pct = hpMax > 0 and math.floor(hp / hpMax * 100 + 0.5) or 100
    f.percent:SetText(pct .. "%")
end

function FrameBoss:UpdatePower(f, unit)
    if not self.db.profile.showPower then
        f.power:Hide()
        f:SetHeight(FRAME_H_NP)
        return
    end
    local powerType = UnitPowerType(unit)
    local power, powerMax = UnitPower(unit), UnitPowerMax(unit)
    if powerMax == 0 then
        f.power:Hide()
        f:SetHeight(FRAME_H_NP)
    else
        f.power:Show()
        f:SetHeight(FRAME_H)
        f.power:SetMinMaxValues(0, powerMax)
        f.power:SetValue(power)
        local c = PowerBarColor[powerType] or PowerBarColor[0]
        if c then f.power:SetStatusBarColor(c.r, c.g, c.b) end
    end
end

-- 全量刷新（开战/进世界/测试切换）-----------------------------------------

function FrameBoss:RefreshAll()
    local db = self.db.profile
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
