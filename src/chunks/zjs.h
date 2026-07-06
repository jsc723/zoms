#pragma once
#include <stdint.h>
#include <stdbool.h>

void* journalStore_init(const char* path);
void  journalStore_deinit(void* handle);
bool  journalStore_put(void* handle, const uint8_t* hash, const uint8_t* data, size_t len);


typedef struct {
    const uint8_t* ptr; // ?[*]const u8 (or uint8_t* if mutable)
    size_t len;         // usize
} JournalSlice;

void journalStore_getMany(
    void* handle,                 // ?*anyopaque
    char** keys,                  // ?[*]?[*]u8 (array of mutable C-strings)
    JournalSlice* out_slices,     // ?[*]JournalSlice
    size_t len                    // usize
);