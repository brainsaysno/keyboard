/* SPDX-License-Identifier: MIT */

// Right half: reassembles text slots relayed from the left half (see mac_link_protocol.h) and
// renders them. The keyboard has no clock or text of its own; everything shown comes from the
// Mac companion app.

#define DT_DRV_COMPAT zmk_behavior_mac_text

#include <stdio.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <drivers/behavior.h>
#include <lvgl.h>
#include <zmk/battery.h>
#include <zmk/behavior.h>
#include <zmk/display.h>
#include <zmk/split/bluetooth/peripheral.h>

#include "mac_link_protocol.h"

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

// The panel is 160x68 but mounted portrait: draw a 68x160 image, then rotate it onto the panel.
#define WIDTH 68
#define HEIGHT 160
// No text from the Mac for this long means the companion app is not running.
#define OFFLINE_AFTER K_SECONDS(90)
#define WAITING 0xFF

#define FOREGROUND lv_color_black()
#define BACKGROUND lv_color_white()

struct incoming_text {
    char text[MAC_LINK_MAX_TEXT + 1];
    uint8_t expected; // next byte offset, or WAITING until a text starts at offset 0
    uint8_t total;
};

// Only the split service thread touches incoming[]; shown[] is shared with the display thread.
static struct incoming_text incoming[MAC_LINK_SLOT_COUNT] = {
    [0 ... MAC_LINK_SLOT_COUNT - 1] = {.expected = WAITING},
};
static char shown[MAC_LINK_SLOT_COUNT][MAC_LINK_MAX_TEXT + 1];
static bool online;
static K_MUTEX_DEFINE(shown_lock);

static lv_color_t portrait_buf[WIDTH * HEIGHT];
static lv_color_t panel_buf[HEIGHT * WIDTH];
static lv_obj_t *portrait;
static lv_obj_t *panel;

static void draw_text(const lv_font_t *font, lv_text_align_t align, lv_coord_t x, lv_coord_t y,
                      lv_coord_t width, const char *text) {
    lv_draw_label_dsc_t dsc;
    lv_draw_label_dsc_init(&dsc);
    dsc.color = FOREGROUND;
    dsc.font = font;
    dsc.align = align;
    lv_canvas_draw_text(portrait, x, y, width, &dsc, text);
}

static void fill(lv_coord_t y, lv_coord_t height, lv_color_t color) {
    lv_draw_rect_dsc_t dsc;
    lv_draw_rect_dsc_init(&dsc);
    dsc.bg_color = color;
    lv_canvas_draw_rect(portrait, 0, y, WIDTH, height, &dsc);
}

static void render(void) {
    // Rendering happens only on the display thread, so one static copy is enough.
    static char text[MAC_LINK_SLOT_COUNT][MAC_LINK_MAX_TEXT + 1];
    bool is_online;

    if (portrait == NULL) {
        return;
    }

    k_mutex_lock(&shown_lock, K_FOREVER);
    memcpy(text, shown, sizeof(text));
    is_online = online;
    k_mutex_unlock(&shown_lock);

    lv_canvas_fill_bg(portrait, BACKGROUND, LV_OPA_COVER);

#if IS_ENABLED(CONFIG_ZMK_BATTERY_REPORTING)
    char battery[8];
    snprintf(battery, sizeof(battery), "%u%%", zmk_battery_state_of_charge());
    draw_text(&lv_font_montserrat_12, LV_TEXT_ALIGN_LEFT, 0, 0, WIDTH, battery);
#endif
    draw_text(&lv_font_montserrat_12, LV_TEXT_ALIGN_RIGHT, 0, 0, WIDTH,
              zmk_split_bt_peripheral_is_connected() ? LV_SYMBOL_BLUETOOTH : LV_SYMBOL_CLOSE);
    fill(15, 1, FOREGROUND);

    if (is_online) {
        draw_text(&lv_font_montserrat_22, LV_TEXT_ALIGN_CENTER, 0, 18, WIDTH,
                  text[MAC_LINK_SLOT_TIME]);
        draw_text(&lv_font_montserrat_14, LV_TEXT_ALIGN_CENTER, 0, 44, WIDTH,
                  text[MAC_LINK_SLOT_DETAIL]);
        fill(63, 1, FOREGROUND);
        draw_text(&lv_font_montserrat_12, LV_TEXT_ALIGN_LEFT, 1, 67, WIDTH - 2,
                  text[MAC_LINK_SLOT_PHRASE]);
        // Clip a phrase that runs long instead of letting it overprint the author.
        fill(143, HEIGHT - 143, BACKGROUND);
        draw_text(&lv_font_montserrat_12, LV_TEXT_ALIGN_RIGHT, 0, 145, WIDTH - 1,
                  text[MAC_LINK_SLOT_AUTHOR]);
    } else {
        draw_text(&lv_font_montserrat_22, LV_TEXT_ALIGN_CENTER, 0, 18, WIDTH, "--:--");
        fill(63, 1, FOREGROUND);
        draw_text(&lv_font_montserrat_12, LV_TEXT_ALIGN_CENTER, 0, 90, WIDTH,
                  "Waiting for Mac");
    }

    // Rotate 90 degrees clockwise: portrait (x, y) lands at panel (HEIGHT - 1 - y, x).
    for (int y = 0; y < HEIGHT; y++) {
        for (int x = 0; x < WIDTH; x++) {
            panel_buf[x * HEIGHT + (HEIGHT - 1 - y)] = portrait_buf[y * WIDTH + x];
        }
    }
    lv_obj_invalidate(panel);
}

