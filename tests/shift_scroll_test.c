#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../src/behavior_shift_scroll.c"

static unsigned char explicit_mods, masked_mods, reported_mods;
static int child_error;
static struct {
    char kind;
    unsigned char mods;
    bool down;
    uint32_t direction;
} events[32];
static unsigned int event_count;

const struct device *zmk_behavior_get_binding(const char *name) {
    return strcmp(name, "down") == 0 ? &device_0 : &device_1;
}

unsigned char zmk_hid_get_explicit_mods(void) { return explicit_mods; }

int zmk_hid_masked_modifiers_set(unsigned char mask) {
    unsigned char before = explicit_mods & ~masked_mods;
    masked_mods = mask;
    return before != (explicit_mods & ~masked_mods);
}

int zmk_hid_masked_modifiers_clear(void) { return zmk_hid_masked_modifiers_set(0); }

int zmk_endpoints_send_report(int page) {
    assert(page == HID_USAGE_KEY);
    assert(event_count < 32);
    reported_mods = explicit_mods & ~masked_mods;
    events[event_count].kind = 'k';
    events[event_count++].mods = reported_mods;
    return 0;
}

int zmk_behavior_invoke_binding(struct zmk_behavior_binding *binding,
                                struct zmk_behavior_binding_event event, bool down) {
    (void)event;
    assert(event_count < 32);
    events[event_count].kind = binding->behavior_dev[0];
    events[event_count].mods = reported_mods;
    events[event_count].direction = binding->param1;
    events[event_count++].down = down;
    return child_error;
}

static void reset(unsigned char mods) {
    memset(&shift_scroll_data_0, 0, sizeof(shift_scroll_data_0));
    memset(&shift_scroll_data_1, 0, sizeof(shift_scroll_data_1));
    scrolling_keys = 0;
    explicit_mods = reported_mods = mods;
    masked_mods = 0;
    event_count = 0;
    child_error = 0;
}

int main(void) {
    struct zmk_behavior_binding down = {.behavior_dev = "down"};
    struct zmk_behavior_binding up = {.behavior_dev = "up"};
    struct zmk_behavior_binding_event event = {0};

    // Plain movement stays movement even if Shift changes before release.
    reset(0);
    assert(shift_scroll_api.binding_pressed(&down, event) == 0);
    explicit_mods = MOD_LSFT;
    assert(shift_scroll_api.binding_released(&down, event) == 0);
    assert(event_count == 2 && events[0].kind == 'm' && events[1].kind == 'm');
    assert(events[0].down && !events[1].down && scrolling_keys == 0);

    // Either Shift, or both, must be suppressed before the first scroll event.
    unsigned char shifts[] = {MOD_LSFT, MOD_RSFT, MOD_LSFT | MOD_RSFT};
    for (unsigned int i = 0; i < sizeof(shifts); i++) {
        reset(shifts[i] | MOD_LCTL);
        assert(shift_scroll_pressed(&up, event) == 0);
        assert(event_count == 2 && events[0].kind == 'k' && events[1].kind == 's');
        assert(events[0].mods == MOD_LCTL && events[1].mods == MOD_LCTL);
        assert(events[1].direction == 1);
        assert(shift_scroll_released(&up, event) == 0);
        assert(event_count == 4 && events[2].kind == 's' && !events[2].down);
        assert(events[3].kind == 'k' && events[3].mods == (shifts[i] | MOD_LCTL));
        assert(masked_mods == 0 && scrolling_keys == 0);
    }

    // Opposite scroll keys can overlap. Releasing either must not restore Shift early.
    reset(MOD_LSFT);
    assert(shift_scroll_pressed(&down, event) == 0);
    assert(events[1].direction == 0);
    assert(shift_scroll_pressed(&up, event) == 0);
    assert(scrolling_keys == 2);
    assert(shift_scroll_released(&down, event) == 0);
    assert(scrolling_keys == 1 && reported_mods == 0 && masked_mods == SHIFT_MASK);
    assert(shift_scroll_released(&up, event) == 0);
    assert(scrolling_keys == 0 && reported_mods == MOD_LSFT && masked_mods == 0);

    // Releasing Shift first must stop the scroll on key-up without a stuck modifier.
    reset(MOD_LSFT);
    assert(shift_scroll_pressed(&down, event) == 0);
    explicit_mods = 0;
    zmk_endpoints_send_report(HID_USAGE_KEY);
    assert(shift_scroll_released(&down, event) == 0);
    assert(events[event_count - 1].kind == 's' && !events[event_count - 1].down);
    assert(reported_mods == 0 && masked_mods == 0 && scrolling_keys == 0);

    // Failed presses, duplicate presses and duplicate releases must not leak mask state.
    reset(MOD_RSFT);
    child_error = -EIO;
    assert(shift_scroll_pressed(&down, event) == -EIO);
    assert(!shift_scroll_data_0.active && scrolling_keys == 0 && masked_mods == 0);
    assert(reported_mods == MOD_RSFT);
    child_error = 0;
    assert(shift_scroll_pressed(&down, event) == 0);
    assert(shift_scroll_pressed(&down, event) == -ENOTSUP);
    assert(scrolling_keys == 1);
    assert(shift_scroll_released(&down, event) == 0);
    assert(shift_scroll_released(&down, event) == -ENOTSUP);
    assert(scrolling_keys == 0 && masked_mods == 0);

    puts("Shift-scroll modifier ordering, overlap, release and error tests passed.");
    return 0;
}
