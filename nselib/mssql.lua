---
-- MSSQL Library supporting a very limited subset of operations.
--
-- The library was designed and tested against Microsoft SQL Server 2005.
-- However, it should work with versions 7.0, 2000, 2005, 2008 and 2012.
-- Only a minimal amount of parsers have been added for tokens, column types
-- and column data in order to support the first scripts.
--
-- The code has been implemented based on traffic analysis and the following
-- documentation:
-- * SSRP Protocol Specification: http://msdn.microsoft.com/en-us/library/cc219703.aspx
-- * TDS Protocol Specification: http://msdn.microsoft.com/en-us/library/dd304523.aspx
-- * TDS Protocol Documentation: http://www.freetds.org/tds.html.
-- * The JTDS source code: http://jtds.sourceforge.net/index.html.
--
-- * SSRP: Class that handles communication over the SQL Server Resolution Protocol, used for identifying instances on a host.
-- * ColumnInfo: Class containing parsers for column types which are present before the row data in all query response packets. The column information contains information relevant to the data type used to hold the data eg. precision, character sets, size etc.
-- * ColumnData: Class containing parsers for the actual column information.
-- * Token: Class containing parsers for tokens returned in all TDS responses. A server response may hold one or more tokens with information from the server. Each token has a type which has a number of type specific fields.
-- * QueryPacket: Class used to hold a query and convert it to a string suitable for transmission over a socket.
-- * LoginPacket: Class used to hold login specific data which can easily be converted to a string suitable for transmission over a socket.
-- * PreLoginPacket: Class used to (partially) implement the TDS PreLogin packet
-- * TDSStream: Class that handles communication over the Tabular Data Stream protocol used by SQL serve. It is used to transmit the Query- and Login-packets to the server.
-- * Helper: Class which facilitates the use of the library by through action oriented functions with descriptive names.
-- * Util: A "static" class containing mostly character and type conversion functions.
--
-- The following sample code illustrates how scripts can use the Helper class
-- to interface the library:
--
-- <code>
-- local helper = mssql.Helper:new()
-- status, result = helper:Connect( host, port )
-- status, result = helper:Login( username, password, "temdpb", host.ip )
-- status, result = helper:Query( "SELECT name FROM master..syslogins" )
-- helper:Disconnect()
-- </code>
--
-- The following sample code illustrates how scripts can use the Helper class
-- with pre-discovered instances (e.g. by <code>ms-sql-discover</code> or <code>broadcast-ms-sql-discover</code>):
--
-- <code>
-- local instances = mssql.Helper.GetDiscoveredInstances( host, port )
-- if ( instances ) then
--   local instance = next(instances)
--   local helper = mssql.Helper:new()
--   status, result = helper:ConnectEx( instance )
--   status, result = helper:LoginEx( instance )
--   status, result = helper:Query( "SELECT name FROM master..syslogins" )
--   helper:Disconnect()
-- end
-- </code>
--
-- Known limitations:
-- * The library does not support SSL. The foremost reason being the awkward choice of implementation where the SSL handshake is performed within the TDS data block. By default, servers support connections over non SSL connections though.
-- * Version 7 and ONLY version 7 of the protocol is supported. This should cover Microsoft SQL Server 7.0 and later.
-- * TDS Responses contain one or more response tokens which are parsed based on their type. The supported tokens are listed in the <code>TokenType</code> table and their respective parsers can be found in the <code>Token</code> class. Note that some token parsers are not fully implemented and simply move the offset the right number of bytes to continue processing of the response.
-- * The library only supports a limited subsets of datatypes and will abort execution and return an error if it detects an unsupported type. The supported data types are listed in the <code>DataTypes</code> table. In order to add additional data types a parser function has to be added to both the <code>ColumnInfo</code> and <code>ColumnData</code> class.
-- * No functionality for languages, localization or character codepages has been considered or implemented.
-- * The library does database authentication only. No OS authentication or use of the integrated security model is supported.
-- * Queries using SELECT, INSERT, DELETE and EXEC of procedures have been tested while developing scripts.
--
-- @copyright Same as Nmap--See https://nmap.org/book/man-legal.html
--
-- @author Patrik Karlsson <patrik@cqure.net>
-- @author Chris Woodbury
--
-- @args mssql.username The username to use to connect to SQL Server instances.
--       This username is used by scripts taking actions that require
--       authentication (e.g. <code>ms-sql-query</code>) This username (and its
--       associated password) takes precedence over any credentials discovered
--       by the <code>ms-sql-brute</code> and <code>ms-sql-empty-password</code>
--       scripts.
--
-- @args mssql.password The password for <code>mssql.username</code>. If this
--       argument is not given but <code>mssql.username</code>, a blank password
--       is used.
--
-- @args mssql.instance-name In addition to instances discovered via port
--                           scanning and version detection, run scripts on
--                           these named instances (string or list of strings)
--
-- @args mssql.instance-port In addition to instances discovered via port
--                           scanning and version detection, run scripts on
--                           the instances running on these ports (number or list of numbers)
--
-- @args mssql.instance-all In addition to instances discovered via port
--                           scanning and version detection, run scripts on all
--                           discovered instances. These include named-pipe
--                           instances via SMB and those discovered via the
--                           browser service.
--
-- @args mssql.domain The domain against which to perform integrated
--       authentication. When set, the scripts assume integrated authentication
--       should be performed, rather than the default sql login.
--
-- @args mssql.protocol The protocol to use to connect to the instance. The
--       protocol may be either <code>NP</code>,<code>Named Pipes</code> or
--       <code>TCP</code>.
--
-- @args mssql.timeout How long to wait for SQL responses. This is a number
--       followed by <code>ms</code> for milliseconds, <code>s</code> for
--       seconds, <code>m</code> for minutes, or <code>h</code> for hours.
--       Default: <code>30s</code>.
--
-- @args mssql.scanned-ports-only If set, the script will only connect
--       to ports that were included in the Nmap scan. This may result in
--       instances not being discovered, particularly if UDP port 1434 is not
--       included. Additionally, instances that are found to be running on
--       ports that were not scanned (e.g. if 1434/udp is in the scan and the
--       SQL Server Browser service on that port reports an instance
--       listening on 43210/tcp, which was not scanned) will be reported but
--       will not be stored for use by other ms-sql-* scripts.

local math = require "math"
local match = require "match"
local nmap = require "nmap"
local datetime = require "datetime"
local outlib = require "outlib"
local smb = require "smb"
local smbauth = require "smbauth"
local stdnse = require "stdnse"
local strbuf = require "strbuf"
local string = require "string"
local table = require "table"
local tableaux = require "tableaux"
local unicode = require "unicode"
_ENV = stdnse.module("mssql", stdnse.seeall)

-- Created 01/17/2010 - v0.1 - created by Patrik Karlsson <patrik@cqure.net>
-- Revised 03/28/2010 - v0.2 - fixed incorrect token types. added 30 seconds timeout
-- Revised 01/23/2011 - v0.3 - fixed parsing error in discovery code with patch
--                             from Chris Woodbury
-- Revised 02/01/2011 - v0.4 - numerous changes and additions to support new
--                             functionality in ms-sql- scripts and to be more
--                             robust in parsing and handling data. (Chris Woodbury)
-- Revised 02/19/2011 - v0.5 - numerous changes in script, library behaviour
--                             * huge improvements in version detection
--                             * added support for named pipes
--                             * added support for integrated NTLMv1 authentication
--
--                             (Patrik Karlsson, Chris Woodbury)
-- Revised 08/19/2012 - v0.6 - added multiple data types
--                             * added detection and handling of null values when processing query responses from the server
--                             * added DoneProc response token support
--
--                             (Tom Sellers)
-- Updated 10/01/2012 - v0.7 - added support for 2012 and later service packs for 2005, 2008 and 2008 R2 (Rob Nicholls)
-- Updated 02/06/2015 - v0.8 - added support for 2014 and later service packs for older versions (Rob Nicholls)

local HAVE_SSL, openssl = pcall(require, "openssl")

do
  namedpipes = smb.namedpipes
  local arg = stdnse.get_script_args( "mssql.timeout" ) or "30s"

  local timeout, err = stdnse.parse_timespec(arg)
  if not timeout then
    error(err)
  end
  MSSQL_TIMEOUT = timeout

end

-- Make args either a list or nil
local function list_of (input, transform)
  if not input then return nil end
  if type(input) ~= "table" then
    return {transform(input)}
  end
  for i, v in ipairs(input) do
    input[i] = transform(v)
  end
  return input
end

local SCANNED_PORTS_ONLY = not not stdnse.get_script_args("mssql.scanned-ports-only")
local targetInstanceNames = list_of(stdnse.get_script_args("mssql.instance-name"), string.upper)
local targetInstancePorts = list_of(stdnse.get_script_args("mssql.instance-port"), tonumber)
local targetAllInstances = not not stdnse.get_script_args("mssql.instance-all")

-- This constant is number of seconds from 1900-01-01 to 1970-01-01
local tds_offset_seconds = -2208988800 - datetime.utc_offset()

-- *************************************
-- Informational Classes
-- *************************************

--- SqlServerInstanceInfo class
SqlServerInstanceInfo =
{
  instanceName = nil,
  version = nil,
  serverName = nil,
  isClustered = nil,
  host = nil,
  port = nil,
  pipeName = nil,

  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  -- Compares two SqlServerInstanceInfo objects and determines whether they
  -- refer to the same SQL Server instance, judging by a combination of host,
  -- port, named pipe information and instance name.
  __eq = function( self, other )
    local areEqual
    if ( not (self.host and other.host) ) then
      -- if they don't both have host information, we certainly can't say
      -- whether they're the same
      areEqual = false
    else
      areEqual = (self.host.ip == other.host.ip)
    end

    if (self.port and other.port) then
      areEqual = areEqual and ( other.port.number == self.port.number and
        other.port.protocol == self.port.protocol )
    elseif (self.pipeName and other.pipeName) then
      areEqual = areEqual and (self.pipeName == other.pipeName)
    elseif (self.instanceName and other.instanceName) then
      areEqual = areEqual and (self.instanceName == other.instanceName)
    else
      -- if we have neither port nor named pipe info nor instance names,
      -- we can't say whether they're the same
      areEqual = false
    end

    return areEqual
  end,

  --- Merges the data from one SqlServerInstanceInfo object into another.
  --
  -- Each field in the first object is populated with the data from that field
  -- in second object if the first object's field is nil OR if
  -- <code>overwrite</code> is set to true. A special case is made for the
  -- <code>version</code> field, which is only overwritten in the second object
  -- has more reliable version information. The second object is not modified.
  Merge = function( self, other, overwrite )
    local mergeFields = { "host", "port", "instanceName", "version", "isClustered", "pipeName" }
    for _, fieldname in ipairs( mergeFields ) do
      -- Add values from other only if self doesn't have a value, or if overwrite is true
      if ( other[ fieldname ] ~= nil and (overwrite or self[ fieldname ] == nil) ) then
        self[ fieldname ] = other[ fieldname ]
      end
    end
    if (self.version and self.version.source == "SSRP" and
        other.version and other.version.Source == "SSNetLib") then
      self.version = other.version
    end
  end,

  --- Returns a name for the instance, based on the available information.
  --
  -- This may take one of the following forms:
  --  * HOST\INSTANCENAME
  --  * PIPENAME
  --  * HOST:PORT
  GetName = function( self )
    if (self.instanceName) then
      return string.format( "%s\\%s", self.host.ip or self.serverName or "[nil]", self.instanceName or "[nil]" )
    elseif (self.pipeName) then
      return string.format( "%s", self.pipeName )
    else
      return string.format( "%s:%s",  self.host.ip or self.serverName or "[nil]", (self.port and self.port.number) or "[nil]" )
    end
  end,

  --- Sets whether the instance is in a cluster
  --
  -- @param self
  -- @param isClustered Boolean true or the string "Yes" are interpreted as true;
  --         all other values are interpreted as false.
  SetIsClustered = function( self, isClustered )
    self.isClustered = (isClustered == true) or (isClustered == "Yes")
  end,

  --- Indicates whether this instance has networking protocols enabled, such
  --  that scripts could attempt to connect to it.
  HasNetworkProtocols = function( self )
    return (self.pipeName ~= nil) or (self.port and self.port.number)
  end,
}


