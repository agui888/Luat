--- 数据链路激活(创建、连接、状态维护)
-- @module link
-- @author 稀饭放姜、小强
-- @license MIT
-- @copyright openLuat.com
-- @release 2017.9.20
module(..., package.seeall)
-- 定义模块,导入依赖库
local base = _G
local string = require "string"
local table = require "table"
local sys = require "sys"
local ril = require "ril"
local net = require "net"
local rtos = require "rtos"
local sim = require "sim"
-- 加载常用的全局函数至本地
local print = base.print
local pairs = base.pairs
local tonumber = base.tonumber
local tostring = base.tostring
local wait = sys.wait
local waitUntil = sys.waitUntil
local publish = sys.publish
local request = ril.request

-- ipStatus：IP环境状态
-- shuting：是否正在关闭数据网络
local ipStatus, shuting = "IP INITIAL"
-- GPRS数据网络附着状态，"1"附着，其余未附着
-- local cgatt
-- apn，用户名，密码
local apnname = "CMNET"
local username = ''
local password = ''

-- apnflg：本功能模块是否自动获取apn信息，true是，false则由用户应用脚本自己调用setapn接口设置apn、用户名和密码
-- flyMode：是否处于飞行模式
local apnFlag, flyMode = true

--- 设置APN的参数
-- @string apn, APN的名字
-- @string user, APN登陆用户名
-- @string pwd,  APN登陆用户密码
function setApn(apn, user, pwd)
    apnname, username, password = apn, user or '', pwd or ''
    apnflag = false
end

--- 获取APN的名称
-- @return string, APN的名字
function getApn()
    return apnname
end

--[[
函数名：cgattrsp
功能  ：查询GPRS数据网络附着状态的应答处理
参数  ：
cmd：此应答对应的AT命令
success：AT命令执行结果，true或者false
response：AT命令的应答中的执行结果字符串
intermediate：AT命令的应答中的中间信息
返回值：无
]]
local function cgattRsp(cmd, success, response, intermediate)
    --已附着
    if intermediate == "+CGATT: 1" then
        -- 发布GPRS附着消息
        publish("NET_GPRS_READY")
        -- 如果存在链接,那么在gprs附着上以后自动激活IP网络
        if ipStatus == "IP INITIAL" then
            -- 激活IP服务
            request("AT+CSTT=\"" .. apnname .. '\",\"' .. username .. '\",\"' .. password .. "\"")
            request("AT+CIICR")
        end
        --查询激活状态
        request("AT+CIPSTATUS")
        print("link.cgattRsp is NET_GPRS_READY:\t", intermediate)
    
    --发布GPRS分离消息
    elseif intermediate == "+CGATT: 0" then
        publish("CONNECTION_LINK_ERROR")
        print("link.cgattRsp is NET_GPRS_NOTREADY:\t", intermediate)
    end
end

--[[
函数名：ipState
功能  ：IP网络状态处理函数
参数  ：
data：IP网络状态
prefix: +CIPSTATUS 的返回主动上报urc 前缀STATE
返回值：无
]]
local function ipState(data, prefix)
    status = string.sub(data, 8, -1)
    if status == "IP GPRSACT" then
        --获取IP地址，地址获取成功后，IP网络状态会切换为"IP STATUS"
        request("AT+CIFSR")
        -- 查询连接状态，是否正确获取IP地址
        request("AT+CIPSTATUS")
        -- 发布 PDP成功消息
        publish("IP_PDP_READY")
    elseif status == "IP PROCESSING" or status == "IP STATUS" then
        -- 发布IP服务激活成功消息
        publish("IP_STATUS_SUCCESS")
    elseif status == "PDP DEACT" then
        if ipStatus == "IP PROCESSING" or ipStatus == "IP STATUS" or ipStatus == "IP GPRSACT" then
            -- IP服务激活过程中发生的‘PDP DEACT' 处理
            else
            publish("CONNECTION_LINK_ERROR")
        end
    end
    ipStatus = status
    print("link.ipState IP STATUS is :\t", ipStatus)
end

--sim卡的默认apn表
local apntable = {
    ["46000"] = "CMNET",
    ["46002"] = "CMNET",
    ["46004"] = "CMNET",
    ["46007"] = "CMNET",
    ["46001"] = "UNINET",
    ["46006"] = "UNINET",
}

