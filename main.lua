local function add(a)
    local sum = 0
    for v in ipairs(a) do
        sum = sum + v
    end
    return sum
end

print(add({1,2,3,4,5,6,7}))