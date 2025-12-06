# AskGPT 插件开发指南

这是一个全面的AskGPT插件开发和理解指南，帮助开发者深入了解项目架构、代码结构和开发方法。

## 📚 目录

- [项目概述](#项目概述)
- [项目架构](#项目架构)
- [Lua语言基础](#lua语言基础)
- [代码文件详解](#代码文件详解)
- [交互逻辑设计](#交互逻辑设计)
- [代码阅读方法](#代码阅读方法)
- [开发和调试](#开发和调试)
- [常见修改任务](#常见修改任务)
- [学习路径](#学习路径)

---

## 🎯 项目概述

AskGPT是一个为KOReader电子书阅读器开发的AI插件，它允许用户在阅读时高亮文本并向AI询问相关问题。插件已从最初的OpenAI ChatGPT集成演进为主要使用自定义Reader AI FastAPI后端，并增强了中文语言支持。

### 核心功能
1. **文本高亮交互** - 选中文本后显示"Ask ChatGPT"选项
2. **智能问答** - 字典查询、文本摘要、内容翻译
3. **多语言支持** - 完整的中文本地化和国际化支持
4. **网络弹性** - 自动重试机制和优雅的错误处理
5. **用户友好界面** - 可滚动的响应查看器和交互式按钮

---

## 🏗️ 项目架构

### 文件组织结构
```
askgpt.koplugin/
├── main.lua                    # 🚪 插件入口点和生命周期管理
├── dialogs.lua                 # 🎭 UI交互协调器和工作流管理
├── gpt_query.lua              # 🌐 网络通信模块和AI服务客户端
├── chatgptviewer.lua          # 📱 AI响应显示界面
├── _meta.lua                  # 📋 插件元信息和版本定义
├── configuration.lua          # ⚙️ 用户运行时配置
├── configuration.lua.example  # 📝 配置模板和示例
├── update_checker.lua         # 🔄 自动更新检查器
└── CLAUDE.md                  # 📖 项目开发文档
```

### 模块职责划分

| 模块 | 主要职责 | 关键函数/类 |
|------|----------|-------------|
| `main.lua` | 插件入口、初始化、菜单注册 | `AskGPT:init()`, `validateConfiguration()` |
| `dialogs.lua` | UI工作流协调、用户交互管理 | `showChatGPTDialog()`, `performLookup()` |
| `gpt_query.lua` | 网络通信、API调用、重试机制 | `dictionaryLookup()`, `summarizeContent()` |
| `chatgptviewer.lua` | 响应显示、界面组件、用户交互 | `ChatGPTViewer:init()`, `askAnotherQuestion()` |

### 数据流程图
```
用户高亮文本
    ↓
KOReader显示菜单 (main.lua)
    ↓
用户点击"Ask ChatGPT"
    ↓
显示输入对话框 (dialogs.lua)
    ↓
发送API请求 (gpt_query.lua)
    ↓
显示AI响应 (chatgptviewer.lua)
    ↓
用户交互：再次提问/添加笔记
```

---

## 📖 Lua语言基础

### 基本语法特点
```lua
-- 注释以双短横线开始
local variable = "本地变量"    -- 建议使用local
global_var = "全局变量"       -- 避免使用全局变量

-- 表（类似对象/字典/数组）
local config = {
    name = "askgpt",           -- 字符串键
    version = 1.01,            -- 数值
    features = {               -- 嵌套表
        translate = true
    },
    [1] = "第一个元素",         -- 数组风格
    [2] = "第二个元素"
}

-- 函数定义
local function processText(input)
    return input .. " processed"
end

-- 条件语句
if condition then
    -- 执行代码
elseif other_condition then
    -- 其他情况
else
    -- 默认情况
end
```

### 模块系统
```lua
-- 引入模块
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local _ = require("gettext")  -- 国际化函数

-- 定义模块
local MyModule = {}

function MyModule.publicFunction()
    -- 公开函数
end

local function privateFunction()
    -- 私有函数
end

-- 导出模块
return MyModule
```

### 面向对象模式
```lua
-- 类定义（继承InputContainer）
local ChatGPTViewer = InputContainer:extend {
    title = nil,        -- 属性
    text = nil,
    width = nil
}

-- 方法定义（使用冒号语法）
function ChatGPTViewer:init()
    -- self 自动传入，指向当前实例
    self.width = self.width or Screen:getWidth() - 30
end

-- 创建实例
local viewer = ChatGPTViewer:new{
    title = "AI Response",
    text = "Hello world"
}
```

---

## 📄 代码文件详解

### main.lua - 插件入口点

**核心功能**：
- 插件生命周期管理
- 高亮菜单注册
- 配置验证和网络检查
- 错误处理和用户反馈

**关键代码分析**：
```lua
-- 第58-90行：插件初始化函数
function AskGPT:init()
  -- 注册高亮动作到KOReader菜单系统
  self.ui.highlight:addToHighlightDialog("askgpt_ChatGPT", function(_reader_highlight_instance)
    return {
      text = _("Ask ChatGPT"),        -- 菜单显示文字
      enabled = Device:hasClipboard(), -- 功能可用性检查
      callback = function()           -- 点击回调函数
        -- 网络和配置检查
        if not checkNetworkAndConfig() then
          return
        end
        -- 调用主对话框
        showChatGPTDialog(self.ui, _reader_highlight_instance)
      end,
    }
  end)
end
```

**配置验证机制**：
```lua
-- 第19-32行：配置验证函数
local function validateConfiguration()
  -- 使用pcall保护调用，防止配置文件错误
  local config_success, CONFIGURATION = pcall(function()
    return require("configuration")
  end)

  if not config_success then
    return false, "configuration.lua not found"
  end

  -- 检查必要的API端点配置
  if not CONFIGURATION.base_url and not CONFIGURATION.reader_ai_base_url then
    return false, "No API endpoint configured"
  end

  return true, CONFIGURATION
end
```

### dialogs.lua - UI交互协调器

**核心功能**：
- 管理用户输入对话框
- 协调AI服务调用
- 格式化和显示AI响应
- 错误处理和用户反馈

**主要函数分析**：
```lua
-- 第681行：主对话框函数
local function showChatGPTDialog(ui, highlight_source)
  -- 1. 提取高亮文本和上下文
  local highlightedText, highlightedContext = extract_highlight_data(highlight_source)

  -- 2. 获取文档元数据
  local props = ui.document and ui.document:getProps() or {}
  local title = props.title or _("Unknown Title")
  local author = props.authors or _("Unknown Author")

  -- 3. 定义内部工作流函数
  local function startLookup(options)
    -- 字典查询逻辑
  end

  local function startSummarize(options)
    -- 文本摘要逻辑
  end

  -- 4. 创建和显示输入对话框
  -- ...
end
```

**错误处理策略**：
```lua
-- 第563-578行：统一错误处理
local function performLookup(request_opts)
  local ok, response = pcall(ReaderAI.dictionaryLookup, request_opts)
  if not ok then
    local error_msg = tostring(response)
    -- 分类错误处理
    if error_msg:match("timeout") then
      showError(_("网络请求超时，请检查网络连接后重试。"))
    elseif error_msg:match("connection") then
      showError(_("无法连接到AI服务，请检查网络设置。"))
    elseif error_msg:match("attempts") then
      showError(_("网络连接失败，已重试" .. MAX_RETRY_ATTEMPTS .. "次。"))
    else
      showError(_("字典查询失败：") .. error_msg)
    end
    return nil
  end
  return response
end
```

### gpt_query.lua - 网络通信模块

**核心功能**：
- HTTP/HTTPS请求处理
- 自动重试机制
- JSON数据编码/解码
- 超时和错误处理

**网络请求实现**：
```lua
-- 核心请求函数结构
local function makeRequest(url, data, headers, timeout)
    -- 1. 准备请求数据
    local json_data = json.encode(data)

    -- 2. 设置请求头
    local request_headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = string.len(json_data),
        -- 自定义头部
    }

    -- 3. 执行HTTP请求
    local response_body = {}
    local request_options = {
        method = "POST",
        url = url,
        source = ltn12.source.string(json_data),
        sink = ltn12.sink.table(response_body),
        headers = request_headers
    }

    -- 4. 处理响应
    local ok, status, headers = http.request(request_options)
    return ok, status, table.concat(response_body)
end
```

**重试机制**：
```lua
-- 自动重试逻辑
local function requestWithRetry(url, data, max_attempts, delay)
    for attempt = 1, max_attempts do
        local success, response = makeRequest(url, data)

        if success then
            return response
        end

        if attempt < max_attempts then
            socket.sleep(delay)  -- 重试延迟
        end
    end

    error("Max retry attempts exceeded")
end
```

### chatgptviewer.lua - 响应显示界面

**核心功能**：
- 可滚动文本显示
- 交互式按钮界面
- 文本选择和复制
- 继续对话功能

**UI组件结构**：
```lua
-- 第86行开始：UI初始化
function ChatGPTViewer:init()
    -- 1. 计算窗口尺寸
    self.width = self.width or Screen:getWidth() - Screen:scaleBySize(30)
    self.height = self.height or Screen:getHeight() - Screen:scaleBySize(30)

    -- 2. 创建标题栏
    local titlebar = TitleBar:new{
        title = self.title,
        width = self.width,
        -- ...
    }

    -- 3. 创建滚动文本组件
    self.scroll_text_w = ScrollTextWidget:new{
        text = self.text,
        face = self.text_face,         -- 字体配置
        width = text_width,
        height = text_height,
        scroll_callback = self._buttons_scroll_callback,
    }

    -- 4. 创建按钮组
    local default_buttons = {
        {
            text = _("Ask Another Question"),
            callback = function() self:askAnotherQuestion() end,
        },
        -- 滚动控制按钮
        -- 添加笔记按钮
    }

    -- 5. 组装最终界面
    self.frame = FrameContainer:new{
        VerticalGroup:new{
            titlebar,           -- 标题栏
            self.textw,         -- 文本区域
            self.button_table,  -- 按钮区域
        }
    }
end
```

**按钮状态管理**：
```lua
-- 第195-212行：智能滚动按钮控制
local function _buttons_scroll_callback(low, high)
    -- 顶部按钮状态
    if prev_at_top and low > 0 then
        button_update("top", true)    -- 启用"到顶部"按钮
        prev_at_top = false
    elseif not prev_at_top and low <= 0 then
        button_update("top", false)   -- 禁用"到顶部"按钮
        prev_at_top = true
    end

    -- 底部按钮状态
    if prev_at_bottom and high < 1 then
        button_update("bottom", true)  -- 启用"到底部"按钮
        prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
        button_update("bottom", false) -- 禁用"到底部"按钮
        prev_at_bottom = true
    end
end
```

---

## 🔄 交互逻辑设计

### 整体交互流程

1. **入口交互**（main.lua:58-90）
   - 用户高亮文本
   - KOReader显示"Ask ChatGPT"选项
   - 前置检查：网络连接、配置文件、设备支持

2. **主对话流程**（dialogs.lua:681-750）
   - 自动提取文本和上下文
   - 显示用户输入对话框
   - 提供多种操作选项：询问、摘要、翻译

3. **AI处理流程**（gpt_query.lua）
   - 构建API请求
   - 执行网络调用（支持重试）
   - 解析和验证响应

4. **结果显示流程**（chatgptviewer.lua）
   - 格式化显示内容
   - 提供交互功能：滚动、继续提问、添加笔记

### 用户体验设计亮点

**渐进式加载体验**：
```lua
-- 异步加载，避免界面冻结
local loading = showLoadingDialog()
UIManager:scheduleIn(0.1, function()
    -- 处理AI请求
    UIManager:close(loading)
    -- 显示结果
end)
```

**智能状态感知**：
- 滚动位置实时控制按钮状态
- 网络状态检测和用户提醒
- 动态错误消息和解决建议

**多功能按钮设计**：
- "再问一个问题" - 保持上下文的连续对话
- "添加笔记" - 集成KOReader笔记系统
- 智能滚动控制 - 精确导航长文本

### 错误处理策略

**分层错误消息**：
- 技术错误转换为用户友好的中文提示
- 每个错误提供明确的解决建议
- 不同错误类型的针对性处理

**网络弹性设计**：
- 3次自动重试机制
- 1000秒长超时适应慢速API
- 优雅降级保持应用稳定

---

## 📖 代码阅读方法

### 方法1：按功能模块读

**推荐阅读顺序**：
1. **_meta.lua** → 了解插件基本信息和版本
2. **main.lua** → 理解插件入口逻辑和初始化流程
3. **dialogs.lua** → 掌握核心交互逻辑和工作流
4. **gpt_query.lua** → 理解网络通信和API集成
5. **chatgptviewer.lua** → 学习UI组件设计和用户交互

### 方法2：按数据流读

**数据流追踪**：
1. 从用户操作开始（高亮文本）
2. 追踪事件传递（main.lua:callback）
3. 跟进函数调用（dialogs.lua:showChatGPTDialog）
4. 理解处理逻辑（网络请求、响应处理）
5. 最终UI显示（chatgptviewer.lua）

### 方法3：按问题域读

**特定功能查找**：
- **字体设置** → 搜索 `Font`、`text_face`、`getFace`
- **网络处理** → 搜索 `http`、`https`、`timeout`、`retry`
- **错误处理** → 搜索 `pcall`、`error`、`showError`
- **UI交互** → 搜索 `callback`、`button`、`gesture`
- **配置系统** → 搜索 `CONFIGURATION`、`require.*configuration`

### 代码注释解读技巧

**中文注释模式**：
```lua
--[[--
函数功能的详细说明
多行文档注释，包含：
- 功能描述
- 参数说明
- 返回值说明
- 使用示例

@param parameter_name type 参数说明
@return type 返回值说明
]]
```

**内联注释**：
```lua
local timeout = 1000  -- 网络超时设置（秒）
```

---

## 🔧 开发和调试

### 调试技巧

**1. 添加调试输出**：
```lua
print("调试信息：", variable)              -- 输出到KOReader日志
print("函数调用：", function_name, param)  -- 跟踪函数调用
```

**2. 使用pcall进行安全调试**：
```lua
local success, result = pcall(function()
    -- 可能出错的代码
    return risky_operation()
end)

if not success then
    print("错误信息：", result)
else
    print("成功结果：", result)
end
```

**3. 条件调试输出**：
```lua
local DEBUG = true  -- 调试开关

local function debug_print(...)
    if DEBUG then
        print("[DEBUG]", ...)
    end
end

debug_print("变量值：", variable)
```

### 开发环境设置

**文件同步到设备**：
```bash
# 同步到KOReader设备
rsync -av --delete . user@device:/mnt/onboard/koreader/plugins/askgpt.koplugin/

# 本地测试（如果有KOReader桌面版）
cp -r . ~/.local/share/koreader/plugins/askgpt.koplugin/
```

**代码质量检查**：
```bash
# 安装luacheck
sudo apt-get install luacheck  # Ubuntu/Debian
brew install luacheck          # macOS

# 运行代码检查
luacheck *.lua
luacheck --globals Device UIManager _ main.lua  # 忽略特定全局变量
```

### 配置文件管理

**开发配置示例**：
```lua
local CONFIGURATION = {
    -- 开发服务器配置
    reader_ai_base_url = "http://localhost:8000",

    -- 调试选项
    debug = {
        enabled = true,
        log_requests = true,
        log_responses = false,
    },

    -- 开发功能开关
    features = {
        translate_to = "Chinese",
        experimental_features = true,
    },

    -- 开发网络设置
    network = {
        timeout = 5,        -- 更短的超时用于快速测试
        retry_attempts = 1, -- 减少重试次数
    }
}
```

---

## ⚙️ 常见修改任务

### 字体和UI调整

**修改字体大小**：
```lua
-- chatgptviewer.lua:66
text_face = Font:getFace("infofont"),      -- 标准大小
text_face = Font:getFace("cfont"),         -- 较大字体
text_face = Font:getFace("infofont", 18),  -- 指定18pt
```

**调整界面尺寸**：
```lua
-- chatgptviewer.lua:95-96
self.width = Screen:getWidth() - Screen:scaleBySize(20)   -- 更宽
self.height = Screen:getHeight() - Screen:scaleBySize(20) -- 更高
```

**修改按钮文字**：
```lua
-- chatgptviewer.lua:218
text = _("Ask Another Question"),  -- 修改按钮文字
```

### 功能扩展

**添加新按钮**：
```lua
-- chatgptviewer.lua:215-250 在default_buttons中添加
{
    text = _("Custom Action"),
    id = "custom_action",
    callback = function()
        self:customAction()  -- 自定义功能
    end,
}
```

**添加新API端点**：
```lua
-- gpt_query.lua 添加新函数
function ReaderAI.customAnalysis(options)
    local url = getApiUrl("custom_analysis_path")
    local response = makeApiRequest(url, {
        text = options.text,
        type = options.analysis_type
    })
    return response
end
```

**扩展配置选项**：
```lua
-- configuration.lua
local CONFIGURATION = {
    -- 新功能配置
    custom_features = {
        analysis_depth = "deep",
        custom_prompts = {
            summary = "请用中文总结以下内容",
            translate = "请翻译成中文"
        }
    }
}
```

### 网络和API修改

**修改超时设置**：
```lua
-- gpt_query.lua 修改默认超时
local DEFAULT_TIMEOUT = 30  -- 30秒超时

-- 或在配置文件中
network = {
    timeout = 30,
    retry_attempts = 5,
    retry_delay = 3,
}
```

**添加新的API后端支持**：
```lua
-- gpt_query.lua 添加新的API适配器
local function callCustomAPI(endpoint, data)
    local url = CONFIGURATION.custom_api_base_url .. endpoint
    local headers = {
        ["Authorization"] = "Bearer " .. CONFIGURATION.custom_api_key,
        ["Custom-Header"] = "value"
    }
    return makeRequest(url, data, headers)
end
```

---

## 📈 学习路径

### 初学者路径（1-2周）

**第1阶段：基础理解**
- [ ] 学习Lua基础语法（变量、函数、表）
- [ ] 理解模块系统和require机制
- [ ] 阅读_meta.lua和main.lua理解插件结构
- [ ] 进行简单修改：字体大小、按钮文字

**第2阶段：功能理解**
- [ ] 深入阅读dialogs.lua理解交互流程
- [ ] 学习错误处理模式和pcall使用
- [ ] 理解配置系统和用户定制
- [ ] 尝试添加简单的新按钮

**练习项目**：
- 修改插件界面文字为其他语言
- 添加一个显示当前时间的按钮
- 修改字体和颜色主题

### 中级开发者路径（2-4周）

**第3阶段：网络和API**
- [ ] 理解gpt_query.lua的网络请求机制
- [ ] 学习JSON处理和HTTP协议
- [ ] 掌握异步编程和回调模式
- [ ] 实现自定义API集成

**第4阶段：UI深度开发**
- [ ] 深入chatgptviewer.lua的UI组件系统
- [ ] 学习KOReader的UI框架
- [ ] 理解事件处理和手势识别
- [ ] 实现复杂的交互功能

**练习项目**：
- 集成新的AI服务API
- 添加文本导出功能
- 实现用户偏好设置界面
- 开发批量处理功能

### 高级开发者路径（4-8周）

**第5阶段：架构和性能**
- [ ] 深入理解插件架构模式
- [ ] 学习性能优化技巧
- [ ] 掌握内存管理和资源清理
- [ ] 实现复杂的状态管理

**第6阶段：扩展和集成**
- [ ] 开发插件扩展系统
- [ ] 实现与其他插件的集成
- [ ] 添加高级分析功能
- [ ] 构建测试和CI系统

**练习项目**：
- 开发插件框架和扩展系统
- 实现离线AI模型集成
- 构建自动化测试套件
- 开发插件市场和分发系统

### 学习资源推荐

**Lua编程**：
- [Lua 5.4 Reference Manual](https://www.lua.org/manual/5.4/)
- [Programming in Lua](https://www.lua.org/pil/) (在线免费版本)

**KOReader开发**：
- [KOReader GitHub Repository](https://github.com/koreader/koreader)
- [KOReader Plugin Development Wiki](https://github.com/koreader/koreader/wiki/Developer-Setup)

**UI开发**：
- KOReader源码中的ui/widget目录
- 现有插件源码作为参考

---

## 🎯 总结

AskGPT插件展现了一个完整的软件工程实践案例，包含：

**技术特点**：
- ✅ 清晰的模块化设计
- ✅ 健壮的错误处理机制
- ✅ 用户友好的交互设计
- ✅ 完善的配置和国际化系统
- ✅ 高质量的代码文档

**学习价值**：
- 🎓 Lua语言在实际项目中的应用
- 🎓 插件架构和设计模式
- 🎓 UI编程和事件处理
- 🎓 网络编程和API集成
- 🎓 错误处理和用户体验设计

这个项目为学习嵌入式Lua开发、插件架构设计和用户界面编程提供了优秀的参考案例。通过逐步深入理解这个项目，开发者可以掌握从基础语法到复杂系统设计的完整技能栈。

---

## 📞 支持和贡献

如果你在开发过程中遇到问题，或者想要贡献代码改进：

1. **问题报告**：在项目GitHub页面提交Issue
2. **功能建议**：通过Issue或Discussion讨论新功能
3. **代码贡献**：提交Pull Request
4. **文档改进**：帮助完善文档和示例

记住：最好的学习方式是实际动手修改和实验！从小的改动开始，逐步深入理解整个系统。