--[[
    FrameBoss - Auras.lua
    12.x 起副本内首领单位的光环整体是 secret：tainted（插件）代码直接调用
    C_UnitAuras.GetAuraDataByIndex 会报 "Auras cannot be accessed when secret"。
    因此改用暴雪原生 AuraContainer（CustomAuraContainerTemplate，定义在按需
    加载的 Blizzard_AuraContainer 插件里）：引擎在安全上下文内部枚举光环，
    secret 单位也能正常显示，并自动处理刷新、冷却扫秒、层数、类型边框和 Tooltip。

    每个首领框两个容器（当前客户端为 Flow 布局 API，参考 DBM AuraTracking）：
      Buff   容器：HELPFUL + 候选 isStealable / Enrage —— 可偷取或可进攻驱散（激怒）
      Debuff 容器：HARMFUL|PLAYER                      —— 仅玩家（含宠物/载具）施加
--]]

local FrameBoss = LibStub("AceAddon-3.0"):GetAddon("FrameBoss")
local Auras = {}
FrameBoss.Auras = Auras

local GetSpellTexture = C_Spell.GetSpellTexture  -- 11.0 起全局 GetSpellTexture 已移除

local FRAME_W = FrameBoss.FRAME_W
local GAP = 0  -- 图标紧贴，光环行紧贴框体

local DEBUFF_FILTER = "HARMFUL|PLAYER"

local function profile() return FrameBoss.db.profile end

-- CustomAuraContainerTemplate 属于按需加载的 Blizzard_AuraContainer
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

-- 每侧各占框体一半宽，图标间留 GAP；返回每侧最大个数与像素行宽
local function MaxPerSide(size)
    return math.max(1, math.floor((FRAME_W / 2 + GAP) / (size + GAP)))
end
local function LineSize(size)
    local n = MaxPerSide(size)
    return size * n + GAP * (n - 1)
end

-- 战斗中无法创建 AuraContainer（受保护），脱战后自动补建并重绑单位
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

