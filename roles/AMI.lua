--[[

Copyright © 2015 Mihail Zuev <z.m.c@list.ru>. 
Author: Mihail Zuev <z.m.c@list.ru>.
 
All rights reserved.
 
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the <organization> nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.
                                                                                
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

--]]

-- MD5 Algorithm Required for Authentication
local md5 = require "md5"
-- Library of tools used in lua-socket
local ltn12 = require "ltn12"
-- Standart LUA Socket Library
local socket = require "socket"
-- Pre-define future logger function
local debugger

-- Wait a packet from socket
local wait_reply = function(self)
	-- Table which will contains future reply 
	local buff = {}
	-- Do not use get_connection, because we are waiting reply from allready connected server
	local sock = self.socket
	if not sock then
		return self.logger("not connected")
	end

	-- Waiting until timeout/error occured or incoming data ended
	while true do
		-- read one line
		local line, err = sock:receive()
		-- Some error on socket
		if not line then
			return self.logger(err)
		end
		-- Empty line, that meens end of sequence
		if #line == 0 then
			return buff -- Just return reply buffer
		end
		-- Parse incoming line
		local key, val = line:match("^([^:]+)%s*:%s*(.*)$")
		-- Parse is successed
		if key then
			-- That key allready exists
			if buff[key] then
				-- If exiats but not array
				if type(buff[key]) ~= "table" then
					buff[key] = { buff[key] } -- Transform to array
				end
				buff[key][#buff[key] + 1] = val -- Append value
			else
				buff[key] = val -- Key is does't exists, will adding him
			end
		else
			-- Error parsing line
			return self.logger('Malformed line')
		end
	end
end

-- Simple parse of the reply
local parse_reply = function(response, field)
	-- What we searches whithin response
	field = field or "Message"
	-- Prepare the response 
	response = type(response) ~= "table" and {tostring(response)} or response
	-- Checking if response successed
	if response and response['Response'] == "Success" then
		-- Search field
		if response[field] then
			return tostring(response[field]) -- Field found
		else
			return debugger(table.concat {"Reply structure miss required field: ",tostring(field)}) -- Not
		end
	else -- Unknown AMI response structure or it's not success
		return debugger(tostring(response['Message']) or "Unknown AMI response structure")
	end
	-- Just in case
	return debugger("Malformed reply")
end

-- Challenge login implementation
local function challenge_login(conn, user, secret)
	-- Trying send challenge
	local stat, err = conn:command("Challenge", { AuthType = "md5" })
	-- Checking if error occured
	if not stat then
		return conn.logger("AMI: Can't get challenge:" .. err)
	end
	-- Wait reply
	stat, err	= conn:wait_reply()
	if not stat then
		return conn.logger(err)
	end
	-- Search challenge sequence
	parse_reply(stat, "Challenge")
	-- If found
	if stat and stat['Challenge'] then
		-- Login command
		stat, err = conn:command(
				"Login",
				{
					AuthType = "md5",
					Username = user,
					Key = md5.sumhexa(table.concat({stat.Challenge,secret}))
				}
		)
		-- Checking reply
		if stat then
			stat, err	= conn:wait_reply()
			if stat then
				return parse_reply(stat)
			end
		end
	end
	return conn.logger(err)
end

-- Plain text login implementation
local plain_login = function(conn, user, secret)
	-- Login command
	local stat, err = conn:command(
		"Login",
		{
		  Username = user,
		  Secret = secret,
		}
	)
	-- Check error
	if not stat then
		return conn.logger(err)
	end
	-- Check reply
	stat, err = conn:wait_reply()
	if not stat then
		return conn.logger(err) -- Something going wrong
	end
	-- Parsing reply
	return parse_reply(stat)
end

-- Close current connection if any
local function close(self)
	-- Just for convenience
	local skt = self['socket'] or {}
	-- Trying close connection
	local stat, err = pcall(skt['close'],skt)

	-- Checking error if any
	if stat then
		return true
	end
	-- Log and return error
	return self.logger(err)
end

-- Make tcp connection
local function make_connection(self)
	-- Create simple TCP socket
	local sock, err = socket.tcp()

	-- If socket.tcp() fails, return nil and an error message
	if not sock then
		return self.logger(err)
	end

	sock:settimeout(self['timeout'] or 1)

	-- Connect to AMI server
	stat, err = sock:connect(self['host'] or '127.0.0.1', self['port'] or 5038)

	-- If socket:connect() fails, return nil and an error message
	if not stat then
		return self.logger(err)
	end

	-- Trying Receive banner line
	line, err = sock:receive()

	-- If error occured, then does as usual ...
	if err then
		return self.logger(err)
	end
	
	protocol_version = string.lower(line):match( "^asterisk call manager/(%d.%d)")

	-- Unknown signature
	if not protocol_version then
		sock:close()
		return self.logger(string.format("bad signature: %s",line))
	end

	self.socket = sock
	self.protocol_version = protocol_version
end


-- Connect to AMI socket (if not connected)
local get_connection = function(self)
	-- Connection is not establish yet
	if not self.socket then
		make_connection(self) -- Trying connect to server
	end
	-- Return established connection if any
	return self.socket
end

-- Execute AMI command
local function command(self, action, data)
	-- Future packet
	local packet
	data = type(data) == "table" and data or {data}
	-- Get established connection or make if not connected yet
	local sock, err = get_connection(self)
	-- Return error message if any
	if not sock then
		return self.logger(err)
	end

	packet = {string.format("Action:%s",action)}

	for k, v in pairs(data) do
		packet[#packet + 1] = string.format("%s:%s",k,v)
	end

	packet = string.format("%s\n\n",table.concat(packet, "\n"))
	return ltn12.pump.all(
			ltn12.source.string(packet),
			socket.sink("keep-open", sock)
	)
end

-- Create a low-level connection object
local ami_connection = function(host, port, timeout, logger)
	-- Decorator for logger function
	debugger = function(...)
		-- Local copy of logger function
		local logger = logger
		-- Status and message
		local stat, msg = ...
		-- If the message is not defined, then only one parametr is passed
		if not msg then
			-- Flip them
			msg, stat = stat, nil
		end
		-- If logger function is defined, then execute it with message passing
		if type(logger) == "function" then
			logger(string.format("[AMI] %s",msg))
		end
		-- Return status and message
		return stat, msg
	end

	-- Return connection object
	return {
		-- methods
		get_connection = get_connection,
		wait_reply = wait_reply,
		command = command,
		logger = debugger,
		close = close,
		-- fields
		protocol_version = nil,
		timeout = timeout,
		socket = nil,
		host = host,
		port = port
	}
end

local AMI = setmetatable({},{
	__call = function(self,...)
		return self:new(...)
	end
})

-- New method of AMI object
function AMI.new(self,...)
	-- Future AMI object
	local mngr
	-- Extract CONF object or init him
	local conf = table.pack(...)[1] or {}

	-- Checking HOST parameter or init if needed
	if not conf or type(conf['host']) ~= 'string' then conf['host'] = '127.0.0.1' end
	-- Preparing AMI connection, not connect itself
	mngr = ami_connection(conf['host'],conf['port'] or 5038,conf['timeout'], conf['logger']) or nil
	-- Not a single error
	if mngr then
		-- Save configuration parameters whithin AMI object
		mngr.conf = conf
		-- Array of future callbacks
		mngr.events = {}
		-- Array of future responses
		mngr.responses = {}
		-- Pre-define plain auth algorithm
		mngr.login = plain_login
		-- If challenge needed
		if conf['secure'] then
			mngr.login = challenge_login
		end
		-- Itself connecttion
		if mngr:get_connection() then
			-- Connection success, then auth
			local stat, err = mngr:login(conf['user'],conf['secret'])
			-- Checking errors
			if not stat then
				return mngr.logger(err)
			end
		end
	end
	-- Return AMI object
	return mngr and setmetatable(mngr,{__index = self}) or debugger("Can't connect to " .. conf['host'])
end

-- Add event-listener
-- Syntax like: ami:addEvent(event, function)
--	event: Event name(Newchannel,Hangup, Answer, etc)
--	function: Callback function that will be executed when an event occurs
function AMI.addEvent(self,...)
	-- Checking the structure of the Callbacks Table
	if type(self['events']) ~= 'table' then return self.logger('Callbacks table is malformed') end
	-- Prepare/Parse of input parameters
	local pattern, func, i = (function(...) local p,f,i = ... return string.lower(p),f,i end)(...)
	-- Check if this event is already being processed
	if self.events[pattern] then
		if type(func) == 'function' then
			-- Transform 'pattern' in to array if not already
			if type(self.events[pattern]) ~= 'table' then
				self.events[pattern] = { self.events[pattern] }
			end
			-- Add callback function to patterns array
			self.events[pattern][i or #self.events[pattern] + 1] = func

			return i or #self.events[pattern] -- Return assigned index from patterns array
		end
	else
		if type(func) == 'function' then
			-- Add callback function to patterns array
			self.events[pattern] = {[i or 1] = func} return i or 1 -- Return assigned index from patterns array
		end
	end
end


-- Add event-listener many at once
-- Syntax like:
--	ami:addEvents({
--		'event1'=function()
--		end,
--		...
--		'event2'=function()
--		end
--	})
--	event: Event name(Newchannel,Hangup, Answer, etc)
--	function: Callback function that will be executed when an event occurs
function AMI.addEvents(self,...)
	-- Checking the structure of the Callbacks Table
	if type(self['events']) ~= 'table' then return self.logger('Callbacks table is malformed') end
	-- Prepare/Parse of input parameters
	local array = (function(...) local a = ... return type(a) == 'table' and a or {[a] = a} end)(...)
	-- Execute for each input parameter 'addEvent'
	for pattern,func in pairs(array) do
		self:addEvent(pattern,func)
	end
end

-- Remove previously defined callback function for some event and by some index
-- Syntax like: ami:removeEvent(pattern,index)
--	pattern: Event pattern(Hangup,Answer, etc)
--	index: Index inside callback patterns array
function AMI.removeEvent(self,...)
	-- Checking the structure of the Callbacks Table
	if type(self['events']) ~= 'table' then return self.logger('Callbacks table is malformed') end

	local pattern, index = (function(...) local p,i = ... return string.lower(p),i end)(...)
	-- Check if this event pattern is being defined
	if self.events[pattern] then
		-- If pattern is array
		if type(self.events[pattern]) == 'table' then
			-- If the callback function exists at the specified index
			if self.events[pattern][index] then
				-- Just delete
				self.events[pattern][index] = nil return true
			else
				-- Delete last pattern from array
				self.events[pattern][#self.events[pattern]] = nil return true
			end
		else
			-- Not array, just delete
			self.events[pattern] = nil return true
		end
	end

	return false
end

-- Remove previously defined callback function for some event many at once
-- Syntrax like: ami:removeEvent(pattern1,...,pattern2)
--	pattern: Event pattern(Hangup,Answer, etc)
function AMI.removeEvents(self,...)
	-- Checking the structure of the Callbacks Table
	if type(self['events']) ~= 'table' then return self.logger('Callbacks table is malformed') end
	-- Prepare/Parse of input parameters
	
	for _,p in ipairs({...} or {}) do
		local pattern = string.lower(p)
		-- Seems like a complete cleanup
		if pattern == '*' then
			-- Loop is needed because we are not wont delete 'hidden' events from completely cleanup
			for i, t in pairs(self.events) do
				-- Pattern of event is table
				if type(t) == 'table' then
					-- Delete only functions with a numerical index in the array
					for k,v in ipairs(t) do
						t[k] = nil
					end
				else
					-- Pattern not table, just delete him
					self.events[i] = nil
				end
			end
		else
			-- Cleanup some event pattern
			if self.events[pattern] then
				self.events[pattern] = nil
			end
		end
	end
end

return AMI
