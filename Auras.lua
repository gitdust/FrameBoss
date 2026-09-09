--[[
    FrameBoss - Auras.lua
    12.x 起副本内首领单位的光环整体是 secret：tainted（插件）代码直接调用
    C_UnitAuras.GetAuraDataByIndex 会报 "Auras cannot be accessed when secret"。
    因此改用暴雪原生 AuraContainer（CustomAuraContainerTemplate，定义在按需
    加载的 Blizzard_AuraContainer 插件里）：引擎在安全上下文内部枚举光环，
    secret 单位也能正常显示，并自动处理刷新、冷却扫秒、层数、类型边框和 Tooltip。

    每个首领框三个容器（当前客户端为 Flow 布局 API，参考 DBM AuraTracking）：
      Buff-Special 容器（左侧）：HELPFUL 且可偷取 / 可驱散（激怒）  20×20
      Buff-Regular 容器（中左）：HELPFUL 普通增益                    16×16
      Debuff        容器（右侧）：HARMFUL|PLAYER —— 仅玩家（含宠物/载具）施加  16×16
--]]

local FrameBoss = LibStub("AceAddon-3.0"):GetAddon("FrameBoss")
local Auras = {}
FrameBoss.Auras = Auras

local GetSpellTexture = C_Spell.GetSpellTexture  -- 11.0 起全局 GetSpellTexture 已移除

local FRAME_W = FrameBoss.FRAME_W
local GAP = 0  -- 图标紧贴，光环行紧贴框体

-- 光环组尺寸（用户指定：可驱散/可偷取放大，普通光环缩小）
local SIZE_BUFF_SPECIAL = 20  -- 可偷取 / 激怒
local SIZE_BUFF_REGULAR = 16  -- 普通 HELPFUL
local SIZE_DEBUFF       = 16  -- 玩家施加的 HARMFUL

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

-- 容器宽 = 光环行可用宽度（左半帧 / 右半帧）
local CONTAINER_W = math.floor(FRAME_W / 2) - GAP
-- 每侧最多图标数（按指定 size 计算）
local function MaxPerSide(size)
    return math.max(1, math.floor((CONTAINER_W + GAP) / (size + GAP)))
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

-- 按钮初始化（引擎创建新按钮时回调）
-- 容器为单一 size 时直接用；混合 size 容器使用传入的 size 闭包
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

-- 容器构造（inAuraRow=左侧起点；iconFromRight=debuff 时反向生长）
local function BuildContainer(f, anchor, relAnchor, growH, size)
    if InCombatLockdown() then return nil end  -- 战斗中创建受保护，等脱战补建
    EnsureAuraLib()

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, f, "CustomAuraContainerTemplate")
    if not ok or not c then return nil end

    c.buttons = {}
    c.currentSize = size
    c.groupKeys = {}

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

