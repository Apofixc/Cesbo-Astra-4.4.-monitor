local stream = {
    ["127.0.0.1"] = "Узда",
    ["127.0.0.2"] = "Дружный",
    ["127.0.0.3"] = "Старобин",
    ["127.0.0.4"] = "Октябрьский",
    ["127.0.0.5"] = "Червень",
    ["127.0.0.6"] = "Mediatech",
    ["127.0.0.7"] = "PlayOut",
    ["127.0.0.8"] = "BeCloud",
    ["127.0.0.9"] = "WikiLink",
}

function Get_stream(ip_address)
    if stream[ip_address] then
        return stream[ip_address]
    end

    return ip_address
end

function m_ratio(old, new)
    if type(old) ~= "number" or type(new) ~= "number" or new == 0 then 
        return 0     
    end

    return math.abs(old - new) / math.max(old, new)
end

table.copy = function(t)
    local copy = {}

    for k, v in pairs(t) do
        copy[k] = v
    end

    return copy
end

function check(cond, msg)
    if not cond then
        log.error(msg)
        return false
    end
    return true
end

local client_default

function Set_client_monitoring(host, port, path)
    client_default = { host = host, port = port, path = path }
end

local hostname =  utils.hostname()

function Get_server_name()
    return hostname
end

function send_monitor(content, client)
    local addr = client or client_default
    if not addr then
        print(content)
    else
        http_request({
            host = addr.host,
            path = addr.path,
            method = "POST",
            content = content,
            port = addr.port,
            headers = {
                "User-Agent: Astra v." .. astra.version,
                "Host: " .. addr.host,
                "Content-Type: application/json;charset=utf-8",
                "Content-Length: " .. #content,
                "Connection: close",
            },
            callback = function(s,r)
            end
        })
    end
end


