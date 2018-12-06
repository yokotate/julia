module Memory

using Profile.StackTraceTools
using Base.StackTraces
export clear_malloc_data, @memprofile, AllocationInfo

##
## For --track-allocation (unrelated to @memprofile)
##
# Reset the malloc log. Used to avoid counting memory allocated during
# compilation.

"""
    clear_malloc_data()

Clears any stored memory allocation data when running julia with `--track-allocation`.
Execute the command(s) you want to test (to force JIT-compilation), then call
[`clear_malloc_data`](@ref). Then execute your command(s) again, quit
Julia, and examine the resulting `*.mem` files.
"""
clear_malloc_data() = ccall(:jl_clear_malloc_data, Cvoid, ())


"""
    build_tag_filter(memory_domain = :all, allocator = :all)

Build a memory profile tag filter that will capture only events matching the given
filter parameters.  This method is meant to mirror the `#define`'d `JL_MEMPROF_TAG_*`
values within `julia_internal,.h`.  Valid memory domains are `:cpu`, `:gpu`, `:external`
and `:all`.  Valid allocators are `:std`, `:pool`, `:big`, and `:all`.

You can build a union of multiple allocators and memory domains by passing in a
vector of symbols, e.g. `build_tag_filter(:all, [:std, :pool])`.
"""
function build_tag_filter(memory_domain = :all, allocator = :all)
    tag_lookup(d::Dict, s::Symbol) = d[s]
    tag_lookup(d::Dict, v::Vector{Symbol}) = reduce(|, [d[s] for s in v])

    memory_domain_map = Dict(
        :cpu => 0x01,
        :gpu => 0x02,
        :external => 0x04,

        :all => 0x0f,
    )
    allocator_map = Dict(
        :std => 0x10,
        :pool => 0x20,
        :big => 0x40,

        :all => 0xf0,
    )
    return tag_lookup(memory_domain_map, memory_domain) | tag_lookup(allocator_map, allocator)
end

"""
    init(; bt_size::Integer, alloc_size::Integer, tag_filter::UInt8)

Configure the number `bt_size` of instruction pointers that may be stored for backtraces
of memory allocation and deallocation locatinos, as well as the number of allocation event
structures that are prepared for when profiling memory usage. Each instruction pointer
corresponds to a single line of code; backtraces generally consist of a long list of
instruction pointers. Default settings can be obtained by calling this function with no
arguments, and each can be set independently using keywords or in the order `(bt_size, alloc_size)`.

`tag_filter` can be used to filter what kind of events are captured by the memory profiler,
see `build_tag_filter()` for more.
"""
function init(; bt_size::Union{Nothing,Integer} = nothing,
                alloc_size::Union{Nothing,Integer} = nothing,
                tag_filter::UInt8 = build_tag_filter())
    bt_size_cur = ccall(:jl_memprofile_len_bt_data, Csize_t, ())
    alloc_size_cur = ccall(:jl_memprofile_len_alloc_data, Csize_t, ())
    if bt_size === nothing && alloc_size === nothing
        # If they're both nothing, don't call init(), just return this immediately, because
        # we're not going to reallocate anything.
        return Int(bt_size_cur), Int(alloc_size_cur)
    end
    bt_size = something(bt_size, bt_size_cur)
    alloc_size = something(alloc_size, alloc_size_cur)
    tag_filter = something(tag_filter, 0xff)

    # Sub off to our friend
    return init(bt_size, alloc_size, tag_filter)
end

function init(bt_size::Integer, alloc_size::Integer, tag_filter::UInt8)
    status = ccall(:jl_memprofile_init, Cint, (Csize_t, Csize_t, UInt8), bt_size, alloc_size, tag_filter)
    if status == -1
        error("could not allocate space for ", bt_size, " instruction pointers and ", alloc_size, " allocation event structures")
    end
end

# This struct must stay in sync with `src/memprofiler.c`
struct allocation_info_t
    address::Ptr{Cvoid}
    time::Float64
    allocsz::Csize_t
    tag::UInt8
end

# This struct is a combined version of the above `allocation_info_t` with backtrace data
struct AllocationInfo
    address::UInt
    alloc_time::Float64
    free_time::Float64
    alloc_stacktrace::Vector{StackFrame}
    free_stacktrace::Vector{StackFrame}
    allocsz::UInt64
    tag::UInt8
end

"""
    open_AI(a::allocation_info_t, alloc_stacktrace)

Create an `AllocationInfo` that represents an allocated (and not yet deallocated) chunk
of memory.  This `AllocationInfo` will later be "closed" to represent the full lifecycle
of an allocated and then freed piece of memory.  This function has also been known to
create highly competitive dota agents.
"""
function open_AI(a::allocation_info_t, alloc_stacktrace)
    return AllocationInfo(
        UInt(a.address),
        a.time,
        0.0,
        alloc_stacktrace,
        StackFrame[],
        UInt64(a.allocsz),
        a.tag,
    )
end

"""
    close_AI(a::AllocationInfo, d::allocation_info_t, dealloc_stacktrace)

Mark a previously opened `AllocationInfo` as closed, denoting that we know both the
allocation and deallocation points for this chunk of memory.
"""
function close_AI(a::AllocationInfo, d::allocation_info_t, dealloc_stacktrace)
    # Ensure that we're dealing with the same memory location
    @assert a.address == UInt(d.address) "Attempting to close different memory locations!"
    @assert a.tag == d.tag "Attempting to close memory from different domains!"

    return AllocationInfo(
        a.address,
        a.alloc_time,
        d.time,
        a.alloc_stacktrace,
        dealloc_stacktrace,
        a.allocsz,
        a.tag,
    )
