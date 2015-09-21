#! /usr/bin/env luajit

local function printfln(fmt, ...)
	print(fmt:format(...))
end

local function average(values)
	local sum = 0.0
	for _, value in ipairs(values) do
		sum = sum + value
	end
	return sum / #values
end

local function stderror(values)
	local avg = average(values)
	local diffsum = 0.0
	for _, value in ipairs(values) do
		local diff = (value - avg)
		diffsum = diffsum + (diff * diff)
	end
	local stddev = math.sqrt(diffsum / #values)
	return stddev / math.sqrt(#values)
end


if #arg ~= 2 then
	io.stderr:write("Usage: benchrun.lua N command\n")
	os.exit(1)
end
local rounds = tonumber(arg[1])
local command = arg[2]

local sample_sets = {}
for i = 1, rounds do
	local proc = io.popen(command, "r")
	local sample_set = 1
	for line in proc:lines() do
		-- Rate: N.M MPPS
		local value, nsubs = string.gsub(line, "^Rate:%s+([%d%.]+)%s+MPPS$", "%1")
		if nsubs > 0 then
			if sample_sets[sample_set] == nil then
				sample_sets[sample_set] = {}
			end
			table.insert(sample_sets[sample_set], tonumber(value))
			sample_set = sample_set + 1
		end
	end
end

for setnum, samples in ipairs(sample_sets) do
	printfln("set %d", setnum)
	printfln("  min: %g", math.min(unpack(samples)))
	printfln("  max: %g", math.max(unpack(samples)))
	printfln("  avg: %g", average(samples))
	printfln("  err: %g", stderror(samples))
end

if #sample_sets > 1 then
	local sum_samples = {}
	for i = 1, #sample_sets[1] do
		local v = 0.0
		for _, samples in ipairs(sample_sets) do
			v = v + samples[1]
		end
		table.insert(sum_samples, v)
	end
	printfln("sum", setnum)
	printfln("  min: %g", math.min(unpack(sum_samples)))
	printfln("  max: %g", math.max(unpack(sum_samples)))
	printfln("  avg: %g", average(sum_samples))
	printfln("  err: %g", stderror(sum_samples))
end
