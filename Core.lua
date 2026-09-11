--[[
    FrameBoss - Core.lua
    Minimalist boss frames: name / large health bar / power bar /
    important buffs / player debuffs (no portrait, no frame backdrop).
    Pure Blizzard native API + Ace3 scaffolding; elements are flush (0 gap).
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

-- Layout constants: content hugs the edges, no padding and no portrait;
-- the health/power bars span the full frame width.
local FRAME_W    = 240
local HEALTH_H   = 32
local POWER_H    = 24
local FRAME_H    = HEALTH_H + POWER_H               -- 56 (health + power)
local FRAME_H_NP = HEALTH_H                         -- 32 (no power bar)
local BAR_W      = FRAME_W                          -- bars span the full width
local AURA_ROW_H = 28                               -- 28 (height of the aura row placeholder; equals largest icon)
local MAX_BOSS   = 5

-- Native-style status bar texture (Blizzard's built-in glossy bar).
local BAR_TEX    = "Interface\\TargetingFrame\\UI-StatusBar"

local WHITE_TEX  = "Interface\\Buttons\\WHITE8X8"

-- Bar background tracks reuse the bar's native color darkened by this factor.
local BG_COLOR_FACTOR = 0.15
-- Hostile-red fallback for test frames / when UnitSelectionColor is unavailable.
local FALLBACK_HEALTH_COLOR = { 0.9, 0.2, 0.2 }

-- Dark backing shell behind the bar block: drawn by the addon (not a stretched
-- atlas, whose baked-in art padding made the bars visually poke out of their
-- wrapper), outset by this many pixels on every side with a 1px edge.
local SHELL_OUTSET   = 2
local SHELL_BG_ALPHA = 0.55

-- Target highlight: a bright pulsing outline in the same wrapper rect.
local TARGET_EDGE    = 2

-- Vertical gap between the bar block and the aura icons (and between an aura
-- row and the next frame). The shell/target outline extends SHELL_OUTSET plus
-- half the edge width (3px total) past the bars; icons must clear it.
local AURA_GAP       = 4

-- Native nameplate look (see Blizzard_NamePlates): a "deselected" overlay on
-- top of the fill that Blizzard uses to slightly darken every non-target bar.
local ATLAS_BAR_DIM    = "ui-hud-nameplates-deselected-overlay"

FrameBoss.FRAME_W  = FRAME_W
FrameBoss.AURA_GAP = AURA_GAP

local DEFAULT_POINT = { "TOPLEFT", "UIParent", "TOPLEFT", 400, -300 }

local defaults = {
    profile = {
        scale       = 1.0,
        showPower   = true,
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
    -- One-time cleanup: healthColor was removed when bars switched to native
    -- UnitSelectionColor; drop the stale key left in older saved variables.
    self.db.profile.healthColor = nil
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
    -- Faction / flags (tapped state) changes alter the native selection color.
    self:RegisterEvent("UNIT_FACTION", "UnitFaction")
    self:RegisterEvent("UNIT_FLAGS", "UnitFaction")
    -- Keep the "current target" highlight in sync.
    self:RegisterEvent("PLAYER_TARGET_CHANGED", "PlayerTargetChanged")
    -- Visibility safety nets: INSTANCE_ENCOUNTER_ENGAGE_UNIT is the primary
    -- show/hide driver, but boss tokens can clear later than the event
    -- (death animation, world bosses, resets). Re-check on encounter end,
    -- when combat drops, and again a few seconds after that.
    self:RegisterEvent("ENCOUNTER_END", "RefreshAll")
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "CombatState")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "CombatState")
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

function FrameBoss:PlayerTargetChanged()
    self:UpdateTargeting()
end

-- Combat state: test frames are only for out-of-combat positioning, so end
-- test/edit mode the instant combat starts; when combat ends, re-evaluate
-- frame visibility and once more after a delay (boss tokens may outlive the
-- disengage event during the death animation).
function FrameBoss:CombatState(event)
    if event == "PLAYER_REGEN_DISABLED" then
        if self.db.profile.testMode then
            self:SetEditMode(false)
        end
    else
        self:RefreshAll()
        C_Timer.After(2.5, function()
            if FrameBoss.db and FrameBoss.db.profile then FrameBoss:RefreshAll() end
        end)
    end
end

function FrameBoss:UnitFaction(event, unit)
    if self.db.profile.testMode then return end
    local f = BossFrame(unit)
    if f and UnitExists(unit) then self:UpdateHealthColor(f, unit) end
end

-- Container (anchor / drag / scale) -----------------------------------------

function FrameBoss:CreateMover()
    local mover = CreateFrame("Frame", "FrameBossAnchor", UIParent, "BackdropTemplate")
    mover:SetSize(FRAME_W + 2 * SHELL_OUTSET,
        MAX_BOSS * FRAME_H + (2 * MAX_BOSS - 1) * AURA_GAP + MAX_BOSS * AURA_ROW_H + 2 * SHELL_OUTSET)
    mover:SetClampedToScreen(true)
    mover:SetMovable(true)
    mover:EnableMouse(false)
    mover:SetBackdrop({
        bgFile   = WHITE_TEX,
        edgeFile = WHITE_TEX, edgeSize = 1,
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
    local stackH = MAX_BOSS * FRAME_H + (2 * MAX_BOSS - 1) * AURA_GAP + MAX_BOSS * AURA_ROW_H + 2 * SHELL_OUTSET
    mover:SetSize(FRAME_W + 2 * SHELL_OUTSET, stackH)
    mover:ClearAllPoints()
    mover:SetPoint(unpack(db.point))
    mover:SetScale(db.scale)
    local active = db.editMode
    mover:EnableMouse(active)
    mover:SetMovable(active)
    if self.frames then
        for i = 1, MAX_BOSS do
            -- While unlocked, clicks should reach the mover for dragging
            -- instead of targeting via the secure boss buttons.
            self.frames[i]:EnableMouse(not active)
        end
    end
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
        -- Secure unit button (backdrop-less): left click targets the boss,
        -- right click opens the native unit menu. Visibility stays driven by
        -- the addon (no RegisterUnitWatch) so test mode can show frames that
        -- have no real unit behind them.
        local f = CreateFrame("Button", "FrameBossBossFrame" .. i, self.mover, "SecureUnitButtonTemplate")
        f:SetSize(FRAME_W, FRAME_H)
        if i == 1 then
            f:SetPoint("TOPLEFT", self.mover, "TOPLEFT", SHELL_OUTSET, -SHELL_OUTSET)
        else
            f:SetPoint("TOPLEFT", self.frames[i - 1].auraRow, "BOTTOMLEFT", 0, -AURA_GAP)
        end
        f.bossIndex = i
        f.unit = "boss" .. i

        f:SetAttribute("unit", f.unit)
        f:SetAttribute("*type1", "target")
        f:SetAttribute("*type2", "togglemenu")
        f:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        -- Dark backing shell around the bars. Created before the bars on
        -- purpose: child frame levels rise in creation order, so this keeps
        -- the shell's BACKGROUND layer below the per-bar track textures.
        f.shell = CreateFrame("Frame", nil, f, "BackdropTemplate")
        f.shell:EnableMouse(false)
        f.shell:SetBackdrop({
            bgFile   = WHITE_TEX,
            edgeFile = WHITE_TEX, edgeSize = 1,
        })
        f.shell:SetBackdropColor(0, 0, 0, SHELL_BG_ALPHA)
        f.shell:SetBackdropBorderColor(0, 0, 0, 0.9)

        -- Large health bar (height 32, flush against the top).
        f.health = CreateFrame("StatusBar", nil, f)
        f.health:SetSize(BAR_W, HEALTH_H)
        f.health:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        f.health:SetStatusBarTexture(BAR_TEX)
        f.health:EnableMouse(false)
        f.hbg = f.health:CreateTexture(nil, "BACKGROUND")
        f.hbg:SetAllPoints()
        f.hbg:SetTexture(BAR_TEX)

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
        f.power:EnableMouse(false)
        f.pbg = f.power:CreateTexture(nil, "BACKGROUND")
        f.pbg:SetAllPoints()
        f.pbg:SetTexture(BAR_TEX)

        -- Native "deselected" dimming overlay (BORDER sits above the fill but
        -- below the OVERLAY-layer name/percent text).
        f.dimHealth = f.health:CreateTexture(nil, "BORDER")
        f.dimHealth:SetPoint("TOPLEFT", f.health, "TOPLEFT", 0, 1)
        f.dimHealth:SetPoint("BOTTOMRIGHT", f.health, "BOTTOMRIGHT", 0, -1)
        f.dimHealth:SetAtlas(ATLAS_BAR_DIM)
        f.dimPower = f.power:CreateTexture(nil, "BORDER")
        f.dimPower:SetPoint("TOPLEFT", f.power, "TOPLEFT", 0, 1)
        f.dimPower:SetPoint("BOTTOMRIGHT", f.power, "BOTTOMRIGHT", 0, -1)
        f.dimPower:SetAtlas(ATLAS_BAR_DIM)

        -- Current-target outline: a bright frame wrapped around the same
        -- rect as the shell, with a soft alpha pulse to draw the eye.
        -- Created after the bars so its BORDER edge draws above the dim
        -- overlay but below the OVERLAY-layer text.
        local target = CreateFrame("Frame", nil, f, "BackdropTemplate")
        target:EnableMouse(false)
        target:SetBackdrop({ edgeFile = WHITE_TEX, edgeSize = TARGET_EDGE })
        target:SetBackdropBorderColor(1, 1, 1, 1)
        target:Hide()
        local pulse = target:CreateAnimationGroup()
        local pulseAlpha = pulse:CreateAnimation("Alpha")
        pulseAlpha:SetFromAlpha(1)
        pulseAlpha:SetToAlpha(0.45)
        pulseAlpha:SetDuration(0.75)
        pulseAlpha:SetSmoothing("IN_OUT")
        pulse:SetLooping("BOUNCE")
        target.pulse = pulse
        f.targetHolder = target

        -- Wrap the default (health + power) block; re-wrapped dynamically
        -- when the power bar hides.
        self:UpdateChrome(f, true)

        -- Aura row placeholder (flush under the frame; doesn't render itself,
        -- only reserves vertical space for the native AuraContainer from
        -- Auras.lua).
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(FRAME_W, AURA_ROW_H)
        row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -AURA_GAP)
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
    f.name:SetText(UnitName(unit))
    self:UpdateHealth(f, unit)
    self:UpdatePower(f, unit)
    self.Auras.SetUnit(f, unit)
end

-- Native health color: UnitSelectionColor is the same source the native unit
-- frames / nameplates use (hostile red, neutral yellow, tapped/dead gray).
function FrameBoss:UpdateHealthColor(f, unit)
    local r, g, b
    if unit and UnitSelectionColor then r, g, b = UnitSelectionColor(unit) end
    if not r then r, g, b = unpack(FALLBACK_HEALTH_COLOR) end
    f.health:SetStatusBarColor(r, g, b)
    f.hbg:SetVertexColor(r * BG_COLOR_FACTOR, g * BG_COLOR_FACTOR, b * BG_COLOR_FACTOR)
end

function FrameBoss:UpdateHealth(f, unit)
    self:UpdateHealthColor(f, unit)
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

-- Keep the shell and target outline wrapped around the visible bar block:
-- health only when the power bar is hidden, health+power otherwise.
function FrameBoss:UpdateChrome(f, powerVisible)
    local bottom = powerVisible and f.power or f.health
    f.shell:ClearAllPoints()
    f.shell:SetPoint("TOPLEFT", f.health, "TOPLEFT", -SHELL_OUTSET, SHELL_OUTSET)
    f.shell:SetPoint("BOTTOMRIGHT", bottom, "BOTTOMRIGHT", SHELL_OUTSET, -SHELL_OUTSET)
    f.targetHolder:ClearAllPoints()
    f.targetHolder:SetPoint("TOPLEFT", f.health, "TOPLEFT", -SHELL_OUTSET, SHELL_OUTSET)
    f.targetHolder:SetPoint("BOTTOMRIGHT", bottom, "BOTTOMRIGHT", SHELL_OUTSET, -SHELL_OUTSET)
end

-- Current-target highlight: hide the native "deselected" dimming on the
-- targeted boss and show the pulsing outline instead. Test mode has no real
-- units, so it previews the highlight on the first frame.
function FrameBoss:UpdateTargeting()
    local test = self.db.profile.testMode
    for i = 1, MAX_BOSS do
        local f = self.frames[i]
        local selected
        if test then
            selected = (i == 1)
        else
            selected = f:IsShown() and UnitIsUnit(f.unit, "target")
        end
        f.targetSelected = selected
        f.dimHealth:SetShown(not selected)
        f.dimPower:SetShown(not selected and f.power:IsShown())
        f.targetHolder:SetShown(selected)
        if selected then
            if not f.targetHolder.pulse:IsPlaying() then
                f.targetHolder.pulse:Play()
            end
        else
            f.targetHolder.pulse:Stop()
        end
    end
end

function FrameBoss:UpdatePower(f, unit)
    if not self.db.profile.showPower then
        f.power:Hide()
        f.dimPower:Hide()
        f:SetHeight(FRAME_H_NP)
        self:UpdateChrome(f, false)
        return
    end
    local power, powerMax = UnitPower(unit), UnitPowerMax(unit)
    local secret = isSecret(powerMax)
    if not secret and (not powerMax or powerMax <= 0) then
        f.power:Hide()
        f.dimPower:Hide()
        f:SetHeight(FRAME_H_NP)
        self:UpdateChrome(f, false)
    else
        f.power:Show()
        f.dimPower:SetShown(not f.targetSelected)
        f:SetHeight(FRAME_H)
        self:UpdateChrome(f, true)
        -- Pass through when secret; floor to max >= 1 for normal numbers.
        f.power:SetMinMaxValues(0, secret and powerMax or math.max(powerMax, 1))
        f.power:SetValue(power)
        local c = PowerBarColor[UnitPowerType(unit)] or PowerBarColor[0]
        if c then
            f.power:SetStatusBarColor(c.r, c.g, c.b)
            f.pbg:SetVertexColor(c.r * BG_COLOR_FACTOR, c.g * BG_COLOR_FACTOR, c.b * BG_COLOR_FACTOR)
        end
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
    self:UpdateTargeting()
end

function FrameBoss:ApplySettings()
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
    f.name:SetText(L["TEXT_TEST_BOSS"]:format(i))
    local hp = 90 - i * 10
    f.health:SetMinMaxValues(0, 100)
    f.health:SetValue(hp)
    -- No real unit in test mode; UnitSelectionColor("player") would be green.
    self:UpdateHealthColor(f, nil)
    f.percent:SetText(string.format("%.2f%%", hp))
    if self.db.profile.showPower then
        f.power:Show()
        f.dimPower:SetShown(not f.targetSelected)
        f:SetHeight(FRAME_H)
        self:UpdateChrome(f, true)
        f.power:SetMinMaxValues(0, 100)
        f.power:SetValue(60)
        local c = PowerBarColor[0]
        if c then
            f.power:SetStatusBarColor(c.r, c.g, c.b)
            f.pbg:SetVertexColor(c.r * BG_COLOR_FACTOR, c.g * BG_COLOR_FACTOR, c.b * BG_COLOR_FACTOR)
        end
    else
        f.power:Hide()
        f.dimPower:Hide()
        f:SetHeight(FRAME_H_NP)
        self:UpdateChrome(f, false)
    end
    self.Auras.ShowTest(f)
end