static void render_cb(struct k_work *work) { render(); }
static K_WORK_DEFINE(render_work, render_cb);

static void offline_cb(struct k_work *work) {
    k_mutex_lock(&shown_lock, K_FOREVER);
    online = false;
    k_mutex_unlock(&shown_lock);
    render();
}
static K_WORK_DELAYABLE_DEFINE(offline_work, offline_cb);

static void show(uint8_t slot, const char *text) {
    k_mutex_lock(&shown_lock, K_FOREVER);
    strcpy(shown[slot], text);
    online = true;
    k_mutex_unlock(&shown_lock);

    k_work_reschedule_for_queue(zmk_display_work_q(), &offline_work, OFFLINE_AFTER);
    k_work_submit_to_queue(zmk_display_work_q(), &render_work);
}

static void receive(uint8_t slot, uint8_t offset, uint8_t total, const uint8_t *bytes,
                    uint8_t count) {
    if (slot >= MAC_LINK_SLOT_COUNT || total > MAC_LINK_MAX_TEXT ||
        count > MAC_LINK_RELAY_CHUNK) {
        return;
    }

    struct incoming_text *in = &incoming[slot];
    if (offset == 0) {
        in->expected = 0;
        in->total = total;
    }
    // Pieces arrive in order, so a gap means one was lost; drop this copy and wait for the next.
    if (offset != in->expected || total != in->total || offset + count > total) {
        in->expected = WAITING;
        return;
    }

    memcpy(in->text + offset, bytes, count);
    in->expected += count;
    if (in->expected == total) {
        in->text[total] = '\0';
        in->expected = WAITING;
        show(slot, in->text);
    }
}

static int mac_text_pressed(struct zmk_behavior_binding *binding,
                            struct zmk_behavior_binding_event event) {
    uint32_t p1 = binding->param1;
    uint32_t p2 = binding->param2;
    const uint8_t bytes[MAC_LINK_RELAY_CHUNK] = {
        (uint8_t)(p1 >> 16), (uint8_t)(p1 >> 24), (uint8_t)p2,
        (uint8_t)(p2 >> 8),  (uint8_t)(p2 >> 16), (uint8_t)(p2 >> 24),
    };

    receive(event.position & 0x0F, p1 & 0xFF, (p1 >> 8) & 0xFF, bytes,
            (event.position >> 4) & 0x0F);
    return ZMK_BEHAVIOR_OPAQUE;
}

static int mac_text_released(struct zmk_behavior_binding *binding,
                             struct zmk_behavior_binding_event event) {
    return ZMK_BEHAVIOR_OPAQUE;
}

static const struct behavior_driver_api mac_text_api = {
    .binding_pressed = mac_text_pressed,
    .binding_released = mac_text_released,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif
};

BEHAVIOR_DT_INST_DEFINE(0, NULL, NULL, NULL, NULL, POST_KERNEL,
                        CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, &mac_text_api);

lv_obj_t *zmk_display_status_screen(void) {
    lv_obj_t *screen = lv_obj_create(NULL);

    portrait = lv_canvas_create(screen);
    lv_canvas_set_buffer(portrait, portrait_buf, WIDTH, HEIGHT, LV_IMG_CF_TRUE_COLOR);
    lv_obj_add_flag(portrait, LV_OBJ_FLAG_HIDDEN);

    panel = lv_canvas_create(screen);
    lv_canvas_set_buffer(panel, panel_buf, HEIGHT, WIDTH, LV_IMG_CF_TRUE_COLOR);
    lv_obj_align(panel, LV_ALIGN_TOP_LEFT, 0, 0);

    render();
    return screen;
}