local function AddGroup(c, key, filter, candidate, size)
    if not c:HasAuraGroup(key) then
        c:AddAuraGroup(key, filter, GroupOptions(c, size, candidate))
        c.groupKeys[#c.groupKeys + 1] = key
    end
    c:SetAuraGroupMaxFrameCount(key, MaxPerSide(size))
    if candidate then c:SetAuraGroupCandidateFilters(key, candidate) end
    -- 显式设置，确保 Flow API 下生效
    c:SetAuraGroupLayout(key, {
        elementWidth = size,
        elementHeight = size,
        elementSpacing = GAP,
        lineSpacing = GAP,
    })
end

-- 一整套构建（含分组）放进 pcall：任何 API 缺失/战斗保护都不中断插件
local function SetupContainer(f, c, groups)
    for _, g in ipairs(groups) do
        AddGroup(c, g.key, g.filter, g.candidate, g.size)
    end
end

-- 为单个首领框创建 3 个原生容器；失败则排队脱战重试
function Auras.CreateContainers(f)
    if not f then return false end
    if not f.buffSpecial then
        -- 可偷取 + 激怒（可驱散） 20×20，左侧起点向右生长
        local ok, c = pcall(BuildContainer, f, "TOPLEFT", "BOTTOMLEFT", FlowDir.Right, SIZE_BUFF_SPECIAL)
        if ok and c then
            pcall(SetupContainer, f, c, {
                { key = f.unit .. "Stealable", filter = "HELPFUL", candidate = { isStealable = true }, size = SIZE_BUFF_SPECIAL },
                { key = f.unit .. "Enrage",    filter = "HELPFUL", candidate = { includeDispelTypes = { Enrage = true } }, size = SIZE_BUFF_SPECIAL },
            })
            f.buffSpecial = c
        end
    end
    if not f.buffRegular then
        -- 普通 HELPFUL 增益 16×16，锚定到 buffSpecial 右侧
        if not InCombatLockdown() and f.buffSpecial then
            local ok, c = pcall(BuildContainer, f, "TOPLEFT", "BOTTOMLEFT", FlowDir.Right, SIZE_BUFF_REGULAR)
            if ok and c then
                pcall(SetupContainer, f, c, {
                    { key = f.unit .. "Regular", filter = "HELPFUL", candidate = nil, size = SIZE_BUFF_REGULAR },
                })
                -- 重定位到 buffSpecial 右侧
                c:ClearAllPoints()
                c:SetPoint("TOPLEFT", f.buffSpecial, "TOPRIGHT", 0, 0)
                f.buffRegular = c
            end
        end
    end
    if not f.debuffContainer then
        -- 玩家施加的 HARMFUL debuff 16×16，右侧起点向左生长
        local ok, c = pcall(BuildContainer, f, "TOPRIGHT", "BOTTOMRIGHT", FlowDir.Left, SIZE_DEBUFF)
        if ok and c then
            pcall(SetupContainer, f, c, {
                { key = f.unit .. "Debuff", filter = DEBUFF_FILTER, candidate = nil, size = SIZE_DEBUFF },
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

-- 绑定单位并启用查询（之后容器自行监听 UNIT_AURA，无需插件驱动）
function Auras.SetUnit(f, unit)
    if not Auras.CreateContainers(f) then return end  -- 战斗中尚未建成，脱战会补
    if f.testRow then f.testRow:Hide() end
    for _, c in ipairs({ f.buffSpecial, f.buffRegular, f.debuffContainer }) do
        if c then
            c:SetUnit(unit)
            c:Show()
            c:SetEnabled(true)
        end
    end
end

-- 三个容器尺寸都是常量，应用层仅同步 Flow 布局最大行宽
function Auras.ApplySize(f)
    if not f or not f.buffSpecial then return end
    for _, entry in ipairs({
        { c = f.buffSpecial,   size = SIZE_BUFF_SPECIAL },
        { c = f.buffRegular,   size = SIZE_BUFF_REGULAR },
        { c = f.debuffContainer, size = SIZE_DEBUFF },
    }) do
        local c, size = entry.c, entry.size
        if c then
            c.currentSize = size
            c:SetSize(size, size)
            c:SetFlowLayoutMaximumLineSize(LineSize(size))
            for _, key in ipairs(c.groupKeys) do
                c:SetAuraGroupMaxFrameCount(key, MaxPerSide(size))
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

-- 单位消失：停用容器（随父框体一并隐藏）
function Auras.Clear(f)
    if f.testRow then f.testRow:Hide() end
    for _, c in ipairs({ f.buffSpecial, f.buffRegular, f.debuffContainer }) do
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
    -- 测试按钮按各类型对应尺寸
    local szSpec  = SIZE_BUFF_SPECIAL
    local szReg   = SIZE_BUFF_REGULAR
    local szDebuf = SIZE_DEBUFF
    row:SetSize(FRAME_W, szSpec)

    while #row.buttons < 4 do
        local b = CreateTestButton(row, szSpec)
        row.buttons[#row.buttons + 1] = b
    end
    local b1, b2, b3, b4 = row.buttons[1], row.buttons[2], row.buttons[3], row.buttons[4]

    -- b1: 可偷取（20×20，左侧起）
    b1:SetSize(szSpec, szSpec)
    b1:ClearAllPoints()
    b1:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    b1.icon:SetTexture(GetSpellTexture(118))    -- 变形术图标，模拟可偷取
    b1.count:SetText("")
    b1.border:SetVertexColor(unpack(COLOR_STEALABLE))
    b1.cooldown:Hide()
    b1:Show()

    -- b2: 激怒/可驱散（20×20，紧贴 b1 右侧）
    b2:SetSize(szSpec, szSpec)
    b2:ClearAllPoints()
    b2:SetPoint("TOPLEFT", b1, "TOPRIGHT", GAP, 0)
    b2.icon:SetTexture(GetSpellTexture(6673))   -- 战斗怒吼图标，模拟激怒
    b2.count:SetText(3)
    b2.border:SetVertexColor(unpack(COLOR_DISPEL))
    b2.cooldown:Hide()
    b2:Show()

    -- b3: 普通 HELPFUL（16×16，紧贴 b2 右侧）
    b3:SetSize(szReg, szReg)
    b3:ClearAllPoints()
    b3:SetPoint("TOPLEFT", b2, "TOPRIGHT", GAP, 0)
    b3.icon:SetTexture(GetSpellTexture(48440))  -- 嗜血
    b3.count:SetText("")
    b3.border:SetVertexColor(unpack(COLOR_STEALABLE))
    b3.cooldown:Hide()
    b3:Show()

    -- b4: 玩家 debuff（16×16，右侧起）
    b4:SetSize(szDebuf, szDebuf)
    b4:ClearAllPoints()
    b4:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    b4.icon:SetTexture(GetSpellTexture(589))    -- 暗言术：痛图标，模拟玩家 debuff
    b4.count:SetText(5)
    b4.border:SetVertexColor(unpack(COLOR_DEBUFF))
    b4.cooldown:SetCooldown(GetTime() - 8, 30)  -- 剩余约 22 秒
    b4.cooldown:Show()
    b4:Show()

    row:Show()
end