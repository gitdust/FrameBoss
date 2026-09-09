--[[
    FrameBoss - Options.lua
    AceConfig graphical settings panel (wired into Blizzard's Settings UI)
    plus the /fb and /frameboss slash commands.
--]]

local FrameBoss = LibStub("AceAddon-3.0"):GetAddon("FrameBoss")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("FrameBoss", true)

function FrameBoss:SetupOptions()
    local function profile() return self.db.profile end

    local options = {
        type = "group",
        name = "FrameBoss",
        args = {
            general = {
                type = "group",
                name = L["OPT_GROUP_GENERAL"],
                order = 1,
                args = {
                    scale = {
                        type = "range",
                        name = L["OPT_SCALE"],
                        order = 1,
                        min = 0.6, max = 2.0, step = 0.05,
                        get = function() return profile().scale end,
                        set = function(_, v) profile().scale = v; FrameBoss:ApplyMover() end,
                    },
                    showPower = {
                        type = "toggle",
                        name = L["OPT_SHOW_POWER"],
                        order = 2,
                        get = function() return profile().showPower end,
                        set = function(_, v) profile().showPower = v; FrameBoss:RefreshAll() end,
                    },
                    healthColor = {
                        type = "color",
                        name = L["OPT_HEALTH_COLOR"],
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
                    editHeader = { type = "header", name = L["OPT_HEADER_POSITION"], order = 10 },
                    editMode = {
                        type = "toggle",
                        name = L["OPT_EDIT_MODE"],
                        order = 11,
                        desc = L["OPT_EDIT_MODE_DESC"],
                        get = function() return profile().editMode end,
                        set = function(_, v) FrameBoss:SetEditMode(v) end,
                    },
                    resetPosition = {
                        type = "execute",
                        name = L["OPT_RESET_POSITION"],
                        order = 12,
                        func = function() FrameBoss:ResetPosition() end,
                    },
                },
            },
        },
    }

    -- Profiles
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
        -- /fb test or /fb edit: toggle edit mode (also toggles test mode).
        self:SetEditMode(not self.db.profile.editMode)
    else
        AceConfigDialog:Open("FrameBoss")
    end
end