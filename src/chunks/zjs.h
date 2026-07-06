#pragma once
#include <stdint.h>
#include <stdbool.h>

void* journalStore_init(const char* path);
void  journalStore_deinit(void* handle);
bool  journalStore_put(void* handle, const uint8_t* data, size_t len);

typedef void (*OnChunkFound)(void* ctx, const uint8_t* data, size_t len);

void journalStore_getMany(
    void* handle,
    const uint8_t** hashes,  // array of hash pointers (20 bytes each)
    size_t hashCount,
    OnChunkFound callback,
    void* ctx
);