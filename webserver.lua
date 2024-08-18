local socket = require('socket')
local url = require('socket.url')

local string = string
local table = table

local print = print
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local date = os.date

_ENV = nil

local serverString = "Lua Webserver 0.0.1"

local clients = {}
local sessions = {}
local nextSessionID = 1
local g_server = nil
local handlers = {}

local function findHandlerIndex(path, method)
    for i, h in ipairs(handlers) do
        if path == h.path then
            if method == h.method then
                return i
            end
        end
    end
    return nil
end

local function findHandler(path, method)
    for i, h in ipairs(handlers) do
        print("Checking " .. h.path .. "  " .. h.method)

        local base = string.gsub(h.path, "%*", ".*") -- Turn asterisks into Lua wild patterns
        local pat = string.format("^%s$", base)  -- Add anchors to pattern
        if string.find(path, pat) == 1 then
            --if path == h.path then
            if method == nil or h.method == "*" or method == h.method then
                print("Match for", h.path)
                return h
            end
        end
    end
    return nil
end

local function getNewClients()
    --print( "Waiting for connection on " .. i .. ":" .. p .. "..." )
    local client, err = g_server:accept()
    if client == nil then
        if err ~= "timeout" then
            print("Error from accept: " .. err)
        end
    else
        print("Accepted connection from client")
        client:settimeout(1)
        table.insert(clients, client)
        local s = { id = nextSessionID, state = "init", client = client }
        nextSessionID = nextSessionID + 1
        sessions[client] = s
    end
end

