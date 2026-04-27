local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local PinyinPatch = WidgetContainer:extend{}

-- 插件是否启用（从设置中读取）
local function isEnabled()
    local enabled = G_reader_settings:readSetting("pinyin_enhancement_enabled")
    if enabled == nil then
        G_reader_settings:saveSetting("pinyin_enhancement_enabled", true)
        return true
    end
    return enabled
end

-- 保存设置
local function setEnabled(enabled)
    G_reader_settings:saveSetting("pinyin_enhancement_enabled", enabled)
end

-- 加载补丁
local function loadPatch()
    UIManager:scheduleIn(0.5, function()
        local ok, err = pcall(dofile, "plugins/pinyin_enhancement.koplugin/candidate_bar.lua")
        if not ok then
            print("拼音补丁加载失败:", err)
        end
    end)
end

-- 构建设置菜单项
local function buildSettingsMenu()
    return {
        text = _("拼音输入法增强"),
        sub_item_table = {
            {
                text = _("启用拼音候选词"),
                checked_func = function() 
                    local enabled = G_reader_settings:readSetting("pinyin_enhancement_enabled")
                    if enabled == nil then
                        return true
                    end
                    return enabled
                end,
                callback = function()
                    local new_state = not isEnabled()
                    setEnabled(new_state)
                    if new_state then
                        loadPatch()
                    else
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = _("拼音功能已禁用，重启KOReader后生效。"),
                        })
                    end
                end,
                help_text = _("启用后，在中文输入法下输入拼音时会显示候选词栏。"),
            },
            -- 新增：检查更新
            {
                text = _("检查更新"),
                callback = function()
                local update = require("pinyin_update")
                update.check_for_updates(false)
                end,
                separator = true,
            },
        },
    }
end

-- 注入设置菜单到文件管理器和阅读器
local function injectSettingsMenu()
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local FileManagerMenuOrder = require("ui/elements/filemanager_menu_order")
    
    local already_in_order = false
    for _, v in ipairs(FileManagerMenuOrder.setting) do
        if v == "pinyin_enhancement_config" then 
            already_in_order = true
            break 
        end
    end
    if not already_in_order then
        table.insert(FileManagerMenuOrder.setting, "----------------------------")
        table.insert(FileManagerMenuOrder.setting, "pinyin_enhancement_config")
    end
    
    local orig_fm_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
    FileManagerMenu.setUpdateItemTable = function(self)
        self.menu_items.pinyin_enhancement_config = buildSettingsMenu()
        orig_fm_setUpdateItemTable(self)
    end
    
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local ReaderMenuOrder = require("ui/elements/reader_menu_order")
    
    already_in_order = false
    for _, v in ipairs(ReaderMenuOrder.setting) do
        if v == "pinyin_enhancement_config" then 
            already_in_order = true
            break 
        end
    end
    if not already_in_order then
        table.insert(ReaderMenuOrder.setting, "----------------------------")
        table.insert(ReaderMenuOrder.setting, "pinyin_enhancement_config")
    end
    
    local orig_reader_setUpdateItemTable = ReaderMenu.setUpdateItemTable
    ReaderMenu.setUpdateItemTable = function(self)
        self.menu_items.pinyin_enhancement_config = buildSettingsMenu()
        orig_reader_setUpdateItemTable(self)
    end
end

function PinyinPatch:init()
    injectSettingsMenu()
    
    if G_reader_settings:readSetting("pinyin_enhancement_enabled") == nil then
        G_reader_settings:saveSetting("pinyin_enhancement_enabled", true)
        loadPatch()
    elseif isEnabled() then
        loadPatch()
    end
end

return PinyinPatch