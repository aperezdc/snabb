module(..., package.seeall)

local bit = require("bit")
local pf = require("pf")

--- ### `basicnat` app: Implement http://www.ietf.org/rfc/rfc1631.txt Basic NAT
--- This translates one IP address to another IP address

BasicNAT = {}

local function bytes_to_uint32(a, b, c, d)
   return a * 2^24 + b * 2^16 + c * 2^8 + d
end

local function str_ip_to_uint32(ip)
   local a, b, c, d = ip:match("([0-9]+).([0-9]+).([0-9]+).([0-9]+)")
   return bytes_to_uint32(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

local function subst(str, values)
   local out, pos = '', 1
   while true do
      local before, after = str:match('()%$[%w_]+()', pos)
      if not before then return out..str:sub(pos) end
      out = out..str:sub(pos, before - 1)
      local var = str:sub(before + 1, after - 1)
      local val = values[var]
      print (before, after, var, val)
      if not val then error('var not found: '..var) end
      out = out..val
      pos = after
   end
   return out
end

local function uint32_to_bytes(u)
   local a = bit.rshift(u, 24)
   local b = bit.band(bit.rshift(u, 16), 0xff)
   local c = bit.band(bit.rshift(u, 8), 0xff)
   local d = bit.band(u, 0xff)
   return a, b, c, d
end

local function csum_carry_and_not(checksum)
   while checksum > 0xffff do -- process the carry nibbles
      local carry = bit.rshift(checksum, 16)
      checksum = bit.band(checksum, 0xffff) + carry
   end
   return bit.band(bit.bnot(checksum), 0xffff)
end

local function ipv4_checksum(data, ip_base)
   local IHL = bit.rshift(data[ip_base], 4)
   local len = IHL * 4
   local checksum = 0
   for i = ip_base, ip_base + len, 2 do
      if i ~= ip_base + 10 then -- The checksum bytes are assumed to be 0
         checksum = checksum + data[i] * 0x100 + data[i+1]
      end
   end
   return csum_carry_and_not(checksum)
end

local function tcp_checksum(data, ip_base, tcp_base, tcp_len)
   local checksum = 0
   -- First 64 bytes of the TCP pseudo-header: the ip addresses
   for i = ip_base + 12, ip_base + 18, 2 do
      checksum = checksum + data[i] * 0x100 + data[i+1]
   end
   -- Add the protocol field of the IPv4 header to the checksum
   local protocol = data[ip_base + 9]
   checksum = checksum + protocol
   local tcplen = data[ip_base + 2] * 0x100 + data[ip_base + 3] - 20
   checksum = checksum + tcplen -- end of pseudo-header

   for i = transport_base, transport_base + tcplen - 2, 2 do
      if i ~= transport_base + 16 then -- The checksum bytes are zero
         checksum = checksum + data[i] * 0x100 + data[i+1]
      end
   end
   if tcplen % 2 == 1 then
      checksum = checksum + data[transport_base + tcplen - 1]
   end
   return csum_carry_and_not(checksum)
end

local function udp_checksum(data, ip_base, udp_base, udp_len)
   -- ipv4 udp checksums are optional
   return 0
end

local function fix_tcp_checksums(data, ip_base, tcp_base, payload_len)
   local checksum = tcp_checksum(data, ip_base, tcp_base, payload_len)
   data[tcp_base + 16] = bit.rshift(checksum, 8)
   data[tcp_base + 17] = bit.band(checksum, 0xff)
end

local function fix_udp_checksums(data, ip_base, udp_base, payload_len)
   local checksum = udp_checksum(data, ip_base, udp_base, payload_len)
   data[udp_base + 6] = bit.rshift(checksum, 8)
   data[udp_base + 7] = bit.band(checksum, 0xff)
end

local function fix_ip_checksums(data, ip_base)
   local checksum = ipv4_checksum(data, ip_base)
   data[ip_base + 10] = bit.rshift(checksum, 8)
   data[ip_base + 11] = bit.band(checksum, 0xff)
end

local function set_src_ip(data, ip_base, ip)
   local a, b, c, d = uint32_to_bytes(ip)
   data[ip_base + 12] = a
   data[ip_base + 13] = b
   data[ip_base + 14] = c
   data[ip_base + 15] = d
   fix_ip_checksums(data, ip_base)
end

local function set_dst_ip(data, ip_base, ip)
   local a, b, c, d = uint32_to_bytes(ip)
   data[ip_base + 16] = a
   data[ip_base + 17] = b
   data[ip_base + 18] = c
   data[ip_base + 19] = d
   fix_ip_checksums(data, ip_base)
end

-- For packets outbound from the
-- private IP, the source IP address and related fields such as IP,
-- TCP, UDP and ICMP header checksums are translated. For inbound
-- packets, the destination IP address and the checksums as listed above
-- are translated.

-- FIXME: Would be nice to have &ip src as an addressable.
-- todo: add comment syntax, "else"
local dispatch_template = [[
(forward, drop,
 incoming_tcp, incoming_udp, incoming_other,
 outgoing_tcp, outgoing_udp, outgoing_other) => {
   not ip => forward
   ip[6] & 0x4 = 1 => drop
   ip src $external_ip => {
      tcp => incoming_tcp(&ip[0], &tcp[0])
      udp => incoming_udp(&ip[0], &udp[0])
      _ => incoming_other(&ip[0])
   }
   ip dst $internal_ip => {
      tcp => outgoing_tcp(&ip[0], &tcp[0])
      udp => outgoing_udp(&ip[0], &udp[0])
      _ => outgoing_other(&ip[0])
   }
   _ => drop
}]]

local function forward(data, len)
   return len
end

local function drop(data, len)
   -- Could truncate packet here and overwrite with ICMP error if
   -- wanted.
   return false
end

local function make_dispatcher(conf)
   local external_ip = str_ip_to_uint32(conf.external_ip)
   local internal_ip = str_ip_to_uint32(conf.internal_ip)
   -- FIXME: Verify IP header length within packet length?  What about
   -- payload length?
   local function incoming_tcp(data, len, ip_base, tcp_base)
      set_src_ip(data, ip_base, internal_ip)
      fix_tcp_checksums(data, tcp_base, len - tcp_base)
      return len
   end
   local function incoming_udp(data, len, ip_base, udp_base)
      set_src_ip(data, ip_base, internal_ip)
      fix_udp_checksums(data, udp_base, len - udp_base)
      return len
   end
   local function incoming_other(data, len, ip_base, payload_base)
      set_src_ip(data, ip_base, internal_ip)
      return len
   end
   local function outgoing_tcp(data, len, ip_base, tcp_base)
      set_dst_ip(data, ip_base, external_ip)
      fix_tcp_checksums(data, tcp_base, len - tcp_base)
      return len
   end
   local function outgoing_udp(data, len, ip_base, udp_base)
      set_dst_ip(data, ip_base, external_ip)
      fix_udp_checksums(data, udp_base, len - udp_base)
      return len
   end
   local function outgoing_other(data, len, ip_base)
      set_dst_ip(data, ip_base, external_ip)
      return len
   end
   return pf.dispatch.compile(subst(dispatch_template, conf))(
      forward, drop,
      incoming_tcp, incoming_udp, incoming_other,
      outgoing_tcp, outgoing_udp, outgoing_other)
end

function BasicNAT:new (conf)
   local c = {dispatch = make_dispatcher(conf)}
   return setmetatable(c, {__index=BasicNAT})
end

function BasicNAT:push ()
   local i, o = self.input.input, self.output.output
   while not link.empty() do
      local pkt = link.receive(i)
      local out_len = self.dispatch(pkt.data, pkt.length)
      if out_len then
         pkt.length = out.len
         link.transmit(o, pkt)
      end
   end
end
