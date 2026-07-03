local _DTAG = 0.25

local function ptest(test, names, tags)
    local st, res = pcall(test, '', names, tags)
    if not st then
        if string.find(res, 'compare') then return -1 end
        if string.find(res, 'arith') then return -2 end
        return -3
    end
    return res and 1 or 0
end

local function RawToSimple(names, tags)
    local recipe = { minnames = {}, mintags = {}, maxnames = {}, maxtags = {} }
    for name, amount in pairs(names) do
        if amount < 1000 then recipe.maxnames[name] = amount end
        if amount > 0 then recipe.minnames[name] = amount end
    end
    for tag, amount in pairs(tags) do
        if amount < 1000 then recipe.maxtags[tag] = amount end
        if amount > 0 then recipe.mintags[tag] = amount end
    end
    return recipe
end

local BruteForceSearch

local function SmartSearch(test, allnames, alltags)
    local tags = {}
    local names = {}
    local tags_proxy = {}
    local names_proxy = {}
    local access_list = {}
    local all_accessed_names = {}
    local all_accessed_tags = {}

    setmetatable(names_proxy, { __index = function(t, field)
        table.insert(access_list, { type = 'names', field = field })
        all_accessed_names[field] = true
        if allnames[field] == nil then
            allnames[field] = 4
        end
        return names[field]
    end })

    setmetatable(tags_proxy, { __index = function(t, field)
        table.insert(access_list, { type = 'tags', field = field })
        all_accessed_tags[field] = true
        if alltags[field] == nil then
            alltags[field] = 1000
        end
        return tags[field]
    end })

    local result
    while true do
        access_list = {}
        result = ptest(test, names_proxy, tags_proxy)

        if result == 1 then
            return RawToSimple(names, tags), all_accessed_names, all_accessed_tags,
                   names, tags, names_proxy, tags_proxy
        elseif result == -3 or #access_list == 0 then
            return nil
        elseif result == -2 then
            return nil
        else
            local access = table.remove(access_list)
            if access.type == 'tags' then
                tags[access.field] = (tags[access.field] or 0) + _DTAG
                if tags[access.field] > 4 then break end
            elseif access.type == 'names' then
                names[access.field] = (names[access.field] or 0) + 1
                if names[access.field] > 4 then break end
            end
        end
    end

    return BruteForceSearch(test, all_accessed_names, all_accessed_tags,
                            allnames, alltags,
                            names, tags, names_proxy, tags_proxy)
end

BruteForceSearch = function(test, accessed_names, accessed_tags,
                                allnames, alltags,
                                names, tags, names_proxy, tags_proxy)
    local names_list = {}
    for name, _ in pairs(accessed_names) do
        table.insert(names_list, name)
    end
    local tags_list = {}
    for tag, _ in pairs(accessed_tags) do
        table.insert(tags_list, tag)
    end

    local n_count, t_count = #names_list, #tags_list
    if n_count == 0 and t_count == 0 then
        return nil end

    local t_steps = math.floor(4 / _DTAG) + 1
    local total = 1
    for _ = 1, n_count do total = total * 5 end
    for _ = 1, t_count do total = total * t_steps end
    if total > 100000 then
        return nil end

    for k in pairs(names) do names[k] = nil end
    for k in pairs(tags) do tags[k] = nil end

    local function dfs_tags(idx)
        if idx > t_count then
            if ptest(test, names_proxy, tags_proxy) == 1 then
                local res = { names = {}, tags = {} }
                for k, v in pairs(names) do res.names[k] = v end
                for k, v in pairs(tags) do res.tags[k] = v end
                return res
            end
            return nil
        end
        local tag = tags_list[idx]
        local max_val = math.min(4, alltags[tag] or 4)
        local steps = math.floor(max_val / _DTAG)
        for i = 0, steps do
            tags[tag] = i * _DTAG
            local ok = dfs_tags(idx + 1)
            if ok then return ok end
        end
        tags[tag] = nil
        return nil
    end

    local function dfs_names(idx)
        if idx > n_count then return dfs_tags(1) end
        local name = names_list[idx]
        for val = 0, 4 do
            names[name] = val
            local ok = dfs_names(idx + 1)
            if ok then return ok end
        end
        names[name] = nil
        return nil
    end

    local bf_result = dfs_names(1)
    if bf_result then
        return RawToSimple(bf_result.names, bf_result.tags),
               accessed_names, accessed_tags,
               bf_result.names, bf_result.tags,
               names_proxy, tags_proxy
    end
    return nil
end

