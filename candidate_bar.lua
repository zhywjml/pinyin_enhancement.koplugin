--[[
    拼音候选词（10个按键版本，5个候选词，有序候选词）
]]

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local Font = require("ui/font")

logger.info("[CANDIDATE_BAR] 候选词栏模块加载（有序候选词）")

local patched = false
local virtualkeyboard_hooked = false
local current_ime = nil
local current_inputbox = nil
local current_keyboard = nil
local code_map = nil

-- 保存候选栏按键的引用
local pinyin_key = nil
local cursor_left_key = nil
local cursor_right_key = nil
local prev_page_key = nil
local next_page_key = nil
local candidate_key_refs = {}

local current_pinyin = ""
local current_candidates = nil
local current_page = 1
local page_size = 5
local total_pages = 1
local cursor_pos = 1  -- 当前拼音光标位置，1-indexed，范围 1..#pinyin+1

-- 是否启用拼音功能
local pinyin_enabled = false

-- 向前声明（实际定义使用 local function，一致绑定）
local updateCandidateKeys
local enablePinyinFeatures
local disablePinyinFeatures

-- 辅助：转义 Lua pattern 特殊字符（完整包含所有魔法字符: ( ) . % + - * ? [ ] ^ $）
local function escapePattern(str)
    return (str:gsub("([%.%%%+%-%*%?%[%]%^%$%(%)])", "%%%1"))
end

-- UTF-8 匹配模式：匹配一个完整的 Unicode 字符（ASCII 或多字节）
-- 单字节 0x01-0x7F | 首字节 0xC2-0xF4 + 1-3 个续字节 0x80-0xBF
local UTF8_CHAR_PATTERN = "[\1-\127\194-\244][\128-\191]*"

-- 提取字符串的第一个 UTF-8 字符
local function firstUTF8Char(str)
    if not str or #str == 0 then return "" end
    return str:match(UTF8_CHAR_PATTERN) or ""
end

-- 模糊音规则表（前缀交换 + 后缀交换）
local fuzzy_rules = {
    -- 平翘舌（前缀）
    {type = "prefix", match = "zh", fuzzy = "z"},
    {type = "prefix", match = "z", fuzzy = "zh"},
    {type = "prefix", match = "ch", fuzzy = "c"},
    {type = "prefix", match = "c", fuzzy = "ch"},
    {type = "prefix", match = "sh", fuzzy = "s"},
    {type = "prefix", match = "s", fuzzy = "sh"},
    -- l/n, r/l, f/h（前缀）
    {type = "prefix", match = "l", fuzzy = "n"},
    {type = "prefix", match = "n", fuzzy = "l"},
    {type = "prefix", match = "r", fuzzy = "l"},
    {type = "prefix", match = "f", fuzzy = "h"},
    {type = "prefix", match = "h", fuzzy = "f"},
    -- 前后鼻音（后缀）
    {type = "suffix", match = "en", fuzzy = "eng"},
    {type = "suffix", match = "eng", fuzzy = "en"},
    {type = "suffix", match = "in", fuzzy = "ing"},
    {type = "suffix", match = "ing", fuzzy = "in"},
    {type = "suffix", match = "an", fuzzy = "ang"},
    {type = "suffix", match = "ang", fuzzy = "an"},
    {type = "suffix", match = "ou", fuzzy = "o"},
    {type = "suffix", match = "uo", fuzzy = "o"},
    {type = "suffix", match = "ong", fuzzy = "eng"},
    {type = "suffix", match = "iu", fuzzy = "iou"},
    {type = "suffix", match = "ui", fuzzy = "uei"},
}

-- 检查模糊音是否启用
local function isFuzzyEnabled()
    local enabled = G_reader_settings:readSetting("pinyin_fuzzy_enabled")
    if enabled == nil then
        G_reader_settings:saveSetting("pinyin_fuzzy_enabled", false)
        return false
    end
    return enabled
end

