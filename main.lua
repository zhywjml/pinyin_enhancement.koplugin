local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local DataStorage = require("datastorage")

local PinyinPatch = WidgetContainer:extend{}

-- 互斥锁：防止 monkey-patch 多次嵌套
local _patch_applied = false
local _menu_patched = false

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

-- 解析插件目录路径
local function getPluginDir()
    local data_dir = DataStorage:getDataDir()
    -- 去掉开头的 "./" 或 "."
    if data_dir:sub(1, 2) == "./" then
        data_dir = data_dir:sub(3)
    elseif data_dir:sub(1, 1) == "." then
        data_dir = data_dir:sub(2)
    end
    if data_dir:sub(-1) ~= "/" then
        data_dir = data_dir .. "/"
    end
    return data_dir .. "plugins/pinyin_enhancement.koplugin/"
end

-- 加载补丁（通过 require，利用 package.path 机制）
local function loadPatch()
    if _patch_applied then
        return
    end

    -- 确保插件目录在 Lua 搜索路径中
    local plugin_dir = getPluginDir()
    local dir = plugin_dir .. "?.lua"
    if not package.path:find(dir, 1, true) then
        package.path = dir .. ";" .. package.path
    end

    local ok, err = pcall(require, "candidate_bar")
    if ok then
        _patch_applied = true
    else
        print("拼音补丁加载失败:", err)
    end
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
                        UIManager:show(InfoMessage:new{
                            text = _("拼音功能已禁用，重启KOReader后生效。"),
                        })
                    end
                end,
                help_text = _("启用后，在中文输入法下输入拼音时会显示候选词栏。"),
            },
            {
                text = _("启用模糊音"),
                checked_func = function()
                    local enabled = G_reader_settings:readSetting("pinyin_fuzzy_enabled")
                    return enabled == true
                end,
                callback = function()
                    local current = G_reader_settings:readSetting("pinyin_fuzzy_enabled")
                    G_reader_settings:saveSetting("pinyin_fuzzy_enabled", not current)
                end,
                help_text = _("支持平翘舌(zh/z)、前后鼻音(en/eng)、l/n、f/h 等常见混淆。"),
            },
            {
                text = _("检查更新"),
                callback = function()
                    local ok, update = pcall(require, "pinyin_update")
                    if ok then
                        update.check_for_updates(false)
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("无法加载更新模块"),
                        })
                    end
                end,
                separator = true,
            },
        },
    }
end

-- 注入设置菜单到文件管理器和阅读器（仅执行一次）
local function injectSettingsMenu()
    if _menu_patched then
        return
    end
    _menu_patched = true

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