--- SqlServerVersionInfo class
SqlServerVersionInfo =
{
  versionNumber = "", -- The full version string (e.g. "9.00.2047.00")
  major = nil, -- The major version (e.g. 9)
  minor = nil, -- The minor version (e.g. 0)
  build = nil, -- The build number (e.g. 2047)
  subBuild = nil, -- The sub-build number (e.g. 0)
  productName = nil, -- The product name (e.g. "SQL Server 2005")
  brandedVersion = nil, -- The branded version of the product (e.g. "2005")
  servicePackLevel = nil, -- The service pack level (e.g. "SP1")
  patched = nil, -- Whether patches have been applied since SP installation (true/false/nil)
  source = nil, -- The source of the version info (e.g. "SSRP", "SSNetLib")

  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  --- Sets the version using a version number string.
  --
  -- @param versionNumber a version number string (e.g. "9.00.1399.00")
  -- @param source a string indicating the source of the version info (e.g. "SSRP", "SSNetLib")
  SetVersionNumber = function(self, versionNumber, source)
    local parts = {versionNumber:match("^(%d+)%.(%d+)%.(%d+)")}
    if not parts[1] then
      stdnse.debug1("%s: SetVersionNumber: versionNumber is not in correct format: %s", "MSSQL", versionNumber or "nil" )
      return
    end

    -- If it doesn't match, subBuild will be nil
    parts[4] = versionNumber:match( "^%d+%.%d+%.%d+%.(%d+)" )
    parts[5] = source

    self:SetVersion( table.unpack(parts) )
  end,

  --- Sets the version using the individual numeric components of the version
  --  number.
  --
  -- @param source a string indicating the source of the version info (e.g. "SSRP", "SSNetLib")
  SetVersion = function(self, major, minor, build, subBuild, source)
    self.source = source
    -- make sure our version numbers all end up as valid numbers
    self.major, self.minor, self.build, self.subBuild =
      tonumber( major or 0 ), tonumber( minor or 0 ), tonumber( build or 0 ), tonumber( subBuild or 0 )

    self.versionNumber = string.format( "%u.%02u.%u.%02u", self.major, self.minor, self.build, self.subBuild )

    self:_ParseVersionInfo()
  end,

  --- Using the version number, determines the product version
  _InferProductVersion = function(self)

    local VERSION_LOOKUP_TABLE = {
      ["^6%.0"] = "6.0", ["^6%.5"] = "6.5", ["^7%.0"] = "7.0",
      ["^8%.0"] = "2000", ["^9%.0"] = "2005", ["^10%.0"] = "2008",
      ["^10%.50"] = "2008 R2", ["^11%.0"] = "2012", ["^12%.0"] = "2014",
      ["^13%.0"] = "2016", ["^14%.0"] = "2017", ["^15%.0"] = "2019",
      ["^16%.0"] = "2022",
    }

    local product = ""

    for m, v in pairs(VERSION_LOOKUP_TABLE) do
      if ( self.versionNumber:match(m) ) then
        product = v
        self.brandedVersion = product
        break
      end
    end

    self.productName = ("Microsoft SQL Server %s"):format(product)

  end,


  --- Returns a lookup table that maps revision numbers to service pack and
  --  cumulative update levels for the applicable SQL Server version,
  --  e.g., {{1913, "RC1"}, {2100, "RTM"}, {2316, "RTMCU1"}, ...,
  --        {3000, "SP1"}, {3321, "SP1CU1"}, ..., {3368, "SP1CU4"}, ...}
  _GetSpLookupTable = function(self)

    -- Service pack lookup tables:
    -- For instances where a revised service pack was released, e.g. 2000 SP3a,
    -- we will include the build number for the original SP and the build number
    -- for the revision. However, leaving it like this would make it appear that
    -- subsequent builds were a patched version of the revision, e.g., a patch
    -- applied to 2000 SP3 that increased the build number to 780 would get
    -- displayed as "SP3a+", when it was actually SP3+. To avoid this, we will
    -- include an additional fake build number that combines the two.
    -- Source: https://sqlserverbuilds.blogspot.com/
    local SP_LOOKUP_TABLE = {
      ["6.5"] = {
        {201, "RTM"},
        {213, "SP1"},
        {240, "SP2"},
        {258, "SP3"},
        {281, "SP4"},
        {415, "SP5"},
        {416, "SP5a"},
        {417, "SP5/SP5a"},
      },

      ["7.0"] = {
        {623, "RTM"},
        {699, "SP1"},
        {842, "SP2"},
        {961, "SP3"},
        {1063, "SP4"},
      },

      ["2000"] = {
        {194, "RTM"},
        {384, "SP1"},
        {532, "SP2"},
        {534, "SP2"},
        {760, "SP3"},
        {766, "SP3a"},
        {767, "SP3/SP3a"},
        {2039, "SP4"},
      },

      ["2005"] = {
        {1399, "RTM"},
        {2047, "SP1"},
        {3042, "SP2"},
        {4035, "SP3"},
        {5000, "SP4"},
      },

      ["2008"] = {
        {1600, "RTM"},
        {2531, "SP1"},
        {4000, "SP2"},
        {5500, "SP3"},
        {6000, "SP4"},
      },

      ["2008 R2"] = {
        {1600, "RTM"},
        {2500, "SP1"},
        {4000, "SP2"},
        {6000, "SP3"},
      },

      ["2012"] = {
        {1103, "CTP1"},
        {1440, "CTP3"},
        {1750, "RC0"},
        {1913, "RC1"},
        {2100, "RTM"},
        {2316, "RTMCU1"},
        {2325, "RTMCU2"},
        {2332, "RTMCU3"},
        {2383, "RTMCU4"},
        {2395, "RTMCU5"},
        {2401, "RTMCU6"},
        {2405, "RTMCU7"},
        {2410, "RTMCU8"},
        {2419, "RTMCU9"},
        {2420, "RTMCU10"},
        {2424, "RTMCU11"},
        {3000, "SP1"},
        {3321, "SP1CU1"},
        {3339, "SP1CU2"},
        {3349, "SP1CU3"},
        {3368, "SP1CU4"},
        {3373, "SP1CU5"},
        {3381, "SP1CU6"},
        {3393, "SP1CU7"},
        {3401, "SP1CU8"},
        {3412, "SP1CU9"},
        {3431, "SP1CU10"},
        {3449, "SP1CU11"},
        {3470, "SP1CU12"},
        {3482, "SP1CU13"},
        {3486, "SP1CU14"},
        {3487, "SP1CU15"},
        {3492, "SP1CU16"},
        {5058, "SP2"},
        {5532, "SP2CU1"},
        {5548, "SP2CU2"},
        {5556, "SP2CU3"},
        {5569, "SP2CU4"},
        {5582, "SP2CU5"},
        {5592, "SP2CU6"},
        {5623, "SP2CU7"},
        {5634, "SP2CU8"},
        {5641, "SP2CU9"},
        {5644, "SP2CU10"},
        {5646, "SP2CU11"},
        {5649, "SP2CU12"},
        {5655, "SP2CU13"},
        {5657, "SP2CU14"},
        {5676, "SP2CU15"},
        {5678, "SP2CU16"},
        {6020, "SP3"},
        {6518, "SP3CU1"},
        {6523, "SP3CU2"},
        {6537, "SP3CU3"},
        {6540, "SP3CU4"},
        {6544, "SP3CU5"},
        {6567, "SP3CU6"},
        {6579, "SP3CU7"},
        {6594, "SP3CU8"},
        {6598, "SP3CU9"},
        {6607, "SP3CU10"},
        {7001, "SP4"},
      },

      ["2014"] = {
        {1524, "CTP2"},
        {2000, "RTM"},
        {2342, "RTMCU1"},
        {2370, "RTMCU2"},
        {2402, "RTMCU3"},
        {2430, "RTMCU4"},
        {2456, "RTMCU5"},
        {2480, "RTMCU6"},
        {2495, "RTMCU7"},
        {2546, "RTMCU8"},
        {2553, "RTMCU9"},
        {2556, "RTMCU10"},
        {2560, "RTMCU11"},
        {2564, "RTMCU12"},
        {2568, "RTMCU13"},
        {2569, "RTMCU14"},
        {4100, "SP1"},
        {4416, "SP1CU1"},
        {4422, "SP1CU2"},
        {4427, "SP1CU3"},
        {4436, "SP1CU4"},
        {4439, "SP1CU5"},
        {4449, "SP1CU6"},
        {4459, "SP1CU7"},
        {4468, "SP1CU8"},
        {4474, "SP1CU9"},
        {4491, "SP1CU10"},
        {4502, "SP1CU11"},
        {4511, "SP1CU12"},
        {4522, "SP1CU13"},
        {5000, "SP2"},
        {5511, "SP2CU1"},
        {5522, "SP2CU2"},
        {5538, "SP2CU3"},
        {5540, "SP2CU4"},
        {5546, "SP2CU5"},
        {5553, "SP2CU6"},
        {5556, "SP2CU7"},
        {5557, "SP2CU8"},
        {5563, "SP2CU9"},
        {5571, "SP2CU10"},
        {5579, "SP2CU11"},
        {5589, "SP2CU12"},
        {5590, "SP2CU13"},
        {5600, "SP2CU14"},
        {5605, "SP2CU15"},
        {5626, "SP2CU16"},
        {5632, "SP2CU17"},
        {5687, "SP2CU18"},
        {6024, "SP3"},
        {6205, "SP3CU1"},
        {6214, "SP3CU2"},
        {6259, "SP3CU3"},
        {6329, "SP3CU4"},
      },

      ["2016"] = {
        { 200, "CTP2"},
        { 300, "CTP2.1"},
        { 407, "CTP2.2"},
        { 500, "CTP2.3"},
        { 600, "CTP2.4"},
        { 700, "CTP3.0"},
        { 800, "CTP3.1"},
        { 900, "CTP3.2"},
        {1000, "CTP3.3"},
        {1100, "RC0"},
        {1200, "RC1"},
        {1300, "RC2"},
        {1400, "RC3"},
        {1601, "RTM"},
        {2149, "RTMCU1"},
        {2164, "RTMCU2"},
        {2186, "RTMCU3"},
        {2193, "RTMCU4"},
        {2197, "RTMCU5"},
        {2204, "RTMCU6"},
        {2210, "RTMCU7"},
        {2213, "RTMCU8"},
        {2216, "RTMCU9"},
        {4001, "SP1"},
        {4411, "SP1CU1"},
        {4422, "SP1CU2"},
        {4435, "SP1CU3"},
        {4446, "SP1CU4"},
        {4451, "SP1CU5"},
        {4457, "SP1CU6"},
        {4466, "SP1CU7"},
        {4474, "SP1CU8"},
        {4502, "SP1CU9"},
        {4514, "SP1CU10"},
        {4528, "SP1CU11"},
        {4541, "SP1CU12"},
        {4550, "SP1CU13"},
        {4560, "SP1CU14"},
        {4574, "SP1CU15"},
        {5026, "SP2"},
        {5149, "SP2CU1"},
        {5153, "SP2CU2"},
        {5216, "SP2CU3"},
        {5233, "SP2CU4"},
        {5264, "SP2CU5"},
        {5292, "SP2CU6"},
        {5337, "SP2CU7"},
        {5426, "SP2CU8"},
        {5479, "SP2CU9"},
        {5492, "SP2CU10"},
        {5598, "SP2CU11"},
        {5698, "SP2CU12"},
        {5820, "SP2CU13"},
        {5830, "SP2CU14"},
        {5850, "SP2CU15"},
        {5882, "SP2CU16"},
        {5888, "SP2CU17"},
        {6300, "SP3"},
      },

      ["2017"] = {
        {   1, "CTP1"},
        { 100, "CTP1.1"},
        { 200, "CTP1.2"},
        { 304, "CTP1.3"},
        { 405, "CTP1.4"},
        { 500, "CTP2.0"},
        { 600, "CTP2.1"},
        { 800, "RC1"},
        { 900, "RC2"},
        {1000, "RTM"},
        {3006, "CU1"},
        {3008, "CU2"},
        {3015, "CU3"},
        {3022, "CU4"},
        {3023, "CU5"},
        {3025, "CU6"},
        {3026, "CU7"},
        {3029, "CU8"},
        {3030, "CU9"},
        {3037, "CU10"},
        {3038, "CU11"},
        {3045, "CU12"},
        {3048, "CU13"},
        {3076, "CU14"},
        {3162, "CU15"},
        {3223, "CU16"},
        {3238, "CU17"},
        {3257, "CU18"},
        {3281, "CU19"},
        {3294, "CU20"},
        {3335, "CU21"},
        {3356, "CU22"},
        {3381, "CU23"},
        {3391, "CU24"},
        {3401, "CU25"},
        {3411, "CU26"},
        {3421, "CU27"},
        {3430, "CU28"},
        {3436, "CU29"},
        {3451, "CU30"},
        {3456, "CU31"},
      },

      ["2019"] = {
        {1000, "CTP2.0"},
        {1100, "CTP2.1"},
        {1200, "CTP2.2"},
        {1300, "CTP2.3"},
        {1400, "CTP2.4"},
        {1500, "CTP2.5"},
        {1600, "CTP3.0"},
        {1700, "CTP3.1"},
        {1800, "CTP3.2"},
        {1900, "RC1"},
        {2000, "RTM"},
        {2070, "GDR1"},
        {4003, "CU1"},
        {4013, "CU2"},
        {4023, "CU3"},
        {4033, "CU4"},
        {4043, "CU5"},
        {4053, "CU6"},
        {4063, "CU7"},
        {4073, "CU8"},
        {4102, "CU9"},
        {4123, "CU10"},
        {4138, "CU11"},
        {4153, "CU12"},
        {4178, "CU13"},
        {4188, "CU14"},
        {4198, "CU15"},
        {4223, "CU16"},
        {4249, "CU17"},
        {4261, "CU18"},
        {4298, "CU19"},
        {4312, "CU20"},
        {4316, "CU21"},
        {4322, "CU22"},
        {4335, "CU23"},
        {4345, "CU24"},
        {4355, "CU25"},
      },

      ["2022"] = {
        {100, "CTP1.0"},
        {101, "CTP1.1"},
        {200, "CTP1.2"},
        {300, "CTP1.3"},
        {400, "CTP1.4"},
        {500, "CTP1.5"},
        {600, "CTP2.0"},
        {700, "CTP2.1"},
        {900, "RC0"},
        {950, "RC1"},
        {1000, "RTM"},
        {4003, "CU1"},
        {4015, "CU2"},
        {4025, "CU3"},
        {4035, "CU4"},
        {4045, "CU5"},
        {4055, "CU6"},
        {4065, "CU7"},
        {4075, "CU8"},
        {4085, "CU9"},
        {4095, "CU10"},
        {4105, "CU11"},
      },
    }


    if ( not self.brandedVersion ) then
      self:_InferProductVersion()
    end

    local spLookupTable = SP_LOOKUP_TABLE[self.brandedVersion]
    stdnse.debug1("brandedVersion: %s, #lookup: %d", self.brandedVersion, spLookupTable and #spLookupTable or 0)

    return spLookupTable

  end,


  --- Processes version data to determine (if possible) the product version,
  --  service pack level and patch status.
  _ParseVersionInfo = function(self)

    local spLookupTable = self:_GetSpLookupTable()

    if spLookupTable then

      local spLookupItr = 0
      -- Loop through the service pack levels until we find one whose revision
      -- number is the same as or lower than our revision number.
      while spLookupItr < #spLookupTable do
        spLookupItr = spLookupItr + 1

        if (spLookupTable[ spLookupItr ][1] == self.build ) then
          spLookupItr = spLookupItr
          break
        elseif (spLookupTable[ spLookupItr ][1] > self.build ) then
          -- The target revision number is lower than the first release
          if spLookupItr == 1 then
            self.servicePackLevel = "Pre-RTM"
          else
            -- we went too far - it's the previous SP, but with patches applied
            spLookupItr = spLookupItr - 1
          end
          break
        end
      end

      -- Now that we've identified the proper service pack level:
      if self.servicePackLevel ~= "Pre-RTM" then
        self.servicePackLevel = spLookupTable[ spLookupItr ][2]

        if ( spLookupTable[ spLookupItr ][1] == self.build ) then
          self.patched = false
        else
          self.patched = true
        end
      end

      -- Clean up some of our inferences. If the source of our revision number
      -- was the SSRP (SQL Server Browser) response, we need to recognize its
      -- limitations:
      --  * Versions of SQL Server prior to 2005 are reported with the RTM build
      --    number, regardless of the actual version (e.g. SQL Server 2000 is
      --    always 8.00.194).
      --  * Versions of SQL Server starting with 2005 (and going through at least
      --    2008) do better but are still only reported with the build number as
      --    of the last service pack (e.g. SQL Server 2005 SP3 with patches is
      --    still reported as 9.00.4035.00).
      if ( self.source == "SSRP" ) then
        self.patched = nil

        if ( self.major <= 8 ) then
          self.servicePackLevel = nil
        end
      end
    end

    return true
  end,

  ---
  ToString = function(self)
    local friendlyVersion = strbuf.new()
    if self.productName then
      friendlyVersion:concatbuf( self.productName )
      if self.servicePackLevel then
        friendlyVersion:concatbuf( " " )
        friendlyVersion:concatbuf( self.servicePackLevel )
      end
      if self.patched then
        friendlyVersion:concatbuf( "+" )
      end
    end

    return friendlyVersion:dump()
  end,

  --- Uses the information in this SqlServerVersionInformation object to
  --  populate the version information in an Nmap port table for a SQL Server
  --  TCP listener.
  --
  --  @param self A SqlServerVersionInformation object
  --  @param port An Nmap port table corresponding to the instance
  PopulateNmapPortVersion = function(self, port)

    port.service = "ms-sql-s"
    port.version = port.version or {}
    port.version.name = "ms-sql-s"
    port.version.product = self.productName

    local versionString = strbuf.new()
    if self.source ~= "SSRP" then
      versionString:concatbuf( self.versionNumber )
      if self.servicePackLevel then
        versionString:concatbuf( "; " )
        versionString:concatbuf( self.servicePackLevel )
      end
      if self.patched then
        versionString:concatbuf( "+" )
      end
      port.version.version = versionString:dump()
    end

    return port
  end,
}


-- *************************************
-- SSRP (SQL Server Resolution Protocol)
-- *************************************
SSRP =
{
  PORT = { number = 1434, protocol = "udp" },
  DEBUG_ID = "MSSQL-SSRP",

  MESSAGE_TYPE =
  {
    ClientBroadcast = 0x02,
    ClientUnicast = 0x03,
    ClientUnicastInstance = 0x04,
    ClientUnicastDAC = 0x0F,
    ServerResponse = 0x05,
  },

  --- Parses an SSRP string and returns a table containing one or more
  --  SqlServerInstanceInfo objects created from the parsed string.
  _ParseSsrpString = function( host, ssrpString )
    -- It would seem easier to just capture (.-;;) repeatedly, since
    -- each instance ends with ";;", but ";;" can also occur within the
    -- data, signifying an empty field (e.g. "...bv;;@COMPNAME;;tcp;1433;;...").
    -- So, instead, we'll split up the string ahead of time.
    -- See the SSRP specification for more details.

    local instanceStrings = {}
    local firstInstanceEnd, instanceString
    repeat
      firstInstanceEnd = ssrpString:find( ";ServerName;(.-);InstanceName;(.-);IsClustered;(.-);" )
      if firstInstanceEnd then
        instanceString = ssrpString:sub( 1, firstInstanceEnd )
        ssrpString = ssrpString:sub( firstInstanceEnd + 1 )
      else
        instanceString = ssrpString
      end

      table.insert( instanceStrings, instanceString )
    until (not firstInstanceEnd)
    stdnse.debug2("%s: SSRP Substrings:\n  %s", SSRP.DEBUG_ID, table.concat(instanceStrings , "\n  ") )

    local instances = {}
    for _, instanceString in ipairs( instanceStrings ) do
      local instance = SqlServerInstanceInfo:new()
      local version = SqlServerVersionInfo:new()
      instance.version = version

      instance.host = host
      instance.serverName = instanceString:match( "ServerName;(.-);")
      instance.instanceName = instanceString:match( "InstanceName;(.-);")
      instance:SetIsClustered( instanceString:match( "IsClustered;(.-);") )
      version:SetVersionNumber( instanceString:match( "Version;(.-);"), "SSRP" )

      local tcpPort = tonumber( instanceString:match( ";tcp;(.-);") )
      if tcpPort then instance.port = {number = tcpPort, protocol = "tcp"} end

      local pipeName = instanceString:match( ";np;(.-);")
      local status, pipeSubPath = namedpipes.get_pipe_subpath( pipeName )
      if status then
        pipeName = namedpipes.make_pipe_name( host.ip, pipeSubPath )
      elseif pipeName ~= nil then
        stdnse.debug1("%s: Invalid pipe name:\n%s", SSRP.DEBUG_ID, pipeName )
      end
      instance.pipeName = pipeName

      table.insert( instances, instance )
    end

    return instances
  end,

  ---
  _ProcessResponse = function( host, responseData )
    local instances

    local pos, messageType, dataLength = 1, nil, nil
    messageType, dataLength, pos = string.unpack("<BI2", responseData, 1)
    -- extract the response data (i.e. everything after the 3-byte header)
    responseData = responseData:sub(4)
    stdnse.debug2("%s: SSRP Data: %s", SSRP.DEBUG_ID, responseData )
    if ( messageType ~= SSRP.MESSAGE_TYPE.ServerResponse or
        dataLength ~= responseData:len() ) then

      stdnse.debug2("%s: Invalid SSRP response. Type: 0x%02x, Length: %d, Actual length: %d",
        SSRP.DEBUG_ID, messageType, dataLength, responseData:len() )
    else
      instances = SSRP._ParseSsrpString( host, responseData )
    end

    return instances
  end,

  ---  Attempts to retrieve information about SQL Server instances by querying
  --  the SQL Server Browser service on a host.
  --
  --  @param host A host table for the target host
  --  @param port (Optional) A port table for the target SQL Server Browser service
  --  @return (status, result) If status is true, result is a table of
  --    SqlServerInstanceInfo objects. If status is false, result is an
  --    error message.
  DiscoverInstances = function( host, port )
    port = port or SSRP.PORT

    if ( SCANNED_PORTS_ONLY and nmap.get_port_state( host, port ) == nil ) then
      stdnse.debug2("%s: Discovery disallowed: scanned-ports-only is set and port %d was not scanned", SSRP.DEBUG_ID, port.number )
      return false, "Discovery disallowed: scanned-ports-only"
    end

    local socket = nmap.new_socket("udp")
    socket:set_timeout(5000)

    if ( port.number ~= SSRP.PORT.number ) then
      stdnse.debug1("%s: DiscoverInstances() called with non-standard port (%d)", SSRP.DEBUG_ID, port.number )
    end

    local status, err = socket:connect( host, port )
    if ( not(status) ) then return false, err end
    status, err = socket:send( string.pack( "B", SSRP.MESSAGE_TYPE.ClientUnicast ) )
    if ( not(status) ) then return false, err end

    local responseData, instances_host
    status, responseData = socket:receive()
    if ( not(status) ) then return false, responseData
    else
      instances_host = SSRP._ProcessResponse( host, responseData )
    end
    socket:close()

    return status, instances_host
  end,


  --- Attempts to retrieve information about SQL Server instances by querying
  -- the SQL Server Browser service on a broadcast domain.
  --
  -- @param host A host table for the broadcast specification
  -- @param port (Optional) A port table for the target SQL Server Browser service
  -- @return (status, result) If status is true, result is a table of
  --         tables containing SqlServerInstanceInfo objects. The top-level table
  --         is indexed by IP address. If status is false, result is an
  --         error message.
  DiscoverInstances_Broadcast = function( host, port )
    port = port or SSRP.PORT

    local socket = nmap.new_socket("udp")
    socket:set_timeout(5000)
    local instances_all = {}

    if ( port.number ~= SSRP.PORT.number ) then
      stdnse.debug1("%S: DiscoverInstances_Broadcast() called with non-standard port (%d)", SSRP.DEBUG_ID, port.number )
    end

    local status, err = socket:sendto(host, port, string.pack( "B", SSRP.MESSAGE_TYPE.ClientBroadcast ))
    if ( not(status) ) then return false, err end

    while ( status ) do
      local responseData
      status, responseData = socket:receive()
      if ( status ) then
        local remoteIp, _
        status, _, _, remoteIp, _ = socket:get_info()
        local instances_host = SSRP._ProcessResponse( {ip = remoteIp, name = ""}, responseData )
        instances_all[ remoteIp ] = instances_host
      end
    end
    socket:close()

    return true, instances_all
  end,
}



-- *************************
-- TDS (Tabular Data Stream)
-- *************************

-- TDS packet types
PacketType =
{
  Query = 0x01,
  Response = 0x04,
  Login = 0x10,
  NTAuthentication = 0x11,
  PreLogin = 0x12,
}

-- TDS response token types
TokenType =
{
  ReturnStatus         = 0x79,
  TDS7Results          = 0x81,
  ErrorMessage         = 0xAA,
  InformationMessage   = 0xAB,
  LoginAcknowledgement = 0xAD,
  Row                  = 0xD1,
  OrderBy              = 0xA9,
  EnvironmentChange    = 0xE3,
  NTLMSSP_CHALLENGE    = 0xed,
  Done                 = 0xFD,
  DoneProc             = 0xFE,
  DoneInProc           = 0xFF,
}

-- SQL Server/Sybase data types
DataTypes =
{
  SQLTEXT       = 0x23,
  GUIDTYPE      = 0x24,
  SYBINTN       = 0x26,
  SYBINT2       = 0x34,
  SYBINT4       = 0x38,
  SYBDATETIME   = 0x3D,
  NTEXTTYPE     = 0x63,
  BITNTYPE      = 0x68,
  DECIMALNTYPE  = 0x6A,
  NUMERICNTYPE  = 0x6C,
  FLTNTYPE      = 0x6D,
  MONEYNTYPE    = 0x6E,
  SYBDATETIMN   = 0x6F,
  XSYBVARBINARY = 0xA5,
  XSYBVARCHAR   = 0xA7,
  BIGBINARYTYPE = 0xAD,
  BIGCHARTYPE   = 0xAF,
  XSYBNVARCHAR  = 0xE7,
  SQLNCHAR      = 0xEF,
}

-- SQL Server login error codes
-- See http://msdn.microsoft.com/en-us/library/ms131024.aspx
LoginErrorType =
{
  AccountLockedOut = 15113,
  NotAssociatedWithTrustedConnection = 18452, -- This probably means that the server is set for Windows authentication only
  InvalidUsernameOrPassword = 18456,
  PasswordChangeFailed_PasswordNotAllowed = 18463,
  PasswordChangeFailed_PasswordTooShort = 18464,
  PasswordChangeFailed_PasswordTooLong = 18465,
  PasswordChangeFailed_PasswordNotComplex = 18466,
  PasswordChangeFailed_PasswordFilter = 18467,
  PasswordChangeFailed_UnexpectedError = 18468,
  PasswordExpired = 18487,
  PasswordMustChange = 18488,
}

LoginErrorMessage = {}
for i, v in pairs(LoginErrorType) do
  LoginErrorMessage[v] = i
end

-- "static" ColumnInfo parser class
ColumnInfo =
{

  Parse =
  {

    [DataTypes.SQLTEXT] = function( data, pos )
      local colinfo = {}
      local tmp

      colinfo.unknown, colinfo.codepage, colinfo.flags, colinfo.charset, pos = string.unpack("<I4I2I2B", data, pos )

      colinfo.tablenamelen, pos = string.unpack("<i2", data, pos )
      colinfo.tablename, pos = string.unpack("c" .. (colinfo.tablenamelen * 2), data, pos)
      colinfo.msglen, pos = string.unpack("<B", data, pos )
      tmp, pos = string.unpack("c" .. (colinfo.msglen * 2), data, pos)

      colinfo.text = unicode.utf16to8(tmp)

      return pos, colinfo
    end,

    [DataTypes.GUIDTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.SYBINTN] = function( data, pos )
      local colinfo = {}
      local tmp

      colinfo.unknown, colinfo.msglen, pos = string.unpack("<BB", data, pos)
      tmp, pos = string.unpack("c" .. (colinfo.msglen * 2), data, pos )
      colinfo.text = unicode.utf16to8(tmp)

      return pos, colinfo
    end,

    [DataTypes.SYBINT2] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBDATETIME](data, pos)
    end,

    [DataTypes.SYBINT4] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBDATETIME](data, pos)
    end,

    [DataTypes.SYBDATETIME] = function( data, pos )
      local colinfo = {}
      local tmp

      colinfo.msglen, pos = string.unpack("B", data, pos)
      tmp, pos = string.unpack("c" .. (colinfo.msglen * 2), data, pos )
      colinfo.text = unicode.utf16to8(tmp)

      return pos, colinfo
    end,

    [DataTypes.NTEXTTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SQLTEXT](data, pos)
    end,

    [DataTypes.BITNTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.DECIMALNTYPE] = function( data, pos )
      local colinfo = {}
      local tmp

      colinfo.unknown, colinfo.precision, colinfo.scale, pos = string.unpack("<BBB", data, pos)
      colinfo.msglen, pos = string.unpack("<B",data,pos)
      tmp, pos = string.unpack("c" .. (colinfo.msglen * 2), data, pos )
      colinfo.text = unicode.utf16to8(tmp)

      return pos, colinfo
    end,

    [DataTypes.NUMERICNTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.DECIMALNTYPE](data, pos)
    end,

    [DataTypes.FLTNTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.MONEYNTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.SYBDATETIMN] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.XSYBVARBINARY] = function( data, pos )
      local colinfo = {}
      local tmp

      colinfo.lts, colinfo.msglen, pos = string.unpack("<I2B", data, pos)
      tmp, pos = string.unpack("c" .. (colinfo.msglen * 2), data, pos )
      colinfo.text = unicode.utf16to8(tmp)

      return pos, colinfo
    end,

    [DataTypes.XSYBVARCHAR] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.XSYBNVARCHAR](data, pos)
    end,

    [DataTypes.BIGBINARYTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.XSYBVARBINARY](data, pos)
    end,

    [DataTypes.BIGCHARTYPE] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.XSYBNVARCHAR](data, pos)
    end,

    [DataTypes.XSYBNVARCHAR] = function( data, pos )
      local colinfo = {}
      local tmp

      colinfo.lts, colinfo.codepage, colinfo.flags, colinfo.charset,
      colinfo.msglen, pos = string.unpack("<I2I2I2BB", data, pos )
      tmp, pos = string.unpack("c" .. (colinfo.msglen * 2), data, pos)
      colinfo.text = unicode.utf16to8(tmp)

      return pos, colinfo
    end,

    [DataTypes.SQLNCHAR] = function( data, pos )
      return ColumnInfo.Parse[DataTypes.XSYBNVARCHAR](data, pos)
    end,

  }

}

