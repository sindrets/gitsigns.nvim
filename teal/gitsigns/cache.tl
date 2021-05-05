local Hunk = require("gitsigns.hunks").Hunk
local Sign = require('gitsigns.signs').Sign
local GitObj = require('gitsigns.git').Obj

local record M
  record CacheEntry
    file          : string
    compare_file  : string    -- For use with externl diff
    compare_text  : {string}  -- For use with internal diff
    hunks         : {Hunk}
    staged_diffs  : {Hunk}
    pending_signs : {integer:Sign}
    index_watcher : vim.loop.FSPollObj -- Timer object watching the files index
    git_obj       : GitObj
    commit        : string
  end
  cache: {integer:CacheEntry}
end

M.cache = {}

return M
