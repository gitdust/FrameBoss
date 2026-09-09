--[[
    FrameBoss - Auras.lua
    As of 12.x, boss auras inside instances are entirely secret: tainted
    (addon) code calling C_UnitAuras.GetAuraDataByIndex raises
    "Auras cannot be accessed when secret". We therefore use Blizzard's
    native AuraContainer (CustomAuraContainerTemplate, defined in the
    on-demand Blizzard_AuraContainer addon): the engine enumerates auras
    inside a secure context, so secret units display correctly and
    refresh, cooldown sweep, stack count, type border, and tooltip are
    all handled automatically.

    Three containers per boss frame (current client uses the Flow layout API,
    modelled after DBM AuraTracking):
      Buff-Special container (left): HELPFUL and stealable / dispel (enrage)  28x28
      Buff-Regular container (mid-left): HELPFUL ordinary buffs              24x24
      Debuff container (right): HARMFUL|PLAYER -- only player (incl. pet/vehicle) applied  24x24
    Buffs start at the portrait's right edge (x = portrait width), aligned
    with the health/power bars.
--]]

local FrameBoss = LibStub("AceAddon-3.0"):GetAddon("FrameBoss")
local Auras = {}
FrameBoss.Auras = Auras

local GetSpellTexture = C_Spell.GetSpellTexture  -- global GetSpellTexture was removed as of 11.0

local FRAME_W    = FrameBoss.FRAME_W
local PORTRAIT_W = FrameBoss.PORTRAIT_W
local GAP = 0  -- icons hug each other; the aura row hugs the frame

-- Aura group sizes: dispel/stealable are larger, ordinary auras are smaller.
local SIZE_BUFF_SPECIAL = 28  -- stealable / enrage
local SIZE_BUFF_REGULAR = 24  -- ordinary HELPFUL
local SIZE_DEBUFF       = 24  -- player-applied HARMFUL

-- Buffs begin where the portrait ends / the bars begin; buffs and debuffs
-- split the bar-width area evenly.
local AURA_X = PORTRAIT_W
local SIDE_W = math.floor((FRAME_W - PORTRAIT_W) / 2)

local DEBUFF_FILTER = "HARMFUL|PLAYER"

local function profile() return FrameBoss.db.profile end

-- CustomAuraContainerTemplate lives in the on-demand Blizzard_AuraContainer addon.
local function EnsureAuraLib()
    if C_AddOns and C_AddOns.IsAddOnLoaded and not C_AddOns.IsAddOnLoaded("Blizzard_AuraContainer") then
        return C_AddOns.LoadAddOn("Blizzard_AuraContainer")
    end
    return true
end

local SortMethod   = (AuraContainerSortMethod   and AuraContainerSortMethod.ExpirationOnly) or 2
local SortDir      = (AuraContainerSortDirection and AuraContainerSortDirection.Normal)     or 1
local FlowDir      = AnchorUtil.FlowDirection    -- .Right / .Left / .Down
local FlowAxisH    = AnchorUtil.FlowLayoutAxis.Horizontal

-- Max icon count per side (computed from the configured size and side width).
local function MaxPerSide(size, width)
    return math.max(1, math.floor((width + GAP) / (size + GAP)))
end
local function LineSize(size, width)
    local n = MaxPerSide(size, width)
    return size * n + GAP * (n - 1)
end

-- AuraContainer creation is protected in combat; rebuild and rebind units after combat ends.
local pendingFrames = {}
local retryFrame = CreateFrame("Frame")
retryFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
retryFrame:SetScript("OnEvent", function()
    local any = false
    for f in pairs(pendingFrames) do
        if Auras.CreateContainers(f) then any = true end
    end
    if any and FrameBoss.frames then FrameBoss:RefreshAll() end
end)

