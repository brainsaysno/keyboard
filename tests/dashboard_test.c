#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dashboard_stale.h"

static void check_messages(void) {
    const uint8_t data_end[] = {DASHBOARD_MSG_DATA, 0x9F, 0x05, 0xAA}; // offset 1439
    const uint8_t data_past_end[] = {DASHBOARD_MSG_DATA, 0x9F, 0x05, 0xAA, 0xBB};
    const uint8_t data_far[] = {DASHBOARD_MSG_DATA, 0xFF, 0xFF, 0xAA};
    const uint8_t data_empty[] = {DASHBOARD_MSG_DATA, 0x00, 0x00};
    const uint8_t present[] = {DASHBOARD_MSG_PRESENT, 0xB1, 0x29};
    const uint8_t present_long[] = {DASHBOARD_MSG_PRESENT, 0xB1, 0x29, 0x00};
    const uint8_t unknown[] = {0x03, 0x00, 0x00, 0x00};
    uint8_t whole_frame[DASHBOARD_HEADER_SIZE + DASHBOARD_FRAME_SIZE] = {DASHBOARD_MSG_DATA};

    assert(DASHBOARD_FRAME_SIZE == 1440);
    assert(dashboard_message_valid(data_end, sizeof(data_end)));
    assert(!dashboard_message_valid(data_past_end, sizeof(data_past_end)));
    assert(!dashboard_message_valid(data_far, sizeof(data_far)));
    assert(!dashboard_message_valid(data_empty, sizeof(data_empty)));
    assert(!dashboard_message_valid(data_end, 2));
    assert(!dashboard_message_valid(data_end, 0));
    assert(dashboard_message_valid(present, sizeof(present)));
    assert(!dashboard_message_valid(present_long, sizeof(present_long)));
    assert(!dashboard_message_valid(present, 2));
    assert(!dashboard_message_valid(unknown, sizeof(unknown)));
    assert(dashboard_message_valid(whole_frame, sizeof(whole_frame)));
}

// argv[1]: "messages" checks dashboard_message_valid(); "never" or a minute count writes that
// "no data" frame to stdout.
int main(int argc, char **argv) {
    if (argc != 2) {
        return 2;
    }
    if (strcmp(argv[1], "messages") == 0) {
        check_messages();
        return 0;
    }

    uint8_t frame[DASHBOARD_FRAME_SIZE];
    // The renderer has to set every byte itself.
    memset(frame, 0xA5, sizeof(frame));
    if (strcmp(argv[1], "never") == 0) {
        dashboard_stale_render(frame, true, 0);
    } else {
        dashboard_stale_render(frame, false, (uint32_t)strtoul(argv[1], NULL, 10));
    }
    return fwrite(frame, 1, sizeof(frame), stdout) == sizeof(frame) ? 0 : 1;
}