--[[
IMSI读取成功的回调函数
函数功能：自动设置APN的参数
--]]
local function autoApn(id, para)
    --本模块内部自动获取apn信息进行配置
    if apnflag then
        if apn then
            local temp1, temp2, temp3 = apn.get_default_apn(tonumber(sim.getMcc(), 16), tonumber(sim.getMnc(), 16))
            if temp1 == '' or temp1 == nil then temp1 = "CMNET" end
            setApn(temp1, temp2, temp3)
        else
            setApn(apntable[sim.getMcc() .. sim.getMnc()] or "CMNET")
        end
    end
end
--[[
函数名：flySwitch
功能  ：切换飞行模式动作
参数  ：
id：内部消息id
para：内部消息参数
返回值：无
]]
---[[
local function flySwitch(id, para)
    --飞行模式状态变化
    flymode = para
    if para then
        publish("CONNECTION_LINK_ERROR")
    else
        request("AT+CGATT?", nil, cgattRsp)
    end
end
--]]
--[[
函数名：rsp
功能  ：本功能模块内“通过虚拟串口发送到底层core软件的AT命令”的应答处理
参数  ：
cmd：此应答对应的AT命令
success：AT命令执行结果，true或者false
response：AT命令的应答中的执行结果字符串
intermediate：AT命令的应答中的中间信息
返回值：无
]]
---[[
local function cipShut(cmd, success, response, intermediate)
    local prefix = string.match(cmd, "AT(%+%u+)")
    local id = tonumber(string.match(cmd, "AT%+%u+=(%d)"))
    --关闭IP网络的应答
    if prefix == "+CIPSHUT" then
        -- shutcnf(response)
    end
end
--]]
--[[
函数名：urc
功能  ：本功能模块内“注册的底层core通过虚拟串口主动上报的通知”的处理
参数  ：
data：通知的完整字符串信息
prefix：通知的前缀
返回值：无
]]
---[[
function urc(data, prefix)
    
    if prefix == "+PDP" then
        
        end
end
--]]
--注册以下urc通知的处理函数
ril.regurc("STATE", ipState)
ril.regurc("+PDP", urc)
-- 订阅AT命令返回消息
ril.regrsp("+CIPSHUT", cipShut)-- 订阅“关闭移动场景”返回消息
-- ril.regrsp("+CIICR", rsp)-- 订阅“激活移动场景”返回消息
-- 订阅app消息
sys.subscribe(autoApn, "IMSI_READY")
sys.subscribe(flySwitch, "FLYMODE_IND")


-- initial 只能初始化1次，这里是初始化完成标志位
local inited = false
-- 配置发送模式 0是慢发，1是快发，默认慢发模式返回SEND OK
local qsend = 0
--[[
函数名：initial
功能  ：配置本模块功能的一些初始化参数
参数  ：无
返回值：无
]]
local function initial()
    if not inited then
        inited = true
        request("AT+CIICRMODE=2")--ciicr异步
        request("AT+CIPMUX=1")--多链接
        request("AT+CIPHEAD=1")
        request("AT+CIPQSEND=" .. qsend)--发送模式
    end
end

function SetQuickSend(mode)
    qsend = mode
end

--- GPRS网络IP服务连接处理任务
function connectionTask()
    while true do
        -- 等待GSM注册成功
        while not waitUntil("NET_STATE_REGISTERED", 120000) do end
        -- 初始化PDP注册之前的一些参数
        initial()
        -- 每隔2000ms查询1次GPRS附着状态，直到附着成功。
        while not waitUntil("NET_GPRS_READY", 2000, function()request("AT+CGATT?", nil, cgattRsp) end) do end
        -- 每隔2000ms查询1次 PDP_READY 消息
        while not waitUntil("IP_PDP_READY", 2000, function()request("AT+CIPSTATUS") end) do end
        -- 激活IP服务，等待IP获取成功消息,每隔2秒查询1次
        while not waitUntil("IP_STATUS_SUCCESS", 2000, function()request("AT+CIPSTATUS") end) do end
        -- while not waitUntil("LINK_STATE_INVALID", 120000) do end
        while not waitUntil("CONNECTION_LINK_ERROR", 12000, function()request("AT+CIPSTATUS") end) do end
    end
end
