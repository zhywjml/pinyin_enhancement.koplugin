-- pinyin_update.lua
-- 拼音增强插件在线更新模块

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local gettext = require("gettext")

local M = {}

-- 仓库信息（使用 GitHub API）
local REPO_API = "https://api.github.com"
local REPO_OWNER = "zhywjml"
local REPO_NAME = "pinyin_enhancement.koplugin"

local Device = require("device")
local is_android = Device:isAndroid()

-- 统一获取插件目录路径（始终通过 DataStorage，不依赖文件路径参数）
local function getPluginDir()
    local data_dir = DataStorage:getDataDir()
    -- 规范化路径：去掉开头的 "./" 或 "."
    if data_dir:sub(1, 2) == "./" then
        data_dir = data_dir:sub(3)
    elseif data_dir:sub(1, 1) == "." then
        data_dir = data_dir:sub(2)
    end
    if data_dir:sub(-1) ~= "/" then
        data_dir = data_dir .. "/"
    end
    local dir = data_dir .. "plugins/pinyin_enhancement.koplugin/"
    -- 去掉尾部 "/"
    if dir:sub(-1) == "/" then
        dir = dir:sub(1, -2)
    end
    return dir
end

local plugin_dir = getPluginDir()

logger.info("PinyinEnhancement: 插件目录: " .. plugin_dir)

local function get_current_version()
    local meta_path = plugin_dir .. "/_meta.lua"
    local f = io.open(meta_path, "r")
    if not f then
        return "v1.0"
    end
    local content = f:read("*all")
    f:close()
    local version = content:match('version%s*=%s*"([^"]+)"')
    if not version then
        version = content:match("version%s*=%s*'([^']+)'")
    end
    return version or "v1.0"
end

-- 获取所有版本列表（分页获取）
function M.get_all_versions()
    local page = 1
    local all_versions = {}
    
    while true do
        local url = string.format("%s/repos/%s/%s/releases?page=%d&per_page=100", REPO_API, REPO_OWNER, REPO_NAME, page)
        
        logger.info("PinyinEnhancement: 请求版本列表 URL: " .. url)
        
        local ok_http, http = pcall(require, "socket.http")
        local ok_ltn12, ltn12 = pcall(require, "ltn12")
        if not ok_http or not ok_ltn12 then
            logger.warn("PinyinEnhancement: 网络库不可用")
            break
        end
        
        local response = {}
        local ok, err = pcall(function()
            return http.request{
                url = url,
                sink = ltn12.sink.table(response),
                headers = {
                    ["User-Agent"] = "KOReader-PinyinEnhancement",
                    ["Accept"] = "application/json",
                }
            }
        end)
        
        if not ok or not response or #response == 0 then
            break
        end
        
        local response_str = table.concat(response)
        local ok_json, json = pcall(require, "json")
        if not ok_json then
            logger.warn("PinyinEnhancement: JSON 库不可用")
            break
        end
        local success, data = pcall(json.decode, response_str)
        
        if not success or not data or #data == 0 then
            break
        end
        
        for _, release in ipairs(data) do
            local tag_name = release.tag_name or release.name
            if tag_name then
                local zip_url = nil
                if release.assets then
                    for _, asset in ipairs(release.assets) do
                        if asset.name and asset.name:match("%.zip$") then
                            zip_url = asset.browser_download_url
                            break
                        end
                    end
                end
                table.insert(all_versions, {
                    tag = tag_name,
                    url = zip_url,
                    body = release.body,
                })
            end
        end
        
        if #data < 100 then
            break
        end
        page = page + 1
    end
    
    return all_versions
end

function M.get_latest_version()
    local url = string.format("%s/repos/%s/%s/releases/latest", REPO_API, REPO_OWNER, REPO_NAME)
    
    logger.info("PinyinEnhancement: 请求最新版本 URL: " .. url)
    
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_http or not ok_ltn12 then
        logger.warn("PinyinEnhancement: 网络库不可用")
        return nil, nil, "网络库不可用"
    end
    
    local response = {}
    local ok, err = pcall(function()
        return http.request{
            url = url,
            sink = ltn12.sink.table(response),
            headers = {
                ["User-Agent"] = "KOReader-PinyinEnhancement",
                ["Accept"] = "application/json",
            }
        }
    end)
    
    if not ok then
        logger.warn("PinyinEnhancement: HTTP 请求异常: " .. tostring(err))
        return nil, nil, "网络请求异常"
    end
    
    if not response or #response == 0 then
        logger.warn("PinyinEnhancement: 响应为空")
        return nil, nil, "服务器无响应"
    end
    
    local response_str = table.concat(response)
    local ok_json, json = pcall(require, "json")
    if not ok_json then
        logger.warn("PinyinEnhancement: JSON 库不可用")
        return nil, nil, "JSON 库不可用"
    end
    local success, data = pcall(json.decode, response_str)
    
    if not success or not data then
        logger.warn("PinyinEnhancement: JSON 解析失败")
        return nil, nil, "解析版本信息失败"
    end
    
    local tag_name = data.tag_name or data.name
    if not tag_name then
        logger.warn("PinyinEnhancement: 未找到版本号")
        return nil, nil, "未找到版本号"
    end
    
    logger.info("PinyinEnhancement: 最新版本: " .. tag_name)
    
    local zip_url = nil
    if data.assets then
        for _, asset in ipairs(data.assets) do
            if asset.name and asset.name:match("%.zip$") then
                zip_url = asset.browser_download_url
                break
            end
        end
    end
    
    return tag_name, zip_url, data.body
