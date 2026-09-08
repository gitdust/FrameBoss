--[[
    FrameBoss - Auras.lua
    Boss buff：仅显示可偷取（isStealable）或可进攻驱散（dispelName）的；
    Debuff：仅显示当前玩家/玩家宠物施加的（HARMFUL|PLAYER + isFromPlayerOrPlayerPet）。
    图标对象池复用，边框按语义配色，Cooldown 扫秒，悬浮显示 Tooltip。
--]]

local FrameBoss = LibStub("AceAddon-3.0"):GetAddon("FrameBoss")
local Auras = {}
FrameBoss.Auras = Auras

local MAX_ICONS_SIDE = 8
local GAP = 8

local BORDER_TEX  = "Interface\\Buttons\\UI-Debuff-Overlays"
local BORDER_COORD = { 0.296875, 0.5703125, 0, 0.515625 }

-- 边框语义色
local COLOR_STEALABLE = { 0.50, 0.25, 1.00 }  -- 可偷取：蓝紫
local COLOR_DISPEL    = { 1.00, 0.38, 0.12 }  -- 可驱散：橙红
local COLOR_DEBUFF = {
    Magic   = { 0.60, 0.20, 1.00 },  -- 魔法：紫
    Curse   = { 1.00, 0.50, 0.00 },  -- 诅咒：橙
    Poison  = { 0.30, 0.80, 0.20 },  -- 中毒：绿
    Disease = { 0.20, 0.60, 0.90 },  -- 疾病：蓝
    none    = { 0.50, 0.50, 0.50 },  -- 无：灰
}

local function Icon_OnEnter(self)
    if not self.auraInstanceID then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    if self.isBuff then
        GameTooltip:SetUnitBuffByAuraInstanceID(self.unit, self.auraInstanceID)
    else
        GameTooltip:SetUnitDebuffByAuraInstanceID(self.unit, self.auraInstanceID)
    end
end

local function CreateIcon(row)
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
    b:SetScript("OnEnter", Icon_OnEnter)
    b:SetScript("OnLeave", GameTooltip_Hide)
    b:Hide()
    return b
end

local function GetIcon(row, n)
    if not row.icons then row.icons = {} end
    local b = row.icons[n]
    if not b then
        b = CreateIcon(row)
        row.icons[n] = b
    end
    return b
end

local function FillIcon(b, unit, data, isBuff, color)
    b:ClearAllPoints()
    b.unit = unit
    b.auraInstanceID = data.auraInstanceID
    b.isBuff = isBuff
    b.icon:SetTexture(data.icon)
    local apps = data.applications or 0
    b.count:SetText(apps > 1 and apps or "")
    if data.duration and data.duration > 0 then
        b.cooldown:SetCooldown(data.expirationTime - data.duration, data.duration)
        b.cooldown:Show()
    else
        b.cooldown:Hide()
    end
    b.border:SetVertexColor(color[1], color[2], color[3])
    b.border:Show()
    local size = FrameBoss.db.profile.auraSize
    b:SetSize(size, size)
    b:Show()
end

function Auras.Clear(f)
    local row = f.auraRow
    -- 即使隐藏也保持 rect：下一框锚定本行底部，尺寸必须与 auraSize 一致
    row:SetSize(FrameBoss.FRAME_W, FrameBoss.db.profile.auraSize)
    if row.icons then
        for _, b in ipairs(row.icons) do b:Hide() end
    end
    row:Hide()
end

-- 扫描：filter 遍历至 nil，predicate 命中则收集，最多 max 个
local function ScanAuras(unit, filter, predicate, max)
    local out = {}
    local i = 1
    while true do
        local data = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
        if not data then break end
        if predicate(data) then
            out[#out + 1] = data
            if #out >= max then break end
        end
        i = i + 1
    end
    return out
end

-- buffs 左侧排列、debuffs 右侧排列
function Auras.Layout(f, unit, buffs, debuffs)
    local row = f.auraRow
    Auras.Clear(f)
    local size = FrameBoss.db.profile.auraSize
    row:SetSize(FrameBoss.FRAME_W, size)

    local n = 0
    local prev
    for _, data in ipairs(buffs) do
        n = n + 1
        local b = GetIcon(row, n)
        local color = data.isStealable and COLOR_STEALABLE or COLOR_DISPEL
        FillIcon(b, unit, data, true, color)
        if prev then
            b:SetPoint("TOPLEFT", prev, "TOPRIGHT", GAP, 0)
        else
            b:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        end
        prev = b
    end

    prev = nil
    for _, data in ipairs(debuffs) do
        n = n + 1
        local b = GetIcon(row, n)
        local color = COLOR_DEBUFF[data.dispelName] or COLOR_DEBUFF.none
        FillIcon(b, unit, data, false, color)
        if prev then
            b:SetPoint("TOPRIGHT", prev, "TOPLEFT", -GAP, 0)
        else
            b:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
        end
        prev = b
    end

    row:SetShown(n > 0)
end

function Auras.Update(f, unit)
    local buffs = ScanAuras(unit, "HELPFUL", function(d)
        return d.isStealable or d.dispelName ~= nil
    end, MAX_ICONS_SIDE)
    local debuffs = ScanAuras(unit, "HARMFUL|PLAYER", function(d)
        return d.isFromPlayerOrPlayerPet
    end, MAX_ICONS_SIDE)
    Auras.Layout(f, unit, buffs, debuffs)
end

-- 测试模式：示例光环（auraInstanceID 为 nil，Tooltip 不触发）
function Auras.ShowTest(f)
    local function fake(icon, apps, duration, expirationTime)
        return {
            icon = icon, applications = apps,
            duration = duration, expirationTime = expirationTime,
            auraInstanceID = nil,
        }
    end
    local stealable = fake(GetSpellTexture(118), 1, 0, 0)   -- 变形术图标，模拟可偷取
    stealable.isStealable = true
    local enrage = fake(GetSpellTexture(6673), 3, 0, 0)      -- 战斗怒吼图标，模拟可驱散
    enrage.dispelName = ""
    local myDebuff = fake(GetSpellTexture(589), 5, 30, GetTime() + 22)  -- 暗言术：痛图标
    Auras.Layout(f, "player", { stealable, enrage }, { myDebuff })
end
