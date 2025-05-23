---
-- A tiny library allowing some basic information enumeration from
-- Versant object database software (see
-- http://en.wikipedia.org/wiki/Versant_Corporation).  The code is
-- entirely based on packet dumps captured when using the Versant
-- Management Center administration application.
--
-- @author Patrik Karlsson <patrik@cqure.net>
--

local stdnse = require "stdnse"
local match = require "match"
local nmap = require "nmap"
local string = require "string"
local table = require "table"
_ENV = stdnse.module("versant", stdnse.seeall)

Versant = {

  -- fallback to these constants when version and user are not given
  USER = "user",
  VERSION = "8.0.2",

  -- Creates an instance of the Versant class
  -- @param host table
  -- @param port table
  -- @return o new instance of Versant
  new = function(self, host, port)
    local o = { host = host, port = port, socket = nmap.new_socket() }
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  -- Connects a socket to the Versant server
  -- @return status true on success, false on failure
  -- @return err string containing the error message if status is false
  connect = function(self)
    return self.socket:connect(self.host, self.port)
  end,

  -- Closes the socket
  -- @return status true on success, false on failure
  -- @return err string containing the error message if status is false
  close = function(self)
    return self.socket:close()
  end,

  -- Sends command to the server
  -- @param cmd string containing the command to run
  -- @param arg string containing any arguments
  -- @param user [optional] string containing the user name
  -- @param ver [optional] string containing the version number
  -- @return status true on success, false on failure
  -- @return data opaque string containing the response
  sendCommand = function(self, cmd, arg, user, ver)

    user = user or Versant.USER
    ver = ver or Versant.VERSION
    arg = arg or ""

    local data = stdnse.fromhex("000100000000000000020002000000010000000000000000000000000000000000010000")
    .. string.pack("zzz",
      cmd,
      user,
      ver
      )
    -- align to even 4 bytes
    data = data .. string.rep("\0", 4 - ((#data % 4) or 0))

    data = data .. stdnse.fromhex("0000000b000001000000000000000000")
    .. string.pack("zxxxxxxxxxxz",
      ("%s:%d"):format(self.host.ip, self.port.number),
      arg
      )

    data = data .. string.rep("\0", 2048 - #data)

    local status, err = self.socket:send(data)
    if ( not(status) ) then
      return false, "Failed to send request to server"
    end

    local status, data = self.socket:receive_buf(match.numbytes(2048), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    return status, data
  end,

  -- Get database node information
  -- @return status true on success, false on failure
  -- @return result table containing an entry for each database. Each entry
  --         contains a table with the following fields:
  --         <code>name</code> - the database name
  --         <code>owner</code> - the database owner
  --         <code>created</code> - the date when the database was created
  --         <code>version</code> - the database version
  getNodeInfo = function(self)
    local status, data = self:sendCommand("o_getnodeinfo", "-nodeinfo")
    if ( not(status) ) then
      return false, data
    end

    status, data = self.socket:receive_buf(match.numbytes(4), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    local db_count = string.unpack(">I4", data)
    if ( db_count == 0 ) then
      return false, "Database count was zero"
    end

    status, data = self.socket:receive_buf(match.numbytes(4), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    local buf_size = string.unpack(">I4", data)
    local dbs = {}

    for i=1, db_count do
      status, data = self.socket:receive_buf(match.numbytes(buf_size), true)
      local db = {}

      db.name = string.unpack("z", data, 23)
      db.owner  = string.unpack("z", data, 599)
      db.created= string.unpack("z", data, 631)
      db.version= string.unpack("z", data, 663)

      -- remove trailing line-feed
      db.created = db.created:match("^(.-)\n*$")

      table.insert(dbs, db)
    end
    return true, dbs
  end,

  -- Gets the database OBE port, this port is dynamically allocated once this
  -- command completes.
  --
  -- @return status true on success, false on failure
  -- @return port table containing the OBE port
  getObePort = function(self)

    local status, data = self:sendCommand("o_oscp", "-utility")
    if ( not(status) ) then
      return false, data
    end

    status, data = self.socket:receive_buf(match.numbytes(256), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    local success, pos = string.unpack(">I4", data)
    if ( success ~= 0 ) then
      return false, "Response contained invalid data"
    end

    local port = { protocol = "tcp" }
    port.number, pos = string.unpack(">I2", data, pos)

    return true, port
  end,


  -- Gets the XML license file from the database
  -- @return status true on success, false on failure
  -- @return data string containing the XML license file
  getLicense = function(self)

    local status, data = self:sendCommand("o_licfile", "-license")
    if ( not(status) ) then
      return false, data
    end

    status, data = self.socket:receive_buf(match.numbytes(4), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    local len = string.unpack(">I4", data)
    if ( len == 0 ) then
      return false, "Failed to retrieve license file"
    end

    status, data = self.socket:receive_buf(match.numbytes(len), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    return true, data
  end,

  -- Gets the TCP port for a given database
  -- @param db string containing the database name
  -- @return status true on success, false on failure
  -- @return port table containing the database port
  getDbPort = function(self, db)
    local status, data = self:sendCommand(db, "")
    if ( not(status) ) then
      return false, data
    end

    if ( not(status) ) then
      return false, "Failed to connect to database"
    end

    local port = { protocol = "tcp" }
    port.number = string.unpack(">I4", data, 27)
    if ( port == 0 ) then
      return false, "Failed to determine database port"
    end
    return true, port
  end,
}

Versant.OBE = {

  -- Creates a new versant OBE instance
  -- @param host table
  -- @param port table
  -- @return o new instance of Versant OBE
  new = function(self, host, port)
    local o = { host = host, port = port, socket = nmap.new_socket() }
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  -- Connects a socket to the Versant server
  -- @return status true on success, false on failure
  -- @return err string containing the error message if status is false
  connect = function(self)
    return self.socket:connect(self.host, self.port)
  end,

  -- Closes the socket
  -- @return status true on success, false on failure
  -- @return err string containing the error message if status is false
  close = function(self)
    return self.socket:close()
  end,

  -- Get database information including file paths and hostname
  -- @return status true on success false on failure
  -- @return result table containing the fields:
  --         <code>root_path</code> - the database root directory
  --         <code>db_path</code> - the database directory
  --         <code>lib_path</code> - the library directory
  --         <code>hostname</code> - the database host name
  getVODInfo = function(self)
    local data = stdnse.fromhex("1002005d00000000000100000000000d000000000000000000000000") --28
    .. "-noprint -i " --12
    .. string.rep("\0", 216) -- 256 - (28 + 12)

    self.socket:send(data)
    local status, data = self.socket:receive_buf(match.numbytes(256), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    local len = string.unpack(">I4", data, 13)
    status, data = self.socket:receive_buf(match.numbytes(len), true)
    if ( not(status) ) then
      return false, "Failed to read response from server"
    end

    local result = {}
    local offset = 13
    result.version = string.unpack("z", data)

    for _, item in ipairs({"root_path", "db_path", "lib_path", "hostname"}) do
      result[item] = string.unpack("z", data, offset)
      offset = offset + 256
    end
    return true, result
  end,
}

return _ENV;
