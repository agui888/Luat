--- mqtt client
-- @module mqtt
-- @author 小强
-- @license MIT
-- @copyright openLuat
-- @release 2017.10.24

require "log"
require "socket"
require "utils"
module(..., package.seeall)

-- MQTT 指令id
local CONNECT, CONNACK, PUBLISH, PUBACK, PUBREC, PUBREL, PUBCOMP, SUBSCRIBE, SUBACK, UNSUBSCRIBE, UNSUBACK, PINGREQ, PINGRESP, DISCONNECT = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
local CLIENT_COMMAND_TIMEOUT = 5000

local function encodeLen(len)
    local s = ""
    local digit
    repeat
        digit = len % 128
        len = len / 128
        if len > 0 then
            digit = bit.bor(digit, 0x80)
        end
        s = s .. string.char(digit)
    until (len <= 0)
    return s
end

local function encodeUTF8(s)
    if not s or #s == 0 then
        return ""
    else
        return pack.pack(">P", s)
    end
end

local function packCONNECT(clientId, keepAlive, username, password, cleanSession, will)
    local content = pack.pack(">PbbHPAAAA",								
								"MQTT",
								4,
								(#username == 0 and 0 or 1) * 128 + (#password == 0 and 0 or 1) * 64 + will.retain * 32 + will.qos * 8 + will.flag * 4 + cleanSession * 2,
								keepAlive,
								clientId,
								encodeUTF8(will.topic),
								encodeUTF8(will.payload),
								encodeUTF8(username),
								encodeUTF8(password))
    return pack.pack(">bAA",
        CONNECT * 16,
        encodeLen(string.len(content)),
        content)
end

local function packSUBSCRIBE(dup, packetId, topics)
    local header = SUBSCRIBE * 16 + dup * 8 + 2
    local data = pack.pack(">H", packetId)
    for topic, qos in pairs(topics) do
        data = data .. pack.pack(">Pb", topic, qos)
    end
    return pack.pack(">bAA", header, encodeLen(#data), data)
end

local function packPUBLISH(dup, qos, retain, packetId, topic, payload)
    local header = PUBLISH * 16 + dup * 8 + qos * 2 + retain
    local len = 2 + #topic + #payload
    if qos > 0 then
        return pack.pack(">bAPHA", header, encodeLen(len + 2), topic, packetId, payload)
    else
        return pack.pack(">bAPA", header, encodeLen(len), topic, payload)
    end
end

local function packACK(id, dup, packetId)
    return pack.pack(">bbH", id * 16 + dup * 8 + (id == PUBREL and 1 or 0) * 2, 0x02, packetId)
end

local function packZeroData(id, dup, qos, retain)
    dup = dup or 0
    qos = qos or 0
    retain = retain or 0
    return pack.pack(">bb", id * 16 + dup * 8 + qos * 2 + retain, 0)
end

local function unpack(s)
    if #s < 2 then return end
    log.debug("mqtt.unpack", #s, string.tohex(string.sub(s, 1, 50)))

    -- read remaining length
    local len = 0
    local multiplier = 1
    local pos = 2

    repeat
        if pos > #s then return end
        local digit = string.byte(s, pos)
        len = len + ((digit % 128) * multiplier)
        multiplier = multiplier * 128
        pos = pos + 1
    until digit < 128

    if #s < len + pos - 1 then return end

    local header = string.byte(s, 1)

    local packet = { id = header / 16, dup = (header % 16) / 8, qos = bit.band(header, 0x06) / 2 }
    local nextpos

    if packet.id == CONNACK then
        nextpos, packet.rc = pack.unpack(s, ">H", pos)
    elseif packet.id == PUBLISH then
        nextpos, packet.topic = pack.unpack(s, ">P", pos)
        if packet.qos > 0 then
            nextpos, packet.packetId = pack.unpack(s, ">H", nextpos)
        end
        packet.payload = string.sub(s, nextpos, pos+len-1)
    elseif packet.id ~= PINGRESP then
        if len >= 2 then
            nextpos, packet.packetId = pack.unpack(s, ">H", pos)
        else
            packet.packetId = 0
        end
    end

    return packet, pos + len
end

local mqttc = {}
mqttc.__index = mqttc

--- mqtt.client() 创建mqtt client实例
-- @param clientId
-- @param keepAlive 心跳间隔，默认300秒
-- @param username 用户名为空请输入nil
-- @param password 密码为空请输入nil
-- @param cleanSession 1/0
-- @param will 遗嘱参数(Last Will/Testament), will.flag, will.qos, will.retain, will.topic, will.payload
-- @return result true - 成功，false - 失败
-- @usage
-- mqttc = mqtt.client("clientid-123", nil, nil, false)
function client(clientId, keepAlive, username, password, cleanSession, will)
    local o = {}
    local packetId = 1

    will = will or { flag = 0, qos = 0, retain = 0, topic = "", payload = "" }

    o.clientId = clientId
    o.keepAlive = keepAlive or 300
    o.username = username or ""
    o.password = password or ""
    o.cleanSession = cleanSession or 1
    o.will = will
    o.commandTimeout = CLIENT_COMMAND_TIMEOUT
    o.cache = {} -- 接收到的mqtt数据包缓冲
    o.inbuf = "" -- 未完成的数据缓冲
    o.connected = false
    o.getNextPacketId = function()
        packetId = packetId == 65535 and 1 or (packetId + 1)
        return packetId
    end
    o.lastIOTime = 0

    setmetatable(o, mqttc)

    return o
end

-- 检测是否需要发送心跳包
function mqttc:checkKeepAlive()
    if self.keepAlive == 0 then return true end
    if os.time() - self.lastIOTime >= self.keepAlive then
        if not self:write(packZeroData(PINGREQ)) then
            log.info("mqtt.client:checkKeepAlive", "pingreq send fail")
            return false
        end
    end
    return true
end

-- 发送mqtt数据
function mqttc:write(data)
    log.debug("mqtt.client:write", string.tohex(string.sub(data, 1, 50)))
    local r = self.io:send(data)
    if r then self.lastIOTime = os.time() end
    return r
end

-- 接收mqtt数据包
function mqttc:read(timeout)
    if not self:checkKeepAlive() then return false end

    -- 处理之前缓冲的数据
    local packet, nextpos = unpack(self.inbuf)
    if packet then
        self.inbuf = string.sub(self.inbuf, nextpos)
        return true, packet
    end

    while true do
        local recvTimeout

        if self.keepAlive == 0 then
            recvTimeout = timeout
        else
            local kaTimeout = (self.keepAlive - (os.time() - self.lastIOTime)) * 1000
            recvTimeout = kaTimeout > timeout and timeout or kaTimeout
        end

        local r, s = self.io:recv(recvTimeout == 0 and 5 or recvTimeout)
        if r then
            self.inbuf = self.inbuf .. s
        elseif s == "timeout" then -- 超时，判断是否需要发送心跳包
            if not self:checkKeepAlive() then
                return false
            end
            return false, "timeout"
        else -- 其他错误直接返回
            return r, s
        end
        local packet, nextpos = unpack(self.inbuf)
        if packet then
            self.lastIOTime = os.time()
            self.inbuf = string.sub(self.inbuf, nextpos)
            return true, packet
        end
    end
end

-- 等待接收指定的mqtt消息
function mqttc:waitfor(id, timeout)
    for index, packet in ipairs(self.cache) do
        if packet.id == id then
            return true, table.remove(self.cache, index)
        end
    end

    while true do
        local r, data = self:read(timeout)
        if r then
            if data.id == PUBLISH then
                if data.qos > 0 then
                    if not self:write(packACK(data.qos == 1 and PUBACK or PUBREC, 0, data.packetId)) then
                        log.info("mqtt.client:waitfor", "send publish ack failed", data.qos)
                        return false
                    end
                end
            elseif data.id == PUBREC or data.id == PUBREL then
                if not self:write(packACK(data.id == PUBREC and PUBREL or PUBCOMP, 0, data.packetId)) then
                    log.info("mqtt.client:waitfor", "send ack fail", data.id == PUBREC and "PUBREC" or "PUBCOMP")
                    return false
                end
            end

            if data.id == id then
                return true, data
            end
            table.insert(self.cache, data)
        else
            return false, data
        end
    end
end

--- 连接mqtt服务器
-- @param host 地址
-- @param port 端口
-- @param transport tcp
-- @return result true - 成功，false - 失败
-- @usage mqttc = mqtt.client("clientid-123", nil, nil, false); mqttc:connect("mqttserver.com", 1883, "tcp")
function mqttc:connect(host, port, transport)
    if self.connected then
        log.info("mqtt.client:connect", "has connected")
        return false
    end

    if self.io then
        self.io:close()
        self.io = nil
    end

    if transport and transport ~= "tcp" then
        log.info("mqtt.client:connect", "invalid transport", transport)
        return false
    end

    self.io = socket.tcp()

    if not self.io:connect(host, port) then
        log.info("mqtt.client:connect", "connect host fail")
        return false
    end

    if not self:write(packCONNECT(self.clientId, self.keepAlive, self.username, self.password, self.cleanSession, self.will)) then
        log.info("mqtt.client:connect", "send fail")
        return false
    end

    local r, packet = self:waitfor(CONNACK, self.commandTimeout)
    if not r or packet.rc ~= 0 then
        log.info("mqtt.client:connect", "connack error", r and packet.rc or -1)
        return false
    end

    self.connected = true

    return true
end

--- mqtt.client:subscribe(topic, qos)
-- @param topic
-- @param qos 0/1/2
-- @return result true - 成功，false - 失败
-- @usage
-- mqttc:subscribe("/abc", 0) -- subscribe topic "/abc" with qos = 0
-- mqttc:subscribe({["/topic1"] = 0, ["/topic2"] = 1, ["/topic3"] = 2}) -- subscribe multi topic
function mqttc:subscribe(topic, qos)
    if not self.connected then
        log.info("mqtt.client:subscribe", "not connected")
        return false
    end

    local topics
    if type(topic) == "string" then
        topics = { [topic] = qos and qos or 0 }
    else
        topics = topic
    end

    if not self:write(packSUBSCRIBE(0, self.getNextPacketId(), topics)) then
        log.info("mqtt.client:subscribe", "send failed")
        return false
    end

    if not self:waitfor(SUBACK, self.commandTimeout) then
        log.info("mqtt.client:subscribe", "wait ack failed")
        return false
    end

    return true
end

--- mqtt.client:publish(topic, payload, qos, retain)
-- @param topic
-- @param payload
-- @param qos 0/1/2, default 0
-- @param retain
-- @return mid mqtt message id
-- @usage
-- mqttc = mqtt.client("clientid-123", nil, nil, false)
-- mqttc:connect("mqttserver.com", 1883, "tcp")
-- mqttc:publish("/topic", "publish from luat mqtt client", 0)
function mqttc:publish(topic, payload, qos, retain)
    if not self.connected then
        log.info("mqtt.client:publish", "not connected")
        return false
    end

    qos = qos or 0
    retain = retain or 0

    if not self:write(packPUBLISH(0, qos, retain, qos > 0 and self.getNextPacketId() or 0, topic, payload)) then
        log.info("mqtt.client:publish", "socket send failed")
        return false
    end

    if qos == 0 then return true end

    if not self:waitfor(qos == 1 and PUBACK or PUBCOMP, self.commandTimeout) then
        log.warn("mqtt.client:publish", "wait ack timeout")
        return false
    end

    return true
end

--- mqtt.client:receive([timeout])
-- @return result true - 成功，false - 失败
-- @return data 如果成功返回的时候接收到的服务器发过来的包，如果失败返回的是错误信息
-- @usage
-- true, packet = mqttc:receive()
-- false, error_message = mqttc:receive()
function mqttc:receive(timeout)
    if not self.connected then
        log.info("mqtt.client:receive", "not connected")
        return false
    end

    return self:waitfor(PUBLISH, timeout)
end

--- mqtt disconnect
-- @return result true - 成功，false - 失败
-- @usage
-- mqttc = mqtt.client("clientid-123", nil, nil, false)
-- mqttc:connect("mqttserver.com", 1883, "tcp")
-- process data
-- mqttc:disconnect()
function mqttc:disconnect()
    if self.connected then
        self:write(packZeroData(DISCONNECT))
    end
    if self.io then
        self.io:close()
        self.io = nil
    end
    self.cache = {}
    self.inbuf = ""
    self.connected = false
end
