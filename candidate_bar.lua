--[[
    拼音候选词补丁 - V21（10个按键版本，7个候选词）
]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Font = require("ui/font")

logger.info("[CANDIDATE_BAR] 候选词栏模块加载 - V21（10个按键版本）")

local patched = false
local virtualkeyboard_hooked = false
local current_ime = nil
local current_inputbox = nil
local current_keyboard = nil
local code_map = nil

-- 保存候选栏按键的引用
local pinyin_key = nil
local prev_page_key = nil
local next_page_key = nil
local candidate_key_refs = {}

local current_pinyin = ""
local current_candidates = nil
local current_page = 1
local page_size = 7
local total_pages = 1

-- 是否启用拼音功能
local pinyin_enabled = false

-- 向前声明
local updateCandidateKeys
local enablePinyinFeatures
local disablePinyinFeatures

-- 辅助函数：更新 VirtualKey 的显示文本
local function updateVirtualKeyText(key, text)
    if not key then
        return false
    end
    key.label = text
    if key[1] and key[1][1] and key[1][1][1] and key[1][1][1].setText then
        key[1][1][1]:setText(text)
        return true
    end
    return false
end

-- 查找 IME
local function findIME()
    for k, v in pairs(package.loaded) do
        if k and (k:find("keyboardlayouts.zh_CN_keyboard") or k:find("zh_CN_keyboard")) and v and v.ime then
            return v.ime
        end
    end
    return nil
end

-- 查找码表
local function findCodeMap()
    local keyboard = require("ui/data/keyboardlayouts/zh_CN_keyboard")
    if keyboard and keyboard.code_map then
        code_map = keyboard.code_map
        return true
    end
    logger.warn("[CANDIDATE_BAR] 未找到码表")
    return false
end

-- 从码表获取候选词（同时支持字符串和table格式）
local function getCandidatesFromCodeMap(pinyin)
    if not pinyin or pinyin == "" or not code_map then
        return nil
    end
    
    local exact_candi = code_map[pinyin]
    if exact_candi then
        local word_list
        if type(exact_candi) == "table" then
            word_list = exact_candi
        elseif type(exact_candi) == "string" then
            word_list = {exact_candi}
        end
        if word_list and #word_list > 0 then
            return word_list
        end
    end
    
    local matches = {}
    for py, words in pairs(code_map) do
        if py:find("^" .. pinyin) then
            local word_list
            if type(words) == "table" then
                word_list = words
            elseif type(words) == "string" then
                word_list = {words}
            else
                goto continue
            end
            for _, word in ipairs(word_list) do
                if not matches[word] then
                    table.insert(matches, word)
                    matches[word] = true
                    if #matches >= page_size * 2 then break end
                end
            end
        end
        ::continue::
    end
    
    return #matches > 0 and matches or nil
end

-- 更新候选列表
local function updateCandidates()
    if not code_map or current_pinyin == "" then
        current_candidates = nil
        current_page = 1
        total_pages = 1
        return false
    end
    
    current_candidates = getCandidatesFromCodeMap(current_pinyin)
    
    if not current_candidates or #current_candidates == 0 then
        current_candidates = nil
        current_page = 1
        total_pages = 1
        return false
    end
    
    total_pages = math.ceil(#current_candidates / page_size)
    current_page = math.min(current_page, total_pages)
    current_page = math.max(current_page, 1)
    
    return true
end

-- 获取当前页候选词
local function getCurrentPageCandidates()
    if not current_candidates then
        return {}
    end
    
    local start_idx = (current_page - 1) * page_size + 1
    local end_idx = math.min(start_idx + page_size - 1, #current_candidates)
    
    local result = {}
    for i = start_idx, end_idx do
        table.insert(result, current_candidates[i])
    end
    return result
end

-- 提交候选词
local function commitCandidate(candidate)
    local inputbox = current_inputbox
    if not inputbox and current_ime then
        inputbox = current_ime._inputbox or current_ime.inputbox
        if inputbox then
            current_inputbox = inputbox
        end
    end
    
    if not inputbox or not inputbox.addChars then
        logger.warn("[CANDIDATE_BAR] 无法提交候选词")
        return false
    end
    
    inputbox:addChars(candidate)
    
    if current_ime and current_ime.clear_stack then
        current_ime:clear_stack()
    end
    
    current_pinyin = ""
    current_candidates = nil
    current_page = 1
    total_pages = 1
    
    updateCandidateKeys()
    
    return true
end

-- 清空拼音（拼音按键回调）
local function clearPinyin()
    if #current_pinyin > 0 then
        current_pinyin = ""
        current_candidates = nil
        current_page = 1
        total_pages = 1
        updateCandidateKeys()
        if current_keyboard then
            UIManager:setDirty(current_keyboard, function()
                return "ui", current_keyboard.dimen
            end)
        end
    end
end

-- 更新候选栏按键的显示
function updateCandidateKeys()
    if not pinyin_key then
        return
    end
    
    if not pinyin_enabled then
        -- 拼音功能未启用，清空候选栏显示
        updateVirtualKeyText(pinyin_key, "[]")
        updateVirtualKeyText(prev_page_key, " ")
        updateVirtualKeyText(next_page_key, " ")
        for i = 1, 7 do
            if candidate_key_refs[i] then
                updateVirtualKeyText(candidate_key_refs[i], "")
            end
        end
        return
    end
    
    -- 更新拼音显示
    local pinyin_text = "[]"
    if current_pinyin ~= "" then
        pinyin_text = "[" .. current_pinyin .. "]"
    end
    updateVirtualKeyText(pinyin_key, pinyin_text)
    
    -- 拼音按键的回调：清空拼音
    pinyin_key.callback = function()
        clearPinyin()
    end
    
    -- 更新上一页
    if total_pages > 1 then
        updateVirtualKeyText(prev_page_key, "◀")
        prev_page_key.callback = function()
            if current_page > 1 then
                current_page = current_page - 1
                updateCandidates()
                updateCandidateKeys()
                if current_keyboard then
                    UIManager:setDirty(current_keyboard, function()
                        return "ui", current_keyboard.dimen
                    end)
                end
            end
        end
    else
        updateVirtualKeyText(prev_page_key, " ")
        prev_page_key.callback = nil
    end
    
    -- 更新候选词
    local page_candidates = getCurrentPageCandidates()
    for i = 1, 7 do
        local key = candidate_key_refs[i]
        if key then
            if page_candidates and page_candidates[i] then
                local candi = page_candidates[i]
                updateVirtualKeyText(key, candi)
                key.callback = function()
                    commitCandidate(candi)
                end
            else
                updateVirtualKeyText(key, "")
                key.callback = nil
            end
        end
    end
    
    -- 更新下一页
    if total_pages > 1 and current_page < total_pages then
        updateVirtualKeyText(next_page_key, "▶")
        next_page_key.callback = function()
            if current_page < total_pages then
                current_page = current_page + 1
                updateCandidates()
                updateCandidateKeys()
                if current_keyboard then
                    UIManager:setDirty(current_keyboard, function()
                        return "ui", current_keyboard.dimen
                    end)
                end
            end
        end
    else
        updateVirtualKeyText(next_page_key, " ")
        next_page_key.callback = nil
    end
    
    if current_keyboard then
        UIManager:setDirty(current_keyboard, function()
            return "ui", current_keyboard.dimen
        end)
    end
end

-- 处理字母输入
local function handleAddChar(key)
    if not key then
        return false
    end
    
    -- 拼音功能未启用时，不拦截
    if not pinyin_enabled then
        return false
    end
    
    -- 如果 key 是 table，尝试获取 key.key 或 key.label
    if type(key) == "table" then
        if key.key then
            key = key.key
        elseif key.label then
            key = key.label
        else
            return false
        end
    end
    
    if (key >= "a" and key <= "z") or (key >= "A" and key <= "Z") then
        current_pinyin = current_pinyin .. key:lower()
        updateCandidates()
        updateCandidateKeys()
        return true
    end
    
    return false
end

-- 启用拼音功能
function enablePinyinFeatures()
    if pinyin_enabled then
        return
    end
    pinyin_enabled = true
    -- 重置状态
    current_pinyin = ""
    current_candidates = nil
    current_page = 1
    total_pages = 1
    updateCandidateKeys()
end

-- 禁用拼音功能
function disablePinyinFeatures()
    if not pinyin_enabled then
        return
    end
    pinyin_enabled = false
    -- 清空拼音状态
    current_pinyin = ""
    current_candidates = nil
    current_page = 1
    total_pages = 1
    updateCandidateKeys()
end

-- 修改键盘布局，添加候选栏行（10个按键：拼音+上一页+7个候选词+下一页）
local function addCandidateRowToKeyboardLayout()
    local keyboard = require("ui/data/keyboardlayouts/zh_CN_keyboard")
    if not keyboard or not keyboard.keys then
        logger.warn("[CANDIDATE_BAR] 无法获取键盘布局")
        return false
    end
    
    -- 检查是否已经添加过候选栏行
    if keyboard.keys[1] and keyboard.keys[1][1] and keyboard.keys[1][1].label == "[]" then
        return true
    end
    
    -- 创建候选栏行（10个按键，全部标准宽度）
    local candidate_row = {}
    
    -- 拼音显示（标准宽度，缩小字体）
    candidate_row[1] = { label = "[]", font_size = 16 }
    -- 上一页
    candidate_row[2] = { label = "◀" }
    -- 7个候选词
    for i = 1, 7 do
        candidate_row[2 + i] = { label = "" }
    end
    -- 下一页
    candidate_row[10] = { label = "▶" }
    
    -- 插入到 keys 数组的第一行
    table.insert(keyboard.keys, 1, candidate_row)
    
    return true
end

-- 保存候选栏按键的引用
local function saveCandidateKeyReferences(keyboard)
    if not keyboard or not keyboard.layout or not keyboard.layout[1] then
        logger.warn("[CANDIDATE_BAR] 无法获取键盘布局")
        return false
    end
    
    local candidate_row_widgets = keyboard.layout[1]
    if not candidate_row_widgets or #candidate_row_widgets < 10 then
        logger.warn("[CANDIDATE_BAR] 候选栏行按键不足")
        return false
    end
    
    pinyin_key = candidate_row_widgets[1]
    prev_page_key = candidate_row_widgets[2]
    for i = 1, 7 do
        candidate_key_refs[i] = candidate_row_widgets[2 + i]
    end
    next_page_key = candidate_row_widgets[10]
    
    return true
end

-- Hook VirtualKeyboard（带防重复）
local function hookVirtualKeyboard()
    if virtualkeyboard_hooked then
        return true
    end
    
    findCodeMap()
    current_ime = findIME()
    
    addCandidateRowToKeyboardLayout()
    
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    if not VirtualKeyboard then
        logger.warn("[CANDIDATE_BAR] 找不到 VirtualKeyboard")
        return false
    end
    
    local originalAddChar = VirtualKeyboard.addChar
    local originalDelChar = VirtualKeyboard.delChar
    local originalInit = VirtualKeyboard.init
    local originalSetKeyboardLayout = VirtualKeyboard.setKeyboardLayout
    
    -- hook addChar 处理字母输入
    VirtualKeyboard.addChar = function(self, key)
        if not handleAddChar(key) then
            originalAddChar(self, key)
        end
    end
    
    -- hook delChar 处理退格键
    VirtualKeyboard.delChar = function(self)
        -- 拼音功能启用时，优先删除拼音缓冲区中的字母
        if pinyin_enabled and #current_pinyin > 0 then
            current_pinyin = current_pinyin:sub(1, -2)
            updateCandidates()
            updateCandidateKeys()
            return
        else
            originalDelChar(self)
        end
    end
    
    -- hook setKeyboardLayout 监听布局切换
    VirtualKeyboard.setKeyboardLayout = function(self, layout)
        originalSetKeyboardLayout(self, layout)
        -- 判断切换后的布局是否为中文
        if layout == "zh_CN" or layout == "zh" then
            enablePinyinFeatures()
        else
            disablePinyinFeatures()
        end
    end
    
    VirtualKeyboard.init = function(self, ...)
        originalInit(self, ...)
        current_keyboard = self
        if self.inputbox then
            current_inputbox = self.inputbox
            if current_ime then
                current_ime._inputbox = self.inputbox
            end
        end
        saveCandidateKeyReferences(self)
        
        -- 判断当前布局是否为中文
        local current_layout = self:getKeyboardLayout()
        if current_layout == "zh_CN" or current_layout == "zh" then
            enablePinyinFeatures()
        else
            disablePinyinFeatures()
        end
    end
    
    virtualkeyboard_hooked = true
    logger.info("[CANDIDATE_BAR] VirtualKeyboard hook 成功")
    return true
end

-- 补丁入口
local function applyPatch()
    if patched then
        return
    end
    
    if hookVirtualKeyboard() then
        patched = true
        logger.info("[CANDIDATE_BAR] 补丁安装完成")
    else
        logger.warn("[CANDIDATE_BAR] 补丁安装失败")
    end
end

UIManager:scheduleIn(1, applyPatch)
return true