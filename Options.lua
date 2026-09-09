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
                    showPower = {
                        type = "toggle",
                        name = "显示能量条",
                        order = 2,
                        get = function() return profile().showPower end,
                        set = function(_, v) profile().showPower = v; FrameBoss:RefreshAll() end,
                    },
                    healthColor = {
                        type = "color",
                        name = "血条颜色",
                        order = 3,
                        get = function()
                            local c = profile().healthColor
                            return c[1], c[2], c[3]
                        end,
                        set = function(_, r, g, b)
                            profile().healthColor = { r, g, b }
                            FrameBoss:ApplySettings()
                        end,
                    },
                    editHeader = { type = "header", name = "位置与预览", order = 10 },
                    editMode = {
                        type = "toggle",
                        name = "编辑模式（解锁拖动 + 显示测试框体）",
                        order = 11,
                        desc = "开启后可拖动绿色框体调整位置，并预览 5 个测试首领框体；关闭后自动退出测试模式。",
                        get = function() return profile().editMode end,
                        set = function(_, v) FrameBoss:SetEditMode(v) end,
                    },
                    resetPosition = {
                        type = "execute",
                        name = "重置位置",
                        order = 12,
                        func = function() FrameBoss:ResetPosition() end,
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
    if cmd == "test" or cmd == "edit" then
        -- /fb test 或 /fb edit：切换编辑模式（含测试模式）
        self:SetEditMode(not self.db.profile.editMode)
    else
        AceConfigDialog:Open("FrameBoss")
    end
end