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

    -- Closing the options UI (Close button / X / Escape) automatically exits
    -- edit/test ("debug") mode.
    local function ExitEditModeIfActive()
        local p = FrameBoss.db and FrameBoss.db.profile
        if p and p.editMode then
            FrameBoss:SetEditMode(false)
        end
    end

    -- Standalone AceGUI window opened by /fb: hook the underlying frame's
    -- OnHide (fires for the Close button, Escape, and programmatic close).
    -- The widget is recreated on every Open, so re-hook via Open hook.
    hooksecurefunc(AceConfigDialog, "Open", function(_, appName)
        if appName ~= "FrameBoss" then return end
        local widget = AceConfigDialog.OpenFrames and AceConfigDialog.OpenFrames[appName]
        local frame = widget and widget.frame
        if frame and not frame.frameBossCloseHooked then
            frame.frameBossCloseHooked = true
            frame:HookScript("OnHide", ExitEditModeIfActive)
        end
    end)

    -- Blizzard Settings panel (the category added by AddToBlizOptions);
    -- Blizzard_Settings is load-on-demand, hook as soon as it exists.
    local function HookBlizzardSettings()
        local panel = _G.SettingsPanel
        if panel and not panel.frameBossCloseHooked then
            panel.frameBossCloseHooked = true
            panel:HookScript("OnHide", ExitEditModeIfActive)
        end
    end
    HookBlizzardSettings()
    local settingsWatcher = CreateFrame("Frame")
    settingsWatcher:RegisterEvent("ADDON_LOADED")
    settingsWatcher:SetScript("OnEvent", function(_, _, addonName)
        if addonName == "Blizzard_Settings" then HookBlizzardSettings() end
    end)

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