-- "static" ColumnData parser class
ColumnData =
{
  Parse = {

    [DataTypes.SQLTEXT] = function( data, pos )
      local len, coldata

      -- The first len value is the size of the meta data block
      -- for non-null values this seems to be 0x10 / 16 bytes
      len, pos = string.unpack( "<B", data, pos )

      if ( len == 0 ) then
        return pos, 'Null'
      end

      -- Skip over the text update time and date values, we don't need them
      -- We may come back add parsing for this information.
      pos = pos + len

      -- skip a label, should be 'dummyTS'
      pos = pos + 8

      -- extract the actual data
      coldata, pos = string.unpack( "<s4", data, pos )

      return pos, coldata
    end,

    [DataTypes.GUIDTYPE] = function( data, pos )
      local len, coldata, index, nextdata
      local hex = {}
      len, pos = string.unpack("B", data, pos)

      if ( len == 0 ) then
        return pos, 'Null'

      elseif ( len == 16 ) then
        -- Mixed-endian; first 3 parts are little-endian, next 2 are big-endian
        local A, B, C, D, E, pos = string.unpack("<I4I2I2>c2c6", data, pos)
        coldata = ("%08x-%04x-%04x-%s-%s"):format(A, B, C, stdnse.tohex(D), stdnse.tohex(E))
      else
        stdnse.debug1("Unhandled length (%d) for GUIDTYPE", len)
        return pos + len, 'Unsupported Data'
      end

      return pos, coldata
    end,

    [DataTypes.SYBINTN] = function( data, pos )
      local len, num
      len, pos = string.unpack("B", data, pos)

      if ( len == 0 ) then
        return pos, 'Null'
      elseif ( len <= 16 ) then
        local v, pos = string.unpack("<i" .. len, data, pos)
        return pos, v
      else
        return -1, ("Unhandled length (%d) for SYBINTN"):format(len)
      end

      return -1, "Error"
    end,

    [DataTypes.SYBINT2] = function( data, pos )
      local num
      num, pos = string.unpack("<I2", data, pos)

      return pos, num
    end,

    [DataTypes.SYBINT4] = function( data, pos )
      local num
      num, pos = string.unpack("<I4", data, pos)

      return pos, num
    end,

    [DataTypes.SYBDATETIME] = function( data, pos )
      local hi, lo

      hi, lo, pos = string.unpack("<i4I4", data, pos)

      local result_seconds = (hi*24*60*60) + (lo/300)

      local result = datetime.format_timestamp(tds_offset_seconds + result_seconds)
      return pos, result
    end,

    [DataTypes.NTEXTTYPE] = function( data, pos )
      local len, coldata

      -- The first len value is the size of the meta data block
      len, pos = string.unpack( "<B", data, pos )

      if ( len == 0 ) then
        return pos, 'Null'
      end

      -- Skip over the text update time and date values, we don't need them
      -- We may come back add parsing for this information.
      pos = pos + len

      -- skip a label, should be 'dummyTS'
      pos = pos + 8

      -- extract the actual data
      coldata, pos = string.unpack( "<s4", data, pos )

      return pos, unicode.utf16to8(coldata)
    end,

    [DataTypes.BITNTYPE] = function( data, pos )
      return ColumnData.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.DECIMALNTYPE] = function( precision, scale, data, pos )
      local len, sign, format_string, coldata

      len, pos = string.unpack("<B", data, pos)

      if ( len == 0 ) then
        return pos, 'Null'
      end

      sign, pos = string.unpack("<B", data, pos)

      -- subtract 1 from data len to account for sign byte
      len = len - 1

      if ( len > 0 and len <= 16 ) then
        coldata, pos = string.unpack("<I" .. len, data, pos)
      else
        stdnse.debug1("Unhandled length (%d) for DECIMALNTYPE", len)
        return pos + len, 'Unsupported Data'
      end

      if ( sign == 0 ) then
        coldata = coldata * -1
      end

      coldata = coldata * (10^-scale)
      -- format the return information to reduce truncation by lua
      format_string = string.format("%%.%if", scale)
      coldata = string.format(format_string,coldata)

      return pos, coldata
    end,

    [DataTypes.NUMERICNTYPE] = function( precision, scale, data, pos )
      return ColumnData.Parse[DataTypes.DECIMALNTYPE]( precision, scale, data, pos )
    end,

    [DataTypes.BITNTYPE] = function( data, pos )
      return ColumnData.Parse[DataTypes.SYBINTN](data, pos)
    end,

    [DataTypes.NTEXTTYPE] = function( data, pos )
      local len, coldata

      -- The first len value is the size of the meta data block
      len, pos = string.unpack( "<B", data, pos )

      if ( len == 0 ) then
        return pos, 'Null'
      end

      -- Skip over the text update time and date values, we don't need them
      -- We may come back add parsing for this information.
      pos = pos + len

      -- skip a label, should be 'dummyTS'
      pos = pos + 8

      -- extract the actual data
      coldata, pos = string.unpack( "<s4", data, pos )

      return pos, unicode.utf16to8(coldata)
    end,

    [DataTypes.FLTNTYPE] = function( data, pos )
      local len, coldata
      len, pos = string.unpack("<B", data, pos)

      if ( len == 0 ) then
        return pos, 'Null'
      elseif ( len == 4 ) then
        coldata, pos = string.unpack("<f", data, pos)
      elseif ( len == 8 ) then
        coldata, pos = string.unpack("<d", data, pos)
      end

      return pos, coldata
    end,

    [DataTypes.MONEYNTYPE] = function( data, pos )
      local len, value, coldata, hi, lo
      len, pos = string.unpack("B", data, pos)

      if ( len == 0 ) then
        return pos, 'Null'
      elseif ( len == 4 ) then
        --type smallmoney
        value, pos = string.unpack("<i4", data, pos)
      elseif ( len == 8 ) then
        -- type money
        hi, lo, pos = string.unpack("<I4I4", data, pos)
        value = ( hi * 0x100000000 ) + lo
      else
        return -1, ("Unhandled length (%d) for MONEYNTYPE"):format(len)
      end

      -- the datatype allows for 4 decimal places after the period to support various currency types.
      -- forcing to string to avoid truncation
      coldata = string.format("%.4f",value/10000)

      return pos, coldata
    end,

    [DataTypes.SYBDATETIMN] = function( data, pos )
      local len, coldata

      len, pos = string.unpack( "<B", data, pos )

      if ( len == 0 ) then
        return pos, 'Null'
      elseif ( len == 4 ) then
        -- format is smalldatetime
        local days, mins
        days, mins, pos = string.unpack("<I2I2", data, pos)

        local result_seconds = (days*24*60*60) + (mins*60)
        coldata = datetime.format_timestamp(tds_offset_seconds + result_seconds)

        return pos,coldata

      elseif ( len == 8 ) then
        -- format is datetime
        return ColumnData.Parse[DataTypes.SYBDATETIME](data, pos)
      else
        return -1, ("Unhandled length (%d) for SYBDATETIMN"):format(len)
      end

    end,

    [DataTypes.XSYBVARBINARY] = function( data, pos )
      local len, coldata

      len, pos = string.unpack( "<I2", data, pos )

      if ( len == 65535 ) then
        return pos, 'Null'
      else
        coldata, pos = string.unpack( "c"..len, data, pos )
        return pos, "0x" .. stdnse.tohex(coldata)
      end

      return -1, "Error"
    end,

    [DataTypes.XSYBVARCHAR] = function( data, pos )
      local len, coldata

      len, pos = string.unpack( "<I2", data, pos )
      if ( len == 65535 ) then
        return pos, 'Null'
      end

      coldata, pos = string.unpack( "c"..len, data, pos )

      return pos, coldata
    end,

    [DataTypes.BIGBINARYTYPE] = function( data, pos )
      return ColumnData.Parse[DataTypes.XSYBVARBINARY](data, pos)
    end,

    [DataTypes.BIGCHARTYPE] = function( data, pos )
      return ColumnData.Parse[DataTypes.XSYBVARCHAR](data, pos)
    end,

    [DataTypes.XSYBNVARCHAR] = function( data, pos )
      local len, coldata

      len, pos = string.unpack( "<I2", data, pos )
      if ( len == 65535 ) then
        return pos, 'Null'
      end
      coldata, pos = string.unpack( "c"..len, data, pos )

      return pos, unicode.utf16to8(coldata)
    end,

    [DataTypes.SQLNCHAR] = function( data, pos )
      return ColumnData.Parse[DataTypes.XSYBNVARCHAR](data, pos)
    end,

  }
}

