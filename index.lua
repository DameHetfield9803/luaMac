print("Hello world")

local function min(a,b)
    if(a > b) then 
        return a;
    else 
        return b;
    end
end

print(min(2.0,12))

A = 10
local i = 0
while i < A do
    print(i)
    i = i+1
end