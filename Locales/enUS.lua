--[[
    FrameBoss - Locales/enUS.lua
    English (default) locale. Registered as AceLocale fallback; missing
    keys in other locales automatically use these values.
--]]

local L = LibStub("AceLocale-3.0"):NewLocale("FrameBoss", "enUS", true)
if not L then return end

-- Anchor / mover labels
L["ANCHOR_LABEL"]        = "FrameBoss (drag to move)"

-- In-frame text
L["TEXT_OFFLINE"]        = "Offline"
L["TEXT_DEAD"]           = "Dead"
L["TEXT_TEST_BOSS"]      = "Test Boss %d"

-- AceConfig option labels and descriptions
L["OPT_GROUP_GENERAL"]   = "General Settings"
L["OPT_SCALE"]           = "Overall Scale"
L["OPT_SHOW_POWER"]      = "Show Power Bar"
L["OPT_HEALTH_COLOR"]    = "Health Bar Color"
L["OPT_HEADER_POSITION"] = "Position & Preview"
L["OPT_EDIT_MODE"]       = "Edit Mode (Unlock Drag + Show Test Frames)"
L["OPT_EDIT_MODE_DESC"]  = "When enabled, drag the green frame to reposition; previews 5 test boss frames. Turning off auto-exits test mode."
L["OPT_RESET_POSITION"]  = "Reset Position"