-- "static" Token parser class
Token =
{

  Parse = {
    --- Parse error message tokens
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.ErrorMessage] = function( data, pos )
      local token = {}
      local tmp

      token.type = TokenType.ErrorMessage
      token.size, token.errno, token.state, token.severity, token.errlen, pos = string.unpack( "<I2I4BBI2", data, pos )
      tmp, pos = string.unpack("c" .. (token.errlen * 2), data, pos )
      token.error = unicode.utf16to8(tmp)
      token.srvlen, pos = string.unpack("B", data, pos)
      tmp, pos = string.unpack("c" .. (token.srvlen * 2), data, pos )
      token.server = unicode.utf16to8(tmp)
      token.proclen, pos = string.unpack("B", data, pos)
      tmp, pos = string.unpack("c" .. (token.proclen * 2), data, pos )
      token.proc = unicode.utf16to8(tmp)
      token.lineno, pos = string.unpack("<I2", data, pos)

      return pos, token
    end,

    --- Parse environment change tokens
    -- (This function is not implemented and simply moves the pos offset)
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.EnvironmentChange] = function( data, pos )
      local token = {}
      local tmp

      token.type = TokenType.EnvironmentChange
      token.size, pos = string.unpack("<I2", data, pos)

      return pos + token.size, token
    end,

    --- Parse information message tokens
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.InformationMessage] = function( data, pos )
      local pos, token = Token.Parse[TokenType.ErrorMessage]( data, pos )
      token.type = TokenType.InformationMessage
      return pos, token
    end,

    --- Parse login acknowledgment tokens
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.LoginAcknowledgement] = function( data, pos )
      local token = {}
      local _

      token.type = TokenType.LoginAcknowledgement
      token.size, _, _, _, _, token.textlen, pos = string.unpack( "<I2BBBI2B", data, pos )
      token.text, pos = string.unpack("c" .. token.textlen * 2, data, pos)
      token.version, pos = string.unpack("<I4", data, pos )

      return pos, token
    end,

    --- Parse done tokens
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.Done] = function( data, pos )
      local token = {}

      token.type = TokenType.Done
      token.flags, token.operation, token.rowcount, pos = string.unpack( "<I2I2I4", data, pos )

      return pos, token
    end,

    --- Parses a DoneProc token received after executing a SP
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.DoneProc] = function( data, pos )
      local token
      pos, token = Token.Parse[TokenType.Done]( data, pos )
      token.type = TokenType.DoneProc

      return pos, token
    end,


    --- Parses a DoneInProc token received after executing a SP
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.DoneInProc] = function( data, pos )
      local token
      pos, token = Token.Parse[TokenType.Done]( data, pos )
      token.type = TokenType.DoneInProc

      return pos, token
    end,

    --- Parses a ReturnStatus token
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.ReturnStatus] = function( data, pos )
      local token = {}

      token.value, pos = string.unpack("<i4", data, pos)
      token.type = TokenType.ReturnStatus
      return pos, token
    end,

    --- Parses a OrderBy token
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.OrderBy] = function( data, pos )
      local token = {}

      token.size, pos = string.unpack("<I2", data, pos)
      token.type = TokenType.OrderBy
      return pos + token.size, token
    end,


    --- Parse TDS result tokens
    --
    -- @param data string containing "raw" data
    -- @param pos number containing offset into data
    -- @return pos number containing new offset after parse
    -- @return token table containing token specific fields
    [TokenType.TDS7Results] = function( data, pos )
      local token = {}
      local _

      token.type = TokenType.TDS7Results
      token.count, pos = string.unpack( "<I2", data, pos )
      token.colinfo = {}

      for i=1, token.count do
        local colinfo = {}
        local usertype, flags, ttype

        usertype, flags, ttype, pos = string.unpack("<I2I2B", data, pos )
        if ( not(ColumnInfo.Parse[ttype]) ) then
          return -1, ("Unhandled data type: 0x%X"):format(ttype)
        end

        pos, colinfo = ColumnInfo.Parse[ttype]( data, pos )
        colinfo.usertype = usertype
        colinfo.flags = flags
        colinfo.type = ttype

        table.insert( token.colinfo, colinfo )
      end
      return pos, token
    end,


    [TokenType.NTLMSSP_CHALLENGE] = function(data, pos)
      local len, ntlmssp, msgtype, pos = string.unpack("<I2c8I4", data, pos)
      local NTLMSSP_CHALLENGE = 2

      if ( ntlmssp ~= "NTLMSSP\0" or msgtype ~= NTLMSSP_CHALLENGE ) then
        return -1, "Failed to process NTLMSSP Challenge"
      end

      local ntlm_challenge = {nonce=data:sub( 28, 35 ), type=TokenType.NTLMSSP_CHALLENGE}
      pos = pos + len - 13
      return pos, ntlm_challenge
    end,
  },

  --- Parses the first token at positions pos
  --
  -- @param data string containing "raw" data
  -- @param pos number containing offset into data
  -- @return pos number containing new offset after parse or -1 on error
  -- @return token table containing token specific fields or error message on error
  ParseToken = function( data, pos )
    local ttype
    ttype, pos = string.unpack("B", data, pos)
    if ( not(Token.Parse[ttype]) ) then
      stdnse.debug1("%s: No parser for token type 0x%X", "MSSQL", ttype )
      return -1, ("No parser for token type: 0x%X"):format( ttype )
    end

    return Token.Parse[ttype](data, pos)
  end,

}


--- QueryPacket class
QueryPacket =
{
  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  SetQuery = function( self, query )
    self.query = query
  end,

  --- Returns the query packet as string
  --
  -- @return string containing the authentication packet
  ToString = function( self )
    return PacketType.Query, unicode.utf8to16( self.query )
  end,

}


