--[[
    FrameBoss - Locales/zhCN.lua
    Simplified Chinese locale. Loaded after enUS so its values override
    the English fallback on zhCN clients. Missing keys fall back to enUS.
--]]

local L = LibStub("AceLocale-3.0"):NewLocale("FrameBoss", "zhCN", false)
if not L then return end

-- Anchor / mover labels
L["ANCHOR_LABEL"]        = "FrameBoss（拖动移动）"

-- In-frame text
L["TEXT_OFFLINE"]        = "离线"
L["TEXT_DEAD"]           = "死亡"
L["TEXT_TEST_BOSS"]      = "测试首领 %d"

-- AceConfig option labels and descriptions
L["OPT_GROUP_GENERAL"]   = "常规设置"
L["OPT_SCALE"]           = "整体缩放"
L["OPT_SHOW_POWER"]      = "显示能量条"
L["OPT_HEADER_POSITION"] = "位置与预览"
L["OPT_EDIT_MODE"]       = "编辑模式（解锁拖动 + 显示测试框体）"
L["OPT_EDIT_MODE_DESC"]  = "开启后可拖动绿色框体调整位置，并预览 5 个测试首领框体；关闭后自动退出测试模式。"
L["OPT_RESET_POSITION"]  = "重置位置"
