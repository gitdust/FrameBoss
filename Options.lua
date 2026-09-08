--[[
    FrameBoss - Options.lua
    AceConfig 图形设置面板（接入暴雪设置界面）+ /fb、/frameboss 斜杠命令。
--]]

local FrameBoss = LibStub("AceAddon-3.0"):GetAddon("FrameBoss")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

function FrameBoss:SetupOptions()
    local function profile() return self.db.profile end

    local options = {
        type = "group",
        name = "FrameBoss",
        args = {
            general = {
                type = "group",
                name = "常规设置",
                order = 1,
                args = {
                    scale = {
                        type = "range",
                        name = "整体缩放",
                        order = 1,
                        min = 0.6, max = 2.0, step = 0.05,
                        get = function() return profile().scale end,
                        set = function(_, v) profile().scale = v; FrameBoss:ApplyMover() end,
                    },
                    auraSize = {
                        type = "select",
                        name = "光环图标大小",
                        order = 2,
                        values = { [24] = "24 px", [32] = "32 px", [40] = "40 px" },
                        get = function() return profile().auraSize end,
                        set = function(_, v) profile().auraSize = v; FrameBoss:RefreshAll() end,
                    },
                    showPower = {
                        type = "toggle",
                        name = "显示能量条",
                        order = 3,
                        get = function() return profile().showPower end,
                        set = function(_, v) profile().showPower = v; FrameBoss:RefreshAll() end,
                    },
                    healthColor = {
                        type = "color",
                        name = "血条颜色",
                        order = 4,
                        get = function()
                            local c = profile().healthColor
                            return c[1], c[2], c[3]
                        end,
                        set = function(_, r, g, b)
                            profile().healthColor = { r, g, b }
                            FrameBoss:ApplySettings()
                        end,
                    },
                    moverHeader = { type = "header", name = "位置", order = 10 },
                    unlock = {
                        type = "toggle",
                        name = "解锁移动（拖动绿色框体）",
                        order = 11,
                        get = function() return not profile().locked end,
                        set = function(_, v)
                            profile().locked = not v
                            FrameBoss:RefreshAll()
                        end,
                    },
                    resetPosition = {
                        type = "execute",
                        name = "重置位置",
                        order = 12,
                        func = function() FrameBoss:ResetPosition() end,
                    },
                    testHeader = { type = "header", name = "测试", order = 20 },
                    testMode = {
                        type = "toggle",
                        name = "测试模式（副本外预览 5 个框体）",
                        order = 21,
                        get = function() return profile().testMode end,
                        set = function(_, v) FrameBoss:SetTestMode(v) end,
                    },
                },
            },
        },
    }

    -- 配置档案（profiles）
    local profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
    profiles.order = -1
    options.args.profiles = profiles

    AceConfig:RegisterOptionsTable("FrameBoss", options)
    AceConfigDialog:AddToBlizOptions("FrameBoss", "FrameBoss")

    self:RegisterChatCommand("fb", "ChatCommand")
    self:RegisterChatCommand("frameboss", "ChatCommand")
end

function FrameBoss:ChatCommand(input)
    local cmd = strtrim(input or ""):lower()
    if cmd == "test" then
        self:SetTestMode(not self.db.profile.testMode)
    else
        AceConfigDialog:Open("FrameBoss")
    end
end