-- 按钮初始化（引擎创建新按钮时回调），参考 DBM ConfigureButton
local function InitializeButton(container)
    return function(button)
        local size = container.currentSize
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

        -- 引擎按光环类型自动着色（魔法/中毒/疾病/诅咒/激怒…），增益减益都显示
        local border = button:CreateTexture(nil, "OVERLAY")
        border:SetAllPoints()
        button:AddDispelTypeTexture(border, {
            showWhenHarmful = true,
            showWhenHelpful = true,
        })

        container.buttons[#container.buttons + 1] = button
    end
end

local function GroupOptions(container, size, candidate)
    return {
        maxFrameCount = MaxPerSide(size),
        sortMethod = SortMethod,
        sortDirection = SortDir,
        initializeFrame = InitializeButton(container),
        candidateFilters = candidate,
        layout = {
            elementWidth = size,
            elementHeight = size,
            elementSpacing = GAP,
            lineSpacing = GAP,
        },
    }
end

-- fromRight=false：左侧 buff，向右生长；true：右侧 debuff，向左生长
local function BuildContainer(f, fromRight)
    if InCombatLockdown() then return nil end  -- 战斗中创建受保护，等脱战补建
    EnsureAuraLib()

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
    if not ok or not c then return nil end

    local size = profile().auraSize
    c.buttons = {}
    c.currentSize = size
    c.groupKeys = {}

    local anchor    = fromRight and "TOPRIGHT" or "TOPLEFT"
    local relAnchor = fromRight and "BOTTOMRIGHT" or "BOTTOMLEFT"
    local growH     = fromRight and FlowDir.Left or FlowDir.Right

    c:SetEnabled(false)
    c:Hide()
    c:ClearAllPoints()
    c:SetPoint(anchor, f, relAnchor, 0, -GAP)
    c:SetSize(size, size)  -- 容器不裁剪子框，图标可向外排布
    c:SetFlowLayoutAxis(FlowAxisH)
    c:SetFlowLayoutAnchorPoint(anchor)
    c:SetFlowLayoutGrowthDirection(growH, FlowDir.Down)
    c:SetFlowLayoutMaximumLineSize(LineSize(size))
    return c
end

local function AddGroup(c, key, filter, candidate)
    if not c:HasAuraGroup(key) then
        c:AddAuraGroup(key, filter, GroupOptions(c, c.currentSize, candidate))
        c.groupKeys[#c.groupKeys + 1] = key
    end
    -- 显式设置，确保 Flow API 下生效
    c:SetAuraGroupMaxFrameCount(key, MaxPerSide(c.currentSize))
    if candidate then c:SetAuraGroupCandidateFilters(key, candidate) end
end

-- 一整套构建（含分组）放进 pcall：任何 API 缺失/战斗保护都不中断插件
local function SetupContainer(f, fromRight, groups)
    local c = BuildContainer(f, fromRight)
    if not c then return nil end
    for _, g in ipairs(groups) do
        AddGroup(c, g.key, g.filter, g.candidate)
    end
    return c
end

-- 为单个首领框创建 buff/debuff 原生容器；失败则排队脱战重试
function Auras.CreateContainers(f)
    if not f then return false end
    if not f.buffContainer then
        -- 可偷取（法术后遣）与激怒（可进攻驱散）分两个候选组，引擎安全判定
        local ok, c = pcall(SetupContainer, f, false, {
            { key = f.unit .. "Stealable", filter = "HELPFUL", candidate = { isStealable = true } },
            { key = f.unit .. "Enrage",    filter = "HELPFUL", candidate = { includeDispelTypes = { Enrage = true } } },
        })
        if ok then f.buffContainer = c end
    end
    if not f.debuffContainer then
        local ok, c = pcall(SetupContainer, f, true, {
            { key = f.unit .. "Debuff", filter = DEBUFF_FILTER, candidate = nil },
        })
        if ok then f.debuffContainer = c end
    end
    if not f.buffContainer or not f.debuffContainer then
        pendingFrames[f] = true
        return false
    end
    pendingFrames[f] = nil
    Auras.ApplySize(f)
    return true
end

-- 绑定单位并启用查询（之后容器自行监听 UNIT_AURA，无需插件驱动）
function Auras.SetUnit(f, unit)
    if not Auras.CreateContainers(f) then return end  -- 战斗中尚未建成，脱战会补
    if f.testRow then f.testRow:Hide() end
    for _, c in ipairs({ f.buffContainer, f.debuffContainer }) do
        c:SetUnit(unit)
        c:Show()
        c:SetEnabled(true)
    end
end

-- 光环图标尺寸变更（选项面板 24/32/40）
function Auras.ApplySize(f)
    if not f or not f.buffContainer then return end
    local size = profile().auraSize
    if f.auraRow then f.auraRow:SetSize(FRAME_W, size) end
    for _, c in ipairs({ f.buffContainer, f.debuffContainer }) do
        c.currentSize = size
        c:SetSize(size, size)
        c:SetFlowLayoutMaximumLineSize(LineSize(size))
        for _, key in ipairs(c.groupKeys) do
            c:SetAuraGroupLayout(key, {
                elementWidth = size,
                elementHeight = size,
                elementSpacing = GAP,
                lineSpacing = GAP,
            })
            c:SetAuraGroupMaxFrameCount(key, MaxPerSide(size))
        end
        -- 不能直接对引擎生成的受保护 AuraButton 调 SetSize（taint 报错），
        -- 尺寸由上面的 SetAuraGroupLayout(elementWidth/Height) 让引擎自行套用
    end
    if f.testRow then f.testRow:SetSize(FRAME_W, size) end
end

-- 单位消失：停用容器（随父框体一并隐藏）；占位行保持尺寸以维持栅格布局
function Auras.Clear(f)
    if f.auraRow then f.auraRow:SetSize(FRAME_W, profile().auraSize) end
    if f.testRow then f.testRow:Hide() end
    for _, c in ipairs({ f.buffContainer, f.debuffContainer }) do
        if c then
            c:SetEnabled(false)
            c:Hide()
        end
    end
end

-- 测试模式（假数据不能灌进原生容器，叠加自绘图标占位）-------------------------

local BORDER_TEX  = "Interface\\Buttons\\UI-Debuff-Overlays"
local BORDER_COORD = { 0.296875, 0.5703125, 0, 0.515625 }

local COLOR_STEALABLE = { 0.50, 0.25, 1.00 }  -- 可偷取：蓝紫
local COLOR_DISPEL    = { 1.00, 0.38, 0.12 }  -- 可驱散：橙红
local COLOR_DEBUFF    = { 0.60, 0.20, 1.00 }  -- 玩家魔法减益：紫

local function CreateTestButton(row)
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
    b:Hide()
    return b
end

function Auras.ShowTest(f)
    if f.buffContainer then f.buffContainer:SetEnabled(false); f.buffContainer:Hide() end
    if f.debuffContainer then f.debuffContainer:SetEnabled(false); f.debuffContainer:Hide() end

    if not f.testRow then
        local row = CreateFrame("Frame", nil, f)
        row:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -GAP)
        row.buttons = {}
        for i = 1, 3 do row.buttons[i] = CreateTestButton(row) end
        f.testRow = row
    end
    local row = f.testRow
    local size = profile().auraSize
    row:SetSize(FRAME_W, size)

    local function place(b, anchor, rightSide)
        b:SetSize(size, size)
        b:ClearAllPoints()
        if anchor then
            b:SetPoint("TOPLEFT", anchor, "TOPRIGHT", GAP, 0)
        elseif rightSide then
            b:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
        else
            b:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        end
    end

    local b1, b2, b3 = row.buttons[1], row.buttons[2], row.buttons[3]

    place(b1, nil, false)
    b1.icon:SetTexture(GetSpellTexture(118))    -- 变形术图标，模拟可偷取
    b1.count:SetText("")
    b1.border:SetVertexColor(unpack(COLOR_STEALABLE))
    b1.cooldown:Hide()
    b1:Show()

    place(b2, b1, false)
    b2.icon:SetTexture(GetSpellTexture(6673))   -- 战斗怒吼图标，模拟激怒（可驱散）
    b2.count:SetText(3)
    b2.border:SetVertexColor(unpack(COLOR_DISPEL))
    b2.cooldown:Hide()
    b2:Show()

    place(b3, nil, true)
    b3.icon:SetTexture(GetSpellTexture(589))    -- 暗言术：痛图标，模拟玩家 debuff
    b3.count:SetText(5)
    b3.border:SetVertexColor(unpack(COLOR_DEBUFF))
    b3.cooldown:SetCooldown(GetTime() - 8, 30)  -- 剩余约 22 秒
    b3.cooldown:Show()
    b3:Show()

    row:Show()
end
