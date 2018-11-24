#include <stdlib.h>
#include <stddef.h>
#include <stdio.h>
#include <inttypes.h>
#include "julia.h"
#include "julia_internal.h"


typedef struct _memprof_allocation_info_t
{
    // The location of the chunk of data in memory, used to match
    // allocations with deallocations.
    void *memory_location;

    // The time at which this happened
    double time;

    // The size of the allocation, or 0 if this was a free of a
    // previously-allocated piece of data.
    size_t allocsz;

    // Used to "tag" this allocation within a particular domain (currently only CPU, GPU, other)
    uint8_t tag;
} allocation_info_t;

static uintptr_t * memprof_bt_data = NULL;
static volatile size_t memprof_bt_data_size = 0;
static volatile size_t memprof_bt_data_size_max = 0;

static allocation_info_t * memprof_alloc_data = NULL;
static volatile size_t memprof_alloc_data_size = 0;
static volatile size_t memprof_alloc_data_size_max = 0;

static volatile uint8_t memprof_running = 0;
static volatile uint8_t memprof_overflow = 0;
static volatile uint8_t memprof_tag_filter = 0xff;

JL_DLLEXPORT void jl_memprofile_clear_data(void)
{
    memprof_bt_data_size = 0;
    memprof_alloc_data_size = 0;
    memprof_overflow = 0;
}

JL_DLLEXPORT int jl_memprofile_init(size_t bt_maxsize, size_t alloc_maxsize, uint8_t tag_filter)
{
    // Free previous profile buffers, if we have any
    if (memprof_bt_data != NULL) {
        free((void*)memprof_bt_data);
        memprof_bt_data = NULL;
        memprof_bt_data_size = 0;
        memprof_bt_data_size_max = 0;
    }
    if (memprof_alloc_data != NULL) {
        free((void*)memprof_alloc_data);
        memprof_alloc_data = NULL;
        memprof_alloc_data_size = 0;
        memprof_alloc_data_size_max = 0;
    }

    // Initialize new profile buffers.  We assume at least 10x 
    memprof_bt_data = (uintptr_t*) calloc(bt_maxsize, sizeof(uintptr_t));
    if (memprof_bt_data == NULL && bt_maxsize > 0) {
        return -1;
    }

    memprof_alloc_data = (allocation_info_t*) calloc(alloc_maxsize, sizeof(allocation_info_t));
    if (memprof_alloc_data == NULL && alloc_maxsize > 0) {
        // Cleanup the previous allocation in the event of failure, so that it
        // cannot be used accidentally.
        free((void*)memprof_bt_data);
        memprof_bt_data = NULL;
        return -1;
    }

    memprof_bt_data_size_max = bt_maxsize;
    memprof_alloc_data_size_max = alloc_maxsize;
    memprof_tag_filter = tag_filter;
    jl_memprofile_clear_data();
    return 0;
}

JL_DLLEXPORT uint8_t* jl_memprofile_get_bt_data(void)
{
    return (uint8_t*) memprof_bt_data;
}

JL_DLLEXPORT uint8_t* jl_memprofile_get_alloc_data(void)
{
    return (uint8_t*) memprof_alloc_data;
}

JL_DLLEXPORT size_t jl_memprofile_len_bt_data(void)
{
    return memprof_bt_data_size;
}

JL_DLLEXPORT size_t jl_memprofile_len_alloc_data(void)
{
    return memprof_alloc_data_size;
}

JL_DLLEXPORT size_t jl_memprofile_maxlen_bt_data(void)
{
    return memprof_bt_data_size_max;
}

JL_DLLEXPORT size_t jl_memprofile_maxlen_alloc_data(void)
{
    return memprof_alloc_data_size_max;
}

JL_DLLEXPORT int jl_memprofile_running(void)
{
    return memprof_running == 1;
}

JL_DLLEXPORT int jl_memprofile_overflow(void)
{
    return memprof_overflow;
}

JL_DLLEXPORT int jl_memprofile_tag_filter(void)
{
    return memprof_tag_filter;
}

JL_DLLEXPORT void jl_memprofile_start(void)
{
    memprof_running = 1;
}

JL_DLLEXPORT void jl_memprofile_stop(void)
{
    memprof_running = 0;
}

JL_DLLEXPORT void jl_memprofile_track_alloc(void *v, uint8_t tag, size_t allocsz)
{
    // Filter out this call with our tag filter
    if ((tag & memprof_tag_filter) != tag)
        return;

    // Store the current backtrace location into our buffer, and increment the
    // buffer index by the number of elements added.
    size_t bt_step = 0;
    bt_step = rec_backtrace(memprof_bt_data + memprof_bt_data_size,
                            memprof_bt_data_size_max - memprof_bt_data_size - 1);

    // If we overran this buffer, then don't record the memory trace and quit.
    if (bt_step == memprof_bt_data_size_max - memprof_bt_data_size) {
        memprof_overflow |= JL_MEMPROF_BT_OVERFLOW;
        jl_memprofile_stop();
        return;
    } else {
        // Otherwise, include this block and add a NULL-separator
        memprof_bt_data_size += bt_step;
        memprof_bt_data[memprof_bt_data_size++] = (uintptr_t)NULL;
    }

    // Next up; store allocation information
    memprof_alloc_data[memprof_alloc_data_size].memory_location = v;
    memprof_alloc_data[memprof_alloc_data_size].time = jl_clock_now();

    // If we are deallocating, then we set allocsz to 0 and must pair this alloc_data entry
    // with a previous allocation within alloc_data to make sense of it.
    memprof_alloc_data[memprof_alloc_data_size].allocsz = allocsz;

    // Tags are used to track the "domain" of this chunk of memory
    memprof_alloc_data[memprof_alloc_data_size].tag = tag;

    memprof_alloc_data_size++;
    
    if (memprof_alloc_data_size >= memprof_alloc_data_size_max) {
        memprof_overflow |= JL_MEMPROF_ALLOC_OVERFLOW;
        jl_memprofile_stop();
    }
}

JL_DLLEXPORT void jl_memprofile_track_dealloc(void *v, uint8_t tag)
{
    jl_memprofile_track_alloc(v, tag, 0);
}
