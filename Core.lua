--[[
    FrameBoss - Core.lua
    Minimalist boss frames: name / large health bar / power bar / important
    buffs / player debuffs (no portrait, no backdrop).
    Pure Blizzard native API + Ace3 scaffolding; layout is a strict 8px grid.
--]]

local FrameBoss = LibStub("AceAddon-3.0"):NewAddon("FrameBoss", "AceEvent-3.0", "AceConsole-3.0")
_G.FrameBoss = FrameBoss

local L = LibStub("AceLocale-3.0"):GetLocale("FrameBoss", true)

-- As of 12.0, enemy-unit health/power inside instances may be "secret" values:
-- addon code may not perform arithmetic or string concatenation on them
-- (raises "numeric conversion on a secret number"); pass them straight
-- through to engine APIs like StatusBar; for percentage display use
-- UnitHealthPercent / UnitPowerPercent.
local isSecret = issecretvalue or function() return false end

-- Layout constants: content hugs the edges, no padding; portrait is a 56x56
-- square to the left of the health/power bars.
local FRAME_W    = 240
local PORTRAIT_W = 56
local PORTRAIT_H = 56
local HEALTH_H   = 32
local POWER_H    = 24
local FRAME_H    = PORTRAIT_H                       -- 56 (matches portrait height when power bar visible)
local FRAME_H_NP = HEALTH_H                         -- 32 (no power bar)
local BAR_X      = PORTRAIT_W                       -- 56
local BAR_W      = FRAME_W - PORTRAIT_W             -- 184
local GAP        = 0                                -- 0 (elements all flush)
local AURA_ROW_H = 20                               -- 20 (height of the aura row placeholder; equals largest icon)
local MAX_BOSS   = 5

-- Native-style status bar texture (Blizzard's built-in glossy bar).
local BAR_TEX    = "Interface\\TargetingFrame\\UI-StatusBar"

FrameBoss.FRAME_W = FRAME_W

local DEFAULT_POINT = { "TOPLEFT", "UIParent", "TOPLEFT", 400, -300 }

local defaults = {
    profile = {
        scale       = 1.0,
        showPower   = true,
        healthColor = { 0.9, 0.2, 0.2 },
        locked      = true,
        testMode    = false,
        editMode    = false,
        point       = { unpack(DEFAULT_POINT) },
    },
}

-- Map a unit token (boss1..boss5) to its frame.
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

function FrameBoss:OnDisable()
    -- On disable: auto-exit test mode; next load starts in a clean state.
    if self.db and self.db.profile then
        self.db.profile.editMode = false
        self.db.profile.testMode = false
        self.db.profile.locked = true
    end
end

-- Disable native boss frames.
-- Approach mirrors oUF blizzard.lua: unregister events on the container,
-- Hide it, reparent to a hidden parent, and hook SetParent so the edit-mode
-- / layout manager cannot drag it back. Child frames (Boss1TargetFrame...)
-- only get event unregistration + Hide - reparenting them would crash the
-- container's layout code because it cannot compute their size.

local hiddenBossParent = CreateFrame("Frame", nil, UIParent)
hiddenBossParent:SetAllPoints()
hiddenBossParent:Hide()

-- SetParent on protected frames is blocked in combat; defer until combat ends.
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
    -- UNIT_AURA is intentionally NOT registered: the native AuraContainer
    -- refreshes its contents on its own.
end

-- Event handlers ------------------------------------------------------------

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

-- Container (anchor / drag / scale) -----------------------------------------

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
    mover.label:SetText(L["ANCHOR_LABEL"])
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
    local stackH = MAX_BOSS * FRAME_H + (2 * MAX_BOSS - 1) * GAP + MAX_BOSS * AURA_ROW_H
    mover:SetSize(FRAME_W, stackH)
    mover:ClearAllPoints()
    mover:SetPoint(unpack(db.point))
    mover:SetScale(db.scale)
    local active = db.editMode
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

-- Frame creation ------------------------------------------------------------

function FrameBoss:CreateFrames()
    self.frames = {}
    for i = 1, MAX_BOSS do
        -- Backdrop-less frame; square portrait on the left (56x56), health
        -- and power bars flush against it on the right.
        local f = CreateFrame("Frame", nil, self.mover)
        f:SetSize(FRAME_W, FRAME_H)
        if i == 1 then
            f:SetPoint("TOPLEFT", self.mover, "TOPLEFT", 0, 0)
        else
            f:SetPoint("TOPLEFT", self.frames[i - 1].auraRow, "BOTTOMLEFT", 0, -GAP)
        end
        f.bossIndex = i
        f.unit = "boss" .. i

        -- Square portrait (fixed 56x56).
        f.portrait = f:CreateTexture(nil, "ARTWORK")
        f.portrait:SetSize(PORTRAIT_W, PORTRAIT_H)
        f.portrait:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        f.portrait:SetTexCoord(0.05, 0.95, 0.08, 0.92)
        local pborder = CreateFrame("Frame", nil, f, "BackdropTemplate")
        pborder:SetAllPoints(f.portrait)
        pborder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        pborder:SetBackdropBorderColor(0, 0, 0, 1)

        -- Large health bar (height 32, flush against the top).
        f.health = CreateFrame("StatusBar", nil, f)
        f.health:SetSize(BAR_W, HEALTH_H)
        f.health:SetPoint("TOPLEFT", f, "TOPLEFT", BAR_X, 0)
        f.health:SetStatusBarTexture(BAR_TEX)
        local hbg = f.health:CreateTexture(nil, "BACKGROUND")
        hbg:SetAllPoints()
        hbg:SetTexture(BAR_TEX)
        hbg:SetVertexColor(0.12, 0.04, 0.04)

        -- Name (left side of the health bar, vertically centered).
        f.name = f.health:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.name:SetPoint("LEFT", f.health, "LEFT", 4, 0)
        f.name:SetPoint("RIGHT", f.health, "CENTER", -4, 0)
        f.name:SetHeight(HEALTH_H)
        f.name:SetJustifyH("LEFT")
        f.name:SetJustifyV("MIDDLE")
        f.name:SetWordWrap(false)

        -- Health percent (right side of the health bar, vertically centered,
        -- 2 decimal places).
        f.percent = f.health:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.percent:SetPoint("LEFT", f.health, "CENTER", 4, 0)
        f.percent:SetPoint("RIGHT", f.health, "RIGHT", -4, 0)
        f.percent:SetHeight(HEALTH_H)
        f.percent:SetJustifyH("RIGHT")
        f.percent:SetJustifyV("MIDDLE")

        -- Power bar (height 24, flush against the bottom of the health bar).
        f.power = CreateFrame("StatusBar", nil, f)
        f.power:SetSize(BAR_W, POWER_H)
        f.power:SetPoint("TOPLEFT", f.health, "BOTTOMLEFT", 0, 0)
        f.power:SetStatusBarTexture(BAR_TEX)
        local pbg = f.power:CreateTexture(nil, "BACKGROUND")
        pbg:SetAllPoints()
        pbg:SetTexture(BAR_TEX)
        pbg:SetVertexColor(0.04, 0.04, 0.08)

        -- Aura row placeholder (flush under the frame; doesn't render itself,
        -- only reserves vertical space for the native AuraContainer from
        -- Auras.lua).
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W, AURA_ROW_H)
        row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -GAP)
        f.auraRow = row

        -- Native aura container (creation fails in combat; Auras rebuilds it
        -- automatically after combat ends).
        self.Auras.CreateContainers(f)

        f:Hide()
        self.frames[i] = f
    end