local function buildHeaders_OK(s, content, contentType)
    local h = {}
    local function add(name, value)
        table.insert(h, string.format("%s: %s", name, value))
    end
    table.insert(h, "HTTP/1.1 200 OK")
    add("Server", serverString)
    add("Date", date("!%a, %d %b %Y %H:%M:%S GMT"))
    add("Connection", "close")
    if content then
        add("Content-Length", #content)
        add("Content-type", contentType)
    end
    return table.concat(h, "\n") .. "\n\n"
end

local function buildHeaders_Error(s, statusCode, statusText)
    local h = {}

    local function add(name, value)
        table.insert(h, string.format("%s: %s", name, value))
    end

    table.insert(h, string.format("HTTP/1.1 %d %s", statusCode, statusText))

    add("Server", serverString)
    add("Date", date("!%a, %d %b %Y %H:%M:%S GMT"))
    add("Connection", "close")

    return table.concat(h, "\n") .. "\n\n"
end

local function removeSession(s)
    for i, client in ipairs(clients) do
        if client == s.client then
            print("Removing client " .. i)
            table.remove(clients, i)
            sessions[s.client] = nil
            client:close()
            break
        end
    end
end

local function sendResponse(s, header, rcontent)
    print "Sending the response"

    local a, b, elast = s.client:send(header)
    if a == nil then
        print("Error: " .. b .. "  last byte sent: " .. elast)
    else
        print("Last byte sent: " .. a .. " header size: " .. #header)
    end

    if rcontent then
        local a, b, elast = s.client:send(rcontent)
        if a == nil then
            print("Error: " .. b .. "  last byte sent: " .. elast)
        else
            print("Last byte sent: " .. a .. " content size: " .. #rcontent)
        end
    end

    removeSession(s)
end

local function sendOKResponse(s, content, contentType)
    local header = buildHeaders_OK(s, content, contentType)
    sendResponse(s, header, content)
end

local function sendErrorResponse(s, statusCode, statusText)
    local header = buildHeaders_Error(s, statusCode, statusText)
    sendResponse(s, header)
end

local function parseHeaders(s)
    --print( string.format( "(%d) Request is '%s'", s.id, s.method ) )

    s.headers = {}

    -- TODO: handle a continued header line!
    for _, line in ipairs(s.rawHeaders) do
        local name, value = string.match(line, "(%S+)%s*:%s*(.+)%s*")
        if name ~= nil then
            --print( string.format( "'%s' = '%s'", name, value ) )
            name = string.lower(name) -- convert to lowercase for simplified access
            s.headers[name] = value
        else
            print("Malformed header line: ", line)
            return -1
        end
    end

    return 0 -- success
end

local function processHeaders( s )
	s.contentLength = 0
	
	local len = s.headers["content-length"]
	if len ~= nil then
		s.contentLength = tonumber( len )
	end
end

local function dumpSession(s)
    print("==============================")
    print("URL string:", s.urlString)
    print(string.format("Method: %s", s.method))
    print(string.format("Version: %s", s.version))

    print("Headers:")
    for name, value in pairs(s.headers) do
        print(string.format("    '%s' = '%s'", name, value))
    end

    print("URL components:")
    for k, v in pairs(s.urlComponents) do
        print(string.format("     %s:  %s", k, tostring(v)))
    end

    if s.queryComponents ~= nil then
        print("URL Query components")
        for k, v in pairs(s.queryComponents) do
            print(string.format("     %s =  %s", k, tostring(v)))
        end
    end

    print("URL Path", s.urlComponents.path)
    print("URL Params", s.urlComponents.params)
    print("URL url", s.urlComponents.url)

    print("URL path components:")
    for k, v in pairs(s.pathComponents) do
        print(string.format("     %s:  %s", k, tostring(v)))
    end

    print(string.format("Content Length: %d", s.contentLength))
    print(string.format("Content: %s", s.content))
end

local function processSession(s)
    dumpSession(s)

    local h = findHandler(s.urlComponents.path, s.method)
    if h then
        --print( ">>>>>>>>>>  Handler is" .. h )
        h.handler(s)
    else
        -- No matching path and method. How about just the path?
        local h = findHandler(s.urlComponents.path, nil)
        if h then
            -- This is a valid path, but not for the method.
            sendErrorResponse(s, 405, "Method Not Allowed")
            -- TODO: need to build a header with the allowed methods!
        else
            sendErrorResponse(s, 404, "Not Found")
        end
    end

    --sendErrorResponse( s, "404", "Not Found" )

    --local rcontent = "Howdy pardners"
end

local function decodeQuery(s)
    local cgi = {}
    for name, value in string.gmatch(s, "([^&=]+)=([^&=]+)") do
        name = url.unescape(name)
        value = url.unescape(value)
        cgi[name] = value
    end
    return cgi
end

local function handleClient(client)
    local s = sessions[client]

    local data, err, partial

    if s.state == "init" or s.state == "header" then
        data, err, partial = client:receive("*l")
    elseif s.state == "body" then
        data, err, partial = client:receive(s.contentLength)
    end

    if data then
        if s.state == "init" then
            print(string.format("(%d) INIT: '%s'", s.id, data))
            s.rawHeaders = {}
            local method, urlString, ver = string.match(data, "(%S+)%s+(%S+)%s+(%S+)")
            if method ~= nil then
                s.method = method
                s.urlString = urlString

                -- Break down the url string
                s.urlComponents = url.parse(urlString)

                s.pathComponents = url.parse_path(s.urlComponents.path)

                print("Query Components", s.urlComponents.query)
                if s.urlComponents.query ~= nil then
                    s.queryComponents = decodeQuery(s.urlComponents.query)
                end

                s.version = ver

                s.state = "header"
            else
                print("Malformed initial line")
                sendErrorResponse(s, 400, "Bad Request")
            end
        elseif s.state == "header" then
            print(string.format("(%d)  HDR: %s", s.id, data))
            if data ~= "" then
                table.insert(s.rawHeaders, data)
            else
                print(string.format("(%d)  End Headers", s.id))
                local rc = parseHeaders(s)
                if rc ~= 0 then
                    sendErrorResponse(s, 400, "Bad Request")
                    return
                end

                processHeaders(s)

                if s.contentLength == 0 then
                    print "Content length = 0, not waiting for content"
                    -- Processing the session will result in it being closed
                    processSession(s)
                else
                    print "Waiting for content"
                    s.state = "body"
                end
            end
        else
            --print( string.format( "(%d) BODY: %s", s.id, data ) )
            s.content = data
            processSession(s)
        end
    else
        if err == "closed" then
            print("Client closed the connection: ")
            removeSession(s)
            --print( "Size of client list is " .. #clients )
        elseif err == "timeout" then
            print("Receive timeout. Partial data: ", partial)
            removeSession(s)
        else
            print("Receive error: " .. err)
            removeSession(s)
        end
    end
end

local function process(timeout)
    local rclients, _, err = socket.select(clients, nil, timeout)
    --print( #rclients, err )
    if err ~= nil then
        -- Either no data (timeout) or an error
        if err ~= "timeout" then
            print("Select error: " .. err)
        end
    else
        -- Some clients have data for us
        for _, client in ipairs(rclients) do
            if client == g_server then
                -- special case, accept new connection
                getNewClients()
            else
                handleClient(client)
            end
        end
    end
end

local function registerHandler(path, method, handler)
    local h = { path = path, method = method, handler = handler }
    -- Already registered?
    local i = findHandlerIndex(path, method)
    if i == nil then
        -- add
        table.insert(handlers, h)
    else
        -- replace
        handlers[i] = h
    end
end

local function init(host, port)
    print("Web Server binding to host '" .. host .. "' on port " .. port .. "...")
    g_server = socket.bind(host, port)
    if g_server == nil then
        print("Unable to bind to port!");
        return
    end

    --i, p = server:getsockname()
    --print( i, p )
    --assert( i, p )

    g_server:settimeout(0.05)

    -- Add the server socket to the client arrays so we will wait on it in select()
    table.insert(clients, g_server)
end

local function run(host, port)
    init(host, port)

    while 1 do
        process(1.0)
    end
end

return {
	run = run,
	registerHandler = registerHandler,
	init = init,
	process = process,
	dumpSession = dumpSession,

	decodeQuery = decodeQuery,

	sendOKResponse = sendOKResponse,
	sendErrorResponse = sendErrorResponse
}