-- Button initialization (engine callback when it creates a new button).
-- Single-size containers use the size directly; mixed-size containers use
-- the size closure passed in.
local function InitializeButton(container, size)
    return function(button)
        button:SetSize(size, size)
        button:SetMouseMotionEnabled(true)

        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        button:SetIcon(icon)

        local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        cd:SetAllPoints()
        cd:SetReverse(true)
        cd:SetDrawEdge(false)
        cd:SetDrawBling(false)
        cd:SetHideCountdownNumbers(true)
        button:SetDurationCooldown(cd)

        local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        count:SetPoint("BOTTOMRIGHT", -1, 1)
        button:SetApplicationCount(count, {})

        -- Engine colors the border by aura type (Magic / Poison / Disease /
        -- Curse / Enrage...); shown for both buffs and debuffs.
        local border = button:CreateTexture(nil, "OVERLAY")
        border:SetAllPoints()
        button:AddDispelTypeTexture(border, {
            showWhenHarmful = true,
            showWhenHelpful = true,
        })

        container.buttons[#container.buttons + 1] = button
    end
end

local function GroupOptions(container, size, width, candidate)
    return {
        maxFrameCount = MaxPerSide(size, width),
        sortMethod = SortMethod,
        sortDirection = SortDir,
        initializeFrame = InitializeButton(container, size),
        candidateFilters = candidate,
        layout = {
            elementWidth = size,
            elementHeight = size,
            elementSpacing = GAP,
            lineSpacing = GAP,
        },
    }
end

-- Container construction (anchor/relAnchor pick the row edge; growH is the
-- horizontal growth direction; xOff shifts the anchor, e.g. AURA_X to start
-- past the portrait).
local function BuildContainer(f, anchor, relAnchor, growH, size, width, xOff)
    if InCombatLockdown() then return nil end  -- protected in combat; rebuilt after combat ends
    EnsureAuraLib()

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
    if not ok or not c then return nil end

    c.buttons = {}
    c.currentSize = size
    c.groupKeys = {}

    c:SetEnabled(false)
    c:Hide()
    c:ClearAllPoints()
    c:SetPoint(anchor, f, relAnchor, xOff or 0, -GAP)
    c:SetSize(size, size)  -- container does not clip child frames; icons may extend outward
    c:SetFlowLayoutAxis(FlowAxisH)
    c:SetFlowLayoutAnchorPoint(anchor)
    c:SetFlowLayoutGrowthDirection(growH, FlowDir.Down)
    c:SetFlowLayoutMaximumLineSize(LineSize(size, width))
    return c
end

local function AddGroup(c, key, filter, candidate, size, width)
    if not c:HasAuraGroup(key) then
        c:AddAuraGroup(key, filter, GroupOptions(c, size, width, candidate))
        c.groupKeys[#c.groupKeys + 1] = key
    end
    c:SetAuraGroupMaxFrameCount(key, MaxPerSide(size, width))
    if candidate then c:SetAuraGroupCandidateFilters(key, candidate) end
    -- Explicit layout call to ensure the Flow API takes effect.
    c:SetAuraGroupLayout(key, {
        elementWidth = size,
        elementHeight = size,
        elementSpacing = GAP,
        lineSpacing = GAP,
    })
end

-- Wrap the whole setup (including group registration) in pcall: any missing
-- API or combat protection won't break the addon.
local function SetupContainer(f, c, groups)
    for _, g in ipairs(groups) do
        AddGroup(c, g.key, g.filter, g.candidate, g.size, g.width)
    end
end

-- Create 3 native containers per boss frame; on failure, queue a retry
-- for after combat ends.
function Auras.CreateContainers(f)
    if not f then return false end
    if not f.buffSpecial then
        -- Stealable + Enrage (dispel) 28x28, starts at the portrait's right
        -- edge (aligned with the bars), grows right.
        local ok, c = pcall(BuildContainer, f, "TOPLEFT", "BOTTOMLEFT", FlowDir.Right, SIZE_BUFF_SPECIAL, SIDE_W, AURA_X)
        if ok and c then
            pcall(SetupContainer, f, c, {
                { key = f.unit .. "Stealable", filter = "HELPFUL", candidate = { isStealable = true }, size = SIZE_BUFF_SPECIAL, width = SIDE_W },
                { key = f.unit .. "Enrage",    filter = "HELPFUL", candidate = { includeDispelTypes = { Enrage = true } }, size = SIZE_BUFF_SPECIAL, width = SIDE_W },
            })
            f.buffSpecial = c
        end
    end
    if not f.buffRegular then
        -- Ordinary HELPFUL buff 24x24, chained to the right of buffSpecial.
        if not InCombatLockdown() and f.buffSpecial then
            local ok, c = pcall(BuildContainer, f, "TOPLEFT", "BOTTOMLEFT", FlowDir.Right, SIZE_BUFF_REGULAR, SIDE_W)
            if ok and c then
                pcall(SetupContainer, f, c, {
                    { key = f.unit .. "Regular", filter = "HELPFUL", candidate = nil, size = SIZE_BUFF_REGULAR, width = SIDE_W },
                })
                -- Re-anchor to the right side of buffSpecial.
                c:ClearAllPoints()
                c:SetPoint("TOPLEFT", f.buffSpecial, "TOPRIGHT", 0, 0)
                f.buffRegular = c
            end
        end
    end
    if not f.debuffContainer then
        -- Player-applied HARMFUL debuff 24x24, anchored to the right, grows left.
        local ok, c = pcall(BuildContainer, f, "TOPRIGHT", "BOTTOMRIGHT", FlowDir.Left, SIZE_DEBUFF, SIDE_W)
        if ok and c then
            pcall(SetupContainer, f, c, {
                { key = f.unit .. "Debuff", filter = DEBUFF_FILTER, candidate = nil, size = SIZE_DEBUFF, width = SIDE_W },
            })
            f.debuffContainer = c
        end
    end
    if not f.buffSpecial or not f.buffRegular or not f.debuffContainer then
        pendingFrames[f] = true
        return false
    end
    pendingFrames[f] = nil
    Auras.ApplySize(f)
    return true
end

-- Bind a unit and enable queries (the container listens to UNIT_AURA on its
-- own; the addon doesn't need to drive it).
function Auras.SetUnit(f, unit)
    if not Auras.CreateContainers(f) then return end  -- not yet built in combat; rebuilt after combat ends
    if f.testRow then f.testRow:Hide() end
    for _, c in ipairs({ f.buffSpecial, f.buffRegular, f.debuffContainer }) do
        if c then
            c:SetUnit(unit)
            c:Show()
            c:SetEnabled(true)
        end
    end
end

-- All three container sizes are constants; the application layer only has to
-- resync each container's Flow layout max line size.
function Auras.ApplySize(f)
    if not f or not f.buffSpecial then return end
    for _, entry in ipairs({
        { c = f.buffSpecial,     size = SIZE_BUFF_SPECIAL, width = SIDE_W },
        { c = f.buffRegular,     size = SIZE_BUFF_REGULAR, width = SIDE_W },
        { c = f.debuffContainer, size = SIZE_DEBUFF,       width = SIDE_W },
    }) do
        local c, size, width = entry.c, entry.size, entry.width
        if c then
            c.currentSize = size
            c:SetSize(size, size)
            c:SetFlowLayoutMaximumLineSize(LineSize(size, width))
            for _, key in ipairs(c.groupKeys) do
                c:SetAuraGroupMaxFrameCount(key, MaxPerSide(size, width))
                c:SetAuraGroupLayout(key, {
                    elementWidth = size,
                    elementHeight = size,
                    elementSpacing = GAP,
                    lineSpacing = GAP,
                })
            end
        end
    end
    if f.testRow then
        f.testRow:SetSize(FRAME_W, SIZE_BUFF_SPECIAL)
    end
end

-- Unit gone: disable the containers (they hide with their parent frame).
function Auras.Clear(f)
    if f.testRow then f.testRow:Hide() end
    for _, c in ipairs({ f.buffSpecial, f.buffRegular, f.debuffContainer }) do
        if c then
            c:SetEnabled(false)
            c:Hide()
        end
    end
end

-- Test mode (fake data cannot be fed into native containers; overlay self-drawn icon placeholders instead).

local BORDER_TEX  = "Interface\\Buttons\\UI-Debuff-Overlays"
local BORDER_COORD = { 0.296875, 0.5703125, 0, 0.515625 }

local COLOR_STEALABLE = { 0.50, 0.25, 1.00 }  -- stealable: blue-purple
local COLOR_DISPEL    = { 1.00, 0.38, 0.12 }  -- dispel: orange-red
local COLOR_DEBUFF    = { 0.60, 0.20, 1.00 }  -- player magic debuff: purple

local function CreateTestButton(row, size)
    local b = CreateFrame("Button", nil, row)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    b.cooldown:SetAllPoints()
    b.cooldown:SetHideCountdownNumbers(false)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -1, 1)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture(BORDER_TEX)
    b.border:SetTexCoord(unpack(BORDER_COORD))
    b.border:SetAllPoints()
    b:SetSize(size, size)
    b:Hide()
    return b
end

function Auras.ShowTest(f)
    if f.buffSpecial then f.buffSpecial:SetEnabled(false); f.buffSpecial:Hide() end
    if f.buffRegular then f.buffRegular:SetEnabled(false); f.buffRegular:Hide() end
    if f.debuffContainer then f.debuffContainer:SetEnabled(false); f.debuffContainer:Hide() end

    if not f.testRow then
        local row = CreateFrame("Frame", nil, f)
        row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -GAP)
        row.buttons = {}
        f.testRow = row
    end
    local row = f.testRow
    -- Test buttons use each type's corresponding size.
    local szSpec  = SIZE_BUFF_SPECIAL
    local szReg   = SIZE_BUFF_REGULAR
    local szDebuf = SIZE_DEBUFF
    row:SetSize(FRAME_W, szSpec)

    while #row.buttons < 4 do
        local b = CreateTestButton(row, szSpec)
        row.buttons[#row.buttons + 1] = b
    end
    local b1, b2, b3, b4 = row.buttons[1], row.buttons[2], row.buttons[3], row.buttons[4]

    -- b1: stealable (28x28, starts at the portrait's right edge)
    b1:SetSize(szSpec, szSpec)
    b1:ClearAllPoints()
    b1:SetPoint("TOPLEFT", row, "TOPLEFT", AURA_X, 0)
    b1.icon:SetTexture(GetSpellTexture(118))    -- Polymorph icon, mock stealable
    b1.count:SetText("")
    b1.border:SetVertexColor(unpack(COLOR_STEALABLE))
    b1.cooldown:Hide()
    b1:Show()

    -- b2: enrage / dispel (28x28, flush right of b1)
    b2:SetSize(szSpec, szSpec)
    b2:ClearAllPoints()
    b2:SetPoint("TOPLEFT", b1, "TOPRIGHT", GAP, 0)
    b2.icon:SetTexture(GetSpellTexture(6673))   -- Battle Shout icon, mock enrage
    b2.count:SetText(3)
    b2.border:SetVertexColor(unpack(COLOR_DISPEL))
    b2.cooldown:Hide()
    b2:Show()

    -- b3: ordinary HELPFUL (24x24, flush right of b2)
    b3:SetSize(szReg, szReg)
    b3:ClearAllPoints()
    b3:SetPoint("TOPLEFT", b2, "TOPRIGHT", GAP, 0)
    b3.icon:SetTexture(GetSpellTexture(48440))  -- Bloodlust
    b3.count:SetText("")
    b3.border:SetVertexColor(unpack(COLOR_STEALABLE))
    b3.cooldown:Hide()
    b3:Show()

    -- b4: player debuff (24x24, right edge)
    b4:SetSize(szDebuf, szDebuf)
    b4:ClearAllPoints()
    b4:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    b4.icon:SetTexture(GetSpellTexture(589))    -- Shadow Word: Pain, mock player debuff
    b4.count:SetText(5)
    b4.border:SetVertexColor(unpack(COLOR_DEBUFF))
    b4.cooldown:SetCooldown(GetTime() - 8, 30)  -- about 22 seconds remaining
    b4.cooldown:Show()
    b4:Show()

    row:Show()
end