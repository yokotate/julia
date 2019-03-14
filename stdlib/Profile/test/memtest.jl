using Profile

import Profile.Memory: clear_memprofile_data, read_and_coalesce_memprofile_data, get_memprofile_bt_data, get_memprofile_bt_data_len, get_memprofile_alloc_data, get_memprofile_alloc_data_len, AllocationInfo, get_memprofile_overflow, bt_lookup_dict, close_AI, open_AI, start_memprofile, stop_memprofile, closing_tag

forever_chunks = []
function foo()
    # Create a chunk that will live forever
    push!(forever_chunks, Array{UInt8,2}(undef,1000,1000))

    # Create a chunk that......will not.
    Array{UInt8,2}(undef,1000,100)

    # Create lots of little objects
    tups = Any[(1,), (2,3)]
    for idx in 1:4
        addition = (tups[end-1]..., tups[end]...)
        addition = addition[2:end]
        push!(tups, addition)
    end
    # Keep a few of them around
    push!(forever_chunks, tups[1])
    push!(forever_chunks, tups[end])
    return nothing
end

exclude_pool = xor(0xff, Profile.Memory.allocator_map[:pool])

Profile.Memory.init(50_000_000, 1_000_000, 0xffff)
forever_chunks = []
@memprofile foo()
forever_chunks = []
Profile.Memory.init(50_000_000, 1_000_000, 0xffff)
@memprofile foo()

open_chunks, closed_chunks, ghost_chunks = read_and_coalesce_memprofile_data()