end

-- Data updates --------------------------------------------------------------

function FrameBoss:RefreshFrame(f, unit)
    SetPortraitTexture(f.portrait, unit)
    f.name:SetText(UnitName(unit))
    self:UpdateHealth(f, unit)
    self:UpdatePower(f, unit)
    self.Auras.SetUnit(f, unit)
end

function FrameBoss:UpdateHealth(f, unit)
    -- hp/hpMax may be secret: pass straight to StatusBar; never arithmetic.
    local hp, hpMax = UnitHealth(unit), UnitHealthMax(unit)
    if isSecret(hpMax) then
        f.health:SetMinMaxValues(0, hpMax)
    else
        f.health:SetMinMaxValues(0, math.max(hpMax or 1, 1))
    end
    f.health:SetValue(hp)

    -- Percentage: UnitHealthPercent may also return secret for instance
    -- bosses. Secret values can only pass through C functions like
    -- string.format (which yields a secret string accepted by SetText); do
    -- NOT perform Lua arithmetic (+/math.floor) or ".." concatenation.
    -- Keep 2 decimal places.
    if not UnitIsConnected(unit) then
        f.percent:SetText(L["TEXT_OFFLINE"])
    elseif UnitIsDeadOrGhost(unit) then
        f.percent:SetText(L["TEXT_DEAD"])
    elseif not UnitHealthPercent then
        f.percent:SetText("")
    else
        local curve = CurveConstants and CurveConstants.ScaleTo100
        local pct = UnitHealthPercent(unit, false, curve)
        if pct == nil then
            f.percent:SetText("")
        elseif isSecret(pct) then
            f.percent:SetText(string.format("%.2f%%", pct))
        else
            f.percent:SetText(string.format("%.2f%%", tonumber(pct) or 0))
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
        -- Pass through when secret; floor to max >= 1 for normal numbers.
        f.power:SetMinMaxValues(0, secret and powerMax or math.max(powerMax, 1))
        f.power:SetValue(power)
        local c = PowerBarColor[UnitPowerType(unit)] or PowerBarColor[0]
        if c then f.power:SetStatusBarColor(c.r, c.g, c.b) end
    end
end

-- Full refresh (engage / world entry / test toggle) ------------------------

function FrameBoss:RefreshAll()
    local db = self.db.profile
    -- Aura size option may be changed in the panel; resync layout every refresh.
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
    if db.editMode then anyShown = true end
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

function FrameBoss:SetEditMode(v)
    -- Edit mode = unlock dragging + show test frames; turning off auto-exits
    -- test mode.
    local db = self.db.profile
    db.editMode = v
    db.locked = not v
    db.testMode = v
    self:RefreshAll()
end

function FrameBoss:ResetPosition()
    self.db.profile.point = { unpack(DEFAULT_POINT) }
    self:ApplyMover()
end

-- Test mode fake data -------------------------------------------------------

function FrameBoss:FillTestFrame(f, i)
    SetPortraitTexture(f.portrait, "player")
    f.name:SetText(L["TEXT_TEST_BOSS"]:format(i))
    local hp = 90 - i * 10
    f.health:SetMinMaxValues(0, 100)
    f.health:SetValue(hp)
    f.percent:SetText(string.format("%.2f%%", hp))
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