--- PreLoginPacket class
PreLoginPacket =
{
  -- TDS pre-login option types
  OPTION_TYPE = {
    Version = 0x00,
    Encryption = 0x01,
    InstOpt = 0x02,
    ThreadId = 0x03,
    MARS = 0x04,
    Terminator = 0xFF,
  },


  versionInfo = nil,
  _requestEncryption = 0,
  _instanceName = "",
  _threadId = 0, -- Dummy value; will be filled in later
  _requestMars = nil,

  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  --- Sets the client version (default = 9.00.1399.00)
  --
  -- @param versionInfo A SqlServerVersionInfo object with the client version information
  SetVersion = function(self, versionInfo)
    self._versionInfo = versionInfo
  end,

  --- Sets whether to request encryption (default = false)
  --
  -- @param requestEncryption A boolean indicating whether encryption will be requested
  SetRequestEncryption = function(self, requestEncryption)
    if requestEncryption then
      self._requestEncryption = 1
    else
      self._requestEncryption = 0
    end
  end,

  --- Sets whether to request MARS support (default = undefined)
  --
  -- @param requestMars A boolean indicating whether MARS support will be requested
  SetRequestMars = function(self, requestMars)
    if requestMars then
      self._requestMars = 1
    else
      self._requestMars = 0
    end
  end,

  --- Sets the instance name of the target
  --
  -- @param instanceName A string containing the name of the instance
  SetInstanceName = function(self, instanceName)
    self._instanceName = instanceName or ""
  end,

  --- Returns the pre-login packet as a byte string
  --
  -- @return byte string containing the pre-login packet
  ToBytes = function(self)
    -- Lengths for the values of TDS pre-login option fields
    local OPTION_LENGTH_CLIENT = {
      [PreLoginPacket.OPTION_TYPE.Version] = 6,
      [PreLoginPacket.OPTION_TYPE.Encryption] = 1,
      [PreLoginPacket.OPTION_TYPE.InstOpt] = -1,
      [PreLoginPacket.OPTION_TYPE.ThreadId] = 4,
      [PreLoginPacket.OPTION_TYPE.MARS] = 1,
      [PreLoginPacket.OPTION_TYPE.Terminator] = 0,
    }

    local optionLength, optionType = 0, 0
    local offset = 1 -- Terminator
    offset = offset + 5 -- Version
    offset = offset + 5 -- Encryption
    offset = offset + 5 -- InstOpt
    offset = offset + 5 -- ThreadId
    if self._requestMars then offset = offset + 3 end -- MARS

    if not self.versionInfo then
      self.versionInfo = SqlServerVersionInfo:new()
      self.versionInfo:SetVersionNumber( "9.00.1399.00" )
    end

    optionType = PreLoginPacket.OPTION_TYPE.Version
    optionLength = OPTION_LENGTH_CLIENT[ optionType ]
    local data = { string.pack( ">BI2I2", optionType, offset, optionLength ) }
    offset = offset + optionLength

    optionType = PreLoginPacket.OPTION_TYPE.Encryption
    optionLength = OPTION_LENGTH_CLIENT[ optionType ]
    data[#data+1] = string.pack( ">BI2I2", optionType, offset, optionLength )
    offset = offset + optionLength

    optionType = PreLoginPacket.OPTION_TYPE.InstOpt
    optionLength = #self._instanceName + 1 --(string length + null-terminator)
    data[#data+1] = string.pack( ">BI2I2", optionType, offset, optionLength )
    offset = offset + optionLength

    optionType = PreLoginPacket.OPTION_TYPE.ThreadId
    optionLength = OPTION_LENGTH_CLIENT[ optionType ]
    data[#data+1] = string.pack( ">BI2I2", optionType, offset, optionLength )
    offset = offset + optionLength

    if self.requestMars then
      optionType = PreLoginPacket.OPTION_TYPE.MARS
      optionLength = OPTION_LENGTH_CLIENT[ optionType ]
      data[#data+1] = string.pack( ">BI2I2", optionType, offset, optionLength )
      offset = offset + optionLength
    end

    data[#data+1] = string.pack( "B", PreLoginPacket.OPTION_TYPE.Terminator )

    -- Now that the pre-login headers are done, write the data
    data[#data+1] = string.pack( ">BBI2I2", self.versionInfo.major, self.versionInfo.minor,
    self.versionInfo.build, self.versionInfo.subBuild )
    data[#data+1] = string.pack( "<BzI4", self._requestEncryption, self._instanceName, self._threadId )
    if self.requestMars then
      data[#data+1] = string.pack( "B", self._requestMars )
    end

    return PacketType.PreLogin, table.concat(data)
  end,

  --- Reads a byte-string and creates a PreLoginPacket object from it. This is
  -- intended to handle the server's response to a pre-login request.
  FromBytes = function( bytes )
    local OPTION_LENGTH_SERVER = {
      [PreLoginPacket.OPTION_TYPE.Version] = 6,
      [PreLoginPacket.OPTION_TYPE.Encryption] = 1,
      [PreLoginPacket.OPTION_TYPE.InstOpt] = -1,
      [PreLoginPacket.OPTION_TYPE.ThreadId] = 0, -- According to the TDS spec, this value should be empty from the server
      [PreLoginPacket.OPTION_TYPE.MARS] = 1,
      [PreLoginPacket.OPTION_TYPE.Terminator] = 0,
    }


    local status, pos = false, 1
    local preLoginPacket = PreLoginPacket:new()

    while true do

      local optionType, optionPos, optionLength, optionData, expectedOptionLength, _
      if pos > #bytes then
        stdnse.debug2("%s: Could not extract optionType.", "MSSQL" )
        return false, "Invalid pre-login response"
      end
      optionType, pos = ("B"):unpack(bytes, pos)
      if ( optionType == PreLoginPacket.OPTION_TYPE.Terminator ) then
        status = true
        break
      end
      expectedOptionLength = OPTION_LENGTH_SERVER[ optionType ]
      if ( not expectedOptionLength ) then
        stdnse.debug2("%s: Unrecognized pre-login option type: %s", "MSSQL", optionType )
        expectedOptionLength = -1
      end

      if pos + 4 > #bytes + 1 then
        stdnse.debug2("%s: Could not unpack optionPos and optionLength.", "MSSQL" )
        return false, "Invalid pre-login response"
      end
      optionPos, optionLength, pos = (">I2I2"):unpack(bytes, pos)

      optionPos = optionPos + 1 -- convert from 0-based index to 1-based index

      if ( optionLength ~= expectedOptionLength and expectedOptionLength ~= -1 ) then
        stdnse.debug2("%s: Option data is incorrect size in pre-login response. ", "MSSQL" )
        stdnse.debug2("%s:   (optionType: %s) (optionLength: %s)", "MSSQL", optionType, optionLength )
        return false, "Invalid pre-login response"
      end
      optionData = bytes:sub( optionPos, optionPos + optionLength - 1 )
      if #optionData ~= optionLength then
        stdnse.debug2("%s: Could not read sufficient bytes from version data.", "MSSQL" )
        return false, "Invalid pre-login response"
      end

      if ( optionType == PreLoginPacket.OPTION_TYPE.Version ) then
        local major, minor, build, subBuild = (">BBI2I2"):unpack(optionData)
        local version = SqlServerVersionInfo:new()
        version:SetVersion( major, minor, build, subBuild, "SSNetLib" )
        preLoginPacket.versionInfo = version
      elseif ( optionType == PreLoginPacket.OPTION_TYPE.Encryption ) then
        preLoginPacket:SetRequestEncryption( ("B"):unpack(optionData) )
      elseif ( optionType == PreLoginPacket.OPTION_TYPE.InstOpt ) then
        preLoginPacket:SetInstanceName( ("z"):unpack(optionData) )
      elseif ( optionType == PreLoginPacket.OPTION_TYPE.ThreadId ) then
        -- Do nothing. According to the TDS spec, this option is empty when sent from the server
      elseif ( optionType == PreLoginPacket.OPTION_TYPE.MARS ) then
        preLoginPacket:SetRequestMars( ("B"):unpack(optionData) )
      end
    end

    return status, preLoginPacket
  end,
}


--- LoginPacket class
LoginPacket =
{

  -- options_1 possible values
  -- 0x80 enable warning messages if SET LANGUAGE issued
  -- 0x40 change to initial database must succeed
  -- 0x20 enable warning messages if USE <database> issued
  -- 0x10 enable BCP

  -- options_2 possible values
  -- 0x80 enable domain login security
  -- 0x40 "USER_SERVER - reserved"
  -- 0x20 user type is "DQ login"
  -- 0x10 user type is "replication login"
  -- 0x08 "fCacheConnect"
  -- 0x04 "fTranBoundary"
  -- 0x02 client is an ODBC driver
  -- 0x01 change to initial language must succeed
  length = 0,
  version = 0x71000001, -- Version 7.1
  size = 0,
  cli_version = 7, -- From jTDS JDBC driver
  cli_pid = 0, -- Dummy value
  conn_id = 0,
  options_1 = 0xa0,
  options_2 = 0x03,
  sqltype_flag = 0,
  reserved_flag= 0,
  time_zone = 0,
  collation = 0,

  -- Strings
  client = "USER",
  username = nil,
  password = nil,
  app = "USER SQL",
  server = nil,
  library = "mssql.lua",
  locale = "",
  database = "master", --nil,
  MAC = "\x00\x00\x00\x00\x00\x00", -- should contain client MAC, jTDS uses all zeroes

  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  --- Sets the username used for authentication
  --
  -- @param username string containing the username to user for authentication
  SetUsername = function(self, username)
    self.username = username
  end,

  --- Sets the password used for authentication
  --
  -- @param password string containing the password to user for authentication
  SetPassword = function(self, password)
    self.password = password
  end,

  --- Sets the database used in authentication
  --
  -- @param database string containing the database name
  SetDatabase = function(self, database)
    self.database = database
  end,

  --- Sets the server's name used in authentication
  --
  -- @param server string containing the name or ip of the server
  SetServer = function(self, server)
    self.server = server
  end,

  SetDomain = function(self, domain)
    self.domain = domain
  end,

  --- Returns the authentication packet as string
  --
  -- @return string containing the authentication packet
  ToString = function(self)
    local data
    local offset = 86
    local ntlmAuth = not(not(self.domain))
    local authLen = 0

    self.cli_pid = math.random(100000)
    local u_client = unicode.utf8to16(self.client)
    local u_app = unicode.utf8to16(self.app)
    local u_server = unicode.utf8to16(self.server)
    local u_library = unicode.utf8to16(self.library)
    local u_locale = unicode.utf8to16(self.locale)
    local u_database = unicode.utf8to16(self.database)
    local u_username, uc_password

    self.length = offset + #u_client + #u_app + #u_server + #u_library + #u_database

    if ( ntlmAuth ) then
      authLen = 32 + #self.domain
      self.length = self.length + authLen
      self.options_2 = self.options_2 + 0x80
    else
      u_username = unicode.utf8to16(self.username)
      uc_password = Auth.TDS7CryptPass(self.password, unicode.utf8_dec)
      self.length = self.length + #u_username + #uc_password
    end

    data = {
      string.pack("<I4I4I4I4I4I4", self.length, self.version, self.size, self.cli_version, self.cli_pid, self.conn_id ),
      string.pack("BBBB", self.options_1, self.options_2, self.sqltype_flag, self.reserved_flag ),
      string.pack("<I4I4", self.time_zone, self.collation ),

      -- offsets begin
      string.pack("<I2I2", offset, #u_client/2 ),
    }
    offset = offset + #u_client

    if ( not(ntlmAuth) ) then
      data[#data+1] = string.pack("<I2I2", offset, #u_username/2 )

      offset = offset + #u_username
      data[#data+1] = string.pack("<I2I2", offset, #uc_password/2 )
      offset = offset + #uc_password
    else
      data[#data+1] = string.pack("<I2I2", offset, 0 )
      data[#data+1] = string.pack("<I2I2", offset, 0 )
    end

    data[#data+1] = string.pack("<I2I2", offset, #u_app/2 )
    offset = offset + #u_app

    data[#data+1] = string.pack("<I2I2", offset, #u_server/2 )
    offset = offset + #u_server

    -- Offset to unused placeholder (reserved for future use in TDS spec)
    data[#data+1] = string.pack("<I2I2", 0, 0 )

    data[#data+1] = string.pack("<I2I2", offset, #u_library/2 )
    offset = offset + #u_library

    data[#data+1] = string.pack("<I2I2", offset, #u_locale/2 )
    offset = offset + #u_locale

    data[#data+1] = string.pack("<I2I2", offset, #u_database/2 )
    offset = offset + #u_database

    -- client MAC address, hardcoded to 00:00:00:00:00:00
    data[#data+1] = self.MAC

    -- offset to auth info
    data[#data+1] = string.pack("<I2", offset)
    -- length of nt auth (should be 0 for sql auth)
    data[#data+1] = string.pack("<I2", authLen)
    -- next position (same as total packet length)
    data[#data+1] = string.pack("<I2", self.length)
    -- zero pad
    data[#data+1] = string.pack("<I2", 0)

    -- Auth info wide strings
    data[#data+1] = u_client
    if ( not(ntlmAuth) ) then
      data[#data+1] = u_username
      data[#data+1] = uc_password
    end
    data[#data+1] = u_app
    data[#data+1] = u_server
    data[#data+1] = u_library
    data[#data+1] = u_locale
    data[#data+1] = u_database

    if ( ntlmAuth ) then
      local NTLMSSP_NEGOTIATE = 1
      local flags = 0x0000b201
      local workstation = ""

      data[#data+1] = "NTLMSSP\0"
      data[#data+1] = string.pack("<I4I4", NTLMSSP_NEGOTIATE, flags)
      data[#data+1] = string.pack("<I2I2I4", #self.domain, #self.domain, 32)
      data[#data+1] = string.pack("<I2I2I4", #workstation, #workstation, 32)
      data[#data+1] = self.domain:upper()
    end

    return PacketType.Login, table.concat(data)
  end,

}

NTAuthenticationPacket = {

  new = function(self, username, password, domain, nonce)
    local o = {}
    setmetatable(o, self)
    o.username = username
    o.domain = domain
    o.nonce = nonce
    o.password = password
    self.__index = self
    return o
  end,

  ToString = function(self)
    local ntlmssp = "NTLMSSP\0"
    local NTLMSSP_AUTH = 3
    local domain = unicode.utf8to16(self.domain:upper())
    local user = unicode.utf8to16(self.username)
    local hostname, sessionkey = "", ""
    local flags = 0x00008201
    local ntlm_response = Auth.NtlmResponse(self.password, self.nonce)
    local lm_response = Auth.LmResponse(self.password, self.nonce)

    local domain_offset = 64
    local username_offset = domain_offset + #domain
    local lm_response_offset = username_offset + #user
    local ntlm_response_offset = lm_response_offset + #lm_response
    local hostname_offset = ntlm_response_offset + #ntlm_response
    local sessionkey_offset = hostname_offset + #hostname

    local data = ntlmssp .. string.pack("<I4I2I2I4", NTLMSSP_AUTH, #lm_response, #lm_response, lm_response_offset)
    .. string.pack("<I2I2I4", #ntlm_response, #ntlm_response, ntlm_response_offset)
    .. string.pack("<I2I2I4", #domain, #domain, domain_offset)
    .. string.pack("<I2I2I4", #user, #user, username_offset)
    .. string.pack("<I2I2I4", #hostname, #hostname, hostname_offset)
    .. string.pack("<I2I2I4", #sessionkey, #sessionkey, sessionkey_offset)
    .. string.pack("<I4", flags)
    .. domain
    .. user
    .. lm_response .. ntlm_response

    return PacketType.NTAuthentication, data
  end,

}

-- Handles communication with SQL Server
TDSStream = {

  -- Status flag constants
  MESSAGE_STATUS_FLAGS = {
    Normal = 0x0,
    EndOfMessage = 0x1,
    IgnoreThisEvent = 0x2,
    ResetConnection = 0x4,
    ResetConnectionSkipTran = 0x8,
  },

  _packetId = 0,
  _pipe = nil,
  _socket = nil,
  _name = nil,

  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  --- Establishes a connection to the SQL server.
  --
  --  @param self A mssql.Helper object
  --  @param instanceInfo  A SqlServerInstanceInfo object for the instance to
  --    connect to.
  --  @param connectionPreference (Optional) A list containing one or both of
  --    the strings "TCP" and "Named Pipes", indicating which transport
  --    methods to try and in what order.
  --  @param smbOverrides (Optional) An overrides table for calls to the <code>smb</code>
  --    library (for use with named pipes).
  ConnectEx = function( self, instanceInfo, connectionPreference, smbOverrides )
    if ( self._socket ) then return false, "Already connected via TCP" end
    if ( self._pipe ) then return false, "Already connected via named pipes" end
    connectionPreference = connectionPreference or stdnse.get_script_args('mssql.protocol') or { "TCP", "Named Pipes" }
    if ( connectionPreference and 'string' == type(connectionPreference) ) then
      connectionPreference = { connectionPreference }
    end

    local status, result, connectionType, errorMessage
    stdnse.debug3("%s: Connection preferences for %s: %s",
    "MSSQL", instanceInfo:GetName(), table.concat(connectionPreference, ", ") )

    for _, connectionType in ipairs( connectionPreference ) do
      if connectionType == "TCP" then

        if not ( instanceInfo.port ) then
          stdnse.debug3("%s: Cannot connect to %s via TCP because port table is not set.",
          "MSSQL", instanceInfo:GetName() )
          result = "No TCP port for this instance"
        else
          status, result = self:Connect( instanceInfo.host, instanceInfo.port )
          if status then return true end
        end

      elseif connectionType == "Named Pipes" or connectionType == "NP" then

        if not ( instanceInfo.pipeName ) then
          stdnse.debug3("%s: Cannot connect to %s via named pipes because pipe name is not set.",
          "MSSQL", instanceInfo:GetName() )
          result = "No named pipe for this instance"
        else
          status, result = self:ConnectToNamedPipe( instanceInfo.host, instanceInfo.pipeName, smbOverrides )
          if status then return true end
        end

      else
        stdnse.debug1("%s: Unknown connection preference: %s", "MSSQL", connectionType )
        return false, ("ERROR: Unknown connection preference: %s"):format(connectionType)
      end

      -- Handle any error messages
      if not status then
        if errorMessage then
          errorMessage = string.format( "%s, %s: %s", errorMessage, connectionType, result or "nil" )
        else
          errorMessage = string.format( "%s: %s", connectionType, result or "nil" )
        end
      end
    end

    if not errorMessage then
      errorMessage = string.format( "%s: None of the preferred connection types are available for %s\\%s",
      "MSSQL", instanceInfo:GetName() )
    end

    return false, errorMessage
  end,

  --- Establishes a connection to the SQL server
  --
  -- @param host A host table for the target host
  -- @param pipePath The path to the named pipe of the target SQL Server
  --         (e.g. "\MSSQL$SQLEXPRESS\sql\query"). If nil, "\sql\query\" is used.
  -- @param smbOverrides (Optional) An overrides table for calls to the <code>smb</code>
  --        library (for use with named pipes).
  -- @return status: true on success, false on failure
  -- @return error_message: an error message, or nil
  ConnectToNamedPipe = function( self, host, pipePath, overrides )
    if ( self._socket ) then return false, "Already connected via TCP" end

    if ( SCANNED_PORTS_ONLY and smb.get_port( host ) == nil ) then
      stdnse.debug2("%s: Connection disallowed: scanned-ports-only is set and no SMB port is available", "MSSQL" )
      return false, "Connection disallowed: scanned-ports-only"
    end

    pipePath = pipePath or "\\sql\\query"

    self._pipe = namedpipes.named_pipe:new()
    local status, result = self._pipe:connect( host, pipePath, overrides )
    if ( status ) then
      self._name = self._pipe.pipe
    else
      self._pipe = nil
    end

    return status, result
  end,

  --- Establishes a connection to the SQL server
  --
  -- @param host table containing host information
  -- @param port table containing port information
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  Connect = function( self, host, port )
    if ( self._pipe ) then return false, "Already connected via named pipes" end

    if ( SCANNED_PORTS_ONLY and nmap.get_port_state( host, port ) == nil ) then
      stdnse.debug2("%s: Connection disallowed: scanned-ports-only is set and port %d was not scanned", "MSSQL", port.number )
      return false, "Connection disallowed: scanned-ports-only"
    end

    local status, result, lport, _

    self._socket = nmap.new_socket()

    -- Set the timeout to something realistic for connects
    self._socket:set_timeout( 5000 )
    status, result = self._socket:connect(host, port)

    if ( status ) then
      -- Sometimes a Query can take a long time to respond, so we set
      -- the timeout to 30 seconds. This shouldn't be a problem as the
      -- library attempt to decode the protocol and avoid reading past
      -- the end of the input buffer. So the only time the timeout is
      -- triggered is when waiting for a response to a query.
      self._socket:set_timeout( MSSQL_TIMEOUT * 1000 )

      status, _, lport, _, _ = self._socket:get_info()
    end

    if ( not(status) ) then
      self._socket = nil
      stdnse.debug2("%s: Socket connection failed on %s:%s", "MSSQL", host.ip, port.number )
      return false, "Socket connection failed"
    end
    self._name = string.format( "%s:%s", host.ip, port.number )

    return status, result
  end,

  --- Disconnects from the SQL Server
  --
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  Disconnect = function( self )
    if ( self._socket ) then
      local status, result = self._socket:close()
      self._socket = nil
      return status, result
    elseif ( self._pipe ) then
      local status, result = self._pipe:disconnect()
      self._pipe = nil
      return status, result
    else
      return false, "Not connected"
    end
  end,

  --- Sets the timeout for communication over the socket
  --
  -- @param timeout number containing the new socket timeout in ms
  SetTimeout = function( self, timeout )
    if ( self._socket ) then
      self._socket:set_timeout(timeout)
    else
      return false, "Not connected"
    end
  end,

  --- Gets the name of the name pipe, or nil
  GetNamedPipeName = function( self )
    if ( self._pipe ) then
      return self._pipe.name
    else
      return nil
    end
  end,

  --- Send a TDS request to the server
  --
  -- @param packetType A <code>PacketType</code>, indicating the type of TDS
  --                   packet being sent.
  -- @param packetData A string containing the raw data to send to the server
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  Send = function( self, packetType, packetData )
    local packetLength = packetData:len() + 8 -- +8 for TDS header
    local messageStatus, spid, window = 1, 0, 0


    if ( packetType ~= PacketType.NTAuthentication ) then self._packetId = self._packetId + 1 end
    local assembledPacket = string.pack(">BBI2I2BB", packetType, messageStatus, packetLength, spid, self._packetId, window) .. packetData

    if ( self._socket ) then
      return self._socket:send( assembledPacket )
    elseif ( self._pipe ) then
      return self._pipe:send( assembledPacket )
    else
      return false, "Not connected"
    end
  end,

  --- Receives responses from SQL Server
  --
  -- The function continues to read and assemble a response until the server
  -- responds with the last response flag set
  --
  -- @return status true on success, false on failure
  -- @return result containing raw data contents or error message on failure
  -- @return errorDetail nil, or additional information about an error. In
  --         the case of named pipes, this will be an SMB error name (e.g. NT_STATUS_PIPE_DISCONNECTED)
  Receive = function( self )
    local status, result, errorDetail
    local combinedData, readBuffer = "", "" -- the buffer is solely for the benefit of TCP connections
    local tdsPacketAvailable = true

    if not ( self._socket or self._pipe ) then
      return false, "Not connected"
    end

    -- Large messages (e.g. result sets) can be split across multiple TDS
    -- packets from the server (which could themselves each be split across
    -- multiple TCP packets or SMB messages).
    while ( tdsPacketAvailable ) do
      local packetType, messageStatus, packetLength, spid, window
      local pos = 1

      if ( self._socket ) then
        -- If there is existing data in the readBuffer, see if there's
        -- enough to read the TDS headers for the next packet. If not,
        -- do another read so we have something to work with.
        if ( readBuffer:len() < 8 ) then
          status, result = self._socket:receive_bytes(8 - readBuffer:len())
          readBuffer = readBuffer .. result
        end
      elseif ( self._pipe ) then
        -- The named pipe takes care of all of its reassembly. We don't
        -- have to mess with buffers and repeatedly reading until we get
        -- the whole packet. We'll still write to readBuffer, though, so
        -- that the common logic can be reused.
        status, result, errorDetail = self._pipe:receive()
        readBuffer = result
      end

      if not ( status and readBuffer ) then return false, result, errorDetail end

      -- TDS packet validity check: packet at least as long as the TDS header
      if ( readBuffer:len() < 8 ) then
        stdnse.debug2("%s: Receiving (%s): packet is invalid length", "MSSQL", self._name )
        return false, "Server returned invalid packet"
      end

      -- read in the TDS headers
      packetType, messageStatus, packetLength, pos = string.unpack(">BBI2", readBuffer, pos )
      spid, self._packetId, window, pos = string.unpack(">I2BB", readBuffer, pos )

      -- TDS packet validity check: packet type is Response (0x4)
      if ( packetType ~= PacketType.Response ) then
        stdnse.debug2("%s: Receiving (%s): Expected type 0x4 (response), but received type 0x%x",
          "MSSQL", self._name, packetType )
        return false, "Server returned invalid packet"
      end

      if ( self._socket ) then
        -- If we didn't previously read in enough data to complete this
        -- TDS packet, let's do so.
        while ( packetLength - readBuffer:len() > 0 ) do
          status, result = self._socket:receive()
          if not ( status and result ) then return false, result end
          readBuffer = readBuffer .. result
        end
      end

      -- We've read in an apparently valid TDS packet
      local thisPacketData = readBuffer:sub( pos, packetLength )
      -- Append its data to that of any previous TDS packets
      combinedData = combinedData .. thisPacketData
      if ( self._socket ) then
        -- If we read in data beyond the end of this TDS packet, save it
        -- so that we can use it in the next loop.
        readBuffer = readBuffer:sub( packetLength + 1 )
      end

      -- TDS packet validity check: packet length matches length from header
      if ( packetLength ~= (thisPacketData:len() + 8) ) then
        stdnse.debug2("%s: Receiving (%s): Header reports length %d, actual length is %d",
          "MSSQL", self._name, packetLength, thisPacketData:len()  )
        return false, "Server returned invalid packet"
      end

      -- Check the status flags in the TDS packet to see if the message is
      -- continued in another TDS packet.
      tdsPacketAvailable = (( messageStatus & TDSStream.MESSAGE_STATUS_FLAGS.EndOfMessage) ~=
        TDSStream.MESSAGE_STATUS_FLAGS.EndOfMessage)
    end

    -- return only the data section ie. without the headers
    return status, combinedData
  end,

}

--- Helper class
Helper =
{
  new = function(self,o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
  end,

  --- Establishes a connection to the SQL server
  --
  -- @param instanceInfo A SqlServerInstanceInfo object for the instance
  --                     to connect to
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  ConnectEx = function( self, instanceInfo )
    local status, result
    self.stream = TDSStream:new()
    status, result = self.stream:ConnectEx( instanceInfo )
    if ( not(status) ) then
      return false, result
    end

    return true
  end,

  --- Establishes a connection to the SQL server
  --
  -- @param host table containing host information
  -- @param port table containing port information
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  Connect = function( self, host, port )
    local status, result
    self.stream = TDSStream:new()
    status, result = self.stream:Connect(host, port)
    if ( not(status) ) then
      return false, result
    end

    return true
  end,

  --- Returns true if discovery has been performed to detect
  -- SQL Server instances on the given host
  WasDiscoveryPerformed = function( host )
    local mutex = nmap.mutex( "discovery_performed for " .. host.ip )
    mutex( "lock" )
    nmap.registry.mssql = nmap.registry.mssql or {}
    nmap.registry.mssql.discovery_performed = nmap.registry.mssql.discovery_performed or {}

    local wasPerformed = nmap.registry.mssql.discovery_performed[ host.ip ] or false
    mutex( "done" )

    return wasPerformed
  end,

  --- Adds an instance to the list of instances kept in the Nmap registry for
  --  shared use by SQL Server scripts.
  --
  --  If the registry already contains the instance, any new information is
  --  merged into the existing instance info.  This may happen, for example,
  --  when an instance is discovered via named pipes, but the same instance has
  --  already been discovered via SSRP; this will prevent duplicates, where
  --  possible.
  AddOrMergeInstance = function( newInstance )
    local instanceExists

    nmap.registry.mssql = nmap.registry.mssql or {}
    nmap.registry.mssql.instances = nmap.registry.mssql.instances or {}
    nmap.registry.mssql.instances[ newInstance.host.ip ] = nmap.registry.mssql.instances[ newInstance.host.ip ] or {}

    for _, existingInstance in ipairs( nmap.registry.mssql.instances[ newInstance.host.ip ] ) do
      if existingInstance == newInstance then
        existingInstance:Merge( newInstance )
        instanceExists = true
        break
      end
    end

    if not instanceExists then
      table.insert( nmap.registry.mssql.instances[ newInstance.host.ip ], newInstance )
    end
  end,

  --- Gets a table containing SqlServerInstanceInfo objects discovered on
  --  the specified host (and port, if specified).
  --
  --  This table is the NSE registry table itself, not a copy, so do not alter
  --  it unintentionally.
  --
  --  @param host A host table for the target host
  --  @param port (Optional) If omitted, all of the instances for the host
  --    will be returned.
  --  @return A table containing SqlServerInstanceInfo objects, or nil
  GetDiscoveredInstances = function( host, port )
    nmap.registry.mssql = nmap.registry.mssql or {}
    nmap.registry.mssql.instances = nmap.registry.mssql.instances or {}
    nmap.registry.mssql.instances[ host.ip ] = nmap.registry.mssql.instances[ host.ip ] or {}

    local instances = nmap.registry.mssql.instances[ host.ip ]
    if ( not port ) then
      if ( instances and #instances == 0 ) then instances = nil end
      return instances
    else
      for _, instance in ipairs(instances) do
        if ( instance.port and instance.port.number == port.number and
          instance.port.protocol == port.protocol ) then
          return { instance }
        end
      end

      return nil
    end
  end,

  --- Attempts to discover SQL Server instances using SSRP to query one or
  --  more (if <code>broadcast</code> is used) SQL Server Browser services.
  --
  --  Any discovered instances are returned, as well as being stored for use
  --  by other scripts (see <code>mssql.Helper.GetDiscoveredInstances()</code>).
  --
  --  @param host A host table for the target.
  --  @param port (Optional) A port table for the target port. If this is nil,
  --    the default SSRP port (UDP 1434) is used.
  --  @param broadcast If true, this will be done with an SSRP broadcast, and
  --    <code>host</code> should contain the broadcast specification (e.g.
  --    ip = "255.255.255.255").
  --  @return (status, result) If status is true, result is a table of
  --    tables containing SqlServerInstanceInfo objects. The top-level table
  --    is indexed by IP address. If status is false, result is an
  --    error message.
  DiscoverBySsrp = function( host, port, broadcast )

    if broadcast then
      local status, result = SSRP.DiscoverInstances_Broadcast( host, port )

      if not status then
        return status, result
      else
        for ipAddress, host in pairs( result ) do
          for _, instance in ipairs( host ) do
            Helper.AddOrMergeInstance( instance )
            -- Give some version info back to Nmap
            if ( instance.port and instance.version ) then
              instance.version:PopulateNmapPortVersion( instance.port )
              --nmap.set_port_version( instance.host, instance.port)
            end
          end
        end

        return true, result
      end
    else
      local status, result = SSRP.DiscoverInstances( host, port )

      if not status then
        return status, result
      else
        for _, instance in ipairs( result ) do
          Helper.AddOrMergeInstance( instance )
          -- Give some version info back to Nmap
          if ( instance.port and instance.version ) then
            instance.version:PopulateNmapPortVersion( instance.port )
            nmap.set_port_version( host, instance.port)
          end
        end

        local instances_all = {}
        instances_all[ host.ip ] = result
        return true, instances_all
      end
    end
  end,

  --- Attempts to discover a SQL Server instance listening on the specified
  --  port.
  --
  --  If an instance is discovered, it is returned, as well as being stored for
  --  use by other scripts (see
  --  <code>mssql.Helper.GetDiscoveredInstances()</code>).
  --
  --  @param host A host table for the target.
  --  @param port A port table for the target port.
  --  @return (status, result) If status is true, result is a table of
  --    SqlServerInstanceInfo objects. If status is false, result is an
  --    error message or nil.
  DiscoverByTcp = function( host, port )
    local version, instance, status
    -- Check to see if we've already discovered an instance on this port
    local instances = Helper.GetDiscoveredInstances(host, port)
    if instances then
      return true, instances
    end
    instance =  SqlServerInstanceInfo:new()
    instance.host = host
    instance.port = port

    -- -sV may have gotten a version, but for now, it doesn't extract subBuild.
    status, version = Helper.GetInstanceVersion( instance )
    if not status then
      return false, version
    end

    Helper.AddOrMergeInstance( instance )
    -- The point of this wasn't to get the version, just to use the
    -- pre-login packet to determine whether there was a SQL Server on
    -- the port. However, since we have the version now, we'll store it.
    instance.version = version
    -- Give some version info back to Nmap
    if ( instance.port and instance.version ) then
      instance.version:PopulateNmapPortVersion( instance.port )
      nmap.set_port_version( host, instance.port)
    end

    return true, { instance }
  end,

  ---  Attempts to discover SQL Server instances listening on default named
  --  pipes.
  --
  --  Any discovered instances are returned, as well as being stored for use by
  --  other scripts (see <code>mssql.Helper.GetDiscoveredInstances()</code>).
  --
  --  @param host A host table for the target.
  --  @param port A port table for the port to connect on for SMB
  --  @return (status, result) If status is true, result is a table of
  --    SqlServerInstanceInfo objects. If status is false, result is an
  --    error message or nil.
  DiscoverBySmb = function( host, port )
    local defaultPipes = {
      "\\sql\\query",
      "\\MSSQL$SQLEXPRESS\\sql\\query",
      "\\MSSQL$SQLSERVER\\sql\\query",
    }
    local tdsStream = TDSStream:new()
    local status, result, instances_host

    for _, pipeSubPath in ipairs( defaultPipes ) do
      status, result = tdsStream:ConnectToNamedPipe( host, pipeSubPath, nil )

      if status then
        instances_host = {}
        local instance = SqlServerInstanceInfo:new()
        instance.pipeName = tdsStream:GetNamedPipeName()
        tdsStream:Disconnect()
        instance.host = host

        Helper.AddOrMergeInstance( instance )
        table.insert( instances_host, instance )
      else
        stdnse.debug3("DiscoverBySmb \n pipe: %s\n result: %s", pipeSubPath, tostring( result ) )
      end
    end

    return (instances_host ~= nil), instances_host
  end,

  --- Attempts to discover SQL Server instances by a variety of means.
  --
  --  This function calls the three DiscoverBy functions, which perform the
  --  actual discovery. Any discovered instances can be retrieved using
  --  <code>mssql.Helper.GetDiscoveredInstances()</code>.
  --
  --  @param host Host table as received by the script action function
  Discover = function( host )
    local mutex = nmap.mutex( "discovery_performed for " .. host.ip )
    mutex( "lock" )
    nmap.registry.mssql = nmap.registry.mssql or {}
    nmap.registry.mssql.discovery_performed = nmap.registry.mssql.discovery_performed or {}
    if nmap.registry.mssql.discovery_performed[ host.ip ] then
      mutex "done"
      return
    end
    nmap.registry.mssql.discovery_performed[ host.ip ] = false

    -- First, do SSRP discovery. Check any open (got response) ports first:
    local port = nmap.get_ports(host, nil, "udp", "open")
    while port do
      if port.version and port.version.name == "ms-sql-m" then
        Helper.DiscoverBySsrp(host, port)
      end
      port = nmap.get_ports(host, port, "udp", "open")
    end
    -- Then check if default SSRP port hasn't been done yet.
    port = nmap.get_port_state(host, SSRP.PORT)
    if not port or port.state == "open|filtered" then
      -- Either it wasn't scanned or it wasn't strictly "open" so we missed it above
        Helper.DiscoverBySsrp(host, port)
    end

    -- Next, do TCP discovery. Check any ports with an appropriate service name
    port = nmap.get_ports(host, nil, "tcp", "open")
    while port do
      if port.version and port.version.name == "ms-sql-s" then
        Helper.DiscoverByTcp(host, port)
      end
      port = nmap.get_ports(host, port, "tcp", "open")
    end

    -- smb.get_port() will return nil if no SMB port was scanned OR if SMB ports were scanned but none was open
    if smb.get_port(host) then
      Helper.DiscoverBySmb( host )
    end

    -- if the user has specified ports, we'll check those too
    if ( targetInstancePorts ) then
      for _, portNumber in ipairs( targetInstancePorts ) do
        portNumber = tonumber( portNumber )
        Helper.DiscoverByTcp( host, {number = portNumber, protocol = "tcp"} )
      end
    end

    nmap.registry.mssql.discovery_performed[ host.ip ] = true
    mutex( "done" )
  end,

  --- Returns all of the credentials available for the target instance,
  --  including any set by the <code>mssql.username</code> and <code>mssql.password</code>
  --  script arguments.
  --
  --  @param instanceInfo A SqlServerInstanceInfo object for the target instance
  --  @return A table of usernames mapped to passwords (i.e. <code>creds[ username ] = password</code>)
  GetLoginCredentials_All = function( instanceInfo )
    local credentials = instanceInfo.credentials or {}
    local credsExist = false
    for _, _ in pairs( credentials ) do
      credsExist = true
      break
    end
    if ( not credsExist ) then credentials = nil end

    if ( stdnse.get_script_args( "mssql.username" ) ) then
      credentials = credentials or {}
      local usernameArg = stdnse.get_script_args( "mssql.username" )
      local passwordArg = stdnse.get_script_args( "mssql.password" ) or ""
      credentials[ usernameArg ] = passwordArg
    end

    return credentials
  end,

  ---  Returns a username-password set according to the following rules of
  --  precedence:
  --
  --  * If the <code>mssql.username</code> and <code>mssql.password</code>
  --    script arguments were set, their values are used. (If the username
  --    argument was specified without the password argument, a blank
  --    password is used.)
  --  * If the password for the "sa" account has been discovered (e.g. by the
  --    <code>ms-sql-empty-password</code> or <code>ms-sql-brute</code>
  --    scripts), these credentials are used.
  --  * If other credentials have been discovered, the first of these in the
  --    table are used.
  --  * Otherwise, nil is returned.
  --
  --  @param instanceInfo A SqlServerInstanceInfo object for the target instance
  --  @return (username, password)
  GetLoginCredentials = function( instanceInfo )

    -- First preference goes to any user-specified credentials
    local username = stdnse.get_script_args( "mssql.username" )
    local password = stdnse.get_script_args( "mssql.password" ) or ""

    -- Otherwise, use any valid credentials that have been discovered (e.g. by ms-sql-brute)
    if ( not(username) and instanceInfo.credentials ) then
      -- Second preference goes to the "sa" account
      if ( instanceInfo.credentials.sa ) then
        username = "sa"
        password = instanceInfo.credentials.sa
      else
        -- ok were stuck with some n00b account, just get the first one
        for user, pass in pairs( instanceInfo.credentials ) do
          username = user
          password = pass
          break
        end
      end
    end

    return username, password
  end,

  --- Disconnects from the SQL Server
  --
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  Disconnect = function( self )
    if ( not(self.stream) ) then
      return false, "Not connected to server"
    end

    self.stream:Disconnect()
    self.stream = nil

    return true
  end,

  --- Authenticates to SQL Server.
  --
  -- If login fails, one of the following error messages will be returned:
  --  * "Password is expired"
  --  * "Must change password at next logon"
  --  * "Account is locked out"
  --  * "Login Failed"
  --
  -- @param username string containing the username for authentication
  -- @param password string containing the password for authentication
  -- @param database string containing the database to access
  -- @param servername string containing the name or ip of the remote server
  -- @return status true on success, false on failure
  -- @return result containing error message on failure
  -- @return errorDetail nil or a <code>LoginErrorType</code> value, if available
  Login = function( self, username, password, database, servername )
    local loginPacket = LoginPacket:new()
    local status, result, data, errorDetail, token
    local servername = servername or "DUMMY"
    local pos = 1
    local ntlmAuth = false

    if ( not self.stream ) then
      return false, "Not connected to server"
    end

    loginPacket:SetUsername(username)
    loginPacket:SetPassword(password)
    loginPacket:SetDatabase(database)
    loginPacket:SetServer(servername)

    local domain = stdnse.get_script_args("mssql.domain")
    if (domain) then
      if ( not(HAVE_SSL) ) then return false, "mssql: OpenSSL not present" end
      ntlmAuth = true
      -- if the domain was specified without an argument, set a default domain of "."
      if (domain == 1 or domain == true ) then
        domain = "."
      end
      loginPacket:SetDomain(domain)
    end

    status, result = self.stream:Send( loginPacket:ToString() )
    if ( not(status) ) then
      return false, result
    end

    status, data, errorDetail = self.stream:Receive()
    if ( not(status) ) then
      -- When logging in via named pipes, SQL Server will sometimes
      -- disconnect the pipe if the login attempt failed (this only seems
      -- to happen with non-"sa") accounts. At this point, having
      -- successfully connected and sent a message, we can be reasonably
      -- comfortable that a disconnected pipe indicates a failed login.
      if ( errorDetail == "NT_STATUS_PIPE_DISCONNECTED" ) then
        return false, "Bad username or password", LoginErrorType.InvalidUsernameOrPassword
      end
      return false, data
    end

    local doNTLM = ntlmAuth

    while( pos < data:len() ) do
      pos, token = Token.ParseToken( data, pos )
      if ( -1 == pos ) then
        return false, token
      end

      if ( token.type == TokenType.ErrorMessage ) then
        local errorMessageLookup = {
          [LoginErrorType.AccountLockedOut] = "Account is locked out",
          [LoginErrorType.NotAssociatedWithTrustedConnection] = "User is not associated with a trusted connection (instance may allow Windows authentication only)",
          [LoginErrorType.InvalidUsernameOrPassword] = "Bad username or password",
          [LoginErrorType.PasswordExpired] = "Password is expired",
          [LoginErrorType.PasswordMustChange] = "Must change password at next logon",
        }
        local errorMessage = errorMessageLookup[ token.errno ] or string.format( "Login Failed (%s)", tostring(token.errno) )

        return false, errorMessage, token.errno
      elseif ( token.type == TokenType.LoginAcknowledgement ) then
        return true, "Login Success"
      elseif doNTLM and token.type == TokenType.NTLMSSP_CHALLENGE then
        local authpacket = NTAuthenticationPacket:new( username, password, domain, token.nonce )
        status, result = self.stream:Send( authpacket:ToString() )
        status, data = self.stream:Receive()
        if not status then
          return false, data
        end
        doNTLM = false -- don't try again.
      else
        local found, ttype = tableaux.contains(TokenType, token.type)
        if found then
          stdnse.debug2("Unexpected token type: %s", ttype)
        else
          stdnse.debug2("Unknown token type: 0x%02x", token.type)
        end
      end
    end

    return false, "Failed to process login response"
  end,

  --- Authenticates to SQL Server, using the credentials returned by
  --  Helper.GetLoginCredentials().
  --
  --  If the login is rejected by the server, the error code will be returned,
  --  as a number in the form of a <code>mssql.LoginErrorType</code> (for which
  --  error messages can be looked up in <code>mssql.LoginErrorMessage</code>).
  --
  -- @param instanceInfo a SqlServerInstanceInfo object for the instance to log into
  -- @param database string containing the database to access
  -- @param servername string containing the name or ip of the remote server
  -- @return status true on success, false on failure
  -- @return result containing error code or error message
  LoginEx = function( self, instanceInfo, database, servername )
    local servername = servername or instanceInfo.host.ip
    local username, password = Helper.GetLoginCredentials( instanceInfo )
    if ( not username ) then
      return false, "No login credentials"
    end

    return self:Login( username, password, database, servername )
  end,

  --- Performs a SQL query and parses the response
  --
  -- @param query string containing the SQL query
  -- @return status true on success, false on failure
  -- @return table containing a table of columns for each row
  --         or error message on failure
  Query = function( self, query )

    local queryPacket = QueryPacket:new()
    local status, result, data, token, colinfo, rows
    local pos = 1

    if ( nil == self.stream ) then
      return false, "Not connected to server"
    end

    queryPacket:SetQuery( query )
    status, result = self.stream:Send( queryPacket:ToString() )
    if ( not(status) ) then
      return false, result
    end

    status, data = self.stream:Receive()
    if ( not(status) ) then
      return false, data
    end

    -- Iterate over tokens until we get to a rowtag
    while( pos < data:len() ) do
      local rowtag = string.unpack("B", data, pos)

      if rowtag == TokenType.Row or rowtag == TokenType.Done then
        break
      end

      pos, token = Token.ParseToken( data, pos )
      if ( -1 == pos ) then
        return false, token
      end
      if ( token.type == TokenType.ErrorMessage ) then
        return false, token.error
      elseif ( token.type == TokenType.TDS7Results ) then
        colinfo = token.colinfo
      end
    end


    rows = {}

    while(true) do
      local rowtag
      rowtag, pos = string.unpack("B", data, pos )

      if ( rowtag ~= TokenType.Row ) then
        break
      end

      if ( rowtag == TokenType.Row and colinfo and #colinfo > 0 ) then
        local columns = {}

        for i=1, #colinfo do
          local val

          local coltype = colinfo[i].type
          if ( ColumnData.Parse[coltype] ) then
            if coltype == DataTypes.DECIMALNTYPE or coltype == DataTypes.NUMERICNTYPE then
              -- decimal / numeric types need precision and scale passed.
              pos, val = ColumnData.Parse[coltype]( colinfo[i].precision,  colinfo[i].scale, data, pos)
            else
              pos, val = ColumnData.Parse[coltype](data, pos)
            end

            if ( -1 == pos ) then
              return false, val
            end
            table.insert(columns, val)
          else
            return false, ("unknown datatype=0x%X"):format(coltype)
          end
        end
        table.insert(rows, columns)
      end
    end

    result = {}
    result.rows = rows
    result.colinfo = colinfo

    return true, result
  end,

  --- Attempts to connect to a SQL Server instance listening on a TCP port in
  --  order to determine the version of the SSNetLib DLL, which is an
  --  authoritative version number for the SQL Server instance itself.
  --
  -- @param instanceInfo An instance of SqlServerInstanceInfo
  -- @return status true on success, false on failure
  -- @return versionInfo an instance of mssql.SqlServerVersionInfo, or nil
  GetInstanceVersion = function( instanceInfo )

    if ( not instanceInfo.host or not (instanceInfo:HasNetworkProtocols()) ) then return false, nil end

    local status, response, version
    local tdsStream = TDSStream:new()

    status, response = tdsStream:ConnectEx( instanceInfo )

    if ( not status ) then
      stdnse.debug2("%s: Connection to %s failed: %s", "MSSQL", instanceInfo:GetName(), response or "" )
      return false, "Connect failed"
    end

    local preLoginRequest = PreLoginPacket:new()
    preLoginRequest:SetInstanceName( instanceInfo.instanceName )

    tdsStream:SetTimeout( 5000 )
    tdsStream:Send( preLoginRequest:ToBytes() )

    -- read in any response we might get
    status, response = tdsStream:Receive()
    tdsStream:Disconnect()

    if status then
      local preLoginResponse
      status, preLoginResponse = PreLoginPacket.FromBytes( response )
      if status then
        version = preLoginResponse.versionInfo
      else
        stdnse.debug2("%s: Parsing of pre-login packet from %s failed: %s",
          "MSSQL", instanceInfo:GetName(), preLoginResponse or "" )
        return false, "Parsing failed"
      end
    else
      stdnse.debug2("%s: Receive for %s failed: %s", "MSSQL", instanceInfo:GetName(), response or "" )
      return false, "Receive failed"
    end

    return status, version
  end,

  --- Gets a table containing SqlServerInstanceInfo objects for the instances
  --  that should be run against, based on the script-args (e.g. <code>mssql.instance</code>)
  --
  --  @param host Host table as received by the script action function
  --  @param port (Optional) Port table as received by the script action function
  --  @return status True on success, false on failure
  --  @return instances If status is true, this will be a table with one or
  --    more SqlServerInstanceInfo objects. If status is false, this will be
  --    an error message.
  GetTargetInstances = function( host, port )
    -- Perform discovery. This won't do anything if it's already been done.
    -- It's important because otherwise we might miss some ports when not using -sV
    Helper.Discover( host )

    if ( port ) then
      local instances = Helper.GetDiscoveredInstances(host, port)
      if instances then
        return true, instances
      else
        return false, "No SQL Server instance detected on this port"
      end
    else
      if ( targetAllInstances and ( targetInstanceNames or targetInstancePorts ) ) then
        return false, "All instances cannot be specified together with an instance name or port."
      end

      if ( not (targetInstanceNames or targetInstancePorts or targetAllInstances) ) then
        return false, "No instance(s) specified."
      end

      local instanceList = Helper.GetDiscoveredInstances( host )
      if ( not instanceList ) then
        return false, "No instances found on target host"
      end

      local targetInstances = {}

      for _, instance in ipairs( instanceList ) do
        repeat -- just so we can use break
          if instance.port then
            local scanport = nmap.get_port_state(host, instance.port)
            -- If scanned-ports-only and it's on a non-scanned port
            if (SCANNED_PORTS_ONLY and not scanport)
              -- or if a portrule script will run on it
              or (scanport and scanport.state == "open") then
              break -- not interested
            end
            -- If they want everything
            if targetAllInstances or
              -- or if it's in the instance-port arg
              (targetInstancePorts and
                tableaux.contains(targetInstancePorts, instance.port.number)) then
              -- keep it and move on
              targetInstances[#targetInstances+1] = instance
              break
            end
          end
          -- If they want everything
          if targetAllInstances or
            -- or if it's in the instance-name arg
            (instance.instanceName and targetInstanceNames and
              tableaux.contains(targetInstanceNames, string.upper(instance.instanceName))) then
            --keep it and move on
            targetInstances[#targetInstances+1] = instance
            break
          end
        until false
      end

      if ( #targetInstances > 0 ) then
        return true, targetInstances
      else
        return false, "Specified instance(s) not found on target host"
      end
    end
  end,

  --- Queries the SQL Browser service for the DAC port of the specified instance
  --
  --  The DAC (Dedicated Admin Connection) port allows DBA's to connect to
  --  the database when normal connection attempts fail, for example, when
  --  the server is hanging, out of memory or other bad states.
  --
  --  @param instance the <code>SqlServerInstanceInfo</code> object to probe for a DAC port
  --  @return number containing the DAC port on success or nil on failure
  DiscoverDACPort = function(instance)
    local instanceName = instance.instanceName or instance.pipeName
    if not instanceName then
      return nil
    end
    local socket = nmap.new_socket("udp")
    socket:set_timeout(5000)

    if ( not(socket:connect(instance.host, 1434, "udp")) ) then
      return false, "Failed to connect to sqlbrowser service"
    end

    if ( not(socket:send(string.pack("c2z", "\x0F\x01", instanceName))) ) then
      socket:close()
      return false, "Failed to send request to sqlbrowser service"
    end

    local status, data = socket:receive_buf(match.numbytes(6), true)
    socket:close()
    if ( not(status) ) then
      return nil
    end

    if ( #data < 6 ) then
      return nil
    end
    return string.unpack("<I2", data, 5)
  end,

  ---  Returns an action, portrule, and hostrule for standard SQL Server scripts
  --
  -- The action function performs discovery if necessary and dispatches the
  -- process_instance function on all discovered instances.
  --
  -- The portrule returns true if the port has been identified as "ms-sql-s" or
  -- discovery has found an instance on that port.
  --
  -- The hostrule returns true if any of the <code>mssql.instance-*</code>
  -- script-args has been set and either a matching instance exists or
  -- discovery has not yet been done.
  -- @usage action, portrule, hostrule = mssql.Helper.InitScript(do_something)
  --
  -- @param process_instance A function that takes a single parameter, a
  --                         <code>SqlServerInstanceInfo</code> object, and
  --                         returns output suitable for an action function to
  --                         return.
  --
  -- @return An action function
  -- @return A portrule function
  -- @return A hostrule function
  InitScript = function(process_instance)
    local action = function(host, port)
      local status, instances = Helper.GetTargetInstances(host, port)
      if not status then
        stdnse.debug1("GetTargetInstances: %s", instances)
        return nil
      end
      local output = {}
      for _, instance in ipairs(instances) do
        output[instance:GetName()] = process_instance(instance)
      end
      if next(output) then
        return outlib.sorted_by_key(output)
      end
      return nil
    end

    -- GetTargetInstances does the right thing depending on whether port is
    -- provided, which corresponds to portrule vs hostrule.
    return action, Helper.GetTargetInstances, Helper.GetTargetInstances
  end,
}

local TDS7Crypt_enc = function (cp)
      local c = cp ~ 0x5a5a
      local m1= ( c >> 4 ) & 0x0F0F
      local m2= ( c << 4 ) & 0xF0F0
      return string.pack("<I2", m1 | m2 )
end

Auth = {

  --- Encrypts a password using the TDS7 *ultra secure* XOR encryption
  --
  -- @param password string containing the password to encrypt
  -- @param decoder a unicode.lua decoder function to convert password to code points
  -- @return string containing the encrypted password
  TDS7CryptPass = function(password, decoder)
    return unicode.transcode(password, decoder, TDS7Crypt_enc)
  end,

  LmResponse = function( password, nonce )

    if ( not(HAVE_SSL) ) then
      stdnse.debug1("ERROR: Nmap is missing OpenSSL")
      return
    end

    password = password .. string.rep('\0', 14 - #password)

    password = password:upper()

    -- Take the first and second half of the password (note that if it's longer than 14 characters, it's truncated)
    local str1 = string.sub(password, 1, 7)
    local str2 = string.sub(password, 8, 14)

    -- Generate the keys
    local key1 = openssl.DES_string_to_key(str1)
    local key2 = openssl.DES_string_to_key(str2)

    local result = openssl.encrypt("DES", key1, nil, nonce) .. openssl.encrypt("DES", key2, nil, nonce)

    result = result .. string.rep('\0', 21 - #result)

    str1 = string.sub(result, 1, 7)
    str2 = string.sub(result, 8, 14)
    local str3 = string.sub(result, 15, 21)

    key1 = openssl.DES_string_to_key(str1)
    key2 = openssl.DES_string_to_key(str2)
    local key3 = openssl.DES_string_to_key(str3)

    result = openssl.encrypt("DES", key1, nil, nonce) .. openssl.encrypt("DES", key2, nil, nonce) .. openssl.encrypt("DES", key3, nil, nonce)
    return result
  end,

  NtlmResponse = function( password, nonce )
    local lm_response, ntlm_response, mac_key = smbauth.get_password_response(nil,
      nil,
      nil,
      password,
      nil,
      "v1",
      nonce,
      false
    )
    return ntlm_response
  end,
}

--- "static" Utility class containing mostly conversion functions
Util =
{
  --- Takes a table as returned by Query and does some fancy formatting
  --  better suitable for <code>stdnse.format_output</code>
  --
  -- @param tbl as received by <code>Helper.Query</code>
  -- @param with_headers boolean true if output should contain column headers
  -- @return table suitable for <code>stdnse.format_output</code>
  FormatOutputTable = function ( tbl, with_headers )
    local new_tbl = {}
    local col_names = {}

    if ( not(tbl) ) then
      return
    end

    if ( with_headers and tbl.rows and #tbl.rows > 0 ) then
      local headers
      for k, v in pairs( tbl.colinfo ) do
        table.insert( col_names, v.text)
      end
      headers = table.concat(col_names, "\t")
      table.insert( new_tbl, headers)
      headers = headers:gsub("[^%s]", "=")
      table.insert( new_tbl, headers )
    end

    for _, v in ipairs( tbl.rows ) do
      table.insert( new_tbl, table.concat(v, "\t") )
    end

    return new_tbl
  end,
}

local unittest = require "unittest"
if not unittest.testing() then
  return _ENV
end

local tests = {
  {"host", "\x23\xa5\x53\xa5\x92\xa5\xe2\xa5", unicode.utf8_dec},
  {"p@ssword12-", "\xa2\xa5\xa1\xa5\x92\xa5\x92\xa5\xd2\xa5\x53\xa5\x82\xa5\xe3\xa5\xb6\xa5\x86\xa5\x77\xa5", unicode.utf8_dec},
}
test_suite = unittest.TestSuite:new()

for _, test in ipairs(tests) do
  test_suite:add_test(unittest.equal(Auth.TDS7CryptPass(test[1], test[3]), test[2]), ("TDS7 crypt %s"):format(test[1]))
end

return _ENV
