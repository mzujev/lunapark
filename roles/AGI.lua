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

-- Pre-define future logger function
local debugger

-- Future AGI object
local agi = {}

-- Get established connection
function agi.get_connection(self)
	local stat, err
	-- I socket determined
	if self['sock'] then
		-- And soket is valid socket object
		if type(self['sock']['settimeout']) == "function" then
			return self['sock'] -- return socket object
		end
	else
		-- Socket is not determined
		return self.logger('client socket must be determined')
	end
	-- All other errors
	return self.logger('wrong socket object')

end

-- Execute some AGI command
function agi.execute(self,command)
	-- Get established connection
	local sock, err = self:get_connection()
	-- Socket is valid socket object
	if sock then
		-- Checking the command for the valid content
		if type(command) == "string" and #command ~= 0 then
			-- Remember the last result and the last data
			if self['result'] then
				self['last_result'] = self['result']
				self['last_data'] = self['data']
			end
			-- Reset status/result/data before sending
			self['status'],self['result'],self['data'] = nil,nil,nil

			return sock:send((command:gsub('\n$','')) .. '\n')
		else
			-- The command has not valid content
			return self.logger('command cannot be an empty string')
		end
	else
		-- Not valid socket object
		return self.logger(err)
	end
end

-- Waiting for a response for the last command
function agi.response(self)
	-- Future response object
	local response = {}
	-- Get established connection
	local sock, err = self:get_connection()
	-- Not valid socket object
	if not sock then
		return self.logger(err)
	end
	-- Attempt to read from socket before error or timeout occurs
	while true do
		-- Reading a line obviously
		local line, err = sock:receive()
		-- Some error or empty line
		if not line or #line == 0 then
			-- Error occured and error is not by timeout
			if err and err ~= "timeout" then
				-- Close the erroneous socket because it is no needed any more
				sock:close()
				return self.logger(err)
			else
				-- Return response object if timeout or empty line
				return response
			end
		else
			-- No any error and line is not empty
			table.insert(response,line) -- Add line to the response object
		end
	end
end

-- Checking is valid syntax on response
function agi.checkresult(self,response)
	-- Parse response by code, result and data itself
	local code, result, data = string.match(response, '^(%d+) result=(-?[%d*#]+)%s*%(*([^)(]*)%)*')
	-- Parse is successed
	if code then
		-- Not relatively successful
		if not string.match(code,'^[200|510]') then
			code, result, data = nil, -1, response
		end
		-- Set status, result and data for last command
		self.status = code
		self.result = result and result
		self.data = (data and #data ~= 0) and data or result
	end

	return self.status
end

-- Parse input headers and store they in to the headers array
local function parseheaders(buff)
	-- Future array of headers
	local headers = {}
	-- Checking input data by type of table
	if type(buff) ~= "table" then
		return debugger("headers buffer must be a table")
	end
	-- Process input data line by line
	for _,line in pairs(buff) do
		-- Line is empty
		if string.len(line) < 1 then
			break
		end
		-- Parse line by key, value
		local k, v = string.match(line, "^agi_([%w|_]+):%s+(.*)$")
		-- Store parsed key and value in to headers array
		if k and v then
			headers[k] = v
		end
	end

	return headers
end

-- Read headers for current connection
local function readheaders(conf)
	-- Future buffer
	local buff = {}
	-- Get established connection
	local sock, err = agi.get_connection(conf)
	-- Socket is valid socket object
	if not sock then return debugger(err) end
	-- Attempt to read from socket before error or timeout occurs
	while true do
		-- Reading a line obviously
		local line, err = sock:receive()
		-- Some error or empty line
		if not line or #line == 0 then
			-- Error occured and error is not by timeout
			if err and err ~= "timeout" then
				-- Close the erroneous socket because it is no needed any more
				sock:close()
				return debugger(err)
			else
				-- Timeout occurs but headers buffer is empty
				if #buff == 0 and err == 'timeout' then
					return debugger('failed to read session headers, timeout occurs')
				else
					-- Return response object if timeout or empty line
					return buff
				end
			end
		else
			-- No any error and line is not empty
			table.insert(buff,line)  -- Add line to the response object
		end
	end
end

-- Return object with minimal functionality
return setmetatable({
		readheaders = readheaders,
		parseheaders = parseheaders
	},{
	-- Construct AGI object from config parameters
	__call = function(self,conf)
		-- Decorator for logger function
		debugger = function(...)
			-- Local copy of logger function if set
			local logger = conf['logger']
			-- Status and message
			local stat, msg = ...
			-- If the message is not defined, then only one parametr is passed
			if not msg then
				-- Flip them
				msg, stat = stat, nil
			end
			-- If logger function is defined, then execute it with message passing
			if type(logger) == "function" then
				logger(string.format("[AGI] %s",msg))
			end
			-- Return status and message
			return stat, msg
		end
		-- Client socket is not determined
		if not conf['sock'] then
			return debugger('client socket must be determined')
		end
		-- Headers is not defined at creation
		if not conf['headers'] then
			-- Trying to read the incoming headers
			local buff, err = self.readheaders(conf)
			-- Headers read successfully
			if buff then
				-- Parse and store
				conf['headers'] = self.parseheaders(buff)
				-- Parse is fail
				if not conf['headers'] then
					return debugger("error parse headers")
				end
			else
				-- Some error ocurred when read headers
				return debugger(err)
			end
		end
		-- If all right then return AGI session object
		return conf and setmetatable({logger = debugger},{__index = setmetatable(conf,{__index = agi})}) or debugger("failed to create AGI session")
	end
})