local function resolve_tag_display(simple, tag, test, vnp, vtp, vtags)
    local val = simple.mintags[tag]
    local display_val = math.floor(val / _DTAG + 0.0001) * _DTAG
    local mode
    vtags[tag] = display_val
    if ptest(test, vnp, vtp) == 1 then
        mode = ">="
    else
        mode = ">"
    end
    if display_val == 0 then
        mode = ">"
    end
    vtags[tag] = val
    if not simple.mintag_display then simple.mintag_display = {} end
    simple.mintag_display[tag] = { value = display_val, mode = mode }
end

local function MinimizeRecipe(test, simple, allnames, alltags, names, tags, names_proxy, tags_proxy)
    local vnames = {}
    for name, amt in pairs(simple.minnames) do
        vnames[name] = amt
    end
    local vtags = {}
    for tag, amt in pairs(simple.mintags) do
        vtags[tag] = amt
    end

    local vnp = setmetatable({}, { __index = function(t, k)
        return vnames[k]
    end })
    local vtp = setmetatable({}, { __index = function(t, k)
        return vtags[k]
    end })

    if ptest(test, vnp, vtp) ~= 1 then
        return false
    end

    for name, amount in pairs(vnames) do
        vnames[name] = nil
        if ptest(test, vnp, vtp) == 1 then
            simple.minnames[name] = nil
        else
            vnames[name] = amount - 1
            if ptest(test, vnp, vtp) ~= 1 then
                vnames[name] = amount
            else
                vnames[name] = 1
                while ptest(test, vnp, vtp) ~= 1 and vnames[name] <= 4 do
                    vnames[name] = vnames[name] + 1
                end
                simple.minnames[name] = vnames[name]
            end
        end
    end

    for tag, amount in pairs(vtags) do
        vtags[tag] = nil
        if ptest(test, vnp, vtp) == 1 then
            simple.mintags[tag] = nil
        else
            vtags[tag] = amount - _DTAG
            if ptest(test, vnp, vtp) ~= 1 then
                local lo, hi = amount - _DTAG, amount
                while hi - lo > 0.001 do
                    local mid = (lo + hi) / 2
                    vtags[tag] = mid
                    if ptest(test, vnp, vtp) == 1 then
                        hi = mid
                    else
                        lo = mid
                    end
                end
                vtags[tag] = hi
                simple.mintags[tag] = hi
                resolve_tag_display(simple, tag, test, vnp, vtp, vtags)
            else
                vtags[tag] = _DTAG
                while ptest(test, vnp, vtp) ~= 1 and vtags[tag] < 1001 do
                    vtags[tag] = vtags[tag] + _DTAG
                end
                simple.mintags[tag] = vtags[tag]
                local lo, hi = vtags[tag] - _DTAG, vtags[tag]
                while hi - lo > 0.001 do
                    local mid = (lo + hi) / 2
                    vtags[tag] = mid
                    if ptest(test, vnp, vtp) == 1 then
                        hi = mid
                    else
                        lo = mid
                    end
                end
                vtags[tag] = hi
                simple.mintags[tag] = hi
                resolve_tag_display(simple, tag, test, vnp, vtp, vtags)
            end
        end
    end

    local buffer
    for name, _ in pairs(allnames) do
        buffer = vnames[name]
        local maxtest = math.max(
            simple.minnames[name] and simple.minnames[name] + 1 or 0,
            simple.maxnames[name] and simple.maxnames[name] + 1 or 0,
            1
        )
        vnames[name] = maxtest
        if ptest(test, vnp, vtp) == 1 then
            vnames[name] = 4
            if ptest(test, vnp, vtp) == 1 then
                simple.maxnames[name] = nil
            else
                vnames[name] = maxtest + 1
                while ptest(test, vnp, vtp) == 1 and vnames[name] <= 4 do
                    vnames[name] = vnames[name] + 1
                end
                simple.maxnames[name] = vnames[name] - 1
            end
        else
            repeat
                vnames[name] = vnames[name] - 1
            until vnames[name] <= 0 or ptest(test, vnp, vtp) == 1
            simple.maxnames[name] = vnames[name]
        end
        vnames[name] = buffer
    end

    for tag, _ in pairs(alltags) do
        buffer = vtags[tag]
        local maxtest = math.max(
            simple.mintags[tag] and simple.mintags[tag] + _DTAG or 0,
            simple.maxtags[tag] and simple.maxtags[tag] + _DTAG or 0,
            _DTAG
        )
        vtags[tag] = maxtest
        if ptest(test, vnp, vtp) == 1 then
            vtags[tag] = 1000
            if ptest(test, vnp, vtp) == 1 then
                simple.maxtags[tag] = nil
            else
                vtags[tag] = maxtest + _DTAG
                while ptest(test, vnp, vtp) == 1 and vtags[tag] < 1001 do
                    vtags[tag] = vtags[tag] + _DTAG
                end
                simple.maxtags[tag] = vtags[tag] - _DTAG
            end
        else
            repeat
                vtags[tag] = vtags[tag] - _DTAG
            until vtags[tag] <= 0 or ptest(test, vnp, vtp) == 1
            simple.maxtags[tag] = vtags[tag]
        end
        vtags[tag] = buffer
    end

    for tag, _ in pairs(simple.maxtags or {}) do
        local X = simple.maxtags[tag]
        if X ~= nil then
            local saved = vtags[tag]
            local mode, display_val
            vtags[tag] = X + 0.001
            if ptest(test, vnp, vtp) == 1 then
                mode = "<"
                display_val = X + _DTAG
            else
                mode = "<="
                display_val = X
            end
            vtags[tag] = saved
            if not simple.maxtag_display then simple.maxtag_display = {} end
            simple.maxtag_display[tag] = { value = display_val, mode = mode }
        end
    end

    return true