end

macro memprofile(ex)
    return quote
        try
            Base.GC.gc()
            start_memprofile()
            $(esc(ex))
        finally
            stop_memprofile()
        end
    end
end

start_memprofile() = ccall(:jl_memprofile_start, Cvoid, ())
stop_memprofile() = ccall(:jl_memprofile_stop, Cvoid, ())

get_memprofile_bt_data() = ccall(:jl_memprofile_get_bt_data, Ptr{UInt}, ())
get_memprofile_bt_data_len() = convert(Int, ccall(:jl_memprofile_len_bt_data, Csize_t, ()))
get_memprofile_bt_data_maxlen() = convert(Int, ccall(:jl_memprofile_maxlen_bt_data, Csize_t, ()))

get_memprofile_alloc_data() = ccall(:jl_memprofile_get_alloc_data, Ptr{allocation_info_t}, ())
get_memprofile_alloc_data_len() = convert(Int, ccall(:jl_memprofile_len_alloc_data, Csize_t, ()))
get_memprofile_alloc_data_maxlen() = convert(Int, ccall(:jl_memprofile_maxlen_alloc_data, Csize_t, ()))

get_memprofile_overflow() = ccall(:jl_memprofile_overflow, Cint, ())

"""
    read_and_coalesce_memprofile_data()

Load in the backtrace and allocation data buffers from the C side of Julia-land, returns two
vectors, `open_chunks` and `closed_chunks`, which represent all allocations that are yet to
be freed, and all allocations that were properly freed.
"""
function read_and_coalesce_memprofile_data()
    overflow = get_memprofile_overflow()
    if overflow & 0x01 != 0
        @warn """The memory profile backtrace buffer overflowed; profiling terminated
                 before your program finished. To profile for longer runs, call
                 `Profile.init()` with a larger buffer and/or larger delay."""
    end
    if overflow & 0x02 != 0
        @warn """The memory profile allocation info buffer overflowed; profiling terminated
                 before your program finished. To profile for longer runs, call
                 `Profile.init()` with a larger buffer and/or larger delay."""
    end

    bt_data = unsafe_wrap(Array, get_memprofile_bt_data(), (get_memprofile_bt_data_len(),))
    alloc_data = unsafe_wrap(Array, get_memprofile_alloc_data(), (get_memprofile_alloc_data_len(),))

    # Build backtrace lookup table
    bt_data = Base._reformat_bt(bt_data)
    bt_lookup = bt_lookup_dict(bt_data)

    # These are chunks of memory that have been allocated, but not yet freed.  They are keyed by
    # (memory_address, tag) for easy lookup
    open_chunks_map = Dict{Tuple{UInt,UInt8},AllocationInfo}()

    # These are chunks of memory that have been allocated and then freed.  They will start in
    # open_chunks_map, then get migrated over here once they are freed.
    closed_chunks = AllocationInfo[]

    # These are chunks of memory that were free'd but we didn't see them get created.
    ghost_chunks = Tuple[]

    # Loop over every event in `alloc_data`, looking for identical memory pointers; attempt to pair
    # them together to create "closed" chunks:
    bt_idx = 1
    for a in alloc_data
        # Extract the backtrace associated with this allocation event
        bt_end_idx = bt_idx
        while bt_data[bt_end_idx] != 0x0
            bt_end_idx += 1
        end
        bt = [bt_lookup[x][1] for x in bt_data[bt_idx:bt_end_idx-1]]
        bt_idx = bt_end_idx + 1

        # Construct the "chunk identifier" that we use to loop up within open_chunks_map, etc...
        chunk_id = (UInt(a.address), a.tag)

        # Are we an allocation?
        if a.allocsz != 0
            @info("Opening $(chunk_id) $(a.allocsz)")

            # Assert that we're not inserting an identical chunk
            @assert !(chunk_id in keys(open_chunks_map)) "Doubly-opened memory chunk!"
            open_chunks_map[chunk_id] = open_AI(a, bt)
        else
            @info("Closing $(chunk_id)")

            # If this `a` represents a free(), let's see if we're closing a previously opened chunk.
            if !(chunk_id in keys(open_chunks_map))
                push!(ghost_chunks, (a, bt))
            else
                # "Close" the chunk by adding deallocation information to it, then remove
                # that chunk from the open_chunks_map!
                push!(closed_chunks, close_AI(open_chunks_map[chunk_id], a, bt))
                delete!(open_chunks_map, chunk_id)
            end
        end
    end

    if !isempty(ghost_chunks)
        @warn "Attempted to close $(length(ghost_chunks)) ghost memory chunks!"
    end

    # Any leftover "open" chunks are just plain old leaked memory.  >:}
    open_chunks = sort(collect(values(open_chunks_map)); by = x -> x.alloc_time)
    closed_chunks = sort(closed_chunks, by = x -> x.alloc_time)

    return open_chunks, closed_chunks, ghost_chunks
end


"""
    clear()

Clear any existing memory profile data from the internal buffers.
"""
clear_memprofile_data() = ccall(:jl_memprofile_clear_data, Cvoid, ())

end # module Memory