end

function M.is_newer_version(current, latest)
    if current == latest then return false end
    
    local cur = current:gsub("^v", "")
    local lat = latest:gsub("^v", "")
    
    local cur_parts = {}
    for part in cur:gmatch("[^.]+") do
        table.insert(cur_parts, tonumber(part) or 0)
    end
    local lat_parts = {}
    for part in lat:gmatch("[^.]+") do
        table.insert(lat_parts, tonumber(part) or 0)
    end
    
    for i = 1, math.max(#cur_parts, #lat_parts) do
        local cur_part = cur_parts[i] or 0
        local lat_part = lat_parts[i] or 0
        if lat_part > cur_part then
            return true
        elseif lat_part < cur_part then
            return false
        end
    end
    return false
end

function M.download_update(download_url)
    -- 用 socket.http 下载（跨平台可靠，不依赖 curl/wget）
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_http or not ok_ltn12 then
        return nil, "网络库不可用"
    end

    local zip_path
    if is_android then
        local plugins_dir = plugin_dir:match("(.*/)")
        zip_path = plugins_dir .. "pinyin_enhancement.koplugin.zip"
        if lfs.attributes(plugins_dir, "mode") ~= "directory" then
            os.execute("mkdir -p " .. plugins_dir)
        end
    else
        zip_path = "/tmp/pinyin_enhancement.koplugin.zip"
    end

    local response = {}
    local ok, err = pcall(function()
        return http.request{
            url = download_url,
            sink = ltn12.sink.table(response),
            headers = {
                ["User-Agent"] = "KOReader-PinyinEnhancement",
                ["Accept"] = "application/octet-stream",
            },
            -- 30 秒超时
            timeout = 30,
        }
    end)

    if not ok or not response or #response == 0 then
        os.remove(zip_path)
        return nil, "下载失败: " .. tostring(err)
    end

    -- 写入文件
    local f, err_msg = io.open(zip_path, "wb")
    if not f then
        return nil, "无法创建文件: " .. tostring(err_msg)
    end
    for _, chunk in ipairs(response) do
        f:write(chunk)
    end
    f:close()

    local size = lfs.attributes(zip_path, "size") or 0
    if size < 1000 then
        os.remove(zip_path)
        return nil, "下载的文件无效"
    end

    logger.info("PinyinEnhancement: 下载完成，大小: " .. size .. " 字节")
    return zip_path
end

function M.install_update(zip_path)
    -- 确保目标目录存在
    if lfs.attributes(plugin_dir, "mode") ~= "directory" then
        os.execute("mkdir -p \"" .. plugin_dir .. "\"")
    end

    logger.info("PinyinEnhancement: 解压到插件目录: " .. plugin_dir)

    -- 尝试多种解压方式
    local result = os.execute(string.format("unzip -o -q '%s' -d '%s' 2>/dev/null", zip_path, plugin_dir))
    if result ~= 0 then
        result = os.execute(string.format("busybox unzip -o -q '%s' -d '%s' 2>/dev/null", zip_path, plugin_dir))
    end
    if result ~= 0 then
        result = os.execute(string.format("/usr/bin/unzip -o '%s' -d '%s' 2>/dev/null", zip_path, plugin_dir))
    end

    os.remove(zip_path)

    if result == 0 then
        logger.info("PinyinEnhancement: 更新安装成功")
    else
        logger.warn("PinyinEnhancement: 更新安装失败")
    end

    return result == 0
end

-- 显示版本选择对话框（用于回退）
local _version_dialog = nil  -- 局部变量替代 plugin._version_dialog

local function show_version_choice(versions, current_version)
    local buttons = {}
    
    for _, v in ipairs(versions) do
        local is_current = (v.tag == current_version)
        local button_text = is_current and string.format(gettext("当前版本: %s (重新下载)"), v.tag) or string.format(gettext("回退到 %s"), v.tag)
        
        table.insert(buttons, {
            {
                text = button_text,
                callback = function()
                    if _version_dialog then
                        UIManager:close(_version_dialog)
                        _version_dialog = nil
                    end
                    M.perform_update(v.url, v.tag)
                end
            }
        })
    end
    
    table.insert(buttons, {})
    table.insert(buttons, {
        {
            text = gettext("取消"),
            callback = function()
                if _version_dialog then
                    UIManager:close(_version_dialog)
                    _version_dialog = nil
                end
            end
        }
    })
    
    local ButtonDialog = require("ui/widget/buttondialog")
    local Screen = Device.screen
    _version_dialog = ButtonDialog:new{
        title = gettext("选择要下载的版本"),
        title_align = "center",
        buttons = buttons,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(_version_dialog)
end

function M.check_for_updates(silent)
    if not NetworkMgr:isOnline() then
        if not silent then
            UIManager:show(Notification:new{
                text = gettext("无网络连接，无法检查更新"),
                timeout = 2
            })
        end
        return
    end
    
    if not silent then
        UIManager:show(Notification:new{
            text = gettext("正在检查更新..."),
            timeout = 1
        })
    end
    
    UIManager:scheduleIn(1, function()
        local latest_version, download_url, release_notes = M.get_latest_version()
        
        if not latest_version then
            if not silent then
                UIManager:show(Notification:new{
                    text = gettext("检查更新失败，请稍后重试"),
                    timeout = 2
                })
            end
            return
        end
        
        local current_version = get_current_version()
        
        if M.is_newer_version(current_version, latest_version) then
            local message = string.format(gettext("发现新版本: %s\n当前版本: %s\n\n是否下载并安装更新？"), latest_version, current_version)
            
            if release_notes and release_notes ~= "" then
                local notes = release_notes:sub(1, 200)
                message = message .. "\n\n更新内容:\n" .. notes
                if #release_notes > 200 then
                    message = message .. "..."
                end
            end
            
            UIManager:show(ConfirmBox:new{
                text = message,
                ok_text = gettext("更新"),
                cancel_text = gettext("稍后"),
                ok_callback = function()
                    M.perform_update(download_url, latest_version)
                end
            })
        else
            UIManager:show(ConfirmBox:new{
                text = string.format(gettext("当前已是最新版本 (%s)\n\n是否需要回退到之前的版本？"), current_version),
                ok_text = gettext("回退"),
                cancel_text = gettext("取消"),
                ok_callback = function()
                    UIManager:show(InfoMessage:new{
                        text = gettext("正在获取版本列表..."),
                        timeout = 1
                    })
                    
                    UIManager:scheduleIn(0.5, function()
                        local all_versions = M.get_all_versions()
                        if not all_versions or #all_versions == 0 then
                            UIManager:show(Notification:new{
                                text = gettext("获取版本列表失败"),
                                timeout = 2
                            })
                            return
                        end
                        show_version_choice(all_versions, current_version)
                    end)
                end
            })
        end
    end)
end

function M.perform_update(download_url, target_version)
    if not download_url then
        UIManager:show(Notification:new{
            text = gettext("未找到更新包下载地址"),
            timeout = 2
        })
        return
    end
    
    local version_text = target_version and (" (" .. target_version .. ")") or ""
    
    UIManager:show(Notification:new{
        text = gettext("正在下载更新") .. version_text .. "...",
        timeout = 1
    })
    
    local zip_path, err = M.download_update(download_url)
    
    if not zip_path then
        UIManager:show(Notification:new{
            text = err or gettext("下载失败，请稍后重试"),
            timeout = 3
        })
        return
    end
    
    UIManager:show(Notification:new{
        text = gettext("正在安装更新") .. version_text .. "...",
        timeout = 1
    })
    
    local success = M.install_update(zip_path)
    
    if success then
        UIManager:show(ConfirmBox:new{
            text = gettext("更新安装完成，需要重启 KOReader 才能生效。是否立即重启？"),
            ok_text = gettext("重启"),
            cancel_text = gettext("稍后"),
            ok_callback = function()
                UIManager:restartKOReader()
            end
        })
    else
        if is_android then
            local data_dir = DataStorage:getDataDir()
            if data_dir:sub(1, 2) == "./" then
                data_dir = data_dir:sub(3)
            elseif data_dir:sub(1, 1) == "." then
                data_dir = data_dir:sub(2)
            end
            UIManager:show(Notification:new{
                text = string.format(gettext("自动安装失败，请手动解压 %splugins/pinyin_enhancement.koplugin.zip 到 plugins 目录后重启"), data_dir),
                timeout = 5
            })
        else
            UIManager:show(Notification:new{
                text = gettext("安装失败，请手动更新"),
                timeout = 3
            })
        end
    end
end

return M