# Lunopark
____
***Lunopark*** is a suite of software solutions, that acts as a combination of two roles(FastAGI/AMI) in the same execution space.
That meen, we can execute dialplan applications and receive(proccess) AMI events in one same runtime space and in coopiration with each other.
***Lunopark*** is asyncronous(based on coroutine) service, that feature mast be considered when make up the future configuration.
In general, Lunopark is a replacement of Asterisk REST Interface, but in some places it is more flexible.

### Features
- ***Lunopark*** Asynchronous (based on coroutine)
- Functionality for FastAGI role
- Functionality for AMI role
- Compatible with Lua 5.1, 5.2, 5.3 and ***LuaJIT***

#### AGI Role
The FastAGI implementation it's a classic AGI server that acts as call processing service.
In the simple case, if we want to handle calls using the AGI Role, that we hands over control of a channel from Asterisk to the FastAGI subroutine.
The AGI Role is similar the ***pbx_lua.so*** with some syntax changes:
- ***pbx_lua.so*** contains all configuration in global table ***extensions***, while ***Lunopark*** can stores the configuration everywhere you wish.
- ***pbx_lua.so*** passes in to extension function the current context and extension as the first two arguments, while ***Lunopark*** passes the ***app*** and ***channel*** objects respectively.
- ***pbx_lua.so*** can't store persistent variables(database connection/globally shared objects), instead that, the library does this every time with each next call is processed. The AGI Role devoid of this disadvantage.
- And the most important is what AGI Role has access to the global ***ami*** object in any place of execution. This coopiration allows us to receive the global state or the status of other calls in the system within the AGI execution.

*Example:*
```sh
    ;extensions.conf
    [user_context]
    exten => _.,1,Goto(main)
    ;Pass call control to the lunopark
    exten => _.,100(main),AGI(agi://ip_addres_of_agi_role/subroutine)
    exten => _[hit],1,NoOp()
```

```lua
    -- Processing all new calls
    function subroutine(...)
        local pin
        local app, channel = ...
        
        app.Answer()
        app.Read('PIN','beep',_,_,_,8)
        pin = channel.get('PIN')
        app.Verbose('User entered ' .. pin)
        
        if pin ~= '0000' then
            app.Vebose('Wrong pin code ...') return
        end
        
        app.Dial('SIP/trunk/1234',120,'gr')
        
        -- log dial status by channel.get('HANGUPCAUSE')
    end
```

#### AMI Role
The AMI Role acts as events listener/handler and/or AMI client, what is not less important in the same one connection.
The AMI role creates a global ***ami*** object, that allows execute an AMI command using the `ami.command(args)` syntax.

*Example:*
```lua
    -- Receive current channels status
    local status = ami.Status()

    -- Receive Codec translation
    local stuff = ami.command{command = 'core show translation'}

    -- Redirect some(not necessarily current) channel
    local status = ami.redirect{
        channel = 'SIP/1-0000012c',
        context = 'transfer',
        exten = 's',
        priority = 1
    }

    -- Get Global Variable
    local var = ami.getvar {variable = 'TEST'}

    -- Get variable of some channel
    local cvar = ami.getvar {
        variable = 'CHANNEL',
        channel = 'SIP/1-0000012c'
    }

    -- Add event-listener
    ami.addEvent(hangup,function(e) print(e['Channel'] .. ' is ' .. e['Event']))
    --        OR
    ami.addEvents{
        ['Hangup'] = function(e)
            print(e['Channel'] .. ' is ' .. e['Event'])
        end,
        ['Answer'] == function(e)
            print(e['Channel'] .. ' is ' .. e['Event'])
        end
    }
```

### Configuration
***Lunopark*** is only configured using a configuration file that has the correct lua syntax. The ***Lunopark*** service has only one command line switch `-c`, which points to a configuration file.

*Example:*
```lua
-- (String)              
-- Role of daemon        
-- Can be 'both','agi' or 'ami'
role = 'both'            

-- (String)              
-- User for AMI connection
user = 'admin'           

-- (String)
-- Secret for AMI connection 
secret = 'secret'      

-- (String)
-- Address for AMI server
-- Can be of the form 'ip:port' or 'ip'
host = '127.0.0.1'

-- (String)
-- Listen address for AGI server
-- Can be of the form '*' | 'ip' | '*:port' | 'ip:port'
listen = '*'             

-- (String)
-- Path to the file that contains the processing logic
handler = '/etc/lunopark/handler.lua'

-- (String)
-- Log message identifier
ident = 'lunopark'

-- (String)
-- Log file location
-- If not set then used only console output
log = '/tmp/lunopark.log'
```

### Usage
To start the ***Lunopark*** service just need to specify the configuration file.

```sh
$ lunopark -c /etc/lunopark/lunopark.conf
```
If configuration file not specifyed then will be used default values, also ***Lunopark*** has't background mode, if you need to run in background mode uses the capabilities of the command shell.
```sh
$ lunopark -c /etc/lunopark/lunopark.conf &>/dev/null &
```

The ***Lunopark*** can accepted the `HUP` and `QUIT` signals. When a `HUP`/`QUIT` is received, then ***Lunopark*** re-load a handler file.

### Installation
To install ***Lunopark*** use `git clone` and manually resolve the dependencies.

```sh
# mkdir -p /etc/lunopark && cd /etc/lunopark
# git clone https://github.com/mzujev/lunopark
```

### Dependencies
- [extens](https://github.com/mzujev/extens) - Compatibility/Extensions library
- [lua-ev](https://github.com/brimworks/lua-ev) - Lua integration with libev
- [luasocket](https://github.com/diegonehab/luasocket) - Lua interface library with the TCP/IP stack
- [uuid](https://github.com/Tieske/uuid) - Library to generates UUIDs
- [log](https://github.com/mzujev/log) - Logging module with the minimum necessary functionality
- [md5](https://github.com/keplerproject/md5) - MD5 algorithm implementation

### Copyright
See [Copyright.txt](https://github.com/mzujev/lunopark/Copyright.txt) file for details