-- 生成模糊音变体
local function generateFuzzyVariants(pinyin)
    if not isFuzzyEnabled() then
        return {}
    end
    local seen = {}
    local variants = {}
    for _, rule in ipairs(fuzzy_rules) do
        if rule.type == "prefix" then
            if pinyin:sub(1, #rule.match) == rule.match then
                local v = rule.fuzzy .. pinyin:sub(#rule.match + 1)
                if v ~= pinyin and not seen[v] then
                    seen[v] = true
                    table.insert(variants, v)
                end
            end
        elseif rule.type == "suffix" then
            if pinyin:sub(-#rule.match) == rule.match then
                local v = pinyin:sub(1, -#rule.match - 1) .. rule.fuzzy
                if v ~= pinyin and not seen[v] then
                    seen[v] = true
                    table.insert(variants, v)
                end
            end
        end
    end
    return variants
end

-- 辅助函数：更新 VirtualKey 的显示文本
local function updateVirtualKeyText(key, text)
    if not key then
        return false
    end
    key.label = text
    
    -- 方法1：_text_widget 直接引用（最可靠，不受 widget 层级影响）
    if key._text_widget and key._text_widget.setText then
        key._text_widget:setText(text)
        return true
    end
    
    -- 方法2：硬编码路径 fallback（标准 VirtualKey widget 层级）
    if key[1] and key[1][1] and key[1][1][1] and key[1][1][1].setText then
        key[1][1][1]:setText(text)
        return true
    end
    
    -- 方法3：递归遍历 widget 树寻找 setText
    local function findTextWidget(widget, depth)
        if not widget or depth > 6 then
            return nil
        end
        if widget.setText then
            return widget
        end
        for i = 1, math.min(10, #widget) do
            local found = findTextWidget(widget[i], depth + 1)
            if found then
                return found
            end
        end
        return nil
    end
    
    local text_widget = findTextWidget(key, 0)
    if text_widget then
        text_widget:setText(text)
        return true
    end
    
    -- 所有方法均失败，依赖下次重绘刷新 label
    return false
end

-- 查找 IME（直接从键盘布局获取）
local function findIME()
    local ok, keyboard = pcall(require, "ui/data/keyboardlayouts/zh_CN_keyboard")
    if ok and keyboard and keyboard.ime then
        return keyboard.ime
    end
    return nil
end

-- 直接加载码表数据
local function loadCodeMapDirectly()
    local ok, data = pcall(require, "ui/data/keyboardlayouts/zh_pinyin_data")
    if ok and data and type(data) == "table" then
        code_map = data
        logger.info("[CANDIDATE_BAR] 加载码表成功")
        return true
    end
    
    logger.warn("[CANDIDATE_BAR] 无法加载码表，拼音功能将不可用")
    return false
end

-- 从码表获取候选词（按拼音长度降序 + 字典序）
-- 模糊音启用时，额外搜索模糊变体
local function getCandidatesFromCodeMap(pinyin)
    if not pinyin or pinyin == "" or not code_map then
        return nil
    end
    
    -- 收集候选词（去重）
    local result_map = {}  -- { [word] = {py = pinyin, word = word, fuzzy = false} }
    local insert_order = 0  -- 追踪插入顺序，用于稳定排序
    
    -- 辅助：搜索给定拼音并收集结果
    local function collectFrom(py, is_fuzzy)
        -- 精确匹配
        local exact = code_map[py]
        if exact then
            if type(exact) == "table" then
                for _, w in ipairs(exact) do
                    if w and not result_map[w] then
                        insert_order = insert_order + 1
                        result_map[w] = {py = py, word = w, fuzzy = is_fuzzy, order = insert_order}
                    end
                end
            elseif type(exact) == "string" then
                if #py > 6 then
                    -- 多音节拼音（如 "zhongguo"="中国"），保持词组完整性
                    if not result_map[exact] then
                        insert_order = insert_order + 1
                        result_map[exact] = {py = py, word = exact, fuzzy = is_fuzzy, order = insert_order}
                    end
                else
                    -- 单音节拼音（如 "d"="大但得地对"），逐 UTF-8 字符拆分
                    for w in exact:gmatch(UTF8_CHAR_PATTERN) do
                        if not result_map[w] then
                            insert_order = insert_order + 1
                            result_map[w] = {py = py, word = w, fuzzy = is_fuzzy, order = insert_order}
                        end
                    end
                end
            end
        end
        
        -- 前缀匹配
        local pattern = "^" .. escapePattern(py)
        for code, words in pairs(code_map) do
            if code:find(pattern) then
                local first_word
                if type(words) == "table" then
                    first_word = words[1]
                elseif type(words) == "string" then
                    first_word = firstUTF8Char(words)
                else
                    goto skip
                end
                if first_word and not result_map[first_word] then
                    insert_order = insert_order + 1
                    result_map[first_word] = {py = code, word = first_word, fuzzy = is_fuzzy, order = insert_order}
                end
            end
            ::skip::
        end
    end
    
    -- 第1步：从原拼音搜索
    collectFrom(pinyin, false)
    
    -- 第2步：从模糊音变体搜索（仅当启用时）
    local fuzzy_variants = generateFuzzyVariants(pinyin)
    for _, variant in ipairs(fuzzy_variants) do
        collectFrom(variant, true)
    end
    
    if not next(result_map) then
        return nil
    end
    
    -- 计算每条结果的匹配等级
    -- 等级 0: 原始拼音精确匹配（最优先）
    -- 等级 1: 原始拼音前缀匹配
    -- 等级 2: 模糊拼音精确匹配
    -- 等级 3: 模糊拼音前缀匹配
    for _, v in pairs(result_map) do
        if not v.fuzzy then
            if v.py == pinyin then
                v.rank = 0
            else
                v.rank = 1
            end
        else
            local is_exact = false
            for _, fv in ipairs(fuzzy_variants) do
                if v.py == fv then
                    is_exact = true
                    break
                end
            end
            v.rank = is_exact and 2 or 3
        end
    end
    
    -- 排序：等级升序 → 拼音长度降序 → 字典序 → 插入顺序（稳定同等级候选）
    local sorted = {}
    for _, v in pairs(result_map) do
        table.insert(sorted, v)
    end
    table.sort(sorted, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        if #a.py ~= #b.py then
            return #a.py > #b.py
        end
        if a.py ~= b.py then
            return a.py < b.py
        end
        return a.order < b.order  -- 稳定排序：按插入顺序
    end)
    
    -- 提取结果（最多 page_size * 3 个，模糊结果可能更多）
    local result = {}
    for _, v in ipairs(sorted) do
        table.insert(result, v.word)
        if #result >= page_size * 3 then
            break
        end
    end
    
    return result
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
    cursor_pos = 1
    current_candidates = nil
    current_page = 1
    total_pages = 1
    
    updateCandidateKeys()
    
    return true
end

-- 清空拼音
local function clearPinyin()
    if #current_pinyin > 0 then
        current_pinyin = ""
        cursor_pos = 1
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
updateCandidateKeys = function()
    if not pinyin_key then
        return
    end
    
    if not pinyin_enabled then
        updateVirtualKeyText(pinyin_key, "[]")
        if cursor_left_key then updateVirtualKeyText(cursor_left_key, " ") end
        if cursor_right_key then updateVirtualKeyText(cursor_right_key, " ") end
        updateVirtualKeyText(prev_page_key, " ")
        updateVirtualKeyText(next_page_key, " ")
        for i = 1, 5 do
            if candidate_key_refs[i] then
                updateVirtualKeyText(candidate_key_refs[i], "")
            end
        end
        return
    end
    
    -- 更新拼音显示（含光标位置）
    local function getPinyinDisplay()
        if current_pinyin == "" then
            return "[]"
        end
        if cursor_pos > #current_pinyin then
            return "[" .. current_pinyin .. "|]"
        elseif cursor_pos <= 1 then
            return "[|" .. current_pinyin .. "]"
        else
            return "[" .. current_pinyin:sub(1, cursor_pos - 1) .. "|" .. current_pinyin:sub(cursor_pos) .. "]"
        end
    end
    
    local pinyin_text = getPinyinDisplay()
    updateVirtualKeyText(pinyin_key, pinyin_text)
    pinyin_key.callback = function()
        clearPinyin()
    end
    
    -- 光标左移按钮
    if #current_pinyin > 0 and cursor_pos > 1 then
        updateVirtualKeyText(cursor_left_key, "◄")
        cursor_left_key.callback = function()
            if cursor_pos > 1 then
                cursor_pos = cursor_pos - 1
                updateCandidateKeys()
                if current_keyboard then
                    UIManager:setDirty(current_keyboard, function()
                        return "ui", current_keyboard.dimen
                    end)
                end
            end
        end
    else
        updateVirtualKeyText(cursor_left_key, " ")
        cursor_left_key.callback = nil
    end
    
    -- 光标右移按钮
    if #current_pinyin > 0 and cursor_pos <= #current_pinyin then
        updateVirtualKeyText(cursor_right_key, "►")
        cursor_right_key.callback = function()
            if cursor_pos <= #current_pinyin then
                cursor_pos = cursor_pos + 1
                updateCandidateKeys()
                if current_keyboard then
                    UIManager:setDirty(current_keyboard, function()
                        return "ui", current_keyboard.dimen
                    end)
                end
            end
        end
    else
        updateVirtualKeyText(cursor_right_key, " ")
        cursor_right_key.callback = nil
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
    -- 闭包工厂：确保每个回调捕获独立的 candi 值（兼容 Lua 5.1）
    local function makeCandidateCallback(candi)
        return function()
            commitCandidate(candi)
        end
    end
    for i = 1, 5 do
        local key = candidate_key_refs[i]
        if key then
            if page_candidates and page_candidates[i] then
                local candi = page_candidates[i]
                updateVirtualKeyText(key, candi)
                key.callback = makeCandidateCallback(candi)
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
    
    if not pinyin_enabled then
        return false
    end
    
    if not code_map then
        return false
    end
    
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
        local ch = key:lower()
        -- 在光标位置插入
        local left = current_pinyin:sub(1, cursor_pos - 1)
        local right = current_pinyin:sub(cursor_pos)
        current_pinyin = left .. ch .. right
        cursor_pos = cursor_pos + 1
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
    current_pinyin = ""
    cursor_pos = 1
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
    current_pinyin = ""
    cursor_pos = 1
    current_candidates = nil
    current_page = 1
    total_pages = 1
    updateCandidateKeys()
end

-- 修改键盘布局，添加候选栏行
local function addCandidateRowToKeyboardLayout()
    local keyboard = require("ui/data/keyboardlayouts/zh_CN_keyboard")
    if not keyboard or not keyboard.keys then
        logger.warn("[CANDIDATE_BAR] 无法获取键盘布局")
        return false
    end
    
    if keyboard.keys[1] and keyboard.keys[1][1] and keyboard.keys[1][1].label == "[]" then
        if #keyboard.keys[1] == 10 then
            return true  -- 已是新版 10 键布局
        end
        -- 旧版 12 键布局，移除后重新添加 10 键（用 table.remove 避免数组空洞）
        table.remove(keyboard.keys, 1)
    end
    
    local candidate_row = {}
    
    -- 10键布局，与 QWERTY 行宽一致
    candidate_row[1]  = { label = "[]", font_size = 16 }  -- 拼音显示
    candidate_row[2]  = { label = "◄" }                    -- 光标左移
    candidate_row[3]  = { label = "►" }                    -- 光标右移
    candidate_row[4]  = { label = "◀" }                    -- 候选翻左
    for i = 1, 5 do
        -- font="scfont" 确保中文字符正确渲染
        -- 初始 label 为空格确保 TextWidget 被创建，之后会被 updateCandidateKeys 覆盖
        candidate_row[4 + i] = { label = " ", font_size = 20, font = "scfont" }
    end
    candidate_row[10] = { label = "▶" }                    -- 候选翻右
    
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
    cursor_left_key = candidate_row_widgets[2]
    cursor_right_key = candidate_row_widgets[3]
    prev_page_key = candidate_row_widgets[4]
    for i = 1, 5 do
        candidate_key_refs[i] = candidate_row_widgets[4 + i]
    end
    next_page_key = candidate_row_widgets[10]
    
    return true
end

-- Hook VirtualKeyboard
local function hookVirtualKeyboard()
    if virtualkeyboard_hooked then
        return true
    end
    
    -- 加载码表
    if not loadCodeMapDirectly() then
        logger.warn("[CANDIDATE_BAR] 码表加载失败，拼音功能将不可用")
    end
    
    current_ime = findIME()
    
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    if not VirtualKeyboard then
        logger.warn("[CANDIDATE_BAR] 找不到 VirtualKeyboard")
        return false
    end
    
    local originalAddChar = VirtualKeyboard.addChar
    local originalDelChar = VirtualKeyboard.delChar
    local originalInit = VirtualKeyboard.init
    local originalSetKeyboardLayout = VirtualKeyboard.setKeyboardLayout
    
    VirtualKeyboard.addChar = function(self, key)
        if not handleAddChar(key) then
            originalAddChar(self, key)
        end
    end
    
    VirtualKeyboard.delChar = function(self)
        if pinyin_enabled and #current_pinyin > 0 and cursor_pos > 1 then
            -- 删除光标前的字符
            local left = current_pinyin:sub(1, cursor_pos - 2)
            local right = current_pinyin:sub(cursor_pos)
            current_pinyin = left .. right
            cursor_pos = cursor_pos - 1
            updateCandidates()
            updateCandidateKeys()
            return
        else
            originalDelChar(self)
        end
    end
    
    VirtualKeyboard.setKeyboardLayout = function(self, layout)
        originalSetKeyboardLayout(self, layout)
        if layout == "zh_CN" or layout == "zh" then
            enablePinyinFeatures()
        else
            disablePinyinFeatures()
        end
    end
    
    VirtualKeyboard.init = function(self, ...)
        -- 关键：在 originalInit 处理 keys 之前添加候选行，避免时序竞态
        addCandidateRowToKeyboardLayout()
        originalInit(self, ...)
        current_keyboard = self
        if self.inputbox then
            current_inputbox = self.inputbox
            if current_ime then
                current_ime._inputbox = self.inputbox
            end
        end
        saveCandidateKeyReferences(self)
        
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
