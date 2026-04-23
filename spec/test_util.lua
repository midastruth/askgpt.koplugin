local H    = require("spec.helpers")
local Util = require("askgpt.util")

H.section("A. askgpt/util.lua")

-- trim
H.eq("trim(nil) -> ''",           Util.trim(nil),   "")
H.eq("trim('  hi  ') -> 'hi'",    Util.trim("  hi  "), "hi")
H.eq("trim('') -> ''",            Util.trim(""),    "")
H.eq("trim('no spaces') -> same", Util.trim("no spaces"), "no spaces")

-- split_csv
H.eq("split_csv(nil) -> {}",          Util.split_csv(nil),           {})
H.eq("split_csv('') -> {}",           Util.split_csv(""),            {})
H.eq("split_csv('a, b , ,c') -> 3",   Util.split_csv("a, b , ,c"),  {"a","b","c"})
H.eq("split_csv('single') -> {single}",Util.split_csv("single"),    {"single"})
H.eq("split_csv('x,y,z') -> 3",       Util.split_csv("x,y,z"),      {"x","y","z"})

-- clone_table
local src  = { a = 1, b = 2 }
local copy = Util.clone_table(src)
H.is_true("clone_table copies keys",   copy.a == 1 and copy.b == 2)
H.is_true("clone_table is new table",  copy ~= src)
