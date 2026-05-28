-- ftdetect/q.lua
-- Filetype detection: *.q → "q", *.k → "k"
vim.filetype.add({
  extension = {
    q = "q",
    k = "k",
  },
})
