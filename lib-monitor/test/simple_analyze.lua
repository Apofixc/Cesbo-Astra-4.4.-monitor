local input_url = "http://31.130.202.110/httpts/tv3by/avchigh.ts"
local stream = make_stream({
    name = "TestStream",
    input = { input_url },
    output = { "file:///dev/null" }
})

local a = analyze({
    upstream = stream:stream(),
    name = "SimpleAnalyzer",
    join_pid = true,
    rate_stat = true,
    callback = function(data)
        if data.psi then
            log.info("PSI: " .. tostring(data.psi))
        end
        if data.rate then
            log.info("RATE: " .. json.encode(data.rate))
        end
    end
})

timer({
    interval = 10,
    callback = function()
        log.info("10 seconds passed, exiting")
        astra.exit()
    end
})