end

local function FindAnalogGroups(test, simple, allnames, alltags)
    if not simple.minnames or next(simple.minnames) == nil then
        return nil
    end

    local raw = {}
    for name, amt in pairs(simple.minnames) do
        local vnames = {}
        for n, a in pairs(simple.minnames) do
            if n ~= name then
                vnames[n] = a
            end
        end
        local vtags = {}
        for t, a in pairs(simple.mintags) do
            vtags[t] = a
        end

        local vnp = setmetatable({}, { __index = function(t, k)
            return allnames[k] and vnames[k] or nil
        end})
        local vtp = setmetatable({}, { __index = function(t, k)
            return alltags[k] and vtags[k] or nil
        end})

        local group = {}
        for candidate, _ in pairs(allnames) do
            local prev = vnames[candidate]
            vnames[candidate] = (vnames[candidate] or 0) + amt
            if ptest(test, vnp, vtp) == 1 then
                table.insert(group, candidate)
            end
            vnames[candidate] = prev
        end

        if #group > 1 then
            table.sort(group)
            raw[name] = group
        end
    end

    if next(raw) == nil then return nil end

    local merged = {}
    local seen = {}

    local function merge_groups(start_name, group)
        local super = {}
        local stack = { start_name }
        while #stack > 0 do
            local cur = table.remove(stack)
            if not seen[cur] then
                seen[cur] = true
                super[cur] = true
                if raw[cur] then
                    for _, m in ipairs(raw[cur]) do
                        if not seen[m] then
                            table.insert(stack, m)
                        end
                    end
                end
            end
        end
        return super
    end

    for name, _ in pairs(raw) do
        if not seen[name] then
            local super = merge_groups(name, raw)
            local sorted, total_amount = {}, 0
            for k, _ in pairs(super) do
                table.insert(sorted, k)
                total_amount = total_amount + (simple.minnames[k] or 0)
            end
            table.sort(sorted)
            table.insert(merged, {
                names = sorted,
                amount = total_amount,
            })
        end
    end

    return merged
end

local Detector = {}

function Detector.Detect(test_func, ingredients)
    if type(test_func) ~= "function" then return nil end
    if not ingredients then return nil end

    local allnames = {}
    local alltags = {}
    for name, data in pairs(ingredients) do
        allnames[name] = 4
        if data.tags then
            for tag, _ in pairs(data.tags) do
                if not alltags[tag] then
                    alltags[tag] = 1000
                end
            end
        end
    end

    local simple, an, at, raw_names, raw_tags, np, tp =
        SmartSearch(test_func, allnames, alltags)
    if not simple then
        return nil
    end

    local ok = MinimizeRecipe(test_func, simple, allnames, alltags,
                              raw_names, raw_tags, np, tp)
    if not ok then
        return nil
    end

    simple.analog_groups = FindAnalogGroups(test_func, simple, allnames, alltags)

    local group_covered = {}
    if simple.analog_groups then
        for _, group in ipairs(simple.analog_groups) do
            for _, gname in ipairs(group.names) do
                group_covered[gname] = true
            end
        end
    end

    local slot_min = 0
    for name, amt in pairs(simple.minnames or {}) do
        if not group_covered[name] then
            slot_min = slot_min + amt
        end
    end
    if simple.analog_groups then
        for _, group in ipairs(simple.analog_groups) do
            slot_min = slot_min + group.amount
        end
    end

    if slot_min == 4 then
        if not simple.maxnames then
            simple.maxnames = {}
        end
        for name, amt in pairs(simple.minnames or {}) do
            if simple.maxnames[name] == nil then
                simple.maxnames[name] = amt
            end
        end
        if simple.analog_groups then
            for _, group in ipairs(simple.analog_groups) do
                for _, gname in ipairs(group.names) do
                    if simple.maxnames[gname] == nil then
                        simple.maxnames[gname] = group.amount
                    end
                end
            end
        end
    end

    return simple
end

return